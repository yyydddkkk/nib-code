const std = @import("std");
const sandbox = @import("sandbox.zig");
const provider = @import("provider.zig");
const config = @import("config.zig");
const tui = @import("tui.zig");
const JsonEvent = @import("session/events.zig").JsonEvent;
const Session = @import("session.zig").Session;
const Event = @import("session.zig").Event;

pub fn main(init: std.process.Init) void {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var failure: JsonEvent.Failure = .{};
    var detail: ?[]u8 = null;
    defer if (detail) |d| init.gpa.free(d);
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        std.process.exit(1);
    };
    const json = args.len > 1 and std.mem.eql(u8, args[1], "ask") and for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) break true;
    } else false;
    run(init, args, &out.interface, json, &detail, &failure) catch |err| {
        if (json) {
            failure.message = detail orelse switch (err) {
                error.MissingPrompt, error.InvalidArguments => @errorName(err),
                else => errorMessage(err),
            };
            JsonEvent.write(.{ .@"error" = failure }, &out.interface) catch {};
        } else std.debug.print("nib: {s}\n", .{detail orelse errorMessage(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init, args: []const []const u8, stdout: *std.Io.Writer, json: bool, detail: *?[]u8, failure: *JsonEvent.Failure) !void {
    const gpa = init.gpa;
    if (args.len > 1 and std.mem.eql(u8, args[1], @import("tools/bash/jail.zig").helper_command)) {
        @import("tools/bash/jail.zig").helper(init.io, args[2..]) catch |err| {
            std.debug.print("nib: sandbox: {s}\n", .{@errorName(err)});
            std.process.exit(126);
        };
        std.process.exit(126);
    }
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.writeAll(help);
            var config_detail: ?[]u8 = null;
            const active: ?provider.Config = blk: {
                const home_path = config.home(init.arena.allocator(), init.environ_map) catch break :blk null;
                break :blk config.load(init.arena.allocator(), init.io, init.environ_map, home_path, &config_detail) catch null;
            };
            if (active) |cfg| try stdout.print("Active provider: {s}\n", .{cfg.name()}) else try stdout.writeAll("Active provider: unavailable (invalid configuration)\n");
            return stdout.flush();
        }
    }
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-V"))) {
        try stdout.print("nib {s}\n", .{@import("build_options").version});
        return stdout.flush();
    }
    if (args.len > 1 and (std.mem.eql(u8, args[1], "login") or std.mem.eql(u8, args[1], "logout"))) {
        const cli = @import("auth/cli.zig");
        return if (args[1].len == 5) cli.login(init, args[2..], stdout) else cli.logout(init, args[2..], stdout);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "replay")) {
        return @import("replay.zig").run(init, args[2..], stdout);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "plugin")) return @import("plugin.zig").cli(init, args[2..], stdout);
    if (args.len > 1 and std.mem.eql(u8, args[1], "update")) return @import("update.zig").run(init, args[2..], stdout, detail);
    const js = args.len >= 3 and std.mem.eql(u8, args[1], "js");

    var options: Session.Options = .{
        .environ = init.environ_map,
        .depth = if (init.environ_map.get("NIB_AGENT_DEPTH")) |v| try std.fmt.parseInt(u32, v, 10) else 0,
        .parent_session_id = init.environ_map.get("NIB_PARENT_SESSION_ID"),
        .home = try config.home(init.arena.allocator(), init.environ_map),
        .user_home = init.environ_map.get("HOME") orelse "",
    };
    var effort: ?[]const u8 = null;
    var agent_input = false;
    var ask = false;
    var prompt: ?[]const u8 = null;
    var i: usize = if (js) args.len else 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!ask and std.mem.eql(u8, arg, "ask")) {
            ask = true;
        } else if (ask and std.mem.eql(u8, arg, "--agent-input")) {
            agent_input = true;
        } else if (ask and std.mem.eql(u8, arg, "--json")) {} else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--continue")) {
            options.continue_latest = true;
        } else if (std.mem.eql(u8, arg, "--effort")) {
            i += 1;
            if (i == args.len) return error.MissingReasoningEffort;
            effort = args[i];
        } else if (std.mem.eql(u8, arg, "--resume")) {
            i += 1;
            if (i == args.len) return error.MissingSessionId;
            options.resume_id = args[i];
        } else if (arg.len > 1 and arg[0] == '-') {
            detail.* = try std.fmt.allocPrint(gpa, "Unknown option: {s} · run nib --help", .{arg});
            return error.InvalidArguments;
        } else if (ask and prompt == null) {
            prompt = arg;
        } else return error.InvalidArguments;
    }
    if (options.continue_latest and options.resume_id != null) return error.ConflictingResumeOptions;
    if (ask and prompt == null) return error.MissingPrompt;

    var client: std.http.Client = .{ .allocator = gpa, .io = init.io };
    defer client.deinit();
    try client.initDefaultProxies(init.arena.allocator(), init.environ_map);

    var cfg: provider.Config = undefined;
    if (agent_input) {
        var input = std.Io.File.stdin().reader(init.io, &.{});
        const data = try input.interface.allocRemaining(init.arena.allocator(), .unlimited);
        const envelope = try std.json.parseFromSliceLeaky(@import("tools/agent/input.zig").Input, init.arena.allocator(), data, .{});
        cfg = envelope.config;
        if (cfg.api_key_env) |key_env| cfg.api_key = init.environ_map.get(key_env) orelse "";
        try config.applyStore(init.arena.allocator(), init.io, options.home, &cfg);
        prompt = envelope.prompt;
        options.fork = envelope.fork;
        options.undo_dir = envelope.undo_dir;
    } else {
        var config_detail: ?[]u8 = null;
        cfg = config.load(init.arena.allocator(), init.io, init.environ_map, options.home, &config_detail) catch |err| {
            if (config_detail) |message| detail.* = try gpa.dupe(u8, message);
            return err;
        };
    }
    if (js) {
        const r = try sandbox.eval(gpa, init.io, args[2], .{}, null, null);
        defer r.deinit(gpa);
        try stdout.print("{s}{s}{s}\n", .{ r.logs, if (r.ok) "" else "error: ", r.text });
        try stdout.flush();
        if (!r.ok) return error.ScriptFailed;
        return;
    }
    if (effort) |value| try cfg.setEffort(value);
    if (ask and !config.credentialed(init.arena.allocator(), init.io, cfg)) {
        const explicit = init.environ_map.get("NIB_PROVIDER") != null;
        if (!explicit) {
            detail.* = try gpa.dupe(u8, "No provider · run nib login");
        } else if (cfg.provider == .codex) {
            detail.* = try gpa.dupe(u8, "codex: not signed in; run nib login codex.");
        } else {
            detail.* = try std.fmt.allocPrint(gpa, "{s}: no API key; set {s} or run nib login {s}.", .{ cfg.name(), cfg.api_key_env orelse "the provider key environment variable", cfg.name() });
        }
        return error.MissingApiKey;
    }
    options.undo_enabled = !ask;
    var session = try Session.init(gpa, init.io, &client, cfg, options);
    defer session.deinit();
    defer {
        failure.usage = session.usage;
        failure.steps = session.steps;
        if (session.summary) |summary| failure.timing = summary.timing;
    }

    if (ask) {
        const Print = struct {
            w: *std.Io.Writer,
            json: bool,
            fn emit(ctx: *anyopaque, ev: Event) !void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                if (ev == .turn_end) return;
                if (self.json) return JsonEvent.write(.{ .event = ev }, self.w);
                switch (ev) {
                    .delta => |d| if (d.kind == .text) {
                        try self.w.writeAll(d.text);
                        try self.w.flush();
                    },
                    .run_start => |code| std.debug.print("\n\x1b[33mrun ▸\x1b[0m {s}\n", .{code}),
                    .run_end => |r| {
                        std.debug.print("\x1b[2m{s}\x1b[0m\n", .{r.output});
                        for (r.changes) |c| std.debug.print("\x1b[2mchanged {s}{s} +{d} −{d}\x1b[0m\n", .{ c.path, if (c.created) " (new)" else "", c.added, c.removed });
                    },
                    .retry => |r| std.debug.print("\x1b[2mretry {d} in {d}s: {s}\x1b[0m\n", .{ r.attempt, r.delay_ms / 1000, r.reason }),
                    .step, .usage, .progress, .background, .turn_end => {},
                    .notice => |m| std.debug.print("\x1b[2m{s}\x1b[0m\n", .{m}),
                }
            }
        };
        if (!agent_input and std.mem.eql(u8, prompt.?, "-")) {
            var input = std.Io.File.stdin().reader(init.io, &.{});
            prompt = try input.interface.allocRemaining(init.arena.allocator(), .unlimited);
        }
        if (json) try JsonEvent.write(.{ .start = .{ .session_id = session.id } }, stdout);
        var p: Print = .{ .w = stdout, .json = json };
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
        session.interrupt_signal = &ask_signal;
        std.posix.sigaction(.TERM, &action, null);
        std.posix.sigaction(.INT, &action, null);
        var hook_status: []const u8 = "failed";
        defer @import("session/hooks.zig").TurnJob.start(&session, hook_status, null) catch {};
        errdefer if (ask_cancel.load(.acquire)) {
            hook_status = "cancelled";
        };
        try session.turn(prompt.?, .{ .ctx = &p, .emit = Print.emit }, &ask_cancel, detail);
        hook_status = "completed";
        if (json) {
            try JsonEvent.write(.{ .end = .{
                .text = session.history.items[session.history.items.len - 1].content orelse "",
                .usage = session.usage,
                .steps = session.steps,
                .timing = session.summary.?.timing,
            } }, stdout);
            return;
        }
        try stdout.print("\n", .{});
        try stdout.flush();
        const u = session.usage;
        std.debug.print("[{s}] turn: {d} step{s}, in={d} (cache hit {d}) out={d}\n", .{
            cfg.model, session.steps, if (session.steps == 1) "" else "s", u.prompt_tokens, u.prompt_cache_hit_tokens, u.completion_tokens,
        });
        return;
    }

    try tui.run(init, &session);
}

