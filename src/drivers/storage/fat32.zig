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

    /// Write a cluster from buffer
    pub fn writeCluster(self: *Fat32, cluster: u32, buffer: []const u8) hal.HalError!void {
        const lba = self.clusterToLba(cluster);
        const sectors: u16 = @intCast(self.sectors_per_cluster);
        try ata.writeSectors(lba, sectors, buffer);
    }

    /// Set FAT entry for a cluster
    pub fn setFatEntry(self: *Fat32, cluster: u32, value: u32) hal.HalError!void {
        const fat_offset = cluster * 4;
        const fat_sector = self.fat_start + (fat_offset / 512);
        const offset_in_sector = fat_offset % 512;

        // Load FAT sector if not cached or different sector
        if (!self.fat_cache_valid or self.current_fat_sector != fat_sector) {
            try ata.readSector(fat_sector, &self.fat_cache);
            self.current_fat_sector = fat_sector;
            self.fat_cache_valid = true;
        }

        // Update entry in cache
        const entry_ptr: *align(1) u32 = @ptrCast(&self.fat_cache[offset_in_sector]);
        entry_ptr.* = value & 0x0FFFFFFF;

        // Write back to all FATs
        var fat_num: u8 = 0;
        while (fat_num < self.num_fats) : (fat_num += 1) {
            const sector = fat_sector + (@as(u64, fat_num) * self.fat_sectors);
            try ata.writeSector(sector, &self.fat_cache);
        }
    }

    /// Allocate a free cluster
    /// Returns the cluster number or null if disk is full
    pub fn allocateCluster(self: *Fat32) hal.HalError!?u32 {
        // Search for free cluster starting from cluster 2
        var cluster: u32 = 2;
        while (cluster < self.total_clusters + 2) : (cluster += 1) {
            const entry = try self.getNextCluster(cluster);
            if (entry == null or entry.? == 0) {
                // Check if this is actually a free cluster (entry == 0)
                const fat_offset = cluster * 4;
                const fat_sector = self.fat_start + (fat_offset / 512);
                const offset_in_sector = fat_offset % 512;

                if (!self.fat_cache_valid or self.current_fat_sector != fat_sector) {
                    try ata.readSector(fat_sector, &self.fat_cache);
                    self.current_fat_sector = fat_sector;
                    self.fat_cache_valid = true;
                }

                const entry_ptr: *align(1) const u32 = @ptrCast(&self.fat_cache[offset_in_sector]);
                if ((entry_ptr.* & 0x0FFFFFFF) == 0) {
                    // Mark as end of chain
                    try self.setFatEntry(cluster, 0x0FFFFFFF);
                    return cluster;
                }
            }
        }
        return null; // Disk full
    }

    /// Allocate a cluster and link it to an existing chain
    pub fn extendChain(self: *Fat32, last_cluster: u32) hal.HalError!?u32 {
        const new_cluster = try self.allocateCluster() orelse return null;
        try self.setFatEntry(last_cluster, new_cluster);
        return new_cluster;
    }

    /// Free a cluster chain starting from the given cluster
    pub fn freeChain(self: *Fat32, start_cluster: u32) hal.HalError!void {
        var cluster = start_cluster;
        while (cluster >= 2 and cluster < 0x0FFFFFF8) {
            const next = try self.getNextCluster(cluster);
            try self.setFatEntry(cluster, 0); // Mark as free
            if (next) |n| {
                cluster = n;
            } else {
                break;
            }
        }
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
// High-Level File Access
// ============================================================

pub const FatError = error{
    file_not_found,
    not_a_file,
    not_a_directory,
    path_too_long,
    io_error,
    not_initialized,
};

/// Global filesystem instance (initialized by kernel)
var global_fs: ?Fat32 = null;

/// Initialize global filesystem
pub fn initGlobal(fs: Fat32) void {
    global_fs = fs;
}

/// Check if filesystem is initialized
pub fn isInitialized() bool {
    return global_fs != null;
}

/// Directory entry info for listing
pub const DirEntryInfo = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    is_directory: bool = false,
    size: u32 = 0,

    pub fn getName(self: *const DirEntryInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// List directory contents
/// Returns the number of entries written to the buffer
pub fn listDirectory(path: []const u8, entries: []DirEntryInfo) FatError!usize {
    var fs = global_fs orelse return FatError.not_initialized;

    var dir = try openDirectory(&fs, path);
    var count: usize = 0;

    while (count < entries.len) {
        const entry = dir.readEntry() catch return FatError.io_error;
        if (entry == null) break;

        const e = entry.?;

        // Skip volume labels and hidden files
        if ((e.attributes & DirEntry.ATTR_VOLUME_ID) != 0) continue;
        if ((e.attributes & DirEntry.ATTR_HIDDEN) != 0) continue;

        var info = DirEntryInfo{};
        info.is_directory = e.isDirectory();
        info.size = e.file_size;

        // Convert 8.3 name to normal format
        var name_len: u8 = 0;

        // Copy filename part (first 8 chars, trimmed)
        var i: usize = 0;
        while (i < 8 and e.name[i] != ' ') : (i += 1) {
            info.name[name_len] = e.name[i];
            name_len += 1;
        }

        // Add extension if present (for files)
        if (e.name[8] != ' ') {
            info.name[name_len] = '.';
            name_len += 1;
            i = 8;
            while (i < 11 and e.name[i] != ' ') : (i += 1) {
                info.name[name_len] = e.name[i];
                name_len += 1;
            }
        }

        info.name_len = name_len;
        entries[count] = info;
        count += 1;
    }

    return count;
}

/// Read an entire file into a buffer
/// Returns the number of bytes read
pub fn readFile(path: []const u8, buffer: []u8) FatError!usize {
    var fs = global_fs orelse return FatError.not_initialized;

    // Parse path and find file
    const file = try openFile(&fs, path);
    var f = file;

    // Read entire file
    const bytes_read = f.read(buffer) catch return FatError.io_error;
    return bytes_read;
}

/// Write data to a file, creating it if it doesn't exist
/// This replaces the entire file contents
pub fn writeFile(path: []const u8, data: []const u8) FatError!void {
    var fs = global_fs orelse return FatError.not_initialized;

    // Split path into directory and filename
    var dir_end: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/') dir_end = i;
    }

    const dir_path = if (dir_end > 0) path[0..dir_end] else "/";
    const filename = if (dir_end < path.len - 1) path[dir_end + 1 ..] else return FatError.file_not_found;

    // Open parent directory
    var dir = openDirectory(&fs, dir_path) catch return FatError.file_not_found;

    // Try to find existing file
    dir.rewind();
    const existing = findEntryWithPosition(&dir, filename) catch return FatError.io_error;

    if (existing.entry) |entry| {
        // File exists - update it
        try updateExistingFile(&fs, &dir, entry, existing.cluster, existing.offset, data);
    } else {
        // Create new file
        try createNewFile(&fs, &dir, filename, data);
    }
}

/// Result of finding an entry with position info
const EntrySearchResult = struct {
    entry: ?DirEntry,
    cluster: u32, // Cluster containing the entry
    offset: u32, // Byte offset within cluster
};

/// Find a directory entry and return its location
fn findEntryWithPosition(dir: *Directory, name: []const u8) hal.HalError!EntrySearchResult {
    const entries_per_cluster = dir.fs.cluster_size / 32;

    while (true) {
        const entry_in_cluster = dir.position % entries_per_cluster;
        if (dir.position > 0 and entry_in_cluster == 0) {
            if (try dir.fs.getNextCluster(dir.current_cluster)) |next| {
                dir.current_cluster = next;
            } else {
                return EntrySearchResult{ .entry = null, .cluster = 0, .offset = 0 };
            }
        }

        var cluster_buffer: [32768]u8 = undefined;
        const cluster_data = cluster_buffer[0..dir.fs.cluster_size];
        try dir.fs.readCluster(dir.current_cluster, cluster_data);

        const entry_offset = entry_in_cluster * 32;
        const entry: *const DirEntry = @ptrCast(@alignCast(&cluster_data[entry_offset]));

        const current_cluster = dir.current_cluster;
        const current_offset = @as(u32, @intCast(entry_offset));
        dir.position += 1;

        if (entry.isEndOfDir()) {
            return EntrySearchResult{ .entry = null, .cluster = current_cluster, .offset = current_offset };
        }

        if (entry.isDeleted()) continue;
        if ((entry.attributes & DirEntry.ATTR_LONG_NAME) == DirEntry.ATTR_LONG_NAME) continue;

        // Compare name
        var entry_name: [12]u8 = undefined;
        var entry_name_len: usize = 0;

        var i: usize = 0;
        while (i < 8 and entry.name[i] != ' ') : (i += 1) {
            entry_name[entry_name_len] = entry.name[i];
            entry_name_len += 1;
        }

        if (entry.name[8] != ' ') {
            entry_name[entry_name_len] = '.';
            entry_name_len += 1;
            i = 8;
            while (i < 11 and entry.name[i] != ' ') : (i += 1) {
                entry_name[entry_name_len] = entry.name[i];
                entry_name_len += 1;
            }
        }

        if (caseInsensitiveEqual(entry_name[0..entry_name_len], name)) {
            return EntrySearchResult{ .entry = entry.*, .cluster = current_cluster, .offset = current_offset };
        }
    }
}

/// Update an existing file with new data
fn updateExistingFile(fs: *Fat32, dir: *Directory, entry: DirEntry, entry_cluster: u32, entry_offset: u32, data: []const u8) FatError!void {
    _ = dir;

    // Free old cluster chain if file had data
    if (entry.getCluster() >= 2) {
        fs.freeChain(entry.getCluster()) catch return FatError.io_error;
    }

    // Allocate new clusters and write data
    const first_cluster = try writeDataToChain(fs, data);

    // Update directory entry
    try updateDirectoryEntry(fs, entry_cluster, entry_offset, first_cluster, @intCast(data.len));
}

/// Create a new file
fn createNewFile(fs: *Fat32, dir: *Directory, filename: []const u8, data: []const u8) FatError!void {
    // Find free entry slot in directory
    dir.rewind();
    const slot = findFreeEntrySlot(fs, dir) catch return FatError.io_error;
    if (slot.cluster == 0) return FatError.io_error; // Directory full

    // Allocate clusters and write data
    const first_cluster = if (data.len > 0) try writeDataToChain(fs, data) else 0;

    // Create directory entry
    try createDirectoryEntry(fs, slot.cluster, slot.offset, filename, first_cluster, @intCast(data.len), false);
}

/// Find a free directory entry slot
fn findFreeEntrySlot(fs: *Fat32, dir: *Directory) hal.HalError!struct { cluster: u32, offset: u32 } {
    const entries_per_cluster = fs.cluster_size / 32;
    var last_cluster = dir.current_cluster;

    while (true) {
        const entry_in_cluster = dir.position % entries_per_cluster;
        if (dir.position > 0 and entry_in_cluster == 0) {
            if (try fs.getNextCluster(dir.current_cluster)) |next| {
                last_cluster = dir.current_cluster;
                dir.current_cluster = next;
            } else {
                // Need to extend directory
                const new_cluster = try fs.extendChain(last_cluster) orelse return .{ .cluster = 0, .offset = 0 };
                // Zero out new cluster
                var zeros: [32768]u8 = [_]u8{0} ** 32768;
                try fs.writeCluster(new_cluster, zeros[0..fs.cluster_size]);
                dir.current_cluster = new_cluster;
            }
        }

        var cluster_buffer: [32768]u8 = undefined;
        const cluster_data = cluster_buffer[0..fs.cluster_size];
        try fs.readCluster(dir.current_cluster, cluster_data);

        const entry_offset = entry_in_cluster * 32;
        const entry: *const DirEntry = @ptrCast(@alignCast(&cluster_data[entry_offset]));

        if (entry.isEndOfDir() or entry.isDeleted()) {
            return .{ .cluster = dir.current_cluster, .offset = @intCast(entry_offset) };
        }

        dir.position += 1;
    }
}

/// Write data to a new cluster chain
fn writeDataToChain(fs: *Fat32, data: []const u8) FatError!u32 {
    if (data.len == 0) return 0;

    const first_cluster = (fs.allocateCluster() catch return FatError.io_error) orelse return FatError.io_error;
    var current_cluster = first_cluster;
    var offset: usize = 0;

    while (offset < data.len) {
        const bytes_to_write = @min(data.len - offset, fs.cluster_size);

        // Prepare cluster buffer (zero-padded)
        var cluster_buffer: [32768]u8 = [_]u8{0} ** 32768;
        @memcpy(cluster_buffer[0..bytes_to_write], data[offset..][0..bytes_to_write]);

        fs.writeCluster(current_cluster, cluster_buffer[0..fs.cluster_size]) catch return FatError.io_error;
        offset += bytes_to_write;

        if (offset < data.len) {
            // Need another cluster
            const next = (fs.extendChain(current_cluster) catch return FatError.io_error) orelse return FatError.io_error;
            current_cluster = next;
        }
    }

    return first_cluster;
}

/// Update a directory entry at a known location
fn updateDirectoryEntry(fs: *Fat32, cluster: u32, offset: u32, first_cluster: u32, size: u32) FatError!void {
    var cluster_buffer: [32768]u8 = undefined;
    const cluster_data = cluster_buffer[0..fs.cluster_size];
    fs.readCluster(cluster, cluster_data) catch return FatError.io_error;

    const entry: *DirEntry = @ptrCast(@alignCast(&cluster_data[offset]));
    entry.cluster_low = @truncate(first_cluster);
    entry.cluster_high = @truncate(first_cluster >> 16);
    entry.file_size = size;

    fs.writeCluster(cluster, cluster_data) catch return FatError.io_error;
}

/// Create a new directory entry
fn createDirectoryEntry(fs: *Fat32, cluster: u32, offset: u32, name: []const u8, first_cluster: u32, size: u32, is_directory: bool) FatError!void {
    var cluster_buffer: [32768]u8 = undefined;
    const cluster_data = cluster_buffer[0..fs.cluster_size];
    fs.readCluster(cluster, cluster_data) catch return FatError.io_error;

    const entry: *DirEntry = @ptrCast(@alignCast(&cluster_data[offset]));

    // Convert filename to 8.3 format
    entry.name = [_]u8{' '} ** 11;
    var name_pos: usize = 0;
    var ext_pos: usize = 8;
    var in_ext = false;

    for (name) |c| {
        if (c == '.') {
            in_ext = true;
            continue;
        }
        // Convert to uppercase
        const upper = if (c >= 'a' and c <= 'z') c - 32 else c;
        if (in_ext) {
            if (ext_pos < 11) {
                entry.name[ext_pos] = upper;
                ext_pos += 1;
            }
        } else {
            if (name_pos < 8) {
                entry.name[name_pos] = upper;
                name_pos += 1;
            }
        }
    }

    entry.attributes = if (is_directory) DirEntry.ATTR_DIRECTORY else DirEntry.ATTR_ARCHIVE;
    entry.reserved = 0;
    entry.create_time_tenth = 0;
    entry.create_time = 0;
    entry.create_date = 0;
    entry.access_date = 0;
    entry.modify_time = 0;
    entry.modify_date = 0;
    entry.cluster_high = @truncate(first_cluster >> 16);
    entry.cluster_low = @truncate(first_cluster);
    entry.file_size = size;

    // Write end-of-directory marker after this entry if needed
    if (offset + 32 < fs.cluster_size) {
        const next_entry: *DirEntry = @ptrCast(@alignCast(&cluster_data[offset + 32]));
        if (next_entry.name[0] != 0 and !next_entry.isDeleted()) {
            // Don't overwrite existing entries
        } else if (next_entry.name[0] != 0) {
            // Mark end of directory
            next_entry.name[0] = 0;
        }
    }

    fs.writeCluster(cluster, cluster_data) catch return FatError.io_error;
}

/// Create a directory (including parent directories if needed)
pub fn createDirectory(path: []const u8) FatError!void {
    var fs = global_fs orelse return FatError.not_initialized;

    var current_path: [256]u8 = undefined;
    var path_len: usize = 0;

    var remaining = path;
    if (remaining.len > 0 and remaining[0] == '/') {
        remaining = remaining[1..];
    }

    // Create each component
    while (remaining.len > 0) {
        // Find next component
        var component_end: usize = 0;
        while (component_end < remaining.len and remaining[component_end] != '/') {
            component_end += 1;
        }

        if (component_end == 0) {
            if (remaining.len > 0) remaining = remaining[1..];
            continue;
        }

        const component = remaining[0..component_end];

        // Build path to this component
        if (path_len > 0) {
            current_path[path_len] = '/';
            path_len += 1;
        } else {
            current_path[0] = '/';
            path_len = 1;
        }
        @memcpy(current_path[path_len..][0..component.len], component);
        path_len += component.len;

        // Check if directory exists
        const dir_result = openDirectory(&fs, current_path[0..path_len]);
        if (dir_result) |_| {
            // Directory exists, continue
        } else |_| {
            // Need to create it
            const parent_path = if (path_len > component.len + 1) current_path[0 .. path_len - component.len - 1] else "/";
            var parent_dir = openDirectory(&fs, parent_path) catch return FatError.io_error;

            // Find free slot
            const slot = findFreeEntrySlot(&fs, &parent_dir) catch return FatError.io_error;
            if (slot.cluster == 0) return FatError.io_error;

            // Allocate cluster for new directory
            const dir_cluster = (fs.allocateCluster() catch return FatError.io_error) orelse return FatError.io_error;

            // Initialize directory cluster with . and .. entries
            var dir_data: [32768]u8 = [_]u8{0} ** 32768;

            // . entry
            const dot: *DirEntry = @ptrCast(@alignCast(&dir_data[0]));
            dot.name = ".          ".*;
            dot.attributes = DirEntry.ATTR_DIRECTORY;
            dot.cluster_low = @truncate(dir_cluster);
            dot.cluster_high = @truncate(dir_cluster >> 16);

            // .. entry
            const dotdot: *DirEntry = @ptrCast(@alignCast(&dir_data[32]));
            dotdot.name = "..         ".*;
            dotdot.attributes = DirEntry.ATTR_DIRECTORY;
            const parent_cluster = parent_dir.first_cluster;
            dotdot.cluster_low = @truncate(parent_cluster);
            dotdot.cluster_high = @truncate(parent_cluster >> 16);

            fs.writeCluster(dir_cluster, dir_data[0..fs.cluster_size]) catch return FatError.io_error;

            // Create entry in parent
            try createDirectoryEntry(&fs, slot.cluster, slot.offset, component, dir_cluster, 0, true);
        }

        // Move to next component
        if (component_end < remaining.len) {
            remaining = remaining[component_end + 1 ..];
        } else {
            break;
        }
    }
}

/// Open a directory by path (e.g., "/MUSIC")
pub fn openDirectory(fs: *Fat32, path: []const u8) FatError!Directory {
    // Root directory
    if (path.len == 0 or (path.len == 1 and path[0] == '/')) {
        return fs.openRootDir();
    }

    var current_dir = fs.openRootDir();
    var remaining_path = path;

    // Skip leading slash
    if (remaining_path[0] == '/') {
        remaining_path = remaining_path[1..];
    }

    // Skip trailing slash
    while (remaining_path.len > 0 and remaining_path[remaining_path.len - 1] == '/') {
        remaining_path = remaining_path[0 .. remaining_path.len - 1];
    }

    if (remaining_path.len == 0) {
        return fs.openRootDir();
    }

    // Navigate through path components
    while (remaining_path.len > 0) {
        // Find next path separator
        var component_end: usize = 0;
        while (component_end < remaining_path.len and remaining_path[component_end] != '/') {
            component_end += 1;
        }

        const component = remaining_path[0..component_end];
        if (component.len == 0) break;

        // Find entry in current directory
        current_dir.rewind();
        const entry = findEntry(&current_dir, component) catch return FatError.io_error;
        if (entry == null) return FatError.file_not_found;

        if (!entry.?.isDirectory()) {
            return FatError.not_a_directory;
        }

        // Enter directory
        current_dir = Directory{
            .fs = fs,
            .first_cluster = entry.?.getCluster(),
            .current_cluster = entry.?.getCluster(),
            .position = 0,
        };

        // Move past this component
        if (component_end < remaining_path.len) {
            remaining_path = remaining_path[component_end + 1 ..];
        } else {
            break;
        }
    }

    return current_dir;
}

/// Open a file by path (e.g., "/MUSIC/song.wav")
pub fn openFile(fs: *Fat32, path: []const u8) FatError!File {
    if (path.len == 0) return FatError.file_not_found;

    var current_dir = fs.openRootDir();
    var remaining_path = path;

    // Skip leading slash
    if (remaining_path[0] == '/') {
        remaining_path = remaining_path[1..];
    }

    // Navigate through path components
    while (remaining_path.len > 0) {
        // Find next path separator
        var component_end: usize = 0;
        while (component_end < remaining_path.len and remaining_path[component_end] != '/') {
            component_end += 1;
        }

        const component = remaining_path[0..component_end];
        if (component.len == 0) break;

        // Find entry in current directory
        current_dir.rewind();
        const entry = findEntry(&current_dir, component) catch return FatError.io_error;
        if (entry == null) return FatError.file_not_found;

        // Move past this component
        if (component_end < remaining_path.len) {
            remaining_path = remaining_path[component_end + 1 ..];
        } else {
            remaining_path = remaining_path[remaining_path.len..];
        }

        // If there's more path, this must be a directory
        if (remaining_path.len > 0) {
            if (!entry.?.isDirectory()) {
                return FatError.file_not_found;
            }
            // Enter directory
            current_dir = Directory{
                .fs = fs,
                .first_cluster = entry.?.getCluster(),
                .current_cluster = entry.?.getCluster(),
                .position = 0,
            };
        } else {
            // This is the final component - must be a file
            if (!entry.?.isFile()) {
                return FatError.not_a_file;
            }
            return File{
                .fs = fs,
                .first_cluster = entry.?.getCluster(),
                .current_cluster = entry.?.getCluster(),
                .file_size = entry.?.file_size,
                .position = 0,
            };
        }
    }

    return FatError.file_not_found;
}

/// Find a directory entry by name
fn findEntry(dir: *Directory, name: []const u8) hal.HalError!?DirEntry {
    while (try dir.readEntry()) |entry| {
        // Convert 8.3 name to comparable format
        var entry_name: [12]u8 = undefined;
        var entry_name_len: usize = 0;

        // Copy filename part (first 8 chars, trimmed)
        var i: usize = 0;
        while (i < 8 and entry.name[i] != ' ') : (i += 1) {
            entry_name[entry_name_len] = entry.name[i];
            entry_name_len += 1;
        }

        // Add extension if present
        if (entry.name[8] != ' ') {
            entry_name[entry_name_len] = '.';
            entry_name_len += 1;
            i = 8;
            while (i < 11 and entry.name[i] != ' ') : (i += 1) {
                entry_name[entry_name_len] = entry.name[i];
                entry_name_len += 1;
            }
        }

        // Case-insensitive compare
        if (caseInsensitiveEqual(entry_name[0..entry_name_len], name)) {
            return entry;
        }
    }
    return null;
}

/// Case-insensitive string comparison
fn caseInsensitiveEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

// ============================================================
// Tests
// ============================================================

test "FAT32 structures size" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(DirEntry));
}

