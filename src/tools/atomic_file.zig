const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const windows = @import("builtin").os.tag == .windows;

// Windows inherits the parent directory's ACL; File.Permissions only contains attributes there.
pub const private_file: Io.File.Permissions = if (windows) .default_file else .fromMode(0o600);
pub const private_dir: Io.File.Permissions = if (windows) .default_dir else .fromMode(0o700);

pub const Options = struct {
    /// Creation permissions for a missing target, subject to umask.
    permissions: Io.File.Permissions = .default_file,
    sync: bool = false,
    /// Give an existing target the creation permissions instead of keeping its own.
    force_permissions: bool = false,
};

/// The caller owns the returned path. Missing suffixes are allowed.
pub fn canonicalPath(io: Io, allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return error.FileNotFound;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = Io.Dir.cwd();
    var iter = std.fs.path.componentIterator(path);
    var resolved: []const u8 = if (iter.root()) |root| root else try cwd.realPathFileAlloc(io, ".", a);
    var links: usize = 0;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    while (iter.next()) |component| {
        if (std.mem.eql(u8, component.name, ".")) continue;
        if (std.mem.eql(u8, component.name, "..")) {
            resolved = std.fs.path.dirname(resolved) orelse resolved;
            continue;
        }
        const candidate = try std.fs.path.join(a, &.{ resolved, component.name });
        const len = cwd.readLink(io, candidate, &buffer) catch |err| switch (err) {
            error.NotLink => {
                if (component.path.len < iter.path.len) {
                    const stat = try cwd.statFile(io, candidate, .{});
                    if (stat.kind != .directory) return error.NotDir;
                }
                resolved = candidate;
                continue;
            },
            error.FileNotFound => {
                resolved = candidate;
                continue;
            },
            else => return err,
        };
        links += 1;
        if (links > 40) return error.SymLinkLoop;
        if (len == buffer.len) return error.NameTooLong;
        const pending = try std.fmt.allocPrint(a, "{s}{s}", .{ buffer[0..len], iter.path[component.path.len..] });
        iter = std.fs.path.componentIterator(pending);
        if (iter.root()) |root| resolved = root;
    }
    const last = std.fs.path.basename(iter.path);
    if (iter.path[iter.path.len - 1] == std.fs.path.sep or std.mem.eql(u8, last, ".") or std.mem.eql(u8, last, "..")) {
        const stat = try cwd.statFile(io, resolved, .{});
        if (stat.kind != .directory) return error.NotDir;
    }
    return allocator.dupe(u8, resolved);
}

pub fn replace(io: Io, allocator: Allocator, path: []const u8, data: []const u8, options: Options) !Io.File.Stat {
    const target = try canonicalPath(io, allocator, path);
    defer allocator.free(target);
    const dir = try Io.Dir.cwd().openDir(io, std.fs.path.dirname(target) orelse return error.BadPathName, .{});
    defer dir.close(io);
    const basename = std.fs.path.basename(target);
    const existing: ?Io.File.Stat = dir.statFile(io, basename, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |stat| switch (stat.kind) {
        .file, .directory => {},
        else => return error.NotFile,
    };
    var name_buffer: [64]u8 = undefined;
    var name: []const u8 = undefined;
    const file = file: {
        for (0..16) |_| {
            var random: [16]u8 = undefined;
            io.random(&random);
            name = try std.fmt.bufPrint(&name_buffer, ".nib-{s}", .{std.fmt.bytesToHex(random, .lower)});
            break :file dir.createFile(io, name, .{
                .exclusive = true,
                .permissions = if (existing != null) private_file else options.permissions,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
        }
        return error.PathAlreadyExists;
    };
    var open = true;
    var renamed = false;
    defer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        if (open) file.close(io);
        if (!renamed) dir.deleteFile(io, name) catch {};
    }
    try file.writeStreamingAll(io, data);
    if (existing) |stat| if (!options.force_permissions) try file.setPermissions(io, stat.permissions);
    if (options.force_permissions) try file.setPermissions(io, options.permissions);
    const written = try file.stat(io);
    if (options.sync) try file.sync(io);
    file.close(io);
    open = false;
    try dir.rename(name, dir, basename, io);
    renamed = true;
    return written;
}

fn testPath(allocator: Allocator, tmp: *const std.testing.TmpDir, suffix: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, suffix });
}

fn expectNoTemps(dir: Io.Dir) !void {
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".nib-"));
    }
}

test "replacement preserves existing permissions and uses creation permissions" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const path = try testPath(t.allocator, &tmp, "file");
    defer t.allocator.free(path);
    _ = try replace(t.io, t.allocator, path, "first", .{ .permissions = .fromMode(0o600) });
    try t.expectEqual(@as(std.posix.mode_t, 0o600), (try tmp.dir.statFile(t.io, "file", .{})).permissions.toMode() & 0o7777);
    for ([_]std.posix.mode_t{ 0o751, 0o440, 0o6750 }) |mode| {
        try tmp.dir.setFilePermissions(t.io, "file", .fromMode(mode), .{});
        _ = try replace(t.io, t.allocator, path, "replacement", .{});
        try t.expectEqual(mode, (try tmp.dir.statFile(t.io, "file", .{})).permissions.toMode() & 0o7777);
        const text = try tmp.dir.readFileAlloc(t.io, "file", t.allocator, .unlimited);
        defer t.allocator.free(text);
        try t.expectEqualStrings("replacement", text);
    }
    _ = try replace(t.io, t.allocator, path, "executable", .{ .permissions = .fromMode(0o755), .force_permissions = true, .sync = true });
    try t.expectEqual(@as(std.posix.mode_t, 0o755), (try tmp.dir.statFile(t.io, "file", .{})).permissions.toMode() & 0o7777);
    try expectNoTemps(tmp.dir);
}

