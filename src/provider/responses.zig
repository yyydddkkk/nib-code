const std = @import("std");
const p = @import("../provider.zig");
const sse = @import("sse.zig");
const idle = @import("idle.zig");
const body_reader = @import("body.zig");
const websocket = @import("websocket.zig");
const ws_state = @import("codex_ws.zig");
const image = @import("../image.zig");

const Model = p.Model;
pub const models = [_]Model{
    .{ .id = "gpt-6.2-sol", .context_window = 500_000, .can_disable_reasoning = false },
    .{ .id = "gpt-6.2-astra", .context_window = 272_000, .can_disable_reasoning = false },
    .{ .id = "gpt-6.1-terra", .context_window = 500_000 },
    .{ .id = "gpt-6.1-sol", .context_window = 500_000, .can_disable_reasoning = false },
    .{ .id = "gpt-6-astra", .context_window = 272_000, .can_disable_reasoning = false },
    .{ .id = "gpt-6-sol", .context_window = 272_000 },
    .{ .id = "gpt-6-luna", .context_window = 272_000 },
    .{ .id = "gpt-5.6-luna", .context_window = 272_000 },
    .{ .id = "gpt-5.6-sol", .context_window = 272_000 },
    .{ .id = "gpt-5.6-terra", .context_window = 272_000 },
};
pub const default_model = models[0].id;

fn modelInfo(id: []const u8) ?Model {
    for (models) |model| if (std.mem.eql(u8, id, model.id)) return model;
    return null;
}

pub fn contextWindow(model: []const u8) !u64 {
    return (modelInfo(model) orelse return error.UnknownCodexModelContextWindow).context_window;
}

pub fn reasoningEffort(cfg: p.Config) ?[]const u8 {
    if (cfg.provider == .xai and (cfg.thinking == false or (cfg.reasoning_effort != null and (std.mem.eql(u8, cfg.reasoning_effort.?, "none") or std.mem.eql(u8, cfg.reasoning_effort.?, "minimal"))))) return null;
    if (cfg.thinking == false) {
        if (modelInfo(cfg.model)) |model| if (!model.can_disable_reasoning) return "low";
        return "none";
    }
    return cfg.reasoning_effort orelse if (cfg.thinking == true) @as(?[]const u8, "medium") else null;
}

const login = @import("../auth/codex.zig");

pub fn credentials(gpa: std.mem.Allocator, client: *std.http.Client, cfg: p.Config, detail: *?[]u8, rejected: ?[]const u8) !login.Login {
    return login.current(gpa, client.io, client, .{ .nib_home = cfg.nib_home, .codex_home = cfg.codex_home, .issuer = cfg.auth_issuer }, rejected) catch |err| switch (err) {
        error.NotSignedIn => authError(gpa, detail, "Codex credentials unavailable; run nib login codex to log in."),
        error.InvalidCredentials => authError(gpa, detail, "Invalid or incomplete Codex credentials; run nib login codex to log in again."),
        error.RefreshFailed => authError(gpa, detail, "Codex login expired and could not be refreshed; run nib login codex to log in again."),
        else => return err,
    };
}

fn authError(gpa: std.mem.Allocator, detail: *?[]u8, message: []const u8) error{ OutOfMemory, InvalidCredentials } {
    detail.* = try gpa.dupe(u8, message);
    return error.InvalidCredentials;
}

pub fn stream(gpa: std.mem.Allocator, out: std.mem.Allocator, client: *std.http.Client, cfg: p.Config, cache_key: []const u8, messages: []const p.Message, tools_json: []const u8, max_tokens: ?u32, sink: p.Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8, monitor: *idle.Monitor) !p.Reply {
    if (cfg.provider != .codex) {
        var reply = streamSse(gpa, out, client, cfg, cache_key, messages, tools_json, max_tokens, sink, cancel, detail, monitor) catch |err| {
            if (detail.*) |old| {
                const renamed = try std.mem.replaceOwned(u8, gpa, old, "Codex", cfg.name());
                gpa.free(old);
                detail.* = renamed;
            }
            return err;
        };
        if (reply.reasoning) |*reasoning| reasoning.provider = cfg.provider;
        return reply;
    }
    var local: ws_state.State = .{};
    defer local.reset(gpa);
    const state = sink.codex_state orelse &local;
    state.stale_socket = false;
    state.last = .{ .fallback_reason = state.degraded, .fallback_at = state.degraded_at, .full_reason = if (state.degraded != null) "sse_fallback" else if (cfg.codex_transport == .sse) "sse_configured" else null };
    if (cfg.codex_transport == .websocket and state.degraded == null) {
        state.last.transport = .websocket;
        state.last.full_reason = state.reset_reason;
        var forward: WsForward = .{ .sink = sink };
        return streamWebSocket(gpa, out, client, cfg, cache_key, messages, tools_json, max_tokens, &forward, cancel, detail, monitor, state) catch |err| {
            state.reset(gpa);
            if (err == error.Canceled or err == error.OutOfMemory or cancel.load(.acquire) or monitor.read_failure != null) return err;
            if (!fallbackError(err)) return err;
            const attempted = state.last;
            state.degrade(gpa, @errorName(err));
            state.degraded_at = @intCast(@divFloor(std.Io.Clock.real.now(client.io).nanoseconds, std.time.ns_per_ms));
            state.last.fallback_at = state.degraded_at;
            state.last.fallback_detail = if (detail.*) |d| try out.dupe(u8, d) else null;
            state.last.full_reason = "sse_fallback";
            try sink.fallback(state.last);
            if (forward.emitted) {
                state.last.transport = .websocket;
                state.last.incremental = attempted.incremental;
                state.last.full_reason = attempted.full_reason;
                return error.WebSocketFallback;
            }
            if (detail.*) |d| gpa.free(d);
            detail.* = null;
            if (sink.timing) |timing| timing.used = 0;
            return streamSse(gpa, out, client, cfg, cache_key, messages, tools_json, max_tokens, sink, cancel, detail, monitor);
        };
    }
    return streamSse(gpa, out, client, cfg, cache_key, messages, tools_json, max_tokens, sink, cancel, detail, monitor);
}

const WsForward = struct {
    sink: p.Sink,
    emitted: bool = false,
    fn delta(ctx: *anyopaque, kind: p.Kind, text: []const u8) !void {
        const f: *@This() = @ptrCast(@alignCast(ctx));
        f.emitted = true;
        try f.sink.onDelta(f.sink.ctx, kind, text);
    }
    fn arguments(ctx: *anyopaque) !void {
        const f: *@This() = @ptrCast(@alignCast(ctx));
        try f.sink.toolArguments();
    }
    fn data(ctx: *anyopaque) !void {
        const f: *@This() = @ptrCast(@alignCast(ctx));
        try f.sink.received();
    }
};

fn fallbackError(err: anyerror) bool {
    return switch (err) {
        error.WebSocketHandshake,
        error.WebSocketProtocol,
        error.WebSocketMessageTooLarge,
        => true,
        else => false,
    };
}

