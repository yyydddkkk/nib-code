const std = @import("std");
const config = @import("config.zig");
const core = @import("sandbox/replay.zig");
const End = @import("sandbox/record.zig").End;
const output = @import("session/output.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const Key = struct {
    step: usize,
    run: usize,

    fn eql(a: Key, b: Key) bool {
        return a.step == b.step and a.run == b.run;
    }
};

const Options = struct {
    id: []const u8,
    key: ?Key = null,
    all: bool = false,
    script: ?[]const u8 = null,
    json: bool = false,
};

fn decimal(s: []const u8) !usize {
    if (s.len == 0) return error.InvalidReplayArguments;
    for (s) |c| if (c < '0' or c > '9') return error.InvalidReplayArguments;
    return std.fmt.parseInt(usize, s, 10) catch error.InvalidReplayArguments;
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len == 0) return error.InvalidReplayArguments;
    if (args[0].len != 32) return error.InvalidSessionId;
    for (args[0]) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return error.InvalidSessionId;
    var o: Options = .{ .id = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--all")) {
            if (o.all or o.key != null) return error.InvalidReplayArguments;
            o.all = true;
        } else if (std.mem.eql(u8, arg, "--run")) {
            if (o.key != null or o.all) return error.InvalidReplayArguments;
            i += 1;
            if (i == args.len) return error.InvalidReplayArguments;
            const colon = std.mem.indexOfScalar(u8, args[i], ':') orelse return error.InvalidReplayArguments;
            const step = try decimal(args[i][0..colon]);
            const index = try decimal(args[i][colon + 1 ..]);
            if (step == 0) return error.InvalidReplayArguments;
            o.key = .{ .step = step, .run = index };
        } else if (std.mem.eql(u8, arg, "--script")) {
            if (o.script != null) return error.InvalidReplayArguments;
            i += 1;
            if (i == args.len or args[i].len == 0 or std.mem.startsWith(u8, args[i], "--")) return error.InvalidReplayArguments;
            o.script = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            if (o.json) return error.InvalidReplayArguments;
            o.json = true;
        } else return error.InvalidReplayArguments;
    }
    if ((!o.all and o.key == null) or (o.all and o.script != null)) return error.InvalidReplayArguments;
    return o;
}

const Run = struct {
    source_reference: bool = false,
    key: Key,
    code: []const u8,
    expected: ?[]const u8,
    child: bool = false,
    remaining_steps: ?usize = null,
};

fn field(v: Value, name: []const u8) !Value {
    if (v != .object) return error.InvalidReplayLog;
    return v.object.get(name) orelse error.InvalidReplayLog;
}

fn string(v: Value) ![]const u8 {
    if (v != .string) return error.InvalidReplayLog;
    return v.string;
}

fn natural(v: Value) !usize {
    if (v != .integer or v.integer < 0) return error.InvalidReplayLog;
    return std.math.cast(usize, v.integer) orelse error.InvalidReplayLog;
}

fn optionalString(v: Value, name: []const u8) !?[]const u8 {
    if (v != .object) return error.InvalidReplayLog;
    const item = v.object.get(name) orelse return null;
    if (item == .null) return null;
    return try string(item);
}

fn array(v: Value) ![]Value {
    if (v != .array) return error.InvalidReplayLog;
    return v.array.items;
}

fn parse(a: Allocator, line: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, line, .{ .allocate = .alloc_always }) catch return error.InvalidReplayLog;
}

