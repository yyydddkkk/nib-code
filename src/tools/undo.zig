const std = @import("std");
const Tools = @import("../tools.zig").Tools;
const atomic = @import("atomic_file.zig");
const file_state = @import("file_state.zig");

pub const file_limit = 16 * 1024 * 1024;
pub const turn_limit = 64 * 1024 * 1024;
pub const path_limit = 256;
pub const history_limit = 8;

pub const Reason = enum(u8) {
    snapshot_unavailable = 1,
    file_too_large,
    path_limit,
    turn_limit,

    pub fn text(reason: Reason) []const u8 {
        return switch (reason) {
            .snapshot_unavailable => "undo snapshot could not be read or saved",
            .file_too_large => "file exceeds undo limit (16 MiB)",
            .path_limit => "Turn exceeds undo path limit (256 files)",
            .turn_limit => "Turn exceeds undo snapshot limit (64 MiB)",
        };
    }
};

pub fn markIncomplete(t: *Tools, gpa: std.mem.Allocator, reason: Reason) void {
    const directory = t.undo_dir orelse return;
    _ = t.undo_failure.cmpxchgStrong(0, @backingInt(reason), .acq_rel, .acquire);
    const protection = t.io.swapCancelProtection(.blocked);
    defer _ = t.io.swapCancelProtection(protection);
    const lock = file_state.lock(t, gpa, directory) catch return;
    defer lock.close(t.io);
    // The lock inode shares failure state with children even when snapshots are unwritable.
    if ((lock.length(t.io) catch 0) == 0) lock.setLength(t.io, @backingInt(reason)) catch {};
}

fn recordedReason(t: *Tools, gpa: std.mem.Allocator, directory: []const u8) !?Reason {
    const local = t.undo_failure.load(.acquire);
    if (local != 0) return @fromBackingInt(@intCast(local));
    const lock = try file_state.lock(t, gpa, directory);
    defer lock.close(t.io);
    const code = try lock.length(t.io);
    return if (code == 0) null else std.enums.fromInt(Reason, code) orelse .snapshot_unavailable;
}

const Entry = struct {
    path: []const u8,
    created: bool,
    hash: [32]u8,
    pending: bool = true,
    tainted: bool = false,
    undone: bool = false,
};

fn hash(data: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &result, .{});
    return result;
}

pub const Write = struct {
    lock: std.Io.File,
    metadata: []const u8,
    snapshot: []const u8,
    entry: Entry,
    previous: ?Entry,
    written: bool = false,

    pub fn deinit(w: *Write, t: *Tools, gpa: std.mem.Allocator) void {
        const protection = t.io.swapCancelProtection(.blocked);
        defer _ = t.io.swapCancelProtection(protection);
        if (!w.written) {
            if (w.previous) |entry| {
                save(t.io, gpa, w.metadata, entry) catch {};
            } else {
                std.Io.Dir.cwd().deleteFile(t.io, w.metadata) catch {};
                std.Io.Dir.cwd().deleteFile(t.io, w.snapshot) catch {};
            }
        }
        gpa.free(w.entry.path);
        gpa.free(w.metadata);
        gpa.free(w.snapshot);
        w.lock.close(t.io);
    }

    pub fn commit(w: *Write, t: *Tools, gpa: std.mem.Allocator, after: []const u8) void {
        w.written = true;
        const protection = t.io.swapCancelProtection(.blocked);
        defer _ = t.io.swapCancelProtection(protection);
        w.entry.hash = hash(after);
        w.entry.pending = false;
        save(t.io, gpa, w.metadata, w.entry) catch {
            _ = t.undo_failure.cmpxchgStrong(0, @backingInt(Reason.snapshot_unavailable), .acq_rel, .acquire);
            if ((w.lock.length(t.io) catch 0) == 0) w.lock.setLength(t.io, @backingInt(Reason.snapshot_unavailable)) catch {};
        };
    }
};

fn save(io: std.Io, gpa: std.mem.Allocator, path: []const u8, entry: Entry) !void {
    const data = try std.json.Stringify.valueAlloc(gpa, entry, .{});
    defer gpa.free(data);
    _ = try atomic.replace(io, gpa, path, data, .{ .permissions = atomic.private_file });
}