fn streamWebSocket(gpa: std.mem.Allocator, out: std.mem.Allocator, client: *std.http.Client, cfg: p.Config, cache_key: []const u8, messages: []const p.Message, tools_json: []const u8, max_tokens: ?u32, forward: *WsForward, cancel: *const std.atomic.Value(bool), detail: *?[]u8, monitor: *idle.Monitor, state: *ws_state.State) anyerror!p.Reply {
    const sink: p.Sink = .{ .ctx = forward, .onDelta = WsForward.delta, .onData = WsForward.data, .onToolArguments = WsForward.arguments, .timing = forward.sink.timing, .codex_state = state, .monitor = monitor };
    errdefer state.reset(gpa);
    const body = try requestBody(gpa, client.io, cfg, cache_key, messages, tools_json, max_tokens);
    defer gpa.free(body);
    var auth = try credentials(gpa, client, cfg, detail, null);
    defer auth.deinit();
    const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{auth.access_token});
    defer gpa.free(bearer);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const tier = cfg.codexServiceTier();
    for ([_][]const u8{ cfg.base_url, cfg.model, cache_key, bearer, auth.account_id, tier orelse "" }) |part| {
        hash.update(part);
        hash.update(&.{0});
    }
    var scope: [32]u8 = undefined;
    hash.final(&scope);
    if (state.scope) |old| if (!std.mem.eql(u8, &old, &scope)) {
        state.reset(gpa);
        state.reset_reason = "scope_changed";
    };
    if (state.socket) |*socket| {
        if (!try socket.checkIdle(gpa, monitor)) {
            state.reset(gpa);
            state.reset_reason = "connection_closed";
        }
    }
    state.reused = state.socket != null;
    if (state.socket == null) {
        const url = try std.fmt.allocPrint(gpa, "{s}/codex/responses", .{std.mem.trimEnd(u8, cfg.base_url, "/")});
        defer gpa.free(url);
        if (std.mem.indexOfAny(u8, cfg.model, "\r\n") != null) return error.WebSocketHandshake;
        const routing = try routingHint(gpa, cfg.model, tier);
        defer gpa.free(routing);
        state.socket = try websocket.Connection.open(gpa, client, url, &.{
            .{ .name = "authorization", .value = bearer },
            .{ .name = "chatgpt-account-id", .value = auth.account_id },
            .{ .name = "OpenAI-Beta", .value = "responses_websockets=2026-02-06" },
            .{ .name = "originator", .value = "nib" },
            .{ .name = "session-id", .value = cache_key },
            .{ .name = "x-client-request-id", .value = cache_key },
            .{ .name = "x-codex-routing-hint", .value = routing },
        }, monitor);
        state.scope = scope;
    }
    const socket = &state.socket.?;
    monitor.attach(socket.connection);
    defer monitor.detach(socket.connection);
    var observed = try socket.observe(gpa, monitor, sink);
    defer socket.saveReader(&observed.reader);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (0..2) |attempt| {
        const payload = try state.payload(arena.allocator(), body, attempt != 0);
        try socket.send(1, payload);
        const reply = readEvents(gpa, out, &observed.reader, sink, cancel, detail, socket, body) catch |err| {
            if (err == error.PreviousResponseNotFound and attempt == 0 and state.last.incremental and !forward.emitted) {
                state.clearPrevious(gpa);
                state.last.fallback_reason = "previous_response_not_found";
                state.last.fallback_at = @intCast(@divFloor(std.Io.Clock.real.now(client.io).nanoseconds, std.time.ns_per_ms));
                try forward.sink.fallback(state.last);
                if (detail.*) |d| gpa.free(d);
                detail.* = null;
                continue;
            }
            return if (err == error.PreviousResponseNotFound) error.ProviderFailed else err;
        };
        return reply;
    }
    unreachable;
}

fn routingHint(gpa: std.mem.Allocator, model: []const u8, tier: ?[]const u8) ![]u8 {
    return if (tier) |value|
        std.fmt.allocPrint(gpa, "model={s};tier={s}", .{ model, value })
    else
        std.fmt.allocPrint(gpa, "model={s}", .{model});
}

fn streamSse(gpa: std.mem.Allocator, out: std.mem.Allocator, client: *std.http.Client, cfg: p.Config, cache_key: []const u8, messages: []const p.Message, tools_json: []const u8, max_tokens: ?u32, sink: p.Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8, monitor: *idle.Monitor) !p.Reply {
    const body = try requestBody(gpa, client.io, cfg, cache_key, messages, tools_json, max_tokens);
    defer gpa.free(body);
    const url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, cfg.base_url, "/"), if (cfg.provider == .codex) "codex/responses" else "responses" });
    defer gpa.free(url);
    var rejected: ?[]u8 = null;
    defer if (rejected) |token| gpa.free(token);
    for (0..2) |attempt| {
        var auth: ?login.Login = if (cfg.provider == .codex) try credentials(gpa, client, cfg, detail, rejected) else null;
        defer if (auth) |*value| value.deinit();
        const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{if (auth) |value| value.access_token else cfg.api_key});
        defer gpa.free(bearer);
        const routing = if (cfg.codexServiceTier()) |tier| try routingHint(gpa, cfg.model, tier) else null;
        defer if (routing) |value| gpa.free(value);
        const codex_headers = [_]std.http.Header{
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "chatgpt-account-id", .value = if (auth) |value| value.account_id else "" },
            .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
            .{ .name = "originator", .value = "nib" },
            .{ .name = "session-id", .value = cache_key },
            .{ .name = "x-client-request-id", .value = cache_key },
            .{ .name = "x-codex-routing-hint", .value = routing orelse "" },
        };
        const header_count: usize = if (auth == null) 1 else if (routing == null) codex_headers.len - 1 else codex_headers.len;
        var req = try client.request(.POST, try std.Uri.parse(url), .{
            .redirect_behavior = .not_allowed,
            .headers = .{ .authorization = if (auth != null or cfg.api_key.len > 0) .{ .override = bearer } else .omit, .content_type = .{ .override = "application/json" }, .accept_encoding = .omit },
            .extra_headers = codex_headers[0..header_count],
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.len };
        var writer = try req.sendBodyUnflushed(&.{});
        try writer.writer.writeAll(body);
        try writer.end();
        try req.connection.?.flush();
        monitor.attach(req.connection.?);
        defer monitor.detach(req.connection.?);
        var response = try req.receiveHead(&.{});
        const buffer = try gpa.alloc(u8, 64 * 1024);
        defer gpa.free(buffer);
        const reader = response.reader(buffer);
        const status = @backingInt(response.head.status);
        if (status == 401) {
            if (cfg.provider != .codex) {
                detail.* = try std.fmt.allocPrint(gpa, "{s}: HTTP 401; check {s}.", .{ cfg.name(), cfg.keyHint() });
                return error.HttpStatus;
            }
            if (attempt == 0) {
                rejected = try gpa.dupe(u8, auth.?.access_token);
                continue;
            }
            detail.* = try gpa.dupe(u8, "Codex authentication expired or was revoked (HTTP 401); run nib login codex to log in again.");
            return error.HttpStatus;
        }
        if (response.head.status.class() != .success) {
            detail.* = try std.fmt.allocPrint(gpa, "Codex request failed (HTTP {d})", .{status});
            return if (status == 429 or status >= 500) error.HttpTransient else error.HttpStatus;
        }
        var observed = try body_reader.Reader.init(gpa, reader, monitor, sink);
        defer observed.deinit(gpa);
        return readStream(gpa, out, &observed.reader, sink, cancel, detail);
    }
    unreachable;
}

const InputItem = struct { type: []const u8, text: ?[]const u8 = null, image_url: ?[]const u8 = null };

fn appendInputItems(a: std.mem.Allocator, list: *std.ArrayList(InputItem), parts: []const image.Part) !void {
    for (parts) |part| switch (part) {
        .text => |text| try list.append(a, .{ .type = "input_text", .text = text }),
        .data => try list.append(a, .{ .type = "input_image", .image_url = try part.dataUrl(a) }),
    };
}

/// Only OpenAI's own Responses accept images inside tool outputs.
fn toolOutputImages(cfg: p.Config) bool {
    return cfg.provider == .codex or cfg.provider == .openai;
}

