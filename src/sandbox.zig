const std = @import("std");
const c = @import("qjs");
const console = @import("sandbox/console.zig");
pub const recording = @import("sandbox/record.zig");
const run_timing = @import("sandbox/timing.zig");
pub const RunTiming = run_timing.Run;

/// `JS_UNDEFINED` is a C compound-literal macro that translate-c cannot lower.
const js_undefined: c.JSValue = .{ .u = .{ .uint64 = 0 }, .tag = c.JS_TAG_UNDEFINED };

pub const Limits = struct {
    memory_bytes: usize = 64 * 1024 * 1024,
    stack_bytes: usize = 1024 * 1024,
    timeout_ms: i64 = 5 * 60 * 1000,
    max_log_bytes: usize = 64 * 1024,
};

pub const ToolResult = union(enum) {
    /// JSON.
    ok: []u8,
    err: []u8,
};

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
    record: ?*recording.Run = null,
    replay: ?*recording.Playback = null,
};

pub const LogEntry = console.Entry;
pub const max_log_entries = console.max_entries;

pub const Outcome = struct {
    ok: bool,
    /// Completion value as JSON when `ok`, otherwise error message and stack.
    text: []u8,
    logs: []u8,
    log_entries: []const LogEntry = &.{},
    log_bytes: usize = 0,
    log_head_bytes: usize = 0,
    log_tail_start: usize = 0,
    log_truncated: bool = false,

    pub fn deinit(o: Outcome, gpa: std.mem.Allocator) void {
        gpa.free(o.text);
        gpa.free(o.logs);
        gpa.free(o.log_entries);
    }
};

