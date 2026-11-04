const std = @import("std");
const vaxis = @import("vaxis");
const provider = @import("../provider.zig");
const Change = @import("../tools/diff.zig").Change;
const Progress = @import("../session/events.zig").Progress;
const Background = @import("../session/events.zig").Background;
const BackgroundKind = @FieldType(Background, "kind");
const bill = @import("bill.zig");
const entries = @import("transcript/entry.zig");
const label_text = @import("transcript/label.zig");
pub const Kind = entries.Kind;
pub const Entry = entries.Entry;
pub const ChangeText = @import("transcript/changes.zig").ChangeText;
const run_output_lines = entries.run_output_lines;
const max_segments = entries.max_segments;
const appendHead = label_text.appendHead;
const actualToolSummary = label_text.actualToolSummary;
const promptPrefix = label_text.promptPrefix;
const appendPreview = label_text.appendPreview;
const agent_tree = @import("agent_tree.zig");
const ToolSummary = @import("../session/tool_summary.zig").Summary;

/// What the conversation area shows, built from Session events or replayed history.
pub const Transcript = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// ctrl+o state; streamed collapsible entries start in it.
    expanded: bool = false,
    next_run: usize = 0,
    pending_results: std.ArrayList(PendingResult) = .empty,

    const PendingResult = struct { id: []const u8, kind: BackgroundKind, ok: bool };

    pub fn deinit(t: *Transcript, gpa: std.mem.Allocator) void {
        t.clear(gpa);
        t.entries.deinit(gpa);
    }

    pub fn clear(t: *Transcript, gpa: std.mem.Allocator) void {
        for (t.entries.items) |*e| e.deinit(gpa);
        t.entries.clearRetainingCapacity();
        t.next_run = 0;
        t.clearPendingResults(gpa, 0);
        t.pending_results.deinit(gpa);
        t.pending_results = .empty;
    }

    pub fn add(t: *Transcript, gpa: std.mem.Allocator, kind: Kind, text: []const u8) !void {
        var e: Entry = .{ .kind = kind, .open = t.expanded };
        errdefer e.deinit(gpa);
        try e.text.appendSlice(gpa, text);
        try e.refreshLabel(gpa);
        try t.entries.append(gpa, e);
    }

    pub fn backgroundResult(t: *Transcript, gpa: std.mem.Allocator, kind: BackgroundKind, id: []const u8, ok: bool, result: []const u8) !void {
        try t.settleBackgroundProgress(gpa, kind, id, ok);
        var e: Entry = .{ .kind = .background, .run = if (ok) .ok else .failed, .open = t.expanded };
        errdefer e.deinit(gpa);
        e.task_id = try gpa.dupe(u8, id);
        try e.text.appendSlice(gpa, result);
        try e.label.print(gpa, "{s} {s} · {s}", .{ id, @tagName(kind), if (ok) "ok" else "failed" });
        const Summary = struct { text: ?[]const u8 = null, output: ?[]const u8 = null, @"error": ?[]const u8 = null };
        const parsed = std.json.parseFromSlice(Summary, gpa, result, .{ .ignore_unknown_fields = true }) catch null;
        if (parsed) |summary| {
            defer summary.deinit();
            const output = if (kind == .agent) summary.value.text orelse "" else summary.value.output orelse "";
            const preview = if (output.len > 0) output else summary.value.@"error" orelse "";
            if (preview.len > 0) {
                try e.label.appendSlice(gpa, " · ");
                try appendPreview(gpa, &e.label, preview);
            }
        } else if (std.mem.indexOf(u8, result, if (kind == .agent) "\"text\":" else "\"output\":")) |at| {
            const tail = std.mem.trimStart(u8, result[at + (if (kind == .agent) @as(usize, 7) else 9) ..], " \t\r\n");
            if (tail.len > 0 and tail[0] == '"') {
                const preview = tail[1..@min(tail.len, 1 + promptPrefix(tail[1..]).len)];
                const end = std.mem.indexOfScalar(u8, preview, '"') orelse preview.len;
                if (end > 0) {
                    try e.label.appendSlice(gpa, " · ");
                    try appendPreview(gpa, &e.label, preview[0..end]);
                }
            }
        }
        try t.entries.append(gpa, e);
    }

    pub fn lostBackground(t: *Transcript, gpa: std.mem.Allocator, kind: BackgroundKind, id: []const u8, result: []const u8) !void {
        try t.settleBackgroundProgress(gpa, kind, id, false);
        var e: Entry = .{ .kind = .background, .run = .failed, .open = t.expanded };
        errdefer e.deinit(gpa);
        e.task_id = try gpa.dupe(u8, id);
        try e.label.print(gpa, "{s} {s} · lost", .{ id, @tagName(kind) });
        try e.text.appendSlice(gpa, result);
        try t.entries.append(gpa, e);
    }

    fn settleBackgroundProgress(t: *Transcript, gpa: std.mem.Allocator, kind: BackgroundKind, id: []const u8, ok: bool) !void {
        // Results have only task IDs; registration order is the delivery FIFO.
        for (t.entries.items) |*e| {
            if (e.kind != .run) continue;
            for (e.invocations.items) |*call| {
                if (!call.background or call.result != null or call.kind != kind or !std.mem.eql(u8, call.id, id)) continue;
                call.result = ok;
                for (e.agents.items) |*p| {
                    if (p.invocation == call.invocation and std.mem.eql(u8, p.id, id)) settleProgress(p, ok);
                }
                try e.refreshAgents(gpa);
                try e.refreshLabel(gpa);
                e.cached = null;
                return;
            }
        }
        const copy = try gpa.dupe(u8, id);
        errdefer gpa.free(copy);
        try t.pending_results.append(gpa, .{ .id = copy, .kind = kind, .ok = ok });
    }

    fn clearPendingResults(t: *Transcript, gpa: std.mem.Allocator, from: usize) void {
        for (t.pending_results.items[from..]) |result| gpa.free(result.id);
        t.pending_results.shrinkRetainingCapacity(from);
    }

    pub fn clearBackgroundProgress(t: *Transcript, gpa: std.mem.Allocator) !void {
        for (t.entries.items) |*e| {
            if (e.kind != .run) continue;
            for (e.invocations.items) |*call| {
                if (call.result == null) call.background = false;
            }
            var changed = false;
            var i: usize = 0;
            while (i < e.agents.items.len) {
                if (!e.agents.items[i].background) {
                    i += 1;
                } else {
                    var removed = e.agents.orderedRemove(i);
                    removed.deinit(gpa);
                    changed = true;
                }
            }
            if (changed) {
                try e.refreshAgents(gpa);
                try e.refreshLabel(gpa);
                e.cached = null;
            }
        }
    }

    pub fn userInserted(t: *Transcript, id: u64) void {
        for (t.entries.items) |*e| {
            if (e.queued == id) {
                e.queued = null;
                e.cached = null;
                return;
            }
        }
    }

    pub fn removeQueued(t: *Transcript, gpa: std.mem.Allocator) void {
        var i = t.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (t.entries.items[i].queued != null) {
                var entry = t.entries.orderedRemove(i);
                entry.deinit(gpa);
            }
        }
    }

    pub fn toggleExpanded(t: *Transcript) void {
        t.expanded = !t.expanded;
        for (t.entries.items) |*e| if (e.collapsible()) {
            e.open = t.expanded;
        };
    }

    pub fn lastAnswer(t: *const Transcript) ?[]const u8 {
        var i = t.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (t.entries.items[i].kind == .assistant) return t.entries.items[i].text.items;
        }
        return null;
    }

    pub fn appendDelta(t: *Transcript, gpa: std.mem.Allocator, kind: provider.Kind, text: []const u8) !void {
        if (kind == .reasoning) return;
        const entry_kind: Kind = .assistant;
        const items = t.entries.items;
        if (items.len == 0 or items[items.len - 1].kind != entry_kind) try t.entries.append(gpa, .{ .kind = entry_kind, .open = t.expanded });
        const current = &t.entries.items[t.entries.items.len - 1];
        try current.text.appendSlice(gpa, text);
    }

    pub fn startRun(t: *Transcript, gpa: std.mem.Allocator, code: []const u8) !void {
        try t.startRunWithEffort(gpa, code, null);
    }

    pub fn startRunWithEffort(t: *Transcript, gpa: std.mem.Allocator, code: []const u8, effort: ?provider.StepEffort) !void {
        try t.addRun(gpa, code, t.expanded, effort);
        t.next_run += 1;
        t.entries.items[t.entries.items.len - 1].run_number = t.next_run;
    }

    pub fn progress(t: *Transcript, gpa: std.mem.Allocator, p: Progress) !void {
        const e = target: {
            for (t.entries.items) |*entry| {
                if (entry.kind != .run or (p.run != 0 and entry.run_number != p.run)) continue;
                for (entry.invocations.items) |call| {
                    if (call.invocation == p.invocation and std.mem.eql(u8, call.id, p.id)) break :target entry;
                }
            }
            if (p.run != 0) {
                var i = t.entries.items.len;
                while (i > 0) {
                    i -= 1;
                    const entry = &t.entries.items[i];
                    if (entry.kind == .run and entry.run_number == p.run and (entry.run == .running or p.background)) break :target entry;
                }
                return;
            }
            break :target t.lastRunning() orelse return;
        };
        const call = registered: {
            for (e.invocations.items) |*call| {
                if (call.invocation == p.invocation and std.mem.eql(u8, call.id, p.id)) break :registered call;
            }
            const id = try gpa.dupe(u8, p.id);
            errdefer gpa.free(id);
            try e.invocations.append(gpa, .{ .id = id, .kind = p.kind, .invocation = p.invocation, .background = p.background });
            break :registered &e.invocations.items[e.invocations.items.len - 1];
        };
        if (call.background and call.result == null) {
            for (t.pending_results.items, 0..) |result, i| {
                if (result.kind != p.kind or !std.mem.eql(u8, result.id, p.id)) continue;
                call.result = result.ok;
                gpa.free(t.pending_results.orderedRemove(i).id);
                break;
            }
        }
        for (e.agents.items) |current| {
            if (std.mem.eql(u8, current.id, p.id) and current.invocation > p.invocation) return;
        }
        var copy = try p.clone(gpa);
        var transferred = false;
        errdefer if (!transferred) copy.deinit(gpa);
        if (call.result) |ok| settleProgress(&copy, ok);
        for (e.agents.items) |*current| {
            if (!std.mem.eql(u8, current.id, p.id)) continue;
            current.deinit(gpa);
            current.* = copy;
            break;
        } else try e.agents.append(gpa, copy);
        transferred = true;
        try e.refreshAgents(gpa);
        try e.refreshLabel(gpa);
        e.cached = null;
    }

    /// Takes ownership of `changes`.
    pub fn endRun(t: *Transcript, gpa: std.mem.Allocator, ok: bool, output: []const u8, elapsed_ms: u64, changes: ChangeText) !void {
        try t.endRunWithSummary(gpa, ok, output, elapsed_ms, changes, null);
    }

    /// Takes ownership of `changes`; borrows `summary`.
    pub fn endRunWithSummary(t: *Transcript, gpa: std.mem.Allocator, ok: bool, output: []const u8, elapsed_ms: u64, changes: ChangeText, summary: ?ToolSummary) !void {
        const e = t.lastRunning() orelse {
            var c = changes;
            c.deinit(gpa);
            return;
        };
        e.run = if (ok) .ok else .failed;
        e.elapsed_ms = elapsed_ms;
        e.changes.deinit(gpa);
        e.changes = changes;
        if (summary) |value| e.tool_summary = try value.clone(gpa);
        try appendHead(gpa, &e.output, output, run_output_lines);
        try e.refreshLabel(gpa);
        e.cached = null;
    }

    pub fn addHistory(t: *Transcript, gpa: std.mem.Allocator, history: []const provider.Message) !void {
        const pending_start = t.pending_results.items.len;
        defer t.clearPendingResults(gpa, pending_start);
        var runs: std.StringHashMap(usize) = .init(gpa);
        defer runs.deinit();
        for (history) |m| {
            const content = m.content orelse "";
            if (m.source == .background) {
                const kind = m.background_kind orelse .agent;
                if (std.mem.startsWith(u8, content, "[background ") and std.mem.indexOf(u8, content, " lost:") != null) {
                    try t.lostBackground(gpa, kind, m.background_id orelse "?", content);
                    continue;
                }
                const result = if (std.mem.indexOfScalar(u8, content, '\n')) |nl| content[nl + 1 ..] else content;
                const Result = struct { ok: ?bool = null, exit_code: ?i64 = null };
                const parsed = std.json.parseFromSlice(Result, gpa, result, .{ .ignore_unknown_fields = true }) catch null;
                defer if (parsed) |value| value.deinit();
                const parsed_ok = if (parsed) |value| (if (kind == .agent) value.value.ok orelse false else value.value.exit_code != null and value.value.exit_code.? == 0) else false;
                try t.backgroundResult(gpa, kind, m.background_id orelse "?", m.background_ok orelse parsed_ok, result);
            } else if (std.mem.eql(u8, m.role, "user")) {
                try t.add(gpa, .user, content);
            } else if (std.mem.eql(u8, m.role, "assistant")) {
                if (content.len > 0) try t.add(gpa, .assistant, content);
                for (m.tool_calls orelse &.{}) |call| {
                    const Args = struct { code: []const u8 = "" };
                    const args = std.json.parseFromSlice(Args, gpa, call.function.arguments, .{ .ignore_unknown_fields = true }) catch continue;
                    defer args.deinit();
                    try t.addRun(gpa, args.value.code, false, m.step_effort);
                    try runs.put(call.id, t.entries.items.len - 1);
                }
                if (m.step_calls_omitted) |omitted| {
                    const text = try std.fmt.allocPrint(gpa, "tools +{d} · omitted calls (Run unknown)", .{omitted});
                    defer gpa.free(text);
                    try t.add(gpa, .info, text);
                }
            } else if (std.mem.eql(u8, m.role, "tool")) {
                if (runs.get(m.tool_call_id orelse "")) |index| {
                    const e = &t.entries.items[index];
                    e.run = .ok;
                    if (m.tool_summary) |summary| e.tool_summary = try summary.clone(gpa);
                    try appendHead(gpa, &e.output, content, run_output_lines);
                    try e.refreshLabel(gpa);
                }
            }
        }
    }

    fn addRun(t: *Transcript, gpa: std.mem.Allocator, code: []const u8, open: bool, effort: ?provider.StepEffort) !void {
        var e: Entry = .{ .kind = .run, .open = open };
        errdefer e.deinit(gpa);
        if (effort) |value| e.step_effort = .{ .effort = try gpa.dupe(u8, value.effort), .source = value.source };
        try e.text.appendSlice(gpa, std.mem.trim(u8, code, "\n"));
        try e.refreshLabel(gpa);
        try t.entries.append(gpa, e);
    }

    fn lastRunning(t: *Transcript) ?*Entry {
        var i = t.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = &t.entries.items[i];
            if (e.kind == .run and e.run == .running) return e;
        }
        return null;
    }
};

