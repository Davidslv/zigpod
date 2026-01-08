//! ATA/IDE Controller Simulation
//!
//! Simulates the PP5021C ATA controller for virtual disk access.
//! Implements standard ATA commands used by iPod.

const std = @import("std");
const disk_image = @import("disk_image.zig");
const identify = @import("identify.zig");

const DiskImage = disk_image.DiskImage;
const IdentifyData = identify.IdentifyData;
const SECTOR_SIZE = disk_image.SECTOR_SIZE;
const MAX_TRANSFER_SECTORS = disk_image.MAX_TRANSFER_SECTORS;

/// ATA command codes
pub const AtaCommand = enum(u8) {
    identify = 0xEC,
    read_sectors = 0x20,
    read_sectors_ext = 0x24,
    write_sectors = 0x30,
    write_sectors_ext = 0x34,
    standby_immediate = 0xE0,
    idle_immediate = 0xE1,
    standby = 0xE2,
    idle = 0xE3,
    flush_cache = 0xE7,
    flush_cache_ext = 0xEA,
    set_features = 0xEF,
    _,

    pub fn fromByte(b: u8) AtaCommand {
        return @enumFromInt(b);
    }
};

/// ATA status register bits
pub const AtaStatus = struct {
    pub const BSY: u8 = 0x80; // Busy
    pub const DRDY: u8 = 0x40; // Device ready
    pub const DF: u8 = 0x20; // Device fault
    pub const DSC: u8 = 0x10; // Seek complete
    pub const DRQ: u8 = 0x08; // Data request
    pub const CORR: u8 = 0x04; // Corrected data
    pub const IDX: u8 = 0x02; // Index
    pub const ERR: u8 = 0x01; // Error
};

/// ATA error register bits
pub const AtaError = struct {
    pub const BBK: u8 = 0x80; // Bad block
    pub const UNC: u8 = 0x40; // Uncorrectable error
    pub const MC: u8 = 0x20; // Media changed
    pub const IDNF: u8 = 0x10; // ID not found
    pub const MCR: u8 = 0x08; // Media change requested
    pub const ABRT: u8 = 0x04; // Aborted command
    pub const TK0NF: u8 = 0x02; // Track 0 not found
    pub const AMNF: u8 = 0x01; // Address mark not found
};

/// Controller state
pub const ControllerState = enum {
    /// Idle, ready for commands
    idle,
    /// Executing command
    busy,
    /// Data ready to be read (DRQ set)
    data_out,
    /// Waiting for data to be written (DRQ set)
    data_in,
    /// Error state
    err_state,
    /// Device is in standby/sleep
    standby,
};

