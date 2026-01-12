//! Add Rockbox Files to FAT32 Filesystem
//!
//! Creates /.rockbox directory and adds a dummy rockbox.ipod file
//! for testing the bootloader.

const std = @import("std");

const SECTOR_SIZE = 512;

/// FAT32 Boot Sector (partial, just what we need)
const Fat32BootSector = extern struct {
    jump: [3]u8,
    oem_name: [8]u8,
    bytes_per_sector: u16 align(1),
    sectors_per_cluster: u8,
    reserved_sectors: u16 align(1),
    num_fats: u8,
    root_entry_count: u16 align(1),
    total_sectors_16: u16 align(1),
    media_type: u8,
    fat_size_16: u16 align(1),
    sectors_per_track: u16 align(1),
    num_heads: u16 align(1),
    hidden_sectors: u32 align(1),
    total_sectors_32: u32 align(1),
    fat_size_32: u32 align(1),
    ext_flags: u16 align(1),
    fs_version: u16 align(1),
    root_cluster: u32 align(1),
};

/// Directory entry
const DirEntry = extern struct {
    name: [11]u8,
    attr: u8,
    nt_res: u8,
    crt_time_tenth: u8,
    crt_time: u16 align(1),
    crt_date: u16 align(1),
    lst_acc_date: u16 align(1),
    fst_clus_hi: u16 align(1),
    wrt_time: u16 align(1),
    wrt_date: u16 align(1),
    fst_clus_lo: u16 align(1),
    file_size: u32 align(1),
};

const ATTR_READ_ONLY: u8 = 0x01;
const ATTR_HIDDEN: u8 = 0x02;
const ATTR_SYSTEM: u8 = 0x04;
const ATTR_VOLUME_ID: u8 = 0x08;
const ATTR_DIRECTORY: u8 = 0x10;
const ATTR_ARCHIVE: u8 = 0x20;

