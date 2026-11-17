const std = @import("std");
const provider = @import("../provider.zig");
const Fork = @import("../tools/agent/input.zig").Fork;

pub fn snapshot(a: std.mem.Allocator, committed: []const provider.Message, pending: []const provider.Message) ![]const provider.Message {
    // Message payloads already belong to the Session arena; only these arrays can move.
    const messages = try a.alloc(provider.Message, committed.len + pending.len);
    @memcpy(messages[0..committed.len], committed);
    @memcpy(messages[committed.len..], pending);
    return messages;
}

pub fn inherit(a: std.mem.Allocator, fork: Fork) ![]const provider.Message {
    if (fork.message_count != fork.history.len or fork.history.len == 0 or
        !std.mem.eql(u8, fork.history[0].role, "system")) return error.InvalidForkHistory;
    var messages: std.ArrayList(provider.Message) = .empty;
    var i: usize = 0;
    while (i < fork.history.len) {
        const message = fork.history[i];
        if (i > 0 and !std.mem.eql(u8, message.role, "user") and
            !std.mem.eql(u8, message.role, "assistant")) return error.InvalidForkHistory;
        try messages.append(a, try clone(a, message));
        i += 1;
        for (message.tool_calls orelse &.{}) |call| {
            if (i < fork.history.len and std.mem.eql(u8, fork.history[i].role, "tool")) {
                const result = fork.history[i];
                if (!std.mem.eql(u8, result.tool_call_id orelse "", call.id)) return error.InvalidForkHistory;
                try messages.append(a, try clone(a, result));
                i += 1;
            } else {
                try messages.append(a, .{
                    .role = "tool",
                    .tool_call_id = try a.dupe(u8, call.id),
                    .content = try std.fmt.allocPrint(a, "[forked as child agent {s} from session {s}; this tool call continues independently in the parent session; its result is not available in this child]", .{ fork.id, fork.session }),
                });
            }
        }
    }
    return messages.toOwnedSlice(a);
}

fn clone(a: std.mem.Allocator, message: provider.Message) !provider.Message {
    var copy = message;
    copy.role = try a.dupe(u8, message.role);
    copy.content = try dupeOptional(a, message.content);
    copy.tool_call_id = try dupeOptional(a, message.tool_call_id);
    copy.phase = try dupeOptional(a, message.phase);
    copy.background_id = try dupeOptional(a, message.background_id);
    if (message.reasoning) |reasoning| copy.reasoning = .{ .provider = reasoning.provider, .data = try a.dupe(u8, reasoning.data), .includes_output = reasoning.includes_output };
    if (message.step_effort) |effort| copy.step_effort = .{ .effort = try a.dupe(u8, effort.effort) };
    if (message.executed_source) |code| copy.executed_source = try a.dupe(u8, code);
    if (message.tool_summary) |summary| copy.tool_summary = try summary.clone(a);
    if (message.images) |images| {
        const copies = try a.alloc(@import("../image.zig").Image, images.len);
        for (images, copies) |image, *copied| copied.* = try image.clone(a);
        copy.images = copies;
    }
    if (message.tool_calls) |calls| {
        const copies = try a.alloc(provider.ToolCall, calls.len);
        for (calls, copies) |call, *copied| copied.* = .{
            .id = try a.dupe(u8, call.id),
            .type = try a.dupe(u8, call.type),
            .function = .{ .name = try a.dupe(u8, call.function.name), .arguments = try a.dupe(u8, call.function.arguments) },
        };
        copy.tool_calls = copies;
    }
    return copy;
}

fn dupeOptional(a: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    return if (text) |value| try a.dupe(u8, value) else null;
}

test "snapshot retains the complete assistant prefix across array reuse" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var committed = [_]provider.Message{.{ .role = "system", .content = try a.dupe(u8, "system bytes") }};
    var pending = [_]provider.Message{
        .{ .role = "user", .content = try a.dupe(u8, "prompt") },
        .{ .role = "assistant", .reasoning = .{ .provider = .codex, .data = try a.dupe(u8, "opaque reasoning") }, .tool_calls = try a.dupe(provider.ToolCall, &.{
            .{ .id = "one", .function = .{ .name = "run", .arguments = "{}" } },
            .{ .id = "two", .function = .{ .name = "run", .arguments = "{}" } },
        }) },
    };
    const prefix = try snapshot(a, &committed, &pending);
    try t.expectEqual(@as(usize, 3), prefix.len);
    try t.expectEqualDeep(pending[1], prefix[2]);
    committed[0] = .{ .role = "system", .content = "replacement" };
    pending[1] = .{ .role = "tool", .content = "Run result", .tool_call_id = "one" };
    try t.expectEqualStrings("system bytes", prefix[0].content.?);
    try t.expectEqualStrings("assistant", prefix[2].role);
    try t.expectEqualStrings("opaque reasoning", prefix[2].reasoning.?.data);
    try t.expectEqual(@as(usize, 2), prefix[2].tool_calls.?.len);
}

test "inherit deep copies messages and completes only unpaired tool calls" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = [_]provider.Message{
        .{ .role = "system", .content = "exact system" },
        .{ .role = "user", .content = "compacted summary", .source = .background, .background_id = "b1", .background_ok = true, .background_kind = .bash },
        .{ .role = "assistant", .content = "launch", .phase = "commentary", .reasoning = .{ .provider = .codex, .data = "opaque reasoning" }, .step_effort = .{ .effort = "high" }, .tool_calls = &.{
            .{ .id = "one", .function = .{ .name = "run", .arguments = "{}" } },
            .{ .id = "two", .function = .{ .name = "run", .arguments = "{}" } },
            .{ .id = "three", .function = .{ .name = "run", .arguments = "{}" } },
        } },
        .{ .role = "tool", .tool_call_id = "one", .content = "real result", .tool_summary = .{ .counts = &.{.{ .name = "read", .count = 1 }} }, .step_calls_omitted = 4 },
    };
    const fork: Fork = .{ .session = "parent", .message_count = original.len, .history = &original, .cache_key = "cache", .id = "a7", .provider = .codex, .model = "mock" };
    const copied = try inherit(a, fork);
    try t.expectEqual(@as(usize, 6), copied.len);
    try t.expectEqualDeep(@as([]const provider.Message, &original), copied[0..original.len]);
    try t.expect(copied[0].content.?.ptr != original[0].content.?.ptr);
    try t.expect(copied[2].tool_calls.?.ptr != original[2].tool_calls.?.ptr);
    try t.expect(copied[2].tool_calls.?[0].function.arguments.ptr != original[2].tool_calls.?[0].function.arguments.ptr);
    try t.expect(copied[2].reasoning.?.data.ptr != original[2].reasoning.?.data.ptr);
    try t.expect(copied[3].tool_summary.?.counts[0].name.ptr != original[3].tool_summary.?.counts[0].name.ptr);
    for (copied[4..], [_][]const u8{ "two", "three" }) |message, id| {
        try t.expectEqualStrings("tool", message.role);
        try t.expectEqualStrings(id, message.tool_call_id.?);
        try t.expect(std.mem.indexOf(u8, message.content.?, "child agent a7") != null);
        try t.expect(std.mem.indexOf(u8, message.content.?, "independently in the parent") != null);
    }
    var invalid = fork;
    invalid.message_count += 1;
    try t.expectError(error.InvalidForkHistory, inherit(a, invalid));
}
