const std = @import("std");
const Tools = @import("../tools.zig").Tools;
const process = @import("../tools/process.zig");
const redaction = @import("../sandbox/redaction.zig");
pub const timeout_ms = 30_000;
pub const Failure = struct { command: []const u8, exit_code: i32, output: []const u8 };

pub fn quote(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const escaped = try std.mem.replaceOwned(u8, a, text, "'", "'\\''");
    defer a.free(escaped);
    return std.fmt.allocPrint(a, "'{s}'", .{escaped});
}

pub fn run(t: *Tools, a: std.mem.Allocator, event: []const u8, commands: []const []const u8, paths: []const []const u8, status: []const u8, timeout: i64) !?Failure {
    if (commands.len == 0) return null;
    const cwd = try std.process.currentPathAlloc(t.io, a);
    const root = try @import("instructions.zig").projectRoot(t.io, a, cwd);
    var quoted: std.ArrayList(u8) = .empty;
    var files: std.ArrayList(u8) = .empty;
    for (paths, 0..) |path, i| {
        const relative = try std.fs.path.relative(a, cwd, t.environ, root, path);
        if (i > 0) {
            try quoted.append(a, ' ');
            try files.append(a, '\n');
        }
        try quoted.appendSlice(a, try quote(a, relative));
        try files.appendSlice(a, relative);
    }
    var env = if (t.environ) |e| try e.clone(a) else try process.inheritedEnvironment(a);
    defer env.deinit();
    try env.put("NIB_EVENT", event);
    try env.put("NIB_FILES", files.items);
    try env.put("NIB_TURN_STATUS", status);
    var cancel: std.atomic.Value(bool) = .init(false);
    const started: std.Io.Clock.Timestamp = .now(t.io, .awake);
    for (commands) |template| {
        const command = try std.mem.replaceOwned(u8, a, template, "{files}", quoted.items);
        const script = try std.fmt.allocPrint(a, "{s}\n{s}", .{ if (std.mem.eql(u8, event, "turn_end")) "exec >/dev/null 2>&1" else "exec 2>&1", command });
        const argv = try t.sandboxedArgv(a, &.{ "/bin/sh", "-c", script });
        const command_start: std.Io.Clock.Timestamp = .now(t.io, .awake);
        const remaining = if (std.mem.eql(u8, event, "turn_end")) timeout - @as(i64, @intCast(@max(started.untilNow(t.io).raw.toMilliseconds(), 0))) else timeout;
        if (remaining <= 0) return .{ .command = command, .exit_code = 124, .output = "timed out" };
        var code: i32 = 1;
        var output: []const u8 = "";
        if (process.run(a, t.io, .{ .spawn = .{ .argv = argv, .cwd = .{ .path = root }, .environ_map = &env, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }, .strip_api_key = if (t.cfg) |cfg| cfg.api_key_env else null, .cancel = &cancel, .timeout_ms = remaining, .max_output_bytes = std.math.maxInt(usize) })) |result| {
            code = if (result.stop != null) 124 else switch (result.term) {
                .exited => |value| value,
                else => 1,
            };
            output = result.output;
        } else |err| output = @errorName(err);
        const duration: u64 = @intCast(@max(command_start.untilNow(t.io).raw.toMilliseconds(), 0));
        if (t.background.log) |log| {
            const masked = if (std.mem.eql(u8, event, "after_edit")) try redaction.mask(a, command, .rendered) else null;
            try log.hook(t.io, a, event, masked orelse command, code, duration);
        }
        if (code != 0) return .{ .command = command, .exit_code = code, .output = output };
    }
    return null;
}

pub fn afterEdit(t: *Tools, gpa: std.mem.Allocator, tracker: *const @import("../tools/changes.zig").Tracker, outcome: *@import("../sandbox.zig").Outcome) !void {
    const cfg = t.cfg orelse return;
    if (tracker.entries.items.len == 0 or cfg.hooks.after_edit.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = try a.alloc([]const u8, tracker.entries.items.len);
    for (tracker.entries.items, paths) |entry, *path| path.* = entry.path;
    if (try run(t, a, "after_edit", cfg.hooks.after_edit, paths, "", timeout_ms)) |failure| {
        const safe: Failure = .{
            .command = (try redaction.mask(a, failure.command, .rendered)) orelse failure.command,
            .output = (try redaction.mask(a, failure.output, .plain)) orelse failure.output,
            .exit_code = failure.exit_code,
        };
        const hook = try std.json.Stringify.valueAlloc(gpa, .{ .hook = safe }, .{});
        errdefer gpa.free(hook);
        outcome.hook_notice = try std.fmt.allocPrint(gpa, "hook {s} · exit {d}", .{ safe.command, safe.exit_code });
        outcome.hook = hook;
    }
}

test "shell quoting preserves spaces quotes and unicode" {
    const a = std.testing.allocator;
    const value = try quote(a, "a b'你好");
    defer a.free(value);
    try std.testing.expectEqualStrings("'a b'\\''你好'", value);
}

pub const TurnJob = struct {
    session: *@import("../session.zig").Session,
    status: []const u8,
    notify: ?struct { ctx: *anyopaque, emit: *const fn (*anyopaque, std.mem.Allocator, []const u8) void } = null,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),

    pub fn start(s: *@import("../session.zig").Session, status: []const u8, notify: @FieldType(TurnJob, "notify")) !void {
        if (s.tools.depth != 0 or s.cfg.hooks.turn_end.len == 0) return;
        var i: usize = 0;
        while (i < s.hook_jobs.items.len) {
            const previous = s.hook_jobs.items[i];
            if (previous.done.load(.acquire)) {
                previous.thread.join();
                s.gpa.destroy(previous);
                _ = s.hook_jobs.swapRemove(i);
            } else i += 1;
        }
        const job = try s.gpa.create(TurnJob);
        errdefer s.gpa.destroy(job);
        job.* = .{ .session = s, .status = status, .notify = notify };
        try s.hook_jobs.append(s.gpa, job);
        errdefer _ = s.hook_jobs.pop();
        job.thread = try std.Thread.spawn(.{}, work, .{job});
    }

    fn work(job: *TurnJob) void {
        defer job.done.store(true, .release);
        const s = job.session;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const failure = run(&s.tools, a, "turn_end", s.cfg.hooks.turn_end, &.{}, job.status, timeout_ms) catch return;
        if (failure) |f| if (job.notify) |notify| {
            const notice = std.fmt.allocPrint(a, "hook turn_end · exit {d}", .{f.exit_code}) catch return;
            notify.emit(notify.ctx, s.gpa, notice);
        };
    }
};

