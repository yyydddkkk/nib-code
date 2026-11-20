const std = @import("std");
const provider = @import("../../provider.zig");
const Background = @import("../events.zig").Background;
const Tuning = @import("../tuning.zig").Resolved;
const schema = @import("schema.zig");
const Record = schema.Record;
const AgentSession = schema.AgentSession;
const ForkedFrom = schema.ForkedFrom;
const ResumeAdaptation = schema.ResumeAdaptation;

pub const Restored = struct {
    resume_adaptation: ResumeAdaptation,
    plugin_skills: []const @import("../skills.zig").Skill,
    tuning: Tuning,
    mcp_servers: []const @import("../../mcp/config.zig").Server,
    skills: @import("../skills.zig").Summary,
    needs_repair: bool,
    steps: usize,
    parent_session_id: ?[]const u8,
    cache_key: ?[]const u8,
    forked_from: ?ForkedFrom,
    provider: provider.Id,
    custom_provider: ?[]const u8,
    model: ?[]const u8,
    next_agent_id: u64,
    next_bash_id: u64,
    next_run_id: u64,
    agent_sessions: []const AgentSession,
    lost_background: []const Background,
    background_repairs: []const Background,
    pending_background_bytes: u64,
};

const Pending = struct { event: Background, delivered: bool = false };

fn settleBackground(pending_background: *std.ArrayList(Pending), id: []const u8) void {
    for (pending_background.items, 0..) |pending, i| {
        if (std.mem.eql(u8, pending.event.id, id)) {
            _ = pending_background.orderedRemove(i);
            break;
        }
    }
}

fn restoreToolSummaries(a: std.mem.Allocator, history: []provider.Message, record: Record, replacements: *const std.StringHashMap(@import("../../tools/bash/registry.zig").Event)) !void {
    for (record.run_results orelse &.{}) |result| {
        if (result.background_id == null) continue;
        for (history[record.from..]) |*message| {
            if (std.mem.eql(u8, message.role, "tool") and std.mem.eql(u8, message.tool_call_id orelse "", result.tool_call_id)) message.background_id = result.background_id;
        }
    }
    for (record.messages) |message| {
        const completion = message.background_run orelse continue;
        const id = message.background_id orelse continue;
        for (history) |*origin| {
            if (!std.mem.eql(u8, origin.role, "tool") or !std.mem.eql(u8, origin.background_id orelse "", id)) continue;
            var replaced: std.ArrayList(@import("../../tools/bash/registry.zig").Event) = .empty;
            for (completion.calls) |call| {
                if (replacements.get(call.id orelse "")) |event| try replaced.append(a, event);
            }
            if (replaced.items.len > 0) origin.bash_replacements = try replaced.toOwnedSlice(a);
        }
    }
    const calls = record.calls orelse return;
    for (record.messages, record.from..) |assistant, message_index| {
        const runs = assistant.tool_calls orelse continue;
        var unassigned = record.calls_omitted orelse 0;
        for (record.run_results orelse &.{}) |result| {
            if (result.calls_omitted) |omitted| unassigned -|= omitted;
        }
        if (runs.len > 1 and unassigned > 0) history[message_index].step_calls_omitted = unassigned;
        for (runs, 0..) |run, run_index| {
            var omitted: u64 = if (runs.len == 1) record.calls_omitted orelse 0 else 0;
            for (record.run_results orelse &.{}) |result| {
                if (std.mem.eql(u8, result.tool_call_id, run.id)) {
                    omitted = result.calls_omitted orelse omitted;
                    break;
                }
            }
            for (history[record.from..]) |*message| {
                if (std.mem.eql(u8, message.role, "tool") and std.mem.eql(u8, message.tool_call_id orelse "", run.id)) {
                    var replaced: std.ArrayList(@import("../../tools/bash/registry.zig").Event) = .empty;
                    for (calls) |call| {
                        if (call.run_index != run_index) continue;
                        if (replacements.get(call.id orelse "")) |event| try replaced.append(a, event);
                    }
                    if (replaced.items.len > 0) message.bash_replacements = try replaced.toOwnedSlice(a);
                    message.tool_summary = try @import("../tool_summary.zig").Summary.init(a, calls, run_index, omitted);
                    if (message.images) |images| try message.tool_summary.?.annotateViews(a, images);
                    break;
                }
            }
        }
    }
}

