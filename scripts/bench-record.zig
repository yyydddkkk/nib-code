const std = @import("std");
const record = @import("record");

pub fn main(init: std.process.Init) !void {
    for ([_]usize{ 128, 1024 * 1024 }) |size| {
        for ([_]bool{ true, false }) |enabled| {
            for ([_]bool{ false, true }) |duplicate| {
                for ([_]bool{ false, true }) |cold| {
                    var counted = std.testing.FailingAllocator.init(init.gpa, .{});
                    var recorder = record.Recorder.init(counted.allocator(), init.io, "unused-benchmark-path", enabled);
                    defer recorder.deinit();
                    recorder.loaded = true;
                    const payload = try init.gpa.alloc(u8, size);
                    defer init.gpa.free(payload);
                    @memset(payload, 'x');
                    const batches: usize = if (size == 128) 2000 else 30;
                    const calls: usize = if (size == 128) 64 else 8;
                    var elapsed: i128 = 0;
                    var allocations: usize = 0;
                    var allocated_bytes: usize = 0;
                    var resizes: usize = 0;
                    var recorded_bytes: usize = 0;
                    for (0..batches + 1) |batch| {
                        recorder.begin(1, 0);
                        if (cold) {
                            recorder.buffer.clearAndFree(counted.allocator());
                            recorder.seen.clearAndFree(counted.allocator());
                        } else recorder.seen.clearRetainingCapacity();
                        const a = counted.allocations;
                        const b = counted.allocated_bytes;
                        const s = counted.resize_index;
                        const start: std.Io.Clock.Timestamp = .now(init.io, .awake);
                        for (0..calls) |index| {
                            payload[0] = if (duplicate) 'x' else @intCast('A' + index % 26);
                            payload[1] = if (duplicate) 'x' else @intCast('A' + index / 26);
                            recorder.capture(index, "read", "{\"path\":\"fixture\"}", true, payload);
                        }
                        const ns = start.untilNow(init.io).raw.toNanoseconds();
                        if (enabled and (!recorder.enabled or recorder.seq != calls)) return error.RecordingFailed;
                        if (batch == 0) continue;
                        elapsed += ns;
                        allocations += counted.allocations - a;
                        allocated_bytes += counted.allocated_bytes - b;
                        resizes += counted.resize_index - s;
                        recorded_bytes += recorder.buffer.items.len;
                    }
                    var digest: [32]u8 = undefined;
                    std.crypto.hash.sha2.Sha256.hash(recorder.buffer.items, &digest, .{});
                    const hex = std.fmt.bytesToHex(digest, .lower);
                    std.debug.print("{{\"size\":{d},\"enabled\":{},\"duplicate\":{},\"cold\":{},\"calls\":{d},\"ns\":{d},\"allocations\":{d},\"allocated_bytes\":{d},\"resizes\":{d},\"recorded_bytes\":{d},\"buffer_sha256\":\"{s}\"}}\n", .{ size, enabled, duplicate, cold, batches * calls, elapsed, allocations, allocated_bytes, resizes, recorded_bytes, hex });
                }
            }
        }
    }
}
