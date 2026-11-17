const std = @import("std");
const sandbox = @import("../sandbox.zig");
const Tools = @import("../tools.zig").Tools;
const RunScope = @import("../tools.zig").RunScope;
const output = @import("output.zig");
const Completion = @import("events.zig").RunCompletion;

pub const Job = struct {
    gpa: std.mem.Allocator,
    t: *Tools,
    input_arena: std.heap.ArenaAllocator,
    join_mutex: std.Io.Mutex = .init,
    elapsed_ms: u64 = 0,
    state: enum { done, failed, canceled, timed_out } = .failed,
    execution: @import("../sandbox/timing.zig").Execution = .{},
    scope: RunScope,
    cancel: std.atomic.Value(bool) = .init(false),
    code: []const u8,
    step: usize,
    timing: sandbox.RunTiming,
    recorder: ?sandbox.Recorder = null,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    completed: std.Io.Event = .unset,
    waiting: std.atomic.Value(bool) = .init(false),
    outcome: ?sandbox.Outcome = null,
    failure: ?anyerror = null,
    id: []const u8 = "",
    announced: bool = false,
    collected: bool = false,
    delivered: bool = false,

    pub fn create(t: *Tools, gpa: std.mem.Allocator, code: []const u8, step: usize, index: usize, recorder: ?*sandbox.Recorder) !*Job {
        const job = try gpa.create(Job);
        job.* = .{ .gpa = gpa, .t = t, .input_arena = .init(gpa), .scope = .{ .tools = t, .id = t.run_id }, .code = "", .step = step, .timing = .init(t.io, .now(t.io, .awake)) };
        errdefer job.destroy();
        job.timing.run_index = index;
        job.execution.start_ms_epoch = @import("../sandbox/timing.zig").Execution.now(t.io);
        const a = job.input_arena.allocator();
        job.code = try a.dupe(u8, code);
        if (t.fork_snapshot) |fork| {
            var copy = fork;
            copy.history = try @import("history.zig").snapshot(a, fork.history, &.{});
            const versions = try a.dupe(@import("../tools/file_state.zig").Observation, fork.file_versions);
            for (versions) |*version| version.path = try a.dupe(u8, version.path);
            copy.file_versions = versions;
            job.scope.fork = copy;
        }
        if (recorder) |r| {
            job.recorder = try r.fork(step, index);
            job.recorder.?.run_output_bytes = if (t.cfg) |cfg| cfg.limits.run_output_bytes else output.max_bytes;
        }
        job.thread = try std.Thread.spawn(.{}, work, .{job});
        return job;
    }

    fn work(job: *Job) void {
        defer {
            job.done.store(true, .release);
            job.completed.set(job.t.io);
        }
        defer {
            job.state = if (job.cancel.load(.acquire)) .canceled else if (job.outcome) |outcome| (if (outcome.ok) .done else if (std.mem.eql(u8, outcome.text, "Error: run timed out")) .timed_out else .failed) else .failed;
            job.elapsed_ms = job.timing.elapsed();
            job.execution.end_ms_epoch = @import("../sandbox/timing.zig").Execution.now(job.t.io);
        }
        var host = job.scope.host();
        job.timing.detail_allocator = job.input_arena.allocator();
        host.timing = &job.timing;
        host.waiting = &job.waiting;
        if (job.recorder) |*r| host.record = r;
        job.outcome = sandbox.eval(job.gpa, job.t.io, job.code, .{}, host, &job.cancel) catch |err| result: {
            job.failure = err;
            break :result null;
        };
        if (job.outcome) |*o| @import("hooks.zig").afterEdit(job.t, job.gpa, &job.scope.changes, o) catch |err| {
            job.failure = err;
        };
        if (job.recorder) |*r| r.finish(if (job.cancel.load(.acquire)) .cancelled else if (job.outcome) |o| (if (o.ok) .ok else if (std.mem.eql(u8, o.text, "Error: run timed out")) .timeout else .@"error") else .@"error");
    }

    pub fn join(job: *Job) void {
        job.join_mutex.lockUncancelable(job.t.io);
        defer job.join_mutex.unlock(job.t.io);
        if (job.thread) |thread| thread.join();
        job.thread = null;
    }

    pub fn destroy(job: *Job) void {
        job.cancel.store(true, .release);
        job.join();
        job.releaseExecution();
        job.input_arena.deinit();
        job.gpa.destroy(job);
    }

    pub fn releaseExecution(job: *Job) void {
        if (job.outcome) |o| o.deinit(job.gpa);
        job.outcome = null;
        if (job.recorder) |*r| r.deinit();
        job.recorder = null;
        job.scope.changes.discard(job.gpa);
        @import("../tools.zig").clearImages(&job.scope.images, job.gpa);
        job.input_arena.deinit();
        job.input_arena = .init(job.gpa);
    }

    pub fn completion(job: *Job, a: std.mem.Allocator) !Completion {
        job.join();
        if (job.failure) |err| return err;
        const o = job.outcome.?;
        const cwd = try std.process.currentPathAlloc(job.t.io, job.gpa);
        defer job.gpa.free(cwd);
        const formatted = try output.format(a, o, if (job.t.cfg) |cfg| cfg.limits.run_output_bytes else output.max_bytes);
        const failed = job.state == .failed;
        var text = formatted;
        if (job.t.background.log) |log| {
            const reference = try std.fmt.allocPrint(a, "{d}:{d}", .{ job.step, job.timing.run_index });
            if (try log.findSource(job.t.io, a, reference, false)) |original| {
                var source = original;
                source.failed = failed;
                try log.source(job.t.io, a, source);
                if (failed) text = try std.fmt.allocPrint(a, "{s}\nSource: {s} (rerun executes from the beginning; prior effects may repeat)", .{ formatted, reference });
            }
        }
        return .{ .hook_notice = if (o.hook_notice.len > 0) try a.dupe(u8, o.hook_notice) else null, .execution = job.execution, .step = job.step, .run_index = job.timing.run_index, .ok = o.ok, .output = text, .run_ms = job.elapsed_ms, .tool_bytes = job.timing.tool_bytes, .calls = job.timing.entries[0..job.timing.count], .calls_omitted = job.timing.omitted, .changes = try job.scope.changes.take(job.gpa, a, cwd) };
    }
};
