const std = @import("std");
const provider = @import("../provider.zig");

pub const RunResult = struct {
    tool_call_id: []const u8,
    ok: bool,
    run_ms: ?u64 = null,
};

pub const Diagnostic = struct {
    error_name: []const u8,
    message: []const u8,
    attempts: u32,
    step: u32,
};

pub const Record = struct {
    at: ?i64 = null,
    diagnostic: ?Diagnostic = null,
    usage: ?provider.Usage = null,
    effort: ?[]const u8 = null,
    effort_source: ?provider.EffortSource = null,
    effort_downgraded: ?bool = null,
    turn_step: ?u32 = null,
    ms: ?u64 = null,
    model_ms: ?u64 = null,
    attempts: ?u32 = null,
    first_data_ms: ?u64 = null,
    code: ?[]const @import("../provider/timing.zig").Code = null,
    run_ms: ?u64 = null,
    calls: ?[]const @import("../sandbox/timing.zig").Call = null,
    calls_omitted: ?u64 = null,
    run_results: ?[]const RunResult = null,
    nib_version: ?[]const u8 = null,
    system_sha: ?[]const u8 = null,
    patches_off: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    provider: ?provider.Id = null,
    model: ?[]const u8 = null,
    parent_session_id: ?[]const u8 = null,
    from: usize = 0,
    messages: []const provider.Message = &.{},
    context_tokens: u64 = 0,
    repair: bool = false,
};

pub const Log = struct {
    file: std.Io.File,
    offset: u64,
    poisoned: bool = false,
    steps: usize = 0,
    provider: provider.Id = .chat_completions,
    model: ?[]const u8 = null,
    parent_session_id: ?[]const u8 = null,

    pub fn create(io: std.Io, path: []const u8) !Log {
        return .{ .file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = .fromMode(0o600),
        }), .offset = 0 };
    }

    pub fn restore(io: std.Io, gpa: std.mem.Allocator, a: std.mem.Allocator, path: []const u8, history: *std.ArrayList(provider.Message), tokens: *u64) !Log {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true });
        errdefer file.close(io);
        var reader = file.reader(io, &.{});
        const data = try reader.interface.allocRemaining(a, .unlimited);
        const restored = try replay(gpa, a, data, history, tokens);
        var log: Log = .{ .file = file, .offset = data.len, .steps = restored.steps, .parent_session_id = restored.parent_session_id, .provider = restored.provider, .model = restored.model };
        if (restored.needs_repair) {
            try log.append(io, a, .{ .repair = true });
            try log.file.sync(io);
        }
        return log;
    }

    pub fn close(log: *Log, io: std.Io) void {
        log.file.close(io);
    }

    fn append(log: *Log, io: std.Io, a: std.mem.Allocator, record: Record) !void {
        if (log.poisoned) return error.SessionLogFailed;
        var stamped = record;
        stamped.at = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
        const bytes = try std.fmt.allocPrint(a, "{s}{f}\n", .{ if (stamped.repair) "\n" else "", std.json.fmt(stamped, .{ .emit_null_optional_fields = false }) });
        defer a.free(bytes);
        errdefer log.poisoned = true;
        try log.file.writePositionalAll(io, bytes, log.offset);
        log.offset += bytes.len;
    }

    pub fn diagnose(log: *Log, io: std.Io, a: std.mem.Allocator, diagnostic: Diagnostic) !void {
        try log.append(io, a, .{ .diagnostic = diagnostic });
        errdefer log.poisoned = true;
        try log.file.sync(io);
    }

    pub fn commit(log: *Log, io: std.Io, a: std.mem.Allocator, history: *std.ArrayList(provider.Message), tokens: *u64, record: Record) !void {
        if (record.from > history.items.len) return error.InvalidSessionLog;
        try history.ensureTotalCapacity(a, record.from + record.messages.len);
        try log.append(io, a, record);
        if (record.turn_step != null) log.steps += 1;
        apply(history, record);
        tokens.* = record.context_tokens;
        errdefer log.poisoned = true;
        try log.file.sync(io);
    }
};

fn apply(history: *std.ArrayList(provider.Message), record: Record) void {
    history.shrinkRetainingCapacity(record.from);
    history.appendSliceAssumeCapacity(record.messages);
    if (record.effort) |effort| {
        const source = record.effort_source orelse .default;
        for (history.items[record.from..]) |*message| {
            if (std.mem.eql(u8, message.role, "assistant")) message.step_effort = .{ .effort = effort, .source = source };
        }
    }
}