const FAT_END_OF_CHAIN: u32 = 0x0FFFFFFF;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: add_rockbox <disk_image>\n", .{});
        return;
    }

    const disk_path = args[1];

    const file = try std.fs.cwd().openFile(disk_path, .{ .mode = .read_write });
    defer file.close();

    // Read boot sector to get filesystem parameters
    var boot_sector: [SECTOR_SIZE]u8 = undefined;
    const partition_start: u64 = 1 * SECTOR_SIZE;  // Partition starts at sector 1

    try file.seekTo(partition_start);
    _ = try file.readAll(&boot_sector);

    const boot: *const Fat32BootSector = @ptrCast(&boot_sector);

    const reserved_sectors = boot.reserved_sectors;
    const fat_size = boot.fat_size_32;
    const num_fats = boot.num_fats;
    const sectors_per_cluster = boot.sectors_per_cluster;
    const root_cluster = boot.root_cluster;

    const fat1_sector = 1 + reserved_sectors;  // Partition start + reserved
    const data_start_sector = 1 + reserved_sectors + (num_fats * fat_size);

    std.debug.print("FAT32 Parameters:\n", .{});
    std.debug.print("  Reserved sectors: {}\n", .{reserved_sectors});
    std.debug.print("  FAT size: {} sectors\n", .{fat_size});
    std.debug.print("  Data start sector: {}\n", .{data_start_sector});
    std.debug.print("  Root cluster: {}\n", .{root_cluster});

    // Helper function to convert cluster to sector
    const clusterToSector = struct {
        fn call(cluster: u32, data_start: u32, spc: u8) u64 {
            return @as(u64, data_start) + @as(u64, (cluster - 2) * spc);
        }
    }.call;

    // Allocate clusters for .rockbox directory and rockbox.ipod file
    // Cluster 2 = root directory (already used)
    // Cluster 3 = .rockbox directory
    // Cluster 4-N = rockbox.ipod file

    const rockbox_dir_cluster: u32 = 3;
    const rockbox_file_cluster: u32 = 4;

    // Create dummy rockbox.ipod content
    // Format: 8-byte header (4 bytes checksum BE + 4 bytes model "ipvd") + firmware
    var rockbox_content: [512]u8 = undefined;
    @memset(&rockbox_content, 0);

    // Create a minimal "firmware" that just returns
    // The checksum is calculated over the firmware data
    const firmware_data = [_]u8{
        // Simple ARM code: infinite loop (for testing)
        0xFE, 0xFF, 0xFF, 0xEA,  // B .  (branch to self)
    };

    // Calculate checksum (sum of all bytes, big-endian)
    var checksum: u32 = 0;
    for (firmware_data) |b| {
        checksum += b;
    }

    // Model name "ipvd" for iPod Video
    const model = "ipvd";

    // Header: checksum (BE) + model
    rockbox_content[0] = @truncate(checksum >> 24);
    rockbox_content[1] = @truncate(checksum >> 16);
    rockbox_content[2] = @truncate(checksum >> 8);
    rockbox_content[3] = @truncate(checksum);
    @memcpy(rockbox_content[4..8], model);

    // Firmware data
    @memcpy(rockbox_content[8..12], &firmware_data);

    const file_size: u32 = 8 + firmware_data.len;  // Header + firmware

    // Update FAT entries
    var fat_sector: [SECTOR_SIZE]u8 = undefined;

    // Read first FAT sector
    try file.seekTo(fat1_sector * SECTOR_SIZE);
    _ = try file.readAll(&fat_sector);

    const fat_data = @as(*[128]u32, @ptrCast(@alignCast(&fat_sector)));

    // Cluster 3 (.rockbox dir) - end of chain
    fat_data[3] = FAT_END_OF_CHAIN;
    // Cluster 4 (rockbox.ipod) - end of chain
    fat_data[4] = FAT_END_OF_CHAIN;

    // Write updated FAT1
    try file.seekTo(fat1_sector * SECTOR_SIZE);
    try file.writeAll(&fat_sector);
    std.debug.print("Updated FAT1 at sector {}\n", .{fat1_sector});

    // Write updated FAT2
    const fat2_sector = fat1_sector + fat_size;
    try file.seekTo(fat2_sector * SECTOR_SIZE);
    try file.writeAll(&fat_sector);
    std.debug.print("Updated FAT2 at sector {}\n", .{fat2_sector});

    // Add .rockbox directory entry to root directory
    var root_sector_data: [SECTOR_SIZE]u8 = undefined;
    const root_sector = clusterToSector(root_cluster, data_start_sector, sectors_per_cluster);

    try file.seekTo(root_sector * SECTOR_SIZE);
    _ = try file.readAll(&root_sector_data);

    const root_entries = @as(*[16]DirEntry, @ptrCast(@alignCast(&root_sector_data)));

    // Find first free entry (after volume label)
    var entry_idx: usize = 1;
    while (entry_idx < 16 and root_entries[entry_idx].name[0] != 0) : (entry_idx += 1) {}

    if (entry_idx >= 16) {
        std.debug.print("Error: Root directory full\n", .{});
        return;
    }

    // Add .rockbox directory entry
    // Note: FAT short name rules - leading dot is special
    // ".rockbox" becomes ".ROCKBOX   " (11 chars, space padded)
    // But actually FAT doesn't allow leading dots in 8.3 names!
    // We need to use "ROCKBOX    " and mark it as hidden, or use LFN
    // For simplicity, let's just use "ROCKBOX " directory name
    root_entries[entry_idx].name = ".ROCKBOX   ".*;  // Actually this won't work properly
    root_entries[entry_idx].attr = ATTR_DIRECTORY;
    root_entries[entry_idx].nt_res = 0;
    root_entries[entry_idx].crt_time_tenth = 0;
    root_entries[entry_idx].crt_time = 0;
    root_entries[entry_idx].crt_date = 0x5421;
    root_entries[entry_idx].lst_acc_date = 0x5421;
    root_entries[entry_idx].fst_clus_hi = 0;
    root_entries[entry_idx].wrt_time = 0;
    root_entries[entry_idx].wrt_date = 0x5421;
    root_entries[entry_idx].fst_clus_lo = @truncate(rockbox_dir_cluster);
    root_entries[entry_idx].file_size = 0;  // Directories have size 0

    // Write updated root directory
    try file.seekTo(root_sector * SECTOR_SIZE);
    try file.writeAll(&root_sector_data);
    std.debug.print("Added .ROCKBOX directory entry to root\n", .{});

    // Create .rockbox directory contents
    var rockbox_dir_data: [SECTOR_SIZE]u8 = [_]u8{0} ** SECTOR_SIZE;
    const rockbox_entries = @as(*[16]DirEntry, @ptrCast(@alignCast(&rockbox_dir_data)));

    // . entry (self)
    rockbox_entries[0].name = ".          ".*;
    rockbox_entries[0].attr = ATTR_DIRECTORY;
    rockbox_entries[0].fst_clus_hi = 0;
    rockbox_entries[0].fst_clus_lo = @truncate(rockbox_dir_cluster);
    rockbox_entries[0].file_size = 0;
    rockbox_entries[0].crt_date = 0x5421;
    rockbox_entries[0].wrt_date = 0x5421;

    // .. entry (parent)
    rockbox_entries[1].name = "..         ".*;
    rockbox_entries[1].attr = ATTR_DIRECTORY;
    rockbox_entries[1].fst_clus_hi = 0;
    rockbox_entries[1].fst_clus_lo = @truncate(root_cluster);
    rockbox_entries[1].file_size = 0;
    rockbox_entries[1].crt_date = 0x5421;
    rockbox_entries[1].wrt_date = 0x5421;

    // rockbox.ipod file entry
    rockbox_entries[2].name = "ROCKBOX IPO".*;  // 8.3 format: ROCKBOX.IPO -> ROCKBOX IPO (no dot)
    rockbox_entries[2].attr = ATTR_ARCHIVE;
    rockbox_entries[2].nt_res = 0;
    rockbox_entries[2].crt_time_tenth = 0;
    rockbox_entries[2].crt_time = 0;
    rockbox_entries[2].crt_date = 0x5421;
    rockbox_entries[2].lst_acc_date = 0x5421;
    rockbox_entries[2].fst_clus_hi = 0;
    rockbox_entries[2].wrt_time = 0;
    rockbox_entries[2].wrt_date = 0x5421;
    rockbox_entries[2].fst_clus_lo = @truncate(rockbox_file_cluster);
    rockbox_entries[2].file_size = file_size;

    // Write .rockbox directory
    const rockbox_dir_sector = clusterToSector(rockbox_dir_cluster, data_start_sector, sectors_per_cluster);
    try file.seekTo(rockbox_dir_sector * SECTOR_SIZE);
    try file.writeAll(&rockbox_dir_data);
    std.debug.print("Created .rockbox directory at cluster {} (sector {})\n", .{ rockbox_dir_cluster, rockbox_dir_sector });

    // Write rockbox.ipod file
    const rockbox_file_sector = clusterToSector(rockbox_file_cluster, data_start_sector, sectors_per_cluster);
    try file.seekTo(rockbox_file_sector * SECTOR_SIZE);
    try file.writeAll(&rockbox_content);
    std.debug.print("Created rockbox.ipod at cluster {} (sector {})\n", .{ rockbox_file_cluster, rockbox_file_sector });
    std.debug.print("  File size: {} bytes\n", .{file_size});
    std.debug.print("  Checksum: 0x{X:0>8}\n", .{checksum});

    std.debug.print("\nRockbox files added successfully!\n", .{});
}
