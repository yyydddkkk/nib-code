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
    cwd: ?[]const u8 = null,
    timeout_ms: ?i64 = null,
    background: bool = false,
    detached: bool = false,

    fn timeoutMs(a: Args) i64 {
        return a.timeout_ms orelse if (a.detached) @as(i64, 0) else 1_800_000;
    }

    fn validationError(a: Args) ?[]const u8 {
        if (a.cwd) |path| if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return "cwd must be a non-empty path without NUL bytes";
        if (a.detached and !a.background) return "detached requires background: true";
        if (a.timeoutMs() < 0) return "timeout_ms must not be negative";
        if (a.timeoutMs() == 0 and !a.detached) return "timeout_ms: 0 requires detached: true";
        return null;
    }
};

const WorkingDir = struct {
    path: [:0]const u8,
    dir: ?std.Io.Dir = null,

    fn open(t: *Tools, gpa: std.mem.Allocator, path: ?[]const u8) !WorkingDir {
        const requested = path orelse return .{ .path = try std.process.currentPathAlloc(t.io, gpa) };
        if (policy.checkCredentials(requested, t.codexHome(), t.data_home) == .deny) return error.CredentialAccessDenied;
        const dir = try std.Io.Dir.cwd().openDir(t.io, requested, .{});
        errdefer dir.close(t.io);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = buf[0..try dir.realPath(t.io, &buf)];
        if (policy.checkCredentials(real, t.codexHome(), t.data_home) == .deny) return error.CredentialAccessDenied;
        const auth_path = try std.fs.path.join(gpa, &.{ real, "auth.json" });
        defer gpa.free(auth_path);
        const canonical_auth = try tools.normalizedPath(t.io, gpa, auth_path);
        defer gpa.free(canonical_auth);
        try t.checkCredentialPath(gpa, canonical_auth);
        return .{ .path = try gpa.dupeSentinel(u8, real, 0), .dir = dir };
    }

    fn close(cwd: WorkingDir, t: *Tools, gpa: std.mem.Allocator) void {
        if (cwd.dir) |dir| dir.close(t.io);
        gpa.free(cwd.path);
    }

    fn failure(gpa: std.mem.Allocator, path: ?[]const u8, err: anyerror) !sandbox.ToolResult {
        return fail(gpa, "cannot use cwd {f}: {s}", .{ std.json.fmt(path orelse ".", .{}), @errorName(err) });
    }
};