pub fn requestBody(gpa: std.mem.Allocator, io: std.Io, cfg: p.Config, cache_key: []const u8, messages: []const p.Message, tools_json: []const u8, max_tokens: ?u32) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var input: std.Io.Writer.Allocating = .init(a);
    const w = &input.writer;
    try w.writeByte('[');
    var separator: []const u8 = "";
    var instructions: []const u8 = "You are a helpful assistant.";
    var pending_images: std.ArrayList(InputItem) = .empty;
    for (messages, 0..) |m, index| {
        if (std.mem.eql(u8, m.role, "system")) {
            instructions = m.content orelse instructions;
            continue;
        }
        if (m.reasoning) |r| if (r.compatible(cfg)) {
            const items = try std.json.parseFromSliceLeaky([]const std.json.Value, a, r.data, .{});
            for (items) |raw| {
                const item = if (r.includes_output) (try ws_state.normalize(a, raw) orelse return error.InvalidResponse) else raw;
                try w.print("{s}{f}", .{ separator, std.json.fmt(item, .{}) });
                separator = ",";
            }
            if (r.includes_output) continue;
        };
        if (std.mem.eql(u8, m.role, "tool")) {
            const custom = blk: {
                for (messages[0..index]) |previous| {
                    for (previous.tool_calls orelse &.{}) |call| {
                        if (m.tool_call_id != null and std.mem.eql(u8, call.id, m.tool_call_id.?)) break :blk std.mem.eql(u8, call.type, "custom");
                    }
                }
                break :blk false;
            };
            const kind: []const u8 = if (custom) "custom_tool_call_output" else "function_call_output";
            if (m.images) |images| {
                var list: std.ArrayList(InputItem) = .empty;
                const parts = try image.parts(a, io, images, cfg.vision());
                if (toolOutputImages(cfg)) {
                    try list.append(a, .{ .type = "input_text", .text = m.content orelse "" });
                    try appendInputItems(a, &list, parts);
                    try w.print("{s}{f}", .{ separator, std.json.fmt(.{ .type = kind, .call_id = m.tool_call_id, .output = list.items }, .{ .emit_null_optional_fields = false }) });
                } else {
                    try w.print("{s}{f}", .{ separator, std.json.fmt(.{ .type = kind, .call_id = m.tool_call_id, .output = m.content orelse "" }, .{}) });
                    for (images, parts) |source, part| {
                        try pending_images.append(a, .{ .type = "input_text", .text = try std.fmt.allocPrint(a, "[tool result image: {s}]", .{source.name}) });
                        try appendInputItems(a, &pending_images, &.{part});
                    }
                }
            } else try w.print("{s}{f}", .{ separator, std.json.fmt(.{ .type = kind, .call_id = m.tool_call_id, .output = m.content orelse "" }, .{}) });
            separator = ",";
            if (pending_images.items.len > 0 and !(index + 1 < messages.len and std.mem.eql(u8, messages[index + 1].role, "tool"))) {
                try w.print(",{f}", .{std.json.fmt(.{ .role = "user", .content = pending_images.items }, .{ .emit_null_optional_fields = false })});
                pending_images.clearRetainingCapacity();
            }
            continue;
        }
        if (m.images) |images| {
            var list: std.ArrayList(InputItem) = .empty;
            try list.append(a, .{ .type = "input_text", .text = m.content orelse "" });
            try appendInputItems(a, &list, try image.parts(a, io, images, cfg.vision()));
            try w.print("{s}{f}", .{ separator, std.json.fmt(.{ .role = m.role, .content = list.items, .phase = m.phase }, .{ .emit_null_optional_fields = false }) });
            separator = ",";
        } else if (m.content) |text| if (text.len > 0) {
            const content = if (max_tokens != null and std.mem.eql(u8, m.role, "user") and index == messages.len - 1)
                try std.fmt.allocPrint(a, "{s}\nKeep the summary within {d} tokens.", .{ text, max_tokens.? })
            else
                text;
            try w.print("{s}{f}", .{ separator, std.json.fmt(.{ .role = m.role, .content = content, .phase = m.phase }, .{ .emit_null_optional_fields = false }) });
            separator = ",";
        };
        for (m.tool_calls orelse &.{}) |call| {
            if (std.mem.eql(u8, call.type, "custom")) {
                const args = try std.json.parseFromSliceLeaky(struct { code: []const u8 }, a, call.function.arguments, .{ .ignore_unknown_fields = true });
                try w.print("{s}{f}", .{ separator, std.json.fmt(.{ .type = "custom_tool_call", .call_id = call.id, .name = call.function.name, .input = args.code }, .{}) });
            } else {
                try w.print("{s}{f}", .{ separator, std.json.fmt(.{ .type = "function_call", .call_id = call.id, .name = call.function.name, .arguments = call.function.arguments }, .{}) });
            }
            separator = ",";
        }
    }
    try w.writeByte(']');
    const tools = try std.json.parseFromSliceLeaky([]const struct { function: struct { name: []const u8, description: []const u8, parameters: std.json.Value } }, a, tools_json, .{ .ignore_unknown_fields = true });
    var tool_writer: std.Io.Writer.Allocating = .init(a);
    try tool_writer.writer.writeByte('[');
    for (tools, 0..) |tool, i| {
        if (i != 0) try tool_writer.writer.writeByte(',');
        if (cfg.customRun() and std.mem.eql(u8, tool.function.name, "run")) {
            try tool_writer.writer.print("{f}", .{std.json.fmt(.{ .type = "custom", .name = "run", .description = custom_run_description, .format = .{ .type = "grammar", .syntax = "lark", .definition = custom_run_grammar } }, .{})});
        } else {
            try tool_writer.writer.print("{f}", .{std.json.fmt(.{ .type = "function", .name = tool.function.name, .description = tool.function.description, .parameters = tool.function.parameters, .strict = false }, .{})});
        }
    }
    try tool_writer.writer.writeByte(']');
    const effort = reasoningEffort(cfg);
    const reasoning = if (effort != null or cfg.reasoning_summary == .auto) try std.fmt.allocPrint(a, ",\"reasoning\":{f}", .{std.json.fmt(.{ .effort = effort, .summary = if (cfg.reasoning_summary == .auto) @as(?[]const u8, "auto") else null }, .{ .emit_null_optional_fields = false })}) else "";
    const format = if (cfg.output_schema) |schema|
        try std.fmt.allocPrint(a, ",\"text\":{f}", .{std.json.fmt(.{ .format = .{ .type = "json_schema", .name = "result", .strict = true, .schema = schema } }, .{})})
    else
        "";
    const service_tier = if (cfg.codexServiceTier()) |tier| try std.fmt.allocPrint(a, ",\"service_tier\":{f}", .{std.json.fmt(tier, .{})}) else "";
    return std.fmt.allocPrint(gpa,
        \\{{"model":{f},"prompt_cache_key":{f},"store":false,"stream":true,"instructions":{f},"input":{s},"include":["reasoning.encrypted_content"]{s}{s}{s}{s}}}
    , .{ std.json.fmt(cfg.model, .{}), std.json.fmt(cache_key, .{}), std.json.fmt(instructions, .{}), input.written(), if (tools.len == 0) "" else try std.fmt.allocPrint(a, ",\"tools\":{s}", .{tool_writer.written()}), reasoning, format, service_tier });
}

test "Responses only requests Fast for supported Codex GPT models when enabled" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { id: p.Id, model: []const u8, enabled: bool, priority: bool }{
        .{ .id = .codex, .model = "gpt-6.2-sol", .enabled = true, .priority = true },
        .{ .id = .codex, .model = "gpt-6.1-sol", .enabled = false, .priority = false },
        .{ .id = .codex, .model = "unknown-model", .enabled = true, .priority = false },
        .{ .id = .openai, .model = "gpt-6.1-sol", .enabled = true, .priority = false },
        .{ .id = .xai, .model = "grok-4.7", .enabled = true, .priority = false },
    };
    for (cases) |case| {
        const cfg: p.Config = .{ .provider = case.id, .model = case.model, .base_url = "", .api_key = "", .codex_fast = case.enabled };
        const body = try requestBody(a, t.io, cfg, "key", &.{}, "[]", null);
        const value = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        const tier = value.object.get("service_tier");
        if (case.priority) try t.expectEqualStrings("priority", tier.?.string) else try t.expect(tier == null);
    }
}

