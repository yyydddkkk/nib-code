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
const Turn = @import("tui/turn.zig").Turn;
const Ticker = @import("tui/turn.zig").Ticker;
const bill = @import("tui/bill.zig");
const TurnSummary = @import("session/events.zig").TurnSummary;
const ToolSummary = @import("session/tool_summary.zig").Summary;

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    paste_start,
    paste_end,
    mouse: vaxis.Mouse,
    tick,
    model_activity: struct { state: ModelActivity, at: std.Io.Clock.Timestamp },
    /// Slices are owned by the receiver.
    step: struct { n: u32, effort: []u8, source: provider.EffortSource },
    delta: struct { kind: provider.Kind, text: []u8, step: u32 },
    run_start: struct { code: []u8, step: u32 },
    run_end: struct { ok: bool, output: []u8, changes: ChangeText, tool_summary: ?ToolSummary = null },
    retry: []u8,
    notice: []u8,
    user_inserted: u64,
    done,
    turn_end: TurnSummary,
    usage: struct { tokens: provider.Usage, context: u64, steps: u32 },
    progress: @import("session/events.zig").Progress,
    background: @FieldType(SessionEvent, "background"),
    failed: []u8,
    /// One outcome line from automatic issue filing, owned by the receiver.
    issue: []u8,
    issues_done,
};