test "hook failure payload and timeout" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var tools: Tools = .{ .io = t.io, .home = "/unused" };
    const failure = (try run(&tools, arena.allocator(), "after_edit", &.{"printf bad; exit 7"}, &.{}, "", 1000)).?;
    try t.expectEqual(@as(i32, 7), failure.exit_code);
    try t.expectEqualStrings("bad", failure.output);
    const payload = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .hook = failure }, .{});
    try t.expectEqualStrings("{\"hook\":{\"command\":\"printf bad; exit 7\",\"exit_code\":7,\"output\":\"bad\"}}", payload);
    const timeout = (try run(&tools, arena.allocator(), "after_edit", &.{"sleep 5"}, &.{}, "", 20)).?;
    try t.expectEqual(@as(i32, 124), timeout.exit_code);
}

test "after-edit batches both tracked paths into one failure payload" {
    const t = std.testing;
    var tools: Tools = .{ .io = t.io, .home = "/unused", .cfg = .{ .base_url = "", .api_key = "", .model = "mock", .sandbox = .{ .mode = .off }, .hooks = .{ .after_edit = &.{"exit 7 # {files}"} } } };
    var tracker: @import("../tools/changes.zig").Tracker = .{};
    defer tracker.discard(t.allocator);
    const cwd = try std.process.currentPathAlloc(t.io, t.allocator);
    defer t.allocator.free(cwd);
    const path = try std.fs.path.join(t.allocator, &.{ cwd, "first" });
    defer t.allocator.free(path);
    const other = try std.fs.path.join(t.allocator, &.{ cwd, "second" });
    defer t.allocator.free(other);
    try tracker.record(t.allocator, path, null, "a");
    try tracker.record(t.allocator, path, "a", "b");
    try tracker.record(t.allocator, other, null, "c");
    var outcome: @import("../sandbox.zig").Outcome = .{ .ok = true, .text = try t.allocator.dupe(u8, "undefined"), .logs = try t.allocator.dupe(u8, "") };
    defer outcome.deinit(t.allocator);
    try afterEdit(&tools, t.allocator, &tracker, &outcome);
    try t.expectEqualStrings("{\"hook\":{\"command\":\"exit 7 # 'first' 'second'\",\"exit_code\":7,\"output\":\"\"}}", outcome.hook);
}

test "after-edit masks a failed hook without changing the executed command" {
    const t = std.testing;
    const secret = redaction.test_openai;
    const command = "token='" ++ secret ++ "'; [ \"${#token}\" = " ++ std.fmt.comptimePrint("{d}", .{secret.len}) ++ " ] || exit 2; printf '%s' \"$token\"; exit 7";
    var tools: Tools = .{ .io = t.io, .home = "/unused", .cfg = .{ .base_url = "", .api_key = "", .model = "mock", .sandbox = .{ .mode = .off }, .hooks = .{ .after_edit = &.{command} } } };
    var tracker: @import("../tools/changes.zig").Tracker = .{};
    defer tracker.discard(t.allocator);
    const cwd = try std.process.currentPathAlloc(t.io, t.allocator);
    defer t.allocator.free(cwd);
    const path = try std.fs.path.join(t.allocator, &.{ cwd, "file" });
    defer t.allocator.free(path);
    try tracker.record(t.allocator, path, null, "edited");
    var outcome: @import("../sandbox.zig").Outcome = .{ .ok = true, .text = &.{}, .logs = &.{} };
    defer outcome.deinit(t.allocator);
    try afterEdit(&tools, t.allocator, &tracker, &outcome);
    const payload = try std.json.parseFromSlice(struct { hook: Failure }, t.allocator, outcome.hook, .{});
    defer payload.deinit();
    try t.expectEqual(@as(i32, 7), payload.value.hook.exit_code);
    try t.expectEqualStrings(redaction.marker, payload.value.hook.output);
    try t.expect(std.mem.indexOf(u8, payload.value.hook.command, "token='[REDACTED]'") != null);
    try t.expect(std.mem.indexOf(u8, outcome.hook_notice, "token='[REDACTED]'") != null);
}
