const std = @import("std");
const A = std.mem.Allocator;
const Skill = @import("../session/skills.zig").Skill;
const Server = @import("../mcp/config.zig").Server;
const V = std.json.Value;

pub const Package = struct {
    name: []const u8,
    root: []const u8,
    skills: []const Skill,
    servers: []const Server,
    unsupported: []const []const u8,

    pub fn skillCount(p: Package) usize {
        var count: usize = 0;
        for (p.skills) |s| {
            if (!s.command) count += 1;
        }
        return count;
    }
    pub fn commandCount(p: Package) usize {
        return p.skills.len - p.skillCount();
    }

    pub fn summary(p: Package, a: A) ![]const u8 {
        const skills = p.skillCount();
        const commands = p.commandCount();
        return std.fmt.allocPrint(a, "{d} skill{s} · {d} command{s} · {d} MCP server{s}", .{ skills, if (skills == 1) @as([]const u8, "") else "s", commands, if (commands == 1) @as([]const u8, "") else "s", p.servers.len, if (p.servers.len == 1) @as([]const u8, "") else "s" });
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 100 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

fn json(a: A, io: std.Io, file_path: []const u8) !V {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, file_path, a, .limited(1024 * 1024));
    return (try std.json.parseFromSlice(V, a, text, .{ .allocate = .alloc_always })).value;
}

fn field(v: V, key: []const u8) ?V {
    return if (v == .object) v.object.get(key) else null;
}
fn string(v: V) ![]const u8 {
    return if (v == .string) v.string else error.InvalidPluginManifest;
}

fn path(a: A, io: std.Io, root: []const u8, relative: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(relative)) return error.InvalidPluginPath;
    const resolved = try std.fs.path.resolve(a, &.{ root, relative });
    if (!std.mem.startsWith(u8, resolved, root) or resolved.len <= root.len or resolved[root.len] != '/') return error.InvalidPluginPath;
    const real = try std.Io.Dir.cwd().realPathFileAlloc(io, resolved, a);
    if (!std.mem.startsWith(u8, real, root) or real.len <= root.len or real[root.len] != '/') return error.InvalidPluginPath;
    return real;
}

