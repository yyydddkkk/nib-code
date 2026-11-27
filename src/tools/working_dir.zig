const std = @import("std");
const tools = @import("../tools.zig");
const Tools = tools.Tools;
const policy = @import("policy.zig");

pub const WorkingDir = struct {
    path: [:0]const u8,
    dir: ?std.Io.Dir = null,

    pub fn open(t: *Tools, gpa: std.mem.Allocator, path: ?[]const u8, base: ?[]const u8) !WorkingDir {
        const input = path orelse base orelse return .{ .path = try std.process.currentPathAlloc(t.io, gpa) };
        if (input.len == 0 or std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidPath;
        if (policy.checkCredentials(input, t.codexHome(), t.data_home) == .deny) return error.CredentialAccessDenied;
        const joined = try tools.joinRelative(gpa, base, input);
        defer if (joined) |value| gpa.free(value);
        const requested = joined orelse input;
        const dir = try std.Io.Dir.cwd().openDir(t.io, requested, .{});
        errdefer dir.close(t.io);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const real = buf[0..try dir.realPath(t.io, &buf)];
        if (policy.checkCredentials(real, t.codexHome(), t.data_home) == .deny) return error.CredentialAccessDenied;
        const auth_path = try std.fs.path.join(gpa, &.{ real, "auth.json" });
        defer gpa.free(auth_path);
        const canonical_auth = try tools.normalizedPath(t.io, gpa, auth_path);
        defer gpa.free(canonical_auth);
        try t.checkCredentialPath(gpa, canonical_auth);
        return .{ .path = try gpa.dupeSentinel(u8, real, 0), .dir = dir };
    }

    pub fn close(cwd: WorkingDir, t: *Tools, gpa: std.mem.Allocator) void {
        if (cwd.dir) |dir| dir.close(t.io);
        gpa.free(cwd.path);
    }
};
