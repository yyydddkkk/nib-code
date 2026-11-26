const std = @import("std");
const sandbox = @import("../sandbox.zig");
const record = @import("record.zig");
pub const Entry = record.Entry;

pub const Report = struct {
    outcome: sandbox.Outcome,
    divergence: ?[]u8,
    incomplete: bool,
    uses_time: bool,
    uses_random: bool,

    pub fn deinit(r: Report, gpa: std.mem.Allocator) void {
        r.outcome.deinit(gpa);
        if (r.divergence) |text| gpa.free(text);
    }
};

const Engine = struct {
    gpa: std.mem.Allocator,
    entries: []const Entry,
    script: bool,
    bindings: std.ArrayList(Binding) = .empty,
    divergence: ?[]u8 = null,
    failed: bool = false,
    seq: usize = 0,
    incomplete: bool = false,

    const Binding = struct { entry: ?usize, missing: ?[]u8 = null };

    fn self(ctx: *anyopaque) *Engine {
        return @ptrCast(@alignCast(ctx));
    }

    fn diverge(e: *Engine, comptime fmt: []const u8, args: anytype) void {
        if (e.divergence != null or e.failed) return;
        e.divergence = std.fmt.allocPrint(e.gpa, fmt, args) catch {
            e.failed = true;
            return;
        };
    }

    fn create(ctx: *anyopaque, index: usize, name: []const u8, args_json: []const u8) void {
        const e = self(ctx);
        e.bind(index, name, args_json) catch {
            e.failed = true;
        };
    }

    fn bind(e: *Engine, index: usize, name: []const u8, args_json: []const u8) !void {
        if (e.divergence != null or e.failed) return;
        const args = try std.json.parseFromSlice(std.json.Value, e.gpa, args_json, .{});
        defer args.deinit();
        var expected: ?Entry = null;
        var found: ?usize = null;
        for (e.entries, 0..) |entry, i| {
            if (!e.script and entry.index != index) continue;
            if (!e.script) expected = entry;
            if (std.mem.eql(u8, name, entry.name) and jsonEqual(args.value, entry.args)) {
                found = i;
                break;
            }
            if (!e.script) break;
        }
        if (found == null and !e.script) {
            if (expected) |entry| {
                e.diverge("index {d}: expected name={s} args={f}; actual name={s} args={s}", .{ index, entry.name, std.json.fmt(entry.args, .{}), name, args_json });
            } else {
                e.diverge("index {d}: expected no call; actual name={s} args={s}", .{ index, name, args_json });
            }
            return;
        }
        const missing = if (found == null) try std.fmt.allocPrint(e.gpa, "not recorded: {s}", .{name}) else null;
        errdefer if (missing) |msg| e.gpa.free(msg);
        try e.bindings.append(e.gpa, .{ .entry = found, .missing = missing });
    }

    fn stopped(ctx: *anyopaque) bool {
        const e = self(ctx);
        return e.divergence != null or e.failed;
    }

    fn select(ctx: *anyopaque, pending: []const usize) ?usize {
        const e = self(ctx);
        if (pending.len == 0 or stopped(ctx)) return null;
        if (e.script) return pending[0];
        for (e.entries) |entry| {
            if (entry.seq != e.seq) continue;
            for (pending) |index| if (index == entry.index) return index;
            const actual = e.entries[e.bindings.items[pending[0]].entry.?];
            e.diverge("settlement {d}, index {d}: expected name={s} args={f}; actual index={d} name={s} args={f}", .{ e.seq, entry.index, entry.name, std.json.fmt(entry.args, .{}), actual.index, actual.name, std.json.fmt(actual.args, .{}) });
            return null;
        }
        const actual = e.entries[e.bindings.items[pending[0]].entry.?];
        e.diverge("settlement {d}, index {d}: expected no call; actual name={s} args={f}", .{ e.seq, actual.index, actual.name, std.json.fmt(actual.args, .{}) });
        return null;
    }

    fn result(ctx: *anyopaque, gpa: std.mem.Allocator, index: usize) !sandbox.VirtualResult {
        const e = self(ctx);
        const binding = e.bindings.items[index];
        e.seq += 1;
        if (binding.missing) |message| return .{ .result = .{ .err = try gpa.dupe(u8, message) } };
        const entry = e.entries[binding.entry.?];
        e.incomplete = e.incomplete or entry.truncated;
        const bytes = (if (entry.ok) entry.result else entry.@"error") orelse {
            e.incomplete = true;
            return .{ .result = .{ .err = try gpa.dupe(u8, "recorded result unavailable") } };
        };
        var string_result = false;
        if (entry.ok and entry.truncated) {
            const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch null;
            if (parsed) |value| value.deinit() else string_result = true;
        }
        const copy = try gpa.dupe(u8, bytes);
        return .{ .result = if (entry.ok) .{ .ok = copy } else .{ .err = copy }, .string_result = string_result };
    }

    fn forbidden(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) sandbox.ToolResult {
        @panic("virtual host must never dispatch real tools");
    }
};

