const std = @import("std");
const Profile = @import("profile.zig").Profile;

/// The variant of every tuning ([ADR 0026](../../docs/adr/0026-tuning.md)). A field is a
/// tuning, its enum a set of variants whose first value is the default.
pub const Resolved = struct {
    delivery: Delivery = .user,
    validation: Validation = .single,

    /// How background completions and mid-Turn user messages reach the model:
    /// `user` inserts user messages at the next Step; `tool` appends them to the next tool result.
    pub const Delivery = enum { user, tool };
    pub const Validation = enum { single, @"existing-only", none };

    pub const BackgroundMode = enum {
        user,
        tool,
        tool_without_wait,

        pub fn foldsResults(mode: BackgroundMode) bool {
            return mode != .user;
        }
    };

    pub fn backgroundMode(r: Resolved, can_wait: bool) BackgroundMode {
        return switch (r.delivery) {
            .user => .user,
            .tool => if (can_wait) .tool else .tool_without_wait,
        };
    }

    pub fn forProfile(profile: Profile) Resolved {
        return switch (profile) {
            .deepseek => .{ .delivery = .tool, .validation = .none },
            .codex, .claude, .default => .{},
        };
    }

    /// Applies `<tuning>=<variant>[,...]`; on failure `detail` is allocated in `a`.
    pub fn override(base: Resolved, a: std.mem.Allocator, spec: []const u8, detail: *[]const u8) !Resolved {
        var result = base;
        var entries = std.mem.splitScalar(u8, spec, ',');
        while (entries.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t");
            if (entry.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse {
                detail.* = try std.fmt.allocPrint(a, "NIB_TUNE: expected <tuning>=<variant>, got '{s}'", .{entry});
                return error.InvalidTuning;
            };
            const name = std.mem.trim(u8, entry[0..eq], " \t");
            const variant = std.mem.trim(u8, entry[eq + 1 ..], " \t");
            var known = false;
            inline for (tuning_names, tuning_types) |field, Variants| {
                if (std.mem.eql(u8, name, field)) {
                    known = true;
                    @field(result, field) = std.meta.stringToEnum(Variants, variant) orelse {
                        detail.* = try std.fmt.allocPrint(a, "NIB_TUNE: {s} has no variant '{s}'; variants: {s}", .{ name, variant, variantNames(Variants) });
                        return error.InvalidTuning;
                    };
                }
            }
            if (!known) {
                detail.* = try std.fmt.allocPrint(a, "NIB_TUNE: unknown tuning '{s}'; tunings: {s}", .{ name, tuningNames() });
                return error.InvalidTuning;
            }
        }
        return result;
    }

    pub fn resolve(a: std.mem.Allocator, profile: Profile, spec: ?[]const u8, detail: *[]const u8) !Resolved {
        return forProfile(profile).override(a, spec orelse "", detail);
    }

    /// Unknown tunings and variants (from a newer nib) fall back to defaults.
    pub fn fromLog(record: std.json.ArrayHashMap([]const u8)) Resolved {
        var result: Resolved = .{};
        inline for (tuning_names, tuning_types) |field, Variants| {
            if (record.map.get(field)) |name| {
                if (std.meta.stringToEnum(Variants, name)) |variant| @field(result, field) = variant;
            }
        }
        return result;
    }

    pub fn toLog(r: Resolved, a: std.mem.Allocator) !std.json.ArrayHashMap([]const u8) {
        var record: std.json.ArrayHashMap([]const u8) = .{};
        inline for (tuning_names) |field| try record.map.put(a, field, @tagName(@field(r, field)));
        return record;
    }
};

const tuning_names = std.meta.fieldNames(Resolved);
const tuning_types = std.meta.fieldTypes(Resolved);

fn join(comptime names: []const [:0]const u8) []const u8 {
    comptime var text: []const u8 = "";
    inline for (names, 0..) |name, i| text = text ++ (if (i == 0) "" else ", ") ++ name;
    return text;
}

fn variantNames(comptime Variants: type) []const u8 {
    return comptime join(std.meta.fieldNames(Variants));
}

fn tuningNames() []const u8 {
    return comptime join(tuning_names);
}

test "profiles pick a variant; unmatched models get the defaults" {
    const t = std.testing;
    try t.expectEqual(Resolved.Delivery.tool, Resolved.forProfile(.deepseek).delivery);
    try t.expectEqual(Resolved.Validation.none, Resolved.forProfile(.deepseek).validation);
    for ([_]Profile{ .codex, .claude, .default }) |profile| {
        try t.expectEqual(Resolved.Delivery.user, Resolved.forProfile(profile).delivery);
        try t.expectEqual(Resolved.Validation.single, Resolved.forProfile(profile).validation);
    }
}

test "NIB_TUNE replaces profile variants" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var detail: []const u8 = "";
    try t.expectEqual(Resolved.Delivery.user, (try Resolved.resolve(arena.allocator(), .deepseek, "delivery=user", &detail)).delivery);
    try t.expectEqual(Resolved.Delivery.tool, (try Resolved.resolve(arena.allocator(), .codex, " delivery = tool ,", &detail)).delivery);
    try t.expectEqual(Resolved.Delivery.tool, (try Resolved.resolve(arena.allocator(), .deepseek, "", &detail)).delivery);
    try t.expectEqual(Resolved.Delivery.tool, (try Resolved.resolve(arena.allocator(), .deepseek, null, &detail)).delivery);
    const overridden = try Resolved.resolve(arena.allocator(), .deepseek, "validation=single", &detail);
    try t.expectEqual(Resolved.Validation.single, overridden.validation);
    try t.expectEqual(Resolved.Delivery.tool, overridden.delivery);
    try t.expectEqual(Resolved.Validation.@"existing-only", (try Resolved.resolve(arena.allocator(), .codex, "validation=existing-only", &detail)).validation);
}