/// ATA Controller simulation
pub const AtaController = struct {
    // Task file registers
    status: u8 = AtaStatus.DRDY,
    err: u8 = 0,
    sector_count: u16 = 0,
    lba: u64 = 0,
    features: u8 = 0,
    device: u8 = 0,
    command: u8 = 0,

    // Internal state
    state: ControllerState = .idle,
    disk: ?*DiskImage = null,
    identify_data: ?IdentifyData = null,

    // Transfer buffer
    transfer_buffer: [SECTOR_SIZE * MAX_TRANSFER_SECTORS]u8 = undefined,
    transfer_pos: usize = 0,
    transfer_len: usize = 0,
    sectors_remaining: u16 = 0,
    current_lba: u64 = 0,

    // Use LBA48 mode
    lba48_mode: bool = false,

    // Interrupt pending flag
    interrupt_pending: bool = false,

    const Self = @This();

    /// Initialize controller with a disk image
    pub fn init(disk: *DiskImage) Self {
        var self = Self{};
        self.attachDisk(disk);
        return self;
    }

    /// Create controller without disk (for testing)
    pub fn initNoDisk() Self {
        return Self{};
    }

    /// Attach a disk image to the controller
    pub fn attachDisk(self: *Self, disk: *DiskImage) void {
        self.disk = disk;
        self.identify_data = IdentifyData.fromDiskImage(disk);
        self.state = .idle;
        self.status = AtaStatus.DRDY;
        self.err = 0;
    }

    /// Detach the disk
    pub fn detachDisk(self: *Self) void {
        self.disk = null;
        self.identify_data = null;
        self.state = .idle;
        self.status = 0;
    }

    /// Check if a disk is attached
    pub fn hasDisk(self: *const Self) bool {
        return self.disk != null;
    }

    /// Write to command register (starts command execution)
    pub fn writeCommand(self: *Self, cmd: u8) void {
        if (!self.hasDisk()) {
            self.setError(AtaError.ABRT);
            return;
        }

        self.command = cmd;
        self.interrupt_pending = false;

        const ata_cmd = AtaCommand.fromByte(cmd);
        switch (ata_cmd) {
            .identify => self.cmdIdentify(),
            .read_sectors => self.cmdReadSectors(false),
            .read_sectors_ext => self.cmdReadSectors(true),
            .write_sectors => self.cmdWriteSectors(false),
            .write_sectors_ext => self.cmdWriteSectors(true),
            .standby_immediate, .idle_immediate, .standby, .idle => self.cmdStandby(),
            .flush_cache, .flush_cache_ext => self.cmdFlush(),
            .set_features => self.cmdSetFeatures(),
            _ => self.setError(AtaError.ABRT),
        }
    }

    /// Read data from controller (for PIO data transfer)
    pub fn readData(self: *Self, buffer: []u8) usize {
        if (self.state != .data_out) return 0;

        const available = self.transfer_len - self.transfer_pos;
        const to_read = @min(buffer.len, available);

        @memcpy(buffer[0..to_read], self.transfer_buffer[self.transfer_pos..][0..to_read]);
        self.transfer_pos += to_read;

        // Check if sector transfer complete
        if (self.transfer_pos >= self.transfer_len) {
            self.sectors_remaining -= 1;

            if (self.sectors_remaining > 0) {
                // Load next sector
                self.loadNextSector();
            } else {
                // Transfer complete
                self.state = .idle;
                self.status = AtaStatus.DRDY;
                self.interrupt_pending = true;
            }
        }

        return to_read;
    }

    /// Write data to controller (for PIO data transfer)
    pub fn writeData(self: *Self, data: []const u8) usize {
        if (self.state != .data_in) return 0;

        const available = self.transfer_len - self.transfer_pos;
        const to_write = @min(data.len, available);

        @memcpy(self.transfer_buffer[self.transfer_pos..][0..to_write], data[0..to_write]);
        self.transfer_pos += to_write;

        // Check if sector transfer complete
        if (self.transfer_pos >= self.transfer_len) {
            // Write sector to disk
            if (self.disk) |d| {
                d.writeSectors(self.current_lba, 1, self.transfer_buffer[0..SECTOR_SIZE]) catch {
                    self.setError(AtaError.UNC);
                    return to_write;
                };
            }

            self.current_lba += 1;
            self.sectors_remaining -= 1;

            if (self.sectors_remaining > 0) {
                // Ready for next sector
                self.transfer_pos = 0;
            } else {
                // Transfer complete
                self.state = .idle;
                self.status = AtaStatus.DRDY;
                self.interrupt_pending = true;
            }
        }

        return to_write;
    }

    /// Read 16-bit word from data register
    pub fn readDataWord(self: *Self) u16 {
        var buf: [2]u8 = undefined;
        _ = self.readData(&buf);
        return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
    }

    /// Write 16-bit word to data register
    pub fn writeDataWord(self: *Self, word: u16) void {
        const buf = [2]u8{ @truncate(word), @truncate(word >> 8) };
        _ = self.writeData(&buf);
    }

    /// Get current status
    pub fn getStatus(self: *const Self) u8 {
        return self.status;
    }

    /// Get error register
    pub fn getError(self: *const Self) u8 {
        return self.err;
    }

    /// Check and clear interrupt pending flag
    pub fn checkAndClearInterrupt(self: *Self) bool {
        const pending = self.interrupt_pending;
        self.interrupt_pending = false;
        return pending;
    }

    /// Set LBA registers (for command setup)
    pub fn setLba(self: *Self, lba: u64, count: u16, lba48: bool) void {
        self.lba = lba;
        self.sector_count = count;
        self.lba48_mode = lba48;
    }

    // --------------------------------------------------------
    // Command implementations
    // --------------------------------------------------------

    fn cmdIdentify(self: *Self) void {
        if (self.identify_data) |id| {
            @memcpy(self.transfer_buffer[0..512], id.getData());
            self.transfer_pos = 0;
            self.transfer_len = 512;
            self.sectors_remaining = 1;
            self.state = .data_out;
            self.status = AtaStatus.DRDY | AtaStatus.DRQ;
            self.interrupt_pending = true;
        } else {
            self.setError(AtaError.ABRT);
        }
    }

    fn cmdReadSectors(self: *Self, lba48: bool) void {
        _ = lba48;

        const count = if (self.sector_count == 0) 256 else self.sector_count;
        self.sectors_remaining = @intCast(count);
        self.current_lba = self.lba;

        // Load first sector
        self.loadNextSector();
    }

    fn loadNextSector(self: *Self) void {
        if (self.disk) |d| {
            d.readSectors(self.current_lba, 1, self.transfer_buffer[0..SECTOR_SIZE]) catch {
                self.setError(AtaError.IDNF);
                return;
            };
            self.current_lba += 1;
            self.transfer_pos = 0;
            self.transfer_len = SECTOR_SIZE;
            self.state = .data_out;
            self.status = AtaStatus.DRDY | AtaStatus.DRQ;
            self.interrupt_pending = true;
        } else {
            self.setError(AtaError.ABRT);
        }
    }

    fn cmdWriteSectors(self: *Self, lba48: bool) void {
        _ = lba48;

        const count = if (self.sector_count == 0) 256 else self.sector_count;
        self.sectors_remaining = @intCast(count);
        self.current_lba = self.lba;

        // Ready to receive first sector
        self.transfer_pos = 0;
        self.transfer_len = SECTOR_SIZE;
        self.state = .data_in;
        self.status = AtaStatus.DRDY | AtaStatus.DRQ;
    }

    fn cmdStandby(self: *Self) void {
        self.state = .standby;
        self.status = AtaStatus.DRDY;
        self.interrupt_pending = true;
    }

    fn cmdFlush(self: *Self) void {
        if (self.disk) |d| {
            d.flush() catch {
                self.setError(AtaError.ABRT);
                return;
            };
        }
        self.status = AtaStatus.DRDY;
        self.interrupt_pending = true;
    }

    fn cmdSetFeatures(self: *Self) void {
        // Accept all SET FEATURES commands silently
        self.status = AtaStatus.DRDY;
        self.interrupt_pending = true;
    }

    fn setError(self: *Self, err_code: u8) void {
        self.err = err_code;
        self.state = .err_state;
        self.status = AtaStatus.DRDY | AtaStatus.ERR;
        self.interrupt_pending = true;
    }
};

