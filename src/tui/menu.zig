const std = @import("std");
const commands = @import("commands.zig");
const Session = @import("../session.zig").Session;
const session_log = @import("../session/log.zig");
const paths = @import("paths.zig");
const Editor = @import("editor.zig").Editor;

/// The `/` candidate list above the input: selection, dismissal and session choices.
pub const Menu = struct {
    /// `items` returns slices of this; a Menu must not move while they are used.
    buf: [128]commands.Candidate = undefined,
    sel: usize = 0,
    closed: bool = false,
    /// Owns `sessions` and resolved ids; reset when sessions are listed again.
    arena: std.heap.ArenaAllocator,
    sessions: []const commands.Choice = &.{},
    sessions_loaded: bool = false,
    tasks: []const commands.Choice = &.{},
    models: []const commands.Choice = &.{},
    services: []const commands.Choice = &.{},
    /// A fixed list that replaces the `/` candidates until unpinned; owns its strings.
    pinned: []commands.Candidate = &.{},
    pin_arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    /// `@` completions: set while the cursor ends an `@` mention.
    mention: enum { none, file, skill } = .none,
    index: ?*paths.Index = null,
    wake: ?paths.Index.Wake = null,
    /// Owns the strings of `file_buf`; reset when the matches are recomputed.
    file_arena: std.heap.ArenaAllocator,
    file_buf: [paths.max_hits]commands.Candidate = undefined,
    file_len: usize = 0,
    file_query: [256]u8 = undefined,
    file_query_len: usize = 0,
    file_generation: u64 = 0,
    file_fresh: bool = false,
    reflect_enabled: bool = false,
    /// Skills listed when a `$` mention starts; owned by `skill_arena`.
    skill_arena: std.heap.ArenaAllocator,
    skill_list: []const @import("../session/skills.zig").Skill = &.{},

    pub fn init(gpa: std.mem.Allocator) Menu {
        return .{ .arena = .init(gpa), .gpa = gpa, .file_arena = .init(gpa), .pin_arena = .init(gpa), .skill_arena = .init(gpa) };
    }

    pub fn deinit(m: *Menu) void {
        if (m.index) |ix| {
            ix.deinit();
            m.gpa.destroy(ix);
        }
        m.file_arena.deinit();
        m.skill_arena.deinit();
        m.pin_arena.deinit();
        m.arena.deinit();
    }

    pub fn isPinned(m: Menu) bool {
        return m.pinned.len > 0;
    }

    pub fn pin(m: *Menu, rows: []const commands.Candidate) !void {
        m.unpin();
        const a = m.pin_arena.allocator();
        const copy = try a.alloc(commands.Candidate, rows.len);
        for (rows, copy) |row, *out| {
            out.* = row;
            out.label = try a.dupe(u8, row.label);
            out.detail = try a.dupe(u8, row.detail);
            if (row.value) |value| out.value = try a.dupe(u8, value);
        }
        m.pinned = copy;
        m.sel = 0;
    }

    pub fn unpin(m: *Menu) void {
        m.pinned = &.{};
        _ = m.pin_arena.reset(.retain_capacity);
        m.sel = 0;
    }

    pub fn items(m: *Menu, input: []const u8) []commands.Candidate {
        if (m.pinned.len > 0) return m.pinned;
        if (m.closed) return m.buf[0..0];
        var slash = commands.candidates(input, m.sessions, m.tasks, m.models, m.services, &m.buf);
        if (!m.reflect_enabled) {
            var n: usize = 0;
            for (slash) |candidate| {
                if (candidate.command == .reflect) continue;
                slash[n] = candidate;
                n += 1;
            }
            slash = slash[0..n];
        }
        if (slash.len > 0 or m.mention == .none) return slash;
        return m.file_buf[0..m.file_len];
    }

    /// Follows the editor's `@` mention: starts or refreshes the path listing and ranks it.
    pub fn sync(m: *Menu, io: std.Io, e: *const Editor, session: *const Session) void {
        const found = e.fileMention() orelse {
            if (e.skillMention()) |skill| return m.syncSkills(@constCast(session), skill.query);
            m.mention = .none;
            m.file_fresh = false;
            m.file_len = 0;
            return;
        };
        if (m.index == null) {
            const ix = m.gpa.create(paths.Index) catch return;
            ix.* = .{ .gpa = m.gpa, .io = io, .wake = m.wake };
            m.index = ix;
        }
        const ix = m.index.?;
        if (m.mention != .file) {
            m.mention = .file;
            m.file_fresh = false;
            ix.refresh(@constCast(&session.tools));
        }
        const query = found.query[0..@min(found.query.len, m.file_query.len)];
        const same = m.file_fresh and std.mem.eql(u8, query, m.file_query[0..m.file_query_len]);
        ix.withEntries(Rank{ .m = m, .query = query, .same = same, .generation = &ix.generation }, Rank.run);
    }

    /// Lists discovered skills whose names start with `query`; they reuse the `@` rows.
    fn syncSkills(m: *Menu, session: *Session, query: []const u8) void {
        if (m.mention != .skill) {
            m.mention = .skill;
            _ = m.skill_arena.reset(.retain_capacity);
            m.skill_list = session.discoverSkills(m.skill_arena.allocator()) catch &.{};
        }
        m.file_fresh = false;
        _ = m.file_arena.reset(.retain_capacity);
        const a = m.file_arena.allocator();
        m.file_len = 0;
        for (m.skill_list) |skill| {
            if (m.file_len == m.file_buf.len) break;
            if (query.len > skill.name.len or !std.ascii.eqlIgnoreCase(skill.name[0..query.len], query)) continue;
            const value = std.fmt.allocPrint(a, "${s} ", .{skill.name}) catch break;
            const line = std.mem.sliceTo(skill.description, '\n');
            m.file_buf[m.file_len] = .{ .command = .help, .value = value, .label = skill.name, .detail = line, .is_path = true };
            m.file_len += 1;
        }
        if (m.sel >= m.file_len) m.sel = 0;
    }

    const Rank = struct {
        m: *Menu,
        query: []const u8,
        same: bool,
        generation: *const u64,

        fn run(r: Rank, entries: []const paths.Entry) void {
            const m = r.m;
            if (r.same and m.file_generation == r.generation.*) return;
            m.file_generation = r.generation.*;
            m.file_fresh = true;
            @memcpy(m.file_query[0..r.query.len], r.query);
            m.file_query_len = r.query.len;
            _ = m.file_arena.reset(.retain_capacity);
            const a = m.file_arena.allocator();
            var hits: [paths.max_hits]paths.Hit = undefined;
            m.file_len = 0;
            for (paths.top(entries, r.query, &hits)) |h| {
                const entry = entries[h.index];
                const value = paths.insertion(a, entry.path, entry.dir) catch break;
                const label = if (entry.dir) std.fmt.allocPrint(a, "{s}/", .{entry.path}) catch break else entry.path;
                m.file_buf[m.file_len] = .{ .command = .help, .value = value, .label = label, .detail = "", .is_path = true };
                m.file_len += 1;
            }
            if (m.sel >= m.file_len) m.sel = 0;
        }
    };

    pub fn selected(m: *Menu, input: []const u8) ?commands.Candidate {
        const list = m.items(input);
        return if (list.len > 0) list[@min(m.sel, list.len - 1)] else null;
    }

    pub fn move(m: *Menu, input: []const u8, down: bool) void {
        const len = m.items(input).len;
        if (len == 0) return;
        const current = @min(m.sel, len - 1);
        m.sel = if (down) (current + 1) % len else (current + len - 1) % len;
    }

    pub fn inputChanged(m: *Menu, input: []const u8) void {
        m.sel = 0;
        m.closed = false;
        if (!std.mem.startsWith(u8, input, "/resume ")) m.sessions_loaded = false;
    }

    pub fn forgetSessions(m: *Menu) void {
        m.sessions_loaded = false;
    }

    /// Lists this directory's sessions once the input starts asking for one.
    pub fn load(m: *Menu, io: std.Io, input: []const u8, session: *const Session) !void {
        if (std.mem.startsWith(u8, input, "/model ")) {
            _ = m.arena.reset(.retain_capacity);
            const a = m.arena.allocator();
            var empty_env: std.process.Environ.Map = .init(a);
            const env = session.options.environ orelse &empty_env;
            const entries = try @import("../config.zig").modelEntries(a, io, env, session.options.home, session.cfg);
            const choices = try a.alloc(commands.Choice, entries.len);
            for (entries, choices) |entry, *choice| {
                const active = std.mem.eql(u8, entry.provider, session.cfg.name()) and std.mem.eql(u8, entry.model, session.cfg.model);
                choice.* = .{
                    .value = try std.fmt.allocPrint(a, "{s}/{s}", .{ entry.provider, entry.model }),
                    .label = entry.model,
                    .service = entry.provider,
                    .detail = if (active) "current" else "",
                };
            }
            m.models = choices;
            return;
        }
        if (std.mem.startsWith(u8, input, "/provider ")) {
            _ = m.arena.reset(.retain_capacity);
            const env = session.options.environ orelse return;
            m.services = try @import("providers.zig").serviceChoices(m.arena.allocator(), io, env, session.options.home, session.cfg.name(), input["/provider ".len..]);
            return;
        }
        if (std.mem.startsWith(u8, input, "/stop ")) {
            _ = m.arena.reset(.retain_capacity);
            const a = m.arena.allocator();
            const tasks = try @constCast(&session.tools.background).snapshot(a, io);
            var choices: std.ArrayList(commands.Choice) = .empty;
            for (tasks) |task| {
                if (!std.mem.eql(u8, task.state, "queued") and !std.mem.eql(u8, task.state, "working")) continue;
                try choices.append(a, .{ .value = task.id, .label = task.id, .detail = task.description });
            }
            m.tasks = try choices.toOwnedSlice(a);
            return;
        }
        if (m.sessions_loaded or !std.mem.startsWith(u8, input, "/resume ")) return;
        _ = m.arena.reset(.retain_capacity);
        m.sessions = try sessionChoices(io, m.arena.allocator(), session);
        m.sessions_loaded = true;
    }

    /// A full id, or the one session here whose id starts with `arg`.
    pub fn resolveSession(m: *Menu, io: std.Io, session: *const Session, arg: []const u8) ![]const u8 {
        if (arg.len == 0) return error.MissingSessionId;
        if (arg.len == 32) return arg;
        var match: ?[]const u8 = null;
        for (try sessionChoices(io, m.arena.allocator(), session)) |c| {
            if (!std.mem.startsWith(u8, c.value, arg)) continue;
            if (match != null) return error.AmbiguousSession;
            match = c.value;
        }
        return match orelse error.UnknownSession;
    }
};

