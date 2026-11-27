const std = @import("std");
const vaxis = @import("vaxis");
const File = @import("../../session/tool_summary.zig").File;

pub const object: vaxis.Style = .{ .fg = .{ .index = 6 } };
const dim: vaxis.Style = .{ .dim = true };

pub fn appendTools(a: std.mem.Allocator, parts: *std.ArrayList(vaxis.Segment), text: []const u8) !void {
    if (text.len == 0) return;
    var fields = std.mem.splitSequence(u8, text, " · ");
    while (fields.next()) |field| {
        if (field.len > 0 and field[0] != '+') {
            const end = std.mem.indexOfScalar(u8, field, ' ') orelse field.len;
            try parts.append(a, .{ .text = field[0..end], .style = object });
            if (end < field.len) try parts.append(a, .{ .text = field[end..], .style = dim });
        } else if (field.len > 0) try parts.append(a, .{ .text = field, .style = dim });
        if (fields.peek() != null) try parts.append(a, .{ .text = " · ", .style = dim });
    }
}

pub fn appendFile(a: std.mem.Allocator, parts: *std.ArrayList(vaxis.Segment), file: File) !void {
    try parts.append(a, .{ .text = file.tool, .style = object });
    try parts.append(a, .{ .text = " " });
    const detail = if (std.mem.eql(u8, file.tool, "view")) std.mem.lastIndexOf(u8, file.path, " · ") orelse file.path.len else file.path.len;
    const path = file.path[0..detail];
    const leaf = if (file.duration_ms != null) 0 else if (std.mem.lastIndexOfAny(u8, path, "/\\")) |at| at + 1 else 0;
    if (leaf > 0) try parts.append(a, .{ .text = path[0..leaf], .style = dim });
    try parts.append(a, .{ .text = path[leaf..], .style = object });
    if (detail < file.path.len) try parts.append(a, .{ .text = file.path[detail..], .style = dim });
}
const ToolSummary = @import("../../session/tool_summary.zig").Summary;

pub fn actualToolSummary(summary: ToolSummary, changed_files: usize, buf: []u8) []const u8 {
    if (summary.counts.len == 0 and summary.omitted == 0) return "";
    var w: std.Io.Writer = .fixed(buf);
    var changed_shown = false;
    calls: for (summary.counts) |call| {
        for (summary.files) |file| {
            if (std.mem.eql(u8, call.name, file.tool)) continue :calls;
        }
        const changed = changed_files > 0 and (std.mem.eql(u8, call.name, "edit") or std.mem.eql(u8, call.name, "write"));
        if (changed and changed_shown) continue;
        if (w.end > 0) w.writeAll(" · ") catch break;
        if (changed) {
            w.print("edit {d} file{s}", .{ changed_files, if (changed_files == 1) "" else "s" }) catch break;
            changed_shown = true;
        } else {
            w.writeAll(call.name) catch break;
            if (call.count > 1) w.print(" ×{d}", .{call.count}) catch break;
        }
    }
    if (summary.omitted > 0) {
        if (w.end > 0) w.writeAll(" · ") catch {};
        w.print("+{d}", .{summary.omitted}) catch {};
    }
    return w.buffered();
}

pub fn promptPrefix(prompt: []const u8) []const u8 {
    var end: usize = 0;
    var count: usize = 0;
    while (end < prompt.len and count < 40) : (count += 1) {
        const len = std.unicode.utf8ByteSequenceLength(prompt[end]) catch 1;
        end = @min(prompt.len, end + len);
    }
    return prompt[0..end];
}

test "path facts replace generic tools without losing fallback or omitted counts" {
    var buf: [128]u8 = undefined;
    const counts = [_]@import("../../session/tool_summary.zig").Count{
        .{ .name = "read", .count = 2 },
        .{ .name = "grep", .count = 1 },
    };
    try std.testing.expectEqualStrings("+3", actualToolSummary(.{
        .counts = &counts,
        .files = &.{ .{ .tool = "read", .path = "sample.txt" }, .{ .tool = "grep", .path = "." } },
        .omitted = 3,
    }, 0, &buf));
    try std.testing.expectEqualStrings("read ×2 · grep", actualToolSummary(.{ .counts = &counts }, 0, &buf));
}
