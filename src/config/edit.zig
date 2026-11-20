const mode = @import("../tui/mode.zig");
const std = @import("std");
const atomic_file = @import("../tools/atomic_file.zig");
const provider = @import("../provider.zig");
const auth = @import("../auth.zig");
const parse_mod = @import("parse.zig");
const resolve_mod = @import("resolve.zig");
const Allocator = std.mem.Allocator;
const Env = std.process.Environ.Map;

pub const Endpoint = struct { id: []const u8, protocol: provider.Protocol, base_url: []const u8, model: []const u8, context_window: u64 };

/// Appends a `[providers.<id>]` section; the key is never written here.
pub fn addEndpoint(a: Allocator, io: std.Io, home_path: []const u8, endpoint: Endpoint) !void {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try parse_mod.read(a, io, path);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, text);
    const newline = if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(a, newline);
    if (out.items.len > 0) try out.appendSlice(a, newline);
    try out.print(a, "[providers.{s}]{s}protocol = \"{s}\"{s}base_url = {f}{s}model = {f}{s}context_window = {d}{s}", .{
        endpoint.id,                          newline,
        @tagName(endpoint.protocol),          newline,
        std.json.fmt(endpoint.base_url, .{}), newline,
        std.json.fmt(endpoint.model, .{}),    newline,
        endpoint.context_window,              newline,
    });
    var detail: ?[]u8 = null;
    _ = try parse_mod.parse(a, a, out.items, path, &detail);
    try std.Io.Dir.cwd().createDirPath(io, home_path);
    _ = try atomic_file.replace(io, a, path, out.items, .{ .permissions = .fromMode(0o600), .sync = true });
}

pub const ModelSelection = struct { provider: []const u8, model: ?[]const u8 };

pub fn parseModel(arg: []const u8) !ModelSelection {
    var words = std.mem.tokenizeAny(u8, arg, " \t\n");
    const first = words.next() orelse return error.InvalidModelArgument;
    if (std.mem.indexOfScalar(u8, first, '/')) |slash| {
        if (slash == 0 or slash + 1 == first.len or words.next() != null) return error.InvalidModelArgument;
        return .{ .provider = first[0..slash], .model = first[slash + 1 ..] };
    }
    const model = words.next();
    if (words.next() != null) return error.InvalidModelArgument;
    return .{ .provider = first, .model = model };
}

fn rewriteValue(a: Allocator, text: []const u8, section: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var current: []const u8 = "";
    var found_section = section.len == 0;
    var inserted = false;
    var offset: usize = 0;
    const newline = if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
    while (offset < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, offset, '\n')) |i| i + 1 else text.len;
        const raw = text[offset..end];
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.startsWith(u8, line, "[")) {
            if (std.mem.eql(u8, current, section) and !inserted) {
                try out.print(a, "{s} = {f}{s}", .{ key, std.json.fmt(value, .{}), newline });
                inserted = true;
            }
            const close = std.mem.indexOfScalar(u8, line, ']').?;
            current = line[1..close];
            if (std.mem.eql(u8, current, section)) found_section = true;
        }
        if (std.mem.eql(u8, current, section)) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) {
                    const start = std.mem.indexOfScalar(u8, raw, '=').? + 1;
                    const vstart = start + raw[start..].len - std.mem.trimStart(u8, raw[start..], " \t").len;
                    var consumed: usize = 0;
                    var detail: ?[]u8 = null;
                    const parser: parse_mod.Parser = .{ .a = a, .diagnostics = a, .path = "config.toml", .detail = &detail, .line = 1 };
                    _ = try parser.value(raw[vstart..], &consumed);
                    try out.appendSlice(a, raw[0..vstart]);
                    try out.print(a, "{f}", .{std.json.fmt(value, .{})});
                    try out.appendSlice(a, raw[vstart + consumed ..]);
                    inserted = true;
                    offset = end;
                    continue;
                }
            }
        }
        try out.appendSlice(a, raw);
        offset = end;
    }
    if (!inserted) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(a, newline);
        if (!found_section) try out.print(a, "[{s}]{s}", .{ section, newline });
        try out.print(a, "{s} = {f}{s}", .{ key, std.json.fmt(value, .{}), newline });
    }
    return out.toOwnedSlice(a);
}

