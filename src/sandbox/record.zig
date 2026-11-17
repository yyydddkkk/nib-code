const std = @import("std");

pub const End = enum { ok, @"error", timeout, cancelled };

pub const Entry = struct {
    index: usize,
    seq: usize,
    name: []const u8,
    args: std.json.Value,
    ok: bool,
    result: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    sha256: []const u8 = "",
    truncated: bool = false,
    same_as: ?[]const u8 = null,
};

pub const max_result_bytes = 1024 * 1024;

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    parent: ?*Recorder = null,
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    path: []const u8,
    enabled: bool,
    warned: bool = false,
    active: bool = false,
    step: usize = 0,
    run: usize = 0,
    start_ms_epoch: i64 = 0,
    run_output_bytes: usize = 16 * 1024,
    seq: usize = 0,
    incomplete: bool = false,
    buffer: std.ArrayList(u8) = .empty,
    seen: std.AutoHashMapUnmanaged([32]u8, usize) = .empty,
    file: ?std.Io.File = null,
    offset: u64 = 0,
    loaded: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: []const u8, enabled: bool) Recorder {
        return .{ .gpa = gpa, .io = io, .path = if (enabled) gpa.dupe(u8, path) catch &.{} else &.{}, .enabled = enabled };
    }

    pub fn fork(r: *Recorder, step: usize, run: usize) !Recorder {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.enabled and !r.loaded) r.restore(step) catch r.fail();
        var child: Recorder = .{ .gpa = r.gpa, .io = r.io, .path = &.{}, .enabled = r.enabled, .loaded = true, .parent = r };
        errdefer child.deinit();
        child.begin(step, run);
        return child;
    }

    pub fn deinit(r: *Recorder) void {
        if (r.file) |file| file.close(r.io);
        r.gpa.free(r.path);
        r.buffer.deinit(r.gpa);
        r.seen.deinit(r.gpa);
    }

    fn fail(r: *Recorder) void {
        if (r.parent) |parent| {
            parent.mutex.lockUncancelable(r.io);
            defer parent.mutex.unlock(r.io);
            parent.fail();
            r.enabled = false;
            r.active = false;
            r.warned = true;
            return;
        }
        r.enabled = false;
        r.active = false;
        if (!r.warned) {
            r.warned = true;
            if (!@import("builtin").is_test) std.debug.print("warning: tool call recording disabled (cannot write calls JSONL)\n", .{});
        }
    }

    fn line(r: *Recorder, value: anytype) !void {
        const start = r.buffer.items.len;
        var out: std.Io.Writer.Allocating = .fromArrayList(r.gpa, &r.buffer);
        defer r.buffer = out.toArrayList();
        errdefer out.writer.end = start;
        std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
        out.writer.writeByte('\n') catch return error.OutOfMemory;
    }

    pub fn begin(r: *Recorder, step: usize, run: usize) void {
        if (!r.enabled) return;
        if (r.path.len == 0 and r.parent == null) return r.fail();
        if (!r.loaded) r.restore(step) catch return r.fail();
        r.buffer.clearRetainingCapacity();
        r.step = step;
        r.run = run;
        r.seq = 0;
        r.incomplete = false;
        r.start_ms_epoch = @intCast(@divFloor(std.Io.Clock.real.now(r.io).nanoseconds, std.time.ns_per_ms));
        r.active = true;
    }

    fn restore(r: *Recorder, step: usize) !void {
        r.loaded = true;
        const file = std.Io.Dir.cwd().openFile(r.io, r.path, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        r.file = file;
        try file.setPermissions(r.io, .fromMode(0o600));
        r.offset = (try file.stat(r.io)).size;
        var read_buffer: [8192]u8 = undefined;
        var reader = file.reader(r.io, &read_buffer);
        var line_buffer: std.Io.Writer.Allocating = .init(r.gpa);
        defer line_buffer.deinit();
        var offset: u64 = 0;
        var retained: u64 = 0;
        while (true) {
            line_buffer.clearRetainingCapacity();
            _ = reader.interface.streamDelimiter(&line_buffer.writer, '\n') catch |err| switch (err) {
                error.EndOfStream => {
                    if (line_buffer.written().len != 0 and retained == offset) return error.IncompleteRecording;
                    break;
                },
                else => return err,
            };
            reader.interface.toss(1);
            const start = offset;
            offset += line_buffer.written().len + 1;
            if (line_buffer.written().len == 0) continue;
            const Hash = struct { step: usize, ok: ?bool = null, sha256: ?[]const u8 = null };
            const parsed = try std.json.parseFromSlice(Hash, r.gpa, line_buffer.written(), .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (parsed.value.step >= step) continue;
            if (retained != start) {
                try file.writePositionalAll(r.io, line_buffer.written(), retained);
                try file.writePositionalAll(r.io, "\n", retained + line_buffer.written().len);
            }
            retained += line_buffer.written().len + 1;
            if (parsed.value.ok == true) if (parsed.value.sha256) |hash| {
                var key: [32]u8 = undefined;
                if (hash.len != 64) return error.InvalidRecordingHash;
                _ = try std.fmt.hexToBytes(&key, hash);
                try r.seen.put(r.gpa, key, parsed.value.step);
            };
        }
        if (retained != r.offset) {
            try file.setLength(r.io, retained);
            try file.sync(r.io);
        }
        r.offset = retained;
    }

    pub fn evalEnd(r: *Recorder, created: usize) void {
        if (!r.enabled or !r.active) return;
        r.incomplete = created != r.seq;
    }

    pub fn settle(r: *Recorder, index: usize, name: []const u8, args_json: []const u8, result: anytype) void {
        switch (result) {
            .ok => |bytes| r.capture(index, name, args_json, true, bytes),
            .err => |bytes| r.capture(index, name, args_json, false, bytes),
        }
    }

    pub fn capture(r: *Recorder, index: usize, name: []const u8, args_json: []const u8, ok: bool, bytes: []const u8) void {
        if (!r.enabled or !r.active) return;
        r.captureFallible(index, name, args_json, ok, bytes) catch r.fail();
    }

    fn captureFallible(r: *Recorder, index: usize, name: []const u8, args_json: []const u8, ok: bool, bytes: []const u8) !void {
        const args = try std.json.parseFromSlice(std.json.Value, r.gpa, args_json, .{});
        defer args.deinit();
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const duplicate = if (ok) blk: {
            if (r.parent) |parent| {
                parent.mutex.lockUncancelable(r.io);
                defer parent.mutex.unlock(r.io);
                if (parent.seen.get(digest)) |step| if (step <= r.step) break :blk true;
            }
            const entry = try r.seen.getOrPut(r.gpa, digest);
            if (!entry.found_existing) entry.value_ptr.* = r.step;
            break :blk entry.found_existing;
        } else false;
        var len = @min(bytes.len, max_result_bytes);
        if (len < bytes.len) while (len > 0 and bytes[len] & 0xc0 == 0x80) {
            len -= 1;
        };
        var reference: std.json.ObjectMap = .empty;
        defer reference.deinit(r.gpa);
        if (duplicate) try reference.put(r.gpa, "same_as", .{ .string = &hex });
        const result: ?std.json.Value = if (!ok) null else if (duplicate) .{ .object = reference } else .{ .string = bytes[0..len] };
        try r.line(.{
            .step = r.step,
            .run = r.run,
            .index = index,
            .seq = r.seq,
            .name = name,
            .args = args.value,
            .ok = ok,
            .result = result,
            .@"error" = if (!ok) bytes[0..len] else @as(?[]const u8, null),
            .sha256 = hex[0..],
            .truncated = len < bytes.len,
        });
        r.seq += 1;
    }

    pub fn finish(r: *Recorder, end: End) void {
        if (!r.enabled or !r.active) return;
        r.flush(end) catch r.fail();
        r.active = false;
        r.buffer.clearRetainingCapacity();
    }

    fn flush(r: *Recorder, end: End) !void {
        try r.line(.{ .step = r.step, .run = r.run, .meta = .{ .start_ms_epoch = r.start_ms_epoch, .run_output_bytes = r.run_output_bytes, .end = @tagName(end), .incomplete = if (r.incomplete) @as(?bool, true) else null } });
        const target = r.parent orelse r;
        target.mutex.lockUncancelable(r.io);
        defer target.mutex.unlock(r.io);
        if (!target.enabled) return error.RecordingDisabled;
        if (target.file == null) {
            const file = try std.Io.Dir.cwd().createFile(r.io, target.path, .{ .read = true, .truncate = false, .permissions = .fromMode(0o600), .lock = .exclusive, .lock_nonblocking = true });
            target.file = file;
            try file.setPermissions(r.io, .fromMode(0o600));
            target.offset = (try file.stat(r.io)).size;
        }
        try target.file.?.writePositionalAll(r.io, r.buffer.items, target.offset);
        try target.file.?.sync(r.io);
        target.offset += r.buffer.items.len;
        if (r.parent != null) {
            var keys = r.seen.keyIterator();
            while (keys.next()) |key| {
                const entry = try target.seen.getOrPut(r.gpa, key.*);
                entry.value_ptr.* = if (entry.found_existing) @min(entry.value_ptr.*, r.step) else r.step;
            }
        }
    }
};

const t = std.testing;

test "record init and disabled begin finish perform no filesystem IO" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/calls.jsonl", .{tmp.sub_path});
    defer t.allocator.free(path);
    var off = Recorder.init(t.allocator, t.io, path, false);
    defer off.deinit();
    off.begin(1, 0);
    off.capture(0, "read", "{}", true, "1");
    off.finish(.ok);
    try t.expectError(error.FileNotFound, tmp.dir.openFile(t.io, "calls.jsonl", .{}));
    var on = Recorder.init(t.allocator, t.io, path, true);
    defer on.deinit();
    on.begin(1, 0);
    on.capture(1, "read", "{}", true, "1");
    try t.expectError(error.FileNotFound, tmp.dir.openFile(t.io, "calls.jsonl", .{}));
    on.finish(.ok);
    const file = try tmp.dir.openFile(t.io, "calls.jsonl", .{});
    defer file.close(t.io);
    try t.expectEqual(@as(u32, 0o600), (try file.stat(t.io)).permissions.toMode() & 0o777);
    const data = try tmp.dir.readFileAlloc(t.io, "calls.jsonl", t.allocator, .unlimited);
    defer t.allocator.free(data);
    try t.expect(std.mem.indexOf(u8, data, "\"start_ms_epoch\":") != null);
    try t.expect(std.mem.indexOf(u8, data, "\"index\":1,\"seq\":0") != null);
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    const call = try std.json.parseFromSlice(std.json.Value, t.allocator, lines.next().?, .{});
    defer call.deinit();
    const meta = try std.json.parseFromSlice(std.json.Value, t.allocator, lines.next().?, .{});
    defer meta.deinit();
    try t.expect(call.value.object.get("type") == null);
    try t.expectEqualStrings("1", call.value.object.get("result").?.string);
    try t.expectEqual(@as(usize, 3), meta.value.object.count());
    try t.expectEqual(@as(i64, 1), meta.value.object.get("step").?.integer);
    try t.expectEqualStrings("ok", meta.value.object.get("meta").?.object.get("end").?.string);
    try t.expect(lines.next() == null);
}