pub fn replay(gpa: std.mem.Allocator, a: std.mem.Allocator, data: []const u8, history: *std.ArrayList(provider.Message), tokens: *u64) !Restored {
    var resume_adaptation: ResumeAdaptation = .{};
    var parent_session_id: ?[]const u8 = null;
    var mcp_servers: []const @import("../../mcp/config.zig").Server = &.{};
    var skills: @import("../skills.zig").Summary = .{};
    var plugin_skills: []const @import("../skills.zig").Skill = &.{};
    var cache_key: ?[]const u8 = null;
    var tuning: Tuning = .{};
    var forked_from: ?ForkedFrom = null;
    var next_agent_id: u64 = 1;
    var next_bash_id: u64 = 1;
    var next_run_id: u64 = 1;
    var pending_background_bytes: u64 = 0;
    var agent_sessions: std.ArrayList(AgentSession) = .empty;
    defer agent_sessions.deinit(a);
    var pending_background: std.ArrayList(Pending) = .empty;
    defer pending_background.deinit(a);
    var id: provider.Id = .chat_completions;
    var custom_provider: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var replacements: std.StringHashMap(@import("../../tools/bash/registry.zig").Event) = .init(gpa);
    defer replacements.deinit();
    var lines = std.mem.splitScalar(u8, data, '\n');
    var torn = false;
    var steps: usize = 0;
    while (lines.next()) |line| {
        if (lines.peek() == null) break;
        if (line.len == 0) continue;
        const r = schema.parseRecord(a, line) catch |err| {
            if (err == error.OutOfMemory) return err;
            torn = true;
            continue;
        };
        if (r.hook != null or r.source != null) continue;
        if (history.items.len == 0 or (steps == 0 and r.from == 0 and r.provider != null)) {
            parent_session_id = r.parent_session_id;
            skills = r.skills orelse .{};
            mcp_servers = r.mcp_servers orelse &.{};
            plugin_skills = r.plugin_skills orelse &.{};
            cache_key = r.cache_key;
            tuning = if (r.tuning) |record| Tuning.fromLog(record) else .{};
            forked_from = r.forked_from;
            // A fork header labels the child runtime, not the inherited system text.
            resume_adaptation = .{
                .header_model = r.model,
                .family = if (r.forked_from == null) r.family else null,
                .profile = if (r.forked_from == null) r.profile else null,
            };
            id = r.provider orelse .chat_completions;
            custom_provider = r.custom_provider;
        }
        if (r.model) |m| model = m;
        if (r.repair) {
            torn = false;
            continue;
        }
        if (torn) return error.InvalidSessionLog;
        for (r.calls orelse &.{}) |call| if (call.id) |call_id| {
            try restoreId(call_id, &next_agent_id, &next_bash_id, &next_run_id);
        };
        if (r.task_ids) |ids| {
            next_agent_id = @max(next_agent_id, std.math.add(u64, ids.agent, 1) catch return error.InvalidSessionLog);
            next_bash_id = @max(next_bash_id, std.math.add(u64, ids.bash, 1) catch return error.InvalidSessionLog);
            next_run_id = @max(next_run_id, std.math.add(u64, ids.run, 1) catch return error.InvalidSessionLog);
        }
        if (r.agent_session) |mapping| {
            try restoreId(mapping.id, &next_agent_id, &next_bash_id, &next_run_id);
            try agent_sessions.append(a, mapping);
            continue;
        }
        if (r.background) |b| {
            try restoreId(b.id, &next_agent_id, &next_bash_id, &next_run_id);
            if (b.state == .started) {
                try pending_background.append(a, .{ .event = b });
            } else {
                settleBackground(&pending_background, b.id);
            }
            continue;
        }
        if (r.deliveries == null) for (r.messages) |m| {
            if (m.source != .background) continue;
            if (m.background_id) |background_id| {
                for (pending_background.items) |*pending| {
                    if (!pending.delivered and std.mem.eql(u8, pending.event.id, background_id)) {
                        pending.delivered = true;
                        // Finished deliveries carry ok; lost deliveries leave it null.
                        pending.event = .{ .id = pending.event.id, .kind = pending.event.kind, .state = if (m.background_ok != null) .finished else .lost, .ok = m.background_ok };
                        break;
                    }
                }
            }
        };
        if (r.bash) |event| {
            if (event.superseded_by != null) try replacements.put(event.id, event);
            try restoreId(event.id, &next_agent_id, &next_bash_id, &next_run_id);
            continue;
        }
        if (r.task_stop != null or r.sandbox_unavailable != null) continue;
        if (r.diagnostic != null or (r.transport_fallback != null and r.messages.len == 0)) continue;
        if (r.from > history.items.len) return error.InvalidSessionLog;
        try history.ensureTotalCapacity(gpa, r.from + r.messages.len);
        if (r.from == history.items.len and r.forked_from == null) {
            steps += schema.assistantCount(r.messages);
            for (r.deliveries orelse &.{}) |delivery| {
                try restoreId(delivery.event.id, &next_agent_id, &next_bash_id, &next_run_id);
                settleBackground(&pending_background, delivery.event.id);
            }
            pending_background_bytes = schema.pendingBytes(pending_background_bytes, r);
        }
        schema.apply(history, r);
        try restoreToolSummaries(a, history.items, r, &replacements);
        try validate(history.items);
        tokens.* = r.context_tokens;
    }
    if (history.items.len == 0) return error.InvalidSessionLog;
    var lost_background: std.ArrayList(Background) = .empty;
    defer lost_background.deinit(a);
    var background_repairs: std.ArrayList(Background) = .empty;
    defer background_repairs.deinit(a);
    for (pending_background.items) |pending| {
        if (pending.delivered) {
            try background_repairs.append(a, pending.event);
        } else try lost_background.append(a, pending.event);
    }
    return .{
        .resume_adaptation = resume_adaptation,
        .tuning = tuning,
        .mcp_servers = mcp_servers,
        .plugin_skills = plugin_skills,
        .skills = skills,
        .steps = steps,
        .needs_repair = torn or data[data.len - 1] != '\n',
        .parent_session_id = parent_session_id,
        .cache_key = cache_key,
        .forked_from = forked_from,
        .provider = id,
        .custom_provider = custom_provider,
        .model = model,
        .next_agent_id = next_agent_id,
        .next_bash_id = next_bash_id,
        .next_run_id = next_run_id,
        .agent_sessions = try agent_sessions.toOwnedSlice(a),
        .lost_background = try lost_background.toOwnedSlice(a),
        .background_repairs = try background_repairs.toOwnedSlice(a),
        .pending_background_bytes = pending_background_bytes,
    };
}

