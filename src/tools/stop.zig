const std = @import("std");
const tools = @import("../tools.zig");
const sandbox = @import("../sandbox.zig");

pub fn stop(t: *tools.Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const parsed = std.json.parseFromSlice(struct { id: []const u8, reason: ?[]const u8 = null }, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return tools.fail(gpa, "expected {{ id: string, reason: string }}", .{});
    defer parsed.deinit();
    const reason = parsed.value.reason orelse "";
    if (std.mem.trim(u8, reason, " \t\r\n").len == 0)
        return tools.fail(gpa, "stop requires a nonempty reason. Canceling a running test discards its progress and prevents a completed validation result. Elapsed time or no output alone does not mean it is stuck; {s} Stop only for a concrete failure, changed requirement or user request.", .{if (t.waitEnabled()) "await tools.wait() to wait." else "reply without tools to wait locally."});
    return stopTask(t, gpa, parsed.value.id, reason, false);
}

pub fn stopTask(t: *tools.Tools, gpa: std.mem.Allocator, id: []const u8, reason: []const u8, user: bool) !sandbox.ToolResult {
    const stopped = try t.background.stopTask(t.io, id, user);
    if (t.background.log) |log| try log.taskStop(t.io, gpa, .{ .id = id, .reason = reason, .stopped = stopped });
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .id = id, .stopped = stopped, .reason = reason, .notice = if (stopped) @as(?[]const u8, "Task canceled; unfinished validation has no passing result. Restarting repeats its work.") else null }, .{ .emit_null_optional_fields = false }) };
}

pub fn userStop(t: *tools.Tools, gpa: std.mem.Allocator, id: []const u8) ![]u8 {
    const result = stopTask(t, gpa, id, "user requested stop", true) catch |err| return std.fmt.allocPrint(gpa, "{s}: {s}", .{ id, @errorName(err) });
    defer switch (result) {
        inline else => |bytes| gpa.free(bytes),
    };
    const parsed = try std.json.parseFromSlice(struct { stopped: bool }, gpa, result.ok, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return std.fmt.allocPrint(gpa, "{s}: {s} · partial changes may remain", .{ id, if (parsed.value.stopped) "stopped by user" else "already finished" });
}
