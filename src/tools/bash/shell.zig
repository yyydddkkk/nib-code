const std = @import("std");

pub fn executable(io: std.Io) ![]const u8 {
    if (@import("builtin").os.tag != .windows) return "bash";
    return findGitBash(io);
}

fn findGitBash(io: std.Io) ![]const u8 {
    // Do not resolve Bash through a project directory, PATH, or the WSL launcher.
    for ([_][]const u8{
        "C:\\Program Files\\Git\\bin\\bash.exe",
        "C:\\Program Files (x86)\\Git\\bin\\bash.exe",
    }) |path| {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        if (stat.kind == .file) return path;
    }
    return error.GitBashNotFound;
}