test "BootSector structure size" {
    try std.testing.expectEqual(@as(usize, 90), @sizeOf(BootSector));
}

test "DirEntry cluster extraction" {
    var entry = DirEntry{
        .name = "TEST    TXT".*,
        .attributes = 0x20,
        .reserved = 0,
        .create_time_tenth = 0,
        .create_time = 0,
        .create_date = 0,
        .access_date = 0,
        .cluster_high = 0x0001,
        .modify_time = 0,
        .modify_date = 0,
        .cluster_low = 0x0002,
        .file_size = 1024,
    };

    // Cluster should be 0x00010002 = 65538
    try std.testing.expectEqual(@as(u32, 0x00010002), entry.getCluster());
}

test "DirEntry attributes" {
    // Regular file
    var file_entry = DirEntry{
        .name = "TEST    TXT".*,
        .attributes = DirEntry.ATTR_ARCHIVE,
        .reserved = 0,
        .create_time_tenth = 0,
        .create_time = 0,
        .create_date = 0,
        .access_date = 0,
        .cluster_high = 0,
        .modify_time = 0,
        .modify_date = 0,
        .cluster_low = 2,
        .file_size = 1024,
    };
    try std.testing.expect(file_entry.isFile());
    try std.testing.expect(!file_entry.isDirectory());

    // Directory
    var dir_entry = file_entry;
    dir_entry.attributes = DirEntry.ATTR_DIRECTORY;
    try std.testing.expect(dir_entry.isDirectory());
    try std.testing.expect(!dir_entry.isFile());

    // Deleted entry
    var deleted_entry = file_entry;
    deleted_entry.name[0] = 0xE5;
    try std.testing.expect(deleted_entry.isDeleted());

    // End of directory
    var end_entry = file_entry;
    end_entry.name[0] = 0x00;
    try std.testing.expect(end_entry.isEndOfDir());
}

