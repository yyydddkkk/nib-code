const mode = @import("tui/mode.zig");
const std = @import("std");
const atomic_file = @import("tools/atomic_file.zig");
const provider = @import("provider.zig");
const codex = @import("provider/responses.zig");
const auth_store = @import("auth/store.zig");
const auth_codex = @import("auth/codex.zig");
const Allocator = std.mem.Allocator;
const Env = std.process.Environ.Map;

pub fn home(a: Allocator, env: *const Env) ![]const u8 {
    if (env.get("NIB_HOME")) |value| return a.dupe(u8, value);
    return std.fs.path.join(a, &.{ env.get("HOME") orelse return error.MissingHome, ".nib" });
}

pub fn recordTools(env: ?*const Env) bool {
    const value = (if (env) |e| e.get("NIB_RECORD") else null) orelse return false;
    return !std.mem.eql(u8, value, "off");
}

pub fn load(a: Allocator, io: std.Io, env: *const Env, home_path: []const u8, detail: *?[]u8) !provider.Config {
    detail.* = null;
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    defer a.free(path);
    const text = read(a, io, path) catch |err| {
        detail.* = try std.fmt.allocPrint(a, "{s}:1: cannot read configuration: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer a.free(text);
    var cfg = try resolve(a, env, text, path, detail);
    try applyStore(a, io, home_path, &cfg);
    if (env.get("NIB_PROVIDER") == null and !credentialed(a, io, cfg)) {
        if (try pickCredentialed(a, io, env, home_path, text, path)) |picked| cfg = picked;
    }
    return cfg;
}

/// Fills a missing key from nib's own store; environment keys win.
pub fn applyStore(a: Allocator, io: std.Io, home_path: []const u8, cfg: *provider.Config) !void {
    if (cfg.provider == .codex or cfg.api_key.len > 0) return;
    const file = try auth_store.path(a, home_path);
    defer a.free(file);
    var doc = auth_store.Doc.load(a, io, file) catch return;
    defer doc.deinit();
    const key = doc.key(cfg.name()) orelse return;
    cfg.api_key = try a.dupe(u8, key);
    cfg.key_source = .store;
}

/// Whether requests can be sent: a Codex login, a key, or a service that needs none.
pub fn credentialed(a: Allocator, io: std.Io, cfg: provider.Config) bool {
    if (cfg.provider != .codex) return !cfg.missingKey();
    var login = auth_codex.load(a, io, .{ .nib_home = cfg.nib_home, .codex_home = cfg.codex_home, .issuer = cfg.auth_issuer }) catch return false;
    login.deinit();
    return true;
}

pub const startup_order = [_][]const u8{ "codex", "anthropic", "openai", "deepseek", "xai" };

/// First credentialed service: Codex login, built-in keys, then custom services. Not persisted.
fn pickCredentialed(a: Allocator, io: std.Io, env: *const Env, home_path: []const u8, text: []const u8, path: []const u8) !?provider.Config {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var detail: ?[]u8 = null;
    const file = try parse(scratch.allocator(), a, text, path, &detail);
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(scratch.allocator(), &startup_order);
    for (file.providers.items) |item| if (item.custom) try names.append(scratch.allocator(), item.name);
    var picked_env = try env.clone(scratch.allocator());
    for ([_][]const u8{ "NIB_MODEL", "NIB_BASE_URL", "NIB_CONTEXT_WINDOW" }) |name| _ = picked_env.swapRemove(name);
    for (names.items) |name| {
        try picked_env.put("NIB_PROVIDER", name);
        var d: ?[]u8 = null;
        var cfg = resolve(a, &picked_env, text, path, &d) catch continue;
        try applyStore(a, io, home_path, &cfg);
        if (credentialed(a, io, cfg)) return cfg;
    }
    return null;
}

pub const Custom = struct { id: []const u8, protocol: provider.Protocol, base_url: []const u8, model: []const u8, context_window: u64, api_key_env: ?[]const u8 };

/// Custom `[providers.<id>]` services in file order, allocated with `a`.
pub fn customProviders(a: Allocator, io: std.Io, home_path: []const u8) ![]const Custom {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try read(a, io, path);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var detail: ?[]u8 = null;
    const file = try parse(scratch.allocator(), a, text, path, &detail);
    var out: std.ArrayList(Custom) = .empty;
    for (file.providers.items) |item| {
        if (!item.custom) continue;
        const st = item.settings;
        try out.append(a, .{
            .id = try a.dupe(u8, item.name),
            .protocol = st.protocol.?,
            .base_url = try a.dupe(u8, st.base_url.?),
            .model = try a.dupe(u8, st.model.?),
            .context_window = st.context_window.?,
            .api_key_env = if (st.api_key_env) |env_name| try a.dupe(u8, env_name) else null,
        });
    }
    return out.toOwnedSlice(a);
}

pub fn endpointIdProblem(id: []const u8, existing: []const []const u8) ?[]const u8 {
    if (id.len == 0) return "Name cannot be empty";
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return "Use letters, digits, _ and - only";
    if (std.meta.stringToEnum(provider.Id, id) != null) return "Name is taken by a built-in service";
    for (existing) |name| if (std.mem.eql(u8, name, id)) return "Name is already used";
    return null;
}

pub const Endpoint = struct { id: []const u8, protocol: provider.Protocol, base_url: []const u8, model: []const u8, context_window: u64 };

/// Appends a `[providers.<id>]` section; the key is never written here.
pub fn addEndpoint(a: Allocator, io: std.Io, home_path: []const u8, endpoint: Endpoint) !void {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try read(a, io, path);
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
    _ = try parse(a, a, out.items, path, &detail);
    try std.Io.Dir.cwd().createDirPath(io, home_path);
    _ = try atomic_file.replace(io, a, path, out.items, .{ .permissions = .fromMode(0o600), .sync = true });
}

fn read(a: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => a.dupe(u8, ""),
        else => return err,
    };
}

const Settings = struct {
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    context_window: ?u64 = null,
    model_line: usize = 1,
    protocol: ?provider.Protocol = null,
    api_key_env: ?[]const u8 = null,
    vision: ?bool = null,
    max_output: ?u32 = null,
    transport: provider.Transport = .websocket,
    run_tool: @FieldType(provider.Config, "codex_run_tool") = .custom,
    reasoning_summary: @FieldType(provider.Config, "reasoning_summary") = .off,
};

pub const SkillSetting = struct { name: []const u8, enabled: bool, span: Span };

pub fn skillEnabled(settings: []const SkillSetting, name: []const u8) bool {
    for (settings) |setting| if (std.mem.eql(u8, setting.name, name)) return setting.enabled;
    return false;
}

const Span = struct { start: usize, end: usize };
const ProviderSetting = struct { name: []const u8, settings: Settings = .{}, line: usize, seen: [11]bool = @splat(false), custom: bool };

const File = struct {
    providers: std.ArrayList(ProviderSetting) = .empty,
    provider_name: ?[]const u8 = null,
    provider_line: usize = 1,
    skills: std.ArrayList(SkillSetting) = .empty,
    skills_end: ?usize = null,
    mcp: std.ArrayList(SkillSetting) = .empty,
    mcp_end: ?usize = null,
    plugins: std.ArrayList(SkillSetting) = .empty,
    plugins_end: ?usize = null,
    mcp_servers: std.ArrayList(@import("mcp/config.zig").Server) = .empty,
    top_end: usize = 0,
    limits: provider.Limits = .{},
    sandbox: provider.Sandbox = .{},
    hooks: provider.Hooks = .{},
    provider_id: ?provider.Id = null,
    simple: bool = false,
    open: ?[]const u8 = null,
    ui_value: ?Span = null,
    effort: ?[]const u8 = null,
    codex_settings: Settings = .{},
    chat_settings: Settings = .{},
    effort_value: ?Span = null,
    effort_line: ?Span = null,
};

fn fail(a: Allocator, detail: *?[]u8, path: []const u8, line: usize, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, InvalidConfig } {
    const message = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(message);
    detail.* = try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ path, line, message });
    return error.InvalidConfig;
}

fn knownEffort(value: []const u8) ?[]const u8 {
    for (provider.Config.effort_values) |v| if (std.mem.eql(u8, v, value)) return v;
    return null;
}

const Parser = struct {
    a: Allocator,
    diagnostics: Allocator,
    path: []const u8,
    detail: *?[]u8,
    line: usize = 1,

    fn bad(p: Parser, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, InvalidConfig } {
        return fail(p.diagnostics, p.detail, p.path, p.line, fmt, args);
    }

    fn string(p: Parser, input: []const u8, consumed: *usize) ![]const u8 {
        if (input.len == 0 or input[0] != '"') return p.bad("expected a quoted string", .{});
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < input.len) {
            const c = input[i];
            i += 1;
            if (c == '"') {
                consumed.* = i;
                return out.toOwnedSlice(p.a);
            }
            if (c < 0x20 and c != '\t' or c == 0x7f) return p.bad("control character in string", .{});
            if (c != '\\') {
                try out.append(p.a, c);
                continue;
            }
            if (i == input.len) return p.bad("unterminated string escape", .{});
            const escape = input[i];
            i += 1;
            switch (escape) {
                '"', '\\' => try out.append(p.a, escape),
                'n' => try out.append(p.a, '\n'),
                else => return p.bad("unsupported string escape", .{}),
            }
        }
        return p.bad("unterminated string", .{});
    }

    fn integer(p: Parser, input: []const u8, consumed: *usize) !i128 {
        const end = std.mem.indexOfAny(u8, input, " \t#") orelse input.len;
        consumed.* = end;
        var digits = input[0..end];
        const negative = std.mem.startsWith(u8, digits, "-");
        if (negative or std.mem.startsWith(u8, digits, "+")) digits = digits[1..];
        if (digits.len == 0) return p.bad("expected a decimal integer", .{});
        var clean: std.ArrayList(u8) = .empty;
        for (digits, 0..) |c, i| {
            if (c == '_') {
                if (i == 0 or i + 1 == digits.len or !std.ascii.isDigit(digits[i - 1]) or !std.ascii.isDigit(digits[i + 1])) return p.bad("invalid integer separator", .{});
            } else if (std.ascii.isDigit(c)) {
                try clean.append(p.a, c);
            } else return p.bad("expected a decimal integer", .{});
        }
        if (clean.items.len > 1 and clean.items[0] == '0') return p.bad("leading zero in integer", .{});
        const number = std.fmt.parseInt(i128, clean.items, 10) catch return p.bad("integer out of range", .{});
        return if (negative) -number else number;
    }
    fn stringArray(p: Parser, input: []const u8, consumed: *usize) ![]const []const u8 {
        if (input.len == 0 or input[0] != '[') return p.bad("expected an array of strings on one line", .{});
        var items: std.ArrayList([]const u8) = .empty;
        var i: usize = 1;
        while (true) {
            while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
            if (i == input.len) return p.bad("unterminated array; arrays must fit on one line", .{});
            if (input[i] == ']') break;
            var used: usize = 0;
            try items.append(p.a, try p.string(input[i..], &used));
            i += used;
            while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
            if (i < input.len and input[i] == ',') i += 1 else if (i == input.len or input[i] != ']') return p.bad("expected , or ] in array", .{});
        }
        consumed.* = i + 1;
        return items.items;
    }

    const Value = union(enum) { string: []const u8, integer: i128, boolean: bool };

    fn value(p: Parser, input: []const u8, consumed: *usize) !Value {
        if (input.len > 0 and input[0] == '"') return .{ .string = try p.string(input, consumed) };
        const end = std.mem.indexOfAny(u8, input, " \t#") orelse input.len;
        const token = input[0..end];
        if (std.mem.eql(u8, token, "true") or std.mem.eql(u8, token, "false")) {
            consumed.* = end;
            return .{ .boolean = std.mem.eql(u8, token, "true") };
        }
        return .{ .integer = try p.integer(input, consumed) };
    }
};

