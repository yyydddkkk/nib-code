const std = @import("std");
const config = @import("config.zig");
const components = @import("plugin/components.zig");
pub const Package = components.Package;
pub const load = components.load;
pub const validName = components.validName;
pub const install = @import("plugin/install.zig").install;
pub const cli = @import("plugin/cli.zig").run;

pub fn installedRoot(a: std.mem.Allocator, io: std.Io, home: []const u8, name: []const u8) ![]const u8 {
    if (!validName(name)) return error.InvalidPluginName;
    const path = try std.fs.path.join(a, &.{ home, "plugins", "installed", name });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
    const root = std.mem.trim(u8, text, "\r\n");
    const store = try std.fs.path.resolve(a, &.{ home, "plugins", "store" });
    if (!std.mem.startsWith(u8, root, store) or root.len != store.len + 33 or root[store.len] != '/' or std.mem.indexOfNone(u8, root[store.len + 1 ..], "0123456789abcdef") != null) return error.InvalidPluginPath;
    return root;
}

pub fn get(a: std.mem.Allocator, io: std.Io, home: []const u8, name: []const u8) !Package {
    const package = try load(a, io, try installedRoot(a, io, home, name));
    if (!std.mem.eql(u8, package.name, name)) return error.InvalidPluginName;
    return package;
}

pub fn setEnabled(a: std.mem.Allocator, io: std.Io, home: []const u8, name: []const u8, enabled: bool) !Package {
    if (!validName(name)) return error.InvalidPluginName;
    const package = get(a, io, home, name) catch |err| blk: {
        if (enabled or err == error.OutOfMemory) return err;
        break :blk Package{ .name = name, .root = "", .skills = &.{}, .servers = &.{}, .unsupported = &.{} };
    };
    try config.savePlugin(a, io, home, name, enabled);
    return package;
}

pub fn list(a: std.mem.Allocator, io: std.Io, home: []const u8) ![]const u8 {
    const settings = try config.loadPlugins(a, io, home);
    const directory = try std.fs.path.join(a, &.{ home, "plugins", "installed" });
    var names: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return "No plugins installed.";
        return err;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and validName(entry.name)) try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    for (names.items) |name| {
        const package = get(a, io, home, name) catch |err| {
            try out.print(a, "{s} · {s} · unavailable: {s}\n", .{ name, if (config.skillEnabled(settings, name)) "on" else "off", @errorName(err) });
            continue;
        };
        try out.print(a, "{s} · {s} · {s}\n", .{ name, if (config.skillEnabled(settings, name)) "on" else "off", try package.summary(a) });
        for (package.unsupported) |item| try out.print(a, "  Unsupported: {s}\n", .{item});
    }
    if (names.items.len == 0) return "No plugins installed.";
    try out.appendSlice(a, "Applies to new sessions.");
    return out.items;
}

pub fn apply(a: std.mem.Allocator, io: std.Io, home: []const u8, cfg: *@import("provider.zig").Config) !void {
    var skills: std.ArrayList(@import("session/skills.zig").Skill) = .empty;
    var servers: std.ArrayList(@import("mcp/config.zig").Server) = .empty;
    try servers.appendSlice(a, cfg.mcp_servers);
    for (cfg.enabled_plugins) |name| {
        const package = try get(a, io, home, name);
        try skills.appendSlice(a, package.skills);
        for (package.servers) |server| {
            for (servers.items) |existing| if (std.mem.eql(u8, existing.id, server.id)) return error.PluginMcpNameConflict;
            try servers.append(a, server);
        }
    }
    cfg.plugin_skills = skills.items;
    cfg.mcp_servers = servers.items;
    cfg.plugins_loaded = true;
}
