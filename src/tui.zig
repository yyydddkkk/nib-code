const std = @import("std");
const vaxis = @import("vaxis");
const Session = @import("session.zig").Session;
const SessionEvent = @import("session.zig").Event;
const ModelActivity = @import("session.zig").ModelActivity;
const provider = @import("provider.zig");
const Editor = @import("tui/editor.zig").Editor;
const commands = @import("tui/commands.zig");
const Transcript = @import("tui/transcript.zig").Transcript;
const EntryKind = @import("tui/transcript.zig").Kind;
const ChangeText = @import("tui/transcript.zig").ChangeText;
const Viewport = @import("tui/viewport.zig").Viewport;
const Menu = @import("tui/menu.zig").Menu;
const status = @import("tui/status.zig");
const view = @import("tui/view.zig");
const selection = @import("tui/selection.zig");
const reflect = @import("tui/reflect.zig");
const image = @import("image.zig");
const clipboard = @import("tui/clipboard.zig");
const providers = @import("tui/providers.zig");
const provider_flow = @import("tui/provider_flow.zig");
const config = @import("config.zig");
const prediction = @import("tui/prediction.zig");
const Turn = @import("tui/turn.zig").Turn;
const Ticker = @import("tui/turn.zig").Ticker;
const Frames = @import("tui/frames.zig").Frames;
const bill = @import("tui/bill.zig");
const open = @import("tui/open.zig");
const title = @import("tui/title.zig");
const TurnSummary = @import("session/events.zig").TurnSummary;
const ToolSummary = @import("session/tool_summary.zig").Summary;

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    paste_start,
    paste_end,
    mouse: vaxis.Mouse,
    color_report: vaxis.Color.Report,
    color_scheme: vaxis.Color.Scheme,
    tick,
    tool_activity: []const u8,
    model_activity: struct { state: ModelActivity, at: std.Io.Clock.Timestamp },
    /// Slices are owned by the receiver.
    step: struct { n: u32, effort: []u8 },
    delta: struct { kind: provider.Kind, text: []u8, step: u32 },
    run_start: struct { code: []u8, step: u32 },
    run_end: struct { background_id: ?[]const u8 = null, ok: bool, output: []u8, changes: ChangeText, tool_summary: ?ToolSummary = null },
    retry: []u8,
    notice: []u8,
    user_inserted: u64,
    done,
    turn_end: TurnSummary,
    usage: struct { tokens: provider.Usage, context: u64, steps: u32 },
    progress: @import("session/events.zig").Progress,
    background: struct {
        hook_notice: ?[]const u8 = null,
        id: []const u8,
        kind: @FieldType(@FieldType(SessionEvent, "background"), "kind"),
        state: @FieldType(@FieldType(SessionEvent, "background"), "state"),
        ok: ?bool = null,
        result: ?[]const u8 = null,
        changes: ChangeText = .{},
        tool_summary: ?ToolSummary = null,
    },
    failed: struct { message: []u8, reason: @import("tools/changes.zig").Recovery.Reason },
    /// One outcome line from automatic issue filing, owned by the receiver.
    issue: []u8,
    issues_done,
    paths_ready,
    /// A sign-in or model-listing job finished; freed with the event.
    flow: *provider_flow.Result,
    /// A predicted next message; `text` is owned by the receiver.
    prediction: struct { generation: u64, text: []u8 },

    pub fn flushesVisible(event: Event) bool {
        return switch (event) {
            .delta, .tick, .model_activity, .usage, .progress, .tool_activity => false,
            else => true,
        };
    }

    pub fn refresh(event: Event) Frames.Refresh {
        return switch (event) {
            .tick => .animation,
            .key_press, .paste_end, .mouse, .winsize, .color_report, .color_scheme, .done, .failed, .issues_done, .flow, .prediction => .immediate,
            else => .content,
        };
    }

    pub fn deinit(event: Event, gpa: std.mem.Allocator) void {
        switch (event) {
            .step => |s| gpa.free(s.effort),
            .delta => |d| gpa.free(d.text),
            .run_start => |r| gpa.free(r.code),
            .run_end => |r| {
                if (r.background_id) |id| gpa.free(id);
                gpa.free(r.output);
                var changes = r.changes;
                changes.deinit(gpa);
                if (r.tool_summary) |summary| summary.deinit(gpa);
            },
            .retry, .notice, .issue => |text| gpa.free(text),
            .prediction => |p| gpa.free(p.text),
            .failed => |failure| gpa.free(failure.message),
            .progress => |p| {
                var owned = p;
                owned.deinit(gpa);
            },
            .background => |b| {
                if (b.hook_notice) |notice| gpa.free(notice);
                gpa.free(b.id);
                if (b.result) |result| gpa.free(result);
                var changes = b.changes;
                changes.deinit(gpa);
                if (b.tool_summary) |summary| summary.deinit(gpa);
            },
            .flow => |r| {
                r.deinit(gpa);
                gpa.destroy(r);
            },
            .key_press, .winsize, .paste_start, .paste_end, .mouse, .color_report, .color_scheme, .tick, .tool_activity, .model_activity, .user_inserted, .done, .turn_end, .usage, .issues_done, .paths_ready => {},
        }
    }
};

/// `session` may already hold history (a resumed Session); it is shown first.
pub fn run(init: std.process.Init, session: *Session) !void {
    session.tools.recovery.enabled = true;
    const io = init.io;
    const gpa = init.gpa;

    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    const w = tty.writer();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(gpa, w);

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.installResizeHandler();
    defer loop.uninstallResizeHandler();
    try loop.start();
    defer loop.stop();
    defer session.finishHooks();

    try vx.enterAltScreen(w);
    try w.flush();
    try vx.queryTerminal(w, .fromSeconds(1));
    try vx.setBracketedPaste(w, true);
    // Selection needs cell coordinates; some terminals claim SGR pixel mode yet report cells.
    vx.caps.sgr_pixels = false;
    try vx.setMouseMode(w, true);
    try vx.queryColor(w, .bg);
    if (vx.caps.color_scheme_updates) try vx.subscribeToColorSchemeUpdates(w);

    var ticker: Ticker = .{ .io = io, .loop = &loop };
    const ticker_thread = try std.Thread.spawn(.{}, Ticker.work, .{&ticker});
    defer {
        ticker.stop.store(true, .release);
        ticker_thread.join();
    }

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .session = session,
        .environ = init.environ_map,
        .cfg = session.cfg,
        .config_allocator = init.arena.allocator(),
        .vx = &vx,
        .w = w,
        .loop = &loop,
        .menu = .init(gpa),
        .activity = .start(io, .thinking),
        .context = session.context_tokens,
        .flow = .{ .gpa = gpa },
    };
    app.menu.reflect_enabled = reflect.issueRepo(&app) != null;
    defer app.deinit();
    app.refreshCredentials();
    app.menu.wake = .{ .ctx = &app, .call = pathsReady };

    try app.transcript.addHistory(gpa, session.history.items);
    for (session.history.items) |m| {
        if (m.source != .undo and std.mem.eql(u8, m.role, "user")) try app.input.remember(gpa, m.content orelse "");
    }

    var frames: Frames = .{};
    while (true) {
        const event = try loop.nextEvent();
        const refresh = event.refresh();
        const old_hover = app.hovered;
        const old_hover_row = app.hovered_row;
        const old_link = app.link;
        const motion = event == .mouse and event.mouse.type == .motion and !app.selection.active;
        if (!motion and event.flushesVisible()) app.transcript.flushVisible();
        if (!try app.handle(event)) break;
        if (motion and old_hover == app.hovered and old_hover_row == app.hovered_row and std.meta.eql(old_link, app.link)) continue;
        const frame_start = std.Io.Clock.Timestamp.now(io, .awake);
        if (frames.due(frame_start, if (refresh != .immediate and app.transcript.hasBacklog()) .content else refresh)) {
            app.transcript.advanceVisible(frame_start);
            try app.render();
            frames.painted(frame_start);
        }
        ticker.busy.store(frames.pending or app.transcript.hasBacklog() or app.turn != null or app.session.tools.background.anyPending(io), .release);
    }
}

fn pathsReady(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.loop.postEvent(.paths_ready) catch {};
}