fn secretKey(key: []const u8) bool {
    var buf: [256]u8 = undefined;
    const len = @min(key.len, buf.len);
    for (key[0..len], 0..) |c, i| buf[i] = if (c == '-') '_' else std.ascii.toLower(c);
    const lower = buf[0..len];
    for ([_][]const u8{ "api_key", "apikey", "token", "secret", "password", "credential", "authorization" }) |word| {
        if (std.mem.indexOf(u8, lower, word) != null) return true;
    }
    return false;
}

fn parse(a: Allocator, diagnostics: Allocator, text: []const u8, path: []const u8, detail: *?[]u8) !File {
    var p: Parser = .{ .a = a, .diagnostics = diagnostics, .path = path, .detail = detail };
    var file: File = .{};
    const Section = enum { chat_completions, codex, limits, skills, sandbox, hooks, provider_dynamic, mcp, mcp_dynamic, plugins };
    var section: ?Section = null;
    var seen_sections: [10]bool = @splat(false);
    var hooks_seen: [2]bool = @splat(false);
    var sandbox_seen: [2]bool = @splat(false);
    var seen: [10][11]bool = @splat(@splat(false));
    var current_provider: usize = 0;
    var mcp_seen: [5]bool = @splat(false);
    var offset: usize = 0;
    while (offset < text.len) : (p.line += 1) {
        const end = if (std.mem.indexOfScalarPos(u8, text, offset, '\n')) |n| n + 1 else text.len;
        const raw = text[offset..end];
        const line = std.mem.trim(u8, raw, " \t\r\n");
        const start = offset;
        offset = end;
        if (!std.unicode.utf8ValidateSlice(raw)) return p.bad("invalid UTF-8", .{});
        if (std.mem.indexOfScalar(u8, raw, '\r')) |cr| {
            if (cr + 2 != raw.len or raw[cr + 1] != '\n') return p.bad("bare carriage return", .{});
        }
        for (line) |c| if ((c < 0x20 and c != '\t') or c == 0x7f) return p.bad("control character", .{});
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse return p.bad("unterminated section", .{});
            const name = std.mem.trim(u8, line[1..close], " \t");
            if (!std.mem.startsWith(u8, name, "providers.") and !std.mem.startsWith(u8, name, "mcp.") and secretKey(name)) return p.bad("secrets are not allowed; use NIB_API_KEY or DEEPSEEK_API_KEY (Codex uses CODEX_HOME/auth.json)", .{});
            if (section == .skills) file.skills_end = start;
            if (section == .mcp) file.mcp_end = start;
            if (section == .plugins) file.plugins_end = start;
            if (section == null) file.top_end = start;
            if (std.mem.startsWith(u8, name, "mcp.")) {
                const id = name[4..];
                if (endpointIdProblem(id, &.{}) != null) return p.bad("invalid MCP server id '{s}'", .{id});
                for (file.mcp_servers.items) |server| if (std.mem.eql(u8, server.id, id)) return p.bad("duplicate section '{s}'", .{name});
                const tail = std.mem.trimStart(u8, line[close + 1 ..], " \t");
                if (tail.len > 0 and tail[0] != '#') return p.bad("unexpected text after section", .{});
                try file.mcp_servers.append(a, .{ .id = try a.dupe(u8, id), .line = p.line });
                mcp_seen = @splat(false);
                section = .mcp_dynamic;
                continue;
            }
            const builtin = std.meta.stringToEnum(provider.Id, name);
            const custom = std.mem.startsWith(u8, name, "providers.");
            if (custom or (builtin != null and builtin != .codex and builtin != .chat_completions and builtin != .custom)) {
                const id = if (custom) name[10..] else name;
                if (id.len == 0) return p.bad("empty provider id", .{});
                for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return p.bad("invalid provider id", .{});
                if (custom and std.meta.stringToEnum(provider.Id, id) != null) return p.bad("provider id conflicts with built-in '{s}'", .{id});
                for (file.providers.items) |item| if (std.mem.eql(u8, item.name, id)) return p.bad("duplicate section '{s}'", .{name});
                current_provider = file.providers.items.len;
                try file.providers.append(a, .{ .name = try a.dupe(u8, id), .line = p.line, .custom = custom });
                section = .provider_dynamic;
            } else section = (if (std.mem.eql(u8, name, "provider_dynamic") or std.mem.eql(u8, name, "mcp_dynamic")) null else std.meta.stringToEnum(Section, name)) orelse return p.bad("unknown section '{s}'", .{name});
            if (section == .provider_dynamic and !custom and builtin == null) return p.bad("unknown section '{s}'", .{name});
            const tail = std.mem.trimStart(u8, line[close + 1 ..], " \t");
            if (tail.len > 0 and tail[0] != '#') return p.bad("unexpected text after section", .{});
            const index = @backingInt(section.?);
            if (section == .provider_dynamic) continue;
            if (seen_sections[index]) return p.bad("duplicate section '{s}'", .{name});
            seen_sections[index] = true;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return p.bad("expected key = value", .{});
        const key = std.mem.trimEnd(u8, line[0..eq], " \t");
        if (section != .skills and section != .mcp and section != .plugins and section != .mcp_dynamic and !std.mem.eql(u8, key, "api_key_env") and secretKey(key)) return p.bad("secrets are not allowed; use NIB_API_KEY or DEEPSEEK_API_KEY (Codex uses CODEX_HOME/auth.json)", .{});
        if (key.len == 0) return p.bad("empty key", .{});
        for (key) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return p.bad("expected a bare key (dotted and quoted keys are unsupported)", .{});
        if (section == .skills or section == .mcp or section == .plugins) {
            const switches = if (section == .skills) &file.skills else if (section == .mcp) &file.mcp else &file.plugins;
            for (switches.items) |setting| if (std.mem.eql(u8, setting.name, key)) return p.bad("duplicate key '{s}'", .{key});
            const value = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
            var consumed: usize = 0;
            const parsed = try p.value(value, &consumed);
            if (parsed != .boolean) return p.bad("enablement must be a boolean", .{});
            const tail = std.mem.trim(u8, value[consumed..], " \t");
            if (tail.len > 0 and tail[0] != '#') return p.bad("unexpected text after value", .{});
            const value_start = start + @intFromPtr(value.ptr) - @intFromPtr(raw.ptr);
            try switches.append(a, .{ .name = try a.dupe(u8, key), .enabled = parsed.boolean, .span = .{ .start = value_start, .end = value_start + consumed } });
            continue;
        }
        if (section == .mcp_dynamic) {
            const names = [_][]const u8{ "command", "url", "args", "env", "header_env" };
            const which = for (names, 0..) |name, i| {
                if (std.mem.eql(u8, key, name)) break i;
            } else return p.bad("unknown MCP key '{s}'", .{key});
            if (mcp_seen[which]) return p.bad("duplicate key '{s}'", .{key});
            mcp_seen[which] = true;
            const value = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
            var consumed: usize = 0;
            const server = &file.mcp_servers.items[file.mcp_servers.items.len - 1];
            if (which == 2 or which == 3) {
                const values = try p.stringArray(value, &consumed);
                if (which == 2) server.args = values else {
                    for (values) |v| if (!@import("mcp/config.zig").envName(v)) return p.bad("invalid environment variable name", .{});
                    server.env = values;
                }
            } else {
                const parsed = try p.value(value, &consumed);
                if (parsed != .string or parsed.string.len == 0) return p.bad("{s} must be a nonempty string", .{key});
                switch (which) {
                    0 => server.command = parsed.string,
                    1 => {
                        const uri = std.Uri.parse(parsed.string) catch return p.bad("invalid MCP URL", .{});
                        if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or uri.host == null or uri.user != null or uri.password != null) return p.bad("MCP URL must be http(s) without credentials", .{});
                        server.url = parsed.string;
                    },
                    4 => {
                        if (!@import("mcp/config.zig").envName(parsed.string)) return p.bad("invalid environment variable name", .{});
                        server.header_env = parsed.string;
                    },
                    else => unreachable,
                }
            }
            const tail = std.mem.trimStart(u8, value[consumed..], " \t");
            if (tail.len > 0 and tail[0] != '#') return p.bad("unexpected text after value", .{});
            continue;
        }
        if (section == .hooks) {
            const which: usize = if (std.mem.eql(u8, key, "after_edit")) 0 else if (std.mem.eql(u8, key, "turn_end")) 1 else return p.bad("unknown hooks key '{s}'", .{key});
            if (hooks_seen[which]) return p.bad("duplicate key '{s}'", .{key});
            hooks_seen[which] = true;
            const value = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
            var consumed: usize = 0;
            const commands = try p.stringArray(value, &consumed);
            if (which == 0) file.hooks.after_edit = commands else file.hooks.turn_end = commands;
            const tail = std.mem.trimStart(u8, value[consumed..], " \t");
            if (tail.len > 0 and tail[0] != '#') return p.bad("unexpected text after value", .{});
            continue;
        }
        if (section == .sandbox) {
            const which: usize = if (std.mem.eql(u8, key, "mode")) 0 else if (std.mem.eql(u8, key, "writable")) 1 else return p.bad("unknown sandbox key '{s}'", .{key});
            if (sandbox_seen[which]) return p.bad("duplicate key '{s}'", .{key});
            sandbox_seen[which] = true;
            const value = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
            var consumed: usize = 0;
            if (which == 0) {
                const parsed = try p.value(value, &consumed);
                if (parsed != .string) return p.bad("mode must be a string", .{});
                file.sandbox.mode = std.meta.stringToEnum(@FieldType(provider.Sandbox, "mode"), parsed.string) orelse return p.bad("mode must be workspace or off", .{});
            } else {
                const paths = try p.stringArray(value, &consumed);
                for (paths) |entry| if (!std.fs.path.isAbsolute(entry) and !std.mem.eql(u8, entry, "~") and !std.mem.startsWith(u8, entry, "~/")) return p.bad("writable paths must be absolute or start with ~/", .{});
                file.sandbox.writable = paths;
            }
            const tail = std.mem.trimStart(u8, value[consumed..], " \t");
            if (tail.len > 0 and tail[0] != '#') return p.bad("unexpected text after value", .{});
            continue;
        }
        const index: usize = if (section == null)
            if (std.mem.eql(u8, key, "provider")) 0 else if (std.mem.eql(u8, key, "effort")) 1 else if (std.mem.eql(u8, key, "ui")) 2 else if (std.mem.eql(u8, key, "open")) 3 else return p.bad("unknown top-level key '{s}'", .{key})
        else if (section == .limits) blk: {
            const names = .{ "llm_concurrency", "llm_calls_per_run", "llm_input_kib", "agent_concurrency", "max_steps", "stream_idle_timeout_s", "run_background_after_ms", "stream_content_timeout_s", "request_timeout_s", "run_output_bytes" };
            inline for (names, 0..) |name, i| {
                if (std.mem.eql(u8, key, name)) break :blk i;
            }
            return p.bad("unknown limits key '{s}'", .{key});
        } else if (std.mem.eql(u8, key, "model")) 0 else if (std.mem.eql(u8, key, "base_url")) 1 else if (std.mem.eql(u8, key, "context_window")) 2 else if (section == .codex and std.mem.eql(u8, key, "transport")) 3 else if (section == .codex and std.mem.eql(u8, key, "reasoning_summary")) 4 else if (section == .codex and std.mem.eql(u8, key, "run_tool")) 5 else if (section == .provider_dynamic and file.providers.items[current_provider].custom and std.mem.eql(u8, key, "protocol")) 6 else if (section == .provider_dynamic and file.providers.items[current_provider].custom and std.mem.eql(u8, key, "api_key_env")) 7 else if (section == .provider_dynamic and file.providers.items[current_provider].custom and std.mem.eql(u8, key, "vision")) 8 else if (section == .provider_dynamic and file.providers.items[current_provider].custom and std.mem.eql(u8, key, "max_output")) 10 else return p.bad("unknown provider key '{s}'", .{key});
        const group: usize = if (section) |id| @as(usize, @backingInt(id)) + 1 else 0;
        const keys = if (section == .provider_dynamic) &file.providers.items[current_provider].seen else &seen[group];
        if (keys[index]) return p.bad("duplicate key '{s}'", .{key});
        keys[index] = true;
        const value = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
        var consumed: usize = 0;
        const settings = if (section == .provider_dynamic) &file.providers.items[current_provider].settings else if (section == .codex) &file.codex_settings else &file.chat_settings;
        const parsed = try p.value(value, &consumed);
        if (section == .limits) {
            if (parsed != .integer) return p.bad("{s} must be an integer", .{key});
            const maxima = [_]usize{ 64, 10000, 65536, 64, 100000, 3600, 3600000, 3600, 3600, 16 * 1024 * 1024 };
            const minimum: usize = if (index == 9) 16 * 1024 else 1;
            if (parsed.integer < minimum or parsed.integer > maxima[index]) return p.bad("{s} must be between {d} and {d}", .{ key, minimum, maxima[index] });
            const n: usize = @intCast(parsed.integer);
            switch (index) {
                0 => file.limits.llm_concurrency = n,
                1 => file.limits.llm_calls_per_run = n,
                2 => file.limits.llm_input_kib = n,
                3 => file.limits.agent_concurrency = n,
                4 => file.limits.max_steps = n,
                5 => file.limits.stream_idle_timeout_s = n,
                6 => file.limits.run_background_after_ms = n,
                7 => file.limits.stream_content_timeout_s = n,
                8 => file.limits.request_timeout_s = n,
                9 => file.limits.run_output_bytes = n,
                else => unreachable,
            }
        } else if (section != null and index == 8) {
            if (parsed != .boolean) return p.bad("vision must be true or false", .{});
            settings.vision = parsed.boolean;
        } else if (section != null and index == 10) {
            if (parsed != .integer) return p.bad("max_output must be an integer", .{});
            if (parsed.integer <= 0 or parsed.integer > std.math.maxInt(u32)) return p.bad("max_output must be a positive u32 integer", .{});
            settings.max_output = @intCast(parsed.integer);
        } else if (section != null and index == 2) {
            if (parsed != .integer) return p.bad("context_window must be an integer", .{});
            if (parsed.integer <= 0 or parsed.integer > std.math.maxInt(u64)) return p.bad("context_window must be a positive u64 integer", .{});
            settings.context_window = @intCast(parsed.integer);
        } else {
            if (parsed != .string) return p.bad("{s} must be a string", .{key});
            const decoded = parsed.string;
            if (section == null) {
                if (index == 0) {
                    file.provider_id = std.meta.stringToEnum(provider.Id, decoded) orelse .custom;
                    file.provider_name = decoded;
                    file.provider_line = p.line;
                } else if (index == 2) {
                    if (!std.mem.eql(u8, decoded, mode.value) and !std.mem.eql(u8, decoded, "normal")) return p.bad("ui must be simple or normal", .{});
                    file.simple = std.mem.eql(u8, decoded, mode.value);
                    const value_start = start + @intFromPtr(value.ptr) - @intFromPtr(raw.ptr);
                    file.ui_value = .{ .start = value_start, .end = value_start + consumed };
                } else if (index == 3) {
                    if (std.mem.trim(u8, decoded, " \t").len == 0) return p.bad("open must not be empty", .{});
                    file.open = decoded;
                } else {
                    file.effort = knownEffort(decoded) orelse return p.bad("invalid effort; expected default|off|none|minimal|low|medium|high|xhigh|max", .{});
                    const value_start = start + @intFromPtr(value.ptr) - @intFromPtr(raw.ptr);
                    file.effort_value = .{ .start = value_start, .end = value_start + consumed };
                    file.effort_line = .{ .start = start, .end = end };
                }
            } else if (index == 0) {
                settings.model = decoded;
                settings.model_line = p.line;
            } else if (index == 6) {
                settings.protocol = std.meta.stringToEnum(provider.Protocol, decoded) orelse return p.bad("protocol must be responses, chat_completions or anthropic_messages", .{});
            } else if (index == 7) {
                if (decoded.len == 0) return p.bad("api_key_env must name an environment variable", .{});
                for (decoded, 0..) |c, i| if (!(std.ascii.isAlphabetic(c) or c == '_' or (i > 0 and std.ascii.isDigit(c)))) return p.bad("invalid api_key_env name", .{});
                settings.api_key_env = decoded;
            } else if (index == 3) {
                settings.transport = std.meta.stringToEnum(provider.Transport, decoded) orelse return p.bad("transport must be websocket or sse", .{});
            } else if (index == 4) {
                settings.reasoning_summary = std.meta.stringToEnum(@FieldType(provider.Config, "reasoning_summary"), decoded) orelse return p.bad("reasoning_summary must be off or auto", .{});
            } else if (index == 5) {
                settings.run_tool = std.meta.stringToEnum(@FieldType(provider.Config, "codex_run_tool"), decoded) orelse return p.bad("run_tool must be custom or function", .{});
            } else settings.base_url = decoded;
        }
        const tail = std.mem.trimStart(u8, value[consumed..], " \t");
        if (tail.len > 0 and tail[0] != '#') return p.bad("unexpected text after value", .{});
    }
    if (section == .skills) file.skills_end = text.len;
    if (section == .mcp) file.mcp_end = text.len;
    if (section == .plugins) file.plugins_end = text.len;
    for (file.mcp_servers.items) |*server| {
        if ((server.command == null) == (server.url == null)) return fail(diagnostics, detail, path, server.line, "MCP server requires exactly one of command or url", .{});
        if (server.url != null and (server.args.len > 0 or server.env.len > 0)) return fail(diagnostics, detail, path, server.line, "args and env require command", .{});
        if (server.command != null and server.header_env != null) return fail(diagnostics, detail, path, server.line, "header_env requires url", .{});
        server.enabled = skillEnabled(file.mcp.items, server.id);
    }
    if (section == null) file.top_end = text.len;
    for (file.providers.items) |item| if (item.custom) {
        if (item.settings.protocol == null or item.settings.base_url == null or item.settings.model == null or item.settings.context_window == null)
            return fail(diagnostics, detail, path, item.line, "custom provider '{s}' requires protocol, base_url, model and context_window", .{item.name});
        if (item.settings.base_url.?.len == 0 or item.settings.model.?.len == 0) return fail(diagnostics, detail, path, item.line, "provider base_url and model must not be empty", .{});
    };
    if (file.provider_id == .custom) {
        const name = file.provider_name.?;
        const found = for (file.providers.items) |item| {
            if (item.custom and std.mem.eql(u8, name, item.name)) break true;
        } else false;
        if (!found) return fail(diagnostics, detail, path, file.provider_line, "provider must be a built-in id or configured custom provider; unknown '{s}'", .{name});
    }
    return file;
}

