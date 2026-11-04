//! No frontend dependencies: frontends observe a Session only through `Sink`.

const std = @import("std");
const sandbox = @import("sandbox.zig");
const tools = @import("tools.zig");
const provider = @import("provider.zig");
const session_log = @import("session/log.zig");
const instructions = @import("session/instructions.zig");
const effort = @import("session/effort.zig");
const prompt = @import("session/prompt.zig");
const compaction = @import("session/compact.zig");
const runner = @import("session/run.zig");
const session_history = @import("session/history.zig");
const Fork = @import("tools/agent/input.zig").Fork;

pub const Event = @import("session/events.zig").Event;
pub const ModelActivity = @import("session/events.zig").ModelActivity;

pub const Sink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, event: Event) anyerror!void,
    onModelActivity: ?*const fn (ctx: *anyopaque, activity: ModelActivity) anyerror!void = null,
    onUserInserted: ?*const fn (ctx: *anyopaque, id: u64) anyerror!void = null,

    pub fn modelActivity(sink: Sink, activity: ModelActivity) !void {
        if (sink.onModelActivity) |notify| try notify(sink.ctx, activity);
    }
};

const max_attempts = provider.max_attempts;

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    cfg: provider.Config,
    /// Owns every string in `history`.
    arena: std.heap.ArenaAllocator,
    history: std.ArrayList(provider.Message) = .empty,
    /// Totals for the current or most recent Turn.
    usage: provider.Usage = .{},
    steps: u32 = 0,
    summary: ?@import("session/events.zig").TurnSummary = null,
    interrupt_signal: ?*const std.atomic.Value(std.posix.SIG) = null,
    /// Next-request estimate: latest usage plus tool results, or the compacted history size.
    context_tokens: u64 = 0,
    pending_background_bytes: u64 = 0,
    /// Automatic compaction is not retried until the context reaches this size.
    compact_backoff: u64 = 0,
    tools: tools.Tools,
    log: session_log.Log = undefined,
    recorder: ?sandbox.Recorder = null,
    id: []const u8 = undefined,
    cache_key: []const u8 = undefined,
    parent_session_id: ?[]const u8 = null,
    options: Options = undefined,
    inbox: @import("session/inbox.zig").Inbox = .{},

    /// Thread-safe while a Turn runs; other Session mutation is exclusive.
    pub fn enqueue(s: *Session, text: []const u8) !u64 {
        return s.inbox.enqueue(s.gpa, s.io, text);
    }

    /// The caller owns the batch. Take leftovers only after joining the Turn.
    pub fn takeQueued(s: *Session) !@import("session/inbox.zig").Batch {
        return s.inbox.takeUsers(s.gpa, s.io);
    }

    pub const Options = struct { environ: ?*const std.process.Environ.Map = null, depth: u32 = 0, parent_session_id: ?[]const u8 = null, home: []const u8, user_home: []const u8, resume_id: ?[]const u8 = null, continue_latest: bool = false, fork: ?Fork = null };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, cfg: provider.Config, options: Options) !Session {
        if (options.fork) |fork| {
            if (options.resume_id != null or options.continue_latest) return error.ConflictingForkOptions;
            try cfg.checkSession(fork.provider, fork.model);
        }
        var s: Session = .{
            .gpa = gpa,
            .io = io,
            .client = client,
            .cfg = cfg,
            .arena = .init(gpa),
            .tools = .{ .io = io, .home = options.user_home, .data_home = options.home, .depth = options.depth, .environ = options.environ, .cfg = cfg, .track_changes = true },
            .parent_session_id = options.parent_session_id,
            .options = options,
        };
        errdefer s.arena.deinit();
        errdefer s.history.deinit(gpa);
        errdefer s.tools.agent_sessions.deinit(gpa);
        errdefer s.tools.file_state.deinit(gpa);
        s.options.fork = null;
        const a = s.arena.allocator();
        const cwd = try std.process.currentPathAlloc(io, a);
        const directory = try std.fs.path.join(a, &.{ options.home, "sessions" });
        try std.Io.Dir.cwd().createDirPath(io, directory);
        if (options.resume_id != null or options.continue_latest) {
            const path = if (options.resume_id) |id| blk: {
                if (id.len != 32 or std.mem.indexOfNone(u8, id, "0123456789abcdef") != null) return error.InvalidSessionId;
                break :blk try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ directory, id });
            } else try session_log.latest(io, a, directory, cwd);
            s.id = try a.dupe(u8, std.fs.path.stem(path));
            s.log = try session_log.Log.restore(io, gpa, a, path, &s.history, &s.context_tokens, options.parent_session_id);
            s.pending_background_bytes = s.log.pending_background_bytes;
            errdefer s.log.close(io);
            try cfg.checkSession(s.log.provider, s.log.model);
            s.cache_key = s.log.cache_key orelse s.id;
            s.tools.forked = s.log.forked_from != null;
            s.parent_session_id = s.log.parent_session_id;
            if (s.parent_session_id != null) s.tools.depth = @max(s.tools.depth, 1);
            s.tools.race_fact_pending = s.tools.depth == 0 and prompt.raceNeedsAnnouncement(s.history.items);
        } else {
            var random: [16]u8 = undefined;
            io.random(&random);
            const path = try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ directory, std.fmt.bytesToHex(random, .lower) });
            s.id = try a.dupe(u8, std.fs.path.stem(path));
            s.log = try session_log.Log.create(io, path);
            errdefer s.log.close(io);
            s.cache_key = s.id;
            if (options.fork) |fork| {
                s.cache_key = try a.dupe(u8, fork.cache_key);
                s.tools.forked = true;
                s.tools.depth = @max(s.tools.depth, 1);
                s.parent_session_id = options.parent_session_id orelse try a.dupe(u8, fork.session);
                if (fork.race) |race| s.tools.race_paths = .{
                    .parent_root = try a.dupe(u8, race.parent_root),
                    .worktree_root = try a.dupe(u8, race.worktree_root),
                };
                try @import("tools/files.zig").importForkVersions(&s.tools, gpa, fork.file_versions);
                const messages = try inheritFork(a, fork);
                try s.log.commit(io, gpa, &s.history, &s.context_tokens, .{
                    .messages = messages,
                    .context_tokens = compaction.estimateTokens(messages),
                    .cwd = cwd,
                    .provider = cfg.provider,
                    .model = cfg.model,
                    .parent_session_id = s.parent_session_id,
                    .cache_key = s.cache_key,
                    .forked_from = .{ .session = try a.dupe(u8, fork.session), .message_count = fork.message_count },
                    .nib_version = @import("build_options").nib_version,
                });
            } else {
                const template = try prompt.renderSystem(a, cwd, &s.tools, options.environ);
                const base = try prompt.stepLimitPrompt(a, template, cfg.limits.max_steps);
                const global = try std.fs.path.join(a, &.{ options.home, "AGENTS.md" });
                const project = try std.fs.path.join(a, &.{ try instructions.projectRoot(io, a, cwd), "AGENTS.md" });
                const system = try instructions.append(io, a, base, global, project);
                const sha = prompt.systemSha(base);
                try s.log.commit(io, gpa, &s.history, &s.context_tokens, .{
                    .messages = &.{.{ .role = "system", .content = system }},
                    .cwd = cwd,
                    .provider = cfg.provider,
                    .model = cfg.model,
                    .parent_session_id = s.parent_session_id,
                    .cache_key = s.cache_key,
                    .nib_version = @import("build_options").nib_version,
                    .system_sha = &sha,
                    .patches_off = try prompt.disabledPatches(a, options.environ),
                });
            }
        }
        errdefer s.log.close(io);
        const recording = if (options.environ) |env| !std.mem.eql(u8, env.get("NIB_RECORD") orelse "", "off") else true;
        const calls_path = try std.fmt.allocPrint(a, "{s}/{s}.calls.jsonl", .{ directory, s.id });
        s.recorder = sandbox.Recorder.init(gpa, io, calls_path, recording);
        errdefer if (s.recorder) |*recorder| recorder.deinit();
        s.tools.session_id = s.id;
        for (s.log.agent_sessions) |entry| {
            try s.tools.agent_sessions.add(gpa, io, entry.id, entry.session, false);
            s.tools.agent_sessions.setFork(io, entry.id, entry.fork);
        }
        s.tools.progress.next_agent_id = s.log.next_agent_id;
        s.tools.progress.next_bash_id = s.log.next_bash_id;
        for (s.log.lost_background) |lost| {
            const id = lost.id;
            const text = try std.fmt.allocPrint(gpa, "[background {s} {s} lost: process ended]", .{ @tagName(lost.kind), id });
            defer gpa.free(text);
            _ = try s.inbox.enqueueBackground(gpa, io, id, lost.kind, .lost, null, text, false, 0);
        }
        return s;
    }

    /// Replaces this Session with a new one (`id == null`) or a logged one.
    /// On failure the current Session is left untouched.
    pub fn reopen(s: *Session, id: ?[]const u8) !void {
        var options = s.options;
        options.resume_id = id;
        options.continue_latest = false;
        var next = try Session.init(s.gpa, s.io, s.client, s.cfg, options);
        next.tools.race_enabled = s.tools.race_enabled;
        next.tools.race_fact_pending = true;
        s.deinit();
        s.* = next;
    }

    pub fn deinit(s: *Session) void {
        s.tools.background.stop(s.gpa);
        s.tools.progress.deinit(s.gpa);
        s.tools.agent_sessions.deinit(s.gpa);
        s.inbox.batch.deinit(s.gpa);
        s.tools.discardChanges(s.gpa);
        s.tools.file_state.deinit(s.gpa);
        if (s.recorder) |*recorder| recorder.deinit();
        s.log.close(s.io);
        s.history.deinit(s.gpa);
        s.arena.deinit();
    }

    pub fn commit(s: *Session, from: usize, messages: []const provider.Message, tokens: u64, cwd: ?[]const u8) !void {
        try s.log.commit(s.io, s.gpa, &s.history, &s.context_tokens, .{ .from = from, .messages = messages, .context_tokens = tokens, .task_ids = s.tools.progress.highWater(s.io), .cwd = cwd, .provider = if (cwd != null) s.cfg.provider else null, .model = s.cfg.model, .parent_session_id = if (cwd != null) s.parent_session_id else null });
    }

    pub const Compaction = compaction.Compaction;
    pub const compact = compaction.compact;
    const autoCompact = compaction.autoCompact;
    pub const Ran = runner.Ran;
    pub const run = runner.run;
    const execute = runner.execute;

    pub fn turn(s: *Session, user_text: []const u8, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
        s.summary = .{};
        s.tools.background.cancel.store(false, .release);
        if (s.tools.background.inbox == null) s.tools.background.inbox = &s.inbox;
        if (s.tools.background.log == null) s.tools.background.log = &s.log;
        var target: runner.PollTarget = .{ .session = s, .sink = sink };
        s.tools.usage_sink = .{ .ctx = &target, .emit = runner.PollTarget.usage };
        s.tools.progress.sink = .{ .ctx = &target, .emit = runner.PollTarget.progress };
        s.tools.background_sink = .{ .ctx = &target, .emit = runner.PollTarget.background };
        const started: std.Io.Clock.Timestamp = .now(s.io, .awake);
        defer {
            s.summary.?.timing.wall_ms = @intCast(@max(started.untilNow(s.io).raw.toMilliseconds(), 0));
            sink.emit(sink.ctx, .{ .turn_end = s.summary.? }) catch {};
        }
        var stop_background = true;
        defer {
            s.tools.background.finishTurn(s.gpa, s.io, stop_background);
            s.tools.progress.drain(s.io) catch {};
            s.usage.add(s.tools.takeUsage());
            s.summary.?.usage = s.usage;
            s.tools.usage_sink = null;
            s.tools.progress.sink = null;
            s.tools.background_sink = null;
            if (!s.tools.background.anyPending(s.io)) s.tools.progress.clear(s.gpa);
        }
        errdefer {
            if (s.summary.?.status != .canceled) s.summary.?.status = if (cancel.load(.acquire)) .canceled else .failed;
        }
        var pending: std.ArrayList(provider.Message) = .empty;
        defer pending.deinit(s.gpa);
        var partial: Partial = .{};
        defer partial.deinit(s.gpa);
        const budget_text = try prompt.turnBudgetText(s.arena.allocator(), s.history.items[0].content orelse "", s.cfg.limits.max_steps, user_text);
        const turn_text = if (s.tools.depth == 0) try prompt.raceText(s.arena.allocator(), &s.tools.race_fact_pending, s.tools.race_enabled, s.cfg.limits.race_branches, budget_text) else budget_text;
        try pending.append(s.gpa, .{ .role = "user", .content = turn_text });
        s.usage = .{};
        s.steps = 0;
        try sink.emit(sink.ctx, .{ .usage = s.usage });
        s.runSteps(&pending, &partial, sink, cancel, detail) catch |err| {
            // A signal can surface as a read error instead of error.Canceled.
            if (err == error.Canceled or cancel.load(.acquire)) {
                s.summary.?.status = .canceled;
                try s.commitInterrupted(pending.items, &partial);
            }
            if (err == error.TooManySteps and !cancel.load(.acquire)) stop_background = false;
            return err;
        };
        stop_background = cancel.load(.acquire);
    }

    const Partial = struct {
        text: std.ArrayList(u8) = .empty,
        reasoning: std.ArrayList(u8) = .empty,

        fn clear(p: *Partial) void {
            p.text.clearRetainingCapacity();
            p.reasoning.clearRetainingCapacity();
        }

        fn deinit(p: *Partial, gpa: std.mem.Allocator) void {
            p.text.deinit(gpa);
            p.reasoning.deinit(gpa);
        }
    };

    /// An unfinished Step is dropped, since its tool calls would need results.
    fn commitInterrupted(s: *Session, pending: []const provider.Message, partial: *const Partial) !void {
        const a = s.arena.allocator();
        const terminated = if (s.interrupt_signal) |signal| signal.load(.acquire) == .TERM else false;
        const marker = if (terminated) "[interrupted: process terminated]" else "[interrupted by user]";
        const text = if (partial.text.items.len == 0) marker else try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ partial.text.items, marker });
        var reasoning: ?provider.Reasoning = null;
        if (s.cfg.provider == .chat_completions and s.cfg.thinking != false) {
            // DeepSeek thinking mode rejects any later request whose assistant messages lack reasoning_content.
            reasoning = .{ .provider = .chat_completions, .data = if (partial.reasoning.items.len == 0) marker else try a.dupe(u8, partial.reasoning.items) };
        }
        var messages: std.ArrayList(provider.Message) = .empty;
        defer messages.deinit(s.gpa);
        for (pending) |m| {
            if (!std.mem.eql(u8, m.role, "user")) break;
            try messages.append(s.gpa, m);
        }
        try messages.append(s.gpa, .{ .role = "assistant", .content = text, .reasoning = reasoning });
        try s.commit(s.history.items.len, messages.items, s.context_tokens + compaction.estimateTokens(messages.items), null);
    }

    fn insertInbox(s: *Session, pending: *std.ArrayList(provider.Message), sink: Sink, background_only: bool) !@import("session/inbox.zig").Batch {
        var inserted = if (background_only)
            try s.inbox.insertBackground(s.gpa, s.io, s.arena.allocator(), pending)
        else
            try s.inbox.insert(s.gpa, s.io, s.arena.allocator(), pending);
        errdefer inserted.deinit(s.gpa);
        var has_background = false;
        for (inserted.items.items) |item| {
            if (item.background) |b| {
                has_background = true;
                s.tools.background.delivered(s.io, b.id, item.invocation);
                var event = b;
                event.result = if (std.mem.indexOfScalar(u8, item.text, '\n')) |nl| item.text[nl + 1 ..] else item.text;
                try sink.emit(sink.ctx, .{ .background = event });
            } else if (sink.onUserInserted) |notify| try notify(sink.ctx, item.id);
        }
        if (has_background) {
            try s.commit(s.history.items.len, pending.items, s.context_tokens + compaction.estimateTokens(pending.items), null);
            pending.clearRetainingCapacity();
            for (inserted.items.items) |item| if (item.background != null) {
                s.pending_background_bytes += item.text.len;
            };
            for (inserted.items.items) |item| if (item.background) |b|
                try s.log.background(s.io, s.gpa, b, s.steps + 1);
        }
        return inserted;
    }

    fn finishStepLimit(s: *Session, pending: *std.ArrayList(provider.Message), sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8, max_steps: usize) !void {
        const waited = try s.tools.background.pendingNames(s.gpa, s.io);
        defer s.gpa.free(waited);
        if (waited.len > 0) {
            const notice = try std.fmt.allocPrint(s.arena.allocator(), "Step limit reached; waiting for background tasks: {s}", .{waited});
            try sink.emit(sink.ctx, .{ .notice = notice });
        }
        while (s.tools.background.pending(s.io)) {
            if (cancel.load(.acquire)) return error.Canceled;
            try tools.Tools.poll(&s.tools);
            var inserted = try s.insertInbox(pending, sink, true);
            inserted.deinit(s.gpa);
            if (s.tools.background.pending(s.io))
                try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(20), .clock = .awake }, s.io);
        }
        if (cancel.load(.acquire)) return error.Canceled;
        detail.* = if (waited.len > 0)
            try std.fmt.allocPrint(s.gpa, "stopped after {d} steps (waited for background tasks: {s})", .{ max_steps, waited })
        else
            try std.fmt.allocPrint(s.gpa, "stopped after {d} steps", .{max_steps});
        return error.TooManySteps;
    }

    fn runSteps(s: *Session, pending: *std.ArrayList(provider.Message), partial: *Partial, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
        var next_effort: ?effort.Pending = null;
        var step_index: usize = 0;
        while (true) : (step_index += 1) {
            if (cancel.load(.acquire)) return error.Canceled;
            if (s.cfg.limits.max_steps) |max_steps| {
                if (step_index >= max_steps) return s.finishStepLimit(pending, sink, cancel, detail, max_steps);
            }
            const size = s.context_tokens + compaction.estimateTokens(pending.items);
            // The first fork request must send the inherited cache prefix before compaction can rewrite it.
            if (!(s.tools.forked and s.log.steps == 0) and size >= s.cfg.context_window - s.cfg.context_window / 4 and size >= s.compact_backoff)
                try s.autoCompact(sink, cancel, detail);
            if (cancel.load(.acquire)) return error.Canceled;
            try tools.Tools.poll(&s.tools);
            var inserted = try s.insertInbox(pending, sink, false);
            defer inserted.deinit(s.gpa);
            const background_output_bytes = s.pending_background_bytes;
            var request: std.ArrayList(provider.Message) = .empty;
            defer request.deinit(s.gpa);
            try request.appendSlice(s.gpa, s.history.items);
            try request.appendSlice(s.gpa, pending.items);
            try tools.Tools.poll(&s.tools);
            s.tools.background.setTurnStep(s.io, s.steps + 1);
            const decision = effort.decide(s.cfg, step_index == 0 or inserted.items.items.len > 0, next_effort);
            next_effort = null;
            try sink.emit(sink.ctx, .{ .step = .{ .n = s.steps + 1, .effort = decision.metadata.effort, .source = decision.metadata.source } });
            const started: std.Io.Clock.Timestamp = .now(s.io, .awake);
            var model_timing: provider.ModelTiming = .init(s.io, started);
            var attempts: u32 = 0;
            var first_data_ms: ?u64 = null;
            const reply = try s.complete(decision.cfg, request.items, sink, cancel, detail, partial, &model_timing, &attempts, &first_data_ms);
            const model_ms: u64 = @intCast(@max(started.untilNow(s.io).raw.toMilliseconds(), 0));
            var run_timing: sandbox.RunTiming = .init(s.io, started);
            defer s.summary.?.timing.race_branches += run_timing.race_branches;
            var run_ms: u64 = 0;
            partial.clear();
            s.usage.add(reply.usage);
            try sink.emit(sink.ctx, .{ .usage = s.usage });
            s.steps += 1;
            try pending.append(s.gpa, .{
                .role = "assistant",
                .content = reply.text,
                .tool_calls = if (reply.tool_calls.len > 0) reply.tool_calls else null,
                .reasoning = reply.reasoning,
                .phase = reply.phase,
                .step_effort = decision.metadata,
            });
            const fork_prefix = if (reply.tool_calls.len > 0 and s.tools.depth == 0 and !s.tools.forked)
                try session_history.snapshot(s.gpa, s.history.items, pending.items)
            else
                null;
            defer if (fork_prefix) |prefix| s.gpa.free(prefix);
            const fork_versions = if (fork_prefix != null) try s.tools.file_state.exportVersions(s.io, s.gpa) else null;
            defer if (fork_versions) |versions| @import("tools/file_state.zig").freeVersions(s.gpa, versions);
            if (fork_prefix) |prefix| {
                s.tools.fork_snapshot = .{
                    .session = s.id,
                    .message_count = prefix.len,
                    .history = prefix,
                    .cache_key = s.cache_key,
                    .id = "",
                    .provider = s.cfg.provider,
                    .model = s.cfg.model,
                    .thinking = decision.cfg.thinking,
                    .reasoning_effort = decision.cfg.reasoning_effort,
                    .file_versions = fork_versions.?,
                };
            }
            defer s.tools.fork_snapshot = null;
            var run_results: std.ArrayList(session_log.RunResult) = .empty;
            defer run_results.deinit(s.gpa);
            var output_tokens: u64 = 0;
            for (reply.tool_calls, 0..) |call, run_index| {
                run_timing.run_index = run_index;
                const before_bytes = run_timing.tool_bytes;
                const before_omitted = run_timing.omitted;
                const result = try s.execute(call, sink, cancel, &run_timing);
                run_timing.output_bytes += result.output.len;
                effort.Pending.record(&next_effort, result.effort, result.ok);
                run_ms += result.run_ms orelse 0;
                try sink.emit(sink.ctx, .{ .usage = s.usage });
                try pending.append(s.gpa, .{ .role = "tool", .content = result.output, .tool_call_id = call.id, .tool_summary = result.tool_summary });
                try run_results.append(s.gpa, .{
                    .tool_call_id = call.id,
                    .ok = result.ok,
                    .run_ms = result.run_ms,
                    .tool_bytes = run_timing.tool_bytes - before_bytes,
                    .calls_omitted = run_timing.omitted - before_omitted,
                    .output_bytes = result.output.len,
                    .remaining_steps = result.remaining_steps,
                });
                output_tokens += result.output.len / 3 + 1;
            }
            const tokens = reply.usage.prompt_tokens + reply.usage.completion_tokens + output_tokens;
            const ms: u64 = @intCast(@max(started.untilNow(s.io).raw.toMilliseconds(), 0));
            try s.log.commit(s.io, s.gpa, &s.history, &s.context_tokens, .{
                .from = s.history.items.len,
                .messages = pending.items,
                .context_tokens = tokens,
                .model = s.cfg.model,
                .usage = reply.usage,
                .turn_step = @intCast(step_index + 1),
                .ms = ms,
                .model_ms = model_ms,
                .effort = decision.metadata.effort,
                .effort_source = decision.metadata.source,
                .effort_downgraded = decision.downgraded,
                .attempts = attempts,
                .first_data_ms = first_data_ms,
                .max_gap_ms = model_timing.max_gap_ms,
                .code = try model_timing.finish(s.arena.allocator(), reply.tool_calls),
                .run_ms = run_ms,
                .calls = run_timing.entries[0..run_timing.count],
                .calls_omitted = run_timing.omitted,
                .task_ids = s.tools.progress.highWater(s.io),
                .tool_bytes = run_timing.tool_bytes,
                .output_bytes = run_timing.output_bytes + background_output_bytes,
                .run_results = run_results.items,
            });
            s.pending_background_bytes = 0;
            s.summary.?.steps += 1;
            s.summary.?.usage = s.usage;
            s.summary.?.timing.model_ms += model_ms;
            s.summary.?.timing.run_ms += run_ms;
            s.summary.?.timing.tool_bytes += run_timing.tool_bytes;
            s.summary.?.timing.output_bytes += run_timing.output_bytes + background_output_bytes;
            s.summary.?.timing.llm_calls += run_timing.llm_calls;
            s.summary.?.timing.agent_calls += run_timing.agent_calls;
            pending.clearRetainingCapacity();
            try sink.emit(sink.ctx, .{ .usage = s.usage });
            if (reply.tool_calls.len == 0) {
                if (!s.tools.background.pending(s.io)) return;
                if (s.cfg.limits.max_steps) |max_steps| {
                    if (s.steps >= max_steps) continue;
                }
                while (s.inbox.empty(s.io) and s.tools.background.pending(s.io)) {
                    if (cancel.load(.acquire)) return error.Canceled;
                    try tools.Tools.poll(&s.tools);
                    try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(20), .clock = .awake }, s.io);
                }
                if (s.inbox.empty(s.io)) return;
            }
            if (cancel.load(.acquire)) return error.Canceled;
        }
    }

    fn complete(s: *Session, request_cfg: provider.Config, messages: []const provider.Message, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8, partial: *Partial, timing: *provider.ModelTiming, attempts: *u32, first_data_ms: *?u64) !provider.Reply {
        const Forward = struct {
            mutex: std.Io.Mutex = .init,
            sink: Sink,
            gpa: std.mem.Allocator,
            partial: *Partial,
            io: std.Io,
            started: std.Io.Clock.Timestamp,
            first_data_ms: *?u64,
            session: *Session,
            fn onData(ctx: *anyopaque) !void {
                const f: *@This() = @ptrCast(@alignCast(ctx));
                f.mutex.lockUncancelable(f.io);
                defer f.mutex.unlock(f.io);
                if (f.first_data_ms.* == null) f.first_data_ms.* = @intCast(@max(f.started.untilNow(f.io).raw.toMilliseconds(), 0));
                try f.sink.modelActivity(.data);
            }
            fn onDelta(ctx: *anyopaque, kind: provider.Kind, text: []const u8) !void {
                const f: *@This() = @ptrCast(@alignCast(ctx));
                f.mutex.lockUncancelable(f.io);
                defer f.mutex.unlock(f.io);
                try (if (kind == .text) &f.partial.text else &f.partial.reasoning).appendSlice(f.gpa, text);
                try f.sink.emit(f.sink.ctx, .{ .delta = .{ .kind = kind, .text = text } });
            }
            fn onRetry(ctx: *anyopaque, event: provider.RetryEvent) !void {
                const f: *@This() = @ptrCast(@alignCast(ctx));
                f.mutex.lockUncancelable(f.io);
                defer f.mutex.unlock(f.io);
                switch (event) {
                    .started => try f.sink.modelActivity(.started),
                    .finished => try f.sink.modelActivity(.finished),
                    .retry => |retry| {
                        try f.sink.emit(f.sink.ctx, .{ .retry = .{ .attempt = retry.attempt, .delay_ms = retry.delay_ms, .reason = retry.reason } });
                        // Visible failed-attempt deltas must not be committed on later cancellation.
                        f.partial.clear();
                    },
                    .failed => |failure| if (f.session.cfg.provider == .codex) {
                        try f.session.log.diagnose(f.io, f.gpa, .{
                            .error_name = @errorName(failure.err),
                            .message = failure.reason,
                            .attempts = failure.attempt,
                            .step = f.session.steps + 1,
                        });
                    },
                }
            }
        };
        var fwd: Forward = .{ .sink = sink, .gpa = s.gpa, .partial = partial, .io = s.io, .started = timing.started, .first_data_ms = first_data_ms, .session = s };
        const provider_sink: provider.Sink = .{ .ctx = &fwd, .onDelta = Forward.onDelta, .onData = Forward.onData, .timing = timing };
        if (!s.tools.background.anyPending(s.io))
            return provider.complete(s.gpa, s.arena.allocator(), s.client, request_cfg, s.cache_key, messages, prompt.tools_json, null, provider_sink, cancel, detail, attempts, .{ .ctx = &fwd, .onEvent = Forward.onRetry });
        const Request = struct {
            fn work(session: *Session, cfg: provider.Config, history: []const provider.Message, ps: provider.Sink, flag: *const std.atomic.Value(bool), failure: *?[]u8, tries: *u32, observer: *Forward, done: *std.Io.Event) !provider.Reply {
                defer done.set(session.io);
                return provider.complete(session.gpa, session.arena.allocator(), session.client, cfg, session.cache_key, history, prompt.tools_json, null, ps, flag, failure, tries, .{ .ctx = observer, .onEvent = Forward.onRetry });
            }
        };
        var done: std.Io.Event = .unset;
        var request = try s.io.concurrent(Request.work, .{ s, request_cfg, messages, provider_sink, cancel, detail, attempts, &fwd, &done });
        defer _ = request.cancel(s.io) catch {};
        while (!done.isSet()) {
            {
                fwd.mutex.lockUncancelable(s.io);
                defer fwd.mutex.unlock(s.io);
                try tools.Tools.poll(&s.tools);
            }
            done.waitTimeout(s.io, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                else => return err,
            };
        }
        return request.await(s.io);
    }
};