const custom_run_description = "Run JavaScript in a fresh sandbox using the tools API described in the system prompt. Send raw JavaScript, not JSON, a quoted string or markdown fences. Top-level await is allowed; the last expression's value is returned.";

const custom_run_grammar =
    \\start: SOURCE
    \\SOURCE: /[\s\S]+/
;

const Output = struct {
    type: []const u8,
    phase: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    input: ?[]const u8 = null,
};
const StreamError = struct {
    code: ?std.json.Value = null,
    message: ?[]const u8 = null,
    type: ?[]const u8 = null,
    status: ?u16 = null,
    status_code: ?u16 = null,
};
const ResponseEvent = struct {
    type: []const u8,
    @"error": ?StreamError = null,
    headers: ?std.json.Value = null,
    code: ?std.json.Value = null,
    message: ?[]const u8 = null,
    status: ?u16 = null,
    status_code: ?u16 = null,
    delta: ?[]const u8 = null,
    output_index: usize = 0,
    item: ?std.json.Value = null,
    response: ?struct {
        id: ?[]const u8 = null,
        status: ?[]const u8 = null,
        @"error": ?StreamError = null,
        incomplete_details: ?struct { reason: ?[]const u8 = null } = null,
        usage: ?struct {
            input_tokens: u64 = 0,
            output_tokens: u64 = 0,
            input_tokens_details: ?struct { cached_tokens: u64 = 0, cache_write_tokens: u64 = 0 } = null,
        } = null,
    } = null,
};