pub fn replay(gpa: std.mem.Allocator, a: std.mem.Allocator, data: []const u8, history: *std.ArrayList(provider.Message), tokens: *u64) !struct { steps: usize, needs_repair: bool, parent_session_id: ?[]const u8, provider: provider.Id, model: ?[]const u8 } {
    var parent_session_id: ?[]const u8 = null;
    var id: provider.Id = .chat_completions;
    var model: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var torn = false;
    var steps: usize = 0;
    while (lines.next()) |line| {
        if (lines.peek() == null) break;
        if (line.len == 0) continue;
        const r = parseRecord(a, line) catch {
            torn = true;
            continue;
        };
        if (history.items.len == 0) {
            parent_session_id = r.parent_session_id;
            id = r.provider orelse .chat_completions;
        }
        if (r.model) |m| model = m;
        if (r.repair) {
            torn = false;
            continue;
        }
        if (torn) return error.InvalidSessionLog;
        if (r.diagnostic != null) continue;
        if (r.turn_step != null) steps += 1;
        if (r.from > history.items.len) return error.InvalidSessionLog;
        try history.ensureTotalCapacity(gpa, r.from + r.messages.len);
        apply(history, r);
        try validate(history.items);
        tokens.* = r.context_tokens;
    }
    if (history.items.len == 0) return error.InvalidSessionLog;
    return .{ .steps = steps, .needs_repair = torn or data[data.len - 1] != '\n', .parent_session_id = parent_session_id, .provider = id, .model = model };
}

fn parseRecord(a: std.mem.Allocator, line: []const u8) !Record {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{ .allocate = .alloc_always });
    if (value == .object) if (value.object.get("messages")) |messages| {
        if (messages == .array) for (messages.array.items) |*m| {
            if (m.* != .object) continue;
            if (m.object.get("reasoning_content")) |legacy| {
                _ = m.object.swapRemove("reasoning_content");
                if (legacy != .string) continue;
                var reasoning: std.json.ObjectMap = .{};
                try reasoning.put(a, "provider", .{ .string = "chat_completions" });
                try reasoning.put(a, "data", legacy);
                try m.object.put(a, "reasoning", .{ .object = reasoning });
            }
        };
    };
    return std.json.parseFromValueLeaky(Record, a, value, .{});
}

fn validate(messages: []const provider.Message) !void {
    if (messages.len == 0 or !std.mem.eql(u8, messages[0].role, "system")) return error.InvalidSessionLog;
    var i: usize = 1;
    while (i < messages.len) : (i += 1) {
        const m = messages[i];
        if (std.mem.eql(u8, m.role, "user")) continue;
        if (!std.mem.eql(u8, m.role, "assistant")) return error.InvalidSessionLog;
        for (m.tool_calls orelse &.{}) |call| {
            i += 1;
            if (i >= messages.len or !std.mem.eql(u8, messages[i].role, "tool") or
                !std.mem.eql(u8, messages[i].tool_call_id orelse "", call.id)) return error.InvalidSessionLog;
        }
    }
}

pub const Summary = struct {
    id: []const u8,
    path: []const u8,
    modified_ns: i96,
    /// First line of the first user message, at most ~60 bytes.
    preview: []const u8,
};

/// Top-level Sessions started in `cwd` that have a user message, newest first.
pub fn list(io: std.Io, a: std.mem.Allocator, directory: []const u8, cwd: []const u8) ![]Summary {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var found: std.ArrayList(Summary) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl") or std.mem.endsWith(u8, entry.name, ".calls.jsonl")) continue;
        const file = try dir.openFile(io, entry.name, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        var line_no: usize = 0;
        while (line_no < 8) {
            var line: std.Io.Writer.Allocating = .init(a);
            defer line.deinit();
            _ = reader.interface.streamDelimiter(&line.writer, '\n') catch break;
            reader.interface.toss(1);
            const r = std.json.parseFromSliceLeaky(Record, a, line.written(), .{ .allocate = .alloc_always }) catch {
                if (line_no == 0) break;
                line_no += 1;
                continue;
            };
            if (r.diagnostic != null) continue;
            const header = line_no == 0;
            line_no += 1;
            if (header) {
                if (r.parent_session_id != null or !std.mem.eql(u8, r.cwd orelse "", cwd)) break;
                continue;
            }
            const user = for (r.messages) |m| {
                if (std.mem.eql(u8, m.role, "user")) break m.content orelse "";
            } else continue;
            try found.append(a, .{
                .id = try a.dupe(u8, std.fs.path.stem(entry.name)),
                .path = try std.fs.path.join(a, &.{ directory, entry.name }),
                .modified_ns = stat.mtime.nanoseconds,
                .preview = firstLine(user, 60),
            });
            break;
        }
    }
    std.mem.sort(Summary, found.items, {}, struct {
        fn newer(_: void, l: Summary, r: Summary) bool {
            return l.modified_ns > r.modified_ns;
        }
    }.newer);
    return found.items;
}