pub fn execute(gpa: std.mem.Allocator, io: std.Io, code: []const u8, entries: []const Entry, start_ms_epoch: i64, end: record.End, script_mode: bool) !Report {
    return executeSession(gpa, io, code, entries, start_ms_epoch, end, script_mode, false, .current);
}

pub fn executeSession(gpa: std.mem.Allocator, io: std.Io, code: []const u8, entries: []const Entry, start_ms_epoch: i64, end: record.End, script_mode: bool, child: bool, policy: sandbox.redaction.Policy) !Report {
    var engine: Engine = .{ .gpa = gpa, .entries = entries, .script = script_mode, .incomplete = end == .timeout or end == .cancelled };
    defer {
        for (engine.bindings.items) |binding| if (binding.missing) |msg| gpa.free(msg);
        engine.bindings.deinit(gpa);
    }
    errdefer if (engine.divergence) |text| gpa.free(text);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for ([_][]const u8{ "mcp", "mcp_schema", "sleep", "read", "view", "edit", "write", "grep", "glob", "fetch", "search", "bash", "stop", "llm" }) |name| try names.append(gpa, name);
    if (!child) try names.append(gpa, "agent");
    for (entries) |entry| {
        var found = false;
        for (names.items) |name| if (std.mem.eql(u8, name, entry.name)) {
            found = true;
            break;
        };
        if (!found) try names.append(gpa, entry.name);
        engine.incomplete = engine.incomplete or entry.truncated;
    }
    var virtual: sandbox.Virtual = .{ .ctx = &engine, .create = Engine.create, .select = Engine.select, .result = Engine.result, .stopped = Engine.stopped, .start_ms_epoch = start_ms_epoch };
    const outcome = try sandbox.eval(gpa, io, code, .{ .output_policy = policy }, .{ .ctx = &engine, .names = names.items, .call = Engine.forbidden, .virtual = &virtual }, null);
    errdefer outcome.deinit(gpa);
    if (engine.failed) return error.OutOfMemory;
    if (!script_mode and engine.divergence == null and (engine.bindings.items.len != entries.len or engine.seq != entries.len)) {
        var first: ?Entry = null;
        for (entries) |entry| {
            if (entry.index < engine.bindings.items.len) continue;
            if (first == null or entry.index < first.?.index) first = entry;
        }
        if (first) |entry| {
            engine.diverge("index {d}: expected name={s} args={f}; actual no call", .{ entry.index, entry.name, std.json.fmt(entry.args, .{}) });
        } else {
            for (entries) |entry| if (entry.seq == engine.seq) {
                engine.diverge("settlement {d}, index {d}: expected name={s} args={f}; actual no settlement", .{ entry.seq, entry.index, entry.name, std.json.fmt(entry.args, .{}) });
                break;
            };
        }
    }
    if (engine.failed) return error.OutOfMemory;
    return .{ .outcome = outcome, .divergence = engine.divergence, .incomplete = engine.incomplete, .uses_time = virtual.uses_time, .uses_random = virtual.uses_random };
}

fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    if (a == .integer and b == .float) return @as(f64, @floatFromInt(a.integer)) == b.float;
    if (a == .float and b == .integer) return a.float == @as(f64, @floatFromInt(b.integer));
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |v| blk: {
            if (v.items.len != b.array.items.len) break :blk false;
            for (v.items, b.array.items) |x, y| if (!jsonEqual(x, y)) break :blk false;
            break :blk true;
        },
        .object => |v| blk: {
            if (v.count() != b.object.count()) break :blk false;
            var it = v.iterator();
            while (it.next()) |kv| {
                const other = b.object.get(kv.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(kv.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

const t = std.testing;

fn emptyArgs() std.json.Value {
    return .{ .object = .empty };
}

test "replay race obeys settlement seq rather than entry or creation order" {
    const entries = [_]Entry{
        .{ .index = 1, .seq = 0, .name = "fast", .args = emptyArgs(), .ok = true, .result = "2" },
        .{ .index = 0, .seq = 1, .name = "slow", .args = emptyArgs(), .ok = true, .result = "1" },
        .{ .index = 2, .seq = 2, .name = "fast", .args = emptyArgs(), .ok = true, .result = "3" },
    };
    for (0..8) |_| {
        const r = try execute(t.allocator, t.io, "const winner = await Promise.race([tools.slow(), tools.fast()]); const after = await tools.fast(); [winner,after]", &entries, 0, .ok, false);
        defer r.deinit(t.allocator);
        try t.expect(r.outcome.ok);
        try t.expectEqualStrings("[2,3]", r.outcome.text);
        try t.expect(r.divergence == null);
    }
}

test "strict replay detects creation mismatch, different args, extra and fewer calls" {
    const args = try std.json.parseFromSlice(std.json.Value, t.allocator, "{\"x\":1,\"y\":[true,null]}", .{});
    defer args.deinit();
    const entries = [_]Entry{.{ .index = 0, .seq = 0, .name = "read", .args = args.value, .ok = true, .result = "7" }};
    const good = try execute(t.allocator, t.io, "await tools.read({y:[true,null],x:1.0})", &entries, 0, .ok, false);
    defer good.deinit(t.allocator);
    try t.expect(good.divergence == null);
    try t.expectEqualStrings("7", good.outcome.text);
    for ([_][]const u8{ "await tools.write({x:1,y:[true,null]})", "await tools.read({x:2,y:[true,null]})", "42", "await tools.read({x:1,y:[true,null]}); await tools.read({x:1,y:[true,null]})" }) |code| {
        const r = try execute(t.allocator, t.io, code, &entries, 0, .ok, false);
        defer r.deinit(t.allocator);
        const difference = r.divergence.?;
        try t.expect(std.mem.indexOf(u8, difference, "index ") != null);
        try t.expect(std.mem.indexOf(u8, difference, "expected ") != null);
        try t.expect(std.mem.indexOf(u8, difference, "actual ") != null);
        try t.expect(std.mem.indexOf(u8, difference, "name=read args=") != null);
        if (std.mem.eql(u8, code, "42")) try t.expect(std.mem.indexOf(u8, difference, "actual no call") != null);
    }
}

test "script lookup reuses recordings and rejects misses, never performs IO" {
    const entries = [_]Entry{
        .{ .index = 1, .seq = 0, .name = "read", .args = emptyArgs(), .ok = true, .result = "1" },
        .{ .index = 0, .seq = 1, .name = "write", .args = emptyArgs(), .ok = true, .result = "2" },
    };
    const r = try execute(t.allocator, t.io, "const winner = await Promise.race([tools.write(),tools.read()]); const again = await tools.read(); let miss; try { await tools.bash({command:'touch /tmp/replay-MUST-NOT-EXIST'}); } catch(e) { miss=e.message; } [winner,again,miss]", &entries, 0, .ok, true);
    defer r.deinit(t.allocator);
    try t.expect(r.divergence == null);
    try t.expect(r.outcome.ok);
    try t.expectEqualStrings("[2,1,\"bash: not recorded: bash\"]", r.outcome.text);
}

test "recorded reject and truncated payload are handed back with incomplete flag" {
    const entries = [_]Entry{
        .{ .index = 0, .seq = 0, .name = "bash", .args = emptyArgs(), .ok = false, .@"error" = "denied" },
        .{ .index = 1, .seq = 1, .name = "read", .args = emptyArgs(), .ok = true, .result = "{\"text\":\"prefix", .truncated = true },
    };
    const r = try execute(t.allocator, t.io, "let msg; try { await tools.bash(); } catch(e) { msg=e.message; } [msg,await tools.read()]", &entries, 0, .ok, false);
    defer r.deinit(t.allocator);
    try t.expect(r.divergence == null);
    try t.expect(r.outcome.ok);
    try t.expect(r.incomplete);
    try t.expectEqualStrings("[\"bash: denied\",\"{\\\"text\\\":\\\"prefix\"]", r.outcome.text);
}

test "virtual Date and random are fixed and tracked" {
    const code = "[Date.now(),new Date().getTime(),Date(),Math.random(),Math.random(),new Date(123).getTime(),Date.parse('1970-01-01T00:00:00Z'),Date.UTC(1970,0,1),new Date() instanceof Date]";
    const a = try execute(t.allocator, t.io, code, &.{}, 1700000000123, .ok, false);
    defer a.deinit(t.allocator);
    const b = try execute(t.allocator, t.io, code, &.{}, 1700000000123, .ok, false);
    defer b.deinit(t.allocator);
    try t.expect(a.outcome.ok);
    try t.expect(a.uses_time and a.uses_random);
    try t.expectEqualStrings(a.outcome.text, b.outcome.text);
    try t.expect(std.mem.startsWith(u8, a.outcome.text, "[1700000000123,1700000000123,"));
    const plain = try execute(t.allocator, t.io, "42", &.{}, 0, .cancelled, false);
    defer plain.deinit(t.allocator);
    try t.expect(!plain.uses_time and !plain.uses_random);
    try t.expect(plain.incomplete);
}

test "ordinary Run errors are complete and recorded timeout remains incomplete" {
    const failed = try execute(t.allocator, t.io, "throw new Error('complete failure')", &.{}, 0, .@"error", false);
    defer failed.deinit(t.allocator);
    try t.expect(!failed.outcome.ok);
    try t.expect(!failed.incomplete);
    try t.expect(failed.divergence == null);
    const timeout = try execute(t.allocator, t.io, "42", &.{}, 0, .timeout, false);
    defer timeout.deinit(t.allocator);
    try t.expect(timeout.incomplete);
    try t.expect(timeout.outcome.ok);
    try t.expect(timeout.divergence == null);
    try t.expectEqualStrings("42", timeout.outcome.text);
}

test "fewer calls reports first missing creation index not first settlement" {
    const entries = [_]Entry{
        .{ .index = 1, .seq = 0, .name = "fast", .args = emptyArgs(), .ok = true, .result = "2" },
        .{ .index = 0, .seq = 1, .name = "slow", .args = emptyArgs(), .ok = true, .result = "1" },
    };
    const r = try execute(t.allocator, t.io, "42", &entries, 0, .ok, false);
    defer r.deinit(t.allocator);
    try t.expectEqualStrings("index 0: expected name=slow args={}; actual no call", r.divergence.?);
}
