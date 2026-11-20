const std = @import("std");
const c = @import("qjs");
const console = @import("sandbox/console.zig");
const run_timing = @import("sandbox/timing.zig");
const scheduler = @import("sandbox/scheduler.zig");
const native = @import("sandbox/native.zig");
const State = scheduler.State;
pub const RunTiming = run_timing.Run;
pub const benchmark = @import("sandbox/benchmark.zig");
pub const tool_concurrency = 8;
pub const max_stopped_bytes = 4096;

pub const Recorder = @import("sandbox/record.zig").Recorder;
pub const replay = @import("sandbox/replay.zig");

// Callbacks run only on the eval thread; contexts and pending-index slices are borrowed.
pub const Virtual = struct {
    ctx: *anyopaque,
    create: *const fn (*anyopaque, usize, []const u8, []const u8) void,
    select: *const fn (*anyopaque, []const usize) ?usize,
    result: *const fn (*anyopaque, std.mem.Allocator, usize) anyerror!VirtualResult,
    stopped: *const fn (*anyopaque) bool,
    start_ms_epoch: i64,
    uses_time: bool = false,
    uses_random: bool = false,
};

pub const VirtualResult = struct {
    result: ToolResult,
    string_result: bool = false,
};

/// `JS_UNDEFINED` is a C compound-literal macro that translate-c cannot lower.
pub const js_undefined: c.JSValue = .{ .u = .{ .uint64 = 0 }, .tag = c.JS_TAG_UNDEFINED };

pub const Limits = struct {
    memory_bytes: usize = 64 * 1024 * 1024,
    stack_bytes: usize = 1024 * 1024,
    timeout_ms: i64 = 5 * 60 * 1000,
    max_log_bytes: usize = 64 * 1024,
    max_full_log_bytes: usize = 16 * 1024 * 1024,
};

pub const ToolResult = union(enum) {
    /// JSON.
    ok: []u8,
    err: []u8,
};

// Tool workers publish session-owned IDs without changing the JavaScript return value.
pub threadlocal var tool_identity: struct { id: ?[]const u8 = null, background: bool = false } = .{};

pub const Host = struct {
    ctx: *anyopaque,
    names: []const []const u8,
    /// Returned slices are allocated with `gpa` and owned by the caller.
    cancel: ?*std.atomic.Value(bool) = null,
    call: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, args_json: []const u8) ToolResult,
    poll: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    /// Runs before enqueue; rejection messages use `gpa` and are caller-owned.
    admit: ?*const fn (ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8) anyerror!?[]u8 = null,
    /// Borrowed until eval returns; inspect entries or change started/run_index only between evals.
    timing: ?*RunTiming = null,
    record: ?*Recorder = null,
    waiting: ?*std.atomic.Value(bool) = null,
    virtual: ?*Virtual = null,
    benchmark_probe: if (benchmark.enabled) ?*benchmark.Probe else void = if (benchmark.enabled) null else {},
};

pub const LogEntry = console.Entry;
pub const max_log_entries = console.max_entries;

pub const Outcome = struct {
    hook: []const u8 = "",
    hook_notice: []const u8 = "",
    ok: bool,
    /// Completion value as JSON when `ok`, otherwise error message and stack.
    text: []u8,
    logs: []u8,
    log_entries: []const LogEntry = &.{},
    log_bytes: usize = 0,
    log_head_bytes: usize = 0,
    log_tail_start: usize = 0,
    log_truncated: bool = false,
    full_logs: []const u8 = "",
    full_logs_truncated: bool = false,
    tool_bytes: u64 = 0,
    stopped: []const u8 = "",

    pub fn deinit(o: Outcome, gpa: std.mem.Allocator) void {
        gpa.free(o.hook);
        gpa.free(o.hook_notice);
        gpa.free(o.text);
        gpa.free(o.logs);
        gpa.free(o.log_entries);
        gpa.free(o.full_logs);
        gpa.free(o.stopped);
    }
};

const prelude =
    \\(() => {
    \\  const host = globalThis.__host, log = globalThis.__log, names = JSON.parse(globalThis.__names);
    \\  delete globalThis.__host; delete globalThis.__log; delete globalThis.__names;
    \\  const fmt = (x) => {
    \\    if (typeof x === "string") return x;
    \\    try { const s = JSON.stringify(x); return s === undefined ? String(x) : s; } catch { return String(x); }
    \\  };
    \\  const out = (...a) => log(a.map(fmt).join(" ") + "\n");
    \\  globalThis.console = Object.freeze({ log: out, info: out, warn: out, error: out });
    \\  const call = async (name, args) => {
    \\    if (name === "sleep" && (!Number.isInteger(args) || args < 0 || args > 2147483647))
    \\      throw new Error("sleep: ms must be an integer in 0..2147483647");
    \\    if (name === "grep" && args?.pattern instanceof RegExp) {
    \\      const re = args.pattern;
    \\      args = { ...args, pattern: re.source, ...(re.ignoreCase && !Object.hasOwn(args, "ignore_case") ? { ignore_case: true } : {}) };
    \\    }
    \\    let r;
    \\    try { r = await host(name, JSON.stringify(args ?? {})); } catch (e) { throw new Error(name + ": " + e.message); }
    \\    return r;
    \\  };
    \\  globalThis.tools = Object.freeze(Object.fromEntries(names.map((n) => [n, (a, b) => call(n, n === "mcp" ? {name: a, arguments: b === undefined ? {} : b} : n === "mcp_schema" ? {name: a} : a)])));
    \\})();