// Returned string fields are allocated with a, except canonical reasoning_effort values.
pub fn resolve(a: Allocator, env: *const Env, text: []const u8, path: []const u8, detail: *?[]u8) !provider.Config {
    detail.* = null;
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const file = try parse(scratch.allocator(), a, text, path, detail);
    const name = env.get("NIB_PROVIDER") orelse file.provider_name orelse "codex";
    const id = std.meta.stringToEnum(provider.Id, name) orelse .custom;
    var settings: Settings = if (id == .codex) file.codex_settings else if (id == .chat_completions) file.chat_settings else .{};
    var found = false;
    for (file.providers.items) |item| if (std.mem.eql(u8, item.name, name)) {
        settings = item.settings;
        found = true;
        break;
    };
    if (id == .custom and (!found or std.mem.eql(u8, name, "custom"))) {
        detail.* = try std.fmt.allocPrint(a, "NIB_PROVIDER: unknown provider '{s}'", .{name});
        return error.InvalidProvider;
    }
    const entry = if (id == .custom) provider.Definition{ .id = name, .name = name, .protocol = settings.protocol.?, .base_url = settings.base_url.?, .default_model = settings.model.?, .api_key_env = &.{} } else provider.definition(id);
    const model = env.get("NIB_MODEL") orelse settings.model orelse entry.default_model;
    const context_window = if (env.get("NIB_CONTEXT_WINDOW")) |v| blk: {
        const n = std.fmt.parseInt(u64, v, 10) catch {
            detail.* = try a.dupe(u8, "NIB_CONTEXT_WINDOW: expected a positive integer");
            return error.InvalidContextWindow;
        };
        if (n == 0) {
            detail.* = try a.dupe(u8, "NIB_CONTEXT_WINDOW: must be greater than zero");
            return error.InvalidContextWindow;
        }
        break :blk n;
    } else settings.context_window orelse if (id == .codex) codex.contextWindow(model) catch |err| {
        detail.* = try std.fmt.allocPrint(a, "{s}:{d}: unknown Codex model context window; set context_window or NIB_CONTEXT_WINDOW", .{ path, settings.model_line });
        return err;
    } else blk: {
        for (entry.models) |item| if (std.mem.eql(u8, item.id, model)) break :blk item.context_window;
        if (id == .chat_completions) break :blk 1_000_000;
        return fail(a, detail, path, settings.model_line, "unknown model context window; set context_window or NIB_CONTEXT_WINDOW", .{});
    };
    var cfg: provider.Config = .{ .provider = id, .api_key = "", .base_url = "", .model = "", .context_window = context_window, .limits = file.limits };
    if (id == .custom) {
        cfg.custom_provider = try a.dupe(u8, name);
        cfg.custom_protocol = settings.protocol.?;
        cfg.custom_vision = settings.vision;
        cfg.custom_max_output = settings.max_output;
    }
    cfg.api_key_env = if (settings.api_key_env) |value| try a.dupe(u8, value) else if (entry.api_key_env.len > 0) try a.dupe(u8, entry.api_key_env[0]) else null;
    cfg.codex_transport = if (env.get("NIB_CODEX_TRANSPORT")) |v| std.meta.stringToEnum(provider.Transport, v) orelse {
        detail.* = try a.dupe(u8, "NIB_CODEX_TRANSPORT: expected websocket or sse");
        return error.InvalidConfig;
    } else file.codex_settings.transport;
    cfg.simple = file.simple;
    cfg.open = if (file.open) |value| try a.dupe(u8, value) else null;
    cfg.codex_run_tool = if (env.get("NIB_CODEX_RUN_TOOL")) |v| std.meta.stringToEnum(@FieldType(provider.Config, "codex_run_tool"), v) orelse {
        detail.* = try a.dupe(u8, "NIB_CODEX_RUN_TOOL: expected custom or function");
        return error.InvalidConfig;
    } else file.codex_settings.run_tool;
    cfg.reasoning_summary = if (env.get("NIB_REASONING_SUMMARY")) |v| std.meta.stringToEnum(@FieldType(provider.Config, "reasoning_summary"), v) orelse {
        detail.* = try a.dupe(u8, "NIB_REASONING_SUMMARY: expected off or auto");
        return error.InvalidConfig;
    } else file.codex_settings.reasoning_summary;
    if (env.get("NIB_RUN_OUTPUT_BYTES")) |v| {
        const n = std.fmt.parseInt(usize, v, 10) catch 0;
        if (n < 16 * 1024 or n > 16 * 1024 * 1024) {
            detail.* = try a.dupe(u8, "NIB_RUN_OUTPUT_BYTES: expected 16384..16777216 bytes");
            return error.InvalidConfig;
        }
        cfg.limits.run_output_bytes = n;
    }
    if (env.get("NIB_TUNE")) |spec| {
        var message: []const u8 = "";
        _ = @import("session/tuning.zig").Resolved.override(.{}, a, spec, &message) catch |err| {
            detail.* = try a.dupe(u8, message);
            return err;
        };
    }
    if (env.get("NIB_THINKING") == null and env.get("NIB_REASONING_EFFORT") == null) {
        if (file.effort) |v| try cfg.setEffort(v);
    }
    if (env.get("NIB_THINKING")) |v| {
        cfg.thinking = if (std.mem.eql(u8, v, "on")) true else if (std.mem.eql(u8, v, "off")) false else {
            detail.* = try a.dupe(u8, "NIB_THINKING: expected on or off");
            return error.InvalidThinking;
        };
    }
    if (env.get("NIB_REASONING_EFFORT")) |v| {
        const effort = knownEffort(v) orelse {
            detail.* = try a.dupe(u8, "NIB_REASONING_EFFORT: expected default|off|none|minimal|low|medium|high|xhigh|max");
            return error.InvalidReasoningEffort;
        };
        if (std.mem.eql(u8, effort, "off")) cfg.thinking = false else if (!std.mem.eql(u8, effort, "default")) cfg.reasoning_effort = effort;
    }
    cfg.model = try a.dupe(u8, model);
    errdefer a.free(cfg.model);
    cfg.base_url = try a.dupe(u8, env.get("NIB_BASE_URL") orelse settings.base_url orelse entry.base_url);
    errdefer a.free(cfg.base_url);
    const key = if (settings.api_key_env) |key_env| env.get(key_env) orelse "" else for (entry.api_key_env) |key_name| {
        if (env.get(key_name)) |value| {
            cfg.api_key_env = try a.dupe(u8, key_name);
            break value;
        }
    } else "";
    cfg.api_key = try a.dupe(u8, key);
    errdefer a.free(cfg.api_key);
    cfg.key_source = if (key.len > 0) .env else .none;
    cfg.nib_home = home(a, env) catch null;
    cfg.auth_issuer = if (env.get("NIB_AUTH_ISSUER")) |v| try a.dupe(u8, v) else null;
    cfg.codex_home = if (env.get("CODEX_HOME")) |v| try a.dupe(u8, v) else try std.fs.path.join(a, &.{ env.get("HOME") orelse "", ".codex" });
    cfg.enabled_skills = try enabledSkills(a, file.skills.items);
    cfg.enabled_plugins = try enabledSkills(a, file.plugins.items);
    inline for (.{ "after_edit", "turn_end" }) |event| {
        const commands = try a.alloc([]const u8, @field(file.hooks, event).len);
        for (@field(file.hooks, event), commands) |command, *copy| copy.* = try a.dupe(u8, command);
        @field(cfg.hooks, event) = commands;
    }
    cfg.mcp_servers = try @import("mcp/config.zig").copy(a, file.mcp_servers.items);
    cfg.sandbox.mode = if (env.get("NIB_SANDBOX")) |v| std.meta.stringToEnum(@FieldType(provider.Sandbox, "mode"), v) orelse {
        detail.* = try a.dupe(u8, "NIB_SANDBOX: expected workspace or off");
        return error.InvalidConfig;
    } else file.sandbox.mode;
    const roots = try a.alloc([]const u8, file.sandbox.writable.len);
    for (file.sandbox.writable, roots) |configured, *root| root.* = try @import("tools/bash/jail.zig").expandHome(a, env.get("HOME") orelse "", configured);
    cfg.sandbox.writable = roots;
    return cfg;
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
                    const parser: Parser = .{ .a = a, .diagnostics = a, .path = "config.toml", .detail = &detail, .line = 1 };
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
    _ = try parse(a, a, text, "config.toml", &detail);
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
    const text = try read(a, io, path);
    var selected_env = try env.clone(a);
    _ = selected_env.swapRemove("NIB_MODEL");
    try selected_env.put("NIB_PROVIDER", selection.provider);
    if (selection.model) |model| try selected_env.put("NIB_MODEL", model);
    var detail: ?[]u8 = null;
    var cfg = try resolve(a, &selected_env, text, path, &detail);
    try applyStore(a, io, home_path, &cfg);
    if (cfg.provider == .chat_completions and !std.mem.eql(u8, cfg.model, provider.definition(.chat_completions).default_model) and env.get("NIB_CONTEXT_WINDOW") == null) {
        const file = try parse(a, a, text, path, &detail);
        if (file.chat_settings.context_window == null) return error.UnknownModelContextWindow;
    }
    const updated = try modelText(a, text, .{ .provider = selection.provider, .model = cfg.model });
    try std.Io.Dir.cwd().createDirPath(io, home_path);
    _ = try atomic_file.replace(io, a, path, updated, .{ .permissions = .fromMode(0o600), .sync = true });
    return cfg;
}

