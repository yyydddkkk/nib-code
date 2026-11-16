const std = @import("std");
const chat = @import("provider/openai.zig");
const codex = @import("provider/responses.zig");
const cancelable = @import("provider/cancel.zig");
const model_timing = @import("provider/timing.zig");
const retry = @import("provider/retry.zig");
const idle = @import("provider/idle.zig");
pub const complete = retry.complete;
pub const RetryEvent = retry.Event;
pub const RetrySink = retry.Sink;
pub const max_attempts = retry.max_attempts;
pub const ModelTiming = model_timing.Model;

pub const CodexState = @import("provider/codex_ws.zig").State;
pub const Transport = enum { sse, websocket };

pub const Protocol = enum { responses, chat_completions, anthropic_messages };
pub const Id = blk: {
    var names: [definitions.len + 1][:0]const u8 = undefined;
    var values: [definitions.len + 1]u8 = undefined;
    for (definitions, 0..) |entry, i| {
        names[i] = std.fmt.comptimePrint("{s}", .{entry.id});
        values[i] = i;
    }
    names[definitions.len] = "custom";
    values[definitions.len] = definitions.len;
    break :blk @Enum(u8, .exhaustive, &names, &values);
};

/// The cheap model of a service for side requests (search, input prediction); null when none is known.
pub fn smallModel(id: Id) ?[]const u8 {
    return switch (id) {
        .codex, .openai => "gpt-6-luna",
        .anthropic => "claude-haiku-5-5",
        .deepseek => "deepseek-flash",
        else => null,
    };
}

/// Session config switched to the service's small model with its own default effort; null when the service has none.
pub fn withSmallModel(cfg: Config) ?Config {
    var small = cfg;
    small.model = smallModel(cfg.provider) orelse return null;
    small.thinking = null;
    small.reasoning_effort = null;
    return small;
}

pub const Model = struct { id: []const u8, context_window: u64, max_output: u32 = 128000, can_disable_reasoning: bool = true, vision: ?bool = null };

pub const Definition = struct {
    id: []const u8,
    name: []const u8,
    protocol: Protocol,
    base_url: []const u8,
    api_key_env: []const []const u8,
    default_model: []const u8,
    models: []const Model = &.{},
    custom_run: bool = false,
    vision: bool = true,
};

pub const definitions = [_]Definition{
    .{ .id = "codex", .models = &codex.models, .name = "Codex", .protocol = .responses, .base_url = "https://chatgpt.com/backend-api", .api_key_env = &.{}, .default_model = codex.default_model },
    .{ .id = "chat_completions", .vision = false, .name = "Chat Completions", .protocol = .chat_completions, .base_url = "https://api.deepseek.com", .api_key_env = &.{ "NIB_API_KEY", "DEEPSEEK_API_KEY" }, .default_model = chat.default_model },
    .{ .id = "openai", .custom_run = true, .name = "OpenAI", .protocol = .responses, .base_url = "https://api.openai.com/v1", .api_key_env = &.{"OPENAI_API_KEY"}, .default_model = "gpt-6.1-sol", .models = &.{ .{ .id = "gpt-6.1-sol", .context_window = 1050000 }, .{ .id = "gpt-6.1-terra", .context_window = 1050000 } } },
    .{ .id = "anthropic", .name = "Anthropic", .protocol = .anthropic_messages, .base_url = "https://api.anthropic.com", .api_key_env = &.{"ANTHROPIC_API_KEY"}, .default_model = "claude-sonnet-5-5", .models = &.{ .{ .id = "claude-opus-5-5", .context_window = 1000000 }, .{ .id = "claude-sonnet-5-5", .context_window = 1000000 }, .{ .id = "claude-haiku-5-5", .context_window = 1000000 }, .{ .id = "claude-fable-5-1", .context_window = 1000000 } } },
    .{ .id = "deepseek", .vision = false, .name = "DeepSeek", .protocol = .chat_completions, .base_url = "https://api.deepseek.com", .api_key_env = &.{"DEEPSEEK_API_KEY"}, .default_model = "deepseek-flash", .models = &.{ .{ .id = "deepseek-flash", .context_window = 1000000 }, .{ .id = "deepseek-v4-pro", .context_window = 1000000 } } },
    .{ .id = "xai", .name = "xAI", .protocol = .responses, .base_url = "https://api.x.ai/v1", .api_key_env = &.{"XAI_API_KEY"}, .default_model = "grok-4.7", .models = &.{ .{ .id = "grok-4.7", .context_window = 500000 }, .{ .id = "grok-4.6", .context_window = 500000 } } },
};

