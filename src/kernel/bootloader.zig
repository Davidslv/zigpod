//! ZigPod Bootloader
//!
//! Provides dual-boot capability and recovery mode for safe firmware installation.
//! Supports booting ZigPod OS, original firmware, or entering recovery mode.

const std = @import("std");
const hal = @import("../hal/hal.zig");

// ============================================================
// Bootloader Constants
// ============================================================

/// Bootloader version
pub const VERSION = "1.0.0";

/// Magic number to identify ZigPod firmware
pub const ZIGPOD_MAGIC: u32 = 0x5A504F44; // "ZPOD"

/// Boot configuration stored in SRAM
pub const BOOT_CONFIG_ADDR: u32 = 0x40000000;

/// Original firmware location
pub const ORIG_FW_ADDR: u32 = 0x40010000;

/// ZigPod firmware location
pub const ZIGPOD_FW_ADDR: u32 = 0x40100000;

/// Recovery mode timeout (seconds)
pub const RECOVERY_TIMEOUT_SEC: u32 = 5;

// ============================================================
// Boot Mode
// ============================================================

pub const BootMode = enum(u8) {
    zigpod = 0, // Boot ZigPod OS (default)
    original = 1, // Boot original Apple firmware
    recovery = 2, // Enter recovery mode
    dfu = 3, // Device Firmware Upgrade mode
};

pub const BootReason = enum(u8) {
    normal = 0, // Normal power on
    watchdog = 1, // Watchdog reset
    user_request = 2, // User held button
    recovery_flag = 3, // Recovery flag set
    update = 4, // Firmware update pending
};

// ============================================================
// Boot Configuration
// ============================================================

pub const BootConfig = extern struct {
    magic: u32 = ZIGPOD_MAGIC,
    version: u32 = 1,
    default_mode: BootMode = .zigpod,
    last_boot_mode: BootMode = .zigpod,
    boot_count: u32 = 0,
    last_boot_reason: BootReason = .normal,
    flags: BootFlags = .{},
    checksum: u32 = 0,

    pub const BootFlags = packed struct {
        recovery_requested: bool = false,
        update_pending: bool = false,
        safe_mode: bool = false,
        first_boot: bool = true,
        _reserved: u28 = 0,
    };

    /// Calculate checksum for config validation
    pub fn calculateChecksum(self: *const BootConfig) u32 {
        const bytes = std.mem.asBytes(self);
        var sum: u32 = 0;
        // Exclude checksum field from calculation
        for (bytes[0 .. bytes.len - 4]) |b| {
            sum +%= b;
        }
        return sum ^ 0xDEADBEEF;
    }

    /// Validate configuration
    pub fn isValid(self: *const BootConfig) bool {
        return self.magic == ZIGPOD_MAGIC and
            self.checksum == self.calculateChecksum();
    }

    /// Update checksum before saving
    pub fn updateChecksum(self: *BootConfig) void {
        self.checksum = self.calculateChecksum();
    }
};

// ============================================================
// Firmware Header
// ============================================================

pub const FirmwareHeader = extern struct {
    magic: u32 = ZIGPOD_MAGIC,
    version_major: u8 = 0,
    version_minor: u8 = 1,
    version_patch: u8 = 0,
    _reserved: u8 = 0,
    size: u32 = 0,
    entry_point: u32 = 0,
    load_address: u32 = 0,
    checksum: u32 = 0,
    build_timestamp: u32 = 0,
    name: [32]u8 = [_]u8{0} ** 32,

    /// Check if header is valid
    pub fn isValid(self: *const FirmwareHeader) bool {
        return self.magic == ZIGPOD_MAGIC and
            self.size > 0 and
            self.entry_point >= self.load_address;
    }

    /// Get version string
    pub fn getVersion(self: *const FirmwareHeader, buffer: []u8) []u8 {
        return std.fmt.bufPrint(buffer, "{d}.{d}.{d}", .{
            self.version_major,
            self.version_minor,
            self.version_patch,
        }) catch buffer[0..0];
    }
};

// ============================================================
// Bootloader State
// ============================================================

var boot_config: BootConfig = .{};
var selected_mode: BootMode = .zigpod;
var boot_reason: BootReason = .normal;

// ============================================================
// Bootloader Functions
// ============================================================

/// Initialize the bootloader
pub fn init() void {
    // Load saved configuration
    loadConfig();

    // Determine boot reason
    boot_reason = detectBootReason();

    // Check for user boot mode selection
    selected_mode = detectUserSelection();

    // Handle recovery flag
    if (boot_config.flags.recovery_requested) {
        selected_mode = .recovery;
        boot_config.flags.recovery_requested = false;
        saveConfig();
    }

    // Increment boot count
    boot_config.boot_count +%= 1;
    boot_config.last_boot_reason = boot_reason;
}

/// Load configuration from persistent storage
fn loadConfig() void {
    // In real implementation, read from SRAM/flash
    // For now, use defaults if invalid
    if (!boot_config.isValid()) {
        boot_config = BootConfig{};
        boot_config.updateChecksum();
    }
}

/// Save configuration to persistent storage
fn saveConfig() void {
    boot_config.updateChecksum();
    // In real implementation, write to SRAM/flash
}

/// Detect reason for boot
fn detectBootReason() BootReason {
    // Check watchdog reset flag
    // In real implementation, read from hardware register

    // Check for recovery flag
    if (boot_config.flags.recovery_requested) {
        return .recovery_flag;
    }

    // Check for update pending
    if (boot_config.flags.update_pending) {
        return .update;
    }

    return .normal;
}

