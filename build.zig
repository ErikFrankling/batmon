const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_module.link_libc = true;
    core_module.linkSystemLibrary("sqlite3", .{ .use_pkg_config = .yes });

    const batmond_root = b.createModule(.{
        .root_source_file = b.path("src/batmond/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    batmond_root.addImport("core", core_module);

    const batmond = b.addExecutable(.{
        .name = "batmond",
        .root_module = batmond_root,
    });
    b.installArtifact(batmond);

    const batmon_root = b.createModule(.{
        .root_source_file = b.path("src/batmon/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    batmon_root.addImport("core", core_module);

    const batmon = b.addExecutable(.{
        .name = "batmon",
        .root_module = batmon_root,
    });
    b.installArtifact(batmon);

    const run_batmond = b.addRunArtifact(batmond);
    if (b.args) |args| run_batmond.addArgs(args);
    const run_batmon = b.addRunArtifact(batmon);
    if (b.args) |args| run_batmon.addArgs(args);

    const run_collector_step = b.step("run-batmond", "Run the batmond collector");
    run_collector_step.dependOn(&run_batmond.step);

    const run_tui_step = b.step("run-batmon", "Run the batmon TUI");
    run_tui_step.dependOn(&run_batmon.step);

    const test_root = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_root.linkSystemLibrary("sqlite3", .{ .use_pkg_config = .yes });

    const core_tests = b.addTest(.{
        .root_module = test_root,
    });
    const batmond_test_root = b.createModule(.{
        .root_source_file = b.path("src/batmond/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    batmond_test_root.addImport("core", core_module);
    batmond_test_root.linkSystemLibrary("sqlite3", .{ .use_pkg_config = .yes });

    const batmond_tests = b.addTest(.{
        .root_module = batmond_test_root,
    });

    const compile_tests_step = b.step("test-compile", "Compile unit tests without running them");
    compile_tests_step.dependOn(&core_tests.step);
    compile_tests_step.dependOn(&batmond_tests.step);

    const run_tests = b.addRunArtifact(core_tests);
    const run_batmond_tests = b.addRunArtifact(batmond_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_batmond_tests.step);
}