pub const ModelEntry = struct { provider: []const u8, model: []const u8 };

/// Catalog and configured models of configured or signed-in services, plus the active model.
pub fn modelEntries(a: Allocator, io: std.Io, env: *const Env, home_path: []const u8, cfg: provider.Config) ![]const ModelEntry {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try read(a, io, path);
    var detail: ?[]u8 = null;
    const file = try parse(a, a, text, path, &detail);
    const services = try @import("auth.zig").services(a, io, env, home_path);
    var entries: std.ArrayList(ModelEntry) = .empty;
    for (provider.definitions) |entry| {
        const configured = for (file.providers.items) |item| {
            if (std.mem.eql(u8, item.name, entry.id)) break true;
        } else false;
        const signed_in = if (@import("auth.zig").find(services, entry.id)) |svc| svc.signed_in else false;
        const selected = if (file.provider_name) |name| std.mem.eql(u8, name, entry.id) else false;
        if (!configured and !selected and !signed_in and !std.mem.eql(u8, entry.id, cfg.name())) continue;
        if (entry.models.len == 0) try appendModel(a, &entries, entry.id, entry.default_model);
        for (entry.models) |model| try appendModel(a, &entries, entry.id, model.id);
    }
    for (file.providers.items) |item| {
        if (item.settings.model) |model| try appendModel(a, &entries, item.name, model);
    }
    try appendModel(a, &entries, cfg.name(), cfg.model);
    std.mem.sort(ModelEntry, entries.items, cfg.name(), struct {
        fn before(current: []const u8, lhs: ModelEntry, rhs: ModelEntry) bool {
            return std.mem.eql(u8, lhs.provider, current) and !std.mem.eql(u8, rhs.provider, current);
        }
    }.before);
    return entries.toOwnedSlice(a);
}