;

pub fn eval(
    gpa: std.mem.Allocator,
    io: std.Io,
    code: []const u8,
    limits: Limits,
    host: ?Host,
    cancel: ?*const std.atomic.Value(bool),
) !Outcome {
    var st: State = .{
        .gpa = gpa,
        .io = io,
        .host = host,
        .logs = .{ .limit = limits.max_log_bytes, .full_limit = limits.max_full_log_bytes },
        .js_remaining_ns = std.Io.Duration.fromMilliseconds(limits.timeout_ms).toNanoseconds(),
        .cancel = cancel,
    };
    defer st.logs.deinit(gpa);
    defer if (host) |h| if (h.record) |recorder| recorder.evalEnd(st.creation_index);

    const rt = c.JS_NewRuntime() orelse return error.OutOfMemory;
    defer c.JS_FreeRuntime(rt);
    c.JS_SetMemoryLimit(rt, limits.memory_bytes);
    c.JS_SetMaxStackSize(rt, limits.stack_bytes);
    c.JS_SetInterruptHandler(rt, native.interrupt, &st);

    const ctx = c.JS_NewContext(rt) orelse return error.OutOfMemory;
    defer c.JS_FreeContext(ctx);
    defer st.deinit(ctx);
    c.JS_SetContextOpaque(ctx, &st);

    try native.install(gpa, ctx, host);
    {
        const v = c.JS_Eval(ctx, prelude, prelude.len, "<prelude>", c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(ctx, v);
        if (c.JS_IsException(v)) return error.PreludeFailed;
    }

    if (host) |h| if (h.virtual) |v| try native.installVirtual(gpa, ctx, v);

    const src = try gpa.dupeSentinel(u8, code, 0);
    defer gpa.free(src);

    st.beginJs();
    const promise = c.JS_Eval(ctx, src.ptr, code.len, "<run>", c.JS_EVAL_TYPE_GLOBAL | c.JS_EVAL_FLAG_ASYNC);
    st.endJs();
    defer c.JS_FreeValue(ctx, promise);

    var ok = false;
    var jobs_drained = true;
    var text: []u8 = undefined;
    if (c.JS_IsException(promise)) {
        st.beginJs();
        defer st.endJs();
        text = try native.takeException(gpa, ctx);
    } else {
        st.promise = promise;
        jobs_drained = try st.jobs(ctx, rt);
        st.beginJs();
        defer st.endJs();
        switch (c.JS_PromiseState(ctx, promise)) {
            c.JS_PROMISE_FULFILLED => {
                const res = c.JS_PromiseResult(ctx, promise);
                defer c.JS_FreeValue(ctx, res);
                // Async global eval resolves to `{ value: <completion value> }`.
                const value = c.JS_GetPropertyStr(ctx, res, "value");
                defer c.JS_FreeValue(ctx, value);
                text = try native.toJson(gpa, ctx, value);
                ok = true;
            },
            c.JS_PROMISE_REJECTED => {
                const err = c.JS_PromiseResult(ctx, promise);
                defer c.JS_FreeValue(ctx, err);
                text = try native.describeError(gpa, ctx, err);
            },
            else => text = try gpa.dupe(u8, "Error: script is still awaiting something that can never settle"),
        }
    }
    errdefer gpa.free(text);
    if (!ok) {
        const annotated = try sourceContext(gpa, text, code);
        gpa.free(text);
        text = annotated;
    }
    if (jobs_drained) _ = try st.jobs(ctx, rt);
    if (st.oom) return error.OutOfMemory;

    if (scheduler.isInterrupted(&st)) {
        ok = false;
        gpa.free(text);
        text = try gpa.dupe(u8, if (st.cancel != null and st.cancel.?.load(.acquire)) "Error: run canceled" else "Error: run timed out");
    }
    const stopped = if (scheduler.isInterrupted(&st)) try st.stoppedCalls() else "";
    errdefer gpa.free(stopped);
    const captured = try st.logs.snapshot(gpa);
    return .{
        .ok = ok,
        .tool_bytes = st.tool_bytes,
        .stopped = stopped,
        .text = text,
        .logs = captured.logs,
        .log_entries = captured.entries,
        .log_bytes = st.logs.bytes,
        .log_head_bytes = captured.head_bytes,
        .log_tail_start = captured.tail_start,
        .log_truncated = st.logs.bytes > limits.max_log_bytes,
        .full_logs = captured.full,
        .full_logs_truncated = captured.full_truncated,
    };
}

const testing = std.testing;

fn sourceContext(a: std.mem.Allocator, message: []const u8, code: []const u8) ![]u8 {
    const marker = "<run>:";
    const start = std.mem.indexOf(u8, message, marker) orelse return a.dupe(u8, message);
    var location = std.mem.tokenizeAny(u8, message[start + marker.len ..], ":\r\n )");
    const line = std.fmt.parseInt(usize, location.next() orelse return a.dupe(u8, message), 10) catch return a.dupe(u8, message);
    const column = std.fmt.parseInt(usize, location.next() orelse "1", 10) catch 1;
    var lines = std.mem.splitScalar(u8, code, '\n');
    var number: usize = 0;
    while (lines.next()) |source| {
        number += 1;
        if (number != line) continue;
        var first = @min(column -| 1, source.len) -| 80;
        while (first < source.len and (source[first] & 0xc0) == 0x80) first += 1;
        var last = @min(source.len, first + 200);
        while (last > first and last < source.len and (source[last] & 0xc0) == 0x80) last -= 1;
        return std.fmt.allocPrint(a, "{s}\nsource line {d}: {s}{s}{s}", .{ message, line, if (first > 0) @as([]const u8, "…") else "", source[first..last], if (last < source.len) @as([]const u8, "…") else "" });
    }
    return a.dupe(u8, message);
}

test "syntax errors include original source location and a bounded UTF-8 line" {
    const r = try eval(testing.allocator, testing.io, "const ok = 1;\nconst broken = \"oops\n\";", .{}, null, null);
    defer r.deinit(testing.allocator);
    try testing.expect(!r.ok);
    try testing.expect(std.mem.indexOf(u8, r.text, "<run>:2:") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "source line 2: const broken = \"oops") != null);
    const code = try testing.allocator.alloc(u8, 900);
    defer testing.allocator.free(code);
    for (0..300) |i| @memcpy(code[i * 3 ..][0..3], "你");
    const message = "TypeError: bad\n    at <eval> (<run>:1:500)";
    const bounded = try sourceContext(testing.allocator, message, code);
    defer testing.allocator.free(bounded);
    try testing.expect(std.mem.startsWith(u8, bounded, message));
    try testing.expect(bounded.len <= message.len + "\nsource line 1: …".len + 200 + "…".len);
    try testing.expect(std.unicode.utf8ValidateSlice(bounded));
}

