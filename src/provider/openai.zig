const std = @import("std");
pub const default_model = "deepseek-flash";
const sse = @import("sse.zig");
const idle = @import("idle.zig");
const body_reader = @import("body.zig");
const image = @import("../image.zig");

const Config = @import("../provider.zig").Config;
const Message = @import("../provider.zig").Message;
const ToolCall = @import("../provider.zig").ToolCall;
const Usage = @import("../provider.zig").Usage;
const Reply = @import("../provider.zig").Reply;
const Sink = @import("../provider.zig").Sink;
const Chunk = struct {
    choices: []const struct {
        finish_reason: ?[]const u8 = null,
        delta: struct {
            content: ?[]const u8 = null,
            reasoning_content: ?[]const u8 = null,
            tool_calls: []const struct {
                index: usize = 0,
                id: ?[]const u8 = null,
                function: struct {
                    name: ?[]const u8 = null,
                    arguments: ?[]const u8 = null,
                } = .{},
            } = &.{},
        } = .{},
    } = &.{},
    usage: ?struct {
        prompt_tokens: u64 = 0,
        completion_tokens: u64 = 0,
        prompt_cache_hit_tokens: u64 = 0,
        prompt_tokens_details: ?struct { cached_tokens: u64 = 0, cache_write_tokens: u64 = 0 } = null,
    } = null,
};

const PartialCall = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,

    fn deinit(p: *PartialCall, gpa: std.mem.Allocator) void {
        p.id.deinit(gpa);
        p.name.deinit(gpa);
        p.args.deinit(gpa);
    }
};

