const std = @import("std");

pub fn projectRoot(io: std.Io, a: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    var path = cwd;
    while (true) {
        const marker = try std.fs.path.join(a, &.{ path, ".git" });
        std.Io.Dir.cwd().access(io, marker, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                path = std.fs.path.dirname(path) orelse return cwd;
                continue;
            },
            else => return err,
        };
        return path;
    }
}

pub const precedence_notice = "\n\nInstructions below apply in order; later instructions take priority.\n";

pub fn append(io: std.Io, a: std.mem.Allocator, base: []const u8, global: []const u8, project: []const u8) ![]const u8 {
    var prompt: std.ArrayList(u8) = .empty;
    try prompt.appendSlice(a, base);
    try prompt.appendSlice(a, precedence_notice);
    for ([_][]const u8{ global, project }) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try prompt.print(a, "\n--- {s} ---\n{s}\n", .{ path, text });
    }
    return prompt.items;
}

test "AGENTS order and git worktree root" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".git", .data = "gitdir: /elsewhere" });
    try tmp.dir.createDirPath(t.io, "sub/deep");
    const cwd = try std.fs.path.join(a, &.{ root, "sub/deep" });
    try t.expectEqualStrings(root, try projectRoot(t.io, a, cwd));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "global", .data = "GLOBAL" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "AGENTS.md", .data = "PROJECT" });
    const prompt = try append(t.io, a, "BASE", try std.fs.path.join(a, &.{ root, "global" }), try std.fs.path.join(a, &.{ root, "AGENTS.md" }));
    try t.expect(std.mem.indexOf(u8, prompt, "BASE").? < std.mem.indexOf(u8, prompt, "GLOBAL").?);
    try t.expect(std.mem.indexOf(u8, prompt, "GLOBAL").? < std.mem.indexOf(u8, prompt, "PROJECT").?);
}
