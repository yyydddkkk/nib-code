const std = @import("std");
const tools = @import("../tools.zig");
const sandbox = @import("../sandbox.zig");
const Profile = @import("profile.zig").Profile;

pub const tools_json =
    \\[{"type":"function","function":{"name":"run",
    \\"description":"Run JavaScript in a fresh sandbox. The `tools` API it can call is described in the system prompt.",
    \\"parameters":{"type":"object","properties":{"code":{"type":"string",
    \\"description":"JavaScript source. Top-level await is allowed; the last expression's value is returned."}},
    \\"required":["code"]}}}]
;

/// Prompt lines that compensate for current models. Each id is registered in
/// docs/compromises.md; NIB_PATCHES_OFF=<id,...|all> drops them so their effect can be measured.
/// Patches with `default_on = false` are added only by NIB_PATCHES_ON=<id,...>; OFF wins over ON.
pub const Patch = struct { id: []const u8, text: []const u8, applies_to: Profile.Set = Profile.all, default_on: bool = true };

pub const patches = [_]Patch{
    .{
        .id = "json-escape",
        .text =
        \\For file/shell text with backticks, ${ or backslashes, use JSON-escaped double-quoted strings, not template literals, e.g. content: "` ${x} \\path \"quoted\"\n"
        ,
    },
    .{ .id = "no-shell-search", .text = "Search with tools.grep/tools.glob, not shell rg/find/grep." },
    .{
        .id = "expected-continuation",
        .text = "A Run can continue while results match expectations and return at the first unexpected result. Command output redirected to a file can be read within the same Run, returning only the needed portion.",
    },
    .{
        .id = "run-build-test",
        .text = "The same Run can then build and test, returning only what you need (such as failures).",
    },
    .{
        .id = "single-validation",
        .text = "Before full builds/tests, finish implementation, known regression tests, expected results/fixtures and formatting; aim for one full validation. On failure, fix the failures and revalidate. Keep all necessary checks.",
    },
    .{
        .id = "existing-tests-only",
        .text = "Run the project's existing tests or checks when they exist. Unless the user asks, do not write new test scripts or install toolchains only to verify your work.",
        .default_on = false,
    },
};

pub fn patchLines(a: std.mem.Allocator, environ: ?*const std.process.Environ.Map, profile: Profile) ![]const u8 {
    return renderPatches(a, &patches, environ, profile);
}

fn renderPatches(a: std.mem.Allocator, list: []const Patch, environ: ?*const std.process.Environ.Map, profile: Profile) ![]const u8 {
    const off = envValue(environ, "NIB_PATCHES_OFF");
    const on = envValue(environ, "NIB_PATCHES_ON");
    var out: std.ArrayList(u8) = .empty;
    for (list) |patch| {
        if (!patch.applies_to.contains(profile) or patchDisabled(off, patch.id)) continue;
        if (!patch.default_on and !patchListed(on, patch.id)) continue;
        try out.print(a, "- {s}\n", .{patch.text});
    }
    return out.toOwnedSlice(a);
}

fn envValue(environ: ?*const std.process.Environ.Map, name: []const u8) []const u8 {
    return if (environ) |e| e.get(name) orelse "" else "";
}

fn patchListed(list: []const u8, id: []const u8) bool {
    var ids = std.mem.splitScalar(u8, list, ',');
    while (ids.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " "), id)) return true;
    }
    return false;
}

fn patchDisabled(off: []const u8, id: []const u8) bool {
    return patchListed(off, "all") or patchListed(off, id);
}

fn sortedIds(a: std.mem.Allocator, ids: *std.ArrayList([]const u8)) !?[]const []const u8 {
    if (ids.items.len == 0) return null;
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return try ids.toOwnedSlice(a);
}

pub fn disabledPatches(a: std.mem.Allocator, environ: ?*const std.process.Environ.Map) !?[]const []const u8 {
    const off = envValue(environ, "NIB_PATCHES_OFF");
    var ids: std.ArrayList([]const u8) = .empty;
    for (patches) |patch| {
        if (patch.default_on and patchDisabled(off, patch.id)) try ids.append(a, patch.id);
    }
    return sortedIds(a, &ids);
}

