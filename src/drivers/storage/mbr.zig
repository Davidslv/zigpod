//! Master Boot Record (MBR) Partition Table Parser
//!
//! This module parses the MBR partition table to find partitions on the disk.
//! The iPod uses a standard MBR layout with:
//! - Partition 1: Firmware partition (type 0x00 - appears empty but contains Apple firmware)
//! - Partition 2: FAT32 data partition (type 0x0B or 0x0C)
//!
//! The MBR is located at LBA 0 (first sector of the disk) and contains:
//! - 446 bytes: Bootstrap code
//! - 64 bytes: Partition table (4 entries × 16 bytes)
//! - 2 bytes: Boot signature (0x55AA)

const std = @import("std");
const hal = @import("../../hal/hal.zig");
const ata = @import("ata.zig");

// ============================================================
// MBR Constants
// ============================================================

/// MBR sector location
pub const MBR_LBA: u64 = 0;

/// Partition table offset within MBR
pub const PARTITION_TABLE_OFFSET: usize = 0x1BE;

/// Boot signature bytes
pub const BOOT_SIGNATURE: u16 = 0xAA55;

/// Number of partition entries in MBR
pub const NUM_PARTITIONS: usize = 4;

// ============================================================
// Partition Types
// ============================================================

pub const PartitionType = enum(u8) {
    empty = 0x00,
    fat12 = 0x01,
    fat16_small = 0x04,
    extended = 0x05,
    fat16 = 0x06,
    ntfs = 0x07,
    fat32 = 0x0B,
    fat32_lba = 0x0C,
    fat16_lba = 0x0E,
    extended_lba = 0x0F,
    linux_swap = 0x82,
    linux = 0x83,
    linux_extended = 0x85,
    linux_lvm = 0x8E,
    hfs = 0xAF, // Apple HFS/HFS+
    _,

    pub fn isFat32(self: PartitionType) bool {
        return self == .fat32 or self == .fat32_lba;
    }

    pub fn isFat(self: PartitionType) bool {
        return self == .fat12 or
            self == .fat16_small or
            self == .fat16 or
            self == .fat16_lba or
            self.isFat32();
    }

    pub fn getName(self: PartitionType) []const u8 {
        return switch (self) {
            .empty => "Empty",
            .fat12 => "FAT12",
            .fat16_small => "FAT16 <32MB",
            .extended => "Extended",
            .fat16 => "FAT16",
            .ntfs => "NTFS/HPFS",
            .fat32 => "FAT32",
            .fat32_lba => "FAT32 LBA",
            .fat16_lba => "FAT16 LBA",
            .extended_lba => "Extended LBA",
            .linux_swap => "Linux Swap",
            .linux => "Linux",
            .linux_extended => "Linux Extended",
            .linux_lvm => "Linux LVM",
            .hfs => "Apple HFS",
            _ => "Unknown",
        };
    }
};

// ============================================================
// MBR Structures
// ============================================================

/// MBR Partition Entry (16 bytes)
pub const PartitionEntry = extern struct {
    /// Boot indicator (0x80 = bootable, 0x00 = not bootable)
    boot_flag: u8,

    /// Starting CHS address (legacy, usually ignored)
    start_head: u8,
    start_sector_cylinder: u16 align(1),

    /// Partition type
    partition_type: PartitionType,

    /// Ending CHS address (legacy, usually ignored)
    end_head: u8,
    end_sector_cylinder: u16 align(1),

    /// Starting LBA (most important field)
    lba_start: u32 align(1),

    /// Partition size in sectors
    sector_count: u32 align(1),

    /// Check if partition entry is valid/used
    pub fn isValid(self: PartitionEntry) bool {
        return self.partition_type != .empty and self.sector_count > 0;
    }

    /// Check if partition is bootable
    pub fn isBootable(self: PartitionEntry) bool {
        return self.boot_flag == 0x80;
    }

    /// Get partition size in bytes
    pub fn getSizeBytes(self: PartitionEntry) u64 {
        return @as(u64, self.sector_count) * 512;
    }

    /// Get partition size in MB
    pub fn getSizeMB(self: PartitionEntry) u32 {
        return @intCast(self.getSizeBytes() / (1024 * 1024));
    }

    /// Get partition end LBA
    pub fn getLbaEnd(self: PartitionEntry) u64 {
        return @as(u64, self.lba_start) + self.sector_count - 1;
    }
};

/// Complete MBR structure
pub const Mbr = extern struct {
    /// Bootstrap code
    bootstrap: [446]u8,

    /// Partition table
    partitions: [4]PartitionEntry,

    /// Boot signature (should be 0xAA55)
    signature: u16 align(1),

    /// Check if MBR has valid signature
    pub fn isValid(self: *const Mbr) bool {
        return self.signature == BOOT_SIGNATURE;
    }

    /// Find first partition of given type
    pub fn findPartition(self: *const Mbr, ptype: PartitionType) ?*const PartitionEntry {
        for (&self.partitions) |*entry| {
            if (entry.partition_type == ptype and entry.isValid()) {
                return entry;
            }
        }
        return null;
    }

    /// Find first FAT32 partition
    pub fn findFat32Partition(self: *const Mbr) ?*const PartitionEntry {
        for (&self.partitions) |*entry| {
            if (entry.partition_type.isFat32() and entry.isValid()) {
                return entry;
            }
        }
        return null;
    }

    /// Find first FAT partition (any type)
    pub fn findFatPartition(self: *const Mbr) ?*const PartitionEntry {
        for (&self.partitions) |*entry| {
            if (entry.partition_type.isFat() and entry.isValid()) {
                return entry;
            }
        }
        return null;
    }

    /// Get number of valid partitions
    pub fn getPartitionCount(self: *const Mbr) usize {
        var count: usize = 0;
        for (self.partitions) |entry| {
            if (entry.isValid()) {
                count += 1;
            }
        }
        return count;
    }
};