fn firstLine(text: []const u8, max: usize) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const line = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
    if (line.len <= max) return line;
    var end = max;
    while (end > 0 and (line[end] & 0xC0) == 0x80) end -= 1;
    return line[0..end];
}

pub fn latest(io: std.Io, a: std.mem.Allocator, directory: []const u8, cwd: []const u8) ![]const u8 {
    const all = try list(io, a, directory, cwd);
    if (all.len == 0) return error.NoSession;
    return all[0].path;
}

test "list finds top-level sessions with messages for a directory, newest first" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(t.io, .{ .sub_path = "aaaa.jsonl", .data = "{\"cwd\":\"/w\",\"messages\":[{\"role\":\"system\",\"content\":\"s\"}]}\n{\"from\":1,\"messages\":[{\"role\":\"user\",\"content\":\"first question\\nmore\"}]}\n" });
    try std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(20), .clock = .awake }, t.io);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bbbb.jsonl", .data = "{\"cwd\":\"/w\",\"messages\":[{\"role\":\"system\",\"content\":\"s\"}]}\n{\"from\":1,\"messages\":[{\"role\":\"user\",\"content\":\"second\"}]}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "empty.jsonl", .data = "{\"cwd\":\"/w\",\"messages\":[{\"role\":\"system\",\"content\":\"s\"}]}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "child.jsonl", .data = "{\"cwd\":\"/w\",\"parent_session_id\":\"aaaa\",\"messages\":[]}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "other.jsonl", .data = "{\"cwd\":\"/elsewhere\",\"messages\":[]}\n" });
    const all = try list(t.io, a, dir, "/w");
    try t.expectEqual(@as(usize, 2), all.len);
    try t.expectEqualStrings("bbbb", all[0].id);
    try t.expectEqualStrings("second", all[0].preview);
    try t.expectEqualStrings("aaaa", all[1].id);
    try t.expectEqualStrings("first question", all[1].preview);
    try t.expectEqualStrings(all[0].path, try latest(t.io, a, dir, "/w"));
}

test "commit and replay preserve safe history, compaction and torn tail" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/s.jsonl", .{tmp.sub_path});
    var log = try Log.create(t.io, path);
    var history: std.ArrayList(provider.Message) = .empty;
    const before = @divFloor(std.Io.Clock.real.now(t.io).nanoseconds, std.time.ns_per_ms);
    const records = [_]Record{
        .{ .at = 1, .cwd = "/work", .messages = &.{.{ .role = "system", .content = "base" }} },
        .{ .from = 1, .messages = &.{ .{ .role = "user", .content = "hi" }, .{ .role = "assistant", .tool_calls = &.{.{ .id = "c", .function = .{ .name = "run", .arguments = "{}" } }} }, .{ .role = "tool", .content = "ok", .tool_call_id = "c" } }, .context_tokens = 100, .usage = .{ .prompt_tokens = 90, .completion_tokens = 10, .prompt_cache_hit_tokens = 20 }, .ms = 42, .run_results = &.{.{ .tool_call_id = "c", .ok = false }} },
        .{ .from = 1, .messages = &.{.{ .role = "user", .content = "summary" }}, .context_tokens = 10 },
        .{ .from = 2, .messages = &.{ .{ .role = "user", .content = "interrupted" }, .{ .role = "assistant", .content = "partial\n\n[interrupted by user]" } }, .context_tokens = 10 },
    };
    var committed_tokens: u64 = 0;
    for (records) |r| {
        try log.commit(t.io, a, &history, &committed_tokens, r);
        const data = try tmp.dir.readFileAlloc(t.io, "s.jsonl", a, .unlimited);
        var restored: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        _ = try replay(a, a, data, &restored, &tokens);
        try t.expectEqualDeep(history.items, restored.items);
        try t.expectEqual(r.context_tokens, tokens);
    }
    try log.file.writePositionalAll(t.io, "{\"from\":\n{\"repair\":", log.offset);
    log.close(t.io);
    var restored: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    log = try Log.restore(t.io, a, a, path, &restored, &tokens);
    defer log.close(t.io);
    try t.expectEqualDeep(history.items, restored.items);
    try log.commit(t.io, a, &restored, &tokens, .{ .from = restored.items.len, .messages = &.{.{ .role = "assistant", .content = "next" }} });
    var again: std.ArrayList(provider.Message) = .empty;
    const data = try tmp.dir.readFileAlloc(t.io, "s.jsonl", a, .unlimited);
    const after = @divFloor(std.Io.Clock.real.now(t.io).nanoseconds, std.time.ns_per_ms);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var stamped_count: usize = 0;
    var repairs: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const record = parseRecord(a, line) catch continue;
        try t.expect(record.at != null);
        const at = record.at.?;
        try t.expect(at >= before and at <= after);
        stamped_count += 1;
        if (record.repair) repairs += 1;
    }
    try t.expectEqual(records.len + 2, stamped_count);
    try t.expectEqual(@as(usize, 1), repairs);
    const result = try replay(a, a, data, &again, &tokens);
    try t.expect(!result.needs_repair);
    try t.expectEqualDeep(restored.items, again.items);
}