fn restoreId(id: []const u8, next_agent: *u64, next_bash: *u64, next_run: *u64) !void {
    if (id.len < 2 or (id[0] != 'a' and id[0] != 'b' and id[0] != 'r')) return;
    const number = std.fmt.parseInt(u64, id[1..], 10) catch return error.InvalidSessionLog;
    const next = if (id[0] == 'a') next_agent else if (id[0] == 'b') next_bash else next_run;
    next.* = @max(next.*, std.math.add(u64, number, 1) catch return error.InvalidSessionLog);
}

fn validate(messages: []const provider.Message) !void {
    if (messages.len == 0 or !std.mem.eql(u8, messages[0].role, "system")) return error.InvalidSessionLog;
    var i: usize = 1;
    while (i < messages.len) : (i += 1) {
        const m = messages[i];
        if (std.mem.eql(u8, m.role, "user")) continue;
        if (!std.mem.eql(u8, m.role, "assistant")) return error.InvalidSessionLog;
        for (m.tool_calls orelse &.{}) |call| {
            i += 1;
            if (i >= messages.len or !std.mem.eql(u8, messages[i].role, "tool") or
                !std.mem.eql(u8, messages[i].tool_call_id orelse "", call.id)) return error.InvalidSessionLog;
        }
    }
}

test "replay rejects dangling tool calls and unrepaired interior corruption" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    const header = "{\"messages\":[{\"role\":\"system\",\"content\":\"base\"}]}\n";
    const dangling = header ++ "{\"from\":1,\"messages\":[{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"c\",\"function\":{\"name\":\"run\",\"arguments\":\"{}\"}}]}]}\n";
    try t.expectError(error.InvalidSessionLog, replay(a, a, dangling, &history, &tokens));
    history.clearRetainingCapacity();
    const corrupt = header ++ "broken\n{\"from\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}\n";
    try t.expectError(error.InvalidSessionLog, replay(a, a, corrupt, &history, &tokens));
}

test "legacy chat reasoning is migrated without changing provider identity" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var history: std.ArrayList(provider.Message) = .empty;
    defer history.deinit(t.allocator);
    var tokens: u64 = 0;
    try t.expectEqual(@as(?i64, null), (try schema.parseRecord(arena.allocator(), "{}")).at);
    try t.expectEqual(@as(?i64, null), (try schema.parseRecord(arena.allocator(), "{\"at\":null}")).at);
    const result = try replay(t.allocator, arena.allocator(),
        \\{"from":0,"messages":[{"role":"system","content":"s"}]}
        \\{"from":1,"messages":[{"role":"user","content":"u"},{"role":"assistant","content":"a","reasoning_content":"legacy"}]}
        \\
    , &history, &tokens);
    try t.expectEqual(provider.Id.chat_completions, result.provider);
    try t.expectEqualDeep(provider.Reasoning{ .provider = .chat_completions, .data = "legacy" }, history.items[2].reasoning.?);
}

