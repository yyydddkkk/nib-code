const std = @import("std");
const provider = @import("../provider.zig");

pub const RunResult = struct {
    tool_call_id: []const u8,
    ok: bool,
    run_ms: ?u64 = null,
    tool_bytes: ?u64 = null,
    output_bytes: ?u64 = null,
    remaining_steps: ?usize = null,
    calls_omitted: ?u64 = null,
};

pub const Diagnostic = struct {
    error_name: []const u8,
    message: []const u8,
    attempts: u32,
    step: u32,
};

pub const AgentSession = struct {
    id: []const u8,
    session: []const u8,
    fork: bool = false,
};

pub const RaceBranch = struct {
    id: []const u8,
    state: @FieldType(@import("events.zig").Progress, "state") = .queued,
    elapsed_ms: i64 = 0,
    usage: provider.Usage = .{},
    @"error": ?[]const u8 = null,
};

pub const Race = struct {
    state: enum { started, finished },
    branches: []const RaceBranch,
    winner: ?[]const u8 = null,
    applied: ?bool = null,
    elapsed_ms: i64 = 0,
    win_ms: ?i64 = null,
    usage: provider.Usage = .{},
    patch: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

pub const ForkedFrom = struct {
    session: []const u8,
    message_count: usize,
};

pub const Record = struct {
    at: ?i64 = null,
    diagnostic: ?Diagnostic = null,
    race: ?Race = null,
    agent_session: ?AgentSession = null,
    background: ?@import("events.zig").Background = null,
    usage: ?provider.Usage = null,
    effort: ?[]const u8 = null,
    effort_source: ?provider.EffortSource = null,
    effort_downgraded: ?bool = null,
    turn_step: ?u32 = null,
    ms: ?u64 = null,
    model_ms: ?u64 = null,
    attempts: ?u32 = null,
    first_data_ms: ?u64 = null,
    max_gap_ms: ?u64 = null,
    code: ?[]const @import("../provider/timing.zig").Code = null,
    run_ms: ?u64 = null,
    tool_bytes: ?u64 = null,
    output_bytes: ?u64 = null,
    calls: ?[]const @import("../sandbox/timing.zig").Call = null,
    calls_omitted: ?u64 = null,
    task_ids: ?@import("events.zig").TaskIds = null,
    run_results: ?[]const RunResult = null,
    nib_version: ?[]const u8 = null,
    system_sha: ?[]const u8 = null,
    patches_off: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    provider: ?provider.Id = null,
    model: ?[]const u8 = null,
    parent_session_id: ?[]const u8 = null,
    cache_key: ?[]const u8 = null,
    forked_from: ?ForkedFrom = null,
    from: usize = 0,
    messages: []const provider.Message = &.{},
    context_tokens: u64 = 0,
    repair: bool = false,
};

pub const Log = struct {
    file: std.Io.File,
    mutex: std.Io.Mutex = .init,
    next_agent_id: u64 = 1,
    next_bash_id: u64 = 1,
    agent_sessions: []const AgentSession = &.{},
    lost_background: []const @import("events.zig").Background = &.{},
    pending_background_bytes: u64 = 0,
    offset: u64,
    poisoned: bool = false,
    steps: usize = 0,
    provider: provider.Id = .chat_completions,
    model: ?[]const u8 = null,
    parent_session_id: ?[]const u8 = null,
    cache_key: ?[]const u8 = null,
    forked_from: ?ForkedFrom = null,

    pub fn create(io: std.Io, path: []const u8) !Log {
        return .{ .file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = .fromMode(0o600),
        }), .offset = 0 };
    }

    pub fn restore(io: std.Io, gpa: std.mem.Allocator, a: std.mem.Allocator, path: []const u8, history: *std.ArrayList(provider.Message), tokens: *u64, expected_parent: ?[]const u8) !Log {
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true }) catch |err| return if (err == error.WouldBlock) error.SessionBusy else err;
        errdefer file.close(io);
        var reader = file.reader(io, &.{});
        const data = try reader.interface.allocRemaining(a, .unlimited);
        const restored = try replay(gpa, a, data, history, tokens);
        if (expected_parent) |parent| {
            if (!std.mem.eql(u8, parent, restored.parent_session_id orelse "")) return error.AgentSessionParentMismatch;
        }
        var log: Log = .{ .file = file, .offset = data.len, .parent_session_id = restored.parent_session_id, .cache_key = restored.cache_key, .forked_from = restored.forked_from, .provider = restored.provider, .model = restored.model, .steps = restored.steps, .next_agent_id = restored.next_agent_id, .next_bash_id = restored.next_bash_id, .agent_sessions = restored.agent_sessions, .lost_background = restored.lost_background, .pending_background_bytes = restored.pending_background_bytes };
        if (restored.needs_repair) try log.append(io, a, .{ .repair = true });
        for (restored.background_repairs) |event| try log.append(io, a, .{ .background = event });
        if (restored.needs_repair or restored.background_repairs.len != 0) try log.file.sync(io);
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

    pub fn background(log: *Log, io: std.Io, a: std.mem.Allocator, event: @import("events.zig").Background, step: u32) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        try log.append(io, a, .{ .background = event, .turn_step = step });
        errdefer log.poisoned = true;
        try log.file.sync(io);
    }

    pub fn race(log: *Log, io: std.Io, a: std.mem.Allocator, event: Race, step: u32) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        try log.append(io, a, .{ .race = event, .turn_step = step });
        errdefer log.poisoned = true;
        try log.file.sync(io);
    }

    pub fn agentSession(log: *Log, io: std.Io, a: std.mem.Allocator, mapping: AgentSession) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        try log.append(io, a, .{ .agent_session = mapping });
        errdefer log.poisoned = true;
        try log.file.sync(io);
    }

    pub fn diagnose(log: *Log, io: std.Io, a: std.mem.Allocator, diagnostic: Diagnostic) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        try log.append(io, a, .{ .diagnostic = diagnostic });
        errdefer log.poisoned = true;
        try log.file.sync(io);
    }

    pub fn commit(log: *Log, io: std.Io, a: std.mem.Allocator, history: *std.ArrayList(provider.Message), tokens: *u64, record: Record) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        if (record.from > history.items.len) return error.InvalidSessionLog;
        try history.ensureTotalCapacity(a, record.from + record.messages.len);
        try log.append(io, a, record);
        if (record.from == history.items.len and record.forked_from == null) log.steps += assistantCount(record.messages);
        apply(history, record);
        tokens.* = record.context_tokens;
        errdefer log.poisoned = true;
        try log.file.sync(io);
    }
};

