const std = @import("std");
const vaxis = @import("vaxis");
const Progress = @import("../session/events.zig").Progress;

pub const Tree = struct {
    rows: std.ArrayList(Row) = .empty,

    pub fn deinit(tree: *Tree, gpa: std.mem.Allocator) void {
        for (tree.rows.items) |row| gpa.free(row.text);
        tree.rows.deinit(gpa);
        tree.* = .{};
    }

    pub fn update(tree: *Tree, gpa: std.mem.Allocator, agents: []const Progress) !void {
        var next: Tree = .{};
        errdefer next.deinit(gpa);
        try next.rows.ensureTotalCapacity(gpa, agents.len);
        for (agents, 0..) |p, i| next.rows.appendAssumeCapacity(try Row.init(gpa, p, i + 1 == agents.len));
        tree.deinit(gpa);
        tree.* = next;
    }

    pub fn print(tree: *const Tree, win: vaxis.Window, commit: bool) u16 {
        for (tree.rows.items, 0..) |*row, i| {
            row.print(win.child(.{ .y_off = @intCast(i), .height = 1 }), commit);
        }
        return @intCast(tree.rows.items.len);
    }
};

const Row = struct {
    text: []u8,
    prompt_start: usize,
    prompt_end: usize,
    status_end: usize,
    tools_end: usize,
    prompt_omitted: bool,

    fn init(gpa: std.mem.Allocator, p: Progress, last: bool) !Row {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(gpa);
        try text.print(gpa, "  {s} {s}{s} {s}", .{ if (last) "└─" else "├─", p.id, if (p.race) " race" else if (p.fork) " fork" else "", if (p.kind == .bash) "bash " else "" });
        const prompt_start = text.items.len;
        var end: usize = 0;
        var chars: usize = 0;
        var it = vaxis.unicode.graphemeIterator(p.prompt);
        while (it.next()) |grapheme| {
            const bytes = grapheme.bytes(p.prompt);
            const count = std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
            if (chars + count > 40) break;
            chars += count;
            end += bytes.len;
        }
        try text.appendSlice(gpa, p.prompt[0..end]);
        const prompt_end = text.items.len;
        const live = p.state == .queued or p.state == .working;
        const state = if (p.detached) (if (live) "detached" else @tagName(p.state)) else if (p.background) "background" else @tagName(p.state);
        if (p.kind == .bash) {
            try text.appendSlice(gpa, " · ");
            try appendElapsed(gpa, &text, p.elapsed_ms);
            try text.print(gpa, " · {s}", .{state});
        } else {
            try text.print(gpa, " · {s} · step {d}", .{ state, p.step });
        }
        const status_end = text.items.len;
        for (p.tools, 0..) |name, i| {
            try text.appendSlice(gpa, if (i == 0) " · " else ", ");
            try text.appendSlice(gpa, name);
        }
        const tools_end = text.items.len;
        for (p.files, 0..) |path, i| {
            try text.appendSlice(gpa, if (i > 0) ", " else if (p.tools.len > 0) " " else " · ");
            try text.appendSlice(gpa, path);
        }
        for (text.items) |*byte| {
            if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
        }
        return .{
            .text = try text.toOwnedSlice(gpa),
            .prompt_start = prompt_start,
            .prompt_end = prompt_end,
            .status_end = status_end,
            .tools_end = tools_end,
            .prompt_omitted = end < p.prompt.len,
        };
    }

    fn print(row: *const Row, win: vaxis.Window, commit: bool) void {
        const prefix = row.text[0..row.prompt_start];
        const status = row.text[row.prompt_end..row.status_end];
        const used = fit(win, row.text[row.status_end..row.tools_end], win.width -| (width(win, prefix) +| width(win, status)), false);
        const fixed = width(win, prefix) +| width(win, status) +| width(win, used.text) +| width(win, used.suffix);
        const prompt = fit(win, row.text[row.prompt_start..row.prompt_end], win.width -| fixed, row.prompt_omitted);
        const files = fit(win, row.text[row.tools_end..], win.width -| (fixed +| width(win, prompt.text) +| width(win, prompt.suffix)), false);
        const dim: vaxis.Style = .{ .dim = true };
        _ = win.print(&.{
            .{ .text = prefix, .style = dim },
            .{ .text = prompt.text, .style = dim },
            .{ .text = prompt.suffix, .style = dim },
            .{ .text = status, .style = dim },
            .{ .text = used.text, .style = dim },
            .{ .text = used.suffix, .style = dim },
            .{ .text = files.text, .style = dim },
            .{ .text = files.suffix, .style = dim },
        }, .{ .wrap = .none, .commit = commit });
    }
};

pub fn appendElapsed(gpa: std.mem.Allocator, out: *std.ArrayList(u8), elapsed_ms: u64) !void {
    if (elapsed_ms >= 60_000) {
        try out.print(gpa, "{d}m{d}s", .{ elapsed_ms / 60_000, elapsed_ms / 1000 % 60 });
    } else {
        try out.print(gpa, "{d}.{d}s", .{ elapsed_ms / 1000, elapsed_ms % 1000 / 100 });
    }
}