test "session dedup uses complete sha256 and UTF8 truncation keeps byte boundary" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/calls.jsonl", .{tmp.sub_path});
    defer t.allocator.free(path);
    var r = Recorder.init(t.allocator, t.io, path, true);
    defer r.deinit();
    const bytes = try t.allocator.alloc(u8, max_result_bytes + 10);
    defer t.allocator.free(bytes);
    @memset(bytes, 'x');
    @memcpy(bytes[max_result_bytes - 1 ..][0..3], "中");
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    r.begin(1, 0);
    r.capture(0, "read", "{}", true, bytes);
    r.finish(.ok);
    r.begin(2, 0);
    r.capture(0, "read", "{}", true, bytes);
    r.capture(1, "bash", "{}", false, bytes);
    r.capture(2, "bash", "{}", false, bytes);
    r.finish(.@"error");
    const data = try tmp.dir.readFileAlloc(t.io, "calls.jsonl", t.allocator, .unlimited);
    defer t.allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var calls: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try t.expect(obj.get("type") == null);
        if (obj.get("meta") != null) continue;
        try t.expectEqualStrings(&hex, obj.get("sha256").?.string);
        try t.expect(obj.get("truncated").?.bool);
        if (calls == 1) {
            try t.expectEqualStrings(&hex, obj.get("result").?.object.get("same_as").?.string);
            try t.expect(obj.get("same_as") == null);
        } else {
            const value = obj.get(if (calls == 0) "result" else "error").?.string;
            try t.expectEqual(max_result_bytes - 1, value.len);
            try t.expect(std.unicode.utf8ValidateSlice(value));
            try t.expect(obj.get("same_as") == null);
        }
        calls += 1;
    }
    try t.expectEqual(@as(usize, 4), calls);
}