const help =
    \\nib · a coding agent whose unit of work is a Run
    \\
    \\Usage:
    \\  nib [options]                         Open the TUI
    \\  nib ask [options] <prompt|->           Ask once; - reads stdin
    \\  nib js <code>                         Run sandbox JavaScript
    \\  nib login [service] [--device]        Sign in or store a key; no service lists them
    \\  nib plugin [list|install|uninstall|on|off] Manage extension packages
    \\  nib update [version]                  Upgrade in place
    \\  nib logout <service>                  Remove nib's stored credential
    \\  nib replay <session-id> --all [--json] Replay recorded Runs offline
    \\
    \\Options:
    \\  -h, --help            Show help
    \\  -V, --version         Show version
    \\  -c, --continue        Continue this directory's latest session
    \\  --resume <id>         Resume a session (32 lowercase hex characters)
    \\  --effort <level>      Set reasoning effort; /effort lists levels
    \\  --json                Stream NDJSON events (ask only)
    \\
    \\TUI: Enter sends · Shift+Enter adds a line · Esc cancels · Ctrl+O opens latest details · click a Run
    \\Type / for commands, /help for keys, /status for timing and cache details.
    \\First run: nib, then /provider to sign in; /model picks a model.
    \\Setup: see README.md and docs/config.md.
    \\
