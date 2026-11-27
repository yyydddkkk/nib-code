const std = @import("std");
const builtin = @import("builtin");
const atomic = @import("tools/atomic_file.zig");
const current = @import("build_options").version;

fn version(text: []const u8) ![]const u8 {
    const v = if (std.mem.startsWith(u8, text, "v")) text[1..] else text;
    _ = std.SemanticVersion.parse(v) catch return error.InvalidVersion;
    return v;
}

fn newer(candidate: []const u8, installed: []const u8) !bool {
    const installed_version = std.SemanticVersion.parse(installed) catch return true;
    return (try std.SemanticVersion.parse(candidate)).order(installed_version) == .gt;
}

fn asset(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ![]const u8 {
    return switch (os) {
        .linux => switch (arch) {
            .x86_64 => "nib-x86_64-linux.tar.gz",
            .aarch64 => "nib-aarch64-linux.tar.gz",
            else => error.UnsupportedPlatform,
        },
        .windows => if (arch == .x86_64) "nib-x86_64-windows-preview.zip" else error.UnsupportedPlatform,
        .macos => switch (arch) {
            .aarch64 => "nib-aarch64-macos.tar.gz",
            .x86_64 => error.IntelMacUnsupported,
            else => error.UnsupportedPlatform,
        },
        else => error.UnsupportedPlatform,
    };
}

fn checksum(text: []const u8, name: []const u8) ![32]u8 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const hash = words.next() orelse continue;
        const file = words.next() orelse continue;
        if (!std.mem.eql(u8, file, name)) continue;
        if (hash.len != 64) return error.InvalidChecksum;
        var out: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, hash) catch return error.InvalidChecksum;
        return out;
    }
    return error.MissingChecksum;
}

fn extract(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var input: std.Io.Reader = .fixed(bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    var names: [4096]u8 = undefined;
    var links: [4096]u8 = undefined;
    var tar = std.tar.Iterator.init(&gzip.reader, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    var result: ?[]const u8 = null;
    while (try tar.next()) |file| {
        if (!std.mem.eql(u8, file.name, "nib") or file.kind != .file or result != null) return error.InvalidArchive;
        var out: std.Io.Writer.Allocating = .init(a);
        try tar.streamRemaining(file, &out.writer);
        result = out.written();
    }
    return result orelse error.InvalidArchive;
}

fn download(a: std.mem.Allocator, io: std.Io, client: *std.http.Client, base: []const u8, name: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), name });
    if (std.mem.startsWith(u8, url, "file://")) {
        const path = if (builtin.os.tag == .windows) blk: {
            const uri = try std.Uri.parse(url);
            if (uri.host) |host| if ((try host.toRawMaybeAlloc(a)).len != 0) return error.InvalidFileUrl;
            const raw = try uri.path.toRawMaybeAlloc(a);
            if (raw.len < 4 or raw[0] != '/' or !std.fs.path.isAbsolute(raw[1..])) return error.InvalidFileUrl;
            break :blk raw[1..];
        } else url[7..];
        return std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    }
    var out: std.Io.Writer.Allocating = .init(a);
    const response = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &out.writer });
    if (response.status != .ok) return error.DownloadFailed;
    return out.written();
}