fn settleProgress(p: *Progress, ok: bool) void {
    p.background = false;
    p.state = if (ok) .done else switch (p.state) {
        .canceled, .timed_out => p.state,
        else => .failed,
    };
}

const testing = std.testing;

test "background results fold to an id and text summary and expand to complete JSON" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    const result = "{\"ok\":true,\"text\":\"found it\\nsecond line\",\"changes\":[],\"usage\":{}}";
    try t.backgroundResult(gpa, .agent, "bg_1", true, result);
    const e = &t.entries.items[0];
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expect(e.collapsible());
    try testing.expectEqual(@as(usize, 2), e.segments(&segs).len);
    try testing.expectEqualStrings("bg_1 agent · ok · found it second line", segs[1].text);
    t.toggleExpanded();
    try testing.expectEqual(@as(usize, 4), e.segments(&segs).len);
    try testing.expectEqualStrings(result, segs[3].text);
    try testing.expect(t.lastAnswer() == null);
    try t.backgroundResult(gpa, .agent, "bg_2", false, "{\"ok\":false,\"text\":\"failed\"}");
    try testing.expect(t.entries.items[1].open);
    try testing.expectEqualStrings("✗ ", t.entries.items[1].segments(&segs)[0].text);
}

test "restored background results retain their kind and complete result" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    const result = "{\"ok\":true,\"text\":\"result\"}";
    try t.addHistory(gpa, &.{.{ .role = "user", .content = "background agent bg_1 finished\n" ++ result, .source = .background, .background_kind = .agent, .background_id = "bg_1" }});
    try testing.expectEqual(Kind.background, t.entries.items[0].kind);
    try testing.expectEqualStrings(result, t.entries.items[0].text.items);
    try testing.expectEqualStrings("bg_1 agent · ok · result", t.entries.items[0].label.items);
}

