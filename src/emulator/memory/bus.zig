//! PP5021C Memory Bus
//!
//! Implements the memory map for the PP5021C SoC as used in iPod 5th/5.5th Gen.
//! Routes memory accesses to the appropriate handler (RAM, ROM, peripherals).
//!
//! Memory Map (from Rockbox):
//! - 0x00000000-0x0001FFFF: Boot ROM (128KB, read-only)
//! - 0x10000000-0x11FFFFFF: SDRAM (32MB for 30GB, 64MB for 60/80GB)
//! - 0x30000000-0x30070000: BCM2722 LCD Controller
//! - 0x40000000-0x40017FFF: IRAM (96KB, fast internal RAM)
//! - 0x60004000-0x600041FF: Interrupt Controller
//! - 0x60005000-0x6000503F: Timers
//! - 0x60006000-0x600063FF: System Controller
//! - 0x6000A000-0x6000BFFF: DMA Controller
//! - 0x6000D000-0x6000D2FF: GPIO
//! - 0x70000000-0x7000007F: Device Init
//! - 0x70000080-0x700000FF: GPO32
//! - 0x70002800-0x700028FF: I2S Audio
//! - 0x7000C000-0x7000C0FF: I2C Controller
//! - 0x7000C100-0x7000C1FF: Click Wheel
//! - 0xC3000000-0xC30003FF: ATA/IDE Controller (4-byte aligned!)

const std = @import("std");

/// Memory region identifiers
pub const Region = enum {
    boot_rom,
    sdram,
    iram,
    lcd,
    lcd_bridge, // LCD2 bridge at 0x70008a00 (what Rockbox uses)
    interrupt_ctrl,
    timers,
    system_ctrl,
    cache_ctrl,
    dma,
    gpio,
    device_init,
    gpo32,
    i2s,
    i2c,
    clickwheel,
    ata,
    unmapped,
};

/// Peripheral handler interface
pub const PeripheralHandler = struct {
    context: *anyopaque,
    readFn: *const fn (*anyopaque, u32) u32,
    writeFn: *const fn (*anyopaque, u32, u32) void,

    pub fn read(self: *const PeripheralHandler, offset: u32) u32 {
        return self.readFn(self.context, offset);
    }

    pub fn write(self: *const PeripheralHandler, offset: u32, value: u32) void {
        self.writeFn(self.context, offset, value);
    }
};

