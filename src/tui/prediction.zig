//! Ghost-text prediction of the user's next message. Background, stateless
//! and silent: every failure shows nothing.

const std = @import("std");
const vaxis = @import("vaxis");
const provider = @import("../provider.zig");
const web = @import("../tools/web.zig");
const tui = @import("../tui.zig");
const Editor = @import("editor.zig").Editor;
const skills = @import("../session/skills.zig");

const timeout_ms = 15_000;
const max_reply_bytes = 3 * 1024;
const max_user_bytes = 1024;
const max_recent = 8;
const max_recent_message_bytes = 300;
const max_recent_bytes = 3 * 1024;
const max_tokens = 256;

const instruction =
    \\Predict the user's next message to the coding agent. You are an input predictor, not the agent.
    \\Default to NONE. Suggest a message only when the user's own words strongly support that specific next message.
    \\A question or a list of options from the assistant does not establish the user's preference. Do not pick an option for them.
    \\If no reply is expected or the user's intent is unclear, output exactly NONE.
    \\Never invent agreement, praise, or thanks. A greeting, a generic question, or a completed-work report alone does not justify a prediction.
    \\Write only what the user would type, in their language and style. 'I' refers to the user; 'you' refers to the agent.
    \\Use the assistant's last reply only as context. Do not answer the user, echo the assistant's reply, or continue it.
    \\Return one line of at most 80 characters, with no labels or commentary.
;

const no_reply = [_][]const u8{ "none", "nothing", "(nothing)", "no reply", "no reply needed", "no response", "n/a", "na", "无", "无需回复", "不需要回复", "无需回应" };
const thanks = [_][]const u8{ "thanks", "thank you", "thx", "谢谢", "感谢" };

fn headEnd(text: []const u8, max: usize) usize {
    var end = @min(text.len, max);
    while (end < text.len and end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return end;
}

fn tailStart(text: []const u8, max: usize) usize {
    var start = text.len -| max;
    while (start < text.len and text[start] & 0xc0 == 0x80) start += 1;
    return start;
}

/// Typed user messages, newest last, borrowed from the history; skips background and undo messages.
pub fn recentUserMessages(a: std.mem.Allocator, history: []const provider.Message) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    var i = history.len;
    while (i > 0 and out.items.len < max_recent) : (i -= 1) {
        const m = history[i - 1];
        if (m.source != null or !std.mem.eql(u8, m.role, "user")) continue;
        const text = std.mem.trim(u8, skills.typed(m.content orelse continue), " \t\r\n");
        if (text.len != 0) try out.append(a, text);
    }
    std.mem.reverse([]const u8, out.items);
    return out.toOwnedSlice(a);
}

/// The model input: the user's recent messages (oldest first), the head of the last one and the tail of the reply.
pub fn buildInput(a: std.mem.Allocator, recent: []const []const u8, reply: []const u8) ![]u8 {
    const last = if (recent.len > 0) recent[recent.len - 1] else "";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var first: usize = recent.len;
    var used: usize = 0;
    while (first > 0) {
        const n = headEnd(recent[first - 1], max_recent_message_bytes) + 3;
        if (used + n > max_recent_bytes) break;
        used += n;
        first -= 1;
    }
    if (first < recent.len) {
        try out.appendSlice(a, "User's recent messages, oldest first:\n");
        for (recent[first..]) |text| {
            try out.appendSlice(a, "- ");
            for (text[0..headEnd(text, max_recent_message_bytes)]) |c| try out.append(a, if (c == '\n' or c == '\r') ' ' else c);
            try out.append(a, '\n');
        }
        try out.append(a, '\n');
    }
    try out.print(a, "User's last message:\n{s}\n\nAssistant's last reply:\n{s}", .{
        last[0..headEnd(last, max_user_bytes)],
        reply[tailStart(reply, max_reply_bytes)..],
    });
    return out.toOwnedSlice(a);
}

fn matchesAny(text: []const u8, list: []const []const u8) bool {
    for (list) |item| if (std.ascii.eqlIgnoreCase(text, item)) return true;
    return false;
}

const punctuation = [_][]const u8{ ".", "!", ",", ":", ";", "*", "_", "[", "]", "(", ")", "<", ">", "\"", "'", "`", " ", "。", "！", "，", "：", "；", "（", "）", "《", "》", "“", "”", "「", "」" };

