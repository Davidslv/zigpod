//! PP5021C ATA/IDE Controller
//!
//! Implements the ATA controller for the PP5021C SoC.
//!
//! CRITICAL: The PP5021C uses 4-byte aligned ATA registers!
//! This is different from standard ATA where task file registers
//! are at 1-byte offsets.
//!
//! Reference: Rockbox firmware/target/arm/pp/ata-pp5020.c
//!            Rockbox firmware/target/arm/pp/ata-target.h
//!
//! Register Map (base 0xC3000000):
//! - 0x000: IDE0_PRI_TIMING0 - PIO timing
//! - 0x004: IDE0_PRI_TIMING1 - DMA timing
//! - 0x028: IDE0_CFG - Configuration (bit 5=PIO enable, bit 28=>65MHz)
//! - 0x1E0: ATA_DATA - Data register (16-bit)
//! - 0x1E4: ATA_ERROR/ATA_FEATURE - Error (read) / Feature (write)
//! - 0x1E8: ATA_NSECTOR - Sector count
//! - 0x1EC: ATA_SECTOR - LBA bits 0-7
//! - 0x1F0: ATA_LCYL - LBA bits 8-15
//! - 0x1F4: ATA_HCYL - LBA bits 16-23
//! - 0x1F8: ATA_SELECT - Drive/head select (LBA bits 24-27)
//! - 0x1FC: ATA_COMMAND/ATA_STATUS - Command (write) / Status (read)
//! - 0x3F8: ATA_CONTROL - Device control (bit 1=nIEN, bit 2=SRST)
//! - 0x3FC: ATA_ALT_STATUS - Alternate status (read-only)

const std = @import("std");
const bus = @import("../memory/bus.zig");
const interrupt_ctrl = @import("interrupt_ctrl.zig");

/// ATA Status Register bits
pub const Status = struct {
    pub const ERR: u8 = 0x01; // Error
    pub const IDX: u8 = 0x02; // Index
    pub const CORR: u8 = 0x04; // Corrected data
    pub const DRQ: u8 = 0x08; // Data request
    pub const DSC: u8 = 0x10; // Device seek complete
    pub const DWF: u8 = 0x20; // Device write fault
    pub const DRDY: u8 = 0x40; // Device ready
    pub const BSY: u8 = 0x80; // Busy
};

/// ATA Commands
pub const Command = struct {
    pub const IDENTIFY: u8 = 0xEC;
    pub const READ_SECTORS: u8 = 0x20;
    pub const READ_SECTORS_EXT: u8 = 0x24;
    pub const WRITE_SECTORS: u8 = 0x30;
    pub const WRITE_SECTORS_EXT: u8 = 0x34;
    pub const SET_FEATURES: u8 = 0xEF;
    pub const STANDBY_IMMEDIATE: u8 = 0xE0;
    pub const IDLE_IMMEDIATE: u8 = 0xE1;
    pub const FLUSH_CACHE: u8 = 0xE7;
    pub const FLUSH_CACHE_EXT: u8 = 0xEA;
    pub const SET_MULTIPLE: u8 = 0xC6;
    pub const READ_MULTIPLE: u8 = 0xC4;
    pub const WRITE_MULTIPLE: u8 = 0xC5;
};

