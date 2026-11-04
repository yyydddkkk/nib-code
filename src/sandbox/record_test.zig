const std = @import("std");
const record = @import("record.zig");
const testing = std.testing;

fn recordingPath(a: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/session.calls.jsonl", .{sub_path});
}

fn entries(a: std.mem.Allocator, bytes: []const u8) ![]const record.Entry {
    var result: std.ArrayList(record.Entry) = .empty;
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| try result.append(a, try std.json.parseFromSliceLeaky(record.Entry, a, line, .{}));
    return result.items;
}

test "recording deduplicates results across Runs and preserves rejected calls" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try recordingPath(a, &tmp.sub_path);
    var recorder: record.Recorder = .{ .gpa = a, .io = testing.io, .path = path };
    defer recorder.deinit();
    const text = try a.dupe(u8, "complete result");
    var first = recorder.begin(1, 0);
    first.capture(2, "read", "{\"path\":\"a\"}", .{ .ok = text });
    first.capture(0, "bash", "{}", .{ .err = try a.dupe(u8, "rejected call") });
    first.finish(.@"error");
    var second = recorder.begin(2, 1);
    second.capture(0, "read", "{\"path\":\"b\"}", .{ .ok = text });
    second.finish(.ok);
    try testing.expect(!recorder.failed);
    try testing.expectEqualStrings("complete result", text);
    const bytes = try tmp.dir.readFileAlloc(testing.io, "session.calls.jsonl", a, .limited(4096));
    const rows = try entries(a, bytes);
    try testing.expectEqual(@as(usize, 5), rows.len);
    try testing.expectEqualStrings(text, rows[0].result.?.string);
    try testing.expectEqual(@as(?usize, 2), rows[0].index);
    try testing.expectEqual(@as(?usize, 0), rows[0].seq);
    try testing.expectEqualStrings("a", rows[0].args.?.object.get("path").?.string);
    try testing.expectEqual(@as(?bool, false), rows[1].ok);
    try testing.expectEqualStrings("rejected call", rows[1].@"error".?);
    try testing.expect(rows[1].result == null);
    try testing.expectEqual(@as(?usize, 1), rows[1].seq);
    try testing.expectEqual(record.End.@"error", rows[2].meta.?.end);
    try testing.expectEqual(@as(usize, 2), rows[3].step);
    try testing.expectEqual(@as(usize, 1), rows[3].run);
    const sha = record.sha256(text);
    try testing.expectEqualStrings(&sha, rows[3].result.?.object.get("same_as").?.string);
    try testing.expectEqual(record.End.ok, rows[4].meta.?.end);
}

test "recording hashes the full result and truncates on a UTF-8 boundary" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var recorder: record.Recorder = .{ .gpa = a, .io = testing.io, .path = try recordingPath(a, &tmp.sub_path) };
    defer recorder.deinit();
    const text = try a.alloc(u8, record.max_result_bytes + 2);
    @memset(text[0 .. record.max_result_bytes - 1], 'a');
    @memcpy(text[record.max_result_bytes - 1 ..], "中");
    var run = recorder.begin(1, 0);
    run.capture(0, "read", "{}", .{ .ok = text });
    run.finish(.ok);
    try testing.expect(!recorder.failed);
    const bytes = try tmp.dir.readFileAlloc(testing.io, "session.calls.jsonl", a, .limited(2 * record.max_result_bytes));
    const rows = try entries(a, bytes);
    const result = rows[0].result.?.object;
    const content = result.get("content").?.string;
    try testing.expect(result.get("truncated").?.bool);
    try testing.expectEqual(record.max_result_bytes - 1, content.len);
    try testing.expect(std.unicode.utf8ValidateSlice(content));
    try testing.expectEqualStrings(text[0..content.len], content);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const full_sha = std.fmt.bytesToHex(digest, .lower);
    const prefix_sha = record.sha256(content);
    try testing.expectEqualStrings(&full_sha, result.get("sha").?.string);
    try testing.expect(!std.mem.eql(u8, &full_sha, &prefix_sha));
}