fn width(win: vaxis.Window, text: []const u8) u16 {
    return vaxis.gwidth.gwidth(text, win.screen.width_method);
}

const Fitted = struct { text: []const u8, suffix: []const u8 = "" };

fn fit(win: vaxis.Window, text: []const u8, columns: u16, omitted: bool) Fitted {
    if (!omitted and width(win, text) <= columns) return .{ .text = text };
    if (columns == 0) return .{ .text = "" };
    const available = columns -| width(win, "…");
    var end: usize = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |grapheme| {
        const next = end + grapheme.bytes(text).len;
        if (width(win, text[0..next]) > available) break;
        end = next;
    }
    return .{ .text = text[0..end], .suffix = "…" };
}

const testing = std.testing;

fn expectLine(screen: *vaxis.Screen, y: u16, expected: []const u8) !void {
    var x: u16 = 0;
    var it = vaxis.unicode.graphemeIterator(expected);
    while (it.next()) |g| {
        const bytes = g.bytes(expected);
        const cell = screen.readCell(x, y).?;
        try testing.expectEqualStrings(bytes, cell.char.grapheme);
        try testing.expect(cell.style.dim);
        x += vaxis.gwidth.gwidth(bytes, screen.width_method);
    }
    while (x < screen.width) : (x += 1) try testing.expectEqualStrings(" ", screen.readCell(x, y).?.char.grapheme);
}

test "tree rows fit Unicode prompts and files around state step and tools" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 120, .rows = 4, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 4, .screen = &screen };
    var tree: Tree = .{};
    defer tree.deinit(gpa);
    try tree.update(gpa, &.{
        .{ .id = "a1", .prompt = "修复登录流程，补充测试", .step = 56, .tools = &.{ "edit", "bash" }, .files = &.{"src/auth.zig"} },
        .{ .id = "a2", .prompt = "check config", .state = .done, .step = 27, .tools = &.{ "grep", "read" } },
        .{ .id = "a3", .prompt = "test", .state = .failed, .step = 38, .files = &.{"docs/config.md"} },
    });
    try testing.expectEqual(@as(u16, 3), tree.print(win, true));
    try expectLine(&screen, 0, "  ├─ a1 修复登录流程，补充测试 · working · step 56 · edit, bash src/auth.zig");
    try expectLine(&screen, 1, "  ├─ a2 check config · done · step 27 · grep, read");
    try expectLine(&screen, 2, "  └─ a3 test · failed · step 38 · docs/config.md");
    try expectLine(&screen, 3, "");

    win.clear();
    win.width = 48;
    _ = tree.print(win, true);
    try expectLine(&screen, 0, "  ├─ a1 修复登… · working · step 56 · edit, bash");
    win.width = 120;
    win.clear();
    win.width = 75;
    _ = tree.print(win, true);
    try expectLine(&screen, 0, "  ├─ a1 修复登录流程，补充测试 · working · step 56 · edit, bash src/auth.z…");
}

test "tree previews sanitize control bytes and cap prompts without wrapping" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 120, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 3, .screen = &screen };
    var tree: Tree = .{};
    defer tree.deinit(gpa);
    try tree.update(gpa, &.{
        .{ .id = "a1", .prompt = "line\nnext\r\t\x1b", .state = .queued, .files = &.{"a\nb"} },
        .{ .id = "a2", .prompt = "12345678901234567890123456789012345678901234567890", .state = .timed_out, .step = 4 },
    });
    _ = tree.print(win, true);
    try expectLine(&screen, 0, "  ├─ a1 line next    · queued · step 0 · a b");
    try expectLine(&screen, 1, "  └─ a2 1234567890123456789012345678901234567890… · timed_out · step 4");
    try expectLine(&screen, 2, "");
    for (0..121) |columns| {
        win.width = 120;
        win.clear();
        win.width = @intCast(columns);
        try testing.expectEqual(@as(u16, 2), tree.print(win, false));
        try testing.expectEqual(@as(u16, 2), tree.print(win, true));
        try expectLine(&screen, 2, "");
    }
}

test "truncation preserves complete graphemes" {
    var screen: vaxis.Screen = .{ .width_method = .unicode };
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 8, .height = 1, .screen = &screen };
    const text = "á👩‍💻xyz";
    const fitted = fit(win, text, 4, false);
    try testing.expectEqualStrings("á👩‍💻", fitted.text);
    try testing.expectEqualStrings("…", fitted.suffix);
}

