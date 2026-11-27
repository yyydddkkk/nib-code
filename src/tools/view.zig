const std = @import("std");
const sandbox = @import("../sandbox.zig");
const tools = @import("../tools.zig");
const image = @import("../image.zig");
const Tools = tools.Tools;
const fail = tools.fail;

fn refuse(gpa: std.mem.Allocator, message: []const u8) !sandbox.ToolResult {
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = false, .@"error" = message }, .{}) };
}

pub fn view(t: *Tools, gpa: std.mem.Allocator, args: []const u8) !sandbox.ToolResult {
    const A = struct { path: []const u8 };
    const a = std.json.parseFromSlice(A, gpa, args, .{ .ignore_unknown_fields = true }) catch
        return fail(gpa, "expected {{ path: string }}", .{});
    defer a.deinit();

    if (t.cfg) |cfg| if (!cfg.vision()) return refuse(gpa, "the current model does not support image input");
    const data_home = t.data_home orelse return refuse(gpa, "image storage is unavailable");
    const session_id = t.session_id orelse return refuse(gpa, "image storage is unavailable");
    const path = try t.resolveRunPath(gpa, a.value.path);
    defer gpa.free(path);
    try t.checkCredentialPath(gpa, path);
    if (t.viewedImages() >= image.max_per_run)
        return refuse(gpa, std.fmt.comptimePrint("at most {d} images per Run", .{image.max_per_run}));

    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(t.io, path, .{}) catch |err| return refuse(gpa, image.rejection(err));
    if (stat.kind != .file) return refuse(gpa, "not a file");
    if (stat.size > image.max_bytes) return refuse(gpa, image.rejection(error.ImageTooLarge));
    const data = cwd.readFileAlloc(t.io, path, gpa, .limited(image.max_bytes)) catch |err| return refuse(gpa, image.rejection(err));
    defer gpa.free(data);

    const directory = try std.fmt.allocPrint(gpa, "{s}/sessions/{s}.images", .{ data_home, session_id });
    defer gpa.free(directory);
    const stored = image.store(t.io, gpa, directory, a.value.path, data) catch |err| return refuse(gpa, image.rejection(err));
    errdefer stored.deinit(gpa);
    if (!try t.attachImage(gpa, stored)) {
        stored.deinit(gpa);
        return refuse(gpa, std.fmt.comptimePrint("at most {d} images per Run", .{image.max_per_run}));
    }
    return .{ .ok = try std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .path = a.value.path, .width = stored.width, .height = stored.height, .bytes = stored.bytes }, .{}) };
}

const testing = std.testing;

const tiny_png = image.sample_png;

fn expectJson(result: sandbox.ToolResult, needle: []const u8) !void {
    defer tools.freeResult(result);
    try testing.expect(result == .ok);
    try testing.expect(std.mem.indexOf(u8, result.ok, needle) != null);
}

test "view returns metadata and attaches the stored image to the Run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shot.png", .data = tiny_png });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.png", .data = "not an image" });
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    var t: Tools = .{ .io = testing.io, .home = root, .data_home = root, .session_id = "abc" };
    defer tools.clearImages(&t.images, testing.allocator);
    defer t.file_state.deinit(testing.allocator);
    defer t.progress.deinit(testing.allocator);
    const good = try std.fmt.allocPrint(testing.allocator, "{{\"path\":\"{s}/shot.png\"}}", .{root});
    defer testing.allocator.free(good);
    try expectJson(Tools.call(&t, testing.allocator, "view", good), "\"width\":640,\"height\":480,\"bytes\":" ++ std.fmt.comptimePrint("{d}", .{tiny_png.len}));
    try testing.expectEqual(@as(usize, 1), t.images.items.len);
    try testing.expectEqualStrings("image/png", t.images.items[0].media_type);
    const bad = try std.fmt.allocPrint(testing.allocator, "{{\"path\":\"{s}/notes.png\"}}", .{root});
    defer testing.allocator.free(bad);
    try expectJson(Tools.call(&t, testing.allocator, "view", bad), "\"ok\":false,\"error\":\"unsupported image");
    try expectJson(Tools.call(&t, testing.allocator, "view", "{\"path\":\"missing.png\"}"), "\"error\":\"file not found\"");
    try testing.expectEqual(@as(usize, 1), t.images.items.len);
    for (0..image.max_per_run) |_| {
        const result = Tools.call(&t, testing.allocator, "view", good);
        tools.freeResult(result);
    }
    try testing.expectEqual(@as(usize, image.max_per_run), t.images.items.len);
    try expectJson(Tools.call(&t, testing.allocator, "view", good), "at most 4 images per Run");
}

test "view refuses models without vision and rejects bad arguments" {
    var t: Tools = .{ .io = testing.io, .home = "/unused", .data_home = "/unused", .session_id = "abc", .cfg = .{ .provider = .deepseek, .base_url = "", .api_key = "", .model = "deepseek-flash" } };
    defer t.file_state.deinit(testing.allocator);
    defer t.progress.deinit(testing.allocator);
    try expectJson(Tools.call(&t, testing.allocator, "view", "{\"path\":\"a.png\"}"), "does not support image input");
    const result = Tools.call(&t, testing.allocator, "view", "{}");
    defer tools.freeResult(result);
    try testing.expect(result == .err);
}
