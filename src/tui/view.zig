const std = @import("std");
const vaxis = @import("vaxis");
const provider = @import("../provider.zig");
const commands = @import("commands.zig");
const Editor = @import("editor.zig").Editor;
const Entry = @import("transcript.zig").Entry;
const Transcript = @import("transcript.zig").Transcript;
const Viewport = @import("viewport.zig").Viewport;
const status = @import("status.zig");

pub const Frame = @import("selection/history.zig").Frame;

const max_menu_rows = 11;

pub fn draw(win: vaxis.Window, entries: []Entry, input: *Editor, scroll: *Viewport, menu: []const commands.Candidate, menu_sel: usize, s: status.Status, text: *status.Text) void {
    _ = drawFrame(win, entries, input, scroll, menu, menu_sel, s, text);
}

pub fn drawFrame(outer: vaxis.Window, entries: []Entry, input: *Editor, scroll: *Viewport, menu: []const commands.Candidate, menu_sel: usize, s: status.Status, text: *status.Text) ?Frame {
    outer.clear();
    const win = outer;
    win.hideCursor();
    for (entries, 0..) |*e, i| {
        if (e.simple != s.cfg.simple) e.cached = null;
        e.simple = s.cfg.simple;
        const hidden = s.cfg.simple and (e.kind == .bill or e.kind == .changes);
        const joined = e.kind == .bill and i + 1 < entries.len and entries[i + 1].kind == .changes;
        e.gap = if (hidden or joined) 0 else 1;
    }
    if (win.height == 0 or win.width == 0) return null;

    const framed = win.height >= 6 and win.width >= 8;
    const status_fixed = framed and win.height >= 8;
    const borders: u16 = if (framed) 2 else 0;
    const x: u16 = if (framed) 3 else @min(3, win.width - 1);
    const input_w = win.width - x - @as(u16, if (framed) 3 else 0);
    const input_h = @min(input.rows(win.child(.{ .width = input_w })), @max(1, win.height / 3));
    const saved_scroll = scroll.*;
    const above_input = win.height - input_h - borders;
    var activity_h = statusHeight(status_fixed, s.busy != null or s.background_count > 0 or s.notice != null or s.hint.len > 0 or scroll.top != null or scroll.pending < 0, above_input);
    const menu_layout = menuLayout(menu, menu_sel, @min(max_menu_rows, (above_input - activity_h) / 2));
    const menu_h = menu_layout.rows;
    var body_h = above_input - menu_h - activity_h;
    var body = win.child(.{ .x_off = @min(1, win.width - 1), .width = @max(1, win.width -| 2), .height = body_h });
    var top = scroll.layout(entries, body);
    scroll.observe(s.revision, saved_scroll.top != null);
    var activity_status = s;
    activity_status.new_output = scroll.new_output;
    const actual_h = statusHeight(status_fixed, text.formatWidth(activity_status, scroll.top != null, win.width -| 2).len > 0, above_input - menu_h);
    if (actual_h != activity_h) {
        activity_h = actual_h;
        body_h = above_input - menu_h - activity_h;
        body.height = body_h;
        scroll.* = saved_scroll;
        top = scroll.layout(entries, body);
        scroll.observe(s.revision, saved_scroll.top != null);
        activity_status.new_output = scroll.new_output;
    }
    var y: i32 = -@as(i32, top.row);
    for (entries[top.entry..], top.entry..) |*e, index| {
        if (y >= body_h) break;
        e.user_bg = s.user_bg;
        e.code_bg = s.code_bg;
        const h = e.height(body);
        if (y + h > 0) _ = e.print(body.child(.{ .y_off = @intCast(y), .height = h }), true);
        if (s.hovered == index) {
            const control_hit = e.control(body, s.hovered_row orelse 0);
            const first = if (control_hit) |c| c.first else 0;
            const rows = if (control_hit) |c| c.rows else 0;
            for (0..body_h) |row| {
                if (@as(i32, @intCast(row)) < y + first or @as(i32, @intCast(row)) >= y + first + rows) continue;
                for (0..body.width) |col| {
                    const cell = &win.screen.buf[row * win.screen.width + col + @as(usize, @intCast(body.x_off))];
                    cell.style.bg = s.hover_bg;
                    cell.default = false;
                }
            }
        }
        y += e.extent(body);
    }

    if (s.signed_out and entries.len == 0 and body_h > 0) {
        _ = body.printSegment(.{ .text = "No provider · /provider to sign in", .style = .{ .dim = true } }, .{ .wrap = .none });
    } else if (s.title.len > 0 and entries.len == 0 and body_h > 0) {
        _ = body.printSegment(.{ .text = s.title, .style = .{ .dim = true } }, .{ .wrap = .none });
    }

    if (activity_h > 0) {
        _ = win.child(.{ .x_off = 1, .y_off = body_h + activity_h - 1, .height = 1 }).printSegment(.{ .text = text.formatWidth(activity_status, scroll.top != null, win.width -| 2), .style = s.activityStyle() }, .{ .wrap = .none });
    }
    var model_width: u16 = 0;
    var service_width: u16 = 0;
    for (menu_layout.first..menu_layout.end) |i| {
        if (menu[i].service) |service| {
            model_width = @max(model_width, win.gwidth(menu[i].label));
            service_width = @max(service_width, win.gwidth(service));
        }
    }
    var menu_y = body_h + activity_h;
    for (menu_layout.first..menu_layout.end) |i| {
        const c = menu[i];
        if (groupHeader(menu, i, menu_layout.first)) |group| {
            _ = win.child(.{ .x_off = 2, .y_off = menu_y, .height = 1 }).printSegment(.{ .text = commands.groupName(group), .style = .{ .bold = true, .dim = true } }, .{ .wrap = .none });
            menu_y += 1;
        }
        const chosen = i == menu_sel;
        const row = win.child(.{ .x_off = 2, .y_off = menu_y, .height = 1 });
        if (c.service) |service| {
            const service_w = @min(service_width, row.width / 3);
            const current_w: u16 = if (row.width >= 36) 9 else 0;
            const label_w = @min(model_width, row.width -| (service_w + current_w + 2));
            printFitted(row.child(.{ .width = label_w }), c.label, .{});
            if (row.width > label_w + 2) printFitted(row.child(.{ .x_off = label_w + 2, .width = service_w }), service, .{ .dim = true });
            if (current_w > 0) printFitted(row.child(.{ .x_off = label_w + service_w + 4 }), c.detail, .{ .dim = true });
        } else {
            const label_width = if (c.is_path) (if (c.detail.len == 0) row.width else @min(row.width, 24)) else if (c.command == .provider and c.value != null) @min(row.width, 14) else @min(row.width, 12);
            printFitted(row.child(.{ .width = label_width }), c.label, .{});
            if (row.width > label_width + 2) printFitted(row.child(.{ .x_off = label_width + 2 }), c.detail, .{ .dim = true });
        }
        if (chosen) for (0..row.width) |col| {
            const cell = &win.screen.buf[@as(usize, menu_y) * win.screen.width + col + 2];
            if (s.hover_bg == .default) cell.style.reverse = true else cell.style.bg = s.hover_bg;
            cell.default = false;
        };
        menu_y += 1;
    }

    const input_y = body_h + activity_h + menu_h;
    if (framed) {
        horizontal(win, input_y, "╭", "╮");
        horizontal(win, input_y + input_h + 1, "╰", "╯");
        for (0..input_h) |i| {
            put(win, 0, @intCast(input_y + 1 + i), "│");
            put(win, win.width - 1, @intCast(input_y + 1 + i), "│");
        }
        if (s.cfg.simple) {
            const percent = s.context * 100 / @max(s.cfg.context_window, 1);
            if (percent >= 80) {
                const label = std.fmt.bufPrint(&text.status, " context {d}% ", .{percent}) catch "";
                const w = win.gwidth(label);
                if (w <= win.width - 2) _ = win.child(.{ .x_off = win.width - 1 - w, .y_off = input_y, .height = 1, .width = w }).printSegment(.{ .text = label, .style = .{ .dim = true } }, .{ .wrap = .none });
            }
        } else {
            const meta = text.footer(s, win.width - 7);
            if (meta.len > 0) {
                const meta_w = win.gwidth(meta);
                const meta_x = win.width - 4 - meta_w;
                put(win, meta_x - 1, input_y + input_h + 1, " ");
                _ = win.child(.{ .x_off = meta_x, .y_off = input_y + input_h + 1, .width = meta_w, .height = 1 }).printSegment(.{ .text = meta, .style = .{ .dim = true } }, .{ .wrap = .none });
                put(win, win.width - 4, input_y + input_h + 1, " ");
            }
        }
    } else if (win.width >= 3) {
        _ = win.child(.{ .x_off = 1, .y_off = input_y, .height = 1 }).printSegment(.{ .text = "› ", .style = .{ .fg = .{ .index = 4 } } }, .{ .wrap = .none });
    }
    const placeholder = input.placeholder;
    if (s.cfg.simple) input.placeholder = "";
    defer input.placeholder = placeholder;
    input.draw(win.child(.{ .x_off = x, .y_off = input_y + @as(u16, if (framed) 1 else 0), .width = input_w, .height = input_h }));
    return .{ .top = top, .window = body };
}

