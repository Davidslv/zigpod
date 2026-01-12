//! FAT32 Filesystem Creator for ZigPod Test Disk
//!
//! Creates a minimal FAT32 filesystem on a disk image for testing
//! the Rockbox bootloader.

const std = @import("std");

const SECTOR_SIZE = 512;

/// FAT32 Boot Sector (Volume Boot Record)
const Fat32BootSector = extern struct {
    jump: [3]u8,           // 0x00: Jump instruction
    oem_name: [8]u8,       // 0x03: OEM name
    bytes_per_sector: u16 align(1),  // 0x0B: Bytes per sector
    sectors_per_cluster: u8,         // 0x0D: Sectors per cluster
    reserved_sectors: u16 align(1),  // 0x0E: Reserved sectors
    num_fats: u8,                    // 0x10: Number of FATs
    root_entry_count: u16 align(1),  // 0x11: Root entries (0 for FAT32)
    total_sectors_16: u16 align(1),  // 0x13: Total sectors (0 for FAT32)
    media_type: u8,                  // 0x15: Media type
    fat_size_16: u16 align(1),       // 0x16: FAT size (0 for FAT32)
    sectors_per_track: u16 align(1), // 0x18: Sectors per track
    num_heads: u16 align(1),         // 0x1A: Number of heads
    hidden_sectors: u32 align(1),    // 0x1C: Hidden sectors
    total_sectors_32: u32 align(1),  // 0x20: Total sectors
    // FAT32 specific
    fat_size_32: u32 align(1),       // 0x24: FAT size in sectors
    ext_flags: u16 align(1),         // 0x28: Extended flags
    fs_version: u16 align(1),        // 0x2A: Filesystem version
    root_cluster: u32 align(1),      // 0x2C: Root directory cluster
    fs_info: u16 align(1),           // 0x30: FSInfo sector
    backup_boot: u16 align(1),       // 0x32: Backup boot sector
    reserved: [12]u8,                // 0x34: Reserved
    drive_number: u8,                // 0x40: Drive number
    reserved1: u8,                   // 0x41: Reserved
    boot_sig: u8,                    // 0x42: Extended boot signature
    volume_id: u32 align(1),         // 0x43: Volume serial number
    volume_label: [11]u8,            // 0x47: Volume label
    fs_type: [8]u8,                  // 0x52: Filesystem type
    // Boot code and signature follow
};

/// FSInfo structure
const FSInfo = extern struct {
    lead_sig: u32 align(1),          // 0x00: Lead signature (0x41615252)
    reserved1: [480]u8,              // 0x04: Reserved
    struct_sig: u32 align(1),        // 0x1E4: Structure signature (0x61417272)
    free_count: u32 align(1),        // 0x1E8: Free cluster count
    next_free: u32 align(1),         // 0x1EC: Next free cluster
    reserved2: [12]u8,               // 0x1F0: Reserved
    trail_sig: u32 align(1),         // 0x1FC: Trail signature (0xAA550000)
};

/// Directory entry
const DirEntry = extern struct {
    name: [11]u8,                    // Short name (8.3)
    attr: u8,                        // Attributes
    nt_res: u8,                      // Reserved for NT
    crt_time_tenth: u8,              // Creation time (tenths)
    crt_time: u16 align(1),          // Creation time
    crt_date: u16 align(1),          // Creation date
    lst_acc_date: u16 align(1),      // Last access date
    fst_clus_hi: u16 align(1),       // First cluster high word
    wrt_time: u16 align(1),          // Write time
    wrt_date: u16 align(1),          // Write date
    fst_clus_lo: u16 align(1),       // First cluster low word
    file_size: u32 align(1),         // File size
};

