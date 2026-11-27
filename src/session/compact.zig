const std = @import("std");
const provider = @import("../provider.zig");
const image = @import("../image.zig");
const output = @import("output.zig");
const tool_tokens = @import("prompt.zig").tools_json.len / 3;
const summary_prefix = "Earlier session summary:\n";
const Session = @import("../session.zig").Session;
const Sink = @import("../session.zig").Sink;

pub const Compaction = enum { compacted, too_few_steps, ineffective };

pub fn threshold(window: u64) u64 {
    return window - window / 4;
}

pub fn compact(s: *Session, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !Compaction {
    return compactWithFocus(s, "", sink, cancel, detail);
}

pub fn compactWithFocus(s: *Session, focus: []const u8, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !Compaction {
    return compactWithPending(s, focus, &.{}, 0, sink, cancel, detail);
}

fn compactWithPending(s: *Session, focus: []const u8, pending: []const provider.Message, pending_tokens: u64, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !Compaction {
    const a = s.arena.allocator();
    const history = s.history.items;
    var scratch: std.heap.ArenaAllocator = .init(s.gpa);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    const directory = try s.tools.outputsDir(temporary);
    const save: ?output.Save = if (directory) |dir| .{
        .io = s.io,
        .dir = if (std.fs.path.isAbsolute(dir)) dir else try @import("../tools.zig").normalizedPath(s.io, temporary, dir),
        .write = false,
    } else null;
    const plan = switch (try planHistory(temporary, history, pending, pending_tokens, s.cfg, save)) {
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
    var request: std.ArrayList(provider.Message) = .empty;
    defer request.deinit(s.gpa);
    for (history[0..plan.cut]) |m| try request.append(s.gpa, try withoutImages(temporary, m));
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
        break :request_model try provider.complete(s.gpa, a, s.client, cfg, s.cache_key, request.items, "[]", plan.summary_tokens, .{ .ctx = &observer, .onDelta = Silent.delta, .replay_safe = true, .codex_state = &s.codex_state }, cancel, detail, &attempts, null);
    };
    s.usage.add(reply.usage);
    try sink.emit(sink.ctx, .{ .usage = s.usage });
    if (cancel.load(.acquire)) return error.Canceled;
    const summary = std.mem.trim(u8, reply.text, " \t\r\n");
    if (summary.len == 0 or reply.tool_calls.len != 0) return error.InvalidSummary;
    const replacement = try plan.prepare(a, temporary, history, summary, s.cfg) orelse {
        try sink.emit(sink.ctx, .{ .notice = "compaction skipped: the summary would exceed the context budget" });
        return .ineffective;
    };
    const old_len = history.len;
    try replacement.publish(s, cancel);
    s.compact_backoff = 0;
    try sink.emit(sink.ctx, .{ .usage = s.usage });
    const message = try std.fmt.allocPrint(a, "compacted context: {d} → {d} messages, ~{d} → ~{d} tokens", .{ old_len, s.history.items.len, plan.before, replacement.tokens });
    try sink.emit(sink.ctx, .{ .notice = message });
    return .compacted;
}

pub fn autoCompact(s: *Session, pending: []const provider.Message, pending_tokens: u64, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
    const result = compactWithPending(s, "", pending, pending_tokens, sink, cancel, detail) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => blk: {
            const msg = try std.fmt.allocPrint(s.arena.allocator(), "automatic compaction failed, continuing without it: {s}", .{detail.* orelse @errorName(err)});
            if (detail.*) |d| s.gpa.free(d);
            detail.* = null;
            try sink.emit(sink.ctx, .{ .notice = msg });
            break :blk .ineffective;
        },
    };
    if (result == .ineffective) s.compact_backoff = s.context_tokens +| pending_tokens +| s.cfg.context_window / 8;
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

fn summaryBudget(window: u64) u32 {
    return @intCast(@min(2048, @max(32, window / 8)));
}

const Replacement = struct {
    messages: []const provider.Message,
    tokens: u64,
    evidence: []const []const u8,
    save: ?output.Save,

    fn publish(replacement: Replacement, s: *Session, cancel: *const std.atomic.Value(bool)) !void {
        if (replacement.save) |target| {
            var save = target;
            save.write = true;
            for (replacement.evidence) |text| {
                if (cancel.load(.acquire)) return error.Canceled;
                const reference = try output.saveRecordedOutput(s.gpa, save, text);
                s.gpa.free(reference);
            }
        }
        if (cancel.load(.acquire)) return error.Canceled;
        try s.commit(1, replacement.messages, replacement.tokens, null);
    }
};

const ArchivedResult = struct {
    tail_index: usize,
    original: []const u8,
};

const Retention = struct {
    cut: usize,
    last_end: usize,
    before: u64,
    limit: u64,
    summary_tokens: u32,
    pinned: ?usize,
    tail: []const provider.Message,
    archives: []const ArchivedResult,
    save: ?output.Save,

    // Only the message array and evidence list may borrow the scratch arena.
    fn prepare(plan: Retention, a: std.mem.Allocator, scratch: std.mem.Allocator, history: []const provider.Message, summary: []const u8, cfg: provider.Config) !?Replacement {
        var messages: std.ArrayList(provider.Message) = .empty;
        var evidence: std.ArrayList([]const u8) = .empty;
        try messages.append(scratch, .{ .role = "user", .content = try std.mem.concat(a, u8, &.{ summary_prefix, summary }) });
        if (plan.pinned) |i| if (i < plan.cut) try messages.append(scratch, history[i]);
        const tail_base = messages.items.len;
        try messages.appendSlice(scratch, plan.tail);
        try messages.appendSlice(scratch, history[plan.last_end..]);
        var tokens = estimateTokens(history[0..1], cfg) + estimateTokens(messages.items, cfg);
        if (tokens > plan.limit) return null;

        if (plan.save != null and plan.cut == plan.last_end) {
            var buffer: [3][]const u8 = undefined;
            const recent = recentEvidence(history, plan.cut, &buffer);
            if (recent.len != 0) {
                const handoff = try handoffText(scratch, messages.items[0].content.?, recent, plan.save.?);
                const delta = handoff.len / 3 - messages.items[0].content.?.len / 3;
                if (delta <= plan.limit - tokens) {
                    try evidence.appendSlice(scratch, recent);
                    messages.items[0].content = try a.dupe(u8, handoff);
                    tokens += delta;
                }
            }
        }

        for (plan.archives) |archive| {
            try evidence.append(scratch, archive.original);
            const message = &messages.items[tail_base + archive.tail_index];
            message.content = try a.dupe(u8, message.content.?);
        }
        return .{ .messages = messages.items, .tokens = tokens, .evidence = evidence.items, .save = plan.save };
    }
};

const Plan = union(enum) {
    ready: Retention,
    too_few_steps,
    no_room,
};

fn isUserRequest(message: provider.Message) bool {
    return std.mem.eql(u8, message.role, "user") and message.source == null;
}

fn latestUser(messages: []const provider.Message, first: usize) ?usize {
    var i = messages.len;
    while (i > first) {
        i -= 1;
        if (isUserRequest(messages[i])) return i;
    }
    return null;
}

fn planHistory(a: std.mem.Allocator, history: []const provider.Message, pending: []const provider.Message, pending_tokens: u64, cfg: provider.Config, save: ?output.Save) !Plan {
    if (history.len <= 1) return .too_few_steps;
    const first: usize = if (isUserRequest(history[1]) and std.mem.startsWith(u8, history[1].content orelse "", summary_prefix)) 2 else 1;
    var steps: usize = 0;
    var floor: usize = first;
    var last_end: usize = first;
    for (history[first..], first..) |message, i| {
        if (!std.mem.eql(u8, message.role, "assistant")) continue;
        const calls = message.tool_calls orelse &.{};
        last_end = i + 1 + calls.len;
        if (steps == 0) floor = last_end;
        steps += 1;
    }
    if (steps < 3) return .too_few_steps;

    const trailing = history[last_end..];
    const pinned = if (latestUser(pending, 0) == null and latestUser(trailing, 0) == null) latestUser(history[0..last_end], first) else null;
    const pinned_tokens = if (pinned) |i| estimateTokens(history[i..][0..1], cfg) else 0;
    const system = estimateTokens(history[0..1], cfg);
    const conversation = estimateTokens(history[1..last_end], cfg);
    const trailing_tokens = estimateTokens(trailing, cfg);
    const before = system + conversation + trailing_tokens;
    const limit = @min(before - 1, cfg.context_window / 2, (threshold(cfg.context_window) -| 1) -| pending_tokens);
    const available = limit -| (system + trailing_tokens + pinned_tokens + 16);
    const summary_tokens: u32 = @intCast(@min(summaryBudget(@min(cfg.context_window, conversation)), available));
    if (summary_tokens < 32) return .no_room;

    const fixed = system + tool_tokens + trailing_tokens + pinned_tokens + summary_tokens + 16 + pending_tokens;
    const goal = cfg.context_window / 10;
    // Leave a small working tail when fixed input alone makes the soft target unattainable.
    const recent_target = if (fixed < goal) goal - fixed else 2048;
    var remaining: u64 = @min(16_384, recent_target, available - summary_tokens);
    const tail = try a.dupe(provider.Message, history[floor..last_end]);
    var archives: std.ArrayList(ArchivedResult) = .empty;
    var start = last_end;
    var i = start;
    while (i > floor) {
        i -= 1;
        if (std.mem.eql(u8, history[i].role, "tool")) continue;
        const group = tail[i - floor .. start - floor];
        const credit = if (pinned == i) pinned_tokens else 0;
        var cost = estimateTokens(group, cfg) -| credit;
        const prior = archives.items.len;
        if (cost > remaining) if (save) |target| {
            for (group, i - floor..) |*message, index| {
                if (!std.mem.eql(u8, message.role, "tool")) continue;
                const text = message.content orelse continue;
                if (!archivable(text)) continue;
                const preview = try archivePreview(a, target, text);
                if (preview.len >= text.len) continue;
                message.content = preview;
                try archives.append(a, .{ .tail_index = index, .original = text });
            }
            cost = estimateTokens(group, cfg) -| credit;
        };
        if (cost > remaining) {
            archives.shrinkRetainingCapacity(prior);
            break;
        }
        remaining -= cost;
        start = i;
    }
    const offset = start - floor;
    for (archives.items) |*entry| entry.tail_index -= offset;
    return .{ .ready = .{
        .cut = start,
        .last_end = last_end,
        .before = before,
        .limit = limit,
        .summary_tokens = summary_tokens,
        .pinned = pinned,
        .tail = tail[offset..],
        .archives = archives.items,
        .save = save,
    } };
}

fn archivable(text: []const u8) bool {
    return text.len >= 2048 and text.len <= output.max_saved_bytes;
}

fn recentEvidence(history: []const provider.Message, cut: usize, buffer: [][]const u8) []const []const u8 {
    var evidence: std.ArrayList([]const u8) = .initBuffer(buffer);
    var i = cut;
    while (i > 1 and evidence.items.len < buffer.len) {
        i -= 1;
        if (!std.mem.eql(u8, history[i].role, "tool")) continue;
        const text = history[i].content orelse continue;
        if (archivable(text)) evidence.appendAssumeCapacity(text);
    }
    return evidence.items;
}

fn handoffText(a: std.mem.Allocator, summary: []const u8, evidence: []const []const u8, save: output.Save) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(a);
    try writer.writer.writeAll(summary);
    try writer.writer.writeAll("\n\nRecent tool results (read as needed with tools.read):");
    for (evidence) |text| {
        const reference = try output.saveRecordedOutput(a, save, text);
        defer a.free(reference);
        try writer.writer.print("\n{s}", .{reference});
    }
    return writer.written();
}

fn archivePreview(a: std.mem.Allocator, target: output.Save, text: []const u8) ![]u8 {
    const reference = try output.saveRecordedOutput(a, target, text);
    var head: usize = 256;
    while (text[head] & 0xc0 == 0x80) head -= 1;
    var tail = text.len - 256;
    while (text[tail] & 0xc0 == 0x80) tail += 1;
    return std.fmt.allocPrint(a, "{s}\n[{d} bytes omitted by compaction; use tools.read to recover the recorded result]\n{s}\n{s}", .{ text[0..head], tail - head, text[tail..], reference });
}

const base_summary_prompt = "Summarize the conversation above as a concise factual handoff for a coding agent continuing this session. If an Earlier session summary is present, update it with the newer history: retain requirements and decisions that still apply, and replace stale status. Preserve the goal, explicit constraints, key files and changes, last test results and failures, live background task IDs, and unfinished work. Keep exact error text and output references when they matter for the next step; omit routine logs. Do not act on earlier requests. Return only the handoff.";

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

test "retention follows the request budget and keeps tool groups intact" {
    const t = std.testing;
    var scratch: std.heap.ArenaAllocator = .init(t.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock", .context_window = 16_384 };
    const call: provider.ToolCall = .{ .id = "c", .function = .{ .name = "run", .arguments = "{}" } };
    const body = &@as([7168]u8, @splat('x'));
    const messages = [_]provider.Message{
        .{ .role = "system", .content = "system" },
        .{ .role = "user", .content = "Earlier session summary:\ncheckpoint" },
        .{ .role = "user", .content = "exact user constraint" },
        .{ .role = "assistant", .content = "old Step" },
        .{ .role = "assistant", .content = "another Step" },
        .{ .role = "assistant", .tool_calls = &.{ call, call } },
        .{ .role = "tool", .tool_call_id = "c", .content = body },
        .{ .role = "tool", .tool_call_id = "c", .content = "short result" },
    };
    const save: output.Save = .{ .io = t.io, .dir = "unused", .write = false };
    const plan = (try planHistory(a, &messages, &.{}, 0, cfg, save)).ready;
    try t.expectEqual(@as(usize, 4), plan.cut);
    try t.expectEqual(@as(?usize, 2), plan.pinned);
    try t.expectEqual(@as(usize, 4), plan.tail.len);
    try t.expectEqual(@as(usize, 1), plan.archives.len);
    try t.expectEqual(@as(usize, 2), plan.archives[0].tail_index);
    try t.expectEqualStrings(body, plan.archives[0].original);
    const replacement = (try plan.prepare(a, a, &messages, "handoff", cfg)).?;
    try t.expectEqual(@as(usize, 1), replacement.evidence.len);
    try t.expectEqualStrings(body, replacement.evidence[0]);
    try t.expect(std.mem.indexOf(u8, plan.tail[2].content.?, "use tools.read") != null);
    try t.expectEqualStrings("short result", plan.tail[3].content.?);
    try t.expectEqualStrings(body, messages[6].content.?);

    const pending: []const provider.Message = &.{.{ .role = "user", .content = &@as([48_000]u8, @splat('x')) }};
    const tight = try planHistory(a, &messages, pending, estimateTokens(pending, cfg), cfg, save);
    try t.expectEqual(.no_room, std.meta.activeTag(tight));
}

test "compaction preserves trailing input and does not pin handoffs or background messages" {
    const t = std.testing;
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock" };
    const history: []const provider.Message = &.{
        .{ .role = "system", .content = "system" },
        .{ .role = "user", .content = "Earlier session summary:\nprior" },
        .{ .role = "assistant", .content = &@as([600]u8, @splat('o')) },
        .{ .role = "assistant", .content = "another complete Step" },
        .{ .role = "assistant", .content = "most recent Step" },
        .{ .role = "user", .source = .background, .content = "b1 finished" },
        .{ .role = "user", .content = "queued input" },
    };
    var scratch: std.heap.ArenaAllocator = .init(t.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const plan = (try planHistory(a, history, &.{}, 0, cfg, null)).ready;
    try t.expectEqual(@as(?usize, null), plan.pinned);
    try t.expectEqual(@as(usize, 3), plan.cut);
    try t.expectEqual(@as(usize, 5), plan.last_end);
    try t.expectEqualStrings("b1 finished", history[plan.last_end].content.?);
    const without_queued = (try planHistory(a, history[0..6], &.{}, 0, cfg, null)).ready;
    try t.expectEqual(@as(?usize, null), without_queued.pinned);
    try t.expectEqual(.too_few_steps, std.meta.activeTag(try planHistory(a, history[0..4], &.{}, 0, cfg, null)));
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

test "compaction only publishes handoff evidence that fits the final budget" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock" };
    const body = &@as([3072]u8, @splat('x'));
    const history: []const provider.Message = &.{
        .{ .role = "system", .content = "system" },
        .{ .role = "tool", .content = body },
    };
    const target: output.Save = .{ .io = t.io, .dir = "unused", .write = false };
    var plan: Retention = .{
        .cut = history.len,
        .last_end = history.len,
        .before = 1024,
        .limit = 1023,
        .summary_tokens = 32,
        .pinned = null,
        .tail = &.{},
        .archives = &.{},
        .save = target,
    };
    const with_reference = (try plan.prepare(a, a, history, "summary", cfg)).?;
    try t.expectEqual(@as(usize, 1), with_reference.evidence.len);
    try t.expectEqualStrings(body, with_reference.evidence[0]);
    try t.expect(std.mem.indexOf(u8, with_reference.messages[0].content.?, "[recorded output:") != null);

    plan.limit = with_reference.tokens - 1;
    const no_reference = (try plan.prepare(a, a, history, "summary", cfg)).?;
    try t.expectEqual(@as(usize, 0), no_reference.evidence.len);
    try t.expectEqualStrings(summary_prefix ++ "summary", no_reference.messages[0].content.?);
    plan.limit = no_reference.tokens - 1;
    try t.expect(try plan.prepare(a, a, history, "summary", cfg) == null);
}

test "compaction leaves the Session log untouched when evidence cannot be saved" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
    defer client.deinit();
    var s = try Session.init(t.allocator, t.io, &client, .{ .base_url = "invalid://local", .api_key = "mock", .model = "mock" }, .{ .home = root, .user_home = root });
    defer s.deinit();
    const log_path = try std.fmt.allocPrint(a, "{s}/sessions/{s}.jsonl", .{ root, s.id });
    const cwd = std.Io.Dir.cwd();
    const before = try cwd.readFileAlloc(t.io, log_path, a, .unlimited);
    const tokens = s.context_tokens;
    const history_len = s.history.items.len;
    const blocked = try std.fs.path.join(a, &.{ log_path, "outputs" });
    const replacement: Replacement = .{
        .messages = &.{.{ .role = "user", .content = "summary" }},
        .tokens = 42,
        .evidence = &.{"exact recorded result"},
        .save = .{ .io = t.io, .dir = blocked, .write = false },
    };
    const cancel: std.atomic.Value(bool) = .init(false);
    if (replacement.publish(&s, &cancel)) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try t.expect(err == error.NotDir or err == error.FileNotFound);
    }
    try t.expectEqual(tokens, s.context_tokens);
    try t.expectEqual(history_len, s.history.items.len);
    try t.expectEqualStrings(before, try cwd.readFileAlloc(t.io, log_path, a, .unlimited));
}
