const std = @import("std");
const sandbox = @import("../sandbox.zig");
const tools = @import("../tools.zig");
const Tools = tools.Tools;
const fail = tools.fail;
const provider = @import("../provider.zig");
const JsonEvent = @import("../session/events.zig").JsonEvent;
const process = @import("process.zig");
const Progress = @import("../session/events.zig").Progress;

const Args = struct { prompt: []const u8, @"resume": ?[]const u8 = null, fork: bool = false, timeout_ms: i64 = 1_800_000, model: ?[]const u8 = null, effort: ?[]const u8 = null, background: bool = false };

pub fn agent(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const a = std.json.parseFromSlice(Args, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ prompt: string, resume?: string, fork?: boolean, timeout_ms?: number, model?: string, effort?: string, background?: boolean }}", .{});
    defer a.deinit();
    const raw = try std.json.parseFromSlice(std.json.Value, gpa, args, .{});
    defer raw.deinit();
    if (t.depth != 0 or t.forked) return fail(gpa, "{s}", .{if (t.forked) "agent is unavailable inside a forked sub-agent" else "agent is unavailable inside a sub-agent"});
    if (raw.value.object.contains("fork") and raw.value.object.contains("resume"))
        return fail(gpa, "fork and resume cannot be passed together", .{});
    if (a.value.fork and t.fork_snapshot == null) return fail(gpa, "fork requires a current conversation history", .{});
    if (raw.value.object.get("resume")) |value| {
        if (value != .string) return fail(gpa, "resume must be a string", .{});
    }
    if (a.value.timeout_ms <= 0) return fail(gpa, "timeout_ms must be positive", .{});
    var cfg = t.cfg orelse return error.AgentConfigUnavailable;
    if (a.value.fork) {
        cfg.thinking = t.fork_snapshot.?.thinking;
        cfg.reasoning_effort = t.fork_snapshot.?.reasoning_effort;
    }
    if (a.value.model) |model| cfg.model = model;
    if (a.value.effort) |effort| try cfg.setEffort(effort);
    const id = if (a.value.@"resume") |requested| block: {
        const reserved = t.agent_sessions.reserve(t.io, requested) catch |err| {
            const out: Output = .{ .id = requested };
            return out.result(gpa, 0, @errorName(err), null);
        };
        break :block reserved;
    } else block: {
        const allocated = try t.progress.addAgent(gpa, t.io, a.value.prompt, t.run_id, a.value.background, a.value.fork);
        try t.agent_sessions.add(gpa, t.io, allocated, null, true);
        t.agent_sessions.setFork(t.io, allocated, a.value.fork);
        break :block allocated;
    };
    var transferred = false;
    errdefer if (!transferred) t.agent_sessions.release(t.io, id);
    if (a.value.@"resume" != null)
        try t.progress.restart(gpa, t.io, .{ .id = id, .prompt = a.value.prompt, .run = t.run_id, .background = a.value.background, .fork = t.agent_sessions.isFork(t.io, id), .state = .queued });
    const fork_input = if (a.value.fork) blk: {
        var copy = t.fork_snapshot.?;
        copy.id = id;
        break :blk try std.json.Stringify.valueAlloc(gpa, @import("agent/input.zig").Input{ .prompt = a.value.prompt, .config = cfg, .fork = copy }, .{});
    } else null;
    defer if (fork_input) |input| gpa.free(input);
    if (a.value.background) {
        const result = try t.background.startAgent(t, gpa, args, a.value.prompt, id, fork_input);
        transferred = true;
        return .{ .ok = result };
    }
    sandbox.tool_identity = .{ .id = id };
    transferred = true;
    return execute(t, gpa, args, &t.cancel, id, t.run_id, false, fork_input, null);
}