// Replacement records and fork headers retain assistant messages, not new Steps.
pub fn loadMain(a: Allocator, data: []const u8) ![]Run {
    var runs: std.ArrayList(Run) = .empty;
    var sources: std.ArrayList(@import("session/log.zig").Source) = .empty;
    var length: usize = 0;
    var step: usize = 0;
    var torn = false;
    var records: usize = 0;
    var child = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null) break;
        if (line.len == 0) continue;
        const record = parse(a, line) catch {
            torn = true;
            continue;
        };
        if (record != .object) return error.InvalidReplayLog;
        if (record.object.get("source")) |source| {
            const value = try std.json.parseFromValueLeaky(@import("session/log.zig").Source, a, source, .{});
            try sources.append(a, value);
            for (runs.items) |*item| if (item.key.step == value.step and item.key.run == value.run) {
                item.source_reference = value.failed;
            };
            continue;
        }
        if (record.object.get("repair")) |repair| {
            if (repair == .bool and repair.bool) {
                torn = false;
                continue;
            }
        }
        if (torn) return error.InvalidReplayLog;
        if (record.object.get("diagnostic")) |d| if (d != .null) continue;
        if (record.object.get("agent_session")) |mapping| if (mapping != .null) continue;
        if (record.object.get("background")) |b| if (b != .null) continue;
        if (record.object.get("bash")) |b| if (b != .null) continue;
        if (record.object.get("task_stop")) |stop| if (stop != .null) continue;
        if (record.object.get("sandbox_unavailable")) |reason| if (reason != .null) continue;
        if (record.object.get("hook")) |hook| if (hook != .null) continue;
        const messages: []const Value = if (record.object.get("messages")) |v| try array(v) else &.{};
        if (messages.len == 0 and (try optionalString(record, "transport_fallback")) != null) continue;
        const from = if (record.object.get("from")) |v| try natural(v) else 0;
        if (from > length) return error.InvalidReplayLog;
        if (records == 0) child = (try optionalString(record, "parent_session_id")) != null;
        const appended = from == length;
        length = std.math.add(usize, from, messages.len) catch return error.InvalidReplayLog;
        records += 1;
        if (!appended) continue;
        if (record.object.get("forked_from")) |fork| if (fork != .null) continue;
        for (messages, 0..) |message, m| {
            if (message.object.get("background_run")) |completion| if (completion != .null) {
                const key: Key = .{ .step = try natural(try field(completion, "step")), .run = try natural(try field(completion, "run_index")) };
                for (runs.items) |*item| if (item.key.eql(key)) {
                    item.expected = try string(try field(completion, "output"));
                    item.remaining_steps = null;
                };
            };
            if (!std.mem.eql(u8, try string(try field(message, "role")), "assistant")) continue;
            step += 1;
            const calls_value = message.object.get("tool_calls") orelse continue;
            if (calls_value == .null) continue;
            for (try array(calls_value), 0..) |call, index| {
                const function = try field(call, "function");
                const name = try string(try field(function, "name"));
                if (!std.mem.eql(u8, name, "run") and !std.mem.eql(u8, name, "rerun")) continue;
                const arguments = parse(a, try string(try field(function, "arguments"))) catch continue;
                const code = if (std.mem.eql(u8, name, "rerun")) resolved: {
                    var source_index = sources.items.len;
                    while (source_index > 0) {
                        source_index -= 1;
                        const source = sources.items[source_index];
                        if (source.step == step and source.run == index) break :resolved @as(?[]const u8, source.code);
                    }
                    break :resolved @as(?[]const u8, null);
                } else optionalString(arguments, "code") catch continue;
                if (code == null) continue;
                const id = try string(try field(call, "id"));
                var expected: ?[]const u8 = null;
                for (messages[m + 1 ..]) |result| {
                    const role = try string(try field(result, "role"));
                    if (std.mem.eql(u8, role, "assistant")) break;
                    if (!std.mem.eql(u8, role, "tool")) continue;
                    if (try optionalString(result, "tool_call_id")) |result_id| {
                        if (std.mem.eql(u8, id, result_id)) {
                            expected = try optionalString(result, "content");
                            break;
                        }
                    }
                }
                var remaining_steps: ?usize = null;
                if (record.object.get("run_results")) |results| {
                    if (results != .null) for (try array(results)) |result| {
                        if (std.mem.eql(u8, id, try string(try field(result, "tool_call_id")))) {
                            if (try optionalString(result, "background_id")) |_| expected = null;
                            if (result.object.get("remaining_steps")) |remaining| {
                                if (remaining != .null) remaining_steps = try natural(remaining);
                            }
                            break;
                        }
                    };
                }
                var source_reference = false;
                for (sources.items) |source| if (source.step == step and source.run == index) {
                    source_reference = source.failed;
                };
                try runs.append(a, .{ .source_reference = source_reference, .key = .{ .step = step, .run = index }, .code = code.?, .expected = expected, .child = child, .remaining_steps = remaining_steps });
            }
        }
    }
    if (records == 0) return error.InvalidReplayLog;
    return runs.toOwnedSlice(a);
}

