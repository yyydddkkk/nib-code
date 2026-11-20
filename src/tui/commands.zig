const mode = @import("mode.zig");
const std = @import("std");
const App = @import("../tui.zig").App;
const Turn = @import("turn.zig").Turn;
const reflect = @import("reflect.zig");
const config = @import("../config.zig");
const ChangeText = @import("transcript.zig").ChangeText;
const provider = @import("../provider.zig");
const auth = @import("../auth.zig");
const providers = @import("providers.zig");

pub const Command = enum { simple, help, new, @"resume", compact, undo, provider, model, effort, fast, copy, reflect, js, tasks, stop, status, skills, mcp, plugins };

pub const Choices = enum { none, models, efforts, sessions, tasks, services };

pub const Group = enum { send, view, session };

pub const Spec = struct {
    group: Group = .session,
    args: []const u8 = "",
    help: []const u8,
    /// Usable while a Turn is running.
    while_busy: bool = false,
    choices: Choices = .none,
    /// Accepting the bare command waits for an argument instead of running.
    needs_arg: bool = false,
};

pub const specs = std.enums.EnumArray(Command, Spec).init(.{
    .simple = .{ .group = .view, .help = "toggle " ++ mode.name ++ " mode", .while_busy = true },
    .mcp = .{ .group = .view, .args = "[on|off <id>]", .help = "list or enable MCP servers for new sessions" },
    .plugins = .{ .group = .view, .args = "[on|off <name>]", .help = "list or enable plugins for new sessions" },
    .skills = .{ .group = .view, .args = "[on|off <name>]", .help = "list or enable skills for new sessions" },
    .status = .{ .group = .view, .help = "timing and cache details", .while_busy = true },
    .tasks = .{ .group = .view, .help = "background tasks", .while_busy = true },
    .stop = .{ .args = "<id>", .help = "stop a task; changes may remain", .while_busy = true, .choices = .tasks, .needs_arg = true },
    .help = .{ .group = .view, .help = "commands and keys", .while_busy = true },
    .new = .{ .help = "new session" },
    .@"resume" = .{ .args = "<id>", .help = "resume a session", .choices = .sessions, .needs_arg = true },
    .undo = .{ .help = "undo last edited Turn; edit/write only", .while_busy = true },
    .compact = .{ .args = "[focus]", .help = "compact earlier history" },
    .provider = .{ .args = "[service]", .help = "sign in and switch service", .choices = .services, .needs_arg = true },
    .model = .{ .args = "<model>", .help = "switch model and service", .choices = .models, .needs_arg = true },
    .effort = .{ .group = .send, .args = "[level]", .help = "reasoning effort", .choices = .efforts },
    .fast = .{ .group = .send, .help = "toggle Codex Fast mode" },
    .copy = .{ .group = .view, .help = "copy last answer", .while_busy = true },
    .reflect = .{ .args = "[focus]", .help = "publish issue drafts" },
    .js = .{ .group = .send, .args = "<code>", .help = "run JavaScript", .needs_arg = true },
});

pub const keys = "Enter send · Shift+Enter newline · Esc cancel\n" ++ mode.shortcut ++ " simple mode · Ctrl+O latest details · click a block summary for details\nPgUp/PgDn scroll · ↑ input history · Ctrl+C twice to quit";

const slash_names = blk: {
    var names: [std.enums.values(Command).len][]const u8 = undefined;
    for (std.enums.values(Command), &names) |c, *n| n.* = if (c == .simple) "/" ++ mode.command else "/" ++ @tagName(c);
    const final = names;
    break :blk final;
};

pub fn slashName(c: Command) []const u8 {
    return slash_names[@backingInt(c)];
}

pub const Parsed = union(enum) {
    known: struct { command: Command, arg: []const u8 },
    unknown: []const u8,
};

/// null for ordinary messages, including ones that start with a path like `/etc/hosts`.
pub fn parse(line: []const u8) ?Parsed {
    if (line.len < 2 or line[0] != '/') return null;
    const end = std.mem.indexOfAny(u8, line, " \t\n") orelse line.len;
    const name = line[1..end];
    if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
    const command = (if (std.mem.eql(u8, name, mode.command)) Command.simple else std.meta.stringToEnum(Command, name)) orelse return .{ .unknown = name };
    return .{ .known = .{ .command = command, .arg = std.mem.trim(u8, line[end..], " \t\n") } };
}

