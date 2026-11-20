const std = @import("std");
const walk = @import("walk.zig");
const regex = @import("regex.zig");

pub const Options = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    glob: ?[]const u8 = null,
    ignore_case: bool = false,
    literal: bool = false,
    context: usize = 0,
    limit: usize = 100,
};

pub const Match = struct {
    path: []const u8,
    line: usize,
    column: usize,
    text: []const u8,
    before: ?[]const []const u8 = null,
    after: ?[]const []const u8 = null,
};

pub const Result = struct {
    matches: []const Match,
    /// More matches may exist beyond `limit`.
    truncated: bool,
};

const max_line = 500;
const max_file = 16 * 1024 * 1024;
const max_workers = 8;

/// Owns everything in `result`.
pub const Search = struct {
    arena: std.heap.ArenaAllocator,
    result: Result,

    pub fn deinit(s: *Search) void {
        s.arena.deinit();
    }
};

/// `message` receives the reason for error.InvalidPattern.
pub fn search(io: std.Io, gpa: std.mem.Allocator, options: Options, walk_options: walk.Options, message: *[128]u8) !Search {
    var s: Search = .{ .arena = .init(gpa), .result = undefined };
    errdefer s.arena.deinit();
    const a = s.arena.allocator();

    var engine: regex.Engine = undefined;
    try engine.init(walk_options.cancel);
    defer engine.deinit();
    const source = try a.dupeSentinel(u8, if (options.literal) try escape(a, options.pattern) else options.pattern, 0);
    const compiled = try regex.Regex.compile(&engine, source, options.ignore_case, message);
    defer compiled.deinit(&engine);

    var walk_filtered = walk_options;
    walk_filtered.filter = options.glob;
    const files = try walk.files(io, a, options.path, walk_filtered);
    const limit = @max(options.limit, 1);
    var shared: Shared = .{
        .io = io,
        .gpa = gpa,
        .files = files,
        .slots = try a.alloc([]const Match, files.len),
        .regex = compiled,
        .needle = if (options.literal and !options.ignore_case) options.pattern else null,
        .required_literal = requiredLiteral(options),
        .context = options.context,
        .limit = limit,
        .cancel = walk_options.cancel,
    };
    @memset(shared.slots, &.{});

    const workers = @min(max_workers, files.len, std.Thread.getCpuCount() catch 1);
    var threads: [max_workers]?std.Thread = @splat(null);
    var arenas: [max_workers]std.heap.ArenaAllocator = undefined;
    for (arenas[0..@max(workers, 1)]) |*arena| arena.* = .init(gpa);
    defer for (arenas[0..@max(workers, 1)]) |*arena| arena.deinit();
    if (workers <= 1) {
        shared.work(&arenas[0], &engine);
    } else {
        for (threads[0..workers], arenas[0..workers]) |*thread, *arena|
            thread.* = std.Thread.spawn(.{}, Shared.workOwnEngine, .{ &shared, arena }) catch null;
        for (threads[0..workers]) |thread| if (thread) |t| t.join();
    }
    if (shared.failure) |err| return err;

    var matches: std.ArrayList(Match) = .empty;
    const processed = @min(shared.next.load(.acquire), files.len);
    for (shared.slots[0..processed]) |slot| {
        for (slot) |m| {
            if (matches.items.len == limit) break;
            try matches.append(a, try copyMatch(a, m));
        }
    }
    const found = shared.found.load(.acquire);
    s.result = .{ .matches = matches.items, .truncated = found > limit or (found >= limit and processed < files.len) };
    return s;
}

