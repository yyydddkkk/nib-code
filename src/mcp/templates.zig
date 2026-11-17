const std = @import("std");
const config = @import("config.zig");

pub fn expand(a: std.mem.Allocator, text: []const u8, env: ?*const std.process.Environ.Map) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const start = std.mem.indexOfPos(u8, text, i, "${") orelse {
            try out.appendSlice(a, text[i..]);
            break;
        };
        try out.appendSlice(a, text[i..start]);
        const end = std.mem.indexOfScalarPos(u8, text, start + 2, '}') orelse return error.InvalidEnvironmentTemplate;
        const name = text[start + 2 .. end];
        if (!config.envName(name)) return error.InvalidEnvironmentTemplate;
        const value = if (env) |source| source.get(name) orelse return error.MissingPluginEnvironment else return error.MissingPluginEnvironment;
        try out.appendSlice(a, value);
        i = end + 1;
    }
    return out.items;
}

pub fn validate(text: []const u8) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "${")) |start| {
        const end = std.mem.indexOfScalarPos(u8, text, start + 2, '}') orelse return error.InvalidEnvironmentTemplate;
        if (!config.envName(text[start + 2 .. end])) return error.InvalidEnvironmentTemplate;
        i = end + 1;
    }
}

test "plugin environment templates preserve values and reject missing variables" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    try env.put("TOKEN", "secret${literal}");
    try t.expectEqualStrings("prefix-secret${literal}-suffix", try expand(a, "prefix-${TOKEN}-suffix", &env));
    try t.expectEqualStrings("literal", try expand(a, "literal", null));
    try t.expectError(error.MissingPluginEnvironment, expand(a, "${MISSING}", &env));
    try t.expectError(error.InvalidEnvironmentTemplate, validate("${BAD-NAME}"));
    try t.expectError(error.InvalidEnvironmentTemplate, validate("${TOKEN"));
}
