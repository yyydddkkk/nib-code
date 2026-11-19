const std = @import("std");

pub const Head = union(enum) { branch: []const u8, detached: []const u8, unknown };

/// Parses the content of a `.git/HEAD` file.
pub fn parseHead(text: []const u8) Head {
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, line, "ref:")) {
        const ref = std.mem.trim(u8, line[4..], " \t");
        const branch = if (std.mem.startsWith(u8, ref, "refs/heads/")) ref["refs/heads/".len..] else ref;
        return if (branch.len == 0) .unknown else .{ .branch = branch };
    }
    if (line.len >= 7 and std.mem.indexOfNone(u8, line, "0123456789abcdef") == null) return .{ .detached = line[0..7] };
    return .unknown;
}

/// Target of a `.git` file (`gitdir: <path>`), relative paths against `root`.
pub fn gitdirOf(a: std.mem.Allocator, root: []const u8, text: []const u8) !?[]u8 {
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, line, "gitdir:")) return null;
    const dir = std.mem.trim(u8, line["gitdir:".len..], " \t");
    if (dir.len == 0) return null;
    if (std.fs.path.isAbsolute(dir)) return try a.dupe(u8, dir);
    return try std.fs.path.join(a, &.{ root, dir });
}

/// Branch name or short SHA of the repository at `root`; null without git or when unreadable.
pub fn readBranch(io: std.Io, a: std.mem.Allocator, root: []const u8) ?[]u8 {
    const dot_git = std.fs.path.join(a, &.{ root, ".git" }) catch return null;
    defer a.free(dot_git);
    const cwd = std.Io.Dir.cwd();
    var gitdir: ?[]u8 = null;
    defer if (gitdir) |d| a.free(d);
    const head_path = blk: {
        const head = std.fs.path.join(a, &.{ dot_git, "HEAD" }) catch return null;
        if (cwd.access(io, head, .{})) |_| break :blk head else |_| a.free(head);
        const pointer = cwd.readFileAlloc(io, dot_git, a, .limited(4096)) catch return null;
        defer a.free(pointer);
        gitdir = (gitdirOf(a, root, pointer) catch return null) orelse return null;
        break :blk std.fs.path.join(a, &.{ gitdir.?, "HEAD" }) catch return null;
    };
    defer a.free(head_path);
    const text = cwd.readFileAlloc(io, head_path, a, .limited(4096)) catch return null;
    defer a.free(text);
    return switch (parseHead(text)) {
        .branch, .detached => |name| a.dupe(u8, name) catch null,
        .unknown => null,
    };
}

/// `<project> · <branch> · <model> · <effort>`; the branch is omitted when null, the
/// effort when the server picks it.
pub fn compose(buf: []u8, project: []const u8, branch: ?[]const u8, model: []const u8, effort: []const u8, fast: bool) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(project) catch return w.buffered();
    if (branch) |b| w.print(" · {s}", .{b}) catch return w.buffered();
    w.print(" · {s}", .{model}) catch return w.buffered();
    if (std.mem.indexOf(u8, effort, "default") == null) w.print(" · {s}", .{effort}) catch return w.buffered();
    if (fast) w.writeAll(" · Fast") catch {};
    return w.buffered();
}

const testing = std.testing;

test "HEAD parsing: branch, nested branch, detached, junk" {
    try testing.expectEqualStrings("main", parseHead("ref: refs/heads/main\n").branch);
    try testing.expectEqualStrings("feat/x", parseHead("ref: refs/heads/feat/x\n").branch);
    try testing.expectEqualStrings("abcdef1", parseHead("abcdef1234567890abcdef1234567890abcdef12\n").detached);
    try testing.expect(parseHead("garbage") == .unknown);
    try testing.expect(parseHead("") == .unknown);
}

test "branch from a plain repository, a worktree gitdir file and no git" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(testing.io, "plain/.git");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.createDirPath(testing.io, "real/wt");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real/wt/HEAD", .data = "ref: refs/heads/feat/wt\n" });
    try tmp.dir.createDirPath(testing.io, "linked");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "linked/.git", .data = "gitdir: ../real/wt\n" });
    try tmp.dir.createDirPath(testing.io, "detached/.git");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "detached/.git/HEAD", .data = "0123456789abcdef0123456789abcdef01234567\n" });
    try tmp.dir.createDirPath(testing.io, "none");
    const root = try std.fmt.allocPrint(a, "{s}/plain", .{base});
    try testing.expectEqualStrings("main", readBranch(testing.io, a, root).?);
    try testing.expectEqualStrings("feat/wt", readBranch(testing.io, a, try std.fmt.allocPrint(a, "{s}/linked", .{base})).?);
    try testing.expectEqualStrings("0123456", readBranch(testing.io, a, try std.fmt.allocPrint(a, "{s}/detached", .{base})).?);
    try testing.expect(readBranch(testing.io, a, try std.fmt.allocPrint(a, "{s}/none", .{base})) == null);
}

test "title composition" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("nibcode · main · deepseek-flash · high", compose(&buf, "nibcode", "main", "deepseek-flash", "high", false));
    try testing.expectEqualStrings("nibcode · deepseek-flash · off", compose(&buf, "nibcode", null, "deepseek-flash", "off", false));
    try testing.expectEqualStrings("nibcode · main · m", compose(&buf, "nibcode", "main", "m", "server default", false));
    try testing.expectEqualStrings("nibcode · main · m", compose(&buf, "nibcode", "main", "m", "on (server default effort)", false));
    try testing.expectEqualStrings("nibcode · main · gpt-6.1-sol · high · Fast", compose(&buf, "nibcode", "main", "gpt-6.1-sol", "high", true));
    try testing.expectEqualStrings("nibcode · gpt-6.1-sol · Fast", compose(&buf, "nibcode", null, "gpt-6.1-sol", "server default", true));
}