test "failed Turn leaves replay equal to in-memory safe history" {
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
    var cancel: std.atomic.Value(bool) = .init(true);
    var detail: ?[]u8 = null;
    defer if (detail) |d| t.allocator.free(d);
    const Quiet = struct {
        activities: std.ArrayList(ModelActivity) = .empty,
        fn emit(ctx: *anyopaque, event: Event) !void {
            const quiet: *@This() = @ptrCast(@alignCast(ctx));
            if (event == .retry) try std.testing.expectEqual(ModelActivity.finished, quiet.activities.items[quiet.activities.items.len - 1]);
        }
        fn activity(ctx: *anyopaque, state: ModelActivity) !void {
            const quiet: *@This() = @ptrCast(@alignCast(ctx));
            try quiet.activities.append(std.testing.allocator, state);
        }
    };
    var ctx: Quiet = .{};
    defer ctx.activities.deinit(t.allocator);
    for (0..2) |completed| {
        if (completed == 1) try session.commit(session.history.items.len, &.{
            .{ .role = "user", .content = "saved" },
            .{ .role = "assistant", .tool_calls = &.{.{ .id = "safe", .function = .{ .name = "run", .arguments = "{}" } }} },
            .{ .role = "tool", .tool_call_id = "safe", .content = "saved result" },
        }, 100, null);
        for ([_]bool{ false, true }) |canceled| {
            cancel.store(canceled, .release);
            ctx.activities.clearRetainingCapacity();
            const result = session.turn("failed turn", .{ .ctx = &ctx, .emit = Quiet.emit, .onModelActivity = Quiet.activity }, &cancel, &detail);
            try t.expectEqual(@as(usize, if (canceled) 0 else max_attempts * 2), ctx.activities.items.len);
            var i: usize = 0;
            while (i < ctx.activities.items.len) : (i += 2) {
                try t.expectEqualSlices(ModelActivity, &.{ .started, .finished }, ctx.activities.items[i..][0..2]);
            }
            try t.expectError(if (canceled) error.Canceled else error.UnsupportedUriScheme, result);
            const directory = try std.fs.path.join(a, &.{ root, "sessions" });
            const path = try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ directory, session.id });
            const data = try std.Io.Dir.cwd().readFileAlloc(t.io, path, a, .unlimited);
            var restored: std.ArrayList(provider.Message) = .empty;
            var tokens: u64 = 0;
            _ = try session_log.replay(a, a, data, &restored, &tokens);
            try t.expectEqualDeep(session.history.items, restored.items);
            try t.expectEqual(session.context_tokens, tokens);
        }
    }
    for ([_]bool{ false, true }) |canceled| {
        cancel.store(canceled, .release);
        ctx.activities.clearRetainingCapacity();
        try t.expectError(if (canceled) error.Canceled else error.UnsupportedUriScheme, session.compact(.{ .ctx = &ctx, .emit = Quiet.emit, .onModelActivity = Quiet.activity }, &cancel, &detail));
        try t.expectEqualSlices(ModelActivity, &.{ .started, .finished }, ctx.activities.items);
    }
}

