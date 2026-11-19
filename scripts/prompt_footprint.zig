const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    try @import("nib").prompt_footprint.dump(init.arena.allocator(), init.io, &out.interface);
    try out.interface.flush();
}