const Link = struct { row: u16, x0: u16, x1: u16 };

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    session: *Session,
    cfg: provider.Config,
    config_allocator: ?std.mem.Allocator = null,
    vx: *vaxis.Vaxis,
    w: *std.Io.Writer,
    loop: *vaxis.Loop(Event),
    environ: *const std.process.Environ.Map,
    selection: selection.Selection = .{},
    body: ?view.Frame = null,
    user_bg: vaxis.Color = .default,
    code_bg: vaxis.Color = .default,
    hover_bg: vaxis.Color = .default,
    terminal_bg: ?[3]u8 = null,
    hovered: ?usize = null,
    hovered_row: ?u16 = null,
    /// Underlined file path under the pointer; only when `open` is configured.
    link: ?Link = null,
    files: open.Files = .{},
    files_revision: usize = 0,
    project: ?[]u8 = null,
    work_dir: ?[]u8 = null,
    title_loaded: bool = false,
    title_project: ?[]u8 = null,
    title_branch: ?[]u8 = null,
    title_buf: [512]u8 = undefined,
    /// Shown on the status line until the next key or click; not part of the transcript.
    notice: ?[]const u8 = null,
    notice_buf: [256]u8 = undefined,
    /// Set by the first ctrl+c; any other key or click disarms it, a second ctrl+c quits.
    quit_armed: bool = false,
    /// Set while a /reflect Turn runs: its focus, owned.
    reflecting: ?[]u8 = null,
    issues: ?*reflect.Issues = null,
    transcript: Transcript = .{},
    input: Editor = .{},
    pasting: bool = false,
    paste_buf: std.ArrayList(u8) = .empty,
    live_steps: u32 = 0,
    background_count: usize = 0,
    step_effort: ?provider.StepEffort = null,
    scroll: Viewport = .{},
    menu: Menu,
    status_text: status.Text = .{},
    reflect_help: [512]u8 = undefined,
    activity_detail: [256]u8 = undefined,
    retry_detail: [256]u8 = undefined,
    retry_len: usize = 0,
    activity: status.Activity,
    usage: provider.Usage = .{},
    steps: u32 = 0,
    context: u64 = 0,
    turn: ?*Turn = null,
    // turn_end precedes done/failed; append only after their terminal content.
    pending_bill: ?TurnSummary = null,
    last_summary: ?TurnSummary = null,
    turn_runs: usize = 0,
    flow: provider_flow.Flow = .{ .gpa = undefined },
    prediction: prediction.State = .{},
    /// No usable credentials for the current service; see refreshCredentials.
    signed_out: bool = false,
    prompt_view: Editor = .{ .placeholder = "" },
    prompt_text: std.ArrayList(u8) = .empty,
    flow_hint: [256]u8 = undefined,

    const command = commands.execute;
    const saveReflection = reflect.saveReflection;
    const stopReflecting = reflect.stopReflecting;

    fn deinit(app: *App) void {
        // Close before joining producers: a full queue must not block shutdown.
        app.loop.queue.close(error.Closed);
        if (app.turn) |t| {
            t.cancel.store(true, .release);
            t.finish();
        }
        app.prediction.deinit(app.gpa);
        app.files.deinit(app.gpa);
        for ([_]?[]u8{ app.project, app.work_dir, app.title_project, app.title_branch }) |owned| if (owned) |text| app.gpa.free(text);
        app.flow.deinit();
        app.stopReflecting();
        app.clearStepEffort();
        if (app.issues) |job| job.finish();
        app.loop.queue.mutex.lockUncancelable(app.io);
        while (app.loop.queue.drain()) |event| event.deinit(app.gpa);
        app.loop.queue.mutex.unlock(app.io);
        app.menu.deinit();
        app.transcript.deinit(app.gpa);
        app.input.deinit(app.gpa);
        app.prompt_view.deinit(app.gpa);
        app.prompt_text.deinit(app.gpa);
        app.paste_buf.deinit(app.gpa);
    }

    pub fn refreshCredentials(app: *App) void {
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        app.signed_out = !config.credentialed(arena.allocator(), app.io, app.cfg);
    }

    pub fn credentialed(app: *App) bool {
        app.refreshCredentials();
        return !app.signed_out;
    }

    fn idleProgress(ctx: *anyopaque, progress: @import("session/events.zig").Progress) !void {
        const app: *App = @ptrCast(@alignCast(ctx));
        try app.transcript.progress(app.gpa, progress);
    }

    /// False to quit.
    fn handle(app: *App, value: Event) !bool {
        const gpa = app.gpa;
        var event = value;
        defer event.deinit(gpa);
        switch (event) {
            .key_press => |k| {
                app.hovered = null;
                app.link = null;
                return app.onKey(k);
            },
            .paste_start => {
                app.pasting = true;
                app.paste_buf.clearRetainingCapacity();
            },
            .paste_end => {
                app.pasting = false;
                if (app.flow.takesText()) {
                    try providers.pasted(app, app.paste_buf.items);
                } else if (std.mem.trim(u8, app.paste_buf.items, &std.ascii.whitespace).len == 0) {
                    try app.attachClipboardImage();
                } else {
                    if (!try app.attachPastedFile(app.paste_buf.items)) try app.input.paste(gpa, app.paste_buf.items);
                    app.menu.inputChanged(app.input.text());
                    app.menu.closed = true;
                }
                app.paste_buf.clearRetainingCapacity();
            },
            .mouse => |m| {
                if (m.type == .motion and !app.selection.active) {
                    app.hovered = null;
                    app.hovered_row = null;
                    app.link = null;
                    if (app.selection.dragged) return true;
                    if (app.body) |body| {
                        if (m.col >= body.window.x_off and m.col < body.window.x_off + body.window.width and m.row >= 0 and m.row < body.window.height) {
                            if (@import("tui/selection/history.zig").position(body, app.transcript.entries.items, @intCast(m.col), @intCast(m.row))) |p| {
                                if (app.transcript.entries.items[p.entry].control(body.window, p.row)) |control_hit| {
                                    app.hovered = p.entry;
                                    app.hovered_row = control_hit.first;
                                }
                                var text: [open_buf_len]u8 = undefined;
                                if (app.hitAt(p.entry, p.row, m.col, m.row, &text)) |hit| app.link = .{ .row = @intCast(m.row), .x0 = hit.found.x0, .x1 = hit.found.x1 };
                            }
                        }
                    }
                    return true;
                }
                app.hovered = null;
                app.link = null;
                if (m.type == .press) {
                    app.notice = null;
                    app.quit_armed = false;
                }
                if (m.button == .wheel_up or m.button == .wheel_down) {
                    if (m.type == .press) {
                        if (!app.selection.active or app.selection.history == null) app.selection.clear();
                        app.scroll.pending += if (m.button == .wheel_up) @as(i64, -3) else 3;
                    }
                } else if (app.selection.mouseInHistory(m, &app.vx.screen, app.body, app.transcript.entries.items)) {
                    const text = try app.selection.textInHistory(gpa, &app.vx.screen, app.body, app.transcript.entries.items);
                    defer gpa.free(text);
                    if (std.mem.trim(u8, text, " \n").len == 0) {
                        app.selection.clear();
                    } else {
                        try selection.copy(app.vx, app.w, gpa, app.io, app.environ, text);
                        app.notice = std.fmt.bufPrint(&app.notice_buf, "copied {d} chars", .{std.unicode.utf8CountCodepoints(text) catch text.len}) catch null;
                    }
                }
                if (app.selection.takeClick()) |c| {
                    if (!app.openClick(c.entry, c.row, m)) app.clickEntry(c.entry, c.row);
                }
                if (app.selection.active and app.selection.history != null) {
                    if (app.body) |body| app.scroll.top = body.top;
                }
            },
            .paths_ready => {},
            .prediction => |p| {
                app.prediction.arrive(gpa, p.generation, p.text);
                event.prediction.text = &.{};
            },
            .flow => |r| try providers.result(app, r),
            .tick => if (app.turn == null) {
                app.session.tools.progress.sink = .{ .ctx = app, .emit = idleProgress };
                defer app.session.tools.progress.sink = null;
                try app.session.tools.progress.drain(app.io);
            },
            .tool_activity => |name| {
                app.activity.tool = name;
                app.activity.progress(.now(app.io, .awake));
            },
            .model_activity => |activity| {
                if (activity.state == .started) {
                    app.transcript.beginAttempt();
                    if (app.activity.phase != .compacting and app.activity.phase != .retrying) app.activity.set(app.io, .thinking);
                }
                if (activity.state == .script) app.activity.set(app.io, .scripting);
                if (activity.state == .waiting) app.activity.set(app.io, .waiting);
                app.activity.modelActivity(activity.state, activity.at);
            },
            .color_report => |color| {
                if (color.kind == .bg) {
                    app.terminal_bg = color.value;
                    app.user_bg = userBackground(color.value);
                    app.code_bg = codeBackground(color.value);
                    app.hover_bg = hoverBackground(color.value);
                }
            },
            .color_scheme => |scheme| {
                app.hover_bg = if (app.terminal_bg) |bg| hoverBackground(bg) else hoverFallback(scheme);
                try app.vx.queryColor(app.w, .bg);
            },
            .winsize => |ws| {
                app.selection.clear();
                try app.vx.resize(gpa, app.w, ws);
            },
            .step => |s| {
                app.clearStepEffort();
                app.step_effort = .{ .effort = s.effort };
                event.step.effort = &.{};
                app.live_steps = s.n;
            },
            .delta => |d| {
                app.live_steps = d.step;
                if (d.text.len > 0) app.activity.progress(.now(app.io, .awake));
                if (d.text.len > 0 and app.activity.phase != .compacting) app.activity.set(app.io, status.Activity.deltaPhase(d.kind));
                if (d.kind == .text and d.text.len > 0) app.transcript.clearRetry(gpa, &app.scroll);
                if (d.kind == .text) try app.transcript.smoothDelta(gpa, d.text, .now(app.io, .awake));
            },
            .run_start => |r| {
                app.transcript.clearRetry(gpa, &app.scroll);
                app.live_steps = r.step;
                app.turn_runs += 1;
                app.activity.tool = "";
                app.activity.set(app.io, .running);
                try app.transcript.startRunWithEffort(gpa, r.code, app.step_effort);
            },
            .run_end => |r| {
                const elapsed = app.activity.label(app.io).ms;
                app.activity.set(app.io, .thinking);
                if (r.background_id) |id| try app.transcript.backgroundRun(gpa, id);
                event.run_end.changes = .{};
                try app.transcript.endRunWithSummary(gpa, r.ok, r.output, elapsed, r.changes, r.tool_summary);
            },
            .retry => |msg| {
                try app.transcript.retryAttempt(gpa, &app.scroll);
                app.activity.set(app.io, .retrying);
                const line = std.fmt.bufPrint(&app.retry_detail, "{s}", .{msg}) catch app.retry_detail[0..0];
                app.retry_len = line.len;
            },
            .notice => |msg| {
                if (std.mem.startsWith(u8, msg, "hook ") and !std.mem.startsWith(u8, msg, "hook turn_end ")) {
                    try app.transcript.hookNotice(gpa, msg);
                } else try app.transcript.add(gpa, .info, msg);
            },
            .usage => |u| {
                app.usage = u.tokens;
                app.context = u.context;
                app.steps = u.steps;
            },
            .progress => |p| {
                if (app.transcript.progressChanged(p)) app.activity.progress(.now(app.io, .awake));
                try app.transcript.progress(gpa, p);
            },
            .background => |b| {
                if (b.hook_notice) |notice| try app.transcript.backgroundHookNotice(gpa, b.id, notice);
                if (b.kind == .run and b.tool_summary != null) try app.transcript.updateBackgroundRun(gpa, b.id, b.result orelse "", b.changes, b.tool_summary.?);
                switch (b.state) {
                    .started => app.background_count += 1,
                    .finished => {
                        app.background_count -|= 1;
                        try app.transcript.backgroundResult(gpa, b.kind, b.id, b.ok orelse false, b.result orelse "{}");
                    },
                    .lost => {
                        app.background_count -|= 1;
                        try app.transcript.lostBackground(gpa, b.kind, b.id, b.result orelse "background task was lost");
                    },
                }
            },
            .turn_end => |summary| app.pending_bill = summary,
            .user_inserted => |id| app.transcript.userInserted(id),
            .done => {
                app.transcript.clearRetry(gpa, &app.scroll);
                const canceled = app.turn.?.cancel.load(.acquire);
                const predict = !canceled and !app.turn.?.compact and app.reflecting == null;
                try app.finishTurn();
                try app.saveReflection();
                try app.appendBill();
                if (canceled) try app.recoveryHint(.canceled) else try app.appendChanges();
                try app.finishQueued(!canceled);
                if (predict) app.predictNext();
            },
            .issue => |msg| {
                try app.transcript.add(gpa, .info, msg);
            },
            .issues_done => {
                if (app.issues) |job| job.finish();
                app.issues = null;
            },
            .failed => |failure| {
                app.transcript.clearRetry(gpa, &app.scroll);
                const msg = failure.message;
                app.stopReflecting();
                const canceled = app.turn.?.cancel.load(.acquire);
                if (!canceled) {
                    app.transcript.discardAttempt(gpa);
                    try app.transcript.failure(gpa, msg, failure.reason);
                }
                try app.finishTurn();
                try app.appendBill();
                try app.recoveryHint(failure.reason);
                try app.finishQueued(false);
            },
        }
        return true;
    }

    fn page(app: *App) i64 {
        return @max(app.vx.window().height / 2, 1);
    }

    fn onKey(app: *App, k: vaxis.Key) !bool {
        app.notice = null;
        app.selection.clear();
        const gpa = app.gpa;
        if (app.pasting) {
            if (k.text) |t| {
                try app.paste_buf.appendSlice(gpa, t);
            } else if (isNewline(k, true)) {
                try app.paste_buf.append(gpa, '\n');
            } else if (k.matches(vaxis.Key.tab, .{})) {
                try app.paste_buf.append(gpa, '\t');
            }
            return true;
        }
        const input = &app.input;
        const armed = app.quit_armed;
        app.quit_armed = false;
        if ((k.matches(@import("tui/mode.zig").key, .{ .ctrl = true }) or k.matches(@import("tui/mode.zig").key, .{ .ctrl = true, .shift = true }))) {
            try app.toggleSimple();
            return true;
        }
        if (k.matches('c', .{ .ctrl = true })) {
            if (armed) return false;
            app.quit_armed = true;
            app.notice = "press ctrl+c again to quit";
            return true;
        }
        if (k.matches('d', .{ .ctrl = true }) and input.text().len == 0) return false;
        if (app.flow.active() or app.menu.isPinned()) {
            try providers.key(app, k);
            return true;
        }
        app.menu.sync(app.io, input, app.session);
        const selected = app.menu.selected(input.text());
        const before = std.hash.Wyhash.hash(0, input.text());
        var submitted: ?[]u8 = null;

        if (selected == null and k.matches(vaxis.Key.tab, .{}) and app.turn == null and try app.prediction.accept(gpa, input)) {
            // Accepted into the editor; Enter sends it.
        } else if (selected != null and k.matches(vaxis.Key.escape, .{})) {
            app.menu.closed = true;
        } else if (selected != null and k.matches(vaxis.Key.up, .{})) {
            app.menu.move(input.text(), false);
        } else if (selected != null and k.matches(vaxis.Key.down, .{})) {
            app.menu.move(input.text(), true);
        } else if (selected != null and selected.?.is_path and (k.matches(vaxis.Key.tab, .{}) or k.matches(vaxis.Key.enter, .{}))) {
            if (input.fileMention() orelse input.skillMention()) |m| try input.completeMention(gpa, m.start, selected.?.value.?);
        } else if (selected != null and (k.matches(vaxis.Key.tab, .{}) or (k.matches(vaxis.Key.enter, .{}) and !app.pasting and !selected.?.runs()))) {
            const completion = try selected.?.completion(gpa);
            defer gpa.free(completion);
            try input.replace(gpa, completion);
        } else if (selected != null and k.matches(vaxis.Key.enter, .{}) and !app.pasting) {
            const line = try selected.?.line(gpa);
            defer gpa.free(line);
            try input.replace(gpa, line);
            if (app.turn == null or commands.allowedWhileBusy(line)) submitted = try input.take(gpa) else app.notice = "Turn running · retry command when it ends";
        } else if (k.matches(vaxis.Key.escape, .{})) {
            if (app.turn) |t| t.cancel.store(true, .release);
        } else if (k.matches(vaxis.Key.page_up, .{})) {
            app.scroll.pending -= app.page();
        } else if (k.matches(vaxis.Key.page_down, .{})) {
            app.scroll.pending = if (app.scroll.top != null) std.math.maxInt(i32) else app.page();
        } else if (k.matches('o', .{ .ctrl = true })) {
            if (app.transcript.latestDetails()) |i| app.toggleEntry(i);
        } else if (k.matches('v', .{ .ctrl = true })) {
            try app.attachClipboardImage();
        } else if (k.matches(vaxis.Key.up, .{ .shift = true })) {
            app.scroll.pending -= 3;
        } else if (k.matches(vaxis.Key.down, .{ .shift = true })) {
            app.scroll.pending += 3;
        } else if (isNewline(k, app.pasting)) {
            try input.insert(gpa, "\n");
        } else if (k.matches(vaxis.Key.enter, .{})) {
            if (input.text().len > 0 and (commands.parse(input.text()) == null or app.session.isPluginCommand(input.text())) and !app.credentialed()) {
                try providers.openMenu(app);
            } else if (input.imageCount() > 0 and !app.cfg.vision()) {
                app.notice = std.fmt.bufPrint(&app.notice_buf, "{s} has no image input · remove the [Image] blocks", .{app.cfg.model}) catch null;
            } else if (input.imageCount() > 0 and app.turn != null) {
                app.notice = "Turn running · images send with the next message";
            } else if (app.turn == null or (commands.parse(input.text()) == null or app.session.isPluginCommand(input.text())) or commands.allowedWhileBusy(input.text())) submitted = try input.take(gpa) else app.notice = "Turn running · retry command when it ends";
        } else {
            _ = try input.key(gpa, k);
        }
        if (std.hash.Wyhash.hash(0, input.text()) != before) app.menu.inputChanged(input.text());
        if (submitted) |line| try app.submit(line);
        return true;
    }

    fn showImageNotice(app: *App, comptime fmt: []const u8, args: anytype) void {
        app.notice = std.fmt.bufPrint(&app.notice_buf, fmt, args) catch null;
    }

    fn attachBytes(app: *App, name: []const u8, data: []const u8) !void {
        if (!app.cfg.vision()) return app.showImageNotice("{s} has no image input", .{app.cfg.model});
        const directory = try app.session.imageDirectory(app.gpa);
        defer app.gpa.free(directory);
        const stored = image.store(app.io, app.gpa, directory, name, data) catch |err| switch (err) {
            error.UnsupportedImage, error.ImageTooLarge => return app.showImageNotice("{s}: {s}", .{ name, image.rejection(err) }),
            else => return err,
        };
        defer stored.deinit(app.gpa);
        try app.input.attach(app.gpa, stored);
        app.menu.inputChanged(app.input.text());
    }

    /// True when pasted text names an existing image file and was handled.
    fn attachPastedFile(app: *App, pasted: []const u8) !bool {
        const path = try image.pastedPath(app.gpa, pasted) orelse return false;
        defer app.gpa.free(path);
        const stat = std.Io.Dir.cwd().statFile(app.io, path, .{}) catch return false;
        if (stat.kind != .file) return false;
        const name = std.fs.path.basename(path);
        if (stat.size > image.max_bytes) {
            app.showImageNotice("{s}: {s}", .{ name, image.rejection(error.ImageTooLarge) });
            return true;
        }
        const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(image.max_bytes)) catch return false;
        defer app.gpa.free(data);
        try app.attachBytes(name, data);
        return true;
    }

    fn attachClipboardImage(app: *App) !void {
        if (!app.cfg.vision()) return app.showImageNotice("{s} has no image input", .{app.cfg.model});
        switch (try clipboard.readImage(app.gpa, app.io, app.environ)) {
            .png => |data| {
                defer app.gpa.free(data);
                try app.attachBytes("clipboard.png", data);
            },
            .no_tool => app.notice = "No clipboard image tool · install wl-paste or xclip",
            .no_image => app.notice = "No image in clipboard",
            .too_large => app.notice = "Clipboard image is larger than 5 MB",
        }
    }

    /// Takes ownership of `line`.
    fn submit(app: *App, line: []u8) !void {
        const gpa = app.gpa;
        app.scroll = .{};
        app.menu.forgetSessions();
        if (line.len == 0) return gpa.free(line);
        if (!app.session.isPluginCommand(line)) if (commands.parse(line)) |parsed| {
            defer gpa.free(line);
            return switch (parsed) {
                .unknown => |name| app.report(.err, "unknown command /{s} · /help lists commands", .{name}),
                .known => |c| app.command(c.command, c.arg, line),
            };
        };
        if (!app.credentialed()) {
            gpa.free(line);
            return app.transcript.add(gpa, .err, "No provider · /provider to sign in");
        }
        if (app.turn != null) {
            defer gpa.free(line);
            const id = try app.session.enqueue(line);
            try app.transcript.add(gpa, .user, line);
            app.transcript.entries.items[app.transcript.entries.items.len - 1].queued = id;
            return;
        }
        try app.startTurnWithImages(line, app.input.sent_images.items);
    }

    /// Takes ownership of text without interpreting slash commands.
    fn startTurn(app: *App, text: []u8) !void {
        return app.startTurnWithImages(text, &.{});
    }

    fn startTurnWithImages(app: *App, text: []u8, images: []const @import("image.zig").Image) !void {
        errdefer app.gpa.free(text);
        app.dropPrediction();
        try app.transcript.add(app.gpa, .user, text);
        app.turn = try Turn.spawnWithImages(app.gpa, app.session, app.loop, text, images, false);
        app.live_steps = 0;
        app.turn_runs = 0;
        app.activity = .start(app.io, .thinking);
    }

    pub fn dropPrediction(app: *App) void {
        app.prediction.invalidate(app.gpa);
    }

    fn predictNext(app: *App) void {
        if (app.turn != null or app.flow.active() or app.menu.isPinned() or !app.credentialed()) return;
        var reply: ?[]const u8 = null;
        var i = app.session.history.items.len;
        while (i > 0) : (i -= 1) {
            const m = app.session.history.items[i - 1];
            const content = m.content orelse continue;
            if (content.len != 0 and std.mem.eql(u8, m.role, "assistant")) {
                reply = content;
                break;
            }
        }
        const recent = prediction.recentUserMessages(app.gpa, app.session.history.items) catch return;
        defer app.gpa.free(recent);
        if (recent.len == 0) return;
        app.prediction.start(app.gpa, app.io, app.loop, app.cfg, app.session.id, recent, reply orelse return);
    }

    pub fn report(app: *App, kind: EntryKind, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(app.gpa, fmt, args);
        defer app.gpa.free(message);
        try app.transcript.add(app.gpa, kind, message);
    }

    fn recoveryHint(app: *App, reason: @import("tools/changes.zig").Recovery.Reason) !void {
        const cwd = try std.process.currentPathAlloc(app.io, app.gpa);
        defer app.gpa.free(cwd);
        const hint = try app.session.tools.recovery.hint(app.gpa, app.io, reason, cwd);
        defer app.gpa.free(hint);
        try app.transcript.add(app.gpa, .info, hint);
    }

    fn appendBill(app: *App) !void {
        const summary = app.pending_bill orelse return;
        var text: bill.Text = .{};
        const footer = text.format(summary, app.turn_runs, std.math.maxInt(u16));
        if (footer.len > 0) try app.transcript.add(app.gpa, .bill, footer);
        app.last_summary = summary;
        app.pending_bill = null;
    }

    fn appendChanges(app: *App) !void {
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        const cwd = try std.process.currentPathAlloc(app.io, arena.allocator());
        const files = try app.session.tools.recovery.files(arena.allocator(), app.io, cwd);
        try app.transcript.addChanges(app.gpa, try @import("tui/transcript/changes.zig").turnChanges(app.gpa, files));
    }

    fn clearStepEffort(app: *App) void {
        if (app.step_effort) |effort| app.gpa.free(effort.effort);
        app.step_effort = null;
    }

    fn finishTurn(app: *App) !void {
        app.clearStepEffort();
        app.turn.?.finish();
        app.turn = null;
        while (app.session.tools.background.takeStop(app.io)) |id| {
            defer app.gpa.free(id);
            const notice = try @import("tools/stop.zig").userStop(&app.session.tools, app.gpa, id);
            defer app.gpa.free(notice);
            try app.transcript.add(app.gpa, .info, notice);
        }
        if (!app.session.tools.background.anyPending(app.io)) {
            app.background_count = 0;
            try app.transcript.clearBackgroundProgress(app.gpa);
        }
        app.usage = app.session.usage;
        app.steps = app.session.steps;
        app.context = app.session.context_tokens;
    }

    fn finishQueued(app: *App, send: bool) !void {
        var batch = try app.session.takeQueued();
        defer batch.deinit(app.gpa);
        if (batch.items.items.len == 0) return;
        const text = try batch.joined(app.gpa);
        if (text.len == 0) {
            app.gpa.free(text);
            return;
        }
        app.selection.clear();
        app.transcript.removeQueued(app.gpa);
        if (send) {
            try app.startTurn(text);
        } else {
            defer app.gpa.free(text);
            const draft = try app.input.expanded(app.gpa);
            defer app.gpa.free(draft);
            const restored = if (draft.len == 0) try app.gpa.dupe(u8, text) else try std.fmt.allocPrint(app.gpa, "{s}\n\n{s}", .{ text, draft });
            defer app.gpa.free(restored);
            try app.input.replace(app.gpa, restored);
            app.menu.inputChanged(app.input.text());
            try app.report(.info, "{d} queued message{s} returned to input", .{ batch.items.items.len, if (batch.items.items.len == 1) "" else "s" });
        }
    }

    fn activityDetail(app: *App) []const u8 {
        if (app.activity.phase == .retrying) return app.retry_detail[0..app.retry_len];
        if (app.activity.phase == .running) return app.transcript.activityDetail(&app.activity_detail, app.activity.tool);
        if (app.activity.phase == .waiting) {
            const task = app.session.tools.background.waitingTask(app.io) orelse return "";
            var elapsed: [64]u8 = undefined;
            return std.fmt.bufPrint(&app.activity_detail, "{s} · {s}", .{ task.id, @import("tui/format.zig").duration(&elapsed, task.elapsed_ms) }) catch "";
        }
        return "";
    }

    fn workDirs(app: *App) ?struct { cwd: []const u8, project: []const u8 } {
        if (app.work_dir == null or app.project == null) {
            var arena: std.heap.ArenaAllocator = .init(app.gpa);
            defer arena.deinit();
            const cwd = std.process.currentPathAlloc(app.io, arena.allocator()) catch return null;
            const root = @import("session/instructions.zig").projectRoot(app.io, arena.allocator(), cwd) catch return null;
            const owned_cwd = app.gpa.dupe(u8, cwd) catch return null;
            const owned_root = app.gpa.dupe(u8, root) catch {
                app.gpa.free(owned_cwd);
                return null;
            };
            app.work_dir = owned_cwd;
            app.project = owned_root;
        }
        return .{ .cwd = app.work_dir.?, .project = app.project.? };
    }

    const open_buf_len = 512 + 1024;
    const Hit = struct { found: open.Found, path: []const u8 };

    /// A clickable file path at screen cell (col, row) inside `entry`; null unless `open` is configured.
    fn hitAt(app: *App, entry: usize, entry_row: u16, col: i16, row: i16, text: *[open_buf_len]u8) ?Hit {
        if (app.cfg.open == null or col < 0 or row < 0) return null;
        const body = (app.body orelse return null).window;
        const x: u16 = @intCast(col);
        const y: u16 = @intCast(row);
        if (x < body.x_off or x >= body.x_off + body.width or y >= body.height or entry >= app.transcript.entries.items.len) return null;
        if (app.files_revision != app.transcript.revision) {
            app.files.clear(app.gpa);
            app.files_revision = app.transcript.revision;
        }
        const e = &app.transcript.entries.items[entry];
        const rows_only = switch (e.kind) {
            .assistant => false,
            .changes => e.open and entry_row >= 1,
            .run => e.open,
            else => return null,
        };
        var grs: [512]open.Gr = undefined;
        var n: usize = 0;
        const x_off: u16 = @intCast(body.x_off);
        var c: u16 = x_off;
        while (c < x_off + body.width and n < grs.len) {
            const cell = app.vx.screen.readCell(c, y) orelse break;
            const width: u16 = @max(1, cell.char.width);
            grs[n] = .{ .col = c, .width = width, .text = cell.char.grapheme };
            n += 1;
            c += width;
        }
        const found = (if (rows_only) open.changeRowAt(grs[0..n], x, text[0..512]) else open.tokenAt(grs[0..n], x, text[0..512])) orelse return null;
        const dirs = app.workDirs() orelse return null;
        const path = app.files.find(app.gpa, app.io, dirs.cwd, dirs.project, found.token.path, text[512..]) orelse return null;
        return .{ .found = found, .path = path };
    }

    fn openClick(app: *App, entry: usize, entry_row: u16, m: vaxis.Mouse) bool {
        var text: [open_buf_len]u8 = undefined;
        const hit = app.hitAt(entry, entry_row, m.col, m.row, &text) orelse return false;
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        const argv = open.argv(arena.allocator(), app.cfg.open.?, hit.path, hit.found.token.line) catch return true;
        open.launch(app.io, app.environ, argv) catch {
            app.notice = std.fmt.bufPrint(&app.notice_buf, "Could not run {s}", .{std.fs.path.basename(argv[0])}) catch null;
        };
        return true;
    }

    fn titleLine(app: *App) []const u8 {
        if (!app.title_loaded) {
            if (app.title_project) |old| app.gpa.free(old);
            if (app.title_branch) |old| app.gpa.free(old);
            app.title_project = null;
            app.title_branch = null;
            if (app.workDirs()) |dirs| {
                const name = std.fs.path.basename(dirs.project);
                app.title_project = app.gpa.dupe(u8, if (name.len == 0) dirs.project else name) catch null;
                app.title_branch = title.readBranch(app.io, app.gpa, dirs.project);
            }
            app.title_loaded = true;
        }
        const project = app.title_project orelse return "";
        return title.compose(&app.title_buf, project, app.title_branch, app.cfg.model, app.cfg.effectiveEffort());
    }

    fn clickEntry(app: *App, entry: usize, row: u16) void {
        const frame = app.body orelse return;
        if (entry >= app.transcript.entries.items.len) return;
        const e = &app.transcript.entries.items[entry];
        const control_hit = e.control(frame.window, row) orelse return;
        e.toggleControl(control_hit);
        app.scroll.toggled(frame.top, control_hit.action == null and app.transcript.latestDetails() == entry);
    }

    pub fn toggleSimple(app: *App) !void {
        const simple = !app.cfg.simple;
        @import("config.zig").saveSimple(app.gpa, app.io, app.session.options.home, simple) catch |err| {
            try app.report(.err, "could not save simple mode: {s}", .{@errorName(err)});
            return;
        };
        app.cfg.simple = simple;
        app.session.cfg.simple = simple;
        app.selection.clear();
        app.hovered = null;
    }

    fn toggleEntry(app: *App, index: usize) void {
        app.transcript.toggle(index);
        const frame = app.body orelse return;
        app.scroll.toggled(frame.top, app.transcript.latestDetails() == index);
    }

    fn render(app: *App) !void {
        try app.menu.load(app.io, app.input.text(), app.session);
        app.menu.sync(app.io, &app.input, app.session);
        var visible_input: *Editor = &app.input;
        if (app.flow.takesText()) {
            try app.flow.display(&app.prompt_text, app.gpa);
            try app.prompt_view.replace(app.gpa, app.prompt_text.items);
            visible_input = &app.prompt_view;
        }
        app.input.ghost = if (app.turn == null and !app.flow.active() and !app.menu.isPinned()) app.prediction.visible(&app.input) else "";
        const menu = app.menu.items(app.input.text());
        for (menu) |*candidate| if (candidate.command == .reflect and candidate.value == null) {
            candidate.detail = commands.reflectHelp(&app.reflect_help, reflect.issueRepo(app));
        };
        if (app.scroll.pending != 0 and (!app.selection.active or app.selection.history == null)) app.selection.clear();
        if (app.scroll.pending != 0 or app.selection.dragged) {
            app.hovered = null;
            app.link = null;
        }
        const empty = app.transcript.entries.items.len == 0;
        if (!empty) app.title_loaded = false;
        const heading = if (empty and !app.signed_out) app.titleLine() else "";
        app.body = view.drawFrame(app.vx.window(), app.transcript.entries.items, visible_input, &app.scroll, menu, @min(app.menu.sel, menu.len -| 1), .{
            .cfg = app.cfg,
            .user_bg = app.user_bg,
            .code_bg = app.code_bg,
            .hovered = app.hovered,
            .hovered_row = app.hovered_row,
            .hover_bg = app.hover_bg,
            .usage = app.usage,
            .steps = app.steps,
            .background_count = app.background_count,
            .context = app.context,
            .busy = if (app.turn != null) app.activity.label(app.io) else null,
            .notice = app.notice,
            .detail = app.activityDetail(),
            .hint = if (app.flow.active()) app.flow.hint(&app.flow_hint) else if (app.menu.isPinned()) "Choose a service" else "",
            .signed_out = app.signed_out,
            .title = heading,
            .revision = app.transcript.revision,
        }, &app.status_text);
        if (app.link) |l| if (l.row < app.vx.screen.height) for (l.x0..@min(@as(usize, l.x1) + 1, app.vx.screen.width)) |col| {
            const cell = &app.vx.screen.buf[@as(usize, l.row) * app.vx.screen.width + col];
            cell.style.ul_style = .single;
            cell.default = false;
        };
        if (app.selection.active and app.selection.history != null) {
            if (app.body) |body| app.scroll.top = body.top;
        }
        app.selection.updateHistory(app.body, app.transcript.entries.items);
        app.selection.highlightHistory(&app.vx.screen, app.body, app.transcript.entries.items);
        try app.vx.render(app.w);
        try app.w.flush();
    }
};

