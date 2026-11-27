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
    scope_id: ?usize = null,
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
    try s.commitLocalRun(s.tools.run_id);
    if (cancel != null and cancel.?.load(.acquire)) s.tools.background.stop(s.gpa);
    return ran;
}

fn runTimed(s: *Session, code: []const u8, cancel: ?*const std.atomic.Value(bool), timing: ?*sandbox.RunTiming) !Ran {
    defer s.usage.add(s.tools.takeUsage());
    defer s.tools.progress.drain(s.io) catch {};
    if (!s.tools.background.anyPending(s.io)) s.tools.progress.clear(s.gpa);
    s.tools.run_id += 1;
    var scope: @import("../tools.zig").RunScope = .{ .tools = &s.tools, .id = s.tools.run_id };
    defer scope.changes.discard(s.gpa);
    defer scope.reads.deinit(s.gpa);
    defer @import("../tools.zig").clearImages(&scope.images, s.gpa);
    var host = scope.hostWithPoll();
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
    try @import("hooks.zig").afterEdit(&s.tools, s.gpa, &scope.changes, &outcome);
    end = if (cancel != null and cancel.?.load(.acquire)) .cancelled else if (outcome.ok) .ok else if (std.mem.eql(u8, outcome.text, "Error: run timed out")) .timeout else .@"error";
    const cwd = try std.process.currentPathAlloc(s.io, s.gpa);
    defer s.gpa.free(cwd);
    return .{ .outcome = outcome, .changes = try scope.changes.take(s.gpa, s.arena.allocator(), cwd) };
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

pub const Executed = struct { cwd: ?[]const u8 = null, scope_id: ?usize = null, executed_source: ?[]const u8 = null, images: []const Image = &.{}, output: []const u8, completion_summary: ?[]const u8 = null, ok: bool, empty: bool = false, run_ms: ?u64 = null, remaining_steps: ?usize = null, tool_summary: ?ToolSummary = null, background_id: ?[]const u8 = null };

/// Output is arena-owned.
pub fn execute(s: *Session, call: provider.ToolCall, sink: Sink, cancel: *const std.atomic.Value(bool), timing: *sandbox.RunTiming) !Executed {
    const a = s.arena.allocator();
    const rerun = std.mem.eql(u8, call.function.name, "rerun");
    if (!rerun and !std.mem.eql(u8, call.function.name, "run"))
        return .{ .ok = false, .output = try a.dupe(u8, "error: expected run or rerun") };
    var base: ?[]const u8 = null;
    var requested_cwd: ?[]const u8 = null;
    const code: []const u8 = if (rerun) resolve: {
        const args = std.json.parseFromSlice(Rerun, a, call.function.arguments, .{}) catch
            return .{ .ok = false, .output = "error: expected {base: string, edits: [{old_text: string, new_text: string}]}" };
        base = args.value.base;
        const source = try s.log.findSource(s.io, a, args.value.base) orelse
            return .{ .ok = false, .output = "error: base source unavailable in this Session" };
        requested_cwd = source.cwd;
        if (!source.failed) return .{ .ok = false, .output = "error: base must be a completed failed script" };
        if (args.value.edits.len == 0) return .{ .ok = false, .output = "error: at least one edit is required" };
        switch (try patch(a, source.code, args.value.edits)) {
            .source => |patched| break :resolve patched,
            .invalid => |invalid| return .{ .ok = false, .output = try std.fmt.allocPrint(a, "error: edit {d} of {d}: {s}; each edit searches the source after earlier edits", .{
                invalid.index + 1, args.value.edits.len, invalid.reason,
            }) },
        }
    } else resolve: {
        const Args = struct { code: []const u8, cwd: ?[]const u8 = null };
        const args = std.json.parseFromSlice(Args, a, call.function.arguments, .{ .ignore_unknown_fields = true }) catch
            return .{ .ok = false, .output = "error: expected Run arguments {code: string, cwd?: string}" };
        requested_cwd = if (std.mem.eql(u8, call.type, "custom")) customCwd(a, args.value.code) catch
            return .{ .ok = false, .output = "error: expected a JSON string after // @cwd:" } else args.value.cwd;
        break :resolve args.value.code;
    };
    const cwd = if (requested_cwd) |requested| resolved: {
        const dir = @import("../tools/working_dir.zig").WorkingDir.open(&s.tools, s.gpa, requested, null) catch |err|
            return .{ .ok = false, .output = try std.fmt.allocPrint(a, "error: cannot use Run cwd {f}: {s}", .{ std.json.fmt(requested, .{}), @errorName(err) }) };
        defer dir.close(&s.tools, s.gpa);
        if (rerun and !std.mem.eql(u8, requested, dir.path))
            return .{ .ok = false, .output = "error: original Run cwd no longer resolves to the same directory" };
        break :resolved try a.dupe(u8, dir.path);
    } else null;
    try s.log.source(s.io, a, .{ .step = s.log.steps + 1, .run = timing.run_index, .code = code, .cwd = cwd, .base = base, .arguments = call.function.arguments, .failed = false });
    try sink.emit(sink.ctx, .{ .run_start = .{ .code = code, .cwd = cwd } });
    const before_omitted = timing.omitted;
    const started: std.Io.Clock.Timestamp = .now(s.io, .awake);
    const ran = try executeTimed(s, code, cwd, cancel, timing, sink);
    if (ran == null) {
        const remaining = if (s.cfg.limits.max_steps) |limit| limit -| s.steps else null;
        const prompt = @import("prompt.zig");
        const can_wait = s.tools.waitEnabled();
        const message = try std.fmt.allocPrint(a, "Run still executing after {d} ms; continuing in background as {s}. Captured output is preserved. {s} {s}", .{
            s.cfg.limits.run_background_after_ms,
            s.tools.background.runs.items[s.tools.background.runs.items.len - 1].id,
            prompt.backgroundDelivery(s.tools.tuning.delivery, can_wait),
            prompt.backgroundWait(can_wait),
        });
        const text = try output_format.stepLimitOutput(a, message, remaining);
        try sink.emit(sink.ctx, .{ .run_end = .{ .cwd = cwd, .background_id = s.tools.background.runs.items[s.tools.background.runs.items.len - 1].id, .ok = true, .output = text, .tool_summary = .{} } });
        return .{ .cwd = cwd, .executed_source = if (rerun) code else null, .output = text, .ok = true, .run_ms = @intCast(@max(started.untilNow(s.io).raw.toMilliseconds(), 0)), .remaining_steps = remaining, .tool_summary = .{}, .background_id = s.tools.background.runs.items[s.tools.background.runs.items.len - 1].id };
    }
    const o = ran.?.outcome;
    defer o.deinit(s.gpa);

    if (o.hook_notice.len > 0) try sink.emit(sink.ctx, .{ .notice = o.hook_notice });
    const remaining_steps = if (s.cfg.limits.max_steps) |limit| limit -| s.steps else null;
    const failed = !o.ok and !cancel.load(.acquire) and !std.mem.eql(u8, o.text, "Error: run timed out");
    try s.log.source(s.io, a, .{ .step = s.log.steps + 1, .run = timing.run_index, .code = code, .cwd = cwd, .base = base, .arguments = call.function.arguments, .failed = failed });
    const save: ?output_format.Save = if (try s.tools.outputsDir(a)) |dir| .{ .io = s.io, .dir = dir } else null;
    const summary = try output_format.completionSummary(a, o, ran.?.changes);
    const formatted = try output_format.formatCompletion(a, o, s.cfg.limits.run_output_bytes, save, summary);
    const referenced = if (failed) try std.fmt.allocPrint(a, "{s}\nSource: {d}:{d} (rerun executes from the beginning; prior effects may repeat)", .{ formatted, s.log.steps + 1, timing.run_index }) else formatted;
    const output = try output_format.stepLimitOutput(a, referenced, remaining_steps);
    const run_ms = timing.elapsed();
    const tool_summary = try ToolSummary.init(a, timing.entries[0..timing.count], timing.run_index, timing.omitted - before_omitted);
    try tool_summary.annotateViews(a, ran.?.images);
    try sink.emit(sink.ctx, .{ .run_end = .{ .cwd = cwd, .ok = o.ok, .output = output, .changes = ran.?.changes, .tool_summary = tool_summary } });
    return .{ .cwd = cwd, .executed_source = if (rerun) code else null, .output = output, .completion_summary = summary, .ok = o.ok, .scope_id = ran.?.scope_id, .empty = summary == null and std.mem.eql(u8, o.text, "undefined") and std.mem.trim(u8, o.logs, " \t\r\n").len == 0, .run_ms = run_ms, .remaining_steps = remaining_steps, .tool_summary = tool_summary, .images = ran.?.images };
}

fn customCwd(a: std.mem.Allocator, code: []const u8) !?[]const u8 {
    const prefix = "// @cwd:";
    const first = code[0..(std.mem.indexOfScalar(u8, code, '\n') orelse code.len)];
    if (!std.mem.startsWith(u8, first, prefix)) return null;
    return try std.json.parseFromSliceLeaky([]const u8, a, first[prefix.len..], .{ .allocate = .alloc_always });
}

fn executeTimed(s: *Session, code: []const u8, cwd: ?[]const u8, cancel: *const std.atomic.Value(bool), timing: *sandbox.RunTiming, sink: Sink) !?Ran {
    defer s.tools.progress.drain(s.io) catch {};
    if (!s.tools.background.anyPending(s.io)) s.tools.progress.clear(s.gpa);
    s.tools.run_id += 1;
    const job = try @import("run_job.zig").Job.create(&s.tools, s.gpa, code, cwd, s.log.steps + 1, timing.run_index, if (s.recorder) |*r| r else null);
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
    const session_cwd = try std.process.currentPathAlloc(s.io, s.gpa);
    defer s.gpa.free(session_cwd);
    const changes = try job.scope.changes.take(s.gpa, s.arena.allocator(), session_cwd);
    return try takeJobResult(job, s.arena.allocator(), changes);
}

fn takeJobResult(job: *@import("run_job.zig").Job, a: std.mem.Allocator, changes: []const Change) !Ran {
    const images = try @import("../tools.zig").takeImages(&job.scope.images, job.gpa, a);
    const outcome = job.outcome.?;
    job.outcome = null;
    return .{ .outcome = outcome, .scope_id = job.scope.id, .changes = changes, .images = images };
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

test "custom Run takes cwd only from its first line and scopes view" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDir(t.io, "feature space", .default_dir);
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "feature space/pixel.png", .data = png });
    var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
    defer client.deinit();
    const cfg: provider.Config = .{ .provider = .openai, .base_url = "invalid://local", .api_key = "mock", .model = "mock" };
    var session = try Session.init(t.allocator, t.io, &client, cfg, .{ .home = root, .user_home = root });
    defer session.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    var timing: sandbox.RunTiming = .init(t.io, .now(t.io, .awake));
    const directory = try std.fmt.allocPrint(a, "{s}/feature space", .{root});
    const code = try std.fmt.allocPrint(a, "// @cwd: {f}\r\nif (!(await tools.view({{path: 'pixel.png'}})).ok) throw Error('view failed');", .{std.json.fmt(directory, .{})});
    const args = try std.json.Stringify.valueAlloc(a, .{ .code = code }, .{});
    const SinkImpl = struct {
        fn emit(_: *anyopaque, _: Event) !void {}
    };
    const result = try execute(&session, .{ .id = "custom", .type = "custom", .function = .{ .name = "run", .arguments = args } }, .{ .ctx = &cancel, .emit = SinkImpl.emit }, &cancel, &timing);
    try t.expect(result.ok);
    try t.expectEqual(@as(usize, 1), result.images.len);
    try t.expectEqualStrings(try tmp.dir.realPathFileAlloc(t.io, "feature space", a), result.cwd.?);
    try t.expectEqual(@as(?[]const u8, null), try customCwd(a, "1;\n// @cwd: bad"));
    try t.expectError(error.SyntaxError, customCwd(a, "// @cwd: bad"));
}