test "replacement follows relative absolute and dangling symlinks" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "real", .default_dir);
    try tmp.dir.symLink(t.io, "real", "alias", .{ .is_directory = true });
    try tmp.dir.symLink(t.io, "alias/target", "link", .{});
    const path = try testPath(t.allocator, &tmp, "link");
    defer t.allocator.free(path);
    _ = try replace(t.io, t.allocator, path, "created", .{});
    _ = try replace(t.io, t.allocator, path, "updated", .{ .sync = true });
    try t.expectEqual(Io.File.Kind.sym_link, (try tmp.dir.statFile(t.io, "link", .{ .follow_symlinks = false })).kind);
    const text = try tmp.dir.readFileAlloc(t.io, "real/target", t.allocator, .unlimited);
    defer t.allocator.free(text);
    try t.expectEqualStrings("updated", text);
    const target = try canonicalPath(t.io, t.allocator, path);
    defer t.allocator.free(target);
    try tmp.dir.symLink(t.io, target, "absolute", .{});
    const absolute = try testPath(t.allocator, &tmp, "absolute");
    defer t.allocator.free(absolute);
    _ = try replace(t.io, t.allocator, absolute, "absolute", .{});
    const actual = try canonicalPath(t.io, t.allocator, absolute);
    defer t.allocator.free(actual);
    try t.expectEqualStrings(target, actual);
    try t.expectEqual(Io.File.Kind.sym_link, (try tmp.dir.statFile(t.io, "absolute", .{ .follow_symlinks = false })).kind);
    try expectNoTemps(tmp.dir);
}

test "canonical paths resolve links before dotdot and normalize missing suffixes" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "real/child");
    try tmp.dir.symLink(t.io, "real/child", "alias", .{ .is_directory = true });
    try tmp.dir.symLink(t.io, "alias/../missing/deep", "dangling", .{});
    const paths = [_][]const u8{ "real/missing/deep/file", "alias/../missing/deep/file", "dangling/./file", "real/missing/other/../deep/file" };
    const reference = try testPath(t.allocator, &tmp, paths[0]);
    defer t.allocator.free(reference);
    const expected = try canonicalPath(t.io, t.allocator, reference);
    defer t.allocator.free(expected);
    for (paths) |suffix| {
        const path = try testPath(t.allocator, &tmp, suffix);
        defer t.allocator.free(path);
        const actual = try canonicalPath(t.io, t.allocator, path);
        defer t.allocator.free(actual);
        try t.expectEqualStrings(expected, actual);
    }
    try t.expect(std.fs.path.isAbsolute(expected));
}

test "failed rename cleans temporary file and leaves target intact" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "target", .default_dir);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "target/keep", .data = "original" });
    const path = try testPath(t.allocator, &tmp, "target");
    defer t.allocator.free(path);
    try t.expectError(error.IsDir, replace(t.io, t.allocator, path, "replacement", .{}));
    const text = try tmp.dir.readFileAlloc(t.io, "target/keep", t.allocator, .unlimited);
    defer t.allocator.free(text);
    try t.expectEqualStrings("original", text);
    try expectNoTemps(tmp.dir);
}

test "symlink loops fail without replacing links or leaving temporary files" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.symLink(t.io, "b", "a", .{});
    try tmp.dir.symLink(t.io, "a", "b", .{});
    const path = try testPath(t.allocator, &tmp, "a");
    defer t.allocator.free(path);
    try t.expectError(error.SymLinkLoop, replace(t.io, t.allocator, path, "replacement", .{}));
    try t.expectEqual(Io.File.Kind.sym_link, (try tmp.dir.statFile(t.io, "a", .{ .follow_symlinks = false })).kind);
    try expectNoTemps(tmp.dir);
}

test "canonical paths do not traverse regular files as directories" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "plain", .data = "plain" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "victim", .data = "keep" });
    try tmp.dir.symLink(t.io, "plain", "link", .{});
    try tmp.dir.symLink(t.io, "plain/", "directory-required", .{});
    for ([_][]const u8{ "plain/../victim", "plain/./../victim", "plain/", "link/../victim", "link/", "directory-required" }) |suffix| {
        const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, suffix });
        defer t.allocator.free(path);
        try t.expectError(error.NotDir, replace(t.io, t.allocator, path, "overwrite", .{}));
    }
    const plain = try tmp.dir.readFileAlloc(t.io, "plain", t.allocator, .limited(100));
    defer t.allocator.free(plain);
    const victim = try tmp.dir.readFileAlloc(t.io, "victim", t.allocator, .limited(100));
    defer t.allocator.free(victim);
    try t.expectEqualStrings("plain", plain);
    try t.expectEqualStrings("keep", victim);
    try expectNoTemps(tmp.dir);
}