const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    host: ?Host,
    logs: console.Capture,
    js_remaining_ns: i96,
    js_started: ?std.Io.Clock.Timestamp = null,
    cancel: ?*const std.atomic.Value(bool),
    oom: bool = false,
    calls: std.ArrayList(?*Call) = .empty,
    mutex: std.Io.Mutex = .init,
    completed: std.Io.Condition = .init,
    ready: ?*Call = null,
    ready_tail: ?*Call = null,
    created: usize = 0,

    const Call = struct {
        state: *State,
        index: usize,
        creation_index: usize,
        replay_seq: ?usize = null,
        name: []u8,
        args: []u8,
        settle: [2]c.JSValue,
        thread: ?std.Thread = null,
        result: ?ToolResult = null,
        timing_index: ?usize = null,
        next: ?*Call = null,

        fn deinit(call: *Call, ctx: *c.JSContext) void {
            const gpa = call.state.gpa;
            if (call.result) |result| switch (result) {
                inline else => |bytes| gpa.free(bytes),
            };
            for (call.settle) |value| c.JS_FreeValue(ctx, value);
            gpa.free(call.name);
            gpa.free(call.args);
            gpa.destroy(call);
        }

        fn work(call: *Call) void {
            const st = call.state;
            const h = st.host.?;
            const timing = if (call.timing_index != null) h.timing else null;
            const start_ms = if (timing) |t| t.elapsed() else 0;
            const result = h.call(h.ctx, st.gpa, call.name, call.args);
            const end_ms = if (timing) |t| t.elapsed() else 0;
            st.mutex.lockUncancelable(st.io);
            defer st.mutex.unlock(st.io);
            if (timing) |t| t.complete(call.timing_index.?, start_ms, end_ms, result == .ok);
            call.result = result;
            if (st.ready_tail) |tail| tail.next = call else st.ready = call;
            st.ready_tail = call;
            st.completed.signal(st.io);
        }
    };

    fn beginJs(st: *State) void {
        std.debug.assert(st.js_started == null);
        st.js_started = .now(st.io, .awake);
    }

    fn endJs(st: *State) void {
        const started = st.js_started.?;
        st.js_remaining_ns -= started.durationTo(.now(st.io, .awake)).raw.toNanoseconds();
        st.js_started = null;
    }

    fn stop(st: *State) void {
        if (st.host) |h| if (h.cancel) |flag| flag.store(true, .release);
    }

    fn deinit(st: *State, ctx: *c.JSContext) void {
        st.stop();
        for (st.calls.items) |item| if (item) |call| if (call.thread) |thread| thread.join();
        for (st.calls.items) |item| if (item) |call| call.deinit(ctx);
        st.calls.deinit(st.gpa);
    }

    fn jobs(st: *State, ctx: *c.JSContext, rt: *c.JSRuntime, promise: c.JSValue) !void {
        var active: usize = 0;
        var next: usize = 0;
        while (true) {
            if (st.host) |h| if (h.poll) |poll| try poll(h.ctx);
            if (active == 0 and next == st.calls.items.len and for (st.calls.items) |item| {
                if (item != null) break false;
            } else true) {
                st.calls.clearRetainingCapacity();
                next = 0;
            }
            if (st.host) |h| if (h.replay) |p| if (p.divergence != null) return;
            if (isInterrupted(st) or c.JS_PromiseState(ctx, promise) == c.JS_PROMISE_REJECTED) {
                st.stop();
                return;
            }
            var pctx: ?*c.JSContext = null;
            st.beginJs();
            const n = c.JS_ExecutePendingJob(rt, &pctx);
            st.endJs();
            if (n < 0) return;
            if (n > 0) continue;
            st.mutex.lockUncancelable(st.io);
            var ready = st.ready;
            if (ready) |call| {
                st.ready = call.next;
                call.next = null;
                if (st.ready == null) st.ready_tail = null;
            }
            st.mutex.unlock(st.io);
            if (st.host) |h| if (h.replay) |p| {
                for (st.calls.items) |item| if (item) |call| {
                    if (call.replay_seq == p.delivered) {
                        ready = call;
                        p.delivered += 1;
                        break;
                    }
                };
                if (ready == null) for (st.calls.items) |item| if (item) |call| {
                    p.divergence = .{ .index = call.creation_index, .recorded = null, .actual = .{ .name = try p.a.dupe(u8, call.name), .args = try std.json.parseFromSliceLeaky(std.json.Value, p.a, call.args, .{ .allocate = .alloc_always }) } };
                    return;
                };
            };
            // Draining JS jobs after each settlement makes seq sufficient to replay continuations.
            if (ready) |call| {
                if (call.thread) |thread| {
                    thread.join();
                    call.thread = null;
                    active -= 1;
                }
                st.beginJs();
                defer st.endJs();
                const result = call.result.?;
                if (st.host.?.record) |record| record.capture(call.creation_index, call.name, call.args, result);
                const value = switch (result) {
                    .ok => |json| blk: {
                        // QuickJS requires buf[len] == 0 even with an explicit length.
                        const source = try st.gpa.dupeSentinel(u8, json, 0);
                        defer st.gpa.free(source);
                        break :blk c.JS_ParseJSON(ctx, source.ptr, source.len, "<tool>");
                    },
                    .err => |msg| blk: {
                        const err = c.JS_NewError(ctx);
                        _ = c.JS_SetPropertyStr(ctx, err, "message", c.JS_NewStringLen(ctx, msg.ptr, msg.len));
                        break :blk err;
                    },
                };
                const rejected = result == .err or c.JS_IsException(value);
                const arg = if (c.JS_IsException(value)) c.JS_GetException(ctx) else value;
                const r = c.JS_Call(ctx, call.settle[@intFromBool(rejected)], js_undefined, 1, @constCast(&arg));
                c.JS_FreeValue(ctx, r);
                c.JS_FreeValue(ctx, arg);
                st.calls.items[call.index] = null;
                call.deinit(ctx);
            }
            if (c.JS_IsJobPending(rt)) continue;
            while (next < st.calls.items.len and active < 8) : (next += 1) {
                const call = st.calls.items[next] orelse continue;
                if (st.host.?.replay != null) continue;
                const timing = st.host.?.timing;
                if (timing) |t| call.timing_index = t.reserve(call.name);
                call.thread = std.Thread.spawn(.{}, Call.work, .{call}) catch |err| {
                    if (timing) |t| t.undoReservation(call.timing_index, call.name);
                    return err;
                };
                active += 1;
            }
            if (active == 0) {
                if (st.host) |h| if (h.replay != null) {
                    const pending = for (st.calls.items) |item| {
                        if (item != null) break true;
                    } else false;
                    if (pending) continue;
                };
                return;
            }
            st.mutex.lockUncancelable(st.io);
            if (st.ready == null) st.completed.waitTimeout(st.io, &st.mutex, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch {};
            st.mutex.unlock(st.io);
        }
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
    \\    if (name === "grep" && args?.pattern instanceof RegExp) {
    \\      const re = args.pattern;
    \\      args = { ...args, pattern: re.source, ...(re.ignoreCase && !Object.hasOwn(args, "ignore_case") ? { ignore_case: true } : {}) };
    \\    }
    \\    let r;
    \\    try { r = await host(name, JSON.stringify(args ?? {})); } catch (e) { throw new Error(name + ": " + e.message); }
    \\    return r;
    \\  };
    \\  globalThis.tools = Object.freeze(Object.fromEntries(names.map((n) => [n, (a) => call(n, a)])));
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
        .logs = .{ .limit = limits.max_log_bytes },
        .js_remaining_ns = std.Io.Duration.fromMilliseconds(limits.timeout_ms).toNanoseconds(),
        .cancel = cancel,
    };
    defer st.logs.deinit(gpa);

    const rt = c.JS_NewRuntime() orelse return error.OutOfMemory;
    defer c.JS_FreeRuntime(rt);
    c.JS_SetMemoryLimit(rt, limits.memory_bytes);
    c.JS_SetMaxStackSize(rt, limits.stack_bytes);
    c.JS_SetInterruptHandler(rt, interrupt, &st);

    const ctx = c.JS_NewContext(rt) orelse return error.OutOfMemory;
    defer c.JS_FreeContext(ctx);
    defer st.deinit(ctx);
    c.JS_SetContextOpaque(ctx, &st);

    try install(gpa, ctx, host);
    {
        const v = c.JS_Eval(ctx, prelude, prelude.len, "<prelude>", c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(ctx, v);
        if (c.JS_IsException(v)) return error.PreludeFailed;
    }

    if (host) |h| if (h.replay) |p| {
        const setup = try std.fmt.allocPrint(gpa,
            \\(() => {{
            \\ const NativeDate = Date, mark = globalThis.__replayUse;
            \\ delete globalThis.__replayUse;
            \\ globalThis.Date = new Proxy(NativeDate, {{
            \\   apply() {{ mark(0); return new NativeDate({d}).toString(); }},
            \\   construct(target, args, receiver) {{ if (!args.length) {{ mark(0); args = [{d}]; }} return Reflect.construct(target, args, receiver); }},
            \\   get(target, key) {{ if (key === 'now') return () => {{ mark(0); return {d}; }}; return Reflect.get(target, key); }}
            \\ }});
            \\ let seed = 1;
            \\ Math.random = () => {{ mark(1); seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; }};
            \\}})();
        , .{ p.start_ms_epoch, p.start_ms_epoch, p.start_ms_epoch });
        defer gpa.free(setup);
        const source = try gpa.dupeSentinel(u8, setup, 0);
        defer gpa.free(source);
        const value = c.JS_Eval(ctx, source.ptr, setup.len, "<replay>", c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(ctx, value);
        if (c.JS_IsException(value)) return error.PreludeFailed;
    };
    const src = try gpa.dupeSentinel(u8, code, 0);
    defer gpa.free(src);

    st.beginJs();
    const promise = c.JS_Eval(ctx, src.ptr, code.len, "<run>", c.JS_EVAL_TYPE_GLOBAL | c.JS_EVAL_FLAG_ASYNC);
    st.endJs();
    defer c.JS_FreeValue(ctx, promise);

    var ok = false;
    var text: []u8 = undefined;
    if (c.JS_IsException(promise)) {
        st.beginJs();
        defer st.endJs();
        text = try takeException(gpa, ctx);
    } else {
        try st.jobs(ctx, rt, promise);
        st.beginJs();
        defer st.endJs();
        switch (c.JS_PromiseState(ctx, promise)) {
            c.JS_PROMISE_FULFILLED => {
                const res = c.JS_PromiseResult(ctx, promise);
                defer c.JS_FreeValue(ctx, res);
                // Async global eval resolves to `{ value: <completion value> }`.
                const value = c.JS_GetPropertyStr(ctx, res, "value");
                defer c.JS_FreeValue(ctx, value);
                text = try toJson(gpa, ctx, value);
                ok = true;
            },
            c.JS_PROMISE_REJECTED => {
                const err = c.JS_PromiseResult(ctx, promise);
                defer c.JS_FreeValue(ctx, err);
                text = try describeError(gpa, ctx, err);
            },
            else => text = try gpa.dupe(u8, "Error: script is still awaiting something that can never settle"),
        }
    }
    errdefer gpa.free(text);
    if (st.oom) return error.OutOfMemory;

    if (isInterrupted(&st)) {
        ok = false;
        gpa.free(text);
        text = try gpa.dupe(u8, if (host != null and host.?.replay != null and host.?.replay.?.divergence != null) "Error: replay diverged" else if (st.cancel != null and st.cancel.?.load(.acquire)) "Error: run canceled" else "Error: run timed out");
    }
    const captured = try st.logs.snapshot(gpa);
    return .{
        .ok = ok,
        .text = text,
        .logs = captured.logs,
        .log_entries = captured.entries,
        .log_bytes = st.logs.bytes,
        .log_head_bytes = captured.head_bytes,
        .log_tail_start = captured.tail_start,
        .log_truncated = st.logs.bytes > limits.max_log_bytes,
    };
}

fn install(gpa: std.mem.Allocator, ctx: *c.JSContext, host: ?Host) !void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    if (host) |h| if (h.replay != null) {
        _ = c.JS_SetPropertyStr(ctx, global, "__replayUse", c.JS_NewCFunction2(ctx, nativeReplayUse, "__replayUse", 1, c.JS_CFUNC_generic, 0));
    };
    _ = c.JS_SetPropertyStr(ctx, global, "__log", c.JS_NewCFunction2(ctx, nativeLog, "__log", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "__host", c.JS_NewCFunction2(ctx, nativeHost, "__host", 2, c.JS_CFUNC_generic, 0));
    const names = try std.json.Stringify.valueAlloc(gpa, if (host) |h| h.names else &.{}, .{});
    defer gpa.free(names);
    _ = c.JS_SetPropertyStr(ctx, global, "__names", c.JS_NewStringLen(ctx, names.ptr, names.len));
}

fn state(ctx: ?*c.JSContext) *State {
    return @ptrCast(@alignCast(c.JS_GetContextOpaque(ctx).?));
}

fn isInterrupted(st: *State) bool {
    if (st.host) |h| if (h.replay) |p| if (p.divergence != null) return true;
    if (st.cancel) |flag| if (flag.load(.acquire)) return true;
    const elapsed = if (st.js_started) |started| started.durationTo(.now(st.io, .awake)).raw.toNanoseconds() else 0;
    return elapsed >= st.js_remaining_ns;
}

fn interrupt(_: ?*c.JSContext, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(isInterrupted(@ptrCast(@alignCast(opaque_ptr.?))));
}

fn nativeLog(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const st = state(ctx);
    if (argc < 1) return js_undefined;
    var len: usize = 0;
    const p = c.JS_ToCStringLen2(ctx, &len, argv[0], false) orelse return js_undefined;
    defer c.JS_FreeCString(ctx, p);
    st.logs.append(st.gpa, p[0..len]) catch {
        st.oom = true;
    };
    return js_undefined;
}

fn nativeReplayUse(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    const p = state(ctx).host.?.replay.?;
    var kind: i32 = 0;
    if (argc > 0) _ = c.JS_ToInt32(ctx, &kind, argv[0]);
    if (kind == 0) p.uses_time = true else p.uses_random = true;
    return js_undefined;
}

fn nativeHost(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    return enqueue(state(ctx), ctx.?, argc, argv) catch c.JS_ThrowOutOfMemory(ctx);
}

fn enqueue(st: *State, ctx: *c.JSContext, argc: c_int, argv: [*c]c.JSValue) !c.JSValue {
    if (st.host == null or argc < 2) return error.InvalidHostCall;
    const call = try st.gpa.create(State.Call);
    errdefer st.gpa.destroy(call);
    const name = try toStr(st.gpa, ctx, argv[0]);
    errdefer st.gpa.free(name);
    const args = try toStr(st.gpa, ctx, argv[1]);
    errdefer st.gpa.free(args);
    var settle: [2]c.JSValue = undefined;
    const promise = c.JS_NewPromiseCapability(ctx, &settle);
    if (c.JS_IsException(promise)) return error.OutOfMemory;
    errdefer {
        c.JS_FreeValue(ctx, promise);
        for (settle) |v| c.JS_FreeValue(ctx, v);
    }
    call.* = .{ .state = st, .index = st.calls.items.len, .creation_index = st.created, .name = name, .args = args, .settle = settle };
    if (st.host.?.replay) |p| {
        const replayed = try p.dispatch(st.gpa, st.created, name, args);
        call.result = replayed.result;
        call.replay_seq = replayed.seq;
    } else if (st.host.?.admit) |admit| {
        if (try admit(st.host.?.ctx, st.gpa, name)) |message| call.result = .{ .err = message };
    }
    errdefer if (call.result) |result| switch (result) {
        inline else => |bytes| st.gpa.free(bytes),
    };
    try st.calls.append(st.gpa, call);
    st.created += 1;
    if (call.result != null and st.host.?.replay == null) {
        st.mutex.lockUncancelable(st.io);
        defer st.mutex.unlock(st.io);
        if (st.ready_tail) |tail| tail.next = call else st.ready = call;
        st.ready_tail = call;
    }
    return promise;
}

fn takeException(gpa: std.mem.Allocator, ctx: *c.JSContext) ![]u8 {
    const exc = c.JS_GetException(ctx);
    defer c.JS_FreeValue(ctx, exc);
    return describeError(gpa, ctx, exc);
}

fn toJson(gpa: std.mem.Allocator, ctx: *c.JSContext, val: c.JSValue) ![]u8 {
    if (c.JS_IsUndefined(val)) return gpa.dupe(u8, "undefined");
    const json = c.JS_JSONStringify(ctx, val, js_undefined, js_undefined);
    defer c.JS_FreeValue(ctx, json);
    if (c.JS_IsException(json) or c.JS_IsUndefined(json)) {
        c.JS_FreeValue(ctx, c.JS_GetException(ctx));
        return toStr(gpa, ctx, val);
    }
    return toStr(gpa, ctx, json);
}

fn describeError(gpa: std.mem.Allocator, ctx: *c.JSContext, exc: c.JSValue) ![]u8 {
    const msg = try toStr(gpa, ctx, exc);
    const stack = c.JS_GetPropertyStr(ctx, exc, "stack");
    defer c.JS_FreeValue(ctx, stack);
    if (c.JS_IsUndefined(stack)) return msg;
    defer gpa.free(msg);
    const st = try toStr(gpa, ctx, stack);
    defer gpa.free(st);
    return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ msg, std.mem.trimEnd(u8, st, "\n") });
}

