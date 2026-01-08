//! ATA IDENTIFY DEVICE Response Generator
//!
//! Generates the 512-byte response to the ATA IDENTIFY DEVICE command.
//! This data structure describes the drive's capabilities.

const std = @import("std");
const disk_image = @import("disk_image.zig");

const DiskImage = disk_image.DiskImage;

/// ATA IDENTIFY DEVICE response structure (256 words = 512 bytes)
pub const IdentifyData = struct {
    /// Raw 512-byte response
    data: [512]u8 = [_]u8{0} ** 512,

    const Self = @This();

    /// Set a 16-bit word at the given index (ATA words are at even byte offsets)
    fn setWord(self: *Self, word_index: usize, value: u16) void {
        const offset = word_index * 2;
        if (offset + 1 < self.data.len) {
            self.data[offset] = @truncate(value);
            self.data[offset + 1] = @truncate(value >> 8);
        }
    }

    /// Get a 16-bit word at the given index
    fn getWord(self: *const Self, word_index: usize) u16 {
        const offset = word_index * 2;
        if (offset + 1 < self.data.len) {
            return @as(u16, self.data[offset]) | (@as(u16, self.data[offset + 1]) << 8);
        }
        return 0;
    }

    /// Set a string at the given word index (ATA strings are byte-swapped)
    fn setString(self: *Self, word_index: usize, str: []const u8, word_count: usize) void {
        const offset = word_index * 2;
        const byte_count = word_count * 2;

        var i: usize = 0;
        while (i < byte_count) : (i += 2) {
            const str_idx0 = i;
            const str_idx1 = i + 1;

            // ATA strings are byte-swapped
            const char0: u8 = if (str_idx1 < str.len) str[str_idx1] else ' ';
            const char1: u8 = if (str_idx0 < str.len) str[str_idx0] else ' ';

            if (offset + i < self.data.len) {
                self.data[offset + i] = char0;
            }
            if (offset + i + 1 < self.data.len) {
                self.data[offset + i + 1] = char1;
            }
        }
    }

    /// Create IDENTIFY response from disk image
    pub fn fromDiskImage(image: *const DiskImage) Self {
        var self = Self{};

        // Word 0: General configuration
        // Bit 15 = 0: ATA device
        // Bit 6 = 1: Fixed drive
        self.setWord(0, 0x0040);

        // Words 1-9: Obsolete/retired fields (set to typical values)
        self.setWord(1, 0x0000); // Number of cylinders (obsolete)
        self.setWord(3, 0x0000); // Number of heads (obsolete)
        self.setWord(6, 0x0000); // Number of sectors per track (obsolete)

        // Words 10-19: Serial number (20 ASCII chars, byte-swapped)
        self.setString(10, &image.serial, 10);

        // Words 23-26: Firmware revision (8 ASCII chars, byte-swapped)
        self.setString(23, &image.firmware, 4);

        // Words 27-46: Model number (40 ASCII chars, byte-swapped)
        self.setString(27, &image.model, 20);

        // Word 47: Max sectors per READ/WRITE MULTIPLE
        self.setWord(47, 0x8010); // 16 sectors

        // Word 49: Capabilities
        // Bit 9 = 1: LBA supported
        // Bit 8 = 1: DMA supported
        self.setWord(49, 0x0300);

        // Word 50: Capabilities 2
        self.setWord(50, 0x4001); // Shall be set to 4001h

        // Word 53: Field validity
        // Bit 1 = 1: Words 64-70 valid
        // Bit 2 = 1: Word 88 valid
        self.setWord(53, 0x0006);

        // Words 60-61: Total addressable sectors (28-bit LBA)
        const total_lba28: u32 = @intCast(@min(image.total_sectors, 0x0FFFFFFF));
        self.setWord(60, @truncate(total_lba28));
        self.setWord(61, @truncate(total_lba28 >> 16));

        // Word 63: Multiword DMA modes
        self.setWord(63, 0x0007); // MWDMA modes 0-2 supported

        // Word 64: PIO modes supported
        self.setWord(64, 0x0003); // PIO modes 3-4 supported

        // Word 65: Minimum MWDMA transfer cycle time
        self.setWord(65, 120); // 120 ns

        // Word 66: Recommended MWDMA transfer cycle time
        self.setWord(66, 120);

        // Word 67: Minimum PIO transfer cycle time without IORDY
        self.setWord(67, 240);

        // Word 68: Minimum PIO transfer cycle time with IORDY
        self.setWord(68, 120);

        // Word 80: Major version number
        // ATA/ATAPI-7 = 0x0078
        self.setWord(80, 0x0078);

        // Word 81: Minor version number
        self.setWord(81, 0x0019);

        // Word 82: Command set supported 1
        // Bit 14 = 1: NOP command supported
        // Bit 0 = 1: SMART supported
        self.setWord(82, 0x4001);

        // Word 83: Command set supported 2
        // Bit 14 = 1: Required (shall be set)
        // Bit 13 = 1: FLUSH CACHE EXT supported
        // Bit 12 = 1: FLUSH CACHE supported
        // Bit 10 = 1: 48-bit LBA supported (if disk is large enough)
        var word83: u16 = 0x7000;
        if (image.requiresLba48()) {
            word83 |= 0x0400;
        }
        self.setWord(83, word83);

        // Word 84: Command set support extension
        self.setWord(84, 0x4000);

        // Word 85: Command set enabled 1
        self.setWord(85, 0x4001);

        // Word 86: Command set enabled 2
        self.setWord(86, word83);

        // Word 87: Command set default
        self.setWord(87, 0x4000);

        // Word 88: Ultra DMA modes
        self.setWord(88, 0x001F); // UDMA modes 0-4 supported

        // Words 100-103: Total addressable sectors (48-bit LBA)
        if (image.requiresLba48()) {
            const total: u64 = image.total_sectors;
            self.setWord(100, @truncate(total));
            self.setWord(101, @truncate(total >> 16));
            self.setWord(102, @truncate(total >> 32));
            self.setWord(103, @truncate(total >> 48));
        } else {
            // For small disks, still fill in LBA48 capacity
            const total: u64 = image.total_sectors;
            self.setWord(100, @truncate(total));
            self.setWord(101, @truncate(total >> 16));
            self.setWord(102, 0);
            self.setWord(103, 0);
        }

        // Word 106: Physical/logical sector size
        // All zeros = 512 byte logical and physical sectors
        self.setWord(106, 0x0000);

        // Word 217: Nominal media rotation rate
        // 1 = Not a rotating media (SSD-like)
        // 5400/7200 = typical HDD
        self.setWord(217, 4200); // Typical iPod drive speed

        return self;
    }

    /// Get the raw data buffer
    pub fn getData(self: *const Self) []const u8 {
        return &self.data;
    }
};

