const std = @import("std");

pub fn build(b: *std.Build) void {
    // ============================================================
    // Target Configuration
    // ============================================================

    // Default to native for testing, can override for ARM target
    const default_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