test "background progress stays with its Run until the matching result arrives" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.agent({})");
    try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "first", .background = true, .step = 1 });
    try t.endRun(gpa, true, "started", 100, .{});
    try t.startRun(gpa, "tools.read({})");
    try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "first", .background = true, .step = 2 });
    try testing.expectEqual(@as(usize, 1), t.entries.items[0].agents.items.len);
    try testing.expectEqual(@as(u32, 2), t.entries.items[0].agents.items[0].step);
    try testing.expectEqual(@as(usize, 0), t.entries.items[1].agents.items.len);
    try testing.expect(std.mem.indexOf(u8, t.entries.items[0].label.items, "background") != null);
    try t.backgroundResult(gpa, .agent, "a1", true, "{\"ok\":true,\"text\":\"done\"}");
    try testing.expectEqual(@as(usize, 1), t.entries.items[0].agent_tree.rows.items.len);
    try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "first", .background = true, .state = .done, .step = 3 });
    try testing.expect(!t.entries.items[0].agents.items[0].background);
    try testing.expectEqualStrings("agent · 0.1s", t.entries.items[0].label.items);
    try testing.expectEqual(Kind.background, t.entries.items[2].kind);
}

test "turn cleanup removes background working rows without removing delivered results" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.bash({})");
    try t.progress(gpa, .{ .id = "b1", .run = 1, .kind = .bash, .background = true, .prompt = "sleep 60" });
    try t.progress(gpa, .{ .id = "b2", .run = 1, .kind = .bash, .background = true, .prompt = "echo done" });
    try t.endRun(gpa, true, "started", 100, .{});
    try t.backgroundResult(gpa, .bash, "b2", true, "{\"exit_code\":0,\"output\":\"done\"}");
    try testing.expectEqual(@as(usize, 2), t.entries.items[0].agents.items.len);
    try t.clearBackgroundProgress(gpa);
    try testing.expectEqual(@as(usize, 1), t.entries.items[0].agents.items.len);
    try testing.expectEqualStrings("  └─ b2 bash echo done · 0.0s · done", t.entries.items[0].agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("bash · 0.1s", t.entries.items[0].label.items);
    try testing.expectEqualStrings("b2 bash · ok · done", t.entries.items[1].label.items);
}

test "truncated background result still previews text and lost result is visible" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.backgroundResult(gpa, .agent, "a1", false, "{\"ok\":false,\"text\":\"partial result");
    try testing.expectEqualStrings("a1 agent · failed · partial result", t.entries.items[0].label.items);
    try t.lostBackground(gpa, .agent, "a2", "[background agent a2 lost: process ended]");
    try testing.expectEqualStrings("a2 agent · lost", t.entries.items[1].label.items);
    try testing.expectEqualStrings("[background agent a2 lost: process ended]", t.entries.items[1].text.items);
}

test "background bash shows command and elapsed time until its result arrives" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.bash({})");
    try t.progress(gpa, .{ .id = "b1", .run = 1, .kind = .bash, .background = true, .prompt = "sleep 2\necho done", .elapsed_ms = 1200 });
    try t.endRun(gpa, true, "started", 100, .{});
    try testing.expectEqualStrings("bash · background · sleep 2 echo done · 1.2s · background", t.entries.items[0].label.items);
    t.toggleExpanded();
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("  └─ b1 bash sleep 2 echo done · 1.2s · background", t.entries.items[0].agent_tree.rows.items[0].text);
    try t.backgroundResult(gpa, .bash, "b1", true, "{\"exit_code\":0,\"output\":\"done\\n\"}");
    try testing.expectEqualStrings("bash · 0.1s", t.entries.items[0].label.items);
    try testing.expectEqualStrings("b1 bash · ok · done ", t.entries.items[1].label.items);
    try testing.expectEqualStrings("{\"exit_code\":0,\"output\":\"done\\n\"}", t.entries.items[1].segments(&segs)[3].text);
}

test "restored background bash uses its persisted kind" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.addHistory(gpa, &.{.{ .role = "user", .content = "[background bash b1 finished]\n{\"exit_code\":0,\"output\":\"ready\"}", .source = .background, .background_kind = .bash, .background_id = "b1" }});
    try testing.expectEqualStrings("b1 bash · ok · ready", t.entries.items[0].label.items);
    try t.addHistory(gpa, &.{.{ .role = "user", .content = "[background bash b2 finished]\n{\"exit_code\":1,\"output\":\"failed\"}", .source = .background, .background_kind = .bash, .background_id = "b2" }});
    try testing.expectEqualStrings("b2 bash · failed · failed", t.entries.items[1].label.items);
    try t.addHistory(gpa, &.{.{ .role = "user", .content = "[background bash b3 finished]\n{\"output\":\"partial", .source = .background, .background_kind = .bash, .background_id = "b3", .background_ok = true }});
    try testing.expectEqualStrings("b3 bash · ok · partial", t.entries.items[2].label.items);
}

test "runs fold to one line until expanded" {
    const gpa = testing.allocator;
    var screen: vaxis.Screen = .{};
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 24, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "const a = await tools.bash({});\nconst b = await tools.bash({});\nawait tools.read({})");
    try t.endRun(gpa, true, "line 1\nline 2", 1234, .{});
    const e = &t.entries.items[0];
    try testing.expectEqual(@as(u16, 1), e.height(win));
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("bash ×2, read · 1.2s", e.segments(&segs)[2].text);
    t.toggleExpanded();
    try testing.expectEqual(@as(u16, 6), e.height(win));
}

test "entry height cache reuses measurements and invalidates on width or append" {
    const gpa = testing.allocator;
    var screen: vaxis.Screen = .{};
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 10, .height = 24, .screen = &screen };
    var e: Entry = .{ .kind = .assistant };
    defer e.text.deinit(gpa);
    try e.text.appendSlice(gpa, "1234567890");
    try testing.expectEqual(@as(u16, 1), e.height(win));
    e.cached.?.rows = 123;
    try testing.expectEqual(@as(u16, 123), e.height(win));
    win.width = 5;
    try testing.expectEqual(@as(u16, 2), e.height(win));
    try e.text.appendSlice(gpa, "12345");
    try testing.expectEqual(@as(u16, 3), e.height(win));
}

test "thinking stays hidden in streamed and restored transcripts" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.appendDelta(gpa, .reasoning, "think");
    try testing.expectEqual(@as(usize, 0), t.entries.items.len);
    try t.appendDelta(gpa, .text, "an");
    try t.appendDelta(gpa, .reasoning, "more thinking");
    try t.appendDelta(gpa, .text, "swer");
    try testing.expectEqual(@as(usize, 1), t.entries.items.len);
    try testing.expectEqualStrings("answer", t.lastAnswer().?);

    t.clear(gpa);
    try t.addHistory(gpa, &.{
        .{ .role = "user", .content = "hi" },
        .{ .role = "assistant", .reasoning = .{ .provider = .chat_completions, .data = "hidden thinking" }, .tool_calls = &.{.{ .id = "1", .function = .{ .name = "run", .arguments = "{\"code\":\"tools.bash({})\"}" } }} },
        .{ .role = "tool", .tool_call_id = "1", .content = "out" },
        .{ .role = "assistant", .content = "answer", .reasoning = .{ .provider = .codex, .data = "[{\"summary\":[{\"text\":\"hidden summary\"}]}]" } },
    });
    try testing.expectEqual(@as(usize, 3), t.entries.items.len);
    try testing.expectEqualStrings("answer", t.lastAnswer().?);
    try testing.expectEqualStrings("out", t.entries.items[1].output.items);
    try testing.expect(t.entries.items[1].run == .ok);
}