fn assistantCount(messages: []const provider.Message) usize {
    var count: usize = 0;
    for (messages) |message| if (std.mem.eql(u8, message.role, "assistant")) {
        count += 1;
    };
    return count;
}

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

fn restoreToolSummaries(a: std.mem.Allocator, history: []provider.Message, record: Record) !void {
    const calls = record.calls orelse return;
    for (record.messages, record.from..) |assistant, message_index| {
        const runs = assistant.tool_calls orelse continue;
        var unassigned = record.calls_omitted orelse 0;
        for (record.run_results orelse &.{}) |result| {
            if (result.calls_omitted) |omitted| unassigned -|= omitted;
        }
        if (runs.len > 1 and unassigned > 0) history[message_index].step_calls_omitted = unassigned;
        for (runs, 0..) |run, run_index| {
            var omitted: u64 = if (runs.len == 1) record.calls_omitted orelse 0 else 0;
            for (record.run_results orelse &.{}) |result| {
                if (std.mem.eql(u8, result.tool_call_id, run.id)) {
                    omitted = result.calls_omitted orelse omitted;
                    break;
                }
            }
            for (history[record.from..]) |*message| {
                if (std.mem.eql(u8, message.role, "tool") and std.mem.eql(u8, message.tool_call_id orelse "", run.id)) {
                    message.tool_summary = try @import("tool_summary.zig").Summary.init(a, calls, run_index, omitted);
                    break;
                }
            }
        }
    }
}

pub fn replay(gpa: std.mem.Allocator, a: std.mem.Allocator, data: []const u8, history: *std.ArrayList(provider.Message), tokens: *u64) !struct { needs_repair: bool, steps: usize, parent_session_id: ?[]const u8, cache_key: ?[]const u8, forked_from: ?ForkedFrom, provider: provider.Id, model: ?[]const u8, next_agent_id: u64, next_bash_id: u64, agent_sessions: []const AgentSession, lost_background: []const @import("events.zig").Background, background_repairs: []const @import("events.zig").Background, pending_background_bytes: u64 } {
    var parent_session_id: ?[]const u8 = null;
    var cache_key: ?[]const u8 = null;
    var forked_from: ?ForkedFrom = null;
    var next_agent_id: u64 = 1;
    var next_bash_id: u64 = 1;
    var pending_background_bytes: u64 = 0;
    var agent_sessions: std.ArrayList(AgentSession) = .empty;
    defer agent_sessions.deinit(a);
    const Pending = struct { event: @import("events.zig").Background, delivered: bool = false };
    var pending_background: std.ArrayList(Pending) = .empty;
    defer pending_background.deinit(a);
    var id: provider.Id = .chat_completions;
    var model: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var torn = false;
    var steps: usize = 0;
    while (lines.next()) |line| {
        if (lines.peek() == null) break;
        if (line.len == 0) continue;
        const r = parseRecord(a, line) catch |err| {
            if (err == error.OutOfMemory) return err;
            torn = true;
            continue;
        };
        if (history.items.len == 0) {
            parent_session_id = r.parent_session_id;
            cache_key = r.cache_key;
            forked_from = r.forked_from;
            id = r.provider orelse .chat_completions;
        }
        if (r.model) |m| model = m;
        if (r.repair) {
            torn = false;
            continue;
        }
        if (torn) return error.InvalidSessionLog;
        for (r.calls orelse &.{}) |call| if (call.id) |call_id| {
            try restoreId(call_id, &next_agent_id, &next_bash_id);
        };
        if (r.task_ids) |ids| {
            next_agent_id = @max(next_agent_id, std.math.add(u64, ids.agent, 1) catch return error.InvalidSessionLog);
            next_bash_id = @max(next_bash_id, std.math.add(u64, ids.bash, 1) catch return error.InvalidSessionLog);
        }
        if (r.race) |event| {
            for (event.branches) |branch| try restoreId(branch.id, &next_agent_id, &next_bash_id);
            continue;
        }
        if (r.agent_session) |mapping| {
            try restoreId(mapping.id, &next_agent_id, &next_bash_id);
            try agent_sessions.append(a, mapping);
            continue;
        }
        if (r.background) |b| {
            try restoreId(b.id, &next_agent_id, &next_bash_id);
            if (b.state == .started) {
                try pending_background.append(a, .{ .event = b });
            } else {
                for (pending_background.items, 0..) |pending, i| {
                    if (std.mem.eql(u8, pending.event.id, b.id)) {
                        _ = pending_background.orderedRemove(i);
                        break;
                    }
                }
            }
            continue;
        }
        for (r.messages) |m| if (m.source == .background) {
            if (m.background_id) |background_id| {
                for (pending_background.items) |*pending| {
                    if (!pending.delivered and std.mem.eql(u8, pending.event.id, background_id)) {
                        pending.delivered = true;
                        // Finished deliveries carry ok; lost deliveries leave it null.
                        pending.event = .{ .id = pending.event.id, .kind = pending.event.kind, .state = if (m.background_ok != null) .finished else .lost, .ok = m.background_ok };
                        break;
                    }
                }
            }
        };
        if (r.diagnostic != null) continue;
        if (r.from > history.items.len) return error.InvalidSessionLog;
        try history.ensureTotalCapacity(gpa, r.from + r.messages.len);
        if (r.from == history.items.len and r.forked_from == null) {
            steps += assistantCount(r.messages);
            for (r.messages) |message| if (message.source == .background) {
                if (message.content) |text| pending_background_bytes += text.len;
            };
            if (r.model_ms != null) pending_background_bytes = 0;
        }
        apply(history, r);
        try restoreToolSummaries(a, history.items, r);
        try validate(history.items);
        tokens.* = r.context_tokens;
    }
    if (history.items.len == 0) return error.InvalidSessionLog;
    var lost_background: std.ArrayList(@import("events.zig").Background) = .empty;
    defer lost_background.deinit(a);
    var background_repairs: std.ArrayList(@import("events.zig").Background) = .empty;
    defer background_repairs.deinit(a);
    for (pending_background.items) |pending| {
        if (pending.delivered) {
            try background_repairs.append(a, pending.event);
        } else try lost_background.append(a, pending.event);
    }
    return .{ .steps = steps, .needs_repair = torn or data[data.len - 1] != '\n', .parent_session_id = parent_session_id, .cache_key = cache_key, .forked_from = forked_from, .provider = id, .model = model, .next_agent_id = next_agent_id, .next_bash_id = next_bash_id, .agent_sessions = try agent_sessions.toOwnedSlice(a), .lost_background = try lost_background.toOwnedSlice(a), .background_repairs = try background_repairs.toOwnedSlice(a), .pending_background_bytes = pending_background_bytes };
}