pub fn execute(t: *Tools, gpa: std.mem.Allocator, args: []const u8, cancel: *const std.atomic.Value(bool), id: []const u8, run_id: usize, background: bool, fork_input: ?[]const u8, cwd: ?[]const u8) !sandbox.ToolResult {
    defer if (!background) t.agent_sessions.release(t.io, id);
    const session = t.agent_sessions.session(t.io, id);
    const a = try std.json.parseFromSlice(Args, gpa, args, .{ .ignore_unknown_fields = true });
    defer a.deinit();
    var cfg = t.cfg orelse return error.AgentConfigUnavailable;
    if (a.value.model) |model| cfg.model = model;
    if (a.value.effort) |effort| try cfg.setEffort(effort);
    var tracker: Tracker = .{
        .t = t,
        .arena = .init(gpa),
        .value = .{ .id = id, .run = run_id, .invocation = t.progress.currentInvocation(t.io, id), .background = background, .fork = fork_input != null or t.agent_sessions.isFork(t.io, id), .race = cwd != null, .prompt = a.value.prompt },
        .output = .{ .id = id, .requested_session = session },
    };
    defer tracker.arena.deinit();
    defer t.addUsage(tracker.output.usage);
    var state: @FieldType(Progress, "state") = .failed;
    defer {
        tracker.value.state = state;
        tracker.publish();
    }
    if (cancel.load(.acquire)) {
        state = .canceled;
        return error.Canceled;
    }
    t.agents_mutex.lockUncancelable(t.io);
    while (cwd == null and t.agents_active >= cfg.limits.agent_concurrency and !cancel.load(.acquire))
        t.agents_changed.waitTimeout(t.io, &t.agents_mutex, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch {};
    const canceled = cancel.load(.acquire);
    if (!canceled) t.agents_active += 1;
    t.agents_mutex.unlock(t.io);
    if (canceled) {
        state = .canceled;
        return error.Canceled;
    }
    tracker.publish();
    defer {
        t.agents_mutex.lockUncancelable(t.io);
        t.agents_active -= 1;
        t.agents_changed.signal(t.io);
        t.agents_mutex.unlock(t.io);
    }
    var env = try (t.environ orelse return error.AgentEnvironmentUnavailable).clone(gpa);
    defer env.deinit();
    const depth = try std.fmt.allocPrint(gpa, "{d}", .{t.depth + 1});
    defer gpa.free(depth);
    try env.put("NIB_AGENT_DEPTH", depth);
    try env.put("NIB_PARENT_SESSION_ID", t.session_id orelse return error.MissingSessionId);
    const executable = try std.process.executablePathAlloc(t.io, gpa);
    defer gpa.free(executable);
    const input = fork_input orelse try std.json.Stringify.valueAlloc(gpa, @import("agent/input.zig").Input{ .prompt = a.value.prompt, .config = cfg }, .{});
    defer if (fork_input == null) gpa.free(input);
    const started = std.Io.Clock.awake.now(t.io);
    const result = process.run(gpa, t.io, .{
        .spawn = .{ .argv = if (session) |child| &.{ executable, "ask", "--json", "--agent-input", "--resume", child, "-" } else &.{ executable, "ask", "--json", "--agent-input", "-" }, .environ_map = &env, .cwd = if (cwd) |path| .{ .path = path } else .inherit, .stdout = .pipe, .stderr = .ignore },
        .input = input,
        .cancel = cancel,
        .timeout_ms = a.value.timeout_ms,
        .termination_grace_ms = 500,
        .on_line = .{ .ctx = &tracker, .emit = Tracker.line },
    }) catch |err| {
        if (cancel.load(.acquire)) {
            state = .canceled;
            return error.Canceled;
        }
        return tracker.output.result(gpa, started.durationTo(std.Io.Clock.awake.now(t.io)).toMilliseconds(), @errorName(err), null);
    };
    defer gpa.free(result.output);
    if (result.stop == null) {
        const tail = if (std.mem.lastIndexOfScalar(u8, result.output, '\n')) |last| result.output[last + 1 ..] else result.output;
        if (tail.len > 0) tracker.capture(tail);
    }
    const output = &tracker.output;
    tracker.value.usage = output.usage;
    if (output.steps) |steps| tracker.value.step = steps;
    if (cancel.load(.acquire) or (if (result.stop) |stop| stop == error.Canceled else false)) {
        state = .canceled;
        return error.Canceled;
    }
    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(t.io)).toMilliseconds();
    const reason: ?[]const u8 = if (if (result.stop) |stop| stop == error.TimedOut else false) reason: {
        state = .timed_out;
        break :reason "stopped due to timeout";
    } else if (!result.term.success())
        output.failure orelse "AgentFailed (process crashed or exited nonzero)"
    else if (output.failure) |failure| failure else if (!output.ended) "MissingAgentResult" else null;
    if (reason == null) state = if (cwd != null) .working else .done;
    return output.result(gpa, elapsed_ms, reason, if (state == .timed_out) a.value.timeout_ms else null);
}

const Change = struct { path: []const u8, added: usize, removed: usize, created: bool = false };