test "restored recorder deduplicates earlier session bytes without init IO" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/calls.jsonl", .{tmp.sub_path});
    defer t.allocator.free(path);
    {
        var r = Recorder.init(t.allocator, t.io, path, true);
        defer r.deinit();
        r.begin(1, 0);
        r.capture(0, "read", "{}", true, "{\"value\":7}");
        r.capture(1, "bash", "{}", false, "7");
        r.finish(.ok);
    }
    var resumed = Recorder.init(t.allocator, t.io, path, true);
    defer resumed.deinit();
    try t.expect(!resumed.loaded and resumed.file == null);
    resumed.begin(3, 0);
    resumed.capture(0, "read", "{}", true, "{\"value\":7}");
    try t.expect(std.mem.indexOf(u8, resumed.buffer.items, "\"same_as\":") != null);
    try t.expect(std.mem.indexOf(u8, resumed.buffer.items, "\"result\":") != null);
    resumed.capture(1, "read", "{}", true, "7");
    resumed.finish(.ok);
    const data = try tmp.dir.readFileAlloc(t.io, "calls.jsonl", t.allocator, .unlimited);
    defer t.allocator.free(data);
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, line, .{});
        defer parsed.deinit();
        const row = parsed.value.object;
        if (row.get("meta") != null) continue;
        const result = row.get("result");
        if (count == 2) {
            try t.expect(result.? == .object);
        } else if (count == 3) {
            try t.expectEqualStrings("7", result.?.string);
        }
        count += 1;
    }
    try t.expectEqual(@as(usize, 4), count);
    var again = Recorder.init(t.allocator, t.io, path, true);
    defer again.deinit();
    resumed.file.?.close(t.io);
    resumed.file = null;
    again.begin(5, 0);
    again.capture(0, "read", "{}", true, "{\"value\":7}");
    try t.expect(again.enabled);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, std.mem.trim(u8, again.buffer.items, "\n"), .{});
    defer parsed.deinit();
    try t.expect(parsed.value.object.get("result").? == .object);
    again.finish(.ok);
}

