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
const max_segments = entries.max_segments;
const actualToolSummary = label_text.actualToolSummary;
const promptPrefix = label_text.promptPrefix;
const agent_tree = @import("agent_tree.zig");
const ToolSummary = @import("../session/tool_summary.zig").Summary;

/// What the conversation area shows, built from Session events or replayed history.
pub const Transcript = struct {
    entries: std.ArrayList(Entry) = .empty,
    attempt: usize = 0,
    revision: usize = 0,
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
        t.attempt = 0;
        t.clearPendingResults(gpa, 0);
        t.pending_results.deinit(gpa);
        t.pending_results = .empty;
    }

    pub fn add(t: *Transcript, gpa: std.mem.Allocator, kind: Kind, text: []const u8) !void {
        t.revision +%= 1;
        var e: Entry = .{ .kind = kind, .allocator = gpa };
        errdefer e.deinit(gpa);
        try e.text.appendSlice(gpa, text);
        try e.refreshLabel(gpa);
        try t.entries.append(gpa, e);
    }

    /// The line under a Turn footer; null `changes` adds nothing.
    pub fn addChanges(t: *Transcript, gpa: std.mem.Allocator, changes: ?@import("transcript/changes.zig").TurnChanges) !void {
        const c = changes orelse return;
        defer gpa.free(c.head);
        defer gpa.free(c.rows);
        t.revision +%= 1;
        var e: Entry = .{ .kind = .changes, .allocator = gpa };
        errdefer e.deinit(gpa);
        try e.label.appendSlice(gpa, c.head);
        try e.text.appendSlice(gpa, c.rows);
        try t.entries.append(gpa, e);
    }

    pub fn backgroundResult(t: *Transcript, gpa: std.mem.Allocator, kind: BackgroundKind, id: []const u8, ok: bool, result: []const u8) !void {
        t.revision +%= 1;
        try t.settleBackgroundProgress(gpa, kind, id, ok);
        if (kind == .run) if (t.backgroundRunEntry(id)) |entry| {
            entry.output.clearRetainingCapacity();
            try entry.output.appendSlice(gpa, result);
            try entry.refreshLabel(gpa);
            entry.cached = null;
            return;
        };
        var e: Entry = .{ .kind = .background, .run = if (ok) .ok else .failed };
        errdefer e.deinit(gpa);
        e.task_id = try gpa.dupe(u8, id);
        try e.text.appendSlice(gpa, result);
        try e.label.print(gpa, "{s} {s} · {s}", .{ id, if (kind == .run) "Run" else @tagName(kind), if (ok) "completed" else "failed" });
        const Summary = struct { superseded_by: ?[]const u8 = null, exit_code: ?u8 = null, @"error": ?[]const u8 = null };
        const parsed = std.json.parseFromSlice(Summary, gpa, result, .{ .ignore_unknown_fields = true }) catch null;
        if (parsed) |summary| {
            defer summary.deinit();
            if (summary.value.superseded_by) |replacement| {
                e.run = .superseded;
                e.label.clearRetainingCapacity();
                try e.label.print(gpa, "{s} superseded by {s}", .{ id, replacement });
                try t.replaceBash(gpa, id, replacement);
            }
            if (!ok and std.mem.indexOf(u8, summary.value.@"error" orelse "", "timed out") != null) {
                e.run = .warning;
                e.label.clearRetainingCapacity();
                try e.label.print(gpa, "{s} {s} · timed out", .{ id, @tagName(kind) });
            }
            if (kind == .bash) if (summary.value.exit_code) |code| try e.label.print(gpa, " · exit {d}", .{code});
        }
        try t.entries.append(gpa, e);
    }

    fn replaceBash(t: *Transcript, gpa: std.mem.Allocator, id: []const u8, replacement: []const u8) !void {
        for (t.entries.items) |*entry| {
            for (entry.agents.items) |*p| {
                if (!std.mem.eql(u8, p.id, id)) continue;
                const copy = try gpa.dupe(u8, replacement);
                if (p.superseded_by) |old| gpa.free(old);
                p.superseded_by = copy;
                p.state = .done;
                p.background = false;
            }
            try entry.refreshAgents(gpa);
            try entry.refreshLabel(gpa);
            entry.cached = null;
        }
    }

    pub fn lostBackground(t: *Transcript, gpa: std.mem.Allocator, kind: BackgroundKind, id: []const u8, result: []const u8) !void {
        t.revision +%= 1;
        try t.settleBackgroundProgress(gpa, kind, id, false);
        if (kind == .run) if (t.backgroundRunEntry(id)) |entry| {
            entry.run = .lost;
            entry.output.clearRetainingCapacity();
            try entry.output.appendSlice(gpa, result);
            try entry.refreshLabel(gpa);
            entry.cached = null;
            return;
        };
        var e: Entry = .{ .kind = .background, .run = .warning };
        errdefer e.deinit(gpa);
        e.task_id = try gpa.dupe(u8, id);
        try e.label.print(gpa, "{s} {s} · lost", .{ id, @tagName(kind) });
        try e.text.appendSlice(gpa, result);
        try t.entries.append(gpa, e);
    }

    fn settleBackgroundProgress(t: *Transcript, gpa: std.mem.Allocator, kind: BackgroundKind, id: []const u8, ok: bool) !void {
        for (t.entries.items) |*entry| {
            if (kind != .run or entry.kind != .run or !std.mem.eql(u8, entry.task_id orelse "", id)) continue;
            entry.run = if (ok) .ok else if (entry.run == .timed_out or entry.run == .canceled) entry.run else .failed;
            try entry.refreshLabel(gpa);
            entry.cached = null;
        }
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

    pub fn toggle(t: *Transcript, index: usize) void {
        const e = &t.entries.items[index];
        if (e.collapsible()) e.open = !e.open;
    }

    /// Latest Run, background or failure entry; Ctrl+O targets it.
    pub fn latestDetails(t: *const Transcript) ?usize {
        var i = t.entries.items.len;
        while (i > 0) {
            i -= 1;
            const k = t.entries.items[i].kind;
            if (k == .run or k == .background or k == .failure or (k == .changes and !t.entries.items[i].simple)) return i;
        }
        return null;
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
        if (kind == .reasoning or text.len == 0) return;
        t.revision +%= 1;
        const entry_kind: Kind = .assistant;
        const items = t.entries.items;
        if (items.len == 0 or items[items.len - 1].kind != entry_kind or items[items.len - 1].attempt != t.attempt) try t.entries.append(gpa, .{ .kind = entry_kind, .attempt = t.attempt });
        const current = &t.entries.items[t.entries.items.len - 1];
        current.allocator = gpa;
        try current.text.appendSlice(gpa, text);
    }

    pub fn smoothDelta(t: *Transcript, gpa: std.mem.Allocator, text: []const u8, now: std.Io.Clock.Timestamp) !void {
        const old = if (t.entries.items.len > 0 and t.entries.items[t.entries.items.len - 1].kind == .assistant and t.entries.items[t.entries.items.len - 1].attempt == t.attempt) t.entries.items[t.entries.items.len - 1].text.items.len else 0;
        try t.appendDelta(gpa, .text, text);
        if (text.len == 0) return;
        const entry = &t.entries.items[t.entries.items.len - 1];
        if (entry.smooth == null) entry.smooth = .{ .visible = old };
        entry.smooth.?.arrive(old, entry.text.items.len, now);
    }

    pub fn flushVisible(t: *Transcript) void {
        for (t.entries.items) |*e| if (e.smooth) |*s| s.flush(e.text.items.len);
    }

    pub fn advanceVisible(t: *Transcript, now: std.Io.Clock.Timestamp) void {
        for (t.entries.items) |*e| if (e.smooth) |*s| s.advance(e.text.items, now);
    }

    pub fn hasBacklog(t: *const Transcript) bool {
        for (t.entries.items) |e| if (e.smooth) |s| if (s.deadline != null) return true;
        return false;
    }

    pub fn beginAttempt(t: *Transcript) void {
        t.attempt += 1;
    }

    pub fn discardAttempt(t: *Transcript, gpa: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < t.entries.items.len) {
            const e = &t.entries.items[i];
            if (e.kind == .assistant and e.attempt == t.attempt) {
                var removed = t.entries.orderedRemove(i);
                removed.deinit(gpa);
            } else i += 1;
        }
    }

    pub fn clearRetry(t: *Transcript, gpa: std.mem.Allocator, scroll: *@import("viewport.zig").Viewport) void {
        var i: usize = 0;
        while (i < t.entries.items.len) {
            if (!t.entries.items[i].retry_placeholder) {
                i += 1;
                continue;
            }
            var removed = t.entries.orderedRemove(i);
            removed.deinit(gpa);
            scroll.removed(i);
            t.revision +%= 1;
        }
    }

    pub fn retryAttempt(t: *Transcript, gpa: std.mem.Allocator, scroll: *@import("viewport.zig").Viewport) !void {
        var kept = false;
        var i: usize = 0;
        while (i < t.entries.items.len) {
            const e = &t.entries.items[i];
            if (e.retry_placeholder) kept = true;
            if (e.kind != .assistant or e.attempt != t.attempt) {
                i += 1;
                continue;
            }
            if (!kept) {
                e.deinit(gpa);
                e.* = .{ .kind = .info, .retry_placeholder = true };
                try e.text.appendSlice(gpa, "Interrupted · retrying");
                t.revision +%= 1;
                if (scroll.top) |*top| {
                    if (top.entry == i) top.row = 0;
                }
                kept = true;
                i += 1;
            } else {
                var removed = t.entries.orderedRemove(i);
                removed.deinit(gpa);
                scroll.removed(i);
            }
        }
    }

    pub fn failure(t: *Transcript, gpa: std.mem.Allocator, message: []const u8, reason: @import("../tools/changes.zig").Recovery.Reason) !void {
        t.revision +%= 1;
        var e: Entry = .{ .kind = .failure, .run = if (reason == .timeout) .warning else .failed };
        errdefer e.deinit(gpa);
        try e.text.appendSlice(gpa, message);
        const sentence = switch (reason) {
            .timeout => "The request timed out.",
            .limit => "The step limit was reached.",
            .tool => "The Run failed.",
            else => "The model request failed.",
        };
        try e.label.print(gpa, "{s}", .{sentence});
        try t.entries.append(gpa, e);
    }

    pub fn startRun(t: *Transcript, gpa: std.mem.Allocator, code: []const u8) !void {
        try t.startRunWithEffort(gpa, code, null);
    }

    pub fn startRunWithEffort(t: *Transcript, gpa: std.mem.Allocator, code: []const u8, effort: ?provider.StepEffort) !void {
        t.revision +%= 1;
        try t.addRun(gpa, code, false, effort);
        t.next_run += 1;
        t.entries.items[t.entries.items.len - 1].run_number = t.next_run;
    }

    fn sameStrings(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }

    pub fn progressChanged(t: *const Transcript, p: Progress) bool {
        for (t.entries.items) |entry| for (entry.agents.items) |old| {
            if (!std.mem.eql(u8, old.id, p.id) or old.invocation != p.invocation) continue;
            return old.state != p.state or old.step != p.step or old.output_bytes != p.output_bytes or !sameStrings(old.tools, p.tools) or !sameStrings(old.files, p.files);
        };
        return true;
    }

    pub fn activityDetail(t: *const Transcript, buf: []u8, tool: []const u8) []const u8 {
        var i = t.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = &t.entries.items[i];
            if (entry.kind != .run) continue;
            if (entry.run != .running) continue;
            for (entry.agents.items) |p| {
                if (p.detached or (p.state != .queued and p.state != .working)) continue;
                if (!p.background and (tool.len == 0 or std.mem.eql(u8, @tagName(p.kind), tool))) {
                    const text = std.fmt.bufPrint(buf, "{s} {s}", .{ @tagName(p.kind), promptPrefix(p.prompt) }) catch return tool;
                    for (text) |*byte| if (byte.* < 0x20 or byte.* == 0x7f) {
                        byte.* = ' ';
                    };
                    return text;
                }
            }
        }
        return tool;
    }

    pub fn progress(t: *Transcript, gpa: std.mem.Allocator, p: Progress) !void {
        if (t.progressChanged(p)) t.revision +%= 1;
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
                    if (entry.kind == .run and entry.run_number == p.run and (entry.run == .running or entry.run == .background or p.background)) break :target entry;
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
        if (p.kind == .run and std.mem.eql(u8, p.id, e.task_id orelse "")) {
            if (p.state == .timed_out) e.run = .timed_out;
            if (p.state == .canceled) e.run = .canceled;
        }
        try e.refreshAgents(gpa);
        try e.refreshLabel(gpa);
        e.cached = null;
    }

    /// Takes ownership of `changes`.
    pub fn hookNotice(t: *Transcript, gpa: std.mem.Allocator, message: []const u8) !void {
        const e = t.lastRunning() orelse return;
        try e.hook_notice.appendSlice(gpa, message);
        e.cached = null;
        t.revision +%= 1;
    }

    pub fn endRun(t: *Transcript, gpa: std.mem.Allocator, ok: bool, output: []const u8, elapsed_ms: u64, changes: ChangeText) !void {
        try t.endRunWithSummary(gpa, ok, output, elapsed_ms, changes, null);
    }

    /// Takes ownership of `changes`; borrows `summary`.
    pub fn endRunWithSummary(t: *Transcript, gpa: std.mem.Allocator, ok: bool, output: []const u8, elapsed_ms: u64, changes: ChangeText, summary: ?ToolSummary) !void {
        t.revision +%= 1;
        const e = t.lastRunning() orelse {
            var c = changes;
            c.deinit(gpa);
            return;
        };
        e.run = if (e.task_id != null) .background else if (ok) .ok else .failed;
        e.elapsed_ms = elapsed_ms;
        e.changes.deinit(gpa);
        e.changes = changes;
        if (summary) |value| e.tool_summary = try value.clone(gpa);
        try e.output.appendSlice(gpa, output);
        try e.refreshLabel(gpa);
        e.cached = null;
    }

    fn backgroundRunEntry(t: *Transcript, id: []const u8) ?*Entry {
        for (t.entries.items) |*entry| if (entry.kind == .run and std.mem.eql(u8, entry.task_id orelse "", id)) return entry;
        return null;
    }

    pub fn backgroundHookNotice(t: *Transcript, gpa: std.mem.Allocator, id: []const u8, notice: []const u8) !void {
        const e = t.backgroundRunEntry(id) orelse return;
        try e.hook_notice.appendSlice(gpa, notice);
        e.cached = null;
        t.revision +%= 1;
    }

    pub fn updateBackgroundRun(t: *Transcript, gpa: std.mem.Allocator, id: []const u8, output: []const u8, changes: ChangeText, summary: ToolSummary) !void {
        for (t.entries.items) |*entry| {
            if (entry.kind != .run or !std.mem.eql(u8, entry.task_id orelse "", id)) continue;
            entry.output.clearRetainingCapacity();
            try entry.output.appendSlice(gpa, output);
            const changed = try changes.clone(gpa);
            const used = summary.clone(gpa) catch |err| {
                var owned = changed;
                owned.deinit(gpa);
                return err;
            };
            entry.changes.deinit(gpa);
            entry.changes = changed;
            if (entry.tool_summary) |old| old.deinit(gpa);
            entry.tool_summary = used;
            try entry.refreshLabel(gpa);
            entry.cached = null;
            return;
        }
    }

    pub fn backgroundRun(t: *Transcript, gpa: std.mem.Allocator, id: []const u8) !void {
        const entry = t.lastRunning() orelse return;
        entry.task_id = try gpa.dupe(u8, id);
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
                const shown = if (m.background_run != null and t.backgroundRunEntry(m.background_id orelse "?") == null) try runResultText(gpa, m.background_run.?.output, m.background_run.?.changes) else null;
                defer if (shown) |text| gpa.free(text);
                if (m.background_run) |completion| {
                    var changes = try ChangeText.init(gpa, completion.changes);
                    defer changes.deinit(gpa);
                    const summary = try ToolSummary.init(gpa, completion.calls, completion.run_index, completion.calls_omitted);
                    defer summary.deinit(gpa);
                    try t.updateBackgroundRun(gpa, m.background_id orelse "?", completion.output, changes, summary);
                }
                try t.backgroundResult(gpa, kind, m.background_id orelse "?", m.background_ok orelse parsed_ok, shown orelse result);
            } else if (m.source == .undo) {
                try t.add(gpa, .info, content);
            } else if (std.mem.eql(u8, m.role, "user")) {
                try t.add(gpa, .user, @import("../session/skills.zig").typed(content));
            } else if (std.mem.eql(u8, m.role, "assistant")) {
                if (content.len > 0) try t.add(gpa, if (m.waiting orelse false) .info else .assistant, content);
                for (m.tool_calls orelse &.{}) |call| {
                    const Args = struct { code: []const u8 = "" };
                    const args = std.json.parseFromSlice(Args, gpa, call.function.arguments, .{ .ignore_unknown_fields = true }) catch continue;
                    defer args.deinit();
                    var code = args.value.code;
                    for (history) |result| {
                        if (std.mem.eql(u8, result.tool_call_id orelse "", call.id)) {
                            code = result.executed_source orelse code;
                            break;
                        }
                    }
                    try t.addRun(gpa, code, false, m.step_effort);
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
                    e.run = if (m.background_id != null) .background else if (m.run_ok orelse true) .ok else .failed;
                    if (m.background_id) |id| e.task_id = try gpa.dupe(u8, id);
                    for (m.bash_replacements orelse &.{}) |b| {
                        const p: Progress = .{ .id = b.id, .kind = .bash, .prompt = b.command orelse "", .state = .done, .elapsed_ms = b.elapsed_ms orelse 0, .superseded_by = b.superseded_by };
                        try e.agents.append(gpa, try p.clone(gpa));
                    }
                    try e.refreshAgents(gpa);
                    if (m.tool_summary) |summary| e.tool_summary = try summary.clone(gpa);
                    try e.output.appendSlice(gpa, content);
                    try e.refreshLabel(gpa);
                }
            }
        }
    }

    fn addRun(t: *Transcript, gpa: std.mem.Allocator, code: []const u8, open: bool, effort: ?provider.StepEffort) !void {
        var e: Entry = .{ .kind = .run, .open = open };
        errdefer e.deinit(gpa);
        if (effort) |value| e.step_effort = .{ .effort = try gpa.dupe(u8, value.effort) };
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

fn toggleAll(t: *Transcript) void {
    var any = false;
    for (t.entries.items) |e| any = any or (e.collapsible() and e.open);
    for (t.entries.items) |*e| if (e.collapsible()) {
        e.open = !any;
    };
}

test "background results fold to task facts and expand to complete JSON" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    const result = "{\"ok\":true,\"text\":\"found it\\nsecond line\",\"changes\":[],\"usage\":{}}";
    try t.backgroundResult(gpa, .agent, "bg_1", true, result);
    const e = &t.entries.items[0];
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expect(e.collapsible());
    try testing.expectEqual(@as(usize, 2), e.segments(&segs).len);
    try testing.expectEqualStrings("bg_1 agent · completed", segs[1].text);
    toggleAll(&t);
    try testing.expectEqual(@as(usize, 4), e.segments(&segs).len);
    try testing.expectEqualStrings(result, segs[3].text);
    try testing.expect(t.lastAnswer() == null);
    try t.backgroundResult(gpa, .agent, "bg_2", false, "{\"ok\":false,\"text\":\"failed\"}");
    try testing.expect(!t.entries.items[1].open);
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
    try testing.expectEqualStrings("bg_1 agent · completed", t.entries.items[0].label.items);
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
    try testing.expect(std.mem.indexOf(u8, t.entries.items[0].label.items, "a1 running") != null);
    try t.backgroundResult(gpa, .agent, "a1", true, "{\"ok\":true,\"text\":\"done\"}");
    try testing.expectEqual(@as(usize, 1), t.entries.items[0].agent_tree.rows.items.len);
    try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "first", .background = true, .state = .done, .step = 3 });
    try testing.expect(!t.entries.items[0].agents.items[0].background);
    try testing.expectEqualStrings("Run", t.entries.items[0].label.items);
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
    try testing.expectEqualStrings("  └─ b2 bash echo done · <1s · completed", t.entries.items[0].agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("Run", t.entries.items[0].label.items);
    try testing.expectEqualStrings("b2 bash · completed · exit 0", t.entries.items[1].label.items);
}