pub fn run(init: std.process.Init, args: []const []const u8, stdout: *std.Io.Writer, detail: *?[]u8) !void {
    if (args.len > 1) return error.InvalidArguments;
    const a = init.arena.allocator();
    const name = asset(builtin.os.tag, builtin.cpu.arch) catch |err| {
        detail.* = if (err == error.IntelMacUnsupported) try init.gpa.dupe(u8, "Intel Macs are not supported; build from source with Zig 0.17") else try std.fmt.allocPrint(init.gpa, "Unsupported platform: {s}/{s}", .{ if (builtin.os.tag == .linux) "Linux" else if (builtin.os.tag == .macos) "Darwin" else @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
        return err;
    };
    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();
    try client.initDefaultProxies(a, init.environ_map);
    const wanted = if (args.len == 1) try version(args[0]) else latest: {
        var req = try client.request(.GET, try std.Uri.parse("https://github.com/yyydddkkk/nib-code/releases/latest"), .{ .redirect_behavior = .unhandled });
        defer req.deinit();
        try req.sendBodiless();
        const response = try req.receiveHead(&.{});
        const location = response.head.location orelse return error.MissingReleaseRedirect;
        break :latest try a.dupe(u8, try version(std.fs.path.basename(location)));
    };
    if (args.len == 0 and !try newer(wanted, current)) {
        try stdout.print("nib {s} is the latest\n", .{current});
        return stdout.flush();
    }
    const base = init.environ_map.get("NIB_DOWNLOAD_BASE") orelse try std.fmt.allocPrint(a, "https://github.com/yyydddkkk/nib-code/releases/download/v{s}", .{wanted});
    const bytes = try download(a, init.io, &client, base, name);
    if (!std.mem.eql(u8, init.environ_map.get("NIB_SKIP_VERIFY") orelse "", "1")) {
        const expected = try checksum(try download(a, init.io, &client, base, "SHA256SUMS"), name);
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
        if (!std.mem.eql(u8, &expected, &actual)) return error.ChecksumMismatch;
    }
    const path = try atomic.canonicalPath(init.io, a, try std.process.executablePathAlloc(init.io, a));
    if (builtin.os.tag == .windows) {
        var kept: ?[]const u8 = null;
        @import("update/windows.zig").replace(a, init.io, path, bytes, &kept) catch |err| {
            detail.* = if (kept) |backup|
                try std.fmt.allocPrint(init.gpa, "could not restore {s}; the previous executable is at {s}", .{ path, backup })
            else
                try std.fmt.allocPrint(init.gpa, "could not replace {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
    } else {
        const binary = try extract(a, bytes);
        _ = atomic.replace(init.io, a, path, binary, .{ .permissions = .fromMode(0o755), .force_permissions = true, .sync = true }) catch |err| {
            detail.* = try std.fmt.allocPrint(init.gpa, "could not replace {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
    }
    if (std.mem.eql(u8, wanted, current)) try stdout.print("nib {s} is installed\n", .{wanted}) else try stdout.print("nib {s} → {s}\n", .{ current, wanted });
    try stdout.flush();
}

test "release versions, platforms and checksums" {
    const t = std.testing;
    try t.expectEqualStrings("0.8.0", try version("v0.8.0"));
    try t.expectError(error.InvalidVersion, version("../bad"));
    try t.expect((try std.SemanticVersion.parse(try version("v0.8.0"))).order(try std.SemanticVersion.parse("0.9.0")) == .lt);
    try t.expectEqualStrings("nib-x86_64-linux.tar.gz", try asset(.linux, .x86_64));
    try t.expectEqualStrings("nib-aarch64-linux.tar.gz", try asset(.linux, .aarch64));
    try t.expectEqualStrings("nib-aarch64-macos.tar.gz", try asset(.macos, .aarch64));
    try t.expectEqualStrings("nib-x86_64-windows-preview.zip", try asset(.windows, .x86_64));
    try t.expectError(error.UnsupportedPlatform, asset(.windows, .aarch64));
    try t.expectError(error.IntelMacUnsupported, asset(.macos, .x86_64));
    try t.expectError(error.MissingChecksum, checksum("", "nib"));
    try t.expectError(error.InvalidChecksum, checksum("bad  nib\n", "nib"));
    try t.expectEqual(@as([32]u8, @splat(0)), try checksum("0000000000000000000000000000000000000000000000000000000000000000  nib\n", "nib"));
}

test "extract a gzip release containing only nib" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("test", try extract(arena.allocator(), @embedFile("update/tiny.tar.gz")));
    try std.testing.expectError(error.ReadFailed, extract(arena.allocator(), "bad"));
}

test "update without a version only moves forward" {
    try std.testing.expect(try newer("0.9.0", "0.8.0"));
    try std.testing.expect(!try newer("0.8.0", "0.8.0"));
    try std.testing.expect(!try newer("0.8.0", "0.9.0"));
    try std.testing.expect(try newer("0.10.0", "0.9.0"));
}