/// Framed terminals of 8+ rows always reserve the status row so the input never moves; while the line has text it also reserves a blank row above it, keeping the line off the transcript. Smaller ones reserve the text row only while it has text.
fn statusHeight(fixed: bool, visible: bool, available: u16) u16 {
    if (!fixed and !visible) return 0;
    return @min(@as(u16, if (fixed and visible) 2 else 1), available);
}

const MenuLayout = struct { first: usize = 0, end: usize = 0, rows: u16 = 0 };

fn groupHeader(menu: []const commands.Candidate, index: usize, first: usize) ?commands.Group {
    const group = menu[index].group() orelse return null;
    return if (index == first or menu[index - 1].group() != group) group else null;
}

fn menuLayout(menu: []const commands.Candidate, selected: usize, limit: u16) MenuLayout {
    if (menu.len == 0 or limit == 0) return .{};
    var first = selected;
    var needed: u16 = if (menu[selected].group() == null) 1 else 2;
    while (first > 0) {
        const group = menu[first - 1].group();
        const added: u16 = if (group != null and group != menu[first].group()) 2 else 1;
        if (needed + added > limit) break;
        needed += added;
        first -= 1;
    }
    var layout: MenuLayout = .{ .first = first, .end = first };
    while (layout.end < menu.len) {
        const rows: u16 = 1 + @as(u16, @intFromBool(groupHeader(menu, layout.end, first) != null));
        if (layout.rows + rows > limit) break;
        layout.rows += rows;
        layout.end += 1;
    }
    return layout;
}

fn printFitted(win: vaxis.Window, text: []const u8, style: vaxis.Style) void {
    const fitted = @import("format.zig").fit(text, win.width);
    _ = win.print(&.{ .{ .text = fitted.text, .style = style }, .{ .text = fitted.suffix, .style = style } }, .{ .wrap = .none });
}

fn put(win: vaxis.Window, x: u16, y: u16, glyph: []const u8) void {
    _ = win.child(.{ .x_off = x, .y_off = y, .width = 1, .height = 1 }).printSegment(.{ .text = glyph, .style = .{ .dim = true } }, .{ .wrap = .none });
}

fn horizontal(win: vaxis.Window, y: u16, left: []const u8, right: []const u8) void {
    put(win, 0, y, left);
    for (1..win.width - 1) |i| put(win, @intCast(i), y, "─");
    put(win, win.width - 1, y, right);
}