test "truncated background result still previews text and lost result is visible" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.backgroundResult(gpa, .agent, "a1", false, "{\"ok\":false,\"text\":\"partial result");
    try testing.expectEqualStrings("a1 agent · failed", t.entries.items[0].label.items);
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
    try testing.expectEqualStrings("Run · b1 running", t.entries.items[0].label.items);
    toggleAll(&t);
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("  └─ b1 bash sleep 2 echo done · 1s · running", t.entries.items[0].agent_tree.rows.items[0].text);
    try t.backgroundResult(gpa, .bash, "b1", true, "{\"exit_code\":0,\"output\":\"done\\n\"}");
    try testing.expectEqualStrings("Run", t.entries.items[0].label.items);
    try testing.expectEqualStrings("b1 bash · completed · exit 0", t.entries.items[1].label.items);
    t.toggle(1);
    try testing.expectEqualStrings("{\"exit_code\":0,\"output\":\"done\\n\"}", t.entries.items[1].segments(&segs)[3].text);
}

test "restored background bash uses its persisted kind" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.addHistory(gpa, &.{.{ .role = "user", .content = "[background bash b1 finished]\n{\"exit_code\":0,\"output\":\"ready\"}", .source = .background, .background_kind = .bash, .background_id = "b1" }});
    try testing.expectEqualStrings("b1 bash · completed · exit 0", t.entries.items[0].label.items);
    try t.addHistory(gpa, &.{.{ .role = "user", .content = "[background bash b2 finished]\n{\"exit_code\":1,\"output\":\"failed\"}", .source = .background, .background_kind = .bash, .background_id = "b2" }});
    try testing.expectEqualStrings("b2 bash · failed · exit 1", t.entries.items[1].label.items);
    try t.addHistory(gpa, &.{.{ .role = "user", .content = "[background bash b3 finished]\n{\"output\":\"partial", .source = .background, .background_kind = .bash, .background_id = "b3", .background_ok = true }});
    try testing.expectEqualStrings("b3 bash · completed", t.entries.items[2].label.items);
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
    try testing.expectEqualStrings("Run", e.segments(&segs)[2].text);
    toggleAll(&t);
    try testing.expectEqual(@as(u16, 7), e.height(win));
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
        .{ .role = "assistant", .reasoning = .{ .provider = .codex, .data = "[{\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"opaque\"}]" } },
        .{ .role = "assistant", .reasoning = .{ .provider = .chat_completions, .data = "hidden thinking" }, .tool_calls = &.{.{ .id = "1", .function = .{ .name = "run", .arguments = "{\"code\":\"tools.bash({})\"}" } }} },
        .{ .role = "tool", .tool_call_id = "1", .content = "out" },
        .{ .role = "assistant", .content = "answer", .reasoning = .{ .provider = .codex, .data = "[{\"summary\":[{\"text\":\"hidden summary\"}]}]" } },
    });
    try testing.expectEqual(@as(usize, 3), t.entries.items.len);
    try testing.expectEqualStrings("answer", t.lastAnswer().?);
    try testing.expectEqualStrings("out", t.entries.items[1].output.items);
    try testing.expect(t.entries.items[1].run == .ok);
}

