const std = @import("std");
const vaxis = @import("vaxis");
const history = @import("selection/history.zig");
const Entry = @import("transcript.zig").Entry;

pub const Point = struct { col: u16, row: u16 };

pub const Selection = struct {
    anchor: ?Point = null,
    end: Point = .{ .col = 0, .row = 0 },
    active: bool = false,
    dragged: bool = false,
    history: ?history.History = null,
    click: ?history.Position = null,

    pub fn takeClick(s: *Selection) ?history.Position {
        defer s.click = null;
        return s.click;
    }

    pub fn clear(s: *Selection) void {
        s.* = .{};
    }

    pub fn mouse(s: *Selection, m: vaxis.Mouse, screen: *const vaxis.Screen) bool {
        if (screen.width == 0 or screen.height == 0) return false;
        const p: Point = .{
            .col = @intCast(@min(@max(m.col, 0), screen.width - 1)),
            .row = @intCast(@min(@max(m.row, 0), screen.height - 1)),
        };
        if (m.type == .press and m.button == .left) {
            s.* = .{ .anchor = p, .end = p, .active = true };
        } else if (s.active and (m.type == .drag or m.type == .motion) and m.button == .left) {
            s.end = p;
            s.dragged = s.dragged or !std.meta.eql(s.anchor.?, p);
        } else if (s.active and m.type == .release and (m.button == .left or m.button == .none)) {
            s.end = p;
            s.active = false;
            if (!s.dragged) {
                s.clear();
                return false;
            }
            return true;
        }
        return false;
    }

    pub fn mouseInHistory(s: *Selection, m: vaxis.Mouse, screen: *const vaxis.Screen, frame: ?history.Frame, entries: []Entry) bool {
        if (s.active and s.history != null) {
            if (frame) |f| {
                const col: u16 = @intCast(@min(@max(m.col, 0), screen.width -| 1));
                const row: u16 = @intCast(@max(m.row, 0));
                s.updateEnd(f, entries, col, row);
            }
        }
        const click: ?history.Position = if (s.active and !s.dragged and m.type == .release and (m.button == .left or m.button == .none))
            (if (s.history) |h| h.anchor else null)
        else
            null;
        const copied = s.mouse(m, screen);
        if (click) |c| s.click = c;
        if (m.type == .press and m.button == .left) {
            if (frame) |f| {
                if (m.row >= f.window.y_off and m.row < @as(i32, f.window.y_off) + f.window.height and s.anchor != null) {
                    if (history.position(f, entries, s.end.col, s.end.row)) |p| s.history = .{ .anchor = p, .end = p };
                }
            }
        }
        return copied;
    }

    fn updateEnd(s: *Selection, frame: history.Frame, entries: []Entry, col: u16, row: u16) void {
        const end = frame.limit(entries.len);
        if (frame.top.entry >= end) return;
        const p = history.position(frame, entries, col, @max(row, @as(u16, @intCast(frame.window.y_off)))) orelse history.Position{
            .entry = end - 1,
            .row = entries[end - 1].height(frame.window),
            .col = col,
        };
        s.history.?.end = p;
        s.dragged = s.dragged or !std.meta.eql(s.history.?.anchor, p);
    }

    pub fn updateHistory(s: *Selection, frame: ?history.Frame, entries: []Entry) void {
        if (s.active and s.history != null) {
            if (frame) |f| s.updateEnd(f, entries, s.end.col, s.end.row);
        }
    }

    pub fn highlightHistory(s: Selection, screen: *vaxis.Screen, frame: ?history.Frame, entries: []Entry) void {
        if (s.history) |h| {
            if (s.dragged) if (frame) |f| h.highlight(screen, f, entries);
        } else s.highlight(screen);
    }

    pub fn textInHistory(s: Selection, gpa: std.mem.Allocator, screen: *const vaxis.Screen, frame: ?history.Frame, entries: []Entry) ![]u8 {
        if (s.dragged) if (s.history) |h| {
            if (frame) |f| return h.text(gpa, f, entries);
        };
        return s.text(gpa, screen);
    }

    const Range = struct { first: Point, last: Point };

    fn range(s: Selection) ?Range {
        const a = s.anchor orelse return null;
        if (!s.dragged) return null;
        const forward = a.row < s.end.row or (a.row == s.end.row and a.col <= s.end.col);
        return .{ .first = if (forward) a else s.end, .last = if (forward) s.end else a };
    }

    pub fn highlight(s: Selection, screen: *vaxis.Screen) void {
        const r = s.range() orelse return;
        var row: usize = r.first.row;
        while (row <= r.last.row and row < screen.height) : (row += 1) {
            const first: usize = if (row == r.first.row) r.first.col else 0;
            const last: usize = if (row == r.last.row) r.last.col else screen.width -| 1;
            var col = first;
            while (col <= last and col < screen.width) : (col += 1) {
                const cell = &screen.buf[row * screen.width + col];
                cell.style.reverse = !cell.style.reverse;
                cell.default = false;
            }
        }
    }

    pub fn text(s: Selection, gpa: std.mem.Allocator, screen: *const vaxis.Screen) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (s.range()) |r| {
            var row: usize = r.first.row;
            while (row <= r.last.row and row < screen.height) : (row += 1) {
                if (row != r.first.row) try out.append(gpa, '\n');
                const first: u16 = if (row == r.first.row) r.first.col else 0;
                const last: u16 = if (row == r.last.row) r.last.col else screen.width -| 1;
                try history.appendRow(&out, gpa, screen, @intCast(row), first, last);
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

pub fn copy(vx: *vaxis.Vaxis, w: *std.Io.Writer, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, text: []const u8) !void {
    try vx.copyToSystemClipboard(w, text, gpa);
    try w.flush();
    localCopy(io, env, text) catch {};
}

fn localCopy(io: std.Io, env: *const std.process.Environ.Map, text: []const u8) !void {
    if (!env.contains("WAYLAND_DISPLAY") and !env.contains("DISPLAY")) return;
    const Worker = struct {
        fn run(i: std.Io, e: *const std.process.Environ.Map, bytes: []const u8, done: *std.Io.Event) !void {
            defer done.set(i);
            try localCopyProcess(i, e, bytes);
        }
    };
    var done: std.Io.Event = .unset;
    var task = try io.concurrent(Worker.run, .{ io, env, text, &done });
    defer task.cancel(io) catch {};
    try done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try task.await(io);
}

fn localCopyProcess(io: std.Io, env: *const std.process.Environ.Map, text: []const u8) !void {
    if (!env.contains("WAYLAND_DISPLAY") and !env.contains("DISPLAY")) return;
    const script =
        \\if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null 2>&1; then exec wl-copy
        \\elif [ -n "$DISPLAY" ]; then
        \\  if command -v xsel >/dev/null 2>&1; then exec xsel --clipboard --input
        \\  elif command -v xclip >/dev/null 2>&1; then exec xclip -selection clipboard; fi
        \\fi
        \\exit 1
    ;
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", script }, .environ_map = env, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore });
    defer child.kill(io);
    const file = child.stdin.?;
    child.stdin = null;
    {
        defer file.close(io);
        var writer = file.writer(io, &.{});
        try writer.interface.writeAll(text);
        try writer.interface.flush();
    }
    const term = try child.wait(io);
    if (!term.success()) return error.ClipboardFailed;
}

fn mouse(col: i16, row: i16, kind: vaxis.Mouse.Type) vaxis.Mouse {
    return .{ .col = col, .row = row, .button = .left, .mods = .{}, .type = kind };
}

fn expectText(s: Selection, screen: *vaxis.Screen, expected: []const u8) !void {
    const actual = try s.text(std.testing.allocator, screen);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn testScreen() !vaxis.Screen {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 8, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 8, .height = 3, .screen = &screen };
    _ = win.printSegment(.{ .text = "abc  \n中x y  \nend" }, .{});
    return screen;
}

fn drawHistory(screen: *vaxis.Screen, entries: []Entry, top: @import("viewport.zig").Anchor) history.Frame {
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = screen.height, .screen = screen };
    win.clear();
    var y: i32 = -@as(i32, top.row);
    for (entries[top.entry..]) |*entry| {
        if (y >= win.height) break;
        const height = entry.height(win);
        if (y + height > 0) _ = entry.print(win.child(.{ .y_off = @intCast(y), .height = height }), true);
        y += @as(i32, height) + 1;
    }
    return .{ .top = top, .window = win };
}

test "history selection scrolls both ways and copies offscreen rows including gaps and Unicode" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 8, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    var transcript: @import("transcript.zig").Transcript = .{};
    defer transcript.deinit(gpa);
    try transcript.add(gpa, .info, "abc\n中x\nend");
    try transcript.add(gpa, .info, "four\nfive\nsix");
    const entries = transcript.entries.items;
    for ([_]bool{ false, true }) |reverse| {
        var s: Selection = .{};
        var frame = drawHistory(&screen, entries, if (reverse) .{ .entry = 1 } else .{});
        _ = s.mouseInHistory(mouse(1, 0, .press), &screen, frame, entries);
        frame = drawHistory(&screen, entries, if (reverse) .{} else .{ .entry = 1 });
        s.updateHistory(frame, entries);
        try std.testing.expect(s.active);
        try std.testing.expect(s.dragged);
        s.highlightHistory(&screen, frame, entries);
        try std.testing.expect(screen.readCell(1, 0).?.style.reverse);
        try std.testing.expect(s.mouseInHistory(mouse(1, 0, .release), &screen, frame, entries));
        const copied = try s.textInHistory(gpa, &screen, frame, entries);
        defer gpa.free(copied);
        try std.testing.expectEqualStrings("bc\n中x\nend\n\nfo", copied);
        try std.testing.expect(!s.active);
    }
}

test "history selection clamps the pointer to the body and keeps the start when scrolling back" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 8, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    var transcript: @import("transcript.zig").Transcript = .{};
    defer transcript.deinit(gpa);
    try transcript.add(gpa, .info, "0\n1\n2\n3\n4\n5\n6\n7");
    const entries = transcript.entries.items;
    var s: Selection = .{};
    var frame = drawHistory(&screen, entries, .{ .row = 1 });
    _ = s.mouseInHistory(mouse(0, 0, .press), &screen, frame, entries);
    const anchor = s.history.?.anchor;
    frame = drawHistory(&screen, entries, .{ .row = 5 });
    _ = s.mouseInHistory(mouse(0, 100, .drag), &screen, frame, entries);
    try std.testing.expectEqualDeep(anchor, s.history.?.anchor);
    try std.testing.expectEqual(@as(u16, 7), s.history.?.end.row);
    frame = drawHistory(&screen, entries, .{ .row = 1 });
    s.updateHistory(frame, entries);
    try std.testing.expectEqual(@as(u16, 3), s.history.?.end.row);
    try std.testing.expect(s.mouseInHistory(mouse(0, 2, .release), &screen, frame, entries));
    const copied = try s.textInHistory(gpa, &screen, frame, entries);
    defer gpa.free(copied);
    try std.testing.expectEqualStrings("1\n2\n3", copied);
}

