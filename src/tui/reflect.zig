const std = @import("std");

/// Edit the wording in reflect.md; `{{session_id}}`, `{{log_path}}`, `{{issue_repo}}` and `{{focus}}` are filled in here.
const template = @embedFile("reflect.md");

/// The reflection request sent to the model as the user message. Caller owns it.
pub fn prompt(gpa: std.mem.Allocator, session_id: []const u8, log_path: []const u8, issue_repo: []const u8, focus: []const u8) ![]u8 {
    const focus_text = if (focus.len == 0) try gpa.dupe(u8, "") else try std.fmt.allocPrint(gpa, "\n用户特别想了解：{s}", .{focus});
    defer gpa.free(focus_text);
    const with_id = try std.mem.replaceOwned(u8, gpa, template, "{{session_id}}", session_id);
    defer gpa.free(with_id);
    const with_log = try std.mem.replaceOwned(u8, gpa, with_id, "{{log_path}}", log_path);
    defer gpa.free(with_log);
    const with_repo = try std.mem.replaceOwned(u8, gpa, with_log, "{{issue_repo}}", issue_repo);
    defer gpa.free(with_repo);
    return std.mem.replaceOwned(u8, gpa, with_repo, "{{focus}}", focus_text);
}

pub const Entry = struct {
    unix_seconds: i64,
    session_id: []const u8,
    cwd: []const u8,
    model: []const u8,
    effort: []const u8,
    focus: []const u8 = "",
    answer: []const u8,
};

/// Appends one reflection to `path` (created if missing).
pub fn append(io: std.Io, gpa: std.mem.Allocator, path: []const u8, e: Entry) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const day = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(e.unix_seconds, 0)) };
    const date = day.getEpochDay().calculateYearDay();
    const month_day = date.calculateMonthDay();
    const clock = day.getDaySeconds();
    try text.print(gpa, "## {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC · session {s} · {s} · {s} · effort {s}\n", .{
        date.year,                  month_day.month.numeric(), month_day.day_index + 1,
        clock.getHoursIntoDay(),    clock.getMinutesIntoHour(), e.session_id[0..@min(8, e.session_id.len)],
        e.cwd,                      e.model,                   e.effort,
    });
    if (e.focus.len > 0) try text.print(gpa, "focus: {s}\n", .{e.focus});
    try text.print(gpa, "\n{s}\n\n", .{std.mem.trim(u8, e.answer, "\n")});
    try appendText(io, path, text.items);
}

/// Under an exclusive lock because several nib processes share one file.
pub fn appendText(io: std.Io, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .lock = .exclusive });
    defer file.close(io);
    try file.writePositionalAll(io, text, try file.length(io));
}

pub const Draft = struct { title: []const u8, body: []const u8 };

pub const max_drafts = 3;

/// Issue drafts from the last ```json block of a reflection; empty when absent or malformed.
pub fn drafts(a: std.mem.Allocator, answer: []const u8) ![]const Draft {
    const fence = std.mem.lastIndexOf(u8, answer, "```json") orelse return &.{};
    const start = fence + "```json".len;
    const end = std.mem.indexOfPos(u8, answer, start, "```") orelse return &.{};
    const parsed = std.json.parseFromSliceLeaky([]const Draft, a, answer[start..end], .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return &.{};
    var out: std.ArrayList(Draft) = .empty;
    for (parsed) |d| {
        const title = std.mem.trim(u8, d.title, " \n");
        if (title.len == 0 or out.items.len == max_drafts) continue;
        try out.append(a, .{ .title = title, .body = std.mem.trim(u8, d.body, "\n") });
    }
    return out.items;
}

/// Files `draft` with the GitHub CLI unless an issue with the same title exists.
/// Returns a one-line outcome for the transcript, owned by the caller.
/// `gh_path` is the program to run; tests pass a fake one by absolute path, since spawn searches the parent's PATH.
pub fn fileIssue(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, gh_path: []const u8, repo: []const u8, draft: Draft, footer: []const u8) ![]u8 {
    const search = try std.fmt.allocPrint(gpa, "{s} in:title", .{draft.title});
    defer gpa.free(search);
    const listed = try gh(io, gpa, env, &.{ gh_path, "issue", "list", "--repo", repo, "--state", "all", "--search", search, "--json", "number,title,url", "--limit", "20" }, "");
    defer listed.deinit(gpa);
    if (!listed.ok) return std.fmt.allocPrint(gpa, "could not search {s}: {s}", .{ repo, firstLine(listed.err) });
    const Found = struct { number: u64, title: []const u8, url: []const u8 };
    const found = std.json.parseFromSlice([]const Found, gpa, listed.out, .{ .ignore_unknown_fields = true }) catch
        return std.fmt.allocPrint(gpa, "could not read gh output while searching {s}", .{repo});
    defer found.deinit();
    for (found.value) |f| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, f.title, " "), draft.title))
        return std.fmt.allocPrint(gpa, "skipped: #{d} already has this title · {s}", .{ f.number, f.url });

    const body = try std.fmt.allocPrint(gpa, "{s}\n\n---\n{s}\n", .{ draft.body, footer });
    defer gpa.free(body);
    const created = try gh(io, gpa, env, &.{ gh_path, "issue", "create", "--repo", repo, "--title", draft.title, "--body-file", "-" }, body);
    defer created.deinit(gpa);
    if (!created.ok) return std.fmt.allocPrint(gpa, "could not file the issue: {s}", .{firstLine(created.err)});
    return std.fmt.allocPrint(gpa, "filed {s}", .{std.mem.trim(u8, created.out, " \n")});
}

