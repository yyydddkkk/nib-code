//! `auth.json`: a JSON document edited in place so unknown fields survive.
//! nib's store holds `keys` (API keys by service id) and Codex OAuth `tokens`;
//! the Codex CLI file shares the `tokens` and `last_refresh` fields.

const std = @import("std");
const atomic_file = @import("../tools/atomic_file.zig");

pub const file_name = "auth.json";
const max_bytes = 1024 * 1024;

pub const Tokens = struct {
    id_token: []const u8 = "",
    access_token: []const u8,
    refresh_token: []const u8 = "",
    account_id: []const u8,
};

pub fn path(a: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ dir, file_name });
}

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    root: std.json.Value,

    pub fn deinit(d: *Doc) void {
        d.arena.deinit();
    }

    /// A missing file is an empty document; a file that is not a JSON object is an error.
    pub fn load(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8) !Doc {
        var doc: Doc = .{ .arena = .init(gpa), .root = undefined };
        errdefer doc.arena.deinit();
        const a = doc.arena.allocator();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, file_path, a, .limited(max_bytes)) catch |err| switch (err) {
            error.FileNotFound => {
                doc.root = .{ .object = .empty };
                return doc;
            },
            else => return err,
        };
        doc.root = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return error.InvalidAuthFile;
        if (doc.root != .object) return error.InvalidAuthFile;
        return doc;
    }

    /// Atomic replace; a new file is 0600 and an existing file keeps its mode.
    pub fn save(d: *Doc, io: std.Io, gpa: std.mem.Allocator, file_path: []const u8) !void {
        return d.write(io, gpa, file_path, false);
    }

    /// Atomic replace that leaves the file 0600 even if it was wider before.
    pub fn saveSecret(d: *Doc, io: std.Io, gpa: std.mem.Allocator, file_path: []const u8) !void {
        return d.write(io, gpa, file_path, true);
    }

    fn write(d: *Doc, io: std.Io, gpa: std.mem.Allocator, file_path: []const u8, force: bool) !void {
        const bytes = try std.json.Stringify.valueAlloc(gpa, d.root, .{ .whitespace = .indent_2 });
        defer gpa.free(bytes);
        if (std.fs.path.dirname(file_path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        _ = try atomic_file.replace(io, gpa, file_path, bytes, .{ .permissions = atomic_file.private_file, .sync = true, .force_permissions = force });
    }

    fn object(d: *Doc) *std.json.ObjectMap {
        return &d.root.object;
    }

    fn section(d: *Doc, name: []const u8, create: bool) !?*std.json.ObjectMap {
        const a = d.arena.allocator();
        if (d.object().getPtr(name)) |value| {
            if (value.* == .object) return &value.object;
            if (!create) return null;
        } else if (!create) return null;
        try d.object().put(a, name, .{ .object = .empty });
        return &d.object().getPtr(name).?.object;
    }

    fn text(map: *const std.json.ObjectMap, name: []const u8) ?[]const u8 {
        const value = map.get(name) orelse return null;
        return if (value == .string) value.string else null;
    }

    pub fn key(d: *Doc, id: []const u8) ?[]const u8 {
        const keys = (d.section("keys", false) catch return null) orelse return null;
        const value = text(keys, id) orelse return null;
        return if (value.len > 0) value else null;
    }

    pub fn setKey(d: *Doc, id: []const u8, value: []const u8) !void {
        const a = d.arena.allocator();
        const keys = (try d.section("keys", true)).?;
        try keys.put(a, try a.dupe(u8, id), .{ .string = try a.dupe(u8, value) });
    }

    pub fn removeKey(d: *Doc, id: []const u8) bool {
        const keys = (d.section("keys", false) catch return false) orelse return false;
        return keys.orderedRemove(id);
    }

    /// Complete tokens only: access token and account id are required.
    pub fn tokens(d: *Doc) ?Tokens {
        const map = (d.section("tokens", false) catch return null) orelse return null;
        const access = text(map, "access_token") orelse return null;
        const account = text(map, "account_id") orelse return null;
        if (access.len == 0 or account.len == 0) return null;
        return .{
            .access_token = access,
            .account_id = account,
            .id_token = text(map, "id_token") orelse "",
            .refresh_token = text(map, "refresh_token") orelse "",
        };
    }

    pub fn setTokens(d: *Doc, value: Tokens, refreshed_at: []const u8) !void {
        const a = d.arena.allocator();
        const map = (try d.section("tokens", true)).?;
        inline for (.{ "id_token", "access_token", "refresh_token", "account_id" }) |field| {
            try map.put(a, field, .{ .string = try a.dupe(u8, @field(value, field)) });
        }
        try d.object().put(a, "last_refresh", .{ .string = try a.dupe(u8, refreshed_at) });
    }

    pub fn removeTokens(d: *Doc) bool {
        const removed = d.object().orderedRemove("tokens");
        _ = d.object().orderedRemove("last_refresh");
        return removed;
    }
};

/// RFC 3339 UTC, second resolution.
pub fn timestamp(buf: *[20]u8, unix_seconds: i64) []const u8 {
    const secs: u64 = @intCast(@max(unix_seconds, 0));
    const day = secs / 86400;
    const rem = secs % 86400;
    var z: i64 = @as(i64, @intCast(day)) + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    z = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = z + @as(i64, if (m <= 2) 1 else 0);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ @as(u64, @intCast(y)), @as(u64, @intCast(m)), @as(u64, @intCast(d)), rem / 3600, rem % 3600 / 60, rem % 60 }) catch "";
}

