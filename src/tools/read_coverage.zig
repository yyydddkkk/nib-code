const std = @import("std");
const Version = @import("file_state.zig").State.Version;

const Span = struct { start: usize, end: usize };
const eof = std.math.maxInt(usize);

pub const Coverage = struct {
    mutex: std.Io.Mutex = .init,
    files: std.StringHashMapUnmanaged(File) = .empty,

    const File = struct {
        version: Version,
        spans: std.ArrayList(Span) = .empty,

        fn complete(file: File) bool {
            return file.spans.items.len > 0 and file.spans.items[0].start == 1 and file.spans.items[0].end == eof;
        }

        fn add(file: *File, gpa: std.mem.Allocator, span: Span) !void {
            if (file.complete() or span.start == span.end) return;
            var merged = span;
            const spans = &file.spans;
            var first: usize = 0;
            while (first < spans.items.len and spans.items[first].end < merged.start) : (first += 1) {}
            var last = first;
            while (last < spans.items.len and spans.items[last].start <= merged.end) : (last += 1) {
                merged.start = @min(merged.start, spans.items[last].start);
                merged.end = @max(merged.end, spans.items[last].end);
            }
            try spans.replaceRange(gpa, first, last - first, &.{merged});
        }
    };

    pub fn read(coverage: *Coverage, io: std.Io, gpa: std.mem.Allocator, path: []const u8, version: Version, offset: usize, next: ?usize) !void {
        coverage.mutex.lockUncancelable(io);
        defer coverage.mutex.unlock(io);
        const entry = try coverage.files.getOrPut(gpa, path);
        if (!entry.found_existing) {
            errdefer _ = coverage.files.remove(path);
            entry.key_ptr.* = try gpa.dupe(u8, path);
            entry.value_ptr.* = .{ .version = version };
        }
        const file = entry.value_ptr;
        if (!std.meta.eql(file.version, version)) {
            file.spans.clearRetainingCapacity();
            file.version = version;
        }
        try file.add(gpa, .{ .start = @max(1, offset), .end = next orelse eof });
    }

    pub fn incomplete(coverage: *Coverage, io: std.Io, path: []const u8, version: Version) bool {
        coverage.mutex.lockUncancelable(io);
        defer coverage.mutex.unlock(io);
        const file = coverage.files.get(path) orelse return false;
        return std.meta.eql(file.version, version) and !file.complete();
    }

    pub fn forget(coverage: *Coverage, io: std.Io, gpa: std.mem.Allocator, path: []const u8) void {
        coverage.mutex.lockUncancelable(io);
        defer coverage.mutex.unlock(io);
        const entry = coverage.files.fetchRemove(path) orelse return;
        gpa.free(entry.key);
        var spans = entry.value.spans;
        spans.deinit(gpa);
    }

    pub fn deinit(coverage: *Coverage, gpa: std.mem.Allocator) void {
        var it = coverage.files.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            entry.value_ptr.spans.deinit(gpa);
        }
        coverage.files.deinit(gpa);
        coverage.files = .empty;
    }
};

test "page coverage requires no gaps and never joins versions" {
    const t = std.testing;
    const a = t.allocator;
    var coverage: Coverage = .{};
    defer coverage.deinit(a);
    const old: Version = .{ .inode = 1, .size = 3000, .mtime = 1 };
    var new = old;
    new.mtime = 2;
    try coverage.read(t.io, a, "file", old, 2001, null);
    try coverage.read(t.io, a, "file", new, 1, 2001);
    try t.expect(coverage.incomplete(t.io, "file", new));
    try coverage.read(t.io, a, "file", new, 2501, null);
    try t.expect(coverage.incomplete(t.io, "file", new));
    try coverage.read(t.io, a, "file", new, 1999, 2501);
    try t.expect(!coverage.incomplete(t.io, "file", new));
    try coverage.read(t.io, a, "file", new, 1, 2);
    try t.expect(!coverage.incomplete(t.io, "file", new));
    coverage.forget(t.io, a, "file");
    try t.expect(!coverage.incomplete(t.io, "file", new));
}