fn modelText(a: Allocator, text: []const u8, selection: ModelSelection) ![]u8 {
    var detail: ?[]u8 = null;
    _ = try parse_mod.parse(a, a, text, "config.toml", &detail);
    const top = try rewriteValue(a, text, "", "provider", selection.provider);
    if (selection.model) |model| {
        const builtin = std.meta.stringToEnum(provider.Id, selection.provider) != null;
        const section = if (builtin) selection.provider else try std.fmt.allocPrint(a, "providers.{s}", .{selection.provider});
        return rewriteValue(a, top, section, "model", model);
    }
    return top;
}

pub fn saveModel(a: Allocator, io: std.Io, env: *const Env, home_path: []const u8, selection: ModelSelection) !provider.Config {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try parse_mod.read(a, io, path);
    var selected_env = try env.clone(a);
    _ = selected_env.swapRemove("NIB_MODEL");
    try selected_env.put("NIB_PROVIDER", selection.provider);
    if (selection.model) |model| try selected_env.put("NIB_MODEL", model);
    var detail: ?[]u8 = null;
    var credentials = try auth.Lookup.init(a, io, env, home_path);
    defer credentials.deinit();
    const cfg = try resolve_mod.resolve(a, &selected_env, text, path, &detail, &credentials);
    if (cfg.provider == .chat_completions and !std.mem.eql(u8, cfg.model, provider.definition(.chat_completions).default_model) and env.get("NIB_CONTEXT_WINDOW") == null) {
        const file = try parse_mod.parse(a, a, text, path, &detail);
        if (file.chat_settings.context_window == null) return error.UnknownModelContextWindow;
    }
    const updated = try modelText(a, text, .{ .provider = selection.provider, .model = cfg.model });
    try std.Io.Dir.cwd().createDirPath(io, home_path);
    _ = try atomic_file.replace(io, a, path, updated, .{ .permissions = .fromMode(0o600), .sync = true });
    return cfg;
}

pub fn saveCodexFast(a: Allocator, io: std.Io, home_path: []const u8, enabled: bool) !void {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const tmp = scratch.allocator();
    const path = try std.fs.path.join(tmp, &.{ home_path, "config.toml" });
    const text = try parse_mod.read(tmp, io, path);
    var detail: ?[]u8 = null;
    const file = try parse_mod.parse(tmp, tmp, text, path, &detail);
    if (file.codex_fast == enabled) return;
    const value = if (enabled) "true" else "false";
    const newline = if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
    const updated = if (file.fast_value) |span|
        try std.fmt.allocPrint(tmp, "{s}{s}{s}", .{ text[0..span.start], value, text[span.end..] })
    else blk: {
        const start = file.codex_body_start orelse text.len;
        const separator = if (start > 0 and text[start - 1] != '\n') newline else "";
        const header = if (file.codex_body_start == null) "[codex]" else "";
        try std.Io.Dir.cwd().createDirPath(io, home_path);
        break :blk try std.fmt.allocPrint(tmp, "{s}{s}{s}{s}fast = {s}{s}{s}", .{ text[0..start], separator, header, if (header.len > 0) newline else "", value, newline, text[start..] });
    };
    _ = try atomic_file.replace(io, tmp, path, updated, .{ .permissions = .fromMode(0o600), .sync = true });
}

pub fn saveEffort(a: Allocator, io: std.Io, home_path: []const u8, value: []const u8) !void {
    const effort = parse_mod.knownEffort(value) orelse return error.InvalidReasoningEffort;
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    defer a.free(path);
    const text = try parse_mod.read(a, io, path);
    defer a.free(text);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const file = try parse_mod.parse(scratch.allocator(), a, text, path, &detail);
    const reset = std.mem.eql(u8, effort, "default");
    if (reset and file.effort_value == null) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    if (file.effort_value) |span| {
        if (reset) {
            const line = file.effort_line.?;
            const suffix = text[span.end..line.end];
            if (std.mem.indexOfScalar(u8, suffix, '#')) |hash| {
                const prefix = text[line.start..span.start];
                const indent = prefix.len - std.mem.trimStart(u8, prefix, " \t").len;
                try out.appendSlice(a, text[0 .. line.start + indent]);
                try out.appendSlice(a, suffix[hash..]);
            } else try out.appendSlice(a, text[0..line.start]);
            try out.appendSlice(a, text[line.end..]);
        } else {
            try out.appendSlice(a, text[0..span.start]);
            try out.print(a, "\"{s}\"", .{effort});
            try out.appendSlice(a, text[span.end..]);
        }
    } else {
        const newline = if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
        try out.appendSlice(a, text[0..file.top_end]);
        if (file.top_end > 0 and text[file.top_end - 1] != '\n') try out.appendSlice(a, newline);
        try out.print(a, "effort = \"{s}\"{s}", .{ effort, newline });
        try out.appendSlice(a, text[file.top_end..]);
    }
    if (std.mem.eql(u8, text, out.items)) return;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, home_path);
    _ = try atomic_file.replace(io, a, path, out.items, .{ .permissions = .fromMode(0o600), .sync = true });
}

