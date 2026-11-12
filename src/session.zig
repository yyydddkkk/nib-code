//! No frontend dependencies: frontends observe a Session only through `Sink`.

const std = @import("std");
const sandbox = @import("sandbox.zig");
const tools = @import("tools.zig");
const provider = @import("provider.zig");
const session_log = @import("session/log.zig");
const skills = @import("session/skills.zig");
const instructions = @import("session/instructions.zig");
const prompt = @import("session/prompt.zig");
const Profile = @import("session/profile.zig").Profile;
const compaction = @import("session/compact.zig");
const runner = @import("session/run.zig");
const session_history = @import("session/history.zig");
const Fork = @import("tools/agent/input.zig").Fork;

pub const Event = @import("session/events.zig").Event;
pub const ModelActivity = @import("session/events.zig").ModelActivity;

pub const Sink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, event: Event) anyerror!void,
    onToolActivity: ?*const fn (ctx: *anyopaque, name: []const u8) anyerror!void = null,
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
    codex_state: provider.CodexState = .{},
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
    hook_jobs: std.ArrayList(*@import("session/hooks.zig").TurnJob) = .empty,
    undo_history: @import("tools/undo.zig").History = .{},

    /// Thread-safe while a Turn runs; other Session mutation is exclusive.
    pub fn enqueue(s: *Session, text: []const u8) !u64 {
        return s.inbox.enqueue(s.gpa, s.io, text);
    }

    /// The caller owns the batch. Take leftovers only after joining the Turn.
    pub fn takeQueued(s: *Session) !@import("session/inbox.zig").Batch {
        return s.inbox.takeUsers(s.gpa, s.io);
    }

    pub const Options = struct { environ: ?*const std.process.Environ.Map = null, depth: u32 = 0, parent_session_id: ?[]const u8 = null, home: []const u8, user_home: []const u8, resume_id: ?[]const u8 = null, continue_latest: bool = false, fork: ?Fork = null, undo_enabled: bool = false, undo_dir: ?[]const u8 = null };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, cfg: provider.Config, options: Options) !Session {
        if (options.fork) |fork| {
            if (options.resume_id != null or options.continue_latest) return error.ConflictingForkOptions;
            try cfg.checkSession(fork.provider, fork.model);
            if (!std.mem.eql(u8, cfg.custom_provider orelse "", fork.custom_provider orelse "")) return error.SessionProviderMismatch;
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
        const enabled = try a.alloc([]const u8, cfg.enabled_skills.len);
        for (cfg.enabled_skills, enabled) |name, *copy| copy.* = try a.dupe(u8, name);
        s.cfg.enabled_skills = enabled;
        s.cfg.mcp_servers = try @import("mcp/config.zig").copy(a, cfg.mcp_servers);
        s.tools.cfg = s.cfg;
        const cwd = try std.process.currentPathAlloc(io, a);
        s.tools.mcp_client = try @import("mcp.zig").Client.create(gpa, io, s.cfg.mcp_servers, options.environ, options.home, options.user_home, s.cfg.sandbox.writable, s.cfg.sandbox.mode != .off);
        errdefer if (s.tools.mcp_client) |c| c.destroy();
        const directory = try std.fs.path.join(a, &.{ options.home, "sessions" });
        try std.Io.Dir.cwd().createDirPath(io, directory);
        if (options.resume_id != null or options.continue_latest) {
            const path = if (options.resume_id) |id| blk: {
                if (id.len != 32 or std.mem.indexOfNone(u8, id, "0123456789abcdef") != null) return error.InvalidSessionId;
                break :blk try std.fmt.allocPrint(a, "{s}/{s}.jsonl", .{ directory, id });
            } else try session_log.latest(io, a, directory, cwd);
            s.id = try a.dupe(u8, std.fs.path.stem(path));
            s.log = try session_log.Log.restore(io, gpa, a, path, &s.history, &s.context_tokens, options.parent_session_id);
            errdefer s.log.close(io);
            s.tools.mcp_client.?.destroy();
            s.tools.mcp_client = null;
            s.cfg.mcp_servers = try @import("mcp/config.zig").copy(a, s.log.mcp_servers);
            s.tools.cfg = s.cfg;
            s.tools.mcp_client = try @import("mcp.zig").Client.create(gpa, io, s.cfg.mcp_servers, options.environ, options.home, options.user_home, s.cfg.sandbox.writable, s.cfg.sandbox.mode != .off);
            s.pending_background_bytes = s.log.pending_background_bytes;
            try cfg.checkSession(s.log.provider, s.log.model);
            if (!std.mem.eql(u8, cfg.custom_provider orelse "", s.log.custom_provider orelse "")) return error.SessionProviderMismatch;
            s.cache_key = s.log.cache_key orelse s.id;
            s.tools.forked = s.log.forked_from != null;
            s.parent_session_id = s.log.parent_session_id;
            if (s.parent_session_id != null) s.tools.depth = @max(s.tools.depth, 1);
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
                try s.tools.file_state.importVersions(io, gpa, fork.file_versions);
                const messages = try session_history.inherit(a, fork);
                try s.log.commit(io, gpa, &s.history, &s.context_tokens, .{
                    .mcp_servers = s.cfg.mcp_servers,
                    .messages = messages,
                    .context_tokens = compaction.estimateTokens(messages),
                    .cwd = cwd,
                    .provider = cfg.provider,
                    .custom_provider = cfg.custom_provider,
                    .model = cfg.model,
                    .parent_session_id = s.parent_session_id,
                    .cache_key = s.cache_key,
                    .forked_from = .{ .session = try a.dupe(u8, fork.session), .message_count = fork.message_count },
                    .nib_version = @import("build_options").nib_version,
                });
            } else {
                try s.initializeHistory(cwd);
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
        s.tools.progress.next_run_id = s.log.next_run_id;
        for (s.log.lost_background) |lost| {
            const id = lost.id;
            const text = try std.fmt.allocPrint(gpa, "[background {s} {s} lost: process ended]", .{ @tagName(lost.kind), id });
            defer gpa.free(text);
            _ = try s.inbox.enqueueBackground(gpa, io, id, lost.kind, .lost, null, text, false, 0, null);
        }
        s.tools.undo_dir = options.undo_dir;
        if (options.undo_enabled and s.parent_session_id == null) {
            const root = try std.fmt.allocPrint(a, "{s}/{s}.undo", .{ directory, s.id });
            std.Io.Dir.cwd().deleteTree(io, root) catch {};
            std.Io.Dir.cwd().createDir(io, root, .fromMode(0o700)) catch {};
            s.undo_history.root = root;
        }
        return s;
    }

    pub fn initializeHistory(s: *Session, cwd: []const u8) !void {
        std.debug.assert(s.log.steps == 0);
        const a = s.arena.allocator();
        const template = try prompt.renderSystem(a, cwd, &s.tools, s.options.environ);
        const base = try prompt.stepLimitPrompt(a, template, s.cfg.limits.max_steps);
        const global = try std.fs.path.join(a, &.{ s.options.home, "AGENTS.md" });
        const root = try instructions.projectRoot(s.io, a, cwd);
        const project = try std.fs.path.join(a, &.{ root, "AGENTS.md" });
        const discovered = try skills.load(s.io, a, s.options.home, s.options.user_home, root);
        const found = try skills.select(a, discovered, s.cfg.enabled_skills);
        const system = try s.tools.mcp_client.?.prompt(a, try skills.append(a, try instructions.append(s.io, a, base, global, project), found.skills));
        s.log.skills = found.summary;
        const sha = prompt.systemSha(base);
        try s.log.commit(s.io, s.gpa, &s.history, &s.context_tokens, .{
            .messages = &.{.{ .role = "system", .content = system }},
            .cwd = cwd,
            .provider = s.cfg.provider,
            .custom_provider = s.cfg.custom_provider,
            .model = s.cfg.model,
            .parent_session_id = s.parent_session_id,
            .cache_key = s.cache_key,
            .nib_version = @import("build_options").nib_version,
            .system_sha = &sha,
            .skills = found.summary,
            .mcp_servers = s.cfg.mcp_servers,
            .patches_off = try prompt.disabledPatches(a, s.options.environ),
            .patches_on = try prompt.enabledOptInPatches(a, s.options.environ),
            .profile = @tagName(Profile.forModel(s.cfg.model)),
        });
    }

    /// Replaces this Session with a new one (`id == null`) or a logged one.
    /// On failure the current Session is left untouched.
    pub fn reopen(s: *Session, id: ?[]const u8) !void {
        var options = s.options;
        options.resume_id = id;
        options.continue_latest = false;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        var cfg = s.cfg;
        if (id == null) {
            const config = @import("config.zig");
            cfg.enabled_skills = try config.enabledSkills(arena.allocator(), try config.loadSkills(arena.allocator(), s.io, options.home));
            cfg.mcp_servers = try config.loadMcp(arena.allocator(), s.io, options.home);
        }
        const next = try Session.init(s.gpa, s.io, s.client, cfg, options);
        s.deinit();
        s.* = next;
    }

    pub const Switched = union(enum) {
        updated,
        new_session,
        /// The Session keeps its previous config.
        update_failed: anyerror,
        open_failed: anyerror,
    };

    /// Applies a new provider/model config: in place before the first Step, as a new Session after.
    pub fn switchConfig(s: *Session, cfg: provider.Config) Switched {
        const previous = s.cfg;
        if (s.log.steps > 0) {
            s.cfg = cfg;
            s.reopen(null) catch |err| {
                s.cfg = previous;
                return .{ .open_failed = err };
            };
            s.tools.recovery.enabled = true;
            return .new_session;
        }
        s.cfg = cfg;
        s.tools.cfg = cfg;
        const cwd = std.process.currentPathAlloc(s.io, s.arena.allocator()) catch |err| {
            s.cfg = previous;
            s.tools.cfg = previous;
            return .{ .update_failed = err };
        };
        s.initializeHistory(cwd) catch |err| {
            s.cfg = previous;
            s.tools.cfg = previous;
            return .{ .update_failed = err };
        };
        s.log.provider = cfg.provider;
        s.log.custom_provider = cfg.custom_provider;
        s.log.model = cfg.model;
        return .updated;
    }

    /// Stops using a key that was just removed from the credential store.
    pub fn dropStoredKey(s: *Session) void {
        if (s.cfg.key_source != .store) return;
        s.cfg.api_key = "";
        s.cfg.key_source = .none;
        s.tools.cfg = s.cfg;
    }

    pub fn finishHooks(s: *Session) void {
        for (s.hook_jobs.items) |job| {
            job.thread.join();
            s.gpa.destroy(job);
        }
        s.hook_jobs.deinit(s.gpa);
        s.hook_jobs = .empty;
    }

    pub fn deinit(s: *Session) void {
        s.finishHooks();
        s.codex_state.reset(s.gpa);
        s.tools.background.stop(s.gpa);
        if (s.tools.mcp_client) |c| c.destroy();
        s.undo_history.deinit(s.io, s.gpa);
        s.tools.progress.deinit(s.gpa);
        s.tools.agent_sessions.deinit(s.gpa);
        s.inbox.batch.deinit(s.gpa);
        s.tools.recovery.clear(s.gpa, s.io);
        s.tools.discardChanges(s.gpa);
        tools.clearImages(&s.tools.images, s.gpa);
        s.tools.file_state.deinit(s.gpa);
        if (s.recorder) |*recorder| recorder.deinit();
        s.log.close(s.io);
        s.history.deinit(s.gpa);
        s.arena.deinit();
    }

    pub fn commit(s: *Session, from: usize, messages: []const provider.Message, tokens: u64, cwd: ?[]const u8) !void {
        try s.log.commit(s.io, s.gpa, &s.history, &s.context_tokens, .{ .from = from, .messages = messages, .context_tokens = tokens, .task_ids = s.tools.progress.highWater(s.io), .cwd = cwd, .provider = if (cwd != null) s.cfg.provider else null, .custom_provider = if (cwd != null) s.cfg.custom_provider else null, .model = s.cfg.model, .parent_session_id = if (cwd != null) s.parent_session_id else null });
    }

    pub const Compaction = compaction.Compaction;
    pub const compact = compaction.compact;
    const autoCompact = compaction.autoCompact;
    pub const Ran = runner.Ran;
    pub const run = runner.run;
    const execute = runner.execute;

    pub fn undo(s: *Session) ![]u8 {
        const a = s.arena.allocator();
        const intent = "[undo requested] File restoration may follow. Re-read affected files before continuing.";
        try s.commit(s.history.items.len, &.{.{ .role = "user", .content = intent, .source = .undo }}, s.context_tokens + compaction.estimateTokens(&.{.{ .role = "user", .content = intent }}), null);
        const text = try s.undo_history.undo(&s.tools, s.gpa);
        errdefer s.gpa.free(text);
        try s.commit(s.history.items.len, &.{.{ .role = "user", .content = try a.dupe(u8, text), .source = .undo }}, s.context_tokens + compaction.estimateTokens(&.{.{ .role = "user", .content = text }}), null);
        return text;
    }

    pub fn turn(s: *Session, user_text: []const u8, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
        return s.turnWithImages(user_text, &.{}, sink, cancel, detail);
    }

    /// Every discovered skill, from this Session's project and home.
    pub fn discoverSkills(s: *Session, a: std.mem.Allocator) ![]const skills.Skill {
        const cwd = try std.process.currentPathAlloc(s.io, a);
        const root = try instructions.projectRoot(s.io, a, cwd);
        return (try skills.load(s.io, a, s.options.home, s.options.user_home, root)).skills;
    }

    /// `text` with the SKILL.md of every skill named by `$name`, or `text` itself when none is.
    pub fn expandSkills(s: *Session, text: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, text, '$') == null) return text;
        const a = s.arena.allocator();
        return skills.expand(s.io, a, text, s.discoverSkills(a) catch return text);
    }

    /// Directory holding this Session's stored images.
    pub fn imageDirectory(s: *Session, a: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/sessions/{s}.images", .{ s.options.home, s.id });
    }

    pub fn turnWithImages(s: *Session, user_text: []const u8, images: []const @import("image.zig").Image, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
        if (s.tools.background.log == null) s.tools.background.log = &s.log;
        try s.undo_history.begin(&s.tools, s.gpa);
        defer {
            s.undo_history.finish(&s.tools, s.gpa);
            if (s.undo_history.notice != null) sink.emit(sink.ctx, .{ .notice = "This Turn has no complete undo record; /undo cannot cross it." }) catch {};
        }
        if (s.codex_state.socket) |*socket| {
            if (socket.turn_state) |value| s.gpa.free(value);
            socket.turn_state = null;
        }
        s.summary = .{};
        s.tools.background.cancel.store(false, .release);
        if (s.tools.background.inbox == null) s.tools.background.inbox = &s.inbox;
        if (s.tools.background.log == null) s.tools.background.log = &s.log;
        var target: runner.PollTarget = .{ .session = s, .sink = sink };
        s.tools.usage_sink = .{ .ctx = &target, .emit = runner.PollTarget.usage };
        s.tools.progress.sink = .{ .ctx = &target, .emit = runner.PollTarget.progress };
        s.tools.notice_sink = .{ .gpa = s.gpa, .ctx = &target, .emit = runner.PollTarget.notice };
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
            s.tools.notice_sink = null;
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
        const attached = try s.arena.allocator().alloc(@import("image.zig").Image, images.len);
        for (images, attached) |item, *copy| copy.* = try item.clone(s.arena.allocator());
        try pending.append(s.gpa, .{ .role = "user", .content = try prompt.turnBudgetText(s.arena.allocator(), s.history.items[0].content orelse "", s.cfg.limits.max_steps, try s.expandSkills(user_text)), .images = if (images.len > 0) attached else null });
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
        if (s.cfg.protocol() == .chat_completions and s.cfg.thinking != false) {
            // DeepSeek thinking mode rejects any later request whose assistant messages lack reasoning_content.
            reasoning = .{ .provider = s.cfg.provider, .data = if (partial.reasoning.items.len == 0) marker else try a.dupe(u8, partial.reasoning.items) };
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
        if (waited.len > 0) try sink.modelActivity(.waiting);
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
            try std.fmt.allocPrint(s.gpa, "stopped after {d} step{s} (waited for background tasks: {s})", .{ max_steps, if (max_steps == 1) "" else "s", waited })
        else
            try std.fmt.allocPrint(s.gpa, "stopped after {d} step{s}", .{ max_steps, if (max_steps == 1) "" else "s" });
        return error.TooManySteps;
    }

    fn runSteps(s: *Session, pending: *std.ArrayList(provider.Message), partial: *Partial, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8) !void {
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
            const step_effort: provider.StepEffort = .{ .effort = s.cfg.loggedEffort() };
            try sink.emit(sink.ctx, .{ .step = .{ .n = s.steps + 1, .effort = step_effort.effort } });
            const started: std.Io.Clock.Timestamp = .now(s.io, .awake);
            var model_timing: provider.ModelTiming = .init(s.io, started);
            var attempts: u32 = 0;
            var first_data_ms: ?u64 = null;
            const buffer_text = s.tools.background.pending(s.io);
            const reply = try s.complete(s.cfg, request.items, sink, cancel, detail, partial, &model_timing, &attempts, &first_data_ms, buffer_text);
            var waiting = reply.tool_calls.len == 0 and s.tools.background.pending(s.io);
            if (waiting) {
                try sink.emit(sink.ctx, .{ .notice = if (reply.text.len > 0) reply.text else "Waiting for background results." });
            } else if (buffer_text and reply.text.len > 0) {
                try sink.emit(sink.ctx, .{ .delta = .{ .kind = .text, .text = reply.text } });
            }
            const model_ms: u64 = @intCast(@max(started.untilNow(s.io).raw.toMilliseconds(), 0));
            var run_timing: sandbox.RunTiming = .init(s.io, started);
            var run_ms: u64 = 0;
            partial.clear();
            s.usage.add(reply.usage);
            try sink.emit(sink.ctx, .{ .usage = s.usage });
            s.steps += 1;
            const assistant_index = pending.items.len;
            try pending.append(s.gpa, .{
                .role = "assistant",
                .content = reply.text,
                .tool_calls = if (reply.tool_calls.len > 0) reply.tool_calls else null,
                .reasoning = reply.reasoning,
                .phase = reply.phase,
                .waiting = if (waiting) true else null,
                .step_effort = step_effort,
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
                    .custom_provider = s.cfg.custom_provider,
                    .model = s.cfg.model,
                    .thinking = s.cfg.thinking,
                    .reasoning_effort = s.cfg.reasoning_effort,
                    .file_versions = fork_versions.?,
                };
            }
            defer s.tools.fork_snapshot = null;
            var run_results: std.ArrayList(session_log.RunResult) = .empty;
            defer run_results.deinit(s.gpa);
            var output_tokens: u64 = 0;
            var empty_runs = reply.tool_calls.len > 0;
            for (reply.tool_calls, 0..) |call, run_index| {
                run_timing.run_index = run_index;
                const before_bytes = run_timing.tool_bytes;
                const before_omitted = run_timing.omitted;
                const result = try s.execute(call, sink, cancel, &run_timing);
                empty_runs = empty_runs and result.ok and result.empty and result.background_id == null and
                    result.tool_summary != null and result.tool_summary.?.counts.len == 0 and result.tool_summary.?.omitted == 0;
                run_timing.output_bytes += result.output.len;
                run_ms += result.run_ms orelse 0;
                try sink.emit(sink.ctx, .{ .usage = s.usage });
                try pending.append(s.gpa, .{ .role = "tool", .content = result.output, .tool_call_id = call.id, .background_id = result.background_id, .run_ok = if (result.background_id == null) result.ok else null, .tool_summary = result.tool_summary, .images = if (result.images.len > 0) result.images else null });
                try run_results.append(s.gpa, .{
                    .tool_call_id = call.id,
                    .background_id = result.background_id,
                    .ok = if (result.background_id != null) null else result.ok,
                    .run_ms = result.run_ms,
                    .tool_bytes = run_timing.tool_bytes - before_bytes,
                    .calls_omitted = run_timing.omitted - before_omitted,
                    .output_bytes = result.output.len,
                    .remaining_steps = result.remaining_steps,
                });
                output_tokens += result.output.len / 3 + 1 + result.images.len * @import("image.zig").estimated_tokens;
            }
            if (empty_runs and s.tools.background.pending(s.io)) {
                waiting = true;
                pending.items[assistant_index].waiting = true;
                try sink.emit(sink.ctx, .{ .notice = "Waiting for background results." });
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
                .transport = @tagName(s.codex_state.last.transport),
                .incremental = s.codex_state.last.incremental,
                .input_items = if (s.codex_state.last.transport == .websocket) s.codex_state.last.input_items else null,
                .input_bytes = if (s.codex_state.last.transport == .websocket) s.codex_state.last.input_bytes else null,
                .transport_fallback = s.codex_state.last.fallback_reason,
                .transport_fallback_at = s.codex_state.last.fallback_at,
                .transport_fallback_detail = s.codex_state.last.fallback_detail,
                .full_reason = s.codex_state.last.full_reason,
                .mismatch_index = s.codex_state.last.mismatch_index,
                .model_attempts = model_timing.attempts[0..model_timing.attempt_count],
                .max_content_gap_ms = model_timing.max_content_gap_ms,
                .effort = step_effort.effort,
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
            if (reply.tool_calls.len == 0 or waiting) {
                if (!s.tools.background.pending(s.io)) return;
                if (s.cfg.limits.max_steps) |max_steps| {
                    if (s.steps >= max_steps) continue;
                }
                try sink.modelActivity(.waiting);
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

    fn complete(s: *Session, request_cfg: provider.Config, messages: []const provider.Message, sink: Sink, cancel: *const std.atomic.Value(bool), detail: *?[]u8, partial: *Partial, timing: *provider.ModelTiming, attempts: *u32, first_data_ms: *?u64, buffer_text: bool) !provider.Reply {
        const Forward = struct {
            mutex: std.Io.Mutex = .init,
            sink: Sink,
            gpa: std.mem.Allocator,
            partial: *Partial,
            io: std.Io,
            started: std.Io.Clock.Timestamp,
            first_data_ms: *?u64,
            session: *Session,
            buffer_text: bool,
            timing: *provider.ModelTiming,
            fn onData(ctx: *anyopaque) !void {
                const f: *@This() = @ptrCast(@alignCast(ctx));
                f.mutex.lockUncancelable(f.io);
                defer f.mutex.unlock(f.io);
                if (f.first_data_ms.* == null) f.first_data_ms.* = @intCast(@max(f.started.untilNow(f.io).raw.toMilliseconds(), 0));
            }
            fn onToolArguments(ctx: *anyopaque) !void {
                const f: *@This() = @ptrCast(@alignCast(ctx));
                f.mutex.lockUncancelable(f.io);
                defer f.mutex.unlock(f.io);
                try f.sink.modelActivity(.script);
            }
            fn onDelta(ctx: *anyopaque, kind: provider.Kind, text: []const u8) !void {
                const f: *@This() = @ptrCast(@alignCast(ctx));
                f.mutex.lockUncancelable(f.io);
                defer f.mutex.unlock(f.io);
                if (text.len > 0) try f.sink.modelActivity(.data);
                try (if (kind == .text) &f.partial.text else &f.partial.reasoning).appendSlice(f.gpa, text);
                if (!f.buffer_text or kind != .text) try f.sink.emit(f.sink.ctx, .{ .delta = .{ .kind = kind, .text = text } });
            }
            fn onFallback(ctx: *anyopaque, info: @import("provider/codex_ws.zig").Info) !void {
                const f: *@This() = @ptrCast(@alignCast(ctx));
                try f.session.log.fallback(f.io, f.gpa, info, f.session.steps + 1);
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
                            .model_attempts = f.timing.attempts[0..f.timing.attempt_count],
                        });
                    },
                }
            }
        };
        var fwd: Forward = .{ .sink = sink, .gpa = s.gpa, .partial = partial, .io = s.io, .started = timing.started, .first_data_ms = first_data_ms, .session = s, .buffer_text = buffer_text, .timing = timing };
        const provider_sink: provider.Sink = .{ .ctx = &fwd, .onDelta = Forward.onDelta, .onData = Forward.onData, .onToolArguments = Forward.onToolArguments, .onFallback = Forward.onFallback, .timing = timing, .codex_state = &s.codex_state };
        if (!s.tools.background.anyPending(s.io))
            return provider.complete(s.gpa, s.arena.allocator(), s.client, request_cfg, s.cache_key, messages, prompt.tools_json, s.cfg.sessionMaxTokens(), provider_sink, cancel, detail, attempts, .{ .ctx = &fwd, .onEvent = Forward.onRetry });
        const Request = struct {
            fn work(session: *Session, cfg: provider.Config, history: []const provider.Message, ps: provider.Sink, flag: *const std.atomic.Value(bool), failure: *?[]u8, tries: *u32, observer: *Forward, done: *std.Io.Event) !provider.Reply {
                defer done.set(session.io);
                return provider.complete(session.gpa, session.arena.allocator(), session.client, cfg, session.cache_key, history, prompt.tools_json, session.cfg.sessionMaxTokens(), ps, flag, failure, tries, .{ .ctx = observer, .onEvent = Forward.onRetry });
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
    const fork: Fork = .{ .session = "parent-session", .message_count = messages.len, .history = &messages, .cache_key = "root-cache-key", .id = "a2", .provider = cfg.provider, .custom_provider = cfg.custom_provider, .model = cfg.model };
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

test "switchConfig updates a zero-Step Session in place and replaces one with Steps" {
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

    var next = cfg;
    next.model = "other";
    const id = try a.dupe(u8, session.id);
    try t.expect(session.switchConfig(next) == .updated);
    try t.expectEqualStrings(id, session.id);
    try t.expectEqualStrings("other", session.cfg.model);
    try t.expectEqualStrings("other", session.tools.cfg.?.model);
    try t.expectEqualStrings("other", session.log.model.?);

    try session.commit(session.history.items.len, &.{ .{ .role = "user", .content = "hi" }, .{ .role = "assistant", .content = "yo" } }, 10, null);
    try t.expect(session.log.steps > 0);
    next.model = "third";
    try t.expect(session.switchConfig(next) == .new_session);
    try t.expect(!std.mem.eql(u8, id, session.id));
    try t.expectEqual(@as(usize, 0), session.log.steps);
    try t.expectEqualStrings("third", session.cfg.model);
}

test "switchConfig keeps the previous config when the new Session cannot open" {
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
    try session.commit(session.history.items.len, &.{ .{ .role = "user", .content = "hi" }, .{ .role = "assistant", .content = "yo" } }, 10, null);
    try tmp.dir.deleteTree(t.io, "sessions");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sessions", .data = "not a directory" });
    var next = cfg;
    next.model = "other";
    const id = try a.dupe(u8, session.id);
    try t.expect(session.switchConfig(next) == .open_failed);
    try t.expectEqualStrings("mock", session.cfg.model);
    try t.expectEqualStrings(id, session.id);
}

test "dropStoredKey clears only a key from the store" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const root = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
    defer client.deinit();
    const cfg: provider.Config = .{ .base_url = "invalid://local", .api_key = "mock", .model = "mock", .key_source = .env };
    var session = try Session.init(t.allocator, t.io, &client, cfg, .{ .home = root, .user_home = root });
    defer session.deinit();
    session.dropStoredKey();
    try t.expectEqualStrings("mock", session.tools.cfg.?.api_key);
    session.cfg.key_source = .store;
    session.dropStoredKey();
    try t.expectEqualStrings("", session.cfg.api_key);
    try t.expectEqualStrings("", session.tools.cfg.?.api_key);
}
