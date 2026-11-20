const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const Event = tui.Event;
const Session = @import("../session.zig").Session;
const SessionEvent = @import("../session.zig").Event;
const ModelActivity = @import("../session.zig").ModelActivity;
const Sink = @import("../session.zig").Sink;
const ChangeText = @import("transcript.zig").ChangeText;

/// Posts `.tick` while `busy` so the spinner and timer advance without input.
pub const Ticker = struct {
    io: std.Io,
    loop: *vaxis.Loop(Event),
    busy: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),

    pub fn work(t: *Ticker) void {
        while (!t.stop.load(.acquire)) {
            std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(@import("frames.zig").Frames.interval_ms), .clock = .awake }, t.io) catch return;
            if (t.busy.load(.acquire)) t.loop.postEvent(.tick) catch {};
        }
    }
};

/// A Turn or `/compact` on its own thread. Only Session.enqueue is shared with the UI.
pub const Turn = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    text: []const u8,
    /// Owned copies; empty for compaction and queued text.
    images: []const @import("../image.zig").Image = &.{},
    loop: *vaxis.Loop(Event),
    cancel: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    compact: bool = false,
    failure_stage: @import("../tools/changes.zig").Recovery.Reason = .model,
    last_script_activity: ?std.Io.Clock.Timestamp = null,
    last_model_activity: ?std.Io.Clock.Timestamp = null,

    pub fn spawn(gpa: std.mem.Allocator, session: *Session, loop: *vaxis.Loop(Event), text: []const u8, compact: bool) !*Turn {
        return spawnWithImages(gpa, session, loop, text, &.{}, compact);
    }

    /// Copies `images`; the caller keeps ownership of its slice.
    pub fn spawnWithImages(gpa: std.mem.Allocator, session: *Session, loop: *vaxis.Loop(Event), text: []const u8, images: []const @import("../image.zig").Image, compact: bool) !*Turn {
        const t = try gpa.create(Turn);
        errdefer gpa.destroy(t);
        const copies = try gpa.alloc(@import("../image.zig").Image, images.len);
        var copied: usize = 0;
        errdefer {
            for (copies[0..copied]) |item| item.deinit(gpa);
            gpa.free(copies);
        }
        for (images, copies) |item, *copy| {
            copy.* = try item.clone(gpa);
            copied += 1;
        }
        t.* = .{ .gpa = gpa, .session = session, .text = text, .images = copies, .loop = loop, .compact = compact };
        t.thread = try std.Thread.spawn(.{}, work, .{ t, compact });
        return t;
    }

    fn hookNotice(ctx: *anyopaque, gpa: std.mem.Allocator, message: []const u8) void {
        const loop: *vaxis.Loop(Event) = @ptrCast(@alignCast(ctx));
        const copy = gpa.dupe(u8, message) catch return;
        const posted = loop.tryPostEvent(.{ .notice = copy }) catch false;
        if (!posted) gpa.free(copy);
    }

    pub fn work(t: *Turn, compact: bool) void {
        var status: []const u8 = "completed";
        defer if (!compact) @import("../session/hooks.zig").TurnJob.start(t.session, status, .{ .ctx = t.loop, .emit = hookNotice }) catch {};

        var detail: ?[]u8 = null;
        t.execute(compact, &detail) catch |err| {
            status = if (t.cancel.load(.acquire)) "cancelled" else "failed";
            const msg = detail orelse (t.gpa.dupe(u8, @errorName(err)) catch return);
            t.loop.postEvent(.{ .failed = .{ .message = msg, .reason = @import("../tools/changes.zig").Recovery.classify(err, t.cancel.load(.acquire), t.failure_stage) } }) catch t.gpa.free(msg);
            return;
        };
        t.loop.postEvent(.done) catch {};
    }

    fn execute(t: *Turn, compact: bool, detail: *?[]u8) !void {
        t.session.tools.recovery.clear(t.gpa, t.session.io);
        const sink: Sink = .{ .ctx = t, .emit = emit, .onModelActivity = modelActivity, .onToolActivity = toolActivity, .onUserInserted = userInserted };
        if (compact) {
            errdefer t.session.tools.background.stop(t.gpa);
            _ = try t.session.compactWithFocus(t.text, sink, &t.cancel, detail);
        } else try t.session.turnWithImages(t.text, t.images, sink, &t.cancel, detail);
    }

    pub fn userInserted(ctx: *anyopaque, id: u64) !void {
        const t: *Turn = @ptrCast(@alignCast(ctx));
        try t.loop.postEvent(.{ .user_inserted = id });
    }

    pub fn toolActivity(ctx: *anyopaque, name: []const u8) !void {
        const t: *Turn = @ptrCast(@alignCast(ctx));
        try t.loop.postEvent(.{ .tool_activity = name });
    }

    pub fn modelActivity(ctx: *anyopaque, state: ModelActivity) !void {
        const t: *Turn = @ptrCast(@alignCast(ctx));
        try t.modelActivityAt(state, .now(t.session.io, .awake));
    }

    pub fn modelActivityAt(t: *Turn, state: ModelActivity, at: std.Io.Clock.Timestamp) !void {
        if (state == .started) {
            t.failure_stage = .model;
            t.last_script_activity = null;
        }
        if (state == .script) {
            if (t.last_script_activity) |last| {
                if (last.durationTo(at).raw.toMilliseconds() < 1000) return;
            }
            t.last_script_activity = at;
        }
        if (state == .data) if (t.last_model_activity) |last| {
            if (last.durationTo(at).raw.toMilliseconds() < 1000) return;
        };
        try t.loop.postEvent(.{ .model_activity = .{ .state = state, .at = at } });
        t.last_model_activity = if (state == .finished) null else at;
    }

    pub fn emit(ctx: *anyopaque, ev: SessionEvent) !void {
        const t: *Turn = @ptrCast(@alignCast(ctx));
        const gpa = t.gpa;
        if (ev == .run_start) t.failure_stage = .tool;
        const event: Event = switch (ev) {
            .step => |s| .{ .step = .{ .n = s.n, .effort = try gpa.dupe(u8, s.effort) } },
            .delta => |d| .{ .delta = .{ .kind = d.kind, .text = try gpa.dupe(u8, d.text), .step = t.session.steps + 1 } },
            .run_start => |code| .{ .run_start = .{ .code = try gpa.dupe(u8, code), .step = t.session.steps } },
            .run_end => |r| blk: {
                const output = try gpa.dupe(u8, r.output);
                errdefer gpa.free(output);
                var changes = try ChangeText.init(gpa, r.changes);
                errdefer changes.deinit(gpa);
                const background_id = if (r.background_id) |id| try gpa.dupe(u8, id) else null;
                errdefer if (background_id) |id| gpa.free(id);
                break :blk .{ .run_end = .{ .background_id = background_id, .ok = r.ok, .output = output, .changes = changes, .tool_summary = if (r.tool_summary) |summary| try summary.clone(gpa) else null } };
            },
            .retry => |r| .{ .retry = try std.fmt.allocPrint(gpa, "attempt {d}/{d} · {s}", .{ r.attempt + 1, @import("../provider.zig").max_attempts, @import("status.zig").retryReason(r.reason) }) },
            .notice => |m| .{ .notice = try gpa.dupe(u8, m) },
            .usage => |u| .{ .usage = .{ .tokens = u, .context = t.session.context_tokens, .steps = t.session.steps } },
            .progress => |p| .{ .progress = try p.clone(gpa) },
            .background => |b| blk: {
                const id = try gpa.dupe(u8, b.id);
                errdefer gpa.free(id);
                var changes: ChangeText = if (b.completion) |value| try .init(gpa, value.changes) else .{};
                errdefer changes.deinit(gpa);
                const summary: ?@import("../session/tool_summary.zig").Summary = if (b.completion) |value| try .init(gpa, value.calls, value.run_index, value.calls_omitted) else null;
                errdefer if (summary) |value| value.deinit(gpa);
                const hook_notice = if (b.completion) |value| (if (value.hook_notice) |notice| try gpa.dupe(u8, notice) else null) else null;
                errdefer if (hook_notice) |notice| gpa.free(notice);
                break :blk .{ .background = .{ .hook_notice = hook_notice, .id = id, .kind = b.kind, .state = b.state, .ok = b.ok, .result = if (b.completion) |value| try gpa.dupe(u8, value.output) else if (b.result) |result| try gpa.dupe(u8, result) else null, .changes = changes, .tool_summary = summary } };
            },
            .turn_end => |summary| .{ .turn_end = summary },
        };
        errdefer event.deinit(gpa);
        try t.loop.postEvent(event);
    }

    pub fn finish(t: *Turn) void {
        t.thread.join();
        for (t.images) |item| item.deinit(t.gpa);
        t.gpa.free(t.images);
        t.gpa.free(t.text);
        t.gpa.destroy(t);
    }
};
