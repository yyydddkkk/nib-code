const std = @import("std");
const tools = @import("../tools.zig");
const Tools = tools.Tools;
const sandbox = @import("../sandbox.zig");
const provider = @import("../provider.zig");
const agent = @import("agent.zig");
const input = @import("agent/input.zig");
const process = @import("process.zig");
const log = @import("../session/log.zig");
const Progress = @import("../session/events.zig").Progress;
const Workspace = @import("race/workspace.zig").Workspace;

const Branch = struct { prompt: []const u8, model: ?[]const u8 = null, effort: ?[]const u8 = null };
const Args = struct { branches: []const Branch, verify: ?[]const u8 = null, timeout_ms: i64 = 1_800_000 };
const AgentResult = struct { ok: bool, text: []const u8 = "", @"error": ?[]const u8 = null, usage: provider.Usage = .{} };
const Failure = struct {
    id: []const u8,
    @"error": ?[]const u8,
    elapsed_ms: i64,
    usage: provider.Usage,
    verify_output: ?[]const u8,
};
const no_winner = std.math.maxInt(usize);

pub fn race(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    if (t.depth != 0 or t.forked) return tools.fail(gpa, "race is unavailable inside a sub-agent", .{});
    if (!t.race_enabled) return failure(gpa, "Race is disabled. The user must enable /race before tools.race can run.");
    const parsed = std.json.parseFromSlice(Args, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return tools.fail(gpa, "expected {{ branches: [{{prompt: string, model?: string, effort?: string}}], verify?: string, timeout_ms?: number }}", .{});
    defer parsed.deinit();
    const a = parsed.value;
    const cfg = t.cfg orelse return failure(gpa, "AgentConfigUnavailable");
    if (a.branches.len < 2 or a.branches.len > cfg.limits.race_branches)
        return tools.fail(gpa, "branches must contain 2..{d} entries", .{cfg.limits.race_branches});
    if (a.timeout_ms <= 0) return tools.fail(gpa, "timeout_ms must be positive", .{});
    for (a.branches) |branch| {
        var branch_cfg = cfg;
        if (branch.effort) |effort| branch_cfg.setEffort(effort) catch
            return tools.fail(gpa, "invalid branch effort: {s}", .{effort});
    }
    if (t.cancel.load(.acquire)) return error.Canceled;
    if (t.fork_snapshot == null) return failure(gpa, "race requires a current conversation history");
    var deadline: Deadline = .{ .t = t, .started = .now(t.io, .awake), .timeout_ms = a.timeout_ms };
    const watcher = std.Thread.spawn(.{}, Deadline.watch, .{&deadline}) catch |err| return failure(gpa, @errorName(err));
    defer {
        deadline.done.store(true, .release);
        watcher.join();
    }
    return execute(t, gpa, a, &deadline) catch |err| {
        if (t.cancel.load(.acquire)) return error.Canceled;
        return failure(gpa, if (deadline.expired.load(.acquire)) "TimedOut" else @errorName(err));
    };
}

fn failure(gpa: std.mem.Allocator, message: []const u8) !sandbox.ToolResult {
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = false, .winner = @as(?[]const u8, null), .text = "", .changes = @as([]const @import("diff.zig").Change, &.{}), .stopped = @as([]const []const u8, &.{}), .failures = @as([]const log.RaceBranch, &.{}), .@"error" = message }, .{}) };
}

const Deadline = struct {
    t: *Tools,
    started: std.Io.Timestamp,
    timeout_ms: i64,
    cancel: std.atomic.Value(bool) = .init(false),
    expired: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    fn watch(d: *Deadline) void {
        while (!d.done.load(.acquire)) {
            if (d.started.durationTo(.now(d.t.io, .awake)).toMilliseconds() >= d.timeout_ms) {
                d.expired.store(true, .release);
                d.cancel.store(true, .release);
                return;
            }
            if (d.t.cancel.load(.acquire)) {
                d.cancel.store(true, .release);
                return;
            }
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(10), .clock = .awake }, d.t.io) catch {};
        }
    }
};

const Shared = struct {
    t: *Tools,
    gpa: std.mem.Allocator,
    args: Args,
    started: std.Io.Timestamp,
    jobs: []Job,
    winner: std.atomic.Value(usize) = .init(no_winner),
    expired: std.atomic.Value(bool) = .init(false),

    fn elapsed(s: *Shared) i64 {
        return s.started.durationTo(std.Io.Clock.awake.now(s.t.io)).toMilliseconds();
    }

    fn remaining(s: *Shared) i64 {
        return @max(0, s.args.timeout_ms - s.elapsed());
    }

    fn stop(s: *Shared, except: usize) void {
        for (s.jobs, 0..) |*job, i| if (i != except) {
            job.cancel.store(true, .release);
        };
    }
};

