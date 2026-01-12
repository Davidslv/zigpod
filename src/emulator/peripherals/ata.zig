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

    // Multiple mode sector count
    multiple_count: u8,

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
            .multiple_count = 1,
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

    // Debug: track commands
    pub var debug_last_cmd: u8 = 0;
    pub var debug_cmd_count: u32 = 0;

    /// Execute a command
    fn executeCommand(self: *Self, cmd: u8) void {
        self.command = cmd;
        debug_last_cmd = cmd;
        debug_cmd_count += 1;
        self.status = Status.BSY;
        self.err = 0;

        switch (cmd) {
            Command.IDENTIFY => self.doIdentify(),
            Command.READ_SECTORS, Command.READ_MULTIPLE => self.doReadSectors(),
            Command.WRITE_SECTORS, Command.WRITE_MULTIPLE => self.doWriteSectors(),
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
            Command.SET_MULTIPLE => {
                // Set multiple mode - store block count
                // sector_count contains the block size (sectors per block)
                self.multiple_count = if (self.sector_count == 0) 1 else self.sector_count;
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

    /// Copy ATA string with byte swapping (ATA swaps bytes within each 16-bit word)
    fn copyAtaString(dest: []u8, src: []const u8) void {
        var i: usize = 0;
        while (i < dest.len and i < src.len) : (i += 2) {
            // Swap bytes within each word
            if (i + 1 < src.len and i + 1 < dest.len) {
                dest[i] = src[i + 1];
                dest[i + 1] = src[i];
            } else if (i < src.len and i < dest.len) {
                dest[i] = ' ';
                if (i + 1 < dest.len) dest[i + 1] = src[i];
            }
        }
        // Pad remainder with spaces (swapped)
        while (i < dest.len) : (i += 2) {
            dest[i] = ' ';
            if (i + 1 < dest.len) dest[i + 1] = ' ';
        }
    }

    /// Handle IDENTIFY command
    fn doIdentify(self: *Self) void {
        @memset(&self.data_buffer, 0);

        // Word 0: General configuration
        self.data_buffer[0] = 0x00;
        self.data_buffer[1] = 0x00;

        // Words 10-19: Serial number (20 characters, ATA byte-swapped)
        const serial = "ZigPod-iFlash-Solo01";
        copyAtaString(self.data_buffer[20..40], serial);

        // Words 23-26: Firmware revision (8 characters, ATA byte-swapped)
        const firmware = "1.0.0   ";
        copyAtaString(self.data_buffer[46..54], firmware);

        // Words 27-46: Model number (40 characters, ATA byte-swapped)
        const model = "iFlash Solo CF Adapter                  ";
        copyAtaString(self.data_buffer[54..94], model);

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

        // Debug: trace which sectors are being read
        std.debug.print("ATA: READ LBA={} (remaining={})\n", .{ lba, self.sectors_remaining });

        debug_disk_reads += 1;
        if (self.disk) |disk| {
            if (!disk.read(lba, &self.data_buffer)) {
                // Read error
                self.err = 0x04;
                self.status = Status.DRDY | Status.ERR;
                self.assertInterrupt();
                return;
            }
            debug_disk_read_success += 1;

            // Debug: dump directory entries for sectors 2055 and 2056
            if (lba == 2055 or lba == 2056) {
                std.debug.print("=== Sector {} directory entries ===\n", .{lba});
                var entry_idx: usize = 0;
                while (entry_idx < 4) : (entry_idx += 1) {
                    const offset = entry_idx * 32;
                    const name_slice = self.data_buffer[offset .. offset + 11];
                    const attr = self.data_buffer[offset + 11];
                    const cluster_lo = @as(u16, self.data_buffer[offset + 26]) |
                        (@as(u16, self.data_buffer[offset + 27]) << 8);
                    std.debug.print("  Entry {}: name=", .{entry_idx});
                    for (name_slice) |c| {
                        if (c >= 0x20 and c < 0x7f) {
                            std.debug.print("{c}", .{c});
                        } else {
                            std.debug.print(".", .{});
                        }
                    }
                    std.debug.print(" attr=0x{X:0>2} cluster={}\n", .{ attr, cluster_lo });
                }
            }

            // Capture MBR signature if sector 0
            if (lba == 0) {
                debug_sector0_in_buffer = true;
                debug_sector0_loads += 1;
                debug_mbr_sig = @as(u16, self.data_buffer[510]) |
                    (@as(u16, self.data_buffer[511]) << 8);
                // Capture partition 1 type and sector count for debugging
                debug_part1_type = self.data_buffer[0x1C2];
                debug_part1_lba = @as(u32, self.data_buffer[0x1C6]) |
                    (@as(u32, self.data_buffer[0x1C7]) << 8) |
                    (@as(u32, self.data_buffer[0x1C8]) << 16) |
                    (@as(u32, self.data_buffer[0x1C9]) << 24);
                debug_part1_sectors = @as(u32, self.data_buffer[0x1CA]) |
                    (@as(u32, self.data_buffer[0x1CB]) << 8) |
                    (@as(u32, self.data_buffer[0x1CC]) << 16) |
                    (@as(u32, self.data_buffer[0x1CD]) << 24);
            } else {
                debug_sector0_in_buffer = false;
            }
        } else {
            // No disk attached - return zeros
            debug_disk_null += 1;
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

    /// Debug counters
    pub var debug_data_reads: u32 = 0;
    pub var debug_data_reads_not_ready: u32 = 0;
    pub var debug_last_buffer_byte: u8 = 0;
    pub var debug_disk_reads: u32 = 0;
    pub var debug_disk_read_success: u32 = 0;
    pub var debug_disk_null: u32 = 0;
    pub var debug_mbr_sig: u16 = 0;
    pub var debug_part1_type: u8 = 0;
    pub var debug_part1_lba: u32 = 0;
    pub var debug_part1_sectors: u32 = 0;
    pub var debug_part_bytes: [16]u8 = [_]u8{0} ** 16;
    pub var debug_part_bytes_captured: u8 = 0;
    pub var debug_sector0_in_buffer: bool = false;
    pub var debug_sector0_loads: u32 = 0; // How many times sector 0 was loaded
    // Track partition-related data returns
    pub var debug_part_word_0xE0: u32 = 0; // Word at 0x1C0 (offset 224)
    pub var debug_part_word_0xE1: u32 = 0; // Word at 0x1C2 (type byte)
    pub var debug_part_word_0xE3: u32 = 0; // Word at 0x1C6 (LBA low)
    pub var debug_part_word_0xE4: u32 = 0; // Word at 0x1C8 (LBA high)
    pub var debug_part_word_0xE5: u32 = 0; // Word at 0x1CA (sectors low)
    pub var debug_part_word_0xE6: u32 = 0; // Word at 0x1CC (sectors high)
    pub var debug_s0_words_read: u32 = 0; // How many words read from sector 0
    // Track first 8 words returned
    pub var debug_first_8_words: [8]u16 = [_]u16{0} ** 8;
    pub var debug_first_8_captured: bool = false;
    // Track words at partition offset
    pub var debug_s0_word_at_1be: u16 = 0; // Word at 0x1BE
    pub var debug_s0_word_at_1c0: u16 = 0; // Word at 0x1C0
    pub var debug_s0_word_at_1c2: u16 = 0; // Word at 0x1C2 (type byte)
    pub var debug_s0_word_at_1fe: u16 = 0; // Word at 0x1FE (boot sig)

    /// Read register
    pub fn read(self: *Self, offset: u32) u32 {
        return switch (offset) {
            REG_TIMING0 => self.timing0,
            REG_TIMING1 => self.timing1,
            REG_CFG => self.config,
            REG_DATA => blk: {
                debug_data_reads += 1;
                if (!self.is_read or self.buffer_pos >= self.buffer_len) {
                    debug_data_reads_not_ready += 1;
                    break :blk 0;
                }
                // Capture partition table area (0x1BE-0x1CD) when reading sector 0
                if (debug_part_bytes_captured == 0 and debug_sector0_in_buffer and self.buffer_pos == 0) {
                    // Capture the whole partition entry when starting to read sector 0
                    var i: usize = 0;
                    while (i < 16) : (i += 1) {
                        debug_part_bytes[i] = self.data_buffer[0x1BE + i];
                    }
                    debug_part_bytes_captured = 16;
                }
                const lo = self.data_buffer[self.buffer_pos];
                const hi = if (self.buffer_pos + 1 < self.buffer_len)
                    self.data_buffer[self.buffer_pos + 1]
                else
                    0;
                const word: u32 = @as(u32, lo) | (@as(u32, hi) << 8);

                // Track partition-related word returns for sector 0
                if (debug_sector0_in_buffer) {
                    debug_s0_words_read += 1;
                    // Capture first 8 words of first sector 0 read
                    if (!debug_first_8_captured and self.buffer_pos < 16) {
                        debug_first_8_words[self.buffer_pos / 2] = @truncate(word);
                        if (self.buffer_pos == 14) {
                            debug_first_8_captured = true;
                        }
                    }
                    // buffer_pos is the current position BEFORE incrementing
                    // Capture specific partition-related words
                    switch (self.buffer_pos) {
                        0x1BE => debug_s0_word_at_1be = @truncate(word),
                        0x1C0 => {
                            debug_part_word_0xE0 = word;
                            debug_s0_word_at_1c0 = @truncate(word);
                        },
                        0x1C2 => {
                            debug_part_word_0xE1 = word;
                            debug_s0_word_at_1c2 = @truncate(word);
                        },
                        0x1C6 => debug_part_word_0xE3 = word,
                        0x1C8 => debug_part_word_0xE4 = word,
                        0x1CA => debug_part_word_0xE5 = word,
                        0x1CC => debug_part_word_0xE6 = word,
                        0x1FE => debug_s0_word_at_1fe = @truncate(word),
                        else => {},
                    }
                }
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

                break :blk word;
            },
            REG_ERROR => self.err,
            REG_NSECTOR => self.sector_count,
            REG_SECTOR => self.sector_num,
            REG_LCYL => self.cylinder_low,
            REG_HCYL => self.cylinder_high,
            REG_SELECT => self.head,
            REG_COMMAND => self.status, // Reading command register returns status
            REG_CONTROL => self.status, // Reading control register returns alternate status (no interrupt clear)
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
