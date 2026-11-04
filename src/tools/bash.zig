const std = @import("std");
const sandbox = @import("../sandbox.zig");
const tools = @import("../tools.zig");
const Tools = tools.Tools;
const fail = tools.fail;
const process = @import("process.zig");
const policy = @import("policy.zig");

pub const foreground_progress_threshold_ms = 3000;

const Args = struct {
    command: []const u8,
    timeout_ms: ?i64 = null,
    background: bool = false,
    detached: bool = false,

    fn timeoutMs(a: Args) i64 {
        return a.timeout_ms orelse if (a.detached) @as(i64, 0) else 120_000;
    }

    fn validationError(a: Args) ?[]const u8 {
        if (a.detached and !a.background) return "detached requires background: true";
        if (a.timeoutMs() < 0) return "timeout_ms must not be negative";
        if (a.timeoutMs() == 0 and !a.detached) return "timeout_ms: 0 requires detached: true";
        return null;
    }
};

pub fn bash(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const a = std.json.parseFromSlice(Args, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ command: string, timeout_ms?: number, background?: boolean, detached?: boolean }}", .{});
    defer a.deinit();
    if (a.value.validationError()) |message| return fail(gpa, "{s}", .{message});

    if (t.race_paths) |race| {
        if (std.mem.indexOf(u8, a.value.command, race.parent_root) != null)
            return fail(gpa, "race branch bash cannot contain parent repository root {s}; use relative paths in the branch worktree {s}", .{ race.parent_root, race.worktree_root });
    }

    switch (policy.checkCredentials(a.value.command, t.codexHome())) {
        .allow => {},
        .deny => |why| return fail(gpa, "refused by nib: {s}", .{why}),
    }
    switch (policy.check(a.value.command, t.home)) {
        .allow => {},
        .deny => |why| return if (std.mem.eql(u8, why, policy.too_long))
            fail(gpa, "refused by nib: {s}", .{why})
        else
            fail(gpa, "refused by nib: {s}. If it is really needed, ask the user to run it.", .{why}),
    }

    if (a.value.background) {
        const result = t.background.start(t, gpa, .bash, args, a.value.command) catch |err| return switch (err) {
            error.BackgroundBashLimit => fail(gpa, "background bash limit is {d} running commands; retry after a background result arrives", .{@import("background.zig").Background.bash_limit}),
            else => err,
        };
        return .{ .ok = result };
    }
    return execute(t, gpa, a.value.command, a.value.timeoutMs(), &t.cancel, null);
}

pub fn executeBackground(t: *Tools, gpa: std.mem.Allocator, args: []const u8, cancel: *const std.atomic.Value(bool), progress: @import("../session/events.zig").Progress) !sandbox.ToolResult {
    const parsed = try std.json.parseFromSlice(Args, gpa, args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.validationError()) |message| return fail(gpa, "{s}", .{message});
    var value = progress;
    value.prompt = parsed.value.command;
    value.detached = parsed.value.detached;
    return execute(t, gpa, value.prompt, parsed.value.timeoutMs(), cancel, value);
}

fn execute(t: *Tools, gpa: std.mem.Allocator, command: []const u8, timeout_ms: i64, cancel: *const std.atomic.Value(bool), progress: ?@import("../session/events.zig").Progress) !sandbox.ToolResult {
    if (t.race_paths) |race| {
        if (std.mem.indexOf(u8, command, race.parent_root) != null)
            return fail(gpa, "race branch bash cannot contain parent repository root {s}; use relative paths in the branch worktree {s}", .{ race.parent_root, race.worktree_root });
    }
    var tracker: Tracker = .{ .t = t, .gpa = gpa, .command = command, .value = progress, .started = .now(t.io, .awake) };
    var state: @FieldType(@import("../session/events.zig").Progress, "state") = .failed;
    defer tracker.finish(state);
    tracker.tick();
    // In-shell redirect keeps stdout/stderr interleaving order.
    const script = try std.fmt.allocPrint(gpa, "exec 2>&1\n{s}", .{command});
    defer gpa.free(script);

    const result = process.run(gpa, t.io, .{ .spawn = .{
        .argv = &.{ "bash", "-c", script },
        .environ_map = t.environ,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }, .cancel = cancel, .timeout_ms = timeout_ms, .on_tick = .{ .ctx = &tracker, .emit = Tracker.observe }, .max_output_bytes = 16 * 1024 * 1024 }) catch |err| return switch (err) {
        error.OutputLimit => fail(gpa, "output exceeds 16 MiB; redirect output to a file", .{}),
        else => err,
    };
    const stdout = result.output;
    defer gpa.free(stdout);
    if (result.stop) |err| {
        state = if (err == error.TimedOut) .timed_out else .canceled;
        return switch (err) {
            error.TimedOut => fail(gpa, "timed out after {d} ms", .{timeout_ms}),
            error.Canceled => fail(gpa, "canceled", .{}),
        };
    }
    const code: ?u8 = switch (result.term) {
        .exited => |e| e,
        else => null,
    };
    state = if (code != null and code.? == 0) .done else .failed;
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .exit_code = code, .output = stdout }, .{}) };
}

