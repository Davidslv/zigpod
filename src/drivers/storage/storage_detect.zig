//! Storage Type Detection
//!
//! Detects whether the iPod is using original HDD or flash-based storage
//! (iFlash, SD adapters, CompactFlash, etc.) and adjusts behavior accordingly.
//!
//! Detection Priority:
//! 1. ATA IDENTIFY word 217 (rotation_rate) - AUTHORITATIVE for SSD detection
//! 2. Model string pattern matching - for specific adapter identification
//! 3. Capacity-based inference - fallback heuristic
//!
//! Key differences between HDD and Flash:
//! - Spin-up time: HDD needs 1-3 seconds, Flash is instant
//! - Power management: HDD benefits from standby/sleep, Flash doesn't need it
//! - Head parking: HDD needs it before movement/shutdown, Flash doesn't
//! - Access latency: HDD has seek time (~8-12ms), Flash is consistent (<1ms)
//! - Power consumption: Flash generally uses less power (50-100mA vs 200-400mA)
//! - TRIM support: Flash adapters may support TRIM for wear leveling

const std = @import("std");
const hal = @import("../../hal/hal.zig");

// ============================================================
// Storage Type Detection
// ============================================================

/// Detected storage type
pub const StorageType = enum(u8) {
    /// Unknown storage type (conservative defaults)
    unknown = 0,
    /// Original spinning hard drive
    hdd = 1,
    /// iFlash adapter (SD-based)
    iflash = 2,
    /// CompactFlash adapter
    compact_flash = 3,
    /// Other SSD/flash storage
    generic_flash = 4,
    /// mSATA adapter
    msata = 5,

    /// Returns true if this is flash-based storage
    pub fn isFlash(self: StorageType) bool {
        return switch (self) {
            .unknown, .hdd => false,
            .iflash, .compact_flash, .generic_flash, .msata => true,
        };
    }

    /// Returns true if standby/sleep commands are useful
    pub fn needsPowerManagement(self: StorageType) bool {
        return self == .hdd;
    }

    /// Returns true if spin-up delay is needed
    pub fn needsSpinUpDelay(self: StorageType) bool {
        return self == .hdd or self == .unknown;
    }

    /// Get recommended read-ahead buffer size (sectors)
    pub fn getReadAheadSize(self: StorageType) u16 {
        return switch (self) {
            .hdd => 64, // Larger buffer for sequential reads (minimize seeks)
            .unknown => 32, // Conservative default
            else => 8, // Flash is fast for random access, less buffering needed
        };
    }

    /// Get recommended idle timeout before standby (ms)
    pub fn getIdleTimeout(self: StorageType) u32 {
        return switch (self) {
            .hdd => 30_000, // 30 seconds - balance power vs spin-up cost
            .unknown => 60_000, // Conservative for unknown
            else => 0, // Flash doesn't need standby timeout
        };
    }
};

/// Lightweight storage detection result (1 byte for hot path)
pub const DetectionResult = struct {
    storage_type: StorageType = .unknown,
    supports_trim: bool = false,
    rotation_rate: u16 = 1, // 0 = not reported, 1 = non-rotating (SSD), >1 = RPM
};

// ============================================================
// Thread-Safe Global State
// ============================================================

/// Detection state - uses atomic for thread safety on dual-core PP5021C
var detection_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
const STATE_UNINIT: u8 = 0;
const STATE_DETECTING: u8 = 1;
const STATE_DONE: u8 = 2;

/// Cached detection result (only valid when detection_state == STATE_DONE)
var cached_result: DetectionResult = .{};

// ============================================================
// Public API
// ============================================================

/// Initialize storage detection from pre-fetched ATA info
/// Call this from ATA driver init() to avoid duplicate ata_identify() calls
pub fn initFromAtaInfo(ata_info: hal.AtaDeviceInfo) void {
    // Use compare-and-swap to ensure single initialization
    if (detection_state.cmpxchgStrong(STATE_UNINIT, STATE_DETECTING, .acq_rel, .acquire)) |_| {
        // Another core is detecting or already done, spin-wait
        while (detection_state.load(.acquire) == STATE_DETECTING) {
            std.atomic.spinLoopHint();
        }
        return;
    }

    // We won the race - perform detection
    cached_result = detectFromAtaInfo(ata_info);
    detection_state.store(STATE_DONE, .release);
}

