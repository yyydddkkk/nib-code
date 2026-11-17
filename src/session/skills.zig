const std = @import("std");
const trim = std.mem.trim;
pub const Skill = struct { name: []const u8, description: []const u8, location: []const u8, disabled: bool = false, plugin_root: ?[]const u8 = null, command: bool = false };

pub fn copy(a: std.mem.Allocator, entries: []const Skill) ![]Skill {
    const out = try a.alloc(Skill, entries.len);
    for (entries, out) |skill, *item| {
        item.* = skill;
        item.name = try a.dupe(u8, skill.name);
        item.description = try a.dupe(u8, skill.description);
        item.location = try a.dupe(u8, skill.location);
        if (skill.plugin_root) |root| item.plugin_root = try a.dupe(u8, root);
    }
    return out;
}

pub fn commandSkill(text: []const u8, found: []const Skill) ?Skill {
    if (text.len < 2 or text[0] != '/') return null;
    const end = std.mem.indexOfAny(u8, text, " \t\n") orelse text.len;
    for (found) |skill| if (skill.plugin_root != null and std.mem.eql(u8, skill.name, text[1..end])) return skill;
    return null;
}
pub const Diagnostic = struct { path: []const u8, reason: []const u8 };
pub const Summary = struct { count: usize = 0, found: usize = 0, missing: usize = 0, skipped: []const Diagnostic = &.{} };
pub const Result = struct { skills: []Skill, summary: Summary };

fn scalar(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const s = trim(u8, raw, " \t\r");
    if (s.len == 0) return s;
    if (s[0] == '"') {
        const parsed = std.json.parseFromSlice([]const u8, a, s[0 .. quotedEnd(s) orelse return error.InvalidScalar], .{ .allocate = .alloc_always }) catch return error.InvalidScalar;
        return parsed.value;
    }
    if (s[0] == '\'') {
        const end = quotedEnd(s) orelse return error.InvalidScalar;
        return std.mem.replaceOwned(u8, a, s[1 .. end - 1], "''", "'");
    }
    const end = std.mem.indexOf(u8, s, " #") orelse s.len;
    return trim(u8, s[0..end], " \t\r");
}

fn quotedEnd(s: []const u8) ?usize {
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[0] == '"' and s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] != s[0]) continue;
        if (s[0] == '\'' and i + 1 < s.len and s[i + 1] == '\'') {
            i += 1;
            continue;
        }
        const tail = trim(u8, s[i + 1 ..], " \t");
        if (tail.len == 0 or tail[0] == '#') return i + 1;
        return null;
    }
    return null;
}

pub fn parse(a: std.mem.Allocator, text: []const u8, fallback: []const u8, path: []const u8) !Skill {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, trim(u8, lines.next() orelse "", "\r"), "---")) return error.MissingFrontmatter;
    var skill: Skill = .{ .name = fallback, .description = "", .location = path };
    var closed = false;
    while (lines.next()) |raw| {
        const line = trim(u8, raw, "\r");
        if (std.mem.eql(u8, line, "---")) {
            closed = true;
            break;
        }
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const value = trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "description")) {
            if (value.len > 0 and (value[0] == '|' or value[0] == '>')) {
                var block: std.ArrayList(u8) = .empty;
                var indent: ?usize = null;
                while (true) {
                    const saved = lines;
                    const next = lines.next() orelse break;
                    const content = trim(u8, next, " \t\r");
                    const spaces = next.len - std.mem.trimStart(u8, next, " ").len;
                    if (content.len > 0 and (spaces == 0 or (indent != null and spaces < indent.?))) {
                        lines = saved;
                        break;
                    }
                    if (content.len > 0 and indent == null) indent = spaces;
                    if (block.items.len > 0) try block.append(a, if (value[0] == '>') ' ' else '\n');
                    try block.appendSlice(a, if (content.len == 0) "" else std.mem.trimEnd(u8, next[indent.?..], "\r"));
                }
                skill.description = trim(u8, block.items, " \t\r\n");
            } else skill.description = try scalar(a, value);
        } else if (std.mem.eql(u8, key, "name")) {
            const name = try scalar(a, value);
            if (name.len > 0) skill.name = name;
        } else if (std.mem.eql(u8, key, "disable-model-invocation")) {
            skill.disabled = std.mem.eql(u8, try scalar(a, value), "true");
        }
    }
    if (!closed) return error.MissingFrontmatter;
    if (trim(u8, skill.description, " \t\r\n").len == 0) return error.MissingDescription;
    var end: usize = 0;
    var chars: usize = 0;
    while (end < skill.description.len and chars < 1024) : (chars += 1) {
        const n = std.unicode.utf8ByteSequenceLength(skill.description[end]) catch return error.InvalidUtf8;
        end += n;
        if (end > skill.description.len) return error.InvalidUtf8;
    }
    skill.description = skill.description[0..end];
    return skill;
}