pub fn savePlugin(a: Allocator, io: std.Io, home_path: []const u8, name: []const u8, enabled: bool) !void {
    return saveSwitch(a, io, home_path, name, enabled, .plugins);
}

pub fn saveMcp(a: Allocator, io: std.Io, home_path: []const u8, name: []const u8, enabled: bool) !void {
    return saveSwitch(a, io, home_path, name, enabled, .mcp);
}

pub fn saveSkill(a: Allocator, io: std.Io, home_path: []const u8, name: []const u8, enabled: bool) !void {
    return saveSwitch(a, io, home_path, name, enabled, .skills);
}

fn saveSwitch(a: Allocator, io: std.Io, home_path: []const u8, name: []const u8, enabled: bool, section: enum { skills, mcp, plugins }) !void {
    if (name.len == 0) return error.InvalidSkillName;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidSkillName;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const path = try std.fs.path.join(scratch, &.{ home_path, "config.toml" });
    const text = try parse_mod.read(scratch, io, path);
    var detail: ?[]u8 = null;
    const file = try parse_mod.parse(scratch, scratch, text, path, &detail);
    const value = if (enabled) "true" else "false";
    const newline = if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
    var out: std.ArrayList(u8) = .empty;
    const span: ?parse_mod.Span = for (switch (section) {
        .mcp => file.mcp.items,
        .skills => file.skills.items,
        .plugins => file.plugins.items,
    }) |setting| {
        if (std.mem.eql(u8, name, setting.name)) break setting.span;
    } else null;
    if (span) |range| {
        try out.appendSlice(scratch, text[0..range.start]);
        try out.appendSlice(scratch, value);
        try out.appendSlice(scratch, text[range.end..]);
    } else {
        const section_end = switch (section) {
            .mcp => file.mcp_end,
            .skills => file.skills_end,
            .plugins => file.plugins_end,
        };
        const end = section_end orelse text.len;
        try out.appendSlice(scratch, text[0..end]);
        if (end > 0 and text[end - 1] != '\n') try out.appendSlice(scratch, newline);
        if (section_end == null) try out.print(scratch, "[{s}]{s}", .{ @tagName(section), newline });
        try out.print(scratch, "{s} = {s}{s}", .{ name, value, newline });
        try out.appendSlice(scratch, text[end..]);
    }
    if (std.mem.eql(u8, text, out.items)) return;
    try std.Io.Dir.cwd().createDirPath(io, home_path);
    _ = try atomic_file.replace(io, scratch, path, out.items, .{ .permissions = .fromMode(0o600), .sync = true });
}

pub fn saveSimple(a: Allocator, io: std.Io, home_path: []const u8, simple: bool) !void {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    defer a.free(path);
    const text = try parse_mod.read(a, io, path);
    defer a.free(text);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const file = try parse_mod.parse(scratch.allocator(), a, text, path, &detail);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const value = if (simple) mode.value else "normal";
    if (file.ui_value) |span| {
        try out.appendSlice(a, text[0..span.start]);
        try out.print(a, "\"{s}\"", .{value});
        try out.appendSlice(a, text[span.end..]);
    } else {
        try out.print(a, "ui = \"{s}\"\n{s}", .{ value, text });
    }
    try std.Io.Dir.cwd().createDirPath(io, home_path);
    _ = try atomic_file.replace(io, a, path, out.items, .{ .permissions = .fromMode(0o600), .sync = true });
}