/// On `error.HttpStatus` or `error.HttpTransient` (429, 5xx), `detail` holds
/// the response body (caller frees).
pub fn stream(
    gpa: std.mem.Allocator,
    out: std.mem.Allocator,
    client: *std.http.Client,
    cfg: Config,
    messages: []const Message,
    tools_json: []const u8,
    max_tokens: ?u32,
    sink: Sink,
    cancel: *const std.atomic.Value(bool),
    detail: *?[]u8,
    monitor: *idle.Monitor,
) !Reply {
    const url = try std.fmt.allocPrint(gpa, "{s}/chat/completions", .{std.mem.trimEnd(u8, cfg.base_url, "/")});
    defer gpa.free(url);
    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{cfg.api_key});
    defer gpa.free(auth);
    const body = try requestBody(gpa, client.io, cfg, messages, tools_json, max_tokens);
    defer gpa.free(body);

    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .redirect_behavior = .not_allowed,
        .headers = .{
            .authorization = if (cfg.api_key.len > 0) .{ .override = auth } else .omit,
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
        },
        .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();
    monitor.attach(req.connection.?);
    defer monitor.detach(req.connection.?);

    var response = try req.receiveHead(&.{});

    const buf = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(buf);
    const response_reader = response.reader(buf);

    if (response.head.status.class() != .success) {
        const status = @backingInt(response.head.status);
        if (status == 401) {
            detail.* = try std.fmt.allocPrint(gpa, "{s}: HTTP 401; check {s}.", .{ cfg.name(), cfg.keyHint() });
            return error.HttpStatus;
        }
        const text = response_reader.allocRemaining(gpa, .limited(64 * 1024)) catch "";
        defer if (text.len > 0) gpa.free(text);
        detail.* = try std.fmt.allocPrint(gpa, "HTTP {d}: {s}", .{ status, text });
        return if (status == 429 or status >= 500) error.HttpTransient else error.HttpStatus;
    }

    var observed = try body_reader.Reader.init(gpa, response_reader, monitor, sink);
    defer observed.deinit(gpa);
    const reader = &observed.reader;
    var parser: sse.Parser = .{};
    defer parser.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var calls: std.ArrayList(PartialCall) = .empty;
    defer {
        for (calls.items) |*p| p.deinit(gpa);
        calls.deinit(gpa);
    }

    var usage: Usage = .{};
    var done = false;
    var finish_tool_calls: ?bool = null;
    while (true) {
        if (cancel.load(.acquire)) return error.Canceled;
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse err,
            else => return err,
        } orelse break;
        try monitor.check();
        const data = (try parser.feed(gpa, line)) orelse continue;
        if (std.mem.eql(u8, data, "[DONE]")) {
            done = true;
            break;
        }

        defer _ = arena.reset(.retain_capacity);
        const chunk = std.json.parseFromSliceLeaky(Chunk, arena.allocator(), data, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidResponse;
        if (sink.timing) |timing| observeTiming(timing, chunk);
        if (chunk.usage) |u| usage = .{ .prompt_tokens = u.prompt_tokens, .completion_tokens = u.completion_tokens, .prompt_cache_hit_tokens = if (u.prompt_tokens_details) |d| d.cached_tokens else u.prompt_cache_hit_tokens, .prompt_cache_write_tokens = if (u.prompt_tokens_details) |d| d.cache_write_tokens else 0 };
        for (chunk.choices) |choice| {
            if (choice.finish_reason) |reason| finish_tool_calls = std.mem.eql(u8, reason, "tool_calls");
            const d = choice.delta;
            if (d.content) |value| monitor.content(value.len);
            if (d.reasoning_content) |value| monitor.content(value.len);
            for (d.tool_calls) |tc| if (tc.function.arguments) |value| {
                monitor.content(value.len);
            };
            if (d.reasoning_content) |t| if (t.len > 0) {
                try reasoning.appendSlice(gpa, t);
                try sink.onDelta(sink.ctx, .reasoning, t);
            };
            if (d.content) |t| if (t.len > 0) {
                try text.appendSlice(gpa, t);
                try sink.onDelta(sink.ctx, .text, t);
            };
            for (d.tool_calls) |tc| {
                if (tc.index > 64) return error.TooManyToolCalls;
                while (calls.items.len <= tc.index) try calls.append(gpa, .{});
                const p = &calls.items[tc.index];
                if (tc.id) |s| try p.id.appendSlice(gpa, s);
                if (tc.function.name) |s| try p.name.appendSlice(gpa, s);
                if (tc.function.arguments) |s| {
                    try p.args.appendSlice(gpa, s);
                    if (s.len > 0) try sink.toolArguments();
                }
            }
        }
    }

    if (!done) return error.IncompleteResponse;
    if (finish_tool_calls == true and calls.items.len == 0) return error.InvalidResponse;
    for (calls.items) |p| {
        if (p.id.items.len == 0 or p.name.items.len == 0) return error.InvalidResponse;
    }
    const tool_calls = try out.alloc(ToolCall, calls.items.len);
    for (calls.items, tool_calls) |p, *tc| tc.* = .{
        .id = try out.dupe(u8, p.id.items),
        .function = .{ .name = try out.dupe(u8, p.name.items), .arguments = try out.dupe(u8, p.args.items) },
    };
    if (sink.timing) |timing| {
        for (tool_calls, 0..) |_, index| timing.bind(index, index);
    }
    return .{ .text = try out.dupe(u8, text.items), .reasoning = if (reasoning.items.len > 0) .{ .provider = cfg.provider, .data = try out.dupe(u8, reasoning.items) } else null, .tool_calls = tool_calls, .usage = usage };
}

fn observeTiming(timing: *@import("../provider.zig").ModelTiming, chunk: Chunk) void {
    for (chunk.choices) |choice| {
        for (choice.delta.tool_calls) |call| {
            if (call.function.arguments) |args| timing.arguments(call.index, args.len);
        }
    }
}

const WirePart = struct { type: []const u8, text: ?[]const u8 = null, image_url: ?struct { url: []const u8 } = null };

const WireContent = union(enum) {
    text: []const u8,
    parts: []const WirePart,

    pub fn jsonStringify(c: WireContent, jw: anytype) !void {
        switch (c) {
            inline else => |value| try jw.write(value),
        }
    }
};

const WireMessage = struct {
    role: []const u8,
    content: ?WireContent,
    tool_calls: ?[]const ToolCall,
    tool_call_id: ?[]const u8,
    reasoning_content: ?[]const u8,
};

