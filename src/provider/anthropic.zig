const std = @import("std");
const p = @import("../provider.zig");
const idle = @import("idle.zig");
const sse = @import("sse.zig");
const body_reader = @import("body.zig");
const image = @import("../image.zig");

fn family(model: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, model, name)) return false;
    const suffix = model[name.len..];
    if (suffix.len == 0) return true;
    if (suffix.len != 9 or suffix[0] != '-') return false;
    for (suffix[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn adaptive(model: []const u8) bool {
    for ([_][]const u8{ "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-sonnet-4-6", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5", "claude-fable-5-1", "claude-mythos-5", "claude-mythos-5-1" }) |name| if (family(model, name)) return true;
    return false;
}

fn managedEffort(model: []const u8) bool {
    for ([_][]const u8{ "claude-opus-5", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5", "claude-fable-5-1", "claude-mythos-5", "claude-mythos-5-1" }) |name| if (family(model, name)) return true;
    return false;
}

fn string(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidResponse;
    const field = value.object.get(key) orelse return error.InvalidResponse;
    if (field != .string) return error.InvalidResponse;
    return field.string;
}

fn canDisable(model: []const u8) bool {
    for ([_][]const u8{ "claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5", "claude-fable-5-1", "claude-mythos-5", "claude-mythos-5-1" }) |name| if (family(model, name)) return false;
    return true;
}

pub fn effort(cfg: p.Config) ?[]const u8 {
    if (cfg.thinking == false) return if (canDisable(cfg.model)) "off" else "low";
    const value = cfg.reasoning_effort orelse return if (cfg.thinking == true) "high" else null;
    if (std.mem.eql(u8, value, "none")) return if (canDisable(cfg.model)) "off" else "low";
    if (std.mem.eql(u8, value, "minimal")) return if (adaptive(cfg.model)) "low" else "minimal";
    if ((family(cfg.model, "claude-opus-4-6") or family(cfg.model, "claude-sonnet-4-6")) and std.mem.eql(u8, value, "xhigh")) return "high";
    return value;
}

const ephemeral = ",\"cache_control\":{\"type\":\"ephemeral\"}";

fn writeImageBlock(w: *std.Io.Writer, part: image.Part, cache: bool) !void {
    const control: []const u8 = if (cache) ephemeral else "";
    switch (part) {
        .text => |text| try w.print("{{\"type\":\"text\",\"text\":{f}{s}}}", .{ std.json.fmt(text, .{}), control }),
        .data => |data| try w.print("{{\"type\":\"image\",\"source\":{{\"type\":\"base64\",\"media_type\":{f},\"data\":\"{s}\"}}{s}}}", .{ std.json.fmt(data.media_type, .{}), data.base64, control }),
    }
}

pub fn requestBody(gpa: std.mem.Allocator, io: std.Io, cfg: p.Config, messages: []const p.Message, tools_json: []const u8, max_tokens: ?u32) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var body: std.Io.Writer.Allocating = .init(a);
    const w = &body.writer;
    const level = effort(cfg);
    const managed = managedEffort(cfg.model) and level != null and !std.mem.eql(u8, level.?, "off");
    var budget: u32 = 0;
    if (!adaptive(cfg.model) and level != null and !std.mem.eql(u8, level.?, "off")) {
        budget = if (std.mem.eql(u8, level.?, "minimal")) 1024 else if (std.mem.eql(u8, level.?, "low")) 2048 else if (std.mem.eql(u8, level.?, "medium")) 8192 else 16384;
    }
    const cap = @min(@as(u32, 128000), @max(max_tokens orelse 128000, budget + 1024));
    try w.print("{{\"model\":{f},\"max_tokens\":{d},\"stream\":true,\"system\":[", .{ std.json.fmt(cfg.model, .{}), cap });
    var sep: []const u8 = "";
    for (messages) |m| if (std.mem.eql(u8, m.role, "system")) {
        try w.print("{s}{f}", .{ sep, std.json.fmt(.{ .type = "text", .text = m.content orelse "", .cache_control = .{ .type = "ephemeral" } }, .{}) });
        sep = ",";
    };
    try w.writeAll("],\"messages\":[");
    sep = "";
    var last_user: ?usize = null;
    for (messages, 0..) |m, i| if (std.mem.eql(u8, m.role, "user") or std.mem.eql(u8, m.role, "tool")) {
        last_user = i;
    };
    var i: usize = 0;
    while (i < messages.len) : (i += 1) {
        const m = messages[i];
        if (std.mem.eql(u8, m.role, "system")) continue;
        if (std.mem.eql(u8, m.role, "assistant")) {
            const raw = if (m.reasoning) |r| if (r.includes_output and r.compatible(cfg)) r.data else null else null;
            const text: []const u8 = m.content orelse "";
            const calls: []const p.ToolCall = m.tool_calls orelse &.{};
            if (raw == null and text.len == 0 and calls.len == 0) continue;
            if (managed) {
                const historical = if (m.step_effort) |step| step.effort else "high";
                const valid = std.mem.eql(u8, historical, "low") or std.mem.eql(u8, historical, "medium") or std.mem.eql(u8, historical, "high") or std.mem.eql(u8, historical, "xhigh") or std.mem.eql(u8, historical, "max");
                try w.print("{s}{{\"role\":\"system\",\"content\":[],\"output_config\":{{\"effort\":{f}}}}},", .{ sep, std.json.fmt(if (valid) historical else "high", .{}) });
                sep = "";
            }
            if (raw) |data| {
                const blocks = try std.json.parseFromSliceLeaky(std.json.Value, a, data, .{});
                try w.print("{s}{{\"role\":\"assistant\",\"content\":{f}}}", .{ sep, std.json.fmt(blocks, .{}) });
                sep = ",";
                continue;
            }
            try w.print("{s}{{\"role\":\"assistant\",\"content\":[", .{sep});
            var block_sep: []const u8 = "";
            if (text.len > 0) {
                try w.print("{f}", .{std.json.fmt(.{ .type = "text", .text = text }, .{})});
                block_sep = ",";
            }
            for (calls) |call| {
                const args = try std.json.parseFromSliceLeaky(std.json.Value, a, call.function.arguments, .{});
                try w.print("{s}{f}", .{ block_sep, std.json.fmt(.{ .type = "tool_use", .id = call.id, .name = call.function.name, .input = args }, .{}) });
                block_sep = ",";
            }
            try w.writeAll("]}");
        } else {
            try w.print("{s}{{\"role\":\"user\",\"content\":[", .{sep});
            if (std.mem.eql(u8, m.role, "tool")) {
                var block_sep: []const u8 = "";
                while (true) {
                    const result = messages[i];
                    try w.print("{s}{{\"type\":\"tool_result\",\"tool_use_id\":{f},\"content\":", .{ block_sep, std.json.fmt(result.tool_call_id orelse return error.InvalidResponse, .{}) });
                    if (result.images) |images| {
                        try w.print("[{f}", .{std.json.fmt(.{ .type = "text", .text = result.content orelse "" }, .{})});
                        for (try image.parts(a, io, images, cfg.vision())) |part| {
                            try w.writeByte(',');
                            try writeImageBlock(w, part, false);
                        }
                        try w.writeByte(']');
                    } else try w.print("{f}", .{std.json.fmt(result.content orelse "", .{})});
                    try w.print("{s}}}", .{if (last_user == i) ephemeral else ""});
                    if (i + 1 == messages.len or !std.mem.eql(u8, messages[i + 1].role, "tool")) break;
                    i += 1;
                    block_sep = ",";
                }
            } else {
                const parts = if (m.images) |images| try image.parts(a, io, images, cfg.vision()) else &.{};
                const cache = last_user == i;
                try w.print("{{\"type\":\"text\",\"text\":{f}{s}}}", .{ std.json.fmt(m.content orelse "", .{}), if (cache and parts.len == 0) ephemeral else "" });
                for (parts, 0..) |part, index| {
                    try w.writeByte(',');
                    try writeImageBlock(w, part, cache and index + 1 == parts.len);
                }
            }
            try w.writeAll("]}");
        }
        sep = ",";
    }
    if (managed) try w.print("{s}{{\"role\":\"system\",\"content\":[],\"output_config\":{{\"effort\":{f}}}}}", .{ sep, std.json.fmt(level.?, .{}) });
    try w.writeByte(']');
    const tools = try std.json.parseFromSliceLeaky([]const struct { function: struct { name: []const u8, description: []const u8, parameters: std.json.Value } }, a, tools_json, .{ .ignore_unknown_fields = true });
    if (tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (tools, 0..) |tool, index| {
            try w.print("{s}{{\"name\":{f},\"description\":{f},\"input_schema\":{f}{s}}}", .{ if (index == 0) @as([]const u8, "") else ",", std.json.fmt(tool.function.name, .{}), std.json.fmt(tool.function.description, .{}), std.json.fmt(tool.function.parameters, .{}), if (index + 1 == tools.len) ",\"cache_control\":{\"type\":\"ephemeral\"}" else "" });
        }
        try w.writeByte(']');
    }
    if (level) |value| {
        if (std.mem.eql(u8, value, "off")) try w.writeAll(",\"thinking\":{\"type\":\"disabled\"}") else if (managed) {
            try w.writeAll(",\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\",\"block_binding\":{\"prefix_mismatch_behavior\":\"drop_block\"}},\"output_config\":{\"effort\":\"low\"}");
        } else if (adaptive(cfg.model)) {
            try w.print(",\"thinking\":{{\"type\":\"adaptive\"}},\"output_config\":{{\"effort\":{f}}}", .{std.json.fmt(value, .{})});
        } else try w.print(",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{budget});
    }
    try w.writeByte('}');
    return gpa.dupe(u8, body.written());
}

pub fn stream(gpa: std.mem.Allocator, out: std.mem.Allocator, client: *std.http.Client, cfg: p.Config, messages: []const p.Message, tools_json: []const u8, max_tokens: ?u32, sink: p.Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8, monitor: *idle.Monitor) !p.Reply {
    const body = try requestBody(gpa, client.io, cfg, messages, tools_json, max_tokens);
    defer gpa.free(body);
    const url = try std.fmt.allocPrint(gpa, "{s}/v1/messages", .{std.mem.trimEnd(u8, cfg.base_url, "/")});
    defer gpa.free(url);
    const headers = [_]std.http.Header{ .{ .name = "x-api-key", .value = cfg.api_key }, .{ .name = "anthropic-version", .value = "2023-06-01" }, .{ .name = "accept", .value = "text/event-stream" } };
    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .redirect_behavior = .not_allowed,
        .headers = .{ .content_type = .{ .override = "application/json" }, .accept_encoding = .omit },
        .extra_headers = headers[@as(usize, if (cfg.api_key.len == 0) 1 else 0)..],
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
    if (response.head.status.class() != .success) {
        detail.* = try std.fmt.allocPrint(gpa, "{s}: HTTP {d}; check {s}.", .{ cfg.name(), status, cfg.keyHint() });
        return if (status == 429 or status >= 500) error.HttpTransient else error.HttpStatus;
    }
    var observed = try body_reader.Reader.init(gpa, reader, monitor, sink);
    defer observed.deinit(gpa);
    return readStream(gpa, out, &observed.reader, cfg, sink, cancel, detail);
}

const Event = struct {
    type: []const u8,
    index: usize = 0,
    content_block: ?std.json.Value = null,
    delta: ?struct { type: ?[]const u8 = null, text: ?[]const u8 = null, thinking: ?[]const u8 = null, signature: ?[]const u8 = null, partial_json: ?[]const u8 = null, stop_reason: ?[]const u8 = null } = null,
    message: ?struct { usage: ?WireUsage = null } = null,
    usage: ?WireUsage = null,
    @"error": ?struct { type: []const u8 } = null,
};
const WireUsage = struct { input_tokens: ?u64 = null, output_tokens: ?u64 = null, cache_read_input_tokens: ?u64 = null, cache_creation_input_tokens: ?u64 = null };
const Block = struct { value: std.json.Value, text: std.ArrayList(u8) = .empty, signature: std.ArrayList(u8) = .empty, args: std.ArrayList(u8) = .empty, done: bool = false };

fn readStream(gpa: std.mem.Allocator, out: std.mem.Allocator, reader: *std.Io.Reader, cfg: p.Config, sink: p.Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !p.Reply {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var parser: sse.Parser = .{};
    defer parser.deinit(gpa);
    var blocks: std.ArrayList(Block) = .empty;
    var usage: WireUsage = .{};
    var stopped = false;
    var text: std.ArrayList(u8) = .empty;
    var calls: std.ArrayList(p.ToolCall) = .empty;
    var reason: ?[]const u8 = null;
    while (true) {
        if (cancel.load(.acquire)) return error.Canceled;
        if (sink.monitor) |m| try m.check();
        const line = try reader.takeDelimiter('\n') orelse break;
        const data = (try parser.feed(gpa, line)) orelse continue;
        const ev = try std.json.parseFromSliceLeaky(Event, a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (std.mem.eql(u8, ev.type, "error")) {
            const kind = if (ev.@"error") |value| value.type else "api_error";
            detail.* = try std.fmt.allocPrint(gpa, "{s}: {s}; the Step was not committed.", .{ cfg.name(), kind });
            return if (std.mem.eql(u8, kind, "overloaded_error") or std.mem.eql(u8, kind, "api_error")) error.ProviderTransient else if (std.mem.eql(u8, kind, "rate_limit_error")) error.RateLimited else error.ProviderFailed;
        }
        if (ev.message) |message| {
            if (message.usage) |u| usage = u;
        }
        if (ev.usage) |u| {
            if (u.input_tokens) |v| usage.input_tokens = v;
            if (u.output_tokens) |v| usage.output_tokens = v;
            if (u.cache_read_input_tokens) |v| usage.cache_read_input_tokens = v;
            if (u.cache_creation_input_tokens) |v| usage.cache_creation_input_tokens = v;
        }
        if (std.mem.eql(u8, ev.type, "content_block_start")) {
            if (ev.index != blocks.items.len or ev.index > 256) return error.InvalidResponse;
            const value = ev.content_block orelse return error.InvalidResponse;
            if (value != .object) return error.InvalidResponse;
            var block: Block = .{ .value = value };
            if (value.object.get("text")) |_| try block.text.appendSlice(a, try string(value, "text"));
            if (value.object.get("thinking")) |_| try block.text.appendSlice(a, try string(value, "thinking"));
            if (value.object.get("signature")) |_| try block.signature.appendSlice(a, try string(value, "signature"));
            try blocks.append(a, block);
        } else if (std.mem.eql(u8, ev.type, "content_block_delta")) {
            if (ev.index >= blocks.items.len or blocks.items[ev.index].done) return error.InvalidResponse;
            const b = &blocks.items[ev.index];
            const d = ev.delta orelse return error.InvalidResponse;
            if (d.text orelse d.thinking) |value| {
                try b.text.appendSlice(a, value);
                if (sink.monitor) |m| m.content(value.len);
                try sink.onDelta(sink.ctx, if (d.thinking != null) .reasoning else .text, value);
            }
            if (d.signature) |value| try b.signature.appendSlice(a, value);
            if (d.partial_json) |value| {
                try b.args.appendSlice(a, value);
                if (sink.monitor) |m| m.content(value.len);
                if (sink.timing) |timing| timing.arguments(ev.index, value.len);
                if (value.len > 0) try sink.toolArguments();
            }
        } else if (std.mem.eql(u8, ev.type, "content_block_stop")) {
            if (ev.index >= blocks.items.len or blocks.items[ev.index].done) return error.InvalidResponse;
            blocks.items[ev.index].done = true;
        } else if (std.mem.eql(u8, ev.type, "message_delta")) {
            if (ev.delta) |d| reason = d.stop_reason;
        } else if (std.mem.eql(u8, ev.type, "message_stop")) {
            stopped = true;
            break;
        }
    }
    if (!stopped or reason == null) return error.IncompleteResponse;
    if (!std.mem.eql(u8, reason.?, "end_turn") and !std.mem.eql(u8, reason.?, "tool_use") and !std.mem.eql(u8, reason.?, "stop_sequence")) return error.ProviderFailed;
    var content: std.ArrayList(std.json.Value) = .empty;
    for (blocks.items, 0..) |*b, index| {
        if (!b.done) return error.IncompleteResponse;
        const kind = try string(b.value, "type");
        if (std.mem.eql(u8, kind, "text")) {
            try b.value.object.put(a, "text", .{ .string = b.text.items });
            try text.appendSlice(a, b.text.items);
        } else if (std.mem.eql(u8, kind, "thinking")) {
            if (b.signature.items.len == 0) return error.InvalidResponse;
            try b.value.object.put(a, "thinking", .{ .string = b.text.items });
            try b.value.object.put(a, "signature", .{ .string = b.signature.items });
        } else if (std.mem.eql(u8, kind, "tool_use")) {
            if (calls.items.len >= 64) return error.TooManyToolCalls;
            const input = if (b.args.items.len > 0) try std.json.parseFromSliceLeaky(std.json.Value, a, b.args.items, .{}) else b.value.object.get("input") orelse return error.InvalidResponse;
            if (input != .object) return error.InvalidResponse;
            try b.value.object.put(a, "input", input);
            const args = try std.json.Stringify.valueAlloc(out, input, .{});
            try calls.append(a, .{ .id = try out.dupe(u8, try string(b.value, "id")), .function = .{ .name = try out.dupe(u8, try string(b.value, "name")), .arguments = args } });
            if (sink.timing) |timing| {
                timing.finalArguments(index, b.args.items.len);
                timing.bind(index, calls.items.len - 1);
            }
        }
        try content.append(a, b.value);
    }
    return .{ .text = try out.dupe(u8, text.items), .tool_calls = try out.dupe(p.ToolCall, calls.items), .reasoning = if (content.items.len > 0) .{ .provider = cfg.provider, .data = try std.json.Stringify.valueAlloc(out, content.items, .{}), .includes_output = true } else null, .usage = .{ .prompt_tokens = (usage.input_tokens orelse 0) + (usage.cache_read_input_tokens orelse 0) + (usage.cache_creation_input_tokens orelse 0), .completion_tokens = usage.output_tokens orelse 0, .prompt_cache_hit_tokens = usage.cache_read_input_tokens orelse 0, .prompt_cache_write_tokens = usage.cache_creation_input_tokens orelse 0 } };
}

test "Anthropic request caching paired results adaptive effort and signed continuation" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: p.Config = .{ .provider = .anthropic, .base_url = "", .api_key = "", .model = "claude-sonnet-5-5" };
    try cfg.setEffort("off");
    try t.expectEqualStrings("low", effort(cfg).?);
    const blocks = "[{\"type\":\"thinking\",\"thinking\":\"private\",\"signature\":\"opaque-signature\"},{\"type\":\"tool_use\",\"id\":\"call\",\"name\":\"run\",\"input\":{\"code\":\"1\"}}]";
    const messages: []const p.Message = &.{
        .{ .role = "system", .content = "instructions" },
        .{ .role = "user", .content = "task" },
        .{ .role = "assistant", .reasoning = .{ .provider = .anthropic, .data = blocks, .includes_output = true, .model = cfg.model }, .tool_calls = &.{.{ .id = "call", .function = .{ .name = "run", .arguments = "{\"code\":\"1\"}" } }} },
        .{ .role = "tool", .tool_call_id = "call", .content = "result" },
    };
    const body = try requestBody(a, t.io, cfg, messages, "[]", null);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    try t.expectEqualStrings("adaptive", value.object.get("thinking").?.object.get("type").?.string);
    try t.expectEqualStrings("opaque-signature", value.object.get("messages").?.array.items[2].object.get("content").?.array.items[0].object.get("signature").?.string);
    try t.expect(std.mem.indexOf(u8, body, "cache_control") != null);
    try t.expect(std.mem.indexOf(u8, body, "tool_result") != null);
    cfg.model = "claude-haiku-5-5";
    try t.expectEqualStrings("off", effort(cfg).?);
    const changed = try requestBody(a, t.io, cfg, messages, "[]", null);
    try t.expect(std.mem.indexOf(u8, changed, "opaque-signature") == null);
    const history = (try std.json.parseFromSliceLeaky(std.json.Value, a, changed, .{})).object.get("messages").?.array.items;
    const tool_use = history[1].object.get("content").?.array.items[0].object;
    const tool_result = history[2].object.get("content").?.array.items[0].object;
    try t.expectEqualStrings("tool_use", tool_use.get("type").?.string);
    try t.expectEqualStrings("1", tool_use.get("input").?.object.get("code").?.string);
    try t.expectEqualStrings(tool_use.get("id").?.string, tool_result.get("tool_use_id").?.string);
    try t.expectEqualStrings("result", tool_result.get("content").?.string);
    cfg.model = "claude-3-7-sonnet";
    try cfg.setEffort("medium");
    const legacy = try requestBody(a, t.io, cfg, &.{.{ .role = "user", .content = "task" }}, "[]", 32);
    try t.expect(std.mem.indexOf(u8, legacy, "\"budget_tokens\":8192") != null);
    try t.expect(std.mem.indexOf(u8, legacy, "\"max_tokens\":9216") != null);
    try cfg.setEffort("minimal");
    const minimal = try requestBody(a, t.io, cfg, &.{.{ .role = "user", .content = "task" }}, "[]", 32);
    try t.expect(std.mem.indexOf(u8, minimal, "\"budget_tokens\":1024") != null);
    try t.expect(adaptive("claude-fable-5-1"));
    try t.expect(adaptive("claude-opus-5-5-20261106"));
    try t.expect(!adaptive("claude-opus-5-50"));
}

test "Anthropic stream preserves signature deltas and merges cache usage" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var reader: std.Io.Reader = .fixed(
        \\data: {"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":1,"cache_read_input_tokens":20,"cache_creation_input_tokens":30}}}
        \\
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}
        \\
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"think"}}
        \\
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed"}}
        \\
        \\data: {"type":"content_block_stop","index":0}
        \\
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
        \\
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"hello"}}
        \\
        \\data: {"type":"content_block_stop","index":1}
        \\
        \\data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8}}
        \\
        \\data: {"type":"message_stop"}
        \\
        \\
    );
    var cancel: std.atomic.Value(bool) = .init(false);
    var detail: ?[]u8 = null;
    const Quiet = struct {
        fn delta(_: *anyopaque, _: p.Kind, _: []const u8) !void {}
    };
    const cfg: p.Config = .{ .provider = .anthropic, .base_url = "", .api_key = "", .model = "claude-sonnet-5-5" };
    const reply = try readStream(a, a, &reader, cfg, .{ .ctx = &cancel, .onDelta = Quiet.delta }, &cancel, &detail);
    try t.expectEqualStrings("hello", reply.text);
    try t.expectEqualDeep(p.Usage{ .prompt_tokens = 62, .completion_tokens = 8, .prompt_cache_hit_tokens = 20, .prompt_cache_write_tokens = 30 }, reply.usage);
    try t.expect(std.mem.indexOf(u8, reply.reasoning.?.data, "signed") != null);
    try t.expect(reply.reasoning.?.includes_output);
}