;

var ask_cancel: std.atomic.Value(bool) = .init(false);

var ask_signal: std.atomic.Value(std.posix.SIG) = .init(.INT);

fn onSignal(signal: std.posix.SIG) callconv(.c) void {
    ask_signal.store(signal, .release);
    ask_cancel.store(true, .release);
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArguments => "Invalid arguments · run nib --help",
        error.MissingPrompt => "Missing prompt · run nib --help",
        error.AgentSessionParentMismatch => "Cannot continue a session that is not a child of this parent session.",
        error.SessionBusy => "Session is busy in another process; wait for its current task to finish.",
        error.InvalidSessionId => "Session ID must be exactly 32 lowercase hexadecimal characters.",
        error.InvalidReplayArguments => "Use nib replay <session-id> --run <step>:<run> [--script <file>] [--json], or nib replay <session-id> --all [--json].",
        error.ReplayMetadataNotFound => "No replay recording found for this Run; recording must be enabled when the original Run executes.",
        error.ReplayRunNotFound => "Run not found; step counts assistant messages across the entire session (1-based), run indexes tool_calls (0-based).",
        error.InvalidReasoningEffort, error.MissingReasoningEffort => "Use --effort default|off|none|minimal|low|medium|high|xhigh|max (model support varies).",
        error.UnknownService => "Unknown service · run nib login to list services",
        error.EmptyKey => "API key cannot be empty",
        error.SessionProviderMismatch => "Cannot resume this session with a different provider; use its original NIB_PROVIDER or start a new session.",
        error.SessionModelMismatch => "Cannot fork this session with a different model; use the parent session's model.",
        error.UnknownCodexModelContextWindow => "Unknown Codex model context window; set NIB_CONTEXT_WINDOW explicitly (see pi model catalog).",
        else => @errorName(err),
    };
}

test {
    _ = @import("replay.zig");
    _ = @import("auth.zig");
    _ = @import("auth/store.zig");
    _ = @import("auth/oauth.zig");
    _ = @import("auth/codex.zig");
    _ = @import("auth/login.zig");
    _ = @import("auth/models.zig");
    _ = @import("auth/cli.zig");
    _ = sandbox;
    _ = provider;
    _ = config;
    _ = @import("provider/sse.zig");
    _ = @import("tools.zig");
    _ = @import("tools/policy.zig");
    _ = @import("tools/process.zig");
    _ = @import("tools/walk.zig");
    _ = @import("tools/regex.zig");
    _ = @import("tools/grep.zig");
    _ = @import("tools/html.zig");
    _ = @import("tools/diff.zig");
    _ = @import("tui/editor.zig");
    _ = @import("tui/commands.zig");
    _ = @import("tui/reflect.zig");
    _ = @import("tui/transcript.zig");
    _ = @import("tui/viewport.zig");
    _ = @import("tui/menu.zig");
    _ = @import("tui/provider_flow.zig");
    _ = @import("tui/providers.zig");
    _ = @import("tui/status.zig");
    _ = @import("tui/view.zig");
    _ = @import("tui/selection.zig");
    _ = @import("session.zig");
    _ = @import("session/profile.zig");
    _ = @import("update.zig");
}