/// Memory Bus for PP5021C
pub const MemoryBus = struct {
    /// Boot ROM (128KB, loaded at startup)
    boot_rom: []const u8,

    /// SDRAM (32MB or 64MB depending on model)
    sdram: []u8,

    /// IRAM (96KB internal fast RAM)
    iram: [96 * 1024]u8,

    /// Peripheral handlers (optional, can be null for stub behavior)
    interrupt_ctrl: ?PeripheralHandler,
    timers: ?PeripheralHandler,
    system_ctrl: ?PeripheralHandler,
    cache_ctrl: ?PeripheralHandler,
    dma: ?PeripheralHandler,
    gpio: ?PeripheralHandler,
    device_init: ?PeripheralHandler,
    gpo32: ?PeripheralHandler,
    i2s: ?PeripheralHandler,
    i2c: ?PeripheralHandler,
    clickwheel: ?PeripheralHandler,
    ata: ?PeripheralHandler,
    lcd: ?PeripheralHandler,
    lcd_bridge: ?PeripheralHandler,

    /// Stub registers for unimplemented peripherals
    stub_registers: [256]u32,

    /// Access tracking for debugging
    last_access_addr: u32,
    last_access_region: Region,

    /// Debug: count of LCD writes
    lcd_write_count: u32,

    /// Debug: count of LCD bridge writes
    lcd_bridge_write_count: u32,

    const Self = @This();

    /// Boot ROM range
    const ROM_START: u32 = 0x00000000;
    const ROM_END: u32 = 0x0001FFFF;
    const ROM_SIZE: u32 = 128 * 1024;

    /// SDRAM range
    const SDRAM_START: u32 = 0x10000000;
    const SDRAM_END: u32 = 0x11FFFFFF; // 32MB, extends to 0x13FFFFFF for 64MB

    /// LCD range
    const LCD_START: u32 = 0x30000000;
    const LCD_END: u32 = 0x30070000;

    /// IRAM range
    const IRAM_START: u32 = 0x40000000;
    const IRAM_END: u32 = 0x40017FFF;
    const IRAM_SIZE: u32 = 96 * 1024;

    /// Interrupt Controller
    const INT_CTRL_START: u32 = 0x60004000;
    const INT_CTRL_END: u32 = 0x600041FF;

    /// Timers
    const TIMER_START: u32 = 0x60005000;
    const TIMER_END: u32 = 0x6000503F;

    /// System Controller
    const SYS_CTRL_START: u32 = 0x60006000;
    const SYS_CTRL_END: u32 = 0x600063FF;

    /// Cache Controller
    const CACHE_CTRL_START: u32 = 0x6000C000;
    const CACHE_CTRL_END: u32 = 0x6000C0FF;

    /// DMA
    const DMA_START: u32 = 0x6000A000;
    const DMA_END: u32 = 0x6000BFFF;

    /// GPIO
    const GPIO_START: u32 = 0x6000D000;
    const GPIO_END: u32 = 0x6000D2FF;

    /// Device Init
    const DEV_INIT_START: u32 = 0x70000000;
    const DEV_INIT_END: u32 = 0x7000007F;

    /// GPO32
    const GPO32_START: u32 = 0x70000080;
    const GPO32_END: u32 = 0x700000FF;

    /// I2S
    const I2S_START: u32 = 0x70002800;
    const I2S_END: u32 = 0x700028FF;

    /// I2C
    const I2C_START: u32 = 0x7000C000;
    const I2C_END: u32 = 0x7000C0FF;

    /// Click Wheel
    const CLICKWHEEL_START: u32 = 0x7000C100;
    const CLICKWHEEL_END: u32 = 0x7000C1FF;

    /// LCD2 Bridge (Color LCD interface used by Rockbox)
    const LCD_BRIDGE_START: u32 = 0x70008A00;
    const LCD_BRIDGE_END: u32 = 0x70008BFF;

    /// ATA/IDE (4-byte aligned registers!)
    const ATA_START: u32 = 0xC3000000;
    const ATA_END: u32 = 0xC30003FF;

    /// Initialize the memory bus
    pub fn init(sdram_size: usize, boot_rom: []const u8) Self {
        _ = sdram_size;
        return .{
            .boot_rom = boot_rom,
            .sdram = undefined, // Will be allocated externally
            .iram = [_]u8{0} ** (96 * 1024),
            .interrupt_ctrl = null,
            .timers = null,
            .system_ctrl = null,
            .cache_ctrl = null,
            .dma = null,
            .gpio = null,
            .device_init = null,
            .gpo32 = null,
            .i2s = null,
            .i2c = null,
            .clickwheel = null,
            .ata = null,
            .lcd = null,
            .lcd_bridge = null,
            .stub_registers = [_]u32{0} ** 256,
            .last_access_addr = 0,
            .last_access_region = .unmapped,
            .lcd_write_count = 0,
            .lcd_bridge_write_count = 0,
        };
    }

    /// Initialize with external SDRAM allocation
    pub fn initWithSdram(sdram: []u8, boot_rom: []const u8) Self {
        return .{
            .boot_rom = boot_rom,
            .sdram = sdram,
            .iram = [_]u8{0} ** (96 * 1024),
            .interrupt_ctrl = null,
            .timers = null,
            .system_ctrl = null,
            .cache_ctrl = null,
            .dma = null,
            .gpio = null,
            .device_init = null,
            .gpo32 = null,
            .i2s = null,
            .i2c = null,
            .clickwheel = null,
            .ata = null,
            .lcd = null,
            .lcd_bridge = null,
            .stub_registers = [_]u32{0} ** 256,
            .last_access_addr = 0,
            .last_access_region = .unmapped,
            .lcd_write_count = 0,
            .lcd_bridge_write_count = 0,
        };
    }

    /// Determine which region an address belongs to
    pub fn getRegion(addr: u32) Region {
        if (addr >= ROM_START and addr <= ROM_END) return .boot_rom;
        if (addr >= SDRAM_START and addr <= SDRAM_END) return .sdram;
        if (addr >= LCD_START and addr <= LCD_END) return .lcd;
        if (addr >= IRAM_START and addr <= IRAM_END) return .iram;
        if (addr >= INT_CTRL_START and addr <= INT_CTRL_END) return .interrupt_ctrl;
        if (addr >= TIMER_START and addr <= TIMER_END) return .timers;
        if (addr >= SYS_CTRL_START and addr <= SYS_CTRL_END) return .system_ctrl;
        if (addr >= CACHE_CTRL_START and addr <= CACHE_CTRL_END) return .cache_ctrl;
        if (addr >= DMA_START and addr <= DMA_END) return .dma;
        if (addr >= GPIO_START and addr <= GPIO_END) return .gpio;
        if (addr >= DEV_INIT_START and addr <= DEV_INIT_END) return .device_init;
        if (addr >= GPO32_START and addr <= GPO32_END) return .gpo32;
        if (addr >= I2S_START and addr <= I2S_END) return .i2s;
        if (addr >= LCD_BRIDGE_START and addr <= LCD_BRIDGE_END) return .lcd_bridge;
        if (addr >= I2C_START and addr <= I2C_END) return .i2c;
        if (addr >= CLICKWHEEL_START and addr <= CLICKWHEEL_END) return .clickwheel;
        if (addr >= ATA_START and addr <= ATA_END) return .ata;
        return .unmapped;
    }

    /// Read 8-bit value
    pub fn read8(self: *Self, addr: u32) u8 {
        const value = self.read32(addr & ~@as(u32, 3));
        const shift: u5 = @truncate((addr & 3) * 8);
        return @truncate(value >> shift);
    }

    /// Read 16-bit value
    pub fn read16(self: *Self, addr: u32) u16 {
        const value = self.read32(addr & ~@as(u32, 3));
        const shift: u5 = @truncate((addr & 2) * 8);
        return @truncate(value >> shift);
    }

    /// Read 32-bit value
    pub fn read32(self: *Self, addr: u32) u32 {
        const region = getRegion(addr);
        self.last_access_addr = addr;
        self.last_access_region = region;

        return switch (region) {
            .boot_rom => self.readRom(addr),
            .sdram => self.readSdram(addr),
            .iram => self.readIram(addr),
            .lcd => self.readPeripheral(self.lcd, addr, LCD_START),
            .interrupt_ctrl => self.readPeripheral(self.interrupt_ctrl, addr, INT_CTRL_START),
            .timers => self.readPeripheral(self.timers, addr, TIMER_START),
            .system_ctrl => self.readPeripheral(self.system_ctrl, addr, SYS_CTRL_START),
            .cache_ctrl => self.readPeripheral(self.cache_ctrl, addr, CACHE_CTRL_START),
            .dma => self.readPeripheral(self.dma, addr, DMA_START),
            .gpio => self.readPeripheral(self.gpio, addr, GPIO_START),
            .device_init => self.readPeripheral(self.device_init, addr, DEV_INIT_START),
            .gpo32 => self.readPeripheral(self.gpo32, addr, GPO32_START),
            .i2s => self.readPeripheral(self.i2s, addr, I2S_START),
            .i2c => self.readPeripheral(self.i2c, addr, I2C_START),
            .clickwheel => self.readPeripheral(self.clickwheel, addr, CLICKWHEEL_START),
            .lcd_bridge => self.readPeripheral(self.lcd_bridge, addr, LCD_BRIDGE_START),
            .ata => self.readPeripheral(self.ata, addr, ATA_START),
            .unmapped => 0, // Return 0 for unmapped addresses
        };
    }

    /// Write 8-bit value
    pub fn write8(self: *Self, addr: u32, value: u8) void {
        // Read-modify-write for byte access to 32-bit registers
        const aligned = addr & ~@as(u32, 3);
        const shift: u5 = @truncate((addr & 3) * 8);
        const mask: u32 = @as(u32, 0xFF) << shift;

        const region = getRegion(addr);
        if (region == .sdram or region == .iram) {
            // Direct byte write to RAM
            if (region == .sdram) {
                const offset = addr - SDRAM_START;
                if (offset < self.sdram.len) {
                    self.sdram[offset] = value;
                }
            } else {
                const offset = addr - IRAM_START;
                if (offset < IRAM_SIZE) {
                    self.iram[offset] = value;
                }
            }
        } else {
            // Read-modify-write for peripherals
            var old = self.read32(aligned);
            old &= ~mask;
            old |= @as(u32, value) << shift;
            self.write32(aligned, old);
        }
    }

    /// Write 16-bit value
    pub fn write16(self: *Self, addr: u32, value: u16) void {
        // Read-modify-write for halfword access
        const aligned = addr & ~@as(u32, 3);
        const shift: u5 = @truncate((addr & 2) * 8);
        const mask: u32 = @as(u32, 0xFFFF) << shift;

        const region = getRegion(addr);
        if (region == .sdram or region == .iram) {
            // Direct write to RAM
            if (region == .sdram) {
                const offset = addr - SDRAM_START;
                if (offset + 1 < self.sdram.len) {
                    self.sdram[offset] = @truncate(value);
                    self.sdram[offset + 1] = @truncate(value >> 8);
                }
            } else {
                const offset = addr - IRAM_START;
                if (offset + 1 < IRAM_SIZE) {
                    self.iram[offset] = @truncate(value);
                    self.iram[offset + 1] = @truncate(value >> 8);
                }
            }
        } else {
            var old = self.read32(aligned);
            old &= ~mask;
            old |= @as(u32, value) << shift;
            self.write32(aligned, old);
        }
    }

    /// Write 32-bit value
    pub fn write32(self: *Self, addr: u32, value: u32) void {
        const region = getRegion(addr);
        self.last_access_addr = addr;
        self.last_access_region = region;

        // Debug: track LCD writes
        if (region == .lcd) {
            self.lcd_write_count += 1;
        }
        if (region == .lcd_bridge) {
            self.lcd_bridge_write_count += 1;
        }

        switch (region) {
            .boot_rom => {}, // ROM is read-only
            .sdram => self.writeSdram(addr, value),
            .iram => self.writeIram(addr, value),
            .lcd => self.writePeripheral(self.lcd, addr, LCD_START, value),
            .interrupt_ctrl => self.writePeripheral(self.interrupt_ctrl, addr, INT_CTRL_START, value),
            .timers => self.writePeripheral(self.timers, addr, TIMER_START, value),
            .system_ctrl => self.writePeripheral(self.system_ctrl, addr, SYS_CTRL_START, value),
            .cache_ctrl => self.writePeripheral(self.cache_ctrl, addr, CACHE_CTRL_START, value),
            .dma => self.writePeripheral(self.dma, addr, DMA_START, value),
            .gpio => self.writePeripheral(self.gpio, addr, GPIO_START, value),
            .device_init => self.writePeripheral(self.device_init, addr, DEV_INIT_START, value),
            .gpo32 => self.writePeripheral(self.gpo32, addr, GPO32_START, value),
            .i2s => self.writePeripheral(self.i2s, addr, I2S_START, value),
            .i2c => self.writePeripheral(self.i2c, addr, I2C_START, value),
            .clickwheel => self.writePeripheral(self.clickwheel, addr, CLICKWHEEL_START, value),
            .lcd_bridge => self.writePeripheral(self.lcd_bridge, addr, LCD_BRIDGE_START, value),
            .ata => self.writePeripheral(self.ata, addr, ATA_START, value),
            .unmapped => {}, // Ignore writes to unmapped addresses
        }
    }

    // Internal read/write helpers

    fn readRom(self: *const Self, addr: u32) u32 {
        const offset = addr - ROM_START;
        if (offset + 3 < self.boot_rom.len) {
            return @as(u32, self.boot_rom[offset]) |
                (@as(u32, self.boot_rom[offset + 1]) << 8) |
                (@as(u32, self.boot_rom[offset + 2]) << 16) |
                (@as(u32, self.boot_rom[offset + 3]) << 24);
        }
        return 0;
    }

    fn readSdram(self: *const Self, addr: u32) u32 {
        const offset = addr - SDRAM_START;
        if (offset + 3 < self.sdram.len) {
            return @as(u32, self.sdram[offset]) |
                (@as(u32, self.sdram[offset + 1]) << 8) |
                (@as(u32, self.sdram[offset + 2]) << 16) |
                (@as(u32, self.sdram[offset + 3]) << 24);
        }
        return 0;
    }

    fn writeSdram(self: *Self, addr: u32, value: u32) void {
        const offset = addr - SDRAM_START;
        if (offset + 3 < self.sdram.len) {
            self.sdram[offset] = @truncate(value);
            self.sdram[offset + 1] = @truncate(value >> 8);
            self.sdram[offset + 2] = @truncate(value >> 16);
            self.sdram[offset + 3] = @truncate(value >> 24);
        }
    }

    fn readIram(self: *const Self, addr: u32) u32 {
        const offset = addr - IRAM_START;
        if (offset + 3 < IRAM_SIZE) {
            return @as(u32, self.iram[offset]) |
                (@as(u32, self.iram[offset + 1]) << 8) |
                (@as(u32, self.iram[offset + 2]) << 16) |
                (@as(u32, self.iram[offset + 3]) << 24);
        }
        return 0;
    }

    fn writeIram(self: *Self, addr: u32, value: u32) void {
        const offset = addr - IRAM_START;
        if (offset + 3 < IRAM_SIZE) {
            self.iram[offset] = @truncate(value);
            self.iram[offset + 1] = @truncate(value >> 8);
            self.iram[offset + 2] = @truncate(value >> 16);
            self.iram[offset + 3] = @truncate(value >> 24);
        }
    }

    fn readPeripheral(self: *Self, handler: ?PeripheralHandler, addr: u32, base: u32) u32 {
        if (handler) |h| {
            return h.read(addr - base);
        }
        // Stub: return from stub register array
        const idx = ((addr - base) >> 2) & 0xFF;
        return self.stub_registers[idx];
    }

    fn writePeripheral(self: *Self, handler: ?PeripheralHandler, addr: u32, base: u32, value: u32) void {
        if (handler) |h| {
            h.write(addr - base, value);
            return;
        }
        // Stub: store in stub register array
        const idx = ((addr - base) >> 2) & 0xFF;
        self.stub_registers[idx] = value;
    }

    /// Register a peripheral handler
    pub fn registerPeripheral(self: *Self, region: Region, handler: PeripheralHandler) void {
        switch (region) {
            .interrupt_ctrl => self.interrupt_ctrl = handler,
            .timers => self.timers = handler,
            .system_ctrl => self.system_ctrl = handler,
            .cache_ctrl => self.cache_ctrl = handler,
            .dma => self.dma = handler,
            .gpio => self.gpio = handler,
            .device_init => self.device_init = handler,
            .gpo32 => self.gpo32 = handler,
            .i2s => self.i2s = handler,
            .i2c => self.i2c = handler,
            .clickwheel => self.clickwheel = handler,
            .ata => self.ata = handler,
            .lcd => self.lcd = handler,
            .lcd_bridge => self.lcd_bridge = handler,
            else => {},
        }
    }

    /// Load data into IRAM
    pub fn loadIram(self: *Self, offset: u32, data: []const u8) void {
        const start = @min(offset, IRAM_SIZE);
        const end = @min(offset + data.len, IRAM_SIZE);
        const len = end - start;
        if (len > 0) {
            @memcpy(self.iram[start..end], data[0..len]);
        }
    }

    /// Load data into SDRAM
    pub fn loadSdram(self: *Self, offset: u32, data: []const u8) void {
        const start = @min(offset, @as(u32, @intCast(self.sdram.len)));
        const end = @min(offset + @as(u32, @intCast(data.len)), @as(u32, @intCast(self.sdram.len)));
        const len = end - start;
        if (len > 0) {
            @memcpy(self.sdram[start..end], data[0..len]);
        }
    }

    /// Debug: Get region name for address
    pub fn getRegionName(addr: u32) []const u8 {
        return switch (getRegion(addr)) {
            .boot_rom => "Boot ROM",
            .sdram => "SDRAM",
            .iram => "IRAM",
            .lcd => "LCD",
            .lcd_bridge => "LCD Bridge",
            .interrupt_ctrl => "Interrupt Controller",
            .timers => "Timers",
            .system_ctrl => "System Controller",
            .cache_ctrl => "Cache Controller",
            .dma => "DMA",
            .gpio => "GPIO",
            .device_init => "Device Init",
            .gpo32 => "GPO32",
            .i2s => "I2S",
            .i2c => "I2C",
            .clickwheel => "Click Wheel",
            .ata => "ATA",
            .unmapped => "Unmapped",
        };
    }
};