const Tracker = struct {
    t: *Tools,
    gpa: std.mem.Allocator,
    command: []const u8,
    value: ?@import("../session/events.zig").Progress,
    started: std.Io.Clock.Timestamp,
    last_second: ?u64 = null,

    fn observe(ctx: *anyopaque) void {
        const tr: *Tracker = @ptrCast(@alignCast(ctx));
        tr.tick();
    }

    fn tick(tr: *Tracker) void {
        tr.tickAt(@intCast(@max(tr.started.untilNow(tr.t.io).raw.toMilliseconds(), 0)));
    }

    fn tickAt(tr: *Tracker, elapsed_ms: u64) void {
        if (tr.value == null) {
            if (elapsed_ms < foreground_progress_threshold_ms) return;
            const id = tr.t.progress.add(tr.gpa, tr.t.io, .bash, tr.command, tr.t.run_id, false) catch return;
            sandbox.tool_identity = .{ .id = id };
            tr.value = .{ .id = id, .kind = .bash, .prompt = tr.command, .run = tr.t.run_id };
        }
        var value = tr.value.?;
        value.elapsed_ms = elapsed_ms;
        const second = value.elapsed_ms / 1000;
        if (tr.last_second == second) return;
        tr.last_second = second;
        value.state = .working;
        tr.value = value;
        tr.t.progress.update(tr.gpa, tr.t.io, value) catch {};
    }

    fn finish(tr: *Tracker, state: @FieldType(@import("../session/events.zig").Progress, "state")) void {
        tr.tick();
        var value = tr.value orelse return;
        value.elapsed_ms = @intCast(@max(tr.started.untilNow(tr.t.io).raw.toMilliseconds(), 0));
        value.state = state;
        tr.value = value;
        tr.t.progress.update(tr.gpa, tr.t.io, value) catch {};
    }
};

const testing = std.testing;
const callTool = tools.callTool;
const freeResult = tools.freeResult;

test "bash merges stderr and reports exit code" {
    const r = try callTool("bash", "{\"command\":\"echo out; echo err >&2; exit 3\"}");
    defer freeResult(r);
    try testing.expectEqualStrings("{\"exit_code\":3,\"output\":\"out\\nerr\\n\"}", r.ok);
}

test "bash refuses commands denied by policy" {
    const r = try callTool("bash", "{\"command\":\"sudo true\"}");
    defer freeResult(r);
    try testing.expect(std.mem.startsWith(u8, r.err, "refused by nib: privileged"));
}

test "bash executes a 300-line Python heredoc" {
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(testing.allocator);
    try script.appendSlice(testing.allocator, "python3 - <<'EOF'\nx = 0\n");
    for (0..298) |_| try script.appendSlice(testing.allocator, "x += 1\n");
    try script.appendSlice(testing.allocator, "print(x)\nEOF\n");
    const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .command = script.items }, .{});
    defer testing.allocator.free(args);
    const r = try callTool("bash", args);
    defer freeResult(r);
    try testing.expectEqualStrings("{\"exit_code\":0,\"output\":\"298\\n\"}", r.ok);
}

test "bash rejects more than 256 shell words in the command portion" {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(testing.allocator);
    try command.appendSlice(testing.allocator, "echo");
    for (0..256) |_| try command.appendSlice(testing.allocator, " x");
    const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .command = command.items }, .{});
    defer testing.allocator.free(args);
    const r = try callTool("bash", args);
    defer freeResult(r);
    try testing.expectEqualStrings("refused by nib: " ++ policy.too_long, r.err);
    try testing.expectEqualStrings("refused by nib: command portion has more than 256 shell words; write long scripts to a file with tools.write and run that file", r.err);
}

test "bash refuses credential references inside heredoc bodies" {
    const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .command = "python3 - <<'EOF'\nprint('~/.codex/auth.json')\nEOF\n" }, .{});
    defer testing.allocator.free(args);
    const r = try callTool("bash", args);
    defer freeResult(r);
    try testing.expectEqualStrings("refused by nib: access to Codex credentials", r.err);
}