/// Get storage type (triggers detection if not done - DEPRECATED)
/// Prefer initFromAtaInfo() called from ATA driver to avoid duplicate HAL calls
pub fn getStorageType() StorageType {
    ensureDetected();
    return cached_result.storage_type;
}

/// Get full detection result
pub fn getDetectionResult() DetectionResult {
    ensureDetected();
    return cached_result;
}

/// Check if running on flash storage
pub fn isFlashStorage() bool {
    return getStorageType().isFlash();
}

/// Force re-detection (useful after hot-swap, if supported)
pub fn redetect() void {
    detection_state.store(STATE_UNINIT, .release);
}

// ============================================================
// Behavior Adjustment Functions
// ============================================================

/// Should we send standby command when idle?
pub fn shouldStandbyWhenIdle() bool {
    return getStorageType().needsPowerManagement();
}

/// Get spin-up delay in milliseconds (0 for flash)
pub fn getSpinUpDelayMs() u32 {
    return switch (getStorageType()) {
        .hdd => 2000, // 2 seconds for HDD spin-up
        .unknown => 1000, // 1 second conservative default
        else => 0, // Flash needs no spin-up
    };
}

/// Should we park heads before power off?
pub fn shouldParkHeads() bool {
    return getStorageType() == .hdd;
}

/// Get audio buffer size recommendation based on storage type
pub fn getRecommendedAudioBufferMs() u32 {
    return switch (getStorageType()) {
        .hdd => 2000, // 2 seconds buffer for HDD seek latency
        .unknown => 1500, // Conservative
        else => 500, // Flash is fast, smaller buffer OK
    };
}

/// Should TRIM be sent for deleted sectors?
pub fn shouldSendTrim() bool {
    ensureDetected();
    return cached_result.supports_trim and cached_result.storage_type.isFlash();
}

// ============================================================
// Detection Logic
// ============================================================

/// Ensure detection has been performed
fn ensureDetected() void {
    const state = detection_state.load(.acquire);
    if (state == STATE_DONE) return;

    if (state == STATE_UNINIT) {
        // Try to claim detection
        if (detection_state.cmpxchgStrong(STATE_UNINIT, STATE_DETECTING, .acq_rel, .acquire)) |_| {
            // Lost race, spin-wait
            while (detection_state.load(.acquire) != STATE_DONE) {
                std.atomic.spinLoopHint();
            }
            return;
        }

        // We won - perform legacy detection via HAL
        const ata_info = hal.current_hal.ata_identify() catch {
            cached_result = .{ .storage_type = .unknown };
            detection_state.store(STATE_DONE, .release);
            return;
        };
        cached_result = detectFromAtaInfo(ata_info);
        detection_state.store(STATE_DONE, .release);
    } else {
        // STATE_DETECTING - spin-wait for completion
        while (detection_state.load(.acquire) != STATE_DONE) {
            std.atomic.spinLoopHint();
        }
    }
}

/// Core detection logic from ATA IDENTIFY data
fn detectFromAtaInfo(info: hal.AtaDeviceInfo) DetectionResult {
    var result = DetectionResult{
        .rotation_rate = info.rotation_rate,
        .supports_trim = info.supports_trim,
    };

    // Priority 1: ATA IDENTIFY word 217 - AUTHORITATIVE
    // 0x0001 = Non-rotating media (SSD/Flash) - definitive!
    if (info.rotation_rate == 0x0001) {
        // Definitely flash - now determine specific type from model
        result.storage_type = detectTypeFromModel(&info.model) orelse .generic_flash;
        // Ensure we report as flash even if model detection says HDD
        if (result.storage_type == .hdd) {
            result.storage_type = .generic_flash;
        }
        return result;
    }

    // Priority 2: Model string pattern matching
    if (detectTypeFromModel(&info.model)) |detected| {
        result.storage_type = detected;
        return result;
    }

    // Priority 3: Capacity-based inference (fallback heuristic)
    const capacity_bytes = @as(u64, info.total_sectors) * info.sector_size;
    result.storage_type = inferFromCapacity(capacity_bytes);

    return result;
}