const Loader = struct {
    a: A,
    io: std.Io,
    root: []const u8,
    name: []const u8,
    skills: std.ArrayList(Skill) = .empty,
    servers: std.ArrayList(Server) = .empty,
    unsupported: std.ArrayList([]const u8) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    mcp_files: std.StringHashMapUnmanaged(enum { loading, loaded }) = .empty,

    fn warn(l: *Loader, item: []const u8) !void {
        for (l.unsupported.items) |old| if (std.mem.eql(u8, old, item)) return;
        try l.unsupported.append(l.a, item);
    }

    fn addSkill(l: *Loader, file: []const u8, fallback: []const u8, command: bool) !void {
        if (l.seen.contains(file)) return;
        try l.seen.put(l.a, file, {});
        const text = try std.Io.Dir.cwd().readFileAlloc(l.io, file, l.a, .limited(64 * 1024));
        var skill = @import("../session/skills.zig").parse(l.a, text, fallback, file) catch |err| blk: {
            if (!command or (err != error.MissingFrontmatter and err != error.MissingDescription)) return err;
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
            break :blk Skill{ .name = fallback, .description = fallback, .location = file };
        };
        if (!validName(skill.name)) return error.InvalidPluginSkillName;
        skill.name = try std.fmt.allocPrint(l.a, "{s}:{s}", .{ l.name, skill.name });
        for (l.skills.items) |old| if (std.mem.eql(u8, old.name, skill.name)) return error.PluginSkillNameConflict;
        skill.plugin_root = l.root;
        skill.command = command;
        if (command) skill.disabled = true;
        try l.skills.append(l.a, skill);
        for ([_][]const u8{ "allowed-tools:", "context:", "agent:", "model:", "hooks:", "!`" }) |marker| {
            if (std.mem.indexOf(u8, text, marker) != null) try l.warn(try std.fmt.allocPrint(l.a, "{s}: {s}", .{ skill.name, marker }));
        }
    }

    fn scan(l: *Loader, relative: []const u8, command: bool, optional: bool) !void {
        const full = path(l.a, l.io, l.root, relative) catch |err| {
            if (optional and err == error.FileNotFound) return;
            return err;
        };
        const st = try std.Io.Dir.cwd().statFile(l.io, full, .{});
        if (st.kind == .file) {
            if (!command and std.mem.eql(u8, std.fs.path.basename(full), "SKILL.md")) return l.addSkill(full, std.fs.path.basename(std.fs.path.dirname(full).?), false);
            if (!command or !std.mem.endsWith(u8, full, ".md")) return error.InvalidPluginPath;
            return l.addSkill(full, std.fs.path.stem(full), true);
        }
        if (!command) {
            const own = try std.fs.path.join(l.a, &.{ relative, "SKILL.md" });
            const own_path = path(l.a, l.io, l.root, own) catch |err| blk: {
                if (err == error.FileNotFound) break :blk null;
                return err;
            };
            if (own_path) |file| return l.addSkill(file, std.fs.path.basename(full), false);
        }
        var dir = try std.Io.Dir.cwd().openDir(l.io, full, .{ .iterate = true });
        defer dir.close(l.io);
        var it = dir.iterate();
        var names: std.ArrayList([]const u8) = .empty;
        while (try it.next(l.io)) |entry| {
            if (entry.name[0] == '.') continue;
            if ((command and entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) or (!command and entry.kind == .directory)) try names.append(l.a, try l.a.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        for (names.items) |name| {
            const rel = if (command) try std.fs.path.join(l.a, &.{ relative, name }) else try std.fs.path.join(l.a, &.{ relative, name, "SKILL.md" });
            try l.addSkill(try path(l.a, l.io, l.root, rel), if (command) std.fs.path.stem(name) else name, command);
        }
    }

    fn paths(l: *Loader, value: V, command: bool) !void {
        switch (value) {
            .string => try l.scan(value.string, command, false),
            .array => for (value.array.items) |v| try l.scan(try string(v), command, false),
            else => try l.warn(if (command) "inline commands" else "inline skills"),
        }
    }

    fn expand(l: *Loader, text: []const u8) ![]const u8 {
        const result = try std.mem.replaceOwned(u8, l.a, text, "${CLAUDE_PLUGIN_ROOT}", l.root);
        if (std.mem.indexOf(u8, result, "${") != null) return error.UnsupportedPluginVariable;
        return result;
    }

    fn server(l: *Loader, name: []const u8, value: V) !void {
        if (!validName(name) or value != .object) return error.InvalidPluginMcp;
        var s: Server = .{ .id = try std.fmt.allocPrint(l.a, "{s}__{s}", .{ l.name, name }), .enabled = true };
        var fields = value.object.iterator();
        while (fields.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!std.mem.eql(u8, key, "command") and !std.mem.eql(u8, key, "args") and !std.mem.eql(u8, key, "url") and !std.mem.eql(u8, key, "type") and !std.mem.eql(u8, key, "env")) return error.UnsupportedPluginMcpField;
        }
        if (field(value, "type")) |t| {
            const kind = try string(t);
            if (!std.mem.eql(u8, kind, "stdio") and !std.mem.eql(u8, kind, "http")) return error.UnsupportedPluginMcpTransport;
            if (std.mem.eql(u8, kind, "http") != (field(value, "url") != null)) return error.InvalidPluginMcp;
        }
        if (field(value, "command")) |v| s.command = try l.expand(try string(v));
        if (field(value, "url")) |v| s.url = try l.expand(try string(v));
        if ((s.command == null) == (s.url == null)) return error.InvalidPluginMcp;
        if (s.command) |cmd| {
            if (cmd.len == 0 or cmd[0] == '-') return error.InvalidPluginMcp;
        }
        if (s.url) |url| {
            if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return error.InvalidPluginMcp;
        }
        if (field(value, "args")) |v| {
            if (v != .array or s.url != null) return error.InvalidPluginMcp;
            const args = try l.a.alloc([]const u8, v.array.items.len);
            for (v.array.items, args) |arg, *out| out.* = try l.expand(try string(arg));
            s.args = args;
        }
        if (field(value, "env")) |v| {
            if (v != .object or s.url != null) return error.InvalidPluginMcp;
            const bindings = try l.a.alloc(@import("../mcp/config.zig").EnvBinding, v.object.count());
            var it = v.object.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                if (!@import("../mcp/config.zig").envName(entry.key_ptr.*)) return error.InvalidPluginMcp;
                const template = try std.mem.replaceOwned(u8, l.a, try string(entry.value_ptr.*), "${CLAUDE_PLUGIN_ROOT}", l.root);
                try @import("../mcp/config.zig").validateTemplate(template);
                bindings[i] = .{ .name = entry.key_ptr.*, .value = template };
            }
            s.env_bindings = bindings;
        }
        for (l.servers.items) |old| if (std.mem.eql(u8, old.id, s.id)) return error.PluginMcpNameConflict;
        try l.servers.append(l.a, s);
    }

    fn mcp(l: *Loader, value: V, depth: usize) anyerror!void {
        if (depth > 16) return error.PluginMcpNesting;
        if (value == .string) {
            const full = try path(l.a, l.io, l.root, value.string);
            const entry = try l.mcp_files.getOrPut(l.a, full);
            if (entry.found_existing) return if (entry.value_ptr.* == .loaded) {} else error.PluginMcpNesting;
            entry.value_ptr.* = .loading;
            try l.mcp(try json(l.a, l.io, full), depth + 1);
            l.mcp_files.getPtr(full).?.* = .loaded;
            return;
        }
        if (value == .array) {
            for (value.array.items) |item| try l.mcp(item, depth + 1);
            return;
        }
        const servers = field(value, "mcpServers") orelse value;
        if (servers != .object) return error.InvalidPluginMcp;
        var it = servers.object.iterator();
        while (it.next()) |entry| l.server(entry.key_ptr.*, entry.value_ptr.*) catch |err| {
            if (err == error.OutOfMemory or err == error.PluginMcpNameConflict) return err;
            try l.warn(try std.fmt.allocPrint(l.a, "MCP {s}: {s}", .{ entry.key_ptr.*, @errorName(err) }));
        };
    }
};