test "DirEntry long name marker" {
    const lfn_entry = DirEntry{
        .name = [_]u8{ 'T', 'E', 'S', 'T', ' ', ' ', ' ', ' ', 'T', 'X', 'T' },
        .attributes = DirEntry.ATTR_LONG_NAME,
        .reserved = 0,
        .create_time_tenth = 0,
        .create_time = 0,
        .create_date = 0,
        .access_date = 0,
        .cluster_high = 0,
        .modify_time = 0,
        .modify_date = 0,
        .cluster_low = 0,
        .file_size = 0,
    };

    // Long name entries have ATTR_LONG_NAME (0x0F)
    try std.testing.expectEqual(DirEntry.ATTR_LONG_NAME, lfn_entry.attributes);
}

test "FAT32 cluster to LBA calculation" {
    // Create a minimal Fat32 instance for testing
    var fs = Fat32{
        .partition_start = 2048,
        .bytes_per_sector = 512,
        .sectors_per_cluster = 8,
        .cluster_size = 4096,
        .fat_start = 2048 + 32,
        .fat_sectors = 1000,
        .num_fats = 2,
        .data_start = 2048 + 32 + 2000,
        .root_cluster = 2,
        .total_clusters = 100000,
    };

    // Cluster 2 should be at data_start + 0 (since cluster numbering starts at 2)
    try std.testing.expectEqual(fs.data_start, fs.clusterToLba(2));

    // Cluster 3 should be at data_start + sectors_per_cluster
    try std.testing.expectEqual(fs.data_start + 8, fs.clusterToLba(3));

    // Cluster 10 should be at data_start + 8 * sectors_per_cluster
    try std.testing.expectEqual(fs.data_start + 64, fs.clusterToLba(10));
}