test "Codex Fast preference is scoped and preserves the config file" {
    const t = std.testing;
    var home_dir = t.tmpDir(.{});
    defer home_dir.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &home_dir.sub_path });
    const path = try std.fs.path.join(a, &.{ root, "config.toml" });
    try home_dir.dir.writeFile(t.io, .{ .sub_path = "config.toml", .data = "# header\r\n[codex] # keep\r\nmodel = \"gpt-6.1-terra\"\r\n[limits]\r\nmax_steps = 7\r\n" });
    try saveCodexFast(a, t.io, root, true);
    const text = try parse_mod.read(a, t.io, path);
    try t.expectEqualStrings("# header\r\n[codex] # keep\r\nfast = true\r\nmodel = \"gpt-6.1-terra\"\r\n[limits]\r\nmax_steps = 7\r\n", text);
    var detail: ?[]u8 = null;
    var env: Env = .init(a);
    const codex_cfg = try resolve_mod.resolve(a, &env, text, path, &detail, null);
    try t.expectEqualStrings("priority", codex_cfg.codexServiceTier().?);
    try env.put("NIB_PROVIDER", "openai");
    try t.expect(!(try resolve_mod.resolve(a, &env, text, path, &detail, null)).codex_fast);
    for ([_][]const u8{ "[codex]\nfast = \"true\"", "[codex]\nfast = true\nfast = false", "[chat_completions]\nfast = true" }) |invalid| {
        try t.expectError(error.InvalidConfig, parse_mod.parse(a, a, invalid, path, &detail));
    }
    try home_dir.dir.deleteFile(t.io, "config.toml");
    try saveCodexFast(a, t.io, root, true);
    try t.expectEqualStrings("[codex]\nfast = true\n", try parse_mod.read(a, t.io, path));
    try saveCodexFast(a, t.io, root, false);
    try t.expectEqualStrings("[codex]\nfast = false\n", try parse_mod.read(a, t.io, path));
}

test "effort writeback preserves surrounding bytes and inserts at top-level end" {
    const t = std.testing;
    const cases = [_]struct { before: []const u8, effort: []const u8, after: []const u8 }{
        .{ .before = "# first\n  effort  =  \"low\"  # keep\n\n[codex]\nmodel = \"gpt-6.1-sol\"\n", .effort = "high", .after = "# first\n  effort  =  \"high\"  # keep\n\n[codex]\nmodel = \"gpt-6.1-sol\"\n" },
        .{ .before = "# first\neffort = \"low\"\n[codex]\n", .effort = "default", .after = "# first\n[codex]\n" },
        .{ .before = "# first\n  effort = \"low\" # keep\n[codex]\n", .effort = "default", .after = "# first\n  # keep\n[codex]\n" },
        .{ .before = "# top\nprovider = \"codex\"\n\n[codex]\n# end", .effort = "medium", .after = "# top\nprovider = \"codex\"\n\neffort = \"medium\"\n[codex]\n# end" },
        .{ .before = "[codex]\n", .effort = "off", .after = "effort = \"off\"\n[codex]\n" },
        .{ .before = "[limits]\nmax_steps = 7 # keep\n", .effort = "off", .after = "effort = \"off\"\n[limits]\nmax_steps = 7 # keep\n" },
        .{ .before = "# only comment", .effort = "high", .after = "# only comment\neffort = \"high\"\n" },
        .{ .before = "# top\r\n[codex]\r\n", .effort = "high", .after = "# top\r\neffort = \"high\"\r\n[codex]\r\n" },
        .{ .before = "effort=\"low\"", .effort = "max", .after = "effort=\"max\"" },
        .{ .before = "# no setting\n[codex]\n", .effort = "default", .after = "# no setting\n[codex]\n" },
    };
    for (cases) |case| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer t.allocator.free(root);
        try tmp.dir.writeFile(t.io, .{ .sub_path = "config.toml", .data = case.before });
        try saveEffort(t.allocator, t.io, root, case.effort);
        const after = try tmp.dir.readFileAlloc(t.io, "config.toml", t.allocator, .unlimited);
        defer t.allocator.free(after);
        try t.expectEqualStrings(case.after, after);
    }
}

test "effort creates missing home and invalid files are left intact" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/new/home", .{tmp.sub_path});
    defer t.allocator.free(root);
    try saveEffort(t.allocator, t.io, root, "default");
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "new", .{}));
    try saveEffort(t.allocator, t.io, root, "high");
    const text = try tmp.dir.readFileAlloc(t.io, "new/home/config.toml", t.allocator, .unlimited);
    defer t.allocator.free(text);
    try t.expectEqualStrings("effort = \"high\"\n", text);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "new/home/config.toml", .data = "broken" });
    try t.expectError(error.InvalidConfig, saveEffort(t.allocator, t.io, root, "low"));
    const untouched = try tmp.dir.readFileAlloc(t.io, "new/home/config.toml", t.allocator, .unlimited);
    defer t.allocator.free(untouched);
    try t.expectEqualStrings("broken", untouched);
}

