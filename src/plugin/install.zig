const std = @import("std");
const plugin = @import("../plugin.zig");
const config = @import("../config.zig");
const A = std.mem.Allocator;

const Budget = struct { files: usize = 0, bytes: u64 = 0 };

fn copy(a: A, io: std.Io, source: []const u8, target: []const u8, budget: *Budget, depth: usize) anyerror!void {
    if (depth > 64) return error.PluginTooLarge;
    var from = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true, .follow_symlinks = false });
    defer from.close(io);
    try std.Io.Dir.cwd().createDirPath(io, target);
    var to = try std.Io.Dir.cwd().openDir(io, target, .{});
    defer to.close(io);
    var it = from.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        budget.files += 1;
        if (budget.files > 10_000) return error.PluginTooLarge;
        switch (entry.kind) {
            .directory => try copy(a, io, try std.fs.path.join(a, &.{ source, entry.name }), try std.fs.path.join(a, &.{ target, entry.name }), budget, depth + 1),
            .file => {
                const st = try from.statFile(io, entry.name, .{ .follow_symlinks = false });
                budget.bytes += st.size;
                if (budget.bytes > 64 * 1024 * 1024) return error.PluginTooLarge;
                try from.copyFile(entry.name, to, entry.name, io, .{ .replace = false });
            },
            else => return error.PluginSpecialFile,
        }
    }
}

pub fn install(a: A, io: std.Io, home: []const u8, source: []const u8, subdirectory: ?[]const u8) !plugin.Package {
    var random: [16]u8 = undefined;
    io.random(&random);
    const id = try std.fmt.allocPrint(a, "{s}", .{std.fmt.bytesToHex(&random, .lower)});
    const store = try std.fs.path.resolve(a, &.{ home, "plugins", "store" });
    const stage = try std.fmt.allocPrint(a, "{s}/.install-{s}", .{ store, id });
    try std.Io.Dir.cwd().createDirPath(io, stage);
    defer std.Io.Dir.cwd().deleteTree(io, stage) catch {};
    const remote = std.mem.startsWith(u8, source, "https://") or std.mem.startsWith(u8, source, "ssh://") or std.mem.startsWith(u8, source, "git@") or std.mem.startsWith(u8, source, "file://");
    var from = source;
    if (remote) {
        const cloned = try std.fs.path.join(a, &.{ stage, "repository" });
        const result = try std.process.run(a, io, .{
            .argv = &.{ "git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "init.templateDir=", "-c", "protocol.ext.allow=never", "clone", "--depth", "1", "--", source, cloned },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
        });
        if (result.term != .exited or result.term.exited != 0) return error.PluginCloneFailed;
        from = cloned;
    }
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, from, a);
    if (subdirectory) |sub| {
        if (std.fs.path.isAbsolute(sub)) return error.InvalidPluginPath;
        from = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fs.path.resolve(a, &.{ base, sub }), a);
        if (!std.mem.eql(u8, from, base) and (!std.mem.startsWith(u8, from, base) or from.len <= base.len or from[base.len] != '/')) return error.InvalidPluginPath;
    } else from = base;
    if (std.mem.eql(u8, store, from) or (std.mem.startsWith(u8, store, from) and store.len > from.len and store[from.len] == '/')) return error.InvalidPluginPath;
    const payload = try std.fs.path.join(a, &.{ stage, "package" });
    var budget: Budget = .{};
    try copy(a, io, from, payload, &budget, 0);
    const package = try plugin.load(a, io, payload);
    const registry = try std.fs.path.join(a, &.{ home, "plugins", "installed" });
    try std.Io.Dir.cwd().createDirPath(io, registry);
    const record = try std.fs.path.join(a, &.{ registry, package.name });
    if (std.Io.Dir.cwd().statFile(io, record, .{})) |_| return error.PluginAlreadyInstalled else |err| {
        if (err != error.FileNotFound) return err;
    }
    const destination = try std.fs.path.join(a, &.{ store, id });
    try std.Io.Dir.renameAbsolute(payload, destination, io);
    errdefer std.Io.Dir.cwd().deleteTree(io, destination) catch {};
    const installed = try plugin.load(a, io, destination);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, record, .{ .replace = false });
    defer atomic.deinit(io);
    var buf: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buf);
    try writer.interface.print("{s}\n", .{destination});
    try writer.flush();
    // Reinstallation must not reuse a persisted enabled switch.
    try config.savePlugin(a, io, home, package.name, false);
    try atomic.link(io);
    return installed;
}