test "runtime errors retain async stack and include source context" {
    const code = "await Promise.resolve();\nconst value = null;\nvalue.missing();";
    const r = try run(code, .{}, null);
    defer r.deinit(testing.allocator);
    try testing.expect(!r.ok);
    try testing.expect(std.mem.startsWith(u8, r.text, "TypeError:"));
    try testing.expect(std.mem.indexOf(u8, r.text, "<eval> (<run>:3:") != null);
    try testing.expect(std.mem.endsWith(u8, r.text, "source line 3: value.missing();"));
}

test "source context preserves errors without a usable source line" {
    for ([_][]const u8{
        "TypeError: bad",
        "TypeError: bad\n    at <eval> (<run>:invalid:2)",
        "TypeError: bad\n    at <eval> (<run>:0:2)",
        "TypeError: bad\n    at <eval> (<run>:99:2)",
    }) |message| {
        const result = try sourceContext(testing.allocator, message, "const x = 1;");
        defer testing.allocator.free(result);
        try testing.expectEqualStrings(message, result);
    }
}

test {
    _ = @import("sandbox/timer_test.zig");
}

fn run(code: []const u8, limits: Limits, host: ?Host) !Outcome {
    return eval(testing.allocator, testing.io, code, limits, host, null);
}

test "completion value is returned as json" {
    const r = try run("const x = [1, 2].map(v => v * 2); ({ a: x })", .{}, null);
    defer r.deinit(testing.allocator);
    try testing.expect(r.ok);
    try testing.expectEqualStrings("{\"a\":[2,4]}", r.text);
}

test "top-level await and console capture" {
    const r = try run("console.log('hi', {n: 1}); await Promise.resolve(7)", .{}, null);
    defer r.deinit(testing.allocator);
    try testing.expect(r.ok);
    try testing.expectEqualStrings("7", r.text);
    try testing.expectEqualStrings("hi {\"n\":1}\n", r.logs);
}

test "errors are reported, sync and async" {
    const a = try run("throw new TypeError('boom')", .{}, null);
    defer a.deinit(testing.allocator);
    try testing.expect(!a.ok);
    try testing.expect(std.mem.startsWith(u8, a.text, "TypeError: boom"));

    const b = try run("await Promise.reject(new Error('later'))", .{}, null);
    defer b.deinit(testing.allocator);
    try testing.expect(!b.ok);
    try testing.expect(std.mem.startsWith(u8, b.text, "Error: later"));
}

test "production sandbox excludes benchmark acknowledgement bridge and probe storage" {
    if (comptime benchmark.enabled) return;
    try testing.expectEqual(0, @sizeOf(@FieldType(Host, "benchmark_probe")));
    const r = try run("typeof __benchReceived", .{}, null);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("\"undefined\"", r.text);
}