pub fn allowedWhileBusy(line: []const u8) bool {
    const parsed = parse(line) orelse return false;
    return switch (parsed) {
        .known => |c| specs.get(c.command).while_busy,
        .unknown => false,
    };
}

pub const Choice = struct {
    value: []const u8,
    label: []const u8,
    detail: []const u8,
    service: ?[]const u8 = null,
};

pub const Candidate = struct {
    command: Command,
    /// Set when this is an argument choice rather than the command itself.
    value: ?[]const u8 = null,
    label: []const u8,
    detail: []const u8,
    service: ?[]const u8 = null,
    /// An `@` file completion: `value` is the text that replaces the mention.
    is_path: bool = false,

    pub fn group(c: Candidate) ?Group {
        return if (c.value == null) specs.get(c.command).group else null;
    }

    /// What accepting it with Tab leaves in the input.
    pub fn completion(c: Candidate, gpa: std.mem.Allocator) ![]u8 {
        if (c.value) |v| return std.fmt.allocPrint(gpa, "{s} {s}", .{ slashName(c.command), v });
        const spec = specs.get(c.command);
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ slashName(c.command), if (spec.args.len > 0) " " else "" });
    }

    /// Whether Enter on it runs the command now instead of waiting for an argument.
    pub fn runs(c: Candidate) bool {
        return c.value != null or !specs.get(c.command).needs_arg;
    }

    /// The line Enter submits when `runs()`.
    pub fn line(c: Candidate, gpa: std.mem.Allocator) ![]u8 {
        if (c.value) |v| return std.fmt.allocPrint(gpa, "{s} {s}", .{ slashName(c.command), v });
        return gpa.dupe(u8, slashName(c.command));
    }
};

pub const effort_choices = blk: {
    var choices: [provider.Config.effort_values.len]Choice = undefined;
    for (provider.Config.effort_values, &choices) |v, *c| c.* = .{ .value = v, .label = v, .detail = "" };
    const final = choices;
    break :blk final;
};

/// Prefix matches for `input`: command names before the first space,
/// then argument choices for commands that have them.
pub fn candidates(input: []const u8, sessions: []const Choice, tasks: []const Choice, models: []const Choice, services: []const Choice, out: []Candidate) []Candidate {
    if (input.len == 0 or input[0] != '/' or std.mem.indexOfScalar(u8, input, '\n') != null) return out[0..0];
    var n: usize = 0;
    const space = std.mem.indexOfScalar(u8, input, ' ') orelse {
        const prefix = input[1..];
        for (std.enums.values(Group)) |group| {
            for (std.enums.values(Command)) |c| {
                if (n == out.len) return out[0..n];
                if (specs.get(c).group != group) continue;
                if (!std.mem.startsWith(u8, @tagName(c), prefix)) continue;
                const spec = specs.get(c);
                out[n] = .{ .command = c, .label = slashName(c), .detail = spec.help };
                n += 1;
            }
        }
        return out[0..n];
    };
    const command = std.meta.stringToEnum(Command, input[1..space]) orelse return out[0..0];
    const arg = std.mem.trimStart(u8, input[space + 1 ..], " ");
    const choices: []const Choice = switch (specs.get(command).choices) {
        .none => return out[0..0],
        .efforts => &effort_choices,
        .sessions => sessions,
        .tasks => tasks,
        .models => models,
        .services => services,
    };
    for (choices) |choice| {
        if (n == out.len) break;
        const model = if (command == .model) choice.value[(if (std.mem.indexOfScalar(u8, choice.value, '/')) |slash| slash + 1 else 0)..] else "";
        if (!std.mem.startsWith(u8, choice.value, arg) and !(command == .model and std.mem.startsWith(u8, model, arg))) continue;
        out[n] = .{ .command = command, .value = choice.value, .label = choice.label, .detail = choice.detail, .service = choice.service };
        n += 1;
    }
    return out[0..n];
}

pub fn groupName(group: Group) []const u8 {
    return switch (group) {
        .send => "Send",
        .view => "View",
        .session => "Session",
    };
}

pub fn reflectHelp(buf: []u8, repo: ?[]const u8) []const u8 {
    return if (repo) |r| std.fmt.bufPrint(buf, "publish issue drafts: {s}", .{r}) catch "publish issue drafts (see /help)" else "review session · issue publishing off";
}

