const std = @import("std");

/// Glob over `/`-separated relative paths: `*` and `?` stay within a segment, a whole `**` segment
/// spans any number of segments, `[a-z]`/`[!a]` classes, `{a,b}` alternatives, `\` escapes.
pub fn match(pattern: []const u8, path: []const u8) bool {
    const open = braceOpen(pattern) orelse return globMatch(pattern, path);
    const close = braceClose(pattern, open) orelse return globMatch(pattern, path);
    var buf: [1024]u8 = undefined;
    var start = open + 1;
    var depth: usize = 0;
    var i = start;
    while (i <= close) : (i += 1) {
        const ch = pattern[i];
        if (ch == '\\') {
            i += 1;
            continue;
        }
        if (ch == '{') depth += 1;
        if (ch == '}' and depth > 0 and i != close) depth -= 1;
        if ((ch == ',' and depth == 0) or i == close) {
            const alt = pattern[start..i];
            const total = open + alt.len + (pattern.len - close - 1);
            if (total > buf.len) return globMatch(pattern, path);
            @memcpy(buf[0..open], pattern[0..open]);
            @memcpy(buf[open..][0..alt.len], alt);
            @memcpy(buf[open + alt.len ..][0 .. pattern.len - close - 1], pattern[close + 1 ..]);
            if (match(buf[0..total], path)) return true;
            start = i + 1;
        }
    }
    return false;
}

/// Patterns without `/` match the last segment at any depth, as in .gitignore.
pub fn matchPath(pattern: []const u8, path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '/') != null) return match(pattern, path);
    return match(pattern, std.fs.path.basename(path));
}

fn braceOpen(p: []const u8) ?usize {
    var i: usize = 0;
    while (i < p.len) : (i += 1) switch (p[i]) {
        '\\' => i += 1,
        '{' => return i,
        else => {},
    };
    return null;
}

fn braceClose(p: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var comma = false;
    var i = open + 1;
    while (i < p.len) : (i += 1) switch (p[i]) {
        '\\' => i += 1,
        '{' => depth += 1,
        ',' => if (depth == 0) {
            comma = true;
        },
        '}' => if (depth == 0) return if (comma) i else null else {
            depth -= 1;
        },
        else => {},
    };
    return null;
}

fn globMatch(p: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    while (pi < p.len) {
        if (isGlobstar(p, pi)) {
            var rest = p[pi + 2 ..];
            if (rest.len > 0) rest = rest[1..];
            if (rest.len == 0) return true;
            var k = si;
            while (k <= s.len) : (k += 1) {
                if ((k == si or s[k - 1] == '/') and globMatch(rest, s[k..])) return true;
            }
            return false;
        }
        switch (p[pi]) {
            '*' => {
                const rest = p[pi + 1 ..];
                var k = si;
                while (true) : (k += 1) {
                    if (globMatch(rest, s[k..])) return true;
                    if (k == s.len or s[k] == '/') return false;
                }
            },
            '?' => {
                if (si == s.len or s[si] == '/') return false;
                pi += 1;
                si += 1;
            },
            '[' => {
                const end = classEnd(p, pi) orelse {
                    if (si == s.len or s[si] != '[') return false;
                    pi += 1;
                    si += 1;
                    continue;
                };
                if (si == s.len or s[si] == '/' or !classMatch(p[pi + 1 .. end], s[si])) return false;
                pi = end + 1;
                si += 1;
            },
            else => {
                const ch = if (p[pi] == '\\' and pi + 1 < p.len) blk: {
                    pi += 1;
                    break :blk p[pi];
                } else p[pi];
                if (si == s.len or s[si] != ch) return false;
                pi += 1;
                si += 1;
            },
        }
    }
    return si == s.len;
}

fn isGlobstar(p: []const u8, i: usize) bool {
    return i + 1 < p.len and p[i] == '*' and p[i + 1] == '*' and
        (i == 0 or p[i - 1] == '/') and (i + 2 == p.len or p[i + 2] == '/');
}

fn classEnd(p: []const u8, open: usize) ?usize {
    var i = open + 1;
    if (i < p.len and (p[i] == '!' or p[i] == '^')) i += 1;
    if (i < p.len and p[i] == ']') i += 1;
    while (i < p.len) : (i += 1) if (p[i] == ']') return i;
    return null;
}

