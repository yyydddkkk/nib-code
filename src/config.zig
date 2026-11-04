const std = @import("std");
const atomic_file = @import("tools/atomic_file.zig");
const provider = @import("provider.zig");
const codex = @import("provider/codex.zig");
const Allocator = std.mem.Allocator;
const Env = std.process.Environ.Map;

pub fn home(a: Allocator, env: *const Env) ![]const u8 {
    if (env.get("NIB_HOME")) |value| return a.dupe(u8, value);
    return std.fs.path.join(a, &.{ env.get("HOME") orelse return error.MissingHome, ".nib" });
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
    return resolve(a, env, text, path, detail);
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
};
const Span = struct { start: usize, end: usize };
const File = struct {
    top_end: usize = 0,
    limits: provider.Limits = .{},
    provider_id: ?provider.Id = null,
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
    const Section = enum { chat_completions, codex, limits };
    var section: ?Section = null;
    var seen_sections: [3]bool = @splat(false);
    var seen: [4][7]bool = @splat(@splat(false));
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
            if (secretKey(name)) return p.bad("secrets are not allowed; use NIB_API_KEY or DEEPSEEK_API_KEY (Codex uses CODEX_HOME/auth.json)", .{});
            if (section == null) file.top_end = start;
            section = std.meta.stringToEnum(Section, name) orelse return p.bad("unknown section '{s}'", .{name});
            const tail = std.mem.trimStart(u8, line[close + 1 ..], " \t");
            if (tail.len > 0 and tail[0] != '#') return p.bad("unexpected text after section", .{});
            const index = @backingInt(section.?);
            if (seen_sections[index]) return p.bad("duplicate section '{s}'", .{name});
            seen_sections[index] = true;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return p.bad("expected key = value", .{});
        const key = std.mem.trimEnd(u8, line[0..eq], " \t");
        if (secretKey(key)) return p.bad("secrets are not allowed; use NIB_API_KEY or DEEPSEEK_API_KEY (Codex uses CODEX_HOME/auth.json)", .{});
        if (key.len == 0) return p.bad("empty key", .{});
        for (key) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return p.bad("expected a bare key (dotted and quoted keys are unsupported)", .{});
        const index: usize = if (section == null)
            if (std.mem.eql(u8, key, "provider")) 0 else if (std.mem.eql(u8, key, "effort")) 1 else return p.bad("unknown top-level key '{s}'", .{key})
        else if (section == .limits) blk: {
            const names = .{ "llm_concurrency", "llm_calls_per_run", "llm_input_kib", "agent_concurrency", "max_steps", "stream_idle_timeout_s", "race_branches" };
            inline for (names, 0..) |name, i| {
                if (std.mem.eql(u8, key, name)) break :blk i;
            }
            return p.bad("unknown limits key '{s}'", .{key});
        } else if (std.mem.eql(u8, key, "model")) 0 else if (std.mem.eql(u8, key, "base_url")) 1 else if (std.mem.eql(u8, key, "context_window")) 2 else return p.bad("unknown provider key '{s}'", .{key});
        const group: usize = if (section) |id| @as(usize, @backingInt(id)) + 1 else 0;
        if (seen[group][index]) return p.bad("duplicate key '{s}'", .{key});
        seen[group][index] = true;
        const value = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
        var consumed: usize = 0;
        const settings = if (section == .codex) &file.codex_settings else &file.chat_settings;
        const parsed = try p.value(value, &consumed);
        if (section == .limits) {
            if (parsed != .integer) return p.bad("{s} must be an integer", .{key});
            const minima = [_]usize{ 1, 1, 1, 1, 1, 1, 2 };
            const maxima = [_]usize{ 64, 10000, 65536, 64, 100000, 3600, 8 };
            if (parsed.integer < minima[index] or parsed.integer > maxima[index]) return p.bad("{s} must be between {d} and {d}", .{ key, minima[index], maxima[index] });
            const n: usize = @intCast(parsed.integer);
            switch (index) {
                0 => file.limits.llm_concurrency = n,
                1 => file.limits.llm_calls_per_run = n,
                2 => file.limits.llm_input_kib = n,
                3 => file.limits.agent_concurrency = n,
                4 => file.limits.max_steps = n,
                5 => file.limits.stream_idle_timeout_s = n,
                6 => file.limits.race_branches = n,
                else => unreachable,
            }
        } else if (section != null and index == 2) {
            if (parsed != .integer) return p.bad("context_window must be an integer", .{});
            if (parsed.integer <= 0 or parsed.integer > std.math.maxInt(u64)) return p.bad("context_window must be a positive u64 integer", .{});
            settings.context_window = @intCast(parsed.integer);
        } else {
            if (parsed != .string) return p.bad("{s} must be a string", .{key});
            const decoded = parsed.string;
            if (section == null) {
                if (index == 0) {
                    file.provider_id = std.meta.stringToEnum(provider.Id, decoded) orelse return p.bad("provider must be codex or chat_completions", .{});
                } else {
                    file.effort = knownEffort(decoded) orelse return p.bad("invalid effort; expected default|off|none|minimal|low|medium|high|xhigh|max", .{});
                    const value_start = start + @intFromPtr(value.ptr) - @intFromPtr(raw.ptr);
                    file.effort_value = .{ .start = value_start, .end = value_start + consumed };
                    file.effort_line = .{ .start = start, .end = end };
                }
            } else if (index == 0) {
                settings.model = decoded;
                settings.model_line = p.line;
            } else settings.base_url = decoded;
        }
        const tail = std.mem.trimStart(u8, value[consumed..], " \t");
        if (tail.len > 0 and tail[0] != '#') return p.bad("unexpected text after value", .{});
    }
    if (section == null) file.top_end = text.len;
    return file;
}

