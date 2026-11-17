const std = @import("std");
const sandbox = @import("sandbox");
const b = sandbox.benchmark;

const Workload = enum { serial, parallel, mixed, large };
const large_bytes = 256 * 1024;

const Mock = struct {
    io: std.Io,
    nonce: usize = 0,
    active: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn call(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8, args: []const u8) sandbox.ToolResult {
        const self: *Mock = @ptrCast(@alignCast(ctx));
        if (comptime @import("builtin").is_test) {
            const active = self.active.fetchAdd(1, .acq_rel) + 1;
            _ = self.peak.fetchMax(active, .monotonic);
        }
        defer if (comptime @import("builtin").is_test) {
            _ = self.active.fetchSub(1, .acq_rel);
        };
        if (std.mem.eql(u8, name, "wait"))
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(20), .clock = .awake }, self.io) catch unreachable;
        if (std.mem.eql(u8, name, "fail")) return .{ .err = gpa.dupe(u8, "fixture failure") catch unreachable };
        if (std.mem.eql(u8, name, "large")) {
            const index = std.fmt.parseInt(usize, args, 10) catch unreachable;
            const bytes = gpa.alloc(u8, large_bytes + 2) catch unreachable;
            @memset(bytes, 'x');
            bytes[0] = '"';
            bytes[bytes.len - 1] = '"';
            _ = std.fmt.bufPrint(bytes[1..33], "{d:0>16}", .{self.nonce * 16 + index}) catch unreachable;
            return .{ .ok = bytes };
        }
        return .{ .ok = gpa.dupe(u8, "1") catch unreachable };
    }

    fn host(self: *Mock, probe: ?*b.Probe, record: ?*sandbox.Recorder, timing: *sandbox.RunTiming) sandbox.Host {
        return .{ .ctx = self, .names = &.{ "short", "wait", "large", "fail" }, .call = call, .benchmark_probe = probe, .record = record, .timing = timing };
    }
};

fn count(workload: Workload) usize {
    return if (workload == .large) 16 else 128;
}

fn source(workload: Workload) []const u8 {
    return switch (workload) {
        .serial => "for(let i=0;i<128;i++){const r=await tools.short(i);__benchReceived(i);if(r!==1)throw Error('value');} 128",
        .parallel => "await Promise.all(Array.from({length:128},(_,i)=>tools.short(i).then(r=>{__benchReceived(i);if(r!==1)throw Error('value');}))); 128",
        .mixed => "await Promise.all(Array.from({length:128},(_,i)=>(i<4?tools.wait(i):tools.short(i)).then(r=>{__benchReceived(i);if(r!==1)throw Error('value');}))); 128",
        .large => "await Promise.all(Array.from({length:16},(_,i)=>tools.large(i).then(r=>{__benchReceived(i);if(r.length!==262144)throw Error('size');}))); 16",
    };
}

fn validate(slots: []const b.Slot, recorded: bool) !void {
    for (slots) |s| {
        if (!(s.enqueued > 0 and s.enqueued <= s.dispatch and s.dispatch <= s.spawn_begin and
            s.spawn_begin <= s.spawn_end and s.spawn_begin <= s.worker_enter and
            s.worker_enter <= s.tool_begin and s.tool_begin <= s.tool_end and
            s.tool_end <= s.join_begin and s.spawn_end <= s.join_begin and
            s.join_begin <= s.join_end and s.join_end <= s.deliver and
            s.deliver <= s.bridge_begin and s.bridge_begin <= s.bridge_end and s.bridge_end <= s.received))
            return error.InvalidStageOrder;
        if (recorded) {
            if (!(s.deliver <= s.record_begin and s.record_begin <= s.record_end and s.record_end <= s.bridge_begin))
                return error.InvalidRecordOrder;
        } else if (s.record_begin != 0 or s.record_end != 0) return error.UnexpectedRecording;
    }
}

