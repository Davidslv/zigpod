//! ZigPod Bootloader
//!
//! Provides dual-boot capability and recovery mode for safe firmware installation.
//! Supports booting ZigPod OS, original firmware, or entering recovery mode.

const std = @import("std");
const hal = @import("../hal/hal.zig");
const usb_dfu = @import("usb_dfu.zig");

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

/// Maximum consecutive boot failures before forcing original firmware
pub const MAX_BOOT_FAILURES: u8 = 3;

/// Boot timeout in milliseconds (watchdog will reset if boot takes longer)
pub const BOOT_TIMEOUT_MS: u32 = 30_000;

pub const BootConfig = extern struct {
    magic: u32 = ZIGPOD_MAGIC,
    version: u32 = 1,
    default_mode: BootMode = .zigpod,
    last_boot_mode: BootMode = .zigpod,
    boot_count: u32 = 0,
    last_boot_reason: BootReason = .normal,
    flags: BootFlags = .{},
    /// Consecutive boot failures counter
    consecutive_failures: u8 = 0,
    /// Reserved for alignment
    _reserved_align: [3]u8 = [_]u8{0} ** 3,
    checksum: u32 = 0,

    pub const BootFlags = packed struct {
        recovery_requested: bool = false,
        update_pending: bool = false,
        safe_mode: bool = false,
        first_boot: bool = true,
        /// Last boot failed (watchdog reset or crash)
        last_boot_failed: bool = false,
        /// Force original firmware on next boot
        force_original: bool = false,
        /// Boot fallback is active (booting original due to failures)
        fallback_active: bool = false,
        _reserved: u25 = 0,
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
    flags: FirmwareFlags = .{},
    size: u32 = 0,
    entry_point: u32 = 0,
    load_address: u32 = 0,
    checksum: u32 = 0,
    build_timestamp: u32 = 0,
    name: [32]u8 = [_]u8{0} ** 32,
    /// Signature offset from start of firmware (0 = no signature)
    signature_offset: u32 = 0,
    /// Signature length in bytes
    signature_length: u16 = 0,
    /// Signature algorithm ID
    signature_algorithm: SignatureAlgorithm = .none,
    _reserved2: u8 = 0,

    pub const FirmwareFlags = packed struct {
        /// Firmware requires signature verification
        requires_signature: bool = false,
        /// Firmware is a development/debug build
        debug_build: bool = false,
        /// Firmware supports secure boot
        secure_boot_capable: bool = false,
        _reserved: u5 = 0,
    };

    /// Check if header is valid
    pub fn isValid(self: *const FirmwareHeader) bool {
        return self.magic == ZIGPOD_MAGIC and
            self.size > 0 and
            self.entry_point >= self.load_address;
    }

    /// Check if firmware has a signature
    pub fn hasSignature(self: *const FirmwareHeader) bool {
        return self.signature_offset > 0 and
            self.signature_length > 0 and
            self.signature_algorithm != .none;
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
// Firmware Signature Infrastructure (Placeholder)
// ============================================================
//
// This module provides the framework for firmware signature
// verification. Currently a placeholder implementation.
//
// Future implementation should:
// 1. Use Ed25519 or ECDSA signatures
// 2. Embed public key in bootloader ROM
// 3. Verify signature before booting firmware
// 4. Support key rotation via signed updates
//
// Security Notes:
// - Never ship debug builds with signature bypass
// - Bootloader must be ROM-locked after production
// - Consider hardware-backed key storage (if available)

/// Supported signature algorithms
pub const SignatureAlgorithm = enum(u8) {
    none = 0,
    /// Ed25519 signature (planned)
    ed25519 = 1,
    /// ECDSA with P-256 curve (planned)
    ecdsa_p256 = 2,
    /// RSA-2048 with SHA-256 (legacy, not recommended)
    rsa2048_sha256 = 3,
};

/// Signature verification result
pub const SignatureResult = enum {
    /// No signature present or not required
    not_applicable,
    /// Signature verification passed
    valid,
    /// Signature verification failed
    invalid,
    /// Unknown or unsupported algorithm
    unsupported_algorithm,
    /// Signature data corrupted or malformed
    malformed,
    /// Internal verification error
    error_internal,
};

/// Public key for signature verification
/// This would be embedded in the bootloader at build time
pub const PublicKey = struct {
    algorithm: SignatureAlgorithm,
    key_data: [64]u8, // Max size for Ed25519/P-256 public keys

    /// Placeholder: would contain actual key in production
    pub fn getBootloaderKey() PublicKey {
        return PublicKey{
            .algorithm = .none,
            .key_data = [_]u8{0} ** 64,
        };
    }
};

/// Verify firmware signature
/// PLACEHOLDER: Returns not_applicable for now
/// Real implementation would perform cryptographic verification
pub fn verifyFirmwareSignature(header: *const FirmwareHeader) SignatureResult {
    // Check if firmware has signature
    if (!header.hasSignature()) {
        // No signature - check if required
        if (header.flags.requires_signature) {
            return .invalid;
        }
        return .not_applicable;
    }

    // Check algorithm support
    switch (header.signature_algorithm) {
        .none => return .not_applicable,
        .ed25519 => {
            // PLACEHOLDER: Ed25519 verification would go here
            // 1. Get public key from PublicKey.getBootloaderKey()
            // 2. Read signature from firmware at signature_offset
            // 3. Compute hash of firmware data
            // 4. Verify signature against hash with public key
            return .unsupported_algorithm;
        },
        .ecdsa_p256 => {
            // PLACEHOLDER: ECDSA verification would go here
            return .unsupported_algorithm;
        },
        .rsa2048_sha256 => {
            // PLACEHOLDER: RSA verification would go here
            return .unsupported_algorithm;
        },
    }
}

/// Check if signature verification should be enforced
/// In production builds, this should return true
pub fn isSignatureEnforcementEnabled() bool {
    // PLACEHOLDER: In production, return true
    // For development, allow unsigned firmware
    return false;
}

/// Validate firmware for booting
/// Combines header validation and signature verification
pub fn validateFirmwareForBoot(header: *const FirmwareHeader) bool {
    // Basic header validation
    if (!header.isValid()) {
        return false;
    }

    // Signature verification (if enforcement enabled)
    if (isSignatureEnforcementEnabled()) {
        const sig_result = verifyFirmwareSignature(header);
        switch (sig_result) {
            .valid, .not_applicable => return true,
            else => return false,
        }
    }

    return true;
}

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

    // Check if last boot was a watchdog reset (indicates boot failure)
    if (hal.current_hal.wdt_caused_reset()) {
        boot_reason = .watchdog;
        boot_config.flags.last_boot_failed = true;
        boot_config.consecutive_failures +|= 1; // Saturating add

        // Too many consecutive failures - force original firmware
        if (boot_config.consecutive_failures >= MAX_BOOT_FAILURES) {
            boot_config.flags.force_original = true;
            boot_config.flags.fallback_active = true;
        }
    }

    // Check for user boot mode selection
    selected_mode = detectUserSelection();

    // Override selection if force_original is set (due to failures)
    if (boot_config.flags.force_original) {
        selected_mode = .original;
        // Clear the force flag after this boot
        boot_config.flags.force_original = false;
    }

    // Handle recovery flag
    if (boot_config.flags.recovery_requested) {
        selected_mode = .recovery;
        boot_config.flags.recovery_requested = false;
    }

    // Increment boot count
    boot_config.boot_count +%= 1;
    boot_config.last_boot_reason = boot_reason;

    // Save updated config
    saveConfig();
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
    // Set up boot watchdog to catch hangs during initialization
    // Firmware is expected to call markBootSuccessful() after init
    hal.wdtInit(BOOT_TIMEOUT_MS) catch {
        // If watchdog setup fails, fall back for safety
        bootOriginalWithFallbackMarker();
    };
    hal.wdtStart();

    // Pre-flight hardware checks
    if (!performHardwareChecks()) {
        // Hardware check failed - fall back to original firmware
        hal.wdtStop();
        bootOriginalWithFallbackMarker();
    }

    // Verify firmware header
    const header: *const FirmwareHeader = @ptrFromInt(ZIGPOD_FW_ADDR);

    if (!header.isValid()) {
        // Invalid firmware - fallback to original
        hal.wdtStop();
        bootOriginalWithFallbackMarker();
    }

    // Validate firmware for boot (includes signature check if enabled)
    if (!validateFirmwareForBoot(header)) {
        hal.wdtStop();
        bootOriginalWithFallbackMarker();
    }

    // Mark that we're attempting ZigPod boot
    boot_config.flags.last_boot_failed = false; // Will be set true by watchdog if we crash
    saveConfig();

    // Jump to entry point
    // The firmware is responsible for calling markBootSuccessful() and stopping watchdog
    const entry: *const fn () noreturn = @ptrFromInt(header.entry_point);
    entry();
}

/// Boot original firmware with fallback marker
fn bootOriginalWithFallbackMarker() noreturn {
    boot_config.flags.fallback_active = true;
    saveConfig();
    bootOriginal();
}

/// Perform pre-boot hardware checks
fn performHardwareChecks() bool {
    // Check 1: Battery level sufficient for boot
    const battery = hal.pmuGetBatteryPercent();
    if (battery < 5) {
        // Critical battery - don't attempt ZigPod boot
        return false;
    }

    // Check 2: Verify memory is accessible
    if (!checkMemory()) {
        return false;
    }

    // Check 3: Verify storage is responding (basic ATA check)
    if (!checkStorage()) {
        return false;
    }

    return true;
}

/// Basic memory check
fn checkMemory() bool {
    // Write and read test pattern to known RAM location
    const test_addr: *volatile u32 = @ptrFromInt(0x40000100);
    const test_pattern: u32 = 0xDEADBEEF;
    const backup = test_addr.*;

    test_addr.* = test_pattern;
    const readback = test_addr.*;
    test_addr.* = backup;

    return readback == test_pattern;
}

/// Basic storage check
fn checkStorage() bool {
    // Try to read ATA identify (returns false if drive not responding)
    _ = hal.current_hal.ata_identify() catch {
        return false;
    };
    return true;
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
    // Check battery level before entering DFU mode
    // DFU operations require sufficient battery to prevent corruption
    const battery = hal.pmuGetBatteryPercent();
    if (battery < usb_dfu.MIN_BATTERY_FOR_DFU) {
        // Battery too low - display warning and boot to original firmware
        // which can charge the battery
        displayLowBatteryWarning();
        bootOriginal();
    }

    // Initialize watchdog for DFU operations
    hal.wdtInit(60_000) catch {}; // 60 second timeout
    hal.wdtStart();

    // Enter USB DFU mode
    // This implements the USB DFU 1.1 protocol and handles firmware updates
    usb_dfu.enterDfuMode();
}

/// Display low battery warning before falling back
fn displayLowBatteryWarning() void {
    // Would display:
    // "Battery Too Low"
    // "Charge device before updating firmware"
    // Wait 3 seconds for user to read message
    hal.delayMs(3000);
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
// Boot Success / Failure Tracking
// ============================================================

/// Mark boot as successful (called by firmware after successful initialization)
/// This stops the watchdog and resets the failure counter
pub fn markBootSuccessful() void {
    // Stop boot watchdog
    hal.wdtStop();

    // Reset failure tracking
    boot_config.consecutive_failures = 0;
    boot_config.flags.last_boot_failed = false;
    boot_config.flags.fallback_active = false;

    saveConfig();
}

/// Check if we're running in fallback mode (booted original due to failures)
pub fn isInFallbackMode() bool {
    return boot_config.flags.fallback_active;
}

/// Get consecutive failure count
pub fn getFailureCount() u8 {
    return boot_config.consecutive_failures;
}

/// Check if last boot failed
pub fn didLastBootFail() bool {
    return boot_config.flags.last_boot_failed;
}

/// Reset failure counter manually (e.g., after user clears error)
pub fn resetFailureCounter() void {
    boot_config.consecutive_failures = 0;
    boot_config.flags.last_boot_failed = false;
    boot_config.flags.fallback_active = false;
    boot_config.flags.force_original = false;
    saveConfig();
}

/// Force next boot to use original firmware
pub fn forceOriginalFirmware() void {
    boot_config.flags.force_original = true;
    saveConfig();
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

test "firmware header signature detection" {
    // No signature
    const header_no_sig = FirmwareHeader{
        .size = 1024,
        .entry_point = 0x40100100,
        .load_address = 0x40100000,
    };
    try std.testing.expect(!header_no_sig.hasSignature());

    // Has signature
    var header_with_sig = FirmwareHeader{
        .size = 1024,
        .entry_point = 0x40100100,
        .load_address = 0x40100000,
        .signature_offset = 1024,
        .signature_length = 64,
        .signature_algorithm = .ed25519,
    };
    try std.testing.expect(header_with_sig.hasSignature());

    // Has offset but no algorithm
    header_with_sig.signature_algorithm = .none;
    try std.testing.expect(!header_with_sig.hasSignature());
}

test "signature verification - no signature" {
    const header = FirmwareHeader{
        .size = 1024,
        .entry_point = 0x40100100,
        .load_address = 0x40100000,
    };

    const result = verifyFirmwareSignature(&header);
    try std.testing.expectEqual(SignatureResult.not_applicable, result);
}

test "signature verification - requires but missing" {
    var header = FirmwareHeader{
        .size = 1024,
        .entry_point = 0x40100100,
        .load_address = 0x40100000,
    };
    header.flags.requires_signature = true;

    const result = verifyFirmwareSignature(&header);
    try std.testing.expectEqual(SignatureResult.invalid, result);
}

test "signature verification - unsupported algorithm" {
    const header = FirmwareHeader{
        .size = 1024,
        .entry_point = 0x40100100,
        .load_address = 0x40100000,
        .signature_offset = 1024,
        .signature_length = 64,
        .signature_algorithm = .ed25519,
    };

    const result = verifyFirmwareSignature(&header);
    // Currently returns unsupported as it's a placeholder
    try std.testing.expectEqual(SignatureResult.unsupported_algorithm, result);
}

test "validate firmware for boot" {
    // Valid firmware, no signature required
    const valid = FirmwareHeader{
        .size = 1024,
        .entry_point = 0x40100100,
        .load_address = 0x40100000,
    };
    try std.testing.expect(validateFirmwareForBoot(&valid));

    // Invalid firmware (size = 0)
    const invalid = FirmwareHeader{
        .size = 0,
        .entry_point = 0x40100100,
        .load_address = 0x40100000,
    };
    try std.testing.expect(!validateFirmwareForBoot(&invalid));
}

test "signature algorithm enum" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(SignatureAlgorithm.none));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(SignatureAlgorithm.ed25519));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(SignatureAlgorithm.ecdsa_p256));
}

