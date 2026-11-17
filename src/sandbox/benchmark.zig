const std = @import("std");
pub const enabled = @import("sandbox_probe_options").enabled;
pub const Slot = struct {
    enqueued: i64 = 0,
    dispatch: i64 = 0,
    spawn_begin: i64 = 0,
    spawn_end: i64 = 0,
    worker_enter: i64 = 0,
    tool_begin: i64 = 0,
    tool_end: i64 = 0,
    join_begin: i64 = 0,
    join_end: i64 = 0,
    deliver: i64 = 0,
    record_begin: i64 = 0,
    record_end: i64 = 0,
    bridge_begin: i64 = 0,
    bridge_end: i64 = 0,
    received: i64 = 0,
};

pub const Probe = struct {
    io: std.Io,
    slots: []Slot,
    invalid_ack: bool = false,

    pub fn now(p: *const Probe) i64 {
        return @intCast(std.Io.Clock.awake.now(p.io).nanoseconds);
    }

    // Eval and worker write distinct fields; readers wait until eval has joined all workers.
    pub fn mark(p: *Probe, index: usize, comptime field: []const u8) void {
        @field(p.slots[index], field) = p.now();
    }

    pub fn received(p: *Probe, index: usize) void {
        if (index >= p.slots.len or p.slots[index].received != 0) {
            p.invalid_ack = true;
            return;
        }
        p.mark(index, "received");
    }
};