fn readStream(gpa: std.mem.Allocator, out: std.mem.Allocator, reader: *std.Io.Reader, sink: p.Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !p.Reply {
    return readEvents(gpa, out, reader, sink, cancel, detail, null, "");
}

fn readEvents(gpa: std.mem.Allocator, out: std.mem.Allocator, reader: *std.Io.Reader, sink: p.Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8, socket: ?*websocket.Connection, body: []const u8) anyerror!p.Reply {
    var parser: sse.Parser = .{};
    defer parser.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var items: std.ArrayList(?std.json.Value) = .empty;
    defer items.deinit(gpa);
    var pending: usize = 0;
    var usage: p.Usage = .{};
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var event_type: []const u8 = "before_event";
    var event_index: usize = 0;
    var stage: []const u8 = "parse";
    errdefer if (detail.* == null) {
        detail.* = std.fmt.allocPrint(gpa, "Codex stream context: stage={s}, event={s}, output_index={d}, items={d}, pending={d}", .{ stage, event_type, event_index, items.items.len, pending }) catch null;
    };
    while (true) {
        if (cancel.load(.acquire)) return error.Canceled;
        if (sink.monitor) |monitor| try monitor.check();
        stage = "parse";
        const data = if (socket) |ws| ws.message(reader, &line) catch |err| {
            if (sink.codex_state) |state| {
                state.stale_socket = state.reused and std.mem.eql(u8, event_type, "before_event") and
                    (err == error.WebSocketClosed or err == error.EndOfStream);
            }
            detail.* = try std.fmt.allocPrint(gpa, "Codex WebSocket read failed: {s}; last event={s}, output_index={d}", .{ @errorName(err), event_type, event_index });
            return err;
        } else data: {
            line.clearRetainingCapacity();
            _ = reader.streamDelimiter(&line.writer, '\n') catch |err| switch (err) {
                error.EndOfStream => return incompleteResponse(gpa, detail),
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            reader.toss(1);
            break :data (try parser.feed(gpa, line.written())) orelse continue;
        };
        const ev = std.json.parseFromSliceLeaky(ResponseEvent, a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
            detail.* = try std.fmt.allocPrint(gpa, "Codex event decode failed: {s}; last event={s}, output_index={d}", .{ @errorName(err), event_type, event_index });
            return error.InvalidResponse;
        };
        event_type = ev.type;
        event_index = ev.output_index;
        stage = "event";
        if (sink.monitor) |monitor| {
            if (ev.delta) |delta| {
                if (std.mem.eql(u8, ev.type, "response.output_text.delta") or std.mem.eql(u8, ev.type, "response.refusal.delta") or
                    std.mem.eql(u8, ev.type, "response.reasoning_summary_text.delta") or std.mem.eql(u8, ev.type, "response.reasoning_text.delta") or
                    std.mem.eql(u8, ev.type, "response.function_call_arguments.delta") or std.mem.eql(u8, ev.type, "response.custom_tool_call_input.delta")) monitor.content(delta.len);
            }
        }
        if (ev.delta) |delta| {
            if (delta.len > 0 and (std.mem.eql(u8, ev.type, "response.function_call_arguments.delta") or std.mem.eql(u8, ev.type, "response.custom_tool_call_input.delta"))) try sink.toolArguments();
        }
        if (socket) |ws| if (ws.turn_state == null and std.mem.eql(u8, ev.type, "response.metadata")) {
            if (ev.headers) |headers| if (headers == .object) {
                var it = headers.object.iterator();
                while (it.next()) |entry| {
                    if (!std.ascii.eqlIgnoreCase(entry.key_ptr.*, "x-codex-turn-state")) continue;
                    var value = entry.value_ptr.*;
                    while (value == .array and value.array.items.len > 0) value = value.array.items[0];
                    if (value == .string and std.mem.indexOfAny(u8, value.string, "\r\n") == null) ws.turn_state = try gpa.dupe(u8, value.string);
                    break;
                }
            };
        };
        if (sink.timing) |timing| observeTiming(timing, ev);
        if (std.mem.eql(u8, ev.type, "response.output_text.delta") or std.mem.eql(u8, ev.type, "response.refusal.delta")) {
            const delta = ev.delta orelse return error.InvalidResponse;
            try text.appendSlice(gpa, delta);
            try sink.onDelta(sink.ctx, .text, delta);
        } else if (std.mem.eql(u8, ev.type, "response.reasoning_summary_text.delta") or std.mem.eql(u8, ev.type, "response.reasoning_text.delta")) {
            try sink.onDelta(sink.ctx, .reasoning, ev.delta orelse return error.InvalidResponse);
        } else if (std.mem.eql(u8, ev.type, "response.output_item.added")) {
            pending += 1;
        } else if (std.mem.eql(u8, ev.type, "response.output_item.done")) {
            stage = "output_item.done";
            if (ev.output_index > 256) return error.InvalidResponse;
            while (items.items.len <= ev.output_index) try items.append(gpa, null);
            if (items.items[ev.output_index] != null) return error.InvalidResponse;
            items.items[ev.output_index] = ev.item orelse return error.InvalidResponse;
            pending -|= 1;
        } else if (std.mem.eql(u8, ev.type, "response.failed") or std.mem.eql(u8, ev.type, "error") or std.mem.eql(u8, ev.type, "response.incomplete")) {
            return streamFailure(gpa, ev, detail);
        } else if (std.mem.eql(u8, ev.type, "response.completed") or std.mem.eql(u8, ev.type, "response.done")) {
            const response = ev.response orelse return error.InvalidResponse;
            if (response.status) |status| if (!std.mem.eql(u8, status, "completed")) {
                return streamFailure(gpa, ev, detail);
            };
            if (pending != 0) return incompleteResponse(gpa, detail);
            if (socket != null) if (sink.codex_state) |state| try state.remember(gpa, body, response.id, items.items);
            if (response.usage) |u| usage = .{ .prompt_tokens = u.input_tokens, .completion_tokens = u.output_tokens, .prompt_cache_hit_tokens = if (u.input_tokens_details) |d| d.cached_tokens else 0, .prompt_cache_write_tokens = if (u.input_tokens_details) |d| d.cache_write_tokens else 0 };
            break;
        }
    }
    var calls: std.ArrayList(p.ToolCall) = .empty;
    defer calls.deinit(gpa);
    var reasoning: std.ArrayList(std.json.Value) = .empty;
    defer reasoning.deinit(gpa);
    var replayable = true;
    var phase: ?[]const u8 = null;
    stage = "assemble_output";
    for (items.items, 0..) |maybe, index| {
        const item = maybe orelse return error.InvalidResponse;
        const value = try std.json.parseFromValueLeaky(Output, a, item, .{ .ignore_unknown_fields = true });
        if (try ws_state.normalize(a, item) == null) replayable = false;
        if (std.mem.eql(u8, value.type, "message")) {
            if (value.phase) |v| phase = try out.dupe(u8, v);
        } else if (std.mem.eql(u8, value.type, "reasoning")) {
            try reasoning.append(gpa, item);
        } else if (std.mem.eql(u8, value.type, "function_call") or std.mem.eql(u8, value.type, "custom_tool_call")) {
            if (calls.items.len >= 64) return error.TooManyToolCalls;
            if (sink.timing) |timing| timing.bind(index, calls.items.len);
            const custom = std.mem.eql(u8, value.type, "custom_tool_call");
            const arguments = if (custom) try std.json.Stringify.valueAlloc(out, .{ .code = value.input orelse return error.InvalidResponse }, .{}) else try out.dupe(u8, value.arguments orelse return error.InvalidResponse);
            try calls.append(gpa, .{ .id = try out.dupe(u8, value.call_id orelse return error.InvalidResponse), .type = if (custom) "custom" else "function", .function = .{ .name = try out.dupe(u8, value.name orelse return error.InvalidResponse), .arguments = arguments } });
        }
    }
    return .{ .text = try out.dupe(u8, text.items), .phase = phase, .reasoning = if (replayable and items.items.len > 0) .{ .provider = .codex, .data = try std.json.Stringify.valueAlloc(out, items.items, .{}), .includes_output = true } else if (reasoning.items.len > 0) .{ .provider = .codex, .data = try std.json.Stringify.valueAlloc(out, reasoning.items, .{}) } else null, .tool_calls = try out.dupe(p.ToolCall, calls.items), .usage = usage };
}

fn observeTiming(timing: *p.ModelTiming, ev: ResponseEvent) void {
    if (std.mem.eql(u8, ev.type, "response.function_call_arguments.delta") or std.mem.eql(u8, ev.type, "response.custom_tool_call_input.delta")) {
        if (ev.delta) |delta| timing.arguments(ev.output_index, delta.len);
    } else if (std.mem.eql(u8, ev.type, "response.output_item.added") or std.mem.eql(u8, ev.type, "response.output_item.done")) {
        const item = ev.item orelse return;
        if (item != .object) return;
        const kind = item.object.get("type") orelse return;
        if (kind != .string) return;
        const key: []const u8 = if (std.mem.eql(u8, kind.string, "function_call")) "arguments" else if (std.mem.eql(u8, kind.string, "custom_tool_call")) "input" else return;
        const args = item.object.get(key) orelse return;
        if (args != .string) return;
        if (std.mem.eql(u8, ev.type, "response.output_item.added")) {
            timing.arguments(ev.output_index, args.string.len);
        } else {
            timing.finalArguments(ev.output_index, args.string.len);
        }
    }
}

fn incompleteResponse(gpa: std.mem.Allocator, detail: *?[]u8) anyerror {
    detail.* = std.fmt.allocPrint(gpa, "Codex stream failed: IncompleteResponse: the stream ended before a complete response; the Step was not committed.", .{}) catch return error.OutOfMemory;
    return error.IncompleteResponse;
}

fn streamFailure(gpa: std.mem.Allocator, ev: ResponseEvent, detail: *?[]u8) anyerror {
    var failure: StreamError = .{ .code = ev.code, .message = ev.message, .status = ev.status, .status_code = ev.status_code };
    if (ev.@"error") |err| {
        failure = err;
        failure.status = failure.status orelse ev.status;
        failure.status_code = failure.status_code orelse ev.status_code;
    }
    var reason: ?[]const u8 = null;
    if (ev.response) |response| {
        if (response.@"error") |err| failure = err;
        if (response.incomplete_details) |incomplete| reason = incomplete.reason;
    }
    var number: [32]u8 = undefined;
    const code = if (reason) |r| r else if (failure.code) |value| switch (value) {
        .string => value.string,
        .integer => std.fmt.bufPrint(&number, "{d}", .{value.integer}) catch "unknown",
        else => failure.type orelse "unknown",
    } else failure.type orelse "unknown";
    const message = failure.message orelse reason orelse "No error message was provided";
    const status = failure.status_code orelse failure.status orelse statusFromCode(code);
    const fatal = fatalStreamCode(code) or (status >= 400 and status < 500 and status != 429);
    const limited = !fatal and (std.mem.eql(u8, code, "rate_limit_exceeded") or status == 429);
    var hint: ?[]u8 = null;
    defer if (hint) |s| gpa.free(s);
    var shown = clipMessage(message, 300);
    if (limited and shown.len < message.len and retryDelayMs(shown) == null) {
        if (retryDelayMs(message)) |ms| {
            hint = std.fmt.allocPrint(gpa, "{s}… try again in {d}ms", .{ clipMessage(message, 260), ms }) catch return error.OutOfMemory;
            shown = hint.?;
        }
    }
    detail.* = std.fmt.allocPrint(gpa, "Codex stream failed: {s}: {s}; the Step was not committed.", .{ code, shown }) catch return error.OutOfMemory;
    if (std.mem.eql(u8, code, "previous_response_not_found")) return error.PreviousResponseNotFound;
    if (std.mem.eql(u8, code, "websocket_connection_limit_reached")) return error.WebSocketConnectionLimit;
    return if (fatal) error.ProviderFailed else if (limited) error.RateLimited else error.ProviderTransient;
}

fn clipMessage(message: []const u8, limit: usize) []const u8 {
    var end = @min(message.len, limit);
    while (end > 0 and end < message.len and (message[end] & 0xc0) == 0x80) end -= 1;
    return message[0..end];
}

fn statusFromCode(code: []const u8) u16 {
    const digits = if (std.mem.startsWith(u8, code, "http_") or std.mem.startsWith(u8, code, "HTTP ")) code[5..] else code;
    if (digits.len != 3) return 0;
    return std.fmt.parseInt(u16, digits, 10) catch 0;
}

fn fatalStreamCode(code: []const u8) bool {
    for ([_][]const u8{
        "context_length_exceeded", "insufficient_quota", "usage_not_included", "invalid_prompt",
        "invalid_request_error",   "invalid_request",    "bad_request",        "unauthorized",
        "authentication_error",    "invalid_api_key",    "permission_denied",  "forbidden",
        "not_found",               "method_not_allowed", "request_too_large",  "unsupported_media_type",
        "unprocessable_entity",
    }) |known| if (std.mem.eql(u8, code, known)) return true;
    return false;
}

pub fn retryDelayMs(message: []const u8) ?u64 {
    const needle = "try again in ";
    if (message.len < needle.len) return null;
    for (0..message.len - needle.len + 1) |start| {
        if (!std.ascii.eqlIgnoreCase(message[start..][0..needle.len], needle)) continue;
        const rest = std.mem.trimStart(u8, message[start + needle.len ..], " \t");
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isDigit(rest[end]) or rest[end] == '.')) end += 1;
        if (end == 0) continue;
        const duration = std.fmt.parseFloat(f64, rest[0..end]) catch continue;
        const unit = std.mem.trimStart(u8, rest[end..], " \t");
        const ms = duration * @as(f64, if (std.mem.startsWith(u8, unit, "ms")) 1 else if (std.mem.startsWith(u8, unit, "s")) 1000 else continue);
        if (!std.math.isFinite(ms) or ms < 0 or ms >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) continue;
        return @intFromFloat(@ceil(ms));
    }
    return null;
}