pub fn helpText(gpa: std.mem.Allocator, issue_repo: ?[]const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var reflect_buf: [512]u8 = undefined;
    for (std.enums.values(Group)) |group| {
        try text.print(gpa, "{s}\n", .{groupName(group)});
        for (std.enums.values(Command)) |c| {
            const spec = specs.get(c);
            if (spec.group != group or (c == .reflect and issue_repo == null)) continue;
            try text.print(gpa, "  {s}{s}{s} · {s}\n", .{ slashName(c), if (spec.args.len > 0) " " else "", spec.args, if (c == .reflect) reflectHelp(&reflect_buf, issue_repo) else spec.help });
        }
        try text.append(gpa, '\n');
    }
    try text.appendSlice(gpa, keys);
    return text.toOwnedSlice(gpa);
}

const testing = std.testing;

/// A bare word is a model of the current service; `service/model` and `service model` still select a service too.
fn modelSelection(app: *App, arg: []const u8) !config.ModelSelection {
    var words = std.mem.tokenizeAny(u8, arg, " \t\n");
    const first = words.next() orelse return error.InvalidModelArgument;
    const second = words.next();
    if (second != null) return config.parseModel(arg);
    if (std.mem.indexOfScalar(u8, first, '/')) |slash| {
        for (provider.definitions) |entry| {
            if (std.mem.eql(u8, first[0..slash], entry.id)) return config.parseModel(arg);
        }
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        if (slash > 0 and slash + 1 < first.len) {
            const list = config.customProviders(arena.allocator(), app.io, app.session.options.home) catch &.{};
            for (list) |item| {
                if (std.mem.eql(u8, item.id, first[0..slash])) return config.parseModel(arg);
            }
        }
    }
    return .{ .provider = app.cfg.name(), .model = first };
}

/// Saves and applies a service/model choice; a new Session starts when Steps already exist.
/// `note` replaces the confirmation line's service/model text.
pub fn select(app: *App, selection: config.ModelSelection, note: ?[]const u8) !void {
    const gpa = app.gpa;
    const session = app.session;
    const a = app.config_allocator orelse gpa;
    var cfg = config.saveModel(a, app.io, app.environ, session.options.home, selection) catch |err| {
        return app.report(.err, "could not select model: {s} · check provider and context_window", .{@errorName(err)});
    };
    cfg.thinking = app.cfg.thinking;
    cfg.reasoning_effort = app.cfg.reasoning_effort;
    app.dropPrediction();
    const fresh = switch (session.switchConfig(cfg)) {
        .updated => false,
        .new_session => true,
        .open_failed => |err| return app.report(.err, "could not open session: {s}", .{@errorName(err)}),
        .update_failed => |err| return app.report(.err, "model saved, but could not update session: {s}", .{@errorName(err)}),
    };
    if (fresh) {
        app.transcript.clear(gpa);
        app.background_count = 0;
        app.usage = .{};
        app.steps = 0;
        app.last_summary = null;
    }
    app.cfg = session.cfg;
    app.context = session.context_tokens;
    app.refreshCredentials();
    const override = if (app.environ.get("NIB_PROVIDER") != null and app.environ.get("NIB_MODEL") != null) " · NIB_PROVIDER/NIB_MODEL override at startup" else if (app.environ.get("NIB_PROVIDER") != null) " · NIB_PROVIDER overrides at startup" else if (app.environ.get("NIB_MODEL") != null) " · NIB_MODEL overrides at startup" else "";
    const fast = if (fresh and !app.signed_out and cfg.codexServiceTier() != null) " · Fast" else "";
    if (note) |text| {
        try app.report(.info, "{s}{s}{s}{s}", .{ text, if (fresh) " · new session" else "", fast, override });
    } else try app.report(.info, "{s} · {s}{s}{s}{s}", .{ cfg.name(), cfg.model, if (fresh) " · new session" else "", fast, override });
}