pub fn prepare(t: *Tools, gpa: std.mem.Allocator, path: []const u8, before: ?[]const u8, after: []const u8) ?Write {
    return prepareTracked(t, gpa, path, before, after) catch |err| {
        markIncomplete(t, gpa, switch (err) {
            error.UndoFileTooLarge => .file_too_large,
            error.UndoPathLimit => .path_limit,
            error.UndoTurnLimit => .turn_limit,
            else => .snapshot_unavailable,
        });
        return null;
    };
}

fn prepareTracked(t: *Tools, gpa: std.mem.Allocator, path: []const u8, before: ?[]const u8, after: []const u8) !?Write {
    const directory = t.undo_dir orelse return null;
    if (t.undo_failure.load(.acquire) != 0) return null;
    if (before != null and std.mem.eql(u8, before.?, after)) return null;
    if (after.len > file_limit or (before != null and before.?.len > file_limit)) return error.UndoFileTooLarge;
    const lock = try file_state.lock(t, gpa, directory);
    errdefer lock.close(t.io);
    if (try lock.length(t.io) != 0) {
        lock.close(t.io);
        return null;
    }
    const key = std.fmt.bytesToHex(hash(path), .lower);
    const metadata = try std.fmt.allocPrint(gpa, "{s}/{s}.json", .{ directory, key });
    errdefer gpa.free(metadata);
    const snapshot = try std.fmt.allocPrint(gpa, "{s}/{s}.before", .{ directory, key });
    errdefer gpa.free(snapshot);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = std.Io.Dir.cwd();
    const old = dir.readFileAlloc(t.io, metadata, a, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const previous = if (old) |data| try std.json.parseFromSliceLeaky(Entry, a, data, .{}) else null;
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    var entry: Entry = previous orelse .{ .path = path, .created = before == null, .hash = hash(before orelse "") };
    entry.path = owned_path;
    errdefer if (previous == null) {
        dir.deleteFile(t.io, metadata) catch {};
        dir.deleteFile(t.io, snapshot) catch {};
    };
    if (old == null) {
        const folder = try dir.openDir(t.io, directory, .{ .iterate = true });
        defer folder.close(t.io);
        var it = folder.iterate();
        var total: u64 = 0;
        var paths: usize = 0;
        while (try it.next(t.io)) |item| {
            if (std.mem.endsWith(u8, item.name, ".json")) paths += 1;
            if (std.mem.endsWith(u8, item.name, ".before")) total += (try folder.statFile(t.io, item.name, .{})).size;
        }
        if (paths >= path_limit) return error.UndoPathLimit;
        if (total + (if (before) |data| data.len else @as(usize, 0)) > turn_limit) return error.UndoTurnLimit;
        if (before) |data| _ = try atomic.replace(t.io, gpa, snapshot, data, .{ .permissions = atomic.private_file });
    } else if (before == null or !std.mem.eql(u8, &entry.hash, &hash(before.?))) {
        entry.tainted = true;
    }
    entry.pending = true;
    try save(t.io, gpa, metadata, entry);
    var saved = previous;
    if (saved) |*value| value.path = owned_path;
    return .{ .lock = lock, .metadata = metadata, .snapshot = snapshot, .entry = entry, .previous = saved };
}

pub const History = struct {
    const Turn = struct { path: []const u8, reason: ?Reason = null };

    root: ?[]const u8 = null,
    turns: std.ArrayList(Turn) = .empty,
    notice: ?Reason = null,

    pub fn begin(h: *History, t: *Tools, gpa: std.mem.Allocator) !void {
        const root = h.root orelse return;
        var random: [16]u8 = undefined;
        t.io.random(&random);
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, std.fmt.bytesToHex(random, .lower) });
        errdefer gpa.free(path);
        const reason: ?Reason = if (std.Io.Dir.cwd().createDirPath(t.io, path)) null else |_| .snapshot_unavailable;
        try h.turns.append(gpa, .{ .path = path, .reason = reason });
        t.undo_failure.store(0, .release);
        h.notice = null;
        t.undo_dir = path;
    }

    pub fn finish(h: *History, t: *Tools, gpa: std.mem.Allocator) void {
        if (h.root == null) return;
        t.undo_dir = null;
        if (h.turns.items.len == 0) return;
        const turn = &h.turns.items[h.turns.items.len - 1];
        const path = turn.path;
        turn.reason = turn.reason orelse (recordedReason(t, gpa, path) catch .snapshot_unavailable);
        const dir = std.Io.Dir.cwd().openDir(t.io, path, .{ .iterate = true }) catch null;
        defer if (dir) |folder| folder.close(t.io);
        const has_entries = if (dir) |folder| entries: {
            var it = folder.iterate();
            break :entries (it.next(t.io) catch {
                turn.reason = .snapshot_unavailable;
                break :entries true;
            }) != null;
        } else missing: {
            turn.reason = .snapshot_unavailable;
            break :missing true;
        };
        h.notice = turn.reason;
        if (turn.reason != null or has_entries) {
            if (h.turns.items.len > history_limit) {
                const oldest = h.turns.orderedRemove(0);
                std.Io.Dir.cwd().deleteTree(t.io, oldest.path) catch {};
                gpa.free(oldest.path);
            }
            return;
        }
        _ = h.turns.pop();
        std.Io.Dir.cwd().deleteTree(t.io, path) catch {};
        gpa.free(path);
    }

    pub fn deinit(h: *History, io: std.Io, gpa: std.mem.Allocator) void {
        if (h.root) |root| std.Io.Dir.cwd().deleteTree(io, root) catch {};
        for (h.turns.items) |turn| gpa.free(turn.path);
        h.turns.deinit(gpa);
    }

    pub fn undo(h: *History, t: *Tools, gpa: std.mem.Allocator) ![]u8 {
        if (h.turns.items.len == 0) return gpa.dupe(u8, "Nothing to undo in this process. Restored sessions cannot undo earlier Turns.");
        const turn = &h.turns.items[h.turns.items.len - 1];
        const path = turn.path;
        if (turn.reason orelse (recordedReason(t, gpa, path) catch .snapshot_unavailable)) |reason| {
            turn.reason = reason;
            return std.fmt.allocPrint(gpa, "Undo refused; no files changed: {s}. This Turn cannot be fully undone; earlier Turns cannot be undone across it.", .{reason.text()});
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const folder = try std.Io.Dir.cwd().openDir(t.io, path, .{ .iterate = true });
        defer folder.close(t.io);
        const Item = struct {
            entry: Entry,
            metadata: []const u8,
            before: ?[]const u8,
            lock: ?std.Io.File = null,

            fn lessThan(_: void, left: @This(), right: @This()) bool {
                return std.mem.lessThan(u8, left.entry.path, right.entry.path);
            }
        };
        var items: std.ArrayList(Item) = .empty;
        defer for (items.items) |item| {
            if (item.lock) |lock| lock.close(t.io);
        };
        var report: std.ArrayList(u8) = .empty;
        errdefer report.deinit(gpa);
        var conflicts: std.ArrayList(u8) = .empty;
        defer conflicts.deinit(gpa);
        var it = folder.iterate();
        while (try it.next(t.io)) |file| {
            if (!std.mem.endsWith(u8, file.name, ".json")) continue;
            const data = try folder.readFileAlloc(t.io, file.name, a, .limited(64 * 1024));
            const entry = try std.json.parseFromSliceLeaky(Entry, a, data, .{});
            if (entry.undone) continue;
            const before = if (entry.created) null else try folder.readFileAlloc(t.io, try std.fmt.allocPrint(a, "{s}.before", .{file.name[0 .. file.name.len - 5]}), a, .limited(file_limit + 1));
            try items.append(a, .{ .entry = entry, .metadata = try std.fs.path.join(a, &.{ path, file.name }), .before = before });
        }
        std.mem.sort(Item, items.items, {}, Item.lessThan);
        for (items.items) |*item| {
            const entry = item.entry;
            item.lock = try file_state.lock(t, a, entry.path);
            const canonical = atomic.canonicalPath(t.io, a, entry.path) catch "";
            const stat = std.Io.Dir.cwd().statFile(t.io, entry.path, .{ .follow_symlinks = false }) catch null;
            const current = if (stat != null and stat.?.kind == .file) std.Io.Dir.cwd().readFileAlloc(t.io, entry.path, gpa, .limited(file_limit + 1)) catch null else null;
            defer if (current) |bytes| gpa.free(bytes);
            const conflict = entry.pending or entry.tainted or !std.mem.eql(u8, canonical, entry.path) or current == null or !std.mem.eql(u8, &entry.hash, &hash(current.?));
            if (conflict) try conflicts.print(gpa, "\nskipped (external change or incomplete snapshot): {s}", .{entry.path});
        }
        if (conflicts.items.len > 0) {
            try report.print(gpa, "Undo refused; no files changed. Resolve conflicts before retrying.{s}", .{conflicts.items});
            return report.toOwnedSlice(gpa);
        }
        try report.appendSlice(gpa, "[undo] Restoring files to their contents before the latest edited Turn. Re-read listed files before continuing.");
        for (items.items) |*item| {
            const entry = &item.entry;
            var restored_stat: ?std.Io.File.Stat = null;
            if (item.before) |before| {
                restored_stat = atomic.replace(t.io, gpa, entry.path, before, .{}) catch |err| {
                    try report.print(gpa, "\nfailed: {s}: {s} (retry /undo)", .{ entry.path, @errorName(err) });
                    return report.toOwnedSlice(gpa);
                };
            } else std.Io.Dir.cwd().deleteFile(t.io, entry.path) catch |err| {
                try report.print(gpa, "\nfailed: {s}: {s} (retry /undo)", .{ entry.path, @errorName(err) });
                return report.toOwnedSlice(gpa);
            };
            entry.undone = true;
            t.bash_commands.changed(t.io);
            try report.print(gpa, "\n{s}: {s}", .{ if (entry.created) "deleted" else "restored", entry.path });
            if (restored_stat) |stat| t.file_state.remember(t.io, gpa, entry.path, stat) catch |err| {
                try report.print(gpa, "\nfile observation failed: {s}; re-read files before continuing", .{@errorName(err)});
                return report.toOwnedSlice(gpa);
            };
            save(t.io, gpa, item.metadata, entry.*) catch |err| {
                try report.print(gpa, "\nundo tracking failed: {s}; inspect files before retrying", .{@errorName(err)});
                return report.toOwnedSlice(gpa);
            };
        }
        _ = h.turns.pop();
        std.Io.Dir.cwd().deleteTree(t.io, path) catch {};
        gpa.free(path);
        return report.toOwnedSlice(gpa);
    }
};

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    tools: Tools,
    history: History,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        const root = try std.fs.path.join(a, &.{ home, "undo" });
        try std.Io.Dir.cwd().createDirPath(testing.io, root);
        return .{ .tmp = tmp, .arena = arena, .tools = .{ .io = testing.io, .home = home, .data_home = home }, .history = .{ .root = root } };
    }

    fn deinit(f: *Fixture) void {
        f.history.deinit(testing.io, testing.allocator);
        f.tools.file_state.deinit(testing.allocator);
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn path(f: *Fixture, name: []const u8) ![]const u8 {
        return atomic.canonicalPath(testing.io, f.arena.allocator(), try std.fs.path.join(f.arena.allocator(), &.{ f.tools.home, name }));
    }

    fn call(f: *Fixture, name: []const u8, args: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(testing.allocator, args, .{});
        defer testing.allocator.free(json);
        const result = Tools.call(&f.tools, testing.allocator, name, json);
        defer @import("../tools.zig").freeResult(result);
        if (result == .err) std.debug.print("{s}\n", .{result.err});
        try testing.expect(result == .ok);
        if (@hasField(@TypeOf(args), "content")) {
            const expected = try std.fmt.allocPrint(testing.allocator, "{{\"bytes\":{d}}}", .{args.content.len});
            defer testing.allocator.free(expected);
            try testing.expectEqualStrings(expected, result.ok);
        }
    }

    fn begin(f: *Fixture) !void {
        try f.history.begin(&f.tools, testing.allocator);
    }

    fn finish(f: *Fixture) void {
        f.history.finish(&f.tools, testing.allocator);
    }

    fn undo(f: *Fixture, expected: []const u8) !void {
        const text = try f.history.undo(&f.tools, testing.allocator);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, expected) != null);
    }

    fn content(f: *Fixture, name: []const u8, expected: []const u8) !void {
        const data = try f.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(file_limit + 1));
        defer testing.allocator.free(data);
        try testing.expectEqualSlices(u8, expected, data);
    }
};