test "a Run shows changed files in its summary and a colored diff when open" {
    const gpa = testing.allocator;
    var screen: vaxis.Screen = .{};
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 24, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "await tools.edit({})");
    const changes = [_]Change{
        .{ .path = "src/a.zig", .added = 1, .removed = 1, .diff = " keep\n-old\n+new\n" },
        .{ .path = "b.md", .added = 1, .removed = 0, .created = true, .diff = "+hi\n" },
    };
    try t.endRun(gpa, true, "", 300, try .init(gpa, &changes));
    const e = &t.entries.items[0];
    try testing.expectEqualStrings("edit · 0.3s · src/a.zig +1 −1, b.md (new) +1 −0", e.label.items);
    try testing.expectEqual(@as(u16, 1), e.height(win));
    t.toggleExpanded();
    var segs: [max_segments]vaxis.Segment = undefined;
    const shown = e.segments(&segs);
    try testing.expectEqualStrings("-old\n", shown[8].text);
    try testing.expectEqual(@as(u8, 1), shown[8].style.fg.index);
    try testing.expectEqualStrings("+hi", shown[11].text);
    try testing.expectEqual(@as(u16, 8), e.height(win));

    var many: [3]Change = undefined;
    for (&many) |*c| c.* = .{ .path = "x", .added = 2, .removed = 1, .diff = "" };
    var text: ChangeText = try .init(gpa, &many);
    defer text.deinit(gpa);
    try testing.expectEqualStrings("3 files +6 −3", text.summary);
}

test "agent tree stays visible folded, expanded and after Run ends" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "await tools.agent({prompt: 'fix it'})");
    try t.progress(gpa, .{ .id = "a1", .prompt = "fix it", .step = 3, .tools = &.{"edit"}, .files = &.{"src/x.zig"}, .usage = .{ .prompt_tokens = 41000 } });
    const e = &t.entries.items[0];
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("agent · running · step 3 · edit src/x.zig · 41k tok", e.segments(&segs)[2].text);
    try testing.expectEqualStrings("", e.segments(&segs)[1].text);
    t.toggleExpanded();
    try testing.expectEqualStrings("  └─ a1 fix it · working · step 3 · edit src/x.zig", e.agent_tree.rows.items[0].text);
    try testing.expectEqualStrings(e.text.items, e.segments(&segs)[4].text);
    try t.progress(gpa, .{ .id = "a1", .prompt = "fix it", .state = .done, .step = 3, .tools = &.{"edit"}, .files = &.{"src/x.zig"} });
    try t.endRun(gpa, true, "done", 1234, .{});
    try testing.expectEqualStrings("agent · 1.2s", e.segments(&segs)[2].text);
    try testing.expectEqualStrings("run ", e.segments(&segs)[1].text);
    try testing.expectEqualStrings("done", e.segments(&segs)[6].text);
    try testing.expectEqualStrings("  └─ a1 fix it · done · step 3 · edit src/x.zig", e.agent_tree.rows.items[0].text);
    try t.progress(gpa, .{ .id = "a1", .prompt = "late" });
    try testing.expectEqualStrings("agent · 1.2s", e.label.items);
}

test "multiple child progress keeps creation order, is replaced and summed without double counting cache" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "await Promise.all([tools.agent({}), tools.agent({}), tools.agent({})])");
    try t.progress(gpa, .{ .id = "a3", .prompt = "third", .step = 1, .usage = .{ .prompt_tokens = 40000 } });
    try t.progress(gpa, .{ .id = "a1", .prompt = "first", .step = 2, .state = .done, .tools = &.{"read"}, .usage = .{ .prompt_tokens = 39000, .completion_tokens = 1000, .prompt_cache_hit_tokens = 39000 } });
    try t.progress(gpa, .{ .id = "a2", .prompt = "second", .step = 3, .tools = &.{"edit"}, .files = &.{"a.zig"}, .usage = .{ .prompt_tokens = 40000 } });
    const e = &t.entries.items[0];
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("agent ×3 · running · 2 working, 1 done · 120k tok", e.segments(&segs)[2].text);
    t.toggleExpanded();
    try testing.expectEqual(@as(usize, 3), e.agent_tree.rows.items.len);
    try testing.expectEqualStrings("  ├─ a3 third · working · step 1", e.agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("  ├─ a1 first · done · step 2 · read", e.agent_tree.rows.items[1].text);
    try testing.expectEqualStrings("  └─ a2 second · working · step 3 · edit a.zig", e.agent_tree.rows.items[2].text);
    try t.progress(gpa, .{ .id = "a3", .prompt = "third", .state = .timed_out, .step = 1, .usage = .{ .prompt_tokens = 40000 } });
    try testing.expectEqual(@as(usize, 3), e.agents.items.len);
    try testing.expectEqualStrings("agent ×3 · running · 1 working, 1 done, 1 failed · 120k tok", e.label.items);
    try t.endRun(gpa, true, "out", 9000, .{});
    try testing.expectEqualStrings("agent ×3 · 9.0s", e.label.items);
}

test "child prompt preview uses forty Unicode characters and one logical line" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.agent({})");
    const prompt = "中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中" ++ "\nnot shown";
    try t.progress(gpa, .{ .id = "a1", .prompt = prompt, .state = .queued });
    const e = &t.entries.items[0];
    try testing.expectEqualStrings("  └─ a1 " ++ "中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中中" ++ "  · queued · step 0", e.agent_tree.rows.items[0].text);
    e.cached = .{ .width = 80, .len = e.text.items.len, .open = false, .rows = 10 };
    try t.progress(gpa, .{ .id = "a1", .prompt = prompt, .state = .working });
    try testing.expect(e.cached == null);
}

test "long user messages fold live and replayed, truncate the first line, and expand" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 30, .rows = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 30, .height = 12, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    const raw = "a very long first line that must be clipped\n2\n3\n4\n5\n6";
    try t.add(gpa, .user, raw);
    var e = &t.entries.items[0];
    try testing.expectEqual(@as(u16, 1), e.height(win));
    _ = e.print(win, true);
    try testing.expectEqualStrings("s", screen.readCell(29, 0).?.char.grapheme);
    try testing.expect(screen.readCell(29, 0).?.style.dim);
    t.toggleExpanded();
    try testing.expect(e.height(win) > 5);
    t.clear(gpa);
    t.expanded = false;
    try t.addHistory(gpa, &.{.{ .role = "user", .content = raw }});
    e = &t.entries.items[0];
    try testing.expectEqual(@as(u16, 1), e.height(win));
    t.toggleExpanded();
    try testing.expect(e.height(win) > 5);
    try t.add(gpa, .user, raw);
    try testing.expect(t.entries.items[1].open);
    t.toggleExpanded();
    try testing.expectEqual(@as(u16, 1), t.entries.items[1].height(win));
    const long = try gpa.alloc(u8, 801);
    defer gpa.free(long);
    @memset(long, 'x');
    try t.add(gpa, .user, long);
    try testing.expectEqual(@as(u16, 1), t.entries.items[2].height(win));
    try t.add(gpa, .user, long[0..800]);
    try testing.expect(t.entries.items[3].height(win) > 1);
}

test "bills stay dim and one row when resized or expanded" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 120, .rows = 3, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 3, .screen = &screen };
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);
    var text: bill.Text = .{};
    const full = text.format(.{ .steps = 12, .timing = .{ .wall_ms = 190_000, .llm_calls = 8, .agent_calls = 1 } }, 120);
    try transcript.add(gpa, .bill, full);
    const entry = &transcript.entries.items[0];
    for ([_]u16{ 120, 40, 8, 1, 0, 120 }) |width| {
        win.width = width;
        win.clear();
        transcript.toggleExpanded();
        try testing.expectEqual(@as(u16, 1), entry.height(win));
        try testing.expectEqual(@as(u16, 1), entry.print(win, true));
        const expected = bill.fit(full, width);
        var col: u16 = 0;
        var it = std.unicode.Utf8View.initUnchecked(expected).iterator();
        while (it.nextCodepointSlice()) |cp| : (col += 1) {
            const cell = screen.readCell(col, 0).?;
            try testing.expectEqualStrings(cp, cell.char.grapheme);
            try testing.expect(cell.style.dim);
        }
        for (0..120) |x| try testing.expectEqualStrings(" ", screen.readCell(@intCast(x), 1).?.char.grapheme);
    }
}

