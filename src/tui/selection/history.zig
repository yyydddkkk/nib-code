const std = @import("std");
const vaxis = @import("vaxis");
const Entry = @import("../transcript.zig").Entry;
const Anchor = @import("../viewport.zig").Anchor;

pub const Frame = struct {
    top: Anchor,
    window: vaxis.Window,
    end: usize = std.math.maxInt(usize),

    pub fn limit(f: Frame, len: usize) usize {
        return @min(f.end, len);
    }
};
pub const Position = struct {
    entry: usize,
    row: u16,
    col: u16,

    fn before(a: Position, b: Position) bool {
        if (a.entry != b.entry) return a.entry < b.entry;
        if (a.row != b.row) return a.row < b.row;
        return a.col < b.col;
    }
};

pub fn position(frame: Frame, entries: []Entry, col: u16, row: u16) ?Position {
    if (frame.window.height == 0) return null;
    const y: u16 = @intCast(frame.window.y_off);
    if (row < y) return null;
    var remaining: u32 = @as(u32, frame.top.row) + @min(row - y, frame.window.height - 1);
    const end = frame.limit(entries.len);
    if (frame.top.entry >= end) return null;
    for (entries[frame.top.entry..end], frame.top.entry..) |*entry, i| {
        if (remaining < entry.extent(frame.window)) return .{ .entry = i, .row = @intCast(remaining), .col = col };
        remaining -= entry.extent(frame.window);
    }
    return null;
}

pub const History = struct {
    anchor: Position,
    end: Position,

    fn ordered(h: History) struct { first: Position, last: Position } {
        return if (h.end.before(h.anchor)) .{ .first = h.end, .last = h.anchor } else .{ .first = h.anchor, .last = h.end };
    }

    pub fn highlight(h: History, screen: *vaxis.Screen, frame: Frame, entries: []Entry) void {
        const range = h.ordered();
        const y: usize = @intCast(frame.window.y_off);
        for (y..@min(y + frame.window.height, screen.height)) |row| {
            const p = position(frame, entries, 0, @intCast(row)) orelse break;
            const first = if (p.entry == range.first.entry and p.row == range.first.row) range.first.col else 0;
            const last = if (p.entry == range.last.entry and p.row == range.last.row) range.last.col else screen.width -| 1;
            if ((Position{ .entry = p.entry, .row = p.row, .col = screen.width -| 1 }).before(range.first) or range.last.before(p)) continue;
            for (@min(first, screen.width)..@min(@as(u32, last) + 1, screen.width)) |col| {
                const cell = &screen.buf[row * screen.width + col];
                cell.style.reverse = !cell.style.reverse;
                cell.default = false;
            }
        }
    }

    pub fn text(h: History, gpa: std.mem.Allocator, frame: Frame, entries: []Entry) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const range = h.ordered();
        if (range.last.entry >= entries.len) return out.toOwnedSlice(gpa);
        var screen = try vaxis.Screen.init(gpa, .{ .cols = frame.window.screen.width, .rows = 32, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        screen.width_method = frame.window.screen.width_method;
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = screen.height, .screen = &screen };
        const body = win.child(.{ .x_off = frame.window.x_off, .width = frame.window.width });
        var wrote_row = false;
        for (entries[range.first.entry .. range.last.entry + 1], range.first.entry..) |*entry, i| {
            const height = entry.height(body);
            const pad = entry.verticalPadding(body);
            const start: u32 = if (i == range.first.entry) @min(range.first.row, height) else 0;
            const end: u32 = if (i == range.last.entry) @min(range.last.row, height) else height;
            var row = start;
            while (row <= end) {
                win.clear();
                _ = entry.print(body.child(.{ .y_off = @intCast(-@as(i32, @intCast(row))), .height = height }), true);
                const count = @min(screen.height, end - row + 1);
                for (0..count) |r| {
                    const entry_row = row + r;
                    if (entry_row < pad or (entry_row < height and entry_row >= height - pad)) continue;
                    if (wrote_row) try out.append(gpa, '\n');
                    wrote_row = true;
                    const first = if (i == range.first.entry and row + r == range.first.row) range.first.col else 0;
                    const last = if (i == range.last.entry and row + r == range.last.row) range.last.col else screen.width -| 1;
                    try appendRow(&out, gpa, &screen, @intCast(r), first, last);
                }
                row += count;
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

pub fn appendRow(out: *std.ArrayList(u8), gpa: std.mem.Allocator, screen: *const vaxis.Screen, row: u16, first: u16, last: u16) !void {
    const start = out.items.len;
    var col: u32 = 0;
    while (col <= last and col < screen.width) {
        const cell = screen.readCell(@intCast(col), row).?;
        if (col >= first) try out.appendSlice(gpa, cell.char.grapheme);
        // Vaxis leaves covered cells untouched; only the leading cell owns the glyph.
        const width = if (cell.char.width != 0) cell.char.width else vaxis.gwidth.gwidth(cell.char.grapheme, screen.width_method);
        col += @max(1, width);
    }
    while (out.items.len > start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
}