const testing = std.testing;
const mock_cfg: provider.Config = .{ .base_url = "", .api_key = "", .model = "mock" };

test "draw benchmark: 5000 entries" {
    const benchmark = testing.environ.getPosix("NIB_TUI_BENCH") != null;
    const frames: u8 = if (benchmark) 32 else 1;
    const gpa = testing.allocator;
    const entries = try gpa.alloc(Entry, 5000);
    defer gpa.free(entries);
    const sample = "A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. A long session entry with enough words to wrap over several lines. ";
    for (entries) |*e| e.* = .{ .kind = .assistant, .text = .fromOwnedSlice(@constCast(sample)) };
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 100, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 100, .height = 24, .screen = &screen };
    var text: status.Text = .{};
    var input: Editor = .{};
    defer input.deinit(gpa);
    for ([_]u32{ 0, 1200 }) |offset| {
        var samples: [5]i96 = undefined;
        for (&samples) |*sample_ns| {
            var scroll: Viewport = .{ .pending = -@as(i64, offset) };
            draw(win, entries, &input, &scroll, &.{}, 0, .{ .cfg = mock_cfg }, &text);
            const before = std.Io.Clock.awake.now(testing.io);
            for (0..frames) |_| {
                draw(win, entries, &input, &scroll, &.{}, 0, .{ .cfg = mock_cfg }, &text);
            }
            sample_ns.* = @divTrunc(before.untilNow(testing.io, .awake).nanoseconds, frames);
        }
        std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
        if (benchmark) std.debug.print("\nTUI draw: 5000 entries, offset {d}, median {d} ns/frame\n", .{ offset, samples[2] });
        try testing.expect(screen.cursor_vis);
    }
}

test "draw keeps scrolled body fixed while output arrives and caps input height" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 100, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 100, .height = 24, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    var paragraph: std.ArrayList(u8) = .empty;
    defer paragraph.deinit(gpa);
    for (0..40) |i| try paragraph.print(gpa, "line {d}\n", .{i});
    try t.add(gpa, .assistant, paragraph.items);
    try t.add(gpa, .assistant, "stream");
    var input: Editor = .{};
    defer input.deinit(gpa);
    var text: status.Text = .{};
    var view: Viewport = .{ .pending = -30 };
    const busy: status.Status = .{ .cfg = mock_cfg, .busy = .{ .phase = .thinking, .ms = 0 } };
    draw(win, t.entries.items, &input, &view, &.{}, 0, busy, &text);
    const body_before = try gpa.dupe(vaxis.Cell, screen.buf[0 .. 19 * 100]);
    defer gpa.free(body_before);
    try t.entries.items[1].text.appendSlice(gpa, "\nmore streamed text");
    try t.add(gpa, .info, "Run output");
    draw(win, t.entries.items, &input, &view, &.{}, 0, busy, &text);
    try testing.expectEqualDeep(body_before, screen.buf[0 .. 19 * 100]);
    for (0..16) |i| try input.buf.print(gpa, "input {d}\n", .{i});
    input.cursor = input.buf.items.len;
    draw(win, t.entries.items, &input, &view, &.{}, 0, busy, &text);
    try testing.expectEqual(@as(u16, 9), input.top_row);
    try testing.expectEqual(@as(u16, 22), screen.cursor.row);
    try testing.expect(screen.cursor_vis);
    try testing.expectEqualStrings("i", screen.readCell(3, 15).?.char.grapheme);
}

