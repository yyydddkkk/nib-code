const std = @import("std");

pub const Frames = struct {
    pub const interval_ms: i64 = 16;
    pub const animation_ms: i64 = 100;
    pub const Refresh = enum { content, animation, immediate };

    activity_interval_ms: i64 = animation_ms,
    pending: bool = false,
    last: ?std.Io.Clock.Timestamp = null,

    pub fn due(f: *Frames, now: std.Io.Clock.Timestamp, refresh: Refresh) bool {
        if (refresh != .animation) f.pending = true;
        if (refresh == .immediate) return true;
        const last = f.last orelse return true;
        const elapsed = last.durationTo(now).raw.toMilliseconds();
        return elapsed >= if (f.pending) interval_ms else f.activity_interval_ms;
    }

    pub fn painted(f: *Frames, now: std.Io.Clock.Timestamp) void {
        f.last = now;
        f.pending = false;
    }
};

fn at(ms: i64) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(std.testing.io, .awake).addDuration(.{ .raw = .fromMilliseconds(ms), .clock = .awake });
}

test "stream bursts coalesce without starving continuous output" {
    const t = std.testing;
    var f: Frames = .{};
    const start = at(0);
    try t.expect(f.due(start, .content));
    f.painted(start);
    var paints: usize = 0;
    for (1..1001) |ms| {
        const now = start.addDuration(.{ .raw = .fromMilliseconds(@intCast(ms)), .clock = .awake });
        for (0..10) |_| {
            if (f.due(now, .content)) {
                paints += 1;
                f.painted(now);
            }
        }
    }
    try t.expectEqual(@as(usize, 62), paints);
    try t.expect(f.pending);
}

test "a tick flushes the last fragment even if no more model events arrive" {
    const t = std.testing;
    var f: Frames = .{};
    const start = at(0);
    f.painted(start);
    const early = start.addDuration(.{ .raw = .fromMilliseconds(1), .clock = .awake });
    try t.expect(!f.due(early, .content));
    try t.expect(f.pending);
    const next = start.addDuration(.{ .raw = .fromMilliseconds(16), .clock = .awake });
    try t.expect(f.due(next, .animation));
    f.painted(next);
    try t.expect(!f.pending);
}

test "input and terminal events bypass pacing; quiet activity stays at ten fps" {
    const t = std.testing;
    var f: Frames = .{};
    const start = at(0);
    f.painted(start);
    const early = start.addDuration(.{ .raw = .fromMilliseconds(1), .clock = .awake });
    try t.expect(!f.due(early, .animation));
    try t.expect(f.due(early, .immediate));
    f.painted(early);
    const before = early.addDuration(.{ .raw = .fromMilliseconds(99), .clock = .awake });
    try t.expect(!f.due(before, .animation));
    const next = early.addDuration(.{ .raw = .fromMilliseconds(100), .clock = .awake });
    try t.expect(f.due(next, .animation));
    f.painted(next);
    try t.expect(f.due(next, .immediate));
}
