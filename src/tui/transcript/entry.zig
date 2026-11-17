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
const run_details = @import("run_details.zig");
const actualToolSummary = label.actualToolSummary;

pub const max_diff_lines = 60;
pub const max_segments = 16;

pub const Kind = enum { user, assistant, run, background, info, err, bill, failure, changes };

pub const Entry = struct {
    kind: Kind,
    simple: bool = false,
    gap: u16 = 1,
    allocator: ?std.mem.Allocator = null,
    markdown_cache: markdown.Cache = .{},
    smooth: ?@import("../smooth.zig").Smooth = null,
    user_bg: vaxis.Color = .default,
    code_bg: vaxis.Color = .default,
    queued: ?u64 = null,
    attempt: usize = 0,
    retry_placeholder: bool = false,
    /// For `.run`: the script.
    text: std.ArrayList(u8) = .empty,
    /// For `.run`: the complete result delivered by Session.
    output: std.ArrayList(u8) = .empty,
    turn_time: std.ArrayList(u8) = .empty,
    hook_notice: std.ArrayList(u8) = .empty,
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
    files: std.ArrayList(u8) = .empty,
    /// Simple-mode title facts, spliced into `label` at `title_files_at`.
    title_files: std.ArrayList(u8) = .empty,
    title_files_at: usize = 0,
    run: enum { running, background, superseded, ok, failed, warning, lost, timed_out, canceled } = .running,
    elapsed_ms: u64 = 0,
    step_effort: ?provider.StepEffort = null,
    /// Collapsible entries share the transcript ctrl+o state.
    open: bool = false,
    details: run_details.State = .{},
    cached: ?struct { width: u16, len: usize, open: bool, rows: u16 } = null,

    const Invocation = struct {
        id: []const u8,
        kind: BackgroundKind,
        invocation: usize,
        background: bool,
        result: ?bool = null,
    };

    pub fn displayText(e: *const Entry) []const u8 {
        return e.text.items[0..if (e.smooth) |s| s.visible else e.text.items.len];
    }

    pub fn deinit(e: *Entry, gpa: std.mem.Allocator) void {
        e.markdown_cache.deinit(gpa);
        if (e.task_id) |id| gpa.free(id);
        if (e.step_effort) |effort| gpa.free(effort.effort);
        if (e.tool_summary) |summary| summary.deinit(gpa);
        e.text.deinit(gpa);
        e.output.deinit(gpa);
        e.turn_time.deinit(gpa);
        e.hook_notice.deinit(gpa);
        e.label.deinit(gpa);
        e.files.deinit(gpa);
        e.title_files.deinit(gpa);
        e.changes.deinit(gpa);
        for (e.agents.items) |*p| p.deinit(gpa);
        e.agents.deinit(gpa);
        for (e.invocations.items) |call| gpa.free(call.id);
        e.invocations.deinit(gpa);
        e.agent_tree.deinit(gpa);
    }

    pub fn refreshLabel(e: *Entry, gpa: std.mem.Allocator) !void {
        e.label.clearRetainingCapacity();
        e.files.clearRetainingCapacity();
        e.title_files.clearRetainingCapacity();
        e.title_files_at = 0;
        switch (e.kind) {
            .run => {
                try e.label.appendSlice(gpa, "Run");
                for (e.agents.items) |p| {
                    if (p.kind == .run or p.superseded_by != null) continue;
                    if (p.state == .failed or p.state == .timed_out or p.state == .canceled) {
                        try e.label.print(gpa, " · {s} {s}", .{ p.id, @import("../format.zig").state(@tagName(p.state)) });
                    }
                }
                if (e.task_id) |id| try e.label.print(gpa, " · {s} {s}", .{ id, switch (e.run) {
                    .background, .running => "running",
                    .failed => "failed",
                    .lost => "lost",
                    .timed_out => "timed out",
                    .canceled => "canceled",
                    else => "completed",
                } });
                var buf: [512]u8 = undefined;
                const used = if (e.tool_summary) |summary| actualToolSummary(summary, e.changes.file_count, &buf) else "";
                if (e.tool_summary) |summary| for (summary.files, 0..) |file, i| {
                    if (i > 0) try e.files.appendSlice(gpa, if (file.duration_ms != null or summary.files[i - 1].duration_ms != null) "\n" else " · ");
                    try e.files.print(gpa, "{s} {s}", .{ file.tool, file.path });
                    try e.title_files.print(gpa, " · {s} {s}", .{ file.tool, file.path });
                    if (file.duration_ms) |ms| {
                        try e.files.print(gpa, " · {d}.{d}s", .{ ms / 1000, ms % 1000 / 100 });
                        if (file.failed) try e.files.appendSlice(gpa, " · failed");
                    }
                };
                e.title_files_at = e.label.items.len;
                if (used.len > 0) try e.label.print(gpa, " · {s}", .{used});
                for (e.agents.items) |p| {
                    if (!p.background or p.kind == .run or p.state == .failed or p.state == .timed_out or p.state == .canceled) continue;
                    try e.label.print(gpa, " · {s} {s}", .{ p.id, if (p.state == .queued) "queued" else if (p.state == .working) "running" else "waiting" });
                }
                if (e.run == .running) try e.label.appendSlice(gpa, " · running");
            },
            .user => {
                try e.label.print(gpa, " … +{d} lines", .{long_text.lines(e.text.items) - 1});
            },
            else => {},
        }
    }

    pub fn hasWarning(e: *const Entry) bool {
        if (e.hook_notice.items.len > 0) return true;
        for (e.agents.items) |p| if (p.superseded_by == null and (p.state == .failed or p.state == .timed_out or p.state == .canceled)) return true;
        return false;
    }

    pub fn changesOnly(e: *const Entry) bool {
        if (e.run != .ok or e.hasWarning()) return false;
        const summary = e.tool_summary orelse return false;
        if (summary.counts.len == 0 or summary.omitted > 0 or summary.failures == null or summary.failures.? > 0) return false;
        for (summary.counts) |call| {
            if (!std.mem.eql(u8, call.name, "edit") and !std.mem.eql(u8, call.name, "write")) return false;
        }
        for (summary.files) |file| if (file.failed) return false;
        return true;
    }

    /// Rows keep their last state; a row is live while its Run runs or its background result is undelivered.
    pub fn isLive(e: *const Entry, p: Progress) bool {
        return e.run == .running or p.background;
    }

    pub fn refreshAgents(e: *Entry, gpa: std.mem.Allocator) !void {
        try e.agent_tree.update(gpa, e.agents.items);
    }

    pub fn collapsible(e: *const Entry) bool {
        return e.kind == .run or e.kind == .background or e.kind == .failure or e.kind == .changes or (e.kind == .user and long_text.isLong(e.text.items));
    }

    pub fn toggleRows(e: *Entry, win: vaxis.Window) u16 {
        if (!e.collapsible()) return 0;
        if (e.open) return 1;
        const open = e.open;
        e.open = false;
        defer e.open = open;
        return e.print(win, false);
    }

    pub fn print(e: *Entry, win: vaxis.Window, commit: bool) u16 {
        if (e.simple and (e.kind == .bill or e.kind == .changes)) return 0;
        if (e.kind == .changes) return e.printChanges(win, commit);
        if (e.kind == .assistant) {
            if (e.allocator) |a| return e.markdown_cache.draw(a, win, e.displayText(), .{ .tint = e.code_bg }, commit);
            return markdown.print(win, e.displayText(), .{ .tint = e.code_bg }, commit);
        }
        if (e.kind == .user and win.width >= 4) return e.printUser(win, commit);
        if (e.kind == .bill) {
            const time = bill.fit(e.text.items, win.width);
            _ = win.child(.{ .x_off = win.width -| win.gwidth(time) }).printSegment(.{ .text = time, .style = .{ .dim = true } }, .{ .wrap = .none, .commit = commit });
            return 1;
        }
        var segs: [max_segments]vaxis.Segment = undefined;
        const folded = e.collapsible() and !e.open;
        const wrap: @FieldType(vaxis.Window.PrintOptions, "wrap") = if (folded) .none else if (e.kind == .run or e.kind == .background or e.kind == .failure) .grapheme else .word;
        const shown = segments(e, &segs);
        if (e.kind == .run) {
            const rows = e.printRunPrefix(win, commit);
            if (!e.open) return rows;
            return rows +| run_details.draw(e, win.child(.{ .y_off = rows }), commit, null).rows;
        }
        if (folded and e.kind == .user) {
            const suffix_width = vaxis.gwidth.gwidth(e.label.items, win.screen.width_method) + @as(u16, if (e.queued != null) 9 else 0);
            const available = win.width -| suffix_width;
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

    fn printRunPrefix(e: *Entry, win: vaxis.Window, commit: bool) u16 {
        var segs: [max_segments]vaxis.Segment = undefined;
        const shown = e.segments(&segs);
        if (e.simple and !e.open and e.title_files.items.len > 0) {
            const title_text = e.label.items;
            const at = @min(e.title_files_at, title_text.len);
            const title = [_]vaxis.Segment{ shown[0], shown[1], .{ .text = title_text[0..at] }, .{ .text = e.title_files.items }, .{ .text = title_text[at..] } };
            _ = win.print(&title, .{ .wrap = .none, .commit = commit });
        } else _ = win.print(shown, .{ .wrap = .none, .commit = commit });
        if (e.simple and !e.open and e.run != .running) return 1;
        if (e.simple and !e.open) return 1 +| e.agent_tree.print(win.child(.{ .y_off = 1 }), commit);
        var rows: u16 = 1;
        if (!e.open and e.changes.summary.len > 0) {
            const r = win.child(.{ .x_off = 2, .y_off = rows }).printSegment(.{ .text = e.changes.summary, .style = .{ .dim = true } }, .{ .wrap = .word, .commit = commit });
            rows +|= @max(1, r.row +| @intFromBool(r.col > 0));
        }
        if (e.files.items.len > 0) {
            const r = win.child(.{ .x_off = 2, .y_off = rows }).printSegment(.{ .text = e.files.items, .style = .{ .dim = true } }, .{ .wrap = .word, .commit = commit });
            rows +|= @max(1, r.row +| @intFromBool(r.col > 0));
        }
        if (e.hook_notice.items.len > 0) {
            _ = win.child(.{ .x_off = 2, .y_off = rows }).printSegment(.{ .text = e.hook_notice.items, .style = .{ .fg = .{ .index = 3 } } }, .{ .wrap = .none, .commit = commit });
            rows +|= 1;
        }
        rows +|= e.agent_tree.print(win.child(.{ .y_off = rows }), commit);
        return rows;
    }

    pub const Control = struct { first: u16, rows: u16, action: ?run_details.Action = null };

    pub fn control(e: *Entry, win: vaxis.Window, row: u16) ?Control {
        const parent_rows = e.toggleRows(win);
        if (row < parent_rows) return .{ .first = 0, .rows = parent_rows };
        if (e.kind != .run or !e.open) return null;
        const prefix_rows = e.printRunPrefix(win, false);
        if (row < prefix_rows) return null;
        var measure = win;
        measure.height = std.math.maxInt(u16);
        const layout = run_details.draw(e, measure, false, row - prefix_rows);
        const hit = layout.hit orelse return null;
        return .{ .first = prefix_rows +| hit.first, .rows = hit.rows, .action = hit.action };
    }

    pub fn toggleControl(e: *Entry, control_hit: Control) void {
        if (control_hit.action) |action| e.details.toggle(e, action) else e.open = !e.open;
        e.cached = null;
    }

    /// `label` is the summary line, `text` one row per file while open.
    fn printChanges(e: *const Entry, win: vaxis.Window, commit: bool) u16 {
        const dim: vaxis.Style = .{ .dim = true };
        _ = win.print(&.{.{ .text = e.label.items, .style = dim }}, .{ .wrap = .none, .commit = commit });
        var rows: u16 = 1;
        const time = bill.fit(e.turn_time.items, win.width);
        if (time.len > 0) {
            const fits = @as(u32, win.gwidth(e.label.items)) + win.gwidth(time) + 2 <= win.width;
            _ = win.child(.{ .x_off = win.width - win.gwidth(time), .y_off = if (fits) 0 else 1, .height = 1 }).printSegment(.{ .text = time, .style = dim }, .{ .wrap = .none, .commit = commit });
            if (!fits) rows += 1;
        }
        if (!e.open) return rows;
        var lines = std.mem.splitScalar(u8, e.text.items, '\n');
        while (lines.next()) |line| : (rows +|= 1) {
            const added_at = std.mem.lastIndexOf(u8, line, " +");
            const removed_at = std.mem.lastIndexOf(u8, line, " −");
            const counts_at = @min(added_at orelse line.len, removed_at orelse line.len);
            const path_end = std.mem.trimEnd(u8, line[0..counts_at], " ").len;
            const leaf = if (std.mem.lastIndexOfScalar(u8, line[0..path_end], '/')) |at| at + 1 else 0;
            const removed_start = if (removed_at) |at| at + 1 else line.len;
            _ = win.child(.{ .y_off = rows }).print(&.{
                .{ .text = line[0..leaf], .style = dim },
                .{ .text = line[leaf..path_end] },
                .{ .text = line[path_end..counts_at], .style = dim },
                .{ .text = line[counts_at..removed_start], .style = .{ .fg = .{ .index = 2 } } },
                .{ .text = line[removed_start..], .style = .{ .fg = .{ .index = 1 } } },
            }, .{ .wrap = .none, .commit = commit });
        }
        return rows;
    }

    fn printUser(e: *const Entry, win: vaxis.Window, commit: bool) u16 {
        var segs: [max_segments]vaxis.Segment = undefined;
        const shown = e.segments(&segs);
        const body = win.child(.{ .x_off = 2, .width = win.width - 3 });
        const folded = e.collapsible() and !e.open;
        if (folded) {
            const suffix_width = body.gwidth(e.label.items) + @as(u16, if (e.queued != null) 9 else 0);
            const available = body.width -| suffix_width;
            var end: usize = 0;
            while (end < segs[1].text.len) {
                const next = end + (std.unicode.utf8ByteSequenceLength(segs[1].text[end]) catch 1);
                if (body.gwidth(segs[1].text[0..next]) > available) break;
                end = next;
            }
            segs[1].text = segs[1].text[0..end];
        }
        const r = body.print(shown, .{ .wrap = if (folded) .none else .word, .commit = commit });
        const rows = if (folded) 1 else @max(1, r.row +| @intFromBool(r.col > 0));
        if (commit) {
            const first: u16 = @intCast(@min(rows, @max(0, -@as(i32, win.y_off))));
            const last: u16 = @intCast(@min(rows, @max(0, @as(i32, win.screen.height) - win.y_off)));
            for (first..last) |row| {
                for (0..win.width) |col| {
                    var cell = win.readCell(@intCast(col), @intCast(row)) orelse continue;
                    cell.style.bg = e.user_bg;
                    cell.default = false;
                    win.writeCell(@intCast(col), @intCast(row), cell);
                }
                win.writeCell(0, @intCast(row), .{ .char = .{ .grapheme = "▎", .width = 1 }, .style = .{ .fg = .{ .index = 4 }, .bg = e.user_bg } });
            }
        }
        return rows;
    }

    pub fn extent(e: *Entry, win: vaxis.Window) u16 {
        return e.height(win) +| e.gap;
    }

    pub fn height(e: *Entry, win: vaxis.Window) u16 {
        const len = e.displayText().len + e.output.items.len + e.changes.diff.len;
        if (if (e.simple) null else e.cached) |c| {
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
                segs[0] = .{ .text = "" };
                const folded = e.collapsible() and !e.open;
                segs[1] = .{ .text = if (folded) e.text.items[0 .. std.mem.indexOfScalar(u8, e.text.items, '\n') orelse e.text.items.len] else e.text.items };
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
                segs[0] = if (e.run == .failed) .{ .text = "✗ ", .style = .{ .fg = .{ .index = 1 } } } else if (e.run == .warning or e.run == .lost or e.run == .timed_out or e.run == .canceled or e.hasWarning()) .{ .text = "! ", .style = .{ .fg = .{ .index = 3 } } } else .{ .text = "  ", .style = dim };
                segs[1] = .{ .text = "", .style = dim };
                segs[2] = .{ .text = e.label.items };
                return segs[0..3];
            },
            .background => {
                segs[0] = if (e.run == .warning) .{ .text = "! ", .style = .{ .fg = .{ .index = 3 } } } else if (e.run == .superseded) .{ .text = "  ", .style = dim } else .{ .text = if (e.run == .ok) "✓ " else "✗ ", .style = .{ .fg = .{ .index = if (e.run == .ok) 2 else 1 } } };
                segs[1] = .{ .text = e.label.items };
                if (!e.open) return segs[0..2];
                segs[2] = .{ .text = "\n" };
                segs[3] = .{ .text = e.text.items, .style = dim };
                return segs[0..4];
            },
            .failure => {
                segs[0] = .{ .text = e.label.items, .style = .{ .fg = .{ .index = if (e.run == .warning) 3 else 1 } } };
                if (!e.open) return segs[0..1];
                segs[1] = .{ .text = "\nDetails\n", .style = dim };
                segs[2] = .{ .text = e.text.items, .style = dim };
                return segs[0..3];
            },
            .info, .bill => segs[0] = .{ .text = e.text.items, .style = dim },
            .changes => segs[0] = .{ .text = e.label.items, .style = dim },
            .err => segs[0] = .{ .text = e.text.items, .style = .{ .fg = .{ .index = 1 } } },
        }
        return segs[0..1];
    }
};

test "expanded edit and write Runs show only changes without hiding failures or other tools" {
    const edit: ToolSummary = .{ .counts = &.{.{ .name = "edit", .count = 2 }}, .failures = 0 };
    const cases = [_]struct {
        summary: ?ToolSummary = edit,
        run: @FieldType(Entry, "run") = .ok,
        notice: []const u8 = "",
        changes_only: bool = false,
    }{
        .{ .changes_only = true },
        .{ .summary = .{ .counts = &.{.{ .name = "write", .count = 1 }}, .failures = 0 }, .changes_only = true },
        .{ .summary = .{ .counts = &.{ .{ .name = "edit", .count = 2 }, .{ .name = "write", .count = 1 } }, .failures = 0 }, .changes_only = true },
        .{ .summary = .{ .counts = edit.counts, .failures = 1 } },
        .{ .summary = .{ .counts = edit.counts } },
        .{ .run = .failed },
        .{ .run = .running },
        .{ .run = .warning },
        .{ .notice = "after-edit hook failed" },
        .{ .summary = .{ .counts = edit.counts, .files = &.{.{ .tool = "edit", .path = "a.zig", .failed = true }} } },
        .{ .summary = .{ .counts = &.{ .{ .name = "edit", .count = 1 }, .{ .name = "bash", .count = 1 } } } },
        .{ .summary = .{ .counts = &.{ .{ .name = "read", .count = 1 }, .{ .name = "edit", .count = 1 } } } },
        .{ .summary = .{ .counts = edit.counts, .omitted = 1 } },
        .{ .summary = .{} },
        .{ .summary = null },
    };
    for (cases) |c| {
        for ([_]bool{ false, true }) |simple| {
            var e: Entry = .{ .kind = .run, .open = true, .simple = simple, .run = c.run, .tool_summary = c.summary };
            defer {
                e.tool_summary = null;
                e.deinit(std.testing.allocator);
            }
            try e.text.appendSlice(std.testing.allocator, "edit-script");
            try e.output.appendSlice(std.testing.allocator, "edit-result");
            try e.hook_notice.appendSlice(std.testing.allocator, c.notice);
            e.changes = try .init(std.testing.allocator, &.{.{ .path = "a.zig", .added = 1, .removed = 1, .diff = "-before\n+after\n" }});
            try std.testing.expectEqual(c.changes_only, e.changesOnly());
            e.details.open = true;
            e.details.result_open = true;
            e.details.script_open = true;
            var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 120, .rows = 40, .x_pixel = 0, .y_pixel = 0 });
            defer screen.deinit(std.testing.allocator);
            const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 40, .screen = &screen };
            const rows = e.print(win, true);
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(std.testing.allocator);
            for (0..rows) |row| for (0..win.width) |col| {
                try text.appendSlice(std.testing.allocator, screen.readCell(@intCast(col), @intCast(row)).?.char.grapheme);
            };
            try std.testing.expect(std.mem.indexOf(u8, text.items, "Changes") != null);
            try std.testing.expect(std.mem.indexOf(u8, text.items, "+after") != null);
            for ([_][]const u8{ "Result", "Script", "edit-result", "edit-script" }) |body| {
                try std.testing.expectEqual(!c.changes_only, std.mem.indexOf(u8, text.items, body) != null);
            }
            try std.testing.expectEqualStrings("edit-result", e.output.items);
            try std.testing.expectEqualStrings("edit-script", e.text.items);
        }
    }
}

test "caught tool failures open Result by default without overriding an explicit choice" {
    const cases = [_]struct { summary: ToolSummary, expanded: bool }{
        .{ .summary = .{ .failures = 0 }, .expanded = false },
        .{ .summary = .{ .failures = 1 }, .expanded = true },
        .{ .summary = .{ .files = &.{.{ .tool = "edit", .path = "a.zig", .failed = true }} }, .expanded = true },
    };
    for (cases) |c| {
        var e: Entry = .{ .kind = .run, .run = .ok, .tool_summary = c.summary, .changes = .{ .file_count = 1 } };
        try std.testing.expectEqual(c.expanded, e.details.resultExpanded(&e));
        e.details.result_open = false;
        try std.testing.expect(!e.details.resultExpanded(&e));
        e.details.result_open = true;
        try std.testing.expect(e.details.resultExpanded(&e));
        try std.testing.expect(!e.details.script_open);
    }
}