test "queued users have a dim marker until their insertion event" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.add(gpa, .user, "first");
    t.entries.items[0].queued = 1;
    try t.add(gpa, .user, "second");
    t.entries.items[1].queued = 2;
    var segs: [max_segments]vaxis.Segment = undefined;
    const queued = t.entries.items[0].segments(&segs);
    try testing.expectEqualStrings(" · queued", queued[2].text);
    try testing.expect(queued[2].style.dim);
    var screen: vaxis.Screen = .{};
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 10, .height = 24, .screen = &screen };
    _ = t.entries.items[0].height(win);
    t.userInserted(1);
    try testing.expectEqual(@as(?u64, null), t.entries.items[0].queued);
    try testing.expect(t.entries.items[0].cached == null);
    try testing.expectEqual(@as(usize, 2), t.entries.items[0].segments(&segs).len);
    t.removeQueued(gpa);
    try testing.expectEqual(@as(usize, 1), t.entries.items.len);
    try testing.expectEqualStrings("first", t.entries.items[0].text.items);
}

test "Run summaries retain their generating Step effort while running and done" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    for ([_]provider.StepEffort{
        .{ .effort = "low", .source = .model },
        .{ .effort = "high", .source = .default },
        .{ .effort = "high", .source = .guard },
        .{ .effort = "default", .source = .default },
    }) |effort| {
        try t.startRunWithEffort(gpa, "tools.edit({})", effort);
        const e = &t.entries.items[t.entries.items.len - 1];
        const suffix = try std.fmt.allocPrint(gpa, " · {s}{s}", .{ effort.effort, if (effort.source == .guard) " (guard)" else "" });
        defer gpa.free(suffix);
        try testing.expect(std.mem.endsWith(u8, e.label.items, suffix));
        try testing.expect(std.mem.indexOf(u8, e.label.items, "running") != null);
        try t.endRun(gpa, effort.source != .guard, "output", 1234, .{ .summary = try gpa.dupe(u8, "a.zig +1 −0") });
        try testing.expect(std.mem.endsWith(u8, e.label.items, suffix));
        try testing.expect(std.mem.indexOf(u8, e.label.items, "a.zig +1 −0") != null);
    }
}

test "history Run effort is copied from assistant metadata and absent in legacy history" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    var effort = [_]u8{ 'h', 'i', 'g', 'h' };
    const calls: []const provider.ToolCall = &.{.{ .id = "1", .function = .{ .name = "run", .arguments = "{\"code\":\"tools.bash({})\"}" } }};
    try t.addHistory(gpa, &.{
        .{ .role = "assistant", .tool_calls = calls, .step_effort = .{ .effort = &effort, .source = .guard } },
        .{ .role = "tool", .tool_call_id = "1", .content = "out" },
        .{ .role = "assistant", .tool_calls = calls },
        .{ .role = "tool", .tool_call_id = "1", .content = "out" },
    });
    effort[0] = 'x';
    try t.entries.items[0].refreshLabel(gpa);
    try testing.expectEqualStrings("bash · 0.0s · high (guard)", t.entries.items[0].label.items);
    try testing.expectEqualStrings("bash · 0.0s", t.entries.items[1].label.items);
}

test "agent rows have stable heights across folding resizing completion and scrolling" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 100, .rows = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    var win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 100, .height = 12, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    const code = "await tools.agent({})";
    try t.startRun(gpa, code);
    try t.progress(gpa, .{ .id = "a2", .prompt = "second", .step = 3 });
    try t.progress(gpa, .{ .id = "a1", .prompt = "first", .state = .done, .step = 2 });
    const e = &t.entries.items[0];
    for ([_]u16{ 100, 48, 20, 1, 100 }) |columns| {
        win.width = columns;
        try testing.expectEqual(@as(u16, 3), e.height(win));
        try testing.expectEqual(@as(u16, 3), e.print(win, false));
    }
    _ = e.print(win, true);
    try testing.expectEqualStrings("├", screen.readCell(2, 1).?.char.grapheme);
    try testing.expectEqualStrings("└", screen.readCell(2, 2).?.char.grapheme);
    try testing.expectEqualStrings(" ", screen.readCell(0, 3).?.char.grapheme);
    t.toggleExpanded();
    try testing.expectEqual(@as(u16, 4), e.height(win));
    _ = e.print(win, true);
    try testing.expectEqualStrings("a", screen.readCell(0, 3).?.char.grapheme);
    try t.progress(gpa, .{ .id = "a2", .prompt = "second", .state = .failed, .step = 4, .tools = &.{"bash"} });
    try testing.expectEqual(@as(u16, 4), e.height(win));
    try t.endRun(gpa, true, "result", 2000, .{});
    try testing.expectEqual(@as(u16, 5), e.height(win));
    _ = e.print(win, true);
    try testing.expectEqualStrings("r", screen.readCell(0, 4).?.char.grapheme);
    try testing.expectEqualStrings("  ├─ a2 second · failed · step 4 · bash", e.agent_tree.rows.items[0].text);
    t.toggleExpanded();
    try testing.expectEqual(@as(u16, 3), e.height(win));
    win.clear();
    _ = e.print(win.child(.{ .y_off = -1 }), true);
    try testing.expectEqualStrings("├", screen.readCell(2, 0).?.char.grapheme);
    try testing.expectEqualStrings("└", screen.readCell(2, 1).?.char.grapheme);
    try testing.expectEqualStrings(" ", screen.readCell(0, 2).?.char.grapheme);
    try t.startRun(gpa, "1 + 1");
    try testing.expectEqual(@as(u16, 1), t.entries.items[1].height(win));
    try testing.expectEqual(@as(u16, 3), t.entries.items[0].height(win));
}

test "completed Run replaces source estimate with dispatched host tools" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "await tools.edit({new_text: 'tools.llm( tools.llm( tools.write('}); await tools.bash({})");
    try testing.expect(std.mem.indexOf(u8, t.entries.items[0].label.items, "llm ×2") != null);
    const calls = [_]@import("../sandbox/timing.zig").Call{
        .{ .name = "edit", .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 0 },
        .{ .name = "llm", .start_ms = 1, .end_ms = 1, .ok = false, .run_index = 0, .dispatched = false },
        .{ .name = "bash", .start_ms = 1, .end_ms = 2, .ok = false, .run_index = 0 },
    };
    const summary = try ToolSummary.init(gpa, &calls, 0, 0);
    defer summary.deinit(gpa);
    try t.endRunWithSummary(gpa, false, "failed bash", 200, .{}, summary);
    try testing.expectEqualStrings("edit, bash · 0.2s", t.entries.items[0].label.items);
}

test "completed Run includes omitted calls without guessing their names" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    var timing: @import("../sandbox/timing.zig").Run = .init(testing.io, .now(testing.io, .awake));
    for (0..203) |_| _ = timing.reserve("read");
    try t.startRun(gpa, "for (;;) tools.read({}); tools.llm({})");
    const summary = try ToolSummary.init(gpa, timing.entries[0..timing.count], 0, timing.omitted);
    defer summary.deinit(gpa);
    try t.endRunWithSummary(gpa, true, "done", 0, .{}, summary);
    try testing.expectEqualStrings("read ×200, +3 · 0.0s", t.entries.items[0].label.items);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("+3", actualToolSummary(.{ .omitted = 3 }, &buf));
}

test "empty actual summary does not fall back to source text" {
    var t: Transcript = .{};
    defer t.deinit(testing.allocator);
    try t.startRun(testing.allocator, "// tools.llm({})");
    try t.endRunWithSummary(testing.allocator, true, "done", 0, .{}, .{});
    try testing.expectEqualStrings("js · 0.0s", t.entries.items[0].label.items);
}

