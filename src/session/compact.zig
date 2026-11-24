const std = @import("std");
const provider = @import("../provider.zig");
const image = @import("../image.zig");
const Session = @import("../session.zig").Session;
const Sink = @import("../session.zig").Sink;

pub const Compaction = enum { compacted, too_few_steps, ineffective };

const summary_prefix = "Earlier session summary:\n";

pub fn threshold(window: u64) u64 {
    return window - window / 4;
}

pub fn compact(s: *Session, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !Compaction {
    return compactWithFocus(s, "", sink, cancel, detail);
}

pub fn compactWithFocus(s: *Session, focus: []const u8, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !Compaction {
    return compactHistory(s, focus, 0, sink, cancel, detail);
}

fn compactHistory(s: *Session, focus: []const u8, pending_tokens: u64, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !Compaction {
    const plan = switch (planCompaction(s.history.items, s.cfg, pending_tokens)) {
        .ready => |plan| plan,
        .too_few_steps => {
            try sink.emit(sink.ctx, .{ .notice = "compaction skipped: fewer than three complete Steps" });
            return .too_few_steps;
        },
        .no_room => {
            try sink.emit(sink.ctx, .{ .notice = "compaction skipped: no room for a summary within the context budget" });
            return .ineffective;
        },
    };
    s.codex_state.clearPrevious(s.gpa);
    s.codex_state.reset_reason = "compaction";
    defer s.codex_state.clearPrevious(s.gpa);
    const a = s.arena.allocator();
    var request: std.ArrayList(provider.Message) = .empty;
    defer request.deinit(s.gpa);
    for (s.history.items[0..plan.cut]) |m| try request.append(s.gpa, try withoutImages(a, m));
    try request.append(s.gpa, .{ .role = "user", .content = try summaryPrompt(a, focus) });
    const Silent = struct {
        fn delta(ctx: *anyopaque, _: provider.Kind, text: []const u8) !void {
            if (text.len == 0) return;
            const target: *Sink = @ptrCast(@alignCast(ctx));
            try target.modelActivity(.data);
        }
    };
    var observer = sink;
    // Thinking would spend the small summary budget on reasoning.
    var cfg = s.cfg;
    cfg.thinking = false;
    var attempts: u32 = 0;
    const reply = request_model: {
        try sink.modelActivity(.started);
        defer sink.modelActivity(.finished) catch {};
        break :request_model try provider.complete(s.gpa, a, s.client, cfg, s.cache_key, request.items, "[]", @intCast(plan.summary_tokens), .{ .ctx = &observer, .onDelta = Silent.delta, .replay_safe = true, .codex_state = &s.codex_state }, cancel, detail, &attempts, null);
    };
    s.usage.add(reply.usage);
    try sink.emit(sink.ctx, .{ .usage = s.usage });
    if (cancel.load(.acquire)) return error.Canceled;
    const summary = std.mem.trim(u8, reply.text, " \t\r\n");
    if (summary.len == 0 or reply.tool_calls.len != 0) return error.InvalidSummary;
    var replacement: std.ArrayList(provider.Message) = .empty;
    defer replacement.deinit(s.gpa);
    try replacement.append(s.gpa, .{ .role = "user", .content = try std.fmt.allocPrint(a, "{s}{s}", .{ summary_prefix, summary }) });
    try replacement.appendSlice(s.gpa, s.history.items[plan.cut..]);
    const after = estimateTokens(s.history.items[0..1], s.cfg) + estimateTokens(replacement.items, s.cfg);
    if (after > plan.limit) {
        try sink.emit(sink.ctx, .{ .notice = "compaction skipped: the summary would exceed the context budget" });
        return .ineffective;
    }
    const old_len = s.history.items.len;
    try s.commit(1, replacement.items, after, null);
    s.compact_backoff = 0;
    try sink.emit(sink.ctx, .{ .usage = s.usage });
    const message = try std.fmt.allocPrint(a, "compacted context: {d} → {d} messages, ~{d} → ~{d} tokens", .{ old_len, s.history.items.len, plan.before, after });
    try sink.emit(sink.ctx, .{ .notice = message });
    return .compacted;
}

pub fn autoCompact(s: *Session, pending_tokens: u64, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
    const result = compactHistory(s, "", pending_tokens, sink, cancel, detail) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => blk: {
            const msg = try std.fmt.allocPrint(s.arena.allocator(), "automatic compaction failed, continuing without it: {s}", .{detail.* orelse @errorName(err)});
            if (detail.*) |d| s.gpa.free(d);
            detail.* = null;
            try sink.emit(sink.ctx, .{ .notice = msg });
            break :blk .ineffective;
        },
    };
    if (result == .ineffective) s.compact_backoff = s.context_tokens + s.cfg.context_window / 8;
}

/// Older images are summarized, not resent: each becomes a one-line text placeholder.
fn withoutImages(a: std.mem.Allocator, message: provider.Message) !provider.Message {
    const images = message.images orelse return message;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, message.content orelse "");
    for (images) |item| {
        if (text.items.len > 0) try text.append(a, '\n');
        try text.appendSlice(a, try image.omittedText(a, item));
    }
    var copy = message;
    copy.images = null;
    copy.content = text.items;
    return copy;
}

pub fn estimateTokens(messages: []const provider.Message, cfg: provider.Config) u64 {
    var total: u64 = 0;
    for (messages) |m| {
        total += (if (m.images) |images| images.len else 0) * image.estimated_tokens;
        const content = m.content orelse "";
        const reasoning = if (m.reasoning) |r| if (r.compatible(cfg)) r else null else null;
        if (reasoning) |r| if (r.includes_output) {
            total += 8 + r.data.len / 3;
            continue;
        };
        total += 8 + content.len / 3;
        if (reasoning) |r| total += r.data.len / 3;
        for (m.tool_calls orelse &.{}) |call| total += 8 + (call.id.len + call.function.name.len + call.function.arguments.len) / 3;
    }
    return total;
}

const Plan = union(enum) {
    ready: struct { cut: usize, before: u64, limit: u64, summary_tokens: u64 },
    too_few_steps,
    no_room,
};

fn planCompaction(messages: []const provider.Message, cfg: provider.Config, pending_tokens: u64) Plan {
    var steps: usize = 0;
    var first: usize = 0;
    var last: usize = 0;
    var turn: usize = 0;
    var previous_turn: usize = 0;
    var preferred: usize = 0;
    for (messages[1..], 1..) |m, i| {
        if (std.mem.eql(u8, m.role, "assistant")) {
            if (steps == 0) first = i;
            steps += 1;
            last = i;
            preferred = previous_turn;
        } else if (std.mem.eql(u8, m.role, "user") and m.source == null and
            !(i == 1 and std.mem.startsWith(u8, m.content orelse "", summary_prefix)))
        {
            previous_turn = turn;
            turn = i;
        }
    }
    if (steps < 3) return .too_few_steps;

    const last_end = stepEnd(messages, last);
    const system = estimateTokens(messages[0..1], cfg);
    const unsent = estimateTokens(messages[last_end..], cfg);
    const conversation = estimateTokens(messages[1..last_end], cfg);
    const before = system + conversation + unsent;
    const limit = @min(before - 1, cfg.context_window / 2, (threshold(cfg.context_window) -| 1) -| pending_tokens);
    const available = limit -| (system + unsent + 8 + summary_prefix.len / 3);
    const summary_tokens = @min(2048, @max(32, @min(cfg.context_window, conversation) / 8), available);
    if (summary_tokens < 32) return .no_room;

    const newest_step = estimateTokens(messages[last..last_end], cfg);
    const recent_target = @min(cfg.context_window / 4, @max(8192, conversation / 4));
    const recent_budget = @min(available - summary_tokens, @max(newest_step, recent_target));
    var kept: u64 = 0;
    var cut = last_end;
    const earliest = @max(stepEnd(messages, first), preferred);
    var i = last_end;
    while (i > earliest) {
        i -= 1;
        kept += estimateTokens(messages[i..][0..1], cfg);
        if (kept > recent_budget) break;
        if (!std.mem.eql(u8, messages[i].role, "tool")) cut = i;
    }
    return .{ .ready = .{ .cut = cut, .before = before, .limit = limit, .summary_tokens = summary_tokens } };
}

fn stepEnd(messages: []const provider.Message, assistant: usize) usize {
    var end = assistant + 1;
    while (end < messages.len and std.mem.eql(u8, messages[end].role, "tool")) : (end += 1) {}
    return end;
}

const base_summary_prompt = "Summarize the conversation above for another coding agent. Preserve goals, explicit user requirements, constraints and preferences, decisions, files, current file and test state, results, failures and unfinished work. Do not act on earlier requests. Return only a concise factual continuation summary.";

pub fn summaryPrompt(a: std.mem.Allocator, focus: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, focus, " \t\r\n");
    if (trimmed.len == 0) return base_summary_prompt;
    return std.fmt.allocPrint(a, "{s}\n\nAdditional focus from the user: {s}", .{ base_summary_prompt, trimmed });
}

