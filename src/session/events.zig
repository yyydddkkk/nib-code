const std = @import("std");
const provider = @import("../provider.zig");
const Change = @import("../tools/diff.zig").Change;
const Summary = @import("tool_summary.zig").Summary;

pub const TaskIds = struct { agent: u64 = 0, bash: u64 = 0, run: u64 = 0 };

pub const Progress = struct {
    id: []const u8,
    run: usize = 0,
    invocation: usize = 0,
    kind: Background.Kind = .agent,
    exit_code: ?u8 = null,
    output_bytes: u64 = 0,
    elapsed_ms: u64 = 0,
    superseded_by: ?[]const u8 = null,
    background: bool = false,
    detached: bool = false,
    fork: bool = false,
    prompt: []const u8,
    state: enum { queued, working, done, failed, canceled, timed_out } = .working,
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
        const replacement = if (p.superseded_by) |id| try gpa.dupe(u8, id) else null;
        errdefer if (replacement) |id| gpa.free(id);
        const id = try gpa.dupe(u8, p.id);
        return .{ .exit_code = p.exit_code, .output_bytes = p.output_bytes, .superseded_by = replacement, .kind = p.kind, .elapsed_ms = p.elapsed_ms, .run = p.run, .invocation = p.invocation, .background = p.background, .detached = p.detached, .fork = p.fork, .id = id, .prompt = prompt, .state = p.state, .step = p.step, .tools = used, .files = files, .usage = p.usage };
    }

    pub fn deinit(p: *Progress, gpa: std.mem.Allocator) void {
        if (p.superseded_by) |id| gpa.free(id);
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
};

pub const TurnSummary = struct {
    status: enum { completed, canceled, failed } = .completed,
    steps: u32 = 0,
    usage: provider.Usage = .{},
    timing: Timing = .{},
};

pub const ModelActivity = enum { started, data, script, waiting, finished };

pub const RunCompletion = struct {
    hook_notice: ?[]const u8 = null,
    execution: ?@import("../sandbox/timing.zig").Execution = null,
    step: usize,
    run_index: usize,
    source_reference: ?bool = null,
    ok: bool,
    output: []const u8,
    run_ms: u64,
    tool_bytes: u64,
    calls: []const @import("../sandbox/timing.zig").Call,
    calls_omitted: u64,
    changes: []const Change,
};

pub const Background = struct {
    execution: ?@import("../sandbox/timing.zig").Execution = null,
    id: []const u8,
    kind: Kind,
    state: enum { started, finished, lost },
    ok: ?bool = null,
    result: ?[]const u8 = null,
    completion: ?RunCompletion = null,

    pub const Kind = enum { agent, bash, run };
};

pub const Event = union(enum) {
    step: struct { n: u32, effort: []const u8 },
    /// Slices are valid only during the callback.
    delta: struct { kind: provider.Kind, text: []const u8 },
    run_start: []const u8,
    run_end: struct { background_id: ?[]const u8 = null, ok: bool, output: []const u8, changes: []const Change = &.{}, tool_summary: ?Summary = null },
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
                try writer.write(.{ .background = .{ .id = b.id, .kind = b.kind, .state = b.state, .ok = b.ok, .completion = b.completion, .execution = b.execution } });
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
    try t.expectEqualStrings("{\"run_end\":{\"ok\":false,\"output\":\"failed\",\"changes\":[],\"tool_summary\":{\"counts\":[{\"name\":\"bash\",\"count\":2},{\"name\":\"read\",\"count\":1}],\"omitted\":3,\"files\":[]}}}", populated);
    const empty = try std.json.Stringify.valueAlloc(t.allocator, JsonEvent{ .event = .{ .run_end = .{
        .ok = true,
        .output = "",
        .tool_summary = .{},
    } } }, .{ .emit_null_optional_fields = false });
    defer t.allocator.free(empty);
    try t.expectEqualStrings("{\"run_end\":{\"ok\":true,\"output\":\"\",\"changes\":[],\"tool_summary\":{\"counts\":[],\"omitted\":0,\"files\":[]}}}", empty);
    const legacy = try std.json.Stringify.valueAlloc(t.allocator, JsonEvent{ .event = .{ .run_end = .{ .ok = true, .output = "" } } }, .{ .emit_null_optional_fields = false });
    defer t.allocator.free(legacy);
    try t.expectEqualStrings("{\"run_end\":{\"ok\":true,\"output\":\"\",\"changes\":[]}}", legacy);
}
