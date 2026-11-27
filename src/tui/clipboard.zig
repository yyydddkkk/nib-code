const std = @import("std");
const image = @import("../image.zig");

pub const Result = union(enum) {
    /// PNG bytes owned by the caller.
    png: []u8,
    no_tool,
    no_image,
    too_large,
};

/// A hung clipboard tool must not freeze the UI; its child is killed and the read counts as no image.
const timeout_ms = 2000;

const script =
    \\case "$(uname)" in
    \\  Darwin)
    \\    f=$(mktemp -t nibclip) || exit 1
    \\    osascript -e 'on run argv' -e 'set d to the clipboard as «class PNGf»' -e 'set f to open for access POSIX file (item 1 of argv) with write permission' -e 'set eof f to 0' -e 'write d to f' -e 'close access f' -e 'end run' "$f" >/dev/null 2>&1 && cat "$f"
    \\    status=$?
    \\    rm -f "$f"
    \\    exit $status ;;
    \\  *)
    \\    if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-paste >/dev/null 2>&1; then exec wl-paste --type image/png
    \\    elif command -v xclip >/dev/null 2>&1; then exec xclip -selection clipboard -t image/png -o
    \\    fi
    \\    exit 127 ;;
    \\esac
;

/// Tests only: replaces the system clipboard reader.
pub var reader_override: ?*const fn (std.mem.Allocator) Result = null;

pub fn readImage(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Result {
    if (reader_override) |read| return read(gpa);
    if (@import("builtin").os.tag == .windows) return .no_tool;
    const ran = std.process.run(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .environ_map = env,
        .stdout_limit = .limited(image.max_bytes + 1),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |err| switch (err) {
        error.StreamTooLong => return .too_large,
        error.Timeout => return .no_image,
        else => return err,
    };
    defer gpa.free(ran.stderr);
    const code: ?u8 = switch (ran.term) {
        .exited => |value| value,
        else => null,
    };
    if (code == 127) {
        gpa.free(ran.stdout);
        return .no_tool;
    }
    if (code != 0 or image.probe(ran.stdout) == null) {
        gpa.free(ran.stdout);
        return .no_image;
    }
    return .{ .png = ran.stdout };
}