const Edit = struct { old_text: []const u8, new_text: []const u8 };
const Rerun = struct { base: []const u8, edits: []const Edit };

const Patch = union(enum) {
    source: []const u8,
    invalid: struct { index: usize, reason: []const u8 },
};

fn patch(a: std.mem.Allocator, original: []const u8, edits: []const Edit) !Patch {
    var code = original;
    for (edits, 0..) |edit, i| {
        if (edit.old_text.len == 0) return .{ .invalid = .{ .index = i, .reason = "old_text is empty" } };
        const first = std.mem.indexOf(u8, code, edit.old_text) orelse
            return .{ .invalid = .{ .index = i, .reason = "old_text did not match" } };
        if (std.mem.indexOfPos(u8, code, first + 1, edit.old_text) != null)
            return .{ .invalid = .{ .index = i, .reason = "old_text matched more than once" } };
        code = try std.mem.replaceOwned(u8, a, code, edit.old_text, edit.new_text);
    }
    return .{ .source = code };
}

test "patch rejects overlapping matches and applies edits to a copy" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const overlapping = try patch(a, "aaa", &.{.{ .old_text = "aa", .new_text = "b" }});
    try std.testing.expectEqualStrings("old_text matched more than once", overlapping.invalid.reason);
    const original = "alpha beta";
    const resolved = try patch(a, original, &.{ .{ .old_text = "alpha", .new_text = "gamma" }, .{ .old_text = "gamma beta", .new_text = "delta" } });
    try std.testing.expectEqualStrings("delta", resolved.source);
    try std.testing.expectEqualStrings("alpha beta", original);
}