const Recording = struct {
    key: Key,
    start_ms_epoch: i64,
    run_output_bytes: usize = output.max_bytes,
    entries: std.ArrayList(core.Entry) = .empty,
    end: ?End = null,
    incomplete: bool = false,
};

fn recordingFor(recordings: []Recording, key: Key) ?*Recording {
    for (recordings) |*r| if (r.key.eql(key)) return r;
    return null;
}

fn loadCalls(a: Allocator, data: []const u8) ![]Recording {
    var recordings: std.ArrayList(Recording) = .empty;
    var resolved: std.StringHashMap(core.Entry) = .init(a);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null) break;
        if (line.len == 0) continue;
        const row = try parse(a, line);
        const key: Key = .{ .step = try natural(try field(row, "step")), .run = try natural(try field(row, "run")) };
        if (key.step == 0 or row.object.contains("type") or row.object.contains("same_as")) return error.InvalidReplayLog;
        if (recordingFor(recordings.items, key) == null) try recordings.append(a, .{ .key = key, .start_ms_epoch = 0 });
        const r = recordingFor(recordings.items, key).?;
        if (r.end != null) return error.InvalidReplayLog;
        if (row.object.get("meta")) |meta| {
            const start = try field(meta, "start_ms_epoch");
            if (start != .integer) return error.InvalidReplayLog;
            r.start_ms_epoch = start.integer;
            if (meta.object.get("run_output_bytes")) |limit| {
                r.run_output_bytes = try natural(limit);
                if (r.run_output_bytes < 16384 or r.run_output_bytes > 16777216) return error.InvalidReplayLog;
            }
            if (meta.object.get("incomplete")) |incomplete| {
                if (incomplete != .bool) return error.InvalidReplayLog;
                r.incomplete = r.incomplete or incomplete.bool;
            }
            r.end = std.meta.stringToEnum(End, try string(try field(meta, "end"))) orelse return error.InvalidReplayLog;
            continue;
        }
        const ok = try field(row, "ok");
        if (ok != .bool) return error.InvalidReplayLog;
        var entry: core.Entry = .{
            .index = try natural(try field(row, "index")),
            .seq = try natural(try field(row, "seq")),
            .name = try string(try field(row, "name")),
            .args = try field(row, "args"),
            .ok = ok.bool,
            .sha256 = (try optionalString(row, "sha256")) orelse "",
            .@"error" = try optionalString(row, "error"),
        };
        if (row.object.get("truncated")) |truncated| {
            if (truncated != .bool) return error.InvalidReplayLog;
            entry.truncated = truncated.bool;
        }
        if (row.object.get("result")) |result| {
            if (!entry.ok) return error.InvalidReplayLog;
            switch (result) {
                .string => |bytes| entry.result = bytes,
                .object => entry.same_as = try string(try field(result, "same_as")),
                else => return error.InvalidReplayLog,
            }
        }
        if (entry.same_as) |hash| {
            if (resolved.get(hash)) |original| {
                entry.result = original.result;
                entry.truncated = entry.truncated or original.truncated;
            } else {
                r.incomplete = true;
                entry.truncated = true;
            }
        }
        if ((if (entry.ok) entry.result else entry.@"error") == null) {
            r.incomplete = true;
            entry.truncated = true;
            if (entry.ok) entry.result = "" else entry.@"error" = "";
        }
        if (entry.truncated) r.incomplete = true;
        if (entry.ok and entry.sha256.len != 0) try resolved.put(entry.sha256, entry);
        try r.entries.append(a, entry);
    }
    for (recordings.items) |*r| if (r.end == null) {
        r.incomplete = true;
    };
    return recordings.toOwnedSlice(a);
}

