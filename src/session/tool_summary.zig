const std = @import("std");
const Allocator = std.mem.Allocator;
const timing = @import("../sandbox/timing.zig");
const Image = @import("../image.zig").Image;

pub const File = struct {
    tool: []const u8,
    path: []const u8,
    duration_ms: ?u64 = null,
    failed: bool = false,
    pub fn jsonStringify(f: File, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("tool");
        try jw.write(f.tool);
        try jw.objectField("path");
        try jw.write(f.path);
        if (f.duration_ms) |ms| {
            try jw.objectField("duration_ms");
            try jw.write(ms);
            try jw.objectField("failed");
            try jw.write(f.failed);
        }
        try jw.endObject();
    }
};

pub const Count = struct { name: []const u8, count: u64 };

pub const Summary = struct {
    counts: []const Count = &.{},
    omitted: u64 = 0,
    failures: ?u64 = null,
    files: []const File = &.{},

    pub fn init(gpa: Allocator, calls: []const timing.Call, run_index: usize, omitted: u64) !Summary {
        var failures: u64 = 0;
        var counts: std.ArrayList(Count) = .empty;
        errdefer {
            for (counts.items) |item| gpa.free(item.name);
            counts.deinit(gpa);
        }
        for (calls) |call| {
            if (!call.dispatched or call.run_index != run_index) continue;
            failures += @intFromBool(!call.ok);
            for (counts.items) |*item| {
                if (std.mem.eql(u8, item.name, call.name)) {
                    item.count += 1;
                    break;
                }
            } else {
                const name = try gpa.dupe(u8, call.name);
                errdefer gpa.free(name);
                try counts.append(gpa, .{ .name = name, .count = 1 });
            }
        }
        var files: std.ArrayList(File) = .empty;
        errdefer {
            for (files.items) |file| {
                gpa.free(file.tool);
                gpa.free(file.path);
            }
            files.deinit(gpa);
        }
        for (calls) |call| {
            if (!call.dispatched or call.run_index != run_index) continue;
            const path = call.path orelse continue;
            for (files.items) |file| {
                if (!std.mem.eql(u8, call.name, "mcp") and std.mem.eql(u8, file.tool, call.name) and std.mem.eql(u8, file.path, path)) break;
            } else {
                const tool = try gpa.dupe(u8, call.name);
                errdefer gpa.free(tool);
                const copy = try gpa.dupe(u8, path);
                errdefer gpa.free(copy);
                try files.append(gpa, .{ .tool = tool, .path = copy, .duration_ms = if (std.mem.eql(u8, call.name, "mcp")) call.end_ms -| call.start_ms else null, .failed = std.mem.eql(u8, call.name, "mcp") and !call.ok });
            }
        }
        const owned_files = try files.toOwnedSlice(gpa);
        errdefer {
            for (owned_files) |file| {
                gpa.free(file.tool);
                gpa.free(file.path);
            }
            gpa.free(owned_files);
        }
        return .{ .counts = try counts.toOwnedSlice(gpa), .omitted = omitted, .failures = failures, .files = owned_files };
    }

    /// Appends the dimensions of each viewed image to its `view` file entry.
    pub fn annotateViews(s: Summary, gpa: Allocator, images: []const Image) !void {
        for (@constCast(s.files)) |*file| {
            if (!std.mem.eql(u8, file.tool, "view")) continue;
            for (images) |item| {
                if (!std.mem.eql(u8, item.name, file.path)) continue;
                const labeled = try std.fmt.allocPrint(gpa, "{s} · {d}×{d}", .{ file.path, item.width, item.height });
                gpa.free(file.path);
                file.path = labeled;
                break;
            }
        }
    }

    pub fn clone(s: Summary, gpa: Allocator) !Summary {
        const counts = try gpa.alloc(Count, s.counts.len);
        var copied: usize = 0;
        errdefer {
            for (counts[0..copied]) |item| gpa.free(item.name);
            gpa.free(counts);
        }
        for (s.counts, counts) |item, *copy| {
            copy.* = .{ .name = try gpa.dupe(u8, item.name), .count = item.count };
            copied += 1;
        }
        const files = try gpa.alloc(File, s.files.len);
        var copied_files: usize = 0;
        errdefer {
            for (files[0..copied_files]) |file| {
                gpa.free(file.tool);
                gpa.free(file.path);
            }
            gpa.free(files);
        }
        for (s.files, files) |file, *copy| {
            const tool = try gpa.dupe(u8, file.tool);
            errdefer gpa.free(tool);
            copy.* = .{ .tool = tool, .path = try gpa.dupe(u8, file.path), .duration_ms = file.duration_ms, .failed = file.failed };
            copied_files += 1;
        }
        return .{ .counts = counts, .omitted = s.omitted, .failures = s.failures, .files = files };
    }

    pub fn deinit(s: Summary, gpa: Allocator) void {
        for (s.counts) |item| gpa.free(item.name);
        gpa.free(s.counts);
        for (s.files) |file| {
            gpa.free(file.tool);
            gpa.free(file.path);
        }
        gpa.free(s.files);
    }
};