test "restored Run summaries follow run_index and tool_call_id and survive compaction" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = @import("../session/log.zig");
    const record: log.Record = .{ .messages = &.{
        .{ .role = "system", .content = "base" },
        .{ .role = "assistant", .tool_calls = &.{
            .{ .id = "first", .function = .{ .name = "run", .arguments = "{\"code\":\"tools.llm({})\"}" } },
            .{ .id = "second", .function = .{ .name = "run", .arguments = "{\"code\":\"tools.agent({})\"}" } },
        } },
        .{ .role = "tool", .tool_call_id = "first", .content = "first output" },
        .{ .role = "tool", .tool_call_id = "second", .content = "second output" },
    }, .calls = &.{
        .{ .name = "edit", .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 0 },
        .{ .name = "bash", .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 1 },
        .{ .name = "bash", .start_ms = 0, .end_ms = 1, .ok = false, .run_index = 1 },
        .{ .name = "llm", .start_ms = 0, .end_ms = 0, .ok = false, .run_index = 1, .dispatched = false },
    }, .calls_omitted = 5, .run_results = &.{
        .{ .tool_call_id = "first", .ok = true, .calls_omitted = 2 },
        .{ .tool_call_id = "second", .ok = true, .calls_omitted = 3 },
    } };
    const data = try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(record, .{ .emit_null_optional_fields = false })});
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    _ = try log.replay(a, a, data, &history, &tokens);
    var t: Transcript = .{};
    defer t.deinit(testing.allocator);
    try t.addHistory(testing.allocator, history.items);
    try testing.expectEqualStrings("edit, +2 · 0.0s", t.entries.items[0].label.items);
    try testing.expectEqualStrings("bash ×2, +3 · 0.0s", t.entries.items[1].label.items);
    try testing.expectEqualStrings("first output", t.entries.items[0].output.items);
    try testing.expectEqualStrings("second output", t.entries.items[1].output.items);
    const compacted = try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(log.Record{ .messages = history.items }, .{ .emit_null_optional_fields = false })});
    history = .empty;
    _ = try log.replay(a, a, compacted, &history, &tokens);
    t.clear(testing.allocator);
    try t.addHistory(testing.allocator, history.items);
    try testing.expectEqualStrings("edit, +2 · 0.0s", t.entries.items[0].label.items);
    try testing.expectEqualStrings("bash ×2, +3 · 0.0s", t.entries.items[1].label.items);
}

test "legacy logs without calls retain the source estimate" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = @import("../session/log.zig");
    const data = "{\"messages\":[{\"role\":\"system\",\"content\":\"base\"},{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"old\",\"function\":{\"name\":\"run\",\"arguments\":\"{\\\"code\\\":\\\"tools.llm({}); tools.llm({})\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"old\",\"content\":\"done\"}]}\n";
    var history: std.ArrayList(provider.Message) = .empty;
    var tokens: u64 = 0;
    _ = try log.replay(a, a, data, &history, &tokens);
    var t: Transcript = .{};
    defer t.deinit(testing.allocator);
    try t.addHistory(testing.allocator, history.items);
    try testing.expectEqualStrings("llm ×2 · 0.0s", t.entries.items[0].label.items);
}

test "legacy Step overflow is not attributed to a pure JS Run" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = @import("../session/log.zig");
    var calls: [200]@import("../sandbox/timing.zig").Call = undefined;
    @memset(&calls, .{ .name = "read", .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 0 });
    const record: log.Record = .{ .messages = &.{
        .{ .role = "system", .content = "base" },
        .{ .role = "assistant", .tool_calls = &.{
            .{ .id = "first", .function = .{ .name = "run", .arguments = "{\"code\":\"for (;;) tools.read({})\"}" } },
            .{ .id = "second", .function = .{ .name = "run", .arguments = "{\"code\":\"1+1\"}" } },
        } },
        .{ .role = "tool", .tool_call_id = "first", .content = "first output" },
        .{ .role = "tool", .tool_call_id = "second", .content = "second output" },
    }, .calls = &calls, .calls_omitted = 3 };
    var data = try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(record, .{ .emit_null_optional_fields = false })});
    for (0..2) |_| {
        var history: std.ArrayList(provider.Message) = .empty;
        var tokens: u64 = 0;
        _ = try log.replay(a, a, data, &history, &tokens);
        var t: Transcript = .{};
        defer t.deinit(testing.allocator);
        try t.addHistory(testing.allocator, history.items);
        try testing.expectEqualStrings("read ×200 · 0.0s", t.entries.items[0].label.items);
        try testing.expectEqualStrings("js · 0.0s", t.entries.items[1].label.items);
        try testing.expectEqualStrings("tools +3 · omitted calls (Run unknown)", t.entries.items[2].text.items);
        data = try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(log.Record{ .messages = history.items }, .{ .emit_null_optional_fields = false })});
    }
}

fn endRunAllocationFailures(gpa: std.mem.Allocator) !void {
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.llm({})");
    try t.endRunWithSummary(gpa, true, "done", 0, .{}, .{ .counts = &.{.{ .name = "read", .count = 1 }} });
}

test "endRun summary cloning failures release owned data" {
    try testing.checkAllAllocationFailures(testing.allocator, endRunAllocationFailures, .{});
}

test "mixed ids replace in creation order and settle only when delivered" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "Promise.all([tools.agent({}), tools.bash({}), tools.agent({})])");
    var id = [_]u8{ 'a', '1', '0' };
    try t.progress(gpa, .{ .id = &id, .run = 1, .prompt = "first", .step = 1 });
    id[1] = '9';
    try t.progress(gpa, .{ .id = "b2", .run = 1, .kind = .bash, .prompt = "echo ready", .background = true, .state = .done, .elapsed_ms = 192_000 });
    try t.progress(gpa, .{ .id = "a2", .run = 1, .prompt = "last", .background = true, .state = .failed, .step = 2 });
    try t.progress(gpa, .{ .id = "a10", .run = 1, .prompt = "updated", .step = 3 });
    try testing.expectEqual(@as(usize, 3), t.entries.items[0].agents.items.len);
    try testing.expectEqualStrings("a10", t.entries.items[0].agents.items[0].id);
    try testing.expectEqualStrings("b2", t.entries.items[0].agents.items[1].id);
    try testing.expectEqualStrings("a2", t.entries.items[0].agents.items[2].id);
    try testing.expectEqualStrings("  ├─ a10 updated · working · step 3", t.entries.items[0].agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("  ├─ b2 bash echo ready · 3m12s · background", t.entries.items[0].agent_tree.rows.items[1].text);
    try testing.expectEqualStrings("  └─ a2 last · background · step 2", t.entries.items[0].agent_tree.rows.items[2].text);
    try t.endRun(gpa, true, "started", 100, .{});
    try t.startRun(gpa, "tools.read({})");
    try t.progress(gpa, .{ .id = "b2", .kind = .bash, .prompt = "echo ready", .background = true, .state = .done, .elapsed_ms = 192_000 });
    try testing.expectEqual(@as(usize, 0), t.entries.items[1].agents.items.len);
    try t.backgroundResult(gpa, .bash, "b2", true, "{\"exit_code\":0,\"output\":\"ready\"}");
    try testing.expectEqualStrings("  ├─ b2 bash echo ready · 3m12s · done", t.entries.items[0].agent_tree.rows.items[1].text);
    try testing.expect(t.entries.items[0].agents.items[2].background);
    try t.lostBackground(gpa, .agent, "a2", "[background agent a2 lost: process ended]");
    try testing.expectEqualStrings("  └─ a2 last · failed · step 2", t.entries.items[0].agent_tree.rows.items[2].text);
    try t.progress(gpa, .{ .id = "a2", .run = 1, .prompt = "last", .background = true, .state = .done, .step = 4 });
    try testing.expect(!t.entries.items[0].agents.items[2].background);
    try testing.expectEqualStrings("  └─ a2 last · failed · step 4", t.entries.items[0].agent_tree.rows.items[2].text);
    try testing.expectEqualStrings("b2 bash · ok · ready", t.entries.items[2].label.items);
    try testing.expectEqualStrings("a2 agent · lost", t.entries.items[3].label.items);
}