fn toStr(gpa: std.mem.Allocator, ctx: *c.JSContext, val: c.JSValue) ![]u8 {
    var len: usize = 0;
    const p = c.JS_ToCStringLen2(ctx, &len, val, false) orelse return gpa.dupe(u8, "<unprintable>");
    defer c.JS_FreeCString(ctx, p);
    return gpa.dupe(u8, p[0..len]);
}

const testing = std.testing;

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
    try testing.expect(slow.peak.load(.monotonic) > 1 and slow.peak.load(.monotonic) <= 8);
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

test "undispatched tools do not produce native timings" {
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
    try testing.expectEqual(@as(usize, 0), timing.count);
}

test "recorded completion order replays races, sequential indices and rejection" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/s.calls.jsonl", .{tmp.sub_path});
    var recorder: recording.Recorder = .{ .gpa = testing.allocator, .io = testing.io, .path = path };
    defer recorder.deinit();
    var record = recorder.begin(1, 0);
    const Race = struct {
        timing: TimingHost = .{},
        fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, args: []const u8) ToolResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "bash")) return .{ .err = gpa.dupe(u8, "nope") catch unreachable };
            return TimingHost.call(&self.timing, gpa, name, args);
        }
    };
    var race: Race = .{};
    const code = "const a = tools.read({v: 1}), b = tools.fetch({v: 2}); console.log(await Promise.race([a.then(() => 'read'), b.then(() => 'fetch')])); await Promise.all([a, b]); await tools.bash().catch(e => e.message)";
    const original = try run(code, .{}, .{ .ctx = &race, .names = &.{ "read", "fetch", "bash" }, .call = Race.call, .record = &record });
    defer original.deinit(testing.allocator);
    try testing.expectEqualStrings("fetch\n", original.logs);
    try testing.expectEqualStrings("\"bash: nope\"", original.text);
    var rows = std.mem.tokenizeScalar(u8, record.bytes.items, '\n');
    var calls: std.ArrayList(recording.RecordedCall) = .empty;
    while (rows.next()) |line| {
        const entry = try std.json.parseFromSliceLeaky(recording.Entry, a, line, .{ .allocate = .alloc_always });
        try calls.append(a, .{ .index = entry.index.?, .seq = entry.seq.?, .name = entry.name.?, .args = entry.args.?, .ok = entry.ok.?, .text = if (entry.ok.?) (if (entry.result.? == .string) entry.result.?.string else "{\"exit_code\":7}") else entry.@"error".? });
    }
    record.finish(.ok);
    try testing.expectEqual(@as(usize, 3), calls.items.len);
    try testing.expectEqual(@as(usize, 1), calls.items[0].index);
    try testing.expectEqual(@as(usize, 0), calls.items[1].index);
    try testing.expectEqual(@as(usize, 2), calls.items[2].index);
    for (calls.items, 0..) |call, seq| try testing.expectEqual(seq, call.seq);
    var replay: recording.Playback = .{ .a = a, .calls = calls.items, .start_ms_epoch = record.start_ms_epoch };
    const host: Host = .{ .ctx = &replay, .names = &.{ "read", "fetch", "bash" }, .call = recording.Playback.unreachableCall, .replay = &replay };
    const result = try run(code, .{}, host);
    defer result.deinit(testing.allocator);
    replay.finish();
    try testing.expect(replay.divergence == null);
    try testing.expectEqualStrings(original.logs, result.logs);
    try testing.expectEqualStrings(original.text, result.text);

    replay = .{ .a = a, .calls = calls.items, .start_ms_epoch = 0, .script_mode = true };
    const changed = try run("await tools.bash().catch(e => console.log(e.message)); await tools.read({v: 1}); await tools.fetch({v: 9}).catch(e => e.message)", .{}, host);
    defer changed.deinit(testing.allocator);
    try testing.expect(changed.ok);
    try testing.expectEqualStrings("bash: nope\n", changed.logs);
    try testing.expectEqualStrings("\"fetch: not recorded: fetch\"", changed.text);

    replay = .{ .a = a, .calls = calls.items, .start_ms_epoch = 0 };
    const divergent = try run("tools.read({v: 99}); for (;;) {}", .{ .timeout_ms = 50 }, host);
    defer divergent.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), replay.divergence.?.index);
    try testing.expectEqual(@as(i64, 99), replay.divergence.?.actual.?.args.object.get("v").?.integer);
}

