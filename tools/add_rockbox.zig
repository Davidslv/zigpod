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
const ATTR_LFN: u8 = 0x0F; // Long File Name entry

const FAT_END_OF_CHAIN: u32 = 0x0FFFFFFF;

/// Long File Name directory entry structure
const LfnEntry = extern struct {
    seq_num: u8,           // Sequence number (last entry | 0x40)
    name1: [10]u8,         // Characters 1-5 (UCS-2)
    attr: u8,              // Always 0x0F for LFN
    reserved: u8,          // Always 0
    checksum: u8,          // Checksum of short name
    name2: [12]u8,         // Characters 6-11 (UCS-2)
    cluster: u16 align(1), // Always 0
    name3: [4]u8,          // Characters 12-13 (UCS-2)
};

/// Calculate LFN checksum for 8.3 short name
fn lfnChecksum(name: *const [11]u8) u8 {
    var sum: u8 = 0;
    for (name) |byte| {
        // Rotate right by 1 and add
        sum = ((sum >> 1) | ((sum & 1) << 7)) +% byte;
    }
    return sum;
}

/// Write UCS-2 character at position in LFN entry
fn writeUcs2Char(dest: []u8, pos: usize, char: u8) void {
    if (pos * 2 < dest.len) {
        dest[pos * 2] = char;
        if (pos * 2 + 1 < dest.len) {
            dest[pos * 2 + 1] = 0; // High byte is 0 for ASCII
        }
    }
}

/// Write UCS-2 null terminator
fn writeUcs2Null(dest: []u8, pos: usize) void {
    if (pos * 2 < dest.len) {
        dest[pos * 2] = 0;
        if (pos * 2 + 1 < dest.len) {
            dest[pos * 2 + 1] = 0;
        }
    }
}