test "Codex catalog context windows" {
    try std.testing.expectEqualStrings("gpt-6.2-sol", default_model);
    try std.testing.expectEqual(@as(u64, 500_000), try contextWindow("gpt-6.2-sol"));
    try std.testing.expectEqual(@as(u64, 272_000), try contextWindow("gpt-6.2-astra"));
    try std.testing.expectEqual(@as(u64, 500_000), try contextWindow("gpt-6.1-sol"));
    try std.testing.expectEqual(@as(u64, 272_000), try contextWindow("gpt-6-sol"));
    try std.testing.expectError(error.UnknownCodexModelContextWindow, contextWindow("unknown"));
}

test "Codex reasoning mapping and readable summaries" {
    const t = std.testing;
    var cfg: p.Config = .{ .provider = .codex, .model = default_model, .api_key = "", .base_url = "" };
    try t.expectEqual(@as(?[]const u8, null), reasoningEffort(cfg));
    cfg.thinking = true;
    try t.expectEqualStrings("medium", reasoningEffort(cfg).?);
    cfg.reasoning_effort = "high";
    try t.expectEqualStrings("high", reasoningEffort(cfg).?);
    cfg.thinking = false;
    try t.expectEqualStrings("low", reasoningEffort(cfg).?);
    cfg.model = "gpt-6.1-terra";
    try t.expectEqualStrings("none", reasoningEffort(cfg).?);
    try t.expect(!modelInfo("gpt-6.1-sol").?.can_disable_reasoning);
}

test "Codex request body defaults to no summary and supports opt in" {
    const t = std.testing;
    const cases = [_]struct {
        model: []const u8 = default_model,
        thinking: ?bool = null,
        effort: ?[]const u8 = null,
        expected_effort: ?[]const u8 = null,
    }{
        .{},
        .{ .thinking = true, .expected_effort = "medium" },
        .{ .effort = "high", .expected_effort = "high" },
        .{ .thinking = false, .expected_effort = "low" },
        .{ .model = "gpt-6.2-astra", .thinking = false, .expected_effort = "low" },
        .{ .model = "gpt-6.1-sol", .thinking = false, .expected_effort = "low" },
        .{ .model = "gpt-6.1-terra", .thinking = false, .expected_effort = "none" },
        .{ .effort = "none", .expected_effort = "none" },
    };
    for (cases) |case| for ([_]@FieldType(p.Config, "reasoning_summary"){ .off, .auto }) |summary| {
        const cfg: p.Config = .{
            .provider = .codex,
            .model = case.model,
            .api_key = "",
            .base_url = "",
            .thinking = case.thinking,
            .reasoning_effort = case.effort,
            .reasoning_summary = summary,
        };
        const body = try requestBody(t.allocator, t.io, cfg, "cache-key", &.{}, "[]", null);
        defer t.allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try t.expect(!root.contains("summary"));
        try t.expect(!root.get("store").?.bool);
        try t.expectEqualStrings("reasoning.encrypted_content", root.get("include").?.array.items[0].string);
        if (case.expected_effort != null or summary == .auto) {
            const reasoning = root.get("reasoning").?.object;
            if (case.expected_effort) |effort| try t.expectEqualStrings(effort, reasoning.get("effort").?.string) else try t.expect(!reasoning.contains("effort"));
            if (summary == .auto) try t.expectEqualStrings("auto", reasoning.get("summary").?.string) else try t.expect(!reasoning.contains("summary"));
        } else {
            try t.expect(!root.contains("reasoning"));
        }
    };
}

test "Codex request body carries the session cache key" {
    const t = std.testing;
    const cfg: p.Config = .{ .provider = .codex, .model = default_model, .api_key = "", .base_url = "" };
    const cache_key = "0123456789abcdef0123456789abcdef";
    const body = try requestBody(t.allocator, t.io, cfg, cache_key, &.{.{ .role = "user", .content = "hello" }}, "[]", null);
    defer t.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
    defer parsed.deinit();
    try t.expectEqualStrings(cache_key, parsed.value.object.get("prompt_cache_key").?.string);
}

test "Codex custom and legacy history retain their wire types across tool configuration changes" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const code = "// @run: {\"effort\":\"low\"}\nconst text = `line one\n${1}\\path`; text";
    const args = try std.json.Stringify.valueAlloc(a, .{ .code = code }, .{});
    const old_args = "{\"code\":\"42\",\"effort\":\"high\"}";
    const custom: p.ToolCall = .{ .id = "new", .type = "custom", .function = .{ .name = "run", .arguments = args } };
    const raw = try std.json.Stringify.valueAlloc(a, .{.{ .type = "custom_tool_call", .id = "server-id", .status = "completed", .call_id = "new", .name = "run", .input = code }}, .{});
    for ([_]@FieldType(p.Config, "codex_run_tool"){ .custom, .function }) |mode| for ([_]bool{ false, true }) |includes_output| {
        const messages = [_]p.Message{
            .{ .role = "assistant", .tool_calls = &.{.{ .id = "old", .function = .{ .name = "run", .arguments = old_args } }} },
            .{ .role = "tool", .tool_call_id = "old", .content = "42" },
            .{ .role = "assistant", .tool_calls = &.{custom}, .reasoning = if (includes_output) .{ .provider = .codex, .data = raw, .includes_output = true, .model = default_model } else null },
            .{ .role = "tool", .tool_call_id = "new", .content = "result" },
        };
        const cfg: p.Config = .{ .provider = .codex, .model = default_model, .api_key = "", .base_url = "", .codex_run_tool = mode };
        const body = try requestBody(a, t.io, cfg, "key", &messages, @import("../session/prompt.zig").tools_json, null);
        const root = (try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{})).object;
        const input = root.get("input").?.array.items;
        try t.expectEqual(@as(usize, 4), input.len);
        inline for (.{ "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output" }, 0..) |kind, i| try t.expectEqualStrings(kind, input[i].object.get("type").?.string);
        try t.expectEqualStrings(old_args, input[0].object.get("arguments").?.string);
        try t.expectEqualStrings(code, input[2].object.get("input").?.string);
        try t.expect(!input[2].object.contains("id") and !input[2].object.contains("status"));
        const tool = root.get("tools").?.array.items[0].object;
        try t.expectEqualStrings(@tagName(mode), tool.get("type").?.string);
        if (mode == .custom) {
            try t.expectEqualStrings(custom_run_grammar, tool.get("format").?.object.get("definition").?.string);
            try t.expect(!tool.contains("parameters"));
        } else {
            try t.expect(tool.contains("parameters") and !tool.get("strict").?.bool);
        }
    };
}