test "history copy spans scratch buffers without losing wrapped text or blank lines" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 8, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    var transcript: @import("transcript.zig").Transcript = .{};
    defer transcript.deinit(gpa);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    for (0..80) |i| try expected.print(gpa, "{d}\n", .{i});
    try transcript.add(gpa, .info, expected.items);
    const entries = transcript.entries.items;
    var s: Selection = .{};
    var frame = drawHistory(&screen, entries, .{});
    _ = s.mouseInHistory(mouse(0, 0, .press), &screen, frame, entries);
    frame = drawHistory(&screen, entries, .{ .row = 78 });
    try std.testing.expect(s.mouseInHistory(mouse(1, 1, .release), &screen, frame, entries));
    const copied = try s.textInHistory(gpa, &screen, frame, entries);
    defer gpa.free(copied);
    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, expected.items, "\n"), copied);
}

test "selection forward and reverse on one row, click clears" {
    var screen = try testScreen();
    defer screen.deinit(std.testing.allocator);
    for ([_]bool{ false, true }) |reverse| {
        var s: Selection = .{};
        _ = s.mouse(mouse(if (reverse) 2 else 0, 0, .press), &screen);
        _ = s.mouse(mouse(if (reverse) 0 else 2, 0, .drag), &screen);
        try std.testing.expect(s.mouse(mouse(if (reverse) 0 else 2, 0, .release), &screen));
        try expectText(s, &screen, "abc");
        s.highlight(&screen);
        try std.testing.expect(screen.readCell(0, 0).?.style.reverse);
        try std.testing.expect(!screen.readCell(3, 0).?.style.reverse);
        s.highlight(&screen);
        _ = s.mouse(mouse(1, 0, .press), &screen);
        try std.testing.expect(!s.mouse(mouse(1, 0, .release), &screen));
        try expectText(s, &screen, "");
    }
}