pub fn bash(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    if (@import("builtin").os.tag == .windows) return fail(gpa, "tools.bash is unavailable in the Windows CLI preview", .{});
    const expected = "expected {{ command: string, cwd?: string, timeout_ms?: number, background?: boolean, detached?: boolean }}";
    const a = std.json.parseFromSlice(Args, gpa, args, .{}) catch |err| return switch (err) {
        error.UnknownField => fail(gpa, "unknown bash parameter; " ++ expected, .{}),
        else => fail(gpa, expected, .{}),
    };
    defer a.deinit();
    if (a.value.validationError()) |message| return fail(gpa, "{s}", .{message});

    switch (policy.checkCredentials(a.value.command, t.codexHome(), t.data_home)) {
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

    const cwd = WorkingDir.open(t, gpa, a.value.cwd) catch |err| return WorkingDir.failure(gpa, a.value.cwd, err);
    defer cwd.close(t, gpa);
    if (a.value.background) {
        const result = t.background.start(t, gpa, .bash, args, a.value.command) catch |err| return switch (err) {
            error.BackgroundBashLimit => fail(gpa, "background bash limit is {d} running commands; retry after a background result arrives", .{@import("background.zig").Background.bash_limit}),
            else => err,
        };
        return .{ .ok = result };
    }
    return execute(t, gpa, a.value.command, cwd, a.value.timeoutMs(), t.cancelFlag(), null, null, null);
}

pub const Status = struct {
    exit_code: ?u8,
    elapsed_ms: ?u64 = null,
};

pub fn executeBackground(t: *Tools, gpa: std.mem.Allocator, args: []const u8, cancel: *const std.atomic.Value(bool), progress: @import("../session/events.zig").Progress, execution: ?*@import("../sandbox/timing.zig").Execution, status: ?*?Status) !sandbox.ToolResult {
    const parsed = try std.json.parseFromSlice(Args, gpa, args, .{});
    defer parsed.deinit();
    if (parsed.value.validationError()) |message| return fail(gpa, "{s}", .{message});
    var value = progress;
    value.prompt = parsed.value.command;
    value.detached = parsed.value.detached;
    const cwd = WorkingDir.open(t, gpa, parsed.value.cwd) catch |err| return WorkingDir.failure(gpa, parsed.value.cwd, err);
    defer cwd.close(t, gpa);
    return execute(t, gpa, value.prompt, cwd, parsed.value.timeoutMs(), cancel, value, execution, status);
}

fn execute(t: *Tools, gpa: std.mem.Allocator, command: []const u8, cwd: WorkingDir, timeout_ms: i64, cancel: *const std.atomic.Value(bool), progress: ?@import("../session/events.zig").Progress, execution: ?*@import("../sandbox/timing.zig").Execution, status: ?*?Status) !sandbox.ToolResult {
    const id = if (progress) |value| value.id else try t.progress.reserveBash(gpa, t.io);
    sandbox.tool_identity = .{ .id = id, .background = progress != null };
    var active: @import("bash/registry.zig").Command = .{ .id = id, .run = if (progress) |value| value.run else t.runId(), .command = command, .cwd = cwd.path, .detached = if (progress) |value| value.detached else false, .started = .now(t.io, .awake) };
    try t.bash_commands.start(t, gpa, &active);
    var registered = true;
    defer {
        if (registered) _ = t.bash_commands.finish(t, gpa, &active);
    }
    var tracker: Tracker = .{ .t = t, .gpa = gpa, .command = command, .id = id, .value = progress, .started = active.started, .parent_cancel = cancel, .command_cancel = &active.cancel };
    if (progress != null) t.background.beginTask(t.io, id, timeout_ms);
    var state: @FieldType(@import("../session/events.zig").Progress, "state") = .failed;
    defer tracker.finish(state);
    tracker.tick();
    // In-shell redirect keeps stdout/stderr interleaving order.
    const script = try std.fmt.allocPrint(gpa, "exec 2>&1\n{s}", .{command});
    defer gpa.free(script);

    t.recovery.noteBash(t.io);
    var launch: std.heap.ArenaAllocator = .init(gpa);
    defer launch.deinit();
    const argv = try t.sandboxedArgv(launch.allocator(), &.{ "bash", "-c", script });
    const executed = process.run(gpa, t.io, .{ .spawn = .{
        .argv = argv,
        .cwd = if (cwd.dir) |dir| .{ .dir = dir } else .inherit,
        .environ_map = t.environ,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }, .strip_api_key = if (t.cfg) |cfg| cfg.api_key_env else null, .execution = execution, .cancel = &active.cancel, .timeout_ms = timeout_ms, .on_tick = .{ .ctx = &tracker, .emit = Tracker.observe }, .on_line = .{ .ctx = &tracker, .emit = Tracker.line }, .max_output_bytes = 16 * 1024 * 1024 });
    defer {
        if (executed) |result| gpa.free(result.output) else |_| {}
    }
    const superseded_by = t.bash_commands.finish(t, gpa, &active);
    registered = false;
    if (superseded_by) |new_id| {
        tracker.replaced(new_id);
        state = .done;
        return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .superseded_by = new_id }, .{}) };
    }
    const result = executed catch |err| return switch (err) {
        error.OutputLimit => fail(gpa, "output exceeds 16 MiB; redirect output to a file", .{}),
        else => err,
    };
    const stdout = result.output;
    if (result.stop) |err| {
        state = if (err == error.TimedOut) .timed_out else .canceled;
        return switch (err) {
            error.TimedOut => blk: {
                const elapsed = tracker.elapsedMs();
                const json = try std.json.Stringify.valueAlloc(gpa, .{
                    .timed_out = true,
                    .elapsed_ms = elapsed,
                    .exit_code = @as(?u8, null),
                    .output = stdout,
                }, .{});
                if (status) |out| out.* = .{ .exit_code = null, .elapsed_ms = elapsed };
                break :blk .{ .ok = json };
            },
            error.Canceled => fail(gpa, "canceled", .{}),
        };
    }
    const code: ?u8 = switch (result.term) {
        .exited => |e| e,
        else => null,
    };
    tracker.exit_code = code;
    state = if (code != null and code.? == 0) .done else .failed;
    const json = try std.json.Stringify.valueAlloc(gpa, .{ .exit_code = code, .output = stdout }, .{});
    if (status) |out| out.* = .{ .exit_code = code };
    return .{ .ok = json };
}