test "timing fields are optional and replay preserves mixed old and measured Steps" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const legacy = try schema.parseRecord(a,
        \\{"from":1,"messages":[{"role":"assistant","content":"old"}],"ms":10,"run_results":[]}
    );
    try t.expectEqual(@as(?u64, null), legacy.model_ms);
    try t.expect(legacy.tool_bytes == null and legacy.output_bytes == null);
    try t.expectEqual(@as(?u32, null), legacy.attempts);
    try t.expectEqual(@as(?u64, null), legacy.first_data_ms);
    try t.expectEqual(@as(?u64, null), legacy.max_gap_ms);
    try t.expect(legacy.code == null and legacy.calls == null and legacy.run_ms == null and legacy.calls_omitted == null);
    const measured: Record = .{
        .from = 2,
        .messages = &.{.{ .role = "assistant", .content = "new" }},
        .context_tokens = 99,
        .ms = 80,
        .model_ms = 60,
        .attempts = 2,
        .first_data_ms = 3,
        .max_gap_ms = 17,
        .code = &.{.{ .tool_call_id = "c", .first_ms = 5, .last_ms = 55, .progress = &.{ .{ 5, 1 }, .{ 55, 20 } } }},
        .run_ms = 20,
        .tool_bytes = 4000,
        .output_bytes = 12,
        .calls = &.{.{ .name = "read", .start_ms = 1, .end_ms = 19, .ok = true, .run_index = 0, .result_bytes = 4000 }},
        .calls_omitted = 4,
        .run_results = &.{.{ .tool_call_id = "c", .ok = true, .run_ms = 20, .tool_bytes = 4000, .output_bytes = 12 }},
    };
    const encoded = try std.json.Stringify.valueAlloc(a, measured, .{ .emit_null_optional_fields = false });
    const restored = try schema.parseRecord(a, encoded);
    try t.expectEqual(@as(?u64, 60), restored.model_ms);
    try t.expectEqual(@as(?u32, 2), restored.attempts);
    try t.expectEqual(@as(?u64, 17), restored.max_gap_ms);
    try t.expectEqual([2]u64{ 55, 20 }, restored.code.?[0].progress[1]);
    try t.expectEqualStrings("read", restored.calls.?[0].name);
    try t.expectEqual(@as(?u64, 4), restored.calls_omitted);
    try t.expectEqual(@as(?u64, 20), restored.run_results.?[0].run_ms);
    try t.expectEqual(@as(?u64, 4000), restored.tool_bytes);
    try t.expectEqual(@as(?u64, 12), restored.output_bytes);
    try t.expectEqual(restored.tool_bytes, restored.calls.?[0].result_bytes);
    try t.expectEqual(restored.tool_bytes, restored.run_results.?[0].tool_bytes);
    try t.expectEqual(restored.output_bytes, restored.run_results.?[0].output_bytes);
    const data = try std.fmt.allocPrint(a,
        \\{{"from":0,"messages":[{{"role":"system","content":"base"}}]}}
        \\{f}
        \\{s}
        \\
    , .{ std.json.fmt(legacy, .{ .emit_null_optional_fields = false }), encoded });
    var history: std.ArrayList(provider.Message) = .empty;
    defer history.deinit(t.allocator);
    var tokens: u64 = 0;
    _ = try replay(t.allocator, a, data, &history, &tokens);
    try t.expectEqual(@as(usize, 3), history.items.len);
    try t.expectEqualStrings("old", history.items[1].content.?);
    try t.expectEqualStrings("new", history.items[2].content.?);
    try t.expectEqual(@as(u64, 99), tokens);
}

test "Step effort restores from Record and survives compacted message snapshots" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: Record = .{ .messages = &.{
        .{ .role = "system", .content = "base" },
        .{ .role = "user", .content = "task" },
        .{ .role = "assistant", .content = "legacy" },
    } };
    const step: Record = .{ .from = 3, .effort = "high", .context_tokens = 99, .messages = &.{
        .{ .role = "assistant", .content = "new", .step_effort = .{ .effort = "low" } },
    } };
    const data = try std.fmt.allocPrint(a, "{f}\n{f}\n", .{ std.json.fmt(base, .{ .emit_null_optional_fields = false }), std.json.fmt(step, .{ .emit_null_optional_fields = false }) });
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    _ = try replay(a, a, data, &history, &tokens);
    try t.expect(history.items[2].step_effort == null);
    try t.expectEqualStrings("high", history.items[3].step_effort.?.effort);
    const compacted: Record = .{ .from = 0, .messages = history.items, .context_tokens = 20 };
    const compacted_data = try std.fmt.allocPrint(a, "{s}{f}\n", .{ data, std.json.fmt(compacted, .{ .emit_null_optional_fields = false }) });
    var restored: std.ArrayList(provider.Message) = .empty;
    const restored_log = try replay(a, a, compacted_data, &restored, &tokens);
    try t.expectEqual(@as(usize, 2), restored_log.steps);
    try t.expectEqualDeep(history.items, restored.items);
    try t.expectEqual(@as(u64, 20), tokens);
    const old = try schema.parseRecord(a, "{\"messages\":[{\"role\":\"assistant\",\"content\":\"old\"}]}");
    try t.expect(old.effort == null);
    try t.expect(old.messages[0].step_effort == null);
    const scheduled = try schema.parseRecord(a, "{\"effort\":\"low\",\"effort_source\":\"model\",\"effort_downgraded\":true,\"messages\":[{\"role\":\"assistant\",\"content\":\"x\",\"step_effort\":{\"effort\":\"low\",\"source\":\"model\"}}]}");
    try t.expectEqualStrings("low", scheduled.effort.?);
    try t.expectEqualStrings("low", scheduled.messages[0].step_effort.?.effort);
}

