const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // No quickjs-libc: it would give scripts fs/net/process access.
    const qjs_dep = b.dependency("quickjs", .{});
    const qjs = b.addLibrary(.{
        .name = "quickjs",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    qjs.root_module.addCSourceFiles(.{
        .root = qjs_dep.path(""),
        .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c" },
        .flags = &.{ "-D_GNU_SOURCE", "-funsigned-char", "-fwrapv", "-fno-sanitize=undefined" },
    });
    qjs.root_module.addIncludePath(qjs_dep.path(""));
    qjs.root_module.linkSystemLibrary("m", .{});

    const qjs_c = b.addTranslateC(.{
        .root_source_file = qjs_dep.path("quickjs.h"),
        .target = target,
        .optimize = optimize,
    });

    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const vaxis = patchedVaxis(b, vaxis_dep);

    const options = b.addOptions();
    const version = @import("build.zig.zon").version;
    options.addOption([]const u8, "version", version);
    // Git refs are external to Zig's configuration cache, including worktree refs.
    b.graph.poisonCache();
    const commit = switch (b.runFallible(&.{ "git", "rev-parse", "--short", "HEAD" }, .{ .cwd = .{ .path = b.root.joinString(b.allocator, "") catch @panic("OOM") }, .stderr_behavior = .ignore })) {
        .success => |output| std.mem.trim(u8, output, " \r\n"),
        else => "",
    };
    options.addOption([]const u8, "nib_version", if (commit.len == 0) version else b.fmt("{s}+{s}", .{ version, commit }));

    const production_probe = b.addOptions();
    production_probe.addOption(bool, "enabled", false);
    const benchmark_probe = b.addOptions();
    benchmark_probe.addOption(bool, "enabled", true);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis },
            .{ .name = "qjs", .module = qjs_c.createModule() },
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "sandbox_probe_options", .module = production_probe.createModule() },
        },
    });
    mod.linkLibrary(qjs);

    const exe = b.addExecutable(.{ .name = "nib", .root_module = mod });
    exe.root_module.strip = b.option(bool, "strip", "Strip the nib executable");
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run nib").dependOn(&run_cmd.step);

    const tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    b.step("test", "Run tests").dependOn(&tests.step);

    const footprint = b.addExecutable(.{
        .name = "prompt-footprint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/prompt_footprint.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nib", .module = mod }},
        }),
    });
    const footprint_run = b.addRunArtifact(footprint);
    b.step("prompt-footprint", "Dump fixed prompt fixtures without contacting a model").dependOn(&footprint_run.step);

    const bench_sandbox = b.createModule(.{
        .root_source_file = b.path("src/sandbox.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis },
            .{ .name = "qjs", .module = qjs_c.createModule() },
            .{ .name = "sandbox_probe_options", .module = benchmark_probe.createModule() },
        },
    });
    bench_sandbox.linkLibrary(qjs);
    const bench_module = b.createModule(.{
        .root_source_file = b.path("scripts/bench_scheduler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sandbox", .module = bench_sandbox }},
    });
    const bench = b.addExecutable(.{ .name = "bench-scheduler", .root_module = bench_module });
    const bench_run = b.addRunArtifact(bench);
    bench_run.addPassthruArgs();
    b.step("bench-scheduler", "Measure native tool scheduling (ReleaseFast only)").dependOn(&bench_run.step);
    const bench_tests = b.addRunArtifact(b.addTest(.{ .root_module = bench_module }));
    b.step("test-bench-scheduler", "Test scheduler benchmark probes and fixtures").dependOn(&bench_tests.step);
}

fn patchedVaxis(b: *std.Build, dep: *std.Build.Dependency) *std.Build.Module {
    const queue_path = "src/queue.zig";
    const source_path = dep.builder.root.joinString(b.allocator, queue_path) catch @panic("OOM");
    const queue = std.Io.Dir.cwd().readFileAlloc(b.graph.io, source_path, b.allocator, .limited(64 * 1024)) catch |err| std.debug.panic("cannot read vaxis queue: {s}", .{@errorName(err)});
    // The pinned vaxis queue can strand its producer under Debug backpressure when helpers take Queue by value.
    const old = "(self: Self";
    if (std.mem.count(u8, queue, old) != 5) @panic("revisit the vaxis queue patch after updating vaxis");
    const patched = std.mem.replaceOwned(u8, b.allocator, queue, old, "(self: *const Self") catch @panic("OOM");
    const sources = b.addWriteFiles();
    _ = sources.addCopyDirectory(dep.path("src"), "src", .{ .exclude_extensions = &.{"queue.zig"} });
    _ = sources.add(queue_path, patched);
    const module = dep.module("vaxis");
    module.root_source_file = sources.getDirectory().path(b, "src/main.zig");
    return module;
}