fn sessionChoices(io: std.Io, a: std.mem.Allocator, session: *const Session) ![]const commands.Choice {
    const directory = try std.fs.path.join(a, &.{ session.options.home, "sessions" });
    const cwd = try std.process.currentPathAlloc(io, a);
    const found = try session_log.list(io, a, directory, cwd);
    const now = std.Io.Clock.real.now(io).nanoseconds;
    const choices = try a.alloc(commands.Choice, found.len);
    for (found, choices) |f, *c| {
        const seconds: u64 = @intCast(@max(@divTrunc(now - f.modified_ns, std.time.ns_per_s), 0));
        var ago_buf: [128]u8 = undefined;
        const ago = if (seconds < 60)
            "now"
        else if (seconds < 3600)
            try std.fmt.bufPrint(&ago_buf, "{d}m ago", .{seconds / 60})
        else if (seconds < 86400)
            try std.fmt.bufPrint(&ago_buf, "{d}h ago", .{seconds / 3600})
        else
            try std.fmt.bufPrint(&ago_buf, "{d}d ago", .{seconds / 86400});
        const current = std.mem.eql(u8, f.id, session.id);
        c.* = .{
            .value = f.id,
            .label = f.id[0..@min(8, f.id.len)],
            .detail = try std.fmt.allocPrint(a, "{s}{s} · {s}", .{ ago, if (current) " (current)" else "", if (f.preview.len > 0) f.preview else "(no messages)" }),
        };
    }
    return choices;
}