test "recording IO or allocation failures disable once and remain nonfatal" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/missing/calls.jsonl", .{tmp.sub_path});
    defer t.allocator.free(path);
    var r = Recorder.init(t.allocator, t.io, path, true);
    defer r.deinit();
    r.begin(1, 0);
    r.capture(0, "read", "{}", true, "1");
    r.finish(.ok);
    try t.expect(r.warned and !r.enabled);
    const seq = r.seq;
    r.begin(2, 0);
    r.capture(0, "read", "{}", true, "2");
    r.finish(.ok);
    try t.expect(r.warned and !r.enabled and r.seq == seq);
    var failing = std.testing.FailingAllocator.init(t.allocator, .{});
    var memory = Recorder.init(failing.allocator(), t.io, path, true);
    defer memory.deinit();
    memory.begin(1, 0);
    failing.fail_index = failing.alloc_index;
    memory.capture(0, "read", "{}", true, "1");
    try t.expect(memory.warned and !memory.enabled);
    memory.finish(.ok);
}

test "restore removes uncommitted Steps and rebuilds only retained hashes once" {
    for ([_]bool{ false, true }) |orphan_calls| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/calls.jsonl", .{tmp.sub_path});
        defer t.allocator.free(path);
        var old = Recorder.init(t.allocator, t.io, path, true);
        defer old.deinit();
        old.begin(1, 0);
        old.capture(0, "read", "{}", true, "1");
        old.finish(.ok);
        const retained = old.offset;
        old.begin(2, 0);
        if (orphan_calls) old.capture(0, "read", "{}", true, "2");
        old.finish(.ok);
        old.begin(2, 1);
        old.capture(0, "read", "{}", true, "2");
        old.finish(.ok);
        old.begin(3, 0);
        old.finish(.ok);
        try old.file.?.writePositionalAll(t.io, "{\"step\":3", old.offset);
        old.file.?.close(t.io);
        old.file = null;

        var resumed = Recorder.init(t.allocator, t.io, path, true);
        defer resumed.deinit();
        resumed.begin(2, 0);
        try t.expect(resumed.enabled);
        try t.expectEqual(retained, resumed.offset);
        try t.expectEqual(retained, (try resumed.file.?.stat(t.io)).size);
        try t.expectEqual(@as(usize, 1), resumed.seen.count());
        resumed.capture(0, "read", "{}", true, "1");
        resumed.capture(1, "read", "{}", true, "2");
        var lines = std.mem.tokenizeScalar(u8, resumed.buffer.items, '\n');
        const alias = try std.json.parseFromSlice(std.json.Value, t.allocator, lines.next().?, .{});
        defer alias.deinit();
        try t.expect(alias.value.object.get("result").? == .object);
        const full = try std.json.parseFromSlice(std.json.Value, t.allocator, lines.next().?, .{});
        defer full.deinit();
        try t.expectEqualStrings("2", full.value.object.get("result").?.string);
        resumed.finish(.ok);
        const first_run = resumed.offset;
        resumed.begin(2, 1);
        try t.expectEqual(first_run, resumed.offset);
        resumed.finish(.ok);
        const data = try tmp.dir.readFileAlloc(t.io, "calls.jsonl", t.allocator, .unlimited);
        defer t.allocator.free(data);
        var rows = std.mem.tokenizeScalar(u8, data, '\n');
        var metas: usize = 0;
        while (rows.next()) |row| {
            const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, row, .{});
            defer parsed.deinit();
            try t.expect(parsed.value.object.get("step").?.integer <= 2);
            if (parsed.value.object.contains("meta")) metas += 1;
        }
        try t.expectEqual(@as(usize, 3), metas);
        try t.expectEqual(@as(u32, 0o600), (try resumed.file.?.stat(t.io)).permissions.toMode() & 0o777);
    }
}