/// Optimized model detection using first-character dispatch
/// Returns null if no match found
fn detectTypeFromModel(model: *const [40]u8) ?StorageType {
    // Find actual string length (trim trailing spaces/nulls)
    var len: usize = 40;
    while (len > 0 and (model[len - 1] == ' ' or model[len - 1] == 0)) {
        len -= 1;
    }
    if (len == 0) return null;

    const first = std.ascii.toUpper(model[0]);

    return switch (first) {
        'I' => {
            // iFlash, IFLASH
            if (startsWithIgnoreCase(model[0..len], "iflash")) return .iflash;
            return null;
        },
        'T' => {
            // Tarkan (iFlash manufacturer), TOSHIBA
            if (startsWithIgnoreCase(model[0..len], "tarkan")) return .iflash;
            if (startsWithIgnoreCase(model[0..len], "toshiba")) return .hdd;
            return null;
        },
        'M' => {
            // MK (Toshiba prefix), mSATA, MSATA
            if (len >= 2 and model[0] == 'M' and model[1] == 'K') return .hdd;
            if (startsWithIgnoreCase(model[0..len], "msata")) return .msata;
            return null;
        },
        'H' => {
            // HITACHI, Hitachi, HTS (Hitachi prefix), HM (Samsung prefix)
            if (startsWithIgnoreCase(model[0..len], "hitachi")) return .hdd;
            if (len >= 3 and model[0] == 'H' and model[1] == 'T' and model[2] == 'S') return .hdd;
            if (len >= 2 and model[0] == 'H' and model[1] == 'M') return .hdd;
            return null;
        },
        'S' => {
            // SAMSUNG, Samsung, SanDisk, SANDISK
            if (startsWithIgnoreCase(model[0..len], "samsung")) return .hdd;
            if (startsWithIgnoreCase(model[0..len], "sandisk")) return .compact_flash;
            return null;
        },
        'K' => {
            // Kingston, KINGSTON
            if (startsWithIgnoreCase(model[0..len], "kingston")) return .compact_flash;
            return null;
        },
        'L' => {
            // Lexar, LEXAR
            if (startsWithIgnoreCase(model[0..len], "lexar")) return .compact_flash;
            return null;
        },
        else => null,
    };
}

/// Check if string starts with pattern (case-insensitive)
fn startsWithIgnoreCase(str: []const u8, pattern: []const u8) bool {
    if (str.len < pattern.len) return false;
    for (str[0..pattern.len], pattern) |s, p| {
        if (std.ascii.toLower(s) != std.ascii.toLower(p)) return false;
    }
    return true;
}

/// Infer storage type from capacity (fallback heuristic)
fn inferFromCapacity(capacity_bytes: u64) StorageType {
    const gb = capacity_bytes / (1024 * 1024 * 1024);

    // Large capacities (>160GB) are likely flash/SD based
    // Original iPod HDDs topped out at 160GB
    if (gb > 160) return .generic_flash;

    // Very small capacities (<20GB) might be small SD cards
    // Original iPod HDDs were minimum ~30GB
    if (gb < 20 and gb > 0) return .generic_flash;

    // Within normal HDD range - can't determine
    return .unknown;
}

// ============================================================
// Legacy Compatibility (DEPRECATED)
// ============================================================

/// Storage characteristics - DEPRECATED, use DetectionResult
pub const StorageInfo = struct {
    storage_type: StorageType = .unknown,
    model: [40]u8 = [_]u8{0} ** 40,
    serial: [20]u8 = [_]u8{0} ** 20,
    firmware: [8]u8 = [_]u8{0} ** 8,
    capacity_bytes: u64 = 0,
    is_solid_state: bool = false,
    supports_trim: bool = false,
    supports_ncq: bool = false,
    rotation_rate: u16 = 1,

    pub fn getModel(self: *const StorageInfo) []const u8 {
        return std.mem.sliceTo(&self.model, 0);
    }

    pub fn getSerial(self: *const StorageInfo) []const u8 {
        return std.mem.sliceTo(&self.serial, 0);
    }

    pub fn getFirmware(self: *const StorageInfo) []const u8 {
        return std.mem.sliceTo(&self.firmware, 0);
    }
};

