//! Image attachments: header probing, session storage and wire parts. Pixels are never decoded or resized.

const std = @import("std");

pub const max_bytes: u64 = 5 * 1024 * 1024;
pub const max_per_run = 4;
/// Context estimate for one image; compaction budgeting only.
pub const estimated_tokens: u64 = 1500;

pub const Format = enum {
    png,
    jpeg,
    gif,
    webp,

    pub fn mediaType(f: Format) []const u8 {
        return switch (f) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
        };
    }

    pub fn extension(f: Format) []const u8 {
        return switch (f) {
            .png => "png",
            .jpeg => "jpg",
            .gif => "gif",
            .webp => "webp",
        };
    }
};

pub const Info = struct { format: Format, width: u32, height: u32 };

/// A stored attachment; the session log records this reference, never the pixels.
pub const Image = struct {
    path: []const u8,
    name: []const u8,
    media_type: []const u8,
    bytes: u64,
    width: u32,
    height: u32,

    pub fn clone(i: Image, a: std.mem.Allocator) !Image {
        const path = try a.dupe(u8, i.path);
        errdefer a.free(path);
        const name = try a.dupe(u8, i.name);
        errdefer a.free(name);
        return .{ .path = path, .name = name, .media_type = try a.dupe(u8, i.media_type), .bytes = i.bytes, .width = i.width, .height = i.height };
    }

    pub fn deinit(i: Image, a: std.mem.Allocator) void {
        a.free(i.path);
        a.free(i.name);
        a.free(i.media_type);
    }
};

/// A 640×480 PNG header, enough for probing and wire-encoding tests.
pub const sample_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x02\x80\x00\x00\x01\xe0\x08\x06\x00\x00\x00";

pub fn probe(data: []const u8) ?Info {
    const info = probeFormat(data) orelse return null;
    return if (info.width == 0 or info.height == 0) null else info;
}

fn probeFormat(data: []const u8) ?Info {
    if (data.len >= 24 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n") and std.mem.eql(u8, data[12..16], "IHDR"))
        return .{ .format = .png, .width = std.mem.readInt(u32, data[16..20], .big), .height = std.mem.readInt(u32, data[20..24], .big) };
    if (data.len >= 10 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a")))
        return .{ .format = .gif, .width = std.mem.readInt(u16, data[6..8], .little), .height = std.mem.readInt(u16, data[8..10], .little) };
    if (data.len >= 4 and data[0] == 0xFF and data[1] == 0xD8) return probeJpeg(data);
    if (data.len >= 30 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return probeWebp(data);
    return null;
}

fn probeJpeg(data: []const u8) ?Info {
    var i: usize = 2;
    while (i + 4 <= data.len) {
        if (data[i] != 0xFF) return null;
        const marker = data[i + 1];
        if (marker == 0xFF) {
            i += 1;
            continue;
        }
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD8)) {
            i += 2;
            continue;
        }
        if (marker == 0xD9 or marker == 0xDA) return null;
        const length: usize = std.mem.readInt(u16, data[i + 2 ..][0..2], .big);
        const sof = marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC;
        if (sof) {
            if (length < 8 or i + 9 > data.len) return null;
            return .{ .format = .jpeg, .height = std.mem.readInt(u16, data[i + 5 ..][0..2], .big), .width = std.mem.readInt(u16, data[i + 7 ..][0..2], .big) };
        }
        if (length < 2) return null;
        i += 2 + length;
    }
    return null;
}

fn probeWebp(data: []const u8) ?Info {
    const chunk = data[12..16];
    if (std.mem.eql(u8, chunk, "VP8 ")) {
        if (!std.mem.eql(u8, data[23..26], "\x9d\x01\x2a")) return null;
        return .{ .format = .webp, .width = std.mem.readInt(u16, data[26..28], .little) & 0x3fff, .height = std.mem.readInt(u16, data[28..30], .little) & 0x3fff };
    }
    if (std.mem.eql(u8, chunk, "VP8L")) {
        if (data[20] != 0x2f) return null;
        const bits = std.mem.readInt(u32, data[21..25], .little);
        return .{ .format = .webp, .width = (bits & 0x3fff) + 1, .height = ((bits >> 14) & 0x3fff) + 1 };
    }
    if (std.mem.eql(u8, chunk, "VP8X")) {
        const width = @as(u32, data[24]) | @as(u32, data[25]) << 8 | @as(u32, data[26]) << 16;
        const height = @as(u32, data[27]) | @as(u32, data[28]) << 8 | @as(u32, data[29]) << 16;
        return .{ .format = .webp, .width = width + 1, .height = height + 1 };
    }
    return null;
}

pub const StoreError = error{ UnsupportedImage, ImageTooLarge };

pub fn rejection(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedImage => "unsupported image: expected png, jpeg, gif or webp",
        error.ImageTooLarge => "image is larger than 5 MB",
        error.FileNotFound => "file not found",
        else => @errorName(err),
    };
}

