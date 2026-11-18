//! Credentials: where each service's key or login comes from, and what the UI says about it.
//! Precedence: environment key, then nib's `auth.json`, then (Codex only) the Codex CLI login.
//! Keys never leave this module in text meant for people.

const std = @import("std");
const provider = @import("provider.zig");
const config = @import("config.zig");
pub const store = @import("auth/store.zig");
pub const oauth = @import("auth/oauth.zig");
pub const codex = @import("auth/codex.zig");
pub const login = @import("auth/login.zig");
pub const models = @import("auth/models.zig");

const Env = std.process.Environ.Map;

pub const Service = struct {
    id: []const u8,
    name: []const u8,
    custom: bool,
    /// Requests can be sent now.
    signed_in: bool,
    /// nib itself holds a key or login that sign-out would remove.
    stored: bool,
    status: []const u8,
};

pub fn codexLocations(env: *const Env, nib_home: ?[]const u8, a: std.mem.Allocator) !codex.Locations {
    const codex_home = env.get("CODEX_HOME") orelse try std.fs.path.join(a, &.{ env.get("HOME") orelse "", ".codex" });
    return .{ .nib_home = nib_home, .codex_home = codex_home, .issuer = env.get("NIB_AUTH_ISSUER") };
}

/// No key or token values are carried in credential status.
pub const Source = union(enum) {
    missing,
    env: ?[]const u8,
    store,
    key,
    codex: struct { source: codex.Source, plan: ?[]const u8 },
    no_key,

    pub fn available(source: Source) bool {
        return source != .missing;
    }
};

pub const State = struct {
    source: Source,
    /// A saved key can coexist with an effective environment key.
    stored: bool,
};

fn codexSource(a: std.mem.Allocator, io: std.Io, locations: codex.Locations) Source {
    var l = codex.load(a, io, locations) catch return .missing;
    defer l.deinit();
    return .{ .codex = .{ .source = l.source, .plan = if (l.plan) |plan| a.dupe(u8, plan) catch null else null } };
}

fn keySource(id: provider.Id, env_name: ?[]const u8, has_key: bool, source: provider.KeySource) Source {
    if (has_key) return switch (source) {
        .env => .{ .env = env_name },
        .store => .store,
        .none => .key,
    };
    return if (id == .custom and env_name == null) .no_key else .missing;
}

const Key = struct {
    env_name: ?[]const u8,
    value: ?[]const u8,
    source: provider.KeySource,
    stored: bool,
};

/// A short-lived view of the real environment and nib's store, shared across a selection pass.
pub const Lookup = struct {
    env: *const Env,
    home: ?[]const u8 = null,
    doc: ?store.Doc = null,

    pub fn init(a: std.mem.Allocator, io: std.Io, env: *const Env, home: []const u8) !Lookup {
        const file = try store.path(a, home);
        defer a.free(file);
        return .{ .env = env, .home = home, .doc = store.Doc.load(a, io, file) catch null };
    }

    pub fn deinit(lookup: *Lookup) void {
        if (lookup.doc) |*doc| doc.deinit();
    }

    fn key(lookup: *Lookup, id: provider.Id, name: []const u8, custom_env: ?[]const u8) Key {
        const names = if (id != .custom) provider.definition(id).api_key_env else if (custom_env) |variable| &.{variable} else &.{};
        const saved = if (lookup.doc) |*doc| doc.key(name) else null;
        for (names) |variable| {
            const value = lookup.env.get(variable) orelse continue;
            if (value.len > 0) return .{ .env_name = variable, .value = value, .source = .env, .stored = saved != null };
        }
        return .{ .env_name = if (names.len > 0) names[0] else null, .value = saved, .source = if (saved != null) .store else .none, .stored = saved != null };
    }

    pub fn inspect(lookup: *Lookup, a: std.mem.Allocator, io: std.Io, id: provider.Id, name: []const u8, custom_env: ?[]const u8) !State {
        if (id == .codex) {
            var scratch: std.heap.ArenaAllocator = .init(a);
            defer scratch.deinit();
            const source = codexSource(a, io, try codexLocations(lookup.env, lookup.home, scratch.allocator()));
            return .{ .source = source, .stored = source == .codex and source.codex.source == .nib };
        }
        const picked = lookup.key(id, name, custom_env);
        return .{ .source = keySource(id, picked.env_name, picked.value != null, picked.source), .stored = picked.stored };
    }

    /// Only request configuration gets a credential value. Codex loads tokens on demand.
    pub fn apply(lookup: *Lookup, a: std.mem.Allocator, cfg: *provider.Config) !void {
        var scratch: std.heap.ArenaAllocator = .init(a);
        defer scratch.deinit();
        const loc = try codexLocations(lookup.env, lookup.home, scratch.allocator());
        cfg.nib_home = if (loc.nib_home) |dir| try a.dupe(u8, dir) else null;
        cfg.codex_home = if (loc.codex_home) |dir| try a.dupe(u8, dir) else null;
        cfg.auth_issuer = if (loc.issuer) |url| try a.dupe(u8, url) else null;
        if (cfg.provider == .codex) return;
        // A child can carry a direct key without an environment name.
        if (cfg.api_key.len > 0 and cfg.api_key_env == null) return;
        const picked = lookup.key(cfg.provider, cfg.name(), cfg.api_key_env);
        cfg.api_key_env = if (picked.env_name) |name| try a.dupe(u8, name) else null;
        cfg.api_key = if (picked.value) |value| try a.dupe(u8, value) else "";
        cfg.key_source = picked.source;
    }
};

