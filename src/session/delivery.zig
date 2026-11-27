const std = @import("std");
const engine = @import("../session.zig");
const Session = engine.Session;
const Sink = engine.Sink;
const Event = engine.Event;
const Tools = @import("../tools.zig").Tools;
const provider = @import("../provider.zig");
const inbox = @import("inbox.zig");
const session_log = @import("log.zig");
const compaction = @import("compact.zig");

pub const StepDelivery = struct {
    session: *Session,
    pending: *std.ArrayList(provider.Message),
    sink: Sink,
    hold_inbox: bool = false,

    pub fn beforeRequest(d: *StepDelivery) !void {
        if (!d.hold_inbox) try insert(d.session, d.pending, d.sink, false);
    }

    pub fn flushBackground(d: *StepDelivery) !void {
        try insert(d.session, d.pending, d.sink, true);
    }

    pub fn finishStep(d: *StepDelivery, record: session_log.Record, runs: []session_log.RunResult, scopes: []const usize, waiting: bool, started: std.Io.Clock.Timestamp) !void {
        const s = d.session;
        d.hold_inbox = s.tools.tuning.delivery == .tool and runs.len != 0 and !waiting;
        var folded: inbox.Batch = .{};
        defer folded.deinit(s.gpa);
        if (d.hold_inbox) {
            try Tools.poll(&s.tools);
            const own_output = d.pending.items[d.pending.items.len - 1].content;
            folded = try fold(s, d.pending, d.sink);
            if (folded.items.items.len > 0) runs[runs.len - 1].output = own_output;
        }
        var step = record;
        step.from = s.history.items.len;
        step.ms = @intCast(@max(started.untilNow(s.io).raw.toMilliseconds(), 0));
        step.task_ids = s.tools.progress.highWater(s.io);
        step.messages = d.pending.items;
        step.run_results = runs;
        var waited = try commit(s, step, folded, .fold, scopes);
        defer waited.deinit(s.gpa);
        for (waited.items.items) |item| try announceDelivered(s, item, d.sink);
        d.pending.clearRetainingCapacity();
    }
};

pub fn claim(t: *Tools, gpa: std.mem.Allocator, id: []const u8) !?inbox.Inbox.Waited {
    const queue = t.background.inbox orelse return null;
    const result = (try queue.takeForWait(gpa, t.io, id, t.runId())) orelse return null;
    t.background.delivered(t.io, id, result.invocation);
    return result;
}

fn announceDelivered(s: *Session, item: inbox.Item, sink: Sink) !void {
    if (item.background) |b| {
        s.tools.background.delivered(s.io, b.id, item.invocation);
        var event = b;
        event.result = inbox.resultText(item.text);
        try sink.emit(sink.ctx, .{ .background = event });
    } else if (sink.onUserInserted) |notify| try notify(sink.ctx, item.id);
}

fn commit(s: *Session, record: session_log.Record, delivered: inbox.Batch, via: @FieldType(session_log.Delivery, "via"), scopes: []const usize) !inbox.Batch {
    var waited: inbox.Batch = .{};
    errdefer waited.deinit(s.gpa);
    for (scopes) |scope| try s.inbox.takeWaited(s.gpa, s.io, scope, &waited);
    for (delivered.items.items) |item| {
        if (item.run_scope) |scope| try s.inbox.takeWaited(s.gpa, s.io, scope, &waited);
    }
    var deliveries: std.ArrayList(session_log.Delivery) = .empty;
    defer deliveries.deinit(s.gpa);
    try delivered.appendDeliveries(s.gpa, &deliveries, via);
    try waited.appendDeliveries(s.gpa, &deliveries, .wait);
    var commit_record = record;
    commit_record.deliveries = deliveries.items;
    try s.log.commit(s.io, s.gpa, &s.history, &s.context_tokens, commit_record);
    return waited;
}

pub fn commitLocalRun(s: *Session, scope: usize) !void {
    var waited = try commit(s, .{
        .from = s.history.items.len,
        .context_tokens = s.context_tokens,
        .task_ids = s.tools.progress.highWater(s.io),
        .model = s.cfg.model,
    }, .{}, .wait, &.{scope});
    waited.deinit(s.gpa);
}