test "FAT32 cluster size calculation" {
    // Verify cluster_size = bytes_per_sector * sectors_per_cluster
    const bytes_per_sector: u32 = 512;
    const sectors_per_cluster: u32 = 8;
    const expected_cluster_size = bytes_per_sector * sectors_per_cluster;

    try std.testing.expectEqual(@as(u32, 4096), expected_cluster_size);
}

test "File seek within bounds" {
    // Create mock Fat32 and File
    var fs = Fat32{
        .partition_start = 0,
        .bytes_per_sector = 512,
        .sectors_per_cluster = 8,
        .cluster_size = 4096,
        .fat_start = 32,
        .fat_sectors = 100,
        .num_fats = 2,
        .data_start = 232,
        .root_cluster = 2,
        .total_clusters = 1000,
    };

    var file = File{
        .fs = &fs,
        .first_cluster = 10,
        .current_cluster = 10,
        .file_size = 10000,
        .position = 0,
    };

    // tell() should return current position
    try std.testing.expectEqual(@as(u32, 0), file.tell());

    // size() should return file size
    try std.testing.expectEqual(@as(u32, 10000), file.size());
}

test "Directory rewind" {
    var fs = Fat32{
        .partition_start = 0,
        .bytes_per_sector = 512,
        .sectors_per_cluster = 8,
        .cluster_size = 4096,
        .fat_start = 32,
        .fat_sectors = 100,
        .num_fats = 2,
        .data_start = 232,
        .root_cluster = 2,
        .total_clusters = 1000,
    };

    var dir = Directory{
        .fs = &fs,
        .first_cluster = 5,
        .current_cluster = 10,
        .position = 50,
    };

    // Simulate having traversed directory
    dir.rewind();

    // After rewind, should be back at start
    try std.testing.expectEqual(@as(u32, 5), dir.current_cluster);
    try std.testing.expectEqual(@as(u32, 0), dir.position);
}