/// Availability of the effective request configuration, not a fresh lookup of its API key.
pub fn current(a: std.mem.Allocator, io: std.Io, cfg: provider.Config) Source {
    if (cfg.provider == .codex) return codexSource(a, io, .{ .nib_home = cfg.nib_home, .codex_home = cfg.codex_home, .issuer = cfg.auth_issuer });
    return keySource(cfg.provider, cfg.api_key_env, cfg.api_key.len > 0, cfg.key_source);
}

fn host(base_url: []const u8) []const u8 {
    const rest = if (std.mem.indexOf(u8, base_url, "://")) |i| base_url[i + 3 ..] else base_url;
    const authority = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    return if (std.mem.lastIndexOfScalar(u8, authority, '@')) |i| authority[i + 1 ..] else authority;
}

/// Built-in services in menu order, then custom ones. Everything is allocated with `a`.
pub fn services(a: std.mem.Allocator, io: std.Io, env: *const Env, home: []const u8) ![]const Service {
    var lookup = try Lookup.init(a, io, env, home);
    defer lookup.deinit();
    var out: std.ArrayList(Service) = .empty;
    for (config.startup_order) |id| {
        const kind = std.meta.stringToEnum(provider.Id, id).?;
        const entry = provider.definition(kind);
        const state = try lookup.inspect(a, io, kind, id, null);
        const status = switch (state.source) {
            .codex => |l| blk: {
                var buf: [64]u8 = undefined;
                break :blk try std.fmt.allocPrint(a, "signed in · {s}", .{oauth.planLabel(&buf, l.plan)});
            },
            .env => |name| name orelse "environment",
            .store => "key stored",
            else => "—",
        };
        try out.append(a, .{ .id = id, .name = entry.name, .custom = false, .signed_in = state.source.available(), .stored = state.stored, .status = status });
    }
    for (try config.customProviders(a, io, home)) |item| {
        const state = try lookup.inspect(a, io, .custom, item.id, item.api_key_env);
        try out.append(a, .{
            .id = item.id,
            .name = item.id,
            .custom = true,
            .signed_in = state.source.available(),
            .stored = state.stored,
            .status = if (state.source.available()) host(item.base_url) else try std.fmt.allocPrint(a, "{s} · no key", .{host(item.base_url)}),
        });
    }
    return out.toOwnedSlice(a);
}

pub fn find(list: []const Service, id: []const u8) ?Service {
    for (list) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}

/// One line for /status; never contains a key.
pub fn describe(a: std.mem.Allocator, io: std.Io, cfg: provider.Config) []const u8 {
    return switch (current(a, io, cfg)) {
        .codex => |l| if (l.source == .nib) "ChatGPT login stored by nib" else "ChatGPT login from the Codex CLI",
        .env => |name| std.fmt.allocPrint(a, "key from {s}", .{name orelse "environment"}) catch "key from environment",
        .store => "key stored by nib",
        .key => "API key",
        .no_key => "no key needed",
        .missing => if (cfg.provider == .codex) "not signed in" else "no key",
    };
}

pub fn setKey(a: std.mem.Allocator, io: std.Io, home: []const u8, id: []const u8, key: []const u8) !void {
    const file = try store.path(a, home);
    defer a.free(file);
    var doc: store.Doc = try .load(a, io, file);
    defer doc.deinit();
    try doc.setKey(id, key);
    try doc.saveSecret(io, a, file);
}

pub const Signout = struct {
    /// nib's own credential was removed.
    removed: bool,
    /// A key still comes from this environment variable.
    env_name: ?[]const u8 = null,
    /// A Codex CLI login still exists.
    cli_login: bool = false,
};

pub fn signOut(a: std.mem.Allocator, io: std.Io, env: *const Env, home: []const u8, id: []const u8) !Signout {
    const kind = std.meta.stringToEnum(provider.Id, id) orelse .custom;
    var lookup: Lookup = .{ .env = env, .home = home };
    if (kind == .codex) {
        const removed = try codex.remove(a, io, home);
        const remaining = try lookup.inspect(a, io, kind, id, null);
        return .{ .removed = removed, .cli_login = remaining.source == .codex and remaining.source.codex.source == .cli };
    }
    const file = try store.path(a, home);
    defer a.free(file);
    var doc: store.Doc = try .load(a, io, file);
    defer doc.deinit();
    const removed = doc.removeKey(id);
    if (removed) try doc.saveSecret(io, a, file);
    const custom_env = if (kind == .custom) for (config.customProviders(a, io, home) catch &.{}) |item| {
        if (std.mem.eql(u8, item.id, id)) break item.api_key_env;
    } else null else null;
    const remaining = try lookup.inspect(a, io, kind, id, custom_env);
    return .{ .removed = removed, .env_name = if (remaining.source == .env) remaining.source.env else null };
}