fn hoverBackground(bg: [3]u8) vaxis.Color {
    const light = @as(u32, bg[0]) * 299 + @as(u32, bg[1]) * 587 + @as(u32, bg[2]) * 114 > 128_000;
    var rgb: [3]u8 = undefined;
    for (bg, 0..) |base, i| rgb[i] = if (light) base -| 18 else base +| 18;
    return .{ .rgb = rgb };
}

fn hoverFallback(scheme: ?vaxis.Color.Scheme) vaxis.Color {
    return switch (scheme orelse return .default) {
        .light => .{ .rgb = .{ 237, 237, 237 } },
        .dark => .{ .rgb = .{ 18, 18, 18 } },
    };
}

fn codeBackground(bg: [3]u8) vaxis.Color {
    const light = @as(u32, bg[0]) * 299 + @as(u32, bg[1]) * 587 + @as(u32, bg[2]) * 114 > 128_000;
    var rgb: [3]u8 = undefined;
    for (bg, 0..) |base, i| rgb[i] = if (light) base -| 10 else base +| 10;
    return .{ .rgb = rgb };
}

fn userBackground(bg: [3]u8) vaxis.Color {
    const light = @as(u32, bg[0]) * 299 + @as(u32, bg[1]) * 587 + @as(u32, bg[2]) * 114 > 128_000;
    const accent = if (light) [3]u8{ 40, 80, 150 } else [3]u8{ 120, 160, 230 };
    var rgb: [3]u8 = undefined;
    for (bg, accent, 0..) |base, tint, i| rgb[i] = @intCast((@as(u16, base) * 7 + tint) / 8);
    return .{ .rgb = rgb };
}

