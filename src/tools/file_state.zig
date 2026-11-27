const std = @import("std");
const Tools = @import("../tools.zig").Tools;

pub const Observation = struct {
    path: []const u8,
    version: State.Version,
};

pub fn freeVersions(gpa: std.mem.Allocator, versions: []const Observation) void {
    for (versions) |entry| gpa.free(entry.path);
    gpa.free(versions);
}

pub const State = struct {
    mutex: std.Io.Mutex = .init,
    seen: std.StringHashMapUnmanaged(Version) = .empty,

    pub const Version = struct {
        inode: std.Io.File.INode,
        size: u64,
        mtime: i96,

        pub fn from(stat: std.Io.File.Stat) Version {
            return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds };
        }
    };

    pub fn remember(s: *State, io: std.Io, gpa: std.mem.Allocator, path: []const u8, stat: std.Io.File.Stat) !void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        try s.putVersion(gpa, path, .from(stat));
    }

    fn putVersion(s: *State, gpa: std.mem.Allocator, path: []const u8, version: Version) !void {
        const entry = try s.seen.getOrPut(gpa, path);
        if (!entry.found_existing) {
            errdefer _ = s.seen.remove(path);
            entry.key_ptr.* = try gpa.dupe(u8, path);
        }
        entry.value_ptr.* = version;
    }

    // Paths are already canonical observation keys; do not resolve or stat them again.
    pub fn exportVersions(s: *State, io: std.Io, gpa: std.mem.Allocator) ![]const Observation {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const versions = try gpa.alloc(Observation, s.seen.count());
        var copied: usize = 0;
        errdefer {
            for (versions[0..copied]) |entry| gpa.free(entry.path);
            gpa.free(versions);
        }
        var it = s.seen.iterator();
        while (it.next()) |entry| {
            versions[copied] = .{ .path = try gpa.dupe(u8, entry.key_ptr.*), .version = entry.value_ptr.* };
            copied += 1;
        }
        return versions;
    }

    pub fn importVersions(s: *State, io: std.Io, gpa: std.mem.Allocator, versions: []const Observation) !void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        for (versions) |entry| try s.putVersion(gpa, entry.path, entry.version);
    }

    pub fn changed(s: *State, io: std.Io, path: []const u8, stat: std.Io.File.Stat) bool {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const before = s.seen.get(path) orelse return false;
        return !std.meta.eql(before, Version.from(stat));
    }

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        var keys = s.seen.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        s.seen.deinit(gpa);
        s.seen = .empty;
    }
};

pub fn lock(t: *Tools, gpa: std.mem.Allocator, path: []const u8) !std.Io.File {
    if (t.cancelFlag().load(.acquire)) return error.Canceled;
    const home = if (t.data_home) |home| try gpa.dupe(u8, home) else if (t.environ) |env| try @import("../config.zig").home(gpa, env) else try std.fs.path.join(gpa, &.{ t.home, ".nib" });
    defer gpa.free(home);
    const directory = try std.fs.path.join(gpa, &.{ home, "locks" });
    defer gpa.free(directory);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(t.io, directory);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &hash, .{});
    const name = std.fmt.bytesToHex(hash, .lower);
    const lock_path = try std.fs.path.join(gpa, &.{ directory, &name });
    defer gpa.free(lock_path);
    const file = try cwd.createFile(t.io, lock_path, .{ .truncate = false, .permissions = @import("atomic_file.zig").private_file });
    errdefer file.close(t.io);
    while (true) {
        if (t.cancelFlag().load(.acquire)) return error.Canceled;
        if (try file.tryLock(t.io, .exclusive)) break;
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(20), .clock = .awake }, t.io);
    }
    if (t.cancelFlag().load(.acquire)) return error.Canceled;
    // Lock files must stay linked: unlinking lets waiters lock different inodes.
    return file;
}

fn testStat(version: State.Version) std.Io.File.Stat {
    var stat: std.Io.File.Stat = std.mem.zeroes(std.Io.File.Stat);
    stat.inode = version.inode;
    stat.size = version.size;
    stat.mtime.nanoseconds = version.mtime;
    return stat;
}

test "empty file versions export and import" {
    const t = std.testing;
    var state: State = .{};
    defer state.deinit(t.allocator);
    const versions = try state.exportVersions(t.io, t.allocator);
    defer freeVersions(t.allocator, versions);
    try t.expectEqual(@as(usize, 0), versions.len);
    try state.importVersions(t.io, t.allocator, versions);
    try t.expectEqual(@as(u32, 0), state.seen.count());
}