const Output = struct {
    text: std.ArrayList(u8) = .empty,
    usage: provider.Usage = .{},
    changes: std.ArrayList(Change) = .empty,
    child_id: ?[]const u8 = null,
    requested_session: ?[]const u8 = null,
    id: []const u8 = "",
    steps: ?u32 = null,
    ended: bool = false,
    failure: ?[]const u8 = null,

    fn observe(out: *Output, gpa: std.mem.Allocator, a: std.mem.Allocator, bytes: []const u8) !void {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const value = try std.json.parseFromSliceLeaky(std.json.Value, temp, bytes, .{});
        if (value != .object) return error.InvalidAgentOutput;
        const obj = value.object;
        if (obj.contains("start")) {
            if (out.child_id != null) return error.InvalidAgentOutput;
            const event = try std.json.parseFromValueLeaky(JsonEvent, temp, value, .{});
            if (out.requested_session) |id| {
                if (!std.mem.eql(u8, id, event.start.session_id)) return error.InvalidAgentOutput;
            }
            out.child_id = try a.dupe(u8, event.start.session_id);
        }
        if (obj.get("delta")) |delta| {
            const d = try std.json.parseFromValueLeaky(struct { kind: provider.Kind, text: []const u8 }, temp, delta, .{ .ignore_unknown_fields = true });
            if (d.kind == .text) try out.text.appendSlice(a, d.text);
        }
        if (obj.get("usage")) |usage| out.usage = try std.json.parseFromValueLeaky(provider.Usage, temp, usage, .{ .ignore_unknown_fields = true });
        if (obj.get("run_end")) |run| {
            const r = try std.json.parseFromValueLeaky(struct { changes: []const Change = &.{} }, temp, run, .{ .ignore_unknown_fields = true });
            for (r.changes) |change| {
                for (out.changes.items) |*known| {
                    if (!std.mem.eql(u8, known.path, change.path)) continue;
                    known.added += change.added;
                    known.removed += change.removed;
                    known.created = known.created or change.created;
                    break;
                } else {
                    var summary = change;
                    summary.path = try a.dupe(u8, change.path);
                    try out.changes.append(a, summary);
                }
            }
        }
        if (obj.contains("end") or obj.contains("error")) {
            if (out.ended) return error.InvalidAgentOutput;
            const event = try std.json.parseFromValueLeaky(JsonEvent, temp, value, .{ .ignore_unknown_fields = true });
            out.ended = true;
            switch (event) {
                .end => |end| {
                    out.text.clearRetainingCapacity();
                    try out.text.appendSlice(a, end.text);
                    out.usage = end.usage;
                    out.steps = end.steps;
                },
                .@"error" => |err| {
                    out.failure = try a.dupe(u8, err.message);
                    out.usage = err.usage;
                    out.steps = err.steps;
                },
                else => return error.InvalidAgentOutput,
            }
        }
    }

    fn result(out: *const Output, gpa: std.mem.Allocator, elapsed_ms: i64, reason: ?[]const u8, timeout_ms: ?i64) !sandbox.ToolResult {
        if (reason) |message| {
            const detail = if (timeout_ms) |limit|
                try std.fmt.allocPrint(gpa, "subagent stopped due to timeout after {d} ms (limit {d} ms); task id: {s}. Files it changed may be incomplete; inspect them before continuing.", .{ elapsed_ms, limit, out.id })
            else
                try std.fmt.allocPrint(gpa, "subagent: {s} after {d} ms; task id: {s}. Files it changed may be incomplete; inspect them before continuing.", .{ message, elapsed_ms, out.id });
            defer gpa.free(detail);
            return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = false, .id = out.id, .@"error" = detail, .text = out.text.items, .usage = out.usage, .changes = out.changes.items }, .{}) };
        }
        return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .id = out.id, .text = out.text.items, .usage = out.usage, .changes = out.changes.items }, .{}) };
    }
};

