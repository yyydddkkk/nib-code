const std = @import("std");
const tools = @import("../tools.zig");
const sandbox = @import("../sandbox.zig");

const Result = struct { id: []const u8, kind: []const u8, ok: ?bool, output: []const u8 };

pub fn wait(t: *tools.Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const requested = std.json.parseFromSliceLeaky(std.json.Value, a, args, .{}) catch return tools.fail(gpa, "expected an optional array of task ids", .{});
    const bg = &t.background;
    const inbox = bg.inbox orelse return tools.fail(gpa, "no background tasks in this Session", .{});
    var remaining: std.ArrayList([]const u8) = .empty;
    switch (requested) {
        .array => |items| for (items.items) |item| {
            if (item != .string) return tools.fail(gpa, "task ids must be strings", .{});
            try remaining.append(a, item.string);
        },
        .object => try remaining.appendSlice(a, try bg.pendingIds(a, t.io, if (t.scope()) |scope| scope.id else null)),
        else => return tools.fail(gpa, "expected an optional array of task ids", .{}),
    }
    var results: std.ArrayList(Result) = .empty;
    var not_pending: std.ArrayList([]const u8) = .empty;
    while (remaining.items.len > 0) {
        var i: usize = 0;
        while (i < remaining.items.len) {
            const id = remaining.items[i];
            if (try inbox.takeForWait(gpa, t.io, id, t.runId())) |taken| {
                defer gpa.free(taken.text);
                bg.delivered(t.io, id, taken.invocation);
                const output = if (std.mem.indexOfScalar(u8, taken.text, '\n')) |nl| taken.text[nl + 1 ..] else taken.text;
                try results.append(a, .{ .id = id, .kind = @tagName(taken.kind), .ok = taken.ok, .output = try a.dupe(u8, output) });
                _ = remaining.orderedRemove(i);
            } else if (!bg.outstanding(t.io, id)) {
                try not_pending.append(a, id);
                _ = remaining.orderedRemove(i);
            } else i += 1;
        }
        if (remaining.items.len == 0) break;
        if (t.cancelFlag().load(.acquire)) return error.Canceled;
        std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(20), .clock = .awake }, t.io) catch return error.Canceled;
    }
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .results = results.items, .not_pending = if (not_pending.items.len > 0) not_pending.items else null }, .{ .emit_null_optional_fields = false }) };
}