test "replay restores independent ID maxima from every background state and foreground call" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    const records = [_]Record{
        .{ .messages = &.{.{ .role = "system", .content = "base" }} },
        .{ .background = .{ .id = "a3", .kind = .agent, .state = .started } },
        .{ .background = .{ .id = "a8", .kind = .agent, .state = .finished } },
        .{ .background = .{ .id = "b12", .kind = .bash, .state = .lost } },
        .{ .background = .{ .id = "b2", .kind = .bash, .state = .started } },
        .{ .background = .{ .id = "b2", .kind = .bash, .state = .finished } },
        .{ .from = 1, .calls = &.{
            .{ .name = "agent", .id = "a10", .background = false, .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 0 },
            .{ .name = "bash", .id = "b6", .background = false, .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 0 },
        } },
        .{ .from = 1, .messages = &.{.{ .role = "user", .content = "compacted" }} },
        .{ .bash = .{ .id = "b20", .run = 1, .state = .started } },
        .{ .bash = .{ .id = "b20", .run = 1, .state = .superseded, .superseded_by = "b21", .elapsed_ms = 5 } },
        .{ .bash = .{ .id = "b21", .run = 2, .state = .started } },
    };
    for (records) |record| try encoded.writer.print("{f}\n", .{std.json.fmt(record, .{ .emit_null_optional_fields = false })});
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    const restored = try replay(a, a, encoded.written(), &history, &tokens);
    try t.expectEqual(@as(u64, 11), restored.next_agent_id);
    try t.expectEqual(@as(u64, 22), restored.next_bash_id);
    try t.expectEqualStrings("compacted", history.items[1].content.?);
    try t.expectEqual(@as(usize, 1), restored.lost_background.len);
    try t.expectEqualStrings("a3", restored.lost_background[0].id);
    var progress: @import("../../tools/progress.zig").Queue = .{ .next_agent_id = restored.next_agent_id, .next_bash_id = restored.next_bash_id };
    defer progress.deinit(t.allocator);
    try t.expectEqualStrings("a11", try progress.add(t.allocator, t.io, .agent, "resumed", 1, false));
    try t.expectEqualStrings("b22", try progress.add(t.allocator, t.io, .bash, "resumed", 1, true));
}

test "reasoning provenance survives legacy replay and compaction under a different model" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data =
        \\{"provider":"codex","model":"old","messages":[{"role":"system","content":"base"}]}
        \\{"from":1,"model":"old","messages":[{"role":"assistant","content":"old reply","reasoning":{"provider":"codex","data":"[]"}}]}
        \\{"from":2,"messages":[{"role":"assistant","reasoning":{"provider":"codex","data":"[]"}}]}
        \\
    ;
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    _ = try replay(a, a, data, &history, &tokens);
    try t.expectEqualStrings("old", history.items[1].reasoning.?.model.?);
    try t.expectEqualStrings("", history.items[2].reasoning.?.model.?);
    const snapshot: Record = .{ .from = 1, .model = "new", .messages = history.items[1..] };
    const compacted = try std.fmt.allocPrint(a, "{s}{f}\n", .{ data, std.json.fmt(snapshot, .{}) });
    history.clearRetainingCapacity();
    _ = try replay(a, a, compacted, &history, &tokens);
    const cfg: provider.Config = .{ .provider = .codex, .model = "new", .base_url = "", .api_key = "" };
    try t.expectEqualStrings("old", history.items[1].reasoning.?.model.?);
    try t.expect(!history.items[1].reasoning.?.compatible(cfg));
    try t.expect(!history.items[2].reasoning.?.compatible(cfg));
}

test "ID restoration rejects overflow rather than wrapping the session counter" {
    const t = std.testing;
    var next_agent: u64 = 1;
    var next_bash: u64 = 1;
    var next_run: u64 = 1;
    try t.expectError(error.InvalidSessionLog, restoreId("a18446744073709551615", &next_agent, &next_bash, &next_run));
    try restoreId("legacy_id", &next_agent, &next_bash, &next_run);
    try t.expectEqual(@as(u64, 1), next_agent);
    try t.expectEqual(@as(u64, 1), next_bash);
}

test "task ID high water survives omitted calls and later compacted snapshots" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: Record = .{ .messages = &.{.{ .role = "system", .content = "base" }} };
    const overflow: Record = .{ .from = 1, .calls_omitted = 2, .task_ids = .{ .agent = 7, .bash = 12 } };
    const compacted: Record = .{ .messages = base.messages, .task_ids = .{ .agent = 2, .bash = 3 } };
    const data = try std.fmt.allocPrint(a, "{f}\n{f}\n{f}\n", .{ std.json.fmt(base, .{}), std.json.fmt(overflow, .{}), std.json.fmt(compacted, .{}) });
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    const restored = try replay(a, a, data, &history, &tokens);
    try t.expectEqual(@as(u64, 8), restored.next_agent_id);
    try t.expectEqual(@as(u64, 13), restored.next_bash_id);
}