fn trimPunctuation(text: []const u8) []const u8 {
    var t = text;
    outer: while (t.len > 0) {
        for (punctuation) |p| {
            if (std.mem.startsWith(u8, t, p)) {
                t = t[p.len..];
                continue :outer;
            }
            if (std.mem.endsWith(u8, t, p)) {
                t = t[0 .. t.len - p.len];
                continue :outer;
            }
        }
        break;
    }
    return t;
}

/// First line without surrounding quotes, owned; null when empty, "no reply" or a thanks.
pub fn filter(gpa: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const first = std.mem.sliceTo(std.mem.trim(u8, raw, " \t\r\n"), '\n');
    var line = std.mem.trim(u8, first, " \t\r");
    const pairs = [_][2][]const u8{ .{ "\"", "\"" }, .{ "'", "'" }, .{ "`", "`" }, .{ "“", "”" }, .{ "「", "」" } };
    for (pairs) |pair| {
        if (line.len >= pair[0].len + pair[1].len and std.mem.startsWith(u8, line, pair[0]) and std.mem.endsWith(u8, line, pair[1])) {
            line = std.mem.trim(u8, line[pair[0].len .. line.len - pair[1].len], " \t\r");
            break;
        }
    }
    const chars = std.unicode.utf8CountCodepoints(line) catch return null;
    if (chars < 2) return null;
    const bare = trimPunctuation(line);
    if (bare.len == 0 or matchesAny(bare, &no_reply) or matchesAny(bare, &thanks)) return null;
    return try gpa.dupe(u8, line);
}

const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    loop: *vaxis.Loop(tui.Event),
    cfg: provider.Config,
    cache_key: []u8,
    input: []u8,
    generation: u64,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn silent(_: *anyopaque, _: provider.Kind, _: []const u8) !void {}

    fn run(w: *Worker) void {
        defer w.done.store(true, .release);
        const text = w.request() orelse return;
        if (w.cancel.load(.acquire)) return w.gpa.free(text);
        const posted = w.loop.tryPostEvent(.{ .prediction = .{ .generation = w.generation, .text = text } }) catch false;
        if (!posted) w.gpa.free(text);
    }

    fn request(w: *Worker) ?[]u8 {
        const U = union(enum) { reply: ?[]u8, stop: web.Stop };
        var buffer: [2]U = undefined;
        var select = std.Io.Select(U).init(w.io, &buffer);
        defer select.cancelDiscard();
        select.concurrent(.reply, ask, .{w}) catch return null;
        select.concurrent(.stop, web.watch, .{ w.io, &w.cancel, @as(u64, timeout_ms) }) catch return null;
        const first = select.await() catch return null;
        return switch (first) {
            .reply => |text| text,
            .stop => blk: {
                w.cancel.store(true, .release);
                break :blk null;
            },
        };
    }

    fn ask(w: *Worker) ?[]u8 {
        var arena: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var client: std.http.Client = .{ .allocator = w.gpa, .io = w.io };
        defer client.deinit();
        const messages = [_]provider.Message{
            .{ .role = "system", .content = instruction },
            .{ .role = "user", .content = w.input },
        };
        var detail: ?[]u8 = null;
        defer if (detail) |d| w.gpa.free(d);
        var attempts: u32 = 0;
        const reply = provider.complete(w.gpa, a, &client, w.cfg, w.cache_key, &messages, "[]", max_tokens, .{ .ctx = w, .onDelta = silent, .replay_safe = true }, &w.cancel, &detail, &attempts, null) catch return null;
        return (filter(w.gpa, reply.text) catch null) orelse null;
    }

    fn finish(w: *Worker) void {
        w.cancel.store(true, .release);
        w.thread.join();
        w.gpa.free(w.cache_key);
        w.gpa.free(w.input);
        w.gpa.destroy(w);
    }
};