/// `session` may already hold history (a resumed Session); it is shown first.
pub fn run(init: std.process.Init, session: *Session) !void {
    const io = init.io;
    const gpa = init.gpa;

    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    const w = tty.writer();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(gpa, w);

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(w);
    try w.flush();
    try vx.queryTerminal(w, .fromSeconds(1));
    try vx.setBracketedPaste(w, true);
    // Selection needs cell coordinates; some terminals claim SGR pixel mode yet report cells.
    vx.caps.sgr_pixels = false;
    try vx.setMouseMode(w, true);

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .session = session,
        .environ = init.environ_map,
        .cfg = session.cfg,
        .vx = &vx,
        .w = w,
        .loop = &loop,
        .menu = .init(gpa),
        .activity = .start(io, .thinking),
        .context = session.context_tokens,
    };
    defer app.deinit();
    var ticker: Ticker = .{ .io = io, .loop = &loop };
    const ticker_thread = try std.Thread.spawn(.{}, Ticker.work, .{&ticker});
    defer {
        ticker.stop.store(true, .release);
        ticker_thread.join();
    }

    try app.transcript.addHistory(gpa, session.history.items);
    for (session.history.items) |m| {
        if (std.mem.eql(u8, m.role, "user")) try app.input.remember(gpa, m.content orelse "");
    }
    if (app.cfg.missingKey()) try app.transcript.add(gpa, .err, "no API key: set DEEPSEEK_API_KEY (or NIB_API_KEY). /js <code> still works.");

    while (try app.handle(try loop.nextEvent())) {
        ticker.busy.store(app.turn != null or app.session.tools.background.anyPending(io), .release);
        try app.render();
    }
}

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    session: *Session,
    cfg: provider.Config,
    vx: *vaxis.Vaxis,
    w: *std.Io.Writer,
    loop: *vaxis.Loop(Event),
    environ: *const std.process.Environ.Map,
    selection: selection.Selection = .{},
    /// Shown on the status line until the next key or click; not part of the transcript.
    notice: ?[]const u8 = null,
    notice_buf: [256]u8 = undefined,
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
    activity: status.Activity,
    usage: provider.Usage = .{},
    steps: u32 = 0,
    context: u64 = 0,
    turn: ?*Turn = null,
    // turn_end precedes done/failed; append only after their terminal content.
    pending_bill: ?TurnSummary = null,

    const command = commands.execute;
    const saveReflection = reflect.saveReflection;
    const stopReflecting = reflect.stopReflecting;

    fn deinit(app: *App) void {
        if (app.turn) |t| {
            t.cancel.store(true, .release);
            t.finish();
        }
        app.stopReflecting();
        app.clearStepEffort();
        if (app.issues) |job| job.finish();
        app.menu.deinit();
        app.transcript.deinit(app.gpa);
        app.input.deinit(app.gpa);
        app.paste_buf.deinit(app.gpa);
    }

    fn idleProgress(ctx: *anyopaque, progress: @import("session/events.zig").Progress) !void {
        const app: *App = @ptrCast(@alignCast(ctx));
        try app.transcript.progress(app.gpa, progress);
    }

    /// False to quit.
    fn handle(app: *App, event: Event) !bool {
        const gpa = app.gpa;
        switch (event) {
            .key_press => |k| return app.onKey(k),
            .paste_start => {
                app.pasting = true;
                app.paste_buf.clearRetainingCapacity();
            },
            .paste_end => {
                app.pasting = false;
                try app.input.paste(gpa, app.paste_buf.items);
                app.menu.inputChanged(app.input.text());
                app.paste_buf.clearRetainingCapacity();
            },
            .mouse => |m| {
                if (m.type == .press) app.notice = null;
                if (m.button == .wheel_up or m.button == .wheel_down) {
                    if (m.type == .press and !app.selection.active) {
                        app.selection.clear();
                        app.scroll.pending += if (m.button == .wheel_up) @as(i64, -3) else 3;
                    }
                } else if (app.selection.mouse(m, &app.vx.screen)) {
                    const text = try app.selection.text(gpa, &app.vx.screen);
                    defer gpa.free(text);
                    if (std.mem.trim(u8, text, " \n").len == 0) {
                        app.selection.clear();
                    } else {
                        try selection.copy(app.vx, app.w, gpa, app.io, app.environ, text);
                        app.notice = std.fmt.bufPrint(&app.notice_buf, "copied {d} chars", .{std.unicode.utf8CountCodepoints(text) catch text.len}) catch null;
                    }
                }
            },
            .tick => if (app.turn == null) {
                app.session.tools.progress.sink = .{ .ctx = app, .emit = idleProgress };
                defer app.session.tools.progress.sink = null;
                try app.session.tools.progress.drain(app.io);
            },
            .model_activity => |activity| {
                if (activity.state == .started and app.activity.phase != .compacting) app.activity.set(app.io, .thinking);
                app.activity.modelActivity(activity.state, activity.at);
            },
            .winsize => |ws| {
                app.selection.clear();
                try app.vx.resize(gpa, app.w, ws);
            },
            .step => |s| {
                app.clearStepEffort();
                app.step_effort = .{ .effort = s.effort, .source = s.source };
                app.live_steps = s.n;
            },
            .delta => |d| {
                defer gpa.free(d.text);
                app.live_steps = d.step;
                if (app.activity.phase != .compacting) app.activity.set(app.io, if (d.kind == .reasoning) .thinking else .writing);
                try app.transcript.appendDelta(gpa, d.kind, d.text);
            },
            .run_start => |r| {
                defer gpa.free(r.code);
                app.live_steps = r.step;
                app.activity.set(app.io, .running);
                try app.transcript.startRunWithEffort(gpa, r.code, app.step_effort);
            },
            .run_end => |r| {
                defer gpa.free(r.output);
                defer if (r.tool_summary) |summary| summary.deinit(gpa);
                const elapsed = app.activity.label(app.io).ms;
                app.activity.set(app.io, .thinking);
                try app.transcript.endRunWithSummary(gpa, r.ok, r.output, elapsed, r.changes, r.tool_summary);
            },
            .retry, .notice => |msg| {
                defer gpa.free(msg);
                if (std.mem.startsWith(u8, msg, "retry")) app.activity.set(app.io, .retrying);
                try app.transcript.add(gpa, .info, msg);
            },
            .usage => |u| {
                app.usage = u.tokens;
                app.context = u.context;
                app.steps = u.steps;
            },
            .progress => |p| {
                var owned = p;
                defer owned.deinit(gpa);
                try app.transcript.progress(gpa, p);
            },
            .background => |b| {
                defer gpa.free(b.id);
                defer if (b.result) |result| gpa.free(result);
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
                const canceled = app.turn.?.cancel.load(.acquire);
                try app.finishTurn();
                try app.saveReflection();
                try app.appendBill();
                try app.finishQueued(!canceled);
            },
            .issue => |msg| {
                defer gpa.free(msg);
                try app.transcript.add(gpa, .info, msg);
            },
            .issues_done => {
                if (app.issues) |job| job.finish();
                app.issues = null;
            },
            .failed => |msg| {
                defer gpa.free(msg);
                app.stopReflecting();
                const canceled = app.turn.?.cancel.load(.acquire);
                try app.transcript.add(gpa, if (canceled) .info else .err, if (canceled) "canceled" else msg);
                try app.finishTurn();
                try app.appendBill();
                try app.finishQueued(false);
            },
        }
        return true;
    }

    fn onKey(app: *App, k: vaxis.Key) !bool {
        app.notice = null;
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
        const page = @max(app.vx.window().height / 2, 1);
        if (k.matches('c', .{ .ctrl = true })) return false;
        if (k.matches('d', .{ .ctrl = true }) and input.text().len == 0) return false;
        const selected = app.menu.selected(input.text());
        const before = std.hash.Wyhash.hash(0, input.text());
        var submitted: ?[]u8 = null;

        if (selected != null and k.matches(vaxis.Key.escape, .{})) {
            app.menu.closed = true;
        } else if (selected != null and k.matches(vaxis.Key.up, .{})) {
            app.menu.move(input.text(), false);
        } else if (selected != null and k.matches(vaxis.Key.down, .{})) {
            app.menu.move(input.text(), true);
        } else if (selected != null and (k.matches(vaxis.Key.tab, .{}) or (k.matches(vaxis.Key.enter, .{}) and !app.pasting and !selected.?.runs()))) {
            const completion = try selected.?.completion(gpa);
            defer gpa.free(completion);
            try input.replace(gpa, completion);
        } else if (selected != null and k.matches(vaxis.Key.enter, .{}) and !app.pasting) {
            const line = try selected.?.line(gpa);
            defer gpa.free(line);
            try input.replace(gpa, line);
            if (app.turn == null or commands.allowedWhileBusy(line)) submitted = try input.take(gpa);
        } else if (k.matches(vaxis.Key.escape, .{})) {
            if (app.turn) |t| t.cancel.store(true, .release);
        } else if (k.matches(vaxis.Key.page_up, .{})) {
            app.scroll.pending -= page;
        } else if (k.matches(vaxis.Key.page_down, .{})) {
            app.scroll.pending = if (app.scroll.top != null) std.math.maxInt(i32) else page;
        } else if (k.matches('o', .{ .ctrl = true })) {
            app.transcript.toggleExpanded();
        } else if (k.matches(vaxis.Key.up, .{ .shift = true })) {
            app.scroll.pending -= 3;
        } else if (k.matches(vaxis.Key.down, .{ .shift = true })) {
            app.scroll.pending += 3;
        } else if (isNewline(k, app.pasting)) {
            try input.insert(gpa, "\n");
        } else if (k.matches(vaxis.Key.enter, .{})) {
            if (app.turn == null or commands.parse(input.text()) == null or commands.allowedWhileBusy(input.text())) submitted = try input.take(gpa);
        } else {
            _ = try input.key(gpa, k);
        }
        if (std.hash.Wyhash.hash(0, input.text()) != before) app.menu.inputChanged(input.text());
        if (submitted) |line| try app.submit(line);
        return true;
    }

    /// Takes ownership of `line`.
    fn submit(app: *App, line: []u8) !void {
        const gpa = app.gpa;
        app.scroll = .{};
        app.menu.forgetSessions();
        if (line.len == 0) return gpa.free(line);
        if (commands.parse(line)) |parsed| {
            defer gpa.free(line);
            return switch (parsed) {
                .unknown => |name| app.report(.err, "unknown command /{s} · /help lists commands", .{name}),
                .known => |c| app.command(c.command, c.arg, line),
            };
        }
        if (app.cfg.missingKey()) {
            gpa.free(line);
            return app.transcript.add(gpa, .err, "no API key");
        }
        if (app.turn != null) {
            defer gpa.free(line);
            const id = try app.session.enqueue(line);
            try app.transcript.add(gpa, .user, line);
            app.transcript.entries.items[app.transcript.entries.items.len - 1].queued = id;
            return;
        }
        try app.startTurn(line);
    }

    /// Takes ownership of text without interpreting slash commands.
    fn startTurn(app: *App, text: []u8) !void {
        errdefer app.gpa.free(text);
        try app.transcript.add(app.gpa, .user, text);
        app.turn = try Turn.spawn(app.gpa, app.session, app.loop, text, false);
        app.live_steps = 0;
        app.activity = .start(app.io, .thinking);
    }

    pub fn report(app: *App, kind: EntryKind, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(app.gpa, fmt, args);
        defer app.gpa.free(message);
        try app.transcript.add(app.gpa, kind, message);
    }

    fn appendBill(app: *App) !void {
        const summary = app.pending_bill orelse return;
        var text: bill.Text = .{};
        try app.transcript.add(app.gpa, .bill, text.format(summary, std.math.maxInt(u16)));
        app.pending_bill = null;
    }

    fn clearStepEffort(app: *App) void {
        if (app.step_effort) |effort| app.gpa.free(effort.effort);
        app.step_effort = null;
    }

    fn finishTurn(app: *App) !void {
        app.clearStepEffort();
        app.turn.?.finish();
        app.turn = null;
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
        }
    }

    fn render(app: *App) !void {
        try app.menu.load(app.io, app.input.text(), app.session);
        const menu = app.menu.items(app.input.text());
        if (app.scroll.pending != 0) app.selection.clear();
        view.draw(app.vx.window(), app.transcript.entries.items, &app.input, &app.scroll, menu, @min(app.menu.sel, menu.len -| 1), .{
            .cfg = app.cfg,
            .usage = app.usage,
            .steps = app.steps,
            .current_step = @max(1, app.live_steps),
            .background_count = app.background_count,
            .context = app.context,
            .busy = if (app.turn != null) app.activity.label(app.io) else null,
            .notice = app.notice,
        }, &app.status_text);
        app.selection.highlight(&app.vx.screen);
        try app.vx.render(app.w);
        try app.w.flush();
    }
};

