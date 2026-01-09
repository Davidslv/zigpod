//! Mock FAT32 Filesystem
//!
//! Creates an in-memory FAT32 filesystem populated with files from the host
//! filesystem (e.g., audio-samples directory). This allows testing the file
//! browser, music library scanning, and audio playback in the simulator
//! without needing a real disk image.

const std = @import("std");
const disk_image = @import("disk_image.zig");

/// FAT32 Boot Sector structure
const Fat32BootSector = extern struct {
    jump_boot: [3]u8,
    oem_name: [8]u8,
    bytes_per_sector: u16 align(1),
    sectors_per_cluster: u8,
    reserved_sector_count: u16 align(1),
    num_fats: u8,
    root_entry_count: u16 align(1), // 0 for FAT32
    total_sectors_16: u16 align(1), // 0 for FAT32
    media: u8,
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
    fs_info: u16 align(1),
    backup_boot_sector: u16 align(1),
    reserved: [12]u8,
    drive_number: u8,
    reserved1: u8,
    boot_sig: u8,
    volume_id: u32 align(1),
    volume_label: [11]u8,
    fs_type: [8]u8,
    // Boot code and signature would follow
};

/// FAT32 Directory Entry structure
const DirEntry = extern struct {
    name: [11]u8,
    attr: u8,
    nt_res: u8,
    crt_time_tenth: u8,
    crt_time: u16 align(1),
    crt_date: u16 align(1),
    lst_acc_date: u16 align(1),
    first_cluster_hi: u16 align(1),
    wrt_time: u16 align(1),
    wrt_date: u16 align(1),
    first_cluster_lo: u16 align(1),
    file_size: u32 align(1),

    const ATTR_READ_ONLY = 0x01;
    const ATTR_HIDDEN = 0x02;
    const ATTR_SYSTEM = 0x04;
    const ATTR_VOLUME_ID = 0x08;
    const ATTR_DIRECTORY = 0x10;
    const ATTR_ARCHIVE = 0x20;
    const ATTR_LONG_NAME = 0x0F;
};