fn classMatch(class: []const u8, ch: u8) bool {
    var body = class;
    const negate = body.len > 0 and (body[0] == '!' or body[0] == '^');
    if (negate) body = body[1..];
    var hit = false;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (i + 2 < body.len and body[i + 1] == '-') {
            if (body[i] <= ch and ch <= body[i + 2]) hit = true;
            i += 2;
        } else if (body[i] == ch) hit = true;
    }
    return hit != negate;
}

const Rule = struct {
    /// Directory of the .gitignore, relative to the walk's top, without trailing `/`.
    base: []const u8,
    pattern: []const u8,
    negate: bool,
    dir_only: bool,
    anchored: bool,
};

fn parseIgnore(a: std.mem.Allocator, base: []const u8, text: []const u8, rules: *std.ArrayList(Rule)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, "\r");
        while (line.len > 0 and line[line.len - 1] == ' ' and !(line.len > 1 and line[line.len - 2] == '\\')) line = line[0 .. line.len - 1];
        if (line.len == 0 or line[0] == '#') continue;
        var rule: Rule = .{ .base = base, .pattern = undefined, .negate = false, .dir_only = false, .anchored = false };
        if (line[0] == '!') {
            rule.negate = true;
            line = line[1..];
        } else if (line[0] == '\\' and line.len > 1 and (line[1] == '#' or line[1] == '!')) line = line[1..];
        if (line.len > 0 and line[line.len - 1] == '/') {
            rule.dir_only = true;
            line = line[0 .. line.len - 1];
        }
        if (std.mem.indexOfScalar(u8, line, '/') != null) rule.anchored = true;
        if (line.len > 0 and line[0] == '/') line = line[1..];
        if (line.len == 0) continue;
        rule.pattern = try a.dupe(u8, line);
        try rules.append(a, rule);
    }
}

fn ignored(rules: []const Rule, rel: []const u8, is_dir: bool) bool {
    var i = rules.len;
    while (i > 0) {
        i -= 1;
        const r = rules[i];
        if (r.dir_only and !is_dir) continue;
        const sub = if (r.base.len == 0) rel else if (rel.len > r.base.len and rel[r.base.len] == '/' and std.mem.startsWith(u8, rel, r.base)) rel[r.base.len + 1 ..] else continue;
        const hit = if (r.anchored) match(r.pattern, sub) else match(r.pattern, std.fs.path.basename(sub));
        if (hit) return !r.negate;
    }
    return false;
}

pub const File = struct {
    /// `root` joined with the path below it, as the caller would pass it to another tool.
    path: []const u8,
    absolute: []const u8,
    dir: bool = false,
};

pub const Options = struct {
    base: ?[]const u8 = null,
    /// Canonical absolute paths that are never listed or entered.
    deny: []const []const u8 = &.{},
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Glob over paths relative to `root`, see `matchPath`.
    filter: ?[]const u8 = null,
    /// Stops after collecting one file more than this.
    max: usize = std.math.maxInt(usize),
    /// Also lists directories, each before its contents; `filter` still applies to files only.
    dirs: bool = false,
};

