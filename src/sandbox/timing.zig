const std = @import("std");

pub const Call = struct {
    name: []const u8,
    start_ms: u64,
    end_ms: u64,
    ok: bool,
    run_index: usize,
    result_bytes: ?u64 = null,
    dispatched: bool = true,
    background: ?bool = null,
    id: ?[]const u8 = null,
};

pub const Run = struct {
    io: std.Io,
    started: std.Io.Clock.Timestamp,
    run_index: usize = 0,
    entries: [200]Call = undefined,
    count: usize = 0,
    omitted: u64 = 0,
    llm_calls: u64 = 0,
    agent_calls: u64 = 0,
    race_branches: u64 = 0,
    tool_bytes: u64 = 0,
    output_bytes: u64 = 0,

    pub fn init(io: std.Io, started: std.Io.Clock.Timestamp) Run {
        return .{ .io = io, .started = started };
    }

    pub fn elapsed(r: *const Run) u64 {
        return @intCast(@max(r.started.untilNow(r.io).raw.toMilliseconds(), 0));
    }

    // Dispatch owns reservations; workers complete distinct slots under the sandbox queue mutex.
    pub fn reserve(r: *Run, name: []const u8) ?usize {
        if (std.mem.eql(u8, name, "llm")) r.llm_calls += 1;
        if (std.mem.eql(u8, name, "agent")) r.agent_calls += 1;
        return r.reserveEntry(name);
    }

    pub fn reserveEntry(r: *Run, name: []const u8) ?usize {
        if (r.count == r.entries.len) {
            r.omitted +|= 1;
            return null;
        }
        const index = r.count;
        r.entries[index] = .{
            .name = stableName(name),
            .start_ms = 0,
            .end_ms = 0,
            .ok = false,
            .run_index = r.run_index,
            .result_bytes = 0,
        };
        r.count += 1;
        return index;
    }

    pub fn undoReservation(r: *Run, index: ?usize, name: []const u8) void {
        if (std.mem.eql(u8, name, "llm")) r.llm_calls -= 1;
        if (std.mem.eql(u8, name, "agent")) r.agent_calls -= 1;
        if (index) |i| {
            std.debug.assert(i + 1 == r.count);
            r.count -= 1;
        } else {
            r.omitted -= 1;
        }
    }

    pub fn result(r: *Run, index: ?usize, bytes: usize) void {
        r.tool_bytes += bytes;
        if (index) |i| r.entries[i].result_bytes = bytes;
    }

    pub fn complete(r: *Run, index: usize, start_ms: u64, end_ms: u64, ok: bool) void {
        const entry = &r.entries[index];
        entry.start_ms = start_ms;
        entry.end_ms = end_ms;
        entry.ok = ok;
    }
};

fn stableName(name: []const u8) []const u8 {
    inline for (.{ "read", "write", "edit", "grep", "glob", "bash", "stop", "fetch", "agent", "race", "llm", "sleep" }) |known| {
        if (std.mem.eql(u8, name, known)) return known;
    }
    return "unknown";
}

test "bounded calls retain dispatch order and count omitted invocations" {
    const t = std.testing;
    var r: Run = .init(t.io, .now(t.io, .awake));
    for (0..203) |i| {
        r.run_index = i / 100;
        if (r.reserve("bash")) |index| r.complete(index, i, i + 10, i % 2 == 0);
    }
    try t.expectEqual(@as(usize, 200), r.count);
    try t.expectEqual(@as(u64, 3), r.omitted);
    try t.expectEqual(@as(usize, 1), r.entries[199].run_index);
    try t.expectEqual(@as(u64, 209), r.entries[199].end_ms);
    try t.expect(!r.entries[199].ok);
    try t.expect(r.entries[0].ok);
}

test "names survive source mutation and collector copies" {
    const t = std.testing;
    var r: Run = .init(t.io, .now(t.io, .awake));
    var name = [_]u8{ 'r', 'e', 'a', 'd' };
    _ = r.reserve(&name);
    _ = r.reserve("custom");
    name[0] = 'x';
    const copy = r;
    r = .init(t.io, .now(t.io, .awake));
    try t.expectEqualStrings("read", copy.entries[0].name);
    try t.expectEqualStrings("unknown", copy.entries[1].name);
}

test "failed dispatch releases its reservation including overflow" {
    const t = std.testing;
    var r: Run = .init(t.io, .now(t.io, .awake));
    r.undoReservation(r.reserve("read"), "read");
    try t.expectEqual(@as(usize, 0), r.count);
    for (0..200) |_| _ = r.reserve("read");
    r.undoReservation(r.reserve("read"), "read");
    try t.expectEqual(@as(usize, 200), r.count);
    try t.expectEqual(@as(u64, 0), r.omitted);
}

test "delegation counts include overflow and exclude failed dispatch" {
    const t = std.testing;
    var r: Run = .init(t.io, .now(t.io, .awake));
    r.undoReservation(r.reserve("agent"), "agent");
    try t.expectEqual(@as(u64, 0), r.agent_calls);
    for (0..205) |_| _ = r.reserve("agent");
    _ = r.reserve("llm");
    r.undoReservation(r.reserve("llm"), "llm");
    try t.expectEqual(@as(u64, 205), r.agent_calls);
    try t.expectEqual(@as(u64, 1), r.llm_calls);
    try t.expectEqual(@as(u64, 6), r.omitted);
}

test "race dispatch keeps its tool name and is not an ordinary agent call" {
    var run: Run = .init(std.testing.io, .now(std.testing.io, .awake));
    const index = run.reserve("race").?;
    try std.testing.expectEqualStrings("race", run.entries[index].name);
    try std.testing.expectEqual(@as(u64, 0), run.agent_calls);
}
