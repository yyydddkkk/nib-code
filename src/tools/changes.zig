const std = @import("std");
const diff = @import("diff.zig");

pub const Tracker = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        path: []u8,
        added: usize = 0,
        removed: usize = 0,
        created: bool = false,
        preview: diff.Preview = .{},
    };

    pub fn record(t: *Tracker, gpa: std.mem.Allocator, path: []const u8, before: ?[]const u8, after: []const u8) !void {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const stat = try diff.compare(scratch.allocator(), before orelse "", after);
        if (stat.added == 0 and stat.removed == 0 and before != null) return;
        const entry = for (t.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) break entry;
        } else entry: {
            const owned_path = try gpa.dupe(u8, path);
            errdefer gpa.free(owned_path);
            try t.entries.append(gpa, .{ .path = owned_path });
            break :entry &t.entries.items[t.entries.items.len - 1];
        };
        try entry.preview.append(gpa, stat.preview);
        entry.added += stat.added;
        entry.removed += stat.removed;
        entry.created = entry.created or before == null;
    }

    pub fn recordSummary(t: *Tracker, gpa: std.mem.Allocator, change: diff.Change) !void {
        const entry = for (t.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, change.path)) break entry;
        } else entry: {
            const path = try gpa.dupe(u8, change.path);
            errdefer gpa.free(path);
            try t.entries.append(gpa, .{ .path = path });
            break :entry &t.entries.items[t.entries.items.len - 1];
        };
        var preview: diff.Preview = .{};
        defer preview.deinit(gpa);
        try preview.text.appendSlice(gpa, change.diff);
        preview.shown = std.mem.count(u8, change.diff, "\n");
        try entry.preview.append(gpa, preview);
        entry.added += change.added;
        entry.removed += change.removed;
        entry.created = entry.created or change.created;
    }

    pub fn take(t: *Tracker, gpa: std.mem.Allocator, a: std.mem.Allocator, cwd: []const u8) ![]const diff.Change {
        defer t.discard(gpa);
        const out = try a.alloc(diff.Change, t.entries.items.len);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |change| {
                a.free(change.path);
                a.free(change.diff);
            }
            a.free(out);
        }
        for (t.entries.items, out) |entry, *change| {
            const shown = if (std.mem.startsWith(u8, entry.path, cwd) and entry.path.len > cwd.len and entry.path[cwd.len] == '/') entry.path[cwd.len + 1 ..] else entry.path;
            const path = try a.dupe(u8, shown);
            errdefer a.free(path);
            change.* = .{
                .path = path,
                .added = entry.added,
                .removed = entry.removed,
                .created = entry.created,
                .diff = try entry.preview.format(a),
            };
            initialized += 1;
        }
        return out;
    }

    pub fn discard(t: *Tracker, gpa: std.mem.Allocator) void {
        for (t.entries.items) |*entry| {
            gpa.free(entry.path);
            entry.preview.deinit(gpa);
        }
        t.entries.clearAndFree(gpa);
    }
};

const testing = std.testing;

test "changes accumulate writes and reversals in first-seen path order" {
    var tracker: Tracker = .{};
    defer tracker.discard(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try tracker.record(testing.allocator, "/project/a", "old\n", "new\n");
    try tracker.record(testing.allocator, "/project/b", null, "");
    try tracker.record(testing.allocator, "/project/a", "new\n", "old\n");
    try tracker.record(testing.allocator, "/project/b", "", "created\n");
    try tracker.record(testing.allocator, "/project/noop", "same\n", "same\n");
    const changes = try tracker.take(testing.allocator, arena.allocator(), "/project");
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqualStrings("a", changes[0].path);
    try testing.expectEqual(@as(usize, 2), changes[0].added);
    try testing.expectEqual(@as(usize, 2), changes[0].removed);
    try testing.expect(!changes[0].created);
    try testing.expectEqualStrings("-old\n+new\n…\n-new\n+old\n", changes[0].diff);
    try testing.expectEqualStrings("b", changes[1].path);
    try testing.expectEqual(@as(usize, 1), changes[1].added);
    try testing.expectEqual(@as(usize, 0), changes[1].removed);
    try testing.expect(changes[1].created);
    try testing.expectEqualStrings("+created\n", changes[1].diff);
    try testing.expectEqual(@as(usize, 0), (try tracker.take(testing.allocator, arena.allocator(), "/project")).len);
}

test "diff preview stays bounded across repeated operations while totals accumulate" {
    var tracker: Tracker = .{};
    defer tracker.discard(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (0..250) |_| try tracker.record(testing.allocator, "/f", "old\n", "new\n");
    const changes = try tracker.take(testing.allocator, arena.allocator(), "/project");
    try testing.expectEqualStrings("/f", changes[0].path);
    try testing.expectEqual(@as(usize, 250), changes[0].added);
    try testing.expectEqual(@as(usize, 250), changes[0].removed);
    try testing.expectEqual(@as(usize, 100), std.mem.count(u8, changes[0].diff, "+new\n"));
    try testing.expectEqual(@as(usize, 100), std.mem.count(u8, changes[0].diff, "-old\n"));
    try testing.expect(std.mem.endsWith(u8, changes[0].diff, "… 300 more lines\n"));
}

test "diff preview combines already-truncated operations" {
    var tracker: Tracker = .{};
    defer tracker.discard(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..250) |_| try text.appendSlice(testing.allocator, "line\n");
    try tracker.record(testing.allocator, "/f", null, text.items);
    try tracker.record(testing.allocator, "/f", text.items, "");
    const changes = try tracker.take(testing.allocator, arena.allocator(), "/project");
    try testing.expectEqual(@as(usize, 250), changes[0].added);
    try testing.expectEqual(@as(usize, 250), changes[0].removed);
    try testing.expect(changes[0].created);
    try testing.expect(std.mem.endsWith(u8, changes[0].diff, "… 300 more lines\n"));
}

test "external summaries preserve binary and mode-only applied changes" {
    var tracker: Tracker = .{};
    defer tracker.discard(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try tracker.recordSummary(testing.allocator, .{ .path = "/repo/binary", .added = 0, .removed = 0, .diff = "[binary file changed]\n" });
    try tracker.recordSummary(testing.allocator, .{ .path = "/repo/mode", .added = 0, .removed = 0, .diff = "" });
    const changes = try tracker.take(testing.allocator, arena.allocator(), "/repo");
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqualStrings("binary", changes[0].path);
    try testing.expectEqualStrings("[binary file changed]\n", changes[0].diff);
    try testing.expectEqualStrings("mode", changes[1].path);
}
