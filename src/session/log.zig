const std = @import("std");
const provider = @import("../provider.zig");
const Background = @import("events.zig").Background;
const Tuning = @import("tuning.zig").Resolved;
const schema = @import("log/schema.zig");
const replay_mod = @import("log/replay.zig");

pub const RunResult = schema.RunResult;
pub const Delivery = schema.Delivery;
pub const Diagnostic = schema.Diagnostic;
pub const AgentSession = schema.AgentSession;
pub const ForkedFrom = schema.ForkedFrom;
pub const TaskStop = schema.TaskStop;
pub const Record = schema.Record;
pub const Source = schema.Source;
pub const ResumeAdaptation = schema.ResumeAdaptation;
pub const Summary = schema.Summary;
pub const Restored = replay_mod.Restored;
pub const replay = replay_mod.replay;

pub const Log = struct {
    resume_adaptation: ResumeAdaptation = .{},
    tuning: Tuning = .{},
    mcp_servers: []const @import("../mcp/config.zig").Server = &.{},
    plugin_skills: []const @import("skills.zig").Skill = &.{},
    skills: @import("skills.zig").Summary = .{},
    file: std.Io.File,
    mutex: std.Io.Mutex = .init,
    next_agent_id: u64 = 1,
    next_bash_id: u64 = 1,
    next_run_id: u64 = 1,
    agent_sessions: []const AgentSession = &.{},
    lost_background: []const Background = &.{},
    pending_background_bytes: u64 = 0,
    offset: u64,
    poisoned: bool = false,
    steps: usize = 0,
    provider: provider.Id = .chat_completions,
    custom_provider: ?[]const u8 = null,
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
        var log: Log = .{ .resume_adaptation = restored.resume_adaptation, .tuning = restored.tuning, .file = file, .mcp_servers = restored.mcp_servers, .plugin_skills = restored.plugin_skills, .skills = restored.skills, .offset = data.len, .parent_session_id = restored.parent_session_id, .cache_key = restored.cache_key, .forked_from = restored.forked_from, .provider = restored.provider, .custom_provider = restored.custom_provider, .model = restored.model, .steps = restored.steps, .next_agent_id = restored.next_agent_id, .next_bash_id = restored.next_bash_id, .next_run_id = restored.next_run_id, .agent_sessions = restored.agent_sessions, .lost_background = restored.lost_background, .pending_background_bytes = restored.pending_background_bytes };
        if (restored.needs_repair) {
            if (data[data.len - 1] != '\n') {
                // Do not turn a valid JSON value missing its commit newline into a record.
                try file.writePositionalAll(io, "!\n", log.offset);
                log.offset += 2;
            }
            try log.append(io, a, .{ .repair = true });
        }
        for (restored.background_repairs) |event| try log.append(io, a, .{ .background = event });
        if (restored.needs_repair or restored.background_repairs.len != 0) try log.file.sync(io);
        return log;
    }

    pub fn source(log: *Log, io: std.Io, a: std.mem.Allocator, value: Source) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        try log.append(io, a, .{ .source = value });
        try log.file.sync(io);
    }

    pub fn findSource(log: *Log, io: std.Io, a: std.mem.Allocator, reference: []const u8) !?Source {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        var reader = log.file.reader(io, &.{});
        const data = try reader.interface.allocRemaining(a, .unlimited);
        var found: ?Source = null;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (lines.peek() == null) break;
            const record = schema.parseRecord(a, line) catch continue;
            if (record.source) |value| {
                const ref = try std.fmt.allocPrint(a, "{d}:{d}", .{ value.step, value.run });
                if (std.mem.eql(u8, reference, ref)) found = value;
            }
        }
        var value = found orelse return null;
        for (try @import("../replay.zig").loadMain(a, data)) |run| {
            if (run.key.step == value.step and run.key.run == value.run and run.expected != null and std.mem.eql(u8, run.code, value.code)) {
                value.failed = run.source_reference;
                return value;
            }
        }
        return null;
    }

    pub fn close(log: *Log, io: std.Io) void {
        log.file.close(io);
    }

    fn append(log: *Log, io: std.Io, a: std.mem.Allocator, record: Record) !void {
        if (log.poisoned) return error.SessionLogFailed;
        var stamped = record;
        stamped.at = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
        const bytes = try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(stamped, .{ .emit_null_optional_fields = false })});
        defer a.free(bytes);
        errdefer log.poisoned = true;
        try log.file.writePositionalAll(io, bytes, log.offset);
        log.offset += bytes.len;
    }

    pub fn background(log: *Log, io: std.Io, a: std.mem.Allocator, event: Background, step: u32) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        try log.append(io, a, .{ .background = event, .turn_step = step });
        errdefer log.poisoned = true;
        try log.file.sync(io);
    }

    pub fn bash(log: *Log, io: std.Io, a: std.mem.Allocator, event: @import("../tools/bash/registry.zig").Event) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        try log.append(io, a, .{ .bash = event });
    }

    pub fn hook(log: *Log, io: std.Io, a: std.mem.Allocator, event: []const u8, command: []const u8, exit_code: i32, duration_ms: u64) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        try log.append(io, a, .{ .hook = .{ .event = event, .command = command, .exit_code = exit_code, .duration_ms = duration_ms } });
    }

    pub fn sandboxUnavailable(log: *Log, io: std.Io, a: std.mem.Allocator, reason: []const u8) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        try log.append(io, a, .{ .sandbox_unavailable = reason });
    }

    pub fn taskStop(log: *Log, io: std.Io, a: std.mem.Allocator, event: TaskStop) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        try log.append(io, a, .{ .task_stop = event });
    }

    pub fn agentSession(log: *Log, io: std.Io, a: std.mem.Allocator, mapping: AgentSession) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        try log.append(io, a, .{ .agent_session = mapping });
        errdefer log.poisoned = true;
        try log.file.sync(io);
    }

    pub fn fallback(log: *Log, io: std.Io, a: std.mem.Allocator, info: @import("../provider/codex_ws.zig").Info, step: u32) !void {
        log.mutex.lockUncancelable(io);
        defer log.mutex.unlock(io);
        try log.append(io, a, .{
            .transport = @tagName(info.transport),
            .transport_fallback = info.fallback_reason,
            .transport_fallback_at = info.fallback_at,
            .transport_fallback_detail = info.fallback_detail,
            .full_reason = info.full_reason,
            .turn_step = step,
        });
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
        if (record.from == history.items.len and record.forked_from == null) {
            log.steps += schema.assistantCount(record.messages);
            log.pending_background_bytes = schema.pendingBytes(log.pending_background_bytes, record);
        }
        schema.apply(history, record);
        tokens.* = record.context_tokens;
        errdefer log.poisoned = true;
        try log.file.sync(io);
    }
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
        const record = schema.parseRecord(a, line) catch continue;
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
        const record = try schema.parseRecord(a, line);
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

