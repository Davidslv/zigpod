//! Disk Image Backend
//!
//! Provides a file-backed virtual disk for the ATA controller simulation.
//! Supports raw disk images in various sizes.

const std = @import("std");

/// Sector size in bytes (standard ATA)
pub const SECTOR_SIZE: usize = 512;

/// Maximum transfer size (256 sectors)
pub const MAX_TRANSFER_SECTORS: u16 = 256;

/// Disk image backend errors
pub const DiskImageError = error{
    /// File could not be opened
    OpenFailed,
    /// Seek operation failed
    SeekFailed,
    /// Read operation failed
    ReadFailed,
    /// Write operation failed
    WriteFailed,
    /// LBA out of range
    LbaOutOfRange,
    /// Invalid sector count
    InvalidSectorCount,
    /// Disk is read-only
    ReadOnly,
    /// File not open
    NotOpen,
};

/// Disk image file backend
pub const DiskImage = struct {
    /// File handle (null if memory-backed)
    file: ?std.fs.File = null,
    /// Memory buffer for in-memory disk (for tests)
    memory: ?[]u8 = null,
    /// Total number of sectors
    total_sectors: u64 = 0,
    /// Is the disk read-only?
    readonly: bool = false,
    /// Model name (for IDENTIFY)
    model: [40]u8 = [_]u8{' '} ** 40,
    /// Serial number (for IDENTIFY)
    serial: [20]u8 = [_]u8{' '} ** 20,
    /// Firmware revision (for IDENTIFY)
    firmware: [8]u8 = [_]u8{' '} ** 8,
    /// Allocator (for memory-backed)
    allocator: ?std.mem.Allocator = null,

    const Self = @This();

    /// Open a disk image file
    pub fn open(path: []const u8, readonly: bool) DiskImageError!Self {
        const file = std.fs.cwd().openFile(path, .{
            .mode = if (readonly) .read_only else .read_write,
        }) catch return DiskImageError.OpenFailed;

        const stat = file.stat() catch {
            file.close();
            return DiskImageError.OpenFailed;
        };

        const total_sectors = stat.size / SECTOR_SIZE;

        var self = Self{
            .file = file,
            .total_sectors = total_sectors,
            .readonly = readonly,
        };

        // Set default model/serial
        self.setModel("TOSHIBA MK3008GAL");
        self.setSerial("ZP123456789");
        self.setFirmware("ZP01");

        return self;
    }

    /// Create a new disk image of the specified size
    pub fn create(path: []const u8, size_mb: u64) DiskImageError!Self {
        const file = std.fs.cwd().createFile(path, .{
            .truncate = true,
        }) catch return DiskImageError.OpenFailed;

        const size_bytes = size_mb * 1024 * 1024;
        const total_sectors = size_bytes / SECTOR_SIZE;

        // Extend file to full size
        file.seekTo(size_bytes - 1) catch {
            file.close();
            return DiskImageError.SeekFailed;
        };
        file.writer().writeByte(0) catch {
            file.close();
            return DiskImageError.WriteFailed;
        };
        file.seekTo(0) catch {
            file.close();
            return DiskImageError.SeekFailed;
        };

        var self = Self{
            .file = file,
            .total_sectors = total_sectors,
            .readonly = false,
        };

        self.setModel("TOSHIBA MK3008GAL");
        self.setSerial("ZP123456789");
        self.setFirmware("ZP01");

        return self;
    }

    /// Create an in-memory disk image (for testing)
    pub fn createInMemory(allocator: std.mem.Allocator, size_sectors: u64) DiskImageError!Self {
        const size_bytes = size_sectors * SECTOR_SIZE;
        const memory = allocator.alloc(u8, size_bytes) catch return DiskImageError.OpenFailed;
        @memset(memory, 0);

        var self = Self{
            .memory = memory,
            .total_sectors = size_sectors,
            .readonly = false,
            .allocator = allocator,
        };

        self.setModel("SIMULATOR MEMORY DISK");
        self.setSerial("MEM000000001");
        self.setFirmware("SIM1");

        return self;
    }

    /// Close the disk image
    pub fn close(self: *Self) void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
        if (self.memory) |mem| {
            if (self.allocator) |alloc| {
                alloc.free(mem);
            }
            self.memory = null;
        }
        self.total_sectors = 0;
    }

    /// Check if disk is open
    pub fn isOpen(self: *const Self) bool {
        return self.file != null or self.memory != null;
    }

    /// Read sectors from the disk
    pub fn readSectors(self: *Self, lba: u64, count: u16, buffer: []u8) DiskImageError!void {
        if (!self.isOpen()) return DiskImageError.NotOpen;

        if (lba >= self.total_sectors) return DiskImageError.LbaOutOfRange;
        if (lba + count > self.total_sectors) return DiskImageError.LbaOutOfRange;
        if (count == 0 or count > MAX_TRANSFER_SECTORS) return DiskImageError.InvalidSectorCount;

        const required_size = @as(usize, count) * SECTOR_SIZE;
        if (buffer.len < required_size) return DiskImageError.ReadFailed;

        if (self.memory) |mem| {
            // Memory-backed read
            const offset = lba * SECTOR_SIZE;
            @memcpy(buffer[0..required_size], mem[offset..][0..required_size]);
        } else if (self.file) |f| {
            // File-backed read
            const offset = lba * SECTOR_SIZE;
            f.seekTo(offset) catch return DiskImageError.SeekFailed;
            const bytes_read = f.readAll(buffer[0..required_size]) catch return DiskImageError.ReadFailed;
            if (bytes_read != required_size) return DiskImageError.ReadFailed;
        }
    }

    /// Write sectors to the disk
    pub fn writeSectors(self: *Self, lba: u64, count: u16, data: []const u8) DiskImageError!void {
        if (!self.isOpen()) return DiskImageError.NotOpen;
        if (self.readonly) return DiskImageError.ReadOnly;

        if (lba >= self.total_sectors) return DiskImageError.LbaOutOfRange;
        if (lba + count > self.total_sectors) return DiskImageError.LbaOutOfRange;
        if (count == 0 or count > MAX_TRANSFER_SECTORS) return DiskImageError.InvalidSectorCount;

        const required_size = @as(usize, count) * SECTOR_SIZE;
        if (data.len < required_size) return DiskImageError.WriteFailed;

        if (self.memory) |mem| {
            // Memory-backed write
            const offset = lba * SECTOR_SIZE;
            @memcpy(mem[offset..][0..required_size], data[0..required_size]);
        } else if (self.file) |f| {
            // File-backed write
            const offset = lba * SECTOR_SIZE;
            f.seekTo(offset) catch return DiskImageError.SeekFailed;
            f.writeAll(data[0..required_size]) catch return DiskImageError.WriteFailed;
        }
    }

    /// Flush any cached writes to disk
    pub fn flush(self: *Self) DiskImageError!void {
        if (self.file) |f| {
            f.sync() catch return DiskImageError.WriteFailed;
        }
        // Memory-backed disk doesn't need flush
    }

    /// Set model name (ATA-style, space-padded)
    pub fn setModel(self: *Self, name: []const u8) void {
        @memset(&self.model, ' ');
        const len = @min(name.len, self.model.len);
        @memcpy(self.model[0..len], name[0..len]);
    }

    /// Set serial number (ATA-style, space-padded)
    pub fn setSerial(self: *Self, serial: []const u8) void {
        @memset(&self.serial, ' ');
        const len = @min(serial.len, self.serial.len);
        @memcpy(self.serial[0..len], serial[0..len]);
    }

    /// Set firmware revision (ATA-style, space-padded)
    pub fn setFirmware(self: *Self, fw: []const u8) void {
        @memset(&self.firmware, ' ');
        const len = @min(fw.len, self.firmware.len);
        @memcpy(self.firmware[0..len], fw[0..len]);
    }

    /// Get capacity in bytes
    pub fn getCapacity(self: *const Self) u64 {
        return self.total_sectors * SECTOR_SIZE;
    }

    /// Get capacity in MB
    pub fn getCapacityMb(self: *const Self) u64 {
        return self.getCapacity() / (1024 * 1024);
    }

    /// Check if LBA48 is required (>128GB)
    pub fn requiresLba48(self: *const Self) bool {
        return self.total_sectors > 0x0FFFFFFF;
    }
};