// ============================================================
// Tests
// ============================================================

test "identify basic structure" {
    const allocator = std.testing.allocator;

    var image = try DiskImage.createInMemory(allocator, 1000);
    defer image.close();

    image.setModel("TEST MODEL");
    image.setSerial("SERIAL123");
    image.setFirmware("FW01");

    const identify = IdentifyData.fromDiskImage(&image);

    // Check word 0 - general config
    try std.testing.expectEqual(@as(u16, 0x0040), identify.getWord(0));

    // Check LBA capability (word 49)
    try std.testing.expectEqual(@as(u16, 0x0300), identify.getWord(49));

    // Check total sectors (words 60-61)
    const lba_low = identify.getWord(60);
    const lba_high = identify.getWord(61);
    const total_lba = @as(u32, lba_low) | (@as(u32, lba_high) << 16);
    try std.testing.expectEqual(@as(u32, 1000), total_lba);
}

test "identify string encoding" {
    const allocator = std.testing.allocator;

    var image = try DiskImage.createInMemory(allocator, 100);
    defer image.close();

    image.setModel("ABCD");

    const identify = IdentifyData.fromDiskImage(&image);

    // ATA strings are byte-swapped
    // Word 27 should have 'B' in low byte, 'A' in high byte
    try std.testing.expectEqual(@as(u8, 'B'), identify.data[54]); // word 27 low
    try std.testing.expectEqual(@as(u8, 'A'), identify.data[55]); // word 27 high
    try std.testing.expectEqual(@as(u8, 'D'), identify.data[56]); // word 28 low
    try std.testing.expectEqual(@as(u8, 'C'), identify.data[57]); // word 28 high
}

test "identify large disk lba48" {
    const allocator = std.testing.allocator;

    // Create a "large" disk (we'll just test the flag logic)
    var image = try DiskImage.createInMemory(allocator, 100);
    defer image.close();

    // Force large sector count for testing
    image.total_sectors = 0x1_0000_0000; // > 28-bit LBA

    const identify = IdentifyData.fromDiskImage(&image);

    // Word 83 should have LBA48 bit set
    const word83 = identify.getWord(83);
    try std.testing.expect((word83 & 0x0400) != 0);

    // Words 100-103 should have full capacity
    const lba48_0 = identify.getWord(100);
    const lba48_1 = identify.getWord(101);
    const lba48_2 = identify.getWord(102);

    const total_lba48 = @as(u64, lba48_0) |
        (@as(u64, lba48_1) << 16) |
        (@as(u64, lba48_2) << 32);

    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), total_lba48);
}

test "identify data size" {
    const allocator = std.testing.allocator;

    var image = try DiskImage.createInMemory(allocator, 100);
    defer image.close();

    const identify = IdentifyData.fromDiskImage(&image);

    try std.testing.expectEqual(@as(usize, 512), identify.getData().len);
}