test "selection multiline in both directions trims trailing spaces and skips wide continuations" {
    var screen = try testScreen();
    defer screen.deinit(std.testing.allocator);
    for ([_]bool{ false, true }) |reverse| {
        var s: Selection = .{};
        _ = s.mouse(mouse(1, if (reverse) 2 else 0, .press), &screen);
        _ = s.mouse(mouse(1, if (reverse) 0 else 2, .drag), &screen);
        _ = s.mouse(mouse(1, if (reverse) 0 else 2, .release), &screen);
        try expectText(s, &screen, "bc\n中x y\nen");
        s.clear();
        try expectText(s, &screen, "");
    }
    var s: Selection = .{};
    _ = s.mouse(mouse(1, 1, .press), &screen);
    _ = s.mouse(mouse(7, 1, .drag), &screen);
    _ = s.mouse(mouse(7, 1, .release), &screen);
    try expectText(s, &screen, "x y");
}

test "selection preserves empty rows and clamps coordinates to the screen" {
    var screen = try testScreen();
    defer screen.deinit(std.testing.allocator);
    for (0..screen.width) |col| screen.writeCell(@intCast(col), 1, .{});
    var s: Selection = .{};
    _ = s.mouse(mouse(-10, -10, .press), &screen);
    _ = s.mouse(mouse(100, 100, .drag), &screen);
    try std.testing.expect(s.mouse(mouse(100, 100, .release), &screen));
    try expectText(s, &screen, "abc\n\nend");
    s.highlight(&screen);
    for (screen.buf) |cell| try std.testing.expect(cell.style.reverse);
    s.clear();
    try expectText(s, &screen, "");
    try std.testing.expect(!s.mouse(mouse(0, 0, .release), &screen));
}

test "selection reads the screen at release rather than press" {
    var screen = try testScreen();
    defer screen.deinit(std.testing.allocator);
    var s: Selection = .{};
    _ = s.mouse(mouse(0, 0, .press), &screen);
    _ = s.mouse(mouse(2, 0, .drag), &screen);
    screen.writeCell(1, 0, .{ .char = .{ .grapheme = "新", .width = 2 } });
    _ = s.mouse(mouse(2, 0, .release), &screen);
    try expectText(s, &screen, "a新");
}