// Directory attributes
const ATTR_READ_ONLY: u8 = 0x01;
const ATTR_HIDDEN: u8 = 0x02;
const ATTR_SYSTEM: u8 = 0x04;
const ATTR_VOLUME_ID: u8 = 0x08;
const ATTR_DIRECTORY: u8 = 0x10;
const ATTR_ARCHIVE: u8 = 0x20;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Parse command line
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: mkfat32 <disk_image>\n", .{});
        return;
    }

    const disk_path = args[1];

    // Open disk image
    const file = try std.fs.cwd().openFile(disk_path, .{ .mode = .read_write });
    defer file.close();

    const stat = try file.stat();
    const disk_size = stat.size;
    const total_sectors = @as(u32, @intCast(disk_size / SECTOR_SIZE));

    std.debug.print("Disk: {s}\n", .{disk_path});
    std.debug.print("Size: {} bytes ({} sectors)\n", .{ disk_size, total_sectors });

    // Partition starts at sector 1 (after MBR)
    const partition_start: u32 = 1;
    const partition_sectors = total_sectors - partition_start;

    std.debug.print("Partition: starts at sector {}, {} sectors\n", .{ partition_start, partition_sectors });

    // FAT32 parameters for small disk
    const reserved_sectors: u16 = 6;  // Minimal: VBR + FSInfo + backup
    const num_fats: u8 = 2;
    const sectors_per_cluster: u8 = 1;  // 512 bytes per cluster

    // Calculate FAT size
    // FAT32 entries are 4 bytes each
    // Number of clusters = (partition_sectors - reserved_sectors) / sectors_per_cluster
    // But we need to account for FAT tables too...
    // FAT sectors = ceil((clusters + 2) * 4 / 512)
    // This is iterative, but for small disk we can estimate

    const data_area_start = reserved_sectors + 2;  // Approximate
    const approx_clusters = (partition_sectors - data_area_start) / sectors_per_cluster;
    const fat_entries = approx_clusters + 2;  // +2 for reserved entries
    const fat_size: u32 = (fat_entries * 4 + SECTOR_SIZE - 1) / SECTOR_SIZE;

    std.debug.print("FAT size: {} sectors\n", .{fat_size});

    const data_start = reserved_sectors + (num_fats * fat_size);
    const data_sectors = partition_sectors - data_start;
    const total_clusters = data_sectors / sectors_per_cluster;

    std.debug.print("Data start: sector {}, {} clusters\n", .{ data_start, total_clusters });

    // Create boot sector
    var boot_sector: [SECTOR_SIZE]u8 = [_]u8{0} ** SECTOR_SIZE;
    const boot: *Fat32BootSector = @ptrCast(&boot_sector);

    boot.jump = .{ 0xEB, 0x58, 0x90 };  // JMP short + NOP
    boot.oem_name = "ZIGPOD  ".*;
    boot.bytes_per_sector = SECTOR_SIZE;
    boot.sectors_per_cluster = sectors_per_cluster;
    boot.reserved_sectors = reserved_sectors;
    boot.num_fats = num_fats;
    boot.root_entry_count = 0;  // FAT32
    boot.total_sectors_16 = 0;  // FAT32 uses 32-bit field
    boot.media_type = 0xF8;  // Fixed disk
    boot.fat_size_16 = 0;  // FAT32 uses 32-bit field
    boot.sectors_per_track = 63;
    boot.num_heads = 255;
    boot.hidden_sectors = partition_start;
    boot.total_sectors_32 = partition_sectors;
    boot.fat_size_32 = fat_size;
    boot.ext_flags = 0;
    boot.fs_version = 0;
    boot.root_cluster = 2;  // First data cluster
    boot.fs_info = 1;  // FSInfo at sector 1
    boot.backup_boot = 0;  // No backup (to save space)
    boot.reserved = [_]u8{0} ** 12;
    boot.drive_number = 0x80;
    boot.reserved1 = 0;
    boot.boot_sig = 0x29;
    boot.volume_id = 0x12345678;
    boot.volume_label = "ZIGPOD     ".*;
    boot.fs_type = "FAT32   ".*;

    // Boot sector signature
    boot_sector[510] = 0x55;
    boot_sector[511] = 0xAA;

    // Write boot sector at partition start
    try file.seekTo(partition_start * SECTOR_SIZE);
    try file.writeAll(&boot_sector);
    std.debug.print("Wrote boot sector at sector {}\n", .{partition_start});

    // Create FSInfo sector
    var fsinfo_sector: [SECTOR_SIZE]u8 = [_]u8{0} ** SECTOR_SIZE;
    const fsinfo: *FSInfo = @ptrCast(&fsinfo_sector);

    fsinfo.lead_sig = 0x41615252;
    fsinfo.reserved1 = [_]u8{0} ** 480;
    fsinfo.struct_sig = 0x61417272;
    fsinfo.free_count = total_clusters - 1;  // -1 for root dir cluster
    fsinfo.next_free = 3;  // Next free after root cluster
    fsinfo.reserved2 = [_]u8{0} ** 12;
    fsinfo.trail_sig = 0xAA550000;

    // Write FSInfo at sector 2 (partition_start + 1)
    try file.seekTo((partition_start + 1) * SECTOR_SIZE);
    try file.writeAll(&fsinfo_sector);
    std.debug.print("Wrote FSInfo at sector {}\n", .{partition_start + 1});

    // Create FAT tables
    var fat_sector: [SECTOR_SIZE]u8 = [_]u8{0} ** SECTOR_SIZE;

    // First FAT sector has special entries
    // Entry 0: Media type (0x0FFFFFF8 for fixed disk)
    // Entry 1: End of chain marker (0x0FFFFFFF)
    // Entry 2: Root directory (end of chain for now)
    const fat_data = @as(*[128]u32, @ptrCast(@alignCast(&fat_sector)));
    fat_data[0] = 0x0FFFFFF8;  // Media type
    fat_data[1] = 0x0FFFFFFF;  // End of chain marker
    fat_data[2] = 0x0FFFFFFF;  // Root directory cluster (end of chain)

    // Write first FAT
    const fat1_start = partition_start + reserved_sectors;
    try file.seekTo(fat1_start * SECTOR_SIZE);
    try file.writeAll(&fat_sector);
    std.debug.print("Wrote FAT1 at sector {}\n", .{fat1_start});

    // Clear rest of FAT1
    @memset(&fat_sector, 0);
    var i: u32 = 1;
    while (i < fat_size) : (i += 1) {
        try file.writeAll(&fat_sector);
    }

    // Write second FAT (copy of first)
    fat_data[0] = 0x0FFFFFF8;
    fat_data[1] = 0x0FFFFFFF;
    fat_data[2] = 0x0FFFFFFF;

    const fat2_start = fat1_start + fat_size;
    try file.seekTo(fat2_start * SECTOR_SIZE);
    try file.writeAll(&fat_sector);
    std.debug.print("Wrote FAT2 at sector {}\n", .{fat2_start});

    // Clear rest of FAT2
    @memset(&fat_sector, 0);
    i = 1;
    while (i < fat_size) : (i += 1) {
        try file.writeAll(&fat_sector);
    }

    // Create root directory
    var root_sector: [SECTOR_SIZE]u8 = [_]u8{0} ** SECTOR_SIZE;
    const root_entries = @as(*[16]DirEntry, @ptrCast(@alignCast(&root_sector)));

    // Volume label entry
    root_entries[0].name = "ZIGPOD     ".*;
    root_entries[0].attr = ATTR_VOLUME_ID;
    root_entries[0].nt_res = 0;
    root_entries[0].crt_time_tenth = 0;
    root_entries[0].crt_time = 0;
    root_entries[0].crt_date = 0x5421;  // Some date
    root_entries[0].lst_acc_date = 0x5421;
    root_entries[0].fst_clus_hi = 0;
    root_entries[0].wrt_time = 0;
    root_entries[0].wrt_date = 0x5421;
    root_entries[0].fst_clus_lo = 0;
    root_entries[0].file_size = 0;

    // Write root directory at first data cluster
    const root_dir_sector = partition_start + data_start;
    try file.seekTo(root_dir_sector * SECTOR_SIZE);
    try file.writeAll(&root_sector);
    std.debug.print("Wrote root directory at sector {}\n", .{root_dir_sector});

    std.debug.print("\nFAT32 filesystem created successfully!\n", .{});
    std.debug.print("  Cluster size: {} bytes\n", .{@as(u32, sectors_per_cluster) * SECTOR_SIZE});
    std.debug.print("  Total clusters: {}\n", .{total_clusters});
    std.debug.print("  Free clusters: {}\n", .{total_clusters - 1});
}