fn snapshot(gpa: std.mem.Allocator, screen: *const vaxis.Screen) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..screen.height) |row| {
        const start = out.items.len;
        var col: u16 = 0;
        while (col < screen.width) {
            const cell = screen.readCell(col, @intCast(row)).?;
            try out.appendSlice(gpa, cell.char.grapheme);
            col += @max(1, vaxis.gwidth.gwidth(cell.char.grapheme, screen.width_method));
        }
        while (out.items.len > start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "layout snapshots: normal, short, tiny, narrow, menu, busy and history" {
    const gpa = testing.allocator;
    const cases = [_]struct { name: []const u8, w: u16 = 80, h: u16 = 12, busy: bool = false, history: bool = false, menu: bool = false, notice: bool = false }{
        .{ .name = "normal" },
        .{ .name = "standard", .w = 80, .h = 24 },
        .{ .name = "large", .w = 120, .h = 40 },
        .{ .name = "compact", .w = 60, .h = 16 },
        .{ .name = "small", .w = 40, .h = 10 },
        .{ .name = "short", .h = 7 },
        .{ .name = "tiny", .h = 4 },
        .{ .name = "narrow", .w = 18 },
        .{ .name = "menu", .menu = true },
        .{ .name = "busy", .busy = true },
        .{ .name = "history", .history = true },
        .{ .name = "notice", .notice = true },
    };
    var images: std.ArrayList(u8) = .empty;
    defer images.deinit(gpa);
    for (cases) |c| {
        var screen = try vaxis.Screen.init(gpa, .{ .cols = c.w, .rows = c.h, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = c.w, .height = c.h, .screen = &screen };
        var input: Editor = .{};
        defer input.deinit(gpa);
        var t: Transcript = .{};
        defer t.deinit(gpa);
        try t.add(gpa, .assistant, if (c.history) "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14" else "Answer");
        var viewport: Viewport = .{ .pending = if (c.history) -100 else 0 };
        var text: status.Text = .{};
        const candidates = [_]commands.Candidate{.{ .command = .help, .label = "/help", .detail = "show help" }};
        draw(win, t.entries.items, &input, &viewport, if (c.menu) &candidates else &.{}, 0, .{ .cfg = mock_cfg, .busy = if (c.busy) .{ .phase = .thinking, .ms = 1200 } else null, .notice = if (c.notice) "copied 3 chars" else null }, &text);
        try testing.expect(screen.cursor_vis);
        try testing.expectEqual(@as(u16, if (c.h >= 6) c.h - 2 else c.h - 1), screen.cursor.row);
        const image = try snapshot(gpa, &screen);
        defer gpa.free(image);
        try images.print(gpa, "--- {s} {d}x{d} ---\n{s}", .{ c.name, c.w, c.h, image });
        if (testing.environ.getPosix("NIB_TUI_SNAPSHOTS") != null) std.debug.print("\n--- {s} {d}x{d} ---\n{s}", .{ c.name, c.w, c.h, image });
        if (c.h >= 6) {
            try testing.expectEqualStrings("╰", screen.readCell(0, c.h - 1).?.char.grapheme);
            try testing.expectEqualStrings("╯", screen.readCell(c.w - 1, c.h - 1).?.char.grapheme);
        } else try testing.expect(std.mem.indexOf(u8, image, "› Ask about this project · / for commands") != null);
        if (c.busy) try testing.expect(std.mem.indexOf(u8, image, "Waiting for model · turn <1s") != null);

        if (c.notice) try testing.expect(std.mem.indexOf(u8, image, "copied 3 chars") != null);
        if (c.menu) try testing.expect(std.mem.indexOf(u8, image, "/help") != null);
    }
    try testing.expectEqualStrings(@embedFile("layout_snapshots.txt"), images.items);
}

test "status row is reserved so the input box never moves" {
    const gpa = testing.allocator;
    for ([_]u16{ 40, 60, 80, 120, 160 }) |width| for ([_]u16{ 6, 7, 8, 9, 10, 16, 24, 40 }) |height| {
        var screen = try vaxis.Screen.init(gpa, .{ .cols = width, .rows = height, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
        var input: Editor = .{};
        defer input.deinit(gpa);
        var transcript: Transcript = .{};
        defer transcript.deinit(gpa);
        var lines: std.ArrayList(u8) = .empty;
        defer lines.deinit(gpa);
        for (0..40) |i| try lines.print(gpa, "line-{d}\n", .{i});
        try transcript.add(gpa, .assistant, lines.items);
        const status_y = height - 4;
        const states = [_]status.Status{
            .{ .cfg = mock_cfg, .busy = .{ .phase = .scripting, .ms = 0 } },
            .{ .cfg = mock_cfg, .background_count = 1 },
            .{ .cfg = mock_cfg, .notice = "copied 3 chars" },
        };
        for (states) |s| {
            var viewport: Viewport = .{ .pending = 0 };
            var text: status.Text = .{};
            const frame = drawFrame(win, transcript.entries.items, &input, &viewport, &.{}, 0, s, &text).?;
            try testing.expectEqual(if (height >= 8) status_y - 1 else status_y, frame.window.height);
            try testing.expectEqualStrings("╭", screen.readCell(0, status_y + 1).?.char.grapheme);
            try testing.expectEqualStrings("╰", screen.readCell(0, height - 1).?.char.grapheme);
            try testing.expect(!std.mem.eql(u8, " ", screen.readCell(1, status_y).?.char.grapheme));
            if (height >= 8) for (0..width) |col| {
                try testing.expectEqualStrings(" ", screen.readCell(@intCast(col), frame.window.height).?.char.grapheme);
            };
            try testing.expect(screen.cursor_vis);
            try testing.expectEqual(height - 2, screen.cursor.row);
        }
        var viewport: Viewport = .{};
        var text: status.Text = .{};
        const frame = drawFrame(win, transcript.entries.items, &input, &viewport, &.{}, 0, .{ .cfg = mock_cfg }, &text).?;
        try testing.expectEqual(if (height >= 8) status_y else status_y + 1, frame.window.height);
        try testing.expectEqualStrings("╭", screen.readCell(0, height - 3).?.char.grapheme);
        if (height >= 8) for (0..width) |col| {
            try testing.expectEqualStrings(" ", screen.readCell(@intCast(col), status_y).?.char.grapheme);
        };
        try testing.expectEqual(height - 2, screen.cursor.row);
    };
}

test "Simple context label sits on the top border and Normal metadata is spaced" {
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |simple| for ([_]u64{ 0, 79, 80 }) |context| {
        var screen = try vaxis.Screen.init(gpa, .{ .cols = 60, .rows = 12, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 12, .screen = &screen };
        var input: Editor = .{};
        defer input.deinit(gpa);
        var viewport: Viewport = .{};
        var text: status.Text = .{};
        var cfg = mock_cfg;
        cfg.simple = simple;
        cfg.context_window = 100;
        draw(win, &.{}, &input, &viewport, &.{}, 0, .{ .cfg = cfg, .context = context }, &text);
        const image = try snapshot(gpa, &screen);
        defer gpa.free(image);
        var rows = std.mem.splitScalar(u8, image, '\n');
        var top_row: []const u8 = "";
        var bottom_row: []const u8 = "";
        var n: usize = 0;
        while (rows.next()) |row| : (n += 1) {
            if (n == 9) top_row = row;
            if (n == 11) bottom_row = row;
        }
        if (simple) {
            try testing.expectEqual(context >= 80, std.mem.endsWith(u8, top_row, " context 80% ╮"));
            try testing.expect(std.mem.indexOf(u8, bottom_row, "context") == null);
            try testing.expect(std.mem.indexOf(u8, bottom_row, "mock") == null);
        } else {
            try testing.expect(std.mem.indexOf(u8, top_row, "context") == null);
            try testing.expect(std.mem.endsWith(u8, bottom_row, if (context == 0) " mock ──╯" else " mock · context 79% ──╯") or std.mem.endsWith(u8, bottom_row, " mock · context 80% ──╯"));
            try testing.expect(std.mem.indexOf(u8, bottom_row, "% ─") != null or context == 0);
        }
    };
}

test "selection copies displayed blocks at the framed input coordinates" {
    const Selection = @import("selection.zig").Selection;
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 60, .rows = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 12, .screen = &screen };
    var input: Editor = .{};
    defer input.deinit(gpa);
    try input.insert(gpa, "你");
    try input.paste(gpa, "1\n2\n3\n4\n5\n6");
    var viewport: Viewport = .{};
    var text: status.Text = .{};
    draw(win, &.{}, &input, &viewport, &.{}, 0, .{ .cfg = mock_cfg }, &text);
    try testing.expectEqual(@as(u16, 30), screen.cursor.col);
    try testing.expectEqual(@as(u16, 10), screen.cursor.row);
    var selection: Selection = .{};
    _ = selection.mouse(.{ .col = 29, .row = 10, .type = .press, .button = .left, .mods = .{} }, &screen);
    _ = selection.mouse(.{ .col = 3, .row = 10, .type = .drag, .button = .left, .mods = .{} }, &screen);
    try testing.expect(selection.mouse(.{ .col = 3, .row = 10, .type = .release, .button = .left, .mods = .{} }, &screen));
    const copied = try selection.text(gpa, &screen);
    defer gpa.free(copied);
    try testing.expectEqualStrings("你[Pasted #1 · 6 lines · 1]", copied);
    selection.highlight(&screen);
    try testing.expect(screen.readCell(3, 10).?.style.reverse);
    try testing.expect(!screen.readCell(0, 10).?.style.reverse);
}

test "minimal terminal dimensions retain an input cursor" {
    const gpa = testing.allocator;
    for (1..9) |w| for (1..9) |h| {
        var screen = try vaxis.Screen.init(gpa, .{ .cols = @intCast(w), .rows = @intCast(h), .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = @intCast(w), .height = @intCast(h), .screen = &screen };
        var input: Editor = .{};
        defer input.deinit(gpa);
        var viewport: Viewport = .{};
        var text: status.Text = .{};
        draw(win, &.{}, &input, &viewport, &.{}, 0, .{ .cfg = mock_cfg, .busy = .{ .phase = .thinking, .ms = 0 } }, &text);
        try testing.expect(screen.cursor_vis);
        try testing.expect(screen.cursor.col < w and screen.cursor.row < h);
    };
}

test "grouped menus keep the selected command visible within their row budget" {
    var buf: [16]commands.Candidate = undefined;
    const menu = commands.candidates("/", &.{}, &.{}, &.{}, &.{}, &buf);
    for (2..12) |limit| for (0..menu.len) |selected| {
        const layout = menuLayout(menu, selected, @intCast(limit));
        try testing.expect(layout.rows <= limit);
        try testing.expect(layout.first <= selected and layout.end > selected);
    };
}

test "empty screen has one guidance line and no zero statistics" {
    const a = testing.allocator;
    var screen = try vaxis.Screen.init(a, .{ .cols = 60, .rows = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 12, .screen = &screen };
    var input: Editor = .{};
    defer input.deinit(a);
    var scroll: Viewport = .{};
    var text: status.Text = .{};
    draw(win, &.{}, &input, &scroll, &.{}, 0, .{ .cfg = mock_cfg }, &text);
    const image = try snapshot(a, &screen);
    defer a.free(image);
    try testing.expect(std.mem.indexOf(u8, image, "Ask about this project · / for commands") != null);
    try testing.expect(std.mem.indexOf(u8, image, "Enter send") == null);
    try testing.expect(std.mem.indexOf(u8, image, "0%") == null);
}

test "model menu shows distinct model names and current marker at common widths" {
    const a = testing.allocator;
    for ([_]u16{ 60, 120, 160 }) |width| {
        var screen = try vaxis.Screen.init(a, .{ .cols = width, .rows = 16, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(a);
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 16, .screen = &screen };
        var input: Editor = .{};
        defer input.deinit(a);
        var scroll: Viewport = .{};
        var text: status.Text = .{};
        const menu = [_]commands.Candidate{
            .{ .command = .model, .value = "openai/gpt-6.1-sol", .label = "gpt-6.1-sol", .service = "openai", .detail = "current" },
            .{ .command = .model, .value = "openai/gpt-6.1-terra", .label = "gpt-6.1-terra", .service = "openai", .detail = "" },
        };
        draw(win, &.{}, &input, &scroll, &menu, 0, .{ .cfg = mock_cfg }, &text);
        const rendered = try snapshot(a, &screen);
        defer a.free(rendered);
        try testing.expect(std.mem.indexOf(u8, rendered, "gpt-6.1-sol") != null);
        try testing.expect(std.mem.indexOf(u8, rendered, "gpt-6.1-terra") != null);
        try testing.expect(std.mem.indexOf(u8, rendered, "current") != null);
    }
}

test "stream stress frame timings" {
    const a = testing.allocator;
    var screen = try vaxis.Screen.init(a, .{ .cols = 120, .rows = 32, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 32, .screen = &screen };
    var transcript: Transcript = .{};
    defer transcript.deinit(a);
    var input: Editor = .{};
    defer input.deinit(a);
    var scroll: Viewport = .{};
    var text: status.Text = .{};
    const sample = "English 中文 👩‍💻 🙂 **late bold\n- list `late code\n```zig\n" ++ "const value = 123; // 中文\n" ++ "```\nclose` bold**\n";
    var answer: std.ArrayList(u8) = .empty;
    defer answer.deinit(a);
    while ((std.unicode.utf8CountCodepoints(answer.items) catch 0) < 30000) try answer.appendSlice(a, sample);
    for ([_]usize{ 1000, 10000, 30000 }) |size| {
        transcript.clear(a);
        var it = (try std.unicode.Utf8View.init(answer.items)).iterator();
        var end: usize = 0;
        for (0..size) |_| end += it.nextCodepointSlice().?.len;
        try transcript.add(a, .assistant, answer.items[0..end]);
        var times: [100]i64 = undefined;
        for (&times, 0..) |*elapsed, i| {
            transcript.entries.items[0].cached = null;
            if (i % 2 == 0) try input.insert(a, "x") else try input.insert(a, "y");
            const start = std.Io.Clock.Timestamp.now(testing.io, .awake);
            draw(win, transcript.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = mock_cfg }, &text);
            elapsed.* = @intCast(start.durationTo(.now(testing.io, .awake)).raw.toNanoseconds());
        }
        std.mem.sort(i64, &times, {}, std.sort.asc(i64));
        std.debug.print("stress chars={d} frame p95={d}us max={d}us input-to-draw max={d}us\n", .{ size, @divTrunc(times[94], 1000), @divTrunc(times[99], 1000), @divTrunc(times[99], 1000) });
    }
}

test "hover covers full summary width and leaves expanded details unchanged" {
    const a = testing.allocator;
    var screen = try vaxis.Screen.init(a, .{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 80, .height = 24, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(a);
    try t.startRun(a, "console.log('details')");
    const entry = &t.entries.items[0];
    try entry.files.appendSlice(a, "read example.zig");
    entry.open = true;
    var input: Editor = .{};
    defer input.deinit(a);
    var scroll: Viewport = .{};
    var text: status.Text = .{};
    const color: vaxis.Color = .{ .rgb = .{ 8, 8, 8 } };
    const frame = drawFrame(win, t.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = mock_cfg, .hovered = 0, .hover_bg = color }, &text).?;
    const rows = entry.toggleRows(frame.window);
    try testing.expectEqual(@as(u16, 1), rows);
    for (0..rows) |row| for (1..79) |col| {
        try testing.expectEqualDeep(color, screen.readCell(@intCast(col), @intCast(row)).?.style.bg);
    };
    try testing.expect(!std.meta.eql(color, screen.readCell(1, rows).?.style.bg));
}

test "Simple layout snapshots and full-width hit testing" {
    const gpa = testing.allocator;
    var images: std.ArrayList(u8) = .empty;
    defer images.deinit(gpa);
    for ([_]struct { w: u16, h: u16 }{ .{ .w = 80, .h = 24 }, .{ .w = 120, .h = 40 }, .{ .w = 160, .h = 50 }, .{ .w = 40, .h = 10 } }) |size| {
        for ([_]bool{ false, true }) |simple| for ([_]u64{ 0, 84 }) |context| {
            var screen = try vaxis.Screen.init(gpa, .{ .cols = size.w, .rows = size.h, .x_pixel = 0, .y_pixel = 0 });
            defer screen.deinit(gpa);
            const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = size.w, .height = size.h, .screen = &screen };
            var t: Transcript = .{};
            defer t.deinit(gpa);
            try t.add(gpa, .user, "Check the change");
            try t.add(gpa, .assistant, "I will edit and verify it.");
            {
                try t.add(gpa, .run, "await tools.bash({command: 'zig build'});");
                const e = &t.entries.items[t.entries.items.len - 1];
                e.run = .ok;
                try e.refreshLabel(gpa);
            }
            try t.add(gpa, .assistant, "Done.");
            try t.add(gpa, .bill, "41s");
            try t.add(gpa, .user, "Thanks");
            var input: Editor = .{};
            defer input.deinit(gpa);
            var scroll: Viewport = .{};
            var text: status.Text = .{};
            var cfg = mock_cfg;
            cfg.simple = simple;
            cfg.context_window = 100;
            const frame = drawFrame(win, t.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = cfg, .context = context }, &text).?;
            const image = try snapshot(gpa, &screen);
            defer gpa.free(image);
            try images.print(gpa, "--- {s} {d}x{d} context {d}% ---\n{s}", .{ if (simple) "simple" else "normal", size.w, size.h, context, image });
            try testing.expectEqual(@as(u16, 1), frame.window.x_off);
            try testing.expectEqual(context >= 80, std.mem.indexOf(u8, image, "context 84%") != null);
            if (simple) {
                try testing.expect(std.mem.indexOf(u8, image, "╭") != null);
                try testing.expect(std.mem.indexOf(u8, image, "6.6k") == null);
                try testing.expect(std.mem.indexOf(u8, image, "Ask about") == null);
                try testing.expectEqual(@as(u16, 1), t.entries.items[2].height(frame.window));
                const p = @import("selection/history.zig").position(frame, t.entries.items, @intCast(frame.window.x_off + 4), 0).?;
                try testing.expect(p.entry < t.entries.items.len);
            }
            try testing.expectEqualStrings("╰", screen.readCell(0, size.h - 1).?.char.grapheme);
        };
    }
    if (testing.environ.getPosix("NIB_TUI_SNAPSHOTS") != null) std.debug.print("\nSIMPLE_SNAPSHOTS_BEGIN\n{s}SIMPLE_SNAPSHOTS_END\n", .{images.items});
    try testing.expectEqualStrings(@embedFile("simple_snapshots.txt"), images.items);
}

test "Simple Run marks and selection preserve details" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 120, .rows = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 40, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.add(gpa, .run, "script");
    const e = &t.entries.items[0];
    try e.output.appendSlice(gpa, "result");
    var input: Editor = .{};
    defer input.deinit(gpa);
    var scroll: Viewport = .{};
    var text: status.Text = .{};
    var cfg = mock_cfg;
    cfg.simple = true;
    for ([_]@FieldType(Entry, "run"){ .ok, .failed, .running, .warning }) |state| {
        e.run = state;
        try e.refreshLabel(gpa);
        const frame = drawFrame(win, t.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = cfg, .hovered = 0, .hover_bg = .{ .rgb = .{ 18, 18, 18 } } }, &text).?;
        try testing.expectEqual(@as(u16, 1), e.height(frame.window));
        const image = try snapshot(gpa, &screen);
        defer gpa.free(image);
        try testing.expect(std.mem.indexOf(u8, image, switch (state) {
            .ok => "  Run",
            .failed => "✗ Run",
            .running => "Run · running",
            else => "! Run",
        }) != null);
        try testing.expect(std.mem.indexOf(u8, image, "mock") == null);
        const p = @import("selection/history.zig").position(frame, t.entries.items, 15, 0).?;
        try testing.expectEqual(@as(usize, 0), p.entry);
        try testing.expectEqual(@as(u16, 0), p.row);
        try testing.expectEqualDeep(vaxis.Color{ .rgb = .{ 18, 18, 18 } }, screen.readCell(11, 0).?.style.bg);
        try testing.expectEqualDeep(vaxis.Color.default, screen.readCell(0, 0).?.style.bg);
        e.open = true;
        const expanded = drawFrame(win, t.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = cfg }, &text).?;
        try testing.expect(e.height(expanded.window) > 1);
        const history: @import("selection/history.zig").History = .{ .anchor = .{ .entry = 0, .row = 0, .col = 0 }, .end = .{ .entry = 0, .row = 0, .col = 119 } };
        const copied = try history.text(gpa, expanded, t.entries.items);
        defer gpa.free(copied);
        try testing.expect(!std.mem.startsWith(u8, copied, "          "));
        e.open = false;
    }
}

test "resize and mode transitions match a fresh frame" {
    const a = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(a);
    try t.add(a, .user, "Check symbols 界 and wrapping");
    try t.add(a, .assistant, "# Heading\nA completed **Markdown** line with 界 symbols and enough words to wrap in a narrow terminal.\n```zig\nconst value = 42;\n```\nDone.");
    try t.startRun(a, "secret-script");
    try t.endRun(a, true, "result text", 1, try .init(a, &.{
        .{ .path = "src/a.zig", .added = 1, .removed = 1, .diff = "-old\n+new\n" },
        .{ .path = "src/b.zig", .added = 1, .removed = 0, .diff = "+second\n" },
    }));
    t.entries.items[2].open = true;
    t.entries.items[2].details.open = true;
    t.entries.items[2].details.script_open = true;
    t.entries.items[2].details.result_open = false;
    t.entries.items[2].changes.files[0].open = true;
    try t.add(a, .bill, "1 Run · 2 steps");
    try t.add(a, .user, "Again");
    var input: Editor = .{};
    defer input.deinit(a);
    var scroll: Viewport = .{};
    var text: status.Text = .{};
    var screen = try vaxis.Screen.init(a, .{ .cols = 160, .rows = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    for ([_]struct { width: u16, simple: bool }{ .{ .width = 60, .simple = false }, .{ .width = 120, .simple = false }, .{ .width = 120, .simple = true }, .{ .width = 160, .simple = true }, .{ .width = 160, .simple = false }, .{ .width = 60, .simple = false } }) |state| {
        var cfg = mock_cfg;
        cfg.simple = state.simple;
        if (screen.width != state.width) {
            screen.deinit(a);
            screen = try vaxis.Screen.init(a, .{ .cols = state.width, .rows = 40, .x_pixel = 0, .y_pixel = 0 });
        }
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = state.width, .height = 40, .screen = &screen };
        const frame = drawFrame(win, t.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = cfg }, &text).?;
        try testing.expectEqual(@as(u16, 1), frame.window.x_off);
        const before = try snapshot(a, &screen);
        defer a.free(before);
        for (t.entries.items) |*e| {
            e.cached = null;
            e.markdown_cache.deinit(a);
            e.markdown_cache = .{};
        }
        var fresh: Viewport = .{};
        var fresh_screen = try vaxis.Screen.init(a, .{ .cols = state.width, .rows = 40, .x_pixel = 0, .y_pixel = 0 });
        defer fresh_screen.deinit(a);
        var fresh_win = win;
        fresh_win.screen = &fresh_screen;
        draw(fresh_win, t.entries.items, &input, &fresh, &.{}, 0, .{ .cfg = cfg }, &text);
        const after = try snapshot(a, &fresh_screen);
        defer a.free(after);
        try testing.expectEqualStrings(after, before);
        try testing.expect(t.entries.items[2].open);
        try testing.expect(t.entries.items[2].details.script_open);
        try testing.expect(!t.entries.items[2].details.result_open.?);
        try testing.expect(t.entries.items[2].changes.files[0].open.?);
        try testing.expect(t.entries.items[2].changes.files[1].open == null);
    }
}

fn drawText(a: std.mem.Allocator, t: *Transcript, cfg: provider.Config, title: []const u8, signed_out: bool, width: u16) ![]u8 {
    var input: Editor = .{};
    defer input.deinit(a);
    var scroll: Viewport = .{};
    var text: status.Text = .{};
    var screen = try vaxis.Screen.init(a, .{ .cols = width, .rows = 16, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 16, .screen = &screen };
    draw(win, t.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = cfg, .title = title, .signed_out = signed_out }, &text);
    return snapshot(a, &screen);
}

test "title line shows on an empty transcript, also in Simple mode, never when signed out or with entries" {
    const a = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(a);
    var cfg = mock_cfg;
    const empty = try drawText(a, &t, cfg, "nibcode · main · mock", false, 60);
    defer a.free(empty);
    try testing.expect(std.mem.startsWith(u8, empty, " nibcode · main · mock\n"));
    cfg.simple = true;
    const simple = try drawText(a, &t, cfg, "nibcode · main · mock", false, 60);
    defer a.free(simple);
    try testing.expect(std.mem.startsWith(u8, simple, " nibcode · main · mock\n"));
    const out = try drawText(a, &t, mock_cfg, "", true, 60);
    defer a.free(out);
    try testing.expect(std.mem.startsWith(u8, out, " No provider · /provider to sign in\n"));
    try t.add(a, .assistant, "Hello");
    const used = try drawText(a, &t, mock_cfg, "nibcode · main · mock", false, 60);
    defer a.free(used);
    try testing.expect(std.mem.indexOf(u8, used, "nibcode") == null);
}

test "changes and elapsed time share a footer and are hidden in Simple mode" {
    const a = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(a);
    try t.add(a, .assistant, "Done");
    try t.add(a, .bill, "48s");
    try t.addChanges(a, try @import("transcript/changes.zig").turnChanges(a, &.{
        .{ .path = "src/tui.zig", .added = 30, .removed = 4 },
        .{ .path = "docs/ui-style.md", .added = 2, .removed = 0 },
    }));
    const closed = try drawText(a, &t, mock_cfg, "", false, 60);
    defer a.free(closed);
    try testing.expectEqual(@as(usize, 2), t.entries.items.len);
    try testing.expect(std.mem.startsWith(u8, closed, " Done\n\n 2 files changed · +32 −4"));
    try testing.expect(std.mem.indexOf(u8, closed, "48s\n") != null);
    t.entries.items[1].open = true;
    const open = try drawText(a, &t, mock_cfg, "", false, 60);
    defer a.free(open);
    try testing.expect(std.mem.indexOf(u8, open, "   src/tui.zig       +30 −4\n   docs/ui-style.md   +2\n") != null);
    var simple_cfg = mock_cfg;
    simple_cfg.simple = true;
    const simple = try drawText(a, &t, simple_cfg, "", false, 60);
    defer a.free(simple);
    try testing.expect(std.mem.indexOf(u8, simple, "files changed") == null);
    try testing.expect(std.mem.indexOf(u8, simple, "48s") == null);
}

test "nested Run hover highlights only its heading and output stays readable" {
    const a = testing.allocator;
    var screen = try vaxis.Screen.init(a, .{ .cols = 120, .rows = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 40, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(a);
    try t.startRun(a, "script-body");
    try t.endRun(a, true, "output-body", 1, .{});
    const e = &t.entries.items[0];
    e.open = true;
    e.details.open = true;
    e.details.script_open = true;
    var input: Editor = .{};
    defer input.deinit(a);
    var scroll: Viewport = .{};
    var text: status.Text = .{};
    const color: vaxis.Color = .{ .rgb = .{ 18, 18, 18 } };
    const frame = drawFrame(win, t.entries.items, &input, &scroll, &.{}, 0, .{ .cfg = mock_cfg, .hovered = 0, .hovered_row = 2, .hover_bg = color }, &text).?;
    try testing.expectEqualDeep(color, screen.readCell(3, 2).?.style.bg);
    try testing.expectEqualDeep(vaxis.Color.default, screen.readCell(3, 0).?.style.bg);
    try testing.expectEqualDeep(vaxis.Color.default, screen.readCell(7, 3).?.style.bg);
    try testing.expectEqualStrings("o", screen.readCell(7, 3).?.char.grapheme);
    try testing.expect(!screen.readCell(7, 3).?.style.dim);
    try testing.expectEqualStrings("s", screen.readCell(7, 5).?.char.grapheme);
    try testing.expect(!screen.readCell(7, 5).?.style.dim);
    const history: @import("selection/history.zig").History = .{ .anchor = .{ .entry = 0, .row = 3, .col = 7 }, .end = .{ .entry = 0, .row = 3, .col = 17 } };
    const copied = try history.text(a, frame, t.entries.items);
    defer a.free(copied);
    try testing.expectEqualStrings("output-body", copied);
}

test "model menu separates provider and current state from keyboard selection" {
    const a = testing.allocator;
    const colors = [_]vaxis.Color{ .default, .{ .rgb = .{ 18, 18, 18 } }, .{ .rgb = .{ 237, 237, 237 } } };
    for ([_]u16{ 60, 120, 160 }) |width| for (colors) |color| {
        var screen = try vaxis.Screen.init(a, .{ .cols = width, .rows = 16, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(a);
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 16, .screen = &screen };
        var input: Editor = .{};
        defer input.deinit(a);
        var scroll: Viewport = .{};
        var text: status.Text = .{};
        const menu = [_]commands.Candidate{
            .{ .command = .model, .value = "codex/gpt-6.1-sol", .label = "gpt-6.1-sol", .service = "codex", .detail = "current" },
            .{ .command = .model, .value = "local/gpt-6.1-sol", .label = "gpt-6.1-sol", .service = "local", .detail = "" },
        };
        draw(win, &.{}, &input, &scroll, &menu, 1, .{ .cfg = mock_cfg, .hover_bg = color }, &text);
        const image = try snapshot(a, &screen);
        defer a.free(image);
        try testing.expect(std.mem.indexOf(u8, image, "gpt-6.1-sol  codex  current") != null);
        try testing.expect(std.mem.indexOf(u8, image, "gpt-6.1-sol  local") != null);
        const current = screen.readCell(2, 11).?;
        const selected = screen.readCell(2, 12).?;
        try testing.expectEqualStrings("g", current.char.grapheme);
        try testing.expect(!current.style.bold and !current.style.reverse);
        try testing.expect(!selected.style.bold);
        if (color == .default) try testing.expect(selected.style.reverse) else try testing.expectEqualDeep(color, selected.style.bg);
    };
}

test "narrow changes footer puts elapsed time on its own row" {
    const a = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(a);
    try t.add(a, .bill, "1m40s");
    try t.addChanges(a, try @import("transcript/changes.zig").turnChanges(a, &.{.{ .path = "src/a.zig", .added = 42, .removed = 7 }}));
    var screen = try vaxis.Screen.init(a, .{ .cols = 26, .rows = 8, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 26, .height = 8, .screen = &screen };
    const e = &t.entries.items[0];
    try testing.expectEqual(@as(u16, 2), e.print(win, true));
    const image = try snapshot(a, &screen);
    defer a.free(image);
    try testing.expect(std.mem.startsWith(u8, image, "1 file changed · +42 −7\n                     1m40s\n"));
}