pub fn discover(io: std.Io, a: std.mem.Allocator, roots: []const []const u8) !Result {
    var map: std.StringHashMap(Skill) = .init(a);
    var skipped: std.ArrayList(Diagnostic) = .empty;
    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
            if (err != error.FileNotFound) try skipped.append(a, .{ .path = root, .reason = @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.name[0] == '.' or (entry.kind != .directory and entry.kind != .sym_link)) continue;
            var child = dir.openDir(io, entry.name, .{}) catch continue;
            defer child.close(io);
            const path = try std.fs.path.resolve(a, &.{ root, entry.name, "SKILL.md" });
            const text = child.readFileAlloc(io, "SKILL.md", a, .limited(64 * 1024)) catch |err| {
                try skipped.append(a, .{ .path = path, .reason = @errorName(err) });
                continue;
            };
            const skill = parse(a, text, try a.dupe(u8, entry.name), path) catch |err| {
                try skipped.append(a, .{ .path = path, .reason = @errorName(err) });
                continue;
            };
            try map.put(skill.name, skill);
        }
    }
    var skills: std.ArrayList(Skill) = .empty;
    var values = map.valueIterator();
    while (values.next()) |skill| {
        if (skill.disabled) {
            try skipped.append(a, .{ .path = skill.location, .reason = "disable-model-invocation" });
        }
        try skills.append(a, skill.*);
    }
    std.mem.sort(Skill, skills.items, {}, struct {
        fn less(_: void, x: Skill, y: Skill) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    return .{ .skills = skills.items, .summary = .{ .found = skills.items.len, .skipped = skipped.items } };
}

pub fn load(io: std.Io, a: std.mem.Allocator, home: []const u8, user_home: []const u8, root: []const u8) !Result {
    return discover(io, a, &.{
        try std.fs.path.join(a, &.{ user_home, ".agents/skills" }),
        try std.fs.path.join(a, &.{ home, "skills" }),
        try std.fs.path.join(a, &.{ root, ".agents/skills" }),
        try std.fs.path.join(a, &.{ root, ".nib/skills" }),
    });
}

fn enabled(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

pub fn select(a: std.mem.Allocator, found: Result, settings: []const []const u8) !Result {
    var selected: std.ArrayList(Skill) = .empty;
    var summary = found.summary;
    for (found.skills) |skill| {
        if (!skill.disabled and (skill.plugin_root != null or enabled(settings, skill.name))) try selected.append(a, skill);
    }
    for (settings) |name| {
        const exists = for (found.skills) |skill| {
            if (std.mem.eql(u8, skill.name, name)) break true;
        } else false;
        if (!exists) summary.missing += 1;
    }
    summary.count = selected.items.len;
    return .{ .skills = selected.items, .summary = summary };
}

fn escape(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\'' => try out.appendSlice(a, "&apos;"),
        else => try out.append(a, c),
    };
}
pub fn append(a: std.mem.Allocator, base: []const u8, skills: []const Skill) ![]const u8 {
    if (skills.len == 0) return base;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, base);
    try out.appendSlice(a, "\n\nUse tools.read to load a skill's SKILL.md when the task matches its description.\nResolve relative paths against the skill's directory (parent of SKILL.md).\n\n<available_skills>\n");
    for (skills) |skill| {
        try out.appendSlice(a, "  <skill>\n    <name>");
        try escape(a, &out, skill.name);
        try out.appendSlice(a, "</name>\n    <description>");
        try escape(a, &out, skill.description);
        try out.appendSlice(a, "</description>\n    <location>");
        try escape(a, &out, skill.location);
        try out.appendSlice(a, "</location>");
        if (skill.plugin_root) |root| {
            try out.appendSlice(a, "\n    <plugin_root>");
            try escape(a, &out, root);
            try out.appendSlice(a, "</plugin_root>");
        }
        try out.appendSlice(a, "\n  </skill>\n");
    }
    try out.appendSlice(a, "</available_skills>");
    return out.items;
}

