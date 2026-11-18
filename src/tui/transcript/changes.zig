const std = @import("std");
const vaxis = @import("vaxis");
const Change = @import("../../tools/diff.zig").Change;
const max_diff_lines = @import("entry.zig").max_diff_lines;
const File = @import("../../tools/changes.zig").Recovery.File;

/// The line under a Turn footer and its opened per-file rows.
pub const TurnChanges = struct {
    head: []u8,
    rows: []u8,

    pub fn deinit(c: TurnChanges, gpa: std.mem.Allocator) void {
        gpa.free(c.head);
        gpa.free(c.rows);
    }
};

fn counts(w: *std.Io.Writer, added: usize, removed: usize) !void {
    if (added > 0) try w.print("+{d}", .{added});
    if (added > 0 and removed > 0) try w.writeByte(' ');
    if (removed > 0) try w.print("−{d}", .{removed});
}

fn digits(n: usize) usize {
    return std.fmt.count("{d}", .{n});
}

/// Null when no file changed.
pub fn turnChanges(gpa: std.mem.Allocator, files: []const File) !?TurnChanges {
    if (files.len == 0) return null;
    var added: usize = 0;
    var removed: usize = 0;
    var path_width: usize = 0;
    var added_width: usize = 0;
    for (files) |f| {
        added += f.added;
        removed += f.removed;
        path_width = @max(path_width, vaxis.gwidth.gwidth(f.path, .unicode));
        if (f.added > 0) added_width = @max(added_width, 1 + digits(f.added));
    }
    var head: std.Io.Writer.Allocating = .init(gpa);
    errdefer head.deinit();
    try head.writer.print("{d} file{s} changed", .{ files.len, if (files.len == 1) "" else "s" });
    if (added > 0 or removed > 0) {
        try head.writer.writeAll(" · ");
        try counts(&head.writer, added, removed);
    }
    var rows: std.Io.Writer.Allocating = .init(gpa);
    errdefer rows.deinit();
    for (files, 0..) |f, i| {
        if (i > 0) try rows.writer.writeByte('\n');
        const shown = vaxis.gwidth.gwidth(f.path, .unicode);
        try rows.writer.print("  {s}", .{f.path});
        if (f.added == 0 and f.removed == 0) continue;
        try rows.writer.splatByteAll(' ', path_width - shown + 2);
        const used = if (f.added > 0) 1 + digits(f.added) else 0;
        try rows.writer.splatByteAll(' ', added_width - used);
        if (f.added > 0) try rows.writer.print("+{d}", .{f.added});
        if (f.removed > 0) {
            if (added_width > 0) try rows.writer.writeByte(' ');
            try rows.writer.print("−{d}", .{f.removed});
        }
    }
    return .{ .head = try head.toOwnedSlice(), .rows = try rows.toOwnedSlice() };
}

test "turn changes line: singular, zero parts omitted, aligned rows" {
    const gpa = std.testing.allocator;
    const one = (try turnChanges(gpa, &.{.{ .path = "a.zig", .added = 3, .removed = 0 }})).?;
    defer one.deinit(gpa);
    try std.testing.expectEqualStrings("1 file changed · +3", one.head);
    try std.testing.expectEqualStrings("  a.zig  +3", one.rows);
    const many = (try turnChanges(gpa, &.{
        .{ .path = "src/tui.zig", .added = 30, .removed = 4 },
        .{ .path = "src/tui/prediction.zig", .added = 10, .removed = 3 },
        .{ .path = "docs/ui-style.md", .added = 2, .removed = 0 },
        .{ .path = "old.txt", .added = 0, .removed = 5 },
    })).?;
    defer many.deinit(gpa);
    try std.testing.expectEqualStrings("4 files changed · +42 −12", many.head);
    try std.testing.expectEqualStrings(
        "  src/tui.zig             +30 −4\n" ++
            "  src/tui/prediction.zig  +10 −3\n" ++
            "  docs/ui-style.md         +2\n" ++
            "  old.txt                     −5",
        many.rows,
    );
    try std.testing.expect((try turnChanges(gpa, &.{})) == null);
    const removed = (try turnChanges(gpa, &.{.{ .path = "x", .added = 0, .removed = 2 }})).?;
    defer removed.deinit(gpa);
    try std.testing.expectEqualStrings("1 file changed · −2", removed.head);
}