test "file version snapshot and imported keys outlive their sources" {
    const t = std.testing;
    const path = "/observed/file";
    const original = testStat(.{ .inode = 7, .size = 11, .mtime = 9007199254740993 });
    var latest = original;
    latest.size += 1;
    var child: State = .{};
    defer child.deinit(t.allocator);
    var sibling: State = .{};
    defer sibling.deinit(t.allocator);
    {
        var parent: State = .{};
        defer parent.deinit(t.allocator);
        try parent.remember(t.io, t.allocator, path, original);
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const versions = try parent.exportVersions(t.io, arena.allocator());
        try parent.remember(t.io, t.allocator, path, latest);
        try parent.remember(t.io, t.allocator, "/observed/later", latest);
        try t.expectEqual(@as(usize, 1), versions.len);
        try t.expectEqualStrings(path, versions[0].path);
        try t.expectEqualDeep(State.Version.from(original), versions[0].version);
        try child.importVersions(t.io, t.allocator, versions);
        try sibling.importVersions(t.io, t.allocator, versions);
        var keys = child.seen.keyIterator();
        try t.expect(keys.next().?.ptr != versions[0].path.ptr);
    }
    try t.expect(!child.changed(t.io, path, original));
    try t.expect(child.changed(t.io, path, latest));
    try t.expect(!child.changed(t.io, "/observed/later", latest));
    var changed_inode = original;
    changed_inode.inode += 1;
    try t.expect(child.changed(t.io, path, changed_inode));
    var changed_mtime = original;
    changed_mtime.mtime.nanoseconds += 1;
    try t.expect(child.changed(t.io, path, changed_mtime));
    try child.remember(t.io, t.allocator, path, latest);
    try t.expect(!child.changed(t.io, path, latest));
    try t.expect(sibling.changed(t.io, path, latest));
}

test "file version export retains canonical alias observations after deletion" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "sub", .default_dir);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "f", .data = "old" });
    try tmp.dir.symLink(t.io, "f", "alias", .{});
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const alias = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/sub/../alias", .{tmp.sub_path});
    const target = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/f", .{tmp.sub_path});
    const canonical = try @import("../tools.zig").normalizedPath(t.io, a, alias);
    try t.expectEqualStrings(canonical, try @import("../tools.zig").normalizedPath(t.io, a, target));
    const original = try tmp.dir.statFile(t.io, "f", .{});
    var parent: State = .{};
    defer parent.deinit(t.allocator);
    try parent.remember(t.io, t.allocator, canonical, original);
    try tmp.dir.deleteFile(t.io, "f");
    const versions = try parent.exportVersions(t.io, t.allocator);
    defer freeVersions(t.allocator, versions);
    try t.expectEqual(@as(usize, 1), versions.len);
    try t.expectEqualStrings(canonical, versions[0].path);
    var child: State = .{};
    defer child.deinit(t.allocator);
    try child.importVersions(t.io, t.allocator, versions);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "f", .data = "replacement is longer" });
    const recreated = try tmp.dir.statFile(t.io, "f", .{});
    try t.expect(child.changed(t.io, try @import("../tools.zig").normalizedPath(t.io, a, alias), recreated));
    try t.expect(child.changed(t.io, try @import("../tools.zig").normalizedPath(t.io, a, target), recreated));
    try child.remember(t.io, t.allocator, canonical, recreated);
    try t.expect(!child.changed(t.io, canonical, recreated));
}

test "file version export is consistent with concurrent observations" {
    const t = std.testing;
    var parent: State = .{};
    defer parent.deinit(t.allocator);
    const path = "/observed/file";
    try parent.remember(t.io, t.allocator, path, testStat(.{ .inode = 0, .size = 0, .mtime = 0 }));
    const Writer = struct {
        fn run(state: *State) void {
            for (1..1001) |n| {
                state.remember(std.testing.io, std.testing.allocator, path, testStat(.{ .inode = @intCast(n), .size = n, .mtime = n })) catch @panic("remember failed");
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Writer.run, .{&parent});
    defer thread.join();
    for (0..100) |_| {
        const versions = try parent.exportVersions(t.io, t.allocator);
        defer freeVersions(t.allocator, versions);
        try t.expectEqual(@as(usize, 1), versions.len);
        try t.expectEqualStrings(path, versions[0].path);
        try t.expectEqual(versions[0].version.inode, versions[0].version.size);
        try t.expectEqual(@as(i96, @intCast(versions[0].version.inode)), versions[0].version.mtime);
    }
}

test "file version import and export clean up allocation failures" {
    const t = std.testing;
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var parent: State = .{};
            defer parent.deinit(gpa);
            const versions = [_]Observation{
                .{ .path = "/observed/one", .version = .{ .inode = 1, .size = 2, .mtime = 3 } },
                .{ .path = "/observed/two", .version = .{ .inode = 4, .size = 5, .mtime = 6 } },
            };
            try parent.importVersions(std.testing.io, gpa, &versions);
            const snapshot = try parent.exportVersions(std.testing.io, gpa);
            defer freeVersions(gpa, snapshot);
            var child: State = .{};
            defer child.deinit(gpa);
            try child.importVersions(std.testing.io, gpa, snapshot);
            try std.testing.expect(!child.changed(std.testing.io, versions[0].path, testStat(versions[0].version)));
            try std.testing.expect(!child.changed(std.testing.io, versions[1].path, testStat(versions[1].version)));
        }
    };
    try t.checkAllAllocationFailures(t.allocator, Check.run, .{});
}
