const std = @import("std");
const mcp = @import("../mcp.zig");
const index = @import("index.zig");
const jail = @import("../tools/bash/jail.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const field = index.field;
const string = index.string;

pub const Transport = struct {
    gpa: A,
    io: std.Io,
    config: mcp.Server,
    env: ?*const std.process.Environ.Map,
    home: []const u8,
    user_home: []const u8,
    writable: []const []const u8,
    sandboxed: bool,
    child: ?std.process.Child = null,
    reader: ?std.Io.File.Reader = null,
    read_buffer: [8192]u8 = undefined,
    next_id: i64 = 1,
    ready: bool = false,
    modern: bool = true,
    version: []const u8 = mcp.protocol_version,
    session: ?[]const u8 = null,
    dirty: bool = false,
    schema: V = .null,
    last_error: ?[]const u8 = null,
    http_status: u16 = 0,

    pub fn close(t: *Transport) void {
        if (t.child) |*child| {
            if (child.stdin) |file| {
                file.close(t.io);
                child.stdin = null;
            }
            if (child.id) |pid| std.posix.kill(-pid, .KILL) catch {};
            child.kill(t.io);
            t.child = null;
        }
        t.reader = null;
        if (t.session) |s| t.gpa.free(s);
        t.session = null;
        t.ready = false;
        t.version = mcp.protocol_version;
        t.modern = true;
    }

    fn spawn(t: *Transport, a: A) !void {
        var env: std.process.Environ.Map = .init(a);
        if (t.env) |source| {
            for ([_][]const u8{ "PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "TZ", "SYSTEMROOT" }) |name| if (source.get(name)) |v| try env.put(name, v);
            @import("../tools/secrets.zig").removeFrom(&env);
            // Explicitly allowlisted server credentials are intentionally passed through.
            for (t.config.env) |name| if (source.get(name)) |v| try env.put(name, v);
        }
        for (t.config.env_bindings) |binding| try env.put(binding.name, try @import("templates.zig").expand(a, binding.value, t.env));
        const directory = try std.fs.path.join(a, &.{ t.home, "mcp", t.config.id });
        try std.Io.Dir.cwd().createDirPath(t.io, directory);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, t.config.command.?);
        try argv.appendSlice(a, t.config.args);
        var wrapped: []const []const u8 = argv.items;
        if (t.sandboxed) {
            if (jail.unavailable(t.io) != null) return error.SandboxUnavailable;
            const cwd = try std.process.currentPathAlloc(t.io, a);
            var extras: std.ArrayList([]const u8) = .empty;
            try extras.appendSlice(a, t.writable);
            try extras.append(a, directory);
            const roots = try jail.roots(t.io, a, .{ .cwd = cwd, .home = t.user_home, .environ = t.env, .extra = extras.items });
            wrapped = try jail.wrap(a, t.io, roots, argv.items);
        }
        t.child = try std.process.spawn(t.io, .{ .argv = wrapped, .environ_map = &env, .cwd = .{ .path = directory }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .pgid = 0 });
        t.reader = t.child.?.stdout.?.reader(t.io, &t.read_buffer);
    }

    pub fn ensure(t: *Transport, a: A, cancel: *const std.atomic.Value(bool)) !void {
        if (t.ready) return;
        errdefer t.close();
        if (t.config.command != null and t.child == null) try t.spawn(a);
        t.last_error = null;
        const probe = t.exchange(a, "server/discover", .{ .object = .empty }, false, cancel, if (t.config.url == null) 2000 else mcp.timeout_ms) catch |err| blk: {
            if (err == error.Canceled) return err;
            if (err != error.Timeout or t.config.url != null) return err;
            t.close();
            try t.spawn(a);
            break :blk V.null;
        };
        const rpc_error = field(probe, "error");
        const code = field(rpc_error, "code");
        if (rpc_error != .null and code == .integer and code.integer == -32022) return error.UnsupportedProtocolVersion;
        if (field(probe, "result") == .object) {
            const versions = field(field(probe, "result"), "supportedVersions");
            if (versions != .array) return error.InvalidDiscovery;
            const supported = for (versions.array.items) |v| {
                if (v == .string and std.mem.eql(u8, v.string, mcp.protocol_version)) break true;
            } else false;
            if (!supported) return error.UnsupportedProtocolVersion;
            t.ready = true;
            return;
        }
        // Modern errors identify a modern endpoint even if the RPC itself failed.
        if (code == .integer and (code.integer == -32020 or code.integer == -32021)) return error.ModernProtocolError;
        if (t.config.url != null and (t.http_status < 400 or t.http_status >= 500)) return error.DiscoveryFailed;
        t.modern = false;
        t.version = mcp.legacy_version;
        const reply = try t.exchange(a, "initialize", try mcp.value(a, .{ .protocolVersion = mcp.legacy_version, .capabilities = V{ .object = .empty }, .clientInfo = .{ .name = "nib", .version = @import("build_options").version } }), false, cancel, mcp.timeout_ms);
        const result = try mcp.checked(reply);
        const version = string(field(result, "protocolVersion")) orelse return error.InvalidInitialization;
        t.version = for ([_][]const u8{ mcp.legacy_version, "2025-06-18", "2025-03-26", "2024-11-05" }) |v| {
            if (std.mem.eql(u8, v, version)) break v;
        } else return error.UnsupportedProtocolVersion;
        _ = try t.exchange(a, "notifications/initialized", .{ .object = .empty }, true, cancel, mcp.timeout_ms);
        t.ready = true;
    }

    pub fn rpc(t: *Transport, a: A, method: []const u8, params: V, cancel: *const std.atomic.Value(bool)) !V {
        try t.ensure(a, cancel);
        const reply = t.exchange(a, method, params, false, cancel, mcp.timeout_ms) catch |err| {
            t.close();
            return err;
        };
        t.last_error = string(field(field(reply, "error"), "message"));
        return reply;
    }

    fn exchange(t: *Transport, a: A, method: []const u8, params_input: V, notification: bool, cancel: *const std.atomic.Value(bool), ms: u64) !V {
        var params = params_input;
        if (t.modern) {
            try params.object.put(a, "_meta", try mcp.value(a, .{
                .@"io.modelcontextprotocol/protocolVersion" = t.version,
                .@"io.modelcontextprotocol/clientCapabilities" = V{ .object = .empty },
                .@"io.modelcontextprotocol/clientInfo" = .{ .name = "nib", .version = @import("build_options").version },
            }));
        }
        const id = t.next_id;
        t.next_id += 1;
        const body = if (notification) try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = method, .params = params }, .{}) else try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }, .{});
        if (body.len > mcp.max_message) return error.MessageTooLarge;
        const U = union(enum) { result: anyerror!V, stop: anyerror };
        var buffer: [2]U = undefined;
        var select = std.Io.Select(U).init(t.io, &buffer);
        defer select.cancelDiscard();
        try select.concurrent(.result, work, .{ t, a, method, params, body, id, notification });
        try select.concurrent(.stop, watch, .{ t.io, cancel, ms });
        return switch (try select.await()) {
            .result => |v| v,
            .stop => |err| err,
        };
    }

    fn work(t: *Transport, a: A, method: []const u8, params: V, body: []const u8, id: i64, notification: bool) anyerror!V {
        if (t.config.url != null) return t.http(a, method, params, body, id, notification);
        var writer = t.child.?.stdin.?.writer(t.io, &.{});
        try writer.interface.writeAll(body);
        try writer.interface.writeAll("\n");
        try writer.interface.flush();
        if (notification) return .null;
        while (true) {
            const line = try readLine(a, &t.reader.?.interface);
            if (try t.message(a, line, id)) |v| return v;
        }
    }

    fn message(t: *Transport, a: A, line: []const u8, id: i64) !?V {
        const v = std.json.parseFromSliceLeaky(V, a, line, .{}) catch return error.InvalidJsonRpc;
        if (v != .object or !std.mem.eql(u8, string(field(v, "jsonrpc")) orelse "", "2.0")) return error.InvalidJsonRpc;
        if (string(field(v, "method"))) |method| {
            if (std.mem.eql(u8, method, "notifications/tools/list_changed")) t.dirty = true;
            if (field(v, "id") != .null) {
                if (t.child) |child| {
                    const reply = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = field(v, "id"), .@"error" = .{ .code = -32601, .message = "Client method not supported" } }, .{});
                    var writer = child.stdin.?.writer(t.io, &.{});
                    try writer.interface.writeAll(reply);
                    try writer.interface.writeAll("\n");
                    try writer.interface.flush();
                } else return error.UnsupportedServerRequest;
            }
            return null;
        }
        const reply_id = field(v, "id");
        if (reply_id == .null and field(v, "error") == .object) return v;
        if (reply_id != .integer or reply_id.integer != id) return null;
        return v;
    }

    fn http(t: *Transport, a: A, method: []const u8, params: V, body: []const u8, id: i64, notification: bool) !V {
        var client: std.http.Client = .{ .allocator = t.gpa, .io = t.io };
        defer client.deinit();
        if (t.env) |env| try client.initDefaultProxies(a, env);
        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.appendSlice(a, &.{ .{ .name = "accept", .value = "application/json, text/event-stream" }, .{ .name = "MCP-Protocol-Version", .value = t.version } });
        if (t.modern) {
            try headers.append(a, .{ .name = "Mcp-Method", .value = method });
            if (string(field(params, "name"))) |name| try headers.append(a, .{ .name = "Mcp-Name", .value = try @import("headers.zig").encode(a, name) });
            if (t.schema != .null) try @import("headers.zig").append(a, &headers, t.schema, field(params, "arguments"));
        } else if (t.session) |s| try headers.append(a, .{ .name = "Mcp-Session-Id", .value = s });
        if (t.config.header_env) |name| {
            const token = if (t.env) |env| env.get(name) orelse return error.MissingHeaderEnvironment else return error.MissingHeaderEnvironment;
            for (token) |c| if (c < 0x20 or c == 0x7f) return error.InvalidAuthorization;
            try headers.append(a, .{ .name = "authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) });
        }
        var req = try client.request(.POST, try std.Uri.parse(t.config.url.?), .{ .redirect_behavior = .not_allowed, .headers = .{ .content_type = .{ .override = "application/json" }, .accept_encoding = .omit }, .extra_headers = headers.items });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.len };
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(body);
        try bw.end();
        try req.connection.?.flush();
        var head: [8192]u8 = undefined;
        var response = try req.receiveHead(&head);
        t.http_status = @intCast(@backingInt(response.head.status));
        if (!t.modern) {
            var it = response.head.iterateHeaders();
            while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "Mcp-Session-Id")) {
                if (h.value.len == 0 or h.value.len > 1024) return error.InvalidSessionId;
                for (h.value) |c| if (c < 0x21 or c > 0x7e) return error.InvalidSessionId;
                const session = try t.gpa.dupe(u8, h.value);
                if (t.session) |s| t.gpa.free(s);
                t.session = session;
            };
        }
        if (notification and t.http_status == 202) return .null;
        const media = try a.dupe(u8, response.head.content_type orelse "");
        var transfer: [8192]u8 = undefined;
        const reader = response.reader(&transfer);
        if (std.ascii.startsWithIgnoreCase(media, "text/event-stream")) {
            var parser: @import("../provider/sse.zig").Parser = .{};
            defer parser.deinit(a);
            var total: usize = 0;
            while (true) {
                const line = try readLine(a, reader);
                total += line.len + 1;
                if (total > mcp.max_message) return error.MessageTooLarge;
                if (try parser.feed(a, line)) |event| if (try t.message(a, event, id)) |v| return v;
            }
        }
        const data = try reader.allocRemaining(a, .limited(mcp.max_message));
        if (!std.ascii.startsWithIgnoreCase(media, "application/json")) {
            if (t.modern and t.http_status >= 400 and t.http_status < 500) return .null;
            return error.InvalidContentType;
        }
        const parsed_message = t.message(a, data, id) catch |err| {
            if (t.modern and t.http_status >= 400 and t.http_status < 500) return .null;
            return err;
        };
        if (parsed_message) |reply| return reply;
        if (t.modern and t.http_status >= 400 and t.http_status < 500) return .null;
        return error.InvalidResponse;
    }
};

