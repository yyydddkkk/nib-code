const std = @import("std");
const sandbox = @import("../sandbox.zig");
const tools = @import("../tools.zig");
const Tools = tools.Tools;
const fail = tools.fail;
const grep_engine = @import("grep.zig");
const walk = @import("walk.zig");

pub fn grep(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const a = std.json.parseFromSlice(grep_engine.Options, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ pattern: string, path?: string, glob?: string, ignore_case?: boolean, literal?: boolean, context?: number, limit?: number }}", .{});
    defer a.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var options = a.value;
    if (t.race_paths) |race| options.path = (try race.mapPath(arena.allocator(), options.path)) orelse options.path;
    var message: [128]u8 = undefined;
    var s = grep_engine.search(t.io, gpa, options, .{ .deny = try t.credentialPaths(arena.allocator()), .cancel = &t.cancel }, &message) catch |err| return switch (err) {
        error.InvalidPattern => blk: {
            const pattern = a.value.pattern;
            var end = @min(pattern.len, 200);
            while (end < pattern.len and end > 0 and pattern[end] & 0xc0 == 0x80) : (end -= 1) {}
            break :blk fail(gpa, "invalid pattern {f}: {s}", .{ std.json.fmt(pattern[0..end], .{}), std.mem.sliceTo(&message, 0) });
        },
        error.Canceled => fail(gpa, "canceled", .{}),
        error.CredentialAccessDenied => err,
        else => fail(gpa, "{s}: {s}", .{ a.value.path, @errorName(err) }),
    };
    defer s.deinit();
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, s.result, .{ .emit_null_optional_fields = false }) };
}

pub fn glob(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const A = struct { pattern: []const u8, path: []const u8 = ".", limit: usize = 1000 };
    const a = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ pattern: string, path?: string, limit?: number }}", .{});
    defer a.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const pattern = if (std.mem.startsWith(u8, a.value.pattern, "./")) a.value.pattern[2..] else a.value.pattern;
    const path = if (t.race_paths) |race| (try race.mapPath(arena.allocator(), a.value.path)) orelse a.value.path else a.value.path;
    const found = walk.files(t.io, arena.allocator(), path, .{
        .deny = try t.credentialPaths(arena.allocator()),
        .cancel = &t.cancel,
        .filter = pattern,
        .max = a.value.limit,
    }) catch |err| return switch (err) {
        error.Canceled => fail(gpa, "canceled", .{}),
        error.CredentialAccessDenied => err,
        else => fail(gpa, "{s}: {s}", .{ a.value.path, @errorName(err) }),
    };
    const shown = found[0..@min(found.len, a.value.limit)];
    const paths = try arena.allocator().alloc([]const u8, shown.len);
    for (shown, paths) |f, *p| p.* = f.path;
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .paths = paths, .truncated = found.len > a.value.limit }, .{}) };
}

const testing = std.testing;
const callTool = tools.callTool;
const freeResult = tools.freeResult;

test "grep and glob never surface credential files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".codex");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".codex/auth.json", .data = "{\"token\":\"fake-secret\"}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.json", .data = "{\"token\":\"public\"}" });
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    const home = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, root, testing.allocator);
    defer testing.allocator.free(home);
    var t: Tools = .{ .io = testing.io, .home = home };

    const grep_args = try std.fmt.allocPrint(testing.allocator, "{{\"pattern\":\"token\",\"path\":\"{s}\"}}", .{root});
    defer testing.allocator.free(grep_args);
    const found = Tools.call(&t, testing.allocator, "grep", grep_args);
    defer freeResult(found);
    try testing.expect(std.mem.indexOf(u8, found.ok, "public") != null);
    try testing.expect(std.mem.indexOf(u8, found.ok, "fake-secret") == null);

    const glob_args = try std.fmt.allocPrint(testing.allocator, "{{\"pattern\":\"*.json\",\"path\":\"{s}\"}}", .{root});
    defer testing.allocator.free(glob_args);
    const listed = Tools.call(&t, testing.allocator, "glob", glob_args);
    defer freeResult(listed);
    try testing.expect(std.mem.indexOf(u8, listed.ok, "notes.json") != null);
    try testing.expect(std.mem.indexOf(u8, listed.ok, "auth.json") == null);

    const direct_args = try std.fmt.allocPrint(testing.allocator, "{{\"pattern\":\"token\",\"path\":\"{s}/.codex/auth.json\"}}", .{root});
    defer testing.allocator.free(direct_args);
    const direct = Tools.call(&t, testing.allocator, "grep", direct_args);
    defer freeResult(direct);
    try testing.expectEqualStrings("CredentialAccessDenied", direct.err);
}