test "allocation failures while restoring agent mappings release the session log lock" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer t.allocator.free(root);
    const id = "0123456789abcdef0123456789abcdef";
    const path = try std.fmt.allocPrint(t.allocator, "{s}/sessions/{s}.jsonl", .{ root, id });
    defer t.allocator.free(path);
    try tmp.dir.createDir(t.io, "sessions", .default_dir);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sessions/" ++ id ++ ".jsonl", .data = "{\"messages\":[{\"role\":\"system\",\"content\":\"original system\"}]}\n{\"agent_session\":{\"id\":\"a1\",\"session\":\"child\"}}\n" });
    var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
    defer client.deinit();
    const Check = struct {
        fn run(gpa: std.mem.Allocator, home: []const u8, log_path: []const u8, http: *std.http.Client) !void {
            const cfg: provider.Config = .{ .base_url = "invalid://local", .api_key = "mock", .model = "mock" };
            var session = Session.init(gpa, std.testing.io, http, cfg, .{ .home = home, .user_home = home, .resume_id = id }) catch |err| {
                const file = try std.Io.Dir.cwd().openFile(std.testing.io, log_path, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true });
                file.close(std.testing.io);
                return err;
            };
            defer session.deinit();
            try std.testing.expectEqual(@as(usize, 1), session.tools.agent_sessions.entries.items.len);
        }
    };
    try t.checkAllAllocationFailures(t.allocator, Check.run, .{ root, path, &client });
}

