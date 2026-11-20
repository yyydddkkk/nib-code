const std = @import("std");
const provider = @import("../../provider.zig");
const Background = @import("../events.zig").Background;
const Tuning = @import("../tuning.zig").Resolved;

pub const RunResult = struct {
    tool_call_id: []const u8,
    background_id: ?[]const u8 = null,
    ok: ?bool = null,
    run_ms: ?u64 = null,
    tool_bytes: ?u64 = null,
    output_bytes: ?u64 = null,
    /// Own output when the provider tool message also carries Inbox text.
    output: ?[]const u8 = null,
    remaining_steps: ?usize = null,
    calls_omitted: ?u64 = null,
};

pub const Delivery = struct {
    event: Background,
    via: enum { insert, fold, wait },
    output_bytes: u64,
};

pub const Diagnostic = struct {
    error_name: []const u8,
    message: []const u8,
    attempts: u32,
    step: u32,
    model_attempts: ?[]const @import("../../provider/timing.zig").Attempt = null,
};

pub const AgentSession = struct {
    id: []const u8,
    session: []const u8,
    fork: bool = false,
};

pub const ForkedFrom = struct {
    session: []const u8,
    message_count: usize,
};

pub const TaskStop = struct { id: []const u8, reason: []const u8, stopped: bool };

pub const Record = struct {
    hook: ?struct { event: []const u8, command: []const u8, exit_code: i32, duration_ms: u64 } = null,
    mcp_servers: ?[]const @import("../../mcp/config.zig").Server = null,
    plugin_skills: ?[]const @import("../skills.zig").Skill = null,
    skills: ?@import("../skills.zig").Summary = null,
    task_stop: ?TaskStop = null,
    sandbox_unavailable: ?[]const u8 = null,
    at: ?i64 = null,
    source: ?Source = null,
    diagnostic: ?Diagnostic = null,
    agent_session: ?AgentSession = null,
    background: ?Background = null,
    bash: ?@import("../../tools/bash/registry.zig").Event = null,
    usage: ?provider.Usage = null,
    effort: ?[]const u8 = null,
    turn_step: ?u32 = null,
    ms: ?u64 = null,
    model_ms: ?u64 = null,
    transport: ?[]const u8 = null,
    incremental: ?bool = null,
    input_items: ?usize = null,
    input_bytes: ?usize = null,
    transport_fallback: ?[]const u8 = null,
    transport_fallback_at: ?i64 = null,
    transport_fallback_detail: ?[]const u8 = null,
    full_reason: ?[]const u8 = null,
    mismatch_index: ?usize = null,
    model_attempts: ?[]const @import("../../provider/timing.zig").Attempt = null,
    max_content_gap_ms: ?u64 = null,
    attempts: ?u32 = null,
    first_data_ms: ?u64 = null,
    max_gap_ms: ?u64 = null,
    code: ?[]const @import("../../provider/timing.zig").Code = null,
    run_ms: ?u64 = null,
    tool_bytes: ?u64 = null,
    output_bytes: ?u64 = null,
    calls: ?[]const @import("../../sandbox/timing.zig").Call = null,
    calls_omitted: ?u64 = null,
    task_ids: ?@import("../events.zig").TaskIds = null,
    run_results: ?[]const RunResult = null,
    deliveries: ?[]const Delivery = null,
    nib_version: ?[]const u8 = null,
    system_sha: ?[]const u8 = null,
    patches_off: ?[]const []const u8 = null,
    family: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    tuning: ?std.json.ArrayHashMap([]const u8) = null,
    cwd: ?[]const u8 = null,
    provider: ?provider.Id = null,
    custom_provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    parent_session_id: ?[]const u8 = null,
    cache_key: ?[]const u8 = null,
    forked_from: ?ForkedFrom = null,
    from: usize = 0,
    messages: []const provider.Message = &.{},
    context_tokens: u64 = 0,
    repair: bool = false,
};

pub const Source = struct { step: usize, run: usize, code: []const u8, base: ?[]const u8 = null, arguments: []const u8, failed: bool };

pub const ResumeAdaptation = struct {
    header_model: ?[]const u8 = null,
    family: ?[]const u8 = null,
    profile: ?[]const u8 = null,

    /// The retained Profile to display only when it differs or cannot be established.
    pub fn notice(adaptation: ResumeAdaptation, requested_model: []const u8) ?[]const u8 {
        const profile = adaptation.profile orelse {
            const original_model = adaptation.header_model orelse return null;
            return if (std.mem.eql(u8, original_model, requested_model)) null else "unknown";
        };
        const model_profile = @import("../profile.zig");
        const family = model_profile.Family.forModel(requested_model);
        if (!std.mem.eql(u8, profile, @tagName(model_profile.Profile.forFamily(family)))) return profile;
        if (adaptation.family) |recorded| {
            if (!std.mem.eql(u8, recorded, @tagName(family))) return profile;
        }
        return null;
    }
};

pub const Summary = struct {
    id: []const u8,
    path: []const u8,
    modified_ns: i96,
    /// First line of the first user message, at most ~60 bytes.
    preview: []const u8,
};

pub fn pendingBytes(previous: u64, record: Record) u64 {
    var bytes = previous;
    if (record.deliveries) |deliveries| {
        if (record.model_ms != null) bytes = 0;
        for (deliveries) |delivery| if (delivery.via != .wait) {
            bytes += delivery.output_bytes;
        };
    } else {
        for (record.messages) |message| if (message.source == .background) {
            if (message.content) |text| bytes += text.len;
        };
        if (record.model_ms != null) bytes = 0;
    }
    return bytes;
}

pub fn assistantCount(messages: []const provider.Message) usize {
    var count: usize = 0;
    for (messages) |message| if (std.mem.eql(u8, message.role, "assistant")) {
        count += 1;
    };
    return count;
}

pub fn apply(history: *std.ArrayList(provider.Message), record: Record) void {
    history.shrinkRetainingCapacity(record.from);
    history.appendSliceAssumeCapacity(record.messages);
    for (history.items[record.from..]) |*message| {
        if (message.reasoning) |*reasoning| {
            if (reasoning.model == null and reasoning.tracksModel()) reasoning.model = record.model orelse "";
        }
        if (record.effort) |effort| {
            if (std.mem.eql(u8, message.role, "assistant")) message.step_effort = .{ .effort = effort };
        }
    }
}

pub fn parseRecord(a: std.mem.Allocator, line: []const u8) !Record {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{ .allocate = .alloc_always });
    if (value == .object) if (value.object.get("messages")) |messages| {
        if (messages == .array) for (messages.array.items) |*m| {
            if (m.* != .object) continue;
            if (m.object.get("reasoning_content")) |legacy| {
                _ = m.object.swapRemove("reasoning_content");
                if (legacy != .string) continue;
                var reasoning: std.json.ObjectMap = .{};
                try reasoning.put(a, "provider", .{ .string = "chat_completions" });
                try reasoning.put(a, "data", legacy);
                try m.object.put(a, "reasoning", .{ .object = reasoning });
            }
        };
    };
    return std.json.parseFromValueLeaky(Record, a, value, .{ .ignore_unknown_fields = true });
}
