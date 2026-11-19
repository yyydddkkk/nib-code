const std = @import("std");

pub const Family = enum {
    gpt,
    deepseek,
    claude,
    gemini,
    unknown,

    pub fn forModel(model: []const u8) Family {
        const name = model[if (std.mem.lastIndexOfScalar(u8, model, '/')) |slash| slash + 1 else 0..];
        if (startsWithFold(name, "gpt-") or startsWithFold(name, "codex-") or std.ascii.eqlIgnoreCase(name, "codex")) return .gpt;
        if (startsWithFold(name, "deepseek-")) return .deepseek;
        if (startsWithFold(name, "claude-")) return .claude;
        if (startsWithFold(name, "gemini-")) return .gemini;
        return .unknown;
    }
};

pub const Profile = enum {
    codex,
    deepseek,
    claude,
    default,

    pub const Set = std.EnumSet(Profile);
    pub const all: Set = .full;

    pub fn forFamily(family: Family) Profile {
        return switch (family) {
            .gpt => .codex,
            .deepseek => .deepseek,
            .claude => .claude,
            .gemini, .unknown => .default,
        };
    }
};

fn startsWithFold(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

test "profiles follow the model name, not the provider" {
    const t = std.testing;
    const cases = [_]struct { model: []const u8, expected: Profile }{
        .{ .model = "gpt-6.2-sol", .expected = .codex },
        .{ .model = "gpt-6.2-astra", .expected = .codex },
        .{ .model = "gpt-6.1-sol", .expected = .codex },
        .{ .model = "gpt-6-luna", .expected = .codex },
        .{ .model = "GPT-6.1-Terra", .expected = .codex },
        .{ .model = "codex-mini", .expected = .codex },
        .{ .model = "openai/gpt-6.1-sol", .expected = .codex },
        .{ .model = "deepseek-flash", .expected = .deepseek },
        .{ .model = "deepseek-pro", .expected = .deepseek },
        .{ .model = "deepseek/deepseek-flash", .expected = .deepseek },
        .{ .model = "claude-sonnet-5-5", .expected = .claude },
        .{ .model = "anthropic/claude-haiku-5-5", .expected = .claude },
        .{ .model = "mock-model", .expected = .default },
        .{ .model = "qwen3-coder", .expected = .default },
        .{ .model = "", .expected = .default },
        .{ .model = "my-gpt-wrapper", .expected = .default },
        .{ .model = "deepseek", .expected = .default },
    };
    for (cases) |case| try t.expectEqual(case.expected, Profile.forFamily(Family.forModel(case.model)));
}

test "a custom provider resolves by its model" {
    const t = std.testing;
    const provider = @import("../provider.zig");
    const cfg: provider.Config = .{ .provider = .custom, .custom_provider = "boban", .base_url = "http://x", .api_key = "", .model = "deepseek-flash" };
    try t.expectEqual(Profile.deepseek, Profile.forFamily(Family.forModel(cfg.model)));
}

test "the full set holds every profile" {
    for (std.meta.tags(Profile)) |profile| try std.testing.expect(Profile.all.contains(profile));
}

test "recognized family and fallback profile are separate" {
    const t = std.testing;
    try t.expectEqual(Family.gpt, Family.forModel("proxy/codex-mini"));
    try t.expectEqual(Family.gemini, Family.forModel("google/GEMINI-3-flash"));
    try t.expectEqual(Family.unknown, Family.forModel("custom/model"));
    try t.expectEqual(Family.unknown, Family.forModel("codexample"));
    try t.expectEqual(Profile.default, Profile.forFamily(.gemini));
    try t.expectEqual(Profile.default, Profile.forFamily(.unknown));
}