pub fn enabledOptInPatches(a: std.mem.Allocator, environ: ?*const std.process.Environ.Map) !?[]const []const u8 {
    const off = envValue(environ, "NIB_PATCHES_OFF");
    const on = envValue(environ, "NIB_PATCHES_ON");
    var ids: std.ArrayList([]const u8) = .empty;
    for (patches) |patch| {
        if (!patch.default_on and patchListed(on, patch.id) and !patchDisabled(off, patch.id)) try ids.append(a, patch.id);
    }
    return sortedIds(a, &ids);
}

pub fn systemSha(base: []const u8) [12]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(base, &digest, .{});
    return std.fmt.bytesToHex(digest[0..6].*, .lower);
}

pub const system_template =
    \\You are nib, a coding agent working in {s}.
    \\
    \\You act by calling the `run` tool with JavaScript. Each call runs in a fresh sandbox: no variables survive between calls, so write anything you need later to a file. The script can affect the outside world only through these functions:
    \\
    \\```js
    \\{s}```
    \\
    \\Writing scripts:
    \\- Top-level `await` works. Each Step is a full model round trip, usually 10 s or more; one Run can read several files and make all independent edits, returning only what you need.
++ std.fmt.comptimePrint("\n- Tool calls started without awaiting each one (e.g. Promise.all) run concurrently, up to {d} at a time; commands chained inside one bash call (&&, ;) run one after another.\n", .{sandbox.tool_concurrency}) ++
    \\- Long Runs auto-background while awaiting tools; scripts and captured output stay intact. Background Run/bash/agent results arrive automatically as messages. Continue useful work meanwhile; never check or wait for them with ps, cat/tail logs, sleep, empty Runs or timeout reruns. Do not read their redirected logs before completion. If no independent work remains, end the model response immediately with a brief text reply and no run/tool call (not even console.log); Session waits locally, delivers the result and continues the Turn. After edit/write changes, rerun the same command/cwd directly: older Run bash stops with {{superseded_by}}, not failure. Do not wait for the stale result.
    \\- Default to doing the task yourself. Unless the user requests delegation, delegate only independent read-only investigations that can run in parallel with useful parent work and whose results can be discarded. Keep serial edits, builds, tests and reviews in the main loop. Waiting on a foreground agent is serial; background delegation does not help if you must wait for it to proceed.
    \\- The last expression and console.log output share {s} per Run, truncated by console call and final result with markers; tool results inside JS remain complete. Locate with grep, then read needed line ranges. Large multi-file output can exceed this display budget: batch reads or print only needed snippets.
    \\- A run script's syntax or runtime error means the script needs correction. Fix it and continue the task; do not end the Turn just because a script failed.
    \\{s}
    \\When the task is done, answer the user directly without calling the tool.
;

pub fn renderSystem(a: std.mem.Allocator, cwd: []const u8, host: *const tools.Tools, environ: ?*const std.process.Environ.Map) ![]const u8 {
    const docs = try host.documentation(a);
    defer a.free(docs);
    const lines = try patchLines(a, environ, if (host.cfg) |cfg| Profile.forModel(cfg.model) else .default);
    defer a.free(lines);
    const bytes = if (host.cfg) |cfg| cfg.limits.run_output_bytes else @import("output.zig").max_bytes;
    const budget = if (bytes % 1024 == 0) try std.fmt.allocPrint(a, "{d} KiB", .{bytes / 1024}) else try std.fmt.allocPrint(a, "{d} bytes", .{bytes});
    defer a.free(budget);
    return std.fmt.allocPrint(a, system_template, .{ cwd, docs, budget, lines });
}

pub fn turnBudgetText(a: std.mem.Allocator, system: []const u8, max_steps: ?usize, user_text: []const u8) ![]const u8 {
    const marker = "This Turn may use at most ";
    if (max_steps) |limit| {
        const fact = try stepLimitPrompt(a, "", limit);
        if (std.mem.indexOf(u8, system, fact[1..]) == null)
            return std.fmt.allocPrint(a, "[Current Turn budget; configuration changed since the system prompt was recorded]{s}\n\n{s}", .{ fact, user_text });
    } else if (std.mem.indexOf(u8, system, marker) != null) {
        return std.fmt.allocPrint(a, "[Current Turn budget: no Step limit; configuration changed since the system prompt was recorded]\n\n{s}", .{user_text});
    }
    return a.dupe(u8, user_text);
}