// ============================================================
// Tests
// ============================================================

test "controller init" {
    const allocator = std.testing.allocator;

    var disk = try DiskImage.createInMemory(allocator, 1000);
    defer disk.close();

    const controller = AtaController.init(&disk);

    try std.testing.expect(controller.hasDisk());
    try std.testing.expectEqual(AtaStatus.DRDY, controller.getStatus());
    try std.testing.expectEqual(.idle, controller.state);
}

test "identify command" {
    const allocator = std.testing.allocator;

    var disk = try DiskImage.createInMemory(allocator, 1000);
    defer disk.close();

    var controller = AtaController.init(&disk);

    controller.writeCommand(@intFromEnum(AtaCommand.identify));

    // Should be in data_out state with DRQ
    try std.testing.expectEqual(.data_out, controller.state);
    try std.testing.expect((controller.getStatus() & AtaStatus.DRQ) != 0);

    // Read all 512 bytes
    var buffer: [512]u8 = undefined;
    const bytes_read = controller.readData(&buffer);
    try std.testing.expectEqual(@as(usize, 512), bytes_read);

    // Should return to idle
    try std.testing.expectEqual(.idle, controller.state);
}

test "read sectors" {
    const allocator = std.testing.allocator;

    var disk = try DiskImage.createInMemory(allocator, 100);
    defer disk.close();

    // Write some test data
    var test_data: [512]u8 = undefined;
    @memset(&test_data, 0xAA);
    test_data[0] = 0x55;
    try disk.writeSectors(10, 1, &test_data);

    var controller = AtaController.init(&disk);

    // Read sector 10
    controller.setLba(10, 1, false);
    controller.writeCommand(@intFromEnum(AtaCommand.read_sectors));

    try std.testing.expectEqual(.data_out, controller.state);

    var buffer: [512]u8 = undefined;
    _ = controller.readData(&buffer);

    try std.testing.expectEqual(@as(u8, 0x55), buffer[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), buffer[1]);
    try std.testing.expectEqual(.idle, controller.state);
}