fn restoreId(id: []const u8, next_agent: *u64, next_bash: *u64) !void {
    if (id.len < 2 or (id[0] != 'a' and id[0] != 'b')) return;
    const number = std.fmt.parseInt(u64, id[1..], 10) catch return error.InvalidSessionLog;
    const next = if (id[0] == 'a') next_agent else next_bash;
    next.* = @max(next.*, std.math.add(u64, number, 1) catch return error.InvalidSessionLog);
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
    try tmp.dir.createDir(t.io, "private.calls.jsonl", .default_dir);
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
    log = try Log.restore(t.io, a, a, path, &restored, &tokens, null);
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
    try t.expect(legacy.tool_bytes == null and legacy.output_bytes == null);
    try t.expectEqual(@as(?u32, null), legacy.attempts);
    try t.expectEqual(@as(?u64, null), legacy.first_data_ms);
    try t.expectEqual(@as(?u64, null), legacy.max_gap_ms);
    try t.expect(legacy.code == null and legacy.calls == null and legacy.run_ms == null and legacy.calls_omitted == null);
    const measured: Record = .{
        .from = 2,
        .messages = &.{.{ .role = "assistant", .content = "new" }},
        .context_tokens = 99,
        .ms = 80,
        .model_ms = 60,
        .attempts = 2,
        .first_data_ms = 3,
        .max_gap_ms = 17,
        .code = &.{.{ .tool_call_id = "c", .first_ms = 5, .last_ms = 55, .progress = &.{ .{ 5, 1 }, .{ 55, 20 } } }},
        .run_ms = 20,
        .tool_bytes = 4000,
        .output_bytes = 12,
        .calls = &.{.{ .name = "read", .start_ms = 1, .end_ms = 19, .ok = true, .run_index = 0, .result_bytes = 4000 }},
        .calls_omitted = 4,
        .run_results = &.{.{ .tool_call_id = "c", .ok = true, .run_ms = 20, .tool_bytes = 4000, .output_bytes = 12 }},
    };
    const encoded = try std.json.Stringify.valueAlloc(a, measured, .{ .emit_null_optional_fields = false });
    const restored = try parseRecord(a, encoded);
    try t.expectEqual(@as(?u64, 60), restored.model_ms);
    try t.expectEqual(@as(?u32, 2), restored.attempts);
    try t.expectEqual(@as(?u64, 17), restored.max_gap_ms);
    try t.expectEqual([2]u64{ 55, 20 }, restored.code.?[0].progress[1]);
    try t.expectEqualStrings("read", restored.calls.?[0].name);
    try t.expectEqual(@as(?u64, 4), restored.calls_omitted);
    try t.expectEqual(@as(?u64, 20), restored.run_results.?[0].run_ms);
    try t.expectEqual(@as(?u64, 4000), restored.tool_bytes);
    try t.expectEqual(@as(?u64, 12), restored.output_bytes);
    try t.expectEqual(restored.tool_bytes, restored.calls.?[0].result_bytes);
    try t.expectEqual(restored.tool_bytes, restored.run_results.?[0].tool_bytes);
    try t.expectEqual(restored.output_bytes, restored.run_results.?[0].output_bytes);
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
    const restored_log = try replay(a, a, compacted_data, &restored, &tokens);
    try t.expectEqual(@as(usize, 2), restored_log.steps);
    try t.expectEqualDeep(history.items, restored.items);
    try t.expectEqual(@as(u64, 20), tokens);
    const old = try parseRecord(a, "{\"messages\":[{\"role\":\"assistant\",\"content\":\"old\"}]}");
    try t.expect(old.effort == null and old.effort_source == null);
    try t.expect(old.messages[0].step_effort == null);
}

