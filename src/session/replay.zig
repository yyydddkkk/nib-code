const std = @import("std");
const record = @import("../sandbox/record.zig");
const sandbox = @import("../sandbox.zig");
const provider = @import("../provider.zig");
const output = @import("output.zig");
const Allocator = std.mem.Allocator;

const Key = struct { step: usize, run: usize };
const Options = struct {
    id: []const u8,
    selected: ?Key = null,
    all: bool = false,
    script: ?[]const u8 = null,
    json: bool = false,
};

fn parseKey(text: []const u8) !Key {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidReplayRun;
    if (colon == 0 or colon + 1 == text.len) return error.InvalidReplayRun;
    if (std.mem.indexOfNone(u8, text[0..colon], "0123456789") != null or
        std.mem.indexOfNone(u8, text[colon + 1 ..], "0123456789") != null) return error.InvalidReplayRun;
    const key: Key = .{
        .step = std.fmt.parseInt(usize, text[0..colon], 10) catch return error.InvalidReplayRun,
        .run = std.fmt.parseInt(usize, text[colon + 1 ..], 10) catch return error.InvalidReplayRun,
    };
    if (key.step == 0) return error.InvalidReplayRun;
    return key;
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len == 0) return error.MissingSessionId;
    if (args[0].len != 32 or std.mem.indexOfNone(u8, args[0], "0123456789abcdef") != null) return error.InvalidSessionId;
    var opts: Options = .{ .id = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json") and !opts.json) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--all") and !opts.all) {
            opts.all = true;
        } else if (std.mem.eql(u8, arg, "--run") and opts.selected == null) {
            i += 1;
            if (i == args.len) return error.InvalidArguments;
            opts.selected = try parseKey(args[i]);
        } else if (std.mem.eql(u8, arg, "--script") and opts.script == null) {
            i += 1;
            if (i == args.len) return error.InvalidArguments;
            opts.script = args[i];
        } else return error.InvalidArguments;
    }
    if (opts.all == (opts.selected != null) or (opts.all and opts.script != null)) return error.InvalidArguments;
    return opts;
}

const Run = struct {
    key: Key,
    code: ?[]const u8 = null,
    child: bool = false,
    expected: ?[]const u8 = null,
    meta: ?record.Meta = null,
    calls: std.ArrayList(record.RecordedCall) = .empty,
};

fn getRun(a: Allocator, runs: *std.ArrayList(Run), key: Key) !*Run {
    for (runs.items) |*item| if (std.meta.eql(item.key, key)) return item;
    try runs.append(a, .{ .key = key });
    return &runs.items[runs.items.len - 1];
}

fn loadMain(a: Allocator, data: []const u8, runs: *std.ArrayList(Run)) !void {
    const Line = struct { turn_step: ?usize = null, messages: []const provider.Message = &.{}, repair: bool = false, parent_session_id: ?[]const u8 = null };
    var lines = std.mem.splitScalar(u8, data, '\n');
    var step: usize = 0;
    var torn = false;
    var child = false;
    while (lines.next()) |line| {
        if (lines.peek() == null) break;
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        const row = std.json.parseFromSliceLeaky(Line, a, line, .{ .ignore_unknown_fields = true }) catch {
            torn = true;
            continue;
        };
        if (row.repair) {
            torn = false;
            continue;
        }
        if (torn) return error.InvalidSessionLog;
        if (row.parent_session_id != null) child = true;
        if (row.turn_step == null) continue;
        step += 1;
        for (row.messages) |message| {
            if (!std.mem.eql(u8, message.role, "assistant")) continue;
            for (message.tool_calls orelse continue, 0..) |call, index| {
                if (!std.mem.eql(u8, call.function.name, "run")) continue;
                const code = std.json.parseFromSliceLeaky(struct { code: []const u8 }, a, call.function.arguments, .{ .ignore_unknown_fields = true }) catch continue;
                const item = try getRun(a, runs, .{ .step = step, .run = index });
                item.code = code.code;
                item.child = child;
                for (row.messages) |reply| {
                    if (std.mem.eql(u8, reply.role, "tool") and std.mem.eql(u8, reply.tool_call_id orelse "", call.id)) {
                        item.expected = reply.content;
                        break;
                    }
                }
            }
        }
    }
}

const Stored = struct { text: []const u8, incomplete: bool = false };

