const std = @import("std");
const sandbox = @import("../sandbox.zig");
const provider = @import("../provider.zig");
const Change = @import("../tools/diff.zig").Change;
const output_format = @import("output.zig");
const effort = @import("effort.zig");
const ToolSummary = @import("tool_summary.zig").Summary;
const Session = @import("../session.zig").Session;
const Sink = @import("../session.zig").Sink;
const Event = @import("../session.zig").Event;

pub const Ran = struct {
    outcome: sandbox.Outcome,
    /// Session-arena-owned.
    changes: []const Change,
};

pub fn run(s: *Session, code: []const u8, cancel: ?*const std.atomic.Value(bool)) !Ran {
    s.tools.background.cancel.store(false, .release);
    if (s.tools.background.inbox == null) s.tools.background.inbox = &s.inbox;
    if (s.tools.background.log == null) s.tools.background.log = &s.log;
    errdefer s.tools.background.stop(s.gpa);
    const ran = try runTimed(s, code, cancel, null);
    errdefer ran.outcome.deinit(s.gpa);
    try s.commit(s.history.items.len, &.{}, s.context_tokens, null);
    if (cancel != null and cancel.?.load(.acquire)) s.tools.background.stop(s.gpa);
    return ran;
}

fn runTimed(s: *Session, code: []const u8, cancel: ?*const std.atomic.Value(bool), timing: ?*sandbox.RunTiming) !Ran {
    s.tools.race_branches_started.store(0, .monotonic);
    defer {
        const branches = s.tools.race_branches_started.swap(0, .monotonic);
        if (timing) |t| t.race_branches += branches;
    }
    defer s.usage.add(s.tools.takeUsage());
    defer s.tools.progress.drain(s.io) catch {};
    if (!s.tools.background.anyPending(s.io)) s.tools.progress.clear(s.gpa);
    s.tools.run_id += 1;
    s.tools.discardChanges(s.gpa);
    var host = s.tools.host();
    host.timing = timing;
    if (timing) |t| t.started = .now(s.io, .awake);
    const recorder = if (timing != null) (if (s.recorder) |*r| r else null) else null;
    if (recorder) |r| {
        r.begin(s.log.steps + 1, timing.?.run_index);
        host.record = r;
    }
    var end: @import("../sandbox/record.zig").End = .@"error";
    defer if (recorder) |r| r.finish(end);
    const outcome = try sandbox.eval(s.gpa, s.io, code, .{}, host, cancel);
    end = if (cancel != null and cancel.?.load(.acquire)) .cancelled else if (outcome.ok) .ok else if (std.mem.eql(u8, outcome.text, "Error: run timed out")) .timeout else .@"error";
    errdefer outcome.deinit(s.gpa);
    return .{ .outcome = outcome, .changes = try s.tools.takeChanges(s.gpa, s.arena.allocator()) };
}

pub const PollTarget = struct {
    session: *Session,
    sink: Sink,

    pub fn usage(ctx: *anyopaque, value: provider.Usage) !void {
        const target: *PollTarget = @ptrCast(@alignCast(ctx));
        target.session.usage.add(value);
        try target.sink.emit(target.sink.ctx, .{ .usage = target.session.usage });
    }

    pub fn progress(ctx: *anyopaque, value: @import("events.zig").Progress) !void {
        const target: *PollTarget = @ptrCast(@alignCast(ctx));
        try target.sink.emit(target.sink.ctx, .{ .progress = value });
    }

    pub fn background(ctx: *anyopaque, value: @import("events.zig").Background) !void {
        const target: *PollTarget = @ptrCast(@alignCast(ctx));
        try target.sink.emit(target.sink.ctx, .{ .background = value });
    }
};

pub const Executed = struct { output: []const u8, ok: bool, run_ms: ?u64 = null, effort: ?effort.Declaration = null, remaining_steps: ?usize = null, tool_summary: ?ToolSummary = null };

/// Output is arena-owned.
pub fn execute(s: *Session, call: provider.ToolCall, sink: Sink, cancel: *const std.atomic.Value(bool), timing: *sandbox.RunTiming) !Executed {
    const a = s.arena.allocator();
    if (!std.mem.eql(u8, call.function.name, "run"))
        return .{ .ok = false, .output = try std.fmt.allocPrint(a, "error: unknown tool `{s}`; the only tool is `run`", .{call.function.name}) };

    const Args = struct { code: ?std.json.Value = null, effort: ?effort.Declaration = null };
    const args = std.json.parseFromSlice(Args, s.gpa, call.function.arguments, .{ .ignore_unknown_fields = true }) catch
        return .{ .ok = false, .output = try a.dupe(u8, "error: arguments must be a JSON object { \"code\": string }") };
    defer args.deinit();

    const code = if (args.value.code) |value| (if (value == .string) value.string else null) else null;
    if (code == null) return .{ .ok = false, .output = try a.dupe(u8, "error: arguments must be a JSON object { \"code\": string }"), .effort = args.value.effort };
    try sink.emit(sink.ctx, .{ .run_start = code.? });
    const before_omitted = timing.omitted;
    const ran = try runTimed(s, code.?, cancel, timing);
    const o = ran.outcome;
    defer o.deinit(s.gpa);

    const remaining_steps = if (s.cfg.limits.max_steps) |limit| limit -| s.steps else null;
    const output = try output_format.stepLimitOutput(a, try output_format.format(a, o), remaining_steps);
    const run_ms = timing.elapsed();
    const tool_summary = try ToolSummary.init(a, timing.entries[0..timing.count], timing.run_index, timing.omitted - before_omitted);
    try sink.emit(sink.ctx, .{ .run_end = .{ .ok = o.ok, .output = output, .changes = ran.changes, .tool_summary = tool_summary } });
    return .{ .output = output, .ok = o.ok, .run_ms = run_ms, .effort = args.value.effort, .remaining_steps = remaining_steps, .tool_summary = tool_summary };
}