pub const State = struct {
    /// Bumped by every invalidation; a result carrying an older value is dropped.
    generation: u64 = 0,
    text: ?[]u8 = null,
    current: ?*Worker = null,
    workers: std.ArrayList(*Worker) = .empty,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        if (s.text) |t| gpa.free(t);
        for (s.workers.items) |w| w.finish();
        s.workers.deinit(gpa);
    }

    pub fn invalidate(s: *State, gpa: std.mem.Allocator) void {
        s.generation +%= 1;
        if (s.text) |t| gpa.free(t);
        s.text = null;
        if (s.current) |w| w.cancel.store(true, .release);
        s.current = null;
    }

    /// Takes ownership of `text`.
    pub fn arrive(s: *State, gpa: std.mem.Allocator, generation: u64, text: []u8) void {
        if (generation != s.generation) return gpa.free(text);
        if (s.text) |old| gpa.free(old);
        s.text = text;
    }

    /// The ghost text, only while the editor holds nothing at all.
    pub fn visible(s: *const State, editor: *const Editor) []const u8 {
        if (editor.text().len != 0) return "";
        return s.text orelse "";
    }

    /// Tab: moves a visible prediction into the editor. False leaves Tab to its other uses.
    pub fn accept(s: *State, gpa: std.mem.Allocator, editor: *Editor) !bool {
        const text = s.visible(editor);
        if (text.len == 0) return false;
        try editor.insert(gpa, text);
        gpa.free(s.text.?);
        s.text = null;
        return true;
    }

    fn reap(s: *State) void {
        var i: usize = 0;
        while (i < s.workers.items.len) {
            if (s.workers.items[i].done.load(.acquire)) {
                s.workers.swapRemove(i).finish();
            } else i += 1;
        }
    }

    /// Starts a request for the next message; any failure to start is silent.
    pub fn start(s: *State, gpa: std.mem.Allocator, io: std.Io, loop: *vaxis.Loop(tui.Event), session_cfg: provider.Config, session_id: []const u8, recent: []const []const u8, reply: []const u8) void {
        s.invalidate(gpa);
        s.reap();
        startWorker(s, gpa, io, loop, session_cfg, session_id, recent, reply) catch {};
    }

    fn startWorker(s: *State, gpa: std.mem.Allocator, io: std.Io, loop: *vaxis.Loop(tui.Event), session_cfg: provider.Config, session_id: []const u8, recent: []const []const u8, reply: []const u8) !void {
        var cfg = provider.withSmallModel(session_cfg) orelse session_cfg;
        try cfg.setEffort("off");
        cfg.codex_transport = .sse;
        cfg.output_schema = null;
        try s.workers.ensureUnusedCapacity(gpa, 1);
        const w = try gpa.create(Worker);
        errdefer gpa.destroy(w);
        const key = try std.fmt.allocPrint(gpa, "{s}:predict", .{session_id});
        errdefer gpa.free(key);
        const input = try buildInput(gpa, recent, reply);
        errdefer gpa.free(input);
        w.* = .{ .gpa = gpa, .io = io, .loop = loop, .cfg = cfg, .cache_key = key, .input = input, .generation = s.generation };
        w.thread = try std.Thread.spawn(.{}, Worker.run, .{w});
        s.workers.appendAssumeCapacity(w);
        s.current = w;
    }
};

const testing = std.testing;