test "child restore checks parent before repairing and keeps the session exclusively locked" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/child.jsonl", .{tmp.sub_path});
    const data = "{\"parent_session_id\":\"parent\",\"messages\":[{\"role\":\"system\",\"content\":\"child system\"}]}\n{\"from\":";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "child.jsonl", .data = data });
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    try t.expectError(error.AgentSessionParentMismatch, Log.restore(t.io, a, a, path, &history, &tokens, "other"));
    try t.expectEqualStrings(data, try tmp.dir.readFileAlloc(t.io, "child.jsonl", a, .unlimited));
    history = .empty;
    var log = try Log.restore(t.io, a, a, path, &history, &tokens, "parent");
    defer log.close(t.io);
    try t.expectEqualStrings("parent", log.parent_session_id.?);
    try t.expectEqualStrings("child system", history.items[0].content.?);
    var concurrent: std.ArrayList(provider.Message) = .empty;
    try t.expectError(error.SessionBusy, Log.restore(t.io, a, a, path, &concurrent, &tokens, "parent"));
}

test "replay restores independent ID maxima from every background state and foreground call" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    const records = [_]Record{
        .{ .messages = &.{.{ .role = "system", .content = "base" }} },
        .{ .background = .{ .id = "a3", .kind = .agent, .state = .started } },
        .{ .background = .{ .id = "a8", .kind = .agent, .state = .finished } },
        .{ .background = .{ .id = "b12", .kind = .bash, .state = .lost } },
        .{ .background = .{ .id = "b2", .kind = .bash, .state = .started } },
        .{ .background = .{ .id = "b2", .kind = .bash, .state = .finished } },
        .{ .from = 1, .calls = &.{
            .{ .name = "agent", .id = "a10", .background = false, .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 0 },
            .{ .name = "bash", .id = "b6", .background = false, .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 0 },
        } },
        .{ .from = 1, .messages = &.{.{ .role = "user", .content = "compacted" }} },
    };
    for (records) |record| try encoded.writer.print("{f}\n", .{std.json.fmt(record, .{ .emit_null_optional_fields = false })});
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    const restored = try replay(a, a, encoded.written(), &history, &tokens);
    try t.expectEqual(@as(u64, 11), restored.next_agent_id);
    try t.expectEqual(@as(u64, 13), restored.next_bash_id);
    try t.expectEqual(@as(usize, 1), restored.lost_background.len);
    try t.expectEqualStrings("a3", restored.lost_background[0].id);
    var progress: @import("../tools/progress.zig").Queue = .{ .next_agent_id = restored.next_agent_id, .next_bash_id = restored.next_bash_id };
    defer progress.deinit(t.allocator);
    try t.expectEqualStrings("a11", try progress.add(t.allocator, t.io, .agent, "resumed", 1, false));
    try t.expectEqualStrings("b13", try progress.add(t.allocator, t.io, .bash, "resumed", 1, true));
}

test "ID restoration rejects overflow rather than wrapping the session counter" {
    const t = std.testing;
    var next_agent: u64 = 1;
    var next_bash: u64 = 1;
    try t.expectError(error.InvalidSessionLog, restoreId("a18446744073709551615", &next_agent, &next_bash));
    try restoreId("legacy_id", &next_agent, &next_bash);
    try t.expectEqual(@as(u64, 1), next_agent);
    try t.expectEqual(@as(u64, 1), next_bash);
}

test "task ID high water survives omitted calls and later compacted snapshots" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: Record = .{ .messages = &.{.{ .role = "system", .content = "base" }} };
    const overflow: Record = .{ .from = 1, .calls_omitted = 2, .task_ids = .{ .agent = 7, .bash = 12 } };
    const compacted: Record = .{ .messages = base.messages, .task_ids = .{ .agent = 2, .bash = 3 } };
    const data = try std.fmt.allocPrint(a, "{f}\n{f}\n{f}\n", .{ std.json.fmt(base, .{}), std.json.fmt(overflow, .{}), std.json.fmt(compacted, .{}) });
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    const restored = try replay(a, a, data, &history, &tokens);
    try t.expectEqual(@as(u64, 8), restored.next_agent_id);
    try t.expectEqual(@as(u64, 13), restored.next_bash_id);
}

test "race lifecycle preserves history and reserves branch ids without resumable mappings" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: Record = .{ .messages = &.{ .{ .role = "system", .content = "base" }, .{ .role = "user", .content = "task" } }, .context_tokens = 42 };
    const start: Record = .{ .race = .{ .state = .started, .branches = &.{ .{ .id = "a5" }, .{ .id = "a6" } } } };
    const end: Record = .{ .race = .{ .state = .finished, .branches = &.{ .{ .id = "a5" }, .{ .id = "a6" } }, .winner = "a5", .applied = true } };
    const data = try std.fmt.allocPrint(a, "{f}\n{f}\n{f}\n", .{ std.json.fmt(base, .{}), std.json.fmt(start, .{}), std.json.fmt(end, .{}) });
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    const restored = try replay(a, a, data, &history, &tokens);
    try t.expectEqualDeep(base.messages, history.items);
    try t.expectEqual(@as(u64, 42), tokens);
    try t.expectEqual(@as(u64, 7), restored.next_agent_id);
    try t.expectEqual(@as(usize, 0), restored.agent_sessions.len);
}