test "summary filters rejected llm and other Runs in first dispatch order" {
    const t = std.testing;
    var r: timing.Run = .init(t.io, .now(t.io, .awake));
    _ = r.reserve("write");
    r.run_index = 1;
    const rejected = r.reserveEntry("llm").?;
    r.entries[rejected].dispatched = false;
    _ = r.reserve("read");
    _ = r.reserve("bash");
    _ = r.reserve("read");
    const llm = r.reserve("llm").?;
    r.complete(llm, 0, 1, false);
    for (r.entries[0..r.count]) |*call| {
        if (!std.mem.eql(u8, call.name, "llm")) call.ok = true;
    }
    const summary = try Summary.init(t.allocator, r.entries[0..r.count], 1, 0);
    defer summary.deinit(t.allocator);
    try t.expectEqual(@as(?u64, 1), summary.failures);
    try t.expectEqualDeep(&[_]Count{
        .{ .name = "read", .count = 2 },
        .{ .name = "bash", .count = 1 },
        .{ .name = "llm", .count = 1 },
    }, summary.counts);
    const previous = try Summary.init(t.allocator, r.entries[0..r.count], 0, 0);
    defer previous.deinit(t.allocator);
    try t.expectEqualDeep(&[_]Count{.{ .name = "write", .count = 1 }}, previous.counts);
}

test "summary reports overflow delta even when Run has no retained calls" {
    const t = std.testing;
    var r: timing.Run = .init(t.io, .now(t.io, .awake));
    for (0..202) |_| _ = r.reserve("read");
    const first = try Summary.init(t.allocator, r.entries[0..r.count], 0, r.omitted);
    defer first.deinit(t.allocator);
    try t.expectEqualDeep(&[_]Count{.{ .name = "read", .count = 200 }}, first.counts);
    try t.expectEqual(@as(u64, 2), first.omitted);
    r.run_index = 1;
    const before = r.omitted;
    for (0..3) |_| _ = r.reserve("bash");
    const second = try Summary.init(t.allocator, r.entries[0..r.count], 1, r.omitted - before);
    defer second.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), second.counts.len);
    try t.expectEqual(@as(u64, 3), second.omitted);
}

test "summary and clone own names and counts" {
    const t = std.testing;
    var name = [_]u8{ 'r', 'e', 'a', 'd' };
    var calls = [_]timing.Call{.{ .name = &name, .start_ms = 0, .end_ms = 0, .ok = true, .run_index = 0 }};
    const summary = try Summary.init(t.allocator, &calls, 0, 7);
    defer summary.deinit(t.allocator);
    name[0] = 'x';
    const copy = try summary.clone(t.allocator);
    defer copy.deinit(t.allocator);
    try t.expectEqualStrings("read", summary.counts[0].name);
    try t.expectEqualDeep(summary, copy);
    try t.expect(summary.counts.ptr != copy.counts.ptr);
    try t.expect(summary.counts[0].name.ptr != copy.counts[0].name.ptr);
}

test "empty summary can be cloned and freed" {
    const t = std.testing;
    const summary = try Summary.init(t.allocator, &.{}, 0, 0);
    defer summary.deinit(t.allocator);
    const copy = try summary.clone(t.allocator);
    defer copy.deinit(t.allocator);
    try t.expectEqualDeep(Summary{ .failures = 0 }, copy);
    (Summary{}).deinit(t.allocator);
}

fn allocationFailures(gpa: Allocator) !void {
    const calls = [_]timing.Call{
        .{ .name = "read", .start_ms = 0, .end_ms = 0, .ok = true, .run_index = 0 },
        .{ .name = "bash", .start_ms = 0, .end_ms = 0, .ok = false, .run_index = 0 },
    };
    const summary = try Summary.init(gpa, &calls, 0, 1);
    defer summary.deinit(gpa);
    const copy = try summary.clone(gpa);
    defer copy.deinit(gpa);
}

test "summary allocation failures release counts and names" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}

test "summary owns unique dispatched file facts" {
    const a = std.testing.allocator;
    const calls = [_]timing.Call{
        .{ .name = "read", .path = "a.zig", .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 1 },
        .{ .name = "read", .path = "a.zig", .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 1 },
        .{ .name = "grep", .path = ".", .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 1 },
    };
    const summary = try Summary.init(a, &calls, 1, 0);
    defer summary.deinit(a);
    const copy = try summary.clone(a);
    defer copy.deinit(a);
    try std.testing.expectEqualDeep(&[_]File{ .{ .tool = "read", .path = "a.zig" }, .{ .tool = "grep", .path = "." } }, copy.files);
    try std.testing.expect(summary.files[0].path.ptr != copy.files[0].path.ptr);
}

test "annotateViews labels viewed images with their dimensions" {
    const t = std.testing;
    var r: timing.Run = .init(t.io, .now(t.io, .awake));
    r.detail_allocator = t.allocator;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    r.detail_allocator = arena.allocator();
    try r.describe(r.reserve("view"), "view", "{\"path\":\"shot.png\"}");
    try r.describe(r.reserve("view"), "view", "{\"path\":\"gone.png\"}");
    const summary = try Summary.init(t.allocator, r.entries[0..r.count], 0, 0);
    defer summary.deinit(t.allocator);
    try summary.annotateViews(t.allocator, &.{.{ .path = "p", .name = "shot.png", .media_type = "image/png", .bytes = 1, .width = 1280, .height = 720 }});
    try t.expectEqualStrings("shot.png · 1280×720", summary.files[0].path);
    try t.expectEqualStrings("gone.png", summary.files[1].path);
}