const Report = struct {
    run: []const u8,
    match: ?bool,
    divergence: ?[]const u8 = null,
    incomplete: bool,
    uses_time: bool,
    uses_random: bool,
    output: []const u8,
    end: ?End = null,
};

fn replayOne(a: Allocator, io: std.Io, original: Run, recording: Recording, script: ?[]const u8) !Report {
    const evaluated = try core.executeSession(a, io, script orelse original.code, recording.entries.items, recording.start_ms_epoch, recording.end orelse .ok, script != null, original.child);
    defer evaluated.deinit(a);
    const formatted = try output.format(a, evaluated.outcome, recording.run_output_bytes);
    const referenced = if (original.source_reference) try std.fmt.allocPrint(a, "{s}\nSource: {d}:{d} (rerun executes from the beginning; prior effects may repeat)", .{ formatted, original.key.step, original.key.run }) else formatted;
    const text = try output.stepLimitOutput(a, referenced, original.remaining_steps);
    const incomplete = recording.incomplete or evaluated.incomplete or original.expected == null;
    const determined = script == null and !incomplete and recording.end != .timeout and recording.end != .cancelled;
    const equal = if (original.expected) |expected| std.mem.eql(u8, expected, text) else false;
    return .{
        .run = try std.fmt.allocPrint(a, "{d}:{d}", .{ original.key.step, original.key.run }),
        .match = if (determined) evaluated.divergence == null and equal else null,
        .divergence = if (evaluated.divergence) |d| try a.dupe(u8, d) else if (determined and !equal) try std.fmt.allocPrint(a, "output differs: expected={f}; actual={f}", .{ std.json.fmt(original.expected.?, .{}), std.json.fmt(text, .{}) }) else null,
        .incomplete = incomplete,
        .uses_time = evaluated.uses_time,
        .uses_random = evaluated.uses_random,
        .output = text,
        .end = recording.end,
    };
}

fn findRun(runs: []const Run, key: Key) ?Run {
    for (runs) |r| if (r.key.eql(key)) return r;
    return null;
}

fn writeJson(w: *std.Io.Writer, value: anytype) !void {
    try w.print("{f}\n", .{std.json.fmt(value, .{ .emit_null_optional_fields = true })});
}

