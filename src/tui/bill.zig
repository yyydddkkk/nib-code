const std = @import("std");
const TurnSummary = @import("../session/events.zig").TurnSummary;

pub const Text = struct {
    buf: [512]u8 = undefined,

    pub fn format(text: *Text, summary: TurnSummary, width: u16) []const u8 {
        var wall: [64]u8 = undefined;
        var model: [64]u8 = undefined;
        var run: [64]u8 = undefined;
        var tok: [64]u8 = undefined;
        var tool_bytes: [64]u8 = undefined;
        var output_bytes: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&text.buf);
        if (summary.status != .completed) w.print("{s} · ", .{@tagName(summary.status)}) catch unreachable;
        w.print("{d} steps · {s} · think {s} · tools {s}", .{
            summary.steps,
            duration(&wall, summary.timing.wall_ms),
            componentDuration(&model, summary.timing.model_ms),
            componentDuration(&run, summary.timing.run_ms),
        }) catch unreachable;
        if (summary.timing.tool_bytes > 0 or summary.timing.output_bytes > 0) w.print(" · {s}→{s} B", .{
            tokens(&tool_bytes, summary.timing.tool_bytes),
            tokens(&output_bytes, summary.timing.output_bytes),
        }) catch unreachable;
        w.print(" · {s} tok ({d}% cached)", .{
            tokens(&tok, @as(u128, summary.usage.prompt_tokens) + summary.usage.completion_tokens),
            @as(u128, summary.usage.prompt_cache_hit_tokens) * 100 / @max(summary.usage.prompt_tokens, 1),
        }) catch unreachable;
        if (summary.timing.llm_calls > 0) w.print(" · llm ×{d}", .{summary.timing.llm_calls}) catch unreachable;
        if (summary.timing.agent_calls > 0) w.print(" · agent ×{d}", .{summary.timing.agent_calls}) catch unreachable;
        if (summary.timing.race_branches > 0) w.print(" · race ×{d} branches", .{summary.timing.race_branches}) catch unreachable;
        return fit(w.buffered(), width);
    }
};

// Generated bill text contains only single-cell ASCII, middle dots, arrows and multiplication signs.
pub fn fit(full: []const u8, width: u16) []const u8 {
    var line = full;
    while ((std.unicode.utf8CountCodepoints(line) catch unreachable) > width) {
        const end = std.mem.lastIndexOf(u8, line, " · ") orelse return "";
        line = line[0..end];
    }
    return line;
}

fn duration(buf: []u8, ms: u64) []const u8 {
    const s = ms / 1000;
    if (s >= 3600) return std.fmt.bufPrint(buf, "{d}h{d}m{d}s", .{ s / 3600, s % 3600 / 60, s % 60 }) catch unreachable;
    if (s >= 60) return std.fmt.bufPrint(buf, "{d}m{d}s", .{ s / 60, s % 60 }) catch unreachable;
    return std.fmt.bufPrint(buf, "{d}s", .{s}) catch unreachable;
}

fn componentDuration(buf: []u8, ms: u64) []const u8 {
    const full = duration(buf, ms);
    return if (ms >= 60_000) full[0 .. full.len - 1] else full;
}

fn tokens(buf: []u8, n: u128) []const u8 {
    const unit: u128 = if (n >= 1_000_000) 1_000_000 else if (n >= 1000) 1000 else 1;
    if (unit == 1) return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
    const suffix = if (unit == 1000) "k" else "M";
    const tenths = n % unit * 10 / unit;
    if (tenths == 0) return std.fmt.bufPrint(buf, "{d}{s}", .{ n / unit, suffix }) catch unreachable;
    return std.fmt.bufPrint(buf, "{d}.{d}{s}", .{ n / unit, tenths, suffix }) catch unreachable;
}

const example: TurnSummary = .{
    .steps = 12,
    .usage = .{ .prompt_tokens = 44_000, .completion_tokens = 1000, .prompt_cache_hit_tokens = 40_040 },
    .timing = .{ .wall_ms = 190_000, .model_ms = 100_000, .run_ms = 80_000, .tool_bytes = 3_200_000, .output_bytes = 18_000, .llm_calls = 8, .agent_calls = 1 },
};

test "bill formats turn totals and cache hits over prompt tokens" {
    var text: Text = .{};
    try std.testing.expectEqualStrings("12 steps · 3m10s · think 1m40 · tools 1m20 · 3.2M→18k B · 45k tok (91% cached) · llm ×8 · agent ×1", text.format(example, 200));
    var summary = example;
    summary.usage = .{ .prompt_tokens = 1000, .completion_tokens = 1000, .prompt_cache_hit_tokens = 910 };
    try std.testing.expect(std.mem.indexOf(u8, text.format(summary, 200), "2k tok (91% cached)") != null);
}

