const std = @import("std");
const provider = @import("../provider.zig");
const Background = @import("events.zig").Background;

pub const Batch = struct {
    items: std.ArrayList(Item) = .empty,

    pub fn deinit(b: *Batch, gpa: std.mem.Allocator) void {
        for (b.items.items) |item| {
            gpa.free(item.text);
            if (item.background) |bkg| gpa.free(bkg.id);
            if (item.completion_arena) |owned| {
                var arena = owned;
                arena.deinit();
            }
        }
        b.items.deinit(gpa);
    }

    pub fn joined(b: Batch, gpa: std.mem.Allocator) ![]u8 {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(gpa);
        for (b.items.items) |item| {
            if (item.background != null) continue;
            if (text.items.len > 0) try text.appendSlice(gpa, "\n\n");
            try text.appendSlice(gpa, item.text);
        }
        return text.toOwnedSlice(gpa);
    }
};

pub const Item = struct { id: u64, text: []const u8, background: ?Background = null, detached: bool = false, invocation: usize = 0, completion_arena: ?std.heap.ArenaAllocator = null };

pub const Inbox = struct {
    mutex: std.Io.Mutex = .init,
    batch: Batch = .{},
    /// Results returned by `tools.wait`, awaiting the Session's delivery bookkeeping.
    waited: Batch = .{},
    next_id: u64 = 1,

    pub fn enqueue(q: *Inbox, gpa: std.mem.Allocator, io: std.Io, text: []const u8) !u64 {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        const copy = try gpa.dupe(u8, text);
        errdefer gpa.free(copy);
        const id = q.next_id;
        try q.batch.items.append(gpa, .{ .id = id, .text = copy });
        q.next_id += 1;
        return id;
    }

    pub fn enqueueBackground(q: *Inbox, gpa: std.mem.Allocator, io: std.Io, id: []const u8, kind: Background.Kind, state: @FieldType(Background, "state"), ok: ?bool, text: []const u8, detached: bool, invocation: usize, execution: ?@import("../sandbox/timing.zig").Execution) !u64 {
        return q.enqueueCompletion(gpa, io, id, kind, state, ok, text, detached, invocation, null, execution);
    }

    pub fn enqueueCompletion(q: *Inbox, gpa: std.mem.Allocator, io: std.Io, id: []const u8, kind: Background.Kind, state: @FieldType(Background, "state"), ok: ?bool, text: []const u8, detached: bool, invocation: usize, completion: ?@import("events.zig").RunCompletion, execution: ?@import("../sandbox/timing.zig").Execution) !u64 {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        const copy = try gpa.dupe(u8, text);
        errdefer gpa.free(copy);
        const agent_id = try gpa.dupe(u8, id);
        errdefer gpa.free(agent_id);
        var owned: ?std.heap.ArenaAllocator = null;
        errdefer if (owned) |*arena| arena.deinit();
        const copy_completion = if (completion) |value| blk: {
            owned = .init(gpa);
            break :blk try cloneCompletion(owned.?.allocator(), value);
        } else null;
        const message_id = q.next_id;
        try q.batch.items.append(gpa, .{ .id = message_id, .text = copy, .background = .{ .id = agent_id, .kind = kind, .state = state, .ok = ok, .completion = copy_completion, .execution = execution }, .detached = detached, .invocation = invocation, .completion_arena = owned });
        q.next_id += 1;
        return message_id;
    }

    pub const Waited = struct { kind: Background.Kind, ok: ?bool, invocation: usize, text: []u8 };

    /// Moves the oldest queued background result of `id` to `waited`; the copy of its text belongs to the caller.
    pub fn takeForWait(q: *Inbox, gpa: std.mem.Allocator, io: std.Io, id: []const u8) !?Waited {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        for (q.batch.items.items, 0..) |item, i| {
            const b = item.background orelse continue;
            if (!std.mem.eql(u8, b.id, id)) continue;
            const text = try gpa.dupe(u8, item.text);
            errdefer gpa.free(text);
            try q.waited.items.append(gpa, item);
            _ = q.batch.items.orderedRemove(i);
            return .{ .kind = b.kind, .ok = b.ok, .invocation = item.invocation, .text = text };
        }
        return null;
    }

    pub fn takeWaited(q: *Inbox, io: std.Io) Batch {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        const batch = q.waited;
        q.waited = .{};
        return batch;
    }

    pub fn empty(q: *Inbox, io: std.Io) bool {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        return q.batch.items.items.len == 0;
    }

    pub fn take(q: *Inbox, io: std.Io) Batch {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        const batch = q.batch;
        q.batch = .{};
        return batch;
    }

    pub fn takeUsers(q: *Inbox, gpa: std.mem.Allocator, io: std.Io) !Batch {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        var users: Batch = .{};
        errdefer users.items.deinit(gpa);
        var count: usize = 0;
        for (q.batch.items.items) |item| if (item.background == null) {
            count += 1;
        };
        try users.items.ensureTotalCapacity(gpa, count);
        var retained: usize = 0;
        for (q.batch.items.items) |item| {
            if (item.background == null) {
                users.items.appendAssumeCapacity(item);
            } else {
                q.batch.items.items[retained] = item;
                retained += 1;
            }
        }
        q.batch.items.shrinkRetainingCapacity(retained);
        return users;
    }

    pub fn insert(q: *Inbox, gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, pending: *std.ArrayList(provider.Message)) !Batch {
        return q.insertSelected(gpa, io, arena, pending, false);
    }

    pub fn insertBackground(q: *Inbox, gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, pending: *std.ArrayList(provider.Message)) !Batch {
        return q.insertSelected(gpa, io, arena, pending, true);
    }

    fn insertSelected(q: *Inbox, gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, pending: *std.ArrayList(provider.Message), background_only: bool) !Batch {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        var selected: Batch = .{};
        errdefer selected.items.deinit(gpa);
        try selected.items.ensureTotalCapacity(gpa, q.batch.items.items.len);
        var messages: std.ArrayList(provider.Message) = .empty;
        defer messages.deinit(gpa);
        for (q.batch.items.items) |item| {
            if (background_only and (item.background == null or item.detached)) continue;
            selected.items.appendAssumeCapacity(item);
            try messages.append(gpa, .{ .role = "user", .content = try arena.dupe(u8, item.text), .source = if (item.background != null) .background else null, .background_kind = if (item.background) |b| b.kind else null, .background_ok = if (item.background) |b| b.ok else null, .background_id = if (item.background) |b| try arena.dupe(u8, b.id) else null, .background_run = if (item.background) |b| if (b.completion) |value| try cloneCompletion(arena, value) else null else null });
        }
        try pending.appendSlice(gpa, messages.items);
        var retained: usize = 0;
        for (q.batch.items.items) |item| {
            if (background_only and (item.background == null or item.detached)) {
                q.batch.items.items[retained] = item;
                retained += 1;
            }
        }
        q.batch.items.shrinkRetainingCapacity(retained);
        return selected;
    }
};