test "agent session mappings survive snapshots and compaction without changing history" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mappings = [_]AgentSession{
        .{ .id = "a17", .session = "child-17" },
        .{ .id = "a3", .session = "child-3" },
        .{ .id = "a21", .session = "child-21" },
    };
    const records = [_]Record{
        .{ .messages = &.{.{ .role = "system", .content = "base" }}, .context_tokens = 10 },
        .{ .agent_session = mappings[0] },
        .{ .from = 1, .messages = &.{ .{ .role = "user", .content = "task" }, .{ .role = "assistant", .content = "answer" } }, .context_tokens = 100, .task_ids = .{ .agent = 8, .bash = 12 } },
        .{ .messages = &.{ .{ .role = "system", .content = "base" }, .{ .role = "user", .content = "task" }, .{ .role = "assistant", .content = "answer" } }, .context_tokens = 100 },
        .{ .agent_session = mappings[1] },
        .{ .from = 1, .messages = &.{.{ .role = "user", .content = "summary" }}, .context_tokens = 20, .task_ids = .{ .agent = 2, .bash = 3 } },
        .{ .agent_session = mappings[2] },
    };
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    var expected: std.ArrayList(provider.Message) = .empty;
    var mapping_count: usize = 0;
    var expected_tokens: u64 = 0;
    var expected_steps: usize = 0;
    var next_agent: u64 = 1;
    var next_bash: u64 = 1;
    for (records) |record| {
        try encoded.writer.print("{f}\n", .{std.json.fmt(record, .{ .emit_null_optional_fields = false })});
        if (record.agent_session) |mapping| {
            mapping_count += 1;
            try restoreId(mapping.id, &next_agent, &next_bash);
        } else {
            try expected.ensureTotalCapacity(a, record.from + record.messages.len);
            if (record.from == expected.items.len) expected_steps += assistantCount(record.messages);
            apply(&expected, record);
            expected_tokens = record.context_tokens;
        }
        if (record.task_ids) |ids| {
            next_agent = @max(next_agent, ids.agent + 1);
            next_bash = @max(next_bash, ids.bash + 1);
        }
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        const restored = try replay(a, a, encoded.written(), &history, &tokens);
        try t.expectEqualDeep(expected.items, history.items);
        try t.expectEqual(expected_tokens, tokens);
        try t.expectEqualDeep(mappings[0..mapping_count], restored.agent_sessions);
        try t.expectEqual(next_agent, restored.next_agent_id);
        try t.expectEqual(next_bash, restored.next_bash_id);
        try t.expectEqual(expected_steps, restored.steps);
    }
}

test "agentSession append restores mappings and ID high water across repeated resumes" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/parent.jsonl", .{tmp.sub_path});
    const mappings = [_]AgentSession{
        .{ .id = "a9", .session = "child-9" },
        .{ .id = "a4", .session = "child-4" },
        .{ .id = "a27", .session = "child-27" },
    };
    {
        var log = try Log.create(t.io, path);
        defer log.close(t.io);
        try t.expectEqual(@as(usize, 0), log.agent_sessions.len);
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        try log.commit(t.io, a, &history, &tokens, .{ .messages = &.{.{ .role = "system", .content = "base" }}, .context_tokens = 40, .task_ids = .{ .agent = 20, .bash = 30 } });
        try log.agentSession(t.io, a, mappings[0]);
        try log.commit(t.io, a, &history, &tokens, .{ .messages = try a.dupe(provider.Message, history.items), .context_tokens = 12 });
    }
    {
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        var log = try Log.restore(t.io, a, a, path, &history, &tokens, null);
        defer log.close(t.io);
        try t.expectEqualDeep(mappings[0..1], log.agent_sessions);
        try t.expectEqual(@as(u64, 21), log.next_agent_id);
        try t.expectEqual(@as(u64, 31), log.next_bash_id);
        try t.expectEqual(@as(u64, 12), tokens);
        try t.expectEqual(@as(usize, 1), history.items.len);
        try log.agentSession(t.io, a, mappings[1]);
        try log.commit(t.io, a, &history, &tokens, .{ .messages = &.{ .{ .role = "system", .content = "base" }, .{ .role = "user", .content = "summary" } }, .context_tokens = 8, .task_ids = .{ .agent = 2, .bash = 3 } });
        try log.agentSession(t.io, a, mappings[2]);
    }
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    var log = try Log.restore(t.io, a, a, path, &history, &tokens, null);
    defer log.close(t.io);
    try t.expectEqualDeep(&mappings, log.agent_sessions);
    try t.expectEqual(@as(u64, 28), log.next_agent_id);
    try t.expectEqual(@as(u64, 31), log.next_bash_id);
    try t.expectEqual(@as(u64, 8), tokens);
    try t.expectEqual(@as(usize, 2), history.items.len);
    try t.expectEqualStrings("base", history.items[0].content.?);
    try t.expectEqualStrings("summary", history.items[1].content.?);
    log.poisoned = true;
    try t.expectError(error.SessionLogFailed, log.agentSession(t.io, a, .{ .id = "a99", .session = "not-written" }));
}

