const std = @import("std");

pub const Code = struct {
    tool_call_id: []const u8,
    first_ms: u64,
    last_ms: u64,
    progress: []const [2]u64,
};

pub const Attempt = struct {
    start_ms: u64,
    end_ms: u64,
    error_name: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    transport: []const u8,
    incremental: bool,
    full_reason: ?[]const u8 = null,
    fallback_reason: ?[]const u8 = null,
    fallback_at: ?i64 = null,
    fallback_detail: ?[]const u8 = null,
    bytes: u64,
    content_bytes: u64,
    first_content_ms: ?u64 = null,
    last_content_ms: ?u64 = null,
    max_content_gap_ms: ?u64 = null,
    max_gap_ms: ?u64 = null,
};

pub const Model = struct {
    io: std.Io,
    started: std.Io.Clock.Timestamp,
    slots: [65]Slot = @splat(.{}),
    used: usize = 0,
    max_gap_ms: ?u64 = null,
    last_byte_ms: ?u64 = null,
    bytes: u64 = 0,
    content_bytes: u64 = 0,
    first_content_ms: ?u64 = null,
    last_content_ms: ?u64 = null,
    max_content_gap_ms: ?u64 = null,
    attempts: [@import("retry.zig").max_attempts]Attempt = undefined,
    attempt_count: usize = 0,

    const Slot = struct {
        index: usize = 0,
        call_index: ?usize = null,
        bytes: u64 = 0,
        points: [1024][2]u64 = undefined,
        len: usize = 0,
        arrivals: u64 = 0,
        stride: u64 = 1,

        fn append(s: *Slot, ms: u64, bytes: u64) void {
            const point: [2]u64 = .{ if (s.len == 0) ms else @max(ms, s.points[s.len - 1][0]), bytes };
            if (s.len == 0) {
                s.points[0] = point;
                s.len = 1;
            } else if ((s.arrivals - 1) % s.stride != 0) {
                s.points[s.len - 1] = point;
            } else {
                if (s.len == s.points.len) {
                    for (0..s.points.len / 2) |i| s.points[i] = s.points[i * 2];
                    s.len /= 2;
                    s.stride *= 2;
                }
                s.points[s.len] = point;
                s.len += 1;
            }
            s.arrivals += 1;
        }
    };

    pub fn init(io: std.Io, started: std.Io.Clock.Timestamp) Model {
        return .{ .io = io, .started = started };
    }

    pub fn resetAttempt(m: *Model) void {
        m.used = 0;
        m.max_gap_ms = null;
        m.last_byte_ms = null;
        m.bytes = 0;
        m.content_bytes = 0;
        m.first_content_ms = null;
        m.last_content_ms = null;
        m.max_content_gap_ms = null;
    }

    pub fn received(m: *Model, bytes: usize) void {
        m.bytes += bytes;
        m.receivedAt(m.elapsed());
    }

    pub fn content(m: *Model, bytes: usize) void {
        const ms = m.elapsed();
        m.content_bytes += bytes;
        if (m.first_content_ms == null) m.first_content_ms = ms;
        if (m.last_content_ms) |last| m.max_content_gap_ms = @max(m.max_content_gap_ms orelse 0, ms -| last);
        m.last_content_ms = ms;
    }

    pub fn finishAttempt(m: *Model, a: std.mem.Allocator, start_ms: u64, err: ?anyerror, detail: ?[]const u8, state: ?*@import("codex_ws.zig").State) !void {
        const info = if (state) |s| s.last else @import("codex_ws.zig").Info{};
        m.attempts[m.attempt_count] = .{
            .start_ms = start_ms,
            .end_ms = m.elapsed(),
            .error_name = if (err) |e| @errorName(e) else null,
            .detail = if (detail) |d| try a.dupe(u8, d) else null,
            .transport = @tagName(info.transport),
            .incremental = info.incremental,
            .full_reason = info.full_reason,
            .fallback_reason = info.fallback_reason,
            .fallback_at = info.fallback_at,
            .fallback_detail = if (info.fallback_detail) |d| try a.dupe(u8, d) else null,
            .bytes = m.bytes,
            .content_bytes = m.content_bytes,
            .first_content_ms = m.first_content_ms,
            .last_content_ms = m.last_content_ms,
            .max_content_gap_ms = m.max_content_gap_ms,
            .max_gap_ms = m.max_gap_ms,
        };
        m.attempt_count += 1;
    }

    fn receivedAt(m: *Model, ms: u64) void {
        if (m.last_byte_ms) |last| m.max_gap_ms = @max(m.max_gap_ms orelse 0, ms -| last);
        m.last_byte_ms = ms;
    }

    pub fn elapsed(m: *const Model) u64 {
        return @intCast(@max(m.started.untilNow(m.io).raw.toMilliseconds(), 0));
    }

    fn slot(m: *Model, index: usize) ?*Slot {
        for (m.slots[0..m.used]) |*s| if (s.index == index) return s;
        if (m.used == m.slots.len) return null;
        const s = &m.slots[m.used];
        s.* = .{ .index = index };
        m.used += 1;
        return s;
    }

    pub fn arguments(m: *Model, index: usize, bytes: usize) void {
        if (bytes == 0) return;
        m.argumentsAt(index, bytes, m.elapsed());
    }

    fn argumentsAt(m: *Model, index: usize, bytes: usize, ms: u64) void {
        const s = m.slot(index) orelse return;
        s.bytes +|= bytes;
        s.append(ms, s.bytes);
    }

    pub fn finalArguments(m: *Model, index: usize, bytes: usize) void {
        m.finalArgumentsAt(index, bytes, m.elapsed());
    }

    fn finalArgumentsAt(m: *Model, index: usize, bytes: usize, ms: u64) void {
        const s = m.slot(index) orelse return;
        if (s.len != 0) return;
        s.bytes = bytes;
        s.append(ms, s.bytes);
    }

    pub fn bind(m: *Model, index: usize, call_index: usize) void {
        const s = m.slot(index) orelse return;
        s.call_index = call_index;
    }

    pub fn finish(m: *const Model, out: std.mem.Allocator, tool_calls: anytype) ![]const Code {
        var codes: std.ArrayList(Code) = .empty;
        errdefer {
            for (codes.items) |code| {
                out.free(code.tool_call_id);
                out.free(code.progress);
            }
            codes.deinit(out);
        }
        for (tool_calls, 0..) |call, i| {
            if (!std.mem.eql(u8, call.function.name, "run") and !std.mem.eql(u8, call.function.name, "rerun")) continue;
            for (m.slots[0..m.used]) |*s| {
                if (s.call_index != i or s.len == 0) continue;
                const id = try out.dupe(u8, call.id);
                errdefer out.free(id);
                const count = @min(s.len, 32);
                const progress = try out.alloc([2]u64, count);
                for (progress, 0..) |*point, j| {
                    const index = if (count == 1) 0 else j * (s.len - 1) / (count - 1);
                    point.* = s.points[index];
                }
                errdefer out.free(progress);
                try codes.append(out, .{
                    .tool_call_id = id,
                    .first_ms = s.points[0][0],
                    .last_ms = s.points[s.len - 1][0],
                    .progress = progress,
                });
                break;
            }
        }
        return codes.toOwnedSlice(out);
    }
};

