const std = @import("std");

pub const max_entries = 64;

pub const Entry = struct {
    first: usize,
    last: usize,
    // Offsets in the original console stream, not the captured buffer.
    start: usize,
    end: usize,
};

pub const Capture = struct {
    limit: usize,
    full_limit: usize = 0,
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,
    full: std.ArrayList(u8) = .empty,
    full_truncated: bool = false,
    cursor: usize = 0,
    bytes: usize = 0,
    calls: usize = 0,
    entries: [max_entries]Entry = undefined,
    count: usize = 0,

    pub fn deinit(self: *Capture, gpa: std.mem.Allocator) void {
        self.head.deinit(gpa);
        self.tail.deinit(gpa);
        self.full.deinit(gpa);
    }

    pub fn append(self: *Capture, gpa: std.mem.Allocator, text: []const u8) !void {
        if (self.full_limit > 0 and !self.full_truncated) {
            if (self.full.items.len == 0 and self.bytes + text.len > self.limit) {
                try self.appendFull(gpa, self.head.items);
                if (!self.full_truncated) try self.appendFull(gpa, self.tail.items[self.cursor..]);
                if (!self.full_truncated) try self.appendFull(gpa, self.tail.items[0..self.cursor]);
            }
            if ((self.full.items.len > 0 or self.bytes + text.len > self.limit) and !self.full_truncated) {
                try self.appendFull(gpa, text);
            }
        }
        self.calls += 1;
        const entry: Entry = .{ .first = self.calls, .last = self.calls, .start = self.bytes, .end = self.bytes + text.len };
        self.bytes = entry.end;
        if (self.count == max_entries) {
            std.mem.copyForwards(Entry, self.entries[max_entries / 2 .. max_entries - 1], self.entries[max_entries / 2 + 1 ..]);
            self.count -= 1;
        }
        self.entries[self.count] = entry;
        self.count += 1;

        const head_len = @min(text.len, (self.limit - self.limit / 2) - self.head.items.len);
        try self.head.appendSlice(gpa, text[0..head_len]);
        const rest = text[head_len..];
        const capacity = self.limit / 2;
        if (rest.len == 0 or capacity == 0) return;
        if (rest.len >= capacity) {
            self.tail.clearRetainingCapacity();
            try self.tail.appendSlice(gpa, rest[rest.len - capacity ..]);
            self.cursor = 0;
        } else {
            const added = @min(rest.len, capacity - self.tail.items.len);
            try self.tail.appendSlice(gpa, rest[0..added]);
            const overwrite = rest[added..];
            const first = @min(overwrite.len, capacity - self.cursor);
            @memcpy(self.tail.items[self.cursor..][0..first], overwrite[0..first]);
            @memcpy(self.tail.items[0 .. overwrite.len - first], overwrite[first..]);
            self.cursor = (self.cursor + overwrite.len) % capacity;
        }
    }

    fn appendFull(self: *Capture, gpa: std.mem.Allocator, text: []const u8) !void {
        if (text.len == 0 or self.full_truncated) return;
        const rem = self.full_limit -| self.full.items.len;
        if (text.len <= rem) {
            try self.full.appendSlice(gpa, text);
            return;
        }
        try self.full.appendSlice(gpa, text[0..rem]);
        self.full.items.len = trimEnd(self.full.items).len;
        self.full_truncated = true;
    }

    pub const Snapshot = struct {
        logs: []u8,
        entries: []Entry,
        head_bytes: usize,
        tail_start: usize,
        full: []const u8 = "",
        full_truncated: bool = false,
    };

    pub fn snapshot(self: *Capture, gpa: std.mem.Allocator) !Snapshot {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try out.writer.writeAll(self.head.items);
        try out.writer.writeAll(self.tail.items[self.cursor..]);
        try out.writer.writeAll(self.tail.items[0..self.cursor]);
        const raw = out.written();
        var head_bytes = raw.len;
        var tail_start = raw.len;
        var logs: []u8 = undefined;
        if (self.bytes > self.limit) {
            const head = trimEnd(raw[0..self.head.items.len]);
            const tail = trimStart(raw[self.head.items.len..]);
            const marker = try std.fmt.allocPrint(gpa, "\n[console output truncated: {d} of {d} bytes omitted]\n", .{ self.bytes - head.len - tail.len, self.bytes });
            defer gpa.free(marker);
            logs = try std.mem.concat(gpa, u8, &.{ head, marker, tail });
            head_bytes = head.len;
            tail_start = head.len + marker.len;
        } else {
            logs = try out.toOwnedSlice();
        }
        errdefer gpa.free(logs);

        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(gpa);
        for (self.entries[0..self.count]) |entry| {
            if (entries.items.len > 0) {
                const prev = entries.items[entries.items.len - 1];
                if (entry.first > prev.last + 1) try entries.append(gpa, .{ .first = prev.last + 1, .last = entry.first - 1, .start = prev.end, .end = entry.start });
            }
            try entries.append(gpa, entry);
        }
        const entry_slice = try entries.toOwnedSlice(gpa);
        errdefer gpa.free(entry_slice);
        const full = if (self.full.items.len > 0) try gpa.dupe(u8, self.full.items) else "";
        return .{ .logs = logs, .entries = entry_slice, .head_bytes = head_bytes, .tail_start = tail_start, .full = full, .full_truncated = self.full_truncated };
    }
};