fn imageParts(a: std.mem.Allocator, list: *std.ArrayList(WirePart), parts: []const image.Part) !void {
    for (parts) |part| switch (part) {
        .text => |text| try list.append(a, .{ .type = "text", .text = text }),
        .data => try list.append(a, .{ .type = "image_url", .image_url = .{ .url = try part.dataUrl(a) } }),
    };
}

fn requestBody(gpa: std.mem.Allocator, io: std.Io, cfg: Config, messages: []const Message, tools_json: []const u8, max_tokens: ?u32) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var wire: std.ArrayList(WireMessage) = .empty;
    // A tool message cannot carry images; they follow the last tool message of its group.
    var tool_images: std.ArrayList(WirePart) = .empty;
    for (messages, 0..) |m, index| {
        var content: ?WireContent = if (m.content) |text| .{ .text = text } else null;
        if (m.images) |images| if (std.mem.eql(u8, m.role, "tool")) {
            const parts = try image.parts(a, io, images, cfg.vision());
            for (images, parts) |source, part| {
                try tool_images.append(a, .{ .type = "text", .text = try std.fmt.allocPrint(a, "[tool result image: {s}]", .{source.name}) });
                try imageParts(a, &tool_images, &.{part});
            }
        } else {
            var list: std.ArrayList(WirePart) = .empty;
            try list.append(a, .{ .type = "text", .text = m.content orelse "" });
            try imageParts(a, &list, try image.parts(a, io, images, cfg.vision()));
            content = .{ .parts = list.items };
        };
        try wire.append(a, .{
            .role = m.role,
            .content = content,
            .tool_calls = m.tool_calls,
            .tool_call_id = m.tool_call_id,
            .reasoning_content = if (m.reasoning) |r| if (r.provider == cfg.provider) r.data else null else null,
        });
        const next_is_tool = index + 1 < messages.len and std.mem.eql(u8, messages[index + 1].role, "tool");
        if (tool_images.items.len > 0 and !next_is_tool) {
            try wire.append(a, .{ .role = "user", .content = .{ .parts = try tool_images.toOwnedSlice(a) }, .tool_calls = null, .tool_call_id = null, .reasoning_content = null });
        }
    }
    const opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    const limit = if (max_tokens) |n| try std.fmt.allocPrint(gpa, ",\"max_tokens\":{d}", .{n}) else try gpa.dupe(u8, "");
    defer gpa.free(limit);
    const tool_field = if (std.mem.eql(u8, tools_json, "[]")) try gpa.dupe(u8, "") else try std.fmt.allocPrint(gpa, ",\"tools\":{s}", .{tools_json});
    defer gpa.free(tool_field);
    const deepseek = cfg.provider == .chat_completions or cfg.provider == .deepseek;
    const thinking = if (if (deepseek) cfg.thinking else null) |on|
        try std.fmt.allocPrint(gpa, ",\"thinking\":{{\"type\":\"{s}\"}}", .{if (on) "enabled" else "disabled"})
    else
        try gpa.dupe(u8, "");
    defer gpa.free(thinking);
    const effort_value = if (!deepseek and cfg.thinking == false) "none" else if (cfg.thinking != false) cfg.reasoning_effort else null;
    const effort = if (effort_value) |value|
        try std.fmt.allocPrint(gpa, ",\"reasoning_effort\":{f}", .{std.json.fmt(value, opts)})
    else
        try gpa.dupe(u8, "");
    defer gpa.free(effort);
    const format: []const u8 = if (cfg.output_schema != null) ",\"response_format\":{\"type\":\"json_object\"}" else "";
    const cache = if (cfg.prompt_cache_key) |key| try std.fmt.allocPrint(gpa, ",\"prompt_cache_key\":{f}", .{std.json.fmt(key, opts)}) else try gpa.dupe(u8, "");
    defer gpa.free(cache);
    return std.fmt.allocPrint(gpa,
        \\{{"model":{f},"messages":{f}{s}{s}{s}{s}{s}{s},"stream":true,"stream_options":{{"include_usage":true}}}}
    , .{ std.json.fmt(cfg.model, opts), std.json.fmt(wire.items, opts), tool_field, limit, thinking, effort, format, cache });
}

