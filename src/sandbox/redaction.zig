const std = @import("std");

pub const Policy = enum(u8) { legacy, credentials_v1 };
pub const marker = "[REDACTED]";
pub const Text = enum { plain, rendered };

fn tokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

const Prefix = struct { text: []const u8, github: bool = false };
const prefixes = [_]Prefix{
    .{ .text = "ghp_", .github = true },
    .{ .text = "gho_", .github = true },
    .{ .text = "ghu_", .github = true },
    .{ .text = "ghs_", .github = true },
    .{ .text = "sk-proj-" },
    .{ .text = "sk-svcacct-" },
};

fn credential(candidate: []const u8) bool {
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, candidate, prefix.text)) continue;
        const suffix = candidate[prefix.text.len..];
        if (!prefix.github) return suffix.len >= 24;
        if (suffix.len != 36) return false;
        for (suffix) |byte| if (!std.ascii.isAlphanumeric(byte)) return false;
        return true;
    }
    return false;
}

fn escapeLen(text: []const u8) usize {
    if (text.len < 2) return 1;
    return switch (text[1]) {
        'u' => if (text.len >= 6 and std.mem.indexOfNone(u8, text[2..6], "0123456789abcdefABCDEF") == null) 6 else 1,
        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => 2,
        else => 1,
    };
}

// Null means the caller can keep borrowing the original bytes.
pub fn mask(a: std.mem.Allocator, text: []const u8, mode: Text) !?[]u8 {
    return maskAt(a, text, mode, null);
}

pub fn maskAt(a: std.mem.Allocator, text: []const u8, mode: Text, location: ?*usize) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const point = if (location) |pos| pos.* else 0;
    var quoted = false;
    var start: usize = 0;
    var copied: usize = 0;
    while (start < text.len) {
        const byte = text[start];
        if (!tokenByte(byte)) {
            if (mode == .rendered) {
                if (quoted and byte == '\\') {
                    start += escapeLen(text[start..]);
                    continue;
                }
                if (byte == '"') quoted = !quoted;
            }
            start += 1;
            continue;
        }
        var end = start + 1;
        while (end < text.len and tokenByte(text[end])) end += 1;
        if ((byte == 'g' or byte == 's') and credential(text[start..end])) {
            try out.appendSlice(a, text[copied..start]);
            if (location) |pos| {
                if (point >= end) pos.* -= end - start - marker.len else if (point >= start) pos.* = out.items.len;
            }
            try out.appendSlice(a, marker);
            copied = end;
        }
        start = end;
    }
    if (copied == 0) return null;
    try out.appendSlice(a, text[copied..]);
    return try out.toOwnedSlice(a);
}

pub fn owned(a: std.mem.Allocator, text: []u8, mode: Text) ![]u8 {
    if (try mask(a, text, mode)) |masked| {
        a.free(text);
        return masked;
    }
    return text;
}

pub const test_github = "ghp_" ++ "0123456789abcdeFGHIJKLMNOPQRSTUVWXYZ";
pub const test_openai = "sk-proj-" ++ "abcd_efgh-ijkl_mnop-qrst_UVWXYZ";

test "credential families and exact token boundaries" {
    const t = std.testing;
    const suffix = test_github[4..];
    const input = "界" ++ test_github ++ ";(gho_" ++ suffix ++ ")\r\nghu_" ++ suffix ++ ",ghs_" ++ suffix ++ "." ++ test_openai ++ ":sk-svcacct-" ++ test_openai[8..];
    const masked = (try mask(t.allocator, input, .plain)).?;
    defer t.allocator.free(masked);
    try t.expectEqualStrings("界[REDACTED];([REDACTED])\r\n[REDACTED],[REDACTED].[REDACTED]:[REDACTED]", masked);
    for ([_][]const u8{
        "x" ++ test_github,    test_github ++ "x",           test_github ++ "-tail", "_" ++ test_openai,
        "ghp_" ++ suffix[1..], "ghp_" ++ suffix[1..] ++ "_", "ghr_" ++ suffix,       "sk-proj-short",
        "sk-" ++ suffix,       "Bearer " ++ suffix,          "password=" ++ suffix,
    }) |text| try t.expect((try mask(t.allocator, text, .plain)) == null);
}

test "rendered quotes and escapes are separators without changing their bytes" {
    const t = std.testing;
    const input = "{\"" ++ test_github ++ "\":\"\\n" ++ test_openai ++ "\\t\\u0000" ++ test_github ++ "\\\"!\"}";
    const masked = (try mask(t.allocator, input, .rendered)).?;
    defer t.allocator.free(masked);
    try t.expectEqualStrings("{\"[REDACTED]\":\"\\n[REDACTED]\\t\\u0000[REDACTED]\\\"!\"}", masked);
    try t.expect((try mask(t.allocator, "\\n" ++ test_github, .plain)) == null);
}

test "allocation failure never returns unmasked text as a replacement" {
    try std.testing.expectError(error.OutOfMemory, mask(std.testing.failing_allocator, test_openai, .plain));
}
