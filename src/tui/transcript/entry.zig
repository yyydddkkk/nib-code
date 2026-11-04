const std = @import("std");
const vaxis = @import("vaxis");
const provider = @import("../../provider.zig");
const long_text = @import("../long_text.zig");
const markdown = @import("../markdown.zig");
const bill = @import("../bill.zig");
const Progress = @import("../../session/events.zig").Progress;
const agent_tree = @import("../agent_tree.zig");
const AgentTree = agent_tree.Tree;
const BackgroundKind = @FieldType(@import("../../session/events.zig").Background, "kind");
const ToolSummary = @import("../../session/tool_summary.zig").Summary;
const ChangeText = @import("changes.zig").ChangeText;
const label = @import("label.zig");
const actualToolSummary = label.actualToolSummary;
const toolSummary = label.toolSummary;
const appendAction = label.appendAction;
const appendTokens = label.appendTokens;
const appendPreview = label.appendPreview;

pub const run_output_lines = 12;
pub const max_diff_lines = 60;
pub const max_segments = 8 + max_diff_lines + 2;

pub const Kind = enum { user, assistant, run, background, info, err, bill };

pub const Entry = struct {
    kind: Kind,
    queued: ?u64 = null,
    /// For `.run`: the script.
    text: std.ArrayList(u8) = .empty,
    /// For `.run`: the first lines of its output.
    output: std.ArrayList(u8) = .empty,
    /// For `.run`: see `ChangeText`.
    changes: ChangeText = .{},
    agents: std.ArrayList(Progress) = .empty,
    invocations: std.ArrayList(Invocation) = .empty,
    run_number: usize = 0,
    tool_summary: ?ToolSummary = null,
    task_id: ?[]const u8 = null,
    agent_tree: AgentTree = .{},
    /// One-line summary of a collapsible entry. vaxis keeps printed slices
    /// until render, so this must outlive draw(); see `refreshLabel`.
    label: std.ArrayList(u8) = .empty,
    run: enum { running, ok, failed } = .running,
    elapsed_ms: u64 = 0,
    step_effort: ?provider.StepEffort = null,
    /// Collapsible entries share the transcript ctrl+o state.
    open: bool = false,
    cached: ?struct { width: u16, len: usize, open: bool, rows: u16 } = null,

    const Invocation = struct {
        id: []const u8,
        kind: BackgroundKind,
        invocation: usize,
        background: bool,
        result: ?bool = null,
    };

    pub fn deinit(e: *Entry, gpa: std.mem.Allocator) void {
        if (e.task_id) |id| gpa.free(id);
        if (e.step_effort) |effort| gpa.free(effort.effort);
        if (e.tool_summary) |summary| summary.deinit(gpa);
        e.text.deinit(gpa);
        e.output.deinit(gpa);
        e.label.deinit(gpa);
        e.changes.deinit(gpa);
        for (e.agents.items) |*p| p.deinit(gpa);
        e.agents.deinit(gpa);
        for (e.invocations.items) |call| gpa.free(call.id);
        e.invocations.deinit(gpa);
        e.agent_tree.deinit(gpa);
    }

    pub fn refreshLabel(e: *Entry, gpa: std.mem.Allocator) !void {
        e.label.clearRetainingCapacity();
        switch (e.kind) {
            .run => {
                var buf: [512]u8 = undefined;
                const used = if (e.tool_summary) |summary| actualToolSummary(summary, &buf) else toolSummary(e.text.items, &buf);
                var live: std.ArrayList(Progress) = .empty;
                defer live.deinit(gpa);
                for (e.agents.items) |p| if (e.isLive(p)) try live.append(gpa, p);
                const agents = live.items;
                if (agents.len > 0) {
                    if (agents.len == 1) {
                        const p = agents[0];
                        if (p.kind == .bash) {
                            try e.label.print(gpa, "bash · {s} · ", .{if (p.background) "background" else "running"});
                            try appendPreview(gpa, &e.label, p.prompt);
                            try e.label.appendSlice(gpa, " · ");
                            try agent_tree.appendElapsed(gpa, &e.label, p.elapsed_ms);
                            try e.label.print(gpa, " · {s}", .{if (p.background) "background" else @tagName(p.state)});
                        } else {
                            try e.label.print(gpa, "{s} · {s} · step {d}", .{ if (p.race) "race" else "agent", if (p.background) "background" else if (p.race) @tagName(p.state) else "running", p.step });
                            try appendAction(gpa, &e.label, p);
                            try appendTokens(gpa, &e.label, p.usage.prompt_tokens + p.usage.completion_tokens);
                        }
                    } else {
                        var working: usize = 0;
                        var queued: usize = 0;
                        var done: usize = 0;
                        var failed: usize = 0;
                        var bash_count: usize = 0;
                        var race_count: usize = 0;
                        var won: usize = 0;
                        var stopped: usize = 0;
                        var tokens: u64 = 0;
                        for (agents) |p| {
                            if (p.kind == .bash) bash_count += 1;
                            if (p.race) race_count += 1;
                            switch (p.state) {
                                .working => working += 1,
                                .queued => queued += 1,
                                .done => done += 1,
                                .won => won += 1,
                                .stopped => stopped += 1,
                                else => failed += 1,
                            }
                            tokens += p.usage.prompt_tokens + p.usage.completion_tokens;
                        }
                        try e.label.print(gpa, "{s} ×{d} · {s} · {d} working, {d} done", .{ if (race_count == agents.len) "race" else if (bash_count == agents.len) "bash" else if (bash_count == 0) "agent" else "task", agents.len, if (e.run == .running) "running" else "background", working, done });
                        if (queued > 0) try e.label.print(gpa, ", {d} queued", .{queued});
                        if (won > 0) try e.label.print(gpa, ", {d} won", .{won});
                        if (stopped > 0) try e.label.print(gpa, ", {d} stopped", .{stopped});
                        if (failed > 0) try e.label.print(gpa, ", {d} failed", .{failed});
                        if (bash_count < agents.len) try appendTokens(gpa, &e.label, tokens);
                    }
                } else if (e.run == .running) {
                    try e.label.print(gpa, "{s} · running", .{used});
                } else {
                    try e.label.print(gpa, "{s} · {d}.{d}s", .{ used, e.elapsed_ms / 1000, e.elapsed_ms % 1000 / 100 });
                }
                if (e.changes.summary.len > 0) try e.label.print(gpa, " · {s}", .{e.changes.summary});
                if (e.step_effort) |effort| {
                    try e.label.print(gpa, " · {s}{s}", .{ effort.effort, if (effort.source == .guard) " (guard)" else "" });
                }
            },
            .user => {
                try e.label.print(gpa, " … +{d} lines", .{long_text.lines(e.text.items) - 1});
            },
            else => {},
        }
    }

    /// Rows keep their last state; a row is live while its Run runs or its background result is undelivered.
    pub fn isLive(e: *const Entry, p: Progress) bool {
        return e.run == .running or p.background;
    }

    pub fn refreshAgents(e: *Entry, gpa: std.mem.Allocator) !void {
        try e.agent_tree.update(gpa, e.agents.items);
    }

    pub fn collapsible(e: *const Entry) bool {
        return e.kind == .run or e.kind == .background or (e.kind == .user and long_text.isLong(e.text.items));
    }

    pub fn print(e: *const Entry, win: vaxis.Window, commit: bool) u16 {
        if (e.kind == .assistant) return markdown.print(win, e.text.items, commit);
        if (e.kind == .bill) {
            _ = win.print(&.{.{ .text = bill.fit(e.text.items, win.width), .style = .{ .dim = true } }}, .{ .wrap = .none, .commit = commit });
            return 1;
        }
        var segs: [max_segments]vaxis.Segment = undefined;
        const folded = e.collapsible() and !e.open;
        const wrap: @FieldType(vaxis.Window.PrintOptions, "wrap") = if (folded) .none else if (e.kind == .run or e.kind == .background) .grapheme else .word;
        const shown = segments(e, &segs);
        if (e.kind == .run and e.agent_tree.rows.items.len > 0) {
            _ = win.print(shown[0..3], .{ .wrap = .none, .commit = commit });
            const rows = 1 +| e.agent_tree.print(win.child(.{ .y_off = 1 }), commit);
            if (!e.open) return rows;
            const details = win.child(.{ .y_off = @intCast(rows) }).print(shown[4..], .{ .wrap = .grapheme, .commit = commit });
            return rows +| @max(1, details.row +| @intFromBool(details.col > 0));
        }
        if (folded and e.kind == .user) {
            const suffix_width = vaxis.gwidth.gwidth(e.label.items, win.screen.width_method) + @as(u16, if (e.queued != null) 9 else 0);
            const available = win.width -| (suffix_width +| 2);
            var end: usize = 0;
            while (end < segs[1].text.len) {
                const n = end + (std.unicode.utf8ByteSequenceLength(segs[1].text[end]) catch 1);
                if (vaxis.gwidth.gwidth(segs[1].text[0..n], win.screen.width_method) > available) break;
                end = n;
            }
            segs[1].text = segs[1].text[0..end];
        }
        const r = win.print(shown, .{ .wrap = wrap, .commit = commit });
        return if (folded) 1 else @max(1, r.row +| @intFromBool(r.col > 0));
    }

    pub fn height(e: *Entry, win: vaxis.Window) u16 {
        const len = e.text.items.len + e.output.items.len + e.changes.diff.len;
        if (e.cached) |c| {
            if (c.width == win.width and c.len == len and c.open == e.open) return c.rows;
        }
        var measure = win;
        measure.height = std.math.maxInt(u16);
        const rows = e.print(measure, false);
        e.cached = .{ .width = win.width, .len = len, .open = e.open, .rows = rows };
        return rows;
    }

    pub fn segments(e: *const Entry, segs: *[max_segments]vaxis.Segment) []const vaxis.Segment {
        const dim: vaxis.Style = .{ .dim = true };
        switch (e.kind) {
            .user => {
                segs[0] = .{ .text = "› ", .style = .{ .bold = true, .fg = .{ .index = 4 } } };
                const folded = e.collapsible() and !e.open;
                segs[1] = .{ .text = if (folded) e.text.items[0 .. std.mem.indexOfScalar(u8, e.text.items, '\n') orelse e.text.items.len] else e.text.items, .style = .{ .bold = true } };
                var n: usize = 2;
                if (folded) {
                    segs[n] = .{ .text = e.label.items, .style = dim };
                    n += 1;
                }
                if (e.queued != null) {
                    segs[n] = .{ .text = " · queued", .style = dim };
                    n += 1;
                }
                return segs[0..n];
            },
            .assistant => segs[0] = .{ .text = e.text.items },
            .run => {
                segs[0] = switch (e.run) {
                    .running => .{ .text = "◌ ", .style = .{ .fg = .{ .index = 3 } } },
                    .ok => .{ .text = "✓ ", .style = .{ .fg = .{ .index = 2 } } },
                    .failed => .{ .text = "✗ ", .style = .{ .fg = .{ .index = 1 } } },
                };
                const any_live = for (e.agents.items) |p| {
                    if (e.isLive(p)) break true;
                } else false;
                segs[1] = .{ .text = if (any_live) "" else "run ", .style = .{ .fg = .{ .index = 3 }, .bold = true } };
                segs[2] = .{ .text = e.label.items, .style = dim };
                if (!e.open) return segs[0..3];
                segs[3] = .{ .text = "\n" };
                segs[4] = .{ .text = e.text.items, .style = .{ .fg = .{ .index = 3 } } };
                var n: usize = 5;
                if (e.output.items.len > 0) {
                    segs[5] = .{ .text = "\n" };
                    segs[6] = .{ .text = e.output.items, .style = if (e.run == .failed) .{ .fg = .{ .index = 1 }, .dim = true } else dim };
                    n = 7;
                }
                const diff = std.mem.trimEnd(u8, e.changes.diff, "\n");
                if (diff.len == 0) return segs[0..n];
                segs[n] = .{ .text = "\n" };
                n += 1;
                var start: usize = 0;
                while (start < diff.len and n < segs.len) : (n += 1) {
                    const end = if (std.mem.indexOfScalarPos(u8, diff, start, '\n')) |nl| nl + 1 else diff.len;
                    const line = diff[start..end];
                    segs[n] = .{ .text = line, .style = switch (line[0]) {
                        '+' => .{ .fg = .{ .index = 2 } },
                        '-' => .{ .fg = .{ .index = 1 } },
                        ' ' => dim,
                        else => if (std.mem.startsWith(u8, line, "…")) dim else .{ .bold = true },
                    } };
                    start = end;
                }
                return segs[0..n];
            },
            .background => {
                segs[0] = .{ .text = if (e.run == .ok) "✓ " else "✗ ", .style = .{ .fg = .{ .index = if (e.run == .ok) 2 else 1 } } };
                segs[1] = .{ .text = e.label.items, .style = dim };
                if (!e.open) return segs[0..2];
                segs[2] = .{ .text = "\n" };
                segs[3] = .{ .text = e.text.items, .style = dim };
                return segs[0..4];
            },
            .info, .bill => segs[0] = .{ .text = e.text.items, .style = dim },
            .err => segs[0] = .{ .text = e.text.items, .style = .{ .fg = .{ .index = 1 } } },
        }
        return segs[0..1];
    }
};
