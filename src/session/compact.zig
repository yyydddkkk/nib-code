const std = @import("std");
const provider = @import("../provider.zig");
const image = @import("../image.zig");
const Session = @import("../session.zig").Session;
const Sink = @import("../session.zig").Sink;

pub const Compaction = enum { compacted, too_few_steps, ineffective };

pub fn compact(s: *Session, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !Compaction {
    const cut = compactionCut(s.history.items, s.cfg);
    if (cut <= 1) {
        try sink.emit(sink.ctx, .{ .notice = "compaction skipped: fewer than three complete Steps" });
        return .too_few_steps;
    }
    s.codex_state.clearPrevious(s.gpa);
    s.codex_state.reset_reason = "compaction";
    defer s.codex_state.clearPrevious(s.gpa);
    const a = s.arena.allocator();
    var request: std.ArrayList(provider.Message) = .empty;
    defer request.deinit(s.gpa);
    for (s.history.items[0..cut]) |m| try request.append(s.gpa, try withoutImages(a, m));
    try request.append(s.gpa, .{ .role = "user", .content = "Summarize the conversation above for another coding agent. Preserve goals, explicit user requirements, constraints and preferences, decisions, files, current file and test state, results, failures and unfinished work. Do not act on earlier requests. Return only a concise factual continuation summary." });
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
        break :request_model try provider.complete(s.gpa, a, s.client, cfg, s.cache_key, request.items, "[]", @intCast(@min(2048, @max(32, s.cfg.context_window / 8))), .{ .ctx = &observer, .onDelta = Silent.delta, .replay_safe = true, .codex_state = &s.codex_state }, cancel, detail, &attempts, null);
    };
    s.usage.add(reply.usage);
    try sink.emit(sink.ctx, .{ .usage = s.usage });
    if (cancel.load(.acquire)) return error.Canceled;
    if (reply.text.len == 0 or reply.tool_calls.len != 0) return error.InvalidSummary;
    var replacement: std.ArrayList(provider.Message) = .empty;
    defer replacement.deinit(s.gpa);
    try replacement.append(s.gpa, .{ .role = "user", .content = try std.fmt.allocPrint(a, "Earlier session summary:\n{s}", .{reply.text}) });
    try replacement.appendSlice(s.gpa, s.history.items[cut..]);
    const before = s.context_tokens;
    const after = estimateTokens(s.history.items[0..1], s.cfg) + estimateTokens(replacement.items, s.cfg);
    if (after >= estimateTokens(s.history.items, s.cfg) or after > s.cfg.context_window / 2) {
        try sink.emit(sink.ctx, .{ .notice = "compaction skipped: it would not bring context below half the window (retained Steps or system prompt are too large)" });
        return .ineffective;
    }
    const old_len = s.history.items.len;
    try s.commit(1, replacement.items, after, null);
    try sink.emit(sink.ctx, .{ .usage = s.usage });
    const message = try std.fmt.allocPrint(a, "compacted context: {d} → {d} messages, ~{d} → ~{d} tokens", .{ old_len, s.history.items.len, before, after });
    try sink.emit(sink.ctx, .{ .notice = message });
    return .compacted;
}

pub fn autoCompact(s: *Session, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
    const result = s.compact(sink, cancel, detail) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => blk: {
            const msg = try std.fmt.allocPrint(s.arena.allocator(), "automatic compaction failed, continuing without it: {s}", .{detail.* orelse @errorName(err)});
            if (detail.*) |d| s.gpa.free(d);
            detail.* = null;
            try sink.emit(sink.ctx, .{ .notice = msg });
            break :blk .ineffective;
        },
    };
    // Only a spent summary request backs off; too_few_steps resolves itself a Step later.
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

fn compactionCut(messages: []const provider.Message, cfg: provider.Config) usize {
    var turns: usize = 0;
    var cut: usize = 1;
    var i = messages.len;
    while (i > 1) {
        i -= 1;
        if (std.mem.eql(u8, messages[i].role, "user") and messages[i].source == null) {
            turns += 1;
            if (turns == 2) {
                cut = i;
                break;
            }
        }
    }
    if (cut > 1 and estimateTokens(messages[cut..], cfg) <= cfg.context_window / 4) return cut;
    var steps: usize = 0;
    i = messages.len;
    while (i > 1) {
        i -= 1;
        const m = messages[i];
        if (!std.mem.eql(u8, m.role, "assistant")) continue;
        steps += 1;
        const calls = m.tool_calls orelse &.{};
        if (steps == 3) return i + 1 + calls.len;
    }
    return 1;
}

test "compaction cuts preserve recent turns and complete tool groups" {
    const t = std.testing;
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock" };
    const call: provider.ToolCall = .{ .id = "c", .function = .{ .name = "run", .arguments = "{}" } };
    const messages = [_]provider.Message{
        .{ .role = "system", .content = "system" },
        .{ .role = "user", .content = "first" },
        .{ .role = "assistant", .content = "done" },
        .{ .role = "user", .content = "second" },
        .{ .role = "assistant", .tool_calls = &.{ call, call } },
        .{ .role = "tool", .tool_call_id = "c", .content = "one" },
        .{ .role = "tool", .tool_call_id = "c", .content = "two" },
        .{ .role = "assistant", .content = "done" },
        .{ .role = "user", .content = "third" },
        .{ .role = "assistant", .content = "done" },
    };
    try t.expectEqual(@as(usize, 3), compactionCut(&messages, cfg));
    var small = cfg;
    small.context_window = 64;
    try t.expectEqual(@as(usize, 7), compactionCut(&messages, small));
    try t.expectEqual(@as(usize, 1), compactionCut(messages[0..7], small));
    const long_turn = [_]provider.Message{
        messages[0], messages[1], messages[4], messages[5], messages[6],
        messages[4], messages[5], messages[6], messages[4], messages[5],
        messages[6],
    };
    try t.expectEqual(@as(usize, 5), compactionCut(&long_turn, cfg));
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