test "agent session mappings survive snapshots and compaction without changing history" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mappings = [_]AgentSession{
        .{ .id = "a17", .session = "child-17" },
        .{ .id = "a3", .session = "child-3" },
        .{ .id = "a21", .session = "child-21" },
    };
    const records = [_]Record{
        .{ .messages = &.{.{ .role = "system", .content = "base" }}, .context_tokens = 10 },
        .{ .agent_session = mappings[0] },
        .{ .from = 1, .messages = &.{ .{ .role = "user", .content = "task" }, .{ .role = "assistant", .content = "answer" } }, .context_tokens = 100, .task_ids = .{ .agent = 8, .bash = 12 } },
        .{ .messages = &.{ .{ .role = "system", .content = "base" }, .{ .role = "user", .content = "task" }, .{ .role = "assistant", .content = "answer" } }, .context_tokens = 100 },
        .{ .agent_session = mappings[1] },
        .{ .from = 1, .messages = &.{.{ .role = "user", .content = "summary" }}, .context_tokens = 20, .task_ids = .{ .agent = 2, .bash = 3 } },
        .{ .agent_session = mappings[2] },
    };
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    var expected: std.ArrayList(provider.Message) = .empty;
    var mapping_count: usize = 0;
    var expected_tokens: u64 = 0;
    var expected_steps: usize = 0;
    var next_agent: u64 = 1;
    var next_bash: u64 = 1;
    var next_run: u64 = 1;
    for (records) |record| {
        try encoded.writer.print("{f}\n", .{std.json.fmt(record, .{ .emit_null_optional_fields = false })});
        if (record.agent_session) |mapping| {
            mapping_count += 1;
            try restoreId(mapping.id, &next_agent, &next_bash, &next_run);
        } else {
            try expected.ensureTotalCapacity(a, record.from + record.messages.len);
            if (record.from == expected.items.len) expected_steps += schema.assistantCount(record.messages);
            schema.apply(&expected, record);
            expected_tokens = record.context_tokens;
        }
        if (record.task_ids) |ids| {
            next_agent = @max(next_agent, ids.agent + 1);
            next_bash = @max(next_bash, ids.bash + 1);
        }
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        const restored = try replay(a, a, encoded.written(), &history, &tokens);
        try t.expectEqualDeep(expected.items, history.items);
        try t.expectEqual(expected_tokens, tokens);
        try t.expectEqualDeep(mappings[0..mapping_count], restored.agent_sessions);
        try t.expectEqual(next_agent, restored.next_agent_id);
        try t.expectEqual(next_bash, restored.next_bash_id);
        try t.expectEqual(expected_steps, restored.steps);
    }
}