test "frontmatter forms and limits" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "plain", "'plain'", "\"plain\"", "|\n  plain", ">\n  plain" }) |value| {
        const s = try parse(a, try std.fmt.allocPrint(a, "---\ndescription: {s}\n---\n", .{value}), "fallback", "/a");
        try std.testing.expectEqualStrings("plain", s.description);
        try std.testing.expectEqualStrings("fallback", s.name);
    }
    try std.testing.expectError(error.MissingDescription, parse(a, "---\nname: x\n---", "a", "a"));
    const s = try parse(a, "---\ndescription: hi\ndisable-model-invocation: true\n---", "a", "a");
    try std.testing.expect(s.disabled);
    try std.testing.expectEqualStrings("first second", (try parse(a, "---\ndescription: >\n  first\n  second\n---", "a", "a")).description);
    try std.testing.expectEqualStrings("first\nsecond", (try parse(a, "---\ndescription: |\n  first\n  second\n---", "a", "a")).description);
    try std.testing.expectEqualStrings("it's fine", (try parse(a, "---\ndescription: 'it''s fine' # comment\n---", "a", "a")).description);
    try std.testing.expectError(error.MissingDescription, parse(a, "---\ndescription: \"\"\n---", "a", "a"));
    const long = try a.alloc(u8, 2048);
    @memset(long, 'a');
    try std.testing.expectEqual(@as(usize, 1024), (try parse(a, try std.fmt.allocPrint(a, "---\ndescription: {s}\n---", .{long}), "a", "a")).description.len);
}

test "discovery overrides, symlinks and empty prompt" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var roots: [4][]const u8 = undefined;
    for (&roots, 0..) |*root, i| {
        const rel = try std.fmt.allocPrint(a, "{d}/same", .{i});
        try tmp.dir.createDirPath(t.io, rel);
        try tmp.dir.writeFile(t.io, .{ .sub_path = try std.fs.path.join(a, &.{ rel, "SKILL.md" }), .data = try std.fmt.allocPrint(a, "---\nname: same\ndescription: version {d}\n---", .{i}) });
        root.* = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{d}", .{ tmp.sub_path, i });
    }
    const found = try discover(t.io, a, &roots);
    try t.expectEqual(@as(usize, 1), found.skills.len);
    try t.expectEqualStrings("version 3", found.skills[0].description);
    try tmp.dir.createDirPath(t.io, "target");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "target/SKILL.md", .data = "---\ndescription: linked\n---" });
    try tmp.dir.symLink(t.io, "../target", "3/link", .{ .is_directory = true });
    try tmp.dir.createDirPath(t.io, "3/.hidden");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "3/loose.md", .data = "---\ndescription: loose\n---" });
    const linked = try discover(t.io, a, roots[3..]);
    try t.expectEqual(@as(usize, 2), linked.skills.len);
    try t.expectEqualStrings("link", linked.skills[0].name);
    try t.expectEqualStrings("linked", linked.skills[0].description);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "3/same/SKILL.md", .data = "---\nname: same\ndescription: disabled\ndisable-model-invocation: true\n---" });
    const disabled = try discover(t.io, a, &roots);
    try t.expectEqual(@as(usize, 2), disabled.skills.len);
    try t.expectEqual(@as(usize, 1), disabled.summary.skipped.len);
    const empty = try append(a, "BASE", &.{});
    try t.expectEqualStrings("BASE", empty);
    const xml = try append(a, "", &.{.{ .name = "<&", .description = "\"'", .location = "/x" }});
    try t.expect(std.mem.indexOf(u8, xml, "&lt;&amp;") != null);
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':';
}