test "transport fallback events preserve history, tokens and Steps across restore" {
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
    try log.commit(t.io, a, &history, &tokens, .{ .messages = &.{.{ .role = "system", .content = "base" }}, .context_tokens = 123 });
    for ([_][]const u8{ "WebSocketHandshake", "previous_response_not_found" }) |reason| {
        try log.fallback(t.io, a, .{ .fallback_reason = reason, .fallback_at = 1 }, 1);
        try log.commit(t.io, a, &history, &tokens, .{ .from = history.items.len, .messages = &.{ .{ .role = "user", .content = "next" }, .{ .role = "assistant", .content = "ok" } }, .context_tokens = 200, .model_ms = 1, .transport_fallback = reason });
    }
    var restored: std.ArrayList(provider.Message) = .empty;
    var restored_tokens: u64 = 0;
    const result = try replay(a, a, try tmp.dir.readFileAlloc(t.io, "s.jsonl", a, .unlimited), &restored, &restored_tokens);
    try t.expectEqualDeep(history.items, restored.items);
    try t.expectEqual(tokens, restored_tokens);
    try t.expectEqual(@as(usize, 2), result.steps);
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

test "restore after background message commit without finished does not redeliver lost" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/background.jsonl", .{tmp.sub_path});
    const started: Background = .{ .id = "a1", .kind = .agent, .state = .started };
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
        try t.expectEqualDeep(&[_]Background{started}, log.lost_background);
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
                const last = try schema.parseRecord(a, end[std.mem.lastIndexOfScalar(u8, end, '\n').? + 1 ..]);
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

test {
    _ = schema;
    _ = replay_mod;
}