test "replay matches reused background IDs in FIFO order for finished and lost events" {
    const t = std.testing;
    const Background = @import("events.zig").Background;
    const first: Background = .{ .id = "a1", .kind = .agent, .state = .started, .result = "first" };
    const other: Background = .{ .id = "b1", .kind = .bash, .state = .started };
    const second: Background = .{ .id = "a1", .kind = .agent, .state = .started, .result = "second" };
    for ([_]@FieldType(Background, "state"){ .finished, .lost }) |terminal| {
        for ([_]bool{ false, true }) |delivered| {
            var arena: std.heap.ArenaAllocator = .init(t.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var encoded: std.Io.Writer.Allocating = .init(a);
            defer encoded.deinit();
            const records = [_]Record{
                .{ .messages = &.{.{ .role = "system", .content = "base" }}, .context_tokens = 10 },
                .{ .agent_session = .{ .id = "a1", .session = "child" } },
                .{ .background = first },
                .{ .background = other },
                .{ .background = second },
            };
            for (records) |record| try encoded.writer.print("{f}\n", .{std.json.fmt(record, .{ .emit_null_optional_fields = false })});
            var history: std.ArrayList(provider.Message) = .empty;
            var tokens: u64 = 0;
            const started = try replay(a, a, encoded.written(), &history, &tokens);
            try t.expectEqualDeep(&[_]Background{ first, other, second }, started.lost_background);
            try t.expectEqual(@as(usize, 0), started.background_repairs.len);
            if (delivered) {
                const message: Record = .{ .from = 1, .messages = &.{.{ .role = "user", .content = "first done", .source = .background, .background_id = "a1" }}, .context_tokens = 20 };
                try encoded.writer.print("{f}\n", .{std.json.fmt(message, .{ .emit_null_optional_fields = false })});
                history.clearRetainingCapacity();
                const committed = try replay(a, a, encoded.written(), &history, &tokens);
                try t.expectEqualDeep(&[_]Background{ other, second }, committed.lost_background);
                try t.expectEqualDeep(&[_]Background{.{ .id = first.id, .kind = first.kind, .state = .lost }}, committed.background_repairs);
            }
            const end: Record = .{ .background = .{ .id = "a1", .kind = .agent, .state = terminal } };
            try encoded.writer.print("{f}\n", .{std.json.fmt(end, .{ .emit_null_optional_fields = false })});
            history.clearRetainingCapacity();
            const restored = try replay(a, a, encoded.written(), &history, &tokens);
            try t.expectEqualDeep(&[_]Background{ other, second }, restored.lost_background);
            try t.expectEqual(@as(usize, 0), restored.background_repairs.len);
            try t.expectEqualDeep(&[_]AgentSession{.{ .id = "a1", .session = "child" }}, restored.agent_sessions);
            try t.expectEqual(@as(u64, 2), restored.next_agent_id);
            try t.expectEqual(@as(u64, 2), restored.next_bash_id);
            try t.expectEqual(@as(u64, if (delivered) 20 else 10), tokens);
            try t.expectEqual(@as(usize, if (delivered) 2 else 1), history.items.len);
        }
    }
}

test "restore after background message commit without finished does not redeliver lost" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/background.jsonl", .{tmp.sub_path});
    const started: @import("events.zig").Background = .{ .id = "a1", .kind = .agent, .state = .started };
    {
        var log = try Log.create(t.io, path);
        defer log.close(t.io);
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        try log.commit(t.io, a, &history, &tokens, .{ .messages = &.{.{ .role = "system", .content = "base" }} });
        try log.background(t.io, a, started, 1);
        try log.commit(t.io, a, &history, &tokens, .{ .from = 1, .messages = &.{.{ .role = "user", .content = "first done", .source = .background, .background_id = "a1" }} });
    }
    for (0..2) |attempt| {
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        var log = try Log.restore(t.io, a, a, path, &history, &tokens, null);
        defer log.close(t.io);
        try t.expectEqual(@as(usize, 0), log.lost_background.len);
        try t.expectEqual(@as(usize, 2), history.items.len);
        if (attempt == 1) try log.background(t.io, a, started, 2);
    }
    {
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        var log = try Log.restore(t.io, a, a, path, &history, &tokens, null);
        defer log.close(t.io);
        try t.expectEqualDeep(&[_]@import("events.zig").Background{started}, log.lost_background);
        try log.background(t.io, a, .{ .id = "a1", .kind = .agent, .state = .finished }, 1);
    }
    {
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        var log = try Log.restore(t.io, a, a, path, &history, &tokens, null);
        defer log.close(t.io);
        try t.expectEqual(@as(usize, 0), log.lost_background.len);
        try log.commit(t.io, a, &history, &tokens, .{ .from = 2, .messages = &.{.{ .role = "user", .content = "second done", .source = .background, .background_id = "a1" }} });
    }
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    var log = try Log.restore(t.io, a, a, path, &history, &tokens, null);
    defer log.close(t.io);
    try t.expectEqual(@as(usize, 0), log.lost_background.len);
    try t.expectEqual(@as(usize, 3), history.items.len);
    try t.expectEqual(@as(u64, 2), log.next_agent_id);
}