test "undo multiple files, first snapshot, binary Chinese paths, creation and consecutive Turns" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "中文", .data = "\x00\xffold\n" });
    const path = try f.path("中文");
    const created = try f.path("new");
    try f.begin();
    try f.call("edit", .{ .path = path, .old_text = "old", .new_text = "new" });
    try f.call("write", .{ .path = path, .content = "first" });
    try f.call("write", .{ .path = created, .content = "" });
    f.finish();
    try f.begin();
    try f.call("write", .{ .path = path, .content = "second" });
    f.finish();
    try f.begin();
    f.finish();
    try f.undo("restored:");
    try f.content("中文", "first");
    try f.content("new", "");
    try f.undo("deleted:");
    try f.content("中文", "\x00\xffold\n");
    try testing.expectError(error.FileNotFound, f.tmp.dir.statFile(testing.io, "new", .{}));
    try f.undo("Nothing to undo");
}

test "undo rejects whole Turn on external edit, deletion, symlink or in-Turn interference" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "old" });
    const path = try f.path("a");
    const created = try f.path("b");
    try f.begin();
    try f.call("write", .{ .path = path, .content = "new" });
    try f.call("write", .{ .path = created, .content = "created" });
    f.finish();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "external" });
    try f.undo("skipped (external change");
    try f.content("a", "external");
    try f.content("b", "created");
    try f.tmp.dir.deleteFile(testing.io, "a");
    try f.undo("no files changed");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "victim", .data = "new" });
    try f.tmp.dir.symLink(testing.io, "victim", "a", .{});
    try f.undo("no files changed");
    try f.content("victim", "new");
    try f.tmp.dir.deleteFile(testing.io, "a");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "new" });
    try f.undo("restored:");
    try f.begin();
    try f.call("write", .{ .path = path, .content = "first" });
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "external" });
    try f.call("edit", .{ .path = path, .old_text = "external", .new_text = "last" });
    f.finish();
    try f.undo("no files changed");
    try f.content("a", "last");
}