/// ATA Controller state
pub const AtaController = struct {
    // Task file registers
    data: u16,
    err: u8, // "error" register (renamed to avoid keyword)
    feature: u8,
    sector_count: u8,
    sector_num: u8, // LBA 0-7
    cylinder_low: u8, // LBA 8-15
    cylinder_high: u8, // LBA 16-23
    head: u8, // Drive/head + LBA 24-27
    status: u8,
    command: u8,
    control: u8,

    // LBA48 high bytes
    sector_count_high: u8,
    lba_high: [3]u8,

    // Configuration registers
    timing0: u32,
    timing1: u32,
    config: u32,

    // Data transfer state
    data_buffer: [512]u8,
    buffer_pos: u16,
    buffer_len: u16,
    sectors_remaining: u16,
    is_read: bool,
    is_write: bool,

    // LBA mode flag
    lba_mode: bool,

    // Disk image backend
    disk: ?*DiskBackend,

    // Interrupt controller
    int_ctrl: ?*interrupt_ctrl.InterruptController,

    const Self = @This();

    /// Register offsets (4-byte aligned!)
    const REG_TIMING0: u32 = 0x000;
    const REG_TIMING1: u32 = 0x004;
    const REG_CFG: u32 = 0x028;
    const REG_DATA: u32 = 0x1E0;
    const REG_ERROR: u32 = 0x1E4;
    const REG_NSECTOR: u32 = 0x1E8;
    const REG_SECTOR: u32 = 0x1EC;
    const REG_LCYL: u32 = 0x1F0;
    const REG_HCYL: u32 = 0x1F4;
    const REG_SELECT: u32 = 0x1F8;
    const REG_COMMAND: u32 = 0x1FC;
    const REG_CONTROL: u32 = 0x3F8;
    const REG_ALT_STATUS: u32 = 0x3FC;

    /// Config register bits
    const CFG_PIO_ENABLE: u32 = 1 << 5;
    const CFG_HIGH_SPEED: u32 = 1 << 28;

    pub fn init() Self {
        return .{
            .data = 0,
            .err = 0,
            .feature = 0,
            .sector_count = 0,
            .sector_num = 0,
            .cylinder_low = 0,
            .cylinder_high = 0,
            .head = 0,
            .status = Status.DRDY | Status.DSC,
            .command = 0,
            .control = 0,
            .sector_count_high = 0,
            .lba_high = [_]u8{0} ** 3,
            .timing0 = 0,
            .timing1 = 0,
            .config = 0,
            .data_buffer = [_]u8{0} ** 512,
            .buffer_pos = 0,
            .buffer_len = 0,
            .sectors_remaining = 0,
            .is_read = false,
            .is_write = false,
            .lba_mode = false,
            .disk = null,
            .int_ctrl = null,
        };
    }

    /// Set disk backend
    pub fn setDisk(self: *Self, disk: *DiskBackend) void {
        self.disk = disk;
    }

    /// Set interrupt controller
    pub fn setInterruptController(self: *Self, ctrl: *interrupt_ctrl.InterruptController) void {
        self.int_ctrl = ctrl;
    }

    /// Get current LBA address
    fn getLba(self: *const Self) u64 {
        if (self.lba_mode) {
            // LBA28 mode
            const lba28: u32 = @as(u32, self.sector_num) |
                (@as(u32, self.cylinder_low) << 8) |
                (@as(u32, self.cylinder_high) << 16) |
                (@as(u32, self.head & 0x0F) << 24);
            return lba28;
        } else {
            // CHS mode (not commonly used)
            // Convert CHS to LBA
            const cylinder = @as(u16, self.cylinder_low) | (@as(u16, self.cylinder_high) << 8);
            const head = self.head & 0x0F;
            const sector = self.sector_num;
            // This is a simplified conversion; real conversion depends on drive geometry
            return (@as(u64, cylinder) * 16 + head) * 63 + sector - 1;
        }
    }

    /// Set LBA address
    fn setLba(self: *Self, lba: u64) void {
        self.sector_num = @truncate(lba & 0xFF);
        self.cylinder_low = @truncate((lba >> 8) & 0xFF);
        self.cylinder_high = @truncate((lba >> 16) & 0xFF);
        self.head = (self.head & 0xF0) | @as(u8, @truncate((lba >> 24) & 0x0F));
    }

    /// Execute a command
    fn executeCommand(self: *Self, cmd: u8) void {
        self.command = cmd;
        self.status = Status.BSY;
        self.err = 0;

        switch (cmd) {
            Command.IDENTIFY => self.doIdentify(),
            Command.READ_SECTORS => self.doReadSectors(),
            Command.WRITE_SECTORS => self.doWriteSectors(),
            Command.FLUSH_CACHE, Command.FLUSH_CACHE_EXT => {
                // Flush is a no-op for our emulated disk
                self.status = Status.DRDY | Status.DSC;
                self.assertInterrupt();
            },
            Command.STANDBY_IMMEDIATE, Command.IDLE_IMMEDIATE => {
                // Power commands are no-ops
                self.status = Status.DRDY | Status.DSC;
                self.assertInterrupt();
            },
            Command.SET_FEATURES => {
                // Accept all feature settings
                self.status = Status.DRDY | Status.DSC;
                self.assertInterrupt();
            },
            else => {
                // Unknown command
                self.err = 0x04; // Aborted command
                self.status = Status.DRDY | Status.ERR;
                self.assertInterrupt();
            },
        }
    }

    /// Handle IDENTIFY command
    fn doIdentify(self: *Self) void {
        @memset(&self.data_buffer, 0);

        // Word 0: General configuration
        self.data_buffer[0] = 0x00;
        self.data_buffer[1] = 0x00;

        // Words 10-19: Serial number (20 characters)
        const serial = "ZigPod-iFlash-Solo01";
        @memcpy(self.data_buffer[20..40], serial);

        // Words 23-26: Firmware revision (8 characters)
        const firmware = "1.0.0   ";
        @memcpy(self.data_buffer[46..54], firmware);

        // Words 27-46: Model number (40 characters)
        const model = "iFlash Solo CF Adapter                  ";
        @memcpy(self.data_buffer[54..94], model);

        // Word 47: Max sectors per R/W multiple
        self.data_buffer[94] = 16; // 16 sectors max
        self.data_buffer[95] = 0x80;

        // Word 49: Capabilities
        self.data_buffer[98] = 0x00;
        self.data_buffer[99] = 0x02; // LBA supported

        // Word 60-61: Total addressable sectors (LBA28)
        if (self.disk) |disk| {
            const sectors: u32 = @truncate(disk.sector_count);
            self.data_buffer[120] = @truncate(sectors);
            self.data_buffer[121] = @truncate(sectors >> 8);
            self.data_buffer[122] = @truncate(sectors >> 16);
            self.data_buffer[123] = @truncate(sectors >> 24);
        } else {
            // Default to 30GB
            const sectors: u32 = 30 * 1024 * 1024 * 2; // 30GB in 512-byte sectors
            self.data_buffer[120] = @truncate(sectors);
            self.data_buffer[121] = @truncate(sectors >> 8);
            self.data_buffer[122] = @truncate(sectors >> 16);
            self.data_buffer[123] = @truncate(sectors >> 24);
        }

        // Word 83: Command set supported
        self.data_buffer[166] = 0x00;
        self.data_buffer[167] = 0x40; // LBA48 supported

        self.buffer_pos = 0;
        self.buffer_len = 512;
        self.is_read = true;
        self.status = Status.DRDY | Status.DRQ;
        self.assertInterrupt();
    }

    /// Handle READ SECTORS command
    fn doReadSectors(self: *Self) void {
        const count = if (self.sector_count == 0) 256 else @as(u16, self.sector_count);
        self.sectors_remaining = count;
        self.readNextSector();
    }

    /// Read next sector into buffer
    fn readNextSector(self: *Self) void {
        if (self.sectors_remaining == 0) {
            self.is_read = false;
            self.status = Status.DRDY | Status.DSC;
            return;
        }

        const lba = self.getLba();

        if (self.disk) |disk| {
            if (!disk.read(lba, &self.data_buffer)) {
                // Read error
                self.err = 0x04;
                self.status = Status.DRDY | Status.ERR;
                self.assertInterrupt();
                return;
            }
        } else {
            // No disk attached - return zeros
            @memset(&self.data_buffer, 0);
        }

        self.buffer_pos = 0;
        self.buffer_len = 512;
        self.is_read = true;
        self.status = Status.DRDY | Status.DRQ;
        self.assertInterrupt();
    }

    /// Handle WRITE SECTORS command
    fn doWriteSectors(self: *Self) void {
        const count = if (self.sector_count == 0) 256 else @as(u16, self.sector_count);
        self.sectors_remaining = count;
        self.buffer_pos = 0;
        self.buffer_len = 512;
        self.is_write = true;
        self.status = Status.DRDY | Status.DRQ;
        // No interrupt until first sector is received
    }

    /// Write current buffer to disk
    fn writeCurrentSector(self: *Self) void {
        const lba = self.getLba();

        if (self.disk) |disk| {
            if (!disk.write(lba, &self.data_buffer)) {
                // Write error
                self.err = 0x04;
                self.status = Status.DRDY | Status.ERR;
                self.assertInterrupt();
                return;
            }
        }

        self.sectors_remaining -= 1;
        self.setLba(lba + 1);

        if (self.sectors_remaining > 0) {
            // More sectors to write
            self.buffer_pos = 0;
            self.status = Status.DRDY | Status.DRQ;
        } else {
            // Write complete
            self.is_write = false;
            self.status = Status.DRDY | Status.DSC;
        }

        self.assertInterrupt();
    }

    /// Assert IDE interrupt
    fn assertInterrupt(self: *Self) void {
        // Only if interrupts are enabled (nIEN = 0)
        if ((self.control & 0x02) == 0) {
            if (self.int_ctrl) |ctrl| {
                ctrl.assertInterrupt(.ide);
            }
        }
    }

    /// Read register
    pub fn read(self: *Self, offset: u32) u32 {
        return switch (offset) {
            REG_TIMING0 => self.timing0,
            REG_TIMING1 => self.timing1,
            REG_CFG => self.config,
            REG_DATA => blk: {
                if (!self.is_read or self.buffer_pos >= self.buffer_len) {
                    break :blk 0;
                }
                const lo = self.data_buffer[self.buffer_pos];
                const hi = if (self.buffer_pos + 1 < self.buffer_len)
                    self.data_buffer[self.buffer_pos + 1]
                else
                    0;
                self.buffer_pos += 2;

                // Check if sector is complete
                if (self.buffer_pos >= self.buffer_len) {
                    if (self.sectors_remaining > 0) {
                        self.sectors_remaining -= 1;
                        const lba = self.getLba();
                        self.setLba(lba + 1);
                        self.readNextSector();
                    } else {
                        self.is_read = false;
                        self.status = Status.DRDY | Status.DSC;
                    }
                }

                break :blk @as(u32, lo) | (@as(u32, hi) << 8);
            },
            REG_ERROR => self.err,
            REG_NSECTOR => self.sector_count,
            REG_SECTOR => self.sector_num,
            REG_LCYL => self.cylinder_low,
            REG_HCYL => self.cylinder_high,
            REG_SELECT => self.head,
            REG_COMMAND => self.status, // Reading command register returns status
            REG_CONTROL => self.control,
            REG_ALT_STATUS => self.status, // Alt status doesn't clear interrupt
            else => 0,
        };
    }

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        switch (offset) {
            REG_TIMING0 => self.timing0 = value,
            REG_TIMING1 => self.timing1 = value,
            REG_CFG => self.config = value,
            REG_DATA => {
                if (!self.is_write or self.buffer_pos >= self.buffer_len) {
                    return;
                }
                self.data_buffer[self.buffer_pos] = @truncate(value);
                if (self.buffer_pos + 1 < self.buffer_len) {
                    self.data_buffer[self.buffer_pos + 1] = @truncate(value >> 8);
                }
                self.buffer_pos += 2;

                // Check if sector is complete
                if (self.buffer_pos >= self.buffer_len) {
                    self.writeCurrentSector();
                }
            },
            REG_ERROR => self.feature = @truncate(value), // Feature register
            REG_NSECTOR => self.sector_count = @truncate(value),
            REG_SECTOR => self.sector_num = @truncate(value),
            REG_LCYL => self.cylinder_low = @truncate(value),
            REG_HCYL => self.cylinder_high = @truncate(value),
            REG_SELECT => {
                self.head = @truncate(value);
                self.lba_mode = (value & 0x40) != 0;
            },
            REG_COMMAND => {
                // Clear interrupt on command register read
                if (self.int_ctrl) |ctrl| {
                    ctrl.clearInterrupt(.ide);
                }
                self.executeCommand(@truncate(value));
            },
            REG_CONTROL => {
                const old_srst = self.control & 0x04;
                self.control = @truncate(value);
                // Check for software reset
                if ((old_srst != 0) and ((value & 0x04) == 0)) {
                    // Reset released
                    self.status = Status.DRDY | Status.DSC;
                    self.err = 0x01; // Diagnostic passed
                }
            },
            REG_ALT_STATUS => {}, // Read-only
            else => {},
        }
    }

    /// Create a peripheral handler for the memory bus
    pub fn createHandler(self: *Self) bus.PeripheralHandler {
        return .{
            .context = @ptrCast(self),
            .readFn = readWrapper,
            .writeFn = writeWrapper,
        };
    }

    fn readWrapper(ctx: *anyopaque, offset: u32) u32 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.read(offset);
    }

    fn writeWrapper(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write(offset, value);
    }
};