test "image handoff allocation failure leaves Outcome owned by Job" {
    const t = std.testing;
    var tools: @import("../tools.zig").Tools = .{ .io = t.io, .home = "/unused" };
    const job = try @import("run_job.zig").Job.create(&tools, t.allocator, "'complete'", null, 1, 0, null);
    defer job.destroy();
    job.join();
    const original = job.outcome.?.text;
    const attachment: Image = .{ .path = "image.png", .name = "image", .media_type = "image/png", .bytes = 24, .width = 1, .height = 1 };
    try job.scope.images.ensureUnusedCapacity(t.allocator, 1);
    job.scope.images.appendAssumeCapacity(try attachment.clone(t.allocator));
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var arena: std.heap.ArenaAllocator = .init(failing.allocator());
    defer arena.deinit();
    try t.expectError(error.OutOfMemory, takeJobResult(job, arena.allocator(), &.{}));
    try t.expect(job.outcome != null);
    try t.expectEqual(original.ptr, job.outcome.?.text.ptr);
    try t.expectEqualStrings("\"complete\"", job.outcome.?.text);
    try t.expectEqual(@as(usize, 0), job.scope.images.items.len);
    failing.fail_index = std.math.maxInt(usize);
    const result = try takeJobResult(job, arena.allocator(), &.{});
    defer result.outcome.deinit(t.allocator);
    try t.expect(job.outcome == null);
}
