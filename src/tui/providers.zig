//! `/provider`: choosing a service, signing in, adding an endpoint, signing out.

const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../tui.zig").App;
const commands = @import("commands.zig");
const flow = @import("provider_flow.zig");
const auth = @import("../auth.zig");
const config = @import("../config.zig");
const format = @import("format.zig");

const add_value = "+";
const add_label = "Add endpoint…";

/// Rows of the service menu; `current` is marked, `arg` decides whether sign-out rows appear.
pub fn serviceChoices(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, home: []const u8, current: []const u8, arg: []const u8) ![]const commands.Choice {
    const list = try auth.services(a, io, env, home);
    var out: std.ArrayList(commands.Choice) = .empty;
    for (list) |svc| {
        const mark = std.mem.eql(u8, svc.id, current);
        try out.append(a, .{ .value = svc.id, .label = svc.name, .detail = if (mark) try std.fmt.allocPrint(a, "{s} · current", .{svc.status}) else svc.status });
    }
    try out.append(a, .{ .value = add_value, .label = add_label, .detail = "" });
    if (arg.len > 0 and (std.mem.startsWith(u8, "logout ", arg) or std.mem.startsWith(u8, arg, "logout "))) {
        for (list) |svc| if (svc.stored) {
            try out.append(a, .{ .value = try std.fmt.allocPrint(a, "logout {s}", .{svc.id}), .label = try std.fmt.allocPrint(a, "Sign out {s}", .{svc.name}), .detail = "" });
        };
    }
    return out.toOwnedSlice(a);
}

/// Opens the service menu over the editor without touching the draft.
pub fn openMenu(app: *App) !void {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const choices = try serviceChoices(a, app.io, app.environ, app.session.options.home, app.cfg.name(), "");
    const rows = try a.alloc(commands.Candidate, choices.len);
    for (choices, rows) |choice, *row| row.* = .{ .command = .provider, .value = choice.value, .label = choice.label, .detail = choice.detail };
    try app.menu.pin(rows);
}

pub fn command(app: *App, arg: []const u8) !void {
    const gpa = app.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try auth.services(a, app.io, app.environ, app.session.options.home);
    var words = std.mem.tokenizeAny(u8, arg, " \t\n");
    const first = words.next() orelse return openMenu(app);
    if (std.mem.eql(u8, first, "logout")) {
        const id = words.next() orelse return app.transcript.add(gpa, .err, "usage: /provider logout <service>");
        const svc = auth.find(list, id) orelse return app.report(.err, "unknown service {s} · /provider lists services", .{id});
        return logout(app, svc);
    }
    if (words.next() != null) return app.transcript.add(gpa, .err, "usage: /provider [service] · /provider + adds an endpoint · /provider logout <service>");
    if (std.mem.eql(u8, first, add_value)) {
        const ids = try a.alloc([]const u8, list.len);
        for (list, ids) |svc, *id| id.* = svc.id;
        try app.flow.startForm(ids);
        return;
    }
    const svc = auth.find(list, first) orelse return app.report(.err, "unknown service {s} · /provider lists services", .{first});
    if (svc.signed_in) return commands.select(app, .{ .provider = svc.id, .model = null }, null);
    if (std.mem.eql(u8, svc.id, "codex")) return app.flow.startLogin(launch(app));
    try app.flow.startKey(svc.id, svc.name);
}

fn logout(app: *App, svc: auth.Service) !void {
    const gpa = app.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const out = auth.signOut(arena.allocator(), app.io, app.environ, app.session.options.home, svc.id) catch |err| return app.report(.err, "could not sign out: {s}", .{@errorName(err)});
    const text = try auth.signOutText(arena.allocator(), svc.name, out);
    if (out.removed and std.mem.eql(u8, svc.id, app.cfg.name())) dropKey(app);
    app.refreshCredentials();
    try app.transcript.add(gpa, .info, text);
}

/// The running Session must stop using a key that was just removed from the store.
fn dropKey(app: *App) void {
    if (app.cfg.key_source != .store) return;
    app.cfg.api_key = "";
    app.cfg.key_source = .none;
    app.session.dropStoredKey();
}

fn postResult(ctx: *anyopaque, boxed: *flow.Result) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.loop.postEvent(.{ .flow = boxed }) catch {
        boxed.deinit(app.gpa);
        app.gpa.destroy(boxed);
    };
}

fn launch(app: *App) flow.Flow.Launch {
    return .{ .io = app.io, .environ = app.environ, .home = app.session.options.home, .post = .{ .ctx = app, .call = postResult } };
}

/// A key press while a flow is open or the service menu is pinned.
pub fn key(app: *App, k: vaxis.Key) !void {
    const f = &app.flow;
    if (k.matches(vaxis.Key.escape, .{})) return cancel(app);
    if (f.takesText()) return textKey(app, k);
    if (f.kind == .waiting) return;
    if (k.matches(vaxis.Key.up, .{})) return app.menu.move("", false);
    if (k.matches(vaxis.Key.down, .{})) return app.menu.move("", true);
    if (!k.matches(vaxis.Key.enter, .{})) return;
    const chosen = app.menu.selected("") orelse return;
    const value = chosen.value orelse return;
    if (f.kind == .protocol) {
        app.menu.unpin();
        return advance(app, try f.chooseProtocol(value, launch(app)));
    }
    if (f.kind == .pick) {
        const outcome = try f.chooseModel(value, launch(app)) orelse return;
        app.menu.unpin();
        return advance(app, outcome);
    }
    app.menu.unpin();
    try command(app, value);
}

