const std = @import("std");
const sandbox = @import("../sandbox.zig");
const atomic_file = @import("../tools/atomic_file.zig");

pub const max_bytes = 16 * 1024;
pub const max_saved_bytes = 16 * 1024 * 1024;

pub const Save = struct {
    io: std.Io,
    dir: []const u8,
    write: bool = true,
};

test "configured display budget leaves JS data intact" {
    const t = std.testing;
    const text = try t.allocator.alloc(u8, 24 * 1024);
    defer t.allocator.free(text);
    @memset(text, 'x');
    const outcome: sandbox.Outcome = .{ .ok = true, .text = text, .logs = @constCast("") };
    const small = try format(t.allocator, outcome, max_bytes);
    defer t.allocator.free(small);
    const large = try format(t.allocator, outcome, 32 * 1024);
    defer t.allocator.free(large);
    try t.expect(small.len <= max_bytes);
    try t.expect(std.mem.indexOf(u8, small, "bytes omitted") != null);
    try t.expectEqualStrings(text, large["result: ".len..]);
    try t.expectEqual(@as(usize, 24 * 1024), outcome.text.len);
    const message = try formatMessage(t.allocator, "[background bash b1 finished]\n", text, 32 * 1024);
    defer t.allocator.free(message);
    try t.expect(std.mem.endsWith(u8, message, text));
}

const Entry = struct {
    first: usize,
    last: usize,
    kind: enum { console, result, @"error" },
    text: []const u8,
    bytes: usize,
    tail: []const u8 = "",
    keep: ?usize = null,

    fn heading(e: Entry, w: *std.Io.Writer, total: usize) !void {
        if (e.first == e.last) {
            try w.print("[entry {d} of {d} ({s})]\n", .{ e.first, total, @tagName(e.kind) });
        } else {
            try w.print("[entries {d}-{d} of {d} ({s})]\n", .{ e.first, e.last, total, @tagName(e.kind) });
        }
    }

    fn omitted(e: Entry, w: *std.Io.Writer, bytes: usize, lines: ?[2]usize) !void {
        try w.print("[{d} of {d} bytes omitted", .{ bytes, e.bytes });
        if (lines) |l| try w.print(" · lines {d}–{d}", .{ l[0], l[1] });
        try w.writeAll("]\n");
    }
};

fn separatorsWithin(text: []const u8, limit: usize, escaped: bool) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const escape = escaped and text[i] == '\\';
        const end = i + @as(usize, if (escape) 2 else 1);
        if (end > limit) break;
        if (escaped) {
            if (escape and end <= text.len and text[i + 1] == 'n') count += 1;
        } else if (text[i] == '\n') count += 1;
        i = end;
    }
    return count;
}

// Lines of the first and last omitted byte of text[cut_start..cut_end), or null when
// both are on one line or the line structure is unknown. Text without real newlines
// (ignoring a final one) that starts like JSON (`{`, `[`, `"`) is console.log'ed or returned data whose
// newlines are `\n` escapes (`\\n` is an escaped backslash then `n`); any other text
// separates lines by real newlines. A partly shown line counts as omitted.
fn omittedLines(text: []const u8, cut_start: usize, cut_end: usize) ?[2]usize {
    if (cut_end <= cut_start or cut_end > text.len) return null;
    const escaped = text.len > 0 and std.mem.indexOfScalar(u8, "{[\"", text[0]) != null and std.mem.indexOfScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n') == null;
    const first = 1 + separatorsWithin(text, cut_start, escaped);
    const last = 1 + separatorsWithin(text, cut_end - 1, escaped);
    return if (last > first) .{ first, last } else null;
}

pub fn format(gpa: std.mem.Allocator, o: sandbox.Outcome, limit: usize) ![]u8 {
    return formatSaved(gpa, o, limit, null);
}

pub fn formatSaved(gpa: std.mem.Allocator, o: sandbox.Outcome, limit: usize, save: ?Save) ![]u8 {
    if (o.hook.len > 0) {
        var original = o;
        original.hook = "";
        const body = try formatSaved(gpa, original, limit / 2, save);
        defer gpa.free(body);
        const payload = try renderSaved(gpa, .{ .ok = true, .text = @constCast(o.hook), .logs = @constCast("") }, limit - body.len - 1, save);
        defer gpa.free(payload);
        return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ body, payload });
    }
    const suffix: ?[]const u8 = if (o.stopped.len > 0) o.stopped else if (!o.ok) "[Run script failed. Correct the script and continue the task; this error is not a reason to end the Turn.]" else null;
    if (suffix) |s| {
        const body = try renderSaved(gpa, o, limit - s.len - 1, save);
        defer gpa.free(body);
        return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ body, s });
    }
    return renderSaved(gpa, o, limit, save);
}