test "chunk decodes deepseek deltas, tool call fragments and usage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try std.json.parseFromSliceLeaky(Chunk, arena.allocator(),
        \\{"id":"x","choices":[{"index":0,"delta":{"content":"hi","reasoning_content":null,
        \\  "tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"run","arguments":"{\"co"}}]}}],
        \\ "usage":{"prompt_tokens":5,"completion_tokens":1,"prompt_cache_hit_tokens":4,"total_tokens":6}}
    , .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("hi", c.choices[0].delta.content.?);
    try std.testing.expectEqualStrings("{\"co", c.choices[0].delta.tool_calls[0].function.arguments.?);
    try std.testing.expectEqual(@as(u64, 4), c.usage.?.prompt_cache_hit_tokens);
}

test "request body omits null fields and absent tools" {
    const gpa = std.testing.allocator;
    const msgs = [_]Message{
        .{ .role = "user", .content = "hi" },
        .{ .role = "assistant", .content = "", .tool_calls = &.{.{ .id = "c1", .function = .{ .name = "run", .arguments = "{}" } }} },
        .{ .role = "tool", .content = "ok", .tool_call_id = "c1" },
    };
    const body = try requestBody(gpa, std.testing.io, .{ .base_url = "", .api_key = "", .model = "m" }, &msgs, "[]", null);
    defer gpa.free(body);
    try std.testing.expectEqualStrings(
        \\{"model":"m","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"run","arguments":"{}"}}]},{"role":"tool","content":"ok","tool_call_id":"c1"}],"stream":true,"stream_options":{"include_usage":true}}
    , body);
}

test "request body passes reasoning back and sends thinking only when configured" {
    const gpa = std.testing.allocator;
    const msgs = [_]Message{.{ .role = "assistant", .content = "a", .reasoning = .{ .provider = .chat_completions, .data = "r" } }};
    const on = try requestBody(gpa, std.testing.io, .{ .base_url = "", .api_key = "", .model = "m", .thinking = true, .reasoning_effort = "max" }, &msgs, "[]", null);
    defer gpa.free(on);
    try std.testing.expectEqualStrings(
        \\{"model":"m","messages":[{"role":"assistant","content":"a","reasoning_content":"r"}],"thinking":{"type":"enabled"},"reasoning_effort":"max","stream":true,"stream_options":{"include_usage":true}}
    , on);
    const off = try requestBody(gpa, std.testing.io, .{ .base_url = "", .api_key = "", .model = "m", .thinking = false, .reasoning_effort = "max" }, &msgs, "[]", null);
    defer gpa.free(off);
    try std.testing.expect(std.mem.indexOf(u8, off, "\"thinking\":{\"type\":\"disabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, off, "reasoning_effort") == null);
}

test "summary request limits output and omits tools" {
    const t = std.testing;
    const body = try requestBody(t.allocator, t.io, .{ .base_url = "", .api_key = "", .model = "m" }, &.{.{ .role = "user", .content = "summary" }}, "[]", 512);
    defer t.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
    defer parsed.deinit();
    try t.expect(!parsed.value.object.contains("tools"));
    try t.expectEqual(@as(i64, 512), parsed.value.object.get("max_tokens").?.integer);
}

test "chat timing collects argument chunks without emitted text" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const out = arena.allocator();
    var timing: @import("../provider.zig").ModelTiming = .init(t.io, .now(t.io, .awake));
    const chunks = [_][]const u8{
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call\",\"function\":{\"name\":\"run\"}}]}}]}",
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\"}}]}}]}",
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"}\"}}]}}]}",
    };
    for (chunks) |data| {
        const chunk = try std.json.parseFromSliceLeaky(Chunk, out, data, .{});
        observeTiming(&timing, chunk);
    }
    timing.bind(0, 0);
    const calls = [_]ToolCall{.{ .id = "call", .function = .{ .name = "run", .arguments = "{}" } }};
    const codes = try timing.finish(out, &calls);
    try t.expectEqual(@as(usize, 1), codes.len);
    try t.expectEqual(@as(usize, 2), codes[0].progress.len);
    try t.expectEqual(@as(u64, 1), codes[0].progress[0][1]);
    try t.expectEqual(@as(u64, 2), codes[0].progress[1][1]);
}

test "tool-free JSON requests retain system and use json_object without leaking schema" {
    const t = std.testing;
    const schema = try std.json.parseFromSlice(std.json.Value, t.allocator, "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"],\"additionalProperties\":false}", .{});
    defer schema.deinit();
    const system = "Return JSON.\nUse the \"answer\" field.";
    const messages = [_]Message{
        .{ .role = "system", .content = system },
        .{ .role = "user", .content = "question" },
    };
    for ([_]?std.json.Value{ null, schema.value }) |output_schema| {
        const body = try requestBody(t.allocator, t.io, .{ .base_url = "", .api_key = "", .model = "m", .output_schema = output_schema }, &messages, "[]", null);
        defer t.allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try t.expect(!object.contains("tools"));
        const wire_messages = object.get("messages").?.array.items;
        try t.expectEqual(@as(usize, 2), wire_messages.len);
        try t.expectEqualStrings("system", wire_messages[0].object.get("role").?.string);
        try t.expectEqualStrings(system, wire_messages[0].object.get("content").?.string);
        if (output_schema != null) {
            const format = object.get("response_format").?.object;
            try t.expectEqual(@as(usize, 1), format.count());
            try t.expectEqualStrings("json_object", format.get("type").?.string);
        } else {
            try t.expect(!object.contains("response_format"));
        }
    }
}

test "custom Chat Completions effort avoids DeepSeek-only thinking fields" {
    const t = std.testing;
    var cfg: Config = .{ .provider = .custom, .custom_provider = "site", .base_url = "", .api_key = "", .model = "local" };
    try cfg.setEffort("high");
    const body = try requestBody(t.allocator, t.io, cfg, &.{.{ .role = "user", .content = "hi" }}, "[]", null);
    defer t.allocator.free(body);
    try t.expect(std.mem.indexOf(u8, body, "\"thinking\"") == null);
    try t.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
}

test "Chat Completions images use image_url parts and follow tool results in a user message" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const directory = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/images", .{tmp.sub_path});
    const shot = try image.store(t.io, a, directory, "shot.png", image.sample_png);
    const calls = [_]ToolCall{ .{ .id = "one", .function = .{ .name = "run", .arguments = "{}" } }, .{ .id = "two", .function = .{ .name = "run", .arguments = "{}" } } };
    const messages = [_]Message{
        .{ .role = "user", .content = "look", .images = &.{shot} },
        .{ .role = "assistant", .content = "", .tool_calls = &calls },
        .{ .role = "tool", .content = "viewed", .tool_call_id = "one", .images = &.{shot} },
        .{ .role = "tool", .content = "plain", .tool_call_id = "two" },
    };
    const body = try requestBody(a, t.io, .{ .provider = .custom, .custom_provider = "site", .custom_vision = true, .base_url = "", .api_key = "", .model = "m" }, &messages, "[]", null);
    const wire = (try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{})).object.get("messages").?.array.items;
    try t.expectEqual(@as(usize, 5), wire.len);
    const parts = wire[0].object.get("content").?.array.items;
    try t.expectEqualStrings("look", parts[0].object.get("text").?.string);
    try t.expect(std.mem.startsWith(u8, parts[1].object.get("image_url").?.object.get("url").?.string, "data:image/png;base64,iVBOR"));
    try t.expectEqualStrings("viewed", wire[2].object.get("content").?.string);
    try t.expectEqualStrings("tool", wire[3].object.get("role").?.string);
    try t.expectEqualStrings("user", wire[4].object.get("role").?.string);
    const follow = wire[4].object.get("content").?.array.items;
    try t.expectEqualStrings("[tool result image: shot.png]", follow[0].object.get("text").?.string);
    try t.expectEqualStrings("image_url", follow[1].object.get("type").?.string);
}