fn expand(a: Allocator, value: std.json.Value, blobs: *std.StringHashMap(Stored)) !Stored {
    if (value == .string) {
        const hash = record.sha256(value.string);
        const stored: Stored = .{ .text = value.string };
        try blobs.put(try a.dupe(u8, &hash), stored);
        return stored;
    }
    if (value != .object) return error.InvalidReplayLog;
    if (value.object.get("same_as")) |hash| {
        if (hash != .string) return error.InvalidReplayLog;
        return blobs.get(hash.string) orelse error.InvalidReplayLog;
    }
    const content = value.object.get("content") orelse return error.InvalidReplayLog;
    const hash = value.object.get("sha") orelse return error.InvalidReplayLog;
    const truncated = value.object.get("truncated") orelse return error.InvalidReplayLog;
    if (content != .string or hash != .string or truncated != .bool or !truncated.bool) return error.InvalidReplayLog;
    const stored: Stored = .{ .text = content.string, .incomplete = true };
    try blobs.put(hash.string, stored);
    return stored;
}

fn loadCalls(a: Allocator, data: []const u8, runs: *std.ArrayList(Run)) !void {
    var blobs = std.StringHashMap(Stored).init(a);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        const entry = std.json.parseFromSliceLeaky(record.Entry, a, line, .{ .ignore_unknown_fields = true }) catch return error.InvalidReplayLog;
        const item = try getRun(a, runs, .{ .step = entry.step, .run = entry.run });
        if (entry.meta) |meta| {
            if (item.meta != null) item.calls.clearRetainingCapacity();
            item.meta = meta;
            continue;
        }
        if (item.meta != null or (entry.seq == 0 and item.calls.items.len > 0)) {
            item.calls.clearRetainingCapacity();
            item.meta = null;
        }
        const ok = entry.ok orelse return error.InvalidReplayLog;
        const stored: Stored = if (ok) try expand(a, entry.result orelse return error.InvalidReplayLog, &blobs) else .{ .text = entry.@"error" orelse return error.InvalidReplayLog };
        try item.calls.append(a, .{
            .index = entry.index orelse return error.InvalidReplayLog,
            .seq = entry.seq orelse return error.InvalidReplayLog,
            .name = entry.name orelse return error.InvalidReplayLog,
            .args = entry.args orelse return error.InvalidReplayLog,
            .ok = ok,
            .text = stored.text,
            .incomplete = stored.incomplete,
        });
    }
    for (runs.items) |*item| std.mem.sort(record.RecordedCall, item.calls.items, {}, struct {
        fn less(_: void, left: record.RecordedCall, right: record.RecordedCall) bool {
            return left.index < right.index;
        }
    }.less);
}

const RunReport = struct {
    run: []const u8,
    match: ?bool,
    divergence: @FieldType(record.Playback, "divergence") = null,
    incomplete: bool,
    uses_time: bool = false,
    uses_random: bool = false,
    output: []const u8,
    original_end: ?[]const u8,
};

fn execute(a: Allocator, io: std.Io, item: Run, script: ?[]const u8) !RunReport {
    var report: RunReport = .{
        .run = try std.fmt.allocPrint(a, "{d}:{d}", .{ item.key.step, item.key.run }),
        .match = null,
        .incomplete = item.meta == null or item.code == null or item.expected == null,
        .output = "",
        .original_end = if (item.meta) |meta| @tagName(meta.end) else null,
    };
    for (item.calls.items) |call| report.incomplete = report.incomplete or call.incomplete;
    const code = script orelse item.code orelse return report;
    var playback: record.Playback = .{
        .a = a,
        .calls = item.calls.items,
        .script_mode = script != null,
        .start_ms_epoch = if (item.meta) |meta| meta.start_ms_epoch else 0,
    };
    const api: @import("../tools.zig").Tools = .{ .io = io, .home = "", .depth = if (item.child) 1 else 0 };
    const outcome = try sandbox.eval(a, io, code, .{}, .{
        .ctx = &playback,
        .names = api.api().names,
        .call = record.Playback.unreachableCall,
        .replay = &playback,
    }, null);
    defer outcome.deinit(a);
    playback.finish();
    report.output = try output.format(a, outcome);
    report.divergence = playback.divergence;
    report.uses_time = playback.uses_time;
    report.uses_random = playback.uses_random;
    if (script == null and !report.incomplete and item.meta.?.end != .timeout and item.meta.?.end != .cancelled) {
        report.match = playback.divergence == null and std.mem.eql(u8, report.output, item.expected.?);
    }
    return report;
}