pub fn stepLimitOutput(a: std.mem.Allocator, output: []const u8, remaining_steps: ?usize) ![]const u8 {
    const remaining = remaining_steps orelse return output;
    if (remaining > 3) return output;
    return std.fmt.allocPrint(a, "{s}\n[{d} Steps left in this Turn]", .{ output, remaining });
}

pub fn formatMessage(gpa: std.mem.Allocator, prefix: []const u8, json: []const u8, limit: usize) ![]u8 {
    return formatMessageSaved(gpa, prefix, json, limit, null, null);
}

pub fn formatMessageSaved(gpa: std.mem.Allocator, prefix: []const u8, json: []const u8, limit: usize, save: ?Save, raw_full: ?[]const u8) ![]u8 {
    const budget = limit - prefix.len;
    if (json.len <= budget) return std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, json });
    const footer: ?[]u8 = if (save) |target| blk: {
        const full = raw_full orelse json;
        const partial = full.len > max_saved_bytes;
        const slice = if (partial) trimEnd(full[0..max_saved_bytes]) else full;
        break :blk saveBytes(gpa, target, slice, partial) catch null;
    } else null;
    defer if (footer) |f| gpa.free(f);
    if (footer) |f| if (f.len + 2 < budget / 2) {
        const payload = try renderLimit(gpa, .{ .ok = false, .text = @constCast(json), .logs = @constCast("") }, budget - f.len - 2);
        defer gpa.free(payload);
        const nl: []const u8 = if (payload.len > 0 and payload[payload.len - 1] == '\n') "" else "\n";
        return std.fmt.allocPrint(gpa, "{s}{s}{s}{s}\n", .{ prefix, payload, nl, f });
    };
    const payload = try renderLimit(gpa, .{ .ok = false, .text = @constCast(json), .logs = @constCast("") }, budget);
    defer gpa.free(payload);
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, payload });
}

fn renderSaved(gpa: std.mem.Allocator, o: sandbox.Outcome, limit: usize, save: ?Save) ![]u8 {
    const logs = std.mem.trimEnd(u8, o.logs, "\n");
    const value: []const u8 = if (o.ok and std.mem.eql(u8, o.text, "undefined")) "" else o.text;
    const sep: []const u8 = if (logs.len > 0 and value.len > 0) "\n" else "";
    const label: []const u8 = if (o.ok and value.len > 0) "result: " else "";
    if (!o.log_truncated and logs.len + value.len + sep.len + label.len <= limit) {
        if (logs.len == 0 and value.len == 0) return gpa.dupe(u8, "(no output)");
        return std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{ logs, sep, label, value });
    }
    const footer: ?[]u8 = if (save) |target| saveOutcome(gpa, o, target) catch null else null;
    defer if (footer) |f| gpa.free(f);
    if (footer) |f| if (f.len + 2 < limit / 2) {
        const body = try renderLimit(gpa, o, limit - f.len - 2);
        defer gpa.free(body);
        const nl: []const u8 = if (body.len > 0 and body[body.len - 1] == '\n') "" else "\n";
        return std.fmt.allocPrint(gpa, "{s}{s}{s}\n", .{ body, nl, f });
    };
    return renderLimit(gpa, o, limit);
}

fn saveOutcome(gpa: std.mem.Allocator, o: sandbox.Outcome, target: Save) !?[]u8 {
    const raw_logs: []const u8 = if (o.full_logs.len > 0) o.full_logs else if (!o.log_truncated) o.logs else return null;
    const logs = std.mem.trimEnd(u8, raw_logs, "\n");
    const value: []const u8 = if (o.ok and std.mem.eql(u8, o.text, "undefined")) "" else o.text;
    const sep: []const u8 = if (logs.len > 0 and value.len > 0) "\n" else "";
    const label: []const u8 = if (o.ok and value.len > 0) "result: " else "";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var partial = o.full_logs_truncated;
    for ([_][]const u8{ logs, sep, label, value }) |part| {
        if (part.len == 0) continue;
        const rem = max_saved_bytes -| out.items.len;
        if (part.len <= rem) {
            try out.appendSlice(gpa, part);
        } else {
            try out.appendSlice(gpa, part[0..rem]);
            out.items.len = trimEnd(out.items).len;
            partial = true;
            break;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n' and out.items.len < max_saved_bytes) {
        try out.append(gpa, '\n');
    }
    return try saveBytes(gpa, target, out.items, partial);
}

fn saveBytes(gpa: std.mem.Allocator, target: Save, data: []const u8, partial: bool) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const file = try std.fmt.allocPrint(gpa, "{s}.txt", .{std.fmt.bytesToHex(digest[0..16].*, .lower)});
    defer gpa.free(file);
    const path = try std.fs.path.join(gpa, &.{ target.dir, file });
    defer gpa.free(path);
    if (target.write) {
        const cwd = std.Io.Dir.cwd();
        cwd.createDir(target.io, target.dir, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.FileNotFound => try cwd.createDirPath(target.io, target.dir),
            else => return err,
        };
        const present = if (cwd.statFile(target.io, path, .{})) |stat| stat.size == data.len else |_| false;
        if (!present) _ = try atomic_file.replace(target.io, gpa, path, data, .{ .permissions = .fromMode(0o600), .sync = false });
    }
    return if (partial)
        std.fmt.allocPrint(gpa, "[full output (first 16 MiB): {s}]", .{path})
    else
        std.fmt.allocPrint(gpa, "[full output: {s}]", .{path});
}

