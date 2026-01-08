//! FAT32 Filesystem Implementation
//!
//! This module provides FAT32 filesystem support for reading music files.

const std = @import("std");
const hal = @import("../../hal/hal.zig");
const ata = @import("ata.zig");

// ============================================================
// FAT32 Structures
// ============================================================

/// Boot sector (first sector of partition)
pub const BootSector = extern struct {
    jump: [3]u8,
    oem_name: [8]u8,
    bytes_per_sector: u16 align(1),
    sectors_per_cluster: u8,
    reserved_sectors: u16 align(1),
    num_fats: u8,
    root_entries: u16 align(1), // 0 for FAT32
    total_sectors_16: u16 align(1), // 0 for FAT32
    media_type: u8,
    fat_size_16: u16 align(1), // 0 for FAT32
    sectors_per_track: u16 align(1),
    num_heads: u16 align(1),
    hidden_sectors: u32 align(1),
    total_sectors_32: u32 align(1),

    // FAT32 specific
    fat_size_32: u32 align(1),
    ext_flags: u16 align(1),
    fs_version: u16 align(1),
    root_cluster: u32 align(1),
    fs_info_sector: u16 align(1),
    backup_boot_sector: u16 align(1),
    reserved: [12]u8,
    drive_number: u8,
    reserved1: u8,
    boot_signature: u8,
    volume_id: u32 align(1),
    volume_label: [11]u8,
    fs_type: [8]u8,
};

/// Directory entry (32 bytes)
pub const DirEntry = extern struct {
    name: [11]u8,
    attributes: u8,
    reserved: u8,
    create_time_tenth: u8,
    create_time: u16 align(1),
    create_date: u16 align(1),
    access_date: u16 align(1),
    cluster_high: u16 align(1),
    modify_time: u16 align(1),
    modify_date: u16 align(1),
    cluster_low: u16 align(1),
    file_size: u32 align(1),

    pub const ATTR_READ_ONLY: u8 = 0x01;
    pub const ATTR_HIDDEN: u8 = 0x02;
    pub const ATTR_SYSTEM: u8 = 0x04;
    pub const ATTR_VOLUME_ID: u8 = 0x08;
    pub const ATTR_DIRECTORY: u8 = 0x10;
    pub const ATTR_ARCHIVE: u8 = 0x20;
    pub const ATTR_LONG_NAME: u8 = 0x0F;

    pub fn getCluster(self: DirEntry) u32 {
        return (@as(u32, self.cluster_high) << 16) | self.cluster_low;
    }

    pub fn isDirectory(self: DirEntry) bool {
        return (self.attributes & ATTR_DIRECTORY) != 0;
    }

    pub fn isFile(self: DirEntry) bool {
        return (self.attributes & (ATTR_DIRECTORY | ATTR_VOLUME_ID)) == 0;
    }

    pub fn isDeleted(self: DirEntry) bool {
        return self.name[0] == 0xE5;
    }

    pub fn isEndOfDir(self: DirEntry) bool {
        return self.name[0] == 0x00;
    }
};

// ============================================================
// FAT32 Filesystem
// ============================================================

pub const Fat32 = struct {
    // Partition info
    partition_start: u64,
    bytes_per_sector: u32,
    sectors_per_cluster: u32,
    cluster_size: u32,

    // FAT info
    fat_start: u64,
    fat_sectors: u32,
    num_fats: u8,

    // Data region
    data_start: u64,
    root_cluster: u32,
    total_clusters: u32,

    // Caches
    current_fat_sector: u64 = 0,
    fat_cache: [512]u8 = [_]u8{0} ** 512,
    fat_cache_valid: bool = false,

    /// Initialize FAT32 filesystem from partition
    pub fn init(partition_lba: u64) hal.HalError!Fat32 {
        var boot_sector: [512]u8 = undefined;
        try ata.readSector(partition_lba, &boot_sector);

        const bs: *const BootSector = @ptrCast(&boot_sector);

        // Verify this is FAT32
        if (bs.fat_size_16 != 0 or bs.root_entries != 0) {
            return hal.HalError.InvalidParameter; // Not FAT32
        }

        const bytes_per_sector = bs.bytes_per_sector;
        const sectors_per_cluster = bs.sectors_per_cluster;
        const reserved_sectors = bs.reserved_sectors;
        const fat_sectors = bs.fat_size_32;

        const fat_start = partition_lba + reserved_sectors;
        const data_start = fat_start + (@as(u64, fat_sectors) * bs.num_fats);

        const total_sectors = bs.total_sectors_32;
        const data_sectors = total_sectors - reserved_sectors - (@as(u32, fat_sectors) * bs.num_fats);
        const total_clusters = data_sectors / sectors_per_cluster;

        return Fat32{
            .partition_start = partition_lba,
            .bytes_per_sector = bytes_per_sector,
            .sectors_per_cluster = sectors_per_cluster,
            .cluster_size = @as(u32, bytes_per_sector) * sectors_per_cluster,
            .fat_start = fat_start,
            .fat_sectors = fat_sectors,
            .num_fats = bs.num_fats,
            .data_start = data_start,
            .root_cluster = bs.root_cluster,
            .total_clusters = total_clusters,
        };
    }

    /// Convert cluster number to LBA
    pub fn clusterToLba(self: *Fat32, cluster: u32) u64 {
        return self.data_start + (@as(u64, cluster - 2) * self.sectors_per_cluster);
    }

    /// Get next cluster from FAT
    pub fn getNextCluster(self: *Fat32, cluster: u32) hal.HalError!?u32 {
        const fat_offset = cluster * 4;
        const fat_sector = self.fat_start + (fat_offset / 512);
        const offset_in_sector = fat_offset % 512;

        // Load FAT sector if not cached
        if (!self.fat_cache_valid or self.current_fat_sector != fat_sector) {
            try ata.readSector(fat_sector, &self.fat_cache);
            self.current_fat_sector = fat_sector;
            self.fat_cache_valid = true;
        }

        // Read 32-bit FAT entry
        const entry_ptr: *align(1) const u32 = @ptrCast(&self.fat_cache[offset_in_sector]);
        const entry = entry_ptr.* & 0x0FFFFFFF;

        // Check for end of chain
        if (entry >= 0x0FFFFFF8) {
            return null;
        }

        return entry;
    }

    /// Read a cluster into buffer
    pub fn readCluster(self: *Fat32, cluster: u32, buffer: []u8) hal.HalError!void {
        const lba = self.clusterToLba(cluster);
        const sectors: u16 = @intCast(self.sectors_per_cluster);
        try ata.readSectors(lba, sectors, buffer);
    }

    /// Open root directory
    pub fn openRootDir(self: *Fat32) Directory {
        return Directory{
            .fs = self,
            .first_cluster = self.root_cluster,
            .current_cluster = self.root_cluster,
            .position = 0,
        };
    }
};

