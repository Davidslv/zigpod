//! ZigPod OS - Custom Operating System for iPod Video 5th Generation
//!
//! This is the root module that exports all public APIs for the ZigPod OS.
//! It can be used both for the actual firmware (ARM target) and for testing
//! on the host system with mock implementations.

const std = @import("std");
const builtin = @import("builtin");

// ============================================================
// Hardware Abstraction Layer
// ============================================================

/// Hardware Abstraction Layer - provides a unified interface to hardware
/// that can be swapped between real hardware and mock implementations.
pub const hal = @import("hal/hal.zig");

// ============================================================
// Kernel Components
// ============================================================

/// Kernel boot and initialization
pub const boot = @import("kernel/boot.zig");

/// Memory management and allocators
pub const memory = @import("kernel/memory.zig");

/// Interrupt handling
pub const interrupts = @import("kernel/interrupts.zig");

/// Timer and delay utilities
pub const timer = @import("kernel/timer.zig");

// ============================================================
// Drivers
// ============================================================

/// I2C bus driver
pub const i2c = @import("drivers/i2c.zig");

/// GPIO driver
pub const gpio = @import("drivers/gpio.zig");

/// PCF50605 Power Management Unit driver
pub const pmu = @import("drivers/pmu.zig");

/// WM8758 Audio Codec driver
pub const codec = @import("drivers/audio/codec.zig");

/// I2S audio interface
pub const i2s = @import("drivers/audio/i2s.zig");

/// ATA/IDE storage driver
pub const ata = @import("drivers/storage/ata.zig");

/// Storage type detection (HDD vs Flash/iFlash)
pub const storage_detect = @import("drivers/storage/storage_detect.zig");

/// LCD display driver
pub const lcd = @import("drivers/display/lcd.zig");

/// Click wheel input driver
pub const clickwheel = @import("drivers/input/clickwheel.zig");

/// Power management driver
pub const power = @import("drivers/power.zig");

/// USB driver
pub const usb = @import("drivers/usb.zig");

// ============================================================
// Filesystem
// ============================================================

/// FAT32 filesystem implementation
pub const fat32 = @import("drivers/storage/fat32.zig");

// ============================================================
// Audio
// ============================================================

/// Audio playback engine
pub const audio = @import("audio/audio.zig");

// ============================================================
// User Interface
// ============================================================

/// UI framework
pub const ui = @import("ui/ui.zig");

// ============================================================
// Application
// ============================================================

/// Application controller
pub const app = @import("app/app.zig");

// ============================================================
// Library
// ============================================================

/// Music library and playlist management
pub const library = @import("library/library.zig");

// ============================================================
// Utility Library
// ============================================================

/// Ring buffer implementation
pub const RingBuffer = @import("lib/ring_buffer.zig").RingBuffer;

/// Fixed-point math utilities
pub const fixed = @import("lib/fixed_point.zig");

/// CRC calculations
pub const crc = @import("lib/crc.zig");

// ============================================================
// Performance Profiling
// ============================================================

/// Performance metrics and profiling
pub const perf = @import("perf/metrics.zig");

// ============================================================
// Simulator
// ============================================================

/// PP5021C simulator for host-based testing
pub const simulator = @import("simulator/simulator.zig");

// ============================================================
// Integration Tests
// ============================================================

/// Integration tests for multi-component interaction
pub const integration_tests = @import("tests/integration_tests.zig");

// ============================================================
// Platform Detection
// ============================================================

/// Returns true if running on actual ARM hardware
pub fn isHardware() bool {
    return builtin.cpu.arch == .arm and builtin.os.tag == .freestanding;
}

/// Returns true if running in simulator/test mode
pub fn isSimulator() bool {
    return !isHardware();
}

// ============================================================
// Version Information
// ============================================================

pub const version = struct {
    pub const major: u8 = 0;
    pub const minor: u8 = 1;
    pub const patch: u8 = 0;
    pub const string: []const u8 = "0.1.0";
    pub const name: []const u8 = "ZigPod OS";
    pub const codename: []const u8 = "Genesis";
};

// ============================================================
// Tests
// ============================================================

test {
    // Import all modules to run their tests
    std.testing.refAllDecls(@This());
}