/// A `$name` word ending at `cursor`: `$` at the start or after whitespace, then name characters.
pub fn mentionAt(text: []const u8, cursor: usize) ?struct { start: usize, query: []const u8 } {
    var w = cursor;
    while (w > 0 and isNameChar(text[w - 1])) w -= 1;
    if (w == 0 or text[w - 1] != '$') return null;
    const start = w - 1;
    if (start > 0 and !std.ascii.isWhitespace(text[start - 1])) return null;
    return .{ .start = start, .query = text[w..cursor] };
}

/// Distinct skills named by `$name` tokens in `text`, in order of first mention.
pub fn mentioned(a: std.mem.Allocator, text: []const u8, found: []const Skill) ![]const Skill {
    var out: std.ArrayList(Skill) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '$')) |at| {
        i = at + 1;
        if (at > 0 and !std.ascii.isWhitespace(text[at - 1])) continue;
        var end = i;
        while (end < text.len and isNameChar(text[end])) end += 1;
        if (end == i) continue;
        const name = text[i..end];
        const skill = for (found) |skill| {
            if (std.mem.eql(u8, skill.name, name)) break skill;
        } else continue;
        const seen = for (out.items) |previous| {
            if (std.mem.eql(u8, previous.name, name)) break true;
        } else false;
        if (!seen) try out.append(a, skill);
        i = end;
    }
    return out.items;
}

fn body(text: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, text, "---\n") and !std.mem.startsWith(u8, text, "---\r\n")) return text;
    var offset: usize = 0;
    var fences: u8 = 0;
    while (offset < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len;
        const line = trim(u8, text[offset..end], "\r");
        offset = @min(end + 1, text.len);
        if (std.mem.eql(u8, line, "---")) {
            fences += 1;
            if (fences == 2) break;
        }
    }
    return trim(u8, text[offset..], "\r\n");
}

/// `text` followed by one `<skill>` block per distinct mentioned skill whose SKILL.md still reads and parses.
pub const mention_intro = "\n\nSkills named with $name in this message; relative paths in them resolve against the skill's directory (parent of SKILL.md).";

/// The user's own text of a message that `expand` extended.
pub fn typed(content: []const u8) []const u8 {
    return content[0 .. std.mem.indexOf(u8, content, mention_intro) orelse content.len];
}

pub fn expand(io: std.Io, a: std.mem.Allocator, text: []const u8, found: []const Skill) ![]const u8 {
    var used = try mentioned(a, text, found);
    const invoked = commandSkill(text, found);
    if (invoked) |skill| {
        const already = for (used) |item| {
            if (std.mem.eql(u8, item.name, skill.name)) break true;
        } else false;
        if (!already) used = try std.mem.concat(a, Skill, &.{ &.{skill}, used });
    }
    if (used.len == 0) return text;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, text);
    var first = true;
    for (used) |skill| {
        const raw = std.Io.Dir.cwd().readFileAlloc(io, skill.location, a, .limited(64 * 1024)) catch continue;
        if (!skill.command) _ = parse(a, raw, skill.name, skill.location) catch continue;
        var content = body(raw);
        if (skill.plugin_root) |root| content = try std.mem.replaceOwned(u8, a, content, "${CLAUDE_PLUGIN_ROOT}", root);
        if (invoked) |command| {
            if (std.mem.eql(u8, command.name, skill.name)) {
                const end = std.mem.indexOfAny(u8, text, " \t\n") orelse text.len;
                content = try std.mem.replaceOwned(u8, a, content, "$ARGUMENTS", trim(u8, text[end..], " \t\n"));
            }
        }
        if (first) try out.appendSlice(a, mention_intro);
        first = false;
        try out.appendSlice(a, "\n\n<skill name=\"");
        try escape(a, &out, skill.name);
        try out.appendSlice(a, "\" location=\"");
        try escape(a, &out, skill.location);
        try out.print(a, "\">\n{s}\n</skill>", .{content});
    }
    return out.items;
}