const Job = struct {
    shared: *Shared,
    index: usize,
    summary: log.RaceBranch,
    root: []const u8,
    cwd: []const u8,
    args: []const u8,
    fork_input: []const u8,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    result: ?std.json.Parsed(AgentResult) = null,
    verify_output: ?[]u8 = null,
    selected_ms: ?i64 = null,

    fn join(job: *Job) void {
        if (job.thread) |thread| {
            thread.join();
            job.thread = null;
        }
    }

    fn deinit(job: *Job) void {
        job.join();
        if (job.result) |result| result.deinit();
        if (job.verify_output) |bytes| job.shared.gpa.free(bytes);
    }

    fn publish(job: *Job) void {
        const s = job.shared;
        var p = (s.t.progress.snapshot(s.gpa, s.t.io, job.summary.id) catch return) orelse return;
        defer p.deinit(s.gpa);
        p.race = true;
        p.fork = true;
        p.state = job.summary.state;
        p.elapsed_ms = @intCast(@max(0, job.summary.elapsed_ms));
        job.summary.usage = p.usage;
        s.t.progress.update(s.gpa, s.t.io, p) catch {};
    }

    fn work(job: *Job) void {
        const started = std.Io.Clock.awake.now(job.shared.t.io);
        job.finish() catch |err| {
            job.summary.@"error" = @errorName(err);
            job.summary.state = if (err == error.TimedOut) .timed_out else if (job.cancel.load(.acquire)) (if (job.shared.expired.load(.acquire)) .timed_out else .stopped) else .failed;
        };
        job.summary.elapsed_ms = started.durationTo(.now(job.shared.t.io, .awake)).toMilliseconds();
        job.publish();
        job.done.store(true, .release);
    }

    fn finish(job: *Job) !void {
        const s = job.shared;
        const t = s.t;
        const result = try agent.execute(t, s.gpa, job.args, &job.cancel, job.summary.id, t.run_id, false, job.fork_input, job.cwd);
        defer switch (result) {
            inline else => |bytes| s.gpa.free(bytes),
        };
        if (result == .err) return error.AgentFailed;
        job.result = try std.json.parseFromSlice(AgentResult, s.gpa, result.ok, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        const out = job.result.?.value;
        job.summary.usage = out.usage;
        if (!out.ok) {
            job.summary.state = if (s.remaining() == 0) .timed_out else .failed;
            if (job.summary.state == .timed_out) s.expired.store(true, .release);
            job.summary.@"error" = out.@"error" orelse "AgentFailed";
            return;
        }
        if (job.cancel.load(.acquire)) return error.Canceled;
        if (s.remaining() == 0) return error.TimedOut;
        job.summary.state = .working;
        job.publish();
        if (s.args.verify) |command| {
            const shell = try std.fmt.allocPrint(s.gpa, "exec 2>&1\n{s}", .{command});
            defer s.gpa.free(shell);
            const verified = try process.run(s.gpa, t.io, .{
                .spawn = .{ .argv = &.{ "bash", "-c", shell }, .cwd = .{ .path = job.cwd }, .environ_map = t.environ, .stdout = .pipe, .stderr = .ignore },
                .cancel = &job.cancel,
                .timeout_ms = s.remaining(),
                .termination_grace_ms = 500,
            });
            job.verify_output = verified.output;
            if (verified.stop) |err| return err;
            if (!verified.term.success()) return error.VerificationFailed;
        }
        if (job.cancel.load(.acquire)) return error.Canceled;
        if (s.remaining() == 0) return error.TimedOut;
        if (s.winner.cmpxchgStrong(no_winner, job.index, .acq_rel, .acquire) == null) {
            job.selected_ms = s.elapsed();
            job.summary.state = .won;
            s.stop(job.index);
        } else {
            job.summary.state = .stopped;
        }
    }
};

fn execute(t: *Tools, gpa: std.mem.Allocator, args: Args, deadline: *Deadline) !sandbox.ToolResult {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const started = deadline.started;
    var detail: ?[]const u8 = null;
    defer if (detail) |message| gpa.free(message);
    var workspace = Workspace.createWithOptions(gpa, t.io, &deadline.cancel, .{ .data_home = t.data_home, .detail = &detail }) catch |err| {
        if (t.cancel.load(.acquire)) return error.Canceled;
        return failure(gpa, if (deadline.expired.load(.acquire)) "TimedOut" else detail orelse @errorName(err));
    };
    defer workspace.deinit();
    if (args.verify) |verify| if (std.mem.indexOf(u8, verify, workspace.root) != null)
        return failure(gpa, "race verify cannot contain the parent repository absolute root; use relative paths in the branch worktree");
    const jobs = try a.alloc(Job, args.branches.len);
    var shared: Shared = .{ .t = t, .gpa = gpa, .args = args, .started = started, .jobs = jobs[0..0] };
    var initialized: usize = 0;
    defer {
        shared.stop(no_winner);
        for (jobs[0..initialized]) |*job| {
            job.join();
            if (!job.done.load(.acquire)) {
                job.summary.state = if (t.cancel.load(.acquire)) .stopped else if (deadline.expired.load(.acquire)) .timed_out else .failed;
                job.summary.@"error" = if (deadline.expired.load(.acquire)) "TimedOut" else "RaceSetupFailed";
                job.publish();
            }
            job.deinit();
        }
    }
    const summaries = try a.alloc(log.RaceBranch, jobs.len);
    const cwd_suffix = try std.fs.path.relative(a, workspace.root, null, workspace.root, workspace.cwd);
    for (args.branches, 0..) |branch, i| {
        const root = try workspace.branch(i);
        const cwd = try std.fs.path.resolve(a, &.{ root, cwd_suffix });
        try std.Io.Dir.cwd().createDirPath(t.io, cwd);
        const id = try t.progress.addAgent(gpa, t.io, branch.prompt, t.run_id, false, true);
        var cfg = t.cfg.?;
        var fork = t.fork_snapshot.?;
        cfg.thinking = fork.thinking;
        cfg.reasoning_effort = fork.reasoning_effort;
        if (branch.model) |model| cfg.model = model;
        if (branch.effort) |effort| try cfg.setEffort(effort);
        fork.id = id;
        fork.race = .{ .parent_root = workspace.root, .worktree_root = root };
        jobs[i] = .{
            .shared = &shared,
            .index = i,
            .summary = .{ .id = id },
            .root = root,
            .cwd = cwd,
            .args = try std.json.Stringify.valueAlloc(a, .{ .prompt = branch.prompt, .timeout_ms = @max(1, shared.remaining()), .model = branch.model, .effort = branch.effort }, .{}),
            .fork_input = try std.json.Stringify.valueAlloc(a, input.Input{ .prompt = branch.prompt, .config = cfg, .fork = fork }, .{}),
        };
        initialized += 1;
        shared.jobs = jobs[0..initialized];
        jobs[i].publish();
        summaries[i] = jobs[i].summary;
    }
    var event: log.Race = .{ .state = .started, .branches = summaries };
    if (t.background.log) |session_log| try session_log.race(t.io, gpa, event, t.background.turn_step);
    defer {
        shared.stop(no_winner);
        for (jobs) |*job| job.join();
        event.state = .finished;
        event.elapsed_ms = shared.elapsed();
        event.usage = .{};
        for (jobs, summaries) |job, *summary| {
            summary.* = job.summary;
            event.usage.add(summary.usage);
        }
        if (t.cancel.load(.acquire)) event.@"error" = "Canceled";
        if (t.background.log) |session_log| session_log.race(t.io, gpa, event, t.background.turn_step) catch {};
    }
    for (jobs) |*job| {
        job.thread = std.Thread.spawn(.{}, Job.work, .{job}) catch |err| {
            job.summary.state = .failed;
            job.summary.@"error" = @errorName(err);
            job.publish();
            job.done.store(true, .release);
            continue;
        };
        _ = t.race_branches_started.fetchAdd(1, .monotonic);
    }
    while (true) {
        var done = true;
        for (jobs) |*job| done = job.done.load(.acquire) and done;
        if (done) break;
        if (t.cancel.load(.acquire)) shared.stop(no_winner);
        if (shared.remaining() == 0) {
            shared.expired.store(true, .release);
            shared.stop(no_winner);
        }
        std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(10), .clock = .awake }, t.io) catch {};
    }
    for (jobs) |*job| job.join();
    if (t.cancel.load(.acquire)) return error.Canceled;
    var usage: provider.Usage = .{};
    var stopped: std.ArrayList([]const u8) = .empty;
    var failures: std.ArrayList(Failure) = .empty;
    for (jobs) |job| {
        usage.add(job.summary.usage);
        if (job.summary.state == .stopped) try stopped.append(a, job.summary.id);
        if (job.summary.state == .failed or job.summary.state == .timed_out) try failures.append(a, .{ .id = job.summary.id, .@"error" = job.summary.@"error", .elapsed_ms = job.summary.elapsed_ms, .usage = job.summary.usage, .verify_output = job.verify_output });
    }
    const winner = shared.winner.load(.acquire);
    if (winner == no_winner) {
        event.applied = false;
        event.@"error" = if (shared.expired.load(.acquire)) "TimedOut" else "AllBranchesFailed";
        return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = false, .winner = @as(?[]const u8, null), .text = "", .changes = @as([]const @import("diff.zig").Change, &.{}), .stopped = stopped.items, .failures = failures.items, .usage = usage, .@"error" = event.@"error" }, .{}) };
    }
    const job = &jobs[winner];
    event.winner = job.summary.id;
    event.win_ms = job.selected_ms;
    const root = job.result.?.value;
    var applied = workspace.apply(job.root) catch |err| {
        event.applied = false;
        event.@"error" = if (deadline.expired.load(.acquire)) "TimedOut" else @errorName(err);
        return err;
    };
    defer applied.deinit(gpa);
    event.applied = applied.ok;
    event.patch = if (applied.patch) |patch| try a.dupe(u8, patch) else null;
    event.@"error" = if (applied.@"error") |message| try a.dupe(u8, message) else null;
    try applied.recordChanges(t, gpa);
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = applied.ok, .winner = job.summary.id, .text = root.text, .changes = applied.changes, .stopped = stopped.items, .failures = failures.items, .usage = usage, .patch = applied.patch, .@"error" = applied.@"error" }, .{}) };
}

