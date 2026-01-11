const std = @import("std");

pub fn build(b: *std.Build) void {
    // ============================================================
    // Target Configuration
    // ============================================================

    // Default to native for testing, can override for ARM target
    const default_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ARM7TDMI target for iPod hardware
    const arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .freestanding,
        .abi = .eabi,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm7tdmi },
    });

    // ============================================================
    // Build Options
    // ============================================================

    const enable_sdl2 = b.option(bool, "sdl2", "Enable SDL2 GUI (requires SDL2 installed)") orelse false;

    // ============================================================
    // ZigPod Firmware - Single Binary (ARM target)
    // ============================================================
    // This builds a complete ZigPod OS that can be installed directly
    // via ipodpatcher. Apple bootloader loads it to 0x10000000.

    const firmware = b.addExecutable(.{
        .name = "zigpod",
        .root_module = b.createModule(.{
            // Use minimal_boot.zig directly (same as working minimal-test)
            .root_source_file = b.path("src/kernel/minimal_boot.zig"),
            .target = arm_target,
            .optimize = .ReleaseSmall,
        }),
    });

    // Use minimal linker script (same as working minimal test)
    firmware.setLinkerScript(b.path("linker/minimal.ld"));

    // Generate raw binary for flashing
    const firmware_bin = firmware.addObjCopy(.{
        .basename = "zigpod.bin",
        .format = .bin,
    });

    // Install both ELF and binary
    b.installArtifact(firmware);

    const install_bin = b.addInstallFile(firmware_bin.getOutput(), "bin/zigpod.bin");

    const firmware_step = b.step("firmware", "Build ZigPod single-binary firmware (install with: ipodpatcher -ab zigpod.bin)");
    firmware_step.dependOn(&install_bin.step);

    // ============================================================
    // Minimal Boot Test (for hardware debugging)
    // ============================================================
    // Builds a tiny binary that just loops - for testing if code runs at all

    const minimal_test = b.addExecutable(.{
        .name = "zigpod-minimal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/minimal_boot.zig"),
            .target = arm_target,
            .optimize = .ReleaseSmall,
        }),
    });

    minimal_test.setLinkerScript(b.path("linker/minimal.ld"));

    const minimal_bin = minimal_test.addObjCopy(.{
        .basename = "zigpod-minimal.bin",
        .format = .bin,
    });

    const install_minimal = b.addInstallFile(minimal_bin.getOutput(), "bin/zigpod-minimal.bin");

    const minimal_step = b.step("minimal-test", "Build minimal test binary (just infinite loop)");
    minimal_step.dependOn(&install_minimal.step);

    // ============================================================
    // HAL Test Firmware (ARM target)
    // ============================================================
    // Tests the HAL stack on real hardware: LCD, fonts, clickwheel

    // Create ARM root module for hal_test imports
    const hal_test_root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = arm_target,
        .optimize = .ReleaseSmall,
    });

    const hal_test = b.addExecutable(.{
        .name = "zigpod-hal-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/hal_test.zig"),
            .target = arm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "zigpod", .module = hal_test_root_module },
            },
        }),
    });

    hal_test.setLinkerScript(b.path("linker/minimal.ld"));

    const hal_test_bin = hal_test.addObjCopy(.{
        .basename = "zigpod-hal-test.bin",
        .format = .bin,
    });

    const install_hal_test = b.addInstallFile(hal_test_bin.getOutput(), "bin/zigpod-hal-test.bin");

    const hal_test_step = b.step("hal-test", "Build HAL test firmware (tests LCD, fonts, clickwheel)");
    hal_test_step.dependOn(&install_hal_test.step);

    // ============================================================
    // ZigPod Bootloader (ARM target)
    // ============================================================

    // Create ARM root module for bootloader imports
    const arm_root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = arm_target,
        .optimize = .ReleaseSmall,
    });

    const bootloader = b.addExecutable(.{
        .name = "zigpod-bootloader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/bootloader.zig"),
            .target = arm_target,
            .optimize = .ReleaseSmall, // Bootloader should be small
            .imports = &.{
                .{ .name = "zigpod", .module = arm_root_module },
            },
        }),
    });

    // Use the bootloader linker script (runs from IRAM)
    bootloader.setLinkerScript(b.path("linker/bootloader.ld"));

    // Generate raw binary for ipodpatcher
    const bootloader_bin = bootloader.addObjCopy(.{
        .basename = "zigpod-bootloader.bin",
        .format = .bin,
    });

    // Install both ELF and binary
    b.installArtifact(bootloader);

    const install_bootloader_bin = b.addInstallFile(bootloader_bin.getOutput(), "bin/zigpod-bootloader.bin");

    const bootloader_step = b.step("bootloader", "Build ZigPod bootloader for iPod hardware");
    bootloader_step.dependOn(&install_bootloader_bin.step);

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
    // iPod Detection Tool (Host)
    // ============================================================

    const ipod_detect_exe = b.addExecutable(.{
        .name = "ipod-detect",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/ipod_detect.zig"),
            .target = default_target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(ipod_detect_exe);

    const run_ipod_detect = b.addRunArtifact(ipod_detect_exe);
    run_ipod_detect.step.dependOn(b.getInstallStep());

    // Pass command line args
    if (b.args) |args| {
        run_ipod_detect.addArgs(args);
    }

    const ipod_detect_step = b.step("ipod-detect", "Detect connected iPod devices");
    ipod_detect_step.dependOn(&run_ipod_detect.step);

    // ============================================================
    // UI Demo (Native with SDL2)
    // ============================================================

    if (enable_sdl2) {
        const demo_module = b.createModule(.{
            .root_source_file = b.path("src/demo/ui_demo.zig"),
            .target = default_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigpod", .module = root_module },
            },
        });

        const demo_exe = b.addExecutable(.{
            .name = "zigpod-demo",
            .root_module = demo_module,
        });

        demo_exe.linkSystemLibrary("SDL2");
        demo_exe.linkLibC();

        b.installArtifact(demo_exe);

        const run_demo = b.addRunArtifact(demo_exe);
        run_demo.step.dependOn(&demo_exe.step);

        const demo_step = b.step("demo", "Run the ZigPod UI demo (requires SDL2)");
        demo_step.dependOn(&run_demo.step);
    }

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
    // Integration Tests
    // ============================================================

    // Create test root module that provides access to all zigpod modules
    const test_root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = default_target,
        .optimize = optimize,
    });

    // Audio Pipeline Integration Tests
    const audio_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/audio_pipeline_test.zig"),
            .target = default_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigpod", .module = test_root_module },
            },
        }),
    });
    const run_audio_integration = b.addRunArtifact(audio_integration_tests);

    // UI Navigation Integration Tests
    const ui_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/ui_navigation_test.zig"),
            .target = default_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigpod", .module = test_root_module },
            },
        }),
    });
    const run_ui_integration = b.addRunArtifact(ui_integration_tests);

    // File Playback Integration Tests
    const file_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/file_playback_test.zig"),
            .target = default_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigpod", .module = test_root_module },
            },
        }),
    });
    const run_file_integration = b.addRunArtifact(file_integration_tests);

    // MP3 Decoder Integration Tests
    const mp3_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/mp3_decoder_test.zig"),
            .target = default_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigpod", .module = test_root_module },
            },
        }),
    });
    const run_mp3_integration = b.addRunArtifact(mp3_integration_tests);

    // Mock FAT32 Integration Tests
    const mock_fat32_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/mock_fat32_test.zig"),
            .target = default_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigpod", .module = test_root_module },
            },
        }),
    });
    const run_mock_fat32 = b.addRunArtifact(mock_fat32_tests);

    // MP3 Playback Integration Tests
    const mp3_playback_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/mp3_playback_test.zig"),
            .target = default_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigpod", .module = test_root_module },
            },
        }),
    });
    const run_mp3_playback = b.addRunArtifact(mp3_playback_tests);

    // MP3 playback test step
    const mp3_playback_step = b.step("test-mp3-playback", "Run MP3 playback integration tests");
    mp3_playback_step.dependOn(&run_mp3_playback.step);

    const integration_step = b.step("test-integration", "Run integration tests");
    integration_step.dependOn(&run_audio_integration.step);
    integration_step.dependOn(&run_ui_integration.step);
    integration_step.dependOn(&run_file_integration.step);
    integration_step.dependOn(&run_mp3_integration.step);
    integration_step.dependOn(&run_mock_fat32.step);

    // Dedicated MP3 test step
    const mp3_test_step = b.step("test-mp3", "Run MP3 decoder tests");
    mp3_test_step.dependOn(&run_mp3_integration.step);

    // Dedicated mock FAT32 test step
    const mock_fat32_step = b.step("test-mock-fat32", "Run mock FAT32 tests");
    mock_fat32_step.dependOn(&run_mock_fat32.step);

    // All tests step
    const all_tests_step = b.step("test-all", "Run all tests (unit + integration)");
    all_tests_step.dependOn(&run_unit_tests.step);
    all_tests_step.dependOn(&run_audio_integration.step);
    all_tests_step.dependOn(&run_ui_integration.step);
    all_tests_step.dependOn(&run_file_integration.step);
    all_tests_step.dependOn(&run_mp3_integration.step);
    all_tests_step.dependOn(&run_mock_fat32.step);

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