/// Mock FAT32 filesystem builder
pub const MockFat32 = struct {
    disk: *disk_image.DiskImage,
    allocator: std.mem.Allocator,

    // Filesystem parameters
    bytes_per_sector: u16 = 512,
    sectors_per_cluster: u8 = 8, // 4KB clusters
    reserved_sectors: u16 = 32,
    num_fats: u8 = 2,
    fat_size_sectors: u32 = 0,
    root_cluster: u32 = 2,
    data_start_sector: u32 = 0,
    total_clusters: u32 = 0,

    // Current allocation state
    next_free_cluster: u32 = 3, // Start after root dir cluster

    const Self = @This();

    /// Format a disk image as FAT32
    pub fn format(disk: *disk_image.DiskImage, allocator: std.mem.Allocator) !Self {
        var self = Self{
            .disk = disk,
            .allocator = allocator,
        };

        const total_sectors = disk.total_sectors;

        // Calculate FAT size
        // FAT32 needs 4 bytes per cluster entry
        // total_clusters = (total_sectors - reserved - fat_sectors * 2) / sectors_per_cluster
        // fat_size = total_clusters * 4 / bytes_per_sector
        // This is iterative but for simplicity:
        const data_sectors = total_sectors - self.reserved_sectors;
        const estimated_clusters = data_sectors / self.sectors_per_cluster;
        self.fat_size_sectors = @intCast((estimated_clusters * 4 + 511) / 512);

        self.data_start_sector = self.reserved_sectors + (self.fat_size_sectors * self.num_fats);
        self.total_clusters = @intCast((total_sectors - self.data_start_sector) / self.sectors_per_cluster);

        // Write boot sector
        try self.writeBootSector();

        // Initialize FAT tables
        try self.initializeFat();

        // Create root directory
        try self.createRootDirectory();

        return self;
    }

    fn writeBootSector(self: *Self) !void {
        var boot: Fat32BootSector = std.mem.zeroes(Fat32BootSector);

        boot.jump_boot = .{ 0xEB, 0x58, 0x90 }; // Jump instruction
        @memcpy(&boot.oem_name, "ZIGPOD  ");
        boot.bytes_per_sector = self.bytes_per_sector;
        boot.sectors_per_cluster = self.sectors_per_cluster;
        boot.reserved_sector_count = self.reserved_sectors;
        boot.num_fats = self.num_fats;
        boot.root_entry_count = 0; // FAT32
        boot.total_sectors_16 = 0; // FAT32
        boot.media = 0xF8; // Fixed disk
        boot.fat_size_16 = 0; // FAT32
        boot.sectors_per_track = 63;
        boot.num_heads = 255;
        boot.hidden_sectors = 0;
        boot.total_sectors_32 = @intCast(self.disk.total_sectors);
        boot.fat_size_32 = self.fat_size_sectors;
        boot.ext_flags = 0;
        boot.fs_version = 0;
        boot.root_cluster = self.root_cluster;
        boot.fs_info = 1;
        boot.backup_boot_sector = 6;
        boot.drive_number = 0x80;
        boot.boot_sig = 0x29;
        boot.volume_id = 0x12345678;
        @memcpy(&boot.volume_label, "ZIGPOD DISK");
        @memcpy(&boot.fs_type, "FAT32   ");

        // Write boot sector
        var sector: [512]u8 = std.mem.zeroes([512]u8);
        const boot_bytes = std.mem.asBytes(&boot);
        @memcpy(sector[0..@sizeOf(Fat32BootSector)], boot_bytes);
        sector[510] = 0x55;
        sector[511] = 0xAA;

        try self.disk.writeSectors(0, 1, &sector);

        // Write FSInfo sector
        var fsinfo: [512]u8 = std.mem.zeroes([512]u8);
        fsinfo[0] = 0x52; // RRaA signature
        fsinfo[1] = 0x52;
        fsinfo[2] = 0x61;
        fsinfo[3] = 0x41;
        fsinfo[484] = 0x72; // rrAa
        fsinfo[485] = 0x72;
        fsinfo[486] = 0x41;
        fsinfo[487] = 0x61;
        // Free cluster count (unknown = 0xFFFFFFFF)
        fsinfo[488] = 0xFF;
        fsinfo[489] = 0xFF;
        fsinfo[490] = 0xFF;
        fsinfo[491] = 0xFF;
        // Next free cluster
        fsinfo[492] = @truncate(self.next_free_cluster);
        fsinfo[493] = @truncate(self.next_free_cluster >> 8);
        fsinfo[494] = @truncate(self.next_free_cluster >> 16);
        fsinfo[495] = @truncate(self.next_free_cluster >> 24);
        fsinfo[510] = 0x55;
        fsinfo[511] = 0xAA;

        try self.disk.writeSectors(1, 1, &fsinfo);

        // Write backup boot sector
        try self.disk.writeSectors(6, 1, &sector);
    }

    fn initializeFat(self: *Self) !void {
        // Clear FAT
        var zero_sector: [512]u8 = std.mem.zeroes([512]u8);

        for (0..self.num_fats) |fat_idx| {
            const fat_start = self.reserved_sectors + @as(u32, @intCast(fat_idx)) * self.fat_size_sectors;
            for (0..self.fat_size_sectors) |i| {
                try self.disk.writeSectors(fat_start + @as(u32, @intCast(i)), 1, &zero_sector);
            }
        }

        // Initialize first few FAT entries
        // Entry 0: Media type (0x0FFFFFF8)
        // Entry 1: End of chain marker (0x0FFFFFFF)
        // Entry 2: Root directory (end of chain initially)
        try self.setFatEntry(0, 0x0FFFFFF8);
        try self.setFatEntry(1, 0x0FFFFFFF);
        try self.setFatEntry(2, 0x0FFFFFFF); // Root dir is single cluster for now
    }

    fn createRootDirectory(self: *Self) !void {
        // Create empty root directory cluster
        const cluster_size = @as(usize, self.sectors_per_cluster) * self.bytes_per_sector;
        const zero_cluster = try self.allocator.alloc(u8, cluster_size);
        defer self.allocator.free(zero_cluster);
        @memset(zero_cluster, 0);

        try self.writeCluster(self.root_cluster, zero_cluster);
    }

    /// Set a FAT entry value
    fn setFatEntry(self: *Self, cluster: u32, value: u32) !void {
        const fat_offset = cluster * 4;
        const fat_sector = self.reserved_sectors + @as(u32, @intCast(fat_offset / 512));
        const entry_offset = fat_offset % 512;

        var sector: [512]u8 = undefined;
        try self.disk.readSectors(fat_sector, 1, &sector);

        sector[entry_offset] = @truncate(value);
        sector[entry_offset + 1] = @truncate(value >> 8);
        sector[entry_offset + 2] = @truncate(value >> 16);
        sector[entry_offset + 3] = @truncate(value >> 24);

        // Write to both FATs
        try self.disk.writeSectors(fat_sector, 1, &sector);
        try self.disk.writeSectors(fat_sector + self.fat_size_sectors, 1, &sector);
    }

    /// Write data to a cluster
    fn writeCluster(self: *Self, cluster: u32, data: []const u8) !void {
        const sector = self.data_start_sector + (cluster - 2) * self.sectors_per_cluster;
        const sectors_to_write: u16 = @intCast(@min(
            (data.len + 511) / 512,
            self.sectors_per_cluster,
        ));

        // Pad to sector boundary
        const cluster_size = @as(usize, self.sectors_per_cluster) * 512;
        const buffer = try self.allocator.alloc(u8, cluster_size);
        defer self.allocator.free(buffer);
        @memset(buffer, 0);
        @memcpy(buffer[0..@min(data.len, cluster_size)], data[0..@min(data.len, cluster_size)]);

        try self.disk.writeSectors(sector, sectors_to_write, buffer[0 .. sectors_to_write * 512]);
    }

    /// Allocate a new cluster
    fn allocateCluster(self: *Self) !u32 {
        const cluster = self.next_free_cluster;
        if (cluster >= self.total_clusters + 2) {
            return error.DiskFull;
        }
        self.next_free_cluster += 1;
        try self.setFatEntry(cluster, 0x0FFFFFFF); // End of chain
        return cluster;
    }

    /// Convert filename to 8.3 format
    fn toShortName(name: []const u8) [11]u8 {
        var short: [11]u8 = [_]u8{' '} ** 11;

        // Find extension
        var ext_start: ?usize = null;
        var i: usize = name.len;
        while (i > 0) {
            i -= 1;
            if (name[i] == '.') {
                ext_start = i;
                break;
            }
        }

        // Copy name part (up to 8 chars)
        const name_end = ext_start orelse name.len;
        const name_len = @min(name_end, 8);
        for (0..name_len) |j| {
            short[j] = std.ascii.toUpper(name[j]);
        }

        // Copy extension (up to 3 chars)
        if (ext_start) |ext| {
            const ext_len = @min(name.len - ext - 1, 3);
            for (0..ext_len) |j| {
                short[8 + j] = std.ascii.toUpper(name[ext + 1 + j]);
            }
        }

        return short;
    }

    /// Create a directory in a parent cluster
    pub fn createDirectory(self: *Self, parent_cluster: u32, name: []const u8) !u32 {
        // Allocate cluster for new directory
        const new_cluster = try self.allocateCluster();

        // Create directory entry in parent
        var entry: DirEntry = std.mem.zeroes(DirEntry);
        entry.name = toShortName(name);
        entry.attr = DirEntry.ATTR_DIRECTORY;
        entry.first_cluster_hi = @truncate(new_cluster >> 16);
        entry.first_cluster_lo = @truncate(new_cluster);
        entry.wrt_time = 0x0000;
        entry.wrt_date = 0x4C21; // 2018-01-01

        try self.addDirectoryEntry(parent_cluster, &entry);

        // Initialize the new directory with . and .. entries
        const cluster_size = @as(usize, self.sectors_per_cluster) * 512;
        const dir_data = try self.allocator.alloc(u8, cluster_size);
        defer self.allocator.free(dir_data);
        @memset(dir_data, 0);

        // . entry
        var dot_entry: DirEntry = entry;
        dot_entry.name = ".          ".*;
        @memcpy(dir_data[0..32], std.mem.asBytes(&dot_entry));

        // .. entry
        var dotdot_entry: DirEntry = std.mem.zeroes(DirEntry);
        dotdot_entry.name = "..         ".*;
        dotdot_entry.attr = DirEntry.ATTR_DIRECTORY;
        dotdot_entry.first_cluster_hi = @truncate(parent_cluster >> 16);
        dotdot_entry.first_cluster_lo = @truncate(parent_cluster);
        dotdot_entry.wrt_date = 0x4C21;
        @memcpy(dir_data[32..64], std.mem.asBytes(&dotdot_entry));

        try self.writeCluster(new_cluster, dir_data);

        return new_cluster;
    }

    /// Add a file to a directory
    pub fn addFile(self: *Self, parent_cluster: u32, name: []const u8, data: []const u8) !void {
        // Calculate clusters needed
        const cluster_size = @as(usize, self.sectors_per_cluster) * 512;
        const clusters_needed = (data.len + cluster_size - 1) / cluster_size;

        if (clusters_needed == 0) {
            // Empty file
            var entry: DirEntry = std.mem.zeroes(DirEntry);
            entry.name = toShortName(name);
            entry.attr = DirEntry.ATTR_ARCHIVE;
            entry.file_size = 0;
            entry.wrt_date = 0x4C21;
            try self.addDirectoryEntry(parent_cluster, &entry);
            return;
        }

        // Allocate clusters and write data
        var first_cluster: u32 = 0;
        var prev_cluster: u32 = 0;
        var data_offset: usize = 0;

        for (0..clusters_needed) |_| {
            const cluster = try self.allocateCluster();

            if (first_cluster == 0) {
                first_cluster = cluster;
            } else {
                // Link previous cluster to this one
                try self.setFatEntry(prev_cluster, cluster);
            }
            prev_cluster = cluster;

            // Write data to cluster
            const chunk_size = @min(cluster_size, data.len - data_offset);
            const chunk = try self.allocator.alloc(u8, cluster_size);
            defer self.allocator.free(chunk);
            @memset(chunk, 0);
            @memcpy(chunk[0..chunk_size], data[data_offset..][0..chunk_size]);
            try self.writeCluster(cluster, chunk);

            data_offset += chunk_size;
        }

        // Create directory entry
        var entry: DirEntry = std.mem.zeroes(DirEntry);
        entry.name = toShortName(name);
        entry.attr = DirEntry.ATTR_ARCHIVE;
        entry.first_cluster_hi = @truncate(first_cluster >> 16);
        entry.first_cluster_lo = @truncate(first_cluster);
        entry.file_size = @intCast(data.len);
        entry.wrt_date = 0x4C21;

        try self.addDirectoryEntry(parent_cluster, &entry);
    }

    /// Add an entry to a directory
    fn addDirectoryEntry(self: *Self, dir_cluster: u32, entry: *const DirEntry) !void {
        const cluster_size = @as(usize, self.sectors_per_cluster) * 512;
        const dir_data = try self.allocator.alloc(u8, cluster_size);
        defer self.allocator.free(dir_data);

        // Read current directory cluster
        const sector = self.data_start_sector + (dir_cluster - 2) * self.sectors_per_cluster;
        try self.disk.readSectors(sector, self.sectors_per_cluster, dir_data);

        // Find free entry
        var offset: usize = 0;
        while (offset < cluster_size) : (offset += 32) {
            if (dir_data[offset] == 0x00 or dir_data[offset] == 0xE5) {
                // Free entry found
                @memcpy(dir_data[offset..][0..32], std.mem.asBytes(entry));
                try self.writeCluster(dir_cluster, dir_data);
                return;
            }
        }

        return error.DirectoryFull;
    }

    /// Populate filesystem from host directory
    pub fn populateFromHost(self: *Self, host_path: []const u8, target_cluster: u32) !void {
        // Open directory (works with both absolute and relative paths)
        var dir = std.fs.cwd().openDir(host_path, .{ .iterate = true }) catch |err| {
            std.debug.print("Cannot open host directory {s}: {}\n", .{ host_path, err });
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            // Skip hidden files
            if (entry.name[0] == '.') continue;

            // Skip large files (for simulator testing, limit to 50MB)
            const MAX_FILE_SIZE = 50 * 1024 * 1024;

            if (entry.kind == .file) {
                // Check if it's an audio file
                if (isAudioFile(entry.name)) {
                    const file = dir.openFile(entry.name, .{}) catch continue;
                    defer file.close();

                    const stat = file.stat() catch continue;
                    if (stat.size > MAX_FILE_SIZE) {
                        std.debug.print("Skipping large file: {s} ({d} MB)\n", .{
                            entry.name,
                            stat.size / (1024 * 1024),
                        });
                        continue;
                    }

                    const data = file.readToEndAlloc(self.allocator, MAX_FILE_SIZE) catch continue;
                    defer self.allocator.free(data);

                    std.debug.print("Adding file: {s} ({d} bytes)\n", .{ entry.name, data.len });
                    self.addFile(target_cluster, entry.name, data) catch |err| {
                        std.debug.print("  Failed to add: {}\n", .{err});
                    };
                }
            } else if (entry.kind == .directory) {
                // Recurse into subdirectory
                const sub_cluster = self.createDirectory(target_cluster, entry.name) catch continue;
                // Build sub path
                var path_buf: [512]u8 = undefined;
                const sub_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ host_path, entry.name }) catch continue;
                self.populateFromHost(sub_path, sub_cluster) catch {};
            }
        }
    }

    fn isAudioFile(name: []const u8) bool {
        const extensions = [_][]const u8{ ".mp3", ".wav", ".flac", ".aiff", ".aif", ".m4a", ".ogg" };
        const lower_name = name;
        for (extensions) |ext| {
            if (lower_name.len > ext.len) {
                const file_ext = lower_name[lower_name.len - ext.len ..];
                var matches = true;
                for (0..ext.len) |i| {
                    if (std.ascii.toLower(file_ext[i]) != ext[i]) {
                        matches = false;
                        break;
                    }
                }
                if (matches) return true;
            }
        }
        return false;
    }
};