test "argument arrival samples cap at 1024 and finish at 32 with actual endpoints" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var m: Model = .init(t.io, .now(t.io, .awake));
    for (0..1024) |i| m.argumentsAt(142, 3, i + 20);
    try t.expectEqual(@as(usize, 1024), m.slots[0].len);
    for (1024..10000) |i| {
        m.argumentsAt(142, if (i % 2 == 0) 1 else 5, i + 20);
        try t.expect(m.slots[0].len <= 1024);
    }
    const s = &m.slots[0];
    try t.expect(s.stride > 1);
    try t.expectEqual([2]u64{ 20, 3 }, s.points[0]);
    try t.expectEqual([2]u64{ 10019, 30000 }, s.points[s.len - 1]);
    for (s.points[1..s.len], s.points[0 .. s.len - 1]) |point, prev| {
        try t.expect(point[0] >= prev[0]);
        try t.expect(point[1] > prev[1]);
    }
    m.argumentsAt(142, 1, 0);
    m.bind(142, 0);
    const Call = struct { id: []const u8, function: struct { name: []const u8 } };
    const calls = [_]Call{.{ .id = "streamed", .function = .{ .name = "run" } }};
    const codes = try m.finish(arena.allocator(), &calls);
    try t.expectEqual(@as(usize, 1), codes.len);
    const code = codes[0];
    try t.expectEqual(@as(usize, 32), code.progress.len);
    try t.expectEqual(@as(u64, 20), code.first_ms);
    try t.expectEqual(@as(u64, 10019), code.last_ms);
    try t.expectEqual([2]u64{ 20, 3 }, code.progress[0]);
    try t.expectEqual([2]u64{ 10019, 30001 }, code.progress[31]);
    for (code.progress[1..], code.progress[0..31]) |point, prev| {
        try t.expect(point[0] >= prev[0]);
        try t.expect(point[1] > prev[1]);
    }
    for (code.progress, 0..) |point, i| {
        try t.expectEqual(s.points[i * (s.len - 1) / 31], point);
    }
}