test "restore closes delivered FIFO entries before delivering a reused ID as lost" {
    const t = std.testing;
    const Background = @import("events.zig").Background;
    const first: Background = .{ .id = "a1", .kind = .agent, .state = .started, .result = "old invocation" };
    const second: Background = .{ .id = "a1", .kind = .agent, .state = .started, .result = "new invocation" };
    for ([_]?bool{ true, false, null }) |ok| {
        for ([_]bool{ false, true }) |torn| {
            var tmp = t.tmpDir(.{});
            defer tmp.cleanup();
            var arena: std.heap.ArenaAllocator = .init(t.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/fifo.jsonl", .{tmp.sub_path});
            var original: std.ArrayList(provider.Message) = .empty;
            var original_tokens: u64 = 0;
            {
                var log = try Log.create(t.io, path);
                defer log.close(t.io);
                try log.commit(t.io, a, &original, &original_tokens, .{ .parent_session_id = "parent", .messages = &.{ .{ .role = "system", .content = "base" }, .{ .role = "assistant", .content = "ready" } }, .context_tokens = 12 });
                try log.background(t.io, a, first, 1);
                try log.background(t.io, a, second, 2);
                try log.commit(t.io, a, &original, &original_tokens, .{ .from = original.items.len, .messages = &.{.{ .role = "user", .content = "opaque result, not lifecycle text", .source = .background, .background_id = "a1", .background_kind = .agent, .background_ok = ok }}, .context_tokens = 37 });
                if (torn) try log.file.writePositionalAll(t.io, "{\"background\":", log.offset);
            }
            const before = try tmp.dir.readFileAlloc(t.io, "fifo.jsonl", a, .unlimited);
            var history: std.ArrayList(provider.Message) = .empty;
            var tokens: u64 = 0;
            try t.expectError(error.AgentSessionParentMismatch, Log.restore(t.io, a, a, path, &history, &tokens, "other"));
            try t.expectEqualStrings(before, try tmp.dir.readFileAlloc(t.io, "fifo.jsonl", a, .unlimited));
            history = .empty;
            const terminal: Background = .{ .id = "a1", .kind = .agent, .state = if (ok != null) .finished else .lost, .ok = ok };
            {
                var log = try Log.restore(t.io, a, a, path, &history, &tokens, "parent");
                defer log.close(t.io);
                try t.expectEqualDeep(&[_]Background{second}, log.lost_background);
                try t.expectEqualDeep(original.items, history.items);
                try t.expectEqual(original_tokens, tokens);
                try t.expectEqual(@as(usize, 1), log.steps);
                try t.expectEqual(@as(u64, 2), log.next_agent_id);
                const repaired = try tmp.dir.readFileAlloc(t.io, "fifo.jsonl", a, .unlimited);
                try t.expect(std.mem.startsWith(u8, repaired, before));
                const end = std.mem.trimEnd(u8, repaired, "\n");
                const last = try parseRecord(a, end[std.mem.lastIndexOfScalar(u8, end, '\n').? + 1 ..]);
                try t.expectEqualDeep(terminal, last.background.?);
                try t.expectEqual(@as(usize, 0), last.messages.len);
                var replayed: std.ArrayList(provider.Message) = .empty;
                var replayed_tokens: u64 = 0;
                const result = try replay(a, a, repaired, &replayed, &replayed_tokens);
                try t.expect(!result.needs_repair);
                try t.expectEqual(@as(usize, 0), result.background_repairs.len);
                try t.expectEqualDeep(&[_]Background{second}, result.lost_background);
                try t.expectEqualDeep(original.items, replayed.items);
                try t.expectEqual(original_tokens, replayed_tokens);
                try t.expectEqual(@as(usize, 1), result.steps);
            }
            const repaired = try tmp.dir.readFileAlloc(t.io, "fifo.jsonl", a, .unlimited);
            history = .empty;
            {
                var log = try Log.restore(t.io, a, a, path, &history, &tokens, "parent");
                defer log.close(t.io);
                try t.expectEqualStrings(repaired, try tmp.dir.readFileAlloc(t.io, "fifo.jsonl", a, .unlimited));
                try t.expectEqualDeep(&[_]Background{second}, log.lost_background);
                try log.commit(t.io, a, &history, &tokens, .{ .from = history.items.len, .messages = &.{.{ .role = "user", .content = "new invocation lost", .source = .background, .background_id = "a1", .background_kind = .agent }}, .context_tokens = 43 });
                try log.background(t.io, a, .{ .id = "a1", .kind = .agent, .state = .lost }, 2);
            }
            const delivered = history.items;
            for (0..2) |_| {
                history = .empty;
                var log = try Log.restore(t.io, a, a, path, &history, &tokens, "parent");
                defer log.close(t.io);
                try t.expectEqual(@as(usize, 0), log.lost_background.len);
                try t.expectEqualDeep(delivered, history.items);
                try t.expectEqual(@as(u64, 43), tokens);
                try t.expectEqual(@as(usize, 1), log.steps);
                try t.expectEqual(@as(u64, 2), log.next_agent_id);
                try t.expectEqual(@as(u64, 1), log.next_bash_id);
            }
        }
    }
}

test "replay carries unbilled background bytes across interrupted Turns and clears on a committed Step" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var history: std.ArrayList(provider.Message) = .empty;
    defer history.deinit(t.allocator);
    var tokens: u64 = 0;
    const waiting =
        \\{"messages":[{"role":"system","content":"s"}]}
        \\{"from":1,"messages":[{"role":"user","content":"你好🙂","source":"background","background_kind":"bash","background_id":"b1"}]}
        \\{"from":2,"messages":[{"role":"assistant","content":"[interrupted by user]"}]}
        \\
    ;
    const pending = try replay(t.allocator, arena.allocator(), waiting, &history, &tokens);
    try t.expectEqual(@as(u64, "你好🙂".len), pending.pending_background_bytes);
    history.clearRetainingCapacity();
    const charged = try replay(t.allocator, arena.allocator(), waiting ++
        \\{"from":3,"model_ms":0,"output_bytes":10,"messages":[{"role":"assistant","content":"received"}]}
        \\
    , &history, &tokens);
    try t.expectEqual(@as(u64, 0), charged.pending_background_bytes);
}