/// Prepares a draft for publishing: the project path becomes <project> and the home path ~.
/// Null when the draft looks like it carries a credential, which must never be published.
/// Best effort only: the reflection prompt is the main guard.
pub fn sanitize(a: std.mem.Allocator, draft: Draft, home: []const u8, cwd: []const u8) !?Draft {
    const markers = [_][]const u8{ "sk-", "ghp_", "gho_", "github_pat_", "xoxb-", "Bearer ", "PRIVATE KEY" };
    for ([_][]const u8{ draft.title, draft.body }) |text|
        for (markers) |m| if (std.mem.indexOf(u8, text, m) != null) return null;
    return .{ .title = try redact(a, draft.title, home, cwd), .body = try redact(a, draft.body, home, cwd) };
}

fn redact(a: std.mem.Allocator, text: []const u8, home: []const u8, cwd: []const u8) ![]const u8 {
    const without_project = if (cwd.len > 1) try std.mem.replaceOwned(u8, a, text, cwd, "<project>") else text;
    return if (home.len > 1) try std.mem.replaceOwned(u8, a, without_project, home, "~") else without_project;
}

const Output = struct {
    ok: bool,
    out: []u8,
    err: []u8,

    fn deinit(o: Output, gpa: std.mem.Allocator) void {
        gpa.free(o.out);
        gpa.free(o.err);
    }
};

/// The user's own environment, unlike tool subprocesses: gh may authenticate through GH_TOKEN.
fn gh(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, argv: []const []const u8, input: []const u8) !Output {
    var child = std.process.spawn(io, .{ .argv = argv, .environ_map = env, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe }) catch |err|
        return .{ .ok = false, .out = try gpa.dupe(u8, ""), .err = try std.fmt.allocPrint(gpa, "cannot run gh: {s}", .{@errorName(err)}) };
    defer child.kill(io);
    {
        const stdin = child.stdin.?;
        child.stdin = null;
        defer stdin.close(io);
        var w = stdin.writer(io, &.{});
        try w.interface.writeAll(input);
        try w.interface.flush();
    }
    var buf: [4096]u8 = undefined;
    var out_reader = child.stdout.?.reader(io, &buf);
    const out = try out_reader.interface.allocRemaining(gpa, .limited(1 << 20));
    errdefer gpa.free(out);
    var err_reader = child.stderr.?.reader(io, &buf);
    const err = try err_reader.interface.allocRemaining(gpa, .limited(1 << 20));
    errdefer gpa.free(err);
    const term = try child.wait(io);
    return .{ .ok = term.success(), .out = out, .err = err };
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \n");
    return trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
}

const testing = std.testing;

test "prompt fills the session, log path, issue repo and optional focus" {
    const plain = try prompt(testing.allocator, "abc123", "/h/.nib/sessions/abc123.jsonl", "o/r", "");
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "本会话日志是 /h/.nib/sessions/abc123.jsonl") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "parent_session_id 是 abc123") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "gh issue list --repo o/r ") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "{{") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "用户特别想了解") == null);

    const focused = try prompt(testing.allocator, "abc123", "/l", "o/r", "子 agent");
    defer testing.allocator.free(focused);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, focused, "\n"), "用户特别想了解：子 agent"));
}

