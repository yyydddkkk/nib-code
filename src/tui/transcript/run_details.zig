const std = @import("std");
const vaxis = @import("vaxis");
const intraline = @import("intraline.zig");
const FileDiff = @import("changes.zig").ChangeText.FileDiff;

pub const preview_lines = 20;
pub const Action = union(enum) { details, result, full_result, script, file: usize };
pub const Rows = struct {
    first: u16 = 0,
    count: u16 = 0,

    fn end(r: Rows) u16 {
        return r.first +| r.count;
    }

    fn contains(r: Rows, row: u16) bool {
        return row >= r.first and row < r.end();
    }
};

pub const Hit = struct { action: Action, rows: Rows };

const Layout = struct {
    columns: Columns = .{},
    changes: Rows = .{},
    details: Rows = .{},
    result: Rows = .{},
    preview: Rows = .{},
    output: Rows = .{},
    full_result: Rows = .{},
    script: Rows = .{},
    script_body: Rows = .{},
};

pub const State = struct {
    open: ?bool = null,
    result_open: ?bool = null,
    full_result: bool = false,
    script_open: bool = false,
    layout: Layout = .{},

    // vaxis retains printed slices until the frame is rendered.
    changes_label: [80]u8 = undefined,
    result_label: [80]u8 = undefined,
    script_label: [80]u8 = undefined,
    preview_label: [100]u8 = undefined,

    pub fn hit(s: *const State, files: []const FileDiff, row: u16) ?Hit {
        inline for (.{ .details, .result, .full_result, .script }) |action| {
            const rows = @field(s.layout, @tagName(action));
            if (rows.contains(row)) return .{ .action = action, .rows = rows };
        }
        for (files, 0..) |*f, i| {
            if (row < f.heading_rows.first) break;
            if (f.heading_rows.contains(row)) return .{ .action = .{ .file = i }, .rows = f.heading_rows };
        }
        return null;
    }

    pub fn expanded(s: *const State, e: anytype) bool {
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

    pub fn resultExpanded(s: *const State, e: anytype) bool {
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
    row: u16 = 0,

    // Named blocks keep their measured placement even when the paint window clips them.
    fn line(p: *Painter, indent: u16, segments: []const vaxis.Segment, placement: ?*Rows) void {
        if (p.commit) if (placement) |rows| {
            _ = p.printLine(rows.first, rows.count, indent, segments);
            p.row = rows.end();
            return;
        };
        const first = p.row;
        const r = p.printLine(first, null, indent, segments);
        const count = @max(1, r.row +| @intFromBool(r.col > 0));
        if (placement) |rows| rows.* = .{ .first = first, .count = count };
        p.row +|= count;
    }

    fn printLine(p: *Painter, row: u16, height: ?u16, indent: u16, segments: []const vaxis.Segment) vaxis.Window.PrintResult {
        const x = @min(indent, p.win.width -| 1);
        return p.win.child(.{ .x_off = x, .y_off = row, .height = height }).print(segments, .{ .wrap = .grapheme, .commit = p.commit });
    }

    fn heading(p: *Painter, text: []const u8, expanded: bool, placement: *Rows, indent: u16) void {
        p.line(indent, &.{ .{ .text = if (expanded) "▾ " else "▸ ", .style = .{ .dim = true } }, .{ .text = text, .style = .{ .dim = true } } }, placement);
    }

    fn file(p: *Painter, f: *FileDiff, expanded: bool, columns: Columns) void {
        const path = f.header[0..f.path_len];
        const leaf = if (std.mem.lastIndexOfScalar(u8, path, '/')) |at| at + 1 else 0;
        const added = if (f.added > 0) std.fmt.bufPrint(&f.added_label, "+{d}", .{f.added}) catch unreachable else "";
        const removed = if (f.removed > 0) std.fmt.bufPrint(&f.removed_label, "−{d}", .{f.removed}) catch unreachable else "";
        const aligned = columns.end <= p.win.width;
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
        p.line(4, &segments, &f.heading_rows);
        if (aligned and p.commit) {
            const row = p.win.child(.{ .y_off = f.heading_rows.first, .height = 1 });
            if (added.len > 0) _ = row.child(.{ .x_off = @intCast(columns.added_end - row.gwidth(added)) }).printSegment(.{ .text = added, .style = .{ .fg = .{ .index = 2 } } }, .{ .wrap = .none, .commit = p.commit });
            if (removed.len > 0) _ = row.child(.{ .x_off = @intCast(columns.removed_start) }).printSegment(.{ .text = removed, .style = .{ .fg = .{ .index = 1 } } }, .{ .wrap = .none, .commit = p.commit });
        }
    }

    fn diff(p: *Painter, text: []const u8) void {
        var lines: intraline.Lines = .{ .text = text };
        while (p.row < p.win.height) {
            const item = lines.next() orelse break;
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
    added_end: u32 = 0,
    removed_start: u32 = 0,
    end: u32 = 0,

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

pub fn draw(e: anytype, win: vaxis.Window, commit: bool, prefix_rows: u16) u16 {
    var p: Painter = .{ .win = win, .commit = commit, .row = prefix_rows };
    const s = &e.details;
    const layout = &s.layout;
    if (!commit) layout.* = .{ .columns = Columns.measure(win, e.changes.files) };
    if (e.changes.files.len > 0) {
        p.row +|= 1;
        const title = std.fmt.bufPrint(&s.changes_label, "Changes · {d} {s}", .{ e.changes.file_count, if (e.changes.file_count == 1) "file" else "files" }) catch unreachable;
        p.line(2, &.{.{ .text = title, .style = .{ .dim = true, .bold = true } }}, &layout.changes);
        for (e.changes.files) |*f| {
            const expanded = f.expanded(e.changes.files.len == 1);
            p.file(f, expanded, layout.columns);
            if (expanded) p.diff(f.diff);
        }
    }
    if (e.changesOnly()) return p.row;
    const expanded = s.expanded(e);
    p.heading("Details", expanded, &layout.details, 4);
    if (!expanded) return p.row;
    const output = std.mem.trimEnd(u8, e.output.items, "\n");
    const count = lineCount(output);
    const result_open = s.resultExpanded(e);
    const result_title = std.fmt.bufPrint(&s.result_label, "Result · {d} {s}", .{ count, if (count == 1) "line" else "lines" }) catch unreachable;
    p.heading(result_title, result_open, &layout.result, 4);
    if (result_open) {
        const limited = count > preview_lines and !s.full_result;
        if (limited) {
            const label = std.fmt.bufPrint(&s.preview_label, "Preview · first {d} of {d} lines", .{ preview_lines, count }) catch unreachable;
            p.line(6, &.{.{ .text = label, .style = .{ .dim = true } }}, &layout.preview);
        }
        p.line(6, &.{.{ .text = if (output.len == 0) "No result" else if (limited) preview(output) else output }}, &layout.output);
        if (count > preview_lines) p.heading(if (limited) "Show full result" else "Show preview", !limited, &layout.full_result, 6);
    }
    const script_title = std.fmt.bufPrint(&s.script_label, "Script · {d} {s}", .{ lineCount(e.text.items), if (lineCount(e.text.items) == 1) "line" else "lines" }) catch unreachable;
    p.heading(script_title, s.script_open, &layout.script, 4);
    if (s.script_open) p.line(6, &.{.{ .text = std.mem.trimEnd(u8, e.text.items, "\n") }}, &layout.script_body);
    return p.row;
}