fn emit(out: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, out);
    try out.writeByte('\n');
}

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").mode != .fast) @compileError("scheduler benchmark requires -Doptimize=ReleaseFast");
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.ExpectedRecordingPathSamplesWarmups;
    const samples = try std.fmt.parseInt(usize, args[2], 10);
    const warmups = try std.fmt.parseInt(usize, args[3], 10);
    if (samples == 0) return error.EmptySamples;
    const gpa = init.gpa;
    const io = init.io;
    var buf: [65536]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;
    var slots: [128]b.Slot = undefined;
    var probe: b.Probe = .{ .io = io, .slots = &slots };
    var clock_pairs: [10000]i64 = undefined;
    var mark_pairs: [10000]i64 = undefined;
    for (&clock_pairs, &mark_pairs) |*clock, *marks| {
        const begin = probe.now();
        clock.* = probe.now() - begin;
        probe.mark(0, "enqueued");
        probe.mark(0, "dispatch");
        marks.* = slots[0].dispatch - slots[0].enqueued;
    }
    var ack_batches: [100]i64 = undefined;
    var loop_batches: [100]i64 = undefined;
    var calibration_mock: Mock = .{ .io = io };
    for (0..100) |round| {
        for (0..2) |offset| {
            const ack = (round + offset) % 2 == 1;
            const code = if (ack)
                "let n=0;for(let i=0;i<100000;i++){__benchReceived(0);n++;} n"
            else
                "let n=0;for(let i=0;i<100000;i++){n++;} n";
            var timing: sandbox.RunTiming = .init(io, .now(io, .awake));
            const begin = probe.now();
            const result = try sandbox.eval(gpa, io, code, .{}, calibration_mock.host(null, null, &timing), null);
            const end = probe.now();
            defer result.deinit(gpa);
            if (!result.ok or !std.mem.eql(u8, result.text, "100000") or timing.count != 0) return error.InvalidCalibration;
            if (ack) ack_batches[round] = end - begin else loop_batches[round] = end - begin;
        }
    }
    try emit(out, .{ .kind = "calibration", .clock_pair_ns = clock_pairs, .mark_pair_ns = mark_pairs, .ack_batch_ns = ack_batches, .loop_batch_ns = loop_batches, .ack_batch_calls = 100000 });
    var recorder = sandbox.Recorder.init(gpa, io, args[1], true);
    defer recorder.deinit();
    var mock: Mock = .{ .io = io };
    const workloads = [_]Workload{ .serial, .parallel, .mixed, .large };
    for (0..samples + warmups) |round| {
        for (0..16) |offset| {
            const configuration = (offset + round) % 16;
            const workload = workloads[configuration / 4];
            const recorded = configuration % 4 >= 2;
            const traced = configuration % 2 == 1;
            mock.nonce += 1;
            const n = count(workload);
            @memset(&slots, .{});
            probe.slots = slots[0..n];
            probe.invalid_ack = false;
            var timing: sandbox.RunTiming = .init(io, .now(io, .awake));
            const run_begin = probe.now();
            if (recorded) recorder.begin(mock.nonce, 0);
            const eval_begin = probe.now();
            const result = try sandbox.eval(gpa, io, source(workload), .{}, mock.host(if (traced) &probe else null, if (recorded) &recorder else null, &timing), null);
            const eval_end = probe.now();
            defer result.deinit(gpa);
            const finish_begin = probe.now();
            if (recorded) recorder.finish(.ok);
            const finish_end = probe.now();
            const run_end = probe.now();
            if (!result.ok or timing.count != n or timing.omitted != 0 or probe.invalid_ack) return error.InvalidResult;
            if (!std.mem.eql(u8, result.text, if (workload == .large) "16" else "128")) return error.InvalidCount;
            if (recorded and (!recorder.enabled or recorder.seq != n or recorder.incomplete)) return error.RecordingFailed;
            if (traced) try validate(slots[0..n], recorded);
            if (round >= warmups) try emit(out, .{
                .kind = "run",
                .round = round - warmups,
                .workload = @tagName(workload),
                .recorded = recorded,
                .traced = traced,
                .run_ns = run_end - run_begin,
                .eval_ns = eval_end - eval_begin,
                .record_finish_ns = finish_end - finish_begin,
                .slots = if (traced) slots[0..n] else &.{},
            });
        }
    }
    try out.flush();
}

test "probe validates independent spawn and worker timelines, rejects missing acknowledgements" {
    var s: b.Slot = .{ .enqueued = 1, .dispatch = 2, .spawn_begin = 3, .spawn_end = 9, .worker_enter = 4, .tool_begin = 5, .tool_end = 6, .join_begin = 10, .join_end = 11, .deliver = 12, .bridge_begin = 13, .bridge_end = 14, .received = 15 };
    try validate(&.{s}, false);
    s.spawn_end = 8;
    s.worker_enter = 9;
    s.tool_begin = 10;
    s.tool_end = 11;
    s.join_begin = 12;
    s.join_end = 12;
    try validate(&.{s}, false);
    s.received = 0;
    try std.testing.expectError(error.InvalidStageOrder, validate(&.{s}, false));
}

test "benchmark acknowledgements detect duplicates and out of range indices" {
    var slots = [_]b.Slot{.{}};
    var probe: b.Probe = .{ .io = std.testing.io, .slots = &slots };
    probe.received(0);
    try std.testing.expect(slots[0].received > 0);
    probe.received(0);
    try std.testing.expect(probe.invalid_ack);
    probe.invalid_ack = false;
    probe.received(1);
    try std.testing.expect(probe.invalid_ack);
}

test "benchmark fixtures deliver all values with recording on and off" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    const path = try std.fs.path.join(t.allocator, &.{ dir, "calls.jsonl" });
    defer t.allocator.free(path);
    var recorder = sandbox.Recorder.init(t.allocator, t.io, path, true);
    defer recorder.deinit();
    var mock: Mock = .{ .io = t.io };
    for ([_]bool{ false, true }) |recorded| {
        for ([_]Workload{ .serial, .parallel, .mixed, .large }) |workload| {
            var slots: [128]b.Slot = @splat(.{});
            var probe: b.Probe = .{ .io = t.io, .slots = slots[0..count(workload)] };
            var timing: sandbox.RunTiming = .init(t.io, .now(t.io, .awake));
            mock.nonce += 1;
            mock.peak.store(0, .monotonic);
            if (recorded) recorder.begin(mock.nonce, 0);
            const result = try sandbox.eval(t.allocator, t.io, source(workload), .{}, mock.host(&probe, if (recorded) &recorder else null, &timing), null);
            defer result.deinit(t.allocator);
            if (recorded) recorder.finish(.ok);
            try t.expect(result.ok);
            try t.expectEqual(count(workload), timing.count);
            try t.expect(!probe.invalid_ack);
            try validate(probe.slots, recorded);
            try t.expectEqual(0, mock.active.load(.monotonic));
            try t.expect(mock.peak.load(.monotonic) <= sandbox.tool_concurrency);
            if (workload == .serial) try t.expectEqual(1, mock.peak.load(.monotonic));
            if (workload == .mixed) {
                try t.expect(mock.peak.load(.monotonic) > 1);
                for (probe.slots[0..4]) |slot| try t.expect(slot.tool_end - slot.tool_begin >= 20 * std.time.ns_per_ms);
            }
            if (recorded) {
                try t.expect(recorder.enabled and !recorder.incomplete);
                try t.expectEqual(count(workload), recorder.seq);
            }
        }
    }
}
