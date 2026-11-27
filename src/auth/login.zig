//! ChatGPT sign-in: browser flow with a localhost callback, or device code on
//! machines without a usable browser. Blocking; callers run it on a thread.

const std = @import("std");
const builtin = @import("builtin");
const oauth = @import("oauth.zig");
const codex = @import("codex.zig");

pub const Env = std.process.Environ.Map;

pub const Prompt = struct {
    ctx: *anyopaque,
    /// Device flow only: where to go and what to type.
    device: *const fn (ctx: *anyopaque, url: []const u8, code: []const u8) void,
};

pub const Options = struct {
    io: std.Io,
    client: *std.http.Client,
    environ: *const Env,
    nib_home: []const u8,
    cancel: *const std.atomic.Value(bool),
    prompt: Prompt,
    /// Skip the browser even when one seems available.
    device_only: bool = false,
};

pub const Result = struct { plan: ?[]const u8, device: bool };

/// Test hooks, documented in docs/config.md: NIB_AUTH_ISSUER and NIB_AUTH_PORT.
pub fn issuer(env: *const Env) []const u8 {
    return env.get("NIB_AUTH_ISSUER") orelse oauth.default_issuer;
}

pub fn callbackPort(env: *const Env) u16 {
    return if (env.get("NIB_AUTH_PORT")) |v| std.fmt.parseInt(u16, v, 10) catch oauth.default_port else oauth.default_port;
}

const timeout_s: i64 = 15 * 60;

/// `a` owns the plan string in the result.
pub fn run(a: std.mem.Allocator, o: Options) !Result {
    if (builtin.os.tag != .windows and !o.device_only and browserLikely(o.environ)) browser: {
        var server = listen(o) catch break :browser;
        defer server.deinit(o.io);
        const plan = browserFlow(a, o, &server) catch |err| switch (err) {
            error.BrowserUnavailable => break :browser,
            else => return err,
        };
        return .{ .plan = plan, .device = false };
    }
    return .{ .plan = try deviceFlow(a, o), .device = true };
}

pub fn browserLikely(env: *const Env) bool {
    if (env.get("NIB_AUTH_NO_BROWSER") != null) return false;
    if (env.get("SSH_CONNECTION") != null or env.get("SSH_TTY") != null) return false;
    if (builtin.os.tag == .macos) return true;
    return env.get("DISPLAY") != null or env.get("WAYLAND_DISPLAY") != null;
}

fn listen(o: Options) !std.Io.net.Server {
    const address: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", callbackPort(o.environ));
    return address.listen(o.io, .{ .reuse_address = true });
}

fn open(o: Options, url: []const u8) !void {
    const opener = if (builtin.os.tag == .macos) "open" else "xdg-open";
    var child = std.process.spawn(o.io, .{ .argv = &.{ opener, url }, .environ_map = o.environ, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return error.BrowserUnavailable;
    defer child.kill(o.io);
    const term = child.wait(o.io) catch return error.BrowserUnavailable;
    if (!term.success()) return error.BrowserUnavailable;
}

fn readable(handle: std.Io.net.Socket.Handle, timeout_ms: i32) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
    return (std.posix.poll(&fds, timeout_ms) catch return false) != 0;
}

const Callback = struct { code: ?[]const u8 = null, state: ?[]const u8 = null, failed: bool = false, other: bool = false };

fn parseTarget(a: std.mem.Allocator, request_line: []const u8) !Callback {
    var words = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = words.next() orelse return .{ .other = true };
    const target = words.next() orelse return .{ .other = true };
    if (!std.mem.eql(u8, method, "GET")) return .{ .other = true };
    const query_at = std.mem.indexOfScalar(u8, target, '?');
    const route = target[0 .. query_at orelse target.len];
    if (!std.mem.eql(u8, route, "/auth/callback")) return .{ .other = true };
    var out: Callback = .{};
    var pairs = std.mem.splitScalar(u8, if (query_at) |i| target[i + 1 ..] else "", '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const value = try decode(a, pair[eq + 1 ..]);
        const name = pair[0..eq];
        if (std.mem.eql(u8, name, "code")) out.code = value else if (std.mem.eql(u8, name, "state")) out.state = value else if (std.mem.eql(u8, name, "error")) out.failed = true;
    }
    return out;
}

fn decode(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(a, byte);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(a, if (text[i] == '+') ' ' else text[i]);
    }
    return out.toOwnedSlice(a);
}