fn appendModel(a: Allocator, entries: *std.ArrayList(ModelEntry), service: []const u8, model: []const u8) !void {
    for (entries.items) |item| {
        if (std.mem.eql(u8, item.provider, service) and std.mem.eql(u8, item.model, model)) return;
    }
    try entries.append(a, .{ .provider = service, .model = model });
}

pub fn saveEffort(a: Allocator, io: std.Io, home_path: []const u8, value: []const u8) !void {
    const effort = knownEffort(value) orelse return error.InvalidReasoningEffort;
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    defer a.free(path);
    const text = try read(a, io, path);
    defer a.free(text);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const file = try parse(scratch.allocator(), a, text, path, &detail);
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

test "TOML sections comments strings and scalar values" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var detail: ?[]u8 = null;
    const text =
        \\# header
        \\provider = "chat_completions" # provider comment
        \\effort = "medium"
        \\
        \\[codex] # ignored but validated
        \\model = "gpt-6.1-sol"
        \\context_window = 500_000
        \\[chat_completions]
        \\model = "a#b\"c\\d\ne"
        \\base_url = "https://example.test"
        \\context_window = +1000000
    ;
    const file = try parse(a, a, text, "test/config.toml", &detail);
    try t.expectEqual(provider.Id.chat_completions, file.provider_id.?);
    try t.expectEqualStrings("medium", file.effort.?);
    try t.expectEqualStrings("a#b\"c\\d\ne", file.chat_settings.model.?);
    try t.expectEqual(@as(u64, 500000), file.codex_settings.context_window.?);
    try t.expectEqual(@as(u64, 1000000), file.chat_settings.context_window.?);
    const parser: Parser = .{ .a = a, .diagnostics = a, .path = "values", .detail = &detail };
    var consumed: usize = 0;
    try t.expect((try parser.value("true # yes", &consumed)).boolean);
    try t.expectEqual(@as(usize, 4), consumed);
    try t.expect(!(try parser.value("false", &consumed)).boolean);
    try t.expectEqual(@as(i128, -42), (try parser.value("-42", &consumed)).integer);
    try t.expectEqual(@as(i128, 0), (try parser.value("0", &consumed)).integer);
}

test "strict configuration errors report path and exact line" {
    const t = std.testing;
    const cases = [_]struct { text: []const u8, line: usize, message: []const u8 }{
        .{ .text = "# comment\n[unknown]\n", .line = 2, .message = "unknown section" },
        .{ .text = "\nunknown = true\n", .line = 2, .message = "unknown top-level key" },
        .{ .text = "[codex]\neffort = \"high\"\n", .line = 2, .message = "unknown provider key" },
        .{ .text = "provider = false", .line = 1, .message = "must be a string" },
        .{ .text = "effort = 42", .line = 1, .message = "must be a string" },
        .{ .text = "[codex]\nmodel = true", .line = 2, .message = "must be a string" },
        .{ .text = "[codex]\nbase_url = 1", .line = 2, .message = "must be a string" },
        .{ .text = "[codex]\ncontext_window = \"500000\"", .line = 2, .message = "must be an integer" },
        .{ .text = "[codex]\ncontext_window = false", .line = 2, .message = "must be an integer" },
        .{ .text = "[codex]\ncontext_window = 0", .line = 2, .message = "positive u64" },
        .{ .text = "[codex]\ncontext_window = -1", .line = 2, .message = "positive u64" },
        .{ .text = "[codex]\ncontext_window = 18446744073709551616", .line = 2, .message = "positive u64" },
        .{ .text = "[codex]\ncontext_window = 1.5", .line = 2, .message = "decimal integer" },
        .{ .text = "[codex]\ncontext_window = 01", .line = 2, .message = "leading zero" },
        .{ .text = "[codex]\ncontext_window = 1__0", .line = 2, .message = "separator" },
        .{ .text = "effort = \"invalid\"", .line = 1, .message = "invalid effort" },
        .{ .text = "provider = \"invalid\"", .line = 1, .message = "provider must be" },
        .{ .text = "effort \"high\"", .line = 1, .message = "expected key = value" },
        .{ .text = "[codex", .line = 1, .message = "unterminated section" },
        .{ .text = "[codex] trailing", .line = 1, .message = "after section" },
        .{ .text = "effort = \"high", .line = 1, .message = "unterminated string" },
        .{ .text = "effort = \"high\" extra", .line = 1, .message = "after value" },
        .{ .text = "effort = \"hi\\q\"", .line = 1, .message = "unsupported string escape" },
        .{ .text = "effort = \"high\"\neffort = \"low\"", .line = 2, .message = "duplicate key" },
        .{ .text = "[codex]\n[codex]", .line = 2, .message = "duplicate section" },
        .{ .text = "\napi_key = \"no\"", .line = 2, .message = "use NIB_API_KEY" },
        .{ .text = "[codex]\naccess_token = \"no\"", .line = 2, .message = "use NIB_API_KEY" },
        .{ .text = "[chat_completions]\napi-key = \"no\"", .line = 2, .message = "use NIB_API_KEY" },
        .{ .text = "[credentials]", .line = 1, .message = "use NIB_API_KEY" },
        .{ .text = "effort = \"high\"\r", .line = 1, .message = "carriage return" },
        .{ .text = "# \xff", .line = 1, .message = "invalid UTF-8" },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var detail: ?[]u8 = null;
        try t.expectError(error.InvalidConfig, parse(a, a, case.text, "test/config.toml", &detail));
        const prefix = try std.fmt.allocPrint(a, "test/config.toml:{d}: ", .{case.line});
        try t.expect(std.mem.startsWith(u8, detail.?, prefix));
        try t.expect(std.mem.indexOf(u8, detail.?, case.message) != null);
    }
}

test "provider defaults file environment and command effort precedence" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/fictional");
    var detail: ?[]u8 = null;
    var cfg = try resolve(a, &env, "", "test/config.toml", &detail);
    try t.expectEqual(provider.Id.codex, cfg.provider);
    try t.expectEqualStrings("gpt-6.1-sol", cfg.model);
    try t.expectEqual(@as(u64, 500000), cfg.context_window);
    try t.expectEqualStrings("/fictional/.codex", cfg.codex_home.?);
    const text =
        \\provider = "chat_completions"
        \\effort = "medium"
        \\[codex]
        \\model = "gpt-6-sol"
        \\base_url = "https://codex.test"
        \\context_window = 200000
        \\[chat_completions]
        \\model = "file-model"
        \\base_url = "https://chat.test"
        \\context_window = 100000
    ;
    cfg = try resolve(a, &env, text, "test/config.toml", &detail);
    try t.expectEqualStrings("file-model", cfg.model);
    try t.expectEqualStrings("https://chat.test", cfg.base_url);
    try t.expectEqual(@as(u64, 100000), cfg.context_window);
    try t.expectEqualStrings("medium", cfg.reasoning_effort.?);
    try env.put("NIB_PROVIDER", "codex");
    cfg = try resolve(a, &env, text, "test/config.toml", &detail);
    try t.expectEqualStrings("gpt-6-sol", cfg.model);
    try t.expectEqualStrings("https://codex.test", cfg.base_url);
    try t.expectEqual(@as(u64, 200000), cfg.context_window);
    try env.put("NIB_MODEL", "env-model");
    try env.put("NIB_BASE_URL", "https://env.test");
    try env.put("NIB_CONTEXT_WINDOW", "12345");
    try env.put("NIB_REASONING_EFFORT", "low");
    try env.put("NIB_API_KEY", "mock");
    cfg = try resolve(a, &env, text, "test/config.toml", &detail);
    try t.expectEqualStrings("env-model", cfg.model);
    try t.expectEqualStrings("https://env.test", cfg.base_url);
    try t.expectEqual(@as(u64, 12345), cfg.context_window);
    try t.expectEqualStrings("", cfg.api_key);
    try t.expectEqualStrings("low", cfg.reasoning_effort.?);
    try env.put("NIB_THINKING", "off");
    cfg = try resolve(a, &env, text, "test/config.toml", &detail);
    try t.expectEqual(@as(?bool, false), cfg.thinking);
    try cfg.setEffort("high");
    try t.expectEqualStrings("high", cfg.reasoning_effort.?);
    try t.expectEqual(@as(?bool, true), cfg.thinking);
    try cfg.setEffort("default");
    try t.expectEqual(@as(?bool, null), cfg.thinking);
    try t.expectEqual(@as(?[]const u8, null), cfg.reasoning_effort);
    try env.put("NIB_PROVIDER", "chat_completions");
    cfg = try resolve(a, &env, text, "test/config.toml", &detail);
    try t.expectEqualStrings("mock", cfg.api_key);
    for (provider.Config.effort_values) |effort| {
        const file_text = try std.fmt.allocPrint(a, "effort = \"{s}\"", .{effort});
        var empty: Env = .init(t.allocator);
        defer empty.deinit();
        const file_cfg = try resolve(a, &empty, file_text, "test/config.toml", &detail);
        var expected: provider.Config = .{ .base_url = "", .model = "", .api_key = "" };
        try expected.setEffort(effort);
        try t.expectEqual(expected.thinking, file_cfg.thinking);
        try t.expectEqualStrings(expected.reasoning_effort orelse "", file_cfg.reasoning_effort orelse "");
    }
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
    try t.expectEqualStrings("gpt-6.1-sol", cfg.model);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "absent", .{}));
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

