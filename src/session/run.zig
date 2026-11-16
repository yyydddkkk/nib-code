const std = @import("std");
const sandbox = @import("../sandbox.zig");
const provider = @import("../provider.zig");
const Change = @import("../tools/diff.zig").Change;
const Image = @import("../image.zig").Image;
const output_format = @import("output.zig");
const ToolSummary = @import("tool_summary.zig").Summary;
const Session = @import("../session.zig").Session;
const Sink = @import("../session.zig").Sink;
const Event = @import("../session.zig").Event;

pub const Ran = struct {
    outcome: sandbox.Outcome,
    /// Session-arena-owned.
    changes: []const Change,
    images: []const Image = &.{},
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
    defer s.usage.add(s.tools.takeUsage());
    defer s.tools.progress.drain(s.io) catch {};
    if (!s.tools.background.anyPending(s.io)) s.tools.progress.clear(s.gpa);
    s.tools.run_id += 1;
    s.tools.discardChanges(s.gpa);
    @import("../tools.zig").clearImages(&s.tools.images, s.gpa);
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
    var outcome = try sandbox.eval(s.gpa, s.io, code, .{}, host, cancel);
    errdefer outcome.deinit(s.gpa);
    try @import("hooks.zig").afterEdit(&s.tools, s.gpa, &s.tools.changes, &outcome);
    end = if (cancel != null and cancel.?.load(.acquire)) .cancelled else if (outcome.ok) .ok else if (std.mem.eql(u8, outcome.text, "Error: run timed out")) .timeout else .@"error";
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

    pub fn notice(ctx: *anyopaque, value: []const u8) !void {
        const target: *PollTarget = @ptrCast(@alignCast(ctx));
        try target.sink.emit(target.sink.ctx, .{ .notice = value });
    }

    pub fn background(ctx: *anyopaque, value: @import("events.zig").Background) !void {
        const target: *PollTarget = @ptrCast(@alignCast(ctx));
        try target.sink.emit(target.sink.ctx, .{ .background = value });
    }
};

pub const Executed = struct { images: []const Image = &.{}, output: []const u8, ok: bool, empty: bool = false, run_ms: ?u64 = null, remaining_steps: ?usize = null, tool_summary: ?ToolSummary = null, background_id: ?[]const u8 = null };

/// Output is arena-owned.
pub fn execute(s: *Session, call: provider.ToolCall, sink: Sink, cancel: *const std.atomic.Value(bool), timing: *sandbox.RunTiming) !Executed {
    const a = s.arena.allocator();
    if (!std.mem.eql(u8, call.function.name, "run"))
        return .{ .ok = false, .output = try std.fmt.allocPrint(a, "error: unknown tool `{s}`; the only tool is `run`", .{call.function.name}) };

    const Args = struct { code: ?std.json.Value = null };
    const args = std.json.parseFromSlice(Args, s.gpa, call.function.arguments, .{ .ignore_unknown_fields = true }) catch
        return .{ .ok = false, .output = try a.dupe(u8, "error: arguments must be a JSON object { \"code\": string }") };
    defer args.deinit();

    const code = if (args.value.code) |value| (if (value == .string) value.string else null) else null;
    if (code == null) return .{ .ok = false, .output = try a.dupe(u8, "error: arguments must be a JSON object { \"code\": string }") };
    try sink.emit(sink.ctx, .{ .run_start = code.? });
    const before_omitted = timing.omitted;
    const started: std.Io.Clock.Timestamp = .now(s.io, .awake);
    const ran = try executeTimed(s, code.?, cancel, timing, sink);
    if (ran == null) {
        const remaining = if (s.cfg.limits.max_steps) |limit| limit -| s.steps else null;
        const message = if (s.tools.waitEnabled())
            try std.fmt.allocPrint(a, "Run still executing after {d} ms; continuing in background as {s}. Its captured output is preserved and will arrive appended to the output of your next Run when it finishes. Continue useful work meanwhile; no ps, cat/tail logs, sleep, empty Runs or timeout reruns to check/wait. Do not read its redirected logs before completion. If no independent work remains, call await tools.wait() (optionally after other work in the same Run); it returns the results when the tasks finish. After edit/write changes, rerun the same command/cwd directly: older Run bash stops with {{superseded_by}}, not failure. Do not wait for the stale result.", .{ s.cfg.limits.run_background_after_ms, s.tools.background.runs.items[s.tools.background.runs.items.len - 1].id })
        else
            try std.fmt.allocPrint(a, "Run still executing after {d} ms; continuing in background as {s}. Its captured output is preserved and will arrive automatically as a message when it finishes. Continue useful work meanwhile; no ps, cat/tail logs, sleep, empty Runs or timeout reruns to check/wait. Do not read its redirected logs before completion. If no independent work remains, end the model response immediately with a brief text reply and no run/tool call (not even console.log); Session waits locally, delivers the result and continues the Turn. After edit/write changes, rerun the same command/cwd directly: older Run bash stops with {{superseded_by}}, not failure. Do not wait for the stale result.", .{ s.cfg.limits.run_background_after_ms, s.tools.background.runs.items[s.tools.background.runs.items.len - 1].id });
        const text = try output_format.stepLimitOutput(a, message, remaining);
        try sink.emit(sink.ctx, .{ .run_end = .{ .background_id = s.tools.background.runs.items[s.tools.background.runs.items.len - 1].id, .ok = true, .output = text, .tool_summary = .{} } });
        return .{ .output = text, .ok = true, .run_ms = @intCast(@max(started.untilNow(s.io).raw.toMilliseconds(), 0)), .remaining_steps = remaining, .tool_summary = .{}, .background_id = s.tools.background.runs.items[s.tools.background.runs.items.len - 1].id };
    }
    const o = ran.?.outcome;
    defer o.deinit(s.gpa);

    if (o.hook_notice.len > 0) try sink.emit(sink.ctx, .{ .notice = o.hook_notice });
    const remaining_steps = if (s.cfg.limits.max_steps) |limit| limit -| s.steps else null;
    const output = try output_format.stepLimitOutput(a, try output_format.format(a, o, s.cfg.limits.run_output_bytes), remaining_steps);
    const run_ms = timing.elapsed();
    const tool_summary = try ToolSummary.init(a, timing.entries[0..timing.count], timing.run_index, timing.omitted - before_omitted);
    try tool_summary.annotateViews(a, ran.?.images);
    try sink.emit(sink.ctx, .{ .run_end = .{ .ok = o.ok, .output = output, .changes = ran.?.changes, .tool_summary = tool_summary } });
    return .{ .output = output, .ok = o.ok, .empty = std.mem.eql(u8, o.text, "undefined") and std.mem.trim(u8, o.logs, " \t\r\n").len == 0, .run_ms = run_ms, .remaining_steps = remaining_steps, .tool_summary = tool_summary, .images = ran.?.images };
}

