const std = @import("std");
pub const validateTemplate = @import("templates.zig").validate;
pub const EnvBinding = struct { name: []const u8, value: []const u8 };
pub const Server = struct {
    id: []const u8,
    command: ?[]const u8 = null,
    url: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    env_bindings: []const EnvBinding = &.{},
    header_env: ?[]const u8 = null,
    enabled: bool = false,
    line: usize = 1,
};

pub fn envName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| if (!(std.ascii.isAlphabetic(c) or c == '_' or (i > 0 and std.ascii.isDigit(c)))) return false;
    return true;
}

pub fn copy(a: std.mem.Allocator, servers: []const Server) ![]Server {
    const out = try a.alloc(Server, servers.len);
    for (servers, out) |server, *item| {
        item.* = server;
        item.id = try a.dupe(u8, server.id);
        inline for (.{ "command", "url", "header_env" }) |key| if (@field(server, key)) |s| {
            @field(item, key) = try a.dupe(u8, s);
        };
        const bindings = try a.alloc(EnvBinding, server.env_bindings.len);
        for (server.env_bindings, bindings) |binding, *out_binding| out_binding.* = .{ .name = try a.dupe(u8, binding.name), .value = try a.dupe(u8, binding.value) };
        item.env_bindings = bindings;
        inline for (.{ "args", "env" }) |key| {
            const list = try a.alloc([]const u8, @field(server, key).len);
            for (@field(server, key), list) |s, *v| v.* = try a.dupe(u8, s);
            @field(item, key) = list;
        }
    }
    return out;
}