fn inheritFork(a: std.mem.Allocator, fork: Fork) ![]const provider.Message {
    const messages = @constCast(try session_history.inherit(a, fork));
    const race = fork.race orelse return messages;
    var original: usize = 0;
    var copied: usize = 0;
    while (original < fork.history.len) {
        const message = fork.history[original];
        original += 1;
        copied += 1;
        for (message.tool_calls orelse &.{}) |_| {
            if (original < fork.history.len and std.mem.eql(u8, fork.history[original].role, "tool")) {
                original += 1;
            } else {
                messages[copied].content = try std.fmt.allocPrint(a, "[forked as race branch {s} from session {s}; this tool call continues independently in the parent session; its result is not available in this child. Branch worktree root: {s}. read/edit/write/grep/glob map absolute paths beneath parent repository root {s} onto this branch root by normalized path components; other paths are unchanged. bash commands containing the parent repository root are rejected; use relative paths in the branch cwd. Inherited file observations are validated against the snapshot and rebased onto branch file versions.]", .{ fork.id, fork.session, race.worktree_root, race.parent_root });
            }
            copied += 1;
        }
    }
    return messages;
}

test "fork initialization copies history and resume retains independent identity and parent cache" {
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
    const messages = [_]provider.Message{
        .{ .role = "system", .content = "parent system, including original tools and depth text\n" },
        .{ .role = "user", .content = "current compacted history" },
        .{ .role = "assistant", .reasoning = .{ .provider = .chat_completions, .data = "parent reasoning" }, .tool_calls = &.{
            .{ .id = "first", .function = .{ .name = "run", .arguments = "{}" } },
            .{ .id = "second", .function = .{ .name = "run", .arguments = "{}" } },
        } },
    };
    const fork: Fork = .{ .session = "parent-session", .message_count = messages.len, .history = &messages, .cache_key = "root-cache-key", .id = "a2", .provider = cfg.provider, .model = cfg.model };
    var codex_fork = fork;
    codex_fork.provider = .codex;
    var wrong_model = cfg;
    wrong_model.provider = .codex;
    wrong_model.model = "other-model";
    try t.expectError(error.SessionModelMismatch, Session.init(t.allocator, t.io, &client, wrong_model, .{ .home = root, .user_home = root, .fork = codex_fork }));
    var wrong_provider = cfg;
    wrong_provider.provider = .codex;
    try t.expectError(error.SessionProviderMismatch, Session.init(t.allocator, t.io, &client, wrong_provider, .{ .home = root, .user_home = root, .fork = fork }));
    var session = try Session.init(t.allocator, t.io, &client, cfg, .{ .home = root, .user_home = root, .depth = 1, .fork = fork });
    var live = true;
    defer if (live) session.deinit();
    try t.expect(session.tools.forked);
    try t.expectEqual(@as(usize, 0), session.log.steps);
    try t.expect(session.options.fork == null);
    try t.expect(!std.mem.eql(u8, fork.session, session.id));
    try t.expectEqualStrings(fork.cache_key, session.cache_key);
    try t.expectEqualDeep(@as([]const provider.Message, &messages), session.history.items[0..messages.len]);
    try t.expect(session.history.items[0].content.?.ptr != messages[0].content.?.ptr);
    try t.expectEqual(@as(usize, 5), session.history.items.len);
    try session.log.agentSession(t.io, t.allocator, .{ .id = "a9", .session = "grandchild", .fork = true });
    const id = try a.dupe(u8, session.id);
    const expected = try a.dupe(provider.Message, session.history.items);
    const path = try std.fmt.allocPrint(a, "{s}/sessions/{s}.jsonl", .{ root, id });
    const data = try std.Io.Dir.cwd().readFileAlloc(t.io, path, a, .unlimited);
    var restored: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    const replayed = try session_log.replay(a, a, data, &restored, &tokens);
    try t.expectEqualDeep(session.history.items, restored.items);
    try t.expectEqualDeep(session_log.ForkedFrom{ .session = fork.session, .message_count = fork.message_count }, replayed.forked_from.?);
    try t.expectEqualStrings(fork.cache_key, replayed.cache_key.?);
    try t.expectEqual(session.context_tokens, tokens);
    const expected_encoded = try std.json.Stringify.valueAlloc(a, expected, .{});
    session.deinit();
    live = false;
    session = try Session.init(t.allocator, t.io, &client, cfg, .{ .home = root, .user_home = root, .resume_id = id });
    live = true;
    try t.expectEqualStrings(id, session.id);
    try t.expect(session.tools.forked);
    try t.expect(session.tools.agent_sessions.isFork(t.io, "a9"));
    try t.expectEqual(@as(usize, 0), session.log.steps);
    try t.expectEqualStrings(fork.cache_key, session.cache_key);
    const resumed_encoded = try std.json.Stringify.valueAlloc(a, session.history.items, .{});
    try t.expectEqualStrings(expected_encoded, resumed_encoded);
    try session.reopen(null);
    try t.expect(!session.tools.forked);
    try t.expectEqualStrings(session.id, session.cache_key);
}