// Verify structure sizes at compile time
comptime {
    if (@sizeOf(PartitionEntry) != 16) {
        @compileError("PartitionEntry must be 16 bytes");
    }
    if (@sizeOf(Mbr) != 512) {
        @compileError("MBR must be 512 bytes");
    }
}

// ============================================================
// MBR Reading Functions
// ============================================================

/// Read and parse MBR from disk
pub fn readMbr() hal.HalError!Mbr {
    var sector: [512]u8 = undefined;
    try ata.readSector(MBR_LBA, &sector);

    const mbr: *const Mbr = @ptrCast(@alignCast(&sector));

    if (!mbr.isValid()) {
        return hal.HalError.InvalidParameter;
    }

    return mbr.*;
}

/// Find the data partition (FAT32) on iPod
/// Returns the starting LBA of the FAT32 partition
pub fn findDataPartition() hal.HalError!u64 {
    const mbr = try readMbr();

    // First try to find FAT32 partition
    if (mbr.findFat32Partition()) |partition| {
        return partition.lba_start;
    }

    // Fall back to any FAT partition
    if (mbr.findFatPartition()) |partition| {
        return partition.lba_start;
    }

    return hal.HalError.DeviceNotReady;
}

/// Get information about all partitions
pub const PartitionInfo = struct {
    index: u8,
    partition_type: PartitionType,
    lba_start: u64,
    sector_count: u64,
    size_mb: u32,
    bootable: bool,
};

/// List all valid partitions
pub fn listPartitions(buffer: []PartitionInfo) hal.HalError![]PartitionInfo {
    const mbr = try readMbr();

    var count: usize = 0;
    for (mbr.partitions, 0..) |entry, i| {
        if (entry.isValid() and count < buffer.len) {
            buffer[count] = PartitionInfo{
                .index = @intCast(i),
                .partition_type = entry.partition_type,
                .lba_start = entry.lba_start,
                .sector_count = entry.sector_count,
                .size_mb = entry.getSizeMB(),
                .bootable = entry.isBootable(),
            };
            count += 1;
        }
    }

    return buffer[0..count];
}

// ============================================================
// iPod-Specific Functions
// ============================================================

/// iPod partition layout structure
pub const IpodPartitions = struct {
    firmware_lba: ?u64,
    firmware_size: u64,
    data_lba: ?u64,
    data_size: u64,
};

/// Detect iPod-specific partition layout
/// iPods typically have:
/// - Partition 1: Firmware (may appear as type 0x00 or Apple-specific)
/// - Partition 2: Data (FAT32)
pub fn detectIpodLayout() hal.HalError!IpodPartitions {
    const mbr = try readMbr();

    var result = IpodPartitions{
        .firmware_lba = null,
        .firmware_size = 0,
        .data_lba = null,
        .data_size = 0,
    };

    // Partition 1 is typically firmware
    if (mbr.partitions[0].sector_count > 0) {
        result.firmware_lba = mbr.partitions[0].lba_start;
        result.firmware_size = mbr.partitions[0].getSizeBytes();
    }

    // Partition 2 is typically FAT32 data
    if (mbr.partitions[1].isValid() and mbr.partitions[1].partition_type.isFat()) {
        result.data_lba = mbr.partitions[1].lba_start;
        result.data_size = mbr.partitions[1].getSizeBytes();
    } else {
        // Search all partitions for FAT32
        if (mbr.findFat32Partition()) |partition| {
            result.data_lba = partition.lba_start;
            result.data_size = partition.getSizeBytes();
        }
    }

    return result;
}

// ============================================================
// Tests
// ============================================================

test "partition entry size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PartitionEntry));
}

test "mbr size" {
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(Mbr));
}

test "partition type detection" {
    try std.testing.expect(PartitionType.fat32.isFat32());
    try std.testing.expect(PartitionType.fat32_lba.isFat32());
    try std.testing.expect(!PartitionType.fat16.isFat32());
    try std.testing.expect(PartitionType.fat16.isFat());
}

test "partition entry validation" {
    var entry = PartitionEntry{
        .boot_flag = 0,
        .start_head = 0,
        .start_sector_cylinder = 0,
        .partition_type = .empty,
        .end_head = 0,
        .end_sector_cylinder = 0,
        .lba_start = 0,
        .sector_count = 0,
    };

    // Empty partition should be invalid
    try std.testing.expect(!entry.isValid());

    // Valid FAT32 partition
    entry.partition_type = .fat32;
    entry.lba_start = 63;
    entry.sector_count = 1000000;
    try std.testing.expect(entry.isValid());
    try std.testing.expect(entry.partition_type.isFat32());
}

test "partition size calculation" {
    const entry = PartitionEntry{
        .boot_flag = 0,
        .start_head = 0,
        .start_sector_cylinder = 0,
        .partition_type = .fat32,
        .end_head = 0,
        .end_sector_cylinder = 0,
        .lba_start = 63,
        .sector_count = 2097152, // 1GB in sectors
    };

    try std.testing.expectEqual(@as(u64, 1073741824), entry.getSizeBytes());
    try std.testing.expectEqual(@as(u32, 1024), entry.getSizeMB());
}