test "replay rejects dangling tool calls and unrepaired interior corruption" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    const header = "{\"messages\":[{\"role\":\"system\",\"content\":\"base\"}]}\n";
    const dangling = header ++ "{\"from\":1,\"messages\":[{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"c\",\"function\":{\"name\":\"run\",\"arguments\":\"{}\"}}]}]}\n";
    try t.expectError(error.InvalidSessionLog, replay(a, a, dangling, &history, &tokens));
    history.clearRetainingCapacity();
    const corrupt = header ++ "broken\n{\"from\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}\n";
    try t.expectError(error.InvalidSessionLog, replay(a, a, corrupt, &history, &tokens));
}

test "legacy chat reasoning is migrated without changing provider identity" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var history: std.ArrayList(provider.Message) = .empty;
    defer history.deinit(t.allocator);
    var tokens: u64 = 0;
    try t.expectEqual(@as(?i64, null), (try parseRecord(arena.allocator(), "{}")).at);
    try t.expectEqual(@as(?i64, null), (try parseRecord(arena.allocator(), "{\"at\":null}")).at);
    const result = try replay(t.allocator, arena.allocator(),
        \\{"from":0,"messages":[{"role":"system","content":"s"}]}
        \\{"from":1,"messages":[{"role":"user","content":"u"},{"role":"assistant","content":"a","reasoning_content":"legacy"}]}
        \\
    , &history, &tokens);
    try t.expectEqual(provider.Id.chat_completions, result.provider);
    try t.expectEqualDeep(provider.Reasoning{ .provider = .chat_completions, .data = "legacy" }, history.items[2].reasoning.?);
}

test "diagnostic append and replay do not commit messages or replace context tokens" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/s.jsonl", .{tmp.sub_path});
    var log = try Log.create(t.io, path);
    defer log.close(t.io);
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    try log.commit(t.io, a, &history, &tokens, .{ .cwd = "/work", .messages = &.{.{ .role = "system", .content = "base" }}, .context_tokens = 123 });
    const before = @divFloor(std.Io.Clock.real.now(t.io).nanoseconds, std.time.ns_per_ms);
    for (0..10) |_| try log.diagnose(t.io, a, .{ .error_name = "ProviderTransient", .message = "server_error: mock failure", .attempts = 5, .step = 1 });
    const after = @divFloor(std.Io.Clock.real.now(t.io).nanoseconds, std.time.ns_per_ms);
    const data = try tmp.dir.readFileAlloc(t.io, "s.jsonl", a, .unlimited);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var diagnostics: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const record = try parseRecord(a, line);
        if (record.diagnostic == null) continue;
        try t.expect(record.at != null);
        const at = record.at.?;
        try t.expect(at >= before and at <= after);
        diagnostics += 1;
    }
    try t.expectEqual(@as(usize, 10), diagnostics);
    try t.expectEqual(@as(usize, 1), history.items.len);
    try t.expectEqual(@as(u64, 123), tokens);
    var restored: std.ArrayList(provider.Message) = .empty;
    var restored_tokens: u64 = 0;
    _ = try replay(a, a, try tmp.dir.readFileAlloc(t.io, "s.jsonl", a, .unlimited), &restored, &restored_tokens);
    try t.expectEqualDeep(history.items, restored.items);
    try t.expectEqual(tokens, restored_tokens);
    try log.commit(t.io, a, &history, &tokens, .{ .from = 1, .messages = &.{ .{ .role = "user", .content = "next" }, .{ .role = "assistant", .content = "ok" } }, .context_tokens = 200 });
    restored.clearRetainingCapacity();
    _ = try replay(a, a, try tmp.dir.readFileAlloc(t.io, "s.jsonl", a, .unlimited), &restored, &restored_tokens);
    try t.expectEqualDeep(history.items, restored.items);
    try t.expectEqual(tokens, restored_tokens);
    const summaries = try list(t.io, a, std.fs.path.dirname(path).?, "/work");
    try t.expectEqual(@as(usize, 1), summaries.len);
    try t.expectEqualStrings("next", summaries[0].preview);
}