pub const ChangeText = struct {
    /// "src/a.zig +3 −1", or "4 files +20 −5"; empty when nothing changed.
    summary: []u8 = &.{},
    file_count: usize = 0,
    /// Per file a header line, then its diff lines; at most `max_diff_lines` in all.
    diff: []u8 = &.{},
    preview: []u8 = &.{},
    files: []FileDiff = &.{},

    pub const FileDiff = struct {
        header: []u8,
        path_len: usize,
        added: usize,
        removed: usize,
        created: bool,
        added_label: [32]u8 = undefined,
        removed_label: [32]u8 = undefined,
        diff: []u8,
        open: ?bool = null,
        heading_rows: @import("run_details.zig").Rows = .{},

        pub fn expanded(f: FileDiff, single: bool) bool {
            return f.open orelse (single and @import("run_details.zig").lineCount(f.diff) <= 20);
        }
    };

    pub fn init(gpa: std.mem.Allocator, changes: []const Change) !ChangeText {
        if (changes.len == 0) return .{};
        const files = try gpa.alloc(FileDiff, changes.len);
        var initialized: usize = 0;
        errdefer {
            for (files[0..initialized]) |f| {
                gpa.free(f.header);
                gpa.free(f.diff);
            }
            gpa.free(files);
        }
        for (changes, files) |c, *f| {
            const header = try std.fmt.allocPrint(gpa, "{s}{s} +{d} −{d}", .{ c.path, if (c.created) " (new)" else "", c.added, c.removed });
            errdefer gpa.free(header);
            f.* = .{ .header = header, .path_len = c.path.len, .added = c.added, .removed = c.removed, .created = c.created, .diff = try gpa.dupe(u8, c.diff) };
            initialized += 1;
        }
        var summary: std.ArrayList(u8) = .empty;
        errdefer summary.deinit(gpa);
        for (changes, 0..) |c, i| {
            if (i > 0) try summary.appendSlice(gpa, " · ");
            try summary.print(gpa, "{s}{s} +{d} −{d}", .{ c.path, if (c.created) " (new)" else "", c.added, c.removed });
        }
        var diff: std.ArrayList(u8) = .empty;
        errdefer diff.deinit(gpa);
        var shown: usize = 0;
        var hidden: usize = 0;
        for (changes) |c| {
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, c.diff, "\n"), '\n');
            if (shown < max_diff_lines) {
                try diff.print(gpa, "{s}{s} +{d} −{d}\n", .{ c.path, if (c.created) " (new)" else "", c.added, c.removed });
                shown += 1;
            } else hidden += 1;
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                if (shown < max_diff_lines) {
                    try diff.print(gpa, "{s}\n", .{line});
                    shown += 1;
                } else hidden += 1;
            }
        }
        const preview = if (hidden > 0) try std.fmt.allocPrint(gpa, "Diff preview · {d} of {d} lines\n", .{ shown, shown + hidden }) else try gpa.dupe(u8, "");
        errdefer gpa.free(preview);
        const summary_text = try summary.toOwnedSlice(gpa);
        errdefer gpa.free(summary_text);
        return .{ .file_count = changes.len, .summary = summary_text, .diff = try diff.toOwnedSlice(gpa), .preview = preview, .files = files };
    }

    pub fn clone(c: ChangeText, gpa: std.mem.Allocator) !ChangeText {
        const summary = try gpa.dupe(u8, c.summary);
        errdefer gpa.free(summary);
        const diff = try gpa.dupe(u8, c.diff);
        errdefer gpa.free(diff);
        const preview = try gpa.dupe(u8, c.preview);
        errdefer gpa.free(preview);
        const files = try gpa.alloc(FileDiff, c.files.len);
        var initialized: usize = 0;
        errdefer {
            for (files[0..initialized]) |f| {
                gpa.free(f.header);
                gpa.free(f.diff);
            }
            gpa.free(files);
        }
        for (c.files, files) |f, *copy| {
            const header = try gpa.dupe(u8, f.header);
            errdefer gpa.free(header);
            copy.* = .{ .header = header, .path_len = f.path_len, .added = f.added, .removed = f.removed, .created = f.created, .diff = try gpa.dupe(u8, f.diff), .open = f.open };
            initialized += 1;
        }
        return .{ .summary = summary, .file_count = c.file_count, .diff = diff, .preview = preview, .files = files };
    }

    pub fn deinit(c: *ChangeText, gpa: std.mem.Allocator) void {
        gpa.free(c.summary);
        gpa.free(c.diff);
        gpa.free(c.preview);
        for (c.files) |f| {
            gpa.free(f.header);
            gpa.free(f.diff);
        }
        gpa.free(c.files);
        c.* = .{};
    }
};
