//! FAT32 Filesystem Parser
//!
//! Provides read access to FAT32 formatted disk images, useful for:
//! - Reading music files for audio testing
//! - Navigating directory structures
//! - Loading firmware from disk
//!
//! Note: The emulator itself sees raw disk sectors via ATA.
//! This module is for higher-level file access and debugging.
//!
//! Reference: Microsoft FAT32 File System Specification

const std = @import("std");

/// FAT32 Boot Sector / BPB (BIOS Parameter Block)
pub const BootSector = extern struct {
    /// Jump instruction (3 bytes)
    jump: [3]u8,

    /// OEM Name (8 bytes)
    oem_name: [8]u8,

    /// Bytes per sector (usually 512)
    bytes_per_sector: u16 align(1),

    /// Sectors per cluster (power of 2)
    sectors_per_cluster: u8,

    /// Reserved sector count (includes boot sector)
    reserved_sectors: u16 align(1),

    /// Number of FATs (usually 2)
    num_fats: u8,

    /// Root entry count (0 for FAT32)
    root_entry_count: u16 align(1),

    /// Total sectors 16-bit (0 for FAT32)
    total_sectors_16: u16 align(1),

    /// Media type
    media_type: u8,

    /// Sectors per FAT (0 for FAT32, use fat_size_32)
    sectors_per_fat_16: u16 align(1),

    /// Sectors per track
    sectors_per_track: u16 align(1),

    /// Number of heads
    num_heads: u16 align(1),

    /// Hidden sectors
    hidden_sectors: u32 align(1),

    /// Total sectors 32-bit
    total_sectors_32: u32 align(1),

    // FAT32 specific fields
    /// Sectors per FAT (FAT32)
    fat_size_32: u32 align(1),

    /// Extended flags
    ext_flags: u16 align(1),

    /// Filesystem version
    fs_version: u16 align(1),

    /// Root directory cluster
    root_cluster: u32 align(1),

    /// FSInfo sector number
    fs_info_sector: u16 align(1),

    /// Backup boot sector
    backup_boot_sector: u16 align(1),

    /// Reserved (12 bytes)
    reserved: [12]u8,

    /// Drive number
    drive_number: u8,

    /// Reserved
    reserved1: u8,

    /// Boot signature (0x29)
    boot_sig: u8,

    /// Volume ID
    volume_id: u32 align(1),

    /// Volume label (11 bytes)
    volume_label: [11]u8,

    /// Filesystem type string
    fs_type: [8]u8,

    comptime {
        // Ensure correct packing
        std.debug.assert(@sizeOf(BootSector) == 90);
    }

    /// Check if this is a valid FAT32 boot sector
    pub fn isValid(self: *const BootSector) bool {
        // Check for FAT32 signature
        if (!std.mem.eql(u8, &self.fs_type, "FAT32   ")) {
            return false;
        }
        // Check boot signature
        if (self.boot_sig != 0x29) {
            return false;
        }
        // FAT32 should have root_entry_count = 0
        if (self.root_entry_count != 0) {
            return false;
        }
        return true;
    }

    /// Get the start sector of the first FAT
    pub fn fatStartSector(self: *const BootSector) u32 {
        return self.reserved_sectors;
    }

    /// Get the start sector of the data region
    pub fn dataStartSector(self: *const BootSector) u32 {
        return self.reserved_sectors + (self.num_fats * self.fat_size_32);
    }

    /// Convert cluster number to sector number
    pub fn clusterToSector(self: *const BootSector, cluster: u32) u32 {
        // Clusters 0 and 1 are reserved, data starts at cluster 2
        return self.dataStartSector() + (cluster - 2) * self.sectors_per_cluster;
    }

    /// Get total number of clusters
    pub fn totalClusters(self: *const BootSector) u32 {
        const data_sectors = self.total_sectors_32 - self.dataStartSector();
        return data_sectors / self.sectors_per_cluster;
    }
};