const Shared = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    files: []const walk.File,
    /// Indexed like `files`; each slot is written by the one worker that claimed the file.
    slots: [][]const Match,
    regex: regex.Regex,
    needle: ?[]const u8,
    required_literal: ?[]const u8,
    context: usize,
    limit: usize,
    cancel: ?*const std.atomic.Value(bool),
    next: std.atomic.Value(usize) = .init(0),
    found: std.atomic.Value(usize) = .init(0),
    failure_mutex: std.Io.Mutex = .init,
    failure: ?anyerror = null,

    fn workOwnEngine(s: *Shared, arena: *std.heap.ArenaAllocator) void {
        var engine: regex.Engine = undefined;
        engine.init(s.cancel) catch |err| return s.fail(err);
        defer engine.deinit();
        s.work(arena, &engine);
    }

    /// Files are claimed in index order, so the claimed ones always form a prefix
    /// and the first `limit` matches are the same as in a sequential scan.
    fn work(s: *Shared, arena: *std.heap.ArenaAllocator, engine: *regex.Engine) void {
        const scratch = arena.allocator().alloc(?[*]u8, @max(s.regex.captures * 2, 2)) catch |err| return s.fail(err);
        while (s.found.load(.acquire) < s.limit) {
            if (s.cancel) |c| if (c.load(.acquire)) return s.fail(error.Canceled);
            const i = s.next.fetchAdd(1, .acq_rel);
            if (i >= s.files.len) return;
            const matches = s.scan(arena.allocator(), engine, s.files[i], scratch) catch |err| return s.fail(err);
            s.slots[i] = matches;
            _ = s.found.fetchAdd(matches.len, .acq_rel);
        }
    }

    fn fail(s: *Shared, err: anyerror) void {
        s.failure_mutex.lockUncancelable(s.io);
        defer s.failure_mutex.unlock(s.io);
        if (s.failure == null) s.failure = err;
        s.next.store(s.files.len, .release);
    }

    fn scan(s: *Shared, a: std.mem.Allocator, engine: *regex.Engine, file: walk.File, scratch: []?[*]u8) ![]const Match {
        const data = std.Io.Dir.cwd().readFileAlloc(s.io, file.absolute, s.gpa, .limited(max_file)) catch return &.{};
        defer s.gpa.free(data);
        if (std.mem.indexOfScalar(u8, data[0..@min(data.len, 8192)], 0) != null) return &.{};

        if (s.required_literal) |needle| {
            if (std.mem.indexOf(u8, data, needle) == null) return &.{};
        }

        var lines: std.ArrayList(LineMatch) = .empty;
        defer lines.deinit(s.gpa);
        if (s.needle) |needle| {
            try matchLines(u8, s.gpa, data, s.limit, &lines, Literal{ .needle = needle });
        } else if (isAscii(data) or !std.unicode.utf8ValidateSlice(data)) {
            try matchLines(u8, s.gpa, data, s.limit, &lines, Pattern(u8){ .regex = s.regex, .engine = engine, .scratch = scratch });
        } else {
            const wide = try std.unicode.utf8ToUtf16LeAlloc(s.gpa, data);
            defer s.gpa.free(wide);
            try matchLines(u16, s.gpa, wide, s.limit, &lines, Pattern(u16){ .regex = s.regex, .engine = engine, .scratch = scratch });
        }
        if (lines.items.len == 0) return &.{};

        var starts: std.ArrayList(usize) = .empty;
        defer starts.deinit(s.gpa);
        try starts.append(s.gpa, 0);
        for (data, 0..) |ch, i| if (ch == '\n') try starts.append(s.gpa, i + 1);
        const count = if (data.len > 0 and data[data.len - 1] == '\n') starts.items.len - 1 else starts.items.len;
        const lineText = struct {
            fn get(text: []const u8, st: []const usize, n: usize) []const u8 {
                const start = st[n - 1];
                const end = if (n < st.len) st[n] - 1 else text.len;
                return std.mem.trimEnd(u8, text[start..end], "\r");
            }
        }.get;

        const out = try a.alloc(Match, lines.items.len);
        for (lines.items, out) |hit, *m| {
            const n = hit.line;
            const snippet = try clip(a, lineText(data, starts.items, n), hit.offset);
            m.* = .{ .path = file.path, .line = n, .column = hit.offset + 1, .text = snippet.text };
            if (s.context == 0) continue;
            const first = if (n > s.context) n - s.context else 1;
            const last = @min(n + s.context, count);
            const before = try a.alloc([]const u8, n - first);
            for (before, first..) |*t, k| t.* = (try clip(a, lineText(data, starts.items, k), 0)).text;
            const after = try a.alloc([]const u8, last - n);
            for (after, n + 1..) |*t, k| t.* = (try clip(a, lineText(data, starts.items, k), 0)).text;
            m.before = before;
            m.after = after;
        }
        return out;
    }
};

