const std = @import("std");
const vaxis = @import("vaxis");
const intraline = @import("intraline.zig");
const FileDiff = @import("changes.zig").ChangeText.FileDiff;

pub const preview_lines = 20;
pub const Action = union(enum) { details, result, full_result, script, file: usize };
pub const Hit = struct { action: Action, first: u16, rows: u16 };
pub const Layout = struct { rows: u16 = 0, hit: ?Hit = null };

pub const State = struct {
    open: ?bool = null,
    result_open: ?bool = null,
    full_result: bool = false,
    script_open: bool = false,
    // vaxis retains printed slices until the frame is rendered.
    changes_label: [80]u8 = undefined,
    result_label: [80]u8 = undefined,
    script_label: [80]u8 = undefined,
    preview_label: [100]u8 = undefined,

    pub fn expanded(s: State, e: anytype) bool {
        return s.open orelse needsAttention(e);
    }

    fn needsAttention(e: anytype) bool {
        var attention = switch (e.run) {
            .failed, .warning, .lost, .timed_out, .canceled => true,
            else => e.hasWarning(),
        };
        if (e.tool_summary) |summary| {
            if ((summary.failures orelse 0) > 0) attention = true;
            for (summary.files) |file| if (file.failed) {
                attention = true;
                break;
            };
        }
        return attention;
    }

    pub fn resultExpanded(s: State, e: anytype) bool {
        return s.result_open orelse (e.changes.file_count == 0 or needsAttention(e));
    }

    pub fn toggle(s: *State, e: anytype, action: Action) void {
        switch (action) {
            .details => s.open = !s.expanded(e),
            .result => s.result_open = !s.resultExpanded(e),
            .full_result => s.full_result = !s.full_result,
            .script => s.script_open = !s.script_open,
            .file => |i| {
                const f = &e.changes.files[i];
                f.open = !f.expanded(e.changes.files.len == 1);
            },
        }
    }
};

pub fn lineCount(text: []const u8) usize {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    return if (trimmed.len == 0) 0 else std.mem.count(u8, trimmed, "\n") + 1;
}

fn preview(text: []const u8) []const u8 {
    var end: usize = 0;
    for (0..preview_lines) |_| {
        const next = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse return text;
        end = next + 1;
    }
    return std.mem.trimEnd(u8, text[0..end], "\n");
}

const Painter = struct {
    win: vaxis.Window,
    commit: bool,
    target: ?u16,
    layout: Layout = .{},

    fn line(p: *Painter, indent: u16, segments: []const vaxis.Segment, action: ?Action) void {
        const first = p.layout.rows;
        const x = @min(indent, p.win.width -| 1);
        const r = p.win.child(.{ .x_off = x, .y_off = first, .width = p.win.width -| x }).print(segments, .{ .wrap = .grapheme, .commit = p.commit });
        const rows = @max(1, r.row +| @intFromBool(r.col > 0));
        p.layout.rows +|= rows;
        if (action) |a| if (p.target) |row| {
            if (row >= first and row < p.layout.rows) p.layout.hit = .{ .action = a, .first = first, .rows = rows };
        };
    }

    fn heading(p: *Painter, text: []const u8, expanded: bool, action: Action, indent: u16) void {
        p.line(indent, &.{ .{ .text = if (expanded) "▾ " else "▸ ", .style = .{ .dim = true } }, .{ .text = text, .style = .{ .dim = true } } }, action);
    }

    fn file(p: *Painter, f: *FileDiff, index: usize, expanded: bool, columns: Columns) void {
        const path = f.header[0..f.path_len];
        const leaf = if (std.mem.lastIndexOfScalar(u8, path, '/')) |at| at + 1 else 0;
        const added = if (f.added > 0) std.fmt.bufPrint(&f.added_label, "+{d}", .{f.added}) catch unreachable else "";
        const removed = if (f.removed > 0) std.fmt.bufPrint(&f.removed_label, "−{d}", .{f.removed}) catch unreachable else "";
        const aligned = columns.end <= p.win.width;
        const first = p.layout.rows;
        const segments = [_]vaxis.Segment{
            .{ .text = if (expanded) "▾ " else "▸ ", .style = .{ .dim = true } },
            .{ .text = path[0..leaf], .style = .{ .dim = true } },
            .{ .text = path[leaf..] },
            .{ .text = if (f.created) " (new)" else "", .style = .{ .dim = true } },
            .{ .text = if (!aligned and added.len + removed.len > 0) " " else "" },
            .{ .text = if (aligned) "" else added, .style = .{ .fg = .{ .index = 2 } } },
            .{ .text = if (!aligned and added.len > 0 and removed.len > 0) " " else "" },
            .{ .text = if (aligned) "" else removed, .style = .{ .fg = .{ .index = 1 } } },
        };
        p.line(4, &segments, .{ .file = index });
        if (aligned) {
            const row = p.win.child(.{ .y_off = first, .height = 1 });
            if (added.len > 0) _ = row.child(.{ .x_off = @intCast(columns.added_end - row.gwidth(added)) }).printSegment(.{ .text = added, .style = .{ .fg = .{ .index = 2 } } }, .{ .wrap = .none, .commit = p.commit });
            if (removed.len > 0) _ = row.child(.{ .x_off = @intCast(columns.removed_start) }).printSegment(.{ .text = removed, .style = .{ .fg = .{ .index = 1 } } }, .{ .wrap = .none, .commit = p.commit });
        }
    }

    fn diff(p: *Painter, text: []const u8) void {
        var lines: intraline.Lines = .{ .text = text };
        while (lines.next()) |item| {
            const style: vaxis.Style = switch (item.line[0]) {
                '+' => .{ .fg = .{ .index = 2 } },
                '-' => .{ .fg = .{ .index = 1 } },
                ' ' => .{ .dim = true },
                else => .{ .dim = true, .bold = true },
            };
            if (item.emphasis) |r| {
                var strong = style;
                strong.bold = true;
                p.line(6, &.{ .{ .text = item.line[0..r.start], .style = style }, .{ .text = item.line[r.start..r.end], .style = strong }, .{ .text = item.line[r.end..], .style = style } }, null);
            } else p.line(6, &.{.{ .text = item.line, .style = style }}, null);
        }
    }
};

