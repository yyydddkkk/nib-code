const std = @import("std");
const provider = @import("../provider.zig");
const Change = @import("../tools/diff.zig").Change;
const Summary = @import("tool_summary.zig").Summary;

pub const TaskIds = struct { agent: u64 = 0, bash: u64 = 0 };

pub const Progress = struct {
    id: []const u8,
    run: usize = 0,
    invocation: usize = 0,
    kind: Background.Kind = .agent,
    elapsed_ms: u64 = 0,
    background: bool = false,
    detached: bool = false,
    fork: bool = false,
    race: bool = false,
    prompt: []const u8,
    state: enum { queued, working, done, failed, canceled, timed_out, won, stopped } = .working,
    step: u32 = 0,
    tools: []const []const u8 = &.{},
    files: []const []const u8 = &.{},
    usage: provider.Usage = .{},

    pub fn clone(p: Progress, gpa: std.mem.Allocator) !Progress {
        const prompt = try gpa.dupe(u8, p.prompt);
        errdefer gpa.free(prompt);
        const used = try cloneStrings(gpa, p.tools);
        errdefer freeStrings(gpa, used);
        const files = try cloneStrings(gpa, p.files);
        errdefer freeStrings(gpa, files);
        const id = try gpa.dupe(u8, p.id);
        return .{ .kind = p.kind, .elapsed_ms = p.elapsed_ms, .run = p.run, .invocation = p.invocation, .background = p.background, .detached = p.detached, .fork = p.fork, .race = p.race, .id = id, .prompt = prompt, .state = p.state, .step = p.step, .tools = used, .files = files, .usage = p.usage };
    }

    pub fn deinit(p: *Progress, gpa: std.mem.Allocator) void {
        gpa.free(p.prompt);
        gpa.free(p.id);
        freeStrings(gpa, p.tools);
        freeStrings(gpa, p.files);
        p.* = undefined;
    }

    fn cloneStrings(gpa: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| gpa.free(s);
            out.deinit(gpa);
        }
        for (items) |s| {
            const copy = try gpa.dupe(u8, s);
            errdefer gpa.free(copy);
            try out.append(gpa, copy);
        }
        return out.toOwnedSlice(gpa);
    }

    fn freeStrings(gpa: std.mem.Allocator, items: []const []const u8) void {
        for (items) |s| gpa.free(s);
        gpa.free(items);
    }
};

pub const Timing = struct {
    wall_ms: u64 = 0,
    model_ms: u64 = 0,
    run_ms: u64 = 0,
    tool_bytes: u64 = 0,
    output_bytes: u64 = 0,
    llm_calls: u64 = 0,
    agent_calls: u64 = 0,
    race_branches: u64 = 0,
};

pub const TurnSummary = struct {
    status: enum { completed, canceled, failed } = .completed,
    steps: u32 = 0,
    usage: provider.Usage = .{},
    timing: Timing = .{},
};

pub const ModelActivity = enum { started, data, finished };

pub const Background = struct {
    id: []const u8,
    kind: Kind,
    state: enum { started, finished, lost },
    ok: ?bool = null,
    result: ?[]const u8 = null,

    pub const Kind = enum { agent, bash };
};

pub const Event = union(enum) {
    step: struct { n: u32, effort: []const u8, source: provider.EffortSource },
    /// Slices are valid only during the callback.
    delta: struct { kind: provider.Kind, text: []const u8 },
    run_start: []const u8,
    run_end: struct { ok: bool, output: []const u8, changes: []const Change = &.{}, tool_summary: ?Summary = null },
    retry: struct { attempt: u32, delay_ms: u64, reason: []const u8 },
    notice: []const u8,
    usage: provider.Usage,
    progress: Progress,
    background: Background,
    turn_end: TurnSummary,
};

pub const JsonEvent = union(enum) {
    start: struct { session_id: []const u8 },
    event: Event,
    end: End,
    @"error": Failure,

    pub const Failure = struct { message: []const u8 = "", usage: provider.Usage = .{}, steps: u32 = 0, timing: ?Timing = null };

    pub const End = struct { text: []const u8, usage: provider.Usage, steps: u32, timing: ?Timing = null };

    pub fn jsonStringify(value: JsonEvent, writer: *std.json.Stringify) !void {
        switch (value) {
            .event => |event| if (event == .background) {
                const b = event.background;
                try writer.write(.{ .background = .{ .id = b.id, .kind = b.kind, .state = b.state, .ok = b.ok } });
            } else try writer.write(event),
            inline else => |payload, tag| {
                try writer.beginObject();
                try writer.objectField(@tagName(tag));
                try writer.write(payload);
                try writer.endObject();
            },
        }
    }

    pub fn write(value: JsonEvent, writer: *std.Io.Writer) !void {
        try writer.print("{f}\n", .{std.json.fmt(value, .{ .emit_null_optional_fields = false })});
        try writer.flush();
    }
};

test "run_end JSON includes actual tool summary including empty counts" {
    const t = std.testing;
    const counts = [_]@import("tool_summary.zig").Count{
        .{ .name = "bash", .count = 2 },
        .{ .name = "read", .count = 1 },
    };
    const populated = try std.json.Stringify.valueAlloc(t.allocator, JsonEvent{ .event = .{ .run_end = .{
        .ok = false,
        .output = "failed",
        .tool_summary = .{ .counts = &counts, .omitted = 3 },
    } } }, .{ .emit_null_optional_fields = false });
    defer t.allocator.free(populated);
    try t.expectEqualStrings("{\"run_end\":{\"ok\":false,\"output\":\"failed\",\"changes\":[],\"tool_summary\":{\"counts\":[{\"name\":\"bash\",\"count\":2},{\"name\":\"read\",\"count\":1}],\"omitted\":3}}}", populated);
    const empty = try std.json.Stringify.valueAlloc(t.allocator, JsonEvent{ .event = .{ .run_end = .{
        .ok = true,
        .output = "",
        .tool_summary = .{},
    } } }, .{ .emit_null_optional_fields = false });
    defer t.allocator.free(empty);
    try t.expectEqualStrings("{\"run_end\":{\"ok\":true,\"output\":\"\",\"changes\":[],\"tool_summary\":{\"counts\":[],\"omitted\":0}}}", empty);
    const legacy = try std.json.Stringify.valueAlloc(t.allocator, JsonEvent{ .event = .{ .run_end = .{ .ok = true, .output = "" } } }, .{ .emit_null_optional_fields = false });
    defer t.allocator.free(legacy);
    try t.expectEqualStrings("{\"run_end\":{\"ok\":true,\"output\":\"\",\"changes\":[]}}", legacy);
}

test "turn end JSON carries dispatched race branch totals" {
    const t = std.testing;
    const encoded = try std.json.Stringify.valueAlloc(t.allocator, JsonEvent{ .event = .{ .turn_end = .{ .timing = .{ .race_branches = 7 } } } }, .{});
    defer t.allocator.free(encoded);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, encoded, .{});
    defer parsed.deinit();
    try t.expectEqual(@as(i64, 7), parsed.value.object.get("turn_end").?.object.get("timing").?.object.get("race_branches").?.integer);
}