test "undo shares parent snapshots with child tools and evicts only edited Turns" {
    var f = try Fixture.init();
    defer f.deinit();
    const path = try f.path("a");
    try f.begin();
    var child: Tools = .{ .io = testing.io, .home = f.tools.home, .data_home = f.tools.data_home, .undo_dir = f.tools.undo_dir };
    defer child.file_state.deinit(testing.allocator);
    const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .path = path, .content = "child" }, .{});
    defer testing.allocator.free(args);
    const result = Tools.call(&child, testing.allocator, "write", args);
    defer @import("../tools.zig").freeResult(result);
    try testing.expect(result == .ok);
    f.finish();
    try f.undo("deleted:");
    for (0..history_limit + 1) |i| {
        try f.begin();
        try f.call("write", .{ .path = path, .content = try std.fmt.allocPrint(f.arena.allocator(), "{d}", .{i}) });
        f.finish();
    }
    try testing.expectEqual(history_limit, f.history.turns.items.len);
    for (0..history_limit + 2) |_| {
        try f.begin();
        f.finish();
    }
    try testing.expectEqual(history_limit, f.history.turns.items.len);
    for (0..history_limit) |_| try f.undo("restored:");
    try f.content("a", "0");
    try f.undo("Nothing to undo");
}

test "undo file limit allows edits and writes but blocks the whole Turn and earlier history" {
    var f = try Fixture.init();
    defer f.deinit();
    const path = try f.path("a");
    try f.begin();
    try f.call("write", .{ .path = path, .content = "earlier" });
    f.finish();
    try f.begin();
    try f.call("write", .{ .path = try f.path("tracked"), .content = "keep" });
    const large = try testing.allocator.alloc(u8, file_limit + 2);
    defer testing.allocator.free(large);
    @memset(large, 'x');
    try f.call("edit", .{ .path = path, .old_text = "earlier", .new_text = large });
    try f.call("write", .{ .path = path, .content = "written over unreadable snapshot" });
    f.finish();
    try testing.expectEqual(Reason.file_too_large, f.history.notice.?);
    try f.undo("file exceeds undo limit (16 MiB)");
    try f.content("a", "written over unreadable snapshot");
    try f.content("tracked", "keep");
    try f.undo("earlier Turns cannot be undone across it");
    try testing.expectEqual(@as(usize, 2), f.history.turns.items.len);
    try f.begin();
    try f.call("write", .{ .path = path, .content = "newer" });
    f.finish();
    try f.undo("restored:");
    try f.content("a", "written over unreadable snapshot");
    try f.undo("file exceeds undo limit");
}