test "FAT entry values" {
    // FAT32 special cluster values
    const FREE_CLUSTER: u32 = 0x00000000;
    const RESERVED_START: u32 = 0x0FFFFFF0;
    const BAD_CLUSTER: u32 = 0x0FFFFFF7;
    const END_OF_CHAIN: u32 = 0x0FFFFFF8;

    try std.testing.expect(FREE_CLUSTER == 0);
    try std.testing.expect(BAD_CLUSTER < END_OF_CHAIN);
    try std.testing.expect(END_OF_CHAIN >= RESERVED_START);
}

test "8.3 filename parsing" {
    // Standard 8.3 filename: "FILENAME.EXT" stored as "FILENAMEEXT"
    const name_raw = "FILENAMEEXT".*;

    // First 8 chars are name, last 3 are extension
    const name_part = name_raw[0..8];
    const ext_part = name_raw[8..11];

    try std.testing.expect(std.mem.eql(u8, name_part, "FILENAME"));
    try std.testing.expect(std.mem.eql(u8, ext_part, "EXT"));
}

test "cluster chain constants" {
    // Minimum valid cluster number is 2
    const MIN_VALID_CLUSTER: u32 = 2;

    // Maximum valid cluster number (before reserved range)
    const MAX_VALID_CLUSTER: u32 = 0x0FFFFFEF;

    try std.testing.expect(MIN_VALID_CLUSTER < MAX_VALID_CLUSTER);
    try std.testing.expectEqual(@as(u32, 2), MIN_VALID_CLUSTER);
}