test "write sectors" {
    const allocator = std.testing.allocator;

    var disk = try DiskImage.createInMemory(allocator, 100);
    defer disk.close();

    var controller = AtaController.init(&disk);

    // Write to sector 20
    controller.setLba(20, 1, false);
    controller.writeCommand(@intFromEnum(AtaCommand.write_sectors));

    try std.testing.expectEqual(.data_in, controller.state);

    var write_data: [512]u8 = undefined;
    @memset(&write_data, 0xBB);
    write_data[0] = 0xCC;
    _ = controller.writeData(&write_data);

    try std.testing.expectEqual(.idle, controller.state);

    // Verify by reading back from disk
    var read_buf: [512]u8 = undefined;
    try disk.readSectors(20, 1, &read_buf);
    try std.testing.expectEqual(@as(u8, 0xCC), read_buf[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), read_buf[1]);
}

test "multi-sector read" {
    const allocator = std.testing.allocator;

    var disk = try DiskImage.createInMemory(allocator, 100);
    defer disk.close();

    // Write test pattern
    var sector_data: [512]u8 = undefined;
    for (0..3) |i| {
        @memset(&sector_data, @as(u8, @intCast(i + 1)));
        try disk.writeSectors(i, 1, &sector_data);
    }

    var controller = AtaController.init(&disk);

    // Read 3 sectors starting at LBA 0
    controller.setLba(0, 3, false);
    controller.writeCommand(@intFromEnum(AtaCommand.read_sectors));

    var buffer: [512]u8 = undefined;

    // Read sector 1
    _ = controller.readData(&buffer);
    try std.testing.expectEqual(@as(u8, 1), buffer[0]);

    // Read sector 2
    _ = controller.readData(&buffer);
    try std.testing.expectEqual(@as(u8, 2), buffer[0]);

    // Read sector 3
    _ = controller.readData(&buffer);
    try std.testing.expectEqual(@as(u8, 3), buffer[0]);

    try std.testing.expectEqual(.idle, controller.state);
}

test "standby command" {
    const allocator = std.testing.allocator;

    var disk = try DiskImage.createInMemory(allocator, 100);
    defer disk.close();

    var controller = AtaController.init(&disk);
    controller.writeCommand(@intFromEnum(AtaCommand.standby_immediate));

    try std.testing.expectEqual(.standby, controller.state);
    try std.testing.expect(controller.checkAndClearInterrupt());
}

test "no disk error" {
    var controller = AtaController.initNoDisk();
    controller.writeCommand(@intFromEnum(AtaCommand.identify));

    try std.testing.expectEqual(.err_state, controller.state);
    try std.testing.expect((controller.getStatus() & AtaStatus.ERR) != 0);
}

test "word access" {
    const allocator = std.testing.allocator;

    var disk = try DiskImage.createInMemory(allocator, 100);
    defer disk.close();

    var controller = AtaController.init(&disk);

    // Write using words
    controller.setLba(0, 1, false);
    controller.writeCommand(@intFromEnum(AtaCommand.write_sectors));

    // Write 256 words (512 bytes)
    for (0..256) |i| {
        controller.writeDataWord(@as(u16, @intCast(i)));
    }

    // Read back
    controller.setLba(0, 1, false);
    controller.writeCommand(@intFromEnum(AtaCommand.read_sectors));

    for (0..256) |i| {
        const word = controller.readDataWord();
        try std.testing.expectEqual(@as(u16, @intCast(i)), word);
    }
}
