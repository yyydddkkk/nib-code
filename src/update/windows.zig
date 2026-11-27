const std = @import("std");
const windows = std.os.windows;
const max_binary = 64 * 1024 * 1024;

extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) windows.BOOL;

pub fn replace(a: std.mem.Allocator, io: std.Io, path: []const u8, archive: []const u8, kept: *?[]const u8) !void {
    const dir = std.Io.Dir.cwd();
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    const parent = std.fs.path.dirname(path) orelse return error.BadPathName;
    const staging = try std.fmt.allocPrint(a, "{s}\\.nib-update-{s}", .{ parent, std.fmt.bytesToHex(nonce, .lower) });
    try dir.createDir(io, staging, .default_dir);
    defer dir.deleteTree(io, staging) catch {};
    const zip_path = try std.fs.path.join(a, &.{ staging, "release.zip" });
    const staged = try std.fs.path.join(a, &.{ staging, "nib.exe" });
    try dir.writeFile(io, .{ .sub_path = zip_path, .data = archive, .flags = .{ .exclusive = true } });
    const binary = try extract(a, io, zip_path);
    {
        const file = try dir.createFile(io, staged, .{ .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, binary);
        try file.sync(io);
    }

    const previous = try std.fmt.allocPrint(a, "{s}.previous", .{path});
    const old_w = try widePath(a, path);
    const previous_w = try widePath(a, previous);
    const staged_w = try widePath(a, staged);
    dir.deleteFile(io, previous) catch |err| if (err != error.FileNotFound) return err;
    // Windows permits renaming a running image but does not permit replacing it at the same path.
    try move(old_w, previous_w);
    move(staged_w, old_w) catch |err| {
        move(previous_w, old_w) catch {
            kept.* = previous;
            return error.UpdateRollbackFailed;
        };
        return err;
    };
}

fn widePath(a: std.mem.Allocator, path: []const u8) ![:0]u16 {
    const wide = if (std.mem.startsWith(u8, path, "\\\\?\\")) path else if (std.mem.startsWith(u8, path, "\\\\"))
        try std.fmt.allocPrint(a, "\\\\?\\UNC\\{s}", .{path[2..]})
    else
        try std.fmt.allocPrint(a, "\\\\?\\{s}", .{path});
    return std.unicode.wtf8ToWtf16LeAllocZ(a, wide);
}

fn move(from: [:0]const u16, to: [:0]const u16) !void {
    if (MoveFileExW(from, to, 0) != .FALSE) return;
    return switch (windows.GetLastError()) {
        .ACCESS_DENIED, .SHARING_VIOLATION => error.AccessDenied,
        .ALREADY_EXISTS, .FILE_EXISTS => error.PathAlreadyExists,
        else => |err| windows.unexpectedError(err),
    };
}

fn extract(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var zip = try std.zip.Iterator.init(&reader);
    const entry = (try zip.next()) orelse return error.InvalidArchive;
    var name: ["nib.exe".len]u8 = undefined;
    if (entry.filename_len != name.len or entry.uncompressed_size > max_binary) return error.InvalidArchive;
    if (!std.mem.eql(u8, try entry.getFilename(&reader, &name, .{}), "nib.exe") or try zip.next() != null)
        return error.InvalidArchive;
    const binary = try a.alloc(u8, @intCast(entry.uncompressed_size));
    var writer: std.Io.Writer = .fixed(binary);
    try entry.extractTo(&reader, &writer);
    if (!isX64Executable(writer.buffered())) return error.InvalidArchive;
    return writer.buffered();
}

fn isX64Executable(bytes: []const u8) bool {
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..2], "MZ")) return false;
    const offset = std.mem.readInt(u32, bytes[60..64], .little);
    if (offset > bytes.len - 6) return false;
    return std.mem.eql(u8, bytes[offset..][0..4], "PE\x00\x00") and
        std.mem.readInt(u16, bytes[offset + 4 ..][0..2], .little) == 0x8664;
}