/// Get storage info - DEPRECATED, use getDetectionResult()
/// This function makes an additional HAL call for full info
pub fn getStorageInfo() StorageInfo {
    const result = getDetectionResult();

    // Fetch full info from HAL (this is the slow path)
    const ata_info = hal.current_hal.ata_identify() catch {
        return StorageInfo{ .storage_type = result.storage_type };
    };

    var info = StorageInfo{
        .storage_type = result.storage_type,
        .capacity_bytes = @as(u64, ata_info.total_sectors) * ata_info.sector_size,
        .is_solid_state = result.rotation_rate == 0x0001,
        .supports_trim = result.supports_trim,
        .rotation_rate = result.rotation_rate,
    };
    @memcpy(&info.model, &ata_info.model);
    @memcpy(&info.serial, &ata_info.serial);
    @memcpy(&info.firmware, &ata_info.firmware);

    return info;
}

// ============================================================
// Debug/Info Functions
// ============================================================

/// Print storage detection info
pub fn printStorageInfo(writer: anytype) !void {
    const result = getDetectionResult();
    const info = getStorageInfo();

    try writer.print("Storage Detection Report\n", .{});
    try writer.print("========================\n", .{});
    try writer.print("Type: {s}\n", .{@tagName(result.storage_type)});
    try writer.print("Model: {s}\n", .{info.getModel()});
    try writer.print("Serial: {s}\n", .{info.getSerial()});
    try writer.print("Firmware: {s}\n", .{info.getFirmware()});
    try writer.print("Capacity: {d} GB\n", .{info.capacity_bytes / (1024 * 1024 * 1024)});
    try writer.print("Rotation Rate: {d} (0x0001=SSD)\n", .{result.rotation_rate});
    try writer.print("Is Flash: {}\n", .{result.storage_type.isFlash()});
    try writer.print("Supports TRIM: {}\n", .{result.supports_trim});
    try writer.print("Needs Standby: {}\n", .{result.storage_type.needsPowerManagement()});
    try writer.print("Spin-up Delay: {d}ms\n", .{getSpinUpDelayMs()});
    try writer.print("Audio Buffer: {d}ms\n", .{getRecommendedAudioBufferMs()});
}

// ============================================================
// Tests
// ============================================================

test "storage type properties" {
    // HDD
    try std.testing.expect(!StorageType.hdd.isFlash());
    try std.testing.expect(StorageType.hdd.needsPowerManagement());
    try std.testing.expect(StorageType.hdd.needsSpinUpDelay());

    // iFlash
    try std.testing.expect(StorageType.iflash.isFlash());
    try std.testing.expect(!StorageType.iflash.needsPowerManagement());
    try std.testing.expect(!StorageType.iflash.needsSpinUpDelay());

    // Generic flash
    try std.testing.expect(StorageType.generic_flash.isFlash());
    try std.testing.expect(!StorageType.generic_flash.needsPowerManagement());

    // Unknown (conservative)
    try std.testing.expect(!StorageType.unknown.isFlash());
    try std.testing.expect(StorageType.unknown.needsSpinUpDelay());
}

test "read ahead size" {
    // HDD needs larger read-ahead
    try std.testing.expect(StorageType.hdd.getReadAheadSize() > StorageType.iflash.getReadAheadSize());
}

test "idle timeout" {
    // HDD needs idle timeout, flash doesn't
    try std.testing.expect(StorageType.hdd.getIdleTimeout() > 0);
    try std.testing.expectEqual(@as(u32, 0), StorageType.iflash.getIdleTimeout());
}

test "startsWithIgnoreCase" {
    try std.testing.expect(startsWithIgnoreCase("iFlash-Solo", "iflash"));
    try std.testing.expect(startsWithIgnoreCase("IFLASH-QUAD", "iflash"));
    try std.testing.expect(startsWithIgnoreCase("TOSHIBA MK3008GAL", "toshiba"));
    try std.testing.expect(!startsWithIgnoreCase("TOSHIBA", "iflash"));
    try std.testing.expect(!startsWithIgnoreCase("AB", "ABC"));
}