pub fn run(init: std.process.Init, args: []const []const u8, stdout: *std.Io.Writer) !void {
    const options = try parseOptions(args);
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try config.home(a, init.environ_map);
    const main_name = try std.fmt.allocPrint(a, "{s}.jsonl", .{options.id});
    const calls_name = try std.fmt.allocPrint(a, "{s}.calls.jsonl", .{options.id});
    const main_path = try std.fs.path.join(a, &.{ home, "sessions", main_name });
    const calls_path = try std.fs.path.join(a, &.{ home, "sessions", calls_name });
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, main_path, a, .unlimited);
    const runs = try loadMain(a, data);
    const calls = std.Io.Dir.cwd().readFileAlloc(init.io, calls_path, a, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.ReplayMetadataNotFound,
        else => return err,
    };
    const recordings = try loadCalls(a, calls);
    const script = if (options.script) |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .unlimited) else null;
    if (options.all) {
        var reports: std.ArrayList(Report) = .empty;
        const Difference = struct { run: []const u8, divergence: []const u8 };
        var differences: std.ArrayList(Difference) = .empty;
        var matched: usize = 0;
        var divergences: usize = 0;
        var undetermined: usize = 0;
        for (recordings) |recording| {
            const original = findRun(runs, recording.key) orelse {
                const missing: Report = .{
                    .run = try std.fmt.allocPrint(a, "{d}:{d}", .{ recording.key.step, recording.key.run }),
                    .match = null,
                    .incomplete = true,
                    .uses_time = false,
                    .uses_random = false,
                    .output = "",
                    .end = recording.end,
                };
                try reports.append(a, missing);
                undetermined += 1;
                continue;
            };
            const report = try replayOne(a, init.io, original, recording, null);
            try reports.append(a, report);
            if (report.divergence) |d| try differences.append(a, .{ .run = report.run, .divergence = d });
            if (report.match) |match| {
                if (match) matched += 1 else divergences += 1;
            } else undetermined += 1;
        }
        if (options.json) {
            try writeJson(stdout, .{ .total = reports.items.len, .matched = matched, .divergences = divergences, .undetermined = undetermined, .differences = differences.items, .reports = reports.items });
        } else {
            try stdout.print("total: {d}, matched: {d}, divergences: {d}, undetermined: {d}\n", .{ reports.items.len, matched, divergences, undetermined });
            for (differences.items) |difference| try stdout.print("replay {s}: diff: {s}\n", .{ difference.run, difference.divergence });
            for (reports.items) |report| if (report.end == .timeout or report.end == .cancelled) {
                try stdout.print("replay {s}: end={s} (incomplete)\n", .{ report.run, @tagName(report.end.?) });
            };
        }
    } else {
        const key = options.key.?;
        const original = findRun(runs, key) orelse return error.ReplayRunNotFound;
        const recording = recordingFor(recordings, key) orelse return error.ReplayMetadataNotFound;
        const report = try replayOne(a, init.io, original, recording.*, script);
        if (options.json) {
            try writeJson(stdout, report);
        } else {
            try stdout.writeAll(report.output);
            std.debug.print("replay {s}: {s}{s}{s}\n", .{ report.run, if (report.match) |match| (if (match) "match" else "diff") else "undetermined", if (report.incomplete) " (incomplete)" else "", if (script != null) " (script)" else "" });
            if (report.end == .timeout or report.end == .cancelled) std.debug.print("end={s}\n", .{@tagName(report.end.?)});
            if (report.divergence) |d| std.debug.print("{s}\n", .{d});
            if (report.uses_time or report.uses_random) std.debug.print("uses_time={any} uses_random={any}\n", .{ report.uses_time, report.uses_random });
        }
    }
    try stdout.flush();
}