fn respond(o: Options, stream: std.Io.net.Stream, status: []const u8, body: []const u8) void {
    var buf: [512]u8 = undefined;
    var w = stream.writer(o.io, &buf);
    w.interface.print("HTTP/1.1 {s}\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ status, body.len, body }) catch return;
    w.interface.flush() catch {};
}

const success_page = "<!doctype html><title>nib</title><p>Signed in. You can close this tab and return to nib.</p>";
const failure_page = "<!doctype html><title>nib</title><p>Sign-in failed. Return to nib and try again.</p>";

fn waitForCallback(a: std.mem.Allocator, o: Options, server: *std.Io.net.Server, state: []const u8) ![]const u8 {
    const deadline = codex.now(o.io) + timeout_s;
    while (true) {
        if (o.cancel.load(.acquire)) return error.Canceled;
        if (codex.now(o.io) > deadline) return error.LoginTimedOut;
        if (!readable(server.socket.handle, 200)) continue;
        const stream = server.accept(o.io) catch continue;
        defer stream.close(o.io);
        if (!readable(stream.socket.handle, 2000)) continue;
        var buf: [4096]u8 = undefined;
        var reader = stream.reader(o.io, &buf);
        const line = reader.interface.takeDelimiterInclusive('\n') catch continue;
        // Drain the headers so the browser sees the response rather than a reset.
        var lines: usize = 0;
        while (lines < 64 and readable(stream.socket.handle, 200)) : (lines += 1) {
            const header = reader.interface.takeDelimiterInclusive('\n') catch break;
            if (header.len <= 2) break;
        }
        const cb = parseTarget(a, std.mem.trimEnd(u8, line, "\r\n")) catch continue;
        if (cb.other) {
            respond(o, stream, "404 Not Found", "");
            continue;
        }
        if (cb.failed or cb.code == null or cb.state == null or !std.mem.eql(u8, cb.state.?, state)) {
            respond(o, stream, "400 Bad Request", failure_page);
            if (cb.failed) return error.LoginDenied;
            continue;
        }
        respond(o, stream, "200 OK", success_page);
        return cb.code.?;
    }
}

fn browserFlow(a: std.mem.Allocator, o: Options, server: *std.Io.net.Server) !?[]const u8 {
    const pkce: oauth.Pkce = .generate(o.io);
    const state = oauth.randomState(o.io);
    const redirect = try oauth.redirectUri(a, callbackPort(o.environ));
    const url = try oauth.authorizeUrl(a, issuer(o.environ), redirect, &pkce.challenge, &state);
    try open(o, url);
    const code = try waitForCallback(a, o, server, &state);
    const exchanged = try oauth.exchangeCode(a, o.client, issuer(o.environ), code, redirect, &pkce.verifier);
    return codex.save(a, o.io, o.nib_home, exchanged);
}

fn sleepOrCancel(o: Options, seconds: u64) !void {
    var waited: u64 = 0;
    while (waited < seconds * 1000) : (waited += 200) {
        if (o.cancel.load(.acquire)) return error.Canceled;
        std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(200), .clock = .awake }, o.io) catch return error.Canceled;
    }
}

fn deviceFlow(a: std.mem.Allocator, o: Options) !?[]const u8 {
    const base = issuer(o.environ);
    const device = try oauth.requestDeviceCode(a, o.client, base);
    o.prompt.device(o.prompt.ctx, device.verification_url, device.user_code);
    const deadline = codex.now(o.io) + timeout_s;
    const grant = while (true) {
        if (o.cancel.load(.acquire)) return error.Canceled;
        if (codex.now(o.io) > deadline) return error.LoginTimedOut;
        if (try oauth.pollDeviceCode(a, o.client, base, device)) |grant| break grant;
        try sleepOrCancel(o, device.interval_s);
    };
    const redirect = try oauth.deviceRedirectUri(a, base);
    const exchanged = try oauth.exchangeCode(a, o.client, base, grant.authorization_code, redirect, grant.code_verifier);
    return codex.save(a, o.io, o.nib_home, exchanged);
}

const testing = std.testing;

test "callback targets: code and state, errors and unrelated paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try parseTarget(a, "GET /auth/callback?code=ab%2Fcd&state=s%201 HTTP/1.1");
    try testing.expectEqualStrings("ab/cd", ok.code.?);
    try testing.expectEqualStrings("s 1", ok.state.?);
    try testing.expect((try parseTarget(a, "GET /auth/callback?error=access_denied&state=s HTTP/1.1")).failed);
    try testing.expect((try parseTarget(a, "GET /favicon.ico HTTP/1.1")).other);
    try testing.expect((try parseTarget(a, "POST /auth/callback?code=x HTTP/1.1")).other);
    try testing.expect((try parseTarget(a, "")).other);
}

test "environment test hooks" {
    var env: Env = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqualStrings(oauth.default_issuer, issuer(&env));
    try testing.expectEqual(@as(u16, 1455), callbackPort(&env));
    try env.put("NIB_AUTH_ISSUER", "http://127.0.0.1:9");
    try env.put("NIB_AUTH_PORT", "4321");
    try testing.expectEqualStrings("http://127.0.0.1:9", issuer(&env));
    try testing.expectEqual(@as(u16, 4321), callbackPort(&env));
    try testing.expect(!browserLikely(&env) or builtin.os.tag == .macos);
    try env.put("SSH_CONNECTION", "x");
    try testing.expect(!browserLikely(&env));
}