fn renderLimit(gpa: std.mem.Allocator, o: sandbox.Outcome, limit: usize) ![]u8 {
    const logs = std.mem.trimEnd(u8, o.logs, "\n");
    const value: []const u8 = if (o.ok and std.mem.eql(u8, o.text, "undefined")) "" else o.text;
    const sep: []const u8 = if (logs.len > 0 and value.len > 0) "\n" else "";
    const label: []const u8 = if (o.ok and value.len > 0) "result: " else "";
    if (!o.log_truncated and logs.len + value.len + sep.len + label.len <= limit) {
        if (logs.len == 0 and value.len == 0) return gpa.dupe(u8, "(no output)");
        return std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{ logs, sep, label, value });
    }

    var storage: [sandbox.max_log_entries + 2]Entry = undefined;
    var count: usize = 0;
    var total: usize = 0;
    const tail_bytes = if (o.log_entries.len > 0) o.logs.len - o.log_tail_start else 0;
    const tail_offset = o.log_bytes - tail_bytes;
    for (o.log_entries) |log| {
        const head = o.logs[@min(log.start, o.log_head_bytes)..@min(log.end, o.log_head_bytes)];
        const tail = o.logs[o.log_tail_start + (log.start -| tail_offset) .. o.log_tail_start + (log.end -| tail_offset)];
        const bytes = log.end - log.start;
        storage[count] = .{
            .first = log.first,
            .last = log.last,
            .kind = .console,
            .text = if (tail.len == bytes) tail else head,
            .tail = if (tail.len == bytes) "" else tail,
            .bytes = bytes,
        };
        total = log.last;
        count += 1;
    }
    if (count == 0 and logs.len > 0) {
        total = 1;
        storage[count] = .{ .first = 1, .last = 1, .kind = .console, .text = logs, .bytes = logs.len };
        count += 1;
    }
    if (value.len > 0) {
        total += 1;
        storage[count] = .{ .first = total, .last = total, .kind = if (o.ok) .result else .@"error", .text = value, .bytes = value.len };
        count += 1;
    }
    const entries = storage[0..count];

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var available: usize = limit;
    for (entries) |e| {
        const before = out.written().len;
        try e.heading(&out.writer, total);
        try e.omitted(&out.writer, e.bytes, .{ e.bytes + 1, e.bytes + 1 });
        available -= out.written().len - before + 2;
    }
    out.clearRetainingCapacity();

    var remaining = entries.len;
    while (remaining > 0) {
        const share = available / remaining;
        var progress = false;
        for (entries) |*e| {
            if (e.keep == null and e.text.len + e.tail.len <= share) {
                e.keep = e.text.len + e.tail.len;
                available -= e.text.len + e.tail.len;
                remaining -= 1;
                progress = true;
            }
        }
        if (!progress) {
            for (entries) |*e| if (e.keep == null) {
                e.keep = share;
            };
            break;
        }
    }

    for (entries) |e| {
        try e.heading(&out.writer, total);
        const keep = e.keep.?;
        if (keep == e.bytes) {
            try out.writer.writeAll(e.text);
            try out.writer.writeAll(e.tail);
        } else {
            const complete = e.text.len == e.bytes;
            const head_keep = if (complete) (keep + 1) / 2 else @min(e.text.len, keep - @min(e.tail.len, keep / 2));
            const tail_keep = if (complete) keep / 2 else @min(e.tail.len, keep - head_keep);
            const head = trimEnd(e.text[0..head_keep]);
            const suffix = if (complete) e.text else e.tail;
            const tail = trimStart(suffix[suffix.len - tail_keep ..]);
            try out.writer.writeAll(head);
            if (head.len > 0 and head[head.len - 1] != '\n') try out.writer.writeByte('\n');
            const lines = if (complete) omittedLines(e.text, head.len, e.bytes - tail.len) else null;
            try e.omitted(&out.writer, e.bytes - head.len - tail.len, lines);
            try out.writer.writeAll(tail);
        }
        if (out.written().len > 0 and out.written()[out.written().len - 1] != '\n') try out.writer.writeByte('\n');
    }
    std.debug.assert(out.written().len <= limit);
    return out.toOwnedSlice();
}