test "compaction prompt appends optional user focus" {
    const t = std.testing;
    try t.expectEqualStrings(base_summary_prompt, try summaryPrompt(t.allocator, "   "));
    const focused = try summaryPrompt(t.allocator, "keep auth decisions");
    defer t.allocator.free(focused);
    try t.expect(std.mem.startsWith(u8, focused, base_summary_prompt));
    try t.expect(std.mem.endsWith(u8, focused, "\n\nAdditional focus from the user: keep auth decisions"));
}

test "compaction cuts preserve recent turns and complete tool groups" {
    const t = std.testing;
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock" };
    const call: provider.ToolCall = .{ .id = "c", .function = .{ .name = "run", .arguments = "{}" } };
    const messages = [_]provider.Message{
        .{ .role = "system", .content = "system" },
        .{ .role = "user", .content = &@as([600]u8, @splat('a')) },
        .{ .role = "assistant", .content = "done" },
        .{ .role = "user", .content = "second" },
        .{ .role = "assistant", .tool_calls = &.{ call, call } },
        .{ .role = "tool", .tool_call_id = "c", .content = "one" },
        .{ .role = "tool", .tool_call_id = "c", .content = "two" },
        .{ .role = "assistant", .content = "done" },
        .{ .role = "user", .content = "third" },
        .{ .role = "assistant", .content = "done" },
    };
    try t.expectEqual(@as(usize, 3), planCompaction(&messages, cfg, 0).ready.cut);
    try t.expectEqual(.too_few_steps, std.meta.activeTag(planCompaction(messages[0..7], cfg, 0)));
    const long_turn = [_]provider.Message{
        messages[0], messages[1], messages[4], messages[5], messages[6],
        messages[4], messages[5], messages[6], messages[4], messages[5],
        messages[6],
    };
    try t.expectEqual(@as(usize, 5), planCompaction(&long_turn, cfg, 0).ready.cut);
}