test "effort replacement preserves config symlink and permissions" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.toml", .data = "effort = \"low\"\n" });
    try tmp.dir.symLink(t.io, "settings.toml", "config.toml", .{});
    if (@import("builtin").os.tag != .windows) try tmp.dir.setFilePermissions(t.io, "settings.toml", .fromMode(0o640), .{});
    try saveEffort(t.allocator, t.io, root, "high");
    try t.expectEqual(std.Io.File.Kind.sym_link, (try tmp.dir.statFile(t.io, "config.toml", .{ .follow_symlinks = false })).kind);
    if (@import("builtin").os.tag != .windows) try t.expectEqual(@as(std.posix.mode_t, 0o640), (try tmp.dir.statFile(t.io, "settings.toml", .{})).permissions.toMode() & 0o7777);
    const text = try tmp.dir.readFileAlloc(t.io, "settings.toml", t.allocator, .unlimited);
    defer t.allocator.free(text);
    try t.expectEqualStrings("effort = \"high\"\n", text);
    var it = tmp.dir.iterate();
    while (try it.next(t.io)) |entry| try t.expect(!std.mem.startsWith(u8, entry.name, ".nib-"));
}

test "skills config booleans and atomic toggles preserve other lines" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const original = "# config\r\neffort = \"high\"\r\n[skills]\r\nhallmark = false # keep\r\n[codex]\r\nmodel = \"mock\"\r\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.toml", .data = original });
    try saveSkill(a, t.io, path, "hallmark", true);
    const changed = try tmp.dir.readFileAlloc(t.io, "config.toml", a, .unlimited);
    try t.expectEqualStrings(try std.mem.replaceOwned(u8, a, original, "false", "true"), changed);
    try saveSkill(a, t.io, path, "other", true);
    try saveSkill(a, t.io, path, "hallmark", false);
    const settings = try @import("../config.zig").loadSkills(a, t.io, path);
    try t.expect(!parse_mod.skillEnabled(settings, "hallmark"));
    try t.expect(parse_mod.skillEnabled(settings, "other"));
    try t.expect(!parse_mod.skillEnabled(settings, "absent"));
    var detail: ?[]u8 = null;
    try t.expectError(error.InvalidConfig, parse_mod.parse(a, a, "[skills]\na = \"true\"", "test", &detail));
    try t.expectError(error.InvalidConfig, parse_mod.parse(a, a, "[skills]\na = true\na = false", "test", &detail));
    try t.expectError(error.InvalidConfig, parse_mod.parse(a, a, "effort = true", "test", &detail));
    var env: Env = .init(a);
    defer env.deinit();
    const resolved = try resolve_mod.resolve(a, &env, "[skills]\non = true\noff = false", "test", &detail, null);
    try t.expectEqual(@as(usize, 1), resolved.enabled_skills.len);
    try t.expectEqualStrings("on", resolved.enabled_skills[0]);
}

test "model arguments and configuration preserve comments and sections" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("openai", (try parseModel("openai/gpt-test")).provider);
    try t.expectEqualStrings("gpt-test", (try parseModel("openai gpt-test")).model.?);
    try t.expect((try parseModel("openai")).model == null);
    for ([_][]const u8{ "", "/model", "openai/", "openai a b" }) |arg| try t.expectError(error.InvalidModelArgument, parseModel(arg));
    const text = "# header\nprovider = \"codex\" # keep\n[openai] # section\nmodel = \"old\" # model\n[skills]\nx = true\n";
    const updated = try modelText(a, text, .{ .provider = "openai", .model = "new" });
    try t.expectEqualStrings("# header\nprovider = \"openai\" # keep\n[openai] # section\nmodel = \"new\" # model\n[skills]\nx = true\n", updated);
    try t.expectEqualStrings("provider = \"openai\"\n[openai]\nmodel = \"new\"\n", try modelText(a, "", .{ .provider = "openai", .model = "new" }));
    const custom = "[providers.local]\nprotocol = \"responses\"\nbase_url = \"http://localhost\"\nmodel = \"old\" # keep\ncontext_window = 1000\n";
    const changed = try modelText(a, custom, .{ .provider = "local", .model = "new" });
    try t.expect(std.mem.indexOf(u8, changed, "model = \"new\" # keep") != null);
    try t.expect(std.mem.indexOf(u8, changed, "[providers.local]") != null);
}

