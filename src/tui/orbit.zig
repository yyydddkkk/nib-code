const std = @import("std");
const vaxis = @import("vaxis");

pub const columns = 2;
pub const prefix = "   ";
pub const interval_ms = 32;
const side = 22;
const Encoder = std.base64.standard.Encoder;

pub const Cell = struct { x: u16, y: u16 };

pub const Display = struct {
    const Sample = struct { cell: Cell, frame: u64, color: u8, aspect: f32 };

    id: ?u32 = null,
    last: ?Sample = null,

    pub fn clear(d: *Display, w: *std.Io.Writer) !void {
        if (d.last == null) return;
        try w.print("\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{d.id.?});
        d.last = null;
    }

    pub fn draw(d: *Display, vx: *vaxis.Vaxis, w: *std.Io.Writer, cell: ?Cell, ms: u64, bg: ?[3]u8, refresh: bool) !void {
        const at = cell orelse return d.clear(w);
        const screen = &vx.screen;
        const aspect = if (screen.width_pix < screen.width or screen.height_pix < screen.height) 1 else @as(f32, @floatFromInt(@as(u64, columns) * screen.width_pix * screen.height)) /
            @as(f32, @floatFromInt(@as(u64, screen.height_pix) * screen.width));
        const color: u8 = if (bg) |rgb| if (isLight(rgb)) 45 else 222 else 222;
        const now: Sample = .{ .cell = at, .frame = ms / interval_ms, .color = color, .aspect = aspect };
        if (!refresh) if (d.last) |last| if (std.meta.eql(last, now)) return;
        if (d.id == null) {
            d.id = vx.next_img_id;
            vx.next_img_id += 1;
        }
        const rgba = raster(now.frame * interval_ms, aspect, color);
        var encoded: [Encoder.calcSize(rgba.len)]u8 = undefined;
        try w.print("\x1b7\x1b[{d};{d}H\x1b_Ga=T,f=32,s={d},v={d},c={d},r=1,C=1,i={d},q=2;{s}\x1b\\\x1b8", .{
            at.y + 1, at.x + 1, side, side, columns, d.id.?, Encoder.encode(&encoded, &rgba),
        });
        d.last = now;
    }
};

fn isLight(rgb: [3]u8) bool {
    return @as(u32, rgb[0]) * 2126 + @as(u32, rgb[1]) * 7152 + @as(u32, rgb[2]) * 722 >= 1_400_000;
}

const Dot = struct { x: f32, y: f32, radius: f32, alpha: f32 };
const particles = [_]struct { tilt: f32, speed: f32, phase: f32 }{
    .{ .tilt = 0.4, .speed = 1, .phase = 0 },
    .{ .tilt = 2.5, .speed = 1.25, .phase = 2.1 },
    .{ .tilt = 4.6, .speed = 0.85, .phase = 4.2 },
};

fn dotsAt(ms: u64) [4]Dot {
    var dots: [4]Dot = undefined;
    dots[0] = .{ .x = 0, .y = 0, .radius = 2.2, .alpha = 0.45 };
    const t = @as(f32, @floatFromInt(ms)) * 0.002415;
    const orbit_radius: f32 = 16.5;
    for (particles, dots[1..]) |p, *dot| {
        const angle = t * p.speed + p.phase;
        const z = @sin(angle);
        const depth = (z + 1) * 0.5;
        const x = @cos(angle) * orbit_radius;
        const y = z * orbit_radius * 0.42;
        dot.* = .{
            .x = x * @cos(p.tilt) - y * @sin(p.tilt),
            .y = x * @sin(p.tilt) + y * @cos(p.tilt),
            .radius = @max(1.7, 2.4 + z * 1.1) * 1.30,
            .alpha = 0.45 + 0.55 * depth * depth,
        };
    }
    return dots;
}

fn raster(ms: u64, aspect: f32, color: u8) [side * side * 4]u8 {
    var bytes: [side * side * 4]u8 = undefined;
    const dots = dotsAt(ms);
    const sx = @max(aspect, 1);
    const sy = @max(1 / aspect, 1);
    for (0..side) |row| for (0..side) |col| {
        const x = (@as(f32, @floatFromInt(col)) + 0.5 - side / 2) * (44.0 / side) * sx;
        const y = (@as(f32, @floatFromInt(row)) + 0.5 - side / 2) * (44.0 / side) * sy;
        var alpha: f32 = 0;
        for (dots) |dot| {
            const dx = x - dot.x;
            const dy = y - dot.y;
            const coverage = std.math.clamp((dot.radius - @sqrt(dx * dx + dy * dy)) * (@as(f32, side) / 44) + 0.5, 0, 1);
            const a = coverage * dot.alpha;
            alpha += a * (1 - alpha);
        }
        bytes[(row * side + col) * 4 ..][0..4].* = .{ color, color, color, @intFromFloat(@round(alpha * 255)) };
    };
    return bytes;
}

test "orbit particles remain visible and vary with depth" {
    const t = std.testing;
    const initial = dotsAt(0);
    try t.expectApproxEqAbs(@as(f32, 16.5 * @cos(0.4)), initial[1].x, 0.001);
    try t.expectApproxEqAbs(@as(f32, 16.5 * @sin(0.4)), initial[1].y, 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.5875), initial[1].alpha, 0.001);
    const far = dotsAt(1951)[1];
    const near = dotsAt(650)[1];
    try t.expectApproxEqAbs(@as(f32, 2.21), far.radius, 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.45), far.alpha, 0.001);
    try t.expect(dotsAt(1700)[1].alpha > far.alpha);
    try t.expectApproxEqAbs(@as(f32, 4.55), near.radius, 0.001);
    try t.expectApproxEqAbs(@as(f32, 1), near.alpha, 0.001);
    const a = raster(0, 1, 220);
    const b = raster(500, 1, 220);
    try t.expectEqual(@as(u8, 0), a[3]);
    try t.expect(a[((side / 2) * side + side / 2) * 4 + 3] > 0);
    try t.expect(!std.mem.eql(u8, &a, &b));
    try t.expect(Encoder.calcSize(a.len) <= 4096);
}