/// Disk backend interface
pub const DiskBackend = struct {
    context: *anyopaque,
    sector_count: u64,
    readFn: *const fn (*anyopaque, u64, *[512]u8) bool,
    writeFn: *const fn (*anyopaque, u64, *const [512]u8) bool,

    pub fn read(self: *DiskBackend, lba: u64, buffer: *[512]u8) bool {
        if (lba >= self.sector_count) return false;
        return self.readFn(self.context, lba, buffer);
    }

    pub fn write(self: *DiskBackend, lba: u64, buffer: *const [512]u8) bool {
        if (lba >= self.sector_count) return false;
        return self.writeFn(self.context, lba, buffer);
    }
};

/// RAM-backed disk for testing
pub const RamDisk = struct {
    data: []u8,
    sector_count: u64,

    const Self = @This();

    pub fn init(data: []u8) Self {
        return .{
            .data = data,
            .sector_count = data.len / 512,
        };
    }

    pub fn createBackend(self: *Self) DiskBackend {
        return .{
            .context = @ptrCast(self),
            .sector_count = self.sector_count,
            .readFn = readSector,
            .writeFn = writeSector,
        };
    }

    fn readSector(ctx: *anyopaque, lba: u64, buffer: *[512]u8) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const offset = lba * 512;
        if (offset + 512 > self.data.len) return false;
        @memcpy(buffer, self.data[offset..][0..512]);
        return true;
    }

    fn writeSector(ctx: *anyopaque, lba: u64, buffer: *const [512]u8) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const offset = lba * 512;
        if (offset + 512 > self.data.len) return false;
        @memcpy(self.data[offset..][0..512], buffer);
        return true;
    }
};