/// Regular files under `root` in name order, skipping `.git`, symlinks and .gitignore'd entries,
/// including .gitignore files between the enclosing repository's top and `root`.
/// A file `root` is returned as is. Everything is allocated with `a`, meant to be an arena.
pub fn files(io: std.Io, a: std.mem.Allocator, root: []const u8, options: Options) ![]File {
    const cwd = std.Io.Dir.cwd();
    const joined = try @import("../tools.zig").joinRelative(a, options.base, root);
    const absolute_root = try cwd.realPathFileAlloc(io, joined orelse root, a);
    var out: std.ArrayList(File) = .empty;
    const stat = try cwd.statFile(io, absolute_root, .{});
    if (stat.kind != .directory) {
        for (options.deny) |d| if (std.mem.eql(u8, d, absolute_root)) return error.CredentialAccessDenied;
        try out.append(a, .{ .path = root, .absolute = absolute_root });
        return out.items;
    }

    var top: []const u8 = absolute_root;
    var probe: ?[]const u8 = absolute_root;
    while (probe) |dir| : (probe = std.fs.path.dirname(dir)) {
        const marker = try std.fs.path.join(a, &.{ dir, ".git" });
        if (cwd.statFile(io, marker, .{})) |_| {
            top = dir;
            break;
        } else |_| {}
    }
    var rules: std.ArrayList(Rule) = .empty;
    const below = if (absolute_root.len > top.len) absolute_root[top.len + 1 ..] else "";
    var end: usize = 0;
    while (end < below.len) {
        const base = below[0..end];
        const ignore_path = try std.fs.path.join(a, &.{ top, base, ".gitignore" });
        if (cwd.readFileAlloc(io, ignore_path, a, .limited(1 << 20))) |text| try parseIgnore(a, base, text, &rules) else |_| {}
        end = std.mem.indexOfScalarPos(u8, below, end + @intFromBool(end > 0), '/') orelse below.len;
    }

    var dir = try cwd.openDir(io, absolute_root, .{ .iterate = true });
    defer dir.close(io);
    var w: Walk = .{ .io = io, .a = a, .options = options, .rules = &rules, .out = &out, .root = std.mem.trimEnd(u8, root, "/") };
    try w.visit(dir, below, absolute_root, "");
    return out.items;
}

const Walk = struct {
    io: std.Io,
    a: std.mem.Allocator,
    options: Options,
    rules: *std.ArrayList(Rule),
    out: *std.ArrayList(File),
    root: []const u8,

    /// `top_rel` locates `dir` from the walk's top (for ignore rules); `rel` from `root` (for output).
    fn visit(w: *Walk, dir: std.Io.Dir, top_rel: []const u8, absolute: []const u8, rel: []const u8) !void {
        if (w.options.cancel) |c| if (c.load(.acquire)) return error.Canceled;
        const restore = w.rules.items.len;
        defer w.rules.shrinkRetainingCapacity(restore);
        if (dir.readFileAlloc(w.io, ".gitignore", w.a, .limited(1 << 20))) |text| try parseIgnore(w.a, top_rel, text, w.rules) else |_| {}

        var names: std.ArrayList(std.Io.Dir.Entry) = .empty;
        var it = dir.iterate();
        while (try it.next(w.io)) |entry| {
            if (entry.kind != .file and entry.kind != .directory) continue;
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, ".git")) continue;
            try names.append(w.a, .{ .name = try w.a.dupe(u8, entry.name), .kind = entry.kind, .inode = entry.inode });
        }
        std.mem.sortUnstable(std.Io.Dir.Entry, names.items, {}, struct {
            fn lt(_: void, x: std.Io.Dir.Entry, y: std.Io.Dir.Entry) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);

        for (names.items) |entry| {
            if (w.out.items.len > w.options.max) return;
            const is_dir = entry.kind == .directory;
            const entry_top = if (top_rel.len == 0) entry.name else try std.fs.path.join(w.a, &.{ top_rel, entry.name });
            if (ignored(w.rules.items, entry_top, is_dir)) continue;
            const entry_abs = try std.fs.path.join(w.a, &.{ absolute, entry.name });
            if (denied(w.options.deny, entry_abs)) continue;
            const entry_rel = if (rel.len == 0) entry.name else try std.fs.path.join(w.a, &.{ rel, entry.name });
            if (is_dir) {
                if (w.options.dirs) {
                    const path = if (std.mem.eql(u8, w.root, ".")) entry_rel else try std.fs.path.join(w.a, &.{ if (w.root.len == 0) "/" else w.root, entry_rel });
                    try w.out.append(w.a, .{ .path = path, .absolute = entry_abs, .dir = true });
                }
                var sub = dir.openDir(w.io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
                defer sub.close(w.io);
                try w.visit(sub, entry_top, entry_abs, entry_rel);
            } else {
                if (w.options.filter) |f| if (!matchPath(f, entry_rel)) continue;
                const path = if (std.mem.eql(u8, w.root, ".")) entry_rel else try std.fs.path.join(w.a, &.{ if (w.root.len == 0) "/" else w.root, entry_rel });
                try w.out.append(w.a, .{ .path = path, .absolute = entry_abs });
            }
        }
    }
};