test "environment validation and model-dependent defaults" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(t.allocator);
    defer env.deinit();
    var detail: ?[]u8 = null;
    try env.put("NIB_PROVIDER", "chat_completions");
    var cfg = try resolve(a, &env, "", "config.toml", &detail);
    try t.expectEqualStrings("deepseek-flash", cfg.model);
    try t.expectEqualStrings("https://api.deepseek.com", cfg.base_url);
    try t.expectEqual(@as(u64, 1000000), cfg.context_window);
    try t.expect(cfg.missingKey());
    try env.put("DEEPSEEK_API_KEY", "mock-fallback");
    try t.expectEqualStrings("mock-fallback", (try resolve(a, &env, "", "config.toml", &detail)).api_key);
    try env.put("NIB_PROVIDER", "codex");
    try env.put("NIB_MODEL", "gpt-6-sol");
    cfg = try resolve(a, &env, "", "config.toml", &detail);
    try t.expectEqual(@as(u64, 272000), cfg.context_window);
    try cfg.checkSession(.codex, "gpt-6-sol");
    try t.expectError(error.SessionProviderMismatch, cfg.checkSession(.chat_completions, null));
    try env.put("NIB_MODEL", "unknown");
    try t.expectError(error.UnknownCodexModelContextWindow, resolve(a, &env, "", "config.toml", &detail));
    try env.put("NIB_CONTEXT_WINDOW", "10000");
    try t.expectEqual(@as(u64, 10000), (try resolve(a, &env, "", "config.toml", &detail)).context_window);
    try env.put("NIB_CONTEXT_WINDOW", "bad");
    try t.expectError(error.InvalidContextWindow, resolve(a, &env, "", "config.toml", &detail));
    try env.put("NIB_CONTEXT_WINDOW", "0");
    try t.expectError(error.InvalidContextWindow, resolve(a, &env, "", "config.toml", &detail));
    try env.put("NIB_CONTEXT_WINDOW", "10000");
    try env.put("NIB_THINKING", "invalid");
    try t.expectError(error.InvalidThinking, resolve(a, &env, "", "config.toml", &detail));
    try env.put("NIB_THINKING", "on");
    cfg = try resolve(a, &env, "effort = \"off\"", "config.toml", &detail);
    try t.expectEqual(@as(?bool, true), cfg.thinking);
    try t.expectEqual(@as(?[]const u8, null), cfg.reasoning_effort);
    try env.put("NIB_REASONING_EFFORT", "invalid");
    try t.expectError(error.InvalidReasoningEffort, resolve(a, &env, "", "config.toml", &detail));
    try env.put("NIB_PROVIDER", "invalid");
    try t.expectError(error.InvalidProvider, resolve(a, &env, "", "config.toml", &detail));
}

test "NIB_TUNE is validated at startup" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(a);
    var detail: ?[]u8 = null;
    try env.put("NIB_TUNE", "delivery=tool");
    _ = try resolve(a, &env, "", "config.toml", &detail);
    try env.put("NIB_TUNE", "delivery=short");
    try t.expectError(error.InvalidTuning, resolve(a, &env, "", "config.toml", &detail));
    try t.expectEqualStrings("NIB_TUNE: delivery has no variant 'short'; variants: user, tool", detail.?);
}

test "limits defaults, bounds and diagnostics" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(t.allocator);
    defer env.deinit();
    var detail: ?[]u8 = null;
    const defaults = (try resolve(a, &env, "", "config.toml", &detail)).limits;
    try t.expectEqualDeep(provider.Limits{ .llm_concurrency = 4, .llm_calls_per_run = 100, .llm_input_kib = 256, .agent_concurrency = 4, .max_steps = null, .stream_idle_timeout_s = 300 }, defaults);
    try t.expectEqualDeep(defaults, (try resolve(a, &env, "[limits]\n", "config.toml", &detail)).limits);
    try t.expectEqual(@as(?usize, null), (try resolve(a, &env, "[limits]\nllm_concurrency = 8\n", "config.toml", &detail)).limits.max_steps);
    try t.expectEqual(@as(?usize, 50), (try resolve(a, &env, "[limits]\nmax_steps = 50\n", "config.toml", &detail)).limits.max_steps);
    const names = [_][]const u8{ "llm_concurrency", "llm_calls_per_run", "llm_input_kib", "agent_concurrency", "max_steps", "stream_idle_timeout_s", "run_background_after_ms", "stream_content_timeout_s", "request_timeout_s" };
    const maxima = [_]usize{ 64, 10000, 65536, 64, 100000, 3600, 3600000, 3600, 3600 };
    for (names, maxima) |name, max| {
        for ([_]usize{ 1, max }) |n| {
            const text = try std.fmt.allocPrint(a, "[limits]\n{s} = {d}\n", .{ name, n });
            const limits = (try resolve(a, &env, text, "config.toml", &detail)).limits;
            inline for (names) |field| {
                if (std.mem.eql(u8, name, field)) try t.expectEqual(@as(@TypeOf(@field(limits, field)), n), @field(limits, field));
            }
        }
        const values = [_][]const u8{ "0", "-1", "true", "\"1\"", "1.5" };
        for (values) |value| {
            const text = try std.fmt.allocPrint(a, "[limits]\n{s} = {s}\n", .{ name, value });
            try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail));
            try t.expect(std.mem.startsWith(u8, detail.?, "config.toml:2:"));
        }
        const text = try std.fmt.allocPrint(a, "[limits]\n{s} = {d}\n", .{ name, max + 1 });
        try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail));
        try t.expect(std.mem.startsWith(u8, detail.?, "config.toml:2:"));
    }
    for ([_][]const u8{ "[limits]\nunknown = 1", "[limits]\nmax_steps = 1\nmax_steps = 2", "[limits]\n[limits]" }) |text| {
        try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail));
        try t.expect(std.mem.startsWith(u8, detail.?, "config.toml:"));
    }
}

test "sandbox defaults, file settings and NIB_SANDBOX override" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(a);
    try env.put("HOME", "/home/u");
    var detail: ?[]u8 = null;
    const defaults = try resolve(a, &env, "", "config.toml", &detail);
    try t.expectEqual(.off, defaults.sandbox.mode);
    try t.expectEqual(@as(usize, 0), defaults.sandbox.writable.len);
    const text = "[sandbox]\nmode = \"off\" # trusted machine\nwritable = [\"~/extra\", \"/data/shared\",]\n";
    const file = try resolve(a, &env, text, "config.toml", &detail);
    try t.expectEqual(.off, file.sandbox.mode);
    try t.expectEqual(@as(usize, 2), file.sandbox.writable.len);
    try t.expectEqualStrings("/home/u/extra", file.sandbox.writable[0]);
    try t.expectEqualStrings("/data/shared", file.sandbox.writable[1]);
    try t.expectEqual(.workspace, (try resolve(a, &env, "[sandbox]\nmode = \"workspace\"", "config.toml", &detail)).sandbox.mode);
    try env.put("NIB_SANDBOX", "workspace");
    try t.expectEqual(.workspace, (try resolve(a, &env, text, "config.toml", &detail)).sandbox.mode);
    try env.put("NIB_SANDBOX", "off");
    try t.expectEqual(.off, (try resolve(a, &env, "[sandbox]\nmode = \"workspace\"", "config.toml", &detail)).sandbox.mode);
    try env.put("NIB_SANDBOX", "maybe");
    try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail));
    try t.expect(std.mem.startsWith(u8, detail.?, "NIB_SANDBOX:"));
    for ([_][]const u8{ "[sandbox]\nmode = \"on\"", "[sandbox]\nmode = 1", "[sandbox]\nunknown = 1", "[sandbox]\nmode = \"off\"\nmode = \"off\"", "[sandbox]\nwritable = [\"relative\"]", "[sandbox]\nwritable = [\"/a\"", "[sandbox]\nwritable = \"/a\"", "[sandbox]\nwritable = [\"/a\" \"/b\"]", "[sandbox]\n[sandbox]" }) |bad| {
        var clean: Env = .init(a);
        try t.expectError(error.InvalidConfig, resolve(a, &clean, bad, "config.toml", &detail));
        try t.expect(std.mem.startsWith(u8, detail.?, "config.toml:"));
    }
}

test "summary and Run display budget file and environment precedence" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(a);
    var detail: ?[]u8 = null;
    const defaults = try resolve(a, &env, "", "config.toml", &detail);
    try t.expectEqual(.off, defaults.reasoning_summary);
    try t.expectEqual(@as(usize, 16384), defaults.limits.run_output_bytes);
    const text = "[codex]\nreasoning_summary = \"auto\"\n[limits]\nrun_output_bytes = 32768\n";
    const file = try resolve(a, &env, text, "config.toml", &detail);
    try t.expectEqual(.auto, file.reasoning_summary);
    try t.expectEqual(@as(usize, 32768), file.limits.run_output_bytes);
    try env.put("NIB_REASONING_SUMMARY", "off");
    try env.put("NIB_RUN_OUTPUT_BYTES", "65536");
    const overridden = try resolve(a, &env, text, "config.toml", &detail);
    try t.expectEqual(.off, overridden.reasoning_summary);
    try t.expectEqual(@as(usize, 65536), overridden.limits.run_output_bytes);
    for ([_][]const u8{ "0", "16383", "16777217", "many" }) |value| {
        try env.put("NIB_RUN_OUTPUT_BYTES", value);
        try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail));
    }
    _ = env.swapRemove("NIB_RUN_OUTPUT_BYTES");
    try env.put("NIB_REASONING_SUMMARY", "invalid");
    try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail));
    for ([_][]const u8{ "[codex]\nreasoning_summary = \"invalid\"", "[limits]\nrun_output_bytes = 16383", "[limits]\nrun_output_bytes = 16777217", "[limits]\nrun_output_bytes = true" }) |invalid| {
        try t.expectError(error.InvalidConfig, parse(a, a, invalid, "config.toml", &detail));
    }
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