const Tracker = struct {
    t: *Tools,
    gpa: std.mem.Allocator,
    command: []const u8,
    id: ?[]const u8 = null,
    parent_cancel: ?*const std.atomic.Value(bool) = null,
    command_cancel: ?*std.atomic.Value(bool) = null,
    value: ?@import("../session/events.zig").Progress,
    started: std.Io.Clock.Timestamp,
    last_second: ?u64 = null,
    output_bytes: u64 = 0,
    exit_code: ?u8 = null,

    fn line(ctx: *anyopaque, bytes: []const u8) void {
        const tr: *Tracker = @ptrCast(@alignCast(ctx));
        tr.output_bytes += bytes.len + 1;
        tr.tick();
    }

    fn observe(ctx: *anyopaque) void {
        const tr: *Tracker = @ptrCast(@alignCast(ctx));
        if (tr.parent_cancel) |parent| if (parent.load(.acquire)) tr.command_cancel.?.store(true, .release);
        tr.tick();
    }

    fn elapsedMs(tr: *const Tracker) u64 {
        return @intCast(@max(tr.started.untilNow(tr.t.io).raw.toMilliseconds(), 0));
    }

    fn tick(tr: *Tracker) void {
        tr.tickAt(tr.elapsedMs());
    }

    fn tickAt(tr: *Tracker, elapsed_ms: u64) void {
        if (tr.value == null) {
            if (elapsed_ms < foreground_progress_threshold_ms) return;
            const id = tr.id orelse (tr.t.progress.add(tr.gpa, tr.t.io, .bash, tr.command, tr.t.runId(), false) catch return);
            if (tr.id != null) tr.t.progress.show(tr.gpa, tr.t.io, .{ .id = id, .kind = .bash, .prompt = tr.command, .run = tr.t.runId() }) catch return;
            sandbox.tool_identity = .{ .id = id };
            tr.value = .{ .id = id, .kind = .bash, .prompt = tr.command, .run = tr.t.runId() };
        }
        var value = tr.value.?;
        value.elapsed_ms = elapsed_ms;
        value.output_bytes = tr.output_bytes;
        const second = value.elapsed_ms / 1000;
        if (tr.last_second == second) return;
        tr.last_second = second;
        value.state = .working;
        tr.value = value;
        tr.t.progress.update(tr.gpa, tr.t.io, value) catch {};
    }

    fn replaced(tr: *Tracker, id: []const u8) void {
        if (tr.value == null) tr.tickAt(foreground_progress_threshold_ms);
        if (tr.value) |*value| value.superseded_by = id;
    }

    fn finish(tr: *Tracker, state: @FieldType(@import("../session/events.zig").Progress, "state")) void {
        if (tr.value == null) tr.tickAt(foreground_progress_threshold_ms);
        var value = tr.value orelse return;
        value.elapsed_ms = tr.elapsedMs();
        value.state = state;
        value.exit_code = tr.exit_code;
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

test "bash rejects unknown options and invalid working directories before launching" {
    const cases = .{
        .{ "{\"command\":\"true\",\"cwwd\":\"/tmp\"}", "unknown bash parameter" },
        .{ "{\"command\":\"true\",\"cwd\":\"\"}", "cwd must be a non-empty path" },
        .{ "{\"command\":\"true\",\"cwd\":\"/tmp\\u0000ignored\"}", "cwd must be a non-empty path" },
        .{ "{\"command\":\"true\",\"cwd\":\"build.zig\"}", "cannot use cwd \"build.zig\": NotDir" },
        .{ "{\"command\":\"true\",\"cwd\":\"missing-directory\",\"background\":true}", "cannot use cwd \"missing-directory\": FileNotFound" },
        .{ "{\"command\":\"true\",\"cwd\":\".codex\"}", "cannot use cwd \".codex\": CredentialAccessDenied" },
    };
    inline for (cases) |case| {
        const result = try callTool("bash", case[0]);
        defer freeResult(result);
        try testing.expectStringStartsWith(result.err, case[1]);
    }
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
    try expectTimeout(r, 200, "");
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
    defer t.progress.deinit(testing.allocator);
    const r = Tools.call(&t, testing.allocator, "bash", "{\"command\":\"sleep 5\"}");
    defer freeResult(r);
    try testing.expectEqualStrings("canceled", r.err);
}

fn expectTimeout(result: sandbox.ToolResult, timeout_ms: u64, output: []const u8) !void {
    try testing.expect(result == .ok);
    const parsed = try std.json.parseFromSlice(struct { timed_out: bool, elapsed_ms: u64, exit_code: ?u8, output: []const u8 }, testing.allocator, result.ok, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.timed_out);
    try testing.expect(parsed.value.elapsed_ms >= timeout_ms);
    try testing.expectEqual(null, parsed.value.exit_code);
    try testing.expectEqualStrings(output, parsed.value.output);
}

test "bash timeout returns captured stdout and stderr" {
    const r = try callTool("bash", "{\"command\":\"echo before; printf diagnostic >&2; sleep 5; echo after\",\"timeout_ms\":250}");
    defer freeResult(r);
    try expectTimeout(r, 250, "before\ndiagnostic");
}

test "bash timeout still applies after output pipes close" {
    const result = try callTool("bash", "{\"command\":\"exec 1>&- 2>&-; sleep 5\",\"timeout_ms\":80}");
    defer freeResult(result);
    try expectTimeout(result, 80, "");
}

test "bash receives ordinary environment without API keys" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("NIB_API_KEY", "fictional-secret");
    try env.put("NIB_TEST_ORDINARY", "kept");
    var t: Tools = .{ .io = testing.io, .home = "/home/nobody", .environ = &env };
    defer t.progress.deinit(testing.allocator);
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

test "bash returns once the shell exits although detached daemons keep the output pipe" {
    const prelude = "sd() { python3 -c 'import os,sys;os.setsid();os.execvp(sys.argv[1],sys.argv[1:])' \"$@\"; }; export -f sd; ";
    const bodies = [_][]const u8{
        "sd sh -c 'sleep 29.137' & echo one",
        "bash -c 'sd sleep 29.137 &'; echo one",
        "sd sh -c 'sleep 29.137 >/dev/null' 2>&1 & echo one",
        "(sd sleep 29.137 >/dev/null </dev/null &) ; echo one",
        "sd sh -c 'exec sleep 29.137 >&2' & echo one",
    };
    var cases: [bodies.len][]u8 = undefined;
    for (bodies, 0..) |body, i| cases[i] = try std.mem.concat(testing.allocator, u8, &.{ prelude, body });
    defer for (cases) |c| testing.allocator.free(c);
    for (cases) |command| {
        const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .command = command, .timeout_ms = 10000 }, .{});
        defer testing.allocator.free(args);
        const start = std.Io.Clock.awake.now(testing.io);
        const r = try callTool("bash", args);
        defer freeResult(r);
        try testing.expectEqualStrings("{\"exit_code\":0,\"output\":\"one\\n\"}", r.ok);
        try testing.expect(start.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds() < 3000);
    }
    const left = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "pkill", "-f", "sleep 29.137" } });
    testing.allocator.free(left.stdout);
    testing.allocator.free(left.stderr);
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

