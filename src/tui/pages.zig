const std = @import("std");
const Entry = @import("transcript.zig").Entry;
const Viewport = @import("viewport.zig").Viewport;

pub const Pages = struct {
    index: ?usize = null,
    focus: Focus = .blank,
    saved: std.ArrayList(Viewport) = .empty,

    pub const Focus = enum { page, blank, editing };

    pub const Page = struct {
        heading: ?usize = null,
        start: usize = 0,
        end: usize = 0,
        count: usize = 0,
        index: usize = 0,

        pub fn latest(p: Page) bool {
            return p.index + 1 >= p.count;
        }
    };

    pub fn reset(p: *Pages) void {
        p.index = null;
        p.focus = .blank;
        p.saved.clearRetainingCapacity();
    }

    pub fn current(p: Pages, entries: []const Entry) Page {
        var page: Page = .{ .end = entries.len };
        for (entries, 0..) |e, i| {
            if (!e.turn_heading) continue;
            if (p.index == null or page.count <= p.index.?) {
                page.heading = i;
                page.start = i + 1;
                page.index = page.count;
            } else if (page.end == entries.len) {
                page.end = i;
            }
            page.count += 1;
        }
        return page;
    }

    pub fn save(p: *Pages, a: std.mem.Allocator, page: Page, scroll: Viewport) !void {
        while (p.saved.items.len < page.count) try p.saved.append(a, .{});
        p.saved.items[page.index] = scroll;
    }

    pub fn switchTo(p: *Pages, a: std.mem.Allocator, page: Page, next: usize, scroll: *Viewport) !void {
        try p.save(a, page, scroll.*);
        p.index = if (next + 1 == page.count) null else next;
        scroll.* = p.saved.items[next];
    }
};

pub const Prompt = struct {
    x: u16,
    y: u16,
    width: u16,
    rows: u16,
    skip: u16 = 0,

    pub fn bodyWidth(p: Prompt) u16 {
        return @max(1, p.width -| 2);
    }
};

pub const Flight = struct {
    pub const duration = 200;
    from: Prompt,
    at: std.Io.Clock.Timestamp,
    cols: u16,
    rows: u16,

    pub fn sample(f: Flight, at: std.Io.Clock.Timestamp, cols: u16, rows: u16) ?Prompt {
        const ms = f.at.durationTo(at).raw.toMilliseconds();
        if (ms >= duration or cols != f.cols or rows != f.rows) return null;
        const left: f64 = 1 - @as(f64, @floatFromInt(@max(0, ms))) / duration;
        const t = 1 - left * left * left;
        const x = mix(f.from.x, margin(cols), t);
        const right = mix(f.from.x + f.from.width, cols - margin(cols), t);
        return .{ .x = x, .y = mix(f.from.y, headingRow(rows), t), .width = right -| x, .rows = f.from.rows, .skip = f.from.skip };
    }

    fn mix(a: u16, b: u16, t: f64) u16 {
        const x: f64 = @floatFromInt(a);
        return @intFromFloat(@round(x + (@as(f64, @floatFromInt(b)) - x) * t));
    }
};

pub fn margin(cols: u16) u16 {
    return if (cols >= 16) 2 else if (cols >= 6) 1 else 0;
}

pub fn headingRow(rows: u16) u16 {
    return if (rows >= 8) 1 else 0;
}

test "Turn pages ignore interjections and keep independent viewports" {
    const a = std.testing.allocator;
    var p: Pages = .{ .focus = .page };
    defer p.saved.deinit(a);
    const entries = [_]Entry{
        .{ .kind = .user, .turn_heading = true },
        .{ .kind = .user },
        .{ .kind = .assistant },
        .{ .kind = .user, .turn_heading = true },
        .{ .kind = .assistant },
    };
    var scroll: Viewport = .{ .top = .{ .entry = 4, .row = 2 } };
    const last = p.current(&entries);
    try std.testing.expectEqual(Pages.Page{ .heading = 3, .start = 4, .end = 5, .count = 2, .index = 1 }, last);
    try p.switchTo(a, last, 0, &scroll);
    try std.testing.expectEqual(Pages.Page{ .heading = 0, .start = 1, .end = 3, .count = 2 }, p.current(&entries));
    try std.testing.expectEqual(null, scroll.top);
    scroll.top = .{ .entry = 2, .row = 4 };
    try p.switchTo(a, p.current(&entries), 1, &scroll);
    try std.testing.expectEqual(@as(u16, 2), scroll.top.?.row);
    try p.switchTo(a, p.current(&entries), 0, &scroll);
    try std.testing.expectEqual(@as(u16, 4), scroll.top.?.row);
}

test "flight opens both sides as it rises, then lands or snaps on resize" {
    const at: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
    const f: Flight = .{ .from = .{ .x = 47, .y = 15, .width = 26, .rows = 2 }, .at = at, .cols = 120, .rows = 32 };
    try std.testing.expectEqual(f.from, f.sample(at, 120, 32).?);
    const mid = f.sample(at.addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(80) }), 120, 32).?;
    try std.testing.expect(mid.x < f.from.x and mid.y < f.from.y);
    try std.testing.expect(mid.x + mid.width > f.from.x + f.from.width);
    try std.testing.expectEqual(@as(u16, 2), mid.rows);
    try std.testing.expectEqual(null, f.sample(at.addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(200) }), 120, 32));
    try std.testing.expectEqual(null, f.sample(at, 60, 32));
}