test "Anthropic incomplete tool input is never returned for execution" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel: std.atomic.Value(bool) = .init(false);
    var detail: ?[]u8 = null;
    const Quiet = struct {
        fn delta(_: *anyopaque, _: p.Kind, _: []const u8) !void {}
    };
    const cfg: p.Config = .{ .provider = .anthropic, .base_url = "", .api_key = "", .model = "claude-sonnet-5-5" };
    const prefix = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call\",\"name\":\"run\",\"input\":{}}}\n\n";
    var truncated: std.Io.Reader = .fixed(prefix);
    try t.expectError(error.IncompleteResponse, readStream(a, a, &truncated, cfg, .{ .ctx = &cancel, .onDelta = Quiet.delta }, &cancel, &detail));
    var unfinished: std.Io.Reader = .fixed(prefix ++ "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n");
    try t.expectError(error.IncompleteResponse, readStream(a, a, &unfinished, cfg, .{ .ctx = &cancel, .onDelta = Quiet.delta }, &cancel, &detail));
    var limited: std.Io.Reader = .fixed(prefix ++ "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n");
    try t.expectError(error.ProviderFailed, readStream(a, a, &limited, cfg, .{ .ctx = &cancel, .onDelta = Quiet.delta }, &cancel, &detail));
}

test "Anthropic images ride in user blocks and tool results with the cache breakpoint last" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const directory = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/images", .{tmp.sub_path});
    const shot = try image.store(t.io, a, directory, "shot.png", image.sample_png);
    var cfg: p.Config = .{ .provider = .anthropic, .base_url = "", .api_key = "", .model = "claude-sonnet-5-5" };
    const calls = [_]p.ToolCall{.{ .id = "call", .function = .{ .name = "run", .arguments = "{\"code\":\"1\"}" } }};
    const messages = [_]p.Message{
        .{ .role = "system", .content = "instructions" },
        .{ .role = "user", .content = "look [Image #1]", .images = &.{shot} },
        .{ .role = "assistant", .tool_calls = &calls },
        .{ .role = "tool", .tool_call_id = "call", .content = "viewed", .images = &.{shot} },
    };
    const body = try requestBody(a, t.io, cfg, &messages, "[]", null);
    const wire = (try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{})).object.get("messages").?.array.items;
    const user = wire[0].object.get("content").?.array.items;
    try t.expectEqualStrings("text", user[0].object.get("type").?.string);
    try t.expect(user[0].object.get("cache_control") == null);
    try t.expectEqualStrings("image", user[1].object.get("type").?.string);
    try t.expect(user[1].object.get("cache_control") == null);
    const source = user[1].object.get("source").?.object;
    try t.expectEqualStrings("base64", source.get("type").?.string);
    try t.expectEqualStrings("image/png", source.get("media_type").?.string);
    try t.expectEqualStrings("iVBORw0KGgo", source.get("data").?.string[0..11]);
    const result = wire[2].object.get("content").?.array.items[0].object;
    try t.expectEqualStrings("tool_result", result.get("type").?.string);
    try t.expect(result.get("cache_control") != null);
    const inner = result.get("content").?.array.items;
    try t.expectEqualStrings("viewed", inner[0].object.get("text").?.string);
    try t.expectEqualStrings("image", inner[1].object.get("type").?.string);
    const last = try requestBody(a, t.io, cfg, messages[0..2], "[]", null);
    const final_user = (try std.json.parseFromSliceLeaky(std.json.Value, a, last, .{})).object.get("messages").?.array.items[0].object.get("content").?.array.items;
    try t.expect(final_user[0].object.get("cache_control") == null);
    try t.expect(final_user[1].object.get("cache_control") != null);
    cfg.provider = .custom;
    cfg.custom_provider = "site";
    cfg.custom_protocol = .anthropic_messages;
    cfg.custom_vision = false;
    const text_only = try requestBody(a, t.io, cfg, messages[0..2], "[]", null);
    try t.expect(std.mem.indexOf(u8, text_only, "[image shot.png 640×480 omitted]") != null);
    try t.expect(std.mem.indexOf(u8, text_only, "base64") == null);
}