test "mixed task ids retain input order and background hides terminal states until delivery" {
    const gpa = testing.allocator;
    var tree: Tree = .{};
    defer tree.deinit(gpa);
    try tree.update(gpa, &.{
        .{ .id = "a10", .prompt = "first", .step = 2 },
        .{ .id = "b2", .kind = .bash, .prompt = "echo ready", .background = true, .state = .done, .elapsed_ms = 192_900 },
        .{ .id = "a2", .prompt = "last", .background = true, .state = .failed, .step = 7 },
    });
    try testing.expectEqualStrings("  ├─ a10 first · working · step 2", tree.rows.items[0].text);
    try testing.expectEqualStrings("  ├─ b2 bash echo ready · 3m12s · background", tree.rows.items[1].text);
    try testing.expectEqualStrings("  └─ a2 last · background · step 7", tree.rows.items[2].text);
}

test "bash elapsed formatting at the minute boundary" {
    const gpa = testing.allocator;
    const cases = .{
        .{ 0, "0.0s" },
        .{ 42_399, "42.3s" },
        .{ 59_999, "59.9s" },
        .{ 60_000, "1m0s" },
        .{ 192_999, "3m12s" },
        .{ 3_600_000, "60m0s" },
    };
    inline for (cases) |case| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        try appendElapsed(gpa, &text, case[0]);
        try testing.expectEqualStrings(case[1], text.items);
    }
}

test "narrow bash rows preserve id duration and delivery state before command" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 60, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 36, .height = 3, .screen = &screen };
    var tree: Tree = .{};
    defer tree.deinit(gpa);
    try tree.update(gpa, &.{
        .{ .id = "b2", .kind = .bash, .prompt = "abcdefghijklmnopqrstuvwxyz", .background = true, .elapsed_ms = 42_300 },
        .{ .id = "b3", .kind = .bash, .prompt = "abcdefghijklmnopqrstuvwxyz", .background = true, .state = .done, .elapsed_ms = 192_000 },
    });
    _ = tree.print(win, true);
    try expectLine(&screen, 0, "  ├─ b2 bash a… · 42.3s · background");
    try expectLine(&screen, 1, "  └─ b3 bash a… · 3m12s · background");
    try expectLine(&screen, 2, "");
}

test "narrow agent rows reserve state and step before long tool and file names" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 60, .rows = 2, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 32, .height = 2, .screen = &screen };
    var tree: Tree = .{};
    defer tree.deinit(gpa);
    try tree.update(gpa, &.{.{ .id = "a2", .prompt = "a long prompt", .step = 12, .tools = &.{ "read", "edit", "write" }, .files = &.{"src/a_very_long_path.zig"} }});
    _ = tree.print(win, true);
    try expectLine(&screen, 0, "  └─ a2  · working · step 12 · …");
    win.clear();
    win.width = 28;
    _ = tree.print(win, true);
    try expectLine(&screen, 0, "  └─ a2  · working · step 12");
    try expectLine(&screen, 1, "");
}

test "detached shows terminal states while ordinary background waits for delivery" {
    const gpa = testing.allocator;
    var tree: Tree = .{};
    defer tree.deinit(gpa);
    try tree.update(gpa, &.{
        .{ .id = "b1", .kind = .bash, .prompt = "server", .background = true, .detached = true },
        .{ .id = "b2", .kind = .bash, .prompt = "test", .background = true },
        .{ .id = "b3", .kind = .bash, .prompt = "exit", .background = true, .detached = true, .state = .done },
        .{ .id = "b4", .kind = .bash, .prompt = "stop", .background = true, .detached = true, .state = .canceled },
    });
    try testing.expectEqualStrings("  ├─ b1 bash server · 0.0s · detached", tree.rows.items[0].text);
    try testing.expectEqualStrings("  ├─ b2 bash test · 0.0s · background", tree.rows.items[1].text);
    try testing.expectEqualStrings("  ├─ b3 bash exit · 0.0s · done", tree.rows.items[2].text);
    try testing.expectEqualStrings("  └─ b4 bash stop · 0.0s · canceled", tree.rows.items[3].text);
}

test "fork label follows task id" {
    var tree: Tree = .{};
    defer tree.deinit(testing.allocator);
    try tree.update(testing.allocator, &.{.{ .id = "a3", .fork = true, .prompt = "child" }});
    try testing.expectEqualStrings("  └─ a3 fork child · working · step 0", tree.rows.items[0].text);
}

test "race tree preserves won stopped and failed branch identities" {
    var tree: Tree = .{};
    defer tree.deinit(testing.allocator);
    try tree.update(testing.allocator, &.{
        .{ .id = "a1", .prompt = "first", .fork = true, .race = true, .state = .won },
        .{ .id = "a2", .prompt = "second", .fork = true, .race = true, .state = .stopped },
        .{ .id = "a3", .prompt = "third", .fork = true, .race = true, .state = .failed },
    });
    try testing.expectEqualStrings("  ├─ a1 race first · won · step 0", tree.rows.items[0].text);
    try testing.expectEqualStrings("  ├─ a2 race second · stopped · step 0", tree.rows.items[1].text);
    try testing.expectEqualStrings("  └─ a3 race third · failed · step 0", tree.rows.items[2].text);
}
