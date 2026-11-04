const std = @import("std");
const Tools = @import("../tools.zig").Tools;
const agent = @import("agent.zig");
const Inbox = @import("../session/inbox.zig").Inbox;
const Log = @import("../session/log.zig").Log;
const BackgroundEvent = @import("../session/events.zig").Background;
const output = @import("../session/output.zig");

pub const Background = struct {
    mutex: std.Io.Mutex = .init,
    // Join/reap/destruction serialize here; workers only acquire mutex.
    lifecycle: std.Io.Mutex = .init,
    jobs: std.ArrayList(*Job) = .empty,
    cancel: std.atomic.Value(bool) = .init(false),
    inbox: ?*Inbox = null,
    log: ?*Log = null,
    turn_step: u32 = 0,
    bash_active: usize = 0,

    pub const bash_limit = @import("../sandbox.zig").tool_concurrency;

    const Job = struct {
        t: *Tools,
        gpa: std.mem.Allocator,
        args: []u8,
        prompt: []u8,
        id: []u8,
        kind: BackgroundEvent.Kind,
        detached: bool = false,
        fork_input: ?[]u8 = null,
        cancel: std.atomic.Value(bool) = .init(false),
        run: usize,
        invocation: usize = 0,
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = .init(false),
        announced: bool = false,
        delivered: bool = false,
        failure: ?anyerror = null,

        fn join(job: *Job) void {
            if (job.thread) |thread| {
                thread.join();
                job.thread = null;
            }
        }

        fn reap(job: *Job) void {
            if (!job.done.load(.acquire)) return;
            job.join();
            job.gpa.free(job.args);
            job.gpa.free(job.prompt);
            if (job.fork_input) |input| job.gpa.free(input);
            job.fork_input = null;
            job.args = &.{};
            job.prompt = &.{};
        }

        fn destroy(job: *Job) void {
            job.gpa.free(job.args);
            job.gpa.free(job.prompt);
            if (job.fork_input) |input| job.gpa.free(input);
            job.fork_input = null;
            job.gpa.free(job.id);
            job.gpa.destroy(job);
        }

        fn work(job: *Job) void {
            job.finish() catch |err| {
                if (job.kind == .agent) job.t.agent_sessions.release(job.t.io, job.id);
                job.failure = err;
            };
            if (job.kind == .bash) {
                const bg = &job.t.background;
                bg.mutex.lockUncancelable(job.t.io);
                bg.bash_active -= 1;
                bg.mutex.unlock(job.t.io);
            }
            job.done.store(true, .release);
        }

        fn finish(job: *Job) !void {
            const gpa = job.gpa;
            const t = job.t;
            const result = switch (job.kind) {
                .agent => agent.execute(t, gpa, job.args, &job.cancel, job.id, job.run, true, job.fork_input, null),
                .bash => @import("bash.zig").executeBackground(t, gpa, job.args, &job.cancel, .{ .id = job.id, .run = job.run, .background = true, .kind = .bash, .prompt = "" }),
            } catch |err| try @import("../tools.zig").fail(gpa, "{s}", .{@errorName(err)});
            defer switch (result) {
                inline else => |bytes| gpa.free(bytes),
            };
            try job.deliver(result);
        }

        fn deliver(job: *Job, result: @import("../sandbox.zig").ToolResult) !void {
            const t = job.t;
            const gpa = job.gpa;
            if (t.background.cancel.load(.acquire)) {
                if (job.kind == .agent) t.agent_sessions.release(t.io, job.id);
                return;
            }
            const json = try messageResult(gpa, job.kind, job.id, result);
            defer gpa.free(json);
            const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
            defer parsed.deinit();
            const ok = switch (job.kind) {
                .agent => parsed.value.object.get("ok").?.bool,
                .bash => if (parsed.value.object.get("exit_code")) |code| code == .integer and code.integer == 0 else false,
            };
            const prefix = try std.fmt.allocPrint(gpa, "[background {s} {s} finished]\n", .{ @tagName(job.kind), job.id });
            defer gpa.free(prefix);
            const formatted = try output.formatMessage(gpa, prefix, json);
            defer gpa.free(formatted);
            if (job.kind == .agent) {
                t.agent_sessions.mutex.lockUncancelable(t.io);
                defer t.agent_sessions.mutex.unlock(t.io);
                _ = try t.background.inbox.?.enqueueBackground(gpa, t.io, job.id, job.kind, .finished, ok, formatted, job.detached, job.invocation);
                t.agent_sessions.releaseLocked(job.id);
            } else _ = try t.background.inbox.?.enqueueBackground(gpa, t.io, job.id, job.kind, .finished, ok, formatted, job.detached, job.invocation);
        }
    };

    pub fn start(bg: *Background, t: *Tools, gpa: std.mem.Allocator, kind: BackgroundEvent.Kind, args: []const u8, prompt: []const u8) ![]u8 {
        return bg.startWithId(t, gpa, kind, args, prompt, null, null);
    }

    pub fn startAgent(bg: *Background, t: *Tools, gpa: std.mem.Allocator, args: []const u8, prompt: []const u8, id: []const u8, fork_input: ?[]const u8) ![]u8 {
        return bg.startWithId(t, gpa, .agent, args, prompt, id, fork_input);
    }

    fn startWithId(bg: *Background, t: *Tools, gpa: std.mem.Allocator, kind: BackgroundEvent.Kind, args: []const u8, prompt: []const u8, task_id: ?[]const u8, fork_input: ?[]const u8) ![]u8 {
        bg.lifecycle.lockUncancelable(t.io);
        defer bg.lifecycle.unlock(t.io);
        bg.mutex.lockUncancelable(t.io);
        defer bg.mutex.unlock(t.io);
        if (bg.cancel.load(.acquire)) return error.Canceled;
        if (bg.inbox == null) return error.BackgroundUnavailable;
        if (kind == .bash and bg.bash_active >= bash_limit) return error.BackgroundBashLimit;
        const log = bg.log orelse return error.BackgroundUnavailable;
        const detached = if (kind == .bash) blk: {
            const parsed = try std.json.parseFromSlice(struct { detached: bool = false }, gpa, args, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            break :blk parsed.value.detached;
        } else false;
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        const progress_id = task_id orelse try t.progress.add(gpa, t.io, kind, prompt, t.run_id, true);
        if (detached) try t.progress.update(gpa, t.io, .{ .id = progress_id, .run = t.run_id, .kind = kind, .background = true, .detached = true, .prompt = prompt, .state = .queued });
        const id = try gpa.dupe(u8, progress_id);
        errdefer gpa.free(id);
        const copy = try gpa.dupe(u8, args);
        errdefer gpa.free(copy);
        const prompt_copy = try gpa.dupe(u8, prompt);
        errdefer gpa.free(prompt_copy);
        const result = try std.json.Stringify.valueAlloc(gpa, .{ .id = id }, .{});
        errdefer gpa.free(result);
        const fork_copy = if (fork_input) |input| try gpa.dupe(u8, input) else null;
        errdefer if (fork_copy) |input| gpa.free(input);
        try bg.jobs.ensureUnusedCapacity(gpa, 1);
        job.* = .{ .t = t, .gpa = gpa, .args = copy, .prompt = prompt_copy, .id = id, .kind = kind, .detached = detached, .fork_input = fork_copy, .run = t.run_id, .invocation = t.progress.currentInvocation(t.io, id) };
        try log.background(t.io, gpa, .{ .id = id, .kind = kind, .state = .started }, bg.turn_step);
        @import("../sandbox.zig").tool_identity = .{ .id = progress_id, .background = true };
        bg.jobs.appendAssumeCapacity(job);
        errdefer _ = bg.jobs.pop();
        if (kind == .bash) bg.bash_active += 1;
        job.thread = std.Thread.spawn(.{}, Job.work, .{job}) catch |err| {
            if (kind == .bash) bg.bash_active -= 1;
            try t.progress.update(gpa, t.io, .{ .id = id, .run = job.run, .invocation = job.invocation, .kind = kind, .background = true, .detached = detached, .fork = if (kind == .agent) t.agent_sessions.isFork(t.io, id) else false, .prompt = prompt, .state = .failed });
            try job.deliver(.{ .err = @constCast(@errorName(err)) });
            if (kind == .agent) t.agent_sessions.release(t.io, id);
            job.done.store(true, .release);
            return result;
        };
        return result;
    }

    pub fn setTurnStep(bg: *Background, io: std.Io, step: u32) void {
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        bg.turn_step = step;
    }

    pub fn pending(bg: *Background, io: std.Io) bool {
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        for (bg.jobs.items) |job| if (!job.detached and !job.delivered) return true;
        return false;
    }

    pub fn anyPending(bg: *Background, io: std.Io) bool {
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        for (bg.jobs.items) |job| if (!job.delivered) return true;
        return false;
    }

    pub fn pendingNames(bg: *Background, gpa: std.mem.Allocator, io: std.Io) ![]u8 {
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        var names: std.ArrayList(u8) = .empty;
        errdefer names.deinit(gpa);
        for (bg.jobs.items) |job| {
            if (job.detached or job.delivered) continue;
            if (names.items.len > 0) try names.appendSlice(gpa, ", ");
            try names.print(gpa, "{s} {s}", .{ @tagName(job.kind), job.id });
        }
        return names.toOwnedSlice(gpa);
    }

    pub fn delivered(bg: *Background, io: std.Io, id: []const u8, invocation: usize) void {
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        for (bg.jobs.items) |job| if (!job.delivered and job.invocation == invocation and std.mem.eql(u8, job.id, id)) {
            job.delivered = true;
            return;
        };
    }

    pub fn poll(bg: *Background, io: std.Io, ctx: *anyopaque, emit: *const fn (*anyopaque, BackgroundEvent) anyerror!void) !void {
        bg.lifecycle.lockUncancelable(io);
        defer bg.lifecycle.unlock(io);
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        for (bg.jobs.items) |job| {
            if (!job.announced) {
                try emit(ctx, .{ .id = job.id, .kind = job.kind, .state = .started });
                job.announced = true;
            }
            job.reap();
            if (job.done.load(.acquire)) if (job.failure) |err| {
                job.failure = null;
                // No inbox result will arrive after an internal worker failure.
                job.delivered = true;
                return err;
            };
        }
    }

    pub fn stopById(bg: *Background, io: std.Io, id: []const u8) !bool {
        bg.lifecycle.lockUncancelable(io);
        defer bg.lifecycle.unlock(io);
        bg.mutex.lockUncancelable(io);
        var index = bg.jobs.items.len;
        const job = while (index > 0) {
            index -= 1;
            const candidate = bg.jobs.items[index];
            if (std.mem.eql(u8, candidate.id, id)) break candidate;
        } else {
            bg.mutex.unlock(io);
            return error.UnknownBackgroundTask;
        };
        const stopped = !job.done.load(.acquire);
        job.cancel.store(true, .release);
        bg.mutex.unlock(io);
        job.join();
        job.reap();
        return stopped;
    }

    pub fn finishTurn(bg: *Background, gpa: std.mem.Allocator, io: std.Io, aborted: bool) void {
        if (aborted) {
            bg.stop(gpa);
            return;
        }
        bg.lifecycle.lockUncancelable(io);
        defer bg.lifecycle.unlock(io);
        bg.mutex.lockUncancelable(io);
        for (bg.jobs.items) |job| if (!job.detached) {
            job.cancel.store(true, .release);
        };
        bg.mutex.unlock(io);
        for (bg.jobs.items) |job| {
            if (!job.detached) job.join();
            job.reap();
        }
    }

    pub fn stop(bg: *Background, gpa: std.mem.Allocator) void {
        // Background is owned by Tools; teardown shares the same lifecycle lock as stopById.
        const t: *Tools = @fieldParentPtr("background", bg);
        const io = t.io;
        bg.lifecycle.lockUncancelable(io);
        defer bg.lifecycle.unlock(io);
        bg.mutex.lockUncancelable(io);
        bg.cancel.store(true, .release);
        for (bg.jobs.items) |job| job.cancel.store(true, .release);
        bg.mutex.unlock(io);
        for (bg.jobs.items) |job| job.join();
        bg.mutex.lockUncancelable(io);
        defer bg.mutex.unlock(io);
        for (bg.jobs.items) |job| job.destroy();
        bg.jobs.clearAndFree(gpa);
        bg.inbox = null;
        bg.log = null;
    }
};

fn messageResult(gpa: std.mem.Allocator, kind: BackgroundEvent.Kind, id: []const u8, result: @import("../sandbox.zig").ToolResult) ![]u8 {
    if (result == .err) return if (kind == .agent)
        std.json.Stringify.valueAlloc(gpa, .{ .ok = false, .id = id, .text = "", .changes = @as([]const struct {}, &.{}), .@"error" = result.err }, .{})
    else
        std.json.Stringify.valueAlloc(gpa, .{ .@"error" = result.err }, .{});
    if (kind == .bash) return gpa.dupe(u8, result.ok);
    const Parsed = struct { ok: bool, id: ?[]const u8 = null, text: []const u8, changes: std.json.Value, @"error": ?[]const u8 = null };
    const parsed = try std.json.parseFromSlice(Parsed, gpa, result.ok, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return std.json.Stringify.valueAlloc(gpa, parsed.value, .{ .emit_null_optional_fields = false });
}

test "background worker failures are reported once and stop being pending" {
    const testing = std.testing;
    var t: Tools = .{ .io = testing.io, .home = "/tmp" };
    defer t.background.jobs.deinit(testing.allocator);
    defer t.agent_sessions.deinit(testing.allocator);
    try t.agent_sessions.add(testing.allocator, testing.io, "a1", "child", true);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var jobs: [2]Background.Job = undefined;
    for (&jobs, [_]BackgroundEvent.Kind{ .agent, .bash }, [_][]const u8{ "a1", "b2" }) |*job, kind, id| {
        job.* = .{
            .t = &t,
            .gpa = failing.allocator(),
            .args = &.{},
            .prompt = &.{},
            .id = @constCast(id),
            .kind = kind,
            .run = 1,
        };
        try t.background.jobs.append(testing.allocator, job);
    }
    t.background.bash_active = 1;
    const Sink = struct {
        starts: usize = 0,

        fn emit(ctx: *anyopaque, event: BackgroundEvent) !void {
            const sink: *@This() = @ptrCast(@alignCast(ctx));
            try testing.expectEqual(.started, event.state);
            sink.starts += 1;
        }
    };
    var sink: Sink = .{};
    try testing.expect(t.background.pending(testing.io));
    try t.background.poll(testing.io, &sink, Sink.emit);
    try testing.expectEqual(@as(usize, 2), sink.starts);
    for (&jobs) |*job| {
        const thread = try std.Thread.spawn(.{}, Background.Job.work, .{job});
        thread.join();
        try testing.expect(job.done.load(.acquire));
        try testing.expectEqual(error.OutOfMemory, job.failure.?);
    }
    try testing.expectEqualStrings("a1", try t.agent_sessions.reserve(testing.io, "a1"));
    try testing.expectEqual(@as(usize, 0), t.background.bash_active);
    try testing.expectError(error.OutOfMemory, t.background.poll(testing.io, &sink, Sink.emit));
    try testing.expectEqual(null, jobs[0].failure);
    try testing.expect(jobs[0].delivered);
    try testing.expect(!jobs[1].delivered);
    try testing.expect(t.background.pending(testing.io));
    try testing.expectError(error.OutOfMemory, t.background.poll(testing.io, &sink, Sink.emit));
    try testing.expect(!t.background.pending(testing.io));
    try t.background.poll(testing.io, &sink, Sink.emit);
    try t.background.poll(testing.io, &sink, Sink.emit);
    try testing.expectEqual(@as(usize, 2), sink.starts);
}

test "background starts share per-kind foreground counters and leave terminal progress" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/session.jsonl", .{tmp.sub_path});
    defer testing.allocator.free(path);
    var log = try Log.create(testing.io, path);
    defer log.close(testing.io);
    var inbox: Inbox = .{};
    defer inbox.batch.deinit(testing.allocator);
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody", .cfg = .{ .model = "m", .base_url = "", .api_key = "" } };
    defer t.progress.deinit(testing.allocator);
    defer t.agent_sessions.deinit(testing.allocator);
    defer t.background.stop(testing.allocator);
    t.background.inbox = &inbox;
    t.background.log = &log;
    _ = try t.progress.add(testing.allocator, testing.io, .agent, "foreground", 1, false);
    var timing: @import("../sandbox.zig").RunTiming = .init(testing.io, .now(testing.io, .awake));
    var host = t.host();
    host.timing = &timing;
    const result = try @import("../sandbox.zig").eval(testing.allocator, testing.io, "[await tools.bash({command: 'true', background: true}), await tools.agent({prompt: 'child', background: true})]", .{}, host, null);
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expectEqualStrings("[{\"id\":\"b1\"},{\"id\":\"a2\"}]", result.text);
    for (t.background.jobs.items) |job| {
        if (job.thread) |thread| thread.join();
        job.thread = null;
        try testing.expect(job.done.load(.acquire));
    }
    try testing.expectEqual(@as(usize, 2), timing.count);
    try testing.expectEqualStrings("b1", timing.entries[0].id.?);
    try testing.expectEqualStrings("a2", timing.entries[1].id.?);
    for (timing.entries[0..timing.count]) |call| try testing.expectEqual(@as(?bool, true), call.background);
    try testing.expectEqualStrings("a1", t.progress.slots.items[0].value.id);
    try testing.expectEqual(.done, t.progress.slots.items[1].value.state);
    try testing.expectEqual(.failed, t.progress.slots.items[2].value.state);
    try testing.expectEqual(@as(usize, 2), inbox.batch.items.items.len);
    t.background.stop(testing.allocator);
    try testing.expectEqualStrings("b1", timing.entries[0].id.?);
}

fn testBashJob(t: *Tools, command: []const u8, detached: bool) ![]const u8 {
    const gpa = std.testing.allocator;
    const bg = &t.background;
    const job = try gpa.create(Background.Job);
    errdefer gpa.destroy(job);
    const args = try std.json.Stringify.valueAlloc(gpa, .{ .command = command, .background = true, .detached = detached }, .{});
    errdefer gpa.free(args);
    const prompt = try gpa.dupe(u8, command);
    errdefer gpa.free(prompt);
    const progress_id = try t.progress.add(gpa, t.io, .bash, command, 1, true);
    const id = try gpa.dupe(u8, progress_id);
    errdefer gpa.free(id);
    bg.mutex.lockUncancelable(t.io);
    defer bg.mutex.unlock(t.io);
    try bg.jobs.ensureUnusedCapacity(gpa, 1);
    job.* = .{ .t = t, .gpa = gpa, .args = args, .prompt = prompt, .id = id, .kind = .bash, .detached = detached, .run = 1 };
    bg.bash_active += 1;
    errdefer bg.bash_active -= 1;
    job.thread = try std.Thread.spawn(.{}, Background.Job.work, .{job});
    bg.jobs.appendAssumeCapacity(job);
    return id;
}

test "normal turn finish retains detached jobs and concurrent stop delivers exactly once" {
    const testing = std.testing;
    var inbox: Inbox = .{};
    defer inbox.batch.deinit(testing.allocator);
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody" };
    defer t.progress.deinit(testing.allocator);
    t.background.inbox = &inbox;
    defer t.background.stop(testing.allocator);
    const foreground = try testBashJob(&t, "sleep 5", false);
    const detached = try testBashJob(&t, "sleep 5", true);
    try testing.expect(t.background.pending(testing.io));
    const names = try t.background.pendingNames(testing.allocator, testing.io);
    defer testing.allocator.free(names);
    try testing.expectEqualStrings("bash b1", names);
    t.background.finishTurn(testing.allocator, testing.io, false);
    try testing.expectEqual(@as(usize, 2), t.background.jobs.items.len);
    try testing.expectEqual(@as(usize, 1), t.background.bash_active);
    try testing.expect(!t.background.cancel.load(.acquire));
    try testing.expectEqual(@as(usize, 1), inbox.batch.items.items.len);
    try testing.expect(std.mem.indexOf(u8, inbox.batch.items.items[0].text, "canceled") != null);
    try testing.expect(!try t.background.stopById(testing.io, foreground));
    t.background.delivered(testing.io, foreground, 0);
    try testing.expect(!t.background.pending(testing.io));
    try testing.expect(t.background.anyPending(testing.io));
    const Stopper = struct {
        t: *Tools,
        id: []const u8,
        stopped: bool = false,

        fn work(stopper: *@This()) void {
            stopper.stopped = stopper.t.background.stopById(stopper.t.io, stopper.id) catch @panic("stop failed");
        }
    };
    var stoppers: [4]Stopper = undefined;
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    {
        defer for (threads[0..spawned]) |thread| thread.join();
        for (&stoppers, &threads) |*stopper, *thread| {
            stopper.* = .{ .t = &t, .id = detached };
            thread.* = try std.Thread.spawn(.{}, Stopper.work, .{stopper});
            spawned += 1;
        }
    }
    var stopped: usize = 0;
    for (stoppers) |stopper| if (stopper.stopped) {
        stopped += 1;
    };
    try testing.expectEqual(@as(usize, 1), stopped);
    try testing.expectEqual(@as(usize, 0), t.background.bash_active);
    try testing.expectEqual(@as(usize, 2), inbox.batch.items.items.len);
    try testing.expect(std.mem.indexOf(u8, inbox.batch.items.items[1].text, "canceled") != null);
    for (t.background.jobs.items) |job| {
        try testing.expect(job.thread == null);
        try testing.expectEqual(@as(usize, 0), job.args.len);
        try testing.expectEqual(@as(usize, 0), job.prompt.len);
    }
    t.background.delivered(testing.io, detached, 0);
    try testing.expect(!t.background.anyPending(testing.io));
    try testing.expect(!try t.background.stopById(testing.io, detached));
    try testing.expectError(error.UnknownBackgroundTask, t.background.stopById(testing.io, "b99"));
    t.background.finishTurn(testing.allocator, testing.io, false);
    try testing.expectEqual(@as(usize, 2), inbox.batch.items.items.len);
}

test "aborted turn stops detached jobs and suppresses completion" {
    const testing = std.testing;
    var inbox: Inbox = .{};
    defer inbox.batch.deinit(testing.allocator);
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody" };
    defer t.progress.deinit(testing.allocator);
    defer t.background.stop(testing.allocator);
    t.background.inbox = &inbox;
    _ = try testBashJob(&t, "sleep 5", true);
    t.background.finishTurn(testing.allocator, testing.io, true);
    try testing.expectEqual(@as(usize, 0), t.background.jobs.items.len);
    try testing.expectEqual(@as(usize, 0), t.background.bash_active);
    try testing.expect(t.background.cancel.load(.acquire));
    try testing.expect(inbox.empty(testing.io));
    try testing.expect(t.background.inbox == null);
    try testing.expect(t.background.log == null);
}

test "finished detached jobs are joined and compacted without losing their known IDs" {
    const testing = std.testing;
    var inbox: Inbox = .{};
    defer inbox.batch.deinit(testing.allocator);
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody" };
    defer t.progress.deinit(testing.allocator);
    defer t.background.stop(testing.allocator);
    t.background.inbox = &inbox;
    const id = try testBashJob(&t, "true", true);
    const job = t.background.jobs.items[0];
    job.join();
    try testing.expect(job.done.load(.acquire));
    try testing.expect(!try t.background.stopById(testing.io, id));
    try testing.expectEqual(@as(usize, 0), job.args.len);
    try testing.expectEqual(@as(usize, 0), job.prompt.len);
    try testing.expectEqual(@as(usize, 1), inbox.batch.items.items.len);
    try testing.expect(!t.background.pending(testing.io));
    try testing.expect(t.background.anyPending(testing.io));
    t.background.delivered(testing.io, id, 0);
    try testing.expect(!t.background.anyPending(testing.io));
}

test "detached shell exit completes the job and kills descendants" {
    const testing = std.testing;
    for ([_][]const u8{ "", " >/dev/null 2>&1" }) |redirect| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var inbox: Inbox = .{};
        defer inbox.batch.deinit(testing.allocator);
        var t: Tools = .{ .io = testing.io, .home = "/home/nobody" };
        defer t.progress.deinit(testing.allocator);
        defer t.background.stop(testing.allocator);
        t.background.inbox = &inbox;
        const command = try std.fmt.allocPrint(testing.allocator, "(sleep 0.5; echo survived > .zig-cache/tmp/{s}/survived){s} & echo started; exit 7", .{ tmp.sub_path, redirect });
        defer testing.allocator.free(command);
        const id = try testBashJob(&t, command, true);
        const job = t.background.jobs.items[0];
        const deadline = std.Io.Clock.Timestamp.fromNow(testing.io, .{ .raw = .fromSeconds(2), .clock = .awake });
        while (!job.done.load(.acquire)) {
            if (std.Io.Clock.Timestamp.now(testing.io, .awake).compare(.gte, deadline)) return error.JobDidNotFinish;
            try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(10), .clock = .awake }, testing.io);
        }
        job.join();
        try testing.expect(!try t.background.stopById(testing.io, id));
        try testing.expectEqual(@as(usize, 0), t.background.bash_active);
        try testing.expectEqual(@as(usize, 1), inbox.batch.items.items.len);
        try testing.expect(std.mem.indexOf(u8, inbox.batch.items.items[0].text, "\"exit_code\":7") != null);
        try testing.expectEqual(.failed, t.progress.slots.items[0].value.state);
        try testing.expect(t.progress.slots.items[0].value.detached);
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(600), .clock = .awake }, testing.io);
        try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "survived", .{}));
    }
}