test "replay matches reused background IDs in FIFO order for finished and lost events" {
    const t = std.testing;
    const first: Background = .{ .id = "a1", .kind = .agent, .state = .started, .result = "first" };
    const other: Background = .{ .id = "b1", .kind = .bash, .state = .started };
    const second: Background = .{ .id = "a1", .kind = .agent, .state = .started, .result = "second" };
    for ([_]@FieldType(Background, "state"){ .finished, .lost }) |terminal| {
        for ([_]bool{ false, true }) |delivered| {
            var arena: std.heap.ArenaAllocator = .init(t.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var encoded: std.Io.Writer.Allocating = .init(a);
            defer encoded.deinit();
            const records = [_]Record{
                .{ .messages = &.{.{ .role = "system", .content = "base" }}, .context_tokens = 10 },
                .{ .agent_session = .{ .id = "a1", .session = "child" } },
                .{ .background = first },
                .{ .background = other },
                .{ .background = second },
            };
            for (records) |record| try encoded.writer.print("{f}\n", .{std.json.fmt(record, .{ .emit_null_optional_fields = false })});
            var history: std.ArrayList(provider.Message) = .empty;
            var tokens: u64 = 0;
            const started = try replay(a, a, encoded.written(), &history, &tokens);
            try t.expectEqualDeep(&[_]Background{ first, other, second }, started.lost_background);
            try t.expectEqual(@as(usize, 0), started.background_repairs.len);
            if (delivered) {
                const message: Record = .{ .from = 1, .messages = &.{.{ .role = "user", .content = "first done", .source = .background, .background_id = "a1" }}, .context_tokens = 20 };
                try encoded.writer.print("{f}\n", .{std.json.fmt(message, .{ .emit_null_optional_fields = false })});
                history.clearRetainingCapacity();
                const committed = try replay(a, a, encoded.written(), &history, &tokens);
                try t.expectEqualDeep(&[_]Background{ other, second }, committed.lost_background);
                try t.expectEqualDeep(&[_]Background{.{ .id = first.id, .kind = first.kind, .state = .lost }}, committed.background_repairs);
            }
            const end: Record = .{ .background = .{ .id = "a1", .kind = .agent, .state = terminal } };
            try encoded.writer.print("{f}\n", .{std.json.fmt(end, .{ .emit_null_optional_fields = false })});
            history.clearRetainingCapacity();
            const restored = try replay(a, a, encoded.written(), &history, &tokens);
            try t.expectEqualDeep(&[_]Background{ other, second }, restored.lost_background);
            try t.expectEqual(@as(usize, 0), restored.background_repairs.len);
            try t.expectEqualDeep(&[_]AgentSession{.{ .id = "a1", .session = "child" }}, restored.agent_sessions);
            try t.expectEqual(@as(u64, 2), restored.next_agent_id);
            try t.expectEqual(@as(u64, 2), restored.next_bash_id);
            try t.expectEqual(@as(u64, if (delivered) 20 else 10), tokens);
            try t.expectEqual(@as(usize, if (delivered) 2 else 1), history.items.len);
        }
    }
}

test "replay carries unbilled background bytes across interrupted Turns and clears on a committed Step" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var history: std.ArrayList(provider.Message) = .empty;
    defer history.deinit(t.allocator);
    var tokens: u64 = 0;
    const waiting =
        \\{"messages":[{"role":"system","content":"s"}]}
        \\{"from":1,"messages":[{"role":"user","content":"你好🙂","source":"background","background_kind":"bash","background_id":"b1"}]}
        \\{"from":2,"messages":[{"role":"assistant","content":"[interrupted by user]"}]}
        \\
    ;
    const pending = try replay(t.allocator, arena.allocator(), waiting, &history, &tokens);
    try t.expectEqual(@as(u64, "你好🙂".len), pending.pending_background_bytes);
    history.clearRetainingCapacity();
    const charged = try replay(t.allocator, arena.allocator(), waiting ++
        \\{"from":3,"model_ms":0,"output_bytes":10,"messages":[{"role":"assistant","content":"received"}]}
        \\
    , &history, &tokens);
    try t.expectEqual(@as(u64, 0), charged.pending_background_bytes);
}

test "pending background bytes count only appended UTF-8 content and clear only on full Steps" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const background: provider.Message = .{ .role = "user", .content = "你好🙂", .source = .background, .background_id = "b1", .background_kind = .bash };
    const bytes: u64 = "你好🙂".len;
    const cases = [_]struct { record: Record, pending: u64 }{
        .{ .record = .{ .messages = &.{.{ .role = "system", .content = "base" }} }, .pending = 0 },
        .{ .record = .{ .from = 1, .messages = &.{ background, .{ .role = "user", .content = "not background", .background_id = "b2", .background_kind = .bash }, .{ .role = "user", .source = .background }, .{ .role = "user", .content = "", .source = .background } } }, .pending = bytes },
        .{ .record = .{ .messages = &.{ .{ .role = "system", .content = "base" }, background } }, .pending = bytes },
        .{ .record = .{ .from = 1, .messages = &.{background}, .model_ms = 0 }, .pending = bytes },
        .{ .record = .{ .from = 1, .messages = &.{.{ .role = "user", .content = "summary" }}, .model_ms = 1 }, .pending = bytes },
        .{ .record = .{ .from = 2, .messages = &.{.{ .role = "assistant", .content = "[interrupted by user]" }}, .ms = 10, .output_bytes = bytes }, .pending = bytes },
        .{ .record = .{ .diagnostic = .{ .error_name = "Canceled", .message = "interrupted", .attempts = 1, .step = 1 }, .model_ms = 0 }, .pending = bytes },
        .{ .record = .{ .agent_session = .{ .id = "a1", .session = "child" }, .model_ms = 0 }, .pending = bytes },
        .{ .record = .{ .background = .{ .id = "b1", .kind = .bash, .state = .finished }, .model_ms = 0 }, .pending = bytes },
        .{ .record = .{ .from = 3, .messages = &.{background} }, .pending = bytes * 2 },
        .{ .record = .{ .from = 4, .messages = &.{ background, .{ .role = "assistant", .content = "received" } }, .model_ms = 0 }, .pending = 0 },
        .{ .record = .{ .messages = &.{ .{ .role = "system", .content = "base" }, background } }, .pending = 0 },
        .{ .record = .{ .from = 2, .messages = &.{background} }, .pending = bytes },
    };
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    for (cases) |case| {
        try encoded.writer.print("{f}\n", .{std.json.fmt(case.record, .{ .emit_null_optional_fields = false })});
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        const restored = try replay(a, a, encoded.written(), &history, &tokens);
        try t.expectEqual(case.pending, restored.pending_background_bytes);
    }
}