// Tests
test "ATA register addresses are 4-byte aligned" {
    // Verify our register addresses match the PP5021C layout
    try std.testing.expectEqual(@as(u32, 0x1E0), AtaController.REG_DATA);
    try std.testing.expectEqual(@as(u32, 0x1E4), AtaController.REG_ERROR);
    try std.testing.expectEqual(@as(u32, 0x1E8), AtaController.REG_NSECTOR);
    try std.testing.expectEqual(@as(u32, 0x1EC), AtaController.REG_SECTOR);
    try std.testing.expectEqual(@as(u32, 0x1F0), AtaController.REG_LCYL);
    try std.testing.expectEqual(@as(u32, 0x1F4), AtaController.REG_HCYL);
    try std.testing.expectEqual(@as(u32, 0x1F8), AtaController.REG_SELECT);
    try std.testing.expectEqual(@as(u32, 0x1FC), AtaController.REG_COMMAND);
    try std.testing.expectEqual(@as(u32, 0x3F8), AtaController.REG_CONTROL);
}

test "ATA IDENTIFY command" {
    var ata = AtaController.init();

    // Select LBA mode
    ata.write(AtaController.REG_SELECT, 0xE0);

    // Issue IDENTIFY
    ata.write(AtaController.REG_COMMAND, Command.IDENTIFY);

    // Check status
    try std.testing.expect((ata.status & Status.DRQ) != 0);
    try std.testing.expect((ata.status & Status.BSY) == 0);

    // Read data
    var buffer: [512]u8 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const word = ata.read(AtaController.REG_DATA);
        buffer[i * 2] = @truncate(word);
        buffer[i * 2 + 1] = @truncate(word >> 8);
    }

    // Check that DRQ is cleared after reading all data
    try std.testing.expect((ata.status & Status.DRQ) == 0);
}