test "pending background bytes count only appended UTF-8 content and clear only on full Steps" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const background: provider.Message = .{ .role = "user", .content = "你好🙂", .source = .background, .background_id = "b1", .background_kind = .bash };
    const bytes: u64 = "你好🙂".len;
    const cases = [_]struct { record: Record, pending: u64 }{
        .{ .record = .{ .messages = &.{.{ .role = "system", .content = "base" }} }, .pending = 0 },
        .{ .record = .{ .from = 1, .messages = &.{ background, .{ .role = "user", .content = "not background", .background_id = "b2", .background_kind = .bash }, .{ .role = "user", .source = .background }, .{ .role = "user", .content = "", .source = .background } } }, .pending = bytes },
        .{ .record = .{ .messages = &.{ .{ .role = "system", .content = "base" }, background } }, .pending = bytes },
        .{ .record = .{ .from = 1, .messages = &.{background}, .model_ms = 0 }, .pending = bytes },
        .{ .record = .{ .from = 1, .messages = &.{.{ .role = "user", .content = "summary" }}, .model_ms = 1 }, .pending = bytes },
        .{ .record = .{ .from = 2, .messages = &.{.{ .role = "assistant", .content = "[interrupted by user]" }}, .ms = 10, .output_bytes = bytes }, .pending = bytes },
        .{ .record = .{ .diagnostic = .{ .error_name = "Canceled", .message = "interrupted", .attempts = 1, .step = 1 }, .model_ms = 0 }, .pending = bytes },
        .{ .record = .{ .agent_session = .{ .id = "a1", .session = "child" }, .model_ms = 0 }, .pending = bytes },
        .{ .record = .{ .background = .{ .id = "b1", .kind = .bash, .state = .finished }, .model_ms = 0 }, .pending = bytes },
        .{ .record = .{ .from = 3, .messages = &.{background} }, .pending = bytes * 2 },
        .{ .record = .{ .from = 4, .messages = &.{ background, .{ .role = "assistant", .content = "received" } }, .model_ms = 0 }, .pending = 0 },
        .{ .record = .{ .messages = &.{ .{ .role = "system", .content = "base" }, background } }, .pending = 0 },
        .{ .record = .{ .from = 2, .messages = &.{background} }, .pending = bytes },
    };
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    for (cases) |case| {
        try encoded.writer.print("{f}\n", .{std.json.fmt(case.record, .{ .emit_null_optional_fields = false })});
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        const restored = try replay(a, a, encoded.written(), &history, &tokens);
        try t.expectEqual(case.pending, restored.pending_background_bytes);
    }
}

test "restore preserves pending background bytes across snapshots and idempotent lifecycle repairs" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/pending.jsonl", .{tmp.sub_path});
    const background: provider.Message = .{ .role = "user", .content = "你好🙂", .source = .background, .background_id = "a1", .background_kind = .agent, .background_ok = true };
    {
        var log = try Log.create(t.io, path);
        defer log.close(t.io);
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        try log.commit(t.io, a, &history, &tokens, .{ .parent_session_id = "parent", .messages = &.{.{ .role = "system", .content = "base" }} });
        try log.agentSession(t.io, a, .{ .id = "a1", .session = "child" });
        try log.background(t.io, a, .{ .id = "a1", .kind = .agent, .state = .started }, 1);
        try log.commit(t.io, a, &history, &tokens, .{ .from = 1, .messages = &.{background}, .context_tokens = 17 });
        try log.commit(t.io, a, &history, &tokens, .{ .messages = &.{ .{ .role = "system", .content = "base" }, background }, .context_tokens = 17 });
        try log.file.writePositionalAll(t.io, "{\"model_ms\":", log.offset);
    }
    var repaired: ?[]const u8 = null;
    for (0..3) |_| {
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        var log = try Log.restore(t.io, a, a, path, &history, &tokens, "parent");
        defer log.close(t.io);
        try t.expectEqual(@as(u64, "你好🙂".len), log.pending_background_bytes);
        try t.expectEqual(@as(usize, 0), log.lost_background.len);
        try t.expectEqualDeep(&[_]AgentSession{.{ .id = "a1", .session = "child" }}, log.agent_sessions);
        try t.expectEqual(@as(u64, 2), log.next_agent_id);
        try t.expectEqual(@as(u64, 17), tokens);
        const data = try tmp.dir.readFileAlloc(t.io, "pending.jsonl", a, .unlimited);
        if (repaired) |previous| try t.expectEqualStrings(previous, data);
        repaired = data;
        var replayed: std.ArrayList(provider.Message) = .empty;
        var replayed_tokens: u64 = 0;
        const restored = try replay(a, a, data, &replayed, &replayed_tokens);
        try t.expect(!restored.needs_repair);
        try t.expectEqual(@as(usize, 0), restored.background_repairs.len);
        try t.expectEqual(log.pending_background_bytes, restored.pending_background_bytes);
    }
    {
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        var log = try Log.restore(t.io, a, a, path, &history, &tokens, "parent");
        defer log.close(t.io);
        try log.commit(t.io, a, &history, &tokens, .{ .from = history.items.len, .messages = &.{.{ .role = "assistant", .content = "received" }}, .model_ms = 0 });
    }
    for (0..2) |_| {
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        var log = try Log.restore(t.io, a, a, path, &history, &tokens, "parent");
        defer log.close(t.io);
        try t.expectEqual(@as(u64, 0), log.pending_background_bytes);
        try t.expectEqual(@as(usize, 0), log.lost_background.len);
    }
}

test "fork header retains provenance and cache across compaction without billing inherited Steps" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const records = [_]Record{
        .{ .messages = &.{
            .{ .role = "system", .content = "original system" },
            .{ .role = "user", .content = "old background output", .source = .background, .background_id = "b1" },
            .{ .role = "assistant", .content = "inherited assistant" },
        }, .cache_key = "parent-cache", .forked_from = .{ .session = "parent-session", .message_count = 3 }, .context_tokens = 100 },
        .{ .from = 3, .messages = &.{ .{ .role = "user", .content = "child prompt" }, .{ .role = "assistant", .content = "child answer" } }, .context_tokens = 200 },
        .{ .from = 1, .messages = &.{.{ .role = "user", .content = "compacted child history" }}, .context_tokens = 50 },
    };
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    for (records, 0..) |record, i| {
        try encoded.writer.print("{f}\n", .{std.json.fmt(record, .{ .emit_null_optional_fields = false })});
        var messages: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        const restored = try replay(a, a, encoded.written(), &messages, &tokens);
        try t.expectEqual(@as(usize, if (i == 0) 0 else 1), restored.steps);
        try t.expectEqual(@as(u64, 0), restored.pending_background_bytes);
        try t.expectEqualStrings("parent-cache", restored.cache_key.?);
        try t.expectEqualDeep(records[0].forked_from, restored.forked_from);
    }
}