pub fn load(a: A, io: std.Io, directory: []const u8) !Package {
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, directory, a);
    const manifest_path = try std.fs.path.join(a, &.{ root, ".claude-plugin", "plugin.json" });
    const manifest = try json(a, io, manifest_path);
    if (manifest != .object) return error.InvalidPluginManifest;
    const name = try string(field(manifest, "name") orelse return error.InvalidPluginManifest);
    if (!validName(name)) return error.InvalidPluginName;
    var l: Loader = .{ .a = a, .io = io, .root = root, .name = name };
    try l.scan("skills", false, true);
    try l.scan("commands", true, true);
    if (field(manifest, "skills")) |v| try l.paths(v, false);
    if (field(manifest, "commands")) |v| try l.paths(v, true);
    const mcp_path = try std.fs.path.join(a, &.{ root, ".mcp.json" });
    const mcp_value = json(a, io, mcp_path) catch |err| blk: {
        if (err == error.FileNotFound) break :blk null;
        return err;
    };
    if (mcp_value) |v| {
        try l.mcp_files.put(a, mcp_path, .loading);
        try l.mcp(v, 0);
        l.mcp_files.getPtr(mcp_path).?.* = .loaded;
    }
    if (field(manifest, "mcpServers")) |v| try l.mcp(v, 0);
    var fields = manifest.object.iterator();
    while (fields.next()) |entry| {
        const key = entry.key_ptr.*;
        const supported = for ([_][]const u8{ "$schema", "name", "version", "description", "author", "homepage", "repository", "license", "keywords", "metadata", "displayName", "icon", "documentationUrl", "supportUrl", "privacyPolicyUrl", "termsOfServiceUrl", "defaultEnabled", "skills", "commands", "mcpServers" }) |known| {
            if (std.mem.eql(u8, key, known)) break true;
        } else false;
        if (!supported) try l.warn(key);
    }
    for ([_][]const u8{ "agents", "hooks", ".lsp.json", "output-styles", "workflows", "themes", "monitors", "bin" }) |entry| {
        const candidate = try std.fs.path.join(a, &.{ root, entry });
        _ = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        try l.warn(entry);
    }
    return .{ .name = name, .root = root, .skills = l.skills.items, .servers = l.servers.items, .unsupported = l.unsupported.items };
}
