const std = @import("std");
const sandbox = @import("../sandbox.zig");

pub const max_result_bytes = 1024 * 1024;
pub const End = enum { ok, @"error", timeout, cancelled };
pub const Meta = struct { start_ms_epoch: i64, end: End };
pub const Entry = struct {
    step: usize,
    run: usize,
    index: ?usize = null,
    seq: ?usize = null,
    name: ?[]const u8 = null,
    args: ?std.json.Value = null,
    ok: ?bool = null,
    result: ?std.json.Value = null,
    @"error": ?[]const u8 = null,
    meta: ?Meta = null,
};

pub fn sha256(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: ?[]const u8 = null,
    seen: std.AutoHashMapUnmanaged([64]u8, void) = .empty,
    failed: bool = false,

    pub fn deinit(r: *Recorder) void {
        r.seen.deinit(r.gpa);
    }

    pub fn loadHashes(r: *Recorder) void {
        if (r.path == null or r.failed) return;
        r.loadIndex() catch |err| r.fail(err);
    }

    fn hashPath(r: *Recorder) ![]u8 {
        return std.fmt.allocPrint(r.gpa, "{s}.sha256", .{r.path.?[0 .. r.path.?.len - ".jsonl".len]});
    }

    fn loadIndex(r: *Recorder) !void {
        const path = try r.hashPath();
        defer r.gpa.free(path);
        const file = std.Io.Dir.cwd().openFile(r.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(r.io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(r.io, &buffer);
        while (true) {
            var line: [65]u8 = undefined;
            const count = try reader.interface.readSliceShort(&line);
            if (count == 0) break;
            if (count != line.len or line[64] != '\n') return error.InvalidRecordingHash;
            for (line[0..64]) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return error.InvalidRecordingHash;
            try r.seen.put(r.gpa, line[0..64].*, {});
        }
    }

    fn fail(r: *Recorder, err: anyerror) void {
        if (!r.failed) std.debug.print("nib: tool recording disabled: {s}\n", .{@errorName(err)});
        r.failed = true;
    }

    pub fn begin(r: *Recorder, step: usize, run: usize) Run {
        return .{ .recorder = r, .step = step, .run = run, .start_ms_epoch = @intCast(@divFloor(std.Io.Clock.real.now(r.io).nanoseconds, std.time.ns_per_ms)) };
    }
};

pub const Run = struct {
    recorder: *Recorder,
    step: usize,
    run: usize,
    start_ms_epoch: i64,
    seq: usize = 0,
    bytes: std.ArrayList(u8) = .empty,
    hashes: std.ArrayList(u8) = .empty,

    pub fn capture(r: *Run, index: usize, name: []const u8, args: []const u8, result: sandbox.ToolResult) void {
        if (r.recorder.path == null or r.recorder.failed) return;
        r.append(index, name, args, result) catch |err| r.recorder.fail(err);
    }

    fn append(r: *Run, index: usize, name: []const u8, args: []const u8, result: sandbox.ToolResult) !void {
        const a = r.recorder.gpa;
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const tmp = arena.allocator();
        var entry: Entry = .{ .step = r.step, .run = r.run, .index = index, .seq = r.seq, .name = name, .args = try std.json.parseFromSliceLeaky(std.json.Value, tmp, args, .{}), .ok = result == .ok };
        switch (result) {
            .err => |message| entry.@"error" = message,
            .ok => |text| {
                const sha = sha256(text);
                const found = try r.recorder.seen.getOrPut(a, sha);
                if (!found.found_existing) try r.hashes.print(a, "{s}\n", .{sha});
                if (found.found_existing) {
                    var object: std.json.ObjectMap = .{};
                    try object.put(tmp, "same_as", .{ .string = &sha });
                    entry.result = .{ .object = object };
                } else if (text.len > max_result_bytes) {
                    var end: usize = max_result_bytes;
                    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
                    var object: std.json.ObjectMap = .{};
                    try object.put(tmp, "sha", .{ .string = &sha });
                    try object.put(tmp, "content", .{ .string = text[0..end] });
                    try object.put(tmp, "truncated", .{ .bool = true });
                    entry.result = .{ .object = object };
                } else entry.result = .{ .string = text };
                try r.bytes.print(a, "{f}\n", .{std.json.fmt(entry, .{ .emit_null_optional_fields = false })});
                r.seq += 1;
                return;
            },
        }
        try r.bytes.print(a, "{f}\n", .{std.json.fmt(entry, .{ .emit_null_optional_fields = false })});
        r.seq += 1;
    }

    pub fn finish(r: *Run, end: End) void {
        defer r.bytes.deinit(r.recorder.gpa);
        defer r.hashes.deinit(r.recorder.gpa);
        if (r.recorder.path == null or r.recorder.failed) return;
        r.flush(end) catch |err| r.recorder.fail(err);
    }

    fn flush(r: *Run, end: End) !void {
        try r.bytes.print(r.recorder.gpa, "{f}\n", .{std.json.fmt(Entry{ .step = r.step, .run = r.run, .meta = .{ .start_ms_epoch = r.start_ms_epoch, .end = end } }, .{ .emit_null_optional_fields = false })});
        const file = try std.Io.Dir.cwd().createFile(r.recorder.io, r.recorder.path.?, .{ .truncate = false, .permissions = .fromMode(0o600) });
        defer file.close(r.recorder.io);
        try file.setPermissions(r.recorder.io, .fromMode(0o600));
        try file.writePositionalAll(r.recorder.io, r.bytes.items, try file.length(r.recorder.io));
        try file.sync(r.recorder.io);
        if (r.hashes.items.len == 0) return;
        const hash_path = try r.recorder.hashPath();
        defer r.recorder.gpa.free(hash_path);
        const index = try std.Io.Dir.cwd().createFile(r.recorder.io, hash_path, .{ .truncate = false, .permissions = .fromMode(0o600) });
        defer index.close(r.recorder.io);
        try index.setPermissions(r.recorder.io, .fromMode(0o600));
        try index.writePositionalAll(r.recorder.io, r.hashes.items, try index.length(r.recorder.io));
        try index.sync(r.recorder.io);
    }
};

pub const RecordedCall = struct {
    index: usize,
    seq: usize,
    name: []const u8,
    args: std.json.Value,
    ok: bool,
    text: []const u8,
    incomplete: bool = false,
};
pub const Invocation = struct { name: []const u8, args: std.json.Value };
pub const Divergence = struct { index: usize, recorded: ?Invocation, actual: ?Invocation };

pub const Playback = struct {
    a: std.mem.Allocator,
    calls: []const RecordedCall,
    script_mode: bool = false,
    start_ms_epoch: i64,
    divergence: ?Divergence = null,
    uses_time: bool = false,
    uses_random: bool = false,
    created: usize = 0,
    delivered: usize = 0,

    pub fn unreachableCall(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) sandbox.ToolResult {
        @panic("replay must never dispatch a real tool");
    }

    pub fn dispatch(p: *Playback, gpa: std.mem.Allocator, index: usize, name: []const u8, args_json: []const u8) !struct { seq: usize, result: sandbox.ToolResult } {
        p.created += 1;
        const args = try std.json.parseFromSliceLeaky(std.json.Value, p.a, args_json, .{ .allocate = .alloc_always });
        var recorded: ?RecordedCall = null;
        for (p.calls) |call| {
            if (if (p.script_mode) std.mem.eql(u8, name, call.name) and equal(args, call.args) else call.index == index) {
                recorded = call;
                break;
            }
        }
        if (recorded) |call| {
            if (p.script_mode or (std.mem.eql(u8, name, call.name) and equal(args, call.args)))
                return .{ .seq = if (p.script_mode) index else call.seq, .result = if (call.ok) .{ .ok = try gpa.dupe(u8, call.text) } else .{ .err = try gpa.dupe(u8, call.text) } };
        }
        if (!p.script_mode and p.divergence == null) p.divergence = .{
            .index = index,
            .recorded = if (recorded) |call| .{ .name = call.name, .args = call.args } else null,
            .actual = .{ .name = try p.a.dupe(u8, name), .args = args },
        };
        return .{ .seq = index, .result = .{ .err = try std.fmt.allocPrint(gpa, "not recorded: {s}", .{name}) } };
    }

    pub fn finish(p: *Playback) void {
        if (p.script_mode or p.divergence != null) return;
        var missing: ?RecordedCall = null;
        for (p.calls) |call| if (call.index >= p.created and (missing == null or call.index < missing.?.index)) {
            missing = call;
        };
        if (missing) |call| p.divergence = .{ .index = call.index, .recorded = .{ .name = call.name, .args = call.args }, .actual = null };
    }
};

pub fn equal(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |v| blk: {
            if (v.items.len != b.array.items.len) break :blk false;
            for (v.items, b.array.items) |left, right| if (!equal(left, right)) break :blk false;
            break :blk true;
        },
        .object => |v| blk: {
            if (v.count() != b.object.count()) break :blk false;
            var it = v.iterator();
            while (it.next()) |kv| if (!equal(kv.value_ptr.*, b.object.get(kv.key_ptr.*) orelse break :blk false)) break :blk false;
            break :blk true;
        },
    };
}

test {
    _ = @import("record_test.zig");
}