test "raw main records count global assistant Steps across turns and compaction" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const data = "{\"messages\":[{\"role\":\"system\",\"content\":\"s\"},{\"role\":\"user\",\"content\":\"one\"}]}\n" ++
        "{\"from\":2,\"turn_step\":1,\"messages\":[{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"a\",\"function\":{\"name\":\"run\",\"arguments\":\"{\\\"code\\\":\\\"first\\\"}\"}},{\"id\":\"x\",\"function\":{\"name\":\"other\",\"arguments\":\"{\\\"code\\\":\\\"ignored\\\"}\"}},{\"id\":\"b\",\"function\":{\"name\":\"run\",\"arguments\":\"{\\\"code\\\":\\\"second\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"a\",\"content\":\"one\"},{\"role\":\"tool\",\"tool_call_id\":\"x\",\"content\":\"unknown\"},{\"role\":\"tool\",\"tool_call_id\":\"b\",\"content\":\"two\"}]}\n" ++
        "{\"agent_session\":{\"id\":\"a1\",\"session\":\"0123456789abcdef0123456789abcdef\"}}\n" ++
        "{\"task_stop\":{\"id\":\"b1\",\"reason\":\"user requested stop\",\"stopped\":true},\"from\":0,\"messages\":[]}\n" ++
        "{\"transport_fallback\":\"WebSocketProtocol\",\"from\":0,\"messages\":[]}\n" ++
        "{\"from\":6,\"turn_step\":2,\"messages\":[{\"role\":\"assistant\",\"content\":\"done\"}]}\n" ++
        "{\"from\":7,\"turn_step\":1,\"messages\":[{\"role\":\"user\",\"content\":\"two\"},{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"c\",\"function\":{\"name\":\"run\",\"arguments\":\"{\\\"code\\\":\\\"third\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"c\",\"content\":\"three\"}]}\n" ++
        "{\"from\":1,\"messages\":[{\"role\":\"user\",\"content\":\"summary\"},{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"c\",\"function\":{\"name\":\"run\",\"arguments\":\"{\\\"code\\\":\\\"third\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"c\",\"content\":\"three\"}]}\n" ++
        "{\"from\":4,\"turn_step\":1,\"messages\":[{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"d\",\"function\":{\"name\":\"run\",\"arguments\":\"{\\\"code\\\":\\\"fourth\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"d\",\"content\":\"four\"}]}\n";
    const runs = try loadMain(arena.allocator(), data);
    try t.expectEqual(@as(usize, 4), runs.len);
    const steps = [_]usize{ 1, 1, 3, 4 };
    const indexes = [_]usize{ 0, 2, 0, 0 };
    const codes = [_][]const u8{ "first", "second", "third", "fourth" };
    const results = [_][]const u8{ "one", "two", "three", "four" };
    for (runs, steps, indexes, codes, results) |r, step, index, code, expected| {
        try t.expectEqual(step, r.key.step);
        try t.expectEqual(index, r.key.run);
        try t.expectEqualStrings(code, r.code);
        try t.expectEqualStrings(expected, r.expected.?);
    }
}

test "fork headers do not contribute Steps or Runs across compaction and resume" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const data = "{\"parent_session_id\":\"parent\",\"forked_from\":{\"session\":\"parent\",\"message_count\":5},\"messages\":[{\"role\":\"system\",\"content\":\"system\"},{\"role\":\"user\",\"content\":\"parent task\"},{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"p1\",\"function\":{\"name\":\"run\",\"arguments\":\"{\\\"code\\\":\\\"parent-first\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"p1\",\"content\":\"parent output\"},{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"p2\",\"function\":{\"name\":\"run\",\"arguments\":\"{\\\"code\\\":\\\"parent-fork\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"p2\",\"content\":\"synthetic result\"}]}\n" ++
        "{\"from\":6,\"messages\":[{\"role\":\"user\",\"content\":\"child task\"},{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"c1\",\"function\":{\"name\":\"run\",\"arguments\":\"{\\\"code\\\":\\\"child-first\\\"}\"}},{\"id\":\"c2\",\"function\":{\"name\":\"run\",\"arguments\":\"{\\\"code\\\":\\\"child-second\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"first\"},{\"role\":\"tool\",\"tool_call_id\":\"c2\",\"content\":\"second\"}]}\n" ++
        "{\"from\":10,\"messages\":[{\"role\":\"assistant\",\"content\":\"child done\"}]}\n" ++
        "{\"from\":1,\"messages\":[{\"role\":\"user\",\"content\":\"summary\"},{\"role\":\"assistant\",\"content\":\"retained child done\"}]}\n" ++
        "{\"from\":3,\"forked_from\":null,\"messages\":[{\"role\":\"user\",\"content\":\"resume\"},{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"c3\",\"function\":{\"name\":\"run\",\"arguments\":\"{\\\"code\\\":\\\"child-resumed\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"c3\",\"content\":\"resumed\"}]}\n";
    const runs = try loadMain(arena.allocator(), data);
    try t.expectEqual(@as(usize, 3), runs.len);
    const steps = [_]usize{ 1, 1, 3 };
    const indexes = [_]usize{ 0, 1, 0 };
    const codes = [_][]const u8{ "child-first", "child-second", "child-resumed" };
    const results = [_][]const u8{ "first", "second", "resumed" };
    for (runs, steps, indexes, codes, results) |r, step, index, code, expected| {
        try t.expectEqual(step, r.key.step);
        try t.expectEqual(index, r.key.run);
        try t.expectEqualStrings(code, r.code);
        try t.expectEqualStrings(expected, r.expected.?);
        try t.expect(r.child);
    }
}