fn denied(deny: []const []const u8, path: []const u8) bool {
    for (deny) |d| if (std.mem.eql(u8, d, path)) return true;
    return false;
}

const testing = std.testing;

test "glob segments, globstar, classes and alternatives" {
    try testing.expect(match("*.zig", "main.zig"));
    try testing.expect(!match("*.zig", "src/main.zig"));
    try testing.expect(matchPath("*.zig", "src/main.zig"));
    try testing.expect(match("src/**/*.zig", "src/main.zig"));
    try testing.expect(match("src/**/*.zig", "src/a/b/main.zig"));
    try testing.expect(match("**", "a/b"));
    try testing.expect(match("docs/**", "docs/adr/x.md"));
    try testing.expect(!match("docs/**", "src/x.md"));
    try testing.expect(match("file?.[ch]", "file1.c"));
    try testing.expect(!match("file?.[!ch]", "file1.c"));
    try testing.expect(match("*.{zig,zon}", "build.zig.zon"));
    try testing.expect(match("{src,scripts}/*.{py,zig}", "scripts/mock.py"));
    try testing.expect(!match("{src,scripts}/*.{py,zig}", "docs/a.py"));
    try testing.expect(match("\\*literal", "*literal"));
    try testing.expect(match("a{b", "a{b"));
}

test "gitignore rules: anchoring, directories, negation and nesting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rules: std.ArrayList(Rule) = .empty;
    try parseIgnore(a, "", "# comment\n*.log\n!keep.log\n/build\nzig-out/\ndocs/*.tmp\n\\#hash\n", &rules);
    try parseIgnore(a, "sub", "local.txt\n", &rules);
    try testing.expect(ignored(rules.items, "x/y.log", false));
    try testing.expect(!ignored(rules.items, "x/keep.log", false));
    try testing.expect(ignored(rules.items, "build", true));
    try testing.expect(!ignored(rules.items, "src/build", true));
    try testing.expect(ignored(rules.items, "a/zig-out", true));
    try testing.expect(!ignored(rules.items, "a/zig-out", false));
    try testing.expect(ignored(rules.items, "docs/a.tmp", false));
    try testing.expect(!ignored(rules.items, "docs/sub/a.tmp", false));
    try testing.expect(ignored(rules.items, "#hash", false));
    try testing.expect(ignored(rules.items, "sub/deep/local.txt", false));
    try testing.expect(!ignored(rules.items, "local.txt", false));
}

test "files skips .git, ignored, denied and symlinked entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const d = tmp.dir;
    try d.createDirPath(io, ".git");
    try d.createDirPath(io, "src/gen");
    try d.createDirPath(io, ".github");
    try d.writeFile(io, .{ .sub_path = ".gitignore", .data = "gen/\n*.o\n" });
    try d.writeFile(io, .{ .sub_path = ".git/config", .data = "" });
    try d.writeFile(io, .{ .sub_path = ".github/ci.yml", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/b.zig", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/a.o", .data = "" });
    try d.writeFile(io, .{ .sub_path = "src/gen/x.zig", .data = "" });
    try d.writeFile(io, .{ .sub_path = "secret", .data = "" });
    try d.symLink(io, "src/b.zig", "link.zig", .{});

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, root, a);
    const secret = try std.fs.path.join(a, &.{ absolute, "secret" });

    const all = try files(io, a, root, .{ .deny = &.{secret} });
    var paths: std.ArrayList([]const u8) = .empty;
    for (all) |f| try paths.append(a, f.path[root.len + 1 ..]);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ ".github/ci.yml", ".gitignore", "src/b.zig" }), paths.items);

    const sub = try std.fs.path.join(a, &.{ root, "src" });
    const below = try files(io, a, sub, .{});
    try testing.expectEqual(@as(usize, 1), below.len);
    try testing.expectEqualStrings("b.zig", std.fs.path.basename(below[0].path));
    try testing.expectError(error.CredentialAccessDenied, files(io, a, secret, .{ .deny = &.{secret} }));
}