const trimEnd = @import("../sandbox/console.zig").trimEnd;
const trimStart = @import("../sandbox/console.zig").trimStart;

const testing = std.testing;

fn evaluate(code: []const u8, limits: sandbox.Limits) !sandbox.Outcome {
    return sandbox.eval(testing.allocator, testing.io, code, limits, null, null);
}

test "three console entries retain labels and exact omission bytes" {
    const o = try evaluate("console.log('first'); console.log('middle:' + 'z'.repeat(40000) + ':middle-end'); console.log('last');", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o, max_bytes);
    defer testing.allocator.free(out);
    try testing.expect(out.len <= max_bytes);
    try testing.expectEqual(@as(usize, 3), o.log_entries.len);
    try testing.expect(std.mem.startsWith(u8, out, "[entry 1 of 3 (console)]\nfirst\n"));
    try testing.expect(std.mem.indexOf(u8, out, "[entry 2 of 3 (console)]\nmiddle:") != null);
    try testing.expect(std.mem.endsWith(u8, out, ":middle-end\n[entry 3 of 3 (console)]\nlast\n"));
    const shown = std.mem.count(u8, out, "z") + "middle::middle-end\n".len;
    const marker = try std.fmt.allocPrint(testing.allocator, "[{d} of {d} bytes omitted]", .{ (o.log_entries[1].end - o.log_entries[1].start) - shown, (o.log_entries[1].end - o.log_entries[1].start) });
    defer testing.allocator.free(marker);
    try testing.expect(std.mem.indexOf(u8, out, marker) != null);
}

test "console capture limit preserves later entries and exact omission counts" {
    const o = try evaluate("console.log('first'); console.log('middle:' + 'z'.repeat(90000)); console.log('last');", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o, max_bytes);
    defer testing.allocator.free(out);
    try testing.expect(out.len <= max_bytes);
    try testing.expect(o.log_truncated);
    try testing.expectEqual(@as(usize, 90008), (o.log_entries[1].end - o.log_entries[1].start));
    const shown = std.mem.count(u8, out, "z") + "middle:\n".len;
    const marker = try std.fmt.allocPrint(testing.allocator, "[{d} of 90008 bytes omitted]", .{90008 - shown});
    defer testing.allocator.free(marker);
    try testing.expect(std.mem.indexOf(u8, out, marker) != null);
    try testing.expect(std.mem.endsWith(u8, out, "[entry 3 of 3 (console)]\nlast\n"));
    try testing.expect(std.mem.indexOf(u8, out, "[console output truncated]") == null);
}

test "many console entries have bounded metadata and a numbered omission range" {
    const o = try evaluate("for (let i = 0; i < 10000; i++) console.log('x');", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o, max_bytes);
    defer testing.allocator.free(out);
    try testing.expect(out.len <= max_bytes);
    try testing.expectEqual(sandbox.max_log_entries + 1, o.log_entries.len);
    try testing.expect(std.mem.indexOf(u8, out, "[entries 33-9968 of 10000 (console)]") != null);
    try testing.expect(std.mem.endsWith(u8, out, "[entry 10000 of 10000 (console)]\nx\n"));
}

test "small outputs remain unchanged even with more than 64 console calls" {
    const o = try evaluate("for (let i = 0; i < 100; i++) console.log('x');", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o, max_bytes);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(std.mem.trimEnd(u8, o.logs, "\n"), out);
}

test "UTF-8 cuts count all omitted bytes including capture loss" {
    for ([_]usize{ 65536, 16385, 1, 0 }) |capture| {
        const o = try evaluate("console.log('你'.repeat(30000));", .{ .max_log_bytes = capture });
        defer o.deinit(testing.allocator);
        const out = try format(testing.allocator, o, max_bytes);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
        const shown = std.mem.count(u8, out, "你") * 3 + @intFromBool(capture >= 2);
        const marker = try std.fmt.allocPrint(testing.allocator, "[{d} of 90001 bytes omitted", .{90001 - shown});
        defer testing.allocator.free(marker);
        try testing.expect(std.mem.indexOf(u8, out, marker) != null);
    }
}

test "completion and errors have their own entry and cannot be crowded out by logs" {
    const codes = [_][]const u8{
        "console.log('z'.repeat(40000)); 'result-' + 'y'.repeat(40000) + '-end'",
        "console.log('z'.repeat(90000)); throw new Error('failure-marker');",
        "'result-' + 'y'.repeat(40000) + '-end'",
        "throw new Error('failure-' + 'y'.repeat(40000));",
    };
    for (codes, 0..) |code, i| {
        const o = try evaluate(code, .{});
        defer o.deinit(testing.allocator);
        const out = try format(testing.allocator, o, max_bytes);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.mem.indexOf(u8, out, if (o.ok) "(result)" else "(error)") != null);
        try testing.expect(std.mem.indexOf(u8, out, if (o.ok) "result-" else "failure-") != null);
        if (i == 1) try testing.expect(std.mem.indexOf(u8, out, "Error: failure-marker") != null);
        if (o.ok) try testing.expect(std.mem.indexOf(u8, out, "-end\"") != null);
    }
}

