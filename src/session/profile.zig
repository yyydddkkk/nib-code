const std = @import("std");

/// Model-family behavior, chosen from the model name rather than the provider
/// (ADR 0025), so a custom endpoint serving `deepseek-flash` gets `.deepseek`.
pub const Profile = enum {
    codex,
    deepseek,
    claude,
    default,

    pub const Set = std.EnumSet(Profile);
    pub const all: Set = .full;

    pub fn forModel(model: []const u8) Profile {
        const name = model[if (std.mem.lastIndexOfScalar(u8, model, '/')) |slash| slash + 1 else 0..];
        if (startsWithFold(name, "gpt-") or startsWithFold(name, "codex")) return .codex;
        if (startsWithFold(name, "deepseek-")) return .deepseek;
        if (startsWithFold(name, "claude-")) return .claude;
        return .default;
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
    for (cases) |case| try t.expectEqual(case.expected, Profile.forModel(case.model));
}

test "a custom provider resolves by its model" {
    const t = std.testing;
    const provider = @import("../provider.zig");
    const cfg: provider.Config = .{ .provider = .custom, .custom_provider = "boban", .base_url = "http://x", .api_key = "", .model = "deepseek-flash" };
    try t.expectEqual(Profile.deepseek, Profile.forModel(cfg.model));
}

test "the full set holds every profile" {
    for (std.meta.tags(Profile)) |profile| try std.testing.expect(Profile.all.contains(profile));
}