test "eval end counts creations including missing highest index and is allocation free" {
    var failing = std.testing.FailingAllocator.init(t.allocator, .{});
    var r = Recorder.init(failing.allocator(), t.io, "unused-record-test-path", true);
    defer r.deinit();
    r.begin(1, 0);
    r.capture(0, "read", "{}", true, "1");
    failing.fail_index = failing.alloc_index;
    r.evalEnd(2);
    try t.expect(r.enabled and r.incomplete);
    @memset(r.buffer.unusedCapacitySlice(), ' ');
    r.buffer.items.len = r.buffer.capacity;
    failing.resize_fail_index = failing.resize_index;
    r.finish(.@"error");
    try t.expect(r.warned and !r.enabled);
    r.evalEnd(2);
    r.finish(.@"error");
}

test "concurrent Run recorders flush in completion order and restore retains earlier Steps" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/calls.jsonl", .{tmp.sub_path});
    defer t.allocator.free(path);
    var root = Recorder.init(t.allocator, t.io, path, true);
    defer root.deinit();
    var first = try root.fork(1, 0);
    defer first.deinit();
    var orphan = try root.fork(3, 0);
    defer orphan.deinit();
    orphan.capture(0, "read", "{}", true, "same");
    orphan.finish(.ok);
    first.capture(0, "read", "{}", true, "same");
    first.finish(.ok);
    root.file.?.close(t.io);
    root.file = null;
    var restored = Recorder.init(t.allocator, t.io, path, true);
    defer restored.deinit();
    var next = try restored.fork(2, 0);
    defer next.deinit();
    next.capture(0, "read", "{}", true, "same");
    next.finish(.ok);
    const bytes = try tmp.dir.readFileAlloc(t.io, "calls.jsonl", t.allocator, .unlimited);
    defer t.allocator.free(bytes);
    try t.expect(std.mem.indexOf(u8, bytes, "\"step\":3") == null);
    try t.expect(std.mem.indexOf(u8, bytes, "\"step\":1") != null);
    try t.expect(std.mem.indexOf(u8, bytes, "\"same_as\":") != null);
}