pub fn cancel(app: *App) void {
    app.menu.unpin();
    app.flow.reset();
}

fn textKey(app: *App, k: vaxis.Key) !void {
    const f = &app.flow;
    if (k.matches(vaxis.Key.enter, .{})) return submit(app);
    if (k.matches(vaxis.Key.backspace, .{})) return f.backspace();
    if (k.matches('u', .{ .ctrl = true })) return f.wipe();
    if (k.mods.ctrl or k.mods.alt) return;
    if (k.text) |text| try f.insert(text);
}

pub fn pasted(app: *App, text: []const u8) !void {
    if (app.flow.takesText()) try app.flow.insert(std.mem.trim(u8, text, "\r\n"));
}

fn submit(app: *App) !void {
    const f = &app.flow;
    if (f.kind == .key) {
        if (f.text.items.len == 0) return app.transcript.add(app.gpa, .err, "API key cannot be empty");
        const id = try app.gpa.dupe(u8, f.service_id);
        defer app.gpa.free(id);
        auth.setKey(app.gpa, app.io, app.session.options.home, id, f.text.items) catch |err| return app.report(.err, "could not store key: {s}", .{@errorName(err)});
        f.reset();
        return commands.select(app, .{ .provider = id, .model = null }, null);
    }
    const outcome = try f.submitEntry(launch(app));
    if (outcome == .invalid) return app.transcript.add(app.gpa, .err, outcome.invalid);
    try advance(app, outcome);
}

fn advance(app: *App, outcome: flow.Outcome) !void {
    switch (outcome) {
        .next => if (app.flow.kind == .protocol) {
            try app.menu.pin(&.{
                .{ .command = .provider, .value = "1", .label = "OpenAI-compatible", .detail = "" },
                .{ .command = .provider, .value = "2", .label = "Responses", .detail = "" },
                .{ .command = .provider, .value = "3", .label = "Anthropic Messages", .detail = "" },
            });
        },
        .invalid, .list_models => {},
        .ready => try finishEndpoint(app),
    }
}

fn finishEndpoint(app: *App) !void {
    const f = &app.flow;
    const gpa = app.gpa;
    const home = app.session.options.home;
    const ep = f.form.?.endpoint();
    const id = try gpa.dupe(u8, ep.id);
    defer gpa.free(id);
    if (f.form.?.key.len > 0) auth.setKey(gpa, app.io, home, id, f.form.?.key) catch |err| return app.report(.err, "could not store key: {s}", .{@errorName(err)});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    config.addEndpoint(arena.allocator(), app.io, home, ep) catch |err| {
        if (f.form.?.key.len > 0) _ = auth.signOut(arena.allocator(), app.io, app.environ, home, id) catch {};
        f.reset();
        return app.report(.err, "could not save endpoint: {s}", .{@errorName(err)});
    };
    f.reset();
    try commands.select(app, .{ .provider = id, .model = null }, null);
}

/// A background job finished. The event frees `r`; list ownership may move into the flow.
pub fn result(app: *App, r: *flow.Result) !void {
    const gpa = app.gpa;
    const f = &app.flow;
    switch (f.settleResult(r)) {
        .ignored => {},
        .prompt => |p| try app.report(.info, "Open {s} and enter code {s}", .{ p.url, p.code }),
        .signed_in => |l| {
            app.refreshCredentials();
            if (!l.ok) return app.report(if (l.canceled) .info else .err, "{s}", .{l.message});
            const note = try std.fmt.allocPrint(gpa, "Codex · signed in · {s}", .{l.message});
            defer gpa.free(note);
            try commands.select(app, .{ .provider = "codex", .model = null }, note);
        },
        .listed => {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const rows = try a.alloc(commands.Candidate, f.listed.len);
            for (f.listed, rows) |item, *row| {
                var buf: [32]u8 = undefined;
                row.* = .{ .command = .model, .value = item.id, .label = item.id, .detail = if (item.context_window) |n| try std.fmt.allocPrint(a, "{s} tokens", .{format.number(&buf, n)}) else "" };
            }
            try app.menu.pin(rows);
        },
        .listing_failed => try app.transcript.add(gpa, .info, "Could not list models · type the model id"),
    }
}

const testing = std.testing;

test "service rows mark the current service and offer sign-out only when asked" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var env: std.process.Environ.Map = .init(a);
    try env.put("HOME", root);
    try env.put("CODEX_HOME", root);
    try env.put("OPENAI_API_KEY", "fake");
    try auth.setKey(a, testing.io, root, "openai", "fake-stored-openai");
    try auth.setKey(a, testing.io, root, "xai", "fake-stored");
    const plain = try serviceChoices(a, testing.io, &env, root, "openai", "");
    try testing.expectEqual(@as(usize, 6), plain.len);
    try testing.expectEqualStrings("OPENAI_API_KEY · current", plain[2].detail);
    try testing.expectEqualStrings("Add endpoint…", plain[5].label);
    const typed = try serviceChoices(a, testing.io, &env, root, "openai", "lo");
    try testing.expectEqual(@as(usize, 8), typed.len);
    try testing.expectEqualStrings("logout openai", typed[6].value);
    try testing.expectEqualStrings("Sign out OpenAI", typed[6].label);
    try testing.expectEqualStrings("logout xai", typed[7].value);
    try testing.expectEqualStrings("Sign out xAI", typed[7].label);
    try testing.expectEqual(@as(usize, 6), (try serviceChoices(a, testing.io, &env, root, "openai", "x")).len);
}