/// The confirmation after signing out; `out` says what is left behind.
pub fn signOutText(a: std.mem.Allocator, name: []const u8, out: Signout) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.print(a, "{s} · {s}", .{ name, if (out.removed) "signed out" else "nothing stored by nib" });
    if (out.env_name) |env_name| try text.print(a, " · key still set in {s}", .{env_name});
    if (out.cli_login) try text.appendSlice(a, " · Codex CLI login kept");
    return text.toOwnedSlice(a);
}

pub fn knownService(list: []const Service, id: []const u8) bool {
    return find(list, id) != null;
}

const testing = std.testing;

test "service status names sources and never keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var env: Env = .init(a);
    try env.put("HOME", root);
    try env.put("CODEX_HOME", try std.fs.path.join(a, &.{ root, "codex" }));
    try env.put("ANTHROPIC_API_KEY", "secret-env-value");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "auth.json", .data = "{\"keys\":{\"deepseek\":\"secret-stored-value\",\"site\":\"secret-site\"}}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.toml", .data = "[providers.site]\nprotocol = \"responses\"\nbase_url = \"https://models.example.com/v1\"\nmodel = \"m\"\ncontext_window = 9\napi_key_env = \"SITE_KEY\"\n[providers.local]\nprotocol = \"responses\"\nbase_url = \"http://localhost:8080\"\nmodel = \"m\"\ncontext_window = 9\n[providers.gated]\nprotocol = \"responses\"\nbase_url = \"http://gated.test\"\nmodel = \"m\"\ncontext_window = 9\napi_key_env = \"GATED_KEY\"\n" });
    const list = try services(a, testing.io, &env, root);
    const expected = [_][2][]const u8{
        .{ "codex", "—" },
        .{ "anthropic", "ANTHROPIC_API_KEY" },
        .{ "openai", "—" },
        .{ "deepseek", "key stored" },
        .{ "xai", "—" },
        .{ "site", "models.example.com" },
        .{ "local", "localhost:8080" },
        .{ "gated", "gated.test · no key" },
    };
    try testing.expectEqual(expected.len, list.len);
    for (expected, list) |want, got| {
        try testing.expectEqualStrings(want[0], got.id);
        try testing.expectEqualStrings(want[1], got.status);
        try testing.expect(std.mem.indexOf(u8, got.status, "secret") == null);
    }
    try testing.expect(!list[0].signed_in and list[1].signed_in and !list[2].signed_in and list[3].stored and list[5].stored);
    try testing.expect(list[6].signed_in and !list[7].signed_in);
    try tmp.dir.createDirPath(testing.io, "codex");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "codex/auth.json", .data = "{\"tokens\":{\"access_token\":\"a\",\"account_id\":\"b\"}}" });
    const with_codex = try services(a, testing.io, &env, root);
    try testing.expectEqualStrings("signed in · ChatGPT", with_codex[0].status);
    try testing.expect(with_codex[0].signed_in and !with_codex[0].stored);
}

test "sign out removes only nib's credential and reports the rest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var env: Env = .init(a);
    try env.put("HOME", root);
    try env.put("CODEX_HOME", try std.fs.path.join(a, &.{ root, "codex" }));
    try env.put("OPENAI_API_KEY", "env-fake");
    try setKey(a, testing.io, root, "openai", "stored-fake");
    try setKey(a, testing.io, root, "xai", "stored-fake");
    var out = try signOut(a, testing.io, &env, root, "openai");
    try testing.expect(out.removed);
    try testing.expectEqualStrings("OPENAI_API_KEY", out.env_name.?);
    out = try signOut(a, testing.io, &env, root, "openai");
    try testing.expect(!out.removed);
    out = try signOut(a, testing.io, &env, root, "xai");
    try testing.expect(out.removed and out.env_name == null);
    try tmp.dir.createDirPath(testing.io, "codex");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "codex/auth.json", .data = "{\"tokens\":{\"access_token\":\"a\",\"account_id\":\"b\"}}" });
    out = try signOut(a, testing.io, &env, root, "codex");
    try testing.expect(!out.removed and out.cli_login);
    const cli_file = try tmp.dir.readFileAlloc(testing.io, "codex/auth.json", a, .unlimited);
    try testing.expect(cli_file.len > 0);
}

test "describe names the credential source" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: provider.Config = .{ .provider = .anthropic, .base_url = "", .api_key = "k", .model = "m", .key_source = .env, .api_key_env = "ANTHROPIC_API_KEY" };
    try testing.expectEqualStrings("key from ANTHROPIC_API_KEY", describe(a, testing.io, cfg));
    cfg.key_source = .store;
    try testing.expectEqualStrings("key stored by nib", describe(a, testing.io, cfg));
    cfg.key_source = .none;
    cfg.api_key = "";
    try testing.expectEqualStrings("no key", describe(a, testing.io, cfg));
}
