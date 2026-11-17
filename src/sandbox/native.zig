const std = @import("std");
const c = @import("qjs");
const sandbox = @import("../sandbox.zig");
const Host = sandbox.Host;
const Virtual = sandbox.Virtual;
const js_undefined = sandbox.js_undefined;
const scheduler = @import("scheduler.zig");
const State = scheduler.State;
const isInterrupted = scheduler.isInterrupted;
const virtualStopped = scheduler.virtualStopped;

pub fn install(gpa: std.mem.Allocator, ctx: *c.JSContext, host: ?Host) !void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    _ = c.JS_SetPropertyStr(ctx, global, "__log", c.JS_NewCFunction2(ctx, nativeLog, "__log", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "__host", c.JS_NewCFunction2(ctx, nativeHost, "__host", 2, c.JS_CFUNC_generic, 0));
    if (comptime sandbox.benchmark.enabled) {
        _ = c.JS_SetPropertyStr(ctx, global, "__benchReceived", c.JS_NewCFunction2(ctx, benchmarkReceived, "__benchReceived", 1, c.JS_CFUNC_generic, 0));
    }
    const names = try std.json.Stringify.valueAlloc(gpa, if (host) |h| h.names else &.{}, .{});
    defer gpa.free(names);
    _ = c.JS_SetPropertyStr(ctx, global, "__names", c.JS_NewStringLen(ctx, names.ptr, names.len));
}

fn benchmarkReceived(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    if (comptime sandbox.benchmark.enabled) {
        if (state(ctx).host.?.benchmark_probe) |probe| {
            var index: u32 = 0;
            if (argc != 1 or c.JS_ToUint32(ctx, &index, argv[0]) != 0) {
                probe.invalid_ack = true;
            } else probe.received(index);
        }
    }
    return js_undefined;
}

fn virtualTime(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
    state(ctx).host.?.virtual.?.uses_time = true;
    return js_undefined;
}

fn virtualRandom(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
    state(ctx).host.?.virtual.?.uses_random = true;
    return js_undefined;
}

pub fn installVirtual(_: std.mem.Allocator, ctx: *c.JSContext, v: *Virtual) !void {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    _ = c.JS_SetPropertyStr(ctx, global, "__replayEpoch", c.JS_NewFloat64(ctx, @floatFromInt(v.start_ms_epoch)));
    _ = c.JS_SetPropertyStr(ctx, global, "__replayTime", c.JS_NewCFunction2(ctx, virtualTime, "time", 0, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, global, "__replayRandom", c.JS_NewCFunction2(ctx, virtualRandom, "random", 0, c.JS_CFUNC_generic, 0));
    const source = @import("virtual.zig").prelude;
    const result = c.JS_Eval(ctx, source, source.len, "<virtual>", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, result);
    if (c.JS_IsException(result)) return error.PreludeFailed;
}

pub fn state(ctx: ?*c.JSContext) *State {
    return @ptrCast(@alignCast(c.JS_GetContextOpaque(ctx).?));
}

pub fn interrupt(_: ?*c.JSContext, opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const st: *State = @ptrCast(@alignCast(opaque_ptr.?));
    return @intFromBool(isInterrupted(st) or virtualStopped(st));
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

fn nativeHost(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    return enqueue(state(ctx), ctx.?, argc, argv) catch |err| {
        if (err == error.ReplayDivergence) {
            const reason = c.JS_NewError(ctx);
            _ = c.JS_SetPropertyStr(ctx, reason, "message", c.JS_NewString(ctx, "replay diverged"));
            return c.JS_Throw(ctx, reason);
        }
        return c.JS_ThrowOutOfMemory(ctx);
    };
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
    call.* = .{ .state = st, .index = st.calls.items.len, .creation_index = st.creation_index, .name = name, .args = args, .settle = settle };
    if (st.host.?.virtual) |v| {
        v.create(v.ctx, st.creation_index, name, args);
        if (v.stopped(v.ctx)) return error.ReplayDivergence;
    } else if (st.host.?.admit) |admit| {
        if (try admit(st.host.?.ctx, st.gpa, name)) |message| {
            call.result = .{ .err = message };
            if (st.host.?.timing) |t| {
                call.timing_index = t.reserveEntry(name);
                if (call.timing_index) |i| {
                    const ms = t.elapsed();
                    t.complete(i, ms, ms, false);
                    t.entries[i].dispatched = false;
                }
            }
        }
    }
    errdefer if (call.result) |result| switch (result) {
        inline else => |bytes| st.gpa.free(bytes),
    };
    if (st.host.?.virtual == null and call.result == null and std.mem.eql(u8, name, "sleep")) {
        const ms = try std.json.parseFromSlice(u31, st.gpa, args, .{});
        defer ms.deinit();
        call.timer = .init(st.io, ms.value);
    }
    st.creation_index += 1;
    try st.calls.append(st.gpa, call);
    st.mark(call, "enqueued");
    if (call.timer != null) {
        if (st.host.?.timing) |t| {
            call.timing_index = t.reserve(name);
            if (call.timing_index) |i| {
                const ms = t.elapsed();
                t.complete(i, ms, ms, false);
            }
        }
    }
    return promise;
}

pub fn takeException(gpa: std.mem.Allocator, ctx: *c.JSContext) ![]u8 {
    const exc = c.JS_GetException(ctx);
    defer c.JS_FreeValue(ctx, exc);
    return describeError(gpa, ctx, exc);
}

pub fn toJson(gpa: std.mem.Allocator, ctx: *c.JSContext, val: c.JSValue) ![]u8 {
    if (c.JS_IsUndefined(val)) return gpa.dupe(u8, "undefined");
    const json = c.JS_JSONStringify(ctx, val, js_undefined, js_undefined);
    defer c.JS_FreeValue(ctx, json);
    if (c.JS_IsException(json) or c.JS_IsUndefined(json)) {
        c.JS_FreeValue(ctx, c.JS_GetException(ctx));
        return toStr(gpa, ctx, val);
    }
    return toStr(gpa, ctx, json);
}

pub fn describeError(gpa: std.mem.Allocator, ctx: *c.JSContext, exc: c.JSValue) ![]u8 {
    const msg = try toStr(gpa, ctx, exc);
    const stack = c.JS_GetPropertyStr(ctx, exc, "stack");
    defer c.JS_FreeValue(ctx, stack);
    if (c.JS_IsUndefined(stack)) return msg;
    defer gpa.free(msg);
    const st = try toStr(gpa, ctx, stack);
    defer gpa.free(st);
    return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ msg, std.mem.trimEnd(u8, st, "\n") });
}

pub fn toStr(gpa: std.mem.Allocator, ctx: *c.JSContext, val: c.JSValue) ![]u8 {
    var len: usize = 0;
    const p = c.JS_ToCStringLen2(ctx, &len, val, false) orelse return gpa.dupe(u8, "<unprintable>");
    defer c.JS_FreeCString(ctx, p);
    return gpa.dupe(u8, p[0..len]);
}