test "live and restored mixed results have identical folded labels and complete details" {
    const gpa = testing.allocator;
    var live: Transcript = .{};
    defer live.deinit(gpa);
    var restored: Transcript = .{};
    defer restored.deinit(gpa);
    const bash_result = "{\"exit_code\":0,\"output\":\"ready\\nmore output\"}";
    const agent_result = "{\"ok\":false,\"text\":\"failed to build\",\"error\":\"compiler error\"}";
    const lost = "[background agent a10 lost: process ended]";
    try live.backgroundResult(gpa, .bash, "b2", true, bash_result);
    try live.backgroundResult(gpa, .agent, "a2", false, agent_result);
    try live.lostBackground(gpa, .agent, "a10", lost);
    try restored.addHistory(gpa, &.{
        .{ .role = "user", .source = .background, .background_kind = .bash, .background_id = "b2", .content = "[background bash b2 finished]\n" ++ bash_result },
        .{ .role = "user", .source = .background, .background_kind = .agent, .background_id = "a2", .content = "[background agent a2 finished]\n" ++ agent_result },
        .{ .role = "user", .source = .background, .background_kind = .agent, .background_id = "a10", .content = lost },
    });
    var left: [max_segments]vaxis.Segment = undefined;
    var right: [max_segments]vaxis.Segment = undefined;
    const labels = [_][]const u8{ "b2 bash · ok · ready more output", "a2 agent · failed · failed to build", "a10 agent · lost" };
    for (live.entries.items, restored.entries.items, labels, 0..) |*a, *b, label, i| {
        try testing.expectEqualStrings(label, a.label.items);
        try testing.expectEqualStrings(label, b.label.items);
        try testing.expectEqualStrings(if (i == 0) "✓ " else "✗ ", a.segments(&left)[0].text);
        try testing.expectEqualStrings(a.segments(&left)[0].text, b.segments(&right)[0].text);
        try testing.expectEqual(@as(usize, 2), b.segments(&right).len);
    }
    live.toggleExpanded();
    restored.toggleExpanded();
    for (live.entries.items, restored.entries.items, [_][]const u8{ bash_result, agent_result, lost }) |*a, *b, full| {
        try testing.expectEqual(@as(usize, 4), b.segments(&right).len);
        try testing.expectEqualStrings(full, a.segments(&left)[3].text);
        try testing.expectEqualStrings(full, b.segments(&right)[3].text);
    }
}

test "delivered failures retain terminal cancellation and timeout states" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.agent({})");
    try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "canceled", .background = true, .state = .canceled });
    try t.progress(gpa, .{ .id = "a2", .run = 1, .prompt = "timed out", .background = true, .state = .timed_out });
    try t.backgroundResult(gpa, .agent, "a1", false, "{}");
    try t.backgroundResult(gpa, .agent, "a2", false, "{}");
    try testing.expectEqualStrings("  ├─ a1 canceled · canceled · step 0", t.entries.items[0].agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("  └─ a2 timed out · timed_out · step 0", t.entries.items[0].agent_tree.rows.items[1].text);
}

test "session IDs route progress across repeated Turn Run numbers and late terminal events" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.agent({})");
    try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "first", .state = .done });
    try t.endRun(gpa, true, "done", 10, .{});
    t.next_run = 0;
    try t.startRun(gpa, "tools.agent({background:true})");
    try t.progress(gpa, .{ .id = "a2", .run = 1, .prompt = "second", .background = true });
    try testing.expectEqual(@as(usize, 1), t.entries.items[0].agents.items.len);
    try testing.expectEqualStrings("a2", t.entries.items[1].agents.items[0].id);
    try t.progress(gpa, .{ .id = "b1", .run = 1, .kind = .bash, .prompt = "sleep 30", .elapsed_ms = 4000 });
    try t.endRun(gpa, false, "stop", 4000, .{});
    try t.progress(gpa, .{ .id = "b1", .run = 1, .kind = .bash, .prompt = "sleep 30", .elapsed_ms = 4100, .state = .canceled });
    try testing.expectEqualStrings("  └─ b1 bash sleep 30 · 4.1s · canceled", t.entries.items[1].agent_tree.rows.items[1].text);
}

test "background failures without output preview the error and keep complete JSON" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    const result = "{\"error\":\"timed out after 4000 ms\"}";
    try t.backgroundResult(gpa, .bash, "b1", false, result);
    try testing.expectEqualStrings("b1 bash · failed · timed out after 4000 ms", t.entries.items[0].label.items);
    try testing.expectEqualStrings(result, t.entries.items[0].text.items);
}

test "foreground agent reuse creates a new Run row and late progress stays in the old tree" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.agent({})");
    try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "first", .state = .done, .step = 2 });
    try t.endRun(gpa, true, "done", 100, .{});
    try t.startRun(gpa, "tools.agent({resume:'a1'})");
    try t.progress(gpa, .{ .id = "a1", .run = 2, .prompt = "resume", .step = 1 });
    try testing.expectEqual(@as(usize, 1), t.entries.items[0].agents.items.len);
    try testing.expectEqual(@as(usize, 1), t.entries.items[1].agents.items.len);
    try testing.expectEqualStrings("  └─ a1 first · done · step 2", t.entries.items[0].agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("  └─ a1 resume · working · step 1", t.entries.items[1].agent_tree.rows.items[0].text);
    try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "first", .state = .done, .step = 3 });
    try testing.expectEqualStrings("  └─ a1 first · done · step 3", t.entries.items[0].agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("  └─ a1 resume · working · step 1", t.entries.items[1].agent_tree.rows.items[0].text);
    try t.progress(gpa, .{ .id = "a1", .run = 2, .prompt = "resume", .state = .done, .step = 4 });
    try testing.expectEqualStrings("  └─ a1 resume · done · step 4", t.entries.items[1].agent_tree.rows.items[0].text);
}

test "delivered background agent results do not settle foreground or background reuse" {
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |background| {
        var t: Transcript = .{};
        defer t.deinit(gpa);
        try t.startRun(gpa, "tools.agent({background:true})");
        try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "first", .background = true, .state = .done, .step = 2 });
        try t.endRun(gpa, true, "started", 100, .{});
        try t.backgroundResult(gpa, .agent, "a1", false, "{}");
        try t.startRun(gpa, "tools.agent({resume:'a1'})");
        try t.progress(gpa, .{ .id = "a1", .run = 2, .prompt = "resume", .background = background, .step = 1 });
        try testing.expectEqualStrings("  └─ a1 first · failed · step 2", t.entries.items[0].agent_tree.rows.items[0].text);
        try testing.expectEqual(@as(usize, 1), t.entries.items[2].agents.items.len);
        try testing.expectEqual(.working, t.entries.items[2].agents.items[0].state);
        try testing.expectEqual(background, t.entries.items[2].agents.items[0].background);
        try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "first", .background = true, .state = .done, .step = 3 });
        try testing.expectEqualStrings("  └─ a1 first · failed · step 3", t.entries.items[0].agent_tree.rows.items[0].text);
        try testing.expect(!t.entries.items[0].agents.items[0].background);
        try testing.expectEqual(@as(u32, 1), t.entries.items[2].agents.items[0].step);
        try testing.expectEqual(.working, t.entries.items[2].agents.items[0].state);
        if (background) {
            try t.backgroundResult(gpa, .agent, "a1", true, "{}");
            try t.progress(gpa, .{ .id = "a1", .run = 2, .prompt = "resume", .background = true, .step = 4 });
            try testing.expectEqualStrings("  └─ a1 resume · done · step 4", t.entries.items[2].agent_tree.rows.items[0].text);
            try testing.expect(!t.entries.items[2].agents.items[0].background);
            try testing.expectEqualStrings("  └─ a1 first · failed · step 3", t.entries.items[0].agent_tree.rows.items[0].text);
        }
    }
}