test "Codex transport defaults, TOML selection and environment precedence" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(t.allocator);
    defer env.deinit();
    var detail: ?[]u8 = null;
    try t.expectEqual(provider.Transport.websocket, (try resolve(a, &env, "", "config.toml", &detail)).codex_transport);
    const text = "[codex]\ntransport = \"sse\"\n";
    try t.expectEqual(provider.Transport.sse, (try resolve(a, &env, text, "config.toml", &detail)).codex_transport);
    try env.put("NIB_CODEX_TRANSPORT", "websocket");
    try t.expectEqual(provider.Transport.websocket, (try resolve(a, &env, text, "config.toml", &detail)).codex_transport);
    try env.put("NIB_CODEX_TRANSPORT", "sse");
    try t.expectEqual(provider.Transport.sse, (try resolve(a, &env, "", "config.toml", &detail)).codex_transport);
    try env.put("NIB_CODEX_TRANSPORT", "invalid");
    try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail));
    try t.expectError(error.InvalidConfig, parse(a, a, "[codex]\ntransport = \"invalid\"\n", "config.toml", &detail));
    try t.expectError(error.InvalidConfig, parse(a, a, "[chat_completions]\ntransport = \"websocket\"\n", "config.toml", &detail));
}

test "Codex Run tool defaults custom with validated file and environment fallback" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(a);
    var detail: ?[]u8 = null;
    try t.expectEqual(.custom, (try resolve(a, &env, "", "config.toml", &detail)).codex_run_tool);
    const text = "[codex]\nrun_tool = \"function\"";
    try t.expectEqual(.function, (try resolve(a, &env, text, "config.toml", &detail)).codex_run_tool);
    try env.put("NIB_CODEX_RUN_TOOL", "custom");
    try t.expectEqual(.custom, (try resolve(a, &env, text, "config.toml", &detail)).codex_run_tool);
    try env.put("NIB_CODEX_RUN_TOOL", "invalid");
    try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail));
    try env.put("NIB_CODEX_RUN_TOOL", "custom");
    for ([_][]const u8{ "[codex]\nrun_tool = \"invalid\"", "[codex]\nrun_tool = true", "[codex]\nrun_tool = \"custom\"\nrun_tool = \"function\"", "[chat_completions]\nrun_tool = \"custom\"" }) |bad| {
        try t.expectError(error.InvalidConfig, resolve(a, &env, bad, "config.toml", &detail));
    }
}

// The caller supplies an arena for the parsed settings.
pub fn loadSkills(a: Allocator, io: std.Io, home_path: []const u8) ![]const SkillSetting {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try read(a, io, path);
    var detail: ?[]u8 = null;
    return (try parse(a, a, text, path, &detail)).skills.items;
}

pub fn loadMcp(a: Allocator, io: std.Io, home_path: []const u8) ![]const @import("mcp/config.zig").Server {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try read(a, io, path);
    var detail: ?[]u8 = null;
    return (try parse(a, a, text, path, &detail)).mcp_servers.items;
}

pub fn loadPlugins(a: Allocator, io: std.Io, home_path: []const u8) ![]const SkillSetting {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try read(a, io, path);
    var detail: ?[]u8 = null;
    return (try parse(a, a, text, path, &detail)).plugins.items;
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
    const text = try read(scratch, io, path);
    var detail: ?[]u8 = null;
    const file = try parse(scratch, scratch, text, path, &detail);
    const value = if (enabled) "true" else "false";
    const newline = if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
    var out: std.ArrayList(u8) = .empty;
    const span: ?Span = for (switch (section) {
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
    const settings = try loadSkills(a, t.io, path);
    try t.expect(!skillEnabled(settings, "hallmark"));
    try t.expect(skillEnabled(settings, "other"));
    try t.expect(!skillEnabled(settings, "absent"));
    var detail: ?[]u8 = null;
    try t.expectError(error.InvalidConfig, parse(a, a, "[skills]\na = \"true\"", "test", &detail));
    try t.expectError(error.InvalidConfig, parse(a, a, "[skills]\na = true\na = false", "test", &detail));
    try t.expectError(error.InvalidConfig, parse(a, a, "effort = true", "test", &detail));
    var env: Env = .init(a);
    defer env.deinit();
    const resolved = try resolve(a, &env, "[skills]\non = true\noff = false", "test", &detail);
    try t.expectEqual(@as(usize, 1), resolved.enabled_skills.len);
    try t.expectEqualStrings("on", resolved.enabled_skills[0]);
}

pub fn enabledSkills(a: Allocator, settings: []const SkillSetting) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (settings) |setting| if (setting.enabled) {
        try names.append(a, try a.dupe(u8, setting.name));
    };
    return names.toOwnedSlice(a);
}

test "built-in catalogs custom providers and environment selection" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(t.allocator);
    defer env.deinit();
    var detail: ?[]u8 = null;
    for (provider.definitions) |entry| {
        try env.put("NIB_PROVIDER", entry.id);
        if (entry.api_key_env.len > 0) try env.put(entry.api_key_env[0], "fake-key");
        const cfg = try resolve(a, &env, "", "config.toml", &detail);
        try t.expectEqualStrings(entry.id, @tagName(cfg.provider));
        try t.expectEqualStrings(entry.default_model, cfg.model);
        try t.expectEqual(entry.protocol, cfg.protocol());
        if (entry.models.len > 0) try t.expectEqual(entry.models[0].context_window, cfg.context_window);
    }
    _ = env.swapRemove("NIB_PROVIDER");
    try env.put("SITE_KEY", "fake-custom-key");
    const text = "provider = \"mysite\"\n[providers.mysite]\nprotocol = \"responses\"\nbase_url = \"http://localhost:1234/v1\"\nmodel = \"code\"\ncontext_window = 12345\napi_key_env = \"SITE_KEY\"\n";
    var cfg = try resolve(a, &env, text, "config.toml", &detail);
    try t.expectEqualStrings("mysite", cfg.name());
    try t.expectEqualStrings("fake-custom-key", cfg.api_key);
    try t.expectEqual(provider.Protocol.responses, cfg.protocol());
    try t.expectEqual(@as(u64, 12345), cfg.context_window);
    try env.put("NIB_MODEL", "override");
    try env.put("NIB_CONTEXT_WINDOW", "9876");
    cfg = try resolve(a, &env, text, "config.toml", &detail);
    try t.expectEqualStrings("override", cfg.model);
    try t.expectEqual(@as(u64, 9876), cfg.context_window);
}

test "custom max_output is an optional positive integer" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(t.allocator);
    defer env.deinit();
    var detail: ?[]u8 = null;
    const head = "provider = \"site\"\n[providers.site]\nprotocol = \"chat_completions\"\nbase_url = \"http://localhost:1/v1\"\nmodel = \"m\"\ncontext_window = 1000\n";
    try t.expectEqual(@as(?u32, null), (try resolve(a, &env, head, "config.toml", &detail)).custom_max_output);
    const set = try std.fmt.allocPrint(a, "{s}max_output = 8_192\n", .{head});
    try t.expectEqual(@as(?u32, 8192), (try resolve(a, &env, set, "config.toml", &detail)).custom_max_output);
    for ([_][]const u8{ "max_output = 0\n", "max_output = -5\n", "max_output = \"8\"\n", "max_output = true\n", "max_output = 5000000000\n" }) |line| {
        const text = try std.fmt.allocPrint(a, "{s}{s}", .{ head, line });
        try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail));
        try t.expect(std.mem.indexOf(u8, detail.?, "max_output must be") != null);
    }
    try t.expectError(error.InvalidConfig, resolve(a, &env, "[openai]\nmax_output = 5\n", "config.toml", &detail));
}

test "custom configuration rejects incomplete duplicate conflicting and secret fields" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "[providers.site]\nmodel = \"x\"",
        "[providers.openai]\n",
        "[providers.site]\n[providers.site]\n",
        "[providers.site]\napi_key = \"secret\"",
        "[providers.site]\nprotocol = \"fourth_protocol\"",
        "[providers.site]\napi_key_env = \"BAD-NAME\"",
        "[openai]\nmodel = \"a\"\nmodel = \"b\"",
        "[provider_dynamic]\n",
    }) |text| {
        var detail: ?[]u8 = null;
        try t.expectError(error.InvalidConfig, parse(a, a, text, "bad/config.toml", &detail));
        try t.expect(std.mem.startsWith(u8, detail.?, "bad/config.toml:"));
    }
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
    const anthropic = try resolve(a, &anthropic_env, custom, "config.toml", &detail);
    const own = try modelEntries(a, t.io, &env, root, anthropic);
    try t.expectEqual(@as(usize, 6), own.len);
    try t.expectEqualStrings("local", own[4].provider);
    try t.expectEqualStrings("locked", own[5].provider);
    var local_env = try env.clone(a);
    try local_env.put("NIB_PROVIDER", "local");
    const local = try resolve(a, &local_env, custom, "config.toml", &detail);
    const listed = try modelEntries(a, t.io, &env, root, local);
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
    try t.expectEqualStrings("provider = \"openai\"\n[openai]\nmodel = \"gpt-6.1-sol\"\n", try tmp.dir.readFileAlloc(t.io, "new/config.toml", a, .unlimited));
}

test "model entries merge environment login store and configured models by service" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var env = try envWithHome(a, root);
    try env.put("OPENAI_API_KEY", "fake");
    try tmp.dir.createDirPath(t.io, "codex");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "codex/auth.json", .data = "{\"tokens\":{\"access_token\":\"a\",\"account_id\":\"b\"}}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "auth.json", .data = "{\"keys\":{\"xai\":\"stored-fake\"}}" });
    const text = "[anthropic]\nmodel = \"claude-private\"\ncontext_window = 1000\n[providers.local]\nprotocol = \"responses\"\nbase_url = \"http://localhost\"\nmodel = \"gpt-6.1-sol\"\ncontext_window = 1000\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.toml", .data = text });
    const cfg: provider.Config = .{ .provider = .openai, .base_url = "", .api_key = "", .model = "gpt-6.1-sol" };
    const entries = try modelEntries(a, t.io, &env, root, cfg);
    var openai_count: usize = 0;
    var local_count: usize = 0;
    var codex_count: usize = 0;
    var xai_count: usize = 0;
    var private_count: usize = 0;
    for (entries) |entry| {
        try t.expect(!std.mem.eql(u8, entry.provider, "deepseek"));
        try t.expect(!std.mem.eql(u8, entry.provider, "chat_completions"));
        if (std.mem.eql(u8, entry.provider, "openai")) openai_count += 1;
        if (std.mem.eql(u8, entry.provider, "local")) local_count += 1;
        if (std.mem.eql(u8, entry.provider, "codex")) codex_count += 1;
        if (std.mem.eql(u8, entry.provider, "xai")) xai_count += 1;
        if (std.mem.eql(u8, entry.model, "claude-private")) private_count += 1;
    }
    try t.expectEqual(provider.definition(.openai).models.len, openai_count);
    try t.expectEqual(@as(usize, 1), local_count);
    try t.expectEqual(provider.definition(.codex).models.len, codex_count);
    try t.expectEqual(provider.definition(.xai).models.len, xai_count);
    try t.expectEqual(@as(usize, 1), private_count);
}

