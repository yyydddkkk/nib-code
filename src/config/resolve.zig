const std = @import("std");
const provider = @import("../provider.zig");
const codex = @import("../provider/responses.zig");
const auth = @import("../auth.zig");
const parse_mod = @import("parse.zig");
const Allocator = std.mem.Allocator;
const Env = std.process.Environ.Map;

pub const startup_order = [_][]const u8{ "codex", "anthropic", "openai", "deepseek", "xai" };

pub fn load(a: Allocator, io: std.Io, env: *const Env, home_path: []const u8, detail: *?[]u8) !provider.Config {
    detail.* = null;
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    defer a.free(path);
    const text = parse_mod.read(a, io, path) catch |err| {
        detail.* = try std.fmt.allocPrint(a, "{s}:1: cannot read configuration: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer a.free(text);
    var credentials = try auth.Lookup.init(a, io, env, home_path);
    defer credentials.deinit();
    const cfg = try resolve(a, env, text, path, detail, &credentials);
    if (env.get("NIB_PROVIDER") == null and !auth.current(a, io, cfg).available()) {
        if (try pickCredentialed(a, io, &credentials, text, path)) |picked| return picked;
    }
    return cfg;
}

/// First credentialed service: Codex login, built-in keys, then custom services. Not persisted.
fn pickCredentialed(a: Allocator, io: std.Io, credentials: *auth.Lookup, text: []const u8, path: []const u8) !?provider.Config {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var detail: ?[]u8 = null;
    const file = try parse_mod.parse(scratch.allocator(), a, text, path, &detail);
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(scratch.allocator(), &startup_order);
    for (file.providers.items) |item| if (item.custom) try names.append(scratch.allocator(), item.name);
    var picked_env = try credentials.env.clone(scratch.allocator());
    for ([_][]const u8{ "NIB_MODEL", "NIB_BASE_URL", "NIB_CONTEXT_WINDOW" }) |name| _ = picked_env.swapRemove(name);
    for (names.items) |name| {
        try picked_env.put("NIB_PROVIDER", name);
        var d: ?[]u8 = null;
        const cfg = resolve(a, &picked_env, text, path, &d, credentials) catch continue;
        if (auth.current(a, io, cfg).available()) return cfg;
    }
    return null;
}

pub const Custom = struct { id: []const u8, protocol: provider.Protocol, base_url: []const u8, model: []const u8, context_window: u64, api_key_env: ?[]const u8 };

/// Custom `[providers.<id>]` services in file order, allocated with `a`.
pub fn customProviders(a: Allocator, io: std.Io, home_path: []const u8) ![]const Custom {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try parse_mod.read(a, io, path);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    var detail: ?[]u8 = null;
    const file = try parse_mod.parse(scratch.allocator(), a, text, path, &detail);
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

// Returned string fields are allocated with a, except canonical reasoning_effort values.
pub fn resolve(a: Allocator, env: *const Env, text: []const u8, path: []const u8, detail: *?[]u8, credentials: ?*auth.Lookup) !provider.Config {
    detail.* = null;
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const file = try parse_mod.parse(scratch.allocator(), a, text, path, detail);
    const name = env.get("NIB_PROVIDER") orelse file.provider_name orelse "codex";
    const id = std.meta.stringToEnum(provider.Id, name) orelse .custom;
    var settings: parse_mod.Settings = if (id == .codex) file.codex_settings else if (id == .chat_completions) file.chat_settings else .{};
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
        return parse_mod.fail(a, detail, path, settings.model_line, "unknown model context window; set context_window or NIB_CONTEXT_WINDOW", .{});
    };
    var cfg: provider.Config = .{ .provider = id, .api_key = "", .base_url = "", .model = "", .context_window = context_window, .limits = file.limits };
    if (id == .custom) {
        cfg.custom_provider = try a.dupe(u8, name);
        cfg.custom_protocol = settings.protocol.?;
        cfg.custom_vision = settings.vision;
        cfg.custom_max_output = settings.max_output;
    }
    cfg.api_key_env = settings.api_key_env;
    cfg.codex_transport = if (env.get("NIB_CODEX_TRANSPORT")) |v| std.meta.stringToEnum(provider.Transport, v) orelse {
        detail.* = try a.dupe(u8, "NIB_CODEX_TRANSPORT: expected websocket or sse");
        return error.InvalidConfig;
    } else file.codex_settings.transport;
    cfg.codex_fast = id == .codex and file.codex_fast;
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
        _ = @import("../session/tuning.zig").Resolved.override(.{}, a, spec, &message) catch |err| {
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
        const effort = parse_mod.knownEffort(v) orelse {
            detail.* = try a.dupe(u8, "NIB_REASONING_EFFORT: expected default|off|none|minimal|low|medium|high|xhigh|max");
            return error.InvalidReasoningEffort;
        };
        if (std.mem.eql(u8, effort, "off")) cfg.thinking = false else if (!std.mem.eql(u8, effort, "default")) cfg.reasoning_effort = effort;
    }
    cfg.model = try a.dupe(u8, model);
    errdefer a.free(cfg.model);
    cfg.base_url = try a.dupe(u8, env.get("NIB_BASE_URL") orelse settings.base_url orelse entry.base_url);
    errdefer a.free(cfg.base_url);
    var env_only: auth.Lookup = .{ .env = env };
    try (credentials orelse &env_only).apply(a, &cfg);
    cfg.enabled_skills = try parse_mod.enabledSkills(a, file.skills.items);
    cfg.enabled_plugins = try parse_mod.enabledSkills(a, file.plugins.items);
    inline for (.{ "after_edit", "turn_end" }) |event| {
        const commands = try a.alloc([]const u8, @field(file.hooks, event).len);
        for (@field(file.hooks, event), commands) |command, *copy| copy.* = try a.dupe(u8, command);
        @field(cfg.hooks, event) = commands;
    }
    cfg.mcp_servers = try @import("../mcp/config.zig").copy(a, file.mcp_servers.items);
    cfg.sandbox.mode = if (env.get("NIB_SANDBOX")) |v| std.meta.stringToEnum(@FieldType(provider.Sandbox, "mode"), v) orelse {
        detail.* = try a.dupe(u8, "NIB_SANDBOX: expected workspace or off");
        return error.InvalidConfig;
    } else file.sandbox.mode;
    const roots = try a.alloc([]const u8, file.sandbox.writable.len);
    for (file.sandbox.writable, roots) |configured, *root| root.* = try @import("../tools/bash/jail.zig").expandHome(a, env.get("HOME") orelse "", configured);
    cfg.sandbox.writable = roots;
    return cfg;
}

pub const ModelEntry = struct { provider: []const u8, model: []const u8 };

/// Catalog and configured models of configured or signed-in services, plus the active model.
pub fn modelEntries(a: Allocator, io: std.Io, env: *const Env, home_path: []const u8, cfg: provider.Config) ![]const ModelEntry {
    const path = try std.fs.path.join(a, &.{ home_path, "config.toml" });
    const text = try parse_mod.read(a, io, path);
    var detail: ?[]u8 = null;
    const file = try parse_mod.parse(a, a, text, path, &detail);
    var credentials = try auth.Lookup.init(a, io, env, home_path);
    defer credentials.deinit();
    var entries: std.ArrayList(ModelEntry) = .empty;
    for (provider.definitions) |entry| {
        const configured = for (file.providers.items) |item| {
            if (std.mem.eql(u8, item.name, entry.id)) break true;
        } else false;
        const selected = if (file.provider_name) |name| std.mem.eql(u8, name, entry.id) else false;
        if (!configured and !selected and !std.mem.eql(u8, entry.id, cfg.name())) {
            // Do not advertise the compatibility identity as an additional service.
            const id = std.meta.stringToEnum(provider.Id, entry.id).?;
            if (id == .chat_completions or !(try credentials.inspect(a, io, id, entry.id, null)).source.available()) continue;
        }
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

pub fn envWithHome(a: Allocator, root: []const u8) !Env {
    var env: Env = .init(a);
    try env.put("HOME", root);
    try env.put("NIB_HOME", root);
    try env.put("CODEX_HOME", try std.fs.path.join(a, &.{ root, "codex" }));
    return env;
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
    var cfg = try resolve(a, &env, "", "test/config.toml", &detail, null);
    try t.expectEqual(provider.Id.codex, cfg.provider);
    try t.expectEqualStrings("gpt-6.2-sol", cfg.model);
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
    cfg = try resolve(a, &env, text, "test/config.toml", &detail, null);
    try t.expectEqualStrings("file-model", cfg.model);
    try t.expectEqualStrings("https://chat.test", cfg.base_url);
    try t.expectEqual(@as(u64, 100000), cfg.context_window);
    try t.expectEqualStrings("medium", cfg.reasoning_effort.?);
    try env.put("NIB_PROVIDER", "codex");
    cfg = try resolve(a, &env, text, "test/config.toml", &detail, null);
    try t.expectEqualStrings("gpt-6-sol", cfg.model);
    try t.expectEqualStrings("https://codex.test", cfg.base_url);
    try t.expectEqual(@as(u64, 200000), cfg.context_window);
    try env.put("NIB_MODEL", "env-model");
    try env.put("NIB_BASE_URL", "https://env.test");
    try env.put("NIB_CONTEXT_WINDOW", "12345");
    try env.put("NIB_REASONING_EFFORT", "low");
    try env.put("NIB_API_KEY", "mock");
    cfg = try resolve(a, &env, text, "test/config.toml", &detail, null);
    try t.expectEqualStrings("env-model", cfg.model);
    try t.expectEqualStrings("https://env.test", cfg.base_url);
    try t.expectEqual(@as(u64, 12345), cfg.context_window);
    try t.expectEqualStrings("", cfg.api_key);
    try t.expectEqualStrings("low", cfg.reasoning_effort.?);
    try env.put("NIB_THINKING", "off");
    cfg = try resolve(a, &env, text, "test/config.toml", &detail, null);
    try t.expectEqual(@as(?bool, false), cfg.thinking);
    try cfg.setEffort("high");
    try t.expectEqualStrings("high", cfg.reasoning_effort.?);
    try t.expectEqual(@as(?bool, true), cfg.thinking);
    try cfg.setEffort("default");
    try t.expectEqual(@as(?bool, null), cfg.thinking);
    try t.expectEqual(@as(?[]const u8, null), cfg.reasoning_effort);
    try env.put("NIB_PROVIDER", "chat_completions");
    cfg = try resolve(a, &env, text, "test/config.toml", &detail, null);
    try t.expectEqualStrings("mock", cfg.api_key);
    for (provider.Config.effort_values) |effort| {
        const file_text = try std.fmt.allocPrint(a, "effort = \"{s}\"", .{effort});
        var empty: Env = .init(t.allocator);
        defer empty.deinit();
        const file_cfg = try resolve(a, &empty, file_text, "test/config.toml", &detail, null);
        var expected: provider.Config = .{ .base_url = "", .model = "", .api_key = "" };
        try expected.setEffort(effort);
        try t.expectEqual(expected.thinking, file_cfg.thinking);
        try t.expectEqualStrings(expected.reasoning_effort orelse "", file_cfg.reasoning_effort orelse "");
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
    var cfg = try resolve(a, &env, "", "config.toml", &detail, null);
    try t.expectEqualStrings("deepseek-flash", cfg.model);
    try t.expectEqualStrings("https://api.deepseek.com", cfg.base_url);
    try t.expectEqual(@as(u64, 1000000), cfg.context_window);
    try t.expect(!auth.current(a, t.io, cfg).available());
    try env.put("DEEPSEEK_API_KEY", "mock-fallback");
    try t.expectEqualStrings("mock-fallback", (try resolve(a, &env, "", "config.toml", &detail, null)).api_key);
    try env.put("NIB_PROVIDER", "codex");
    try env.put("NIB_MODEL", "gpt-6-sol");
    cfg = try resolve(a, &env, "", "config.toml", &detail, null);
    try t.expectEqual(@as(u64, 272000), cfg.context_window);
    try cfg.checkSession(.codex);
    try t.expectError(error.SessionProviderMismatch, cfg.checkSession(.chat_completions));
    try env.put("NIB_MODEL", "unknown");
    try t.expectError(error.UnknownCodexModelContextWindow, resolve(a, &env, "", "config.toml", &detail, null));
    try env.put("NIB_CONTEXT_WINDOW", "10000");
    try t.expectEqual(@as(u64, 10000), (try resolve(a, &env, "", "config.toml", &detail, null)).context_window);
    try env.put("NIB_CONTEXT_WINDOW", "bad");
    try t.expectError(error.InvalidContextWindow, resolve(a, &env, "", "config.toml", &detail, null));
    try env.put("NIB_CONTEXT_WINDOW", "0");
    try t.expectError(error.InvalidContextWindow, resolve(a, &env, "", "config.toml", &detail, null));
    try env.put("NIB_CONTEXT_WINDOW", "10000");
    try env.put("NIB_THINKING", "invalid");
    try t.expectError(error.InvalidThinking, resolve(a, &env, "", "config.toml", &detail, null));
    try env.put("NIB_THINKING", "on");
    cfg = try resolve(a, &env, "effort = \"off\"", "config.toml", &detail, null);
    try t.expectEqual(@as(?bool, true), cfg.thinking);
    try t.expectEqual(@as(?[]const u8, null), cfg.reasoning_effort);
    try env.put("NIB_REASONING_EFFORT", "invalid");
    try t.expectError(error.InvalidReasoningEffort, resolve(a, &env, "", "config.toml", &detail, null));
    try env.put("NIB_PROVIDER", "invalid");
    try t.expectError(error.InvalidProvider, resolve(a, &env, "", "config.toml", &detail, null));
}

test "NIB_TUNE is validated at startup" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(a);
    var detail: ?[]u8 = null;
    try env.put("NIB_TUNE", "delivery=tool");
    _ = try resolve(a, &env, "", "config.toml", &detail, null);
    try env.put("NIB_TUNE", "delivery=short");
    try t.expectError(error.InvalidTuning, resolve(a, &env, "", "config.toml", &detail, null));
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
    const defaults = (try resolve(a, &env, "", "config.toml", &detail, null)).limits;
    try t.expectEqualDeep(provider.Limits{ .llm_concurrency = 4, .llm_calls_per_run = 100, .llm_input_kib = 256, .agent_concurrency = 4, .max_steps = null, .stream_idle_timeout_s = 300 }, defaults);
    try t.expectEqualDeep(defaults, (try resolve(a, &env, "[limits]\n", "config.toml", &detail, null)).limits);
    try t.expectEqual(@as(?usize, null), (try resolve(a, &env, "[limits]\nllm_concurrency = 8\n", "config.toml", &detail, null)).limits.max_steps);
    try t.expectEqual(@as(?usize, 50), (try resolve(a, &env, "[limits]\nmax_steps = 50\n", "config.toml", &detail, null)).limits.max_steps);
    const names = [_][]const u8{ "llm_concurrency", "llm_calls_per_run", "llm_input_kib", "agent_concurrency", "max_steps", "stream_idle_timeout_s", "run_background_after_ms", "stream_content_timeout_s", "request_timeout_s" };
    const maxima = [_]usize{ 64, 10000, 65536, 64, 100000, 3600, 3600000, 3600, 3600 };
    for (names, maxima) |name, max| {
        for ([_]usize{ 1, max }) |n| {
            const text = try std.fmt.allocPrint(a, "[limits]\n{s} = {d}\n", .{ name, n });
            const limits = (try resolve(a, &env, text, "config.toml", &detail, null)).limits;
            inline for (names) |field| {
                if (std.mem.eql(u8, name, field)) try t.expectEqual(@as(@TypeOf(@field(limits, field)), n), @field(limits, field));
            }
        }
        const values = [_][]const u8{ "0", "-1", "true", "\"1\"", "1.5" };
        for (values) |value| {
            const text = try std.fmt.allocPrint(a, "[limits]\n{s} = {s}\n", .{ name, value });
            try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail, null));
            try t.expect(std.mem.startsWith(u8, detail.?, "config.toml:2:"));
        }
        const text = try std.fmt.allocPrint(a, "[limits]\n{s} = {d}\n", .{ name, max + 1 });
        try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail, null));
        try t.expect(std.mem.startsWith(u8, detail.?, "config.toml:2:"));
    }
    for ([_][]const u8{ "[limits]\nunknown = 1", "[limits]\nmax_steps = 1\nmax_steps = 2", "[limits]\n[limits]" }) |text| {
        try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail, null));
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
    const defaults = try resolve(a, &env, "", "config.toml", &detail, null);
    try t.expectEqual(.off, defaults.sandbox.mode);
    try t.expectEqual(@as(usize, 0), defaults.sandbox.writable.len);
    const text = "[sandbox]\nmode = \"off\" # trusted machine\nwritable = [\"~/extra\", \"/data/shared\",]\n";
    const file = try resolve(a, &env, text, "config.toml", &detail, null);
    try t.expectEqual(.off, file.sandbox.mode);
    try t.expectEqual(@as(usize, 2), file.sandbox.writable.len);
    try t.expectEqualStrings("/home/u/extra", file.sandbox.writable[0]);
    try t.expectEqualStrings("/data/shared", file.sandbox.writable[1]);
    try t.expectEqual(.workspace, (try resolve(a, &env, "[sandbox]\nmode = \"workspace\"", "config.toml", &detail, null)).sandbox.mode);
    try env.put("NIB_SANDBOX", "workspace");
    try t.expectEqual(.workspace, (try resolve(a, &env, text, "config.toml", &detail, null)).sandbox.mode);
    try env.put("NIB_SANDBOX", "off");
    try t.expectEqual(.off, (try resolve(a, &env, "[sandbox]\nmode = \"workspace\"", "config.toml", &detail, null)).sandbox.mode);
    try env.put("NIB_SANDBOX", "maybe");
    try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail, null));
    try t.expect(std.mem.startsWith(u8, detail.?, "NIB_SANDBOX:"));
    for ([_][]const u8{ "[sandbox]\nmode = \"on\"", "[sandbox]\nmode = 1", "[sandbox]\nunknown = 1", "[sandbox]\nmode = \"off\"\nmode = \"off\"", "[sandbox]\nwritable = [\"relative\"]", "[sandbox]\nwritable = [\"/a\"", "[sandbox]\nwritable = \"/a\"", "[sandbox]\nwritable = [\"/a\" \"/b\"]", "[sandbox]\n[sandbox]" }) |bad| {
        var clean: Env = .init(a);
        try t.expectError(error.InvalidConfig, resolve(a, &clean, bad, "config.toml", &detail, null));
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
    const defaults = try resolve(a, &env, "", "config.toml", &detail, null);
    try t.expectEqual(.off, defaults.reasoning_summary);
    try t.expectEqual(@as(usize, 16384), defaults.limits.run_output_bytes);
    const text = "[codex]\nreasoning_summary = \"auto\"\n[limits]\nrun_output_bytes = 32768\n";
    const file = try resolve(a, &env, text, "config.toml", &detail, null);
    try t.expectEqual(.auto, file.reasoning_summary);
    try t.expectEqual(@as(usize, 32768), file.limits.run_output_bytes);
    try env.put("NIB_REASONING_SUMMARY", "off");
    try env.put("NIB_RUN_OUTPUT_BYTES", "65536");
    const overridden = try resolve(a, &env, text, "config.toml", &detail, null);
    try t.expectEqual(.off, overridden.reasoning_summary);
    try t.expectEqual(@as(usize, 65536), overridden.limits.run_output_bytes);
    for ([_][]const u8{ "0", "16383", "16777217", "many" }) |value| {
        try env.put("NIB_RUN_OUTPUT_BYTES", value);
        try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail, null));
    }
    _ = env.swapRemove("NIB_RUN_OUTPUT_BYTES");
    try env.put("NIB_REASONING_SUMMARY", "invalid");
    try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail, null));
    for ([_][]const u8{ "[codex]\nreasoning_summary = \"invalid\"", "[limits]\nrun_output_bytes = 16383", "[limits]\nrun_output_bytes = 16777217", "[limits]\nrun_output_bytes = true" }) |invalid| {
        try t.expectError(error.InvalidConfig, parse_mod.parse(a, a, invalid, "config.toml", &detail));
    }
}