test "stream events are paced while interaction and completion refresh immediately" {
    const t = std.testing;
    try t.expectEqual(Frames.Refresh.animation, Event.refresh(.tick));
    try t.expectEqual(Frames.Refresh.content, Event.refresh(.{ .delta = .{ .kind = .text, .text = &.{}, .step = 1 } }));
    try t.expectEqual(Frames.Refresh.immediate, Event.refresh(.done));
    try t.expectEqual(Frames.Refresh.immediate, Event.refresh(.{ .key_press = .{ .codepoint = vaxis.Key.escape } }));
    try t.expectEqual(Frames.Refresh.immediate, Event.refresh(.paste_end));
}

test "code tint is a neutral shade subtler than the user tint" {
    const dark = codeBackground(.{ 0, 0, 0 }).rgb;
    const light = codeBackground(.{ 255, 255, 255 }).rgb;
    try std.testing.expectEqual([3]u8{ 10, 10, 10 }, dark);
    try std.testing.expectEqual([3]u8{ 245, 245, 245 }, light);
}

test "user message tint preserves dark and light terminal contrast" {
    const dark = userBackground(.{ 0, 0, 0 }).rgb;
    const light = userBackground(.{ 255, 255, 255 }).rgb;
    try std.testing.expect(dark[0] < 32 and dark[1] < 32 and dark[2] < 32);
    try std.testing.expect(light[0] > 220 and light[1] > 220 and light[2] > 220);
    try std.testing.expect(dark[2] > dark[0]);
    try std.testing.expect(light[2] > light[0]);
}