test "replay time and random are fixed and usage flags reflect execution" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var replay: recording.Playback = .{ .a = arena.allocator(), .calls = &.{}, .start_ms_epoch = 123456789 };
    const host: Host = .{ .ctx = &replay, .names = &.{}, .call = recording.Playback.unreachableCall, .replay = &replay };
    const code = "[Date.now(), +new Date(), Math.random(), Math.random()]";
    const first = try run(code, .{}, host);
    defer first.deinit(testing.allocator);
    try testing.expect(first.ok);
    try testing.expect(replay.uses_time and replay.uses_random);
    try testing.expect(std.mem.startsWith(u8, first.text, "[123456789,123456789,"));
    const second = try run(code, .{}, host);
    defer second.deinit(testing.allocator);
    try testing.expectEqualStrings(first.text, second.text);
    replay.uses_time = false;
    replay.uses_random = false;
    const unused = try run("false && Date.now(); +new Date(0)", .{}, host);
    defer unused.deinit(testing.allocator);
    try testing.expect(unused.ok);
    try testing.expect(!replay.uses_time and !replay.uses_random);
}

test "admission rejection uses the recording settlement hook" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/s.calls.jsonl", .{tmp.sub_path});
    defer testing.allocator.free(path);
    var recorder: recording.Recorder = .{ .gpa = testing.allocator, .io = testing.io, .path = path };
    defer recorder.deinit();
    var record = recorder.begin(1, 0);
    const Admission = struct {
        fn reject(_: *anyopaque, gpa: std.mem.Allocator, _: []const u8) !?[]u8 {
            return try gpa.dupe(u8, "limit");
        }
    };
    var dummy: u8 = 0;
    const result = try run("await tools.llm().catch(e => e.message)", .{}, .{ .ctx = &dummy, .names = &.{"llm"}, .call = recording.Playback.unreachableCall, .admit = Admission.reject, .record = &record });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("\"llm: limit\"", result.text);
    try testing.expect(std.mem.indexOf(u8, record.bytes.items, "\"error\":\"limit\"") != null);
    record.finish(.ok);
}