test "undo byte limit allows writes and refuses partial restoration" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.begin();
    const block = try testing.allocator.alloc(u8, file_limit);
    defer testing.allocator.free(block);
    @memset(block, 'x');
    for (0..4) |i| {
        const name = try std.fmt.allocPrint(f.arena.allocator(), "file{d}", .{i});
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = block });
        try f.call("write", .{ .path = try f.path(name), .content = "small" });
    }
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "overflow", .data = "x" });
    try f.call("write", .{ .path = try f.path("overflow"), .content = "y" });
    f.finish();
    try f.undo("Turn exceeds undo snapshot limit (64 MiB)");
    try f.content("file0", "small");
    try f.content("overflow", "y");
}

test "undo path limit allows all writes and refuses partial deletion" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.begin();
    for (0..300) |i| {
        const name = try std.fmt.allocPrint(f.arena.allocator(), "new{d}", .{i});
        try f.call("write", .{ .path = try f.path(name), .content = "" });
    }
    f.finish();
    try f.undo("Turn exceeds undo path limit (256 files)");
    try f.content("new0", "");
    try f.content("new299", "");
}

test "unavailable snapshot directories never prevent file tools or child writes" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.begin();
    const directory = f.tools.undo_dir.?;
    try std.Io.Dir.cwd().deleteTree(testing.io, directory);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = directory, .data = "not a directory" });
    var child: Tools = .{ .io = testing.io, .home = f.tools.home, .data_home = f.tools.data_home, .undo_dir = directory };
    defer child.file_state.deinit(testing.allocator);
    const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .path = try f.path("child"), .content = "written" }, .{});
    defer testing.allocator.free(args);
    const result = Tools.call(&child, testing.allocator, "write", args);
    defer @import("../tools.zig").freeResult(result);
    try testing.expectEqualStrings("{\"bytes\":7}", result.ok);
    try std.Io.Dir.cwd().deleteFile(testing.io, directory);
    try std.Io.Dir.cwd().createDirPath(testing.io, directory);
    try f.call("edit", .{ .path = try f.path("child"), .old_text = "written", .new_text = "edited" });
    f.finish();
    try f.undo("undo snapshot could not be read or saved");
    try f.content("child", "edited");
}