/// Copies `data` into `dir` (created on demand) under a content-hash name and returns its reference.
/// All strings in the result are allocated with `a`.
pub fn store(io: std.Io, a: std.mem.Allocator, dir: []const u8, name: []const u8, data: []const u8) !Image {
    if (data.len > max_bytes) return error.ImageTooLarge;
    const info = probe(data) orelse return error.UnsupportedImage;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const file = try std.fmt.allocPrint(a, "{s}.{s}", .{ std.fmt.bytesToHex(digest[0..16].*, .lower), info.format.extension() });
    defer a.free(file);
    const path = try std.fs.path.join(a, &.{ dir, file });
    errdefer a.free(path);
    const cwd = std.Io.Dir.cwd();
    cwd.createDir(io, dir, @import("tools/atomic_file.zig").private_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => try cwd.createDirPath(io, dir),
        else => return err,
    };
    const present = if (cwd.statFile(io, path, .{})) |stat| stat.size == data.len else |_| false;
    if (!present) try cwd.writeFile(io, .{ .sub_path = path, .data = data, .flags = .{ .permissions = @import("tools/atomic_file.zig").private_file } });
    const owned_name = try a.dupe(u8, name);
    errdefer a.free(owned_name);
    return .{ .path = path, .name = owned_name, .media_type = try a.dupe(u8, info.format.mediaType()), .bytes = data.len, .width = info.width, .height = info.height };
}

/// What a request carries for one image.
pub const Part = union(enum) {
    text: []const u8,
    data: struct { media_type: []const u8, base64: []const u8 },

    pub fn dataUrl(p: Part, a: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "data:{s};base64,{s}", .{ p.data.media_type, p.data.base64 });
    }
};

pub fn omittedText(a: std.mem.Allocator, i: Image) ![]u8 {
    return std.fmt.allocPrint(a, "[image {s} {d}×{d} omitted]", .{ i.name, i.width, i.height });
}

/// Reads and base64-encodes each image; a missing file or a model without vision becomes a text placeholder.
/// Allocate `a` from an arena: nothing is freed individually.
pub fn parts(a: std.mem.Allocator, io: std.Io, images: []const Image, vision: bool) ![]const Part {
    const result = try a.alloc(Part, images.len);
    for (images, result) |image, *part| {
        if (!vision) {
            part.* = .{ .text = try omittedText(a, image) };
            continue;
        }
        const data = std.Io.Dir.cwd().readFileAlloc(io, image.path, a, .limited(max_bytes)) catch {
            part.* = .{ .text = try std.fmt.allocPrint(a, "[image {s} unavailable: file is gone]", .{image.name}) };
            continue;
        };
        const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
        _ = std.base64.standard.Encoder.encode(encoded, data);
        part.* = .{ .data = .{ .media_type = image.media_type, .base64 = encoded } };
    }
    return result;
}

/// The file path named by pasted text, as terminals produce on drag-and-drop: quoted, `file://`
/// or with backslash-escaped characters. Null unless it names a supported image extension.
pub fn pastedPath(a: std.mem.Allocator, pasted: []const u8) !?[]u8 {
    var text = std.mem.trim(u8, pasted, " \t\r\n");
    if (text.len == 0 or std.mem.indexOfAny(u8, text, "\r\n") != null) return null;
    if (text.len >= 2 and (text[0] == '\'' or text[0] == '"') and text[text.len - 1] == text[0]) text = text[1 .. text.len - 1];
    const url = std.mem.startsWith(u8, text, "file://");
    if (url) text = text["file://".len..];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\\' and !url and i + 1 < text.len) {
            i += 1;
            try out.append(a, text[i]);
        } else if (c == '%' and url and i + 2 < text.len and std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch null != null) {
            try out.append(a, try std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16));
            i += 2;
        } else try out.append(a, c);
    }
    const ext = std.fs.path.extension(out.items);
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp" }) |known| {
        if (std.ascii.eqlIgnoreCase(ext, known)) return try out.toOwnedSlice(a);
    }
    out.deinit(a);
    return null;
}

const testing = std.testing;