test "Codex transport defaults, TOML selection and environment precedence" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(t.allocator);
    defer env.deinit();
    var detail: ?[]u8 = null;
    try t.expectEqual(provider.Transport.websocket, (try resolve(a, &env, "", "config.toml", &detail, null)).codex_transport);
    const text = "[codex]\ntransport = \"sse\"\n";
    try t.expectEqual(provider.Transport.sse, (try resolve(a, &env, text, "config.toml", &detail, null)).codex_transport);
    try env.put("NIB_CODEX_TRANSPORT", "websocket");
    try t.expectEqual(provider.Transport.websocket, (try resolve(a, &env, text, "config.toml", &detail, null)).codex_transport);
    try env.put("NIB_CODEX_TRANSPORT", "sse");
    try t.expectEqual(provider.Transport.sse, (try resolve(a, &env, "", "config.toml", &detail, null)).codex_transport);
    try env.put("NIB_CODEX_TRANSPORT", "invalid");
    try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail, null));
    try t.expectError(error.InvalidConfig, parse_mod.parse(a, a, "[codex]\ntransport = \"invalid\"\n", "config.toml", &detail));
    try t.expectError(error.InvalidConfig, parse_mod.parse(a, a, "[chat_completions]\ntransport = \"websocket\"\n", "config.toml", &detail));
}