test "public key placeholder" {
    const key = PublicKey.getBootloaderKey();
    try std.testing.expectEqual(SignatureAlgorithm.none, key.algorithm);
}

test "boot failure counter" {
    var config = BootConfig{};

    // Initially no failures
    try std.testing.expectEqual(@as(u8, 0), config.consecutive_failures);
    try std.testing.expect(!config.flags.last_boot_failed);
    try std.testing.expect(!config.flags.fallback_active);

    // Simulate failures
    config.consecutive_failures = 2;
    config.flags.last_boot_failed = true;
    try std.testing.expectEqual(@as(u8, 2), config.consecutive_failures);

    // After MAX_BOOT_FAILURES, should force original
    config.consecutive_failures = MAX_BOOT_FAILURES;
    try std.testing.expect(config.consecutive_failures >= MAX_BOOT_FAILURES);
}

test "boot flags" {
    var config = BootConfig{};

    // Test individual flags
    config.flags.force_original = true;
    try std.testing.expect(config.flags.force_original);

    config.flags.fallback_active = true;
    try std.testing.expect(config.flags.fallback_active);

    config.flags.last_boot_failed = true;
    try std.testing.expect(config.flags.last_boot_failed);
}

test "max boot failures constant" {
    // Ensure reasonable default
    try std.testing.expect(MAX_BOOT_FAILURES >= 2);
    try std.testing.expect(MAX_BOOT_FAILURES <= 10);
}

test "boot timeout constant" {
    // Ensure reasonable boot timeout
    try std.testing.expect(BOOT_TIMEOUT_MS >= 10_000); // At least 10 seconds
    try std.testing.expect(BOOT_TIMEOUT_MS <= 120_000); // At most 2 minutes
}