const Tracker = struct {
    t: *Tools,
    arena: std.heap.ArenaAllocator,
    value: Progress,
    completed_steps: u32 = 0,
    reply_started: bool = false,
    pending_reply: bool = false,
    post_run_usage: bool = false,
    output: Output = .{},

    fn publish(tr: *Tracker) void {
        tr.t.progress.update(tr.arena.child_allocator, tr.t.io, tr.value) catch {};
    }

    fn line(ctx: *anyopaque, bytes: []const u8) void {
        const tr: *Tracker = @ptrCast(@alignCast(ctx));
        tr.capture(bytes);
        tr.observe(bytes) catch {};
    }

    fn capture(tr: *Tracker, bytes: []const u8) void {
        const had_session = tr.output.child_id != null;
        tr.output.observe(tr.arena.child_allocator, tr.arena.allocator(), bytes) catch |err| {
            tr.output.failure = @errorName(err);
        };
        if (!had_session) if (tr.output.child_id) |session| {
            tr.bindSession(session) catch |err| {
                tr.output.failure = @errorName(err);
            };
        };
    }

    fn bindSession(tr: *Tracker, session: []const u8) !void {
        if (tr.value.race) return;
        const t = tr.t;
        const gpa = tr.arena.child_allocator;
        if (t.agent_sessions.session(t.io, tr.value.id)) |known| {
            if (!std.mem.eql(u8, known, session)) return error.AgentSessionMismatch;
            return;
        }
        const log = t.background.log orelse return error.AgentLogUnavailable;
        try log.agentSession(t.io, gpa, .{ .id = tr.value.id, .session = session, .fork = tr.value.fork });
        try t.agent_sessions.bind(gpa, t.io, tr.value.id, session);
    }

    fn observe(tr: *Tracker, bytes: []const u8) !void {
        const gpa = tr.arena.child_allocator;
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;
        const a = tr.arena.allocator();
        if (obj.contains("notice")) {
            tr.pending_reply = false;
            return;
        }
        if (obj.contains("delta")) {
            if (tr.reply_started) return;
            tr.value.step = tr.completed_steps + 1;
            tr.reply_started = true;
        } else if (!obj.contains("run_start") and !obj.contains("usage") and !obj.contains("run_end")) return;
        if (obj.get("run_start")) |code| {
            if (code != .string) return;
            if (tr.pending_reply) {
                tr.completed_steps += 1;
                tr.value.step = tr.completed_steps;
                tr.pending_reply = false;
            }
            var used: std.ArrayList([]const u8) = .empty;
            var rest = code.string;
            while (std.mem.indexOf(u8, rest, "tools.")) |i| {
                rest = rest[i + 6 ..];
                var end: usize = 0;
                while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
                if (end == 0) continue;
                const name = rest[0..end];
                var call = end;
                while (call < rest.len and std.ascii.isWhitespace(rest[call])) call += 1;
                if (call == rest.len or rest[call] != '(') continue;
                for (used.items) |known| {
                    if (std.mem.eql(u8, name, known)) break;
                } else try used.append(a, try a.dupe(u8, name));
            }
            tr.value.tools = used.items;
            tr.value.files = &.{};
        }
        if (obj.get("run_end")) |run| {
            const r = try std.json.parseFromValue(struct { changes: []const struct { path: []const u8 } = &.{} }, gpa, run, .{ .ignore_unknown_fields = true });
            defer r.deinit();
            var files: std.ArrayList([]const u8) = .empty;
            for (r.value.changes) |change| try files.append(a, try a.dupe(u8, change.path));
            tr.value.files = files.items;
            tr.post_run_usage = true;
        }
        if (obj.get("usage")) |snapshot| {
            const u = try std.json.parseFromValue(provider.Usage, gpa, snapshot, .{ .ignore_unknown_fields = true });
            defer u.deinit();
            tr.value.usage = u.value;
            tr.output.usage = u.value;
            // Each Run repeats the Step's usage; compaction usage has no following Run.
            if (tr.post_run_usage) {
                tr.post_run_usage = false;
            } else if (tr.reply_started) {
                tr.completed_steps = tr.value.step;
                tr.reply_started = false;
            } else tr.pending_reply = true;
        }
        tr.publish();
    }
};