/// Create a mock FAT32 disk populated with audio samples
pub fn createMockDiskWithAudioSamples(
    allocator: std.mem.Allocator,
    audio_samples_path: []const u8,
) !disk_image.DiskImage {
    // Create 256MB in-memory disk (enough for audio samples)
    const sectors = 256 * 1024 * 1024 / 512;
    var disk = try disk_image.DiskImage.createInMemory(allocator, sectors);

    // Format as FAT32
    var mock_fs = try MockFat32.format(&disk, allocator);

    // Create /MUSIC directory
    const music_cluster = try mock_fs.createDirectory(mock_fs.root_cluster, "MUSIC");

    // Populate from host audio-samples directory
    try mock_fs.populateFromHost(audio_samples_path, music_cluster);

    return disk;
}

// ============================================================
// Tests
// ============================================================

test "format FAT32" {
    const allocator = std.testing.allocator;

    var disk = try disk_image.DiskImage.createInMemory(allocator, 1000);
    defer disk.close();

    _ = try MockFat32.format(&disk, allocator);

    // Read boot sector and verify
    var sector: [512]u8 = undefined;
    try disk.readSectors(0, 1, &sector);

    // Check signature
    try std.testing.expectEqual(@as(u8, 0x55), sector[510]);
    try std.testing.expectEqual(@as(u8, 0xAA), sector[511]);

    // Check OEM name
    try std.testing.expectEqualStrings("ZIGPOD  ", sector[3..11]);
}