test "sandbox has no host capabilities" {
    const r = try run("[typeof require, typeof process, typeof std, typeof os, typeof fetch, typeof __host]", .{}, null);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "[\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\"]",
        r.text,
    );
}

test "memory limit is enforced" {
    const r = try run("let a = []; for (;;) a.push(new Array(1e5).fill(1));", .{ .memory_bytes = 8 * 1024 * 1024 }, null);
    defer r.deinit(testing.allocator);
    try testing.expect(!r.ok);
}

test "timeout interrupts an infinite loop" {
    const r = try run("for (;;) {}", .{ .timeout_ms = 50 }, null);
    defer r.deinit(testing.allocator);
    try testing.expect(!r.ok);
    try testing.expectEqualStrings("Error: run timed out", r.text);
    try testing.expectEqualStrings("", r.stopped);
}

test "timeout also covers JS invoked by result and error conversion" {
    for ([_][]const u8{
        "({ get x() { for (;;) {} } })",
        "throw { toString() { for (;;) {} } }",
        "throw { toString() { return 'bad' }, get stack() { for (;;) {} } }",
    }) |code| {
        const r = try run(code, .{ .timeout_ms = 50 }, null);
        defer r.deinit(testing.allocator);
        try testing.expect(!r.ok);
        try testing.expectEqualStrings("Error: run timed out", r.text);
    }
}

const EchoHost = struct {
    fn call(_: *anyopaque, gpa: std.mem.Allocator, name: []const u8, args: []const u8) ToolResult {
        if (std.mem.eql(u8, name, "fail")) return .{ .err = gpa.dupe(u8, "nope") catch unreachable };
        return .{ .ok = std.fmt.allocPrint(gpa, "{{\"tool\":\"{s}\",\"args\":{s}}}", .{ name, args }) catch unreachable };
    }
};

test "tools route through the host, errors become exceptions" {
    var dummy: u8 = 0;
    const host: Host = .{ .ctx = &dummy, .names = &.{ "echo", "fail" }, .call = EchoHost.call };
    const r = try run(
        \\const [a, b] = await Promise.all([tools.echo({x: 1}), tools.echo()]);
        \\let msg = "";
        \\try { await tools.fail({}); } catch (e) { msg = e.message; }
        \\({ a, b, msg, keys: Object.keys(tools) })
    , .{}, host);
    defer r.deinit(testing.allocator);
    try testing.expect(r.ok);
    try testing.expectEqualStrings(
        "{\"a\":{\"tool\":\"echo\",\"args\":{\"x\":1}},\"b\":{\"tool\":\"echo\",\"args\":{}},\"msg\":\"fail: nope\",\"keys\":[\"echo\",\"fail\"]}",
        r.text,
    );
}

test "result and rejection conversion callbacks drain their tool calls" {
    var dummy: u8 = 0;
    for ([_][]const u8{
        "({ toJSON() { tools.echo({x:1}).then(r => console.log('converted', r.args.x)); return 7; } })",
        "throw { toString() { tools.echo({x:1}).then(r => console.log('converted', r.args.x)); return 'original'; } }",
    }, [_]bool{ true, false }, [_][]const u8{ "7", "original" }) |code, ok, text| {
        const result = try run(code, .{}, .{ .ctx = &dummy, .names = &.{"echo"}, .call = EchoHost.call });
        defer result.deinit(testing.allocator);
        try testing.expectEqual(ok, result.ok);
        try testing.expectEqualStrings(text, result.text);
        try testing.expectEqualStrings("converted 1\n", result.logs);
        try testing.expect(result.tool_bytes > 0);
        try testing.expectEqualStrings("", result.stopped);
    }
}

test "tool concurrency is bounded while excess calls queue" {
    const Slow = struct {
        active: std.atomic.Value(usize) = .init(0),
        peak: std.atomic.Value(usize) = .init(0),
        fn call(ctx: *anyopaque, gpa: std.mem.Allocator, _: []const u8, _: []const u8) ToolResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const active = self.active.fetchAdd(1, .acq_rel) + 1;
            defer _ = self.active.fetchSub(1, .acq_rel);
            _ = self.peak.fetchMax(active, .monotonic);
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(20), .clock = .awake }, testing.io) catch unreachable;
            return .{ .ok = gpa.dupe(u8, "1") catch unreachable };
        }
    };
    var slow: Slow = .{};
    const result = try run("(await Promise.all(Array.from({length: 24}, () => tools.slow()))).length", .{}, .{ .ctx = &slow, .names = &.{"slow"}, .call = Slow.call });
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expectEqualStrings("24", result.text);
    try testing.expect(slow.peak.load(.monotonic) > 1 and slow.peak.load(.monotonic) <= tool_concurrency);
    try testing.expectEqual(0, slow.active.load(.monotonic));
}