test "background lifecycle records do not replace replay history" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const data =
        \\{"messages":[{"role":"system","content":"s"}]}
        \\{"from":0,"messages":[],"background":{"id":"b1","kind":"bash","state":"started"}}
        \\{"bash":{"id":"b1","run":1,"state":"started","command":"check","cwd":"/a"}}
        \\{"from":1,"messages":[{"role":"assistant","tool_calls":[{"id":"r1","function":{"name":"run","arguments":"{\"code\":\"42\"}"}}]},{"role":"tool","tool_call_id":"r1","content":"42"}]}
        \\{"from":0,"messages":[],"background":{"id":"b1","kind":"bash","state":"finished"}}
        \\{"bash":{"id":"b1","run":1,"state":"superseded","superseded_by":"b2","elapsed_ms":20}}
        \\
    ;
    const runs = try loadMain(arena.allocator(), data);
    try t.expectEqual(@as(usize, 1), runs.len);
    try t.expectEqualStrings("42", runs[0].code);
    try t.expectEqualStrings("42", runs[0].expected.?);
}

test "calls resolve session wide same_as and retain zero call metadata" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const data = "{\"step\":1,\"run\":0,\"index\":0,\"seq\":0,\"name\":\"read\",\"args\":{\"path\":\"a\"},\"ok\":true,\"result\":\"{\\\"text\\\":\\\"hello\\\"}\",\"sha256\":\"same\",\"truncated\":false}\n" ++
        "{\"step\":1,\"run\":0,\"meta\":{\"start_ms_epoch\":10,\"end\":\"ok\"}}\n" ++
        "{\"step\":3,\"run\":0,\"index\":0,\"seq\":0,\"name\":\"read\",\"args\":{\"path\":\"b\"},\"ok\":true,\"sha256\":\"same\",\"truncated\":false,\"result\":{\"same_as\":\"same\"}}\n" ++
        "{\"step\":3,\"run\":0,\"meta\":{\"start_ms_epoch\":20,\"end\":\"ok\"}}\n" ++
        "{\"step\":4,\"run\":0,\"meta\":{\"start_ms_epoch\":30,\"end\":\"ok\"}}\n";
    const recordings = try loadCalls(arena.allocator(), data);
    try t.expectEqual(@as(usize, 3), recordings.len);
    try t.expectEqualStrings(recordings[0].entries.items[0].result.?, recordings[1].entries.items[0].result.?);
    try t.expect(!recordings[0].incomplete);
    try t.expectEqual(@as(i64, 10), recordings[0].start_ms_epoch);
    try t.expect(!recordings[1].incomplete);
    try t.expectEqual(@as(usize, 0), recordings[2].entries.items.len);
    try t.expectEqual(End.ok, recordings[2].end.?);
}

