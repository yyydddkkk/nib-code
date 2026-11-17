const std = @import("std");
const plugin = @import("../plugin.zig");
const config = @import("../config.zig");

pub fn run(init: std.process.Init, args: []const []const u8, out: *std.Io.Writer) !void {
    const a = init.arena.allocator();
    const home = try config.home(a, init.environ_map);
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        try out.writeAll("Usage: nib plugin [list|install <path-or-git-url> [--path <subdir>]|uninstall <name>|on <name>|off <name>]\nInstalled plugins are disabled. Switches apply to new sessions.\n");
    } else if (args.len == 0 or (args.len == 1 and std.mem.eql(u8, args[0], "list"))) {
        try out.print("{s}\n", .{try plugin.list(a, init.io, home)});
    } else if (std.mem.eql(u8, args[0], "install") and (args.len == 2 or (args.len == 4 and std.mem.eql(u8, args[2], "--path")))) {
        const package = try plugin.install(a, init.io, home, args[1], if (args.len == 4) args[3] else null);
        try out.print("{s} installed · disabled\n", .{package.name});
        try describe(a, out, package);
    } else if (args.len == 2 and (std.mem.eql(u8, args[0], "on") or std.mem.eql(u8, args[0], "off"))) {
        const package = try plugin.setEnabled(a, init.io, home, args[1], std.mem.eql(u8, args[0], "on"));
        try out.print("{s} · {s}\n", .{ package.name, args[0] });
        try describe(a, out, package);
        try out.writeAll("Applies to new sessions.\n");
    } else if (args.len == 2 and std.mem.eql(u8, args[0], "uninstall")) {
        _ = try plugin.installedRoot(a, init.io, home, args[1]);
        try config.savePlugin(a, init.io, home, args[1], false);
        try std.Io.Dir.cwd().deleteFile(init.io, try std.fs.path.join(a, &.{ home, "plugins", "installed", args[1] }));
        try out.print("{s} uninstalled · existing sessions keep their snapshot\n", .{args[1]});
    } else return error.InvalidArguments;
    try out.flush();
}

fn describe(a: std.mem.Allocator, out: *std.Io.Writer, package: plugin.Package) !void {
    try out.print("{s}\n", .{try package.summary(a)});
    for (package.unsupported) |item| try out.print("Unsupported: {s}\n", .{item});
}
