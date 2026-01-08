# ZigPod OS: Comprehensive Implementation Plan

**Version**: 1.0
**Last Updated**: 2026-01-08
**Status**: Planning Phase

---

## Executive Summary

This document outlines a rigorous, test-driven approach to developing ZigPod OS - a custom operating system for the Apple iPod Classic 5th Generation (2005). The plan emphasizes:

- **Zero-bricking philosophy**: All code validated in simulation before hardware deployment
- **Test-Driven Development (TDD)**: Tests written before implementation
- **Hardware Abstraction Layer (HAL)**: Clean separation enabling host-based testing
- **Continuous Integration**: Automated builds, tests, and quality gates
- **Incremental delivery**: Working software at each milestone

---

## Table of Contents

1. [Target Hardware Specifications](#1-target-hardware-specifications)
2. [Development Environment](#2-development-environment)
3. [Project Architecture](#3-project-architecture)
4. [Testing Strategy](#4-testing-strategy)
5. [Simulation Infrastructure](#5-simulation-infrastructure)
6. [CI/CD Pipeline](#6-cicd-pipeline)
7. [Implementation Phases](#7-implementation-phases)
8. [Quality Assurance](#8-quality-assurance)
9. [Risk Management](#9-risk-management)
10. [References & Resources](#10-references--resources)

---

## 1. Target Hardware Specifications

### 1.1 iPod Classic 5th Generation (A1136)

Based on verified documentation from [EveryMac](https://everymac.com/systems/apple/ipod/specs/ipod_5thgen.html) and [The Apple Wiki](https://theapplewiki.com/wiki/PP5021C):

| Component | Specification | Notes |
|-----------|--------------|-------|
| **SoC** | PortalPlayer PP5021C-TDF | Dual-core ARM processor |
| **CPU** | 2x ARM7TDMI | ARMv4T architecture, 80 MHz each |
| **RAM** | 32MB SDRAM (30GB) / 64MB (60GB) | Mobile SDRAM |
| **Storage** | 30GB / 60GB HDD | 1.8" Toshiba MK3008GAL or similar |
| **Display** | 320x240 QVGA LCD | 2.5" TFT, 16-bit color (RGB565) |
| **GPU** | Broadcom BCM2722 | VideoCore 2, H.264/MPEG-4 decode |
| **Audio Codec** | Wolfson WM8758 | 24-bit DAC, I2S interface |
| **Input** | Click Wheel | Capacitive touch, ADC-based |
| **Connectivity** | USB 2.0, Dock connector | 30-pin Apple connector |
| **Battery** | 400-600mAh Li-Ion | Target: 25-30 hours audio playback |

**Important Correction**: The 5th generation uses the **WM8758** codec, not WM8975 (which was used in 4th gen). Source: [Rockbox documentation](https://www.rockbox.org/).

### 1.2 Memory Map (PP5021C)

Based on Rockbox source code and [iPodLinux documentation](http://www.ipodlinux.org/):

```
0x00000000 - 0x0001FFFF  Flash/ROM (128KB boot ROM)
0x10000000 - 0x10001FFF  Internal SRAM (8KB fast memory)
0x40000000 - 0x41FFFFFF  SDRAM (32MB base)
0x60000000 - 0x6FFFFFFF  Peripheral registers
0x70000000 - 0x70FFFFFF  IDE controller
0xC0000000 - 0xCFFFFFFF  Cache controller
```

### 1.3 Key Peripheral Registers

| Peripheral | Base Address | Reference |
|------------|--------------|-----------|
| GPIO | 0x6000D000 | Click wheel, buttons |
| I2C | 0x7000C000 | Audio codec control |
| I2S | 0x70002000 | Audio data |
| LCD Controller | 0x70008000 | Display |
| Timer | 0x60005000 | System tick |
| USB | 0xC5000000 | USB 2.0 OTG |
| IDE | 0xC3000000 | ATA/HDD |

---

## 2. Development Environment

### 2.1 Required Software

| Tool | Version | Purpose | Source |
|------|---------|---------|--------|
| **Zig** | 0.13+ | Primary language & build system | [ziglang.org](https://ziglang.org/) |
| **arm-none-eabi-gcc** | 13+ | Linker, objcopy (backup) | ARM GNU Toolchain |
| **QEMU** | 10.0+ | ARM emulation base | [qemu.org](https://www.qemu.org/) |
| **GDB** | 14+ | Debugging | GNU Project |
| **Git** | 2.40+ | Version control | git-scm.com |
| **Docker** | 24+ | Reproducible builds | docker.com |

### 2.2 Zig Cross-Compilation Setup

Zig natively supports ARM cross-compilation. For ARM7TDMI (ARMv4T):

```zig
// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    // ARM7TDMI target configuration
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm7tdmi },
        .os_tag = .freestanding,
        .abi = .eabi,
    });

    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "zigpod",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Linker script for PP5021C memory layout
    kernel.setLinkerScript(b.path("linker/pp5021c.ld"));

    b.installArtifact(kernel);
}
```

**Verification**: Run `zig targets | grep arm7tdmi` to confirm support.

### 2.3 Development Machine Requirements

- **OS**: Linux (Ubuntu 22.04+) or macOS (13+)
- **RAM**: 16GB minimum (32GB recommended for simulation)
- **Storage**: 50GB free (for toolchain, emulators, test artifacts)
- **CPU**: Multi-core (8+ threads recommended for parallel testing)

### 2.4 Hardware for Testing

| Item | Quantity | Purpose | Est. Cost |
|------|----------|---------|-----------|
| iPod Classic 5G 30GB | 2 | Primary test units | $50-100 each |
| iPod Classic 5G 60GB | 1 | RAM variant testing | $60-120 |
| Segger J-Link EDU | 1 | JTAG debugging | $60 |
| Logic Analyzer (Saleae) | 1 | Protocol debugging | $150-500 |
| USB oscilloscope | 1 | Signal analysis | $100-300 |
| iFlash SD adapter | 2 | Fast storage testing | $50 each |

---

## 3. Project Architecture

### 3.1 Directory Structure

```
zigpod/
├── build.zig                 # Build configuration
├── build.zig.zon            # Package dependencies
├── linker/
│   └── pp5021c.ld           # Linker script
├── src/
│   ├── main.zig             # Entry point
│   ├── kernel/
│   │   ├── boot.zig         # Boot sequence
│   │   ├── interrupts.zig   # IRQ/FIQ handlers
│   │   ├── memory.zig       # Memory allocator
│   │   ├── scheduler.zig    # Task scheduling
│   │   └── syscall.zig      # System calls
│   ├── hal/                 # Hardware Abstraction Layer
│   │   ├── hal.zig          # HAL interface
│   │   ├── pp5021c/         # Real hardware impl
│   │   │   ├── gpio.zig
│   │   │   ├── i2c.zig
│   │   │   ├── i2s.zig
│   │   │   ├── lcd.zig
│   │   │   ├── timer.zig
│   │   │   ├── ide.zig
│   │   │   └── usb.zig
│   │   └── mock/            # Mock implementations
│   │       └── *.zig
│   ├── drivers/
│   │   ├── audio/
│   │   │   ├── wm8758.zig   # Codec driver
│   │   │   └── audio.zig    # Audio subsystem
│   │   ├── display/
│   │   │   └── lcd.zig      # Display driver
│   │   ├── input/
│   │   │   └── clickwheel.zig
│   │   └── storage/
│   │       ├── ata.zig      # ATA/IDE driver
│   │       └── fat32.zig    # FAT32 filesystem
│   ├── audio/
│   │   ├── decoder.zig      # Audio decoder interface
│   │   ├── flac.zig         # FLAC decoder
│   │   ├── aiff.zig         # AIFF decoder
│   │   └── mp3.zig          # MP3 decoder (optional)
│   ├── ui/
│   │   ├── ui.zig           # UI framework
│   │   ├── menu.zig         # Menu system
│   │   ├── now_playing.zig  # Playback screen
│   │   └── fonts/           # Bitmap fonts
│   └── lib/
│       ├── ringbuffer.zig   # Lock-free ring buffer
│       ├── fixed_point.zig  # Fixed-point math
│       └── crc.zig          # CRC calculations
├── tests/
│   ├── unit/                # Unit tests
│   ├── integration/         # Integration tests
│   └── system/              # System-level tests
├── simulator/
│   ├── src/                 # PP5021C simulator
│   └── ui/                  # Simulator GUI
├── tools/
│   ├── flasher/             # Safe flashing tool
│   ├── firmware_dump/       # Firmware extraction
│   └── image_builder/       # Disk image creation
├── docs/
│   ├── 001-zigpod.md
│   ├── 002-plan.md
│   └── 003-implementation-plan.md
└── .github/
    └── workflows/
        ├── ci.yml           # Main CI pipeline
        ├── nightly.yml      # Nightly builds
        └── release.yml      # Release automation
```

### 3.2 Hardware Abstraction Layer (HAL)

The HAL is **critical** for TDD - it allows testing without real hardware.

```zig
// src/hal/hal.zig - HAL Interface
pub const Hal = struct {
    // GPIO
    gpio_read: *const fn (pin: u8) bool,
    gpio_write: *const fn (pin: u8, value: bool) void,
    gpio_set_direction: *const fn (pin: u8, output: bool) void,

    // I2C
    i2c_write: *const fn (addr: u7, data: []const u8) HalError!void,
    i2c_read: *const fn (addr: u7, buffer: []u8) HalError!usize,

    // I2S (Audio)
    i2s_write: *const fn (samples: []const i16) HalError!void,
    i2s_set_sample_rate: *const fn (rate: u32) HalError!void,

    // Timer
    timer_get_ticks: *const fn () u64,
    timer_delay_us: *const fn (us: u32) void,

    // LCD
    lcd_write_pixel: *const fn (x: u16, y: u16, color: u16) void,
    lcd_flush: *const fn () void,

    // Storage
    ata_read_sectors: *const fn (lba: u32, count: u16, buffer: []u8) HalError!void,
    ata_write_sectors: *const fn (lba: u32, count: u16, data: []const u8) HalError!void,

    pub const HalError = error{
        Timeout,
        DeviceNotReady,
        TransferError,
        InvalidParameter,
    };
};

// Real hardware implementation
pub const pp5021c_hal = @import("pp5021c/hal_impl.zig").hal;

// Mock implementation for testing
pub const mock_hal = @import("mock/hal_mock.zig").hal;
```

### 3.3 Layered Architecture

```
┌─────────────────────────────────────────────────┐
│                  Applications                    │
│            (UI, Music Player, Settings)          │
├─────────────────────────────────────────────────┤
│                   Services                       │
│     (Audio Engine, File Manager, Power Mgmt)    │
├─────────────────────────────────────────────────┤
│                   Drivers                        │
│    (WM8758, LCD, Click Wheel, ATA, FAT32)       │
├─────────────────────────────────────────────────┤
│           Hardware Abstraction Layer             │
│     (GPIO, I2C, I2S, Timer, DMA, Interrupts)    │
├─────────────────────────────────────────────────┤
│                    Kernel                        │
│   (Scheduler, Memory, Interrupts, Boot)         │
├─────────────────────────────────────────────────┤
│                  Hardware                        │
│              (PP5021C / Simulator)               │
└─────────────────────────────────────────────────┘
```

---

## 4. Testing Strategy

### 4.1 Test-Driven Development (TDD) Process

Based on [James Grenning's "Test-Driven Development for Embedded C"](https://pragprog.com/titles/jgade/test-driven-development-for-embedded-c/) principles:

```
┌──────────────────────────────────────────────────────────┐
│                    TDD Cycle                             │
│                                                          │
│   ┌─────────┐    ┌─────────┐    ┌──────────┐           │
│   │  RED    │───▶│  GREEN  │───▶│ REFACTOR │───┐       │
│   │ (Write  │    │ (Make   │    │ (Clean   │   │       │
│   │  Test)  │    │  Pass)  │    │   Up)    │   │       │
│   └─────────┘    └─────────┘    └──────────┘   │       │
│        ▲                                        │       │
│        └────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────┘
```

**Rules**:
1. Write a failing test before writing production code
2. Write only enough test to fail (compilation counts)
3. Write only enough production code to pass the test
4. Refactor to remove duplication

### 4.2 Test Pyramid

```
                    ╱╲
                   ╱  ╲
                  ╱ HW ╲         Hardware Tests (5%)
                 ╱ Tests╲        - On real iPod via JTAG
                ╱────────╲       - Power measurements
               ╱ System   ╲      - Audio quality tests
              ╱   Tests    ╲
             ╱──────────────╲    System Tests (15%)
            ╱  Integration   ╲   - Full boot simulation
           ╱     Tests        ╲  - Multi-component interaction
          ╱────────────────────╲
         ╱      Unit Tests      ╲ Integration Tests (30%)
        ╱                        ╲- Driver + HAL mock
       ╱──────────────────────────╲
      ╱        Host Tests          ╲ Unit Tests (50%)
     ╱                              ╲- Pure logic
    ╱────────────────────────────────╲- HAL mocked
```

### 4.3 Zig Testing Framework

Zig has built-in testing support. From [Zig documentation](https://ziglang.org/documentation/master/):

```zig
// src/audio/flac.zig
const std = @import("std");

pub const FlacDecoder = struct {
    // ... implementation

    pub fn decodeFrame(self: *FlacDecoder, input: []const u8) ![]i16 {
        // ... decoding logic
    }
};

// Tests are co-located with source
test "FlacDecoder decodes silence correctly" {
    var decoder = FlacDecoder.init(std.testing.allocator);
    defer decoder.deinit();

    const silence_frame = [_]u8{ /* ... */ };
    const samples = try decoder.decodeFrame(&silence_frame);

    for (samples) |sample| {
        try std.testing.expectEqual(@as(i16, 0), sample);
    }
}

test "FlacDecoder handles corrupt frame" {
    var decoder = FlacDecoder.init(std.testing.allocator);
    defer decoder.deinit();

    const corrupt_frame = [_]u8{ 0xFF, 0xFF, 0xFF };
    try std.testing.expectError(error.InvalidFrame, decoder.decodeFrame(&corrupt_frame));
}
```

Run tests: `zig build test`

### 4.4 Mock Implementation Example

```zig
// src/hal/mock/hal_mock.zig
const std = @import("std");
const Hal = @import("../hal.zig").Hal;

pub const MockHal = struct {
    gpio_state: [128]bool = [_]bool{false} ** 128,
    i2c_write_log: std.ArrayList(I2cTransaction),
    audio_buffer: std.ArrayList(i16),
    tick_counter: u64 = 0,

    const I2cTransaction = struct {
        addr: u7,
        data: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) MockHal {
        return .{
            .i2c_write_log = std.ArrayList(I2cTransaction).init(allocator),
            .audio_buffer = std.ArrayList(i16).init(allocator),
        };
    }

    pub fn deinit(self: *MockHal) void {
        self.i2c_write_log.deinit();
        self.audio_buffer.deinit();
    }

    // Verification helpers
    pub fn expectI2cWrite(self: *MockHal, addr: u7, expected_data: []const u8) !void {
        const transaction = self.i2c_write_log.popOrNull() orelse
            return error.NoI2cTransaction;
        try std.testing.expectEqual(addr, transaction.addr);
        try std.testing.expectEqualSlices(u8, expected_data, transaction.data);
    }
};

// HAL interface implementation pointing to mock
pub const hal = Hal{
    .gpio_read = mockGpioRead,
    .gpio_write = mockGpioWrite,
    // ... etc
};
```

### 4.5 Test Categories

| Category | Location | Runs On | Frequency |
|----------|----------|---------|-----------|
| Unit Tests | `tests/unit/` | Host (x86/ARM64) | Every commit |
| Integration Tests | `tests/integration/` | Host + Simulator | Every commit |
| System Tests | `tests/system/` | Full Simulator | Nightly |
| Hardware Tests | `tests/hardware/` | Real iPod | Manual/Release |
| Performance Tests | `tests/perf/` | Simulator + HW | Weekly |
| Fuzz Tests | `tests/fuzz/` | Host | Nightly |

---

## 5. Simulation Infrastructure

### 5.1 Simulation Strategy

Since no complete iPod 5G emulator exists, we'll build one incrementally:

```
┌─────────────────────────────────────────────────────────────┐
│                    Simulation Layers                         │
├─────────────────────────────────────────────────────────────┤
│  Level 3: Full System Simulator                             │
│  - Complete PP5021C emulation                               │
│  - Cycle-accurate (optional)                                │
│  - GUI with LCD display, click wheel input                  │
├─────────────────────────────────────────────────────────────┤
│  Level 2: Functional Simulator                              │
│  - Peripheral emulation (GPIO, I2C, I2S, ATA)              │
│  - Memory model                                              │
│  - Interrupt simulation                                      │
├─────────────────────────────────────────────────────────────┤
│  Level 1: HAL Mock                                          │
│  - Direct function call substitution                        │
│  - State recording for verification                         │
│  - Runs on host at native speed                            │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 Existing Tools Analysis

| Tool | Status | Usefulness | Reference |
|------|--------|------------|-----------|
| **Clicky** | WIP (iPod 4G focus) | Medium - Can extend | [github.com/daniel5151/clicky](https://github.com/daniel5151/clicky) |
| **QEMU ARM** | Mature | High - Base for custom machine | [qemu.org](https://www.qemu.org/docs/master/system/target-arm.html) |
| **Rockbox Simulator** | Mature | High - UI testing | [rockbox.org](https://www.rockbox.org/) |

### 5.3 Custom PP5021C Simulator

We'll build a Zig-native simulator for maximum integration:

```zig
// simulator/src/pp5021c.zig
const std = @import("std");

pub const PP5021C = struct {
    // CPU state
    cpu0: Arm7tdmi,
    cpu1: Arm7tdmi,

    // Memory
    rom: [128 * 1024]u8,          // 128KB boot ROM
    sram: [8 * 1024]u8,           // 8KB fast SRAM
    sdram: []u8,                  // 32/64MB SDRAM

    // Peripherals
    gpio: GpioController,
    i2c: I2cController,
    i2s: I2sController,
    timer: TimerController,
    lcd: LcdController,
    ide: IdeController,

    // Simulation state
    cycle_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, ram_size: usize) !PP5021C {
        return .{
            .cpu0 = Arm7tdmi.init(),
            .cpu1 = Arm7tdmi.init(),
            .sdram = try allocator.alloc(u8, ram_size),
            .gpio = GpioController.init(),
            .i2c = I2cController.init(),
            .i2s = I2sController.init(),
            .timer = TimerController.init(),
            .lcd = LcdController.init(),
            .ide = IdeController.init(),
        };
    }

    pub fn step(self: *PP5021C) void {
        // Execute one instruction on each CPU
        self.cpu0.step(&self.memory_bus);
        self.cpu1.step(&self.memory_bus);

        // Update peripherals
        self.timer.tick();
        self.i2s.tick();

        self.cycle_count += 1;
    }

    pub fn loadFirmware(self: *PP5021C, firmware: []const u8) void {
        @memcpy(self.sdram[0..firmware.len], firmware);
    }
};

// ARM7TDMI CPU emulator
pub const Arm7tdmi = struct {
    regs: [16]u32 = [_]u32{0} ** 16,
    cpsr: u32 = 0,
    spsr: u32 = 0,

    pub fn step(self: *Arm7tdmi, bus: *MemoryBus) void {
        const pc = self.regs[15];
        const instruction = bus.read32(pc);

        // Decode and execute
        self.execute(instruction, bus);
    }

    // ... instruction implementations
};
```

### 5.4 Simulator Features

| Feature | Priority | Description |
|---------|----------|-------------|
| ARM7TDMI core | P0 | Instruction-accurate CPU emulation |
| Memory bus | P0 | Address decoding, access timing |
| GPIO | P0 | Digital I/O, click wheel interface |
| Timer | P0 | System tick, delays |
| I2C | P1 | Codec control communication |
| I2S | P1 | Audio sample output |
| LCD Controller | P1 | Frame buffer, display simulation |
| IDE/ATA | P1 | Storage access |
| DMA | P2 | Memory transfers |
| USB | P3 | Debug/file transfer |

### 5.5 Simulator GUI

Using Zig's raylib bindings or SDL2 for visualization:

```
┌─────────────────────────────────────────┐
│  ZigPod Simulator                    [X]│
├─────────────────────────────────────────┤
│  ┌─────────────┐  ┌──────────────────┐ │
│  │             │  │ CPU0: Running    │ │
│  │   LCD       │  │ PC: 0x40001234   │ │
│  │  320x240    │  │ Cycles: 1234567  │ │
│  │             │  │                  │ │
│  │             │  │ CPU1: Halted     │ │
│  └─────────────┘  │ PC: 0x40000000   │ │
│                   │                  │ │
│  ┌─────────────┐  ├──────────────────┤ │
│  │ Click Wheel │  │ I2S Buffer: 45%  │ │
│  │    [ ^ ]    │  │ GPIO: 0x0F00     │ │
│  │ [<] [●] [>] │  │ IRQ: Pending     │ │
│  │    [ v ]    │  └──────────────────┘ │
│  │ [Menu][Play]│                       │
│  └─────────────┘                       │
└─────────────────────────────────────────┘
```

---

## 6. CI/CD Pipeline

### 6.1 Pipeline Overview

Based on [mlugg/setup-zig](https://github.com/mlugg/setup-zig) for GitHub Actions:

```yaml
# .github/workflows/ci.yml
name: ZigPod CI

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

env:
  ZIG_VERSION: "0.13.0"

jobs:
  # Stage 1: Build and Unit Tests
  build-and-test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        target: [native, arm-freestanding]
    steps:
      - uses: actions/checkout@v4

      - name: Setup Zig
        uses: mlugg/setup-zig@v1
        with:
          version: ${{ env.ZIG_VERSION }}

      - name: Build
        run: zig build -Dtarget=${{ matrix.target }}

      - name: Run Unit Tests
        if: matrix.target == 'native'
        run: zig build test

      - name: Upload Artifacts
        uses: actions/upload-artifact@v4
        with:
          name: zigpod-${{ matrix.target }}
          path: zig-out/

  # Stage 2: Integration Tests
  integration-tests:
    needs: build-and-test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Zig
        uses: mlugg/setup-zig@v1
        with:
          version: ${{ env.ZIG_VERSION }}

      - name: Build Simulator
        run: zig build simulator

      - name: Run Integration Tests
        run: zig build test-integration

      - name: Upload Test Results
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: test-results/

  # Stage 3: System Tests (Nightly)
  system-tests:
    if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
    needs: integration-tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Zig
        uses: mlugg/setup-zig@v1
        with:
          version: ${{ env.ZIG_VERSION }}

      - name: Build Full System
        run: zig build -Drelease

      - name: Run System Tests
        run: |
          zig build simulator
          ./zig-out/bin/simulator --headless --run-tests

      - name: Performance Benchmarks
        run: zig build bench

  # Stage 4: Static Analysis
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Zig
        uses: mlugg/setup-zig@v1
        with:
          version: ${{ env.ZIG_VERSION }}

      - name: Format Check
        run: zig fmt --check src/ tests/

      - name: Build with All Warnings
        run: zig build -Dwarnings

  # Stage 5: Documentation
  docs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Zig
        uses: mlugg/setup-zig@v1
        with:
          version: ${{ env.ZIG_VERSION }}

      - name: Generate Docs
        run: zig build docs

      - name: Deploy to GitHub Pages
        if: github.ref == 'refs/heads/main'
        uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./zig-out/docs
```

### 6.2 Quality Gates

| Gate | Threshold | Action on Failure |
|------|-----------|-------------------|
| Unit Test Pass Rate | 100% | Block merge |
| Integration Test Pass Rate | 100% | Block merge |
| Code Coverage | > 80% | Warning |
| Build Size | < 1MB | Block merge |
| Format Check | Pass | Block merge |
| No Compiler Warnings | Pass | Block merge |

### 6.3 Nightly Builds

```yaml
# .github/workflows/nightly.yml
name: Nightly Build

on:
  schedule:
    - cron: '0 2 * * *'  # 2 AM UTC daily
  workflow_dispatch:

jobs:
  nightly:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Full Test Suite
        run: |
          zig build test-all
          zig build fuzz -- --iterations 10000

      - name: Build Release
        run: zig build -Doptimize=ReleaseSmall

      - name: Size Report
        run: |
          ls -la zig-out/bin/zigpod.bin
          arm-none-eabi-size zig-out/bin/zigpod.elf

      - name: Create Nightly Release
        uses: softprops/action-gh-release@v1
        with:
          tag_name: nightly-${{ github.run_number }}
          prerelease: true
          files: |
            zig-out/bin/zigpod.bin
            zig-out/bin/zigpod.elf
```

---

## 7. Implementation Phases

### Phase 0: Project Setup (Week 1)

**Objective**: Establish development infrastructure

| Task | Deliverable | Test |
|------|-------------|------|
| Initialize Git repository | `.git/`, `.gitignore` | `git status` clean |
| Create `build.zig` | Cross-compilation working | `zig build` succeeds |
| Set up CI pipeline | GitHub Actions green | PR checks pass |
| Create linker script | `pp5021c.ld` | Links ARM binary |
| Document coding standards | `CONTRIBUTING.md` | Team review |

**Exit Criteria**:
- `zig build` produces ARM binary
- CI runs on every commit
- Documentation complete

---

### Phase 1: HAL Foundation (Weeks 2-3)

**Objective**: Implement Hardware Abstraction Layer with full test coverage

**TDD Sequence**:

1. **GPIO HAL**
   ```zig
   // Test first
   test "GPIO can set pin high" {
       var mock = MockHal.init(testing.allocator);
       defer mock.deinit();

       gpio.write(&mock.hal, 5, true);
       try testing.expect(mock.gpio_state[5] == true);
   }
   ```

2. **Timer HAL**
   ```zig
   test "Timer delay waits correct microseconds" {
       var mock = MockHal.init(testing.allocator);
       const start = mock.tick_counter;

       timer.delayUs(&mock.hal, 1000);

       try testing.expect(mock.tick_counter >= start + 80); // 80 cycles @ 80MHz = 1us
   }
   ```

3. **I2C HAL**
4. **I2S HAL**
5. **ATA HAL**

| Deliverable | Test Coverage |
|-------------|---------------|
| `src/hal/hal.zig` (interface) | N/A (interface) |
| `src/hal/pp5021c/*.zig` (impl) | 90%+ |
| `src/hal/mock/*.zig` | 100% |

---

### Phase 2: Boot Sequence (Weeks 4-5)

**Objective**: Minimal bootable system

**Components**:

1. **Vector Table**
   ```zig
   // src/kernel/boot.zig
   export const vector_table linksection(".vectors") = [_]?*const fn () void{
       resetHandler,    // Reset
       undefined,       // Undefined instruction
       swiHandler,      // Software interrupt
       prefetchAbort,   // Prefetch abort
       dataAbort,       // Data abort
       null,            // Reserved
       irqHandler,      // IRQ
       fiqHandler,      // FIQ
   };
   ```

2. **Memory Initialization**
3. **Stack Setup**
4. **BSS Clear**
5. **Jump to Main**

**Tests**:
- Simulator boots to `main()`
- Memory correctly initialized
- Stack pointer valid

---

### Phase 3: Core Kernel (Weeks 6-8)

**Objective**: Basic kernel services

| Component | Description | Tests |
|-----------|-------------|-------|
| Memory Allocator | Fixed-block allocator for embedded | Allocation/free cycles, fragmentation |
| Interrupt Handler | IRQ/FIQ dispatch | Mock interrupt triggering |
| Task Scheduler | Cooperative multitasking (then preemptive) | Context switch, priority |
| Timer Service | System tick, delays | Timing accuracy |

**TDD Example - Scheduler**:
```zig
test "Scheduler runs highest priority task" {
    var scheduler = Scheduler.init();

    var low_ran = false;
    var high_ran = false;

    scheduler.addTask(.{ .priority = 1, .func = &(struct {
        fn run() void { low_ran = true; }
    }).run });

    scheduler.addTask(.{ .priority = 10, .func = &(struct {
        fn run() void { high_ran = true; }
    }).run });

    scheduler.runOne();

    try testing.expect(high_ran);
    try testing.expect(!low_ran);
}
```

---

### Phase 4: Display Driver (Weeks 9-10)

**Objective**: Working LCD output

| Task | Test |
|------|------|
| LCD initialization sequence | Simulator shows initialized state |
| Pixel writing | Visual verification in simulator |
| Frame buffer management | Memory bounds, DMA transfer |
| Text rendering | Character output correct |
| Basic graphics primitives | Lines, rectangles, fill |

---

### Phase 5: Audio Subsystem (Weeks 11-14)

**Objective**: Audio playback capability

**Components**:

1. **WM8758 Codec Driver**
   - I2C control interface
   - Volume, EQ settings
   - Power management

2. **I2S Audio Output**
   - DMA-based sample transfer
   - Double buffering
   - Sample rate configuration

3. **Audio Decoders**
   - FLAC (lossless priority)
   - WAV/AIFF (uncompressed)
   - MP3 (optional, patent-free now)

**Tests**:
```zig
test "FLAC decoder produces correct samples" {
    const reference_wav = @embedFile("test_data/reference.wav");
    const flac_file = @embedFile("test_data/reference.flac");

    var decoder = FlacDecoder.init(testing.allocator);
    const decoded = try decoder.decodeAll(flac_file);

    // Compare with reference (allowing for floating point)
    for (decoded, 0..) |sample, i| {
        try testing.expectApproxEqAbs(
            @as(f32, @floatFromInt(reference_wav[i])),
            @as(f32, @floatFromInt(sample)),
            1.0
        );
    }
}
```

---

### Phase 6: Storage & Filesystem (Weeks 15-17)

**Objective**: Read files from storage

| Component | Test |
|-----------|------|
| ATA/IDE driver | Sector read/write |
| Partition table parsing | MBR/GPT detection |
| FAT32 filesystem | File open, read, directory listing |
| File cache | Cache hit rate, eviction |

---

### Phase 7: Input System (Week 18)

**Objective**: Click wheel and button input

| Input | Method | Test |
|-------|--------|------|
| Click wheel rotation | ADC sampling | Direction detection |
| Center button | GPIO | Press/release events |
| Menu button | GPIO | Long press detection |
| Play/Pause | GPIO | Debouncing |
| Prev/Next | GPIO | Repeat rate |

---

### Phase 8: User Interface (Weeks 19-22)

**Objective**: Usable menu system

**Components**:
- Menu navigation
- Now Playing screen
- File browser
- Settings

**UI Tests**:
```zig
test "Menu navigation with click wheel" {
    var ui = UI.init(mock_hal, mock_display);
    var menu = ui.createMenu(&[_][]const u8{ "Artists", "Albums", "Songs" });

    // Simulate wheel rotation
    ui.handleInput(.{ .wheel_delta = 1 });
    try testing.expectEqual(@as(usize, 1), menu.selected_index);

    // Select item
    ui.handleInput(.{ .button = .center, .state = .pressed });
    try testing.expect(menu.item_activated);
}
```

---

### Phase 9: Power Management (Weeks 23-24)

**Objective**: Maximize battery life

| Feature | Target | Test |
|---------|--------|------|
| CPU frequency scaling | < 15% usage during playback | Power measurement |
| Sleep modes | < 5mA in standby | Hardware test |
| Peripheral power down | Disable unused | Current measurement |
| Backlight control | Timeout, brightness | Timer test |

---

### Phase 10: Integration & Polish (Weeks 25-28)

**Objective**: Production-ready release

| Task | Criteria |
|------|----------|
| Full system integration | All components working together |
| Performance optimization | 25+ hours audio playback |
| Bug fixes | Zero P0/P1 bugs |
| Documentation | User manual, developer guide |
| Safe installer | Dual-boot, recovery mode |

---

## 8. Quality Assurance

### 8.1 Code Quality Metrics

| Metric | Tool | Target |
|--------|------|--------|
| Test Coverage | kcov + zig test | > 80% |
| Cyclomatic Complexity | Custom analyzer | < 10 per function |
| Code Duplication | Custom analyzer | < 5% |
| Binary Size | arm-none-eabi-size | < 1MB |
| Stack Usage | Static analysis | < 8KB per task |

### 8.2 Testing Tools

| Tool | Purpose | Integration |
|------|---------|-------------|
| Zig built-in test | Unit tests | `zig build test` |
| Custom test harness | Integration tests | `zig build test-integration` |
| Simulator | System tests | `./simulator --test` |
| kcov | Coverage | CI pipeline |
| Valgrind (host) | Memory leaks | `zig build test-valgrind` |
| AFL++ | Fuzz testing | Nightly |

### 8.3 Hardware Testing Protocol

1. **Pre-flight Checklist**
   - [ ] Full simulator test suite passes
   - [ ] Binary size < 1MB
   - [ ] No compiler warnings
   - [ ] Code reviewed
   - [ ] Backup firmware image created

2. **Test Procedure**
   - Flash via JTAG (not replacing bootloader)
   - Monitor via serial debug
   - Test each subsystem in isolation
   - Full integration test
   - Battery life test (24+ hours)

3. **Rollback Procedure**
   - DFU mode restore
   - Original firmware backup restoration
   - Never test without backup iPod

---

## 9. Risk Management

### 9.1 Risk Matrix

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Bricking device | Low | High | Simulation-first, backup units |
| ARM7TDMI Zig support issues | Medium | High | Fallback to C for critical paths |
| Incomplete hardware documentation | High | Medium | Rockbox source reference |
| Audio quality issues | Medium | High | Extensive codec testing |
| Battery life target missed | Medium | High | Early power profiling |
| Timeline slip | High | Medium | Prioritize core features |

### 9.2 Contingency Plans

**If ARM7TDMI Zig compilation fails**:
1. Verify target with `zig targets | grep arm`
2. Use `arm` arch with `v4t` feature set
3. Fallback: Implement critical sections in ARM assembly
4. Fallback: Use C for bootloader, Zig for application

**If emulator development stalls**:
1. Use Rockbox simulator for UI testing
2. Extend Clicky emulator (Rust)
3. Hardware-in-the-loop testing earlier

**If battery life target not met**:
1. Profile with oscilloscope
2. Identify power-hungry subsystems
3. Implement aggressive sleep modes
4. Accept reduced target (20 hours minimum)

---

## 10. References & Resources

### 10.1 Hardware Documentation

- [iPod 5th Gen Specs - EveryMac](https://everymac.com/systems/apple/ipod/specs/ipod_5thgen.html)
- [PP5021C - The Apple Wiki](https://theapplewiki.com/wiki/PP5021C)
- [PortalPlayer - Wikipedia](https://en.wikipedia.org/wiki/PortalPlayer)
- [Wolfson WM8758 Datasheet](https://www.cirrus.com/products/wm8758/)

### 10.2 Software Resources

- [Zig Language Documentation](https://ziglang.org/documentation/master/)
- [MicroZig - Embedded Zig Framework](https://microzig.tech/)
- [Rockbox Source Code](https://git.rockbox.org/)
- [iPodLoader2 Source](https://github.com/crozone/ipodloader2)
- [Clicky iPod Emulator](https://github.com/daniel5151/clicky)

### 10.3 Testing References

- [Test-Driven Development for Embedded C - James Grenning](https://pragprog.com/titles/jgade/test-driven-development-for-embedded-c/)
- [Zig Testing Documentation](https://ziglang.org/documentation/master/#Zig-Test)
- [Embedded TDD Mocking](https://www.boulderes.com/resource-library/embedded-tdd-mocking)

### 10.4 CI/CD

- [mlugg/setup-zig - GitHub Actions](https://github.com/mlugg/setup-zig)
- [Zig Build System](https://ziglang.org/documentation/master/#Build-System)

---

## Appendix A: Claude Code Permission Configuration

To run Claude Code without permission prompts, create or modify `.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)",
      "Glob(*)",
      "Grep(*)",
      "WebFetch(*)",
      "WebSearch(*)"
    ],
    "deny": []
  }
}
```

Or run with the flag:
```bash
claude --dangerously-skip-permissions
```

**Warning**: This allows all operations without confirmation. Use in trusted environments only.

---

## Appendix B: Quick Start Commands

```bash
# Clone repository
git clone https://github.com/yourusername/zigpod.git
cd zigpod

# Install Zig (macOS)
brew install zig

# Verify ARM target support
zig targets | grep arm7tdmi

# Build for host (testing)
zig build

# Build for iPod
zig build -Dtarget=arm-freestanding-eabi

# Run unit tests
zig build test

# Run simulator
zig build simulator && ./zig-out/bin/simulator

# Format code
zig fmt src/ tests/
```

---

**Document Control**

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-08 | Claude | Initial comprehensive plan |