test "restored waiting replies are notices rather than answers" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.addHistory(gpa, &.{.{ .role = "assistant", .content = "Waiting.", .waiting = true }});
    try testing.expectEqual(Kind.info, t.entries.items[0].kind);
    try testing.expect(t.lastAnswer() == null);
}

test "Run and background titles use the normal foreground while summaries stay dim" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 60, .rows = 8, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 8, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "await tools.edit({})");
    const changes = [_]Change{.{ .path = "src/a.zig", .added = 1, .removed = 1, .diff = " keep\n-old\n+new\n" }};
    try t.endRun(gpa, true, "", 300, try .init(gpa, &changes));
    const e = &t.entries.items[0];
    _ = e.print(win, true);
    try testing.expectEqualStrings("R", screen.readCell(2, 0).?.char.grapheme);
    try testing.expect(!screen.readCell(2, 0).?.style.dim);
    try testing.expect(screen.readCell(2, 1).?.style.dim);
    var segs: [max_segments]vaxis.Segment = undefined;
    var b: Entry = .{ .kind = .background, .run = .failed };
    defer b.deinit(gpa);
    try b.label.appendSlice(gpa, "b1 failed");
    const shown = b.segments(&segs);
    try testing.expectEqual(@as(u8, 1), shown[0].style.fg.index);
    try testing.expect(!shown[1].style.dim);
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
    try testing.expectEqualStrings("Run", e.label.items);
    try testing.expectEqual(@as(u16, 2), e.height(win));
    toggleAll(&t);
    const text_view = try entryText(gpa, e, 60);
    defer gpa.free(text_view);
    try testing.expect(std.mem.indexOf(u8, text_view, "▸ src/a.zig +1 −1") != null);
    try testing.expect(std.mem.indexOf(u8, text_view, "▸ b.md (new) +1 −0") != null);
    try testing.expect(std.mem.indexOf(u8, text_view, "-old") == null);
    try testing.expectEqual(@as(u16, 9), e.height(win));

    var many: [3]Change = undefined;
    for (&many) |*c| c.* = .{ .path = "x", .added = 2, .removed = 1, .diff = "" };
    var text: ChangeText = try .init(gpa, &many);
    defer text.deinit(gpa);
    try testing.expectEqualStrings("x +2 −1 · x +2 −1 · x +2 −1", text.summary);
}