test "ATA read sector with RAM disk" {
    // Create a RAM disk with some data
    var disk_data = [_]u8{0} ** (512 * 16);
    disk_data[510] = 0x55; // MBR signature
    disk_data[511] = 0xAA;

    var ramdisk = RamDisk.init(&disk_data);
    var backend = ramdisk.createBackend();

    var ata = AtaController.init();
    ata.setDisk(&backend);

    // Select LBA mode
    ata.write(AtaController.REG_SELECT, 0xE0);

    // Set LBA to 0
    ata.write(AtaController.REG_SECTOR, 0);
    ata.write(AtaController.REG_LCYL, 0);
    ata.write(AtaController.REG_HCYL, 0);

    // Read 1 sector
    ata.write(AtaController.REG_NSECTOR, 1);
    ata.write(AtaController.REG_COMMAND, Command.READ_SECTORS);

    // Check DRQ is set
    try std.testing.expect((ata.status & Status.DRQ) != 0);

    // Read the sector
    var buffer: [512]u8 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const word = ata.read(AtaController.REG_DATA);
        buffer[i * 2] = @truncate(word);
        buffer[i * 2 + 1] = @truncate(word >> 8);
    }

    // Verify MBR signature
    try std.testing.expectEqual(@as(u8, 0x55), buffer[510]);
    try std.testing.expectEqual(@as(u8, 0xAA), buffer[511]);
}