pub fn run(init: std.process.Init, args: []const []const u8, stdout: *std.Io.Writer) !void {
    const opts = try parseOptions(args);
    const a = init.arena.allocator();
    const home = try @import("../config.zig").home(a, init.environ_map);
    const main_path = try std.fs.path.join(a, &.{ home, "sessions", try std.fmt.allocPrint(a, "{s}.jsonl", .{opts.id}) });
    const calls_path = try std.fs.path.join(a, &.{ home, "sessions", try std.fmt.allocPrint(a, "{s}.calls.jsonl", .{opts.id}) });
    const main_data = try std.Io.Dir.cwd().readFileAlloc(init.io, main_path, a, .unlimited);
    const calls_data = try std.Io.Dir.cwd().readFileAlloc(init.io, calls_path, a, .unlimited);
    var runs: std.ArrayList(Run) = .empty;
    try loadMain(a, main_data, &runs);
    try loadCalls(a, calls_data, &runs);
    std.mem.sort(Run, runs.items, {}, struct {
        fn less(_: void, left: Run, right: Run) bool {
            return left.key.step < right.key.step or (left.key.step == right.key.step and left.key.run < right.key.run);
        }
    }.less);
    const script = if (opts.script) |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .unlimited) else null;
    var reports: std.ArrayList(RunReport) = .empty;
    var divergences: std.ArrayList(RunReport) = .empty;
    var matched: usize = 0;
    var indeterminate: usize = 0;
    for (runs.items) |item| {
        if (opts.all and item.meta == null and item.calls.items.len == 0) continue;
        if (opts.selected) |key| if (!std.meta.eql(key, item.key)) continue;
        const report = try execute(a, init.io, item, script);
        try reports.append(a, report);
        if (report.match) |matches| {
            if (matches) matched += 1 else try divergences.append(a, report);
        } else indeterminate += 1;
    }
    if (reports.items.len == 0 and !opts.all) return error.ReplayRunNotFound;
    if (opts.json) {
        if (opts.all) {
            try stdout.print("{f}\n", .{std.json.fmt(.{ .total = reports.items.len, .matched = matched, .divergences = divergences.items, .indeterminate = indeterminate }, .{ .emit_null_optional_fields = true })});
        } else try stdout.print("{f}\n", .{std.json.fmt(reports.items[0], .{ .emit_null_optional_fields = true })});
    } else {
        for (reports.items) |report| {
            try stdout.print("Run {s}: {s}{s}{s}{s} (original_end: {s})\n{s}\n", .{
                report.run,
                if (report.match) |matches| (if (matches) "match" else "diff") else "indeterminate",
                if (report.incomplete) " incomplete" else "",
                if (report.uses_time) " uses_time" else "",
                if (report.uses_random) " uses_random" else "",
                report.original_end orelse "unknown",
                report.output,
            });
            if (report.divergence) |divergence| try stdout.print("divergence: {f}\n", .{std.json.fmt(divergence, .{})});
        }
        if (opts.all) try stdout.print("total: {d}, matched: {d}, divergences: {d}, indeterminate: {d}\n", .{ reports.items.len, matched, divergences.items.len, indeterminate });
    }
    try stdout.flush();
}

test "replay selection validates session, step and mutually exclusive options" {
    const t = std.testing;
    const id = "0123456789abcdef0123456789abcdef";
    const opts = try parseOptions(&.{ id, "--run", "2:0", "--script", "test.js", "--json" });
    try t.expectEqualDeep(Key{ .step = 2, .run = 0 }, opts.selected.?);
    try t.expect(opts.json);
    try t.expectError(error.InvalidArguments, parseOptions(&.{ id, "--all", "--run", "1:0" }));
    try t.expectError(error.InvalidArguments, parseOptions(&.{ id, "--all", "--script", "x" }));
    try t.expectError(error.InvalidReplayRun, parseKey("0:0"));
    try t.expectError(error.InvalidReplayRun, parseKey("1:2:3"));
    try t.expectError(error.InvalidSessionId, parseOptions(&.{ "../x", "--all" }));
}

test "main log selection counts physical steps across turns and compaction" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var runs: std.ArrayList(Run) = .empty;
    try loadMain(arena.allocator(),
        \\{"turn_step":1,"messages":[{"role":"assistant","tool_calls":[{"id":"a","function":{"name":"run","arguments":"{\"code\":\"1\"}"}}]},{"role":"tool","tool_call_id":"a","content":"result: 1"}]}
        \\{"from":0,"messages":[]}
        \\{"turn_step":1,"messages":[{"role":"assistant","tool_calls":[{"id":"b","function":{"name":"run","arguments":"{\"code\":\"2\"}"}}]},{"role":"tool","tool_call_id":"b","content":"result: 2"}]}
        \\
    , &runs);
    try t.expectEqual(@as(usize, 2), runs.items.len);
    try t.expectEqual(@as(usize, 2), runs.items[1].key.step);
    try t.expectEqualStrings("1", runs.items[0].code.?);
    try t.expectEqualStrings("result: 2", runs.items[1].expected.?);
    var skipped: std.ArrayList(Run) = .empty;
    try loadMain(arena.allocator(),
        \\{"turn_step":1,"messages":[{"role":"assistant","tool_calls":[{"id":"x","function":{"name":"unknown","arguments":"{}"}},{"id":"y","function":{"name":"run","arguments":"invalid JSON"}},{"id":"z","function":{"name":"run","arguments":"{}"}}]}]}
        \\
    , &skipped);
    try t.expectEqual(@as(usize, 0), skipped.items.len);
}