const TimingHost = struct {
    fetched: std.atomic.Value(bool) = .init(false),
    fail_fetch: bool = false,

    fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, _: []const u8) ToolResult {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, name, "read")) {
            while (!self.fetched.load(.acquire)) std.Thread.yield() catch {};
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(40), .clock = .awake }, testing.io) catch unreachable;
        } else if (std.mem.eql(u8, name, "fetch")) {
            self.fetched.store(true, .release);
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(10), .clock = .awake }, testing.io) catch unreachable;
            if (self.fail_fetch) return .{ .err = gpa.dupe(u8, "fetch failed") catch unreachable };
        }
        return .{ .ok = gpa.dupe(u8, "{\"exit_code\":7}") catch unreachable };
    }
};

test "native timings span evals and count omitted calls without treating exit codes as errors" {
    var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
    var dummy: TimingHost = .{};
    const host: Host = .{ .ctx = &dummy, .names = &.{"bash"}, .call = TimingHost.call, .timing = &timing };
    const first = try run("await tools.bash()", .{}, host);
    defer first.deinit(testing.allocator);
    try testing.expect(first.ok);
    timing.started = .now(testing.io, .awake);
    timing.run_index = 1;
    const second = try run("await Promise.all(Array.from({length: 204}, () => tools.bash()))", .{}, host);
    defer second.deinit(testing.allocator);
    try testing.expect(second.ok);
    try testing.expectEqual(@as(usize, 200), timing.count);
    try testing.expectEqual(@as(u64, 5), timing.omitted);
    const result_size = "{\"exit_code\":7}".len;
    try testing.expectEqual(205 * result_size, timing.tool_bytes);
    try testing.expectEqual(result_size, first.tool_bytes);
    try testing.expectEqual(204 * result_size, second.tool_bytes);
    for (timing.entries[0..timing.count]) |entry| try testing.expectEqual(@as(?u64, result_size), entry.result_bytes);
    try testing.expectEqual(@as(usize, 0), timing.entries[0].run_index);
    for (timing.entries[1..timing.count]) |entry| {
        try testing.expectEqual(@as(usize, 1), entry.run_index);
        try testing.expectEqualStrings("bash", entry.name);
        try testing.expect(entry.end_ms >= entry.start_ms);
        try testing.expect(entry.ok);
    }
}

test "parallel native timings retain dispatch order and survive rejected JS with outstanding workers" {
    for ([_]bool{ false, true }) |fail_fetch| {
        var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
        var host_ctx: TimingHost = .{ .fail_fetch = fail_fetch };
        const result = try run("await Promise.all([tools.read(), tools.fetch()])", .{}, .{
            .ctx = &host_ctx,
            .names = &.{ "read", "fetch" },
            .call = TimingHost.call,
            .timing = &timing,
        });
        defer result.deinit(testing.allocator);
        try testing.expectEqual(!fail_fetch, result.ok);
        try testing.expectEqual(@as(usize, 2), timing.count);
        try testing.expectEqual(@as(u64, 0), timing.omitted);
        const read = timing.entries[0];
        const fetch = timing.entries[1];
        try testing.expectEqualStrings("read", read.name);
        try testing.expectEqualStrings("fetch", fetch.name);
        try testing.expect(read.ok);
        try testing.expectEqual(!fail_fetch, fetch.ok);
        try testing.expect(read.end_ms - read.start_ms >= 40);
        try testing.expect(fetch.end_ms - fetch.start_ms >= 10);
        try testing.expect(read.start_ms <= fetch.end_ms);
        try testing.expect(fetch.start_ms <= read.end_ms);
    }
}