test "input keeps the head of the user message and the tail of the reply on codepoint boundaries" {
    const a = testing.allocator;
    const user = try a.alloc(u8, 3000);
    defer a.free(user);
    @memset(user, '1');
    const reply = try a.alloc(u8, 9000);
    defer a.free(reply);
    @memset(reply, '2');
    @memcpy(reply[reply.len - 3 ..], "end");
    const text = try buildInput(a, &.{user}, reply);
    defer a.free(text);
    try testing.expectEqual(@as(usize, max_user_bytes + max_recent_message_bytes), std.mem.count(u8, text, "1"));
    try testing.expectEqual(@as(usize, max_reply_bytes - 3), std.mem.count(u8, text, "2"));
    try testing.expect(std.mem.endsWith(u8, text, "2end"));

    const wide = try a.alloc(u8, 6000);
    defer a.free(wide);
    for (0..2000) |i| @memcpy(wide[i * 3 ..][0..3], "界");
    const cut = try buildInput(a, &.{wide}, wide);
    defer a.free(cut);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "input lists recent messages oldest first, cut and capped" {
    const a = testing.allocator;
    const text = try buildInput(a, &.{ "合并", "ship 0.11.1\nnow" }, "done");
    defer a.free(text);
    try testing.expectEqualStrings("User's recent messages, oldest first:\n- 合并\n- ship 0.11.1 now\n\nUser's last message:\nship 0.11.1\nnow\n\nAssistant's last reply:\ndone", text);

    const long: [400]u8 = @splat('x');
    var many: [20][]const u8 = undefined;
    for (&many, 0..) |*m, i| m.* = if (i == 19) "newest" else &long;
    const capped = try buildInput(a, &many, "r");
    defer a.free(capped);
    const section = capped[0..std.mem.indexOf(u8, capped, "\n\nUser's last").?];
    try testing.expect(section.len <= max_recent_bytes + 64);
    try testing.expect(std.mem.endsWith(u8, section, "- newest"));
    try testing.expectEqual(@as(usize, 11), std.mem.count(u8, section, "\n- "));

    const none = try buildInput(a, &.{}, "r");
    defer a.free(none);
    try testing.expect(std.mem.startsWith(u8, none, "User's last message:"));
}

test "recent user messages skip background, undo and skill blocks" {
    const a = testing.allocator;
    const history = [_]provider.Message{
        .{ .role = "user", .content = "one" },
        .{ .role = "assistant", .content = "a" },
        .{ .role = "user", .content = "bg", .source = .background },
        .{ .role = "user", .content = "two" ++ skills.mention_intro ++ "\n\n<skill name=\"x\">y</skill>" },
        .{ .role = "user", .content = "  " },
    };
    const got = try recentUserMessages(a, &history);
    defer a.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("one", got[0]);
    try testing.expectEqualStrings("two", got[1]);
}

test "filter keeps the first line without quotes and drops trivia" {
    const a = testing.allocator;
    const keep = [_][2][]const u8{
        .{ "  \"run the tests\"\nextra", "run the tests" },
        .{ "“修一下这个 bug”", "修一下这个 bug" },
        .{ "commit it", "commit it" },
        .{ "可以", "可以" },
        .{ "合并", "合并" },
        .{ "ok", "ok" },
        .{ "好的", "好的" },
    };
    for (keep) |pair| {
        const got = (try filter(a, pair[0])).?;
        defer a.free(got);
        try testing.expectEqualStrings(pair[1], got);
    }
    for ([_][]const u8{ "", "  \n ", "a", "\"\"", "Thanks!", "谢谢", "感谢", "thx", "NONE", "none.", "\"NONE\"", "(nothing)", "Nothing", "No reply needed.", "N/A", "无需回复", "无", "不需要回复", "（无需回复）" }) |raw| {
        try testing.expect((try filter(a, raw)) == null);
    }
}

test "prediction shows only on an empty editor and survives typing and clearing" {
    const a = testing.allocator;
    var s: State = .{};
    defer s.deinit(a);
    var e: Editor = .{};
    defer e.deinit(a);
    try testing.expectEqualStrings("", s.visible(&e));
    s.arrive(a, s.generation, try a.dupe(u8, "run the tests"));
    try testing.expectEqualStrings("run the tests", s.visible(&e));
    try e.insert(a, "x");
    try testing.expectEqualStrings("", s.visible(&e));
    try e.replace(a, "");
    try testing.expectEqualStrings("run the tests", s.visible(&e));
}

test "late arrival while typing waits for an empty editor and old generations drop" {
    const a = testing.allocator;
    var s: State = .{};
    defer s.deinit(a);
    var e: Editor = .{};
    defer e.deinit(a);
    const generation = s.generation;
    try e.insert(a, "typing");
    s.arrive(a, generation, try a.dupe(u8, "late"));
    try testing.expectEqualStrings("", s.visible(&e));
    try e.replace(a, "");
    try testing.expectEqualStrings("late", s.visible(&e));
    s.invalidate(a);
    try testing.expectEqualStrings("", s.visible(&e));
    s.arrive(a, generation, try a.dupe(u8, "stale"));
    try testing.expectEqualStrings("", s.visible(&e));
    s.arrive(a, s.generation, try a.dupe(u8, "fresh"));
    try testing.expectEqualStrings("fresh", s.visible(&e));
}

test "Tab inserts a visible prediction and otherwise is left alone" {
    const a = testing.allocator;
    var s: State = .{};
    defer s.deinit(a);
    var e: Editor = .{};
    defer e.deinit(a);
    try testing.expect(!try s.accept(a, &e));
    s.arrive(a, s.generation, try a.dupe(u8, "commit it"));
    try e.insert(a, "x");
    try testing.expect(!try s.accept(a, &e));
    try testing.expectEqualStrings("x", e.text());
    try e.replace(a, "");
    try testing.expect(try s.accept(a, &e));
    try testing.expectEqualStrings("commit it", e.text());
    try e.replace(a, "");
    try testing.expectEqualStrings("", s.visible(&e));
}