const Literal = struct {
    needle: []const u8,
    fn find(l: Literal, comptime T: type, text: []const T, from: usize) !?usize {
        return std.mem.indexOfPos(T, text, from, l.needle);
    }
};

fn Pattern(comptime T: type) type {
    return struct {
        regex: regex.Regex,
        engine: *regex.Engine,
        scratch: []?[*]u8,
        fn find(p: @This(), comptime U: type, text: []const U, from: usize) !?usize {
            comptime std.debug.assert(U == T);
            return p.regex.find(p.engine, T, text, from, p.scratch);
        }
    };
}

const LineMatch = struct { line: usize, offset: usize };

fn matchLines(comptime T: type, gpa: std.mem.Allocator, text: []const T, limit: usize, out: *std.ArrayList(LineMatch), finder: anytype) !void {
    var line: usize = 1;
    var counted: usize = 0;
    var from: usize = 0;
    while (out.items.len < limit) {
        const at = (try finder.find(T, text, from)) orelse return;
        line += std.mem.count(T, text[counted..at], &.{'\n'});
        const start = if (std.mem.lastIndexOfScalar(T, text[counted..at], '\n')) |nl| counted + nl + 1 else counted;
        const offset = if (T == u8) at - start else utf16ByteLen(text[start..at]);
        try out.append(gpa, .{ .line = line, .offset = offset });
        const nl = std.mem.indexOfScalarPos(T, text, at, '\n') orelse return;
        line += 1;
        counted = nl + 1;
        from = nl + 1;
        if (from >= text.len) return;
    }
}

fn isAscii(data: []const u8) bool {
    for (data) |ch| if (ch >= 0x80) return false;
    return true;
}

fn utf16ByteLen(text: []const u16) usize {
    var bytes: usize = 0;
    for (text) |unit| {
        const ch = std.mem.littleToNative(u16, unit);
        bytes += switch (ch) {
            0...0x7F => @as(usize, 1),
            0x80...0x7FF => 2,
            // A match on a low surrogate maps to the start of its UTF-8 character.
            0xD800...0xDBFF => 0,
            0xDC00...0xDFFF => 4,
            else => 3,
        };
    }
    return bytes;
}

const Snippet = struct { text: []const u8, start: usize };

fn clip(a: std.mem.Allocator, line: []const u8, at: usize) !Snippet {
    if (line.len <= max_line) return .{ .text = try a.dupe(u8, line), .start = 0 };
    const ellipsis = "…";
    var start = @min(at -| (max_line / 2), line.len - (max_line - ellipsis.len));
    while (start < line.len and (line[start] & 0xC0) == 0x80) start += 1;
    const prefix = if (start > 0) ellipsis else "";
    var end = @min(line.len, start + max_line - prefix.len);
    if (end < line.len) end -= ellipsis.len;
    while (end < line.len and end > start and (line[end] & 0xC0) == 0x80) end -= 1;
    const suffix = if (end < line.len) ellipsis else "";
    return .{ .text = try std.mem.concat(a, u8, &.{ prefix, line[start..end], suffix }), .start = start };
}

fn copyMatch(a: std.mem.Allocator, m: Match) !Match {
    var out = m;
    out.text = try a.dupe(u8, m.text);
    if (m.before) |lines| out.before = try copyLines(a, lines);
    if (m.after) |lines| out.after = try copyLines(a, lines);
    return out;
}

fn copyLines(a: std.mem.Allocator, lines: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, lines.len);
    for (lines, out) |l, *o| o.* = try a.dupe(u8, l);
    return out;
}

fn escape(a: std.mem.Allocator, literal: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (literal) |ch| {
        if (std.mem.indexOfScalar(u8, "\\^$.*+?()[]{}|/", ch) != null) try out.append(a, '\\');
        try out.append(a, ch);
    }
    return out.items;
}