fn fold(s: *Session, pending: *std.ArrayList(provider.Message), sink: Sink) !inbox.Batch {
    var batch = s.inbox.take(s.io);
    errdefer batch.deinit(s.gpa);
    if (batch.items.items.len == 0) return batch;
    const target = &pending.items[pending.items.len - 1];
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(s.gpa);
    try text.appendSlice(s.gpa, target.content orelse "");
    for (batch.items.items) |item| {
        try text.appendSlice(s.gpa, "\n\n");
        if (item.background == null) try text.appendSlice(s.gpa, "[user message]\n");
        try text.appendSlice(s.gpa, if (item.background == null) try s.expandSkills(item.text) else item.text);
    }
    target.content = try s.arena.allocator().dupe(u8, text.items);
    for (batch.items.items) |item| try announceDelivered(s, item, sink);
    return batch;
}

fn insert(s: *Session, pending: *std.ArrayList(provider.Message), sink: Sink, background_only: bool) !void {
    const before = pending.items.len;
    var inserted = if (background_only)
        try s.inbox.insertBackground(s.gpa, s.io, s.arena.allocator(), pending)
    else
        try s.inbox.insert(s.gpa, s.io, s.arena.allocator(), pending);
    defer inserted.deinit(s.gpa);
    for (pending.items[before..]) |*message| {
        if (message.source == null) message.content = try s.expandSkills(message.content orelse "");
    }
    var has_background = false;
    for (inserted.items.items) |item| {
        has_background = has_background or item.background != null;
        try announceDelivered(s, item, sink);
    }
    if (has_background) {
        var waited = try commit(s, .{
            .from = s.history.items.len,
            .messages = pending.items,
            .context_tokens = s.context_tokens + compaction.estimateTokens(pending.items, s.cfg),
            .task_ids = s.tools.progress.highWater(s.io),
            .model = s.cfg.model,
        }, inserted, .insert, &.{});
        defer waited.deinit(s.gpa);
        pending.clearRetainingCapacity();
        for (waited.items.items) |item| try announceDelivered(s, item, sink);
    }
}

test "tool delivery folds queued results and user messages into the last tool message" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const root = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
    defer client.deinit();
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    var session = try Session.init(t.allocator, t.io, &client, .{ .base_url = "invalid://local", .api_key = "mock", .model = "deepseek-flash" }, .{ .home = root, .user_home = root, .environ = &env });
    defer session.deinit();
    const Quiet = struct {
        events: usize = 0,
        inserted: usize = 0,
        fn emit(ctx: *anyopaque, _: Event) !void {
            const quiet: *@This() = @ptrCast(@alignCast(ctx));
            quiet.events += 1;
        }
        fn user(ctx: *anyopaque, _: u64) !void {
            const quiet: *@This() = @ptrCast(@alignCast(ctx));
            quiet.inserted += 1;
        }
    };
    var ctx: Quiet = .{};
    const sink: Sink = .{ .ctx = &ctx, .emit = Quiet.emit, .onUserInserted = Quiet.user };
    var pending: std.ArrayList(provider.Message) = .empty;
    defer pending.deinit(t.allocator);
    try pending.append(t.allocator, .{ .role = "assistant", .content = "" });
    try pending.append(t.allocator, .{ .role = "tool", .tool_call_id = "run", .content = "output" });
    session.tools.tuning.delivery = .tool;
    var step: StepDelivery = .{ .session = &session, .pending = &pending, .sink = sink };
    try step.beforeRequest();
    _ = try session.inbox.enqueueBackground(t.allocator, t.io, "b1", .bash, .finished, true, "[background bash b1 finished]\n{\"exit_code\":0}", false, 0, null);
    _ = try session.inbox.enqueue(t.allocator, t.io, "wait, also fix x");
    var runs = [_]session_log.RunResult{.{ .tool_call_id = "run" }};
    const before = session.history.items.len;
    try step.finishStep(.{ .context_tokens = 64 }, &runs, &.{}, false, .now(t.io, .awake));
    try t.expectEqual(@as(usize, 0), pending.items.len);
    try t.expectEqualStrings("output\n\n[background bash b1 finished]\n{\"exit_code\":0}\n\n[user message]\nwait, also fix x", session.history.items[before + 1].content.?);
    try t.expectEqualStrings("output", runs[0].output.?);
    try t.expectEqual(@as(usize, 1), ctx.inserted);
    try t.expectEqual(@as(usize, 1), ctx.events);
    try t.expect(session.inbox.empty(t.io));

    _ = try session.inbox.enqueue(t.allocator, t.io, "arrived after the fold");
    try step.beforeRequest();
    try t.expectEqual(@as(usize, 0), pending.items.len);
    try t.expect(!session.inbox.empty(t.io));
}