/// Detect user boot mode selection (held buttons at boot)
fn detectUserSelection() BootMode {
    const buttons = hal.clickwheelReadButtons();

    // Menu + Select = Recovery mode
    if ((buttons & 0x11) == 0x11) {
        return .recovery;
    }

    // Menu held = Original firmware
    if ((buttons & 0x01) != 0) {
        return .original;
    }

    // Play held = DFU mode
    if ((buttons & 0x02) != 0) {
        return .dfu;
    }

    // Default to configured mode
    return boot_config.default_mode;
}

/// Boot the selected firmware
pub fn boot() noreturn {
    boot_config.last_boot_mode = selected_mode;
    saveConfig();

    switch (selected_mode) {
        .zigpod => bootZigPod(),
        .original => bootOriginal(),
        .recovery => enterRecovery(),
        .dfu => enterDfu(),
    }
}

/// Boot ZigPod OS
fn bootZigPod() noreturn {
    // Verify firmware header
    const header: *const FirmwareHeader = @ptrFromInt(ZIGPOD_FW_ADDR);

    if (!header.isValid()) {
        // Fallback to original firmware
        bootOriginal();
    }

    // Jump to entry point
    const entry: *const fn () noreturn = @ptrFromInt(header.entry_point);
    entry();
}

/// Boot original Apple firmware
fn bootOriginal() noreturn {
    // Jump to original firmware
    const entry: *const fn () noreturn = @ptrFromInt(ORIG_FW_ADDR);
    entry();
}

/// Enter recovery mode
fn enterRecovery() noreturn {
    // Display recovery menu
    // Options:
    // 1. Boot ZigPod
    // 2. Boot Original
    // 3. Enter DFU
    // 4. Factory Reset

    // For now, just halt
    while (true) {
        hal.sleep();
    }
}

/// Enter DFU (Device Firmware Upgrade) mode
fn enterDfu() noreturn {
    // Enable USB and wait for host connection
    // This would implement USB DFU protocol

    while (true) {
        hal.sleep();
    }
}

// ============================================================
// Boot Selection API
// ============================================================

/// Set default boot mode
pub fn setDefaultMode(mode: BootMode) void {
    boot_config.default_mode = mode;
    saveConfig();
}

/// Get default boot mode
pub fn getDefaultMode() BootMode {
    return boot_config.default_mode;
}

/// Request recovery mode on next boot
pub fn requestRecovery() void {
    boot_config.flags.recovery_requested = true;
    saveConfig();
}

/// Get current boot mode
pub fn getCurrentMode() BootMode {
    return selected_mode;
}

/// Get boot reason
pub fn getBootReason() BootReason {
    return boot_reason;
}

/// Get boot count
pub fn getBootCount() u32 {
    return boot_config.boot_count;
}

// ============================================================
// Firmware Management
// ============================================================

/// Check if ZigPod firmware is installed
pub fn isZigPodInstalled() bool {
    const header: *const FirmwareHeader = @ptrFromInt(ZIGPOD_FW_ADDR);
    return header.isValid();
}

/// Get ZigPod firmware info
pub fn getZigPodInfo() ?FirmwareHeader {
    const header: *const FirmwareHeader = @ptrFromInt(ZIGPOD_FW_ADDR);
    if (header.isValid()) {
        return header.*;
    }
    return null;
}

/// Mark firmware update as pending
pub fn markUpdatePending() void {
    boot_config.flags.update_pending = true;
    saveConfig();
}

/// Clear update pending flag
pub fn clearUpdatePending() void {
    boot_config.flags.update_pending = false;
    saveConfig();
}

// ============================================================
// Safe Mode
// ============================================================

/// Enable safe mode (minimal drivers)
pub fn enableSafeMode() void {
    boot_config.flags.safe_mode = true;
    saveConfig();
}

/// Disable safe mode
pub fn disableSafeMode() void {
    boot_config.flags.safe_mode = false;
    saveConfig();
}

/// Check if safe mode is enabled
pub fn isSafeMode() bool {
    return boot_config.flags.safe_mode;
}

// ============================================================
// Tests
// ============================================================

test "boot config checksum" {
    var config = BootConfig{};
    config.updateChecksum();
    try std.testing.expect(config.isValid());

    // Corrupt data
    config.boot_count = 999;
    try std.testing.expect(!config.isValid());

    // Fix checksum
    config.updateChecksum();
    try std.testing.expect(config.isValid());
}

test "boot config defaults" {
    const config = BootConfig{};
    try std.testing.expectEqual(ZIGPOD_MAGIC, config.magic);
    try std.testing.expectEqual(BootMode.zigpod, config.default_mode);
    try std.testing.expect(config.flags.first_boot);
}

test "firmware header version" {
    var header = FirmwareHeader{
        .version_major = 1,
        .version_minor = 2,
        .version_patch = 3,
    };

    var buf: [16]u8 = undefined;
    const version = header.getVersion(&buf);
    try std.testing.expectEqualStrings("1.2.3", version);
}

test "firmware header validation" {
    var header = FirmwareHeader{
        .size = 1024,
        .entry_point = 0x40100100,
        .load_address = 0x40100000,
    };
    try std.testing.expect(header.isValid());

    // Invalid: size is 0
    header.size = 0;
    try std.testing.expect(!header.isValid());
}