test "child progress counts Steps rather than Runs and ignores compaction snapshots" {
    const testing = std.testing;
    var t: Tools = .{ .io = testing.io, .home = "/unused" };
    defer t.progress.deinit(testing.allocator);
    defer t.agent_sessions.deinit(testing.allocator);
    var tr: Tracker = .{
        .t = &t,
        .arena = .init(testing.allocator),
        .value = .{ .id = try t.progress.add(testing.allocator, testing.io, .agent, "child", 0, false), .prompt = "child" },
    };
    defer tr.arena.deinit();
    try tr.observe("{\"delta\":{}}");
    try tr.observe("{\"delta\":{}}");
    try tr.observe("{\"usage\":{\"prompt_tokens\":100}}");
    try tr.observe("{\"run_start\":\"await tools.edit({}); await tools.edit({}); await tools.read({}); typeof tools.agent\"}");
    try testing.expectEqual(@as(u32, 1), tr.value.step);
    try testing.expectEqual(@as(usize, 2), tr.value.tools.len);
    try testing.expectEqualStrings("edit", tr.value.tools[0]);
    try tr.observe("{\"run_end\":{\"changes\":[{\"path\":\"a.zig\",\"diff\":\"unused\"}]}}");
    try testing.expectEqualStrings("a.zig", tr.value.files[0]);
    try tr.observe("{\"usage\":{\"prompt_tokens\":100}}");
    try tr.observe("{\"run_start\":\"await tools.bash({})\"}");
    try testing.expectEqual(@as(u32, 1), tr.value.step);
    try testing.expectEqual(@as(usize, 0), tr.value.files.len);
    try tr.observe("{\"run_end\":{}}");
    try tr.observe("{\"usage\":{\"prompt_tokens\":100}}");
    try tr.observe("{\"usage\":{\"prompt_tokens\":150}}");
    try tr.observe("{\"notice\":\"compacted\"}");
    try tr.observe("{\"delta\":{}}");
    try testing.expectEqual(@as(u32, 2), tr.value.step);
    try tr.observe("{\"usage\":{\"prompt_tokens\":250}}");
    try tr.observe("{\"run_start\":\"tools.read({})\"}");
    try tr.observe("{\"run_end\":{}}");
    try tr.observe("{\"usage\":{\"prompt_tokens\":250}}");
    try tr.observe("{\"usage\":{\"prompt_tokens\":350}}");
    try tr.observe("{\"run_start\":\"tools.read({})\"}");
    try testing.expectEqual(@as(u32, 3), tr.value.step);
    try testing.expectEqual(@as(u64, 350), tr.value.usage.prompt_tokens);
}

test "agent output retains only returned data and terminal text overrides deltas" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Output = .{ .id = "a1" };
    for (0..500) |_| try out.observe(testing.allocator, arena.allocator(), "{\"delta\":{\"kind\":\"reasoning\",\"text\":\"ignored reasoning\"}}");
    try testing.expectEqual(@as(usize, 0), arena.queryCapacity());
    try out.observe(testing.allocator, arena.allocator(), "{\"delta\":{\"kind\":\"text\",\"text\":\"partial\"}}");
    try testing.expectEqualStrings("partial", out.text.items);
    try out.observe(testing.allocator, arena.allocator(), "{\"run_end\":{\"changes\":[{\"path\":\"a\",\"added\":2,\"removed\":1,\"created\":true,\"diff\":\"not retained\"}]}}");
    try testing.expectEqualStrings("a", out.changes.items[0].path);
    try out.observe(testing.allocator, arena.allocator(), "{\"start\":{\"session_id\":\"0123456789abcdef0123456789abcdef\"}}");
    try out.observe(testing.allocator, arena.allocator(), "{\"end\":{\"text\":\"final\",\"usage\":{\"prompt_tokens\":10},\"steps\":2}}");
    try testing.expectEqualStrings("final", out.text.items);
    try testing.expectEqual(@as(u64, 10), out.usage.prompt_tokens);
    const result = try out.result(testing.allocator, 1, null, null);
    defer tools.freeResult(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.ok, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("ok").?.bool);
    try testing.expectEqualStrings("a1", parsed.value.object.get("id").?.string);
    try testing.expect(!parsed.value.object.contains("session"));
}

test "agent failure without output is data and queued user cancellation rejects" {
    const testing = std.testing;
    const out: Output = .{};
    const result = try out.result(testing.allocator, 12, "AgentFailed", null);
    defer tools.freeResult(result);
    try testing.expect(result == .ok);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.ok, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(!obj.get("ok").?.bool);
    try testing.expectEqualStrings("", obj.get("text").?.string);
    try testing.expect(!obj.contains("session"));
    var t: Tools = .{ .io = testing.io, .home = "/unused", .cfg = .{ .model = "m", .base_url = "", .api_key = "" }, .agents_active = 4 };
    defer t.progress.deinit(testing.allocator);
    defer t.agent_sessions.deinit(testing.allocator);
    t.cancel.store(true, .release);
    try testing.expectError(error.Canceled, agent(&t, testing.allocator, "{\"prompt\":\"cancelled\"}"));
    try testing.expectEqual(@as(usize, 4), t.agents_active);
}

