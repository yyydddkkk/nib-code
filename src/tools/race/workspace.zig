const std = @import("std");
const process = @import("../process.zig");
const diff = @import("../diff.zig");
const Tools = @import("../../tools.zig").Tools;

const helper = @embedFile("workspace.py");

pub const Options = struct {
    cwd: ?[]const u8 = null,
    data_home: ?[]const u8 = null,
    detail: ?*?[]const u8 = null,
};

pub const Workspace = struct {
    root: []const u8 = "",
    cwd: []const u8 = "",
    base: []const u8 = "",
    home: []const u8,
    gpa: std.mem.Allocator,
    io: std.Io,
    cancel: *const std.atomic.Value(bool),
    lock: std.Io.File,
    storage: std.heap.ArenaAllocator,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cancel: *const std.atomic.Value(bool)) !Workspace {
        return createWithOptions(gpa, io, cancel, .{});
    }

    pub fn createWithOptions(gpa: std.mem.Allocator, io: std.Io, cancel: *const std.atomic.Value(bool), options: Options) !Workspace {
        if (cancel.load(.acquire)) return error.Canceled;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var env = try process.inheritedEnvironment(a);
        defer env.deinit();
        const data_home = options.data_home orelse try @import("../../config.zig").home(a, &env);
        const parent = try std.fs.path.join(a, &.{ data_home, "races" });
        try std.Io.Dir.cwd().createDirPath(io, parent);
        var random: [16]u8 = undefined;
        io.random(&random);
        const name = std.fmt.bytesToHex(random, .lower);
        const leaf = try std.fmt.allocPrint(a, "race-{s}", .{name});
        const home = try std.fs.path.resolve(a, &.{ parent, leaf });
        try std.Io.Dir.cwd().createDir(io, home, .fromMode(0o700));
        var initialized = false;
        errdefer if (!initialized) std.Io.Dir.cwd().deleteTree(io, home) catch {};
        const lock_path = try std.fs.path.join(a, &.{ home, "owner.lock" });
        const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .permissions = .fromMode(0o600) });
        errdefer lock.close(io);
        if (!try lock.tryLock(io, .exclusive)) return error.WorkspaceBusy;
        var writer = lock.writer(io, &.{});
        try writer.interface.writeAll("nib-race-1\n");
        try writer.interface.flush();
        var ws: Workspace = .{ .home = home, .gpa = gpa, .io = io, .cancel = cancel, .lock = lock, .storage = arena };
        initialized = true;
        // The lock outlives every helper process, including interrupted Git commands.
        errdefer ws.cleanup();
        const cwd = options.cwd orelse try std.process.currentPathAlloc(io, a);
        const output = try ws.invoke(a, "create", &.{cwd}, true);
        const parsed = try std.json.parseFromSlice(Response, a, output, .{ .ignore_unknown_fields = true });
        if (parsed.value.@"error") |message| {
            if (options.detail) |detail| detail.* = try gpa.dupe(u8, message);
            return error.WorkspaceRefused;
        }
        ws.root = parsed.value.root orelse return error.InvalidWorkspaceResponse;
        ws.cwd = parsed.value.cwd orelse return error.InvalidWorkspaceResponse;
        ws.base = parsed.value.base orelse return error.InvalidWorkspaceResponse;
        ws.storage = arena;
        return ws;
    }

    pub fn branch(ws: *Workspace, index: usize) ![]const u8 {
        const a = ws.storage.allocator();
        const number = try std.fmt.allocPrint(a, "{d}", .{index});
        const output = try ws.invoke(a, "branch", &.{number}, true);
        const parsed = try std.json.parseFromSlice(Response, a, output, .{ .ignore_unknown_fields = true });
        if (parsed.value.@"error" != null) return error.WorkspaceRefused;
        return parsed.value.path orelse error.InvalidWorkspaceResponse;
    }

    pub fn apply(ws: *Workspace, winner_root: []const u8) !Apply {
        if (ws.cancel.load(.acquire)) return error.Canceled;
        var arena: std.heap.ArenaAllocator = .init(ws.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        // Once parent writes can begin, cancellation must not kill the rollback owner.
        const output = try ws.invoke(a, "apply", &.{winner_root}, false);
        const parsed = try std.json.parseFromSlice(Response, a, output, .{ .ignore_unknown_fields = true });
        const value = parsed.value;
        const edits = try a.alloc(Edit, value.edits.len);
        const changes = try a.alloc(diff.Change, value.edits.len);
        for (value.edits, edits, changes) |wire, *edit, *change| {
            const before = if (wire.before) |bytes| try decode(a, bytes) else null;
            const after = if (wire.after) |bytes| try decode(a, bytes) else null;
            edit.* = .{ .path = wire.path, .before = before, .after = after };
            const old = before orelse "";
            const new = after orelse "";
            const binary = std.mem.indexOfScalar(u8, old, 0) != null or std.mem.indexOfScalar(u8, new, 0) != null or
                !std.unicode.utf8ValidateSlice(old) or !std.unicode.utf8ValidateSlice(new);
            const stat = if (binary) diff.Stat{ .added = 0, .removed = 0, .diff = "[binary file changed]\n" } else try diff.compare(a, old, new);
            change.* = .{ .path = wire.path, .added = stat.added, .removed = stat.removed, .created = before == null, .diff = stat.diff };
        }
        return .{ .ok = value.ok, .patch = value.patch, .@"error" = value.@"error", .changes = changes, .edits = edits, .storage = arena };
    }

    pub fn deinit(ws: *Workspace) void {
        ws.cleanup();
        ws.lock.close(ws.io);
        ws.storage.deinit();
        ws.* = undefined;
    }

    fn cleanup(ws: *Workspace) void {
        var scratch: std.heap.ArenaAllocator = .init(ws.gpa);
        defer scratch.deinit();
        _ = ws.invoke(scratch.allocator(), "clean", &.{}, false) catch {};
    }

    fn invoke(ws: *Workspace, a: std.mem.Allocator, operation: []const u8, args: []const []const u8, cancellable: bool) ![]const u8 {
        var never_cancel: std.atomic.Value(bool) = .init(false);
        return runHelper(a, ws.io, if (cancellable) ws.cancel else &never_cancel, ws.home, operation, args);
    }
};