pub fn definition(id: Id) Definition {
    for (definitions) |entry| if (std.mem.eql(u8, entry.id, @tagName(id))) return entry;
    unreachable;
}

pub const Limits = struct {
    llm_concurrency: usize = 4,
    llm_calls_per_run: usize = 100,
    llm_input_kib: usize = 256,
    agent_concurrency: usize = 4,
    max_steps: ?usize = null,
    stream_idle_timeout_s: usize = 300,
    stream_content_timeout_s: usize = 120,
    request_timeout_s: usize = 300,
    run_background_after_ms: usize = 10000,
    run_output_bytes: usize = 16 * 1024,
};

pub const Sandbox = struct {
    mode: enum { workspace, off } = .off,
    /// Absolute extra writable roots.
    writable: []const []const u8 = &.{},
};

pub const KeySource = enum { none, env, store };

pub const Config = struct {
    simple: bool = false,
    open: ?[]const u8 = null,
    sandbox: Sandbox = .{},
    hooks: Hooks = .{},
    enabled_skills: []const []const u8 = &.{},
    mcp_servers: []const @import("mcp/config.zig").Server = &.{},
    limits: Limits = .{},
    provider: Id = .chat_completions,
    custom_provider: ?[]const u8 = null,
    custom_protocol: Protocol = .chat_completions,
    custom_vision: ?bool = null,
    custom_max_output: ?u32 = null,
    api_key_env: ?[]const u8 = null,
    key_source: KeySource = .none,
    /// Where nib's own `auth.json` lives; null in tests that never sign in.
    nib_home: ?[]const u8 = null,
    /// Test hook for the ChatGPT OAuth issuer (NIB_AUTH_ISSUER).
    auth_issuer: ?[]const u8 = null,
    codex_transport: Transport = .websocket,
    codex_run_tool: enum { custom, function } = .custom,
    reasoning_summary: enum { off, auto } = .off,
    codex_home: ?[]const u8 = null,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    context_window: u64 = 1_000_000,
    thinking: ?bool = null,
    reasoning_effort: ?[]const u8 = null,
    /// Borrowed for the duration of the request.
    output_schema: ?std.json.Value = null,
    prompt_cache_key: ?[]const u8 = null,
    /// Values `setEffort` accepts; `default` and `off` first, then levels.
    pub const effort_values = [_][]const u8{ "default", "off", "none", "minimal", "low", "medium", "high", "xhigh", "max" };

    pub fn name(cfg: Config) []const u8 {
        return cfg.custom_provider orelse @tagName(cfg.provider);
    }

    pub fn protocol(cfg: Config) Protocol {
        return if (cfg.provider == .custom) cfg.custom_protocol else definition(cfg.provider).protocol;
    }

    /// Responses services get no limit: that encoder turns `max_tokens` into a summary-length prompt.
    pub fn sessionMaxTokens(cfg: Config) ?u32 {
        return if (cfg.protocol() == .responses) null else cfg.custom_max_output;
    }

    /// Whether the model accepts image input; custom providers declare it, defaulting to the protocol.
    pub fn vision(cfg: Config) bool {
        if (cfg.provider == .custom) return cfg.custom_vision orelse (cfg.custom_protocol != .chat_completions);
        const entry = definition(cfg.provider);
        for (entry.models) |model| if (std.mem.eql(u8, model.id, cfg.model)) {
            if (model.vision) |value| return value;
        };
        return entry.vision;
    }

    pub fn customRun(cfg: Config) bool {
        return (cfg.provider == .codex and cfg.codex_run_tool == .custom) or (cfg.provider != .custom and cfg.provider != .codex and definition(cfg.provider).custom_run);
    }

    pub fn setEffort(cfg: *Config, value: []const u8) !void {
        const known = for (effort_values) |v| {
            if (std.mem.eql(u8, v, value)) break v;
        } else return error.InvalidReasoningEffort;
        if (std.mem.eql(u8, known, "default")) {
            cfg.thinking = null;
            cfg.reasoning_effort = null;
        } else if (std.mem.eql(u8, known, "off")) {
            cfg.thinking = false;
            cfg.reasoning_effort = null;
        } else {
            cfg.thinking = true;
            cfg.reasoning_effort = known;
        }
    }

    pub fn effectiveEffort(cfg: Config) []const u8 {
        if (cfg.protocol() == .responses) return codex.reasoningEffort(cfg) orelse "server default";
        if (cfg.protocol() == .anthropic_messages) return @import("provider/anthropic.zig").effort(cfg) orelse "server default";
        if (cfg.thinking == false) return "off";
        return cfg.reasoning_effort orelse if (cfg.thinking == true) "on (server default effort)" else "server default";
    }

    /// Effort name logged per Step: the effective effort, with server defaults as "default".
    pub fn loggedEffort(cfg: Config) []const u8 {
        const effective = cfg.effectiveEffort();
        if (std.mem.eql(u8, effective, "server default") or std.mem.eql(u8, effective, "on (server default effort)")) return "default";
        return effective;
    }

    /// What a 401 asks the user to check, without revealing any key.
    pub fn keyHint(cfg: Config) []const u8 {
        return if (cfg.key_source == .store) "the key stored by nib (run nib login)" else cfg.api_key_env orelse "API key";
    }

    pub fn missingKey(cfg: Config) bool {
        return cfg.provider != .codex and cfg.api_key.len == 0 and (cfg.provider != .custom or cfg.api_key_env != null);
    }

    pub fn checkSession(cfg: Config, id: Id, model: ?[]const u8) !void {
        if (cfg.provider != id) return error.SessionProviderMismatch;
        if (cfg.protocol() != .chat_completions) if (model) |original| {
            if (!std.mem.eql(u8, original, cfg.model)) return error.SessionModelMismatch;
        };
    }
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

pub const Reasoning = struct {
    provider: Id,
    data: []const u8,
    includes_output: bool = false,
};

pub const StepEffort = struct {
    effort: []const u8,
};

pub const Message = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning: ?Reasoning = null,
    images: ?[]const @import("image.zig").Image = null,
    phase: ?[]const u8 = null,
    waiting: ?bool = null,
    step_effort: ?StepEffort = null,
    bash_replacements: ?[]const @import("tools/bash/registry.zig").Event = null,
    run_ok: ?bool = null,
    tool_summary: ?@import("session/tool_summary.zig").Summary = null,
    step_calls_omitted: ?u64 = null,
    source: ?enum { background, undo } = null,
    background_id: ?[]const u8 = null,
    background_ok: ?bool = null,
    background_run: ?@import("session/events.zig").RunCompletion = null,
    background_kind: ?@import("session/events.zig").Background.Kind = null,
};