// Returned string fields are allocated with a, except canonical reasoning_effort values.
pub fn resolve(a: Allocator, env: *const Env, text: []const u8, path: []const u8, detail: *?[]u8) !provider.Config {
    detail.* = null;
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const file = try parse(scratch.allocator(), a, text, path, detail);
    const id = if (env.get("NIB_PROVIDER")) |v| std.meta.stringToEnum(provider.Id, v) orelse {
        detail.* = try a.dupe(u8, "NIB_PROVIDER: expected codex or chat_completions");
        return error.InvalidProvider;
    } else file.provider_id orelse .codex;
    const settings = if (id == .codex) file.codex_settings else file.chat_settings;
    const model = env.get("NIB_MODEL") orelse settings.model orelse if (id == .codex) codex.default_model else @import("provider/openai.zig").default_model;
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
    } else 1_000_000;
    var cfg: provider.Config = .{ .provider = id, .api_key = "", .base_url = "", .model = "", .context_window = context_window, .limits = file.limits };
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
    cfg.base_url = try a.dupe(u8, env.get("NIB_BASE_URL") orelse settings.base_url orelse if (id == .codex) "https://chatgpt.com/backend-api" else "https://api.deepseek.com");
    errdefer a.free(cfg.base_url);
    cfg.api_key = try a.dupe(u8, if (id == .codex) "" else env.get("NIB_API_KEY") orelse env.get("DEEPSEEK_API_KEY") orelse "");
    errdefer a.free(cfg.api_key);
    cfg.codex_home = if (env.get("CODEX_HOME")) |v| try a.dupe(u8, v) else try std.fs.path.join(a, &.{ env.get("HOME") orelse "", ".codex" });
    return cfg;
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

test "limits defaults, bounds and diagnostics" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(t.allocator);
    defer env.deinit();
    var detail: ?[]u8 = null;
    const defaults = (try resolve(a, &env, "", "config.toml", &detail)).limits;
    try t.expectEqualDeep(provider.Limits{ .llm_concurrency = 4, .llm_calls_per_run = 100, .llm_input_kib = 256, .agent_concurrency = 4, .race_branches = 3, .max_steps = null, .stream_idle_timeout_s = 300 }, defaults);
    try t.expectEqualDeep(defaults, (try resolve(a, &env, "[limits]\n", "config.toml", &detail)).limits);
    try t.expectEqual(@as(?usize, null), (try resolve(a, &env, "[limits]\nllm_concurrency = 8\n", "config.toml", &detail)).limits.max_steps);
    try t.expectEqual(@as(?usize, 50), (try resolve(a, &env, "[limits]\nmax_steps = 50\n", "config.toml", &detail)).limits.max_steps);
    const names = [_][]const u8{ "llm_concurrency", "llm_calls_per_run", "llm_input_kib", "agent_concurrency", "max_steps", "stream_idle_timeout_s", "race_branches" };
    const minima = [_]usize{ 1, 1, 1, 1, 1, 1, 2 };
    const maxima = [_]usize{ 64, 10000, 65536, 64, 100000, 3600, 8 };
    for (names, minima, maxima) |name, min, max| {
        for ([_]usize{ min, max }) |n| {
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
        for ([_]usize{ min - 1, max + 1 }) |n| {
            const text = try std.fmt.allocPrint(a, "[limits]\n{s} = {d}\n", .{ name, n });
            try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail));
            try t.expect(std.mem.startsWith(u8, detail.?, "config.toml:2:"));
            const range = try std.fmt.allocPrint(a, "between {d} and {d}", .{ min, max });
            try t.expect(std.mem.indexOf(u8, detail.?, range) != null);
        }
    }
    for ([_][]const u8{ "[limits]\nunknown = 1", "[limits]\nmax_steps = 1\nmax_steps = 2", "[limits]\n[limits]" }) |text| {
        try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail));
        try t.expect(std.mem.startsWith(u8, detail.?, "config.toml:"));
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