pub fn cleanupResidual(gpa: std.mem.Allocator, io: std.Io, data_home: []const u8) !void {
    const parent = try std.fs.path.join(gpa, &.{ data_home, "races" });
    defer gpa.free(parent);
    std.Io.Dir.cwd().access(io, parent, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    var cancel: std.atomic.Value(bool) = .init(false);
    const result = try process.run(gpa, io, .{
        .spawn = .{ .argv = &.{ "python3", "-c", helper, "reap", parent }, .stdout = .pipe, .stderr = .ignore },
        .cancel = &cancel,
        .timeout_ms = 30_000,
    });
    defer gpa.free(result.output);
    if (!result.term.success()) return error.WorkspaceCleanupFailed;
}

fn runHelper(a: std.mem.Allocator, io: std.Io, cancel: *const std.atomic.Value(bool), home: []const u8, operation: []const u8, args: []const []const u8) ![]const u8 {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{ "python3", "-c", helper, operation, home }, args });
    const result = try process.run(a, io, .{
        .spawn = .{ .argv = argv, .stdout = .pipe, .stderr = .ignore },
        .cancel = cancel,
        .timeout_ms = 0,
        .max_output_bytes = std.math.maxInt(usize),
    });
    if (result.stop) |stop| return stop;
    if (!result.term.success()) return error.WorkspaceHelperFailed;
    return result.output;
}

const WireEdit = struct { path: []const u8, before: ?[]const u8 = null, after: ?[]const u8 = null };
const Edit = struct { path: []const u8, before: ?[]const u8, after: ?[]const u8 };
const Response = struct {
    ok: bool = false,
    root: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    base: ?[]const u8 = null,
    path: ?[]const u8 = null,
    patch: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    edits: []const WireEdit = &.{},
};