pub fn trimEnd(s: []const u8) []const u8 {
    var j = s.len;
    while (j > 0 and s.len - j < 3 and (s[j - 1] & 0xC0) == 0x80) j -= 1;
    if (j == 0) return s[0..0];
    const lead = j - 1;
    const len = std.unicode.utf8ByteSequenceLength(s[lead]) catch return s[0..lead];
    return if (lead + len <= s.len) s else s[0..lead];
}

pub fn trimStart(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and i < 3 and (s[i] & 0xC0) == 0x80) i += 1;
    return s[i..];
}

const testing = std.testing;

test "rolling tail matches original stream across wrap and large writes" {
    for (0..20) |limit| {
        var capture: Capture = .{ .limit = limit };
        defer capture.deinit(testing.allocator);
        var original: std.ArrayList(u8) = .empty;
        defer original.deinit(testing.allocator);
        const chunks = [_][]const u8{ "AB", "CDE", "FG", "HI", "J", "K", "LMN", "OPQR", "STUVWXYZ", "0", "123456789" };
        for (chunks) |chunk| {
            try capture.append(testing.allocator, chunk);
            try original.appendSlice(testing.allocator, chunk);
            try testing.expect(capture.head.items.len + capture.tail.items.len <= limit);
            const snap = try capture.snapshot(testing.allocator);
            defer testing.allocator.free(snap.logs);
            defer testing.allocator.free(snap.entries);
            if (original.items.len <= limit) {
                try testing.expectEqualStrings(original.items, snap.logs);
            } else {
                const head_len = limit - limit / 2;
                const tail_len = limit / 2;
                try testing.expectEqualStrings(original.items[0..head_len], snap.logs[0..snap.head_bytes]);
                try testing.expectEqualStrings(original.items[original.items.len - tail_len ..], snap.logs[snap.tail_start..]);
                const marker = try std.fmt.allocPrint(testing.allocator, "\n[console output truncated: {d} of {d} bytes omitted]\n", .{ original.items.len - limit, original.items.len });
                defer testing.allocator.free(marker);
                try testing.expectEqualStrings(marker, snap.logs[snap.head_bytes..snap.tail_start]);
            }
        }
    }
}

test "metadata keeps first and last calls with exact intervening byte range" {
    for ([_]usize{ 64, 65, 66, 10000 }) |calls| {
        var capture: Capture = .{ .limit = 7 };
        defer capture.deinit(testing.allocator);
        var expected_end: usize = 0;
        for (0..calls) |i| {
            const text = "0123456789"[0 .. i % 10 + 1];
            try capture.append(testing.allocator, text);
            expected_end += text.len;
        }
        const snap = try capture.snapshot(testing.allocator);
        defer testing.allocator.free(snap.logs);
        defer testing.allocator.free(snap.entries);
        try testing.expectEqual(@min(calls, max_entries + 1), snap.entries.len);
        var next_call: usize = 1;
        var next_byte: usize = 0;
        for (snap.entries) |entry| {
            try testing.expectEqual(next_call, entry.first);
            try testing.expectEqual(next_byte, entry.start);
            var bytes: usize = 0;
            for (entry.first..entry.last + 1) |call| bytes += (call - 1) % 10 + 1;
            try testing.expectEqual(bytes, entry.end - entry.start);
            next_call = entry.last + 1;
            next_byte = entry.end;
        }
        try testing.expectEqual(calls + 1, next_call);
        try testing.expectEqual(expected_end, next_byte);
        if (calls > max_entries) {
            const middle = snap.entries[max_entries / 2];
            try testing.expectEqual(@as(usize, 33), middle.first);
            try testing.expectEqual(calls - 32, middle.last);
        }
    }
}

test "full_limit spills only past limit and caps at a valid UTF-8 boundary" {
    var capture: Capture = .{ .limit = 8, .full_limit = 20 };
    defer capture.deinit(testing.allocator);
    try capture.append(testing.allocator, "1234");
    try capture.append(testing.allocator, "5678");
    {
        const snap = try capture.snapshot(testing.allocator);
        defer testing.allocator.free(snap.logs);
        defer testing.allocator.free(snap.entries);
        defer testing.allocator.free(snap.full);
        try testing.expectEqualStrings("", snap.full);
        try testing.expect(!snap.full_truncated);
    }
    try capture.append(testing.allocator, "90你");
    {
        const snap = try capture.snapshot(testing.allocator);
        defer testing.allocator.free(snap.logs);
        defer testing.allocator.free(snap.entries);
        defer testing.allocator.free(snap.full);
        try testing.expectEqualStrings("1234567890你", snap.full);
        try testing.expect(!snap.full_truncated);
    }
    try capture.append(testing.allocator, "你你你");
    {
        const snap = try capture.snapshot(testing.allocator);
        defer testing.allocator.free(snap.logs);
        defer testing.allocator.free(snap.entries);
        defer testing.allocator.free(snap.full);
        try testing.expect(snap.full_truncated);
        try testing.expect(snap.full.len <= 20);
        try testing.expect(std.unicode.utf8ValidateSlice(snap.full));
        try testing.expectEqualStrings("1234567890你你你", snap.full);
    }
}