test "insert drains an owned FIFO batch after tool results" {
    const t = std.testing;
    const gpa = t.allocator;
    var q: Inbox = .{};
    defer q.batch.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var pending: std.ArrayList(provider.Message) = .empty;
    defer pending.deinit(gpa);
    try pending.append(gpa, .{ .role = "tool", .content = "result", .tool_call_id = "run" });
    var original = [_]u8{ 'o', 'n', 'e' };
    const first = try q.enqueue(gpa, t.io, &original);
    original[0] = 'x';
    const second = try q.enqueue(gpa, t.io, "two");
    var batch = try q.insert(gpa, t.io, arena.allocator(), &pending);
    defer batch.deinit(gpa);
    try t.expectEqual(@as(usize, 0), q.batch.items.items.len);
    try t.expectEqual(first, batch.items.items[0].id);
    try t.expectEqual(second, batch.items.items[1].id);
    try t.expectEqualStrings("tool", pending.items[0].role);
    try t.expectEqualStrings("one", pending.items[1].content.?);
    try t.expectEqualStrings("user", pending.items[1].role);
    try t.expectEqualStrings("two", pending.items[2].content.?);
    _ = try q.enqueue(gpa, t.io, "later");
    var leftover = q.take(t.io);
    defer leftover.deinit(gpa);
    try t.expectEqual(@as(usize, 1), leftover.items.items.len);
    const joined = try batch.joined(gpa);
    defer gpa.free(joined);
    try t.expectEqualStrings("one\n\ntwo", joined);
}

test "concurrent enqueue assigns FIFO ids without losing messages" {
    const t = std.testing;
    var q: Inbox = .{};
    defer q.batch.deinit(t.allocator);
    const Worker = struct {
        fn run(inbox: *Inbox) void {
            for (0..25) |_| _ = inbox.enqueue(std.testing.allocator, std.testing.io, "message") catch @panic("enqueue failed");
        }
    };
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    {
        defer for (threads[0..spawned]) |thread| thread.join();
        for (&threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{&q});
            spawned += 1;
        }
    }
    var batch = q.take(t.io);
    defer batch.deinit(t.allocator);
    try t.expectEqual(@as(usize, 100), batch.items.items.len);
    for (batch.items.items, 1..) |item, id| try t.expectEqual(@as(u64, id), item.id);
}