pub fn execute(app: *App, c: Command, arg: []const u8, line: []const u8) !void {
    if (c == .reflect and reflect.issueRepo(app) == null) return app.report(.err, "unknown command /reflect · /help lists commands", .{});
    const gpa = app.gpa;
    const session = app.session;
    switch (c) {
        .simple => try app.toggleSimple(),
        .status => {
            if (app.cfg.codexServiceTier() != null) try app.report(.info, "Fast requested", .{});
            const skills = session.log.skills;
            var suffix: std.ArrayList(u8) = .empty;
            defer suffix.deinit(gpa);
            if (skills.skipped.len > 0) try suffix.print(gpa, " · {d} invalid/skipped", .{skills.skipped.len});
            if (skills.missing > 0) try suffix.print(gpa, " · {d} missing", .{skills.missing});
            try app.report(.info, "Skills: {d} on · {d} found{s}", .{ skills.count, skills.found, suffix.items });
            if (app.cfg.hooks.after_edit.len + app.cfg.hooks.turn_end.len > 0) try app.report(.info, "Hooks: after_edit {d} · turn_end {d}", .{ app.cfg.hooks.after_edit.len, app.cfg.hooks.turn_end.len });
            try app.report(.info, "Sandbox: {s}", .{session.tools.sandboxStatus()});
            var text: @import("bill.zig").Text = .{};
            var credential_arena: std.heap.ArenaAllocator = .init(gpa);
            defer credential_arena.deinit();
            const arena_a = credential_arena.allocator();
            const resume_line = if (session.log.resume_adaptation.notice(app.cfg.model)) |profile|
                try std.fmt.allocPrint(arena_a, "{s} · retained session Profile: {s}\n", .{ app.cfg.model, profile })
            else
                "";
            try app.report(.info, "Provider {s} · {s} · {s} · effort {s} · context {d}%\n{s}{s}", .{ app.cfg.name(), app.cfg.model, auth.describe(arena_a, app.io, app.cfg), app.cfg.effectiveEffort(), app.context * 100 / @max(app.cfg.context_window, 1), resume_line, if (app.last_summary) |summary| text.details(summary, app.last_turn_runs) else "No completed turn yet." });
        },
        .plugins => {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const plugin = @import("../plugin.zig");
            if (arg.len == 0) return app.report(.info, "{s}", .{try plugin.list(a, app.io, session.options.home)});
            var words = std.mem.tokenizeAny(u8, arg, " \t");
            const action = words.next().?;
            const name = words.next() orelse return app.report(.err, "usage: /plugins [on|off <name>]", .{});
            if (words.next() != null or (!std.mem.eql(u8, action, "on") and !std.mem.eql(u8, action, "off"))) return app.report(.err, "usage: /plugins [on|off <name>]", .{});
            const package = plugin.setEnabled(a, app.io, session.options.home, name, std.mem.eql(u8, action, "on")) catch |err| return app.report(.err, "{s}: {s}", .{ name, @errorName(err) });
            var text: std.ArrayList(u8) = .empty;
            try text.print(a, "{s} · {s}\n", .{ name, action });
            for (package.unsupported) |item| try text.print(a, "Unsupported: {s}\n", .{item});
            try text.appendSlice(a, "Applies to new sessions.");
            return app.report(.info, "{s}", .{text.items});
        },
        .mcp => {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const servers = try config.loadMcp(a, app.io, session.options.home);
            if (arg.len > 0) {
                var words = std.mem.tokenizeAny(u8, arg, " \t");
                const action = words.next().?;
                const id = words.next() orelse return app.transcript.add(gpa, .err, "usage: /mcp [on|off <id>]");
                if (words.next() != null or (!std.mem.eql(u8, action, "on") and !std.mem.eql(u8, action, "off"))) return app.transcript.add(gpa, .err, "usage: /mcp [on|off <id>]");
                const exists = for (servers) |server| {
                    if (std.mem.eql(u8, server.id, id)) break true;
                } else false;
                if (!exists) return app.report(.err, "MCP server not found: {s}", .{id});
                config.saveMcp(gpa, app.io, session.options.home, id, std.mem.eql(u8, action, "on")) catch |err| return app.report(.err, "could not save MCP settings: {s}", .{@errorName(err)});
                return app.report(.info, "{s}: {s} · Applies to new sessions.", .{ id, action });
            }
            var text: std.ArrayList(u8) = .empty;
            const mcp_client = session.tools.mcp_client;
            if (mcp_client) |client| client.mutex.lockUncancelable(app.io);
            defer if (mcp_client) |client| client.mutex.unlock(app.io);
            for (servers) |server| {
                try text.print(a, "{s}  {s}", .{ server.id, if (server.enabled) @as([]const u8, "on") else "off" });
                if (server.enabled) if (mcp_client) |client| if (client.state(server.id)) |state| {
                    if (state.failure) |reason| try text.print(a, " · failed: {s}", .{reason}) else if (state.listed) try text.print(a, " · {d} tools", .{state.tools.len});
                };
                try text.append(a, '\n');
            }
            if (servers.len == 0) try text.appendSlice(a, "No MCP servers configured.\n");
            try text.appendSlice(a, "Applies to new sessions.");
            try app.transcript.add(gpa, .info, text.items);
        },
        .skills => {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const module = @import("../session/skills.zig");
            const cwd = try std.process.currentPathAlloc(app.io, a);
            const root = try @import("../session/instructions.zig").projectRoot(app.io, a, cwd);
            const found = try module.load(app.io, a, session.options.home, session.options.user_home, root);
            const settings = try config.loadSkills(a, app.io, session.options.home);
            if (arg.len > 0) {
                var words = std.mem.tokenizeAny(u8, arg, " \t");
                const action = words.next().?;
                const name = words.next() orelse return app.transcript.add(gpa, .err, "usage: /skills [on|off <name>]");
                if (words.next() != null or (!std.mem.eql(u8, action, "on") and !std.mem.eql(u8, action, "off"))) return app.transcript.add(gpa, .err, "usage: /skills [on|off <name>]");
                const enabled = std.mem.eql(u8, action, "on");
                const skill = for (found.skills) |skill| {
                    if (std.mem.eql(u8, skill.name, name)) break skill;
                } else null;
                if (enabled and skill == null) return app.report(.err, "skill not found: {s}", .{name});
                if (enabled and skill.?.disabled) return app.report(.err, "skill disables model invocation: {s}", .{name});
                config.saveSkill(gpa, app.io, session.options.home, name, enabled) catch |err| return app.report(.err, "could not save skills: {s}", .{@errorName(err)});
                return app.report(.info, "{s}: {s} · Applies to new sessions.", .{ name, action });
            }
            var text: std.ArrayList(u8) = .empty;
            for (found.skills) |skill| {
                const source = try module.source(a, skill.location, session.options.home, session.options.user_home, root);
                const on = !skill.disabled and config.skillEnabled(settings, skill.name);
                try text.print(a, "{s} · {s} · {s}\n  ", .{ skill.name, source, if (on) @as([]const u8, "on") else "off" });
                const description = try a.dupe(u8, skill.description);
                for (description) |*byte| if (std.ascii.isWhitespace(byte.*)) {
                    byte.* = ' ';
                };
                const preview = @import("format.zig").fit(description, 48);
                try text.print(a, "{s}{s}", .{ preview.text, preview.suffix });
                try text.append(a, '\n');
            }
            if (found.skills.len == 0) try text.appendSlice(a, "No skills found.\n");
            for (settings) |setting| {
                if (!setting.enabled) continue;
                const exists = for (found.skills) |skill| {
                    if (std.mem.eql(u8, setting.name, skill.name)) break true;
                } else false;
                if (!exists) try text.print(a, "{s} · missing · on\n", .{setting.name});
            }
            try text.appendSlice(a, "Applies to new sessions.");
            try app.transcript.add(gpa, .info, text.items);
        },
        .tasks => {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const list = try session.tools.background.snapshot(arena.allocator(), app.io);
            const text = try @import("tasks.zig").format(arena.allocator(), list, @import("../sandbox/timing.zig").Execution.now(app.io));
            try app.transcript.add(gpa, .info, text);
        },
        .stop => {
            if (arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\n") != null) return app.transcript.add(gpa, .err, "usage: /stop <id>");
            if (app.turn != null) {
                try session.tools.background.requestStop(gpa, app.io, arg);
                try app.report(.info, "{s}: user stop requested", .{arg});
            } else {
                const text = try @import("../tools/stop.zig").userStop(&session.tools, gpa, arg);
                defer gpa.free(text);
                try app.transcript.add(gpa, .info, text);
            }
        },
        .undo => {
            if (app.turn != null) return app.transcript.add(gpa, .err, "Turn running · retry command when it ends");
            if (arg.len != 0) return app.transcript.add(gpa, .err, "usage: /undo");
            const text = session.undo() catch |err| return app.report(.err, "undo failed: {s}; re-read files before continuing", .{@errorName(err)});
            defer gpa.free(text);
            app.context = session.context_tokens;
            try app.transcript.add(gpa, .info, text);
        },
        .help => {
            const text = try helpText(gpa, reflect.issueRepo(app));
            defer gpa.free(text);
            try app.transcript.add(gpa, .info, text);
        },
        .new, .@"resume" => {
            const id = if (c == .new) null else app.menu.resolveSession(app.io, session, arg) catch |err| {
                return app.transcript.add(gpa, .err, switch (err) {
                    error.MissingSessionId => "usage: /resume <id> · type /resume and a space to pick one",
                    error.UnknownSession => "no session here starts with that id",
                    error.AmbiguousSession => "several sessions start with that id; type more of it",
                    else => @errorName(err),
                });
            };
            if (id != null and std.mem.eql(u8, id.?, session.id)) return app.transcript.add(gpa, .info, "already in this session");
            session.reopen(id) catch |err| return app.report(.err, "could not open session: {s}", .{@errorName(err)});
            app.dropPrediction();
            session.tools.recovery.enabled = true;
            app.transcript.clear(gpa);
            app.background_count = 0;
            try app.transcript.addHistory(gpa, session.history.items);
            app.usage = .{};
            app.steps = 0;
            app.last_summary = null;
            app.context = session.context_tokens;
            const fast = if (c == .new and !app.signed_out and app.cfg.codexServiceTier() != null) " · Fast" else "";
            try app.report(.info, "{s} session {s}{s}", .{ if (c == .new) "new" else "resumed", session.id[0..8], fast });
        },
        .copy => {
            const answer = app.transcript.lastAnswer() orelse return app.transcript.add(gpa, .err, "no answer to copy yet");
            try app.vx.copyToSystemClipboard(app.w, answer, gpa);
            try app.report(.info, "copied {d} bytes (needs a terminal with OSC 52 clipboard support)", .{answer.len});
        },
        .provider => try providers.command(app, arg),
        .model => {
            if (arg.len == 0) return app.transcript.add(gpa, .err, "usage: /model <model> · type /model and a space to pick one");
            const selection = modelSelection(app, arg) catch return app.transcript.add(gpa, .err, "usage: /model <model>");
            try select(app, selection, null);
        },
        .fast => {
            if (arg.len != 0) return app.report(.err, "usage: /fast", .{});
            if (!app.cfg.supportsCodexFast()) return app.report(.err, "Fast mode is not available for this provider and model", .{});
            const enabled = !app.cfg.codex_fast;
            config.saveCodexFast(gpa, app.io, session.options.home, enabled) catch |err|
                return app.report(.err, "could not save Fast mode: {s}", .{@errorName(err)});
            app.cfg.codex_fast = enabled;
            session.cfg.codex_fast = enabled;
            session.tools.cfg = session.cfg;
            try app.report(.info, "{s}", .{if (enabled) "Fast requested · may use more credits" else "Standard mode"});
        },
        .effort => {
            if (arg.len > 0) {
                app.cfg.setEffort(arg) catch return app.transcript.add(gpa, .err, "usage: /effort [default|off|none|minimal|low|medium|high|xhigh|max]");
                session.cfg.thinking = app.cfg.thinking;
                session.cfg.reasoning_effort = app.cfg.reasoning_effort;
                session.tools.cfg = session.cfg;
                config.saveEffort(gpa, app.io, session.options.home, arg) catch |err| {
                    try app.report(.err, "effort applied, but could not save {s}/config.toml: {s}", .{ session.options.home, @errorName(err) });
                    return;
                };
                try app.report(.info, "effort: {s} · saved to {s}/config.toml (environment and --effort override saved preferences)", .{ app.cfg.effectiveEffort(), session.options.home });
                return;
            }
            try app.report(.info, "effort: {s} · thinking: {s} · configured: {s} (model support varies)", .{
                app.cfg.effectiveEffort(),
                if (app.cfg.thinking) |on| (if (on) "on" else "off") else "default",
                app.cfg.reasoning_effort orelse "default",
            });
        },
        .js => {
            if (arg.len == 0) return app.transcript.add(gpa, .err, "usage: /js <code>");
            try app.transcript.add(gpa, .user, line);
            defer app.transcript.next_run = session.tools.run_id;
            const ran = try session.run(arg, null);
            const r = ran.outcome;
            app.usage = session.usage;
            defer r.deinit(gpa);
            if (r.logs.len > 0) try app.transcript.add(gpa, .info, std.mem.trimEnd(u8, r.logs, "\n"));
            try app.transcript.add(gpa, if (r.ok) .info else .err, r.text);
            var changes: ChangeText = try .init(gpa, ran.changes);
            defer changes.deinit(gpa);
            if (changes.diff.len > 0) try app.transcript.add(gpa, .info, std.mem.trimEnd(u8, changes.diff, "\n"));
        },
        .compact => {
            app.dropPrediction();
            app.turn = try Turn.spawn(gpa, session, app.loop, try gpa.dupe(u8, arg), true);
            app.live_steps = 0;
            app.turn_runs = 0;
            app.activity = .start(app.io, .compacting);
        },
        .reflect => {
            if (!app.credentialed()) return app.transcript.add(gpa, .err, "No provider · /provider to sign in");
            const log_path = try std.fmt.allocPrint(gpa, "{s}/sessions/{s}.jsonl", .{ session.options.home, session.id });
            defer gpa.free(log_path);
            const text = try reflect.prompt(gpa, session.id, log_path, reflect.issueRepo(app).?, arg);
            errdefer gpa.free(text);
            const focus = try gpa.dupe(u8, arg);
            errdefer gpa.free(focus);
            try app.transcript.add(gpa, .user, line);
            app.dropPrediction();
            app.turn = try Turn.spawn(gpa, session, app.loop, text, false);
            app.live_steps = 0;
            app.turn_runs = 0;
            app.activity = .start(app.io, .thinking);
            app.reflecting = focus;
        },
    }
}

test "parse tells commands from paths and messages" {
    try testing.expect(parse("hello") == null);
    try testing.expect(parse("/etc/hosts 是什么") == null);
    try testing.expectEqual(Command.effort, parse("/effort high").?.known.command);
    try testing.expectEqualStrings("high", parse("/effort  high ").?.known.arg);
    try testing.expectEqualStrings("nope", parse("/nope x").?.unknown);
    try testing.expectEqual(Command.undo, parse("/undo").?.known.command);
    try testing.expect(allowedWhileBusy("/undo"));
}

test "candidates complete command names, then argument choices" {
    var buf: [32]Candidate = undefined;
    try testing.expectEqual(@as(usize, std.enums.values(Command).len), candidates("/", &.{}, &.{}, &.{}, &.{}, &buf).len);
    const co = candidates("/co", &.{}, &.{}, &.{}, &.{}, &buf);
    try testing.expectEqual(@as(usize, 2), co.len);
    try testing.expectEqualStrings("/copy", co[0].label);
    try testing.expectEqualStrings("/compact", co[1].label);
    try testing.expectEqual(@as(usize, 0), candidates("/js 1 + 1", &.{}, &.{}, &.{}, &.{}, &buf).len);
    try testing.expectEqual(@as(usize, 0), candidates("hi /co", &.{}, &.{}, &.{}, &.{}, &buf).len);

    const efforts = candidates("/effort h", &.{}, &.{}, &.{}, &.{}, &buf);
    try testing.expectEqual(@as(usize, 1), efforts.len);
    try testing.expectEqualStrings("high", efforts[0].value.?);
    const line = try efforts[0].line(testing.allocator);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("/effort high", line);

    const sessions = [_]Choice{ .{ .value = "abc123", .label = "abc1", .detail = "now" }, .{ .value = "def456", .label = "def4", .detail = "1h" } };
    const picked = candidates("/resume d", &sessions, &.{}, &.{}, &.{}, &buf);
    try testing.expectEqual(@as(usize, 1), picked.len);
    try testing.expectEqualStrings("def456", picked[0].value.?);
}

test "accepting a command waits for required arguments only" {
    var buf: [8]Candidate = undefined;
    const js = candidates("/j", &.{}, &.{}, &.{}, &.{}, &buf)[0];
    try testing.expect(!js.runs());
    const tab = try js.completion(testing.allocator);
    defer testing.allocator.free(tab);
    try testing.expectEqualStrings("/js ", tab);
    const effort = candidates("/ef", &.{}, &.{}, &.{}, &.{}, &buf)[0];
    try testing.expect(effort.runs());
    const help = try helpText(testing.allocator, "owner/repo");
    defer testing.allocator.free(help);
    try testing.expect(std.mem.indexOf(u8, help, "/resume <id>") != null);
}

test "task commands run while busy and stop completes current task ids" {
    try testing.expect(allowedWhileBusy("/tasks"));
    try testing.expect(allowedWhileBusy("/stop r3"));
    var buf: [32]Candidate = undefined;
    const tasks = [_]Choice{.{ .value = "r3", .label = "r3", .detail = "Run" }};
    const selected = candidates("/stop r", &.{}, &tasks, &.{}, &.{}, &buf);
    try testing.expectEqual(@as(usize, 1), selected.len);
    try testing.expectEqualStrings("r3", selected[0].value.?);
    try testing.expect(selected[0].runs());
    try testing.expect(!candidates("/stop", &.{}, &tasks, &.{}, &.{}, &buf)[0].runs());
}

test "help groups commands and states the real issue destination or disabled state" {
    const a = testing.allocator;
    const on = try helpText(a, "owner/repo");
    defer a.free(on);
    try testing.expect(std.mem.indexOf(u8, on, "Send\n").? < std.mem.indexOf(u8, on, "View\n").?);
    try testing.expect(std.mem.indexOf(u8, on, "publish issue drafts: owner/repo") != null);
    const off = try helpText(a, null);
    defer a.free(off);
    try testing.expect(std.mem.indexOf(u8, off, "/reflect") == null);
    try testing.expect(std.mem.indexOf(u8, off, "owner/repo") == null);
}

test "qualified model choices recognize all built-in services" {
    var app: App = undefined;
    const selection = try modelSelection(&app, "chat_completions/org/model");
    try testing.expectEqualStrings("chat_completions", selection.provider);
    try testing.expectEqualStrings("org/model", selection.model.?);
}

test "model choices filter and complete without running the bare command" {
    var buf: [32]Candidate = undefined;
    const models = [_]Choice{ .{ .value = "openai/gpt-6.1-sol", .label = "openai · gpt-6.1-sol", .detail = "current" }, .{ .value = "openai/gpt-6.1-terra", .label = "gpt-6.1-terra", .detail = "openai" }, .{ .value = "local/gpt-6.1-sol", .label = "gpt-6.1-sol", .detail = "local" } };
    try testing.expect(!allowedWhileBusy("/model gpt-6.1-sol"));
    try testing.expect(!candidates("/model", &.{}, &.{}, &models, &.{}, &buf)[0].runs());
    const selected = candidates("/model gpt-6.1-s", &.{}, &.{}, &models, &.{}, &buf);
    try testing.expectEqual(@as(usize, 2), selected.len);
    try testing.expectEqualStrings("current", selected[0].detail);
    const line = try selected[0].line(testing.allocator);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("/model openai/gpt-6.1-sol", line);
    const qualified = candidates("/model local/gpt-6.1-s", &.{}, &.{}, &models, &.{}, &buf);
    try testing.expectEqual(@as(usize, 1), qualified.len);
    try testing.expectEqualStrings("local/gpt-6.1-sol", qualified[0].value.?);
}

test "service choices complete /provider and run on Enter" {
    var buf: [32]Candidate = undefined;
    const services = [_]Choice{ .{ .value = "codex", .label = "Codex", .detail = "signed in · ChatGPT" }, .{ .value = "anthropic", .label = "Anthropic", .detail = "—" } };
    try testing.expect(!allowedWhileBusy("/provider anthropic"));
    try testing.expect(!candidates("/provider", &.{}, &.{}, &.{}, &services, &buf)[0].runs());
    const all = candidates("/provider ", &.{}, &.{}, &.{}, &services, &buf);
    try testing.expectEqual(@as(usize, 2), all.len);
    const one = candidates("/provider an", &.{}, &.{}, &.{}, &services, &buf);
    try testing.expect(one[0].runs());
    const line = try one[0].line(testing.allocator);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("/provider anthropic", line);
}

test "simple command is a busy-safe view change" {
    try testing.expectEqual(Command.simple, parse("/" ++ mode.command).?.known.command);
    try testing.expect(allowedWhileBusy("/" ++ mode.command));
}