/// Directory entry (32 bytes)
pub const DirEntry = extern struct {
    /// Filename (8.3 format, space padded)
    name: [8]u8,

    /// Extension
    ext: [3]u8,

    /// Attributes
    attr: u8,

    /// Reserved for Windows NT
    nt_reserved: u8,

    /// Creation time (tenths of second)
    create_time_tenth: u8,

    /// Creation time
    create_time: u16 align(1),

    /// Creation date
    create_date: u16 align(1),

    /// Last access date
    access_date: u16 align(1),

    /// High word of first cluster
    cluster_high: u16 align(1),

    /// Last write time
    write_time: u16 align(1),

    /// Last write date
    write_date: u16 align(1),

    /// Low word of first cluster
    cluster_low: u16 align(1),

    /// File size in bytes
    file_size: u32 align(1),

    comptime {
        std.debug.assert(@sizeOf(DirEntry) == 32);
    }

    /// Attribute flags
    pub const ATTR_READ_ONLY: u8 = 0x01;
    pub const ATTR_HIDDEN: u8 = 0x02;
    pub const ATTR_SYSTEM: u8 = 0x04;
    pub const ATTR_VOLUME_ID: u8 = 0x08;
    pub const ATTR_DIRECTORY: u8 = 0x10;
    pub const ATTR_ARCHIVE: u8 = 0x20;
    pub const ATTR_LONG_NAME: u8 = 0x0F;

    /// Check if entry is free (deleted or never used)
    pub fn isFree(self: *const DirEntry) bool {
        return self.name[0] == 0x00 or self.name[0] == 0xE5;
    }

    /// Check if entry is end of directory
    pub fn isEndOfDir(self: *const DirEntry) bool {
        return self.name[0] == 0x00;
    }

    /// Check if this is a long filename entry
    pub fn isLongName(self: *const DirEntry) bool {
        return (self.attr & ATTR_LONG_NAME) == ATTR_LONG_NAME;
    }

    /// Check if this is a directory
    pub fn isDirectory(self: *const DirEntry) bool {
        return (self.attr & ATTR_DIRECTORY) != 0;
    }

    /// Check if this is a volume label
    pub fn isVolumeLabel(self: *const DirEntry) bool {
        return (self.attr & ATTR_VOLUME_ID) != 0;
    }

    /// Get the first cluster number
    pub fn getCluster(self: *const DirEntry) u32 {
        return (@as(u32, self.cluster_high) << 16) | self.cluster_low;
    }

    /// Get the filename as a string (trimmed)
    pub fn getName(self: *const DirEntry, buf: *[12]u8) []const u8 {
        var len: usize = 0;

        // Copy name (trim trailing spaces)
        var name_len: usize = 8;
        while (name_len > 0 and self.name[name_len - 1] == ' ') {
            name_len -= 1;
        }
        @memcpy(buf[0..name_len], self.name[0..name_len]);
        len = name_len;

        // Add extension if present
        var ext_len: usize = 3;
        while (ext_len > 0 and self.ext[ext_len - 1] == ' ') {
            ext_len -= 1;
        }
        if (ext_len > 0) {
            buf[len] = '.';
            len += 1;
            @memcpy(buf[len .. len + ext_len], self.ext[0..ext_len]);
            len += ext_len;
        }

        return buf[0..len];
    }
};

/// Long filename entry (32 bytes)
pub const LfnEntry = extern struct {
    /// Sequence number
    seq: u8,

    /// Characters 1-5 (Unicode)
    name1: [10]u8,

    /// Attributes (always 0x0F)
    attr: u8,

    /// Type (always 0)
    type_: u8,

    /// Checksum
    checksum: u8,

    /// Characters 6-11 (Unicode)
    name2: [12]u8,

    /// First cluster (always 0)
    cluster: u16 align(1),

    /// Characters 12-13 (Unicode)
    name3: [4]u8,

    comptime {
        std.debug.assert(@sizeOf(LfnEntry) == 32);
    }
};