// ============================================================
// Tests
// ============================================================

test "in-memory disk create and read/write" {
    const allocator = std.testing.allocator;

    var disk = try DiskImage.createInMemory(allocator, 100); // 100 sectors = 50KB
    defer disk.close();

    try std.testing.expect(disk.isOpen());
    try std.testing.expectEqual(@as(u64, 100), disk.total_sectors);
    try std.testing.expectEqual(@as(u64, 51200), disk.getCapacity());

    // Write some data
    var write_buf: [512]u8 = undefined;
    @memset(&write_buf, 0xAA);
    write_buf[0] = 0x55;
    write_buf[511] = 0x55;

    try disk.writeSectors(0, 1, &write_buf);

    // Read it back
    var read_buf: [512]u8 = undefined;
    try disk.readSectors(0, 1, &read_buf);

    try std.testing.expectEqual(@as(u8, 0x55), read_buf[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), read_buf[1]);
    try std.testing.expectEqual(@as(u8, 0x55), read_buf[511]);
}

test "multi-sector read/write" {
    const allocator = std.testing.allocator;

    var disk = try DiskImage.createInMemory(allocator, 100);
    defer disk.close();

    // Write 4 sectors
    var write_buf: [512 * 4]u8 = undefined;
    for (0..4) |i| {
        @memset(write_buf[i * 512 ..][0..512], @as(u8, @intCast(i + 1)));
    }

    try disk.writeSectors(10, 4, &write_buf);

    // Read back
    var read_buf: [512 * 4]u8 = undefined;
    try disk.readSectors(10, 4, &read_buf);

    try std.testing.expectEqual(@as(u8, 1), read_buf[0]);
    try std.testing.expectEqual(@as(u8, 2), read_buf[512]);
    try std.testing.expectEqual(@as(u8, 3), read_buf[1024]);
    try std.testing.expectEqual(@as(u8, 4), read_buf[1536]);
}

