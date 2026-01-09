//! ATA/IDE Storage Driver
//!
//! This module handles the ATA/IDE interface for hard drive access.

const std = @import("std");
const hal = @import("../../hal/hal.zig");
const storage_detect = @import("storage_detect.zig");

// Logging - see docs/LOGGING_GUIDE.md for usage
const log = @import("../../debug/logger.zig").scoped(.storage);
const telemetry = @import("../../debug/telemetry.zig");

// ============================================================
// ATA Constants
// ============================================================

pub const SECTOR_SIZE: usize = 512;
pub const MAX_SECTORS_PER_TRANSFER: u16 = 256;

// ============================================================
// ATA Driver State
// ============================================================

var device_info: ?hal.AtaDeviceInfo = null;
var initialized: bool = false;

/// Initialize the ATA driver
pub fn init() hal.HalError!void {
    log.info("Initializing ATA driver", .{});
    telemetry.record(.ata_init, 0, 0);

    try hal.current_hal.ata_init();
    device_info = try hal.current_hal.ata_identify();
    initialized = true;

    if (device_info) |info| {
        const capacity_gb = (info.total_sectors * info.sector_size) / (1024 * 1024 * 1024);
        log.info("ATA device: {d}GB, {d} sectors", .{ capacity_gb, info.total_sectors });

        // Initialize storage detection from the ATA info we already have
        // This avoids a duplicate ata_identify() call
        storage_detect.initFromAtaInfo(info);

        // Log detection results
        const result = storage_detect.getDetectionResult();
        log.info("Storage: {s}, flash={}, rotation={d}, trim={}, delay={d}ms", .{
            @tagName(result.storage_type),
            result.storage_type.isFlash(),
            result.rotation_rate,
            result.supports_trim,
            storage_detect.getSpinUpDelayMs(),
        });
    }
}

/// Check if driver is initialized
pub fn isInitialized() bool {
    return initialized;
}

/// Get device information
pub fn getDeviceInfo() ?hal.AtaDeviceInfo {
    return device_info;
}

/// Get total capacity in bytes
pub fn getCapacity() u64 {
    if (device_info) |info| {
        return info.total_sectors * info.sector_size;
    }
    return 0;
}

// Statistics for diagnostics
var total_reads: u64 = 0;
var total_writes: u64 = 0;
var read_errors: u32 = 0;
var write_errors: u32 = 0;

/// Read sectors from disk
pub fn readSectors(lba: u64, count: u16, buffer: []u8) hal.HalError!void {
    if (!initialized) {
        log.err("Read failed - ATA not initialized", .{});
        return hal.HalError.DeviceNotReady;
    }

    if (device_info) |info| {
        if (lba + count > info.total_sectors) {
            log.err("Read out of bounds: LBA {d} + {d} > {d}", .{ lba, count, info.total_sectors });
            return hal.HalError.InvalidParameter;
        }
        const required_size = @as(usize, count) * info.sector_size;
        if (buffer.len < required_size) {
            log.err("Buffer too small: {d} < {d}", .{ buffer.len, required_size });
            return hal.HalError.InvalidParameter;
        }
    }

    log.trace("Reading {d} sectors at LBA {d}", .{ count, lba });
    telemetry.record(.ata_read, count, @truncate(lba));

    hal.current_hal.ata_read_sectors(lba, count, buffer) catch |err| {
        read_errors += 1;
        log.err("Read failed at LBA {d}: {s} (errors={d})", .{ lba, @errorName(err), read_errors });
        telemetry.record(.ata_error, @truncate(read_errors), @truncate(lba));
        return err;
    };

    total_reads += count;
}

/// Write sectors to disk
pub fn writeSectors(lba: u64, count: u16, data: []const u8) hal.HalError!void {
    if (!initialized) {
        log.err("Write failed - ATA not initialized", .{});
        return hal.HalError.DeviceNotReady;
    }

    if (device_info) |info| {
        if (lba + count > info.total_sectors) {
            log.err("Write out of bounds: LBA {d} + {d} > {d}", .{ lba, count, info.total_sectors });
            return hal.HalError.InvalidParameter;
        }
        const required_size = @as(usize, count) * info.sector_size;
        if (data.len < required_size) {
            log.err("Data too small: {d} < {d}", .{ data.len, required_size });
            return hal.HalError.InvalidParameter;
        }
    }

    log.trace("Writing {d} sectors at LBA {d}", .{ count, lba });
    telemetry.record(.ata_write, count, @truncate(lba));

    hal.current_hal.ata_write_sectors(lba, count, data) catch |err| {
        write_errors += 1;
        log.err("Write failed at LBA {d}: {s} (errors={d})", .{ lba, @errorName(err), write_errors });
        telemetry.record(.ata_error, @truncate(write_errors), @truncate(lba));
        return err;
    };

    total_writes += count;
}

/// Flush write cache
pub fn flush() hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;
    log.debug("Flushing write cache", .{});
    return hal.current_hal.ata_flush();
}

/// Put drive in standby mode (spin down)
/// Note: This is a no-op for flash storage (iFlash, SD adapters, etc.)
pub fn standby() hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;

    // Skip standby for flash storage - it doesn't need it and may not support the command
    if (!storage_detect.shouldStandbyWhenIdle()) {
        log.debug("Standby skipped (flash storage)", .{});
        return;
    }

    log.info("Spinning down drive", .{});
    return hal.current_hal.ata_standby();
}

/// Get ATA statistics for diagnostics
pub const Stats = struct {
    total_reads: u64,
    total_writes: u64,
    read_errors: u32,
    write_errors: u32,
};

pub fn getStats() Stats {
    return .{
        .total_reads = total_reads,
        .total_writes = total_writes,
        .read_errors = read_errors,
        .write_errors = write_errors,
    };
}

/// Reset error counters
pub fn resetErrorCounters() void {
    read_errors = 0;
    write_errors = 0;
    log.debug("ATA error counters reset", .{});
}

/// Read a single sector
pub fn readSector(lba: u64, buffer: *[SECTOR_SIZE]u8) hal.HalError!void {
    return readSectors(lba, 1, buffer);
}

/// Write a single sector
pub fn writeSector(lba: u64, data: *const [SECTOR_SIZE]u8) hal.HalError!void {
    return writeSectors(lba, 1, data);
}

// ============================================================
// Block Device Interface
// ============================================================

pub const BlockDevice = struct {
    sector_size: usize,
    sector_count: u64,

    pub fn read(self: BlockDevice, lba: u64, buffer: []u8) hal.HalError!void {
        _ = self;
        const count: u16 = @intCast(buffer.len / SECTOR_SIZE);
        return readSectors(lba, count, buffer);
    }

    pub fn write(self: BlockDevice, lba: u64, data: []const u8) hal.HalError!void {
        _ = self;
        const count: u16 = @intCast(data.len / SECTOR_SIZE);
        return writeSectors(lba, count, data);
    }
};

/// Get block device interface
pub fn getBlockDevice() ?BlockDevice {
    if (device_info) |info| {
        return BlockDevice{
            .sector_size = info.sector_size,
            .sector_count = info.total_sectors,
        };
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

test "ATA constants" {
    try std.testing.expectEqual(@as(usize, 512), SECTOR_SIZE);
    try std.testing.expectEqual(@as(u16, 256), MAX_SECTORS_PER_TRANSFER);
}