test "fork header retains provenance and cache across compaction without billing inherited Steps" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const records = [_]Record{
        .{ .messages = &.{
            .{ .role = "system", .content = "original system" },
            .{ .role = "user", .content = "old background output", .source = .background, .background_id = "b1" },
            .{ .role = "assistant", .content = "inherited assistant" },
        }, .cache_key = "parent-cache", .forked_from = .{ .session = "parent-session", .message_count = 3 }, .context_tokens = 100 },
        .{ .from = 3, .messages = &.{ .{ .role = "user", .content = "child prompt" }, .{ .role = "assistant", .content = "child answer" } }, .context_tokens = 200 },
        .{ .from = 1, .messages = &.{.{ .role = "user", .content = "compacted child history" }}, .context_tokens = 50 },
    };
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    for (records, 0..) |record, i| {
        try encoded.writer.print("{f}\n", .{std.json.fmt(record, .{ .emit_null_optional_fields = false })});
        var messages: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        const restored = try replay(a, a, encoded.written(), &messages, &tokens);
        try t.expectEqual(@as(usize, if (i == 0) 0 else 1), restored.steps);
        try t.expectEqual(@as(u64, 0), restored.pending_background_bytes);
        try t.expectEqualStrings("parent-cache", restored.cache_key.?);
        try t.expectEqualDeep(records[0].forked_from, restored.forked_from);
    }
}

test "0.4.0 replay restores background Run ids and bash replacements from lifecycle records" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data: std.ArrayList(u8) = .empty;
    for ([_]Record{
        .{ .messages = &.{.{ .role = "system", .content = "system" }} },
        .{ .bash = .{ .id = "b1", .run = 1, .state = .superseded, .superseded_by = "b2" } },
        .{ .from = 1, .messages = &.{
            .{ .role = "assistant", .tool_calls = &.{.{ .id = "run", .function = .{ .name = "run", .arguments = "{}" } }} },
            .{ .role = "tool", .tool_call_id = "run", .content = "registered" },
        }, .calls = &.{.{ .name = "bash", .id = "b1", .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 0 }}, .run_results = &.{.{ .tool_call_id = "run", .background_id = "r3" }} },
    }) |record| {
        const line = try std.json.Stringify.valueAlloc(a, record, .{ .emit_null_optional_fields = false });
        try data.print(a, "{s}\n", .{line});
    }
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    _ = try replay(a, a, data.items, &history, &tokens);
    try t.expectEqualStrings("r3", history.items[2].background_id.?);
    try t.expectEqualStrings("b2", history.items[2].bash_replacements.?[0].superseded_by.?);
}

test "background Run completion restores its superseded bash on the originating Run" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var replacements: std.StringHashMap(@import("../../tools/bash/registry.zig").Event) = .init(a);
    try replacements.put("b1", .{ .id = "b1", .run = 1, .state = .superseded, .superseded_by = "b2" });
    const result: provider.Message = .{ .role = "user", .source = .background, .background_id = "r1", .background_run = .{
        .step = 1,
        .run_index = 0,
        .ok = true,
        .output = "done",
        .run_ms = 1,
        .tool_bytes = 0,
        .calls_omitted = 0,
        .changes = &.{},
        .calls = &.{.{ .name = "bash", .id = "b1", .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 0 }},
    } };
    var history = [_]provider.Message{ .{ .role = "tool", .tool_call_id = "call", .background_id = "r1" }, result };
    try restoreToolSummaries(a, &history, .{ .messages = &.{result} }, &replacements);
    try t.expectEqualStrings("b2", history[0].bash_replacements.?[0].superseded_by.?);
}

test "replay restores image references and view summaries" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data =
        \\{"from":0,"messages":[{"role":"system","content":"s"}],"provider":"codex","model":"m"}
        \\{"from":1,"messages":[{"role":"user","content":"look [Image #1]","images":[{"path":"/x/a.png","name":"a.png","media_type":"image/png","bytes":3,"width":4,"height":3}]},{"role":"assistant","tool_calls":[{"id":"c","type":"function","function":{"name":"run","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c","content":"ok","images":[{"path":"/x/b.png","name":"shot.png","media_type":"image/png","bytes":3,"width":640,"height":480}]}],"calls":[{"name":"view","start_ms":0,"end_ms":1,"ok":true,"run_index":0,"path":"shot.png"}]}
        \\
    ;
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    _ = try replay(a, a, data, &history, &tokens);
    try t.expectEqualStrings("a.png", history.items[1].images.?[0].name);
    try t.expectEqual(@as(u32, 640), history.items[3].images.?[0].width);
    try t.expectEqualStrings("shot.png · 640×480", history.items[3].tool_summary.?.files[0].path);
    const written = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(history.items[1], .{ .emit_null_optional_fields = false })});
    try t.expect(std.mem.indexOf(u8, written, "\"images\":[{\"path\":\"/x/a.png\"") != null);
}