test "out of range access" {
    const allocator = std.testing.allocator;

    var disk = try DiskImage.createInMemory(allocator, 10);
    defer disk.close();

    var buf: [512]u8 = undefined;

    // LBA beyond end
    try std.testing.expectError(DiskImageError.LbaOutOfRange, disk.readSectors(10, 1, &buf));
    try std.testing.expectError(DiskImageError.LbaOutOfRange, disk.readSectors(9, 2, &buf));

    // Zero count
    try std.testing.expectError(DiskImageError.InvalidSectorCount, disk.readSectors(0, 0, &buf));
}

test "model and serial" {
    const allocator = std.testing.allocator;

    var disk = try DiskImage.createInMemory(allocator, 10);
    defer disk.close();

    disk.setModel("TEST DRIVE");
    disk.setSerial("SN12345");
    disk.setFirmware("V1.0");

    // Model should be space-padded
    try std.testing.expectEqualStrings("TEST DRIVE", disk.model[0..10]);
    try std.testing.expectEqual(@as(u8, ' '), disk.model[10]);

    // Serial should be space-padded
    try std.testing.expectEqualStrings("SN12345", disk.serial[0..7]);
}

test "lba48 detection" {
    const allocator = std.testing.allocator;

    // Small disk (doesn't need LBA48)
    var small_disk = try DiskImage.createInMemory(allocator, 100);
    defer small_disk.close();
    try std.testing.expect(!small_disk.requiresLba48());
}

test "close and reopen" {
    const allocator = std.testing.allocator;

    var disk = try DiskImage.createInMemory(allocator, 10);
    try std.testing.expect(disk.isOpen());

    disk.close();
    try std.testing.expect(!disk.isOpen());

    var buf: [512]u8 = undefined;
    try std.testing.expectError(DiskImageError.NotOpen, disk.readSectors(0, 1, &buf));
}