test "an open Run emphasizes the changed middle of paired diff lines" {
    const gpa = testing.allocator;
    var screen: vaxis.Screen = try .init(gpa, .{ .cols = 40, .rows = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 40, .height = 20, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "x");
    const diff = "-let count = 10; // total\n+let count = 11; // total\n";
    try t.endRun(gpa, true, "", 300, try .init(gpa, &.{.{ .path = "a.zig", .added = 1, .removed = 1, .diff = diff }}));
    toggleAll(&t);
    const e = &t.entries.items[0];
    const rows = e.print(win, true);
    try testing.expectEqual(e.height(win), rows);
    try testing.expectEqualStrings("0", screen.readCell(20, 4).?.char.grapheme);
    try testing.expect(screen.readCell(20, 4).?.style.bold);
    try testing.expect(!screen.readCell(19, 4).?.style.bold);
    try testing.expectEqual(@as(u8, 1), screen.readCell(20, 4).?.style.fg.index);
    try testing.expectEqual(@as(u8, 2), screen.readCell(20, 5).?.style.fg.index);
}

test "agent tree stays visible folded, expanded and after Run ends" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "await tools.agent({prompt: 'fix it'})");
    try t.progress(gpa, .{ .id = "a1", .prompt = "fix it", .step = 3, .tools = &.{"edit"}, .files = &.{"src/x.zig"}, .usage = .{ .prompt_tokens = 41000 } });
    const e = &t.entries.items[0];
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("Run · running", e.segments(&segs)[2].text);
    try testing.expectEqualStrings("", e.segments(&segs)[1].text);
    toggleAll(&t);
    try testing.expectEqualStrings("  └─ a1 fix it · running · step 3 · edit src/x.zig", e.agent_tree.rows.items[0].text);
    try testing.expect(!e.details.script_open);
    try t.progress(gpa, .{ .id = "a1", .prompt = "fix it", .state = .done, .step = 3, .tools = &.{"edit"}, .files = &.{"src/x.zig"} });
    try t.endRun(gpa, true, "done", 1234, .{});
    try testing.expectEqualStrings("Run", e.segments(&segs)[2].text);
    try testing.expectEqualStrings("", e.segments(&segs)[1].text);
    const opened = try entryText(gpa, e, 120);
    defer gpa.free(opened);
    try testing.expect(std.mem.indexOf(u8, opened, "done") != null);
    try testing.expectEqualStrings("  └─ a1 fix it · completed · step 3 · edit src/x.zig", e.agent_tree.rows.items[0].text);
    try t.progress(gpa, .{ .id = "a1", .prompt = "late" });
    try testing.expectEqualStrings("Run", e.label.items);
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
    try testing.expectEqualStrings("Run · running", e.segments(&segs)[2].text);
    toggleAll(&t);
    try testing.expectEqual(@as(usize, 3), e.agent_tree.rows.items.len);
    try testing.expectEqualStrings("  ├─ a3 third · running · step 1", e.agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("  ├─ a1 first · completed · step 2 · read", e.agent_tree.rows.items[1].text);
    try testing.expectEqualStrings("  └─ a2 second · running · step 3 · edit a.zig", e.agent_tree.rows.items[2].text);
    try t.progress(gpa, .{ .id = "a3", .prompt = "third", .state = .timed_out, .step = 1, .usage = .{ .prompt_tokens = 40000 } });
    try testing.expectEqual(@as(usize, 3), e.agents.items.len);
    try testing.expectEqualStrings("Run · a3 timed out · running", e.label.items);
    try t.endRun(gpa, true, "out", 9000, .{});
    try testing.expectEqualStrings("Run · a3 timed out", e.label.items);
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

test "user cards tint wrapped rows, retain terminal foreground and leave gaps unstyled" {
    const gpa = testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .cols = 18, .rows = 8, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 18, .height = 8, .screen = &screen };
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.add(gpa, .user, "hello world message\n第二行");
    const entry = &t.entries.items[0];
    entry.user_bg = .{ .rgb = .{ 15, 20, 28 } };
    const height = entry.height(win);
    try testing.expect(height >= 3);
    try testing.expectEqual(height, entry.print(win, true));
    for (0..height) |row| {
        try testing.expectEqualStrings("▎", screen.readCell(0, @intCast(row)).?.char.grapheme);
        try testing.expectEqualDeep(entry.user_bg, screen.readCell(17, @intCast(row)).?.style.bg);
        const body = screen.readCell(2, @intCast(row)).?;
        try testing.expect(body.style.fg == .default);
        try testing.expect(!body.style.bold);
    }
    try testing.expectEqualStrings("h", screen.readCell(2, 0).?.char.grapheme);
    try testing.expectEqualStrings(" ", screen.readCell(1, 0).?.char.grapheme);
    try testing.expect(screen.readCell(0, height).?.style.bg == .default);
    win.clear();
    _ = entry.print(win.child(.{ .y_off = -1, .height = height }), true);
    try testing.expectEqualStrings("▎", screen.readCell(0, 0).?.char.grapheme);
    try testing.expect(screen.readCell(0, height - 1).?.style.bg == .default);
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
    try testing.expectEqualStrings("s", screen.readCell(28, 0).?.char.grapheme);
    try testing.expect(screen.readCell(28, 0).?.style.dim);
    toggleAll(&t);
    try testing.expect(e.height(win) > 5);
    t.clear(gpa);
    try t.addHistory(gpa, &.{.{ .role = "user", .content = raw }});
    e = &t.entries.items[0];
    try testing.expectEqual(@as(u16, 1), e.height(win));
    toggleAll(&t);
    try testing.expect(e.height(win) > 5);
    try t.add(gpa, .user, raw);
    try testing.expect(!t.entries.items[1].open);
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
    const full = text.format(.{ .steps = 12, .timing = .{ .wall_ms = 190_000, .llm_calls = 8, .agent_calls = 1 } }, 2, 120);
    try transcript.add(gpa, .bill, full);
    const entry = &transcript.entries.items[0];
    for ([_]u16{ 120, 40, 8, 1, 0, 120 }) |width| {
        win.width = width;
        win.clear();
        toggleAll(&transcript);
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

test "Run retains effort metadata without exposing it in the title" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    for ([_]provider.StepEffort{
        .{ .effort = "low" },
        .{ .effort = "high" },
        .{ .effort = "default" },
    }) |effort| {
        try t.startRunWithEffort(gpa, "tools.edit({})", effort);
        const e = &t.entries.items[t.entries.items.len - 1];
        try testing.expectEqualStrings(effort.effort, e.step_effort.?.effort);
        try testing.expectEqualStrings("Run · running", e.label.items);
        try t.endRun(gpa, true, "output", 1234, .{ .summary = try gpa.dupe(u8, "a.zig +1 −0") });
        try testing.expectEqualStrings("Run", e.label.items);
        try testing.expectEqualStrings("a.zig +1 −0", e.changes.summary);
    }
}

test "history Run effort is copied from assistant metadata and absent in legacy history" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    var effort = [_]u8{ 'h', 'i', 'g', 'h' };
    const calls: []const provider.ToolCall = &.{.{ .id = "1", .function = .{ .name = "run", .arguments = "{\"code\":\"tools.bash({})\"}" } }};
    try t.addHistory(gpa, &.{
        .{ .role = "assistant", .tool_calls = calls, .step_effort = .{ .effort = &effort } },
        .{ .role = "tool", .tool_call_id = "1", .content = "out" },
        .{ .role = "assistant", .tool_calls = calls },
        .{ .role = "tool", .tool_call_id = "1", .content = "out" },
    });
    effort[0] = 'x';
    try t.entries.items[0].refreshLabel(gpa);
    try testing.expectEqualStrings("Run", t.entries.items[0].label.items);
    try testing.expectEqualStrings("Run", t.entries.items[1].label.items);
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
    toggleAll(&t);
    try testing.expectEqual(@as(u16, 8), e.height(win));
    _ = e.print(win, true);
    try testing.expectEqualStrings("R", screen.readCell(4, 4).?.char.grapheme);
    try t.progress(gpa, .{ .id = "a2", .prompt = "second", .state = .failed, .step = 4, .tools = &.{"bash"} });
    try testing.expectEqual(@as(u16, 8), e.height(win));
    try t.endRun(gpa, true, "result", 2000, .{});
    try testing.expectEqual(@as(u16, 8), e.height(win));
    _ = e.print(win, true);
    try testing.expectEqualStrings("r", screen.readCell(4, 5).?.char.grapheme);
    try testing.expectEqualStrings("  ├─ a2 second · failed · step 4 · bash", e.agent_tree.rows.items[0].text);
    toggleAll(&t);
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
    try testing.expectEqualStrings("Run · running", t.entries.items[0].label.items);
    const calls = [_]@import("../sandbox/timing.zig").Call{
        .{ .name = "edit", .start_ms = 0, .end_ms = 1, .ok = true, .run_index = 0 },
        .{ .name = "llm", .start_ms = 1, .end_ms = 1, .ok = false, .run_index = 0, .dispatched = false },
        .{ .name = "bash", .start_ms = 1, .end_ms = 2, .ok = false, .run_index = 0 },
    };
    const summary = try ToolSummary.init(gpa, &calls, 0, 0);
    defer summary.deinit(gpa);
    try t.endRunWithSummary(gpa, false, "failed bash", 200, .{}, summary);
    try testing.expectEqualStrings("Run · edit · bash", t.entries.items[0].label.items);
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
    try testing.expectEqualStrings("Run · read ×200 · +3", t.entries.items[0].label.items);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("+3", actualToolSummary(.{ .omitted = 3 }, 0, &buf));
}