fn isNewline(key: vaxis.Key, pasting: bool) bool {
    const enter = vaxis.Key.enter;
    return (pasting and key.matches(enter, .{})) or key.matches(enter, .{ .shift = true }) or
        key.matches(enter, .{ .alt = true }) or key.matches('j', .{ .ctrl = true });
}

test "wheel scrolls during history selection and ignores non-press wheel events" {
    const gpa = std.testing.allocator;
    var vx: vaxis.Vaxis = undefined;
    vx.screen = try vaxis.Screen.init(gpa, .{ .cols = 8, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    defer vx.screen.deinit(gpa);
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = gpa;
    app.vx = &vx;
    app.selection = .{};
    app.scroll = .{};
    app.notice = null;
    app.transcript = .{};
    defer app.transcript.deinit(gpa);
    try app.transcript.add(gpa, .info, "one\ntwo\nthree\nfour");
    app.body = .{ .top = .{}, .window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 8, .height = 3, .screen = &vx.screen } };
    for ([_]vaxis.Mouse.Button{ .wheel_up, .wheel_down }) |button| {
        _ = try app.handle(.{ .mouse = .{ .col = 0, .row = 0, .button = .left, .mods = .{}, .type = .press } });
        const pressed = app.selection;
        _ = try app.handle(.{ .mouse = .{ .col = 2, .row = 0, .button = button, .mods = .{}, .type = .press } });
        try std.testing.expectEqualDeep(pressed, app.selection);
        try std.testing.expectEqual(@as(i64, if (button == .wheel_up) -3 else 3), app.scroll.pending);
        app.scroll.pending = 0;
        for ([_]vaxis.Mouse.Type{ .release, .drag, .motion }) |kind| {
            _ = try app.handle(.{ .mouse = .{ .col = 7, .row = 2, .button = button, .mods = .{}, .type = kind } });
            try std.testing.expectEqualDeep(pressed, app.selection);
            try std.testing.expectEqual(@as(i64, 0), app.scroll.pending);
        }
        app.selection.active = false;
        _ = try app.handle(.{ .mouse = .{ .col = 2, .row = 0, .button = button, .mods = .{}, .type = .press } });
        try std.testing.expectEqualDeep(selection.Selection{}, app.selection);
        app.scroll.pending = 0;
    }
}

test "key entry stays out of the editor, its history and drafts" {
    const gpa = std.testing.allocator;
    var app: App = undefined;
    app.gpa = gpa;
    app.flow = .{ .gpa = gpa };
    defer app.flow.deinit();
    app.input = .{};
    defer app.input.deinit(gpa);
    app.menu = .init(gpa);
    defer app.menu.deinit();
    app.paste_buf = .empty;
    defer app.paste_buf.deinit(gpa);
    app.selection = .{};
    app.notice = null;
    app.pasting = false;
    app.turn = null;
    try app.input.insert(gpa, "draft message");
    try app.flow.startKey("openai", "OpenAI");
    const secret = "sk-secret";
    for (0..secret.len) |i| _ = try app.onKey(.{ .codepoint = secret[i], .text = secret[i .. i + 1] });
    try std.testing.expectEqualStrings(secret, app.flow.text.items);
    _ = try app.handle(.paste_start);
    _ = try app.onKey(.{ .codepoint = 'Z', .text = "Z" });
    _ = try app.handle(.paste_end);
    try std.testing.expectEqualStrings(secret ++ "Z", app.flow.text.items);
    try std.testing.expectEqualStrings("draft message", app.input.text());
    try std.testing.expectEqual(@as(usize, 0), app.input.history.items.len);
    try std.testing.expect(app.input.draft == null and app.input.blocks.items.len == 0);
    _ = try app.onKey(.{ .codepoint = vaxis.Key.escape });
    try std.testing.expect(!app.flow.active());
    try std.testing.expectEqual(@as(usize, 0), app.flow.text.items.len);
    try std.testing.expectEqualStrings("draft message", app.input.text());
}

test "bracketed paste buffers newline and slash keys without executing them" {
    const gpa = std.testing.allocator;
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = gpa;
    app.input = .{};
    defer app.input.deinit(gpa);
    app.paste_buf = .empty;
    defer app.paste_buf.deinit(gpa);
    app.menu = .init(gpa);
    defer app.menu.deinit();
    app.notice = null;
    _ = try app.handle(.paste_start);
    _ = try app.onKey(.{ .codepoint = '/', .text = "/help" });
    for (0..5) |_| {
        _ = try app.onKey(.{ .codepoint = 'j', .mods = .{ .ctrl = true } });
        _ = try app.onKey(.{ .codepoint = 'x', .text = "x" });
    }
    try std.testing.expectEqualStrings("", app.input.text());
    _ = try app.handle(.paste_end);
    try std.testing.expectEqualStrings("[Pasted #1 · 6 lines · /help]", app.input.text());
    const expanded = try app.input.expanded(gpa);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings("/help\nx\nx\nx\nx\nx", expanded);
}

test "ctrl+c quits only on a second consecutive press" {
    const t = std.testing;
    var vx: vaxis.Vaxis = undefined;
    vx.screen = try vaxis.Screen.init(t.allocator, .{ .cols = 8, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    defer vx.screen.deinit(t.allocator);
    var app: App = undefined;
    app.flow = .{ .gpa = t.allocator };
    app.signed_out = false;
    app.gpa = t.allocator;
    app.io = t.io;
    app.vx = &vx;
    app.menu = .init(t.allocator);
    defer app.menu.deinit();
    app.input = .{};
    defer app.input.deinit(t.allocator);
    app.selection = .{};
    app.pasting = false;
    app.turn = null;
    app.notice = null;
    app.quit_armed = false;
    app.session = undefined;
    const ctrl_c: vaxis.Key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } };
    try t.expect(try app.onKey(ctrl_c));
    try t.expect(app.quit_armed);
    try t.expectEqualStrings("press ctrl+c again to quit", app.notice.?);
    try t.expect(try app.onKey(.{ .codepoint = 'x', .text = "x" }));
    try t.expect(!app.quit_armed);
    try t.expect(try app.onKey(ctrl_c));
    try t.expect(!try app.onKey(ctrl_c));
}

var clipboard_reads: usize = 0;

fn countingClipboard(_: std.mem.Allocator) clipboard.Result {
    clipboard_reads += 1;
    return .no_image;
}

test "empty or whitespace-only paste reads the clipboard image like Ctrl+V" {
    const gpa = std.testing.allocator;
    var app: App = undefined;
    app.flow = .{ .gpa = gpa };
    app.signed_out = false;
    app.gpa = gpa;
    app.input = .{};
    defer app.input.deinit(gpa);
    app.paste_buf = .empty;
    defer app.paste_buf.deinit(gpa);
    app.menu = .init(gpa);
    app.cfg = .{ .provider = .custom, .base_url = "", .api_key = "", .model = "m", .custom_vision = true };
    app.notice = null;
    clipboard.reader_override = countingClipboard;
    defer clipboard.reader_override = null;
    clipboard_reads = 0;

    _ = try app.handle(.paste_start);
    _ = try app.handle(.paste_end);
    try std.testing.expectEqual(@as(usize, 1), clipboard_reads);
    try std.testing.expectEqualStrings("No image in clipboard", app.notice.?);

    _ = try app.handle(.paste_start);
    try app.paste_buf.appendSlice(gpa, " \n\t");
    _ = try app.handle(.paste_end);
    try std.testing.expectEqual(@as(usize, 2), clipboard_reads);

    _ = try app.handle(.paste_start);
    try app.paste_buf.appendSlice(gpa, "text");
    _ = try app.handle(.paste_end);
    try std.testing.expectEqual(@as(usize, 2), clipboard_reads);
    try std.testing.expectEqualStrings("text", app.input.text());
}

test "usage snapshots refresh the footer without reading the running Session" {
    const t = std.testing;
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = t.allocator;
    app.usage = .{ .prompt_tokens = 99999, .completion_tokens = 999 };
    app.context = 800;
    app.steps = 9;
    _ = try app.handle(.{ .usage = .{ .tokens = .{}, .context = 800, .steps = 0 } });
    try t.expectEqualDeep(provider.Usage{}, app.usage);
    try t.expectEqual(@as(u32, 0), app.steps);
    const usage: provider.Usage = .{ .prompt_tokens = 1200, .completion_tokens = 50, .prompt_cache_hit_tokens = 600 };
    _ = try app.handle(.{ .usage = .{ .tokens = usage, .context = 1250, .steps = 1 } });
    try t.expectEqualDeep(usage, app.usage);
    try t.expectEqual(@as(u64, 1250), app.context);
    try t.expectEqual(@as(u32, 1), app.steps);
    _ = try app.handle(.{ .usage = .{ .tokens = usage, .context = 200, .steps = 1 } });
    try t.expectEqual(@as(u64, 200), app.context);
    try t.expectEqualDeep(usage, app.usage);
}

test "Turn throttles model data events but sends request boundaries immediately" {
    const t = std.testing;
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    var turn: Turn = undefined;
    turn.loop = &loop;
    turn.last_model_activity = null;
    const start: std.Io.Clock.Timestamp = .now(t.io, .awake);
    for (0..100) |i| {
        try turn.modelActivityAt(.data, start.addDuration(.{ .raw = .fromMilliseconds(@intCast(i * 10)), .clock = .awake }));
    }
    const first = (try loop.tryEvent()).?.model_activity;
    try t.expectEqual(ModelActivity.data, first.state);
    try t.expectEqualDeep(start, first.at);
    try t.expectEqual(@as(?Event, null), try loop.tryEvent());
    const before = start.addDuration(.{ .raw = .fromMilliseconds(999), .clock = .awake });
    try turn.modelActivityAt(.data, before);
    try t.expectEqual(@as(?Event, null), try loop.tryEvent());
    const next = start.addDuration(.{ .raw = .fromMilliseconds(1000), .clock = .awake });
    try turn.modelActivityAt(.data, next);
    const second = (try loop.tryEvent()).?.model_activity;
    try t.expectEqual(ModelActivity.data, second.state);
    try t.expectEqualDeep(next, second.at);
    try t.expectEqual(@as(?Event, null), try loop.tryEvent());

    try turn.modelActivityAt(.started, next);
    const before_next = next.addDuration(.{ .raw = .fromMilliseconds(999), .clock = .awake });
    for (0..100) |_| try turn.modelActivityAt(.data, before_next);
    try t.expectEqual(ModelActivity.started, (try loop.tryEvent()).?.model_activity.state);
    try t.expectEqual(@as(?Event, null), try loop.tryEvent());
    const after_start = next.addDuration(.{ .raw = .fromMilliseconds(1000), .clock = .awake });
    try turn.modelActivityAt(.data, after_start);
    try turn.modelActivityAt(.finished, after_start);
    try turn.modelActivityAt(.started, after_start);
    try turn.modelActivityAt(.data, after_start);
    for ([_]ModelActivity{ .data, .finished, .started }) |state| {
        try t.expectEqual(state, (try loop.tryEvent()).?.model_activity.state);
    }
    try t.expectEqual(@as(?Event, null), try loop.tryEvent());

    const silence = after_start.addDuration(.{ .raw = .fromMilliseconds(30_000), .clock = .awake });
    try turn.modelActivityAt(.data, silence);
    const resumed = (try loop.tryEvent()).?.model_activity;
    try t.expectEqual(ModelActivity.data, resumed.state);
    try t.expectEqualDeep(silence, resumed.at);
    try t.expectEqual(@as(?Event, null), try loop.tryEvent());
}

test "turn_end forwards by value and defers bills until terminal content" {
    const t = std.testing;
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    var turn: Turn = undefined;
    turn.gpa = t.allocator;
    turn.loop = &loop;
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = t.allocator;
    app.transcript = .{};
    defer app.transcript.deinit(t.allocator);
    app.pending_bill = null;
    app.turn_runs = 0;
    inline for (.{ .completed, .canceled, .failed }) |status_value| {
        const summary: TurnSummary = .{ .status = status_value, .steps = 2, .timing = .{ .wall_ms = 1000 } };
        try app.transcript.add(t.allocator, .assistant, "answer");
        const before = app.transcript.entries.items.len;
        try Turn.emit(&turn, .{ .turn_end = summary });
        const event = (try loop.tryEvent()).?;
        try t.expectEqualDeep(summary, event.turn_end);
        _ = try app.handle(event);
        try t.expectEqual(before, app.transcript.entries.items.len);
        try t.expectEqualDeep(summary, app.pending_bill.?);
        if (status_value != .completed) try app.transcript.add(t.allocator, .err, @tagName(status_value));
        try app.appendBill();
        const entries = app.transcript.entries.items;
        try t.expectEqual(EntryKind.bill, entries[entries.len - 1].kind);
        try t.expectEqualStrings(if (status_value == .completed) "answer" else @tagName(status_value), entries[entries.len - 2].text.items);
        try t.expect(app.pending_bill == null);
        const count = entries.len;
        try app.appendBill();
        try t.expectEqual(count, app.transcript.entries.items.len);
    }
}

test "insertion notifications reach the queued user entry" {
    const t = std.testing;
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    var turn: Turn = undefined;
    turn.loop = &loop;
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = t.allocator;
    app.transcript = .{};
    defer app.transcript.deinit(t.allocator);
    try app.transcript.add(t.allocator, .user, "interjection");
    app.transcript.entries.items[0].queued = 42;
    try Turn.userInserted(&turn, 42);
    _ = try app.handle((try loop.tryEvent()).?);
    try t.expectEqual(@as(?u64, null), app.transcript.entries.items[0].queued);
}

test "background events own their payload and maintain running count" {
    const t = std.testing;
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    var turn: Turn = undefined;
    turn.gpa = t.allocator;
    turn.loop = &loop;
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = t.allocator;
    app.transcript = .{};
    app.background_count = 0;
    defer app.transcript.deinit(t.allocator);
    var id = [_]u8{ 'a', '1' };
    try Turn.emit(&turn, .{ .background = .{ .id = &id, .kind = .agent, .state = .started } });
    id[1] = '2';
    const started = (try loop.tryEvent()).?;
    try t.expectEqualStrings("a1", started.background.id);
    _ = try app.handle(started);
    try t.expectEqual(@as(usize, 1), app.background_count);
    try t.expectEqual(@as(usize, 0), app.transcript.entries.items.len);
    try Turn.emit(&turn, .{ .background = .{ .id = "a1", .kind = .agent, .state = .finished, .ok = true, .result = "{\"ok\":true,\"text\":\"done\"}" } });
    _ = try app.handle((try loop.tryEvent()).?);
    try t.expectEqual(@as(usize, 0), app.background_count);
    try t.expectEqual(EntryKind.background, app.transcript.entries.items[0].kind);
    try t.expectEqualStrings("a1 agent · completed", app.transcript.entries.items[0].label.items);
}

test "quit drains owned events and closed queues reject Turn payloads without leaks" {
    const t = std.testing;
    for ([_]bool{ false, true }) |closed| {
        var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
        var vx: vaxis.Vaxis = undefined;
        vx.screen = try vaxis.Screen.init(t.allocator, .{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
        defer vx.screen.deinit(t.allocator);
        var app: App = .{
            .gpa = t.allocator,
            .io = t.io,
            .session = undefined,
            .cfg = undefined,
            .vx = &vx,
            .w = undefined,
            .loop = &loop,
            .environ = undefined,
            .menu = .init(t.allocator),
            .activity = .start(t.io, .thinking),
        };
        if (closed) loop.queue.close(error.Closed) else for (0..2) |_| try loop.postEvent(.{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });
        var session: Session = undefined;
        session.steps = 0;
        var turn: Turn = .{ .gpa = t.allocator, .session = &session, .loop = &loop, .text = "" };
        const changes: []const @import("tools/diff.zig").Change = &.{.{ .path = "changed.txt", .added = 1, .removed = 0, .diff = "+new\n" }};
        const events = [_]SessionEvent{
            .{ .step = .{ .n = 1, .effort = "high" } },
            .{ .delta = .{ .kind = .text, .text = "answer" } },
            .{ .run_start = "tools.write({})" },
            .{ .run_end = .{ .background_id = "r1", .ok = true, .output = "registered", .changes = changes, .tool_summary = .{ .counts = &.{.{ .name = "write", .count = 1 }} } } },
            .{ .retry = .{ .attempt = 1, .delay_ms = 0, .reason = "retry" } },
            .{ .notice = "notice" },
            .{ .progress = .{ .id = "b1", .prompt = "work", .tools = &.{"bash"}, .files = &.{"changed.txt"}, .superseded_by = "b2" } },
            .{ .background = .{ .id = "r1", .kind = .run, .state = .finished, .ok = false, .completion = .{
                .step = 1,
                .run_index = 0,
                .ok = false,
                .output = "stopped",
                .run_ms = 1,
                .tool_bytes = 0,
                .calls = &.{.{ .name = "bash", .start_ms = 0, .end_ms = 1, .ok = false, .run_index = 0 }},
                .calls_omitted = 0,
                .changes = changes,
            } } },
        };
        for (events) |event| {
            if (closed) try t.expectError(error.Closed, Turn.emit(&turn, event)) else try Turn.emit(&turn, event);
        }
        if (!closed) {
            try loop.postEvent(.{ .failed = .{ .message = try t.allocator.dupe(u8, "canceled"), .reason = .canceled } });
            try loop.postEvent(.{ .issue = try t.allocator.dupe(u8, "issue outcome") });
            try t.expect(try app.handle(try loop.nextEvent()));
            try t.expect(!try app.handle(try loop.nextEvent()));
        }
        app.deinit();
        try t.expect(try loop.queue.isEmpty());
    }
}

test "shutdown closes a full queue before joining the canceled Turn" {
    const t = std.testing;
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    while (try loop.tryPostEvent(.tick)) {}
    var app: App = .{
        .gpa = t.allocator,
        .io = t.io,
        .session = undefined,
        .cfg = undefined,
        .vx = undefined,
        .w = undefined,
        .loop = &loop,
        .environ = undefined,
        .menu = .init(t.allocator),
        .activity = .start(t.io, .thinking),
    };
    app.turn = blk: {
        const turn = try t.allocator.create(Turn);
        errdefer t.allocator.destroy(turn);
        const text = try t.allocator.dupe(u8, "initial");
        errdefer t.allocator.free(text);
        turn.* = .{ .gpa = t.allocator, .session = undefined, .loop = &loop, .text = text };
        turn.thread = try std.Thread.spawn(.{}, struct {
            fn work(worker: *Turn) void {
                while (!worker.cancel.load(.acquire)) std.Thread.yield() catch {};
                std.testing.expectError(error.Closed, Turn.emit(worker, .{ .background = .{ .id = "r1", .kind = .run, .state = .finished, .result = "canceled" } })) catch @panic("shutdown accepted an event");
            }
        }.work, .{turn});
        break :blk turn;
    };
    app.deinit();
    try t.expect(try loop.queue.isEmpty());
    try t.expectError(error.Closed, loop.postEvent(.tick));
}

test "Step events own effort and Runs keep their generating Step metadata" {
    const t = std.testing;
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = t.allocator;
    app.io = t.io;
    app.transcript = .{};
    defer app.transcript.deinit(t.allocator);
    app.step_effort = null;
    defer app.clearStepEffort();
    app.activity = .start(t.io, .thinking);
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    var turn: Turn = undefined;
    turn.gpa = t.allocator;
    turn.loop = &loop;
    var effort = [_]u8{ 'h', 'i', 'g', 'h' };
    try Turn.emit(&turn, .{ .step = .{ .n = 3, .effort = &effort } });
    effort[0] = 'x';
    _ = try app.handle((try loop.tryEvent()).?);
    try t.expectEqual(@as(u32, 3), app.live_steps);
    app.turn_runs = 0;
    _ = try app.handle(.{ .run_start = .{ .code = try t.allocator.dupe(u8, "tools.read({})"), .step = 3 } });
    _ = try app.handle(.{ .run_end = .{ .ok = true, .output = try t.allocator.dupe(u8, "out"), .changes = .{} } });
    _ = try app.handle(.{ .step = .{ .n = 4, .effort = try t.allocator.dupe(u8, "low") } });
    try t.expectEqualStrings("high", app.transcript.entries.items[0].step_effort.?.effort);
    try t.expectEqualStrings("low", app.step_effort.?.effort);
    try t.expectEqualStrings("Run", app.transcript.entries.items[0].label.items);
}

test "Run summary survives event queue and original summary destruction" {
    const t = std.testing;
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = t.allocator;
    app.io = t.io;
    app.transcript = .{};
    defer app.transcript.deinit(t.allocator);
    app.activity = .start(t.io, .running);
    app.turn_runs = 0;
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    var turn: Turn = undefined;
    turn.gpa = t.allocator;
    turn.loop = &loop;
    try app.transcript.startRun(t.allocator, "// tools.llm(");
    {
        const source = try (ToolSummary{ .counts = &.{.{ .name = "edit", .count = 2 }}, .omitted = 3 }).clone(t.allocator);
        defer source.deinit(t.allocator);
        try Turn.emit(&turn, .{ .run_end = .{ .ok = true, .output = "done", .tool_summary = source } });
    }
    _ = try app.handle((try loop.tryEvent()).?);
    try t.expectEqualStrings("edit", app.transcript.entries.items[0].tool_summary.?.counts[0].name);
    try t.expectEqual(@as(u64, 2), app.transcript.entries.items[0].tool_summary.?.counts[0].count);
    try t.expect(std.mem.startsWith(u8, app.transcript.entries.items[0].label.items, "Run · edit ×2 · +3"));
}

test "cancel returns queued messages alongside an existing draft" {
    const a = std.testing.allocator;
    var session: Session = undefined;
    session.gpa = a;
    session.io = std.testing.io;
    session.inbox = .{};
    defer {
        var remaining = session.inbox.take(session.io);
        remaining.deinit(a);
    }
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = a;
    app.session = &session;
    app.transcript = .{};
    defer app.transcript.deinit(a);
    app.input = .{};
    defer app.input.deinit(a);
    app.menu = .init(a);
    defer app.menu.deinit();
    const id = try session.enqueue("queued request");
    try app.transcript.add(a, .user, "queued request");
    app.transcript.entries.items[0].queued = id;
    try app.input.insert(a, "draft");
    try app.finishQueued(false);
    try std.testing.expectEqualStrings("queued request\n\ndraft", app.input.text());
    try std.testing.expectEqualStrings("1 queued message returned to input", app.transcript.entries.items[0].text.items);
}

test "stream events distinguish reasoning text and Run arguments through retry" {
    const t = std.testing;
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = t.allocator;
    app.io = t.io;
    app.transcript = .{};
    defer app.transcript.deinit(t.allocator);
    app.scroll = .{};
    app.activity = .start(t.io, .thinking);
    app.activity.last_progress = app.activity.since.addDuration(.{ .raw = .fromMilliseconds(-45000), .clock = .awake });
    _ = try app.handle(.{ .delta = .{ .kind = .reasoning, .text = try t.allocator.dupe(u8, "hidden"), .step = 1 } });
    try t.expectEqual(status.Phase.reasoning, app.activity.phase);
    try t.expect(app.activity.label(t.io).quiet_ms < 1000);
    try t.expectEqual(@as(usize, 0), app.transcript.entries.items.len);
    _ = try app.handle(.{ .delta = .{ .kind = .text, .text = try t.allocator.dupe(u8, "draft"), .step = 1 } });
    try t.expectEqual(status.Phase.writing, app.activity.phase);
    _ = try app.handle(.{ .retry = try t.allocator.dupe(u8, "attempt 2/5") });
    try t.expect(app.transcript.entries.items[0].retry_placeholder);
    _ = try app.handle(.{ .model_activity = .{ .state = .script, .at = .now(t.io, .awake) } });
    try t.expectEqual(status.Phase.scripting, app.activity.phase);
    try t.expect(app.transcript.entries.items[0].retry_placeholder);
    _ = try app.handle(.{ .delta = .{ .kind = .text, .text = try t.allocator.dupe(u8, "answer"), .step = 1 } });
    try t.expectEqual(@as(usize, 1), app.transcript.entries.items.len);
    try t.expectEqualStrings("answer", app.transcript.lastAnswer().?);
}

test "terminal, interaction and Run boundaries flush visible backlog" {
    const events = [_]Event{
        .done,                                                              .{ .failed = .{ .message = @constCast("canceled"), .reason = .canceled } },
        .{ .retry = @constCast("retry") },                                  .{ .run_start = .{ .code = @constCast("run"), .step = 1 } },
        .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } }, .{ .mouse = .{ .col = 0, .row = 0, .button = .wheel_up, .type = .press, .mods = .{} } },
    };
    for (events) |event| try std.testing.expect(event.flushesVisible());
    try std.testing.expect(!Event.flushesVisible(.tick));
    try std.testing.expect(!Event.flushesVisible(.{ .delta = .{ .kind = .text, .text = @constCast("text"), .step = 1 } }));
}

fn shown(app: *App) []const @import("tui/commands.zig").Candidate {
    app.menu.sync(app.io, &app.input, app.session);
    return app.menu.items(app.input.text());
}

fn typeText(app: *App, text: []const u8) !void {
    for (text) |c| _ = try app.onKey(.{ .codepoint = c, .text = &.{c} });
}

test "@ completion: Enter and Tab accept instead of sending, directories keep completing, Esc only closes" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = gpa;
    app.io = std.testing.io;
    app.session = &session;
    app.input = .{};
    defer app.input.deinit(gpa);
    app.menu = .init(gpa);
    defer app.menu.deinit();
    app.notice = null;
    app.pasting = false;
    app.selection = .{};
    app.turn = null;
    const ix = try gpa.create(@import("tui/paths.zig").Index);
    ix.* = .{ .gpa = gpa, .io = std.testing.io };
    app.menu.index = ix;
    try ix.setEntries(&.{ "src/", "src/main.zig", "src/tui.zig", "my dir/", "my dir/a b.txt", "README.md" });

    try typeText(&app, "see @sr");
    try std.testing.expect(shown(&app).len > 0);
    _ = try app.onKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings("see @src/", app.input.text());
    try std.testing.expectEqualStrings("src/tui.zig", shown(&app)[0].label);
    try typeText(&app, "ma");
    _ = try app.onKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqualStrings("see @src/main.zig ", app.input.text());
    try std.testing.expectEqual(@as(usize, 0), shown(&app).len);

    try typeText(&app, "@RE");
    _ = try app.onKey(.{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(@as(usize, 0), shown(&app).len);
    try std.testing.expectEqualStrings("see @src/main.zig @RE", app.input.text());
    try typeText(&app, "A");
    _ = try app.onKey(.{ .codepoint = vaxis.Key.down });
    _ = try app.onKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings("see @src/main.zig @README.md ", app.input.text());

    try app.input.replace(gpa, "");
    try typeText(&app, "@my");
    _ = try app.onKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqualStrings("@\"my dir/", app.input.text());
    try typeText(&app, "a");
    _ = try app.onKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqualStrings("@\"my dir/a b.txt\" ", app.input.text());
}

test "@ completion ignores emails and pasted mentions" {
    const gpa = std.testing.allocator;
    var session: Session = undefined;
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = gpa;
    app.io = std.testing.io;
    app.session = &session;
    app.input = .{};
    defer app.input.deinit(gpa);
    app.menu = .init(gpa);
    defer app.menu.deinit();
    app.paste_buf = .empty;
    defer app.paste_buf.deinit(gpa);
    app.notice = null;
    app.pasting = false;
    app.selection = .{};
    app.turn = null;
    const ix = try gpa.create(@import("tui/paths.zig").Index);
    ix.* = .{ .gpa = gpa, .io = std.testing.io };
    app.menu.index = ix;
    try ix.setEntries(&.{ "src/", "bob.txt" });

    try typeText(&app, "mail a@b");
    app.menu.sync(app.io, &app.input, app.session);
    try std.testing.expectEqual(@as(usize, 0), shown(&app).len);

    try app.input.replace(gpa, "");
    _ = try app.handle(.paste_start);
    try typeText(&app, "@sr");
    _ = try app.handle(.paste_end);
    app.menu.sync(app.io, &app.input, app.session);
    try std.testing.expectEqualStrings("@sr", app.input.text());
    try std.testing.expectEqual(@as(usize, 0), shown(&app).len);
    try typeText(&app, "c");
    app.menu.sync(app.io, &app.input, app.session);
    try std.testing.expectEqual(@as(usize, 1), shown(&app).len);
}

fn clickApp(app: *App, vx: *vaxis.Vaxis, top: @import("tui/viewport.zig").Anchor, scroll_top: ?@import("tui/viewport.zig").Anchor) void {
    app.vx = vx;
    app.selection = .{};
    app.scroll = .{ .top = scroll_top };
    app.notice = null;
    app.cfg = .{ .base_url = "", .api_key = "", .model = "mock" };
    app.link = null;
    app.hovered_row = null;
    app.files = .{};
    app.files_revision = 0;
    app.project = null;
    app.work_dir = null;
    app.transcript = .{};
    app.body = .{ .top = top, .window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 8, .height = 8, .screen = &vx.screen } };
}

fn mouseEvent(col: i16, row: i16, kind: vaxis.Mouse.Type) Event {
    return .{ .mouse = .{ .col = col, .row = row, .button = if (kind == .release) .none else .left, .mods = .{}, .type = kind } };
}

test "click toggles only the Run title row under the pointer across wrapped lines and scroll offsets" {
    const gpa = std.testing.allocator;
    var vx: vaxis.Vaxis = undefined;
    vx.screen = try vaxis.Screen.init(gpa, .{ .cols = 8, .rows = 8, .x_pixel = 0, .y_pixel = 0 });
    defer vx.screen.deinit(gpa);
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = gpa;
    clickApp(&app, &vx, .{}, .{});
    defer app.transcript.deinit(gpa);
    try app.transcript.add(gpa, .info, "aaaa bbbb cccc");
    try app.transcript.startRun(gpa, "tools.read({})");
    try app.transcript.startRun(gpa, "tools.read({})");
    const items = app.transcript.entries.items;
    const win = app.body.?.window;
    const first_run = @as(i16, @intCast(items[0].height(win))) + 1;
    const second_run = first_run + @as(i16, @intCast(items[1].height(win))) + 1;
    try std.testing.expect(items[0].height(win) > 1);

    _ = try app.handle(mouseEvent(3, first_run + 1, .press));
    _ = try app.handle(mouseEvent(3, first_run + 1, .release));
    try std.testing.expect(!items[1].open and !items[2].open);
    _ = try app.handle(mouseEvent(3, first_run, .press));
    _ = try app.handle(mouseEvent(3, first_run, .release));
    try std.testing.expect(items[1].open and !items[2].open);
    try std.testing.expectEqual(@as(?@TypeOf(app.scroll.top.?), .{}), app.scroll.top);

    _ = try app.handle(mouseEvent(0, 0, .press));
    _ = try app.handle(mouseEvent(0, 0, .release));
    try std.testing.expect(items[1].open and !items[2].open);

    app.transcript.toggle(1);
    app.body.?.top = .{ .entry = 1 };
    const shifted = second_run - first_run;
    _ = try app.handle(mouseEvent(2, shifted, .press));
    _ = try app.handle(mouseEvent(2, shifted, .release));
    try std.testing.expect(!items[1].open and items[2].open);
}

test "a drag across a Run title selects instead of toggling" {
    const gpa = std.testing.allocator;
    var vx: vaxis.Vaxis = undefined;
    vx.screen = try vaxis.Screen.init(gpa, .{ .cols = 8, .rows = 8, .x_pixel = 0, .y_pixel = 0 });
    defer vx.screen.deinit(gpa);
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    app.gpa = gpa;
    app.io = std.testing.io;
    clickApp(&app, &vx, .{}, .{});
    defer app.transcript.deinit(gpa);
    try app.transcript.startRun(gpa, "tools.read({})");
    _ = try app.handle(mouseEvent(0, 0, .press));
    _ = try app.handle(mouseEvent(4, 0, .drag));
    try std.testing.expect(app.selection.dragged);
    app.selection.active = false;
    try std.testing.expect(!app.transcript.entries.items[0].open);
    try std.testing.expectEqual(@as(?@import("tui/selection/history.zig").Position, null), app.selection.takeClick());
}

test "toggling pins the view unless following the latest details entry" {
    const gpa = std.testing.allocator;
    var vx: vaxis.Vaxis = undefined;
    vx.screen = try vaxis.Screen.init(gpa, .{ .cols = 8, .rows = 8, .x_pixel = 0, .y_pixel = 0 });
    defer vx.screen.deinit(gpa);
    var app: App = undefined;
    app.flow = .{ .gpa = std.testing.allocator };
    app.signed_out = false;
    clickApp(&app, &vx, .{ .entry = 1, .row = 2 }, null);
    defer app.transcript.deinit(gpa);
    try app.transcript.startRun(gpa, "a");
    try app.transcript.startRun(gpa, "b");
    try app.transcript.add(gpa, .assistant, "done");
    app.scroll.top = .{ .entry = 1, .row = 2 };
    app.toggleEntry(1);
    try std.testing.expectEqual(@as(?@TypeOf(app.scroll.top.?), .{ .entry = 1, .row = 2 }), app.scroll.top);
    app.transcript.toggle(1);
    app.scroll.top = null;
    app.toggleEntry(0);
    try std.testing.expectEqualDeep(app.body.?.top, app.scroll.top.?);
    try std.testing.expect(app.scroll.top != null);
    app.scroll.top = null;
    try std.testing.expectEqual(@as(?usize, 1), app.transcript.latestDetails());
    app.toggleEntry(1);
    try std.testing.expect(app.scroll.top == null);
    try std.testing.expect(app.transcript.entries.items[1].open);
}

test "hover changes only between toggleable entries and summary clicks exclude details" {
    const a = std.testing.allocator;
    var vx: vaxis.Vaxis = undefined;
    vx.screen = try vaxis.Screen.init(a, .{ .cols = 8, .rows = 8, .x_pixel = 0, .y_pixel = 0 });
    defer vx.screen.deinit(a);
    var app: App = undefined;
    app.gpa = a;
    app.flow = .{ .gpa = a };
    clickApp(&app, &vx, .{}, .{});
    app.hovered = null;
    defer app.transcript.deinit(a);
    try app.transcript.startRun(a, "console.log('details')");
    try app.transcript.entries.items[0].files.appendSlice(a, "read x");
    const motion: Event = .{ .mouse = .{ .col = 3, .row = 0, .type = .motion, .button = .none, .mods = .{} } };
    _ = try app.handle(motion);
    try std.testing.expectEqual(@as(?usize, 0), app.hovered);
    _ = try app.handle(motion);
    try std.testing.expectEqual(@as(?usize, 0), app.hovered);
    app.selection.dragged = true;
    _ = try app.handle(motion);
    try std.testing.expectEqual(@as(?usize, null), app.hovered);
    app.selection.clear();
    const rows = app.transcript.entries.items[0].toggleRows(app.body.?.window);
    app.clickEntry(0, rows - 1);
    try std.testing.expect(app.transcript.entries.items[0].open);
    app.clickEntry(0, rows);
    try std.testing.expect(app.transcript.entries.items[0].open);
    _ = try app.handle(.{ .mouse = .{ .col = 3, .row = 7, .type = .motion, .button = .none, .mods = .{} } });
    try std.testing.expectEqual(@as(?usize, null), app.hovered);
}

test "hover uses neutral eighteen-level contrast and scheme fallback" {
    const t = std.testing;
    try t.expectEqualDeep(vaxis.Color{ .rgb = .{ 18, 18, 18 } }, hoverBackground(.{ 0, 0, 0 }));
    try t.expectEqualDeep(vaxis.Color{ .rgb = .{ 237, 237, 237 } }, hoverBackground(.{ 255, 255, 255 }));
    try t.expectEqualDeep(hoverBackground(.{ 0, 0, 0 }), hoverFallback(.dark));
    try t.expectEqualDeep(hoverBackground(.{ 255, 255, 255 }), hoverFallback(.light));
    try t.expectEqualDeep(vaxis.Color.default, hoverFallback(null));
}

test "Simple key variants and command toggle silently and persist" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var session: Session = undefined;
    session.options.home = root;
    session.cfg = .{ .base_url = "", .api_key = "", .model = "mock" };
    var app: App = undefined;
    app.gpa = t.allocator;
    app.io = t.io;
    app.session = &session;
    app.cfg = session.cfg;
    app.selection = .{};
    app.input = .{};
    app.pasting = false;
    for ([_]bool{ false, true }) |shift| {
        _ = try app.onKey(.{ .codepoint = @import("tui/mode.zig").key, .mods = .{ .ctrl = true, .shift = shift } });
        try t.expectEqual(!shift, app.cfg.simple);
        try t.expect(app.notice == null);
    }
    try commands.execute(&app, .simple, "", "/simple");
    try t.expect(app.cfg.simple);
}