test "mentions need a boundary and an exact skill name" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = [_]Skill{
        .{ .name = "review", .description = "", .location = "/r" },
        .{ .name = "release", .description = "", .location = "/l", .disabled = true },
        .{ .name = "HOME", .description = "", .location = "/h" },
    };
    const hits = try mentioned(a, "$release go, then $review, $review again, a$review $unknown $1 $HOMEx\n$release", &found);
    try t.expectEqual(@as(usize, 2), hits.len);
    try t.expectEqualStrings("release", hits[0].name);
    try t.expectEqualStrings("review", hits[1].name);
    try t.expectEqual(@as(usize, 1), (try mentioned(a, "use $HOME.", &found)).len);
    try t.expectEqual(@as(usize, 0), (try mentioned(a, "echo $HOMEDIR $PATH", &found)).len);
    try t.expectEqual(@as(usize, 0), (try mentioned(a, "$", &found)).len);
    const m = mentionAt("see $rev", 8).?;
    try t.expectEqual(@as(usize, 4), m.start);
    try t.expectEqualStrings("rev", m.query);
    try t.expect(mentionAt("a$rev", 5) == null);
    try t.expectEqualStrings("", mentionAt("$", 1).?.query);
}

test "expansion appends the body and skips unreadable skills" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(t.io, "s/one");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "s/one/SKILL.md", .data = "---\ndescription: d\ndisable-model-invocation: true\n---\nDo the thing.\n" });
    const found = try discover(t.io, a, &.{try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/s", .{tmp.sub_path})});
    try t.expect(found.skills[0].disabled);
    const out = try expand(t.io, a, "go $one", found.skills);
    try t.expect(std.mem.startsWith(u8, out, "go $one\n\n"));
    try t.expect(std.mem.indexOf(u8, out, "<skill name=\"one\" location=\"") != null);
    try t.expect(std.mem.endsWith(u8, out, "\nDo the thing.\n</skill>"));
    try t.expect(std.mem.indexOf(u8, out, "description: d") == null);
    try t.expectEqualStrings("go $none", try expand(t.io, a, "go $none", found.skills));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "s/one/SKILL.md", .data = try a.alloc(u8, 65 * 1024) });
    try t.expectEqualStrings("go $one", try expand(t.io, a, "go $one", found.skills));
}

pub fn source(a: std.mem.Allocator, path: []const u8, home: []const u8, user_home: []const u8, root: []const u8) ![]const u8 {
    const roots = [_][]const u8{
        try std.fs.path.join(a, &.{ user_home, ".agents/skills" }),
        try std.fs.path.join(a, &.{ home, "skills" }),
        try std.fs.path.join(a, &.{ root, ".agents/skills" }),
        try std.fs.path.join(a, &.{ root, ".nib/skills" }),
    };
    const labels = [_][]const u8{ "~/.agents/skills", "$NIB_HOME/skills", ".agents/skills", ".nib/skills" };
    for (roots, labels) |dir, label| {
        if (std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/') return label;
    }
    return path;
}

test "plugin namespaced mentions and commands share exact matching" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = [_]Skill{
        .{ .name = "example:review", .description = "review", .location = "/review", .plugin_root = "/plugin" },
        .{ .name = "example:check", .description = "check", .location = "/check", .plugin_root = "/plugin", .disabled = true, .command = true },
    };
    const hits = try mentioned(a, "$example:review $example:review $example:check $example:other", &entries);
    try t.expectEqual(@as(usize, 2), hits.len);
    try t.expectEqualStrings("example:review", mentionAt("$example:review", 15).?.query);
    try t.expectEqualStrings("example:check", commandSkill("/example:check file", &entries).?.name);
    try t.expect(commandSkill("/example:check-other", &entries) == null);
    const found = try select(a, .{ .skills = try a.dupe(Skill, &entries), .summary = .{ .found = 2 } }, &.{});
    try t.expectEqual(@as(usize, 1), found.skills.len);
    const duplicated = try copy(a, &entries);
    try t.expectEqualDeep(entries[0], duplicated[0]);
}