test "empty actual summary does not fall back to source text" {
    var t: Transcript = .{};
    defer t.deinit(testing.allocator);
    try t.startRun(testing.allocator, "// tools.llm({})");
    try t.endRunWithSummary(testing.allocator, true, "done", 0, .{}, .{});
    try testing.expectEqualStrings("Run", t.entries.items[0].label.items);
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
    try testing.expectEqualStrings("Run · edit · +2", t.entries.items[0].label.items);
    try testing.expectEqualStrings("Run · bash ×2 · +3", t.entries.items[1].label.items);
    try testing.expectEqualStrings("first output", t.entries.items[0].output.items);
    try testing.expectEqualStrings("second output", t.entries.items[1].output.items);
    const compacted = try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(log.Record{ .messages = history.items }, .{ .emit_null_optional_fields = false })});
    history = .empty;
    _ = try log.replay(a, a, compacted, &history, &tokens);
    t.clear(testing.allocator);
    try t.addHistory(testing.allocator, history.items);
    try testing.expectEqualStrings("Run · edit · +2", t.entries.items[0].label.items);
    try testing.expectEqualStrings("Run · bash ×2 · +3", t.entries.items[1].label.items);
}

test "legacy logs without tool facts keep a plain Run title" {
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
    try testing.expectEqualStrings("Run", t.entries.items[0].label.items);
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
        try testing.expectEqualStrings("Run · read ×200", t.entries.items[0].label.items);
        try testing.expectEqualStrings("Run", t.entries.items[1].label.items);
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
    try testing.expectEqualStrings("  ├─ a10 updated · running · step 3", t.entries.items[0].agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("  ├─ b2 bash echo ready · 3m12s · waiting", t.entries.items[0].agent_tree.rows.items[1].text);
    try testing.expectEqualStrings("  └─ a2 last · failed · step 2", t.entries.items[0].agent_tree.rows.items[2].text);
    try t.endRun(gpa, true, "started", 100, .{});
    try t.startRun(gpa, "tools.read({})");
    try t.progress(gpa, .{ .id = "b2", .kind = .bash, .prompt = "echo ready", .background = true, .state = .done, .elapsed_ms = 192_000 });
    try testing.expectEqual(@as(usize, 0), t.entries.items[1].agents.items.len);
    try t.backgroundResult(gpa, .bash, "b2", true, "{\"exit_code\":0,\"output\":\"ready\"}");
    try testing.expectEqualStrings("  ├─ b2 bash echo ready · 3m12s · completed", t.entries.items[0].agent_tree.rows.items[1].text);
    try testing.expect(t.entries.items[0].agents.items[2].background);
    try t.lostBackground(gpa, .agent, "a2", "[background agent a2 lost: process ended]");
    try testing.expectEqualStrings("  └─ a2 last · failed · step 2", t.entries.items[0].agent_tree.rows.items[2].text);
    try t.progress(gpa, .{ .id = "a2", .run = 1, .prompt = "last", .background = true, .state = .done, .step = 4 });
    try testing.expect(!t.entries.items[0].agents.items[2].background);
    try testing.expectEqualStrings("  └─ a2 last · failed · step 4", t.entries.items[0].agent_tree.rows.items[2].text);
    try testing.expectEqualStrings("b2 bash · completed · exit 0", t.entries.items[2].label.items);
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
    const labels = [_][]const u8{ "b2 bash · completed · exit 0", "a2 agent · failed", "a10 agent · lost" };
    for (live.entries.items, restored.entries.items, labels, 0..) |*a, *b, label, i| {
        try testing.expectEqualStrings(label, a.label.items);
        try testing.expectEqualStrings(label, b.label.items);
        try testing.expectEqualStrings(if (i == 0) "✓ " else if (i == 2) "! " else "✗ ", a.segments(&left)[0].text);
        try testing.expectEqualStrings(a.segments(&left)[0].text, b.segments(&right)[0].text);
        try testing.expectEqual(@as(usize, 2), b.segments(&right).len);
    }
    toggleAll(&live);
    toggleAll(&restored);
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
    try testing.expectEqualStrings("  └─ a2 timed out · timed out · step 0", t.entries.items[0].agent_tree.rows.items[1].text);
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
    try testing.expectEqualStrings("  └─ b1 bash sleep 30 · 4s · canceled", t.entries.items[1].agent_tree.rows.items[1].text);
}

test "background failures without output preview the error and keep complete JSON" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    const result = "{\"error\":\"timed out after 4000 ms\"}";
    try t.backgroundResult(gpa, .bash, "b1", false, result);
    try testing.expectEqualStrings("b1 bash · timed out", t.entries.items[0].label.items);
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
    try testing.expectEqualStrings("  └─ a1 first · completed · step 2", t.entries.items[0].agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("  └─ a1 resume · running · step 1", t.entries.items[1].agent_tree.rows.items[0].text);
    try t.progress(gpa, .{ .id = "a1", .run = 1, .prompt = "first", .state = .done, .step = 3 });
    try testing.expectEqualStrings("  └─ a1 first · completed · step 3", t.entries.items[0].agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("  └─ a1 resume · running · step 1", t.entries.items[1].agent_tree.rows.items[0].text);
    try t.progress(gpa, .{ .id = "a1", .run = 2, .prompt = "resume", .state = .done, .step = 4 });
    try testing.expectEqualStrings("  └─ a1 resume · completed · step 4", t.entries.items[1].agent_tree.rows.items[0].text);
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
            try testing.expectEqualStrings("  └─ a1 resume · completed · step 4", t.entries.items[2].agent_tree.rows.items[0].text);
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
    try testing.expectEqualStrings("  └─ a1 resume · running · step 1", t.entries.items[1].agent_tree.rows.items[0].text);
    try t.backgroundResult(gpa, .agent, "a1", true, "{}");
    try testing.expectEqualStrings("  └─ a1 resume · completed · step 1", t.entries.items[1].agent_tree.rows.items[0].text);
    try testing.expectEqualStrings("  └─ a1 first · failed · step 3", t.entries.items[0].agent_tree.rows.items[0].text);
    try t.progress(gpa, .{ .id = "a1", .run = 2, .prompt = "resume", .background = true, .state = .done, .step = 5 });
    try testing.expectEqualStrings("  └─ a1 resume · completed · step 5", t.entries.items[1].agent_tree.rows.items[0].text);
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
    try testing.expectEqualStrings("  └─ a1 resume · running · step 0", t.entries.items[1].agent_tree.rows.items[0].text);
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
            try testing.expectEqualStrings("  └─ a1 second · completed · step 2", t.entries.items[0].agent_tree.rows.items[0].text);
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

pub fn runResultText(gpa: std.mem.Allocator, result: []const u8, changes: []const @import("../tools/diff.zig").Change) ![]u8 {
    var formatted = try ChangeText.init(gpa, changes);
    defer formatted.deinit(gpa);
    if (formatted.summary.len == 0) return gpa.dupe(u8, result);
    return std.fmt.allocPrint(gpa, "{s}\n\n{s}\n{s}", .{ result, formatted.summary, formatted.diff });
}

test "automatic Run and its agent have a mixed task label" {
    var transcript: Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.startRun(testing.allocator, "await tools.agent({prompt:'task'})");
    try transcript.progress(testing.allocator, .{ .id = "a1", .kind = .agent, .prompt = "task" });
    try transcript.progress(testing.allocator, .{ .id = "r1", .kind = .run, .prompt = "Run", .background = true });
    try testing.expectEqualStrings("Run · running", transcript.entries.items[0].label.items);
}

test "background Run notifications and superseded bash stay neutral live and restored" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "await tools.bash({command:'check'})");
    try t.progress(gpa, .{ .id = "b1", .run = 1, .kind = .bash, .prompt = "check", .background = true });
    try t.backgroundRun(gpa, "r3");
    try t.endRun(gpa, true, "registered", 10000, .{});
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("  ", t.entries.items[0].segments(&segs)[0].text);
    try testing.expectEqualStrings("Run · r3 running · b1 running", t.entries.items[0].label.items);
    try t.backgroundResult(gpa, .bash, "b1", true, "{\"superseded_by\":\"b2\"}");
    try testing.expectEqualStrings("b1 superseded by b2", t.entries.items[1].label.items);
    try testing.expectEqualStrings("  ", t.entries.items[1].segments(&segs)[0].text);
    try testing.expect(std.mem.endsWith(u8, t.entries.items[0].agent_tree.rows.items[0].text, "superseded by b2"));
    try t.backgroundResult(gpa, .run, "r3", false, "late error");
    try testing.expectEqual(@as(usize, 2), t.entries.items.len);
    try testing.expectEqualStrings("late error", t.entries.items[0].output.items);
    t.clear(gpa);
    try t.addHistory(gpa, &.{
        .{ .role = "assistant", .tool_calls = &.{.{ .id = "call", .function = .{ .name = "run", .arguments = "{\"code\":\"check\"}" } }} },
        .{ .role = "tool", .tool_call_id = "call", .content = "registered", .background_id = "r3", .bash_replacements = &.{.{ .id = "b1", .run = 1, .state = .superseded, .superseded_by = "b2" }} },
        .{ .role = "user", .content = "[background run r3 finished]\nlate error", .source = .background, .background_kind = .run, .background_id = "r3", .background_ok = false },
    });
    try testing.expectEqualStrings("Run · r3 failed", t.entries.items[0].label.items);
    try testing.expectEqualStrings("✗ ", t.entries.items[0].segments(&segs)[0].text);
    try testing.expect(std.mem.endsWith(u8, t.entries.items[0].agent_tree.rows.items[0].text, "superseded by b2"));
    try testing.expectEqual(@as(usize, 1), t.entries.items.len);
    try testing.expectEqualStrings("late error", t.entries.items[0].output.items);
}

test "elapsed heartbeats do not count as task progress and active tools show commands" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try t.startRun(gpa, "await tools.bash({})");
    var p: Progress = .{ .id = "b1", .run = 1, .kind = .bash, .prompt = "zig build test", .background = true, .elapsed_ms = 3000 };
    try t.progress(gpa, p);
    p.elapsed_ms = 9000;
    try testing.expect(!t.progressChanged(p));
    p.output_bytes = 10;
    try testing.expect(t.progressChanged(p));
    var buf: [256]u8 = undefined;
    p.background = false;
    try t.progress(gpa, p);
    try testing.expectEqualStrings("bash zig build test", t.activityDetail(&buf, "bash"));
}