test "file paths are links only when open is configured; a click runs the command and reports a failed start" {
    const gpa = std.testing.allocator;
    var vx: vaxis.Vaxis = undefined;
    vx.screen = try vaxis.Screen.init(gpa, .{ .cols = 40, .rows = 8, .x_pixel = 0, .y_pixel = 0 });
    defer vx.screen.deinit(gpa);
    var app: App = undefined;
    app.flow = .{ .gpa = gpa };
    app.signed_out = false;
    app.gpa = gpa;
    app.io = std.testing.io;
    clickApp(&app, &vx, .{}, .{});
    app.body.?.window.width = 40;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    app.environ = &env;
    defer app.transcript.deinit(gpa);
    defer app.files.deinit(gpa);
    defer for ([_]?[]u8{ app.project, app.work_dir }) |owned| if (owned) |text| gpa.free(text);
    const line = "see build.zig:12 and nope.zig now";
    try app.transcript.add(gpa, .assistant, line);
    _ = app.body.?.window.printSegment(.{ .text = line }, .{ .wrap = .none });

    const hover = mouseEvent(6, 0, .motion);
    _ = try app.handle(hover);
    try std.testing.expectEqual(@as(?Link, null), app.link);

    app.cfg.open = "/usr/bin/env true {path}:{line}";
    _ = try app.handle(hover);
    try std.testing.expectEqual(@as(?Link, .{ .row = 0, .x0 = 4, .x1 = 15 }), app.link);
    _ = try app.handle(mouseEvent(20, 0, .motion));
    try std.testing.expectEqual(@as(?Link, null), app.link);
    _ = try app.handle(mouseEvent(0, 0, .motion));
    try std.testing.expectEqual(@as(?Link, null), app.link);

    _ = try app.handle(mouseEvent(6, 0, .press));
    _ = try app.handle(mouseEvent(6, 0, .release));
    try std.testing.expectEqual(@as(?[]const u8, null), app.notice);

    app.cfg.open = "/nonexistent/open-tool {path}";
    _ = try app.handle(mouseEvent(6, 0, .press));
    _ = try app.handle(mouseEvent(6, 0, .release));
    try std.testing.expectEqualStrings("Could not run open-tool", app.notice.?);
}

