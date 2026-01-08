//! ATA/IDE Storage Driver
//!
//! This module handles the ATA/IDE interface for hard drive access.

const std = @import("std");
const hal = @import("../../hal/hal.zig");

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
    try hal.current_hal.ata_init();
    device_info = try hal.current_hal.ata_identify();
    initialized = true;
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

/// Read sectors from disk
pub fn readSectors(lba: u64, count: u16, buffer: []u8) hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;

    if (device_info) |info| {
        if (lba + count > info.total_sectors) {
            return hal.HalError.InvalidParameter;
        }
        const required_size = @as(usize, count) * info.sector_size;
        if (buffer.len < required_size) {
            return hal.HalError.InvalidParameter;
        }
    }

    return hal.current_hal.ata_read_sectors(lba, count, buffer);
}

/// Write sectors to disk
pub fn writeSectors(lba: u64, count: u16, data: []const u8) hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;

    if (device_info) |info| {
        if (lba + count > info.total_sectors) {
            return hal.HalError.InvalidParameter;
        }
        const required_size = @as(usize, count) * info.sector_size;
        if (data.len < required_size) {
            return hal.HalError.InvalidParameter;
        }
    }

    return hal.current_hal.ata_write_sectors(lba, count, data);
}

/// Flush write cache
pub fn flush() hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;
    return hal.current_hal.ata_flush();
}

/// Put drive in standby mode (spin down)
pub fn standby() hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;
    return hal.current_hal.ata_standby();
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