test "tools queued before a top-level throw are still dispatched and billed" {
    var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
    var dummy: TimingHost = .{};
    const result = try run("tools.bash(); throw new Error('before dispatch')", .{}, .{
        .ctx = &dummy,
        .names = &.{"bash"},
        .call = TimingHost.call,
        .timing = &timing,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expectEqual(@as(usize, 1), timing.count);
    try testing.expectEqual(@as(u64, "{\"exit_code\":7}".len), result.tool_bytes);
    try testing.expectEqual(result.tool_bytes, timing.tool_bytes);
}

const FileBytesHost = struct {
    dir: std.Io.Dir,
    const missing = "missing: 文件🙂";

    fn call(ctx: *anyopaque, gpa: std.mem.Allocator, _: []const u8, args: []const u8) ToolResult {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const parsed = std.json.parseFromSlice(struct { path: []const u8 }, gpa, args, .{}) catch unreachable;
        defer parsed.deinit();
        const text = self.dir.readFileAlloc(testing.io, parsed.value.path, gpa, .limited(1024)) catch
            return .{ .err = gpa.dupe(u8, missing) catch unreachable };
        defer gpa.free(text);
        return .{ .ok = serialize(gpa, text) catch unreachable };
    }

    fn serialize(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
        return std.json.Stringify.valueAlloc(gpa, .{ .text = text, .next_offset = @as(?usize, null) }, .{});
    }
};

test "tool bytes include both file results but output bytes only include the formatted short result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = "第一份🙂\n";
    const b = "second\nline\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = a });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b", .data = b });
    const json_a = try FileBytesHost.serialize(testing.allocator, a);
    defer testing.allocator.free(json_a);
    const json_b = try FileBytesHost.serialize(testing.allocator, b);
    defer testing.allocator.free(json_b);
    var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
    var host: FileBytesHost = .{ .dir = tmp.dir };
    var result = try run("await Promise.all([tools.read({path:'a'}), tools.read({path:'b'})]); 'ok'", .{}, .{
        .ctx = &host,
        .names = &.{"read"},
        .call = FileBytesHost.call,
        .timing = &timing,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expectEqual(json_a.len + json_b.len, result.tool_bytes);
    try testing.expectEqual(result.tool_bytes, timing.tool_bytes);
    try testing.expectEqual(@as(?u64, json_a.len), timing.entries[0].result_bytes);
    try testing.expectEqual(@as(?u64, json_b.len), timing.entries[1].result_bytes);
    const output = try @import("session/output.zig").format(testing.allocator, result, @import("session/output.zig").max_bytes);
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("result: \"ok\"", output);
}

test "rejected and unawaited settled calls contribute their UTF-8 result bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "unused🙂" });
    const json = try FileBytesHost.serialize(testing.allocator, "unused🙂");
    defer testing.allocator.free(json);
    var host: FileBytesHost = .{ .dir = tmp.dir };
    for ([_][]const u8{
        "tools.read({path:'a'}); 'ok'",
        "try { await tools.read({path:'missing'}); } catch (_) {} 'ok'",
    }, [_]usize{ json.len, FileBytesHost.missing.len }) |code, expected| {
        var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
        const result = try run(code, .{}, .{
            .ctx = &host,
            .names = &.{"read"},
            .call = FileBytesHost.call,
            .timing = &timing,
        });
        defer result.deinit(testing.allocator);
        try testing.expect(result.ok);
        try testing.expectEqual(expected, result.tool_bytes);
        try testing.expectEqual(expected, timing.tool_bytes);
        try testing.expectEqual(@as(?u64, expected), timing.entries[0].result_bytes);
    }
}

test "admission rejections count only the returned error text" {
    const Rejected = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) ToolResult {
            unreachable;
        }
        fn admit(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8) anyerror!?[]u8 {
            return try gpa.dupe(u8, "denied🙂");
        }
    };
    var dummy: u8 = 0;
    var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
    const result = try run("await tools.llm().catch(() => 'caught')", .{}, .{
        .ctx = &dummy,
        .names = &.{"llm"},
        .call = Rejected.call,
        .admit = Rejected.admit,
        .timing = &timing,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expectEqual("denied🙂".len, result.tool_bytes);
    try testing.expectEqual(result.tool_bytes, timing.tool_bytes);
    try testing.expectEqual(@as(?u64, "denied🙂".len), timing.entries[0].result_bytes);
    try testing.expect(!timing.entries[0].ok);
    try testing.expect(!timing.entries[0].dispatched);
    try testing.expectEqual(@as(u64, 0), timing.llm_calls);
}

test "top-level rejection drains slow results and their continuations" {
    const FailFast = struct {
        fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, args: []const u8) ToolResult {
            if (std.mem.eql(u8, name, "fetch")) {
                const host: *TimingHost = @ptrCast(@alignCast(ctx));
                host.fetched.store(true, .release);
                return .{ .err = gpa.dupe(u8, "fetch failed") catch unreachable };
            }
            return TimingHost.call(ctx, gpa, name, args);
        }
    };
    var host: TimingHost = .{};
    var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
    var recorder = Recorder.init(testing.allocator, testing.io, "unused-record-test-path", true);
    defer recorder.deinit();
    recorder.begin(1, 0);
    const result = try run(
        \\const slow = tools.read().then(async r => {
        \\  console.log('slow delivered', r.exit_code);
        \\  const next = await tools.bash();
        \\  console.log('continuation delivered', next.exit_code);
        \\});
        \\await Promise.all([slow, tools.fetch()]);
    , .{}, .{
        .ctx = &host,
        .names = &.{ "read", "fetch", "bash" },
        .call = FailFast.call,
        .timing = &timing,
        .record = &recorder,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.startsWith(u8, result.text, "Error: fetch: fetch failed"));
    try testing.expectEqualStrings("slow delivered 7\ncontinuation delivered 7\n", result.logs);
    try testing.expectEqualStrings("", result.stopped);
    try testing.expectEqual(@as(usize, 3), timing.count);
    try testing.expectEqual(@as(u64, 2 * "{\"exit_code\":7}".len + "fetch failed".len), result.tool_bytes);
    try testing.expectEqual(result.tool_bytes, timing.tool_bytes);
    try testing.expectEqual(@as(usize, 3), recorder.seq);
    try testing.expect(!recorder.incomplete);
}

const StoppingHost = struct {
    cancel: std.atomic.Value(bool) = .init(false),
    user_cancel: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(usize) = .init(0),
    stopped: std.atomic.Value(usize) = .init(0),

    fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, args: []const u8) ToolResult {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, name, "read")) {
            if (std.mem.indexOf(u8, args, "barrier") != null) {
                while (self.started.load(.acquire) < 2 and !self.cancel.load(.acquire)) std.Thread.yield() catch {};
            }
            return .{ .ok = gpa.dupe(u8, "1") catch unreachable };
        }
        _ = self.started.fetchAdd(1, .release);
        while (!self.cancel.load(.acquire)) std.Thread.yield() catch {};
        _ = self.stopped.fetchAdd(1, .release);
        return .{ .err = gpa.dupe(u8, "not delivered") catch unreachable };
    }

    fn cancelLater(self: *@This()) void {
        while (self.started.load(.acquire) < 2 and !self.cancel.load(.acquire)) std.Thread.yield() catch {};
        if (self.cancel.load(.acquire)) return;
        std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(50), .clock = .awake }, testing.io) catch unreachable;
        self.user_cancel.store(true, .release);
    }
};