test "model detection - iflash" {
    var model: [40]u8 = [_]u8{' '} ** 40;
    const name = "iFlash-Solo v3";
    @memcpy(model[0..name.len], name);

    const detected = detectTypeFromModel(&model);
    try std.testing.expectEqual(StorageType.iflash, detected.?);
}

test "model detection - tarkan" {
    var model: [40]u8 = [_]u8{' '} ** 40;
    const name = "Tarkan iFlash";
    @memcpy(model[0..name.len], name);

    const detected = detectTypeFromModel(&model);
    try std.testing.expectEqual(StorageType.iflash, detected.?);
}

test "model detection - hdd" {
    var model: [40]u8 = [_]u8{' '} ** 40;
    const name = "TOSHIBA MK3008GAL";
    @memcpy(model[0..name.len], name);

    const detected = detectTypeFromModel(&model);
    try std.testing.expectEqual(StorageType.hdd, detected.?);
}

test "model detection - mk prefix" {
    var model: [40]u8 = [_]u8{' '} ** 40;
    const name = "MK6008GAH";
    @memcpy(model[0..name.len], name);

    const detected = detectTypeFromModel(&model);
    try std.testing.expectEqual(StorageType.hdd, detected.?);
}

test "model detection - cf" {
    var model: [40]u8 = [_]u8{' '} ** 40;
    const name = "SanDisk Extreme Pro";
    @memcpy(model[0..name.len], name);

    const detected = detectTypeFromModel(&model);
    try std.testing.expectEqual(StorageType.compact_flash, detected.?);
}

test "rotation rate SSD detection" {
    const info = hal.AtaDeviceInfo{
        .model = [_]u8{' '} ** 40,
        .serial = [_]u8{' '} ** 20,
        .firmware = [_]u8{' '} ** 8,
        .total_sectors = 100000,
        .sector_size = 512,
        .supports_lba48 = true,
        .supports_dma = true,
        .rotation_rate = 0x0001, // Non-rotating = SSD
        .supports_trim = true,
    };

    const result = detectFromAtaInfo(info);
    try std.testing.expect(result.storage_type.isFlash());
    try std.testing.expect(result.supports_trim);
}

test "rotation rate HDD detection" {
    // Initialize model with TOSHIBA prefix
    var model: [40]u8 = [_]u8{' '} ** 40;
    const name = "TOSHIBA MK3008GAL";
    @memcpy(model[0..name.len], name);

    const info = hal.AtaDeviceInfo{
        .model = model,
        .serial = [_]u8{' '} ** 20,
        .firmware = [_]u8{' '} ** 8,
        .total_sectors = 100000,
        .sector_size = 512,
        .supports_lba48 = true,
        .supports_dma = true,
        .rotation_rate = 4200, // 4200 RPM = definitely HDD
        .supports_trim = false,
    };

    const result = detectFromAtaInfo(info);
    try std.testing.expectEqual(StorageType.hdd, result.storage_type);
    try std.testing.expect(!result.supports_trim);
}

test "capacity inference - large" {
    // >160GB should be detected as flash
    const large_capacity: u64 = 256 * 1024 * 1024 * 1024; // 256GB
    const detected = inferFromCapacity(large_capacity);
    try std.testing.expectEqual(StorageType.generic_flash, detected);
}

test "capacity inference - small" {
    // <20GB should be detected as flash (small SD card)
    const small_capacity: u64 = 8 * 1024 * 1024 * 1024; // 8GB
    const detected = inferFromCapacity(small_capacity);
    try std.testing.expectEqual(StorageType.generic_flash, detected);
}

test "capacity inference - normal" {
    // 30-160GB is ambiguous (could be HDD)
    const normal_capacity: u64 = 80 * 1024 * 1024 * 1024; // 80GB
    const detected = inferFromCapacity(normal_capacity);
    try std.testing.expectEqual(StorageType.unknown, detected);
}
