//! Disk Image Inspector
//!
//! Inspects disk images to show partition structure, FAT32 info,
//! and directory listings. Useful for debugging disk access.
//!
//! Usage: disk-inspect <disk-image>

const std = @import("std");
const fat32 = @import("fat32");

const DiskFile = struct {
    file: std.fs.File,

    fn readSector(ctx: *anyopaque, lba: u64, buf: *[512]u8) bool {
        const self: *DiskFile = @ptrCast(@alignCast(ctx));
        self.file.seekTo(lba * 512) catch return false;
        const n = self.file.readAll(buf) catch return false;
        return n == 512;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip program name
    const path = args.next() orelse {
        std.debug.print("Usage: disk-inspect <disk-image>\n", .{});
        return;
    };

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    std.debug.print("Disk image: {s}\n", .{path});
    std.debug.print("Size: {} bytes ({} MB)\n", .{ stat.size, stat.size / (1024 * 1024) });
    std.debug.print("\n", .{});

    // Read first sector to check for MBR
    var sector: [512]u8 = undefined;
    _ = try file.readAll(&sector);

    // Check for MBR signature
    if (sector[510] == 0x55 and sector[511] == 0xAA) {
        std.debug.print("MBR signature found (0x55AA)\n", .{});
        std.debug.print("\nPartition table:\n", .{});

        // Parse partition entries (at 0x1BE, 0x1CE, 0x1DE, 0x1EE)
        for (0..4) |i| {
            const offset = 0x1BE + i * 16;
            const status = sector[offset];
            const ptype = sector[offset + 4];
            const start_lba = @as(u32, sector[offset + 8]) |
                (@as(u32, sector[offset + 9]) << 8) |
                (@as(u32, sector[offset + 10]) << 16) |
                (@as(u32, sector[offset + 11]) << 24);
            const size_sectors = @as(u32, sector[offset + 12]) |
                (@as(u32, sector[offset + 13]) << 8) |
                (@as(u32, sector[offset + 14]) << 16) |
                (@as(u32, sector[offset + 15]) << 24);

            if (ptype != 0) {
                const ptype_name = switch (ptype) {
                    0x00 => "Empty",
                    0x01 => "FAT12",
                    0x04, 0x06, 0x0E => "FAT16",
                    0x0B, 0x0C => "FAT32",
                    0x07 => "NTFS/exFAT",
                    0x83 => "Linux",
                    0x82 => "Linux Swap",
                    else => "Unknown",
                };
                std.debug.print("  Partition {}: type=0x{X:0>2} ({s}), status=0x{X:0>2}, start={}, size={} sectors ({} MB)\n", .{
                    i + 1,
                    ptype,
                    ptype_name,
                    status,
                    start_lba,
                    size_sectors,
                    size_sectors * 512 / (1024 * 1024),
                });
            }
        }
    } else {
        std.debug.print("No MBR signature found\n", .{});

        // Check for FAT boot sector directly
        if (std.mem.eql(u8, sector[0x52..0x5A], "FAT32   ")) {
            std.debug.print("Direct FAT32 boot sector found (no MBR)\n", .{});
        }
    }

    std.debug.print("\n", .{});

    // Initialize FAT32 reader
    var disk = DiskFile{ .file = file };
    var reader = fat32.Fat32Reader.init(@ptrCast(&disk), DiskFile.readSector);

    if (reader.valid) {
        std.debug.print("FAT32 filesystem detected\n", .{});
        std.debug.print("  OEM Name: {s}\n", .{reader.boot_sector.oem_name});
        std.debug.print("  Bytes per sector: {}\n", .{reader.boot_sector.bytes_per_sector});
        std.debug.print("  Sectors per cluster: {}\n", .{reader.boot_sector.sectors_per_cluster});
        std.debug.print("  Reserved sectors: {}\n", .{reader.boot_sector.reserved_sectors});
        std.debug.print("  Number of FATs: {}\n", .{reader.boot_sector.num_fats});
        std.debug.print("  FAT size: {} sectors\n", .{reader.boot_sector.fat_size_32});
        std.debug.print("  Total sectors: {}\n", .{reader.boot_sector.total_sectors_32});
        std.debug.print("  Root cluster: {}\n", .{reader.boot_sector.root_cluster});
        std.debug.print("  Total clusters: {}\n", .{reader.boot_sector.totalClusters()});

        if (reader.getVolumeLabel()) |label| {
            std.debug.print("  Volume label: {s}\n", .{label});
        }

        std.debug.print("\nRoot directory:\n", .{});

        var entries: [64]fat32.DirEntry = undefined;
        const count = reader.readDirectory(reader.getRootCluster(), &entries);

        for (entries[0..count]) |entry| {
            var name_buf: [12]u8 = undefined;
            const name = entry.getName(&name_buf);

            const attr_str = blk: {
                if (entry.isDirectory()) break :blk "<DIR>";
                if (entry.isVolumeLabel()) break :blk "<VOL>";
                break :blk "     ";
            };

            std.debug.print("  {s:<12} {s} {d:>10} bytes  cluster={}\n", .{
                name,
                attr_str,
                entry.file_size,
                entry.getCluster(),
            });
        }

        if (count == 0) {
            std.debug.print("  (empty or unable to read)\n", .{});
        }
    } else {
        std.debug.print("Not a valid FAT32 filesystem\n", .{});

        // Check for iPod firmware partition
        if (std.mem.eql(u8, sector[0..4], "{{~~") or
            std.mem.eql(u8, sector[0x100..0x104], "]ih["))
        {
            std.debug.print("\niPod firmware partition detected!\n", .{});
            std.debug.print("This is the firmware partition, not the data partition.\n", .{});
            std.debug.print("The data partition (FAT32 with music) is separate.\n", .{});
        }
    }
}