test "direct recording lines match valueAlloc bytes including optional fields and escaping" {
    var r: Recorder = .{ .gpa = t.allocator, .io = t.io, .path = &.{}, .enabled = true };
    defer r.deinit();
    inline for (.{
        .{ .result = "\"quoted\"\n\t\\中", .@"error" = @as(?[]const u8, null), .truncated = false },
        .{ .result = @as(?[]const u8, null), .@"error" = "denied\x00\r", .truncated = true },
        .{ .result = .{ .same_as = "0123456789abcdef" }, .args = .{ .path = "a\nb", .limit = 12 } },
        .{ .step = 7, .run = 2, .meta = .{ .end = "cancelled", .incomplete = @as(?bool, true) } },
    }) |value| {
        const expected = try std.json.Stringify.valueAlloc(t.allocator, value, .{ .emit_null_optional_fields = false });
        defer t.allocator.free(expected);
        const start = r.buffer.items.len;
        try r.line(value);
        try t.expectEqualStrings(expected, r.buffer.items[start .. r.buffer.items.len - 1]);
        try t.expectEqual('\n', r.buffer.items[r.buffer.items.len - 1]);
    }
}

fn lineAllocationFailures(gpa: std.mem.Allocator) !void {
    var r: Recorder = .{ .gpa = gpa, .io = t.io, .path = &.{}, .enabled = true };
    defer r.deinit();
    try r.line(.{ .prefix = true });
    r.line(.{ .result = &@as([4096]u8, @splat('\n')) }) catch |err| {
        try t.expectEqualStrings("{\"prefix\":true}\n", r.buffer.items);
        return err;
    };
    try t.expect(std.mem.endsWith(u8, r.buffer.items, "\"}\n"));
}

test "line allocation failures preserve earlier records and buffer ownership" {
    try t.checkAllAllocationFailures(t.allocator, lineAllocationFailures, .{});
}

test "line encoding and newline failures roll back even after growth" {
    const Broken = struct {
        pub fn jsonStringify(_: @This(), jw: *std.json.Stringify) !void {
            try jw.write(&@as([4096]u8, @splat('x')));
            return error.WriteFailed;
        }
    };
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var r: Recorder = .{ .gpa = failing.allocator(), .io = t.io, .path = &.{}, .enabled = true };
    defer r.deinit();
    try r.line(.{ .prefix = true });
    try t.expectError(error.OutOfMemory, r.line(Broken{}));
    try t.expectEqualStrings("{\"prefix\":true}\n", r.buffer.items);
    const start = r.buffer.items.len;
    const room = r.buffer.capacity - start;
    const exact = try t.allocator.alloc(u8, room - 2);
    defer t.allocator.free(exact);
    @memset(exact, 'x');
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try t.expectError(error.OutOfMemory, r.line(exact));
    try t.expectEqualStrings("{\"prefix\":true}\n", r.buffer.items);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try r.line(.{ .after = true });
    try t.expectEqualStrings("{\"prefix\":true}\n{\"after\":true}\n", r.buffer.items);
}

test "capture encoding failure disables child and parent without committing partial record" {
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var root: Recorder = .{ .gpa = failing.allocator(), .io = t.io, .path = &.{}, .enabled = true, .loaded = true };
    defer root.deinit();
    var child = try root.fork(1, 0);
    defer child.deinit();
    child.capture(0, "read", "{}", true, "1");
    const prefix = try t.allocator.dupe(u8, child.buffer.items);
    defer t.allocator.free(prefix);
    // Parsing arguments must succeed before the writer's next growth fails.
    failing.resize_fail_index = failing.resize_index;
    failing.fail_index = failing.alloc_index + 1;
    child.capture(1, "bash", "{}", false, &@as([4096]u8, @splat('\n')));
    try t.expect(!child.enabled and !child.active and child.warned);
    try t.expect(!root.enabled and root.warned);
    try t.expectEqual(@as(usize, 1), child.seq);
    try t.expectEqualStrings(prefix, child.buffer.items);
    child.finish(.@"error");
    child.capture(2, "read", "{}", true, "2");
    try t.expectEqualStrings(prefix, child.buffer.items);
    try t.expect(root.file == null);
}

test "disabled recorder does not allocate parse hash or copy results" {
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var r = Recorder.init(failing.allocator(), t.io, "unused", false);
    defer r.deinit();
    r.begin(1, 0);
    r.capture(0, "read", "not JSON", true, &@as([4096]u8, @splat('x')));
    r.evalEnd(1);
    r.finish(.ok);
    try t.expectEqual(@as(usize, 0), failing.allocations);
    try t.expectEqual(@as(usize, 0), r.buffer.items.len);
    try t.expectEqual(@as(usize, 0), r.seq);
    try t.expect(!r.warned);
}