// shortcut: only whole-word ASCII literals and anchored ASCII prefixes, use a regex parser for broader extraction.
fn requiredLiteral(options: Options) ?[]const u8 {
    if (options.literal or options.ignore_case) return null;
    const pattern = options.pattern;

    if (pattern.len >= 7 and std.mem.startsWith(u8, pattern, "\\b") and
        std.mem.endsWith(u8, pattern, "\\b"))
    {
        const word = pattern[2 .. pattern.len - 2];
        for (word) |byte| if (!asciiWord(byte)) return null;
        return word;
    }

    if (pattern.len < 4 or pattern[0] != '^') return null;
    if (std.mem.indexOfScalar(u8, pattern, '|') != null) return null;
    var end: usize = 1;
    while (end < pattern.len and (asciiWord(pattern[end]) or pattern[end] == ' ')) : (end += 1) {}
    if (end < 4) return null;
    if (end < pattern.len and std.mem.indexOfScalar(u8, ".[(\\$", pattern[end]) == null) return null;
    return pattern[1..end];
}

fn asciiWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

const testing = std.testing;

fn fixture(tmp: *testing.TmpDir) !void {
    const io = testing.io;
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "out/\n" });
    try tmp.dir.createDirPath(io, "out");
    try tmp.dir.writeFile(io, .{ .sub_path = "out/gen.zig", .data = "fn hidden() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "const a = 1;\nfn alpha() void {}\r\n// 注释 TODO 中文\nfn beta() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/b.py", .data = "def alpha():\n    pass\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bin.dat", .data = "fn \x00 binary\n" });
}

fn run(root: []const u8, options: Options) !Search {
    var message: [128]u8 = undefined;
    var o = options;
    o.path = root;
    return search(testing.io, testing.allocator, o, .{}, &message);
}

test "grep finds regex matches in path order, skipping ignored and binary files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(&tmp);
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);

    var s = try run(root, .{ .pattern = "^(fn|def) \\w+" });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.result.matches.len);
    try testing.expect(std.mem.endsWith(u8, s.result.matches[0].path, "src/a.zig"));
    try testing.expectEqual(@as(usize, 2), s.result.matches[0].line);
    try testing.expectEqualStrings("fn alpha() void {}", s.result.matches[0].text);
    try testing.expectEqual(@as(usize, 4), s.result.matches[1].line);
    try testing.expect(std.mem.endsWith(u8, s.result.matches[2].path, "src/b.py"));
    try testing.expect(!s.result.truncated);

    var limited = try run(root, .{ .pattern = "alpha", .limit = 1, .glob = "*.zig" });
    defer limited.deinit();
    try testing.expectEqual(@as(usize, 1), limited.result.matches.len);
    try testing.expect(!limited.result.truncated);

    var capped = try run(root, .{ .pattern = "alpha", .limit = 1 });
    defer capped.deinit();
    try testing.expect(capped.result.truncated);
}

test "grep prefilters only required case-sensitive literals" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "text",
        .data = "中文\npub fn findThing(\nSessionState\nSession\nSESSION\nbeta\nalph\n",
    });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/text", .{tmp.sub_path});
    defer testing.allocator.free(path);

    const cases: []const struct { options: Options, required: ?[]const u8, lines: []const usize } = &.{
        .{ .options = .{ .pattern = "^pub fn find[A-Za-z_]*\\(" }, .required = "pub fn find", .lines = &.{2} },
        .{ .options = .{ .pattern = "\\bSession\\b" }, .required = "Session", .lines = &.{4} },
        .{ .options = .{ .pattern = "\\bMissing\\b" }, .required = "Missing", .lines = &.{} },
        .{ .options = .{ .pattern = "\\bsession\\b", .ignore_case = true }, .required = null, .lines = &.{ 4, 5 } },
        .{ .options = .{ .pattern = "^alpha|beta" }, .required = null, .lines = &.{6} },
        .{ .options = .{ .pattern = "^alpha?" }, .required = null, .lines = &.{7} },
        .{ .options = .{ .pattern = "^alpha{0,2}" }, .required = null, .lines = &.{7} },
    };
    for (cases) |case| {
        try testing.expectEqualDeep(case.required, requiredLiteral(case.options));
        var result = try run(path, case.options);
        defer result.deinit();
        try testing.expectEqual(case.lines.len, result.result.matches.len);
        for (case.lines, result.result.matches) |expected, hit| try testing.expectEqual(expected, hit.line);
    }
}