const Columns = struct {
    added_end: u32,
    removed_start: u32,
    end: u32,

    fn measure(win: vaxis.Window, files: []FileDiff) Columns {
        var path: u32 = 0;
        var added: u32 = 0;
        var removed: u32 = 0;
        for (files) |f| {
            path = @max(path, win.gwidth(f.header[0..f.path_len]) + @as(u32, if (f.created) 6 else 0));
            if (f.added > 0) added = @max(added, 1 + @as(u32, @intCast(std.fmt.count("{d}", .{f.added}))));
            if (f.removed > 0) removed = @max(removed, 1 + @as(u32, @intCast(std.fmt.count("{d}", .{f.removed}))));
        }
        const added_end = 6 + path + 2 + added;
        const removed_start = added_end + @intFromBool(added > 0 and removed > 0);
        return .{ .added_end = added_end, .removed_start = removed_start, .end = removed_start + removed };
    }
};

pub fn draw(e: anytype, win: vaxis.Window, commit: bool, target: ?u16) Layout {
    var p: Painter = .{ .win = win, .commit = commit, .target = target };
    const s = &e.details;
    if (e.changes.files.len > 0) {
        p.layout.rows +|= 1;
        const title = std.fmt.bufPrint(&s.changes_label, "Changes · {d} {s}", .{ e.changes.file_count, if (e.changes.file_count == 1) "file" else "files" }) catch unreachable;
        p.line(2, &.{.{ .text = title, .style = .{ .dim = true, .bold = true } }}, null);
        const columns = Columns.measure(win, e.changes.files);
        for (e.changes.files, 0..) |*f, i| {
            const expanded = f.expanded(e.changes.files.len == 1);
            p.file(f, i, expanded, columns);
            if (expanded) p.diff(f.diff);
        }
    }
    if (e.changesOnly()) return p.layout;
    const expanded = s.expanded(e);
    p.heading("Details", expanded, .details, 4);
    if (!expanded) return p.layout;
    const output = std.mem.trimEnd(u8, e.output.items, "\n");
    const count = lineCount(output);
    const result_open = s.resultExpanded(e);
    const result_title = std.fmt.bufPrint(&s.result_label, "Result · {d} {s}", .{ count, if (count == 1) "line" else "lines" }) catch unreachable;
    p.heading(result_title, result_open, .result, 4);
    if (result_open) {
        const limited = count > preview_lines and !s.full_result;
        if (limited) {
            const label = std.fmt.bufPrint(&s.preview_label, "Preview · first {d} of {d} lines", .{ preview_lines, count }) catch unreachable;
            p.line(6, &.{.{ .text = label, .style = .{ .dim = true } }}, null);
        }
        p.line(6, &.{.{ .text = if (output.len == 0) "No result" else if (limited) preview(output) else output }}, null);
        if (count > preview_lines) p.heading(if (limited) "Show full result" else "Show preview", !limited, .full_result, 6);
    }
    const script_title = std.fmt.bufPrint(&s.script_label, "Script · {d} {s}", .{ lineCount(e.text.items), if (lineCount(e.text.items) == 1) "line" else "lines" }) catch unreachable;
    p.heading(script_title, s.script_open, .script, 4);
    if (s.script_open) p.line(6, &.{.{ .text = std.mem.trimEnd(u8, e.text.items, "\n") }}, null);
    return p.layout;
}