pub fn stepLimitPrompt(a: std.mem.Allocator, base: []const u8, max_steps: ?usize) ![]const u8 {
    const limit = max_steps orelse return base;
    return std.fmt.allocPrint(a, "{s}\nThis Turn may use at most {d} Steps; when they run out, the Turn stops without another model request.", .{ base, limit });
}

test "system prompt documents every tool in JavaScript" {
    const gpa = std.testing.allocator;
    var host: tools.Tools = .{ .io = std.testing.io, .home = "/unused", .cfg = .{ .provider = .codex, .base_url = "", .api_key = "", .model = @import("../provider/responses.zig").default_model } };
    const prompt = try renderSystem(gpa, "/work", &host, null);
    defer gpa.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "```js\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "{{llm_options}}") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "TypeScript") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "backticks, ${ or backslashes") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "last expression and console.log output share 16 KiB per Run") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "tool results inside JS remain complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "returning only what you need.\n- Tool calls started without awaiting each one (e.g. Promise.all) run concurrently, up to 8 at a time;") != null);
    for ([_][]const u8{ "Background Run/bash/agent results arrive automatically as messages", "ps, cat/tail logs, sleep, empty Runs or timeout reruns", "Do not read their redirected logs before completion" }) |text|
        try std.testing.expect(std.mem.indexOf(u8, prompt, text) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Session waits locally, delivers the result and continues the Turn") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "independent read-only investigations") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Keep serial edits, builds, tests and reviews in the main loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "1800000 (30 min)") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "resume:a1 after completion; busy:wait, don't retry/replace") != null);
    for (tools.names) |name| {
        if (std.mem.startsWith(u8, name, "mcp")) continue;
        const call = try std.fmt.allocPrint(gpa, "async {s}(", .{name});
        defer gpa.free(call);
        try std.testing.expect(std.mem.indexOf(u8, prompt, call) != null);
    }
}

test "MCP API descriptions enter context only with enabled servers" {
    const t = std.testing;
    var host: tools.Tools = .{ .io = t.io, .home = "/unused", .cfg = .{ .base_url = "", .api_key = "", .model = "m" } };
    const off = try renderSystem(t.allocator, "/work", &host, null);
    defer t.allocator.free(off);
    try t.expect(std.mem.indexOf(u8, off, "async mcp(") == null);
    host.cfg.?.mcp_servers = &.{.{ .id = "test", .command = "server", .enabled = true }};
    const on = try renderSystem(t.allocator, "/work", &host, null);
    defer t.allocator.free(on);
    try t.expect(std.mem.indexOf(u8, on, "async mcp(") != null);
    try t.expect(std.mem.indexOf(u8, on, "async mcp_schema(") != null);
}

test "system prompt renders configured Run display budget" {
    const t = std.testing;
    var host: tools.Tools = .{ .io = t.io, .home = "/unused", .cfg = .{ .base_url = "", .api_key = "", .model = "m", .limits = .{ .run_output_bytes = 32768 } } };
    const system = try renderSystem(t.allocator, "/work", &host, null);
    defer t.allocator.free(system);
    try t.expect(std.mem.indexOf(u8, system, "share 32 KiB per Run") != null);
    try t.expect(std.mem.indexOf(u8, system, "known regression tests, expected results/fixtures and formatting") != null);
}

test "system prompt never mentions run effort" {
    const t = std.testing;
    var host: tools.Tools = .{ .io = t.io, .home = "/unused", .cfg = .{ .provider = .codex, .base_url = "", .api_key = "", .model = @import("../provider/responses.zig").default_model } };
    const system = try renderSystem(t.allocator, "/work", &host, null);
    defer t.allocator.free(system);
    try t.expect(std.mem.indexOf(u8, system, "run's effort") == null);
    try t.expect(std.mem.indexOf(u8, system, "effort-specific") == null);
}