// Tests
test "memory region detection" {
    try std.testing.expectEqual(Region.boot_rom, MemoryBus.getRegion(0x00000000));
    try std.testing.expectEqual(Region.boot_rom, MemoryBus.getRegion(0x0001FFFF));
    try std.testing.expectEqual(Region.sdram, MemoryBus.getRegion(0x10000000));
    try std.testing.expectEqual(Region.iram, MemoryBus.getRegion(0x40000000));
    try std.testing.expectEqual(Region.interrupt_ctrl, MemoryBus.getRegion(0x60004000));
    try std.testing.expectEqual(Region.timers, MemoryBus.getRegion(0x60005000));
    try std.testing.expectEqual(Region.system_ctrl, MemoryBus.getRegion(0x60006000));
    try std.testing.expectEqual(Region.ata, MemoryBus.getRegion(0xC3000000));
    try std.testing.expectEqual(Region.ata, MemoryBus.getRegion(0xC30001E0)); // ATA data register
    try std.testing.expectEqual(Region.unmapped, MemoryBus.getRegion(0x80000000));
}

test "IRAM read/write" {
    var sdram = [_]u8{0} ** 1024;
    const rom = [_]u8{0} ** 128;
    var bus = MemoryBus.initWithSdram(&sdram, &rom);

    // Write 32-bit value
    bus.write32(0x40000000, 0x12345678);
    try std.testing.expectEqual(@as(u32, 0x12345678), bus.read32(0x40000000));

    // Write 16-bit value
    bus.write16(0x40000010, 0xABCD);
    try std.testing.expectEqual(@as(u16, 0xABCD), bus.read16(0x40000010));

    // Write 8-bit value
    bus.write8(0x40000020, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), bus.read8(0x40000020));
}