test "foreground bash reports terminal command facts even for short commands" {
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
    try testing.expectEqualStrings("b1", timing.entries[0].id.?);
    try testing.expectEqualStrings("b2", timing.entries[1].id.?);
    try testing.expectEqual(@as(?bool, false), timing.entries[1].background);
    try testing.expectEqual(@as(usize, 2), t.progress.slots.items.len);
    try testing.expectEqual(@as(?u8, 0), t.progress.slots.items[0].value.exit_code);
    try testing.expectEqual(.failed, t.progress.slots.items[1].value.state);
    try testing.expectEqual(@as(?u8, 7), t.progress.slots.items[1].value.exit_code);
    try testing.expect(t.progress.slots.items[1].value.elapsed_ms >= 3000);
    t.progress.clear(testing.allocator);
    try testing.expectEqualStrings("b2", timing.entries[1].id.?);
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

test "bash has a finite 30 minute default and honors explicit timeouts in every mode" {
    inline for (.{ false, true }) |background| {
        const ordinary: Args = .{ .command = "true", .background = background };
        try testing.expectEqual(@as(i64, 1_800_000), ordinary.timeoutMs());
        try testing.expect(ordinary.validationError() == null);
        const explicit: Args = .{ .command = "true", .background = background, .timeout_ms = 25 };
        try testing.expectEqual(@as(i64, 25), explicit.timeoutMs());
        try testing.expect(explicit.validationError() == null);
    }
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
    var execution: @import("../sandbox/timing.zig").Execution = .{};
    const result = try executeBackground(&t, testing.allocator, "{\"command\":\"sleep 5\",\"background\":true,\"detached\":true,\"timeout_ms\":25}", &cancel, .{ .id = progress, .kind = .bash, .background = true, .prompt = "" }, &execution, null);
    defer freeResult(result);
    try expectTimeout(result, 25, "");
    try testing.expect(execution.start_ms_epoch > 0);
    try testing.expect(execution.end_ms_epoch >= execution.start_ms_epoch + 25);
}