test "create directory" {
    const allocator = std.testing.allocator;

    var disk = try disk_image.DiskImage.createInMemory(allocator, 2000);
    defer disk.close();

    var mock_fs = try MockFat32.format(&disk, allocator);

    // Create a directory
    const dir_cluster = try mock_fs.createDirectory(mock_fs.root_cluster, "MUSIC");

    // Verify cluster was allocated
    try std.testing.expect(dir_cluster > 2);
}

test "add file" {
    const allocator = std.testing.allocator;

    var disk = try disk_image.DiskImage.createInMemory(allocator, 5000);
    defer disk.close();

    var mock_fs = try MockFat32.format(&disk, allocator);

    // Add a small test file
    const test_data = "Hello, ZigPod!";
    try mock_fs.addFile(mock_fs.root_cluster, "TEST.TXT", test_data);
}

test "short name conversion" {
    const result1 = MockFat32.toShortName("hello.txt");
    try std.testing.expectEqualStrings("HELLO   TXT", &result1);

    const result2 = MockFat32.toShortName("SONG.MP3");
    try std.testing.expectEqualStrings("SONG    MP3", &result2);

    // "very-long-filename" is >8 chars, truncates to "VERY-LON" (8 chars)
    const result3 = MockFat32.toShortName("very-long-filename.wav");
    try std.testing.expectEqualStrings("VERY-LONWAV", &result3);
}

test "is audio file" {
    try std.testing.expect(MockFat32.isAudioFile("song.mp3"));
    try std.testing.expect(MockFat32.isAudioFile("track.WAV"));
    try std.testing.expect(MockFat32.isAudioFile("music.flac"));
    try std.testing.expect(!MockFat32.isAudioFile("document.txt"));
    try std.testing.expect(!MockFat32.isAudioFile("image.png"));
}
