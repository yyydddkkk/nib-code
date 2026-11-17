const std = @import("std");
const c = @import("qjs");
const sandbox = @import("../sandbox.zig");
const Host = sandbox.Host;
const ToolResult = sandbox.ToolResult;
const js_undefined = sandbox.js_undefined;
const console = @import("console.zig");
const Timer = @import("timer.zig").Timer;
const tool_concurrency = sandbox.tool_concurrency;
const max_stopped_bytes = sandbox.max_stopped_bytes;

pub const State = struct {
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
    creation_index: usize = 0,
    tool_bytes: u64 = 0,
    /// The Run's top-level promise; once it rejects, unexpired timers are dropped while host calls still drain.
    promise: ?c.JSValue = null,

    pub fn recordResult(st: *State, index: ?usize, bytes: usize) void {
        st.tool_bytes += bytes;
        if (st.host.?.timing) |t| t.result(index, bytes);
    }

    pub inline fn mark(st: *State, call: *Call, comptime field: []const u8) void {
        if (comptime sandbox.benchmark.enabled) {
            if (st.host.?.benchmark_probe) |probe| probe.mark(call.creation_index, field);
        }
    }

    pub const Call = struct {
        state: *State,
        index: usize,
        creation_index: usize,
        string_result: bool = false,
        name: []u8,
        args: []u8,
        settle: [2]c.JSValue,
        thread: ?std.Thread = null,
        timer: ?Timer = null,
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
            st.mark(call, "worker_enter");
            const h = st.host.?;
            const timing = if (call.timing_index != null) h.timing else null;
            const start_ms = if (timing) |t| t.elapsed() else 0;
            sandbox.tool_identity = .{};
            st.mark(call, "tool_begin");
            const result = h.call(h.ctx, st.gpa, call.name, call.args);
            st.mark(call, "tool_end");
            const end_ms = if (timing) |t| t.elapsed() else 0;
            st.mutex.lockUncancelable(st.io);
            defer st.mutex.unlock(st.io);
            if (timing) |t| {
                t.complete(call.timing_index.?, start_ms, end_ms, result == .ok);
                if (result == .ok and std.mem.eql(u8, call.name, "mcp")) {
                    const parsed = std.json.parseFromSlice(struct { ok: bool = true }, st.gpa, result.ok, .{ .ignore_unknown_fields = true }) catch null;
                    if (parsed) |p| {
                        defer p.deinit();
                        t.entries[call.timing_index.?].ok = p.value.ok;
                    }
                }
                if (sandbox.tool_identity.id) |id| {
                    t.entries[call.timing_index.?].id = id;
                    t.entries[call.timing_index.?].background = sandbox.tool_identity.background;
                }
            }
            call.result = result;
            if (st.ready_tail) |tail| tail.next = call else st.ready = call;
            st.ready_tail = call;
            st.completed.signal(st.io);
        }
    };

    pub fn beginJs(st: *State) void {
        std.debug.assert(st.js_started == null);
        st.js_started = .now(st.io, .awake);
    }

    pub fn endJs(st: *State) void {
        const started = st.js_started.?;
        st.js_remaining_ns -= started.durationTo(.now(st.io, .awake)).raw.toNanoseconds();
        st.js_started = null;
    }

    pub fn stop(st: *State) void {
        if (st.host) |h| if (h.cancel) |flag| flag.store(true, .release);
    }

    pub fn stoppedCalls(st: *State) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(st.gpa);
        defer out.deinit();
        var remaining: usize = 0;
        for (st.calls.items) |item| {
            const call = item orelse continue;
            if (remaining > 0 or out.written().len + call.name.len + 64 > max_stopped_bytes) {
                remaining += 1;
                continue;
            }
            try out.writer.print("{s}{s} #{d}", .{ if (out.written().len == 0) "[stopped before completion: " else ", ", call.name, call.creation_index });
        }
        if (remaining > 0) try out.writer.print("{s}..., {d} more", .{ if (out.written().len == 0) "[stopped before completion: " else ", ", remaining });
        if (out.written().len > 0) try out.writer.writeByte(']');
        return out.toOwnedSlice();
    }

    pub fn deinit(st: *State, ctx: *c.JSContext) void {
        st.stop();
        for (st.calls.items) |item| if (item) |call| if (call.thread) |thread| thread.join();
        for (st.calls.items) |item| if (item) |call| {
            if (call.timer != null) {
                if (st.host.?.timing) |t| if (call.timing_index) |i|
                    t.complete(i, t.entries[i].start_ms, t.elapsed(), false);
            }
            call.deinit(ctx);
        };
        st.calls.deinit(st.gpa);
    }

    pub fn deliver(st: *State, ctx: *c.JSContext, call: *Call) !void {
        st.mark(call, "deliver");
        const result = call.result.?;
        if (st.host.?.record) |recorder| {
            st.mark(call, "record_begin");
            recorder.settle(call.creation_index, call.name, call.args, result);
            st.mark(call, "record_end");
        }
        st.recordResult(call.timing_index, switch (result) {
            inline else => |bytes| bytes.len,
        });
        st.beginJs();
        defer st.endJs();
        st.mark(call, "bridge_begin");
        const value = switch (result) {
            .ok => |json| blk: {
                if (call.string_result) break :blk c.JS_NewStringLen(ctx, json.ptr, json.len);
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
        st.mark(call, "bridge_end");
        st.calls.items[call.index] = null;
        call.deinit(ctx);
    }

    fn compactCalls(st: *State, next: *usize) void {
        var len: usize = 0;
        var dispatched: usize = 0;
        for (st.calls.items, 0..) |item, index| if (item) |call| {
            // Workers retain Call pointers; only the eval thread reads array indices.
            call.index = len;
            st.calls.items[len] = call;
            len += 1;
            if (index < next.*) dispatched += 1;
        };
        st.calls.items.len = len;
        next.* = dispatched;
    }

    fn hasTimers(st: *State) bool {
        for (st.calls.items) |item| if (item) |call| {
            if (call.timer != null) return true;
        };
        return false;
    }

    pub fn jobs(st: *State, ctx: *c.JSContext, rt: *c.JSRuntime) !bool {
        var active: usize = 0;
        var next: usize = 0;
        while (true) {
            if (st.host) |h| if (h.poll) |poll| try poll(h.ctx);
            st.compactCalls(&next);
            if (virtualStopped(st)) return false;
            if (isInterrupted(st)) {
                st.stop();
                return false;
            }
            var pctx: ?*c.JSContext = null;
            st.beginJs();
            const n = c.JS_ExecutePendingJob(rt, &pctx);
            st.endJs();
            if (n < 0) return false;
            if (n > 0) continue;
            if (st.host) |h| if (h.virtual) |v| {
                if (v.stopped(v.ctx)) return false;
                var pending: std.ArrayList(usize) = .empty;
                defer pending.deinit(st.gpa);
                for (st.calls.items) |item| if (item) |call| try pending.append(st.gpa, call.creation_index);
                if (pending.items.len == 0) return true;
                const selected = v.select(v.ctx, pending.items) orelse return false;
                for (st.calls.items) |item| {
                    const call = item orelse continue;
                    if (call.creation_index != selected) continue;
                    const result = try v.result(v.ctx, st.gpa, selected);
                    call.result = result.result;
                    call.string_result = result.string_result;
                    try st.deliver(ctx, call);
                    break;
                }
                continue;
            };
            st.mutex.lockUncancelable(st.io);
            const ready = st.ready;
            if (ready) |call| st.ready = call.next;
            if (st.ready == null) st.ready_tail = null;
            st.mutex.unlock(st.io);
            if (ready) |call| {
                st.mark(call, "join_begin");
                if (call.thread) |thread| thread.join();
                st.mark(call, "join_end");
                call.thread = null;
                active -= 1;
                try st.deliver(ctx, call);
            }
            if (ready != null or c.JS_IsJobPending(rt)) continue;
            while (next < st.calls.items.len) : (next += 1) {
                const call = st.calls.items[next] orelse continue;
                if (call.timer != null) continue;
                if (active == tool_concurrency) break;
                if (call.result != null) {
                    st.mutex.lockUncancelable(st.io);
                    if (st.ready_tail) |tail| tail.next = call else st.ready = call;
                    st.ready_tail = call;
                    st.mutex.unlock(st.io);
                    active += 1;
                    continue;
                }
                st.mark(call, "dispatch");
                const timing = st.host.?.timing;
                if (timing) |t| {
                    call.timing_index = t.reserve(call.name);
                    try t.describe(call.timing_index, call.name, call.args);
                }
                st.mark(call, "spawn_begin");
                call.thread = std.Thread.spawn(.{}, Call.work, .{call}) catch |err| {
                    if (timing) |t| t.undoReservation(call.timing_index, call.name);
                    return err;
                };
                st.mark(call, "spawn_end");
                active += 1;
            }
            const failed = if (st.promise) |p| c.JS_PromiseState(ctx, p) == c.JS_PROMISE_REJECTED else false;
            var wait_ms: i64 = 20;
            var expired: ?*Call = null;
            if (!failed) for (st.calls.items) |item| if (item) |call| {
                if (call.timer) |timer| {
                    const remaining = timer.remaining(st.io);
                    wait_ms = @min(wait_ms, remaining);
                    if (remaining == 0 and (expired == null or timer.before(expired.?.timer.?)))
                        expired = call;
                }
            };
            if (expired) |call| {
                call.result = .{ .ok = try st.gpa.dupe(u8, "null") };
                if (st.host.?.timing) |t| if (call.timing_index) |i|
                    t.complete(i, t.entries[i].start_ms, t.elapsed(), true);
                try st.deliver(ctx, call);
            }
            if (expired != null or c.JS_IsJobPending(rt)) continue;
            if (active == 0 and (failed or !st.hasTimers())) return true;
            if (st.host.?.waiting) |waiting| waiting.store(true, .release);
            defer if (st.host.?.waiting) |waiting| waiting.store(false, .release);
            st.mutex.lockUncancelable(st.io);
            if (st.ready == null) st.completed.waitTimeout(st.io, &st.mutex, .{ .duration = .{ .raw = .fromMilliseconds(wait_ms), .clock = .awake } }) catch {};
            st.mutex.unlock(st.io);
        }
    }
};

pub fn isInterrupted(st: *State) bool {
    if (st.cancel) |flag| if (flag.load(.acquire)) return true;
    const elapsed = if (st.js_started) |started| started.durationTo(.now(st.io, .awake)).raw.toNanoseconds() else 0;
    return elapsed >= st.js_remaining_ns;
}

pub fn virtualStopped(st: *State) bool {
    if (st.host) |h| if (h.virtual) |v| return v.stopped(v.ctx);
    return false;
}