test "model entries include configured services and saving is atomic" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var env: Env = .init(a);
    try env.put("HOME", root);
    try env.put("CODEX_HOME", root);
    const custom = "[providers.local]\nprotocol = \"responses\"\nbase_url = \"http://localhost\"\nmodel = \"old\"\ncontext_window = 1000\n[providers.locked]\nprotocol = \"responses\"\nbase_url = \"http://localhost\"\nmodel = \"old\"\ncontext_window = 1000\napi_key_env = \"SITE_KEY\"\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.toml", .data = custom });
    var detail: ?[]u8 = null;
    var anthropic_env = try env.clone(a);
    try anthropic_env.put("NIB_PROVIDER", "anthropic");
    const anthropic = try resolve_mod.resolve(a, &anthropic_env, custom, "config.toml", &detail, null);
    const own = try resolve_mod.modelEntries(a, t.io, &env, root, anthropic);
    try t.expectEqual(@as(usize, 6), own.len);
    try t.expectEqualStrings("local", own[4].provider);
    try t.expectEqualStrings("locked", own[5].provider);
    var local_env = try env.clone(a);
    try local_env.put("NIB_PROVIDER", "local");
    const local = try resolve_mod.resolve(a, &local_env, custom, "config.toml", &detail, null);
    const listed = try resolve_mod.modelEntries(a, t.io, &env, root, local);
    try t.expectEqual(@as(usize, 2), listed.len);
    try t.expectEqualStrings("old", listed[0].model);
    _ = try saveModel(a, t.io, &env, root, .{ .provider = "local", .model = "new" });
    const saved = try tmp.dir.readFileAlloc(t.io, "config.toml", a, .unlimited);
    try t.expect(std.mem.startsWith(u8, saved, "provider = \"local\"\n"));
    try t.expect(std.mem.indexOf(u8, saved, "model = \"new\"") != null);
    try t.expect(std.mem.indexOf(u8, saved, "[providers.locked]") != null);
    try env.put("OPENAI_API_KEY", "fake");
    try t.expectError(error.InvalidConfig, saveModel(a, t.io, &env, root, .{ .provider = "openai", .model = "unknown" }));
    try t.expectEqualStrings(saved, try tmp.dir.readFileAlloc(t.io, "config.toml", a, .unlimited));
    const new_home = try std.fs.path.join(a, &.{ root, "new" });
    _ = try saveModel(a, t.io, &env, new_home, .{ .provider = "openai", .model = null });
    try t.expectEqualStrings("provider = \"openai\"\n[openai]\nmodel = \"gpt-6.2-sol\"\n", try tmp.dir.readFileAlloc(t.io, "new/config.toml", a, .unlimited));
}

test "legacy chat_completions keeps its identity and ordered keys when switching and signing out" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var env = try resolve_mod.envWithHome(a, root);
    try auth.setKey(a, t.io, root, "chat_completions", "stored-legacy");
    try env.put("NIB_API_KEY", "legacy-env");
    try env.put("DEEPSEEK_API_KEY", "deepseek-env");

    const switched = try saveModel(a, t.io, &env, root, .{ .provider = "chat_completions", .model = null });
    try t.expectEqual(provider.Id.chat_completions, switched.provider);
    try t.expectEqualStrings("legacy-env", switched.api_key);
    try t.expectEqualStrings("key from NIB_API_KEY", auth.describe(a, t.io, switched));
    const removed = try auth.signOut(a, t.io, &env, root, "chat_completions");
    try t.expect(removed.removed);
    try t.expectEqualStrings("NIB_API_KEY", removed.env_name.?);

    var detail: ?[]u8 = null;
    const startup = try resolve_mod.load(a, t.io, &env, root, &detail);
    try t.expectEqual(provider.Id.chat_completions, startup.provider);
    try t.expectEqualStrings(switched.api_key, startup.api_key);
    try env.put("NIB_API_KEY", "");
    const fallback = try resolve_mod.load(a, t.io, &env, root, &detail);
    try t.expectEqual(provider.Id.chat_completions, fallback.provider);
    try t.expectEqualStrings("deepseek-env", fallback.api_key);
    try t.expectEqualStrings("key from DEEPSEEK_API_KEY", auth.describe(a, t.io, fallback));
}

