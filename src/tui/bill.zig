const std = @import("std");
const ui_format = @import("format.zig");
const TurnSummary = @import("../session/events.zig").TurnSummary;

pub const Text = struct {
    buf: [1024]u8 = undefined,

    pub fn format(text: *Text, summary: TurnSummary, width: u16) []const u8 {
        if (summary.timing.wall_ms == 0) return "";
        return fit(ui_format.duration(&text.buf, summary.timing.wall_ms), width);
    }

    pub fn details(text: *Text, summary: TurnSummary, runs: usize) []const u8 {
        var wall: [64]u8 = undefined;
        var model: [64]u8 = undefined;
        var run: [64]u8 = undefined;
        var tool: [64]u8 = undefined;
        var output: [64]u8 = undefined;
        return std.fmt.bufPrint(&text.buf, "Last turn · {s}\n{d} Run{s} · {d} step{s}\nTotal {s} · model {s} · Run {s}\nInput {d} tokens · output {d} tokens\nCache {d} tokens · {d}% of input · writes {d} tokens\nTool data {s} → {s}\nDelegation · llm {d} · agent {d}", .{
            @tagName(summary.status),
            runs,
            if (runs == 1) "" else "s",
            summary.steps,
            if (summary.steps == 1) "" else "s",
            ui_format.duration(&wall, summary.timing.wall_ms),
            ui_format.duration(&model, summary.timing.model_ms),
            ui_format.duration(&run, summary.timing.run_ms),
            summary.usage.prompt_tokens,
            summary.usage.completion_tokens,
            summary.usage.prompt_cache_hit_tokens,
            @as(u128, summary.usage.prompt_cache_hit_tokens) * 100 / @max(summary.usage.prompt_tokens, 1),
            summary.usage.prompt_cache_write_tokens,
            ui_format.bytes(&tool, summary.timing.tool_bytes),
            ui_format.bytes(&output, summary.timing.output_bytes),
            summary.timing.llm_calls,
            summary.timing.agent_calls,
        }) catch unreachable;
    }
};

pub fn fit(full: []const u8, width: u16) []const u8 {
    var line = full;
    while ((std.unicode.utf8CountCodepoints(line) catch unreachable) > width) {
        const end = std.mem.lastIndexOf(u8, line, " · ") orelse return "";
        line = line[0..end];
    }
    return line;
}

const example: TurnSummary = .{
    .steps = 3,
    .usage = .{ .prompt_tokens = 6500, .completion_tokens = 100, .prompt_cache_hit_tokens = 6000 },
    .timing = .{ .wall_ms = 41_999, .model_ms = 30_000, .run_ms = 11_000, .tool_bytes = 3_200_000, .output_bytes = 18_000 },
};

test "quiet footer shows only elapsed time and status retains statistics" {
    var text: Text = .{};
    try std.testing.expectEqualStrings("41s", text.format(example, 200));
    try std.testing.expectEqualStrings("", text.format(.{ .steps = 1 }, 200));
    const details = text.details(example, 2);
    try std.testing.expect(std.mem.indexOf(u8, details, "2 Runs · 3 steps") != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "model 30s · Run 11s") != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "Cache 6000 tokens · 92% of input") != null);
}

test "zero time and unrelated statistics do not create a footer" {
    var text: Text = .{};
    try std.testing.expectEqualStrings("", text.format(.{}, 200));
    try std.testing.expectEqualStrings("", text.format(.{ .timing = .{ .tool_bytes = 320, .output_bytes = 18_000 } }, 200));
    inline for (.{ .canceled, .failed }) |outcome| try std.testing.expectEqualStrings("1s", text.format(.{ .status = outcome, .timing = .{ .wall_ms = 1000 } }, 200));
}

test "footer omits a duration that cannot fit" {
    var text: Text = .{};
    try std.testing.expectEqualStrings("", text.format(example, 2));
    try std.testing.expectEqualStrings("41s", text.format(example, 3));
}