test "UTF-8 cut points" {
    try testing.expectEqualStrings("ab", trimEnd("ab\xe4\xbd"));
    try testing.expectEqualStrings("ab你", trimEnd("ab你"));
    try testing.expectEqualStrings("cd", trimStart("\xbd\xa0cd"));
    try testing.expectEqualStrings("", trimEnd("\xbd\xa0"));
}

test "exact output budget boundaries for console and completion" {
    inline for (.{ "console.log('z'.repeat({d}));", "'z'.repeat({d});" }, 0..) |pattern, kind| {
        for ([_]usize{ max_bytes - 1, max_bytes, max_bytes + 1 }) |size| {
            const n = if (kind == 0) size else size - "result: \"\"".len;
            const source = try std.fmt.allocPrint(testing.allocator, pattern, .{n});
            defer testing.allocator.free(source);
            const o = try evaluate(source, .{});
            defer o.deinit(testing.allocator);
            const out = try format(testing.allocator, o, max_bytes);
            defer testing.allocator.free(out);
            try testing.expect(out.len <= max_bytes);
            if (size <= max_bytes) {
                try testing.expectEqual(size, out.len);
                try testing.expect(std.mem.indexOf(u8, out, "bytes omitted") == null);
            } else {
                try testing.expect(std.mem.indexOf(u8, out, "bytes omitted") != null);
            }
        }
    }
}

test "four-byte UTF-8 capture boundaries" {
    for (0..8) |capture| {
        const o = try evaluate("console.log('😀'.repeat(30000));", .{ .max_log_bytes = capture });
        defer o.deinit(testing.allocator);
        const out = try format(testing.allocator, o, max_bytes);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
        const shown = std.mem.count(u8, out, "😀") * 4 + @intFromBool(capture >= 2);
        const marker = try std.fmt.allocPrint(testing.allocator, "[{d} of 120001 bytes omitted", .{120001 - shown});
        defer testing.allocator.free(marker);
        try testing.expect(std.mem.indexOf(u8, out, marker) != null);
    }
}

test "console entry boundaries are calls rather than arguments or lines" {
    const o = try evaluate("console.log('left', {n: 1}, 'a\\nb'); console.warn('z'.repeat(40000)); console.error('right');", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o, max_bytes);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "[entry 1 of 3 (console)]\nleft {\"n\":1} a\nb\n[entry 2 of 3 (console)]\n"));
    try testing.expect(std.mem.endsWith(u8, out, "[entry 3 of 3 (console)]\nright\n"));
}

test "oversized single call and cumulative calls preserve real head and tail" {
    const codes = [_][]const u8{
        "console.log('BEGIN-' + '你😀'.repeat(30000) + '-FINAL-SENTINEL');",
        "console.log('BEGIN-'); for (let i = 0; i < 10000; i++) console.log('你😀'.repeat(10)); console.log('-FINAL-SENTINEL');",
    };
    for (codes) |code| {
        const o = try evaluate(code, .{});
        defer o.deinit(testing.allocator);
        try testing.expect(o.log_truncated);
        try testing.expect(std.unicode.utf8ValidateSlice(o.logs));
        try testing.expect(std.mem.startsWith(u8, o.logs, "BEGIN-"));
        try testing.expect(std.mem.endsWith(u8, o.logs, "-FINAL-SENTINEL\n"));
        try testing.expect(o.log_head_bytes + o.logs.len - o.log_tail_start <= 65536);
        try testing.expect(o.log_entries.len <= sandbox.max_log_entries + 1);
        const out = try format(testing.allocator, o, max_bytes);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
        try testing.expect(std.mem.indexOf(u8, out, "BEGIN-") != null);
        try testing.expect(std.mem.indexOf(u8, out, "bytes omitted]") != null);
        try testing.expect(std.mem.endsWith(u8, out, "-FINAL-SENTINEL\n"));
    }
}