test "delayed background results settle only the oldest undelivered invocation of a reused ID" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "tools.agent({background:true})");
    try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "first", .background = true, .state = .done, .step = 2 });
    try t.endRun(gpa, true, "started", 100, .{});
    try t.startRun(gpa, "tools.agent({resume:'a1',background:true})");
    try t.progress(gpa, .{ .id = "a1", .run = 2, .prompt = "resume", .background = true, .step = 1 });
    try t.endRun(gpa, true, "started", 100, .{});
    try t.backgroundResult(gpa, .agent, "a1", false, "{}");
    try testing.expect(!t.entries.items[0].agents.items[0].background);
    try testing.expect(t.entries.items[1].agents.items[0].background);
    try testing.expectEqual(.working, t.entries.items[1].agents.items[0].state);
    try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "first", .background = true, .state = .done, .step = 3 });
    try testing.expectEqualStrings("  └─ a1 first · failed · step 3", t.entries.items[0].agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("  └─ a1 resume · background · step 1", t.entries.items[1].agent_tree.rows.items[0].text);
    try t.backgroundResult(gpa, .agent, "a1", true, "{}");
    try testing.expectEqualStrings("  └─ a1 resume · done · step 1", t.entries.items[1].agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("  └─ a1 first · failed · step 3", t.entries.items[0].agent_tree.rows.items[0].text);
    try t.progress(gpa, .{ .id = "a1", .run = 2, .prompt = "resume", .background = true, .state = .done, .step = 5 });
    try testing.expectEqualStrings("  └─ a1 resume · done · step 5", t.entries.items[1].agent_tree.rows.items[0].text);
}

test "restored background results cannot settle a reused ID in a new Run" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.addHistory(gpa, &.{.{ .role = "user", .source = .background, .background_kind = .agent, .background_id = "a1", .content = "[background agent a1 finished]\n{\"ok\":true}" }});
    try t.startRun(gpa, "tools.agent({resume:'a1',background:true})");
    try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "resume", .background = true });
    try testing.expect(t.entries.items[1].agents.items[0].background);
    try testing.expectEqual(.working, t.entries.items[1].agents.items[0].state);
    try testing.expectEqualStrings("  └─ a1 resume · background · step 0", t.entries.items[1].agent_tree.rows.items[0].text);
}

test "same Run foreground and background reuse keep invocation results separate from the latest row" {
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |first_background| {
        for ([_]bool{ false, true }) |second_background| {
            var t: Transcript = .{};
            defer t.deinit(gpa);
            try t.startRun(gpa, "reuse a1");
            try t.progress(gpa, .{ .id = "a1", .invocation = 1, .run = 1, .prompt = "first", .background = first_background, .state = .done, .step = 8 });
            try t.progress(gpa, .{ .id = "a1", .invocation = 2, .run = 1, .prompt = "second", .background = second_background, .step = 1 });
            if (first_background) try t.backgroundResult(gpa, .agent, "a1", false, "{}");
            try testing.expectEqual(@as(usize, 2), t.entries.items[0].invocations.items.len);
            try testing.expectEqual(@as(usize, 1), t.entries.items[0].agents.items.len);
            try testing.expectEqual(.working, t.entries.items[0].agents.items[0].state);
            try testing.expectEqual(second_background, t.entries.items[0].agents.items[0].background);
            try t.progress(gpa, .{ .id = "a1", .invocation = 1, .run = 1, .prompt = "late first", .background = first_background, .state = .failed, .step = 9 });
            try testing.expectEqualStrings("second", t.entries.items[0].agents.items[0].prompt);
            if (second_background) try t.backgroundResult(gpa, .agent, "a1", true, "{}");
            try t.progress(gpa, .{ .id = "a1", .invocation = 2, .run = 1, .prompt = "second", .background = second_background, .state = .done, .step = 2 });
            try testing.expectEqualStrings("  └─ a1 second · done · step 2", t.entries.items[0].agent_tree.rows.items[0].text);
            try testing.expect(!t.entries.items[0].agents.items[0].background);
        }
    }
}

test "same Run background results consume a FIFO with sticky per invocation success and failure" {
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |first_ok| {
        for ([_]bool{ false, true }) |result_first| {
            var t: Transcript = .{};
            defer t.deinit(gpa);
            try t.startRun(gpa, "two background calls");
            if (result_first) {
                try t.backgroundResult(gpa, .agent, "a1", first_ok, "{}");
                try t.backgroundResult(gpa, .agent, "a1", !first_ok, "{}");
            }
            try t.progress(gpa, .{ .id = "a1", .invocation = 11, .run = 1, .prompt = "first", .background = true, .state = .done });
            try t.progress(gpa, .{ .id = "a1", .invocation = 12, .run = 1, .prompt = "second", .background = true, .state = .done });
            if (!result_first) {
                try t.backgroundResult(gpa, .agent, "a1", first_ok, "{}");
                try testing.expect(t.entries.items[0].agents.items[0].background);
                try t.backgroundResult(gpa, .agent, "a1", !first_ok, "{}");
            }
            try testing.expectEqual(@as(?bool, first_ok), t.entries.items[0].invocations.items[0].result);
            try testing.expectEqual(@as(?bool, !first_ok), t.entries.items[0].invocations.items[1].result);
            try t.progress(gpa, .{ .id = "a1", .invocation = 11, .run = 1, .prompt = "late first", .background = true, .state = .done, .step = 99 });
            try t.progress(gpa, .{ .id = "a1", .invocation = 12, .run = 1, .prompt = "second", .background = true, .state = .done, .step = 3 });
            const row = t.entries.items[0].agents.items[0];
            try testing.expectEqual(@as(usize, 12), row.invocation);
            try testing.expectEqual(@as(u32, 3), row.step);
            try testing.expectEqual(@as(@FieldType(Progress, "state"), if (first_ok) .failed else .done), row.state);
            try testing.expect(!row.background);
            try testing.expectEqual(@as(usize, 0), t.pending_results.items.len);
        }
    }
}

test "two coalesced background invocations in one drain register before ID only results settle" {
    const gpa = testing.allocator;
    const Queue = @import("../tools/progress.zig").Queue;
    const Sink = struct {
        transcript: *Transcript,
        fn emit(ctx: *anyopaque, value: Progress) !void {
            const sink: *@This() = @ptrCast(@alignCast(ctx));
            try sink.transcript.progress(std.testing.allocator, value);
        }
    };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "background then resume in one Run");
    var sink: Sink = .{ .transcript = &t };
    var q: Queue = .{ .sink = .{ .ctx = &sink, .emit = Sink.emit } };
    defer q.deinit(gpa);
    const id = try q.add(gpa, testing.io, .agent, "first", 1, true);
    const first = q.currentInvocation(testing.io, id);
    try q.update(gpa, testing.io, .{ .id = id, .invocation = first, .run = 1, .prompt = "first", .background = true, .state = .done });
    try q.restart(gpa, testing.io, .{ .id = id, .run = 1, .prompt = "second", .background = true, .state = .queued });
    const second = q.currentInvocation(testing.io, id);
    try q.update(gpa, testing.io, .{ .id = id, .invocation = second, .run = 1, .prompt = "second", .background = true, .state = .failed });
    try t.backgroundResult(gpa, .agent, id, true, "{}");
    try q.drain(testing.io);
    try testing.expectEqual(@as(usize, 2), t.entries.items[0].invocations.items.len);
    try testing.expectEqual(@as(?bool, true), t.entries.items[0].invocations.items[0].result);
    try testing.expectEqual(@as(?bool, null), t.entries.items[0].invocations.items[1].result);
    try testing.expect(t.entries.items[0].agents.items[0].background);
    try t.backgroundResult(gpa, .agent, id, false, "{}");
    try testing.expectEqualStrings("  └─ a1 second · failed · step 0", t.entries.items[0].agent_tree.rows.items[0].text);
    try testing.expect(!t.entries.items[0].agents.items[0].background);
}

test "race progress remains won and stopped after its Run settles" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "await tools.race({branches: []})");
    try t.progress(gpa, .{ .id = "a1", .run = 1, .invocation = 1, .prompt = "winner", .race = true, .fork = true, .state = .won });
    try t.progress(gpa, .{ .id = "a2", .run = 1, .invocation = 2, .prompt = "loser", .race = true, .fork = true, .state = .stopped });
    const e = &t.entries.items[0];
    try testing.expect(std.mem.indexOf(u8, e.label.items, "race ×2") != null);
    try testing.expect(std.mem.indexOf(u8, e.label.items, "1 won, 1 stopped") != null);
    try t.endRun(gpa, true, "ok", 10, .{});
    try testing.expectEqual(.won, e.agents.items[0].state);
    try testing.expectEqual(.stopped, e.agents.items[1].state);
    try testing.expect(std.mem.indexOf(u8, e.agent_tree.rows.items[0].text, "a1 race winner · won") != null);
    try testing.expect(std.mem.indexOf(u8, e.agent_tree.rows.items[1].text, "a2 race loser · stopped") != null);
}