pub const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    prompt_cache_hit_tokens: u64 = 0,
    prompt_cache_write_tokens: u64 = 0,

    pub fn jsonStringify(u: Usage, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("prompt_tokens");
        try jw.write(u.prompt_tokens);
        try jw.objectField("completion_tokens");
        try jw.write(u.completion_tokens);
        try jw.objectField("prompt_cache_hit_tokens");
        try jw.write(u.prompt_cache_hit_tokens);
        if (u.prompt_cache_write_tokens > 0) {
            try jw.objectField("prompt_cache_write_tokens");
            try jw.write(u.prompt_cache_write_tokens);
        }
        try jw.endObject();
    }

    pub fn add(u: *Usage, other: Usage) void {
        u.prompt_tokens += other.prompt_tokens;
        u.completion_tokens += other.completion_tokens;
        u.prompt_cache_hit_tokens += other.prompt_cache_hit_tokens;
        u.prompt_cache_write_tokens += other.prompt_cache_write_tokens;
    }
};

/// Allocated with the `out` allocator passed to `stream` or `complete`.
pub const Reply = struct {
    text: []const u8,
    reasoning: ?Reasoning = null,
    phase: ?[]const u8 = null,
    tool_calls: []const ToolCall,
    usage: Usage,
};

pub const Kind = enum { text, reasoning };

pub const Sink = struct {
    /// Only buffered callers may replay Chat deltas after a transient failure.
    replay_safe: bool = false,
    timing: ?*model_timing.Model = null,
    codex_state: ?*CodexState = null,
    ctx: *anyopaque,
    onDelta: *const fn (ctx: *anyopaque, kind: Kind, text: []const u8) anyerror!void,
    monitor: ?*idle.Monitor = null,
    onFallback: ?*const fn (ctx: *anyopaque, info: @import("provider/codex_ws.zig").Info) anyerror!void = null,
    onToolArguments: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    onData: ?*const fn (ctx: *anyopaque) anyerror!void = null,

    pub fn toolArguments(s: Sink) !void {
        if (s.onToolArguments) |notify| try notify(s.ctx);
    }

    pub fn fallback(s: Sink, info: @import("provider/codex_ws.zig").Info) !void {
        if (s.onFallback) |notify| try notify(s.ctx, info);
    }

    pub fn received(s: Sink) !void {
        if (s.onData) |notify| try notify(s.ctx);
    }
};