test "cancel and timeout stop only undelivered calls and preserve their creation indices" {
    for ([_]bool{ false, true }) |timeout| {
        var host: StoppingHost = .{};
        const cancel_thread = if (!timeout) try std.Thread.spawn(.{}, StoppingHost.cancelLater, .{&host}) else null;
        defer if (cancel_thread) |thread| thread.join();
        var timing: RunTiming = .init(testing.io, .now(testing.io, .awake));
        var recorder = Recorder.init(testing.allocator, testing.io, "unused-record-test-path", true);
        defer recorder.deinit();
        recorder.begin(1, 0);
        const setup = "tools.bash(); await tools.read(); tools.agent(); await tools.read({barrier:true});";
        const result = try eval(testing.allocator, testing.io, if (timeout) setup ++ "for (;;) {}" else setup ++ "await new Promise(() => {});", .{ .timeout_ms = if (timeout) 50 else 5000 }, .{
            .ctx = &host,
            .names = &.{ "bash", "read", "agent" },
            .call = StoppingHost.call,
            .cancel = &host.cancel,
            .timing = &timing,
            .record = &recorder,
        }, &host.user_cancel);
        defer result.deinit(testing.allocator);
        try testing.expect(!result.ok);
        try testing.expectEqualStrings(if (timeout) "Error: run timed out" else "Error: run canceled", result.text);
        try testing.expectEqualStrings("[stopped before completion: bash #0, agent #2]", result.stopped);
        try testing.expectEqual(@as(usize, 2), host.stopped.load(.acquire));
        try testing.expectEqual(@as(u64, 2), result.tool_bytes);
        try testing.expectEqual(result.tool_bytes, timing.tool_bytes);
        try testing.expectEqual(@as(?u64, 0), timing.entries[0].result_bytes);
        try testing.expectEqual(@as(?u64, 0), timing.entries[2].result_bytes);
        try testing.expectEqual(@as(usize, 2), recorder.seq);
        try testing.expect(recorder.incomplete);
        const output = try @import("session/output.zig").format(testing.allocator, result, @import("session/output.zig").max_bytes);
        defer testing.allocator.free(output);
        try testing.expect(std.mem.endsWith(u8, output, result.stopped));
    }
}

