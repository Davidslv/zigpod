//! Simple Rockbox File Adder - 8.3 Names Only
//!
//! Creates a rockbox.ipod file in root using ONLY 8.3 short name.
//! No LFN entries, no subdirectories.
//! This is for debugging filesystem issues.

const std = @import("std");

const SECTOR_SIZE = 512;

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

const ATTR_ARCHIVE: u8 = 0x20;
const FAT_END_OF_CHAIN: u32 = 0x0FFFFFFF;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: add_rockbox_simple <disk_image>\n", .{});
        return;
    }

    const disk_path = args[1];

    const file = try std.fs.cwd().openFile(disk_path, .{ .mode = .read_write });
    defer file.close();

    // Read VBR for filesystem parameters
    var boot_sector: [SECTOR_SIZE]u8 = undefined;
    const partition_start: u64 = 1 * SECTOR_SIZE;

    try file.seekTo(partition_start);
    _ = try file.readAll(&boot_sector);

    // Read fields directly to avoid alignment issues
    const reserved_sectors = @as(u16, boot_sector[0x0E]) | (@as(u16, boot_sector[0x0F]) << 8);
    const num_fats = boot_sector[0x10];
    const fat_size = @as(u32, boot_sector[0x24]) | (@as(u32, boot_sector[0x25]) << 8) |
        (@as(u32, boot_sector[0x26]) << 16) | (@as(u32, boot_sector[0x27]) << 24);
    const root_cluster = @as(u32, boot_sector[0x2C]) | (@as(u32, boot_sector[0x2D]) << 8) |
        (@as(u32, boot_sector[0x2E]) << 16) | (@as(u32, boot_sector[0x2F]) << 24);
    const sectors_per_cluster = boot_sector[0x0D];

    const fat1_sector: u32 = 1 + reserved_sectors;
    const data_start_sector: u32 = 1 + reserved_sectors + (num_fats * fat_size);

    std.debug.print("FAT32 Parameters:\n", .{});
    std.debug.print("  Reserved sectors: {}\n", .{reserved_sectors});
    std.debug.print("  FAT size: {} sectors\n", .{fat_size});
    std.debug.print("  Data start sector: {}\n", .{data_start_sector});
    std.debug.print("  Root cluster: {}\n", .{root_cluster});
    std.debug.print("  Sectors per cluster: {}\n", .{sectors_per_cluster});

    // Cluster 3 will be rockbox.ipod file
    const rockbox_file_cluster: u32 = 3;

    // Create dummy rockbox.ipod content
    var rockbox_content: [512]u8 = undefined;
    @memset(&rockbox_content, 0);

    // ARM infinite loop firmware
    const firmware_data = [_]u8{
        0xFE, 0xFF, 0xFF, 0xEA, // B . (branch to self)
    };

    // Calculate checksum
    var checksum: u32 = 0;
    for (firmware_data) |b| {
        checksum += b;
    }

    // Header: checksum (BE) + model "ipvd"
    rockbox_content[0] = @truncate(checksum >> 24);
    rockbox_content[1] = @truncate(checksum >> 16);
    rockbox_content[2] = @truncate(checksum >> 8);
    rockbox_content[3] = @truncate(checksum);
    rockbox_content[4] = 'i';
    rockbox_content[5] = 'p';
    rockbox_content[6] = 'v';
    rockbox_content[7] = 'd';
    @memcpy(rockbox_content[8..12], &firmware_data);

    const file_size: u32 = 8 + firmware_data.len;

    // Update FAT entry for cluster 3
    var fat_sector: [SECTOR_SIZE]u8 = undefined;
    try file.seekTo(fat1_sector * SECTOR_SIZE);
    _ = try file.readAll(&fat_sector);

    const fat_data = @as(*[128]u32, @ptrCast(@alignCast(&fat_sector)));
    fat_data[3] = FAT_END_OF_CHAIN;

    // Write FAT1
    try file.seekTo(fat1_sector * SECTOR_SIZE);
    try file.writeAll(&fat_sector);
    std.debug.print("Updated FAT1 at sector {}\n", .{fat1_sector});

    // Write FAT2
    const fat2_sector = fat1_sector + fat_size;
    try file.seekTo(fat2_sector * SECTOR_SIZE);
    try file.writeAll(&fat_sector);
    std.debug.print("Updated FAT2 at sector {}\n", .{fat2_sector});

    // Read root directory
    var root_sector_data: [SECTOR_SIZE]u8 = undefined;
    const root_sector: u64 = data_start_sector + (@as(u64, root_cluster - 2) * sectors_per_cluster);

    try file.seekTo(root_sector * SECTOR_SIZE);
    _ = try file.readAll(&root_sector_data);

    std.debug.print("Root directory at sector {}\n", .{root_sector});

    // Find first free entry (should be right after volume label)
    var entry_idx: usize = 0;
    while (entry_idx < 16) : (entry_idx += 1) {
        const first_byte = root_sector_data[entry_idx * 32];
        if (first_byte == 0) break;
        if (first_byte == 0xE5) break; // Deleted entry
    }

    std.debug.print("Using root entry index: {}\n", .{entry_idx});

    // Create 8.3 short name: "ROCKBOX IPO"
    // Name: "ROCKBOX " (7 chars + 1 space pad = 8 bytes)
    // Ext:  "IPO" (3 bytes, truncated from "ipod")
    const short_name: [11]u8 = "ROCKBOX IPO".*;

    std.debug.print("Short name: '{s}'\n", .{&short_name});

    // Write directory entry directly to buffer
    const offset = entry_idx * 32;
    @memcpy(root_sector_data[offset .. offset + 11], &short_name);
    root_sector_data[offset + 11] = ATTR_ARCHIVE; // attr
    root_sector_data[offset + 12] = 0; // nt_res
    root_sector_data[offset + 13] = 0; // crt_time_tenth
    root_sector_data[offset + 14] = 0; // crt_time low
    root_sector_data[offset + 15] = 0; // crt_time high
    root_sector_data[offset + 16] = 0x21; // crt_date low (2025-01-01)
    root_sector_data[offset + 17] = 0x54; // crt_date high
    root_sector_data[offset + 18] = 0x21; // lst_acc_date low
    root_sector_data[offset + 19] = 0x54; // lst_acc_date high
    root_sector_data[offset + 20] = 0; // fst_clus_hi low
    root_sector_data[offset + 21] = 0; // fst_clus_hi high
    root_sector_data[offset + 22] = 0; // wrt_time low
    root_sector_data[offset + 23] = 0; // wrt_time high
    root_sector_data[offset + 24] = 0x21; // wrt_date low
    root_sector_data[offset + 25] = 0x54; // wrt_date high
    root_sector_data[offset + 26] = @truncate(rockbox_file_cluster); // fst_clus_lo low
    root_sector_data[offset + 27] = 0; // fst_clus_lo high
    root_sector_data[offset + 28] = @truncate(file_size); // file_size byte 0
    root_sector_data[offset + 29] = @truncate(file_size >> 8); // file_size byte 1
    root_sector_data[offset + 30] = @truncate(file_size >> 16); // file_size byte 2
    root_sector_data[offset + 31] = @truncate(file_size >> 24); // file_size byte 3

    // Write root directory
    try file.seekTo(root_sector * SECTOR_SIZE);
    try file.writeAll(&root_sector_data);
    std.debug.print("Wrote root directory\n", .{});

    // Write rockbox.ipod content at cluster 3
    const file_sector: u64 = data_start_sector + (@as(u64, rockbox_file_cluster - 2) * sectors_per_cluster);
    try file.seekTo(file_sector * SECTOR_SIZE);
    try file.writeAll(&rockbox_content);
    std.debug.print("Wrote rockbox.ipod at sector {} (cluster {})\n", .{ file_sector, rockbox_file_cluster });

    std.debug.print("\nDone! Created /ROCKBOX.IPO with size {} bytes\n", .{file_size});
    std.debug.print("The bootloader should find this file and attempt to load it.\n", .{});
}