fn executeTimed(s: *Session, code: []const u8, cancel: *const std.atomic.Value(bool), timing: *sandbox.RunTiming, sink: Sink) !?Ran {
    defer s.tools.progress.drain(s.io) catch {};
    if (!s.tools.background.anyPending(s.io)) s.tools.progress.clear(s.gpa);
    s.tools.run_id += 1;
    const job = try @import("run_job.zig").Job.create(&s.tools, s.gpa, code, s.log.steps + 1, timing.run_index, if (s.recorder) |*r| r else null);
    var adopted = false;
    defer if (!adopted) job.destroy();
    var attempted = false;
    var last_tool: []const u8 = "";
    while (!job.done.load(.acquire)) {
        if (cancel.load(.acquire)) return error.Canceled;
        const tool = job.scope.activeTool();
        if (!std.mem.eql(u8, tool, last_tool)) {
            if (sink.onToolActivity) |notify| try notify(sink.ctx, tool);
            last_tool = tool;
        }
        try @import("../tools.zig").Tools.poll(&s.tools);
        if (!attempted and job.timing.elapsed() >= s.cfg.limits.run_background_after_ms and job.waiting.load(.acquire) and !job.scope.blockedInWait()) {
            attempted = true;
            if (try s.tools.background.adoptRun(job)) {
                adopted = true;
                return null;
            }
        }
        job.completed.waitTimeout(s.io, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            else => return err,
        };
    }
    job.join();
    if (job.failure) |err| return err;
    const count = @min(job.timing.count, timing.entries.len - timing.count);
    @memcpy(timing.entries[timing.count..][0..count], job.timing.entries[0..count]);
    for (timing.entries[timing.count..][0..count]) |*entry| {
        if (entry.path) |path| entry.path = try s.arena.allocator().dupe(u8, path);
    }
    timing.count += count;
    timing.omitted += job.timing.omitted + job.timing.count - count;
    timing.tool_bytes += job.timing.tool_bytes;
    timing.llm_calls += job.timing.llm_calls;
    timing.agent_calls += job.timing.agent_calls;
    timing.started = job.timing.started;
    s.usage.add(s.tools.takeUsage());
    const cwd = try std.process.currentPathAlloc(s.io, s.gpa);
    defer s.gpa.free(cwd);
    const changes = try job.scope.changes.take(s.gpa, s.arena.allocator(), cwd);
    const outcome = job.outcome.?;
    job.outcome = null;
    return .{ .outcome = outcome, .changes = changes, .images = try @import("../tools.zig").takeImages(&job.scope.images, s.gpa, s.arena.allocator()) };
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