test "prompt patches can be disabled individually or all at once" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const all_on = try patchLines(gpa, &env, .default);
    defer gpa.free(all_on);
    for (patches) |patch| try std.testing.expectEqual(patch.default_on, std.mem.indexOf(u8, all_on, patch.text) != null);
    for (patches) |disabled| {
        try env.put("NIB_PATCHES_OFF", disabled.id);
        const one_off = try patchLines(gpa, &env, .default);
        defer gpa.free(one_off);
        for (patches) |patch| {
            try std.testing.expectEqual(
                patch.default_on and !std.mem.eql(u8, disabled.id, patch.id),
                std.mem.indexOf(u8, one_off, patch.text) != null,
            );
        }
    }
    try env.put("NIB_PATCHES_OFF", "no-shell-search, all");
    const none = try patchLines(gpa, &env, .default);
    defer gpa.free(none);
    try std.testing.expectEqualStrings("", none);
}

test "default prompt keeps the validation guidance wording" {
    const t = std.testing;
    var host: tools.Tools = .{ .io = t.io, .home = "/unused", .cfg = .{ .base_url = "", .api_key = "", .model = "m" } };
    const system = try renderSystem(t.allocator, "/work", &host, null);
    defer t.allocator.free(system);
    for ([_][]const u8{
        "one Run can read several files and make all independent edits, returning only what you need.",
        "The same Run can then build and test, returning only what you need (such as failures).",
        "aim for one full validation. On failure, fix the failures and revalidate. Keep all necessary checks.",
    }) |text| try t.expect(std.mem.indexOf(u8, system, text) != null);
    try t.expect(std.mem.indexOf(u8, system, "do not write new test scripts") == null);
}

test "opt-in patches need NIB_PATCHES_ON and lose to NIB_PATCHES_OFF" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    const text = patches[patches.len - 1].text;
    try t.expectEqualStrings("existing-tests-only", patches[patches.len - 1].id);
    try t.expectEqual(null, try enabledOptInPatches(a, &env));

    try env.put("NIB_PATCHES_ON", "unknown, existing-tests-only");
    const on = try patchLines(a, &env, .deepseek);
    try t.expect(std.mem.indexOf(u8, on, text) != null);
    try t.expect(std.mem.indexOf(u8, on, "aim for one full validation") != null);
    try t.expectEqualStrings("existing-tests-only", (try enabledOptInPatches(a, &env)).?[0]);

    try env.put("NIB_PATCHES_OFF", "run-build-test,single-validation");
    const swapped = try patchLines(a, &env, .default);
    try t.expect(std.mem.indexOf(u8, swapped, text) != null);
    try t.expect(std.mem.indexOf(u8, swapped, "aim for one full validation") == null);
    try t.expect(std.mem.indexOf(u8, swapped, "build and test") == null);
    try t.expectEqual(@as(usize, 2), (try disabledPatches(a, &env)).?.len);

    try env.put("NIB_PATCHES_OFF", "existing-tests-only");
    const beaten = try patchLines(a, &env, .default);
    try t.expect(std.mem.indexOf(u8, beaten, text) == null);
    try t.expectEqual(null, try enabledOptInPatches(a, &env));
    try env.put("NIB_PATCHES_OFF", "all");
    try t.expectEqual(null, try enabledOptInPatches(a, &env));
}

test "patches apply only to their profiles" {
    const t = std.testing;
    const list = [_]Patch{
        .{ .id = "everywhere", .text = "A" },
        .{ .id = "codex-only", .text = "B", .applies_to = .initOne(.codex) },
        .{ .id = "not-claude", .text = "C", .applies_to = Profile.all.differenceWith(.initOne(.claude)) },
    };
    const expected = [_]struct { Profile, []const u8 }{
        .{ .codex, "- A\n- B\n- C\n" },
        .{ .deepseek, "- A\n- C\n" },
        .{ .claude, "- A\n" },
        .{ .default, "- A\n- C\n" },
    };
    for (expected) |case| {
        const lines = try renderPatches(t.allocator, &list, null, case[0]);
        defer t.allocator.free(lines);
        try t.expectEqualStrings(case[1], lines);
    }
    var env: std.process.Environ.Map = .init(t.allocator);
    defer env.deinit();
    try env.put("NIB_PATCHES_OFF", "codex-only");
    const off = try renderPatches(t.allocator, &list, &env, .codex);
    defer t.allocator.free(off);
    try t.expectEqualStrings("- A\n- C\n", off);
}