test "SDRAM read/write" {
    var sdram = [_]u8{0} ** (1024 * 1024); // 1MB for testing
    const rom = [_]u8{0} ** 128;
    var bus = MemoryBus.initWithSdram(&sdram, &rom);

    bus.write32(0x10000000, 0xDEADBEEF);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), bus.read32(0x10000000));
}

test "ROM is read-only" {
    var sdram = [_]u8{0} ** 1024;
    var rom = [_]u8{0xAA} ** 128;
    var bus = MemoryBus.initWithSdram(&sdram, &rom);

    // Can read ROM
    try std.testing.expectEqual(@as(u32, 0xAAAAAAAA), bus.read32(0x00000000));

    // Write should be ignored
    bus.write32(0x00000000, 0x12345678);
    try std.testing.expectEqual(@as(u32, 0xAAAAAAAA), bus.read32(0x00000000));
}

test "stub peripheral registers" {
    var sdram = [_]u8{0} ** 1024;
    const rom = [_]u8{0} ** 128;
    var bus = MemoryBus.initWithSdram(&sdram, &rom);

    // Write to unimplemented peripheral should use stub
    bus.write32(0x60005000, 0x12345678); // Timer register
    try std.testing.expectEqual(@as(u32, 0x12345678), bus.read32(0x60005000));
}