test "bash timeout kills the whole process group" {
    const r = try callTool("bash", "{\"command\":\"(sleep 7.3 &) ; sleep 7.3\",\"timeout_ms\":200}");
    defer freeResult(r);
    try testing.expectEqualStrings("timed out after 200 ms", r.err);
    // SIGKILL is asynchronous: give the orphaned sleep a moment to die.
    for (0..20) |_| {
        const left = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "pgrep", "-f", "sleep 7.3" } });
        defer testing.allocator.free(left.stdout);
        defer testing.allocator.free(left.stderr);
        if (left.stdout.len == 0) return;
        try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(50), .clock = .awake }, testing.io);
    }
    return error.ProcessGroupSurvived;
}

test "bash cancel" {
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody", .cancel = .init(true) };
    const r = Tools.call(&t, testing.allocator, "bash", "{\"command\":\"sleep 5\"}");
    defer freeResult(r);
    try testing.expectEqualStrings("canceled", r.err);
}

test "bash timeout" {
    const r = try callTool("bash", "{\"command\":\"sleep 5\",\"timeout_ms\":100}");
    defer freeResult(r);
    try testing.expectEqualStrings("timed out after 100 ms", r.err);
}

test "bash timeout still applies after output pipes close" {
    const result = try callTool("bash", "{\"command\":\"exec 1>&- 2>&-; sleep 5\",\"timeout_ms\":80}");
    defer freeResult(result);
    try testing.expectEqualStrings("timed out after 80 ms", result.err);
}

test "bash receives ordinary environment without API keys" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("NIB_API_KEY", "fictional-secret");
    try env.put("NIB_TEST_ORDINARY", "kept");
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody", .environ = &env };
    const result = Tools.call(&t, testing.allocator, "bash", "{\"command\":\"printf '%s:%s' \\\"${NIB_API_KEY-unset}\\\" \\\"$NIB_TEST_ORDINARY\\\"\"}");
    defer freeResult(result);
    try testing.expectEqualStrings("{\"exit_code\":0,\"output\":\"unset:kept\"}", result.ok);
}

test "bash returns output up to 16 MiB verbatim" {
    const r = try callTool("bash", "{\"command\":\"head -c 16777216 /dev/zero | tr '\\\\0' x\"}");
    defer freeResult(r);
    const parsed = try std.json.parseFromSlice(struct { exit_code: u8, output: []const u8 }, testing.allocator, r.ok, .{});
    defer parsed.deinit();
    try testing.expectEqual(0, parsed.value.exit_code);
    try testing.expectEqual(16 * 1024 * 1024, parsed.value.output.len);
    for (parsed.value.output) |byte| try testing.expectEqual(@as(u8, 'x'), byte);
}

test "bash rejects output over 16 MiB and kills the process group" {
    const start = std.Io.Clock.awake.now(testing.io);
    const r = try callTool("bash", "{\"command\":\"head -c 16777217 /dev/zero; sleep 30\"}");
    defer freeResult(r);
    try testing.expectEqualStrings("output exceeds 16 MiB; redirect output to a file", r.err);
    try testing.expect(start.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds() < 5000);
}

test "bash does not wait for background jobs inheriting stdout or stderr" {
    const start = std.Io.Clock.awake.now(testing.io);
    const r = try callTool("bash", "{\"command\":\"sleep 8 & echo started; echo error >&2; exit 3\",\"timeout_ms\":2000}");
    defer freeResult(r);
    try testing.expectEqualStrings("{\"exit_code\":3,\"output\":\"started\\nerror\\n\"}", r.ok);
    try testing.expect(start.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds() < 1000);
}

test "bash returns when a silent background job holds stdout" {
    const r = try callTool("bash", "{\"command\":\"sleep 8 & exit 0\",\"timeout_ms\":1000}");
    defer freeResult(r);
    try testing.expectEqualStrings("{\"exit_code\":0,\"output\":\"\"}", r.ok);
}

test "foreground bash allocates only at the visibility threshold and advances once per second" {
    var t: Tools = .{ .io = testing.io, .home = "/unused", .run_id = 3 };
    defer t.progress.deinit(testing.allocator);
    var tracker: Tracker = .{ .t = &t, .gpa = testing.allocator, .command = "slow", .value = null, .started = .now(testing.io, .awake) };
    tracker.tickAt(2999);
    try testing.expectEqual(@as(usize, 0), t.progress.slots.items.len);
    try testing.expectEqual(@as(u64, 1), t.progress.next_bash_id);
    tracker.tickAt(3000);
    const value = t.progress.slots.items[0].value;
    try testing.expectEqualStrings("b1", value.id);
    try testing.expectEqual(.bash, value.kind);
    try testing.expect(!value.background);
    try testing.expectEqual(@as(usize, 3), value.run);
    try testing.expectEqual(@as(u64, 3000), value.elapsed_ms);
    tracker.tickAt(3999);
    try testing.expectEqual(@as(u64, 3000), t.progress.slots.items[0].value.elapsed_ms);
    tracker.tickAt(4000);
    try testing.expectEqual(@as(u64, 4000), t.progress.slots.items[0].value.elapsed_ms);
    try testing.expectEqual(@as(u64, 2), t.progress.next_bash_id);
    tracker.finish(.done);
    try testing.expectEqual(.done, t.progress.slots.items[0].value.state);
}