test "attempt reset drops only argument slots and preserves the Step clock" {
    const t = std.testing;
    const started: std.Io.Clock.Timestamp = .now(t.io, .awake);
    var m: Model = .init(t.io, started);
    for (0..3000) |i| m.argumentsAt(100, 9, i + 10);
    m.bind(100, 1);
    m.resetAttempt();
    try t.expectEqual(@as(usize, 0), m.used);
    try t.expectEqual(started, m.started);
    m.argumentsAt(100, 2, 5000);
    const s = &m.slots[0];
    try t.expectEqual(@as(u64, 2), s.bytes);
    try t.expectEqual(@as(u64, 5000), s.points[0][0]);
    try t.expectEqual(@as(usize, 1), s.len);
    try t.expectEqual(@as(u64, 1), s.arrivals);
    try t.expectEqual(@as(u64, 1), s.stride);
    try t.expectEqual(@as(?usize, null), s.call_index);
}

test "sparse indices final-only fallback and run filtering" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var m: Model = .init(t.io, .now(t.io, .awake));
    m.argumentsAt(200, 2, 10);
    m.argumentsAt(200, 3, 20);
    m.finalArgumentsAt(200, 5, 80);
    m.bind(200, 1);
    m.finalArgumentsAt(150, 8, 30);
    m.bind(150, 0);
    m.finalArgumentsAt(201, 9, 40);
    m.bind(201, 2);
    const Call = struct { id: []const u8, function: struct { name: []const u8 } };
    const calls = [_]Call{
        .{ .id = "final", .function = .{ .name = "run" } },
        .{ .id = "streamed", .function = .{ .name = "run" } },
        .{ .id = "other", .function = .{ .name = "search" } },
    };
    const codes = try m.finish(arena.allocator(), &calls);
    try t.expectEqual(@as(usize, 2), codes.len);
    try t.expectEqualStrings("final", codes[0].tool_call_id);
    try t.expectEqual(@as(u64, 30), codes[0].first_ms);
    try t.expectEqual(@as(u64, 30), codes[0].last_ms);
    try t.expectEqualSlices([2]u64, &.{.{ 30, 8 }}, codes[0].progress);
    try t.expectEqualStrings("streamed", codes[1].tool_call_id);
    try t.expectEqualSlices([2]u64, &.{ .{ 10, 2 }, .{ 20, 5 } }, codes[1].progress);
}

test "fixed slots cover all accepted chat indices and ignore excess safely" {
    const t = std.testing;
    var m: Model = .init(t.io, .now(t.io, .awake));
    for (0..66) |i| m.argumentsAt(i + 100, 1, i);
    try t.expectEqual(@as(usize, 65), m.used);
    try t.expectEqual(@as(usize, 164), m.slots[64].index);
    m.argumentsAt(100, 1, 100);
    try t.expectEqual(@as(u64, 2), m.slots[0].bytes);
}

test "byte gaps exclude first wait and reset between attempts" {
    const t = std.testing;
    var m: Model = .init(t.io, .now(t.io, .awake));
    try t.expectEqual(@as(?u64, null), m.max_gap_ms);
    m.receivedAt(10000);
    try t.expectEqual(@as(?u64, null), m.max_gap_ms);
    m.receivedAt(10015);
    m.receivedAt(10015);
    m.receivedAt(10030);
    try t.expectEqual(@as(?u64, 15), m.max_gap_ms);
    m.receivedAt(10100);
    try t.expectEqual(@as(?u64, 70), m.max_gap_ms);
    m.resetAttempt();
    try t.expectEqual(@as(?u64, null), m.max_gap_ms);
    m.receivedAt(50000);
    m.receivedAt(50000);
    try t.expectEqual(@as(?u64, 0), m.max_gap_ms);
}