test "append creates the file, then adds entries after earlier ones" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/nib/reflections.md", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const base: Entry = .{ .unix_seconds = 1_793_600_000, .session_id = "0123456789abcdef", .cwd = "/p", .model = "m", .effort = "high", .answer = "\n### 摘要\n一切正常\n" };
    try append(testing.io, testing.allocator, path, base);
    var second = base;
    second.focus = "超时";
    second.answer = "第二次";
    try append(testing.io, testing.allocator, path, second);
    const data = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(4096));
    defer testing.allocator.free(data);
    try testing.expectEqualStrings(
        \\## 2026-11-02 06:13 UTC · session 01234567 · /p · m · effort high
        \\
        \\### 摘要
        \\一切正常
        \\
        \\## 2026-11-02 06:13 UTC · session 01234567 · /p · m · effort high
        \\focus: 超时
        \\
        \\第二次
        \\
        \\
    , data);
}

test "drafts come from the last json block, trimmed and capped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const answer =
        \\### 摘要
        \\```json
        \\[{"title": "old"}]
        \\```
        \\### Issue 草稿
        \\```json
        \\[{"title": " grep: misses dotfiles ", "body": "\n现象\n"}, {"title": "", "body": "x"},
        \\ {"title": "b", "body": ""}, {"title": "c", "body": ""}, {"title": "d", "body": "", "extra": 1}]
        \\```
    ;
    const found = try drafts(a, answer);
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("grep: misses dotfiles", found[0].title);
    try testing.expectEqualStrings("现象", found[0].body);
    try testing.expectEqualStrings("c", found[2].title);
    try testing.expectEqual(@as(usize, 0), (try drafts(a, "no block")).len);
    try testing.expectEqual(@as(usize, 0), (try drafts(a, "```json\nnot json\n```")).len);
    try testing.expectEqual(@as(usize, 0), (try drafts(a, "```json\n[]\n```")).len);
}

test "file skips an existing title and files new drafts through gh" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(root);
    const session_id = "0123456789abcdef0123456789abcdef";
    const marker = "PRIVATE_CALLS_CONTENT_NOT_FOR_REFLECTION";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = session_id ++ ".calls.jsonl", .data = marker });
    const log_path = try std.fs.path.join(testing.allocator, &.{ root, session_id ++ ".jsonl" });
    defer testing.allocator.free(log_path);
    const request = try prompt(testing.allocator, session_id, log_path, "o/r", "");
    defer testing.allocator.free(request);
    try testing.expect(std.mem.indexOf(u8, request, marker) == null);
    try testing.expect(std.mem.indexOf(u8, request, "只查文件名严格为 `<32位小写十六进制ID>.jsonl`") != null);
    try testing.expect(std.mem.indexOf(u8, request, "不得运行 `nib replay`") != null);
    try testing.expect(std.mem.indexOf(u8, request, "不能对整个目录做内容搜索") != null);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "gh", .data =
        \\#!/bin/sh
        \\if [ "$2" = list ]; then echo '[{"number":7,"title":"Known Bug","url":"https://x/7"}]'; exit 0; fi
        \\cat > "$(dirname "$0")/body"; echo "$@" > "$(dirname "$0")/args"; echo https://x/8
    , .flags = .{ .permissions = .executable_file } });
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const fake = try std.fs.path.join(testing.allocator, &.{ root, "gh" });
    defer testing.allocator.free(fake);

    const skipped = try fileIssue(testing.io, testing.allocator, &env, fake, "o/r", .{ .title = "known bug", .body = "b" }, "footer");
    defer testing.allocator.free(skipped);
    try testing.expectEqualStrings("skipped: #7 already has this title · https://x/7", skipped);

    const filed = try fileIssue(testing.io, testing.allocator, &env, fake, "o/r", .{ .title = "New bug", .body = "body" }, "footer");
    defer testing.allocator.free(filed);
    try testing.expectEqualStrings("filed https://x/8", filed);
    const body = try tmp.dir.readFileAlloc(testing.io, "body", testing.allocator, .limited(1024));
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("body\n\n---\nfooter\n", body);
    try testing.expect(std.mem.indexOf(u8, body, marker) == null);
    const args = try tmp.dir.readFileAlloc(testing.io, "args", testing.allocator, .limited(1024));
    defer testing.allocator.free(args);
    try testing.expect(std.mem.indexOf(u8, args, marker) == null);
}

test "sanitize replaces private paths and refuses credential-like drafts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const clean = (try sanitize(a, .{ .title = "write fails in /home/u/work/acme", .body = "/home/u/work/acme/app.py and /home/u/.nib" }, "/home/u", "/home/u/work/acme")).?;
    try testing.expectEqualStrings("write fails in <project>", clean.title);
    try testing.expectEqualStrings("<project>/app.py and ~/.nib", clean.body);
    try testing.expect(try sanitize(a, .{ .title = "t", .body = "token ghp_abc" }, "/home/u", "/w") == null);
}