test "timing fields are optional and replay preserves mixed old and measured Steps" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const legacy = try parseRecord(a,
        \\{"from":1,"messages":[{"role":"assistant","content":"old"}],"ms":10,"run_results":[]}
    );
    try t.expectEqual(@as(?u64, null), legacy.model_ms);
    try t.expectEqual(@as(?u32, null), legacy.attempts);
    try t.expectEqual(@as(?u64, null), legacy.first_data_ms);
    try t.expect(legacy.code == null and legacy.calls == null and legacy.run_ms == null and legacy.calls_omitted == null);
    const measured: Record = .{
        .from = 2,
        .messages = &.{.{ .role = "assistant", .content = "new" }},
        .context_tokens = 99,
        .ms = 80,
        .model_ms = 60,
        .attempts = 2,
        .first_data_ms = 3,
        .code = &.{.{ .tool_call_id = "c", .first_ms = 5, .last_ms = 55, .progress = &.{ .{ 5, 1 }, .{ 55, 20 } } }},
        .run_ms = 20,
        .calls = &.{.{ .name = "read", .start_ms = 1, .end_ms = 19, .ok = true, .run_index = 0 }},
        .calls_omitted = 4,
        .run_results = &.{.{ .tool_call_id = "c", .ok = true, .run_ms = 20 }},
    };
    const encoded = try std.json.Stringify.valueAlloc(a, measured, .{ .emit_null_optional_fields = false });
    const restored = try parseRecord(a, encoded);
    try t.expectEqual(@as(?u64, 60), restored.model_ms);
    try t.expectEqual(@as(?u32, 2), restored.attempts);
    try t.expectEqual([2]u64{ 55, 20 }, restored.code.?[0].progress[1]);
    try t.expectEqualStrings("read", restored.calls.?[0].name);
    try t.expectEqual(@as(?u64, 4), restored.calls_omitted);
    try t.expectEqual(@as(?u64, 20), restored.run_results.?[0].run_ms);
    const data = try std.fmt.allocPrint(a,
        \\{{"from":0,"messages":[{{"role":"system","content":"base"}}]}}
        \\{f}
        \\{s}
        \\
    , .{ std.json.fmt(legacy, .{ .emit_null_optional_fields = false }), encoded });
    var history: std.ArrayList(provider.Message) = .empty;
    defer history.deinit(t.allocator);
    var tokens: u64 = 0;
    _ = try replay(t.allocator, a, data, &history, &tokens);
    try t.expectEqual(@as(usize, 3), history.items.len);
    try t.expectEqualStrings("old", history.items[1].content.?);
    try t.expectEqualStrings("new", history.items[2].content.?);
    try t.expectEqual(@as(u64, 99), tokens);
}

test "Step effort restores from Record and survives compacted message snapshots" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: Record = .{ .messages = &.{
        .{ .role = "system", .content = "base" },
        .{ .role = "user", .content = "task" },
        .{ .role = "assistant", .content = "legacy" },
    } };
    const step: Record = .{ .from = 3, .effort = "high", .effort_source = .guard, .context_tokens = 99, .messages = &.{
        .{ .role = "assistant", .content = "new", .step_effort = .{ .effort = "low", .source = .model } },
    } };
    const data = try std.fmt.allocPrint(a, "{f}\n{f}\n", .{ std.json.fmt(base, .{ .emit_null_optional_fields = false }), std.json.fmt(step, .{ .emit_null_optional_fields = false }) });
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    _ = try replay(a, a, data, &history, &tokens);
    try t.expect(history.items[2].step_effort == null);
    try t.expectEqualStrings("high", history.items[3].step_effort.?.effort);
    try t.expectEqual(provider.EffortSource.guard, history.items[3].step_effort.?.source);
    const compacted: Record = .{ .from = 0, .messages = history.items, .context_tokens = 20 };
    const compacted_data = try std.fmt.allocPrint(a, "{s}{f}\n", .{ data, std.json.fmt(compacted, .{ .emit_null_optional_fields = false }) });
    var restored: std.ArrayList(provider.Message) = .empty;
    _ = try replay(a, a, compacted_data, &restored, &tokens);
    try t.expectEqualDeep(history.items, restored.items);
    try t.expectEqual(@as(u64, 20), tokens);
    const old = try parseRecord(a, "{\"messages\":[{\"role\":\"assistant\",\"content\":\"old\"}]}");
    try t.expect(old.effort == null and old.effort_source == null);
    try t.expect(old.messages[0].step_effort == null);
}