test "bounded call metadata plus completion preserves original numbering" {
    for ([_]usize{ 64, 65, 66 }) |calls| {
        const code = try std.fmt.allocPrint(testing.allocator, "for (let i = 0; i < {d}; i++) console.log('call-' + i + ':' + '😀'.repeat(600 + i)); 'RESULT-SENTINEL'", .{calls});
        defer testing.allocator.free(code);
        const o = try evaluate(code, .{});
        defer o.deinit(testing.allocator);
        const out = try format(testing.allocator, o, max_bytes);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
        try testing.expect(std.mem.indexOf(u8, out, "call-0:") != null);
        const last = try std.fmt.allocPrint(testing.allocator, "call-{d}:", .{calls - 1});
        defer testing.allocator.free(last);
        try testing.expect(std.mem.indexOf(u8, out, last) != null);
        const result = try std.fmt.allocPrint(testing.allocator, "[entry {d} of {d} (result)]\n\"RESULT-SENTINEL\"\n", .{ calls + 1, calls + 1 });
        defer testing.allocator.free(result);
        try testing.expect(std.mem.endsWith(u8, out, result));
    }
}

test "stopped line follows small output without changing the body" {
    const stopped = "[stopped before completion: bash #0, agent #2]";
    const cases = .{
        .{ "", "(no output)" },
        .{ "console.log('hello');", "hello" },
        .{ "console.log('hello'); 42", "hello\nresult: 42" },
        .{ "throw 'failure'", "failure" },
    };
    inline for (cases) |case| {
        const original = try evaluate(case[0], .{});
        defer original.deinit(testing.allocator);
        var o = original;
        o.stopped = stopped;
        const out = try format(testing.allocator, o, max_bytes);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(case[1] ++ "\n" ++ stopped, out);
    }
}

test "stopped line reserves budget at exact body boundaries" {
    const stopped = "[stopped before completion: bash #0, agent #2]";
    const budget = max_bytes - stopped.len - 1;
    for ([_]usize{ budget - 1, budget, budget + 1 }) |size| {
        const logs = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(logs);
        @memset(logs, 'x');
        const out = try format(testing.allocator, .{
            .ok = true,
            .text = @constCast("undefined"),
            .logs = logs,
            .stopped = stopped,
        }, max_bytes);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.mem.endsWith(u8, out, "\n" ++ stopped));
        if (size <= budget) {
            try testing.expectEqual(size + 1 + stopped.len, out.len);
            try testing.expectEqualStrings(logs, out[0..size]);
        } else {
            try testing.expect(std.mem.indexOf(u8, out, "bytes omitted") != null);
        }
    }
}

test "maximum stopped line survives huge console errors and many entries" {
    var stopped: [sandbox.max_stopped_bytes]u8 = undefined;
    @memset(&stopped, 'x');
    const prefix = "[stopped before completion: ";
    const suffix = ", ..., 9000 more]";
    @memcpy(stopped[0..prefix.len], prefix);
    @memcpy(stopped[stopped.len - suffix.len ..], suffix);
    const codes = [_][]const u8{
        "console.log('你😀'.repeat(30000));",
        "throw new Error('failure-' + '你😀'.repeat(30000));",
        "for (let i = 0; i < 10000; i++) console.log('你😀'.repeat(10)); throw new Error('failure-' + '你😀'.repeat(30000));",
    };
    for (codes) |code| {
        const original = try evaluate(code, .{});
        defer original.deinit(testing.allocator);
        var o = original;
        o.stopped = &stopped;
        const out = try format(testing.allocator, o, max_bytes);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
        try testing.expect(std.mem.endsWith(u8, out, &stopped));
        try testing.expectEqual(@as(u8, '\n'), out[out.len - stopped.len - 1]);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
        try testing.expect(std.mem.indexOf(u8, out, "bytes omitted") != null);
        try testing.expect(std.mem.indexOf(u8, out, if (o.ok) "(console)" else "(error)") != null);
    }
}

test "Step budget metadata leaves unlimited output unchanged and appends after the output budget" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("output", try stepLimitOutput(a, "output", null));
    try t.expectEqualStrings("output", try stepLimitOutput(a, "output", 4));
    try t.expectEqualStrings("output\n[3 Steps left in this Turn]", try stepLimitOutput(a, "output", 3));
    try t.expectEqualStrings("output\n[0 Steps left in this Turn]", try stepLimitOutput(a, "output", 0));
    const full = try a.alloc(u8, 16 * 1024);
    @memset(full, 'x');
    const output = try stepLimitOutput(a, full, 2);
    try t.expectEqualStrings(full, output[0..full.len]);
    try t.expectEqualStrings("\n[2 Steps left in this Turn]", output[full.len..]);
}

test "formatOutcome" {
    const gpa = std.testing.allocator;
    var logs = "a\nb\n".*;
    var text = "1".*;
    const ok = try format(gpa, .{ .ok = true, .text = &text, .logs = &logs }, max_bytes);
    defer gpa.free(ok);
    try std.testing.expectEqualStrings("a\nb\nresult: 1", ok);
    var err = "Error: x".*;
    var none = "".*;
    const bad = try format(gpa, .{ .ok = false, .text = &err, .logs = &none }, max_bytes);
    defer gpa.free(bad);
    try std.testing.expect(std.mem.startsWith(u8, bad, "Error: x\n"));
    try std.testing.expect(std.mem.indexOf(u8, bad, "Correct the script and continue the task") != null);
    var undef = "undefined".*;
    const logged = try format(gpa, .{ .ok = true, .text = &undef, .logs = &logs }, max_bytes);
    defer gpa.free(logged);
    try std.testing.expectEqualStrings("a\nb", logged);
    const silent = try format(gpa, .{ .ok = true, .text = &undef, .logs = &none }, max_bytes);
    defer gpa.free(silent);
    try std.testing.expectEqualStrings("(no output)", silent);
}