fn isNewline(key: vaxis.Key, pasting: bool) bool {
    const enter = vaxis.Key.enter;
    return (pasting and key.matches(enter, .{})) or key.matches(enter, .{ .shift = true }) or
        key.matches(enter, .{ .alt = true }) or key.matches('j', .{ .ctrl = true });
}

test "wheel does not interrupt a selection and resumes scrolling after release" {
    const gpa = std.testing.allocator;
    var vx: vaxis.Vaxis = undefined;
    vx.screen = try vaxis.Screen.init(gpa, .{ .cols = 8, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    defer vx.screen.deinit(gpa);
    for (0..3) |col| {
        vx.screen.writeCell(@intCast(col), 0, .{ .char = .{ .grapheme = "abc"[col .. col + 1], .width = 1 } });
    }
    var app: App = undefined;
    app.gpa = gpa;
    app.vx = &vx;
    app.selection = .{};
    app.scroll = .{};
    app.notice = null;
    for ([_]vaxis.Mouse.Button{ .wheel_up, .wheel_down }) |button| {
        _ = try app.handle(.{ .mouse = .{ .col = 0, .row = 0, .button = .left, .mods = .{}, .type = .press } });
        const pressed = app.selection;
        _ = try app.handle(.{ .mouse = .{ .col = 0, .row = 0, .button = button, .mods = .{}, .type = .press } });
        try std.testing.expectEqualDeep(pressed, app.selection);
        try std.testing.expectEqual(@as(i64, 0), app.scroll.pending);
        _ = try app.handle(.{ .mouse = .{ .col = 2, .row = 0, .button = .left, .mods = .{}, .type = .drag } });
        const dragged = app.selection;
        for ([_]vaxis.Mouse.Type{ .press, .release, .drag, .motion }) |kind| {
            _ = try app.handle(.{ .mouse = .{ .col = 7, .row = 2, .button = button, .mods = .{}, .type = kind } });
            try std.testing.expectEqualDeep(dragged, app.selection);
            try std.testing.expectEqual(@as(i64, 0), app.scroll.pending);
        }
        try std.testing.expect(app.selection.mouse(.{ .col = 2, .row = 0, .button = .left, .mods = .{}, .type = .release }, &vx.screen));
        const text = try app.selection.text(gpa, &vx.screen);
        defer gpa.free(text);
        try std.testing.expectEqualStrings("abc", text);
        const released = app.selection;
        for ([_]vaxis.Mouse.Type{ .release, .drag, .motion }) |kind| {
            _ = try app.handle(.{ .mouse = .{ .col = 7, .row = 2, .button = button, .mods = .{}, .type = kind } });
            try std.testing.expectEqualDeep(released, app.selection);
            try std.testing.expectEqual(@as(i64, 0), app.scroll.pending);
        }
        _ = try app.handle(.{ .mouse = .{ .col = 7, .row = 2, .button = button, .mods = .{}, .type = .press } });
        try std.testing.expectEqualDeep(selection.Selection{}, app.selection);
        try std.testing.expectEqual(@as(i64, if (button == .wheel_up) -3 else 3), app.scroll.pending);
        app.scroll.pending = 0;
    }
}

test "bracketed paste buffers newline and slash keys without executing them" {
    const gpa = std.testing.allocator;
    var app: App = undefined;
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
    try std.testing.expectEqualStrings("[Pasted #1 · 6 lines]", app.input.text());
    const expanded = try app.input.expanded(gpa);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings("/help\nx\nx\nx\nx\nx", expanded);
}

test "usage snapshots refresh the footer without reading the running Session" {
    const t = std.testing;
    var app: App = undefined;
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
    app.gpa = t.allocator;
    app.transcript = .{};
    defer app.transcript.deinit(t.allocator);
    app.pending_bill = null;
    inline for (.{ .completed, .canceled, .failed }) |status_value| {
        const summary: TurnSummary = .{ .status = status_value, .steps = 2, .timing = .{ .wall_ms = 1000, .race_branches = 5 } };
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
        try t.expect(std.mem.endsWith(u8, entries[entries.len - 1].text.items, " · race ×5 branches"));
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
    try t.expectEqualStrings("a1 agent · ok · done", app.transcript.entries.items[0].label.items);
}

test "Step events own effort and Runs keep their generating Step metadata" {
    const t = std.testing;
    var app: App = undefined;
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
    try Turn.emit(&turn, .{ .step = .{ .n = 3, .effort = &effort, .source = .guard } });
    effort[0] = 'x';
    _ = try app.handle((try loop.tryEvent()).?);
    try t.expectEqual(@as(u32, 3), app.live_steps);
    _ = try app.handle(.{ .run_start = .{ .code = try t.allocator.dupe(u8, "tools.read({})"), .step = 3 } });
    _ = try app.handle(.{ .run_end = .{ .ok = true, .output = try t.allocator.dupe(u8, "out"), .changes = .{} } });
    _ = try app.handle(.{ .step = .{ .n = 4, .effort = try t.allocator.dupe(u8, "low"), .source = .model } });
    try t.expectEqualStrings("high", app.transcript.entries.items[0].step_effort.?.effort);
    try t.expectEqualStrings("low", app.step_effort.?.effort);
    try t.expect(std.mem.endsWith(u8, app.transcript.entries.items[0].label.items, " · high (guard)"));
}

test "Run summary survives event queue and original summary destruction" {
    const t = std.testing;
    var app: App = undefined;
    app.gpa = t.allocator;
    app.io = t.io;
    app.transcript = .{};
    defer app.transcript.deinit(t.allocator);
    app.activity = .start(t.io, .running);
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
    try t.expect(std.mem.startsWith(u8, app.transcript.entries.items[0].label.items, "edit ×2, +3 · "));
}