test "snapshot directory creation failure does not stop a Turn" {
    var f = try Fixture.init();
    defer f.deinit();
    try std.Io.Dir.cwd().deleteTree(testing.io, f.history.root.?);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = f.history.root.?, .data = "not a directory" });
    try f.begin();
    try f.call("write", .{ .path = try f.path("a"), .content = "written" });
    f.finish();
    try f.undo("undo snapshot could not be read or saved");
    try f.content("a", "written");
}

test "snapshot commit failure preserves successful write and blocks child Turn undo" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.begin();
    try f.call("write", .{ .path = try f.path("tracked"), .content = "keep" });
    var child: Tools = .{ .io = testing.io, .home = f.tools.home, .data_home = f.tools.data_home, .undo_dir = f.tools.undo_dir };
    const path = try f.path("a");
    var snapshot = prepare(&child, testing.allocator, path, null, "written").?;
    {
        defer snapshot.deinit(&child, testing.allocator);
        try std.Io.Dir.cwd().deleteFile(testing.io, snapshot.metadata);
        try std.Io.Dir.cwd().createDirPath(testing.io, snapshot.metadata);
        _ = try atomic.replace(testing.io, testing.allocator, path, "written", .{});
        snapshot.commit(&child, testing.allocator, "written");
    }
    f.finish();
    try f.undo("undo snapshot could not be read or saved");
    try f.content("a", "written");
    try f.content("tracked", "keep");
}

test "aborted file replacement preserves the prior undo record" {
    var f = try Fixture.init();
    defer f.deinit();
    const path = try f.path("a");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "old" });
    try f.begin();
    try f.call("write", .{ .path = path, .content = "first" });
    var abandoned = prepare(&f.tools, testing.allocator, path, "first", "unwritten").?;
    abandoned.deinit(&f.tools, testing.allocator);
    const fresh_path = try f.path("unwritten");
    var fresh = prepare(&f.tools, testing.allocator, fresh_path, null, "unwritten").?;
    fresh.deinit(&f.tools, testing.allocator);
    f.finish();
    try f.undo("restored:");
    try f.content("a", "old");
}