fn expectMarker(out: []const u8, lines: ?[]const u8) !void {
    const at = std.mem.indexOf(u8, out, " bytes omitted") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfScalarPos(u8, out, at, ']').?;
    const tail = out[at..end];
    if (lines) |want| {
        try testing.expect(std.mem.indexOf(u8, tail, want) != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, tail, "lines") == null);
    }
}

test "omittedLines counts real and escaped newlines" {
    try testing.expectEqual(@as(?[2]usize, .{ 2, 3 }), omittedLines("a\nbb\ncc\nd", 3, 7));
    try testing.expectEqual(@as(?[2]usize, .{ 2, 3 }), omittedLines("\"a\\nbb\\ncc\\nd\"", 5, 12));
    try testing.expectEqual(@as(?[2]usize, null), omittedLines("\"a\\\\nbbbbb\"", 3, 8));
    try testing.expectEqual(@as(?[2]usize, null), omittedLines("a\\nb\\nc\\nd", 2, 8));
    try testing.expectEqual(@as(?[2]usize, null), omittedLines("abc\ndef", 4, 6));
    try testing.expectEqual(@as(?[2]usize, .{ 1, 2 }), omittedLines("abc\ndef", 1, 5));
    try testing.expectEqual(@as(?[2]usize, .{ 2, 3 }), omittedLines("a\nb\nc", 2, 5));
}

test "marker names omitted lines of a logged read object" {
    const o = try evaluate("let t = ''; for (let i = 1; i <= 3000; i++) t += 'line ' + i + '\\n'; console.log({ text: t, next_offset: 3001 });", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o, max_bytes);
    defer testing.allocator.free(out);
    try testing.expect(out.len <= max_bytes);
    const at = std.mem.indexOf(u8, out, "lines ").?;
    const dash = std.mem.indexOfPos(u8, out, at, "–").?;
    const a = try std.fmt.parseInt(usize, out[at + 6 .. dash], 10);
    const close = std.mem.indexOfScalarPos(u8, out, dash, ']').?;
    const b = try std.fmt.parseInt(usize, out[dash + "–".len .. close], 10);
    try testing.expect(a > 1 and b < 3000 and a < b);
    // Entry line n is file line n: every line outside a..b is shown whole.
    const shown_lines = std.mem.count(u8, out, "line ");
    try testing.expectEqual(@as(usize, 3000 - (b - a + 1)), shown_lines);
}

test "marker names omitted lines of raw text and ignores escaped backslash before n" {
    const raw = try evaluate("let t = ''; for (let i = 1; i <= 3000; i++) t += 'line ' + i + '\\n'; console.log(t);", .{});
    defer raw.deinit(testing.allocator);
    const out = try format(testing.allocator, raw, max_bytes);
    defer testing.allocator.free(out);
    try expectMarker(out, " · lines ");
    const none = try evaluate("console.log('a\\\\n'.repeat(20000));", .{});
    defer none.deinit(testing.allocator);
    const out2 = try format(testing.allocator, none, max_bytes);
    defer testing.allocator.free(out2);
    try testing.expect(std.mem.indexOf(u8, out2, "bytes omitted") != null);
    try expectMarker(out2, null);
}

test "marker omits lines when capture lost bytes or the region has no newline" {
    const lost = try evaluate("let t = ''; for (let i = 1; i <= 20000; i++) t += 'line ' + i + '\\n'; console.log(t);", .{});
    defer lost.deinit(testing.allocator);
    try testing.expect(lost.log_truncated);
    const out = try format(testing.allocator, lost, max_bytes);
    defer testing.allocator.free(out);
    try expectMarker(out, null);
    const flat = try evaluate("console.log('x'.repeat(40000));", .{});
    defer flat.deinit(testing.allocator);
    const out2 = try format(testing.allocator, flat, max_bytes);
    defer testing.allocator.free(out2);
    try expectMarker(out2, null);
}