test "result references preserve raw JSON and truncated content" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var blobs = std.StringHashMap(Stored).init(a);
    const raw = "{\"text\":\"a\\nb\",\"n\":1}";
    const original = try expand(a, .{ .string = raw }, &blobs);
    const hash = record.sha256(raw);
    const reference = try std.fmt.allocPrint(a, "{{\"same_as\":\"{s}\"}}", .{hash});
    const ref_value = try std.json.parseFromSliceLeaky(std.json.Value, a, reference, .{});
    try t.expectEqualStrings(raw, (try expand(a, ref_value, &blobs)).text);
    try t.expect(!original.incomplete);
    const partial = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sha":"partial","content":"{\"text\":","truncated":true}
    , .{});
    const stored = try expand(a, partial, &blobs);
    try t.expect(stored.incomplete);
    try t.expectEqualStrings("{\"text\":", stored.text);
    const partial_ref = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"same_as\":\"partial\"}", .{});
    try t.expect((try expand(a, partial_ref, &blobs)).incomplete);
}

test "main replay accepts repaired corruption and ignores an unfinished tail" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runs: std.ArrayList(Run) = .empty;
    const step = "{\"turn_step\":1,\"messages\":[{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"a\",\"function\":{\"name\":\"run\",\"arguments\":\"{\\\"code\\\":\\\"1\\\"}\"}}]}]}\n";
    const repaired = try std.fmt.allocPrint(a, "{s}broken\n{{\"repair\":true}}\n{s}unfinished", .{ step, step });
    try loadMain(a, repaired, &runs);
    try t.expectEqual(@as(usize, 2), runs.items.len);
    try t.expectEqual(@as(usize, 2), runs.items[1].key.step);
    var corrupt: std.ArrayList(Run) = .empty;
    try t.expectError(error.InvalidSessionLog, loadMain(a, try std.fmt.allocPrint(a, "broken\n{s}", .{step}), &corrupt));
    var tail: std.ArrayList(Run) = .empty;
    try loadMain(a, try std.fmt.allocPrint(a, "{s}broken\n", .{step}), &tail);
    try t.expectEqual(@as(usize, 1), tail.items.len);
}

test "duplicate recording keys retain the latest attempt and expand earlier results" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: record.Entry = .{ .step = 1, .run = 0, .index = 0, .seq = 0, .name = "read", .args = .{ .object = .{} }, .ok = true, .result = .{ .string = "{}" } };
    const meta: record.Entry = .{ .step = 1, .run = 0, .meta = .{ .start_ms_epoch = 100, .end = .cancelled } };
    var replacement = original;
    replacement.name = "grep";
    const hash = record.sha256("{}");
    replacement.result = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.fmt.allocPrint(a, "{{\"same_as\":\"{s}\"}}", .{hash}), .{});
    var replacement_meta = meta;
    replacement_meta.meta = .{ .start_ms_epoch = 200, .end = .ok };
    const data = try std.fmt.allocPrint(a, "{f}\n{f}\n{f}\n{f}\n", .{
        std.json.fmt(original, .{ .emit_null_optional_fields = false }),
        std.json.fmt(meta, .{ .emit_null_optional_fields = false }),
        std.json.fmt(replacement, .{ .emit_null_optional_fields = false }),
        std.json.fmt(replacement_meta, .{ .emit_null_optional_fields = false }),
    });
    var runs: std.ArrayList(Run) = .empty;
    try loadCalls(a, data, &runs);
    try t.expectEqual(@as(usize, 1), runs.items.len);
    try t.expectEqual(@as(usize, 1), runs.items[0].calls.items.len);
    try t.expectEqualStrings("grep", runs.items[0].calls.items[0].name);
    try t.expectEqualStrings("{}", runs.items[0].calls.items[0].text);
    try t.expectEqual(@as(i64, 200), runs.items[0].meta.?.start_ms_epoch);
    try t.expectEqual(record.End.ok, runs.items[0].meta.?.end);
    var empty: std.ArrayList(Run) = .empty;
    try loadCalls(a, try std.fmt.allocPrint(a, "{s}{f}\n", .{ data, std.json.fmt(meta, .{ .emit_null_optional_fields = false }) }), &empty);
    try t.expectEqual(@as(usize, 0), empty.items[0].calls.items.len);
    try t.expectEqual(record.End.cancelled, empty.items[0].meta.?.end);
}