test "race authorization survives session switches but not process initialization" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
    defer client.deinit();
    const cfg: provider.Config = .{ .base_url = "invalid://local", .api_key = "mock", .model = "mock", .limits = .{ .race_branches = 8 } };
    const options: Session.Options = .{ .home = root, .user_home = root };
    var session = try Session.init(t.allocator, t.io, &client, cfg, options);
    defer session.deinit();
    const first_id = try a.dupe(u8, session.id);
    const system = try a.dupe(u8, session.history.items[0].content.?);
    try t.expect(!session.tools.race_enabled);
    try t.expect(!session.tools.race_fact_pending);
    session.tools.race_enabled = true;
    try session.reopen(null);
    try t.expect(session.tools.race_enabled);
    try t.expect(session.tools.race_fact_pending);
    _ = try prompt.raceText(a, &session.tools.race_fact_pending, session.tools.race_enabled, 8, "parent: next");
    try t.expect(!session.tools.race_fact_pending);
    try t.expectEqual(@as(usize, 8), session.tools.cfg.?.limits.race_branches);
    try session.reopen(first_id);
    try t.expect(session.tools.race_enabled);
    try t.expect(session.tools.race_fact_pending);
    try t.expectEqualStrings(system, session.history.items[0].content.?);
    session.tools.race_enabled = false;
    try session.reopen(null);
    try t.expect(!session.tools.race_enabled);
    try t.expect(session.tools.race_fact_pending);
    var restarted = try Session.init(t.allocator, t.io, &client, cfg, .{ .home = root, .user_home = root, .resume_id = first_id });
    defer restarted.deinit();
    try t.expect(!restarted.tools.race_enabled);
    try t.expect(!restarted.tools.race_fact_pending);
    try restarted.commit(restarted.history.items.len, &.{.{ .role = "user", .content = "[race enabled: up to 8 branches]\n\nparent: old" }}, 0, null);
    try restarted.reopen(null);
    var stale = try Session.init(t.allocator, t.io, &client, cfg, .{ .home = root, .user_home = root, .resume_id = first_id });
    defer stale.deinit();
    try t.expect(!stale.tools.race_enabled);
    try t.expect(stale.tools.race_fact_pending);
}