test "line ranges apply to results and background messages within budget" {
    const o = try evaluate("let t = ''; for (let i = 1; i <= 3000; i++) t += 'row ' + i + '\\n'; t", .{});
    defer o.deinit(testing.allocator);
    const out = try format(testing.allocator, o, max_bytes);
    defer testing.allocator.free(out);
    try testing.expect(out.len <= max_bytes);
    try expectMarker(out, " · lines ");
    var json: std.Io.Writer.Allocating = .init(testing.allocator);
    defer json.deinit();
    for (0..4000) |i| try json.writer.print("row {d}\n", .{i});
    const message = try formatMessage(testing.allocator, "[background bash b1 finished]\n", json.written(), max_bytes);
    defer testing.allocator.free(message);
    try testing.expect(message.len <= max_bytes);
    try expectMarker(message, " · lines ");
}

test "budget holds for every size around the marker with line ranges" {
    var size: usize = max_bytes - 40;
    while (size < max_bytes + 200) : (size += 7) {
        const buf = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(buf);
        for (buf, 0..) |*c, i| c.* = if (i % 9 == 8) '\n' else 'x';
        const out = try format(testing.allocator, .{ .ok = true, .text = @constCast("undefined"), .logs = buf }, max_bytes);
        defer testing.allocator.free(out);
        try testing.expect(out.len <= max_bytes);
    }
}

test "formatSaved writes full truncated output once and skips small outputs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/outputs", .{tmp.sub_path});
    defer testing.allocator.free(dir);
    const save: Save = .{ .io = testing.io, .dir = dir };

    const small = try evaluate("console.log('short');", .{});
    defer small.deinit(testing.allocator);
    const small_out = try formatSaved(testing.allocator, small, max_bytes, save);
    defer testing.allocator.free(small_out);
    try testing.expectEqualStrings("short", small_out);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, dir, .{}));

    const big = try evaluate("console.log('HEAD\\n' + 'x'.repeat(40000) + '\\nMIDDLE-NEEDLE\\n' + 'y'.repeat(40000) + '\\nTAIL');", .{});
    defer big.deinit(testing.allocator);
    try testing.expect(big.log_truncated);
    const out1 = try formatSaved(testing.allocator, big, max_bytes, save);
    defer testing.allocator.free(out1);
    try testing.expect(out1.len <= max_bytes);
    const prefix = "[full output: ";
    const start = std.mem.indexOf(u8, out1, prefix).? + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, out1, start, ']').?;
    const saved_path = out1[start..end];
    const saved_data = try std.Io.Dir.cwd().readFileAlloc(testing.io, saved_path, testing.allocator, .unlimited);
    defer testing.allocator.free(saved_data);
    try testing.expect(std.mem.startsWith(u8, saved_data, "HEAD\n"));
    try testing.expect(std.mem.indexOf(u8, saved_data, "\nMIDDLE-NEEDLE\n") != null);
    try testing.expect(std.mem.endsWith(u8, saved_data, "\nTAIL\n"));

    // Identical output deduplicates to the exact same formatted text and path, and dry-run matches without writing.
    const out2 = try formatSaved(testing.allocator, big, max_bytes, .{ .io = testing.io, .dir = dir, .write = false });
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings(out1, out2);

    var partial = big;
    partial.full_logs_truncated = true;
    const partial_out = try formatSaved(testing.allocator, partial, max_bytes, .{ .io = testing.io, .dir = dir, .write = false });
    defer testing.allocator.free(partial_out);
    try testing.expect(partial_out.len <= max_bytes);
    try testing.expect(std.mem.indexOf(u8, partial_out, "[full output (first 16 MiB): ") != null);
}

test "formatMessageSaved writes raw full background output only when truncated" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/bg-outputs", .{tmp.sub_path});
    defer testing.allocator.free(dir);
    const save: Save = .{ .io = testing.io, .dir = dir };

    const short_msg = try formatMessageSaved(testing.allocator, "[background bash b1 finished]\n", "{\"exit_code\":0,\"output\":\"ok\"}", max_bytes, save, "exit_code: 0\n\nok");
    defer testing.allocator.free(short_msg);
    try testing.expect(std.mem.indexOf(u8, short_msg, "[full output:") == null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, dir, .{}));

    const long_body = try testing.allocator.alloc(u8, 24 * 1024);
    defer testing.allocator.free(long_body);
    @memset(long_body, 'a');
    @memcpy(long_body[12000..12006], "NEEDLE");
    const msg = try formatMessageSaved(testing.allocator, "[background bash b1 finished]\n", long_body, max_bytes, save, "exit_code: 1\n\nline1\nNEEDLE\nline3\n");
    defer testing.allocator.free(msg);
    try testing.expect(msg.len <= max_bytes);
    const prefix = "[full output: ";
    const start = std.mem.indexOf(u8, msg, prefix).? + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, msg, start, ']').?;
    const saved = try std.Io.Dir.cwd().readFileAlloc(testing.io, msg[start..end], testing.allocator, .unlimited);
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("exit_code: 1\n\nline1\nNEEDLE\nline3\n", saved);
}