test "a queued Background Run retains its receipts across an aborted Step and delivers them once" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var client: std.http.Client = .{ .allocator = t.allocator, .io = t.io };
    defer client.deinit();
    var session = try Session.init(t.allocator, t.io, &client, .{ .base_url = "invalid://local", .api_key = "mock", .model = "mock" }, .{ .home = root, .user_home = root });
    defer session.deinit();

    const Observer = struct {
        ids: std.ArrayList([]const u8) = .empty,
        allocator: std.mem.Allocator,
        fn emit(ctx: *anyopaque, event: Event) !void {
            const observer: *@This() = @ptrCast(@alignCast(ctx));
            if (event == .background) try observer.ids.append(observer.allocator, try observer.allocator.dupe(u8, event.background.id));
        }
    };
    var observed: Observer = .{ .allocator = a };
    var pending: std.ArrayList(provider.Message) = .empty;
    defer pending.deinit(t.allocator);
    var step: StepDelivery = .{ .session = &session, .pending = &pending, .sink = .{ .ctx = &observed, .emit = Observer.emit } };

    _ = try session.inbox.enqueueBackground(t.allocator, t.io, "b1", .bash, .finished, true, "child result", false, 0, null);
    (try session.inbox.takeForWait(t.allocator, t.io, "b1", 1)).?.deinit(t.allocator);
    _ = try session.inbox.enqueueCompletion(t.allocator, t.io, "r1", .run, .finished, true, "inner Run", false, 0, null, null, 1, null);
    (try session.inbox.takeForWait(t.allocator, t.io, "r1", 2)).?.deinit(t.allocator);
    _ = try session.inbox.enqueueCompletion(t.allocator, t.io, "r2", .run, .finished, true, "outer Run", false, 0, null, null, 2, null);
    _ = try session.inbox.enqueueBackground(t.allocator, t.io, "b2", .bash, .finished, true, "uncommitted result", false, 0, null);
    (try session.inbox.takeForWait(t.allocator, t.io, "b2", 3)).?.deinit(t.allocator);
    session.inbox.discardAbortedWaits(t.allocator, t.io);

    const before = session.history.items.len;
    try step.beforeRequest();
    try step.beforeRequest();
    try t.expectEqual(before + 1, session.history.items.len);
    try t.expectEqualStrings("r2", session.history.items[before].background_id.?);
    try t.expectEqual(@as(usize, 3), observed.ids.items.len);
    for ([_][]const u8{ "r2", "b1", "r1" }, observed.ids.items) |expected, id| try t.expectEqualStrings(expected, id);

    const path = try std.fmt.allocPrint(a, "{s}/sessions/{s}.jsonl", .{ root, session.id });
    const data = try std.Io.Dir.cwd().readFileAlloc(t.io, path, a, .unlimited);
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    var delivery_count: usize = 0;
    while (lines.next()) |line| {
        const record = try std.json.parseFromSliceLeaky(session_log.Record, a, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (record.deliveries) |deliveries| {
            try t.expectEqual(@as(usize, 3), deliveries.len);
            for (observed.ids.items, deliveries, 0..) |id, delivery, i| {
                try t.expectEqualStrings(id, delivery.event.id);
                const via: @TypeOf(delivery.via) = if (i == 0) .insert else .wait;
                try t.expectEqual(via, delivery.via);
            }
            delivery_count += 1;
        }
    }
    try t.expectEqual(@as(usize, 1), delivery_count);
}
