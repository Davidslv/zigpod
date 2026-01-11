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
    // PP5021C Emulator (Accurate ARM7TDMI + Peripherals)
    // ============================================================

    const emulator_module = b.createModule(.{
        .root_source_file = b.path("src/emulator/main.zig"),
        .target = default_target,
        .optimize = optimize,
    });

    // Add SDL2 build option for emulator
    const emulator_build_options = b.addOptions();
    emulator_build_options.addOption(bool, "enable_sdl2", enable_sdl2);
    emulator_module.addOptions("build_options", emulator_build_options);

    const emulator_exe = b.addExecutable(.{
        .name = "zigpod-emulator",
        .root_module = emulator_module,
    });

    // Link SDL2 if enabled
    if (enable_sdl2) {
        emulator_exe.linkSystemLibrary("SDL2");
        emulator_exe.linkLibC();
    }

    b.installArtifact(emulator_exe);

    const run_emulator = b.addRunArtifact(emulator_exe);
    run_emulator.step.dependOn(b.getInstallStep());

    // Pass command line args to emulator
    if (b.args) |args| {
        run_emulator.addArgs(args);
    }

    const emulator_step = b.step("emulator", "Run the PP5021C emulator");
    emulator_step.dependOn(&run_emulator.step);

    // ============================================================
    // Emulator LCD Test Firmware (ARM)
    // ============================================================

    const lcd_test = b.addExecutable(.{
        .name = "lcd-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/emulator/test_firmware/lcd_test.zig"),
            .target = arm_target,
            .optimize = .ReleaseSmall,
        }),
    });

    lcd_test.setLinkerScript(b.path("linker/emulator_test.ld"));

    const lcd_test_bin = lcd_test.addObjCopy(.{
        .basename = "lcd-test.bin",
        .format = .bin,
    });

    const install_lcd_test = b.addInstallFile(lcd_test_bin.getOutput(), "bin/lcd-test.bin");

    const lcd_test_step = b.step("lcd-test", "Build LCD test firmware for emulator");
    lcd_test_step.dependOn(&install_lcd_test.step);

    // ============================================================
    // Emulator Thumb Mode Test Firmware (ARM + Thumb)
    // ============================================================

    const thumb_test = b.addExecutable(.{
        .name = "thumb-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/emulator/test_firmware/thumb_test.zig"),
            .target = arm_target,
            .optimize = .ReleaseSmall,
        }),
    });

    thumb_test.setLinkerScript(b.path("linker/emulator_test.ld"));

    const thumb_test_bin = thumb_test.addObjCopy(.{
        .basename = "thumb-test.bin",
        .format = .bin,
    });

    const install_thumb_test = b.addInstallFile(thumb_test_bin.getOutput(), "bin/thumb-test.bin");

    const thumb_test_step = b.step("thumb-test", "Build Thumb mode test firmware for emulator");
    thumb_test_step.dependOn(&install_thumb_test.step);

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
    // Firmware Generator Tools (Host)
    // ============================================================

    // Boot Stub Generator
    const gen_boot_stub = b.addExecutable(.{
        .name = "gen-boot-stub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_boot_stub.zig"),
            .target = default_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(gen_boot_stub);

    const run_gen_boot_stub = b.addRunArtifact(gen_boot_stub);
    run_gen_boot_stub.step.dependOn(b.getInstallStep());
    const gen_boot_stub_step = b.step("gen-boot-stub", "Generate boot stub firmware");
    gen_boot_stub_step.dependOn(&run_gen_boot_stub.step);

    // Test Firmware Generator
    const gen_test_firmware = b.addExecutable(.{
        .name = "gen-test-firmware",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_test_firmware.zig"),
            .target = default_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(gen_test_firmware);

    const run_gen_test_firmware = b.addRunArtifact(gen_test_firmware);
    run_gen_test_firmware.step.dependOn(b.getInstallStep());
    const gen_test_firmware_step = b.step("gen-test-firmware", "Generate test firmware");
    gen_test_firmware_step.dependOn(&run_gen_test_firmware.step);

    // IRQ Test Firmware Generator
    const gen_irq_test = b.addExecutable(.{
        .name = "gen-irq-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_irq_test.zig"),
            .target = default_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(gen_irq_test);

    const run_gen_irq_test = b.addRunArtifact(gen_irq_test);
    run_gen_irq_test.step.dependOn(b.getInstallStep());
    const gen_irq_test_step = b.step("gen-irq-test", "Generate IRQ test firmware");
    gen_irq_test_step.dependOn(&run_gen_irq_test.step);

    // LCD Test Firmware Generator
    const gen_lcd_test = b.addExecutable(.{
        .name = "gen-lcd-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_lcd_test.zig"),
            .target = default_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(gen_lcd_test);

    const run_gen_lcd_test = b.addRunArtifact(gen_lcd_test);
    run_gen_lcd_test.step.dependOn(b.getInstallStep());
    const gen_lcd_test_step = b.step("gen-lcd-test", "Generate LCD test firmware");
    gen_lcd_test_step.dependOn(&run_gen_lcd_test.step);

    // ATA Test Firmware Generator
    const gen_ata_test = b.addExecutable(.{
        .name = "gen-ata-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_ata_test.zig"),
            .target = default_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(gen_ata_test);

    const run_gen_ata_test = b.addRunArtifact(gen_ata_test);
    run_gen_ata_test.step.dependOn(b.getInstallStep());
    const gen_ata_test_step = b.step("gen-ata-test", "Generate ATA test firmware");
    gen_ata_test_step.dependOn(&run_gen_ata_test.step);

    // Audio Test Firmware Generator
    const gen_audio_test = b.addExecutable(.{
        .name = "gen-audio-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_audio_test.zig"),
            .target = default_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(gen_audio_test);

    const run_gen_audio_test = b.addRunArtifact(gen_audio_test);
    run_gen_audio_test.step.dependOn(b.getInstallStep());
    const gen_audio_test_step = b.step("gen-audio-test", "Generate audio test firmware");
    gen_audio_test_step.dependOn(&run_gen_audio_test.step);

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

    // Emulator unit tests
    const emulator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/emulator/core.zig"),
            .target = default_target,
            .optimize = optimize,
        }),
    });

    const run_emulator_tests = b.addRunArtifact(emulator_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_emulator_tests.step);

    // Dedicated emulator test step
    const emulator_test_step = b.step("test-emulator", "Run emulator unit tests");
    emulator_test_step.dependOn(&run_emulator_tests.step);

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