test "foreground agent records its ID even when startup fails and continues across Runs" {
    const testing = std.testing;
    var t: Tools = .{ .io = testing.io, .home = "/unused", .cfg = .{ .model = "m", .base_url = "", .api_key = "" } };
    defer t.progress.deinit(testing.allocator);
    defer t.agent_sessions.deinit(testing.allocator);
    var timing: sandbox.RunTiming = .init(testing.io, .now(testing.io, .awake));
    var host = t.host();
    host.timing = &timing;
    for (0..2) |_| {
        t.cancel.store(false, .release);
        const result = try sandbox.eval(testing.allocator, testing.io, "await tools.agent({prompt: 'child'})", .{}, host, null);
        defer result.deinit(testing.allocator);
        try testing.expect(!result.ok);
        try testing.expectEqual(.failed, t.progress.slots.items[0].value.state);
        t.progress.clear(testing.allocator);
    }
    try testing.expectEqualStrings("a1", timing.entries[0].id.?);
    try testing.expectEqualStrings("a2", timing.entries[1].id.?);
    try testing.expectEqual(@as(?bool, false), timing.entries[0].background);
    try testing.expectEqual(@as(u64, 1), t.progress.next_bash_id);
}

test "execute publishes the reserved invocation on foreground and background cancellation" {
    const testing = std.testing;
    var t: Tools = .{ .io = testing.io, .home = "/unused", .run_id = 1, .cfg = .{ .model = "m", .base_url = "", .api_key = "" } };
    defer t.progress.deinit(testing.allocator);
    defer t.agent_sessions.deinit(testing.allocator);
    const id = try t.progress.add(testing.allocator, t.io, .agent, "first", 1, false);
    try t.agent_sessions.add(testing.allocator, t.io, id, "child-session", true);
    const first = t.progress.currentInvocation(t.io, id);
    t.cancel.store(true, .release);
    try testing.expectError(error.Canceled, execute(&t, testing.allocator, "{\"prompt\":\"first\"}", &t.cancel, id, 1, false, null, null));
    try t.progress.restart(testing.allocator, t.io, .{ .id = id, .run = 1, .prompt = "second", .background = true, .state = .queued });
    _ = try t.agent_sessions.reserve(t.io, id);
    defer t.agent_sessions.release(t.io, id);
    const second = t.progress.currentInvocation(t.io, id);
    try testing.expect(second > first);
    try testing.expectError(error.Canceled, execute(&t, testing.allocator, "{\"prompt\":\"second\",\"resume\":\"a1\",\"background\":true}", &t.cancel, id, 1, true, null, null));
    try testing.expectEqual(@as(usize, 2), t.progress.slots.items.len);
    for (t.progress.slots.items, [_]usize{ first, second }, [_]bool{ false, true }) |slot, invocation, background| {
        try testing.expectEqualStrings("a1", slot.value.id);
        try testing.expectEqual(invocation, slot.value.invocation);
        try testing.expectEqual(background, slot.value.background);
        try testing.expectEqual(.canceled, slot.value.state);
    }
}

test "race tracker never persists resumable sessions and accounts partial usage" {
    const testing = std.testing;
    var t: Tools = .{ .io = testing.io, .home = "/unused" };
    defer t.progress.deinit(testing.allocator);
    defer t.agent_sessions.deinit(testing.allocator);
    const id = try t.progress.addAgent(testing.allocator, testing.io, "race", 1, false, true);
    var tr: Tracker = .{ .t = &t, .arena = .init(testing.allocator), .value = .{ .id = id, .prompt = "race", .race = true, .fork = true } };
    defer tr.arena.deinit();
    try tr.bindSession("race-child-session");
    try testing.expect(t.agent_sessions.session(testing.io, id) == null);
    try testing.expectError(error.AgentNotFound, t.agent_sessions.reserve(testing.io, id));
    try tr.observe("{\"usage\":{\"prompt_tokens\":123,\"completion_tokens\":7}}");
    try testing.expectEqual(@as(u64, 123), tr.output.usage.prompt_tokens);
    var p = (try t.progress.snapshot(testing.allocator, testing.io, id)).?;
    defer p.deinit(testing.allocator);
    try testing.expect(p.race);
    try testing.expectEqual(@as(u64, 7), p.usage.completion_tokens);
}