test "every shipped patch applies to every profile" {
    for (patches) |patch| try std.testing.expect(patch.applies_to.eql(Profile.all));
}

test "experiment labels hash exact base text and normalize actual disabled patches" {
    const t = std.testing;
    try t.expectEqualStrings("cae662172fd4", &systemSha("base"));
    try t.expect(!std.mem.eql(u8, &systemSha("base"), &systemSha("base changed")));
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    try t.expectEqual(null, try disabledPatches(a, &env));
    try env.put("NIB_PATCHES_OFF", "unknown, no-shell-search, expected-continuation, json-escape, expected-continuation, json-escape");
    const normalized = (try disabledPatches(a, &env)).?;
    try t.expectEqual(@as(usize, 3), normalized.len);
    try t.expectEqualStrings("expected-continuation", normalized[0]);
    try t.expectEqualStrings("json-escape", normalized[1]);
    try t.expectEqualStrings("no-shell-search", normalized[2]);
    try env.put("NIB_PATCHES_OFF", "all");
    const all = (try disabledPatches(a, &env)).?;
    var default_count: usize = 0;
    for (patches) |patch| default_count += @intFromBool(patch.default_on);
    try t.expectEqual(default_count, all.len);
    for (patches) |patch| {
        if (!patch.default_on) continue;
        var found = false;
        for (all) |id| found = found or std.mem.eql(u8, id, patch.id);
        try t.expect(found);
    }
    try env.put("NIB_PATCHES_OFF", "unknown");
    try t.expectEqual(null, try disabledPatches(a, &env));
}

test "json-escape patch example survives JS parsing verbatim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const marker = "e.g. content: ";
    const text = patches[0].text;
    const example = text[std.mem.indexOf(u8, text, marker).? + marker.len ..];
    const code = try std.fmt.allocPrint(std.testing.allocator, "await tools.write({{path: '.zig-cache/tmp/{s}/f', content: {s}}})", .{ tmp.sub_path, example });
    defer std.testing.allocator.free(code);
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(home);
    var t: tools.Tools = .{ .io = std.testing.io, .home = home };
    defer t.file_state.deinit(std.testing.allocator);
    const result = try sandbox.eval(std.testing.allocator, std.testing.io, code, .{}, t.host(), null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.ok);
    const content = try tmp.dir.readFileAlloc(std.testing.io, "f", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("` ${x} \\path \"quoted\"\n", content);
}

test "run schema takes only code" {
    const t = std.testing;
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, tools_json, .{});
    defer parsed.deinit();
    const parameters = parsed.value.array.items[0].object.get("function").?.object.get("parameters").?;
    const required = parameters.object.get("required").?.array.items;
    try t.expectEqual(@as(usize, 1), required.len);
    try t.expectEqualStrings("code", required[0].string);
    try t.expectEqual(@as(usize, 1), parameters.object.get("properties").?.object.count());
}

test "Step budget facts leave unlimited prompts unchanged" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "unchanged system prompt";
    const unlimited = try stepLimitPrompt(a, base, null);
    try t.expectEqual(base.ptr, unlimited.ptr);
    try t.expectEqualStrings(&systemSha(base), &systemSha(unlimited));
    const limited = try stepLimitPrompt(a, base, 5);
    try t.expectEqualStrings("unchanged system prompt\nThis Turn may use at most 5 Steps; when they run out, the Turn stops without another model request.", limited);
}

test "resumed Turns expose budget changes without rewriting the original system" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const system = try stepLimitPrompt(a, "base", 5);
    try t.expectEqualStrings("prompt", try turnBudgetText(a, system, 5, "prompt"));
    try t.expectEqualStrings("prompt", try turnBudgetText(a, "base", null, "prompt"));
    const enabled = try turnBudgetText(a, "base", 1, "prompt");
    try t.expect(std.mem.indexOf(u8, enabled, "at most 1 Steps") != null);
    const changed = try turnBudgetText(a, system, 7, "prompt");
    try t.expect(std.mem.indexOf(u8, changed, "at most 7 Steps") != null);
    const disabled = try turnBudgetText(a, system, null, "prompt");
    try t.expect(std.mem.indexOf(u8, disabled, "no Step limit") != null);
    try t.expect(std.mem.endsWith(u8, disabled, "\n\nprompt"));
}