test "stopped facts include queued calls and bound oversized lists explicitly" {
    var dummy: u8 = 0;
    const result = try run("for (let i = 0; i < 1000; i++) tools.bash(); for (;;) {}", .{ .timeout_ms = 2000 }, .{
        .ctx = &dummy,
        .names = &.{"bash"},
        .call = EchoHost.call,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expectEqual(@as(u64, 0), result.tool_bytes);
    try testing.expect(result.stopped.len <= max_stopped_bytes);
    try testing.expect(std.mem.startsWith(u8, result.stopped, "[stopped before completion: bash #0, bash #1, "));
    try testing.expect(std.mem.endsWith(u8, result.stopped, " more]"));
    const listed = std.mem.count(u8, result.stopped, "bash #");
    const suffix = try std.fmt.allocPrint(testing.allocator, ", ..., {d} more]", .{1000 - listed});
    defer testing.allocator.free(suffix);
    try testing.expect(std.mem.endsWith(u8, result.stopped, suffix));
}

test "record and virtual replay share settlement path including admission rejects and monotonic creation indices" {
    const RecordHost = struct {
        fast: std.atomic.Value(bool) = .init(false),
        calls: std.atomic.Value(usize) = .init(0),

        fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, _: []const u8) ToolResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.calls.fetchAdd(1, .monotonic);
            if (std.mem.eql(u8, name, "slow")) {
                while (!self.fast.load(.acquire)) std.Thread.yield() catch {};
                std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(30), .clock = .awake }, testing.io) catch unreachable;
            } else if (std.mem.eql(u8, name, "fast")) self.fast.store(true, .release);
            if (std.mem.eql(u8, name, "fail")) return .{ .err = gpa.dupe(u8, "worker denied") catch unreachable };
            return .{ .ok = std.json.Stringify.valueAlloc(gpa, name, .{}) catch unreachable };
        }

        fn admit(_: *anyopaque, gpa: std.mem.Allocator, name: []const u8) !?[]u8 {
            return if (std.mem.eql(u8, name, "denied")) try gpa.dupe(u8, "admission denied") else null;
        }
    };
    var recorder = Recorder.init(testing.allocator, testing.io, "unused-record-test-path", true);
    defer recorder.deinit();
    recorder.begin(7, 2);
    var host: RecordHost = .{};
    const code = "const pending=[tools.slow(),tools.fast()]; const winner=await Promise.race(pending); await Promise.all(pending); const again=await tools.fast(); let denied,fail; try { await tools.denied(); } catch(e) { denied=e.message; } try { await tools.fail(); } catch(e) { fail=e.message; } [winner,again,denied,fail]";
    const actual = try run(code, .{}, .{ .ctx = &host, .names = &.{ "slow", "fast", "denied", "fail" }, .call = RecordHost.call, .admit = RecordHost.admit, .record = &recorder });
    defer actual.deinit(testing.allocator);
    try testing.expect(actual.ok);
    try testing.expectEqualStrings("[\"fast\",\"fast\",\"denied: admission denied\",\"fail: worker denied\"]", actual.text);
    try testing.expectEqual(@as(usize, 4), host.calls.load(.monotonic));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(replay.Entry) = .empty;
    var lines = std.mem.splitScalar(u8, recorder.buffer.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var row = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        if (row.object.contains("meta")) continue;
        if (row.object.get("result")) |value| if (value == .object) {
            _ = row.object.swapRemove("result");
            try row.object.put(a, "same_as", value.object.get("same_as").?);
        };
        var entry = try std.json.parseFromValueLeaky(replay.Entry, a, row, .{ .ignore_unknown_fields = true });
        if (entry.same_as) |hash| {
            for (entries.items) |prev| if (prev.ok == entry.ok and std.mem.eql(u8, prev.sha256, hash)) {
                entry.result = prev.result;
                entry.@"error" = prev.@"error";
                break;
            };
        }
        try entries.append(a, entry);
    }
    try testing.expectEqual(@as(usize, 5), entries.items.len);
    try testing.expectEqual(@as(usize, 1), entries.items[0].index);
    try testing.expectEqual(@as(usize, 0), entries.items[1].index);
    for (entries.items[2..], 2..) |entry, index| try testing.expectEqual(index, entry.index);
    for (entries.items, 0..) |entry, seq| try testing.expectEqual(seq, entry.seq);
    const repeated = try replay.execute(testing.allocator, testing.io, code, entries.items, recorder.start_ms_epoch, .ok, false);
    defer repeated.deinit(testing.allocator);
    try testing.expect(repeated.divergence == null);
    try testing.expectEqualStrings(actual.text, repeated.outcome.text);
}

test "eval exit records all creations even on top-level errors" {
    const Case = struct { code: []const u8, incomplete: bool, delivered: usize };
    for ([_]Case{
        .{ .code = "tools.bash(); throw new Error('pending')", .incomplete = false, .delivered = 1 },
        .{ .code = "await tools.bash(); tools.bash(); throw new Error('tail pending')", .incomplete = false, .delivered = 2 },
        .{ .code = "await Promise.all([tools.read(), tools.fetch()])", .incomplete = false, .delivered = 2 },
        .{ .code = "await tools.bash(); throw new Error('settled')", .incomplete = false, .delivered = 1 },
        .{ .code = "await tools.fetch()", .incomplete = false, .delivered = 1 },
        .{ .code = "throw new Error('zero calls')", .incomplete = false, .delivered = 0 },
    }) |case| {
        var recorder = Recorder.init(testing.allocator, testing.io, "unused-record-test-path", true);
        defer recorder.deinit();
        recorder.begin(1, 0);
        var host: TimingHost = .{ .fail_fetch = true };
        const result = try run(case.code, .{}, .{ .ctx = &host, .names = &.{ "bash", "read", "fetch" }, .call = TimingHost.call, .record = &recorder });
        defer result.deinit(testing.allocator);
        try testing.expect(!result.ok);
        try testing.expectEqual(case.incomplete, recorder.incomplete);
        try testing.expectEqual(case.delivered, recorder.seq);
    }
}

test "recording allocation failure does not change native result delivered to JS" {
    const Echo = struct {
        fn call(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8, args: []const u8) ToolResult {
            return .{ .ok = gpa.dupe(u8, args) catch unreachable };
        }
    };
    var context: u8 = 0;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var recorder = Recorder.init(failing.allocator(), testing.io, "unused-record-test-path", true);
    defer recorder.deinit();
    recorder.begin(1, 0);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    const result = try run("const r=await tools.echo({text:'中'.repeat(400000)}); [r.text.length,r.text.slice(-1)]", .{}, .{
        .ctx = &context,
        .names = &.{"echo"},
        .call = Echo.call,
        .record = &recorder,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expectEqualStrings("[400000,\"中\"]", result.text);
    try testing.expect(!recorder.enabled and recorder.warned);
    try testing.expectEqual(@as(usize, 0), recorder.seq);
    try testing.expectEqual(@as(usize, 0), recorder.buffer.items.len);
}