fn expectStreamFailure(json: []const u8, expected: anyerror, code: []const u8, message: []const u8) !void {
    const t = std.testing;
    const Sink = struct {
        fn delta(_: *anyopaque, _: p.Kind, _: []const u8) !void {}
    };
    const bytes = try std.fmt.allocPrint(t.allocator, "data: {s}\n\n", .{json});
    defer t.allocator.free(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var cancel: std.atomic.Value(bool) = .init(false);
    var detail: ?[]u8 = null;
    defer if (detail) |text| t.allocator.free(text);
    try t.expectError(expected, readStream(t.allocator, t.allocator, &reader, .{ .ctx = &cancel, .onDelta = Sink.delta }, &cancel, &detail));
    try t.expect(std.mem.indexOf(u8, detail.?, code) != null);
    try t.expect(std.mem.indexOf(u8, detail.?, message) != null);
    try t.expect(std.mem.endsWith(u8, detail.?, "; the Step was not committed."));
}

test "Codex stream errors preserve reasons and distinguish retryable failures" {
    try expectStreamFailure("{\"type\":\"error\",\"code\":\"server_error\",\"message\":\"service broke\"}", error.ProviderTransient, "server_error", "service broke");
    try expectStreamFailure("{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"too much context\"}}}", error.ProviderFailed, "context_length_exceeded", "too much context");
    try expectStreamFailure("{\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"usage_not_included\"}}}", error.ProviderFailed, "usage_not_included", "usage_not_included");
    try expectStreamFailure("{\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}", error.ProviderTransient, "max_output_tokens", "max_output_tokens");
    try expectStreamFailure("{\"type\":\"error\",\"code\":\"rate_limit_exceeded\",\"message\":\"try again in 30ms\"}", error.RateLimited, "rate_limit_exceeded", "try again in 30ms");
    try expectStreamFailure("{\"type\":\"response.completed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"invalid_prompt\",\"message\":\"bad prompt\"}}}", error.ProviderFailed, "invalid_prompt", "bad prompt");
    try expectStreamFailure("{\"type\":\"error\",\"code\":400,\"message\":\"bad request\"}", error.ProviderFailed, "400", "bad request");
    try expectStreamFailure("{\"type\":\"error\",\"status_code\":403,\"message\":\"denied\"}", error.ProviderFailed, "unknown", "denied");
    try expectStreamFailure("{\"type\":\"error\",\"code\":\"new_server_code\",\"message\":\"unknown issue\"}", error.ProviderTransient, "new_server_code", "unknown issue");
    try expectStreamFailure("{\"type\":\"response.created\"}", error.IncompleteResponse, "IncompleteResponse", "stream ended");
    const t = std.testing;
    for ([_][]const u8{ "context_length_exceeded", "insufficient_quota", "usage_not_included", "invalid_prompt", "invalid_request_error" }) |code| try t.expect(fatalStreamCode(code));
    for ([_][]const u8{ "server_error", "overloaded", "service_unavailable", "unknown" }) |code| try t.expect(!fatalStreamCode(code));
}

test "Codex malformed events report the decoder failure without event contents" {
    const t = std.testing;
    const Sink = struct {
        fn delta(_: *anyopaque, _: p.Kind, _: []const u8) !void {}
    };
    var reader: std.Io.Reader = .fixed("data: {\"type\":\"response.custom_tool_call_input.delta\",\"delta\":42,\"private\":\"hidden\"}\n\n");
    var cancel: std.atomic.Value(bool) = .init(false);
    var detail: ?[]u8 = null;
    defer if (detail) |value| t.allocator.free(value);
    try t.expectError(error.InvalidResponse, readStream(t.allocator, t.allocator, &reader, .{ .ctx = &cancel, .onDelta = Sink.delta }, &cancel, &detail));
    try t.expect(std.mem.indexOf(u8, detail.?, "Codex event decode failed: UnexpectedToken") != null);
    try t.expect(std.mem.indexOf(u8, detail.?, "hidden") == null);
}

test "Codex errors bound UTF-8 messages and retain rate-limit hints beyond the cutoff" {
    const t = std.testing;
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(t.allocator);
    for (0..150) |_| try message.appendSlice(t.allocator, "中");
    var detail: ?[]u8 = null;
    defer if (detail) |d| t.allocator.free(d);
    try t.expectEqual(error.ProviderTransient, streamFailure(t.allocator, .{ .type = "error", .code = .{ .string = "server_error" }, .message = message.items }, &detail));
    try t.expect(std.unicode.utf8ValidateSlice(detail.?));
    try t.expect(detail.?.len < 400);
    t.allocator.free(detail.?);
    detail = null;
    try message.appendSlice(t.allocator, " try again in 0.25s");
    try t.expectEqual(error.RateLimited, streamFailure(t.allocator, .{ .type = "error", .code = .{ .string = "rate_limit_exceeded" }, .message = message.items }, &detail));
    try t.expectEqual(@as(?u64, 250), retryDelayMs(detail.?));
    try t.expect(detail.?.len < 420);
}

test "Codex retry hints accept seconds and milliseconds without overflow" {
    const t = std.testing;
    try t.expectEqual(@as(?u64, 1200), retryDelayMs("Please try again in 1.2s."));
    try t.expectEqual(@as(?u64, 25), retryDelayMs("Try again in 25ms"));
    try t.expectEqual(@as(?u64, 1), retryDelayMs("try again in 0.1ms"));
    try t.expectEqual(@as(?u64, 0), retryDelayMs("try again in 0s"));
    for ([_][]const u8{ "try again later", "try again in -1s", "try again in 1minute", "try again in 1.2.3s", "try again in 999999999999999999999999999999s" }) |message| try t.expectEqual(@as(?u64, null), retryDelayMs(message));
}

test "Codex stream activity covers non-text events and SSE heartbeats" {
    const t = std.testing;
    const State = struct {
        received: usize = 0,
        arguments: usize = 0,
        fn argument(ctx: *anyopaque) !void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            state.arguments += 1;
        }
        fn data(ctx: *anyopaque) !void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            state.received += 1;
        }
        fn delta(_: *anyopaque, _: p.Kind, _: []const u8) !void {}
    };
    const prefixes = [_][]const u8{
        ": ping\n\n",
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"text\"}\n\n",
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"reasoning\"}\n\n",
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"args\"}\n\n",
        "data: {\"type\":\"response.output_item.added\"}\n\ndata: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"content\":[]}}\n\n",
    };
    for (prefixes) |prefix| {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const input = try std.fmt.allocPrint(arena.allocator(), "{s}data: {{\"type\":\"response.completed\",\"response\":{{\"status\":\"completed\"}}}}\n\n", .{prefix});
        var reader: std.Io.Reader = .fixed(input);
        var state: State = .{};
        var cancel: std.atomic.Value(bool) = .init(false);
        var detail: ?[]u8 = null;
        defer if (detail) |d| t.allocator.free(d);
        const sink: p.Sink = .{ .ctx = &state, .onDelta = State.delta, .onData = State.data, .onToolArguments = State.argument };
        var monitor: idle.Monitor = .init(t.io, 1, null);
        var observed = try body_reader.Reader.init(t.allocator, &reader, &monitor, sink);
        defer observed.deinit(t.allocator);
        _ = try readStream(t.allocator, arena.allocator(), &observed.reader, sink, &cancel, &detail);
        try t.expectEqual(@as(usize, 1), state.received);
        try t.expectEqual(@as(usize, if (std.mem.indexOf(u8, prefix, "arguments.delta") != null) 1 else 0), state.arguments);
    }
}