test "foreground bash logs the visible call ID without changing its result" {
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody", .run_id = 1 };
    defer t.progress.deinit(testing.allocator);
    var timing: sandbox.RunTiming = .init(testing.io, .now(testing.io, .awake));
    var host = t.host();
    host.timing = &timing;
    const result = try sandbox.eval(testing.allocator, testing.io, "await tools.bash({command: 'true'}); await tools.bash({command: 'sleep 3.2; exit 7'})", .{}, host, null);
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expectEqualStrings("{\"exit_code\":7,\"output\":\"\"}", result.text);
    try testing.expectEqual(@as(usize, 2), timing.count);
    try testing.expect(timing.entries[0].id == null);
    try testing.expectEqualStrings("b1", timing.entries[1].id.?);
    try testing.expectEqual(@as(?bool, false), timing.entries[1].background);
    try testing.expectEqual(@as(usize, 1), t.progress.slots.items.len);
    try testing.expectEqual(.failed, t.progress.slots.items[0].value.state);
    try testing.expect(t.progress.slots.items[0].value.elapsed_ms >= 3000);
    t.progress.clear(testing.allocator);
    try testing.expectEqualStrings("b1", timing.entries[1].id.?);
}

test "bash validates detached and zero timeout before starting" {
    const cases = .{
        .{ "{\"command\":\"true\",\"detached\":true}", "detached requires background: true" },
        .{ "{\"command\":\"true\",\"timeout_ms\":0}", "timeout_ms: 0 requires detached: true" },
        .{ "{\"command\":\"true\",\"background\":true,\"timeout_ms\":0}", "timeout_ms: 0 requires detached: true" },
        .{ "{\"command\":\"true\",\"background\":true,\"detached\":true,\"timeout_ms\":-1}", "timeout_ms must not be negative" },
    };
    inline for (cases) |case| {
        const result = try callTool("bash", case[0]);
        defer freeResult(result);
        try testing.expectEqualStrings(case[1], result.err);
    }
}

test "bash detached timeout defaults and overrides" {
    try testing.expectEqual(@as(i64, 120_000), (Args{ .command = "true" }).timeoutMs());
    try testing.expectEqual(@as(i64, 120_000), (Args{ .command = "true", .background = true }).timeoutMs());
    const detached: Args = .{ .command = "true", .background = true, .detached = true };
    try testing.expectEqual(@as(i64, 0), detached.timeoutMs());
    try testing.expect(detached.validationError() == null);
    const explicit: Args = .{ .command = "true", .background = true, .detached = true, .timeout_ms = 25 };
    try testing.expectEqual(@as(i64, 25), explicit.timeoutMs());
    try testing.expect(explicit.validationError() == null);
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody" };
    defer t.progress.deinit(testing.allocator);
    const progress = try t.progress.add(testing.allocator, testing.io, .bash, "sleep 5", 1, true);
    var cancel: std.atomic.Value(bool) = .init(false);
    const result = try executeBackground(&t, testing.allocator, "{\"command\":\"sleep 5\",\"background\":true,\"detached\":true,\"timeout_ms\":25}", &cancel, .{ .id = progress, .kind = .bash, .background = true, .prompt = "" });
    defer freeResult(result);
    try testing.expectEqualStrings("timed out after 25 ms", result.err);
}

test "race bash rejects parent root text before foreground or background execution" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var t: Tools = .{ .io = testing.io, .home = root, .race_paths = .{ .parent_root = root, .worktree_root = "/branch" } };
    for ([_]bool{ false, true }) |background| {
        const command = try std.fmt.allocPrint(testing.allocator, "touch {s}/must-not-exist", .{root});
        defer testing.allocator.free(command);
        const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .command = command, .background = background }, .{});
        defer testing.allocator.free(args);
        const result = Tools.call(&t, testing.allocator, "bash", args);
        defer freeResult(result);
        try testing.expect(std.mem.indexOf(u8, result.err, "use relative paths") != null);
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "must-not-exist", .{}));
    }
    const allowed = Tools.call(&t, testing.allocator, "bash", "{\"command\":\"printf branch\"}");
    defer freeResult(allowed);
    try testing.expectEqualStrings("{\"exit_code\":0,\"output\":\"branch\"}", allowed.ok);
}
