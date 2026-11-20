const std = @import("std");
const parse_mod = @import("config/parse.zig");
const resolve_mod = @import("config/resolve.zig");
const edit_mod = @import("config/edit.zig");
const Allocator = std.mem.Allocator;
const Env = std.process.Environ.Map;

pub const SkillSetting = parse_mod.SkillSetting;
pub const skillEnabled = parse_mod.skillEnabled;
pub const enabledSkills = parse_mod.enabledSkills;
pub const endpointIdProblem = parse_mod.endpointIdProblem;

pub const startup_order = resolve_mod.startup_order;
pub const load = resolve_mod.load;
pub const Custom = resolve_mod.Custom;
pub const customProviders = resolve_mod.customProviders;
pub const ModelEntry = resolve_mod.ModelEntry;
pub const modelEntries = resolve_mod.modelEntries;

pub const Endpoint = edit_mod.Endpoint;
pub const addEndpoint = edit_mod.addEndpoint;
pub const ModelSelection = edit_mod.ModelSelection;
pub const parseModel = edit_mod.parseModel;
pub const saveModel = edit_mod.saveModel;
pub const saveCodexFast = edit_mod.saveCodexFast;
pub const saveEffort = edit_mod.saveEffort;
pub const savePlugin = edit_mod.savePlugin;
pub const saveMcp = edit_mod.saveMcp;
pub const saveSkill = edit_mod.saveSkill;
pub const saveSimple = edit_mod.saveSimple;

pub fn home(a: Allocator, env: *const Env) ![]const u8 {
    if (env.get("NIB_HOME")) |value| return a.dupe(u8, value);
    return std.fs.path.join(a, &.{ env.get("HOME") orelse return error.MissingHome, ".nib" });
}

pub fn recordTools(env: ?*const Env) bool {
    const value = (if (env) |e| e.get("NIB_RECORD") else null) orelse return false;
    return !std.mem.eql(u8, value, "off");
}

// The caller supplies an arena for the parsed settings.
pub fn loadSkills(a: Allocator, io: std.Io, home_path: []const u8) ![]const SkillSetting {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try parse_mod.read(a, io, path);
    var detail: ?[]u8 = null;
    return (try parse_mod.parse(a, a, text, path, &detail)).skills.items;
}

pub fn loadMcp(a: Allocator, io: std.Io, home_path: []const u8) ![]const @import("mcp/config.zig").Server {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try parse_mod.read(a, io, path);
    var detail: ?[]u8 = null;
    return (try parse_mod.parse(a, a, text, path, &detail)).mcp_servers.items;
}

pub fn loadPlugins(a: Allocator, io: std.Io, home_path: []const u8) ![]const SkillSetting {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try parse_mod.read(a, io, path);
    var detail: ?[]u8 = null;
    return (try parse_mod.parse(a, a, text, path, &detail)).plugins.items;
}

test "NIB_HOME alone locates global data and absent configuration is empty" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/fictional");
    try env.put("XDG_CONFIG_HOME", "/unused");
    try env.put("XDG_DATA_HOME", "/unused");
    try t.expectEqualStrings("/fictional/.nib", try home(a, &env));
    try env.put("NIB_HOME", "/another");
    try t.expectEqualStrings("/another", try home(a, &env));
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/absent", .{tmp.sub_path});
    var detail: ?[]u8 = null;
    const cfg = try load(a, t.io, &env, root, &detail);
    try t.expectEqualStrings("gpt-6.2-sol", cfg.model);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "absent", .{}));
}

test "tool recording is opt-in and preserves explicit legacy values" {
    const t = std.testing;
    var env: Env = .init(t.allocator);
    defer env.deinit();
    try t.expect(!recordTools(null));
    try t.expect(!recordTools(&env));
    try env.put("NIB_RECORD", "off");
    try t.expect(!recordTools(&env));
    for ([_][]const u8{ "on", "", "1", "0", "true", "false", "OFF", "legacy" }) |value| {
        try env.put("NIB_RECORD", value);
        try t.expect(recordTools(&env));
    }
}

test {
    _ = parse_mod;
    _ = resolve_mod;
    _ = edit_mod;
}
