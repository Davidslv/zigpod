const std = @import("std");

pub fn build(b: *std.Build) void {
    // ============================================================
    // Target Configuration
    // ============================================================

    // Default to native for testing, can override for ARM target
    const default_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // Build Options
    // ============================================================

    const enable_sdl2 = b.option(bool, "sdl2", "Enable SDL2 GUI (requires SDL2 installed)") orelse false;

    // ============================================================
    // Simulator Executable
    // ============================================================

    // Create root module that the simulator main will import from
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = default_target,
        .optimize = optimize,
    });

    const sim_module = b.createModule(.{
        .root_source_file = b.path("src/simulator/main.zig"),
        .target = default_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigpod", .module = root_module },
        },
    });

    // Add SDL2 build option
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_sdl2", enable_sdl2);
    sim_module.addOptions("build_options", build_options);

    const sim_exe = b.addExecutable(.{
        .name = "zigpod-sim",
        .root_module = sim_module,
    });

    // Link SDL2 if enabled
    if (enable_sdl2) {
        sim_exe.linkSystemLibrary("SDL2");
        sim_exe.linkLibC();
    }

    b.installArtifact(sim_exe);

    const run_sim = b.addRunArtifact(sim_exe);
    run_sim.step.dependOn(b.getInstallStep());

    // Pass command line args to simulator
    if (b.args) |args| {
        run_sim.addArgs(args);
    }

    const sim_step = b.step("sim", "Run the PP5021C simulator");
    sim_step.dependOn(&run_sim.step);

    // ============================================================
    // Unit Tests
    // ============================================================

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = default_target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ============================================================
    // Format Check
    // ============================================================

    const fmt = b.addFmt(.{
        .paths = &.{
            "src",
            "build.zig",
        },
        .check = true,
    });

    const fmt_step = b.step("fmt-check", "Check code formatting");
    fmt_step.dependOn(&fmt.step);

    // Format (fix)
    const fmt_fix = b.addFmt(.{
        .paths = &.{
            "src",
            "build.zig",
        },
        .check = false,
    });

    const fmt_fix_step = b.step("fmt", "Format code");
    fmt_fix_step.dependOn(&fmt_fix.step);
}