pub const Apply = struct {
    ok: bool,
    patch: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    changes: []const diff.Change = &.{},
    edits: []const Edit = &.{},
    storage: std.heap.ArenaAllocator,

    pub fn deinit(result: *Apply, gpa: std.mem.Allocator) void {
        _ = gpa;
        result.storage.deinit();
        result.* = undefined;
    }

    pub fn recordChanges(result: *const Apply, t: *Tools, gpa: std.mem.Allocator) !void {
        if (!result.ok) return;
        if (!t.track_changes) return;
        t.changes_mutex.lockUncancelable(t.io);
        defer t.changes_mutex.unlock(t.io);
        for (result.changes) |change| try t.changes.recordSummary(gpa, change);
    }
};

fn decode(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const decoder = std.base64.standard.Decoder;
    const output = try a.alloc(u8, try decoder.calcSizeForSlice(bytes));
    try decoder.decode(output, bytes);
    return output;
}

const testing = std.testing;

test "race Git workspace helper integration" {
    var cancel: std.atomic.Value(bool) = .init(false);
    const result = try process.run(testing.allocator, testing.io, .{
        .spawn = .{ .argv = &.{ "python3", "-c", @embedFile("workspace_test.py"), helper }, .stdout = .pipe, .stderr = .ignore },
        .cancel = &cancel,
        .timeout_ms = 60_000,
    });
    defer testing.allocator.free(result.output);
    if (!result.term.success()) std.debug.print("{s}\n", .{result.output});
    try testing.expect(result.term.success());
}

test "race workspace ownership apply and cancellation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var cancel: std.atomic.Value(bool) = .init(false);
    const setup = try process.run(testing.allocator, testing.io, .{
        .spawn = .{ .argv = &.{
            "python3",
            "-c",
            "import subprocess, pathlib; subprocess.run(['git','init','-q'],check=True); pathlib.Path('file').write_text('old\\n'); subprocess.run(['git','add','file'],check=True); subprocess.run(['git','-c','user.name=Test','-c','user.email=test@localhost','commit','-qm','base'],check=True)",
        }, .cwd = .{ .path = root }, .stdout = .pipe, .stderr = .ignore },
        .cancel = &cancel,
        .timeout_ms = 30_000,
    });
    defer testing.allocator.free(setup.output);
    try testing.expect(setup.term.success());
    const data_home = try std.fs.path.join(testing.allocator, &.{ root, ".git", "nib" });
    defer testing.allocator.free(data_home);
    var ws = try Workspace.createWithOptions(testing.allocator, testing.io, &cancel, .{ .cwd = root, .data_home = data_home });
    var live = true;
    defer if (live) ws.deinit();
    const branch_root = try ws.branch(0);
    const file = try std.fs.path.join(testing.allocator, &.{ branch_root, "file" });
    defer testing.allocator.free(file);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = file, .data = "new\n" });
    var applied = try ws.apply(branch_root);
    defer applied.deinit(testing.allocator);
    try testing.expect(applied.ok);
    try testing.expectEqual(@as(usize, 1), applied.changes.len);
    try testing.expectEqual(@as(usize, 1), applied.changes[0].added);
    try testing.expectEqual(@as(usize, 1), applied.changes[0].removed);
    const content = try tmp.dir.readFileAlloc(testing.io, "file", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("new\n", content);
    cancel.store(true, .release);
    try testing.expectError(error.Canceled, ws.branch(1));
    try testing.expectError(error.Canceled, ws.apply(branch_root));
    const private_home = try testing.allocator.dupe(u8, ws.home);
    defer testing.allocator.free(private_home);
    ws.deinit();
    live = false;
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, private_home, .{}));
    try testing.expectEqual(@as(usize, 1), applied.changes[0].added);
}