test "bill durations floor milliseconds and retain seconds at minute and hour boundaries" {
    var buf: [64]u8 = undefined;
    const cases = .{
        .{ @as(u64, 0), "0s" },
        .{ @as(u64, 999), "0s" },
        .{ @as(u64, 1000), "1s" },
        .{ @as(u64, 59_999), "59s" },
        .{ @as(u64, 60_000), "1m0s" },
        .{ @as(u64, 190_000), "3m10s" },
        .{ @as(u64, 3_600_000), "1h0m0s" },
        .{ @as(u64, 3_661_999), "1h1m1s" },
    };
    inline for (cases) |case| {
        try std.testing.expectEqualStrings(case[1], duration(&buf, case[0]));
        const component = if (case[0] >= 60_000) case[1][0 .. case[1].len - 1] else case[1];
        try std.testing.expectEqualStrings(component, componentDuration(&buf, case[0]));
    }
}

test "bill drops complete fields from right to left and never clips UTF-8" {
    var text: Text = .{};
    const full = text.format(example, 200);
    var end = full.len;
    while (true) {
        const prefix = full[0..end];
        const width: u16 = @intCast(try std.unicode.utf8CountCodepoints(prefix));
        try std.testing.expectEqualStrings(prefix, fit(full, width));
        const next = std.mem.lastIndexOf(u8, prefix, " · ") orelse {
            try std.testing.expectEqualStrings("", fit(full, width - 1));
            break;
        };
        try std.testing.expectEqualStrings(full[0..next], fit(full, width - 1));
        end = next;
    }
    for (0..200) |width| {
        const line = fit(full, @intCast(width));
        try std.testing.expect((try std.unicode.utf8CountCodepoints(line)) <= width);
        try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    }
    try std.testing.expectEqualStrings("", fit(full, 0));
}

test "bill omits zero delegation counts and handles zero usage" {
    var text: Text = .{};
    try std.testing.expectEqualStrings("0 steps · 0s · think 0s · tools 0s · 0 tok (0% cached)", text.format(.{}, 200));
    var summary: TurnSummary = .{};
    summary.timing.agent_calls = 1;
    const agent = text.format(summary, 200);
    try std.testing.expect(std.mem.endsWith(u8, agent, " · agent ×1"));
    try std.testing.expect(std.mem.indexOf(u8, agent, "llm") == null);
    summary.timing = .{ .llm_calls = 8 };
    const llm = text.format(summary, 200);
    try std.testing.expect(std.mem.endsWith(u8, llm, " · llm ×8"));
    try std.testing.expect(std.mem.indexOf(u8, llm, "agent") == null);
}

test "bill prefixes canceled and failed outcomes" {
    var text: Text = .{};
    inline for (.{ .canceled, .failed }) |status| {
        const summary: TurnSummary = .{ .status = status };
        const prefix = @tagName(status);
        try std.testing.expect(std.mem.startsWith(u8, text.format(summary, 200), prefix ++ " · 0 steps"));
        try std.testing.expectEqualStrings(prefix, text.format(summary, @intCast(prefix.len)));
        try std.testing.expectEqualStrings("", text.format(summary, @intCast(prefix.len - 1)));
    }
}

test "bill omits zero bytes and shows output without tool bytes" {
    var text: Text = .{};
    var summary: TurnSummary = .{};
    try std.testing.expectEqualStrings("0 steps · 0s · think 0s · tools 0s · 0 tok (0% cached)", text.format(summary, 200));
    summary.timing.output_bytes = 18_000;
    try std.testing.expectEqualStrings("0 steps · 0s · think 0s · tools 0s · 0→18k B · 0 tok (0% cached)", text.format(summary, 200));
    summary.timing.tool_bytes = 320;
    summary.timing.output_bytes = 0;
    try std.testing.expectEqualStrings("0 steps · 0s · think 0s · tools 0s · 320→0 B · 0 tok (0% cached)", text.format(summary, 200));
}

test "bill fits delegation counts before tokens and bytes" {
    var text: Text = .{};
    const prefixes = [_][]const u8{
        "12 steps · 3m10s · think 1m40 · tools 1m20 · 3.2M→18k B · 45k tok (91% cached) · llm ×8",
        "12 steps · 3m10s · think 1m40 · tools 1m20 · 3.2M→18k B · 45k tok (91% cached)",
        "12 steps · 3m10s · think 1m40 · tools 1m20 · 3.2M→18k B",
        "12 steps · 3m10s · think 1m40 · tools 1m20",
    };
    for (prefixes) |prefix| {
        const width: u16 = @intCast(try std.unicode.utf8CountCodepoints(prefix));
        try std.testing.expectEqualStrings(prefix, text.format(example, width));
    }
}

test "bill shows dispatched race branches and drops them as a complete field" {
    const t = std.testing;
    var text: Text = .{};
    var summary: TurnSummary = .{};
    const base = "0 steps · 0s · think 0s · tools 0s · 0 tok (0% cached)";
    try t.expectEqualStrings(base, text.format(summary, 200));
    summary.timing.race_branches = 6;
    try t.expectEqualStrings(base ++ " · race ×6 branches", text.format(summary, 200));
    try t.expectEqualStrings(base, text.format(summary, @intCast(try std.unicode.utf8CountCodepoints(base ++ " · race ×6 branches") - 1)));
    summary.timing.agent_calls = 1;
    summary.timing.llm_calls = 2;
    try t.expectEqualStrings(base ++ " · llm ×2 · agent ×1 · race ×6 branches", text.format(summary, 200));
}