test "Codex Run tool defaults custom with validated file and environment fallback" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(a);
    var detail: ?[]u8 = null;
    try t.expectEqual(.custom, (try resolve(a, &env, "", "config.toml", &detail, null)).codex_run_tool);
    const text = "[codex]\nrun_tool = \"function\"";
    try t.expectEqual(.function, (try resolve(a, &env, text, "config.toml", &detail, null)).codex_run_tool);
    try env.put("NIB_CODEX_RUN_TOOL", "custom");
    try t.expectEqual(.custom, (try resolve(a, &env, text, "config.toml", &detail, null)).codex_run_tool);
    try env.put("NIB_CODEX_RUN_TOOL", "invalid");
    try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail, null));
    try env.put("NIB_CODEX_RUN_TOOL", "custom");
    for ([_][]const u8{ "[codex]\nrun_tool = \"invalid\"", "[codex]\nrun_tool = true", "[codex]\nrun_tool = \"custom\"\nrun_tool = \"function\"", "[chat_completions]\nrun_tool = \"custom\"" }) |bad| {
        try t.expectError(error.InvalidConfig, resolve(a, &env, bad, "config.toml", &detail, null));
    }
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
        const cfg = try resolve(a, &env, "", "config.toml", &detail, null);
        try t.expectEqualStrings(entry.id, @tagName(cfg.provider));
        try t.expectEqualStrings(entry.default_model, cfg.model);
        try t.expectEqual(entry.protocol, cfg.protocol());
        if (entry.models.len > 0) try t.expectEqual(entry.models[0].context_window, cfg.context_window);
    }
    _ = env.swapRemove("NIB_PROVIDER");
    try env.put("SITE_KEY", "fake-custom-key");
    const text = "provider = \"mysite\"\n[providers.mysite]\nprotocol = \"responses\"\nbase_url = \"http://localhost:1234/v1\"\nmodel = \"code\"\ncontext_window = 12345\napi_key_env = \"SITE_KEY\"\n";
    var cfg = try resolve(a, &env, text, "config.toml", &detail, null);
    try t.expectEqualStrings("mysite", cfg.name());
    try t.expectEqualStrings("fake-custom-key", cfg.api_key);
    try t.expectEqual(provider.Protocol.responses, cfg.protocol());
    try t.expectEqual(@as(u64, 12345), cfg.context_window);
    try env.put("NIB_MODEL", "override");
    try env.put("NIB_CONTEXT_WINDOW", "9876");
    cfg = try resolve(a, &env, text, "config.toml", &detail, null);
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
    try t.expectEqual(@as(?u32, null), (try resolve(a, &env, head, "config.toml", &detail, null)).custom_max_output);
    const set = try std.fmt.allocPrint(a, "{s}max_output = 8_192\n", .{head});
    try t.expectEqual(@as(?u32, 8192), (try resolve(a, &env, set, "config.toml", &detail, null)).custom_max_output);
    for ([_][]const u8{ "max_output = 0\n", "max_output = -5\n", "max_output = \"8\"\n", "max_output = true\n", "max_output = 5000000000\n" }) |line| {
        const text = try std.fmt.allocPrint(a, "{s}{s}", .{ head, line });
        try t.expectError(error.InvalidConfig, resolve(a, &env, text, "config.toml", &detail, null));
        try t.expect(std.mem.indexOf(u8, detail.?, "max_output must be") != null);
    }
    try t.expectError(error.InvalidConfig, resolve(a, &env, "[openai]\nmax_output = 5\n", "config.toml", &detail, null));
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
    try t.expect(!auth.current(a, t.io, cfg).available());
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
    const cli = try load(a, t.io, &env, root, &detail);
    try t.expectEqual(provider.Id.codex, cli.provider);
    try t.expectEqualStrings("ChatGPT login from the Codex CLI", auth.describe(a, t.io, cli));
    // A configured credentialed service wins over the order; an explicit NIB_PROVIDER is never replaced.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.toml", .data = "provider = \"deepseek\"\n" });
    try t.expectEqual(provider.Id.codex, (try load(a, t.io, &env, root, &detail)).provider);
    try env.put("DEEPSEEK_API_KEY", "env-fake");
    try t.expectEqual(provider.Id.deepseek, (try load(a, t.io, &env, root, &detail)).provider);
    try env.put("NIB_PROVIDER", "xai");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "auth.json", .data = "{}" });
    const explicit = try load(a, t.io, &env, root, &detail);
    try t.expectEqual(provider.Id.xai, explicit.provider);
    try t.expect(!auth.current(a, t.io, explicit).available());
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

test "open command template is an optional non-empty top-level string" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Env = .init(a);
    defer env.deinit();
    var detail: ?[]u8 = null;
    try t.expect((try resolve(a, &env, "", "test", &detail, null)).open == null);
    try t.expectEqualStrings("zed {path}:{line}", (try resolve(a, &env, "open = \"zed {path}:{line}\"\n[codex]\n", "test", &detail, null)).open.?);
    for ([_][]const u8{ "open = \"\"", "open = \"  \"", "open = 3", "open = \"a\"\nopen = \"b\"" }) |text| try t.expectError(error.InvalidConfig, parse_mod.parse(a, a, text, "test", &detail));
}