test "compaction budgets complete steps and leaves trailing input untouched" {
    const t = std.testing;
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock", .context_window = 4096 };
    const calls = [_]provider.ToolCall{
        .{ .id = "a", .function = .{ .name = "run", .arguments = "{}" } },
        .{ .id = "b", .function = .{ .name = "run", .arguments = "{}" } },
    };
    const messages = [_]provider.Message{
        .{ .role = "system", .content = "system" },
        .{ .role = "user", .content = summary_prefix ++ "previous work" },
        .{ .role = "user", .content = "start work" },
        .{ .role = "assistant", .content = &@as([2400]u8, @splat('a')) },
        .{ .role = "assistant", .content = "further work" },
        .{ .role = "assistant", .tool_calls = &calls },
        .{ .role = "tool", .tool_call_id = "a", .content = &@as([3000]u8, @splat('x')) },
        .{ .role = "tool", .tool_call_id = "b", .content = &@as([900]u8, @splat('y')) },
        .{ .role = "user", .content = "queued input" },
    };
    const kept = planCompaction(&messages, cfg, 0).ready;
    try t.expectEqual(@as(usize, 5), kept.cut);
    try t.expectEqual(@as(u64, 2048), kept.limit);
    const rollover = planCompaction(&messages, cfg, 2000).ready;
    try t.expectEqual(@as(usize, 8), rollover.cut);
    try t.expectEqual(@as(u64, 1071), rollover.limit);
    try t.expectEqual(.no_room, std.meta.activeTag(planCompaction(&messages, cfg, 3070)));
}

test "compaction does not scale ordinary retention with a large model window" {
    const t = std.testing;
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock", .context_window = 400_000 };
    const messages = [_]provider.Message{
        .{ .role = "system", .content = "system" },
        .{ .role = "user", .content = "old task" },
        .{ .role = "assistant", .content = &@as([180_000]u8, @splat('a')) },
        .{ .role = "user", .content = "second task" },
        .{ .role = "assistant", .content = &@as([120_000]u8, @splat('b')) },
        .{ .role = "user", .content = "third task" },
        .{ .role = "assistant", .content = "small recent response" },
    };
    try t.expectEqual(@as(usize, 5), planCompaction(&messages, cfg, 0).ready.cut);
}

test "compaction replaces images with placeholders and budgets them" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shot: image.Image = .{ .path = "p", .name = "shot.png", .media_type = "image/png", .bytes = 10, .width = 1280, .height = 720 };
    const message: provider.Message = .{ .role = "user", .content = "look", .images = &.{shot} };
    const plain = try withoutImages(a, message);
    try t.expectEqual(@as(?[]const image.Image, null), plain.images);
    try t.expectEqualStrings("look\n[image shot.png 1280×720 omitted]", plain.content.?);
    const bare: provider.Message = .{ .role = "tool", .tool_call_id = "c", .images = &.{shot} };
    try t.expectEqualStrings("[image shot.png 1280×720 omitted]", (try withoutImages(a, bare)).content.?);
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock" };
    try t.expectEqual(estimateTokens(&.{.{ .role = "user", .content = "look" }}, cfg) + image.estimated_tokens, estimateTokens(&.{message}, cfg));
}