const testing = std.testing;

test "selection wraps, closing hides the list and editing reopens it" {
    var m: Menu = .init(testing.allocator);
    defer m.deinit();
    try testing.expectEqualStrings("/copy", m.selected("/co").?.label);
    m.move("/co", true);
    try testing.expectEqualStrings("/compact", m.selected("/co").?.label);
    m.move("/co", true);
    try testing.expectEqualStrings("/copy", m.selected("/co").?.label);
    m.move("/co", false);
    try testing.expectEqualStrings("/compact", m.selected("/co").?.label);
    m.closed = true;
    try testing.expect(m.selected("/co") == null);
    m.inputChanged("/c");
    try testing.expectEqualStrings("/copy", m.selected("/c").?.label);
}

test "model menu qualifies choices and marks only the active service model" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.toml", .data = "[providers.local]\nprotocol = \"responses\"\nbase_url = \"http://localhost\"\nmodel = \"gpt-6.1-sol\"\ncontext_window = 1000\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("CODEX_HOME", root);
    var session: Session = undefined;
    session.options = .{ .home = root, .user_home = root, .environ = &env };
    session.cfg = .{ .provider = .openai, .base_url = "", .api_key = "", .model = "gpt-6.1-sol" };
    var m: Menu = .init(testing.allocator);
    defer m.deinit();
    try m.load(testing.io, "/model ", &session);
    const rows = m.items("/model gpt-6.1-sol");
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("openai/gpt-6.1-sol", rows[0].value.?);
    try testing.expectEqualStrings("gpt-6.1-sol", rows[0].label);
    try testing.expectEqualStrings("openai", rows[0].service.?);
    try testing.expectEqualStrings("current", rows[0].detail);
    try testing.expectEqualStrings("local/gpt-6.1-sol", rows[1].value.?);
    try testing.expectEqualStrings("gpt-6.1-sol", rows[1].label);
    try testing.expectEqualStrings("local", rows[1].service.?);
    try testing.expectEqualStrings("", rows[1].detail);
}

test "reflection is hidden unless enabled" {
    var m: Menu = .init(testing.allocator);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.items("/ref").len);
    m.reflect_enabled = true;
    try testing.expectEqualStrings("/reflect", m.items("/ref")[0].label);
}

test "moving straight from an @ mention to a $ mention loads skills" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "skills/review");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "skills/review/SKILL.md", .data = "---\nname: review\ndescription: Review a change.\n---\nBody\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var session: Session = undefined;
    session.io = testing.io;
    session.options = .{ .home = root, .user_home = root };
    session.cfg = .{ .base_url = "", .api_key = "", .model = "mock" };
    var m: Menu = .init(testing.allocator);
    defer m.deinit();
    m.mention = .file;
    var e: Editor = .{};
    defer e.deinit(testing.allocator);
    try e.replace(testing.allocator, "$re");
    m.sync(testing.io, &e, &session);
    try testing.expect(m.mention == .skill);
    try testing.expectEqualStrings("review", m.selected("$re").?.label);
}