fn envWithHome(a: Allocator, root: []const u8) !Env {
    var env: Env = .init(a);
    try env.put("HOME", root);
    try env.put("NIB_HOME", root);
    try env.put("CODEX_HOME", try std.fs.path.join(a, &.{ root, "codex" }));
    return env;
}

test "startup picks the first credentialed service without persisting" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var env = try envWithHome(a, root);
    var detail: ?[]u8 = null;
    // Nothing credentialed: the configured (default Codex) service stays, flagged as not credentialed.
    var cfg = try load(a, t.io, &env, root, &detail);
    try t.expectEqual(provider.Id.codex, cfg.provider);
    try t.expect(!credentialed(a, t.io, cfg));
    // A stored key for xAI and an env key for OpenAI: built-in order puts OpenAI first.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "auth.json", .data = "{\"keys\":{\"xai\":\"stored-fake\"}}" });
    cfg = try load(a, t.io, &env, root, &detail);
    try t.expectEqual(provider.Id.xai, cfg.provider);
    try t.expectEqual(provider.KeySource.store, cfg.key_source);
    try t.expectEqualStrings("stored-fake", cfg.api_key);
    try env.put("OPENAI_API_KEY", "env-fake");
    cfg = try load(a, t.io, &env, root, &detail);
    try t.expectEqual(provider.Id.openai, cfg.provider);
    try t.expectEqual(provider.KeySource.env, cfg.key_source);
    try env.put("ANTHROPIC_API_KEY", "env-fake");
    try t.expectEqual(provider.Id.anthropic, (try load(a, t.io, &env, root, &detail)).provider);
    // A Codex login outranks every key.
    try tmp.dir.createDirPath(t.io, "codex");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "codex/auth.json", .data = "{\"tokens\":{\"access_token\":\"a\",\"account_id\":\"b\"}}" });
    try t.expectEqual(provider.Id.codex, (try load(a, t.io, &env, root, &detail)).provider);
    // A configured credentialed service wins over the order; an explicit NIB_PROVIDER is never replaced.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.toml", .data = "provider = \"deepseek\"\n" });
    try t.expectEqual(provider.Id.codex, (try load(a, t.io, &env, root, &detail)).provider);
    try env.put("DEEPSEEK_API_KEY", "env-fake");
    try t.expectEqual(provider.Id.deepseek, (try load(a, t.io, &env, root, &detail)).provider);
    try env.put("NIB_PROVIDER", "xai");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "auth.json", .data = "{}" });
    const explicit = try load(a, t.io, &env, root, &detail);
    try t.expectEqual(provider.Id.xai, explicit.provider);
    try t.expect(!credentialed(a, t.io, explicit));
    const config_text = try tmp.dir.readFileAlloc(t.io, "config.toml", a, .unlimited);
    try t.expectEqualStrings("provider = \"deepseek\"\n", config_text);
}

test "custom services come last and a stored key serves a keyless config" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var env = try envWithHome(a, root);
    var detail: ?[]u8 = null;
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.toml", .data = "[providers.site]\nprotocol = \"chat_completions\"\nbase_url = \"http://h\"\nmodel = \"m\"\ncontext_window = 9\napi_key_env = \"SITE_KEY\"\n" });
    try t.expectEqual(provider.Id.codex, (try load(a, t.io, &env, root, &detail)).provider);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "auth.json", .data = "{\"keys\":{\"site\":\"stored-fake\"}}" });
    const cfg = try load(a, t.io, &env, root, &detail);
    try t.expectEqual(provider.Id.custom, cfg.provider);
    try t.expectEqualStrings("site", cfg.name());
    try t.expectEqualStrings("stored-fake", cfg.api_key);
    try t.expectEqualStrings("the key stored by nib (run nib login)", cfg.keyHint());
    try env.put("SITE_KEY", "env-fake");
    try t.expectEqualStrings("env-fake", (try load(a, t.io, &env, root, &detail)).api_key);
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
    const found = try customProviders(a, t.io, root);
    try t.expectEqual(@as(usize, 1), found.len);
    try t.expectEqualStrings("m\"1", found[0].model);
    try t.expectError(error.InvalidConfig, addEndpoint(a, t.io, root, .{ .id = "my-site", .protocol = .responses, .base_url = "http://h", .model = "m", .context_window = 1 }));
    try t.expectEqualStrings(text, try tmp.dir.readFileAlloc(t.io, "config.toml", a, .unlimited));
    try t.expect(endpointIdProblem("", &.{}) != null);
    try t.expect(endpointIdProblem("a b", &.{}) != null);
    try t.expect(endpointIdProblem("openai", &.{}) != null);
    try t.expect(endpointIdProblem("custom", &.{}) != null);
    try t.expect(endpointIdProblem("my-site", &.{"my-site"}) != null);
    try t.expect(endpointIdProblem("ok_1", &.{"other"}) == null);
}

test "hooks parse command arrays and reject unknown duplicate and malformed values" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var detail: ?[]u8 = null;
    const file = try parse(a, a, "[hooks]\nafter_edit = [\"zig fmt {files}\"]\nturn_end = []", "config.toml", &detail);
    try t.expectEqualStrings("zig fmt {files}", file.hooks.after_edit[0]);
    try t.expectEqual(@as(usize, 0), file.hooks.turn_end.len);
    for ([_][]const u8{ "[hooks]\nother = []", "[hooks]\nafter_edit = true", "[hooks]\nafter_edit = [1]", "[hooks]\nafter_edit = []\nafter_edit = []", "[hooks]\n[hooks]", "[hooks]\nturn_end = [\"a\" \"b\"]" }) |bad| {
        try t.expectError(error.InvalidConfig, parse(a, a, bad, "config.toml", &detail));
    }
}

test "MCP config validates transports, names, arrays and switches with line diagnostics" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var detail: ?[]u8 = null;
    const parsed = try parse(a, a, "[mcp]\ngithub = true\n[mcp.github]\ncommand = \"server\"\nargs = [\"stdio\"]\nenv = [\"GITHUB_TOKEN\"]\n[mcp.docs]\nurl = \"https://example.com/mcp\"\nheader_env = \"DOCS_MCP_TOKEN\"\n", "test", &detail);
    try t.expectEqual(@as(usize, 2), parsed.mcp_servers.items.len);
    try t.expect(parsed.mcp_servers.items[0].enabled);
    try t.expect(!parsed.mcp_servers.items[1].enabled);
    try t.expectEqualStrings("GITHUB_TOKEN", parsed.mcp_servers.items[0].env[0]);
    for ([_][]const u8{
        "[mcp.x]\ncommand = \"x\"\nurl = \"http://x\"",
        "[mcp.x]\nargs = []",
        "[mcp.x]\nurl = \"file:///x\"",
        "[mcp.x]\nurl = \"https://user:secret@x\"",
        "[mcp.x]\ncommand = \"x\"\nenv = [\"X=secret\"]",
        "[mcp.x]\ncommand = \"x\"\ncommand = \"y\"",
        "[mcp.x]\ncommand = \"x\"\nheader_env = \"KEY\"",
        "[mcp_dynamic]\ncommand = \"x\"",
        "[mcp]\nx = \"true\"",
        "[mcp.bad.id]\ncommand = \"x\"",
        "[mcp.x]\nurl = \"https://x\"\nargs = [\"x\"]",
    }) |bad| {
        detail = null;
        try t.expectError(error.InvalidConfig, parse(a, a, bad, "test", &detail));
        try t.expect(std.mem.startsWith(u8, detail.?, "test:"));
    }
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
    try t.expect((try loadMcp(a, t.io, home_path))[0].enabled);
}

pub fn saveSimple(a: Allocator, io: std.Io, home_path: []const u8, simple: bool) !void {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    defer a.free(path);
    const text = try read(a, io, path);
    defer a.free(text);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const file = try parse(scratch.allocator(), a, text, path, &detail);
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
        try t.expectEqual(simple, (try resolve(a, &env, text, "test", &detail)).simple);
    }
    for ([_][]const u8{ "ui = true", "ui = \"bad\"", "ui = \"normal\"\nui = \"simple\"" }) |text| try t.expectError(error.InvalidConfig, parse(a, a, text, "test", &detail));
}

test "open command template is an optional non-empty top-level string" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(a);
    defer env.deinit();
    var detail: ?[]u8 = null;
    try t.expect((try resolve(a, &env, "", "test", &detail)).open == null);
    try t.expectEqualStrings("zed {path}:{line}", (try resolve(a, &env, "open = \"zed {path}:{line}\"\n[codex]\n", "test", &detail)).open.?);
    for ([_][]const u8{ "open = \"\"", "open = \"  \"", "open = 3", "open = \"a\"\nopen = \"b\"" }) |text| try t.expectError(error.InvalidConfig, parse(a, a, text, "test", &detail));
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
    try t.expectEqual(@as(usize, 0), (try loadPlugins(a, t.io, path)).len);
    try savePlugin(a, t.io, path, "example", true);
    try savePlugin(a, t.io, path, "other", false);
    try t.expect(skillEnabled(try loadPlugins(a, t.io, path), "example"));
    try t.expect(skillEnabled(try loadSkills(a, t.io, path), "example"));
    try savePlugin(a, t.io, path, "example", false);
    try t.expect(!skillEnabled(try loadPlugins(a, t.io, path), "example"));
    try t.expectError(error.InvalidSkillName, savePlugin(a, t.io, path, "../bad", true));
    const text = try tmp.dir.readFileAlloc(t.io, "config.toml", a, .limited(4096));
    try t.expect(std.mem.startsWith(u8, text, "# retained\n[skills]\nexample = true\n[mcp]\nlocal = false\n"));
}