/// FAT32 Filesystem reader
pub const Fat32Reader = struct {
    /// Disk read function
    read_sector: *const fn (ctx: *anyopaque, lba: u64, buf: *[512]u8) bool,
    ctx: *anyopaque,

    /// Cached boot sector
    boot_sector: BootSector,

    /// Is filesystem valid
    valid: bool,

    const Self = @This();

    /// Initialize from disk
    pub fn init(
        ctx: *anyopaque,
        read_fn: *const fn (ctx: *anyopaque, lba: u64, buf: *[512]u8) bool,
    ) Self {
        var self = Self{
            .read_sector = read_fn,
            .ctx = ctx,
            .boot_sector = undefined,
            .valid = false,
        };

        // Read boot sector
        var sector: [512]u8 = undefined;
        if (!self.read_sector(self.ctx, 0, &sector)) {
            return self;
        }

        // Check for MBR (partition table)
        if (sector[510] == 0x55 and sector[511] == 0xAA) {
            // Check first partition type
            const part_type = sector[0x1C2];
            if (part_type == 0x0B or part_type == 0x0C) {
                // FAT32 partition, get start LBA
                const part_start = @as(u32, sector[0x1C6]) |
                    (@as(u32, sector[0x1C7]) << 8) |
                    (@as(u32, sector[0x1C8]) << 16) |
                    (@as(u32, sector[0x1C9]) << 24);

                // Read partition boot sector
                if (!self.read_sector(self.ctx, part_start, &sector)) {
                    return self;
                }
            }
        }

        // Parse boot sector
        const bs: *const BootSector = @ptrCast(&sector);
        self.boot_sector = bs.*;

        // Validate
        self.valid = self.boot_sector.isValid();

        return self;
    }

    /// Read a cluster into buffer
    pub fn readCluster(self: *Self, cluster: u32, buf: []u8) bool {
        if (!self.valid) return false;

        const sector = self.boot_sector.clusterToSector(cluster);
        const sectors = self.boot_sector.sectors_per_cluster;
        const bytes_per_sector = self.boot_sector.bytes_per_sector;

        var offset: usize = 0;
        for (0..sectors) |i| {
            if (offset + bytes_per_sector > buf.len) break;
            var sector_buf: [512]u8 = undefined;
            if (!self.read_sector(self.ctx, sector + i, &sector_buf)) {
                return false;
            }
            @memcpy(buf[offset .. offset + bytes_per_sector], &sector_buf);
            offset += bytes_per_sector;
        }

        return true;
    }

    /// Get next cluster from FAT
    pub fn getNextCluster(self: *Self, cluster: u32) ?u32 {
        if (!self.valid) return null;

        const fat_offset = cluster * 4;
        const fat_sector = self.boot_sector.fatStartSector() + (fat_offset / 512);
        const entry_offset = fat_offset % 512;

        var sector_buf: [512]u8 = undefined;
        if (!self.read_sector(self.ctx, fat_sector, &sector_buf)) {
            return null;
        }

        const next = @as(u32, sector_buf[entry_offset]) |
            (@as(u32, sector_buf[entry_offset + 1]) << 8) |
            (@as(u32, sector_buf[entry_offset + 2]) << 16) |
            (@as(u32, sector_buf[entry_offset + 3]) << 24);

        // Mask off reserved bits
        const next_cluster = next & 0x0FFFFFFF;

        // Check for end of chain
        if (next_cluster >= 0x0FFFFFF8) {
            return null;
        }

        return next_cluster;
    }

    /// Get root directory cluster
    pub fn getRootCluster(self: *const Self) u32 {
        return self.boot_sector.root_cluster;
    }

    /// Read directory entries from a cluster
    pub fn readDirectory(
        self: *Self,
        cluster: u32,
        buf: []DirEntry,
    ) usize {
        if (!self.valid) return 0;

        const cluster_size = @as(usize, self.boot_sector.sectors_per_cluster) *
            self.boot_sector.bytes_per_sector;
        var cluster_buf: [32768]u8 = undefined; // Max 64 sectors/cluster * 512

        if (cluster_size > cluster_buf.len) return 0;

        var count: usize = 0;
        var current_cluster = cluster;

        while (current_cluster != 0 and count < buf.len) {
            if (!self.readCluster(current_cluster, cluster_buf[0..cluster_size])) {
                break;
            }

            // Parse directory entries
            const entries_per_cluster = cluster_size / 32;
            const entries: [*]const DirEntry = @ptrCast(&cluster_buf);

            for (0..entries_per_cluster) |i| {
                if (count >= buf.len) break;

                const entry = entries[i];
                if (entry.isEndOfDir()) {
                    return count;
                }
                if (!entry.isFree() and !entry.isLongName()) {
                    buf[count] = entry;
                    count += 1;
                }
            }

            // Get next cluster
            current_cluster = self.getNextCluster(current_cluster) orelse break;
        }

        return count;
    }

    /// Find a file in a directory by name
    pub fn findFile(
        self: *Self,
        dir_cluster: u32,
        name: []const u8,
    ) ?DirEntry {
        var entries: [128]DirEntry = undefined;
        const count = self.readDirectory(dir_cluster, &entries);

        var name_buf: [12]u8 = undefined;
        for (entries[0..count]) |entry| {
            const entry_name = entry.getName(&name_buf);
            if (std.ascii.eqlIgnoreCase(entry_name, name)) {
                return entry;
            }
        }

        return null;
    }

    /// Get volume label
    pub fn getVolumeLabel(self: *Self) ?[11]u8 {
        if (!self.valid) return null;

        // Check boot sector first
        if (!std.mem.eql(u8, &self.boot_sector.volume_label, "           ")) {
            return self.boot_sector.volume_label;
        }

        // Check root directory for volume label entry
        var entries: [32]DirEntry = undefined;
        const count = self.readDirectory(self.boot_sector.root_cluster, &entries);

        for (entries[0..count]) |entry| {
            if (entry.isVolumeLabel()) {
                var label: [11]u8 = undefined;
                @memcpy(label[0..8], &entry.name);
                @memcpy(label[8..11], &entry.ext);
                return label;
            }
        }

        return null;
    }
};

// Tests
test "boot sector size" {
    try std.testing.expectEqual(@as(usize, 90), @sizeOf(BootSector));
}

test "directory entry size" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(DirEntry));
}