test "Codex parser times argument deltas and final-only calls at sparse output indices" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const out = arena.allocator();
    var bytes: std.Io.Writer.Allocating = .init(t.allocator);
    defer bytes.deinit();
    for (0..70) |index| {
        try bytes.writer.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":{d},\"item\":{{\"type\":\"reasoning\"}}}}\n\n", .{index});
    }
    try bytes.writer.writeAll(
        "data: {\"type\":\"response.output_item.added\",\"output_index\":70,\"item\":{\"type\":\"function_call\",\"call_id\":\"streamed\",\"name\":\"run\",\"arguments\":\"\"}}\n\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":70,\"delta\":\"{\"}\n\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":70,\"delta\":\"}\"}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":70,\"item\":{\"type\":\"function_call\",\"call_id\":\"streamed\",\"name\":\"run\",\"arguments\":\"{}\"}}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":71,\"item\":{\"type\":\"function_call\",\"call_id\":\"final\",\"name\":\"run\",\"arguments\":\"{ }\"}}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":72,\"item\":{\"type\":\"function_call\",\"call_id\":\"other\",\"name\":\"search\",\"arguments\":\"{}\"}}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
    );
    const Counter = struct {
        fn delta(ctx: *anyopaque, _: p.Kind, _: []const u8) !void {
            const count: *usize = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    };
    var count: usize = 0;
    var cancel: std.atomic.Value(bool) = .init(false);
    var detail: ?[]u8 = null;
    defer if (detail) |text| t.allocator.free(text);
    var timing: p.ModelTiming = .init(t.io, .now(t.io, .awake));
    var reader: std.Io.Reader = .fixed(bytes.written());
    const reply = try readStream(t.allocator, out, &reader, .{ .ctx = &count, .onDelta = Counter.delta, .timing = &timing }, &cancel, &detail);
    try t.expectEqual(@as(usize, 0), count);
    try t.expectEqual(@as(usize, 3), reply.tool_calls.len);
    const codes = try timing.finish(out, reply.tool_calls);
    try t.expectEqual(@as(usize, 2), codes.len);
    try t.expectEqualStrings("streamed", codes[0].tool_call_id);
    try t.expectEqual(@as(usize, 2), codes[0].progress.len);
    try t.expectEqual(@as(u64, 1), codes[0].progress[0][1]);
    try t.expectEqual(@as(u64, 2), codes[0].progress[1][1]);
    try t.expectEqualStrings("final", codes[1].tool_call_id);
    try t.expectEqual(@as(usize, 1), codes[1].progress.len);
    try t.expectEqual(codes[1].first_ms, codes[1].last_ms);
    try t.expectEqual(@as(u64, 3), codes[1].progress[0][1]);
    reader = .fixed(bytes.written());
    const untimed = try readStream(t.allocator, out, &reader, .{ .ctx = &count, .onDelta = Counter.delta }, &cancel, &detail);
    try t.expectEqualStrings(try std.json.Stringify.valueAlloc(out, untimed, .{}), try std.json.Stringify.valueAlloc(out, reply, .{}));
}

test "tool-free JSON requests move system to instructions and use strict named schema" {
    const t = std.testing;
    const schema = try std.json.parseFromSlice(std.json.Value, t.allocator, "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}", .{});
    defer schema.deinit();
    const system = "Return JSON.\nUse the \"answer\" field.";
    const messages = [_]p.Message{
        .{ .role = "system", .content = system },
        .{ .role = "user", .content = "question" },
    };
    for ([_]?std.json.Value{ null, schema.value }) |output_schema| {
        const body = try requestBody(t.allocator, t.io, .{ .base_url = "", .api_key = "", .model = "m", .output_schema = output_schema }, "cache", &messages, "[]", null);
        defer t.allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try t.expect(!object.contains("tools"));
        try t.expect(!object.contains("response_format"));
        try t.expectEqualStrings(system, object.get("instructions").?.string);
        const input = object.get("input").?.array.items;
        try t.expectEqual(@as(usize, 1), input.len);
        try t.expectEqualStrings("user", input[0].object.get("role").?.string);
        try t.expectEqualStrings("question", input[0].object.get("content").?.string);
        if (output_schema != null) {
            const text = object.get("text").?.object;
            try t.expectEqual(@as(usize, 1), text.count());
            const format = text.get("format").?.object;
            try t.expectEqual(@as(usize, 4), format.count());
            try t.expectEqualStrings("json_schema", format.get("type").?.string);
            try t.expectEqualStrings("result", format.get("name").?.string);
            try t.expect(format.get("strict").?.bool);
            const actual = try std.json.Stringify.valueAlloc(t.allocator, format.get("schema").?, .{});
            defer t.allocator.free(actual);
            try t.expectEqualStrings("{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}", actual);
        } else {
            try t.expect(!object.contains("text"));
        }
    }
}

test "WebSocket protocol fallback keeps cancellation and transient failures on their existing paths" {
    const t = std.testing;
    for ([_]anyerror{ error.WebSocketHandshake, error.WebSocketProtocol, error.WebSocketMessageTooLarge }) |err| try t.expect(fallbackError(err));
    for ([_]anyerror{ error.InvalidResponse, error.Canceled, error.OutOfMemory, error.StreamIdleTimeout, error.RateLimited, error.ProviderFailed, error.WebSocketClosed, error.WebSocketConnectionLimit }) |err| try t.expect(!fallbackError(err));
}

test "Responses API custom Run is a catalog capability and xAI uses function" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = "[{\"type\":\"function\",\"function\":{\"name\":\"run\",\"description\":\"execute\",\"parameters\":{\"type\":\"object\",\"properties\":{\"code\":{\"type\":\"string\"}},\"required\":[\"code\"]}}}]";
    for ([_]p.Id{ .openai, .xai }) |id| {
        const cfg: p.Config = .{ .provider = id, .base_url = "", .api_key = "fake", .model = "model" };
        const body = try requestBody(a, t.io, cfg, "cache", &.{.{ .role = "user", .content = "task" }}, tools, null);
        const value = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        try t.expectEqualStrings(if (id == .openai) "custom" else "function", value.object.get("tools").?.array.items[0].object.get("type").?.string);
        try t.expect(!value.object.get("store").?.bool);
        try t.expect(std.mem.indexOf(u8, body, "fake") == null);
    }
}

test "Responses images use input_image and tool outputs only where the API accepts them" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const directory = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/images", .{tmp.sub_path});
    const shot = try image.store(t.io, a, directory, "shot.png", image.sample_png);
    const calls = [_]p.ToolCall{.{ .id = "call", .type = "custom", .function = .{ .name = "run", .arguments = "{\"code\":\"1\"}" } }};
    const messages = [_]p.Message{
        .{ .role = "user", .content = "look", .images = &.{shot} },
        .{ .role = "assistant", .tool_calls = &calls },
        .{ .role = "tool", .tool_call_id = "call", .content = "viewed", .images = &.{shot} },
    };
    for ([_]p.Id{ .codex, .xai }) |id| {
        const body = try requestBody(a, t.io, .{ .provider = id, .base_url = "", .api_key = "", .model = "m" }, "key", &messages, "[]", null);
        const input = (try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{})).object.get("input").?.array.items;
        const user = input[0].object.get("content").?.array.items;
        try t.expectEqualStrings("input_text", user[0].object.get("type").?.string);
        try t.expect(std.mem.startsWith(u8, user[1].object.get("image_url").?.string, "data:image/png;base64,iVBOR"));
        try t.expectEqualStrings("custom_tool_call_output", input[2].object.get("type").?.string);
        if (id == .codex) {
            try t.expectEqual(@as(usize, 3), input.len);
            const output = input[2].object.get("output").?.array.items;
            try t.expectEqualStrings("viewed", output[0].object.get("text").?.string);
            try t.expectEqualStrings("input_image", output[1].object.get("type").?.string);
        } else {
            try t.expectEqual(@as(usize, 4), input.len);
            try t.expectEqualStrings("viewed", input[2].object.get("output").?.string);
            try t.expectEqualStrings("user", input[3].object.get("role").?.string);
            const follow = input[3].object.get("content").?.array.items;
            try t.expectEqualStrings("[tool result image: shot.png]", follow[0].object.get("text").?.string);
            try t.expectEqualStrings("input_image", follow[1].object.get("type").?.string);
            try t.expect(follow[1].object.get("text") == null);
        }
    }
}