test "limit wait inserts background results and preserves queued user messages" {
    const t = std.testing;
    var q: Inbox = .{};
    defer q.batch.deinit(t.allocator);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var pending: std.ArrayList(provider.Message) = .empty;
    defer pending.deinit(t.allocator);
    _ = try q.enqueue(t.allocator, t.io, "next user message");
    _ = try q.enqueueBackground(t.allocator, t.io, "b1", .bash, .finished, true, "background result", false, 0, null);
    _ = try q.enqueueBackground(t.allocator, t.io, "b2", .bash, .finished, true, "detached result", true, 0, null);
    _ = try q.enqueue(t.allocator, t.io, "another user message");
    var inserted = try q.insertBackground(t.allocator, t.io, arena.allocator(), &pending);
    defer inserted.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), inserted.items.items.len);
    try t.expectEqual(@as(usize, 1), pending.items.len);
    try t.expectEqualStrings("background result", pending.items[0].content.?);
    try t.expect(pending.items[0].source.? == .background);
    try t.expectEqual(@as(usize, 3), q.batch.items.items.len);
    try t.expectEqualStrings("next user message", q.batch.items.items[0].text);
    try t.expectEqualStrings("detached result", q.batch.items.items[1].text);
    try t.expectEqualStrings("another user message", q.batch.items.items[2].text);
    var next_step = try q.insert(t.allocator, t.io, arena.allocator(), &pending);
    defer next_step.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), next_step.items.items.len);
    try t.expect(q.empty(t.io));
}

test "taking queued users preserves background results for exactly one later insertion" {
    const t = std.testing;
    var q: Inbox = .{};
    defer q.batch.deinit(t.allocator);
    _ = try q.enqueueBackground(t.allocator, t.io, "b1", .bash, .finished, true, "first result", false, 0, null);
    const user_id = try q.enqueue(t.allocator, t.io, "next input");
    _ = try q.enqueueBackground(t.allocator, t.io, "b2", .bash, .finished, false, "second result", false, 0, null);
    var users = try q.takeUsers(t.allocator, t.io);
    defer users.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), users.items.items.len);
    try t.expectEqual(user_id, users.items.items[0].id);
    try t.expectEqualStrings("next input", users.items.items[0].text);
    var again = try q.takeUsers(t.allocator, t.io);
    defer again.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), again.items.items.len);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var pending: std.ArrayList(provider.Message) = .empty;
    defer pending.deinit(t.allocator);
    var results = try q.insert(t.allocator, t.io, arena.allocator(), &pending);
    defer results.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), results.items.items.len);
    try t.expectEqualStrings("b1", results.items.items[0].background.?.id);
    try t.expectEqualStrings("b2", results.items.items[1].background.?.id);
    try t.expectEqualStrings("first result", pending.items[0].content.?);
    try t.expectEqualStrings("second result", pending.items[1].content.?);
    var empty = try q.insert(t.allocator, t.io, arena.allocator(), &pending);
    defer empty.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), empty.items.items.len);
    try t.expectEqual(@as(usize, 2), pending.items.len);
}

test "taking queued users leaves the inbox untouched on allocation failure" {
    const t = std.testing;
    var q: Inbox = .{};
    defer q.batch.deinit(t.allocator);
    _ = try q.enqueueBackground(t.allocator, t.io, "b1", .bash, .finished, true, "result", false, 0, null);
    const id = try q.enqueue(t.allocator, t.io, "next input");
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, q.takeUsers(failing.allocator(), t.io));
    try t.expectEqual(@as(usize, 2), q.batch.items.items.len);
    try t.expectEqualStrings("b1", q.batch.items.items[0].background.?.id);
    try t.expectEqual(id, q.batch.items.items[1].id);
    try t.expectEqualStrings("next input", q.batch.items.items[1].text);
}

fn cloneCompletion(a: std.mem.Allocator, value: @import("events.zig").RunCompletion) !@import("events.zig").RunCompletion {
    const json = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(json);
    return std.json.parseFromSliceLeaky(@import("events.zig").RunCompletion, a, json, .{ .allocate = .alloc_always });
}

test "waiting takes one result by id and leaves the rest queued" {
    const t = std.testing;
    var q: Inbox = .{};
    defer q.batch.deinit(t.allocator);
    defer q.waited.deinit(t.allocator);
    _ = try q.enqueue(t.allocator, t.io, "user text");
    _ = try q.enqueueBackground(t.allocator, t.io, "b1", .bash, .finished, true, "[background bash b1 finished]\nfirst", false, 0, null);
    _ = try q.enqueueBackground(t.allocator, t.io, "b2", .bash, .finished, false, "second", false, 0, null);
    try t.expect(try q.takeForWait(t.allocator, t.io, "b9") == null);
    const taken = (try q.takeForWait(t.allocator, t.io, "b2")).?;
    defer t.allocator.free(taken.text);
    try t.expectEqualStrings("second", taken.text);
    try t.expectEqual(@as(?bool, false), taken.ok);
    try t.expectEqual(@as(usize, 2), q.batch.items.items.len);
    var waited = q.takeWaited(t.io);
    defer waited.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), waited.items.items.len);
    try t.expectEqualStrings("b2", waited.items.items[0].background.?.id);
}
