const std = @import("std");
const provider = @import("../provider.zig");
const Tools = @import("../tools.zig").Tools;
const prompt = @import("prompt.zig");
const routing = @import("profile.zig");
const Tuning = @import("tuning.zig").Resolved;

pub fn dump(a: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !void {
    const cwd = "/work";
    try out.print("{f}\n", .{std.json.fmt(.{ .system = try prompt.renderCommon(a, cwd) }, .{})});
    const cases = [_]struct { provider.Id, []const u8 }{
        .{ .codex, "gpt-6.2-sol" },
        .{ .anthropic, "claude-sonnet-5-5" },
        .{ .deepseek, "deepseek-flash" },
        .{ .custom, "gemini-3-flash" },
        .{ .custom, "unknown-model" },
    };
    for (cases) |entry| {
        const id, const model = entry;
        const cfg: provider.Config = .{ .provider = id, .model = model, .base_url = "https://example.invalid", .api_key = "" };
        const family = routing.Family.forModel(model);
        const profile = routing.Profile.forFamily(family);
        const host: Tools = .{ .io = io, .home = cwd, .cfg = cfg, .tuning = Tuning.forProfile(profile) };
        const base = try prompt.renderSystem(a, cwd, &host, profile, null);
        const system = try std.mem.concat(a, u8, &.{ base, @import("instructions.zig").precedence_notice });
        const messages: []const provider.Message = &.{ .{ .role = "system", .content = system }, .{ .role = "user", .content = "Hello" } };
        const body = switch (cfg.protocol()) {
            .responses => try @import("../provider/responses.zig").requestBody(a, io, cfg, "footprint", messages, prompt.tools_json, null),
            .anthropic_messages => try @import("../provider/anthropic.zig").requestBody(a, io, cfg, messages, prompt.tools_json, null),
            .chat_completions => try @import("../provider/openai.zig").requestBody(a, io, cfg, messages, prompt.tools_json, null),
        };
        const request = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{ .allocate = .alloc_always });
        try out.print("{f}\n", .{std.json.fmt(.{
            .provider = id,
            .model = model,
            .family = family,
            .profile = profile,
            .system = system,
            .tools = request.object.get("tools") orelse return error.MissingTools,
        }, .{})});
    }
}