test "grep handles UTF-8, literals, case and context" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(&tmp);
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/src/a.zig", .{tmp.sub_path});
    defer testing.allocator.free(root);

    var zh = try run(root, .{ .pattern = "注释.*中文", .context = 1 });
    defer zh.deinit();
    try testing.expectEqual(@as(usize, 1), zh.result.matches.len);
    try testing.expectEqual(@as(usize, 3), zh.result.matches[0].line);
    try testing.expectEqualDeep(@as([]const []const u8, &.{"fn alpha() void {}"}), zh.result.matches[0].before.?);
    try testing.expectEqualDeep(@as([]const []const u8, &.{"fn beta() void {}"}), zh.result.matches[0].after.?);

    var literal = try run(root, .{ .pattern = "alpha()", .literal = true });
    defer literal.deinit();
    try testing.expectEqual(@as(usize, 1), literal.result.matches.len);

    var folded = try run(root, .{ .pattern = "TODO", .literal = true, .ignore_case = true });
    defer folded.deinit();
    try testing.expectEqual(@as(usize, 1), folded.result.matches.len);
    var lower = try run(root, .{ .pattern = "todo" });
    defer lower.deinit();
    try testing.expectEqual(@as(usize, 0), lower.result.matches.len);

    try testing.expectError(error.InvalidPattern, run(root, .{ .pattern = "(" }));
}

fn repeat(comptime text: []const u8, comptime count: usize) [text.len * count]u8 {
    @setEvalBranchQuota(20000);
    var out: [text.len * count]u8 = undefined;
    for (0..count) |i| @memcpy(out[i * text.len ..][0..text.len], text);
    return out;
}

fn expectSnippet(line: []const u8, snippet: Snippet) !void {
    const prefix: usize = if (snippet.start > 0) "…".len else 0;
    const suffix: usize = if (std.mem.endsWith(u8, snippet.text, "…")) "…".len else 0;
    try testing.expect(snippet.text.len <= max_line);
    try testing.expect(std.unicode.utf8ValidateSlice(snippet.text));
    if (prefix > 0) try testing.expect(std.mem.startsWith(u8, snippet.text, "…"));
    const body = snippet.text[prefix .. snippet.text.len - suffix];
    try testing.expectEqualStrings(line[snippet.start..][0..body.len], body);
    try testing.expectEqual(suffix > 0, snippet.start + body.len < line.len);
}

test "grep centers long JSONL snippets on the first match in byte columns" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/session.jsonl", .{tmp.sub_path});
    defer testing.allocator.free(root);

    const prefixes = [_][]const u8{
        "{\"text\":\"" ++ repeat("a", 6000),
        "{\"text\":\"" ++ repeat("中文😀", 600),
    };
    for (prefixes) |prefix| {
        const line = try std.mem.concat(testing.allocator, u8, &.{ prefix, "SyntaxError then SyntaxError", &repeat("末尾", 10), "\"}" });
        defer testing.allocator.free(line);
        const data = try std.mem.concat(testing.allocator, u8, &.{ "前文\r\n", line, "\r\n后文\n" });
        defer testing.allocator.free(data);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "session.jsonl", .data = data });

        for ([_]Options{
            .{ .pattern = "Syntax[E]rror", .context = 1 },
            .{ .pattern = "SyntaxError", .literal = true, .context = 1 },
            .{ .pattern = "syntaxerror", .literal = true, .ignore_case = true, .context = 1 },
        }) |options| {
            var s = try run(root, options);
            defer s.deinit();
            try testing.expectEqual(@as(usize, 1), s.result.matches.len);
            const m = s.result.matches[0];
            try testing.expectEqual(@as(usize, 2), m.line);
            try testing.expectEqual(prefix.len + 1, m.column);
            try testing.expect(std.mem.indexOf(u8, m.text, "SyntaxError") != null);
            try testing.expect(m.text.len <= max_line);
            try testing.expect(std.unicode.utf8ValidateSlice(m.text));
            try testing.expect(std.mem.startsWith(u8, m.text, "…"));
            try testing.expectEqualStrings("前文", m.before.?[0]);
            try testing.expectEqualStrings("后文", m.after.?[0]);
            try testing.expect(!s.result.truncated);
        }
    }
}