test "execute emits per-Run actual tool summaries including empty and overflow" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
    defer client.deinit();
    const cfg: provider.Config = .{ .base_url = "invalid://local", .api_key = "mock", .model = "mock" };
    var session = try Session.init(t.allocator, t.io, &client, cfg, .{ .home = root, .user_home = root });
    defer session.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    const Observe = struct {
        summary: ?ToolSummary = null,
        ok: bool = true,
        starts: usize = 0,
        ends: usize = 0,

        fn emit(ctx: *anyopaque, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .run_start => self.starts += 1,
                .run_end => |value| {
                    try std.testing.expect(self.summary == null);
                    try std.testing.expect(value.tool_summary != null);
                    self.summary = try value.tool_summary.?.clone(std.testing.allocator);
                    self.ok = value.ok;
                    self.ends += 1;
                },
                else => {},
            }
        }
    };
    var observed: Observe = .{};
    var timing: sandbox.RunTiming = .init(t.io, .now(t.io, .awake));
    const failing = try std.fmt.allocPrint(a, "try {{ await tools.read({{path: \"{s}/missing\"}}); }} catch (_) {{}} throw new Error(\"failed Run\");", .{root});
    for ([_][]const u8{ failing, "console.log(\"tools.write is not a call\")", failing }, 0..) |code, run_index| {
        if (run_index == 2) {
            while (timing.count < timing.entries.len) _ = timing.reserve("bash");
            _ = timing.reserve("bash");
            _ = timing.reserve("bash");
        }
        timing.run_index = run_index;
        const arguments = try std.json.Stringify.valueAlloc(a, .{ .code = code }, .{});
        const result = try execute(&session, .{ .id = "run", .function = .{ .name = "run", .arguments = arguments } }, .{ .ctx = &observed, .emit = Observe.emit }, &cancel, &timing);
        const summary = observed.summary.?;
        defer {
            summary.deinit(t.allocator);
            observed.summary = null;
        }
        try t.expectEqual(run_index == 1, observed.ok);
        try t.expectEqual(observed.ok, result.ok);
        try t.expectEqual(@as(u64, if (run_index == 2) 1 else 0), summary.omitted);
        if (run_index == 0) {
            try t.expectEqual(@as(usize, 1), summary.counts.len);
            try t.expectEqualStrings("read", summary.counts[0].name);
            try t.expectEqual(@as(u64, 1), summary.counts[0].count);
        } else {
            try t.expectEqual(@as(usize, 0), summary.counts.len);
        }
    }
    try t.expectEqual(@as(usize, 3), observed.starts);
    try t.expectEqual(@as(usize, 3), observed.ends);
}

test "runTimed resets and transfers dispatched race branches on success and failure" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const root = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
    defer client.deinit();
    const cfg: provider.Config = .{ .base_url = "invalid://local", .api_key = "mock", .model = "mock" };
    var session = try Session.init(t.allocator, t.io, &client, cfg, .{ .home = root, .user_home = root });
    defer session.deinit();
    const Dispatch = struct {
        tools: *@import("../tools.zig").Tools,
        branches: u64 = 3,
        sent: bool = false,

        fn emit(ctx: *anyopaque, _: @import("events.zig").Progress) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.sent) return;
            try std.testing.expectEqual(@as(u64, 0), self.tools.race_branches_started.load(.monotonic));
            _ = self.tools.race_branches_started.fetchAdd(self.branches, .monotonic);
            self.sent = true;
        }
    };
    session.tools.background.inbox = &session.inbox;
    session.tools.background.log = &session.log;
    var dispatch: Dispatch = .{ .tools = &session.tools };
    session.tools.progress.sink = .{ .ctx = &dispatch, .emit = Dispatch.emit };
    var timing: sandbox.RunTiming = .init(t.io, .now(t.io, .awake));
    for ([_]bool{ false, true }) |fail| {
        dispatch.sent = false;
        session.tools.race_branches_started.store(99, .monotonic);
        const code = if (fail) "await tools.stop(await tools.bash({command: 'true', background: true})); throw new Error('failed Run');" else "await tools.stop(await tools.bash({command: 'true', background: true}));";
        const ran = try runTimed(&session, code, null, &timing);
        defer ran.outcome.deinit(t.allocator);
        try t.expectEqual(!fail, ran.outcome.ok);
        try t.expect(dispatch.sent);
        try t.expectEqual(@as(u64, if (fail) 6 else 3), timing.race_branches);
        try t.expectEqual(@as(u64, 0), session.tools.race_branches_started.load(.monotonic));
    }
    const empty = try runTimed(&session, "0", null, &timing);
    defer empty.outcome.deinit(t.allocator);
    try t.expectEqual(@as(u64, 6), timing.race_branches);
    dispatch.sent = false;
    const untimed = try runTimed(&session, "await tools.stop(await tools.bash({command: 'true', background: true}));", null, null);
    defer untimed.outcome.deinit(t.allocator);
    try t.expect(dispatch.sent);
    try t.expectEqual(@as(u64, 0), session.tools.race_branches_started.load(.monotonic));
}