test "race authorization is a data fact and arguments reject before allocating branches" {
    const testing = std.testing;
    var t: Tools = .{ .io = testing.io, .home = "/unused", .cfg = .{ .model = "mock", .base_url = "", .api_key = "" } };
    defer t.progress.deinit(testing.allocator);
    defer t.agent_sessions.deinit(testing.allocator);
    const disabled = try race(&t, testing.allocator, "{}");
    defer tools.freeResult(disabled);
    try testing.expect(disabled == .ok);
    const value = try std.json.parseFromSlice(std.json.Value, testing.allocator, disabled.ok, .{});
    defer value.deinit();
    try testing.expect(!value.value.object.get("ok").?.bool);
    try testing.expect(std.mem.indexOf(u8, value.value.object.get("error").?.string, "/race") != null);
    try testing.expect(value.value.object.get("changes").? == .array);
    t.race_enabled = true;
    for ([_][]const u8{ "{}", "{\"branches\":[]}", "{\"branches\":[{\"prompt\":1},{\"prompt\":\"b\"}]}", "{\"branches\":[{\"prompt\":\"a\"},{\"prompt\":\"b\"}],\"timeout_ms\":0}", "{\"branches\":[{\"prompt\":\"a\",\"effort\":\"invalid\"},{\"prompt\":\"b\"}]}" }) |args| {
        const result = try race(&t, testing.allocator, args);
        defer tools.freeResult(result);
        try testing.expect(result == .err);
    }
    try testing.expectEqual(@as(usize, 0), t.progress.slots.items.len);
    t.cancel.store(true, .release);
    try testing.expectError(error.Canceled, race(&t, testing.allocator, "{\"branches\":[{\"prompt\":\"a\"},{\"prompt\":\"b\"}]}"));
}

test "race deadline cancels setup on timeout and forwards parent cancellation" {
    const testing = std.testing;
    var t: Tools = .{ .io = testing.io, .home = "/unused" };
    var deadline: Deadline = .{ .t = &t, .started = .now(testing.io, .awake), .timeout_ms = 20 };
    const watcher = try std.Thread.spawn(.{}, Deadline.watch, .{&deadline});
    watcher.join();
    try testing.expect(deadline.cancel.load(.acquire));
    try testing.expect(deadline.expired.load(.acquire));
    t.cancel.store(true, .release);
    deadline = .{ .t = &t, .started = .now(testing.io, .awake), .timeout_ms = 10000 };
    Deadline.watch(&deadline);
    try testing.expect(deadline.cancel.load(.acquire));
    try testing.expect(!deadline.expired.load(.acquire));
}