test "race fork explains branch paths only in synthetic tool results" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const original = [_]provider.Message{
        .{ .role = "system", .content = "exact system /parent/file" },
        .{ .role = "user", .content = "exact history /parent/file" },
        .{ .role = "assistant", .reasoning = .{ .provider = .codex, .data = "opaque bytes" }, .tool_calls = &.{
            .{ .id = "real", .function = .{ .name = "run", .arguments = "exact arguments /parent/file" } },
            .{ .id = "synthetic", .function = .{ .name = "run", .arguments = "exact arguments" } },
        } },
        .{ .role = "tool", .tool_call_id = "real", .content = "real result /parent/file" },
        .{ .role = "user", .content = "later original message" },
    };
    const fork: Fork = .{ .session = "parent-session", .message_count = original.len, .history = &original, .cache_key = "cache", .id = "a3", .provider = .codex, .model = "mock", .race = .{ .parent_root = "/parent", .worktree_root = "/branch/a3" } };
    const messages = try inheritFork(arena.allocator(), fork);
    try t.expectEqual(@as(usize, 6), messages.len);
    try t.expectEqualDeep(@as([]const provider.Message, original[0..4]), messages[0..4]);
    try t.expectEqualDeep(original[4], messages[5]);
    try t.expectEqualStrings("synthetic", messages[4].tool_call_id.?);
    for ([_][]const u8{ "race branch a3", "/branch/a3", "/parent", "normalized path components", "use relative paths", "rebased" }) |fact|
        try t.expect(std.mem.indexOf(u8, messages[4].content.?, fact) != null);
}