test "stopping and resuming an agent keeps reservations and deliveries invocation scoped" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/session.jsonl", .{tmp.sub_path});
    defer testing.allocator.free(path);
    var log = try Log.create(testing.io, path);
    defer log.close(testing.io);
    var inbox: Inbox = .{};
    defer inbox.batch.deinit(testing.allocator);
    var t: Tools = .{ .io = testing.io, .home = "/unused", .cfg = .{ .model = "m", .base_url = "", .api_key = "", .limits = .{ .agent_concurrency = 1 } }, .agents_active = 1 };
    defer t.progress.deinit(testing.allocator);
    defer t.agent_sessions.deinit(testing.allocator);
    defer t.background.stop(testing.allocator);
    t.background.inbox = &inbox;
    t.background.log = &log;
    const started = try agent.agent(&t, testing.allocator, "{\"prompt\":\"first\",\"background\":true}");
    defer @import("../tools.zig").freeResult(started);
    try testing.expectEqualStrings("{\"id\":\"a1\"}", started.ok);
    try t.agent_sessions.bind(testing.allocator, testing.io, "a1", "child");
    try testing.expectError(error.AgentBusy, t.agent_sessions.reserve(testing.io, "a1"));
    try testing.expect(try t.background.stopById(testing.io, "a1"));
    try testing.expect(!try t.background.stopById(testing.io, "a1"));
    const first = t.background.jobs.items[0];
    try testing.expect(first.done.load(.acquire));
    try testing.expect(!first.delivered);
    try testing.expectEqualStrings("child", t.agent_sessions.session(testing.io, "a1").?);
    const resumed = try agent.agent(&t, testing.allocator, "{\"prompt\":\"second\",\"resume\":\"a1\",\"background\":true}");
    defer @import("../tools.zig").freeResult(resumed);
    try testing.expectEqualStrings("{\"id\":\"a1\"}", resumed.ok);
    const second = t.background.jobs.items[1];
    try testing.expect(first.invocation != second.invocation);
    try testing.expect(try t.background.stopById(testing.io, "a1"));
    try testing.expect(!try t.background.stopById(testing.io, "a1"));
    const resumed_again = try agent.agent(&t, testing.allocator, "{\"prompt\":\"third\",\"resume\":\"a1\",\"background\":true}");
    defer @import("../tools.zig").freeResult(resumed_again);
    try testing.expectEqualStrings("{\"id\":\"a1\"}", resumed_again.ok);
    const third = t.background.jobs.items[2];
    t.background.delivered(testing.io, "a1", second.invocation);
    try testing.expect(!first.delivered);
    try testing.expect(second.delivered);
    try testing.expect(!third.delivered);
    t.background.delivered(testing.io, "a1", first.invocation);
    t.background.delivered(testing.io, "a1", first.invocation);
    try testing.expect(first.delivered);
    try testing.expect(!third.delivered);
    try testing.expectError(error.AgentBusy, t.agent_sessions.reserve(testing.io, "a1"));
    try testing.expect(try t.background.stopById(testing.io, "a1"));
    try testing.expect(!try t.background.stopById(testing.io, "a1"));
    try testing.expectEqualStrings("a1", try t.agent_sessions.reserve(testing.io, "a1"));
    t.background.delivered(testing.io, "a1", third.invocation);
    try testing.expect(!t.background.anyPending(testing.io));
    try testing.expectError(error.AgentBusy, t.agent_sessions.reserve(testing.io, "a1"));
    try testing.expectEqualStrings("child", t.agent_sessions.session(testing.io, "a1").?);
    try testing.expectEqual(@as(usize, 3), inbox.batch.items.items.len);
    for (inbox.batch.items.items, t.background.jobs.items) |item, job| {
        try testing.expectEqualStrings("a1", item.background.?.id);
        try testing.expectEqual(job.invocation, item.invocation);
        try testing.expect(!item.detached);
        try testing.expect(job.thread == null);
        try testing.expectEqual(@as(usize, 0), job.args.len);
        try testing.expectEqual(@as(usize, 0), job.prompt.len);
    }
}

test "background agent failure publishes its task ID without a child session ID" {
    const testing = std.testing;
    const result = try messageResult(testing.allocator, .agent, "a1", .{ .err = @constCast("AgentFailed") });
    defer testing.allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("a1", parsed.value.object.get("id").?.string);
    try testing.expect(!parsed.value.object.contains("session"));
    try testing.expect(!parsed.value.object.get("ok").?.bool);
}