fn png(w: u32, h: u32) [24]u8 {
    var d: [24]u8 = undefined;
    @memcpy(d[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, d[8..12], 13, .big);
    @memcpy(d[12..16], "IHDR");
    std.mem.writeInt(u32, d[16..20], w, .big);
    std.mem.writeInt(u32, d[20..24], h, .big);
    return d;
}

test "probe reads PNG and GIF headers" {
    const p = png(1280, 720);
    try testing.expectEqualDeep(Info{ .format = .png, .width = 1280, .height = 720 }, probe(&p).?);
    try testing.expectEqualDeep(Info{ .format = .gif, .width = 3, .height = 2 }, probe("GIF89a\x03\x00\x02\x00\x00\x00").?);
    try testing.expectEqual(@as(?Info, null), probe(&png(0, 5)));
}

test "probe skips JPEG segments to the frame header" {
    const jpeg = "\xff\xd8\xff\xe0\x00\x04ab\xff\xff\xff\xc2\x00\x0b\x08\x01\x02\x00\x03\x01\x01\x11\x00";
    try testing.expectEqualDeep(Info{ .format = .jpeg, .width = 3, .height = 258 }, probe(jpeg).?);
    try testing.expectEqual(@as(?Info, null), probe("\xff\xd8\xff\xda\x00\x02"));
    try testing.expectEqual(@as(?Info, null), probe("\xff\xd8\xff\xc0\x00\x0b\x08"));
}

test "probe reads the three WebP encodings" {
    var lossy: [30]u8 = @splat(0);
    @memcpy(lossy[0..4], "RIFF");
    @memcpy(lossy[8..16], "WEBPVP8 ");
    @memcpy(lossy[23..26], "\x9d\x01\x2a");
    std.mem.writeInt(u16, lossy[26..28], 640, .little);
    std.mem.writeInt(u16, lossy[28..30], 480, .little);
    try testing.expectEqualDeep(Info{ .format = .webp, .width = 640, .height = 480 }, probe(&lossy).?);
    var lossless: [30]u8 = @splat(0);
    @memcpy(lossless[0..4], "RIFF");
    @memcpy(lossless[8..16], "WEBPVP8L");
    lossless[20] = 0x2f;
    std.mem.writeInt(u32, lossless[21..25], (99) | (49 << 14), .little);
    try testing.expectEqualDeep(Info{ .format = .webp, .width = 100, .height = 50 }, probe(&lossless).?);
    var extended: [30]u8 = @splat(0);
    @memcpy(extended[0..4], "RIFF");
    @memcpy(extended[8..16], "WEBPVP8X");
    extended[24] = 0x0f;
    extended[25] = 0x01;
    extended[27] = 0x09;
    try testing.expectEqualDeep(Info{ .format = .webp, .width = 272, .height = 10 }, probe(&extended).?);
}

test "probe rejects truncated and unknown data" {
    try testing.expectEqual(@as(?Info, null), probe(""));
    try testing.expectEqual(@as(?Info, null), probe("\x89PNG\r\n\x1a\n"));
    try testing.expectEqual(@as(?Info, null), probe("GIF89a\x03"));
    try testing.expectEqual(@as(?Info, null), probe("RIFF\x00\x00\x00\x00WEBPVP8 "));
    try testing.expectEqual(@as(?Info, null), probe("not an image at all, just text bytes"));
}

test "store keeps content-hash files and rejects bad input" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/images", .{tmp.sub_path});
    const p = png(7, 9);
    const first = try store(testing.io, a, dir, "shot.png", &p);
    const second = try store(testing.io, a, dir, "again.png", &p);
    try testing.expectEqualStrings(first.path, second.path);
    try testing.expectEqualStrings("image/png", first.media_type);
    try testing.expectEqual(@as(u32, 9), first.height);
    try testing.expectError(error.UnsupportedImage, store(testing.io, a, dir, "x", "text"));
    const big = try a.alloc(u8, max_bytes + 1);
    try testing.expectError(error.ImageTooLarge, store(testing.io, a, dir, "x", big));
    const encoded = try parts(a, testing.io, &.{first}, true);
    try testing.expectEqualStrings("image/png", encoded[0].data.media_type);
    try testing.expectEqualStrings("iVBORw0KGgo", encoded[0].data.base64[0..11]);
    const text = try parts(a, testing.io, &.{first}, false);
    try testing.expectEqualStrings("[image shot.png 7×9 omitted]", text[0].text);
    var gone = first;
    gone.path = "missing-file.png";
    const missing = try parts(a, testing.io, &.{gone}, true);
    try testing.expect(std.mem.startsWith(u8, missing[0].text, "[image shot.png unavailable"));
}

test "pastedPath understands quoting, escapes and file URLs" {
    const a = testing.allocator;
    const cases = [_]struct { input: []const u8, want: ?[]const u8 }{
        .{ .input = "/tmp/shot.png", .want = "/tmp/shot.png" },
        .{ .input = "  '/tmp/my shot.JPG'\n", .want = "/tmp/my shot.JPG" },
        .{ .input = "\"/tmp/a.webp\"", .want = "/tmp/a.webp" },
        .{ .input = "/tmp/my\\ shot\\ \\(1\\).jpeg", .want = "/tmp/my shot (1).jpeg" },
        .{ .input = "file:///tmp/my%20shot.gif", .want = "/tmp/my shot.gif" },
        .{ .input = "/tmp/notes.txt", .want = null },
        .{ .input = "look at /tmp/shot.png please", .want = null },
        .{ .input = "/tmp/a.png\n/tmp/b.png", .want = null },
        .{ .input = "", .want = null },
    };
    for (cases) |case| {
        const got = try pastedPath(a, case.input);
        defer if (got) |value| a.free(value);
        if (case.want) |want| try testing.expectEqualStrings(want, got.?) else try testing.expectEqual(@as(?[]u8, null), got);
    }
}