test "grep reports byte columns for short, empty, zero-width and surrogate matches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/text", .{tmp.sub_path});
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "text", .data = "前行\n😀中文SyntaxError SyntaxError\r\n\nSyntaxError" });

    for ([_]Options{ .{ .pattern = "SyntaxError" }, .{ .pattern = "SyntaxError", .literal = true } }) |options| {
        var s = try run(root, options);
        defer s.deinit();
        try testing.expectEqual(@as(usize, 2), s.result.matches.len);
        try testing.expectEqual(@as(usize, 2), s.result.matches[0].line);
        try testing.expectEqual(@as(usize, 11), s.result.matches[0].column);
        try testing.expectEqualStrings("😀中文SyntaxError SyntaxError", s.result.matches[0].text);
        try testing.expectEqual(@as(usize, 4), s.result.matches[1].line);
        try testing.expectEqual(@as(usize, 1), s.result.matches[1].column);
    }

    var low = try run(root, .{ .pattern = "\\uDE00" });
    defer low.deinit();
    try testing.expectEqual(@as(usize, 1), low.result.matches.len);
    try testing.expectEqual(@as(usize, 1), low.result.matches[0].column);

    var empty = try run(root, .{ .pattern = "(?<=\n)^$" });
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 1), empty.result.matches.len);
    try testing.expectEqual(@as(usize, 3), empty.result.matches[0].line);
    try testing.expectEqual(@as(usize, 1), empty.result.matches[0].column);
    try testing.expectEqualStrings("", empty.result.matches[0].text);

    var end = try run(root, .{ .pattern = "(?<=^SyntaxError)$" });
    defer end.deinit();
    try testing.expectEqual(@as(usize, 1), end.result.matches.len);
    try testing.expectEqual(@as(usize, 4), end.result.matches[0].line);
    try testing.expectEqual(@as(usize, 12), end.result.matches[0].column);
}

test "grep clips at UTF-8 boundaries within 500 bytes including omission markers" {
    for ([_][]const u8{ &repeat("a", 500), &repeat("a", 501), &repeat("a", 2000), &repeat("é中😀", 300) }) |line| {
        for (0..line.len + 1) |at| {
            const snippet = try clip(testing.allocator, line, at);
            defer testing.allocator.free(snippet.text);
            try expectSnippet(line, snippet);
            try testing.expect(snippet.start <= at);
            const prefix: usize = if (snippet.start > 0) "…".len else 0;
            const suffix: usize = if (std.mem.endsWith(u8, snippet.text, "…")) "…".len else 0;
            const end = snippet.start + snippet.text.len - prefix - suffix;
            if (at < line.len) try testing.expect(at < end);
            if (line.len <= max_line) {
                try testing.expectEqual(@as(usize, 0), snippet.start);
                try testing.expectEqualStrings(line, snippet.text);
            }
        }
    }
    const line = "SyntaxError" ++ repeat("a", 6000);
    const snippet = try clip(testing.allocator, line, 0);
    defer testing.allocator.free(snippet.text);
    try testing.expectEqual(@as(usize, 0), snippet.start);
    try testing.expectEqualStrings(line[0..497] ++ "…", snippet.text);
}

test "grep keeps final multibyte matches when the tail window needs UTF-8 alignment" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/text", .{tmp.sub_path});
    defer testing.allocator.free(root);

    for ([_][]const u8{ &repeat("中", 199), &repeat("😀", 200), &repeat("é", 300) }) |prefix| {
        const line = try std.mem.concat(testing.allocator, u8, &.{ prefix, "末" });
        defer testing.allocator.free(line);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "text", .data = line });
        for ([_]bool{ false, true }) |literal| {
            var s = try run(root, .{ .pattern = "末", .literal = literal });
            defer s.deinit();
            try testing.expectEqual(@as(usize, 1), s.result.matches.len);
            const m = s.result.matches[0];
            try testing.expectEqual(prefix.len + 1, m.column);
            try testing.expect(std.mem.endsWith(u8, m.text, "末"));
            try testing.expect(m.text.len <= max_line);
            try testing.expect(std.unicode.utf8ValidateSlice(m.text));
            try testing.expect(std.mem.startsWith(u8, m.text, "…"));
        }
    }
}