pub fn stream(
    gpa: std.mem.Allocator,
    out: std.mem.Allocator,
    client: *std.http.Client,
    cfg: Config,
    cache_key: []const u8,
    messages: []const Message,
    tools_json: []const u8,
    max_tokens: ?u32,
    sink: Sink,
    cancel: *const std.atomic.Value(bool),
    detail: *?[]u8,
) !Reply {
    if (sink.timing) |timing| timing.resetAttempt();
    var monitor: idle.Monitor = .init(client.io, cfg.limits.stream_idle_timeout_s, sink.timing);
    monitor.content_duration.raw = .fromSeconds(@intCast(cfg.limits.stream_content_timeout_s));
    monitor.request_duration.raw = .fromSeconds(@intCast(cfg.limits.request_timeout_s));
    var observed_sink = sink;
    observed_sink.monitor = &monitor;
    return switch (cfg.protocol()) {
        .chat_completions => cancelable.run(client.io, cancel, monitor.started.addDuration(monitor.request_duration), chat.stream, .{ gpa, out, client, cfg, messages, tools_json, max_tokens, observed_sink, cancel, detail, &monitor }),
        .responses => cancelable.run(client.io, cancel, monitor.started.addDuration(monitor.request_duration), codex.stream, .{ gpa, out, client, cfg, cache_key, messages, tools_json, max_tokens, observed_sink, cancel, detail, &monitor }),
        .anthropic_messages => cancelable.run(client.io, cancel, monitor.started.addDuration(monitor.request_duration), @import("provider/anthropic.zig").stream, .{ gpa, out, client, cfg, messages, tools_json, max_tokens, observed_sink, cancel, detail, &monitor }),
    } catch |err| {
        if (cfg.provider == .codex) if (sink.codex_state) |state| {
            state.reset(gpa);
            state.reset_reason = "reconnect";
        };
        if (cancel.load(.acquire)) return error.Canceled;
        if (err == error.ModelRequestTimeout) {
            monitor.read_failure = error.Timeout;
            monitor.timeout_kind = .request;
        }
        return monitor.failure(gpa, detail, err);
    };
}

test "explicit effort overrides thinking and stores stable names" {
    const t = std.testing;
    var cfg: Config = .{ .base_url = "", .api_key = "", .model = "gpt-6.1-sol", .provider = .codex, .thinking = false };
    var value = [_]u8{ 'h', 'i', 'g', 'h' };
    try cfg.setEffort(&value);
    value[0] = 'x';
    try t.expectEqualStrings("high", cfg.effectiveEffort());
    try t.expectEqual(@as(?bool, true), cfg.thinking);
    try cfg.setEffort("off");
    try t.expectEqualStrings("low", cfg.effectiveEffort());
    try cfg.setEffort("default");
    try t.expectEqualStrings("server default", cfg.effectiveEffort());
    try t.expectEqual(@as(?bool, null), cfg.thinking);
    try t.expectError(error.InvalidReasoningEffort, cfg.setEffort("hgh"));
    try t.expectEqualStrings("server default", cfg.effectiveEffort());
    cfg.provider = .chat_completions;
    try cfg.setEffort("max");
    try t.expectEqualStrings("max", cfg.effectiveEffort());
    try cfg.setEffort("off");
    try t.expectEqualStrings("off", cfg.effectiveEffort());
}

test "provider definitions cover every identity exactly once" {
    for (std.meta.tags(Id)) |id| {
        if (id == .custom) continue;
        var count: usize = 0;
        for (definitions) |entry| {
            if (std.mem.eql(u8, entry.id, @tagName(id))) count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
        try std.testing.expect(definition(id).base_url.len > 0);
        try std.testing.expect(definition(id).default_model.len > 0);
    }
}

test "vision follows provider tables and custom declarations" {
    const t = std.testing;
    try t.expect((Config{ .provider = .codex, .base_url = "", .api_key = "", .model = "gpt-6.1-sol" }).vision());
    try t.expect((Config{ .provider = .anthropic, .base_url = "", .api_key = "", .model = "claude-sonnet-5-5" }).vision());
    try t.expect(!(Config{ .provider = .deepseek, .base_url = "", .api_key = "", .model = "deepseek-flash" }).vision());
    try t.expect(!(Config{ .provider = .chat_completions, .base_url = "", .api_key = "", .model = "deepseek-flash" }).vision());
    var custom: Config = .{ .provider = .custom, .custom_provider = "site", .base_url = "", .api_key = "", .model = "m" };
    try t.expect(!custom.vision());
    custom.custom_vision = true;
    try t.expect(custom.vision());
    custom.custom_protocol = .anthropic_messages;
    custom.custom_vision = null;
    try t.expect(custom.vision());
    custom.custom_vision = false;
    try t.expect(!custom.vision());
}

pub const Hooks = struct { after_edit: []const []const u8 = &.{}, turn_end: []const []const u8 = &.{} };
