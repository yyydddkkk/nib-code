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
    pad: u16 = 0,

    pub fn bodyWidth(p: Prompt) u16 {
        return @max(1, p.width -| 2);
    }
};

pub const Flight = struct {
    pub const duration = 230;
    from: Prompt,
    at: std.Io.Clock.Timestamp,
    cols: u16,
    rows: u16,

    pub const Frame = struct {
        prompt: Prompt,
        tint: f64,
        reveal: bool,
    };

    pub fn sample(f: Flight, at: std.Io.Clock.Timestamp, cols: u16, rows: u16) ?Frame {
        const ms = f.at.durationTo(at).raw.toMilliseconds();
        if (ms >= duration or cols != f.cols or rows != f.rows) return null;
        const travel = ease(ms, 0, 194);
        const spread = ease(ms, 32, 218);
        const x = mix(f.from.x, margin(cols), travel);
        const right = mix(x + f.from.width, cols - margin(cols), spread);
        return .{
            .prompt = .{
                .x = x,
                .y = mix(f.from.y, headingRow(rows), travel),
                .width = right - x,
                .rows = f.from.rows,
                .skip = f.from.skip,
                .pad = mix(0, headingPadding(rows), spread),
            },
            .tint = ease(ms, 32, 196),
            .reveal = ms >= 180,
        };
    }

    fn ease(ms: i64, start: i64, end: i64) f64 {
        const t = @as(f64, @floatFromInt(std.math.clamp(ms, start, end) - start)) / @as(f64, @floatFromInt(end - start));
        return t * t * (3 - 2 * t);
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
    return @as(u16, if (rows >= 8) 1 else 0) + headingPadding(rows);
}

pub fn headingPadding(rows: u16) u16 {
    return if (rows >= 6) 1 else 0;
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
    const start = f.sample(at, 120, 32).?;
    try std.testing.expectEqual(f.from, start.prompt);
    try std.testing.expectEqual(0, start.tint);
    const early = f.sample(at.addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(16) }), 120, 32).?;
    try std.testing.expect(f.from.x - early.prompt.x <= 1);
    try std.testing.expectEqual(f.from.width, early.prompt.width);
    try std.testing.expectEqual(0, early.tint);
    const mid = f.sample(at.addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(125) }), 120, 32).?;
    try std.testing.expect(mid.prompt.x < f.from.x and mid.prompt.y < f.from.y);
    try std.testing.expect(mid.prompt.x + mid.prompt.width > f.from.x + f.from.width);
    try std.testing.expectEqual(@as(u16, 2), mid.prompt.rows);
    try std.testing.expect(mid.tint > 0 and mid.tint < 1 and !mid.reveal);
    const landing = f.sample(at.addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(200) }), 120, 32).?;
    try std.testing.expect(landing.reveal);
    try std.testing.expectEqual(@as(u16, 2), landing.prompt.y);
    try std.testing.expectEqual(null, f.sample(at.addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(Flight.duration) }), 120, 32));
    try std.testing.expectEqual(null, f.sample(at, 60, 32));
}