/// Fill remaining with 0xFF
fn fillUcs2Padding(dest: []u8, start_pos: usize, end_chars: usize) void {
    var pos = start_pos;
    while (pos < end_chars) : (pos += 1) {
        if (pos * 2 < dest.len) {
            dest[pos * 2] = 0xFF;
            if (pos * 2 + 1 < dest.len) {
                dest[pos * 2 + 1] = 0xFF;
            }
        }
    }
}

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

    // Add .rockbox directory entry with LFN
    // FAT 8.3 format doesn't support leading dots for regular entries
    // So we need: LFN entry with ".rockbox" + short name "ROCKBO~1   "

    // Short name for .rockbox (without leading dot, 8.3 format)
    const rockbox_dir_short: [11]u8 = "ROCKBO~1   ".*;
    const rockbox_dir_lfn_checksum = lfnChecksum(&rockbox_dir_short);

    // Entry 1: LFN entry for ".rockbox" (8 chars fits in 1 entry)
    const lfn_dir_entry = @as(*LfnEntry, @ptrCast(@alignCast(&root_sector_data[entry_idx * 32])));
    lfn_dir_entry.seq_num = 0x41; // Sequence 1 with last flag
    lfn_dir_entry.attr = ATTR_LFN;
    lfn_dir_entry.reserved = 0;
    lfn_dir_entry.checksum = rockbox_dir_lfn_checksum;
    lfn_dir_entry.cluster = 0;

    // Fill ".rockbox" into LFN entry (8 chars)
    const rockbox_dirname = ".rockbox";
    writeUcs2Char(&lfn_dir_entry.name1, 0, rockbox_dirname[0]); // '.'
    writeUcs2Char(&lfn_dir_entry.name1, 1, rockbox_dirname[1]); // 'r'
    writeUcs2Char(&lfn_dir_entry.name1, 2, rockbox_dirname[2]); // 'o'
    writeUcs2Char(&lfn_dir_entry.name1, 3, rockbox_dirname[3]); // 'c'
    writeUcs2Char(&lfn_dir_entry.name1, 4, rockbox_dirname[4]); // 'k'

    writeUcs2Char(&lfn_dir_entry.name2, 0, rockbox_dirname[5]); // 'b'
    writeUcs2Char(&lfn_dir_entry.name2, 1, rockbox_dirname[6]); // 'o'
    writeUcs2Char(&lfn_dir_entry.name2, 2, rockbox_dirname[7]); // 'x'
    writeUcs2Null(&lfn_dir_entry.name2, 3);  // null terminator
    fillUcs2Padding(&lfn_dir_entry.name2, 4, 6);  // Fill rest with 0xFFFF

    fillUcs2Padding(&lfn_dir_entry.name3, 0, 2);  // Fill with 0xFFFF

    entry_idx += 1;

    // Entry 2: 8.3 short name entry
    root_entries[entry_idx].name = rockbox_dir_short;
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

    // rockbox.ipod file entry with Long File Name support
    // The filename "rockbox.ipod" has 12 characters, requiring 1 LFN entry
    // 8.3 short name: "ROCKBO~1" + "IPO" (since "ipod" is 4 chars, truncated)
    const short_name: [11]u8 = "ROCKBO~1IPO".*;
    const lfn_checksum = lfnChecksum(&short_name);

    // Entry 2: LFN entry for "rockbox.ipod" (12 chars fits in 1 LFN entry)
    const lfn_entry = @as(*LfnEntry, @ptrCast(@alignCast(&rockbox_dir_data[2 * 32])));
    lfn_entry.seq_num = 0x41; // Sequence 1 with last flag (0x40)
    lfn_entry.attr = ATTR_LFN;
    lfn_entry.reserved = 0;
    lfn_entry.checksum = lfn_checksum;
    lfn_entry.cluster = 0;

    // Fill name1 with first 5 chars: "r", "o", "c", "k", "b" (UCS-2)
    const filename = "rockbox.ipod";
    writeUcs2Char(&lfn_entry.name1, 0, filename[0]);  // 'r'
    writeUcs2Char(&lfn_entry.name1, 1, filename[1]);  // 'o'
    writeUcs2Char(&lfn_entry.name1, 2, filename[2]);  // 'c'
    writeUcs2Char(&lfn_entry.name1, 3, filename[3]);  // 'k'
    writeUcs2Char(&lfn_entry.name1, 4, filename[4]);  // 'b'

    // Fill name2 with next 6 chars: "o", "x", ".", "i", "p", "o" (UCS-2)
    writeUcs2Char(&lfn_entry.name2, 0, filename[5]);  // 'o'
    writeUcs2Char(&lfn_entry.name2, 1, filename[6]);  // 'x'
    writeUcs2Char(&lfn_entry.name2, 2, filename[7]);  // '.'
    writeUcs2Char(&lfn_entry.name2, 3, filename[8]);  // 'i'
    writeUcs2Char(&lfn_entry.name2, 4, filename[9]);  // 'p'
    writeUcs2Char(&lfn_entry.name2, 5, filename[10]); // 'o'

    // Fill name3 with last 2 chars: "d", null (UCS-2)
    writeUcs2Char(&lfn_entry.name3, 0, filename[11]); // 'd'
    writeUcs2Null(&lfn_entry.name3, 1);               // null terminator

    // Entry 3: 8.3 short name entry (after LFN entry)
    rockbox_entries[3].name = short_name;
    rockbox_entries[3].attr = ATTR_ARCHIVE;
    rockbox_entries[3].nt_res = 0;
    rockbox_entries[3].crt_time_tenth = 0;
    rockbox_entries[3].crt_time = 0;
    rockbox_entries[3].crt_date = 0x5421;
    rockbox_entries[3].lst_acc_date = 0x5421;
    rockbox_entries[3].fst_clus_hi = 0;
    rockbox_entries[3].wrt_time = 0;
    rockbox_entries[3].wrt_date = 0x5421;
    rockbox_entries[3].fst_clus_lo = @truncate(rockbox_file_cluster);
    rockbox_entries[3].file_size = file_size;

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