// ============================================================
// Directory Operations
// ============================================================

pub const Directory = struct {
    fs: *Fat32,
    first_cluster: u32,
    current_cluster: u32,
    position: u32,

    /// Read next directory entry
    pub fn readEntry(self: *Directory) hal.HalError!?DirEntry {
        const entries_per_cluster = self.fs.cluster_size / 32;

        while (true) {
            // Check if we need to move to next cluster
            const entry_in_cluster = self.position % entries_per_cluster;
            if (self.position > 0 and entry_in_cluster == 0) {
                // Get next cluster
                if (try self.fs.getNextCluster(self.current_cluster)) |next| {
                    self.current_cluster = next;
                } else {
                    return null; // End of directory
                }
            }

            // Read current cluster
            var cluster_buffer: [32768]u8 = undefined;
            const cluster_data = cluster_buffer[0..self.fs.cluster_size];
            try self.fs.readCluster(self.current_cluster, cluster_data);

            // Get entry
            const entry_offset = entry_in_cluster * 32;
            const entry: *const DirEntry = @ptrCast(@alignCast(&cluster_data[entry_offset]));

            self.position += 1;

            if (entry.isEndOfDir()) {
                return null;
            }

            if (entry.isDeleted()) {
                continue;
            }

            // Skip long name entries
            if ((entry.attributes & DirEntry.ATTR_LONG_NAME) == DirEntry.ATTR_LONG_NAME) {
                continue;
            }

            return entry.*;
        }
    }

    /// Rewind to start of directory
    pub fn rewind(self: *Directory) void {
        self.current_cluster = self.first_cluster;
        self.position = 0;
    }
};

// ============================================================
// File Operations
// ============================================================

pub const File = struct {
    fs: *Fat32,
    first_cluster: u32,
    current_cluster: u32,
    file_size: u32,
    position: u32,

    /// Read bytes from file
    pub fn read(self: *File, buffer: []u8) hal.HalError!usize {
        if (self.position >= self.file_size) {
            return 0;
        }

        var bytes_read: usize = 0;
        var remaining = @min(buffer.len, self.file_size - self.position);

        while (remaining > 0 and self.current_cluster != 0) {
            const offset_in_cluster = self.position % self.fs.cluster_size;
            const bytes_in_cluster = @min(remaining, self.fs.cluster_size - offset_in_cluster);

            // Read cluster
            var cluster_buffer: [32768]u8 = undefined;
            const cluster_data = cluster_buffer[0..self.fs.cluster_size];
            try self.fs.readCluster(self.current_cluster, cluster_data);

            // Copy to output buffer
            const src = cluster_data[offset_in_cluster..][0..bytes_in_cluster];
            @memcpy(buffer[bytes_read..][0..bytes_in_cluster], src);

            bytes_read += bytes_in_cluster;
            self.position += @intCast(bytes_in_cluster);
            remaining -= bytes_in_cluster;

            // Move to next cluster if needed
            if (self.position % self.fs.cluster_size == 0) {
                if (try self.fs.getNextCluster(self.current_cluster)) |next| {
                    self.current_cluster = next;
                } else {
                    break;
                }
            }
        }

        return bytes_read;
    }

    /// Seek to position in file
    pub fn seek(self: *File, position: u32) hal.HalError!void {
        if (position > self.file_size) {
            return hal.HalError.InvalidParameter;
        }

        // Calculate which cluster
        const target_cluster_index = position / self.fs.cluster_size;

        // Walk cluster chain from start
        self.current_cluster = self.first_cluster;
        var i: u32 = 0;
        while (i < target_cluster_index) : (i += 1) {
            if (try self.fs.getNextCluster(self.current_cluster)) |next| {
                self.current_cluster = next;
            } else {
                return hal.HalError.InvalidParameter;
            }
        }

        self.position = position;
    }

    /// Get current position
    pub fn tell(self: *File) u32 {
        return self.position;
    }

    /// Get file size
    pub fn size(self: *File) u32 {
        return self.file_size;
    }
};

// ============================================================
// Tests
// ============================================================

test "FAT32 structures size" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(DirEntry));
}