test "Run facts name changed files and retain warning without changing script success" {
    const a = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(a);
    try t.startRun(a, "ignored source");
    try t.progress(a, .{ .id = "a1", .prompt = "verify", .state = .timed_out });
    const summary: ToolSummary = .{ .counts = &.{ .{ .name = "read", .count = 3 }, .{ .name = "write", .count = 1 }, .{ .name = "edit", .count = 1 }, .{ .name = "bash", .count = 1 } }, .files = &.{.{ .tool = "read", .path = "a.zig" }} };
    try t.endRunWithSummary(a, true, "result", 10, .{ .file_count = 2 }, summary);
    const e = &t.entries.items[0];
    try testing.expectEqual(.ok, e.run);
    try testing.expectEqualStrings("Run · a1 timed out · edit 2 files · bash", e.label.items);
    try testing.expectEqualStrings("read a.zig", e.files.items);
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("! ", e.segments(&segs)[0].text);
    try testing.expectEqual(@as(u8, 3), segs[0].style.fg.index);
}

test "Run detail previews retain complete results and per-file diffs" {
    const a = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(a);
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(a);
    var diff: std.ArrayList(u8) = .empty;
    defer diff.deinit(a);
    for (0..240) |i| {
        try result.print(a, "result {d}\n", .{i});
        try diff.print(a, "+line {d}\n", .{i});
    }
    try t.startRun(a, "secret-script");
    try t.endRun(a, true, result.items, 1, try .init(a, &.{.{ .path = "a", .added = 240, .removed = 0, .diff = diff.items }}));
    const e = &t.entries.items[0];
    try testing.expectEqualStrings(result.items, e.output.items);
    try testing.expectEqualStrings(diff.items, e.changes.files[0].diff);
    try testing.expectEqualStrings("Diff preview · 60 of 241 lines\n", e.changes.preview);
    toggleAll(&t);
    const collapsed = try entryText(a, e, 120);
    defer a.free(collapsed);
    try testing.expect(std.mem.indexOf(u8, collapsed, "result 0") == null);
    try testing.expect(std.mem.indexOf(u8, collapsed, "secret-script") == null);
    try testing.expect(std.mem.indexOf(u8, collapsed, "+line 0") == null);
    e.details.result_open = true;
    e.cached = null;
    const preview = try entryText(a, e, 120);
    defer a.free(preview);
    try testing.expect(std.mem.indexOf(u8, preview, "Preview · first 20 of 240 lines") != null);
    try testing.expect(std.mem.indexOf(u8, preview, "result 19") != null);
    try testing.expect(std.mem.indexOf(u8, preview, "result 20") == null);
    e.details.full_result = true;
    e.details.script_open = true;
    e.changes.files[0].open = true;
    e.cached = null;
    const full = try entryText(a, e, 120);
    defer a.free(full);
    try testing.expect(std.mem.indexOf(u8, full, "result 239") != null);
    try testing.expect(std.mem.indexOf(u8, full, "+line 239") != null);
    try testing.expect(std.mem.indexOf(u8, full, "secret-script") != null);
    var copy = try e.changes.clone(a);
    defer copy.deinit(a);
    try testing.expectEqualStrings(diff.items, copy.files[0].diff);
    try testing.expect(copy.files[0].open.?);
}