test "grep serializes match byte column and clipped text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: [6014]u8 = @splat('a');
    @memcpy(data[6000..6014], "中SyntaxError");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "long.jsonl", .data = &data });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/long.jsonl", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .pattern = "SyntaxError", .path = path }, .{});
    defer testing.allocator.free(args);
    var t: Tools = .{ .io = testing.io, .home = "/nonexistent" };
    const result = Tools.call(&t, testing.allocator, "grep", args);
    defer freeResult(result);
    const parsed = try std.json.parseFromSlice(grep_engine.Result, testing.allocator, result.ok, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.matches.len);
    const m = parsed.value.matches[0];
    try testing.expectEqual(@as(usize, 6004), m.column);
    try testing.expectEqual(@as(usize, 1), m.line);
    try testing.expect(std.mem.indexOf(u8, result.ok, "text_column") == null);
    try testing.expectEqual(@as(usize, 500), m.text.len);
    try testing.expect(std.unicode.utf8ValidateSlice(m.text));
    try testing.expect(std.mem.endsWith(u8, m.text, "中SyntaxError"));
    try testing.expect(std.mem.startsWith(u8, m.text, "…"));
}

test "grep RegExp literals match strings and map only implicit ignore_case" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "x.reserve(\nX.RESERVE(\nareserve(\n" });
    const code = try std.fmt.allocPrint(testing.allocator,
        \\const path = '.zig-cache/tmp/{s}/f';
        \\const literal = await tools.grep({{pattern: /\.reserve\(/, path}});
        \\const string = await tools.grep({{pattern: '\\.reserve\\(', path}});
        \\const args = {{pattern: /X/i, path}};
        \\const folded = await tools.grep(args);
        \\const explicit = await tools.grep({{pattern: /X/i, ignore_case: false, path}});
        \\const enabled = await tools.grep({{pattern: /x/, ignore_case: true, path}});
        \\const flags = await tools.grep({{pattern: /^x.*$/dgmsuy, path}});
        \\[JSON.stringify(literal) === JSON.stringify(string), literal.matches.length,
        \\ folded.matches.length, explicit.matches.length, enabled.matches.length,
        \\ JSON.stringify(flags) === JSON.stringify(await tools.grep({{pattern: '^x.*$', path}})),
        \\ args.pattern instanceof RegExp, Object.hasOwn(args, 'ignore_case')];
    , .{tmp.sub_path});
    defer testing.allocator.free(code);
    var t: Tools = .{ .io = testing.io, .home = "/nonexistent" };
    const result = try sandbox.eval(testing.allocator, testing.io, code, .{}, t.host(), null);
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expectEqualStrings("[true,1,2,1,2,true,true,false]", result.text);
}

test "grep invalid JS string pattern reports what the host received" {
    var t: Tools = .{ .io = testing.io, .home = "/nonexistent" };
    const result = try sandbox.eval(testing.allocator, testing.io,
        \\await tools.grep({pattern: '\.a\('})
    , .{}, t.host(), null);
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.text, "grep: invalid pattern \".a(\": expecting ')'") != null);
}

test "grep invalid pattern preview is JSON quoted and bounded to 200 UTF-8 bytes" {
    for ([_][]const u8{ "a", "中" }) |unit| {
        const pattern = try testing.allocator.alloc(u8, unit.len * 201 + 1);
        defer testing.allocator.free(pattern);
        for (0..201) |i| @memcpy(pattern[i * unit.len ..][0..unit.len], unit);
        pattern[pattern.len - 1] = '(';
        const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .pattern = pattern }, .{});
        defer testing.allocator.free(args);
        const result = try tools.callTool("grep", args);
        defer freeResult(result);
        const end: usize = if (unit.len == 1) 200 else 198;
        const expected = try std.fmt.allocPrint(testing.allocator, "invalid pattern {f}:", .{std.json.fmt(pattern[0..end], .{})});
        defer testing.allocator.free(expected);
        try testing.expect(std.mem.startsWith(u8, result.err, expected));
        try testing.expect(std.unicode.utf8ValidateSlice(result.err));
    }
    const quoted = try tools.callTool("grep", "{\"pattern\":\"\\\"\\n(\"}");
    defer freeResult(quoted);
    try testing.expect(std.mem.startsWith(u8, quoted.err, "invalid pattern \"\\\"\\n(\":"));
}

test "race grep and glob search branch paths instead of parent paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "parent");
    try tmp.dir.createDirPath(testing.io, "branch");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "parent/parent-only.txt", .data = "parent-only" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "branch/branch-only.txt", .data = "branch-only" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const parent_root = try std.fs.path.join(testing.allocator, &.{ root, "parent" });
    defer testing.allocator.free(parent_root);
    const branch_root = try std.fs.path.join(testing.allocator, &.{ root, "branch" });
    defer testing.allocator.free(branch_root);
    var t: Tools = .{ .io = testing.io, .home = root, .race_paths = .{ .parent_root = parent_root, .worktree_root = branch_root } };
    for ([_][]const u8{ "grep", "glob" }) |name| {
        const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .path = parent_root, .pattern = if (std.mem.eql(u8, name, "grep")) "only" else "*.txt" }, .{});
        defer testing.allocator.free(args);
        const result = Tools.call(&t, testing.allocator, name, args);
        defer freeResult(result);
        try testing.expect(std.mem.indexOf(u8, result.ok, "branch-only") != null);
        try testing.expect(std.mem.indexOf(u8, result.ok, "parent-only") == null);
    }
}