test "scrolled nested Run headings toggle without collapsing the Run or its siblings" {
    const a = std.testing.allocator;
    var vx: vaxis.Vaxis = undefined;
    vx.screen = try vaxis.Screen.init(a, .{ .cols = 120, .rows = 40, .x_pixel = 0, .y_pixel = 0 });
    defer vx.screen.deinit(a);
    var app: App = undefined;
    app.gpa = a;
    app.io = std.testing.io;
    app.flow = .{ .gpa = a };
    clickApp(&app, &vx, .{ .row = 2 }, .{ .row = 2 });
    app.body.?.window.width = 120;
    app.body.?.window.height = 40;
    defer app.transcript.deinit(a);
    try app.transcript.startRun(a, "script-body");
    try app.transcript.endRun(a, true, "result-body", 1, .{});
    const e = &app.transcript.entries.items[0];
    e.open = true;
    _ = e.print(app.body.?.window.child(.{ .y_off = -2 }), true);
    _ = try app.handle(mouseEvent(5, 3, .motion));
    try std.testing.expectEqual(@as(?usize, 0), app.hovered);
    try std.testing.expectEqual(@as(?u16, 5), app.hovered_row);
    _ = try app.handle(mouseEvent(5, 3, .press));
    _ = try app.handle(mouseEvent(5, 3, .release));
    try std.testing.expect(e.open and e.details.script_open);
    try std.testing.expect(e.details.result_open == null);
    try std.testing.expectEqual(@as(u16, 2), app.scroll.top.?.row);
    app.clickEntry(0, 6);
    try std.testing.expect(e.open and e.details.script_open);
    _ = try app.handle(mouseEvent(5, 3, .press));
    _ = try app.handle(mouseEvent(9, 3, .drag));
    try std.testing.expect(app.selection.dragged);
    try std.testing.expect(app.selection.takeClick() == null);
    try std.testing.expect(e.details.script_open);
}