test "retry removes only the failed attempt and preserves interjections and prior answers" {
    const a = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(a);
    try t.add(a, .assistant, "previous Step");
    t.beginAttempt();
    try t.appendDelta(a, .text, "failed draft");
    try t.add(a, .user, "interjection");
    t.entries.items[2].queued = 1;
    try t.appendDelta(a, .text, "failed tail");
    t.discardAttempt(a);
    try testing.expectEqual(@as(usize, 2), t.entries.items.len);
    try testing.expectEqualStrings("previous Step", t.entries.items[0].text.items);
    try testing.expectEqualStrings("interjection", t.entries.items[1].text.items);
    t.beginAttempt();
    try t.appendDelta(a, .text, "valid answer");
    try testing.expectEqualStrings("valid answer", t.lastAnswer().?);
    try t.failure(a, "server detail", .model);
    const e = &t.entries.items[3];
    try testing.expect(e.collapsible());
    try testing.expectEqualStrings("The model request failed.", e.label.items);
    try testing.expectEqualStrings("server detail", e.text.items);
}

test "auto-background completion updates its Run and preserves timeout state without another block" {
    const a = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(a);
    try t.startRun(a, "script");
    try t.backgroundRun(a, "r1");
    try t.endRun(a, true, "registered", 500, .{});
    try t.progress(a, .{ .id = "r1", .run = 1, .kind = .run, .prompt = "Run", .background = true, .state = .timed_out });
    try t.backgroundResult(a, .run, "r1", false, "timeout details");
    try testing.expectEqual(@as(usize, 1), t.entries.items.len);
    const e = &t.entries.items[0];
    try testing.expectEqualStrings("Run · r1 timed out", e.label.items);
    try testing.expectEqualStrings("timeout details", e.output.items);
    try testing.expectEqual(@as(usize, 0), e.agent_tree.rows.items.len);
    var segs: [max_segments]vaxis.Segment = undefined;
    try testing.expectEqualStrings("! ", e.segments(&segs)[0].text);
}

test "foreground command facts remain attached after their Run moves to background" {
    const a = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(a);
    try t.startRun(a, "await tools.bash({})");
    try t.backgroundRun(a, "r1");
    try t.endRun(a, true, "registered", 500, .{});
    try t.progress(a, .{ .id = "b1", .run = 1, .kind = .bash, .prompt = "zig build test", .state = .failed, .exit_code = 1 });
    try t.backgroundResult(a, .run, "r1", true, "script returned");
    const e = &t.entries.items[0];
    try testing.expectEqual(@as(usize, 1), e.agents.items.len);
    try testing.expectEqualStrings("  └─ b1 bash zig build test · <1s · failed ✗ exit 1", e.agent_tree.rows.items[0].text);
    try testing.expect(e.hasWarning());
}

test "retry placeholder survives reasoning and replaces draft without losing history anchor" {
    const a = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(a);
    var scroll: @import("viewport.zig").Viewport = .{ .top = .{ .entry = 2, .row = 1 } };
    t.beginAttempt();
    try t.appendDelta(a, .text, "failed draft");
    try t.add(a, .user, "queued");
    try t.appendDelta(a, .text, "tail");
    try t.retryAttempt(a, &scroll);
    try testing.expectEqual(@as(usize, 2), t.entries.items.len);
    try testing.expectEqualStrings("Interrupted · retrying", t.entries.items[0].text.items);
    try testing.expect(t.entries.items[0].retry_placeholder);
    t.beginAttempt();
    try t.appendDelta(a, .reasoning, "hidden");
    try t.retryAttempt(a, &scroll);
    try testing.expectEqual(@as(usize, 2), t.entries.items.len);
    scroll.top = .{ .entry = 1 };
    t.clearRetry(a, &scroll);
    try testing.expectEqual(@as(usize, 0), scroll.top.?.entry);
    try t.appendDelta(a, .text, "answer");
    try testing.expectEqualStrings("answer", t.lastAnswer().?);
    t.clearRetry(a, &scroll);
}

test "display smoothing keeps complete answers and resets at a new attempt" {
    const a = std.testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(a);
    const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    try t.smoothDelta(a, "first", now);
    try std.testing.expectEqualStrings("first", t.entries.items[0].displayText());
    try t.smoothDelta(a, " burst 中文👩‍💻", now);
    try std.testing.expect(t.hasBacklog());
    try std.testing.expectEqualStrings("first burst 中文👩‍💻", t.lastAnswer().?);
    t.flushVisible();
    try std.testing.expect(!t.hasBacklog());
    try std.testing.expectEqualStrings(t.lastAnswer().?, t.entries.items[0].displayText());
    t.beginAttempt();
    try t.smoothDelta(a, "next", now);
    try std.testing.expectEqualStrings("next", t.entries.items[1].displayText());
}