test "recording reloads only persisted hashes and deduplicates after resume" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try recordingPath(a, &tmp.sub_path);
    const text = try a.dupe(u8, "private tool result");
    {
        var recorder: record.Recorder = .{ .gpa = a, .io = testing.io, .path = path };
        defer recorder.deinit();
        recorder.loadHashes();
        try testing.expect(!recorder.failed);
        var run = recorder.begin(1, 0);
        run.capture(0, "read", "{}", .{ .ok = text });
        run.capture(1, "read", "{}", .{ .ok = text });
        try testing.expectError(error.FileNotFound, tmp.dir.openFile(testing.io, "session.calls.sha256", .{}));
        run.finish(.ok);
    }
    const sha = record.sha256(text);
    const hashes = try tmp.dir.readFileAlloc(testing.io, "session.calls.sha256", a, .limited(1024));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}\n", .{sha}), hashes);
    try tmp.dir.rename("session.calls.jsonl", tmp.dir, "private.calls.jsonl", testing.io);
    var resumed: record.Recorder = .{ .gpa = a, .io = testing.io, .path = path };
    defer resumed.deinit();
    resumed.loadHashes();
    try testing.expect(!resumed.failed);
    try testing.expectEqual(@as(usize, 1), resumed.seen.count());
    try tmp.dir.rename("private.calls.jsonl", tmp.dir, "session.calls.jsonl", testing.io);
    var next = resumed.begin(2, 0);
    next.capture(0, "read", "{}", .{ .ok = text });
    next.finish(.ok);
    const bytes = try tmp.dir.readFileAlloc(testing.io, "session.calls.jsonl", a, .limited(4096));
    const rows = try entries(a, bytes);
    try testing.expectEqualStrings(&sha, rows[3].result.?.object.get("same_as").?.string);
    const after = try tmp.dir.readFileAlloc(testing.io, "session.calls.sha256", a, .limited(1024));
    try testing.expectEqualStrings(hashes, after);
}

test "disabled recording neither buffers calls nor creates a file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var recorder: record.Recorder = .{ .gpa = testing.allocator, .io = testing.io };
    defer recorder.deinit();
    recorder.loadHashes();
    const text = try testing.allocator.dupe(u8, "borrowed tool result");
    defer testing.allocator.free(text);
    var run = recorder.begin(1, 0);
    run.capture(0, "read", "{}", .{ .ok = text });
    try testing.expectEqual(@as(usize, 0), run.bytes.items.len);
    run.finish(.ok);
    try testing.expect(!recorder.failed);
    try testing.expectEqualStrings("borrowed tool result", text);
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(testing.io, "session.calls.jsonl", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(testing.io, "session.calls.sha256", .{}));
}

test "recording failures disable subsequent recording without changing tool results" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try recordingPath(a, &tmp.sub_path);
    const text = try a.dupe(u8, "tool still succeeded");
    var recorder: record.Recorder = .{ .gpa = a, .io = testing.io, .path = path };
    defer recorder.deinit();
    var broken = recorder.begin(1, 0);
    broken.capture(0, "read", "invalid json", .{ .ok = text });
    try testing.expect(recorder.failed);
    broken.finish(.ok);
    var next = recorder.begin(2, 0);
    next.capture(0, "read", "{}", .{ .ok = text });
    try testing.expectEqual(@as(usize, 0), next.bytes.items.len);
    next.finish(.ok);
    try testing.expectEqualStrings("tool still succeeded", text);
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(testing.io, "session.calls.jsonl", .{}));

    var unwritable: record.Recorder = .{ .gpa = a, .io = testing.io, .path = try std.fmt.allocPrint(a, "{s}/missing/file", .{path}) };
    defer unwritable.deinit();
    var failed_flush = unwritable.begin(1, 0);
    failed_flush.capture(0, "read", "{}", .{ .ok = text });
    failed_flush.finish(.ok);
    try testing.expect(unwritable.failed);
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(testing.io, "session.calls.sha256", .{}));
    try testing.expectEqualStrings("tool still succeeded", text);
}

test "invalid hash indexes disable recording" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try recordingPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "session.calls.sha256", .data = "not a result digest\n" });
    var recorder: record.Recorder = .{ .gpa = testing.allocator, .io = testing.io, .path = path };
    defer recorder.deinit();
    recorder.loadHashes();
    try testing.expect(recorder.failed);
}