pub fn readLine(a: A, reader: *std.Io.Reader) ![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        const byte = try reader.takeByte();
        if (byte == '\n') return line.items;
        if (line.items.len == mcp.max_message) return error.MessageTooLarge;
        try line.append(a, byte);
    }
}

pub fn watch(io: std.Io, cancel: *const std.atomic.Value(bool), ms: u64) anyerror {
    var elapsed: u64 = 0;
    while (elapsed < ms) : (elapsed += 20) {
        if (cancel.load(.acquire)) return error.Canceled;
        std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(20), .clock = .awake }, io) catch return error.Canceled;
    }
    return error.Timeout;
}

test "stdio newline framing retains escaped newlines and next messages" {
    var reader: std.Io.Reader = .fixed("{\"text\":\"a\\nb\"}\n{\"id\":2}\n");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("{\"text\":\"a\\nb\"}", try readLine(arena.allocator(), &reader));
    try std.testing.expectEqualStrings("{\"id\":2}", try readLine(arena.allocator(), &reader));
    try std.testing.expectError(error.EndOfStream, readLine(arena.allocator(), &reader));
}

test "timeout and cancellation watches" {
    var cancel: std.atomic.Value(bool) = .init(false);
    try std.testing.expectEqual(error.Timeout, watch(std.testing.io, &cancel, 1));
    cancel.store(true, .release);
    try std.testing.expectEqual(error.Canceled, watch(std.testing.io, &cancel, 1000));
}

test "SSE messages correlate replies and mark tool lists dirty" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var transport: Transport = .{ .gpa = t.allocator, .io = t.io, .config = .{ .id = "test" }, .env = null, .home = "", .user_home = "", .writable = &.{}, .sandboxed = false };
    var parser: @import("../provider/sse.zig").Parser = .{};
    defer parser.deinit(a);
    const stream = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\r\n\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n\n";
    var lines = std.mem.splitScalar(u8, stream, '\n');
    var result: ?V = null;
    while (lines.next()) |line| if (try parser.feed(a, line)) |event| {
        if (try transport.message(a, event, 7)) |reply| {
            result = reply;
        }
    };
    try t.expect(transport.dirty);
    try t.expect(result != null);
    try t.expectEqual(@as(i64, 7), field(result.?, "id").integer);
    try t.expect(try transport.message(a, "{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{}}", 7) == null);
}