test "latest details entry is the newest Run, background or failure" {
    const gpa = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(gpa);
    try testing.expectEqual(@as(?usize, null), t.latestDetails());
    try t.add(gpa, .assistant, "hi");
    try t.startRun(gpa, "a");
    try t.add(gpa, .assistant, "done");
    try testing.expectEqual(@as(?usize, 1), t.latestDetails());
    try t.failure(gpa, "boom", .tool);
    try testing.expectEqual(@as(?usize, 3), t.latestDetails());
    t.toggle(t.latestDetails().?);
    try testing.expect(t.entries.items[3].open and !t.entries.items[1].open);
}

fn firstRow(gpa: std.mem.Allocator, screen: *vaxis.Screen, width: u16) ![]u8 {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(gpa);
    for (0..width) |x| try row.appendSlice(gpa, screen.readCell(@intCast(x), 0).?.char.grapheme);
    return row.toOwnedSlice(gpa);
}

test "Simple collapsed Run shows path facts on its title row" {
    const gpa = testing.allocator;
    const Case = struct { files: []const @import("../session/tool_summary.zig").File, counts: []const @import("../session/tool_summary.zig").Count, changed: usize, simple: []const u8, normal: []const u8 };
    const cases = [_]Case{
        .{ .files = &.{.{ .tool = "glob", .path = "**/*.md" }}, .counts = &.{.{ .name = "glob", .count = 1 }}, .changed = 0, .simple = "  Run · glob **/*.md", .normal = "  Run" },
        .{
            .files = &.{ .{ .tool = "read", .path = "src/a.zig" }, .{ .tool = "read", .path = "src/b.zig" } },
            .counts = &.{ .{ .name = "read", .count = 2 }, .{ .name = "edit", .count = 1 } },
            .changed = 1,
            .simple = "  Run · read src/a.zig · read src/b.zig · edit 1 file",
            .normal = "  Run · edit 1 file",
        },
    };
    for (cases) |c| for ([_]bool{ true, false }) |simple| {
        var screen = try vaxis.Screen.init(gpa, .{ .cols = 60, .rows = 4, .x_pixel = 0, .y_pixel = 0 });
        defer screen.deinit(gpa);
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 60, .height = 4, .screen = &screen };
        var t: Transcript = .{};
        defer t.deinit(gpa);
        try t.startRun(gpa, "await tools.read({})");
        const changes = [_]Change{.{ .path = "a", .added = 1, .removed = 0, .diff = "+x\n" }};
        try t.endRunWithSummary(gpa, true, "", 10, try .init(gpa, if (c.changed > 0) &changes else &.{}), .{ .counts = c.counts, .files = c.files });
        const e = &t.entries.items[0];
        e.simple = simple;
        if (simple) try testing.expectEqual(@as(u16, 1), e.print(win, true));
        if (!simple) _ = e.print(win, true);
        const row = try firstRow(gpa, &screen, 60);
        defer gpa.free(row);
        const expected = if (simple) c.simple else c.normal;
        try testing.expectEqualStrings(expected, std.mem.trimEnd(u8, row, " "));
    };
}

fn entryText(a: std.mem.Allocator, e: *Entry, width: u16) ![]u8 {
    var screen = try vaxis.Screen.init(a, .{ .cols = width, .rows = 1024, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(a);
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 1024, .screen = &screen };
    const rows = e.print(win, true);
    try testing.expectEqual(rows, e.height(win));
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    for (0..@min(rows, 1024)) |y| {
        for (0..width) |x| {
            const cell = screen.readCell(@intCast(x), @intCast(y)).?;
            try text.appendSlice(a, if (cell.char.grapheme.len == 0) " " else cell.char.grapheme);
        }
        try text.append(a, '\n');
    }
    return text.toOwnedSlice(a);
}

test "Run detail controls preserve siblings and mode state at narrow and wide widths" {
    const a = testing.allocator;
    for ([_]u16{ 60, 120, 160 }) |width| {
        var screen: vaxis.Screen = .{};
        const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 40, .screen = &screen };
        var t: Transcript = .{};
        defer t.deinit(a);
        try t.startRun(a, "hidden-script");
        try t.endRun(a, true, "output-body", 1, try .init(a, &.{
            .{ .path = "src/a-long-path-with-界-symbols-and-enough-text-to-wrap-at-sixty-columns.zig", .added = 1, .removed = 0, .diff = "+first-body\n" },
            .{ .path = "b.zig", .added = 1, .removed = 0, .diff = "+second-body\n" },
        }));
        const e = &t.entries.items[0];
        e.open = true;
        const file_hit = e.control(win, 3).?;
        try testing.expectEqual(@as(usize, 0), file_hit.action.?.file);
        if (width == 60) {
            try testing.expect(file_hit.rows > 1);
            try testing.expectEqual(@as(usize, 0), e.control(win, 4).?.action.?.file);
        }
        e.toggleControl(file_hit);
        try testing.expect(e.open and e.changes.files[0].open.?);
        try testing.expect(e.changes.files[1].open == null);
        try testing.expect(!e.details.script_open);
        var script_hit: ?Entry.Control = null;
        for (0..e.height(win)) |row| {
            if (e.control(win, @intCast(row))) |hit| {
                if (hit.action) |action| if (action == .script) {
                    script_hit = hit;
                    break;
                };
            }
        }
        e.toggleControl(script_hit.?);
        const normal = try entryText(a, e, width);
        defer a.free(normal);
        try testing.expect(std.mem.indexOf(u8, normal, "hidden-script") != null);
        try testing.expect(std.mem.indexOf(u8, normal, "output-body") == null);
        try testing.expect(std.mem.indexOf(u8, normal, "+first-body") != null);
        try testing.expect(std.mem.indexOf(u8, normal, "+second-body") == null);
        e.simple = true;
        const simple = try entryText(a, e, width);
        defer a.free(simple);
        try testing.expectEqualStrings(normal, simple);
        e.simple = false;
        e.toggleControl(e.control(win, 0).?);
        try testing.expect(!e.open);
        e.toggleControl(e.control(win, 0).?);
        try testing.expect(e.details.script_open and e.changes.files[0].open.?);
        const restored = try entryText(a, e, width);
        defer a.free(restored);
        try testing.expectEqualStrings(normal, restored);
    }
}

test "read-only Runs omit Changes and failed edits expose output without exposing Script" {
    const a = testing.allocator;
    var t: Transcript = .{};
    defer t.deinit(a);
    try t.startRun(a, "private-script");
    try t.endRun(a, true, "read-result", 1, .{});
    const e = &t.entries.items[0];
    e.open = true;
    const read_view = try entryText(a, e, 60);
    defer a.free(read_view);
    try testing.expect(std.mem.indexOf(u8, read_view, "Changes") == null);
    try testing.expect(std.mem.indexOf(u8, read_view, "read-result") != null);
    try testing.expect(std.mem.indexOf(u8, read_view, "private-script") == null);
    e.changes = try .init(a, &.{.{ .path = "a", .added = 1, .removed = 0, .diff = "+small-diff\n" }});
    e.run = .failed;
    e.cached = null;
    const failed = try entryText(a, e, 60);
    defer a.free(failed);
    try testing.expect(std.mem.indexOf(u8, failed, "+small-diff") != null);
    try testing.expect(std.mem.indexOf(u8, failed, "read-result") != null);
    try testing.expect(std.mem.indexOf(u8, failed, "private-script") == null);
}