test "strict replay arguments" {
    const t = std.testing;
    const id = "0123456789abcdef0123456789abcdef";
    const valid = try parseOptions(&.{ id, "--json", "--run", "2:0", "--script", "replacement.js" });
    try t.expectEqual(@as(usize, 2), valid.key.?.step);
    try t.expect(valid.json);
    const invalid = [_][]const []const u8{
        &.{},                               &.{id},                                                     &.{ id, "--run" },          &.{ id, "--run", "0:0" },
        &.{ id, "--run", "1:-1" },          &.{ id, "--run", "1:0:0" },                                 &.{ id, "--run", "+1:0" },  &.{ id, "--all", "--run", "1:0" },
        &.{ id, "--all", "--script", "a" }, &.{ id, "--all", "--json", "--json" },                      &.{ id, "--all", "--all" }, &.{ id, "--run", "1:0", "--run", "2:0" },
        &.{ id, "--all", "--unknown" },     &.{ id, "--run", "1:0", "--script", "a", "--script", "b" },
    };
    for (invalid) |args| try t.expectError(error.InvalidReplayArguments, parseOptions(args));
    try t.expectError(error.InvalidSessionId, parseOptions(&.{ "0123456789ABCDEF0123456789abcdef", "--all" }));
    try t.expectError(error.InvalidSessionId, parseOptions(&.{ "../a", "--all" }));
}

test "truncated aliases missing references and unfinished recordings are incomplete" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const data = "{\"step\":1,\"run\":0,\"index\":0,\"seq\":0,\"name\":\"read\",\"args\":{},\"ok\":true,\"result\":\"{\\\"text\\\":\",\"sha256\":\"h\",\"truncated\":true}\n" ++
        "{\"step\":1,\"run\":0,\"meta\":{\"start_ms_epoch\":1,\"end\":\"ok\"}}\n" ++
        "{\"step\":2,\"run\":0,\"index\":0,\"seq\":0,\"name\":\"read\",\"args\":{},\"ok\":true,\"sha256\":\"h\",\"truncated\":false,\"result\":{\"same_as\":\"h\"}}\n" ++
        "{\"step\":2,\"run\":0,\"meta\":{\"start_ms_epoch\":2,\"end\":\"ok\"}}\n" ++
        "{\"step\":3,\"run\":0,\"index\":0,\"seq\":0,\"name\":\"read\",\"args\":{},\"ok\":true,\"sha256\":\"h\",\"truncated\":false,\"result\":{\"same_as\":\"missing\"}}\n" ++
        "{\"step\":3,\"run\":0,\"meta\":{\"start_ms_epoch\":3,\"end\":\"ok\"}}\n" ++
        "{\"step\":4,\"run\":0,\"index\":0,\"seq\":0,\"name\":\"read\",\"args\":{},\"ok\":true,\"result\":\"1\"}\n";
    const recordings = try loadCalls(arena.allocator(), data);
    try t.expectEqual(@as(usize, 4), recordings.len);
    for (recordings) |r| try t.expect(r.incomplete);
    try t.expect(recordings[1].entries.items[0].truncated);
    try t.expectEqualStrings(recordings[0].entries.items[0].result.?, recordings[1].entries.items[0].result.?);
    try t.expectEqualStrings("", recordings[2].entries.items[0].result.?);
    try t.expect(recordings[2].entries.items[0].@"error" == null);
    try t.expect(recordings[3].end == null);
}

test "optional incomplete metadata distinguishes pending and settled ordinary errors" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const data = "{\"step\":1,\"run\":0,\"meta\":{\"start_ms_epoch\":1,\"end\":\"error\",\"incomplete\":true}}\n" ++
        "{\"step\":2,\"run\":0,\"meta\":{\"start_ms_epoch\":2,\"end\":\"error\"}}\n" ++
        "{\"step\":3,\"run\":0,\"meta\":{\"start_ms_epoch\":3,\"end\":\"error\",\"incomplete\":false}}\n";
    const recordings = try loadCalls(arena.allocator(), data);
    try t.expect(recordings[0].incomplete);
    try t.expect(!recordings[1].incomplete);
    try t.expect(!recordings[2].incomplete);
    const pending: Run = .{ .key = .{ .step = 1, .run = 0 }, .code = "tools.read(); throw new Error('boom')", .expected = "Error: boom" };
    const report = try replayOne(arena.allocator(), t.io, pending, recordings[0], null);
    try t.expect(report.incomplete);
    try t.expect(report.match == null);
    try t.expect(report.divergence != null);
}