const testing = std.testing;

fn tmpPath(tmp: *testing.TmpDir, a: std.mem.Allocator, name: []const u8) ![]u8 {
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(dir);
    return std.fs.path.join(a, &.{ dir, name });
}

test "store round trip keeps unknown fields, mode 0600 and removes cleanly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try tmpPath(&tmp, testing.allocator, "nib/auth.json");
    defer testing.allocator.free(p);
    var doc: Doc = try .load(testing.allocator, testing.io, p);
    try testing.expectEqual(@as(usize, 0), doc.object().count());
    try doc.setKey("anthropic", "fake-key-1");
    try doc.object().put(doc.arena.allocator(), "future", .{ .integer = 7 });
    try doc.saveSecret(testing.io, testing.allocator, p);
    doc.deinit();

    var again: Doc = try .load(testing.allocator, testing.io, p);
    defer again.deinit();
    try testing.expectEqualStrings("fake-key-1", again.key("anthropic").?);
    try testing.expect(again.key("openai") == null);
    try testing.expectEqual(@as(i64, 7), again.object().get("future").?.integer);
    try again.setTokens(.{ .access_token = "a", .account_id = "acc", .refresh_token = "r" }, "2026-11-06T00:00:00Z");
    try again.save(testing.io, testing.allocator, p);
    try testing.expect(again.removeKey("anthropic"));
    try testing.expect(!again.removeKey("anthropic"));
    try again.save(testing.io, testing.allocator, p);
    const stat = try std.Io.Dir.cwd().statFile(testing.io, p, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(@backingInt(stat.permissions) & 0o777)));
    try tmp.dir.setFilePermissions(testing.io, "nib/auth.json", .fromMode(0o644), .{});
    try again.save(testing.io, testing.allocator, p);
    try testing.expectEqual(@as(u32, 0o644), @as(u32, @intCast(@backingInt((try std.Io.Dir.cwd().statFile(testing.io, p, .{})).permissions) & 0o777)));
    try again.saveSecret(testing.io, testing.allocator, p);
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(@backingInt((try std.Io.Dir.cwd().statFile(testing.io, p, .{})).permissions) & 0o777)));
    var third: Doc = try .load(testing.allocator, testing.io, p);
    defer third.deinit();
    try testing.expectEqualStrings("acc", third.tokens().?.account_id);
    try testing.expect(third.key("anthropic") == null);
    try testing.expect(third.removeTokens());
    try testing.expect(third.tokens() == null);
}

test "invalid files are errors and incomplete tokens are ignored" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try tmpPath(&tmp, testing.allocator, "auth.json");
    defer testing.allocator.free(p);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "auth.json", .data = "[1]" });
    try testing.expectError(error.InvalidAuthFile, Doc.load(testing.allocator, testing.io, p));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "auth.json", .data = "{\"tokens\":{\"access_token\":\"x\"}}" });
    var doc: Doc = try .load(testing.allocator, testing.io, p);
    defer doc.deinit();
    try testing.expect(doc.tokens() == null);
}

test "save leaves no temporary files behind and replaces atomically" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const p = try tmpPath(&tmp, testing.allocator, "auth.json");
    defer testing.allocator.free(p);
    for (0..3) |i| {
        var doc: Doc = try .load(testing.allocator, testing.io, p);
        defer doc.deinit();
        var buf: [8]u8 = undefined;
        try doc.setKey("k", try std.fmt.bufPrint(&buf, "v{d}", .{i}));
        try doc.save(testing.io, testing.allocator, p);
    }
    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "timestamps are RFC 3339" {
    var buf: [20]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", timestamp(&buf, 0));
    try testing.expectEqualStrings("2026-11-06T12:34:56Z", timestamp(&buf, 1793968496));
}
