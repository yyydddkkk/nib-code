const mode = @import("../tui/mode.zig");
const std = @import("std");
const provider = @import("../provider.zig");
const Allocator = std.mem.Allocator;

pub const Settings = struct {
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

pub fn enabledSkills(a: Allocator, settings: []const SkillSetting) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (settings) |setting| if (setting.enabled) {
        try names.append(a, try a.dupe(u8, setting.name));
    };
    return names.toOwnedSlice(a);
}

pub const Span = struct { start: usize, end: usize };
pub const ProviderSetting = struct { name: []const u8, settings: Settings = .{}, line: usize, seen: [11]bool = @splat(false), custom: bool };

pub const File = struct {
    providers: std.ArrayList(ProviderSetting) = .empty,
    provider_name: ?[]const u8 = null,
    provider_line: usize = 1,
    skills: std.ArrayList(SkillSetting) = .empty,
    skills_end: ?usize = null,
    mcp: std.ArrayList(SkillSetting) = .empty,
    mcp_end: ?usize = null,
    plugins: std.ArrayList(SkillSetting) = .empty,
    plugins_end: ?usize = null,
    mcp_servers: std.ArrayList(@import("../mcp/config.zig").Server) = .empty,
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
    codex_body_start: ?usize = null,
    fast_value: ?Span = null,
    codex_fast: bool = false,
    chat_settings: Settings = .{},
    effort_value: ?Span = null,
    effort_line: ?Span = null,
};

pub fn read(a: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => a.dupe(u8, ""),
        else => return err,
    };
}

pub fn endpointIdProblem(id: []const u8, existing: []const []const u8) ?[]const u8 {
    if (id.len == 0) return "Name cannot be empty";
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return "Use letters, digits, _ and - only";
    if (std.meta.stringToEnum(provider.Id, id) != null) return "Name is taken by a built-in service";
    for (existing) |name| if (std.mem.eql(u8, name, id)) return "Name is already used";
    return null;
}

pub fn fail(a: Allocator, detail: *?[]u8, path: []const u8, line: usize, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, InvalidConfig } {
    const message = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(message);
    detail.* = try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ path, line, message });
    return error.InvalidConfig;
}

pub fn knownEffort(value: []const u8) ?[]const u8 {
    for (provider.Config.effort_values) |v| if (std.mem.eql(u8, v, value)) return v;
    return null;
}

pub const Parser = struct {
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

    pub const Value = union(enum) { string: []const u8, integer: i128, boolean: bool };

    pub fn value(p: Parser, input: []const u8, consumed: *usize) !Value {
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

pub fn parse(a: Allocator, diagnostics: Allocator, text: []const u8, path: []const u8, detail: *?[]u8) !File {
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
            if (section == .codex) file.codex_body_start = end;
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
                    for (values) |v| if (!@import("../mcp/config.zig").envName(v)) return p.bad("invalid environment variable name", .{});
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
                        if (!@import("../mcp/config.zig").envName(parsed.string)) return p.bad("invalid environment variable name", .{});
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
        } else if (std.mem.eql(u8, key, "model")) 0 else if (std.mem.eql(u8, key, "base_url")) 1 else if (std.mem.eql(u8, key, "context_window")) 2 else if (section == .codex and std.mem.eql(u8, key, "transport")) 3 else if (section == .codex and std.mem.eql(u8, key, "reasoning_summary")) 4 else if (section == .codex and std.mem.eql(u8, key, "run_tool")) 5 else if (section == .provider_dynamic and file.providers.items[current_provider].custom and std.mem.eql(u8, key, "protocol")) 6 else if (section == .provider_dynamic and file.providers.items[current_provider].custom and std.mem.eql(u8, key, "api_key_env")) 7 else if (section == .provider_dynamic and file.providers.items[current_provider].custom and std.mem.eql(u8, key, "vision")) 8 else if (section == .provider_dynamic and file.providers.items[current_provider].custom and std.mem.eql(u8, key, "max_output")) 10 else if (section == .codex and std.mem.eql(u8, key, "fast")) 9 else return p.bad("unknown provider key '{s}'", .{key});
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
        } else if (section == .codex and index == 9) {
            if (parsed != .boolean) return p.bad("fast must be true or false", .{});
            file.codex_fast = parsed.boolean;
            const value_start = start + @intFromPtr(value.ptr) - @intFromPtr(raw.ptr);
            file.fast_value = .{ .start = value_start, .end = value_start + consumed };
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