test "adding an endpoint appends one section and validates ids" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.toml", .data = "# keep\neffort = \"high\"" });
    try addEndpoint(a, t.io, root, .{ .id = "my-site", .protocol = .chat_completions, .base_url = "https://x.example/v1", .model = "m\"1", .context_window = 128000 });
    const text = try tmp.dir.readFileAlloc(t.io, "config.toml", a, .unlimited);
    try t.expect(std.mem.startsWith(u8, text, "# keep\neffort = \"high\"\n\n[providers.my-site]\nprotocol = \"chat_completions\"\n"));
    const found = try resolve_mod.customProviders(a, t.io, root);
    try t.expectEqual(@as(usize, 1), found.len);
    try t.expectEqualStrings("m\"1", found[0].model);
    try t.expectError(error.InvalidConfig, addEndpoint(a, t.io, root, .{ .id = "my-site", .protocol = .responses, .base_url = "http://h", .model = "m", .context_window = 1 }));
    try t.expectEqualStrings(text, try tmp.dir.readFileAlloc(t.io, "config.toml", a, .unlimited));
    try t.expect(parse_mod.endpointIdProblem("", &.{}) != null);
    try t.expect(parse_mod.endpointIdProblem("a b", &.{}) != null);
    try t.expect(parse_mod.endpointIdProblem("openai", &.{}) != null);
    try t.expect(parse_mod.endpointIdProblem("custom", &.{}) != null);
    try t.expect(parse_mod.endpointIdProblem("my-site", &.{"my-site"}) != null);
    try t.expect(parse_mod.endpointIdProblem("ok_1", &.{"other"}) == null);
}

test "MCP atomic toggles preserve nested definitions and CRLF comments" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home_path = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.toml", .data = "[mcp]\r\nx = false # keep\r\n[mcp.x]\r\ncommand = \"server\"\r\n" });
    try saveMcp(a, t.io, home_path, "x", true);
    try t.expectEqualStrings("[mcp]\r\nx = true # keep\r\n[mcp.x]\r\ncommand = \"server\"\r\n", try tmp.dir.readFileAlloc(t.io, "config.toml", a, .limited(10000)));
    try saveMcp(a, t.io, home_path, "new", false);
    try t.expect((try @import("../config.zig").loadMcp(a, t.io, home_path))[0].enabled);
}

test "simple persistence preserves surrounding configuration and rejects invalid values" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.toml", .data = "# keep\n[codex]\n" });
    var env: Env = .init(a);
    defer env.deinit();
    var detail: ?[]u8 = null;
    for ([_]bool{ true, false, true }) |simple| {
        try saveSimple(a, t.io, root, simple);
        const text = try tmp.dir.readFileAlloc(t.io, "config.toml", a, .limited(10000));
        try t.expect(std.mem.endsWith(u8, text, "# keep\n[codex]\n"));
        try t.expectEqual(simple, (try resolve_mod.resolve(a, &env, text, "test", &detail, null)).simple);
    }
    for ([_][]const u8{ "ui = true", "ui = \"bad\"", "ui = \"normal\"\nui = \"simple\"" }) |text| try t.expectError(error.InvalidConfig, parse_mod.parse(a, a, text, "test", &detail));
}

test "plugin switches default off and preserve independent skill and MCP settings" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.toml", .data = "# retained\n[skills]\nexample = true\n[mcp]\nlocal = false\n" });
    const config_mod = @import("../config.zig");
    try t.expectEqual(@as(usize, 0), (try config_mod.loadPlugins(a, t.io, path)).len);
    try savePlugin(a, t.io, path, "example", true);
    try savePlugin(a, t.io, path, "other", false);
    try t.expect(parse_mod.skillEnabled(try config_mod.loadPlugins(a, t.io, path), "example"));
    try t.expect(parse_mod.skillEnabled(try config_mod.loadSkills(a, t.io, path), "example"));
    try savePlugin(a, t.io, path, "example", false);
    try t.expect(!parse_mod.skillEnabled(try config_mod.loadPlugins(a, t.io, path), "example"));
    try t.expectError(error.InvalidSkillName, savePlugin(a, t.io, path, "../bad", true));
    const text = try tmp.dir.readFileAlloc(t.io, "config.toml", a, .limited(4096));
    try t.expect(std.mem.startsWith(u8, text, "# retained\n[skills]\nexample = true\n[mcp]\nlocal = false\n"));
}