test "NIB_TUNE rejects unknown names and malformed entries" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const cases = [_]struct { spec: []const u8, message: []const u8 }{
        .{ .spec = "nope=tool", .message = "NIB_TUNE: unknown tuning 'nope'; tunings: delivery, validation" },
        .{ .spec = "validation=huge", .message = "NIB_TUNE: validation has no variant 'huge'; variants: single, existing-only, none" },
        .{ .spec = "delivery=huge", .message = "NIB_TUNE: delivery has no variant 'huge'; variants: user, tool" },
        .{ .spec = "delivery", .message = "NIB_TUNE: expected <tuning>=<variant>, got 'delivery'" },
        .{ .spec = "delivery=tool,x=y", .message = "NIB_TUNE: unknown tuning 'x'; tunings: delivery, validation" },
    };
    for (cases) |case| {
        var detail: []const u8 = "";
        try t.expectError(error.InvalidTuning, Resolved.resolve(arena.allocator(), .default, case.spec, &detail));
        try t.expectEqualStrings(case.message, detail);
    }
}

test "the log record round-trips and tolerates unknown names" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const record = try (Resolved{ .delivery = .tool, .validation = .none }).toLog(a);
    try t.expectEqual(Resolved.Delivery.tool, Resolved.fromLog(record).delivery);
    try t.expectEqual(Resolved.Validation.none, Resolved.fromLog(record).validation);
    var future: std.json.ArrayHashMap([]const u8) = .{};
    try future.map.put(a, "delivery", "gone");
    try future.map.put(a, "other", "x");
    try t.expectEqual(Resolved.Delivery.user, Resolved.fromLog(future).delivery);
    try t.expectEqual(Resolved.Validation.single, Resolved.fromLog(future).validation);
    var old: std.json.ArrayHashMap([]const u8) = .{};
    try old.map.put(a, "delivery", "tool");
    try t.expectEqual(Resolved.Validation.single, Resolved.fromLog(old).validation);
}
