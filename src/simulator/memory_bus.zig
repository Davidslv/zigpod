//! PP5021C Memory Bus
//!
//! Connects the ARM7TDMI CPU to memory and peripherals.
//! Implements the PP5021C memory map.

const std = @import("std");
const executor = @import("cpu/executor.zig");
const ata_controller = @import("storage/ata_controller.zig");
const interrupt_controller = @import("interrupts/interrupt_controller.zig");
const timer_sim = @import("interrupts/timer_sim.zig");

/// Re-export the CPU's MemoryBus type for external use
pub const CpuMemoryBus = executor.MemoryBus;
pub const MemoryError = executor.MemoryError;

/// PP5021C Memory Map
pub const MemoryMap = struct {
    // Boot ROM
    pub const ROM_BASE: u32 = 0x00000000;
    pub const ROM_SIZE: u32 = 0x00010000; // 64KB

    // SDRAM
    pub const SDRAM_BASE: u32 = 0x10000000;
    pub const SDRAM_SIZE: u32 = 0x02000000; // 32MB

    // Flash (NOR)
    pub const FLASH_BASE: u32 = 0x20000000;
    pub const FLASH_SIZE: u32 = 0x00100000; // 1MB

    // IRAM (internal SRAM)
    pub const IRAM_BASE: u32 = 0x40000000;
    pub const IRAM_SIZE: u32 = 0x00020000; // 128KB

    // Peripheral registers
    pub const PERIPH_BASE: u32 = 0x60000000;

    // Specific peripheral regions
    pub const DEV_CTRL: u32 = 0x60006000; // Device controller
    pub const GPIO_BASE: u32 = 0x6000D000; // GPIO
    pub const I2C_BASE: u32 = 0x7000C000; // I2C
    pub const I2S_BASE: u32 = 0x70002000; // I2S audio
    pub const IDE_BASE: u32 = 0xC0000000; // IDE/ATA
    pub const TIMER_BASE: u32 = 0x60005000; // Timers
    pub const INT_BASE: u32 = 0x60004000; // Interrupt controller
    pub const LCD_BASE: u32 = 0x70003000; // LCD controller
};

/// Memory bus errors
pub const BusError = error{
    UnmappedAddress,
    AlignmentFault,
    WriteProtected,
    BusTimeout,
};

/// Memory Bus
pub const MemoryBus = struct {
    // Memory regions
    rom: []u8,
    iram: []u8,
    sdram: []u8,
    flash: []u8,

    // Track ownership of memory regions
    owns_iram: bool = true,
    owns_sdram: bool = true,

    // Peripheral registers (simplified - 64KB peripheral space)
    periph_regs: [0x10000]u8 = [_]u8{0} ** 0x10000,

    // Connected peripherals
    ata: ?*ata_controller.AtaController = null,
    intc: ?*interrupt_controller.InterruptController = null,
    timers: ?*timer_sim.TimerSystem = null,

    // LCD framebuffer pointer
    lcd_framebuffer: ?[]u16 = null,

    // GPIO state
    gpio_out: [4]u32 = [_]u32{0} ** 4,
    gpio_enable: [4]u32 = [_]u32{0} ** 4,
    gpio_in: [4]u32 = [_]u32{0} ** 4,

    // I2C state
    i2c_data: u8 = 0,
    i2c_ctrl: u8 = 0,

    // Debug/trace
    trace_enabled: bool = false,
    last_access_addr: u32 = 0,
    last_access_write: bool = false,

    // Allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize memory bus with allocated memory
    pub fn init(allocator: std.mem.Allocator) !Self {
        const iram = try allocator.alloc(u8, MemoryMap.IRAM_SIZE);
        errdefer allocator.free(iram);

        const sdram = try allocator.alloc(u8, MemoryMap.SDRAM_SIZE);
        errdefer allocator.free(sdram);

        return Self{
            .allocator = allocator,
            .rom = try allocator.alloc(u8, MemoryMap.ROM_SIZE),
            .iram = iram,
            .sdram = sdram,
            .flash = try allocator.alloc(u8, MemoryMap.FLASH_SIZE),
            .owns_iram = true,
            .owns_sdram = true,
        };
    }

    /// Initialize with pre-allocated memory (for SimulatorState integration)
    pub fn initWithMemory(
        allocator: std.mem.Allocator,
        iram: []u8,
        sdram: []u8,
    ) !Self {
        return Self{
            .allocator = allocator,
            .rom = try allocator.alloc(u8, MemoryMap.ROM_SIZE),
            .iram = iram,
            .sdram = sdram,
            .flash = try allocator.alloc(u8, MemoryMap.FLASH_SIZE),
            .owns_iram = false,
            .owns_sdram = false,
        };
    }

    /// Cleanup
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.rom);
        self.allocator.free(self.flash);
        if (self.owns_iram) {
            self.allocator.free(self.iram);
        }
        if (self.owns_sdram) {
            self.allocator.free(self.sdram);
        }
    }

    /// Connect ATA controller
    pub fn connectAta(self: *Self, ata: *ata_controller.AtaController) void {
        self.ata = ata;
    }

    /// Connect interrupt controller
    pub fn connectInterruptController(self: *Self, intc: *interrupt_controller.InterruptController) void {
        self.intc = intc;
    }

    /// Connect timer system
    pub fn connectTimers(self: *Self, timers: *timer_sim.TimerSystem) void {
        self.timers = timers;
    }

    /// Connect LCD framebuffer
    pub fn connectLcd(self: *Self, fb: []u16) void {
        self.lcd_framebuffer = fb;
    }

    /// Read 32-bit word
    pub fn read32(self: *Self, address: u32) BusError!u32 {
        self.last_access_addr = address;
        self.last_access_write = false;

        // Check alignment
        if (address & 3 != 0) {
            return BusError.AlignmentFault;
        }

        return switch (address) {
            // ROM
            MemoryMap.ROM_BASE...MemoryMap.ROM_BASE + MemoryMap.ROM_SIZE - 1 => blk: {
                const offset = address - MemoryMap.ROM_BASE;
                break :blk std.mem.readInt(u32, self.rom[offset..][0..4], .little);
            },
            // SDRAM
            MemoryMap.SDRAM_BASE...MemoryMap.SDRAM_BASE + MemoryMap.SDRAM_SIZE - 1 => blk: {
                const offset = address - MemoryMap.SDRAM_BASE;
                break :blk std.mem.readInt(u32, self.sdram[offset..][0..4], .little);
            },
            // Flash
            MemoryMap.FLASH_BASE...MemoryMap.FLASH_BASE + MemoryMap.FLASH_SIZE - 1 => blk: {
                const offset = address - MemoryMap.FLASH_BASE;
                break :blk std.mem.readInt(u32, self.flash[offset..][0..4], .little);
            },
            // IRAM
            MemoryMap.IRAM_BASE...MemoryMap.IRAM_BASE + MemoryMap.IRAM_SIZE - 1 => blk: {
                const offset = address - MemoryMap.IRAM_BASE;
                break :blk std.mem.readInt(u32, self.iram[offset..][0..4], .little);
            },
            // Peripherals
            0x60000000...0x7FFFFFFF => self.readPeripheral32(address),
            // IDE
            0xC0000000...0xC00001FF => self.readIde(address),
            else => BusError.UnmappedAddress,
        };
    }

    /// Write 32-bit word
    pub fn write32(self: *Self, address: u32, value: u32) BusError!void {
        self.last_access_addr = address;
        self.last_access_write = true;

        // Check alignment
        if (address & 3 != 0) {
            return BusError.AlignmentFault;
        }

        switch (address) {
            // ROM - write protected
            MemoryMap.ROM_BASE...MemoryMap.ROM_BASE + MemoryMap.ROM_SIZE - 1 => {
                return BusError.WriteProtected;
            },
            // SDRAM
            MemoryMap.SDRAM_BASE...MemoryMap.SDRAM_BASE + MemoryMap.SDRAM_SIZE - 1 => {
                const offset = address - MemoryMap.SDRAM_BASE;
                std.mem.writeInt(u32, self.sdram[offset..][0..4], value, .little);
            },
            // Flash - write protected (simplified, real flash needs unlock)
            MemoryMap.FLASH_BASE...MemoryMap.FLASH_BASE + MemoryMap.FLASH_SIZE - 1 => {
                return BusError.WriteProtected;
            },
            // IRAM
            MemoryMap.IRAM_BASE...MemoryMap.IRAM_BASE + MemoryMap.IRAM_SIZE - 1 => {
                const offset = address - MemoryMap.IRAM_BASE;
                std.mem.writeInt(u32, self.iram[offset..][0..4], value, .little);
            },
            // Peripherals
            0x60000000...0x7FFFFFFF => try self.writePeripheral32(address, value),
            // IDE
            0xC0000000...0xC00001FF => try self.writeIde(address, value),
            else => return BusError.UnmappedAddress,
        }
    }

    /// Read 16-bit halfword
    pub fn read16(self: *Self, address: u32) BusError!u16 {
        if (address & 1 != 0) {
            return BusError.AlignmentFault;
        }

        return switch (address) {
            MemoryMap.SDRAM_BASE...MemoryMap.SDRAM_BASE + MemoryMap.SDRAM_SIZE - 1 => blk: {
                const offset = address - MemoryMap.SDRAM_BASE;
                break :blk std.mem.readInt(u16, self.sdram[offset..][0..2], .little);
            },
            MemoryMap.IRAM_BASE...MemoryMap.IRAM_BASE + MemoryMap.IRAM_SIZE - 1 => blk: {
                const offset = address - MemoryMap.IRAM_BASE;
                break :blk std.mem.readInt(u16, self.iram[offset..][0..2], .little);
            },
            else => @truncate(try self.read32(address & ~@as(u32, 3))),
        };
    }

    /// Write 16-bit halfword
    pub fn write16(self: *Self, address: u32, value: u16) BusError!void {
        if (address & 1 != 0) {
            return BusError.AlignmentFault;
        }

        switch (address) {
            MemoryMap.SDRAM_BASE...MemoryMap.SDRAM_BASE + MemoryMap.SDRAM_SIZE - 1 => {
                const offset = address - MemoryMap.SDRAM_BASE;
                std.mem.writeInt(u16, self.sdram[offset..][0..2], value, .little);
            },
            MemoryMap.IRAM_BASE...MemoryMap.IRAM_BASE + MemoryMap.IRAM_SIZE - 1 => {
                const offset = address - MemoryMap.IRAM_BASE;
                std.mem.writeInt(u16, self.iram[offset..][0..2], value, .little);
            },
            else => {
                // Byte-lane write for peripherals
                const aligned = address & ~@as(u32, 3);
                var word = try self.read32(aligned);
                if (address & 2 == 0) {
                    word = (word & 0xFFFF0000) | value;
                } else {
                    word = (word & 0x0000FFFF) | (@as(u32, value) << 16);
                }
                try self.write32(aligned, word);
            },
        }
    }

    /// Read 8-bit byte
    pub fn read8(self: *Self, address: u32) BusError!u8 {
        return switch (address) {
            MemoryMap.ROM_BASE...MemoryMap.ROM_BASE + MemoryMap.ROM_SIZE - 1 => blk: {
                const offset = address - MemoryMap.ROM_BASE;
                break :blk self.rom[offset];
            },
            MemoryMap.SDRAM_BASE...MemoryMap.SDRAM_BASE + MemoryMap.SDRAM_SIZE - 1 => blk: {
                const offset = address - MemoryMap.SDRAM_BASE;
                break :blk self.sdram[offset];
            },
            MemoryMap.IRAM_BASE...MemoryMap.IRAM_BASE + MemoryMap.IRAM_SIZE - 1 => blk: {
                const offset = address - MemoryMap.IRAM_BASE;
                break :blk self.iram[offset];
            },
            else => blk: {
                const word = try self.read32(address & ~@as(u32, 3));
                const shift: u5 = @truncate((address & 3) * 8);
                break :blk @truncate(word >> shift);
            },
        };
    }

    /// Write 8-bit byte
    pub fn write8(self: *Self, address: u32, value: u8) BusError!void {
        switch (address) {
            MemoryMap.SDRAM_BASE...MemoryMap.SDRAM_BASE + MemoryMap.SDRAM_SIZE - 1 => {
                const offset = address - MemoryMap.SDRAM_BASE;
                self.sdram[offset] = value;
            },
            MemoryMap.IRAM_BASE...MemoryMap.IRAM_BASE + MemoryMap.IRAM_SIZE - 1 => {
                const offset = address - MemoryMap.IRAM_BASE;
                self.iram[offset] = value;
            },
            else => {
                const aligned = address & ~@as(u32, 3);
                var word = try self.read32(aligned);
                const shift: u5 = @truncate((address & 3) * 8);
                const mask = @as(u32, 0xFF) << shift;
                word = (word & ~mask) | (@as(u32, value) << shift);
                try self.write32(aligned, word);
            },
        }
    }

    /// Read peripheral register
    fn readPeripheral32(self: *Self, address: u32) BusError!u32 {
        return switch (address) {
            // Interrupt controller
            MemoryMap.INT_BASE...MemoryMap.INT_BASE + 0xFF => blk: {
                if (self.intc) |intc| {
                    const reg = (address - MemoryMap.INT_BASE) >> 2;
                    break :blk switch (reg) {
                        0 => intc.readCpuIntStat(),
                        1 => intc.readCpuIntEn(),
                        4 => intc.readCopIntStat(),
                        5 => intc.readCopIntEn(),
                        else => 0,
                    };
                }
                break :blk 0;
            },
            // Timers
            MemoryMap.TIMER_BASE...MemoryMap.TIMER_BASE + 0xFF => blk: {
                if (self.timers) |timers| {
                    break :blk self.readTimerReg(timers, address);
                }
                break :blk 0;
            },
            // GPIO
            MemoryMap.GPIO_BASE...MemoryMap.GPIO_BASE + 0xFF => self.readGpio(address),
            // Device controller - return chip ID
            MemoryMap.DEV_CTRL...MemoryMap.DEV_CTRL + 0xFF => blk: {
                if (address == MemoryMap.DEV_CTRL) {
                    break :blk 0x55020000; // PP5021C-TDF ID
                }
                break :blk 0;
            },
            // Default - return from periph_regs
            else => blk: {
                const offset = (address - 0x60000000) & 0xFFFF;
                break :blk std.mem.readInt(u32, self.periph_regs[offset..][0..4], .little);
            },
        };
    }

    /// Write peripheral register
    fn writePeripheral32(self: *Self, address: u32, value: u32) BusError!void {
        switch (address) {
            // Interrupt controller
            MemoryMap.INT_BASE...MemoryMap.INT_BASE + 0xFF => {
                if (self.intc) |intc| {
                    const reg = (address - MemoryMap.INT_BASE) >> 2;
                    switch (reg) {
                        0 => intc.writeCpuIntClr(value),
                        1 => intc.writeCpuIntEn(value),
                        4 => intc.writeCopIntClr(value),
                        5 => intc.writeCopIntEn(value),
                        else => {},
                    }
                }
            },
            // Timers
            MemoryMap.TIMER_BASE...MemoryMap.TIMER_BASE + 0xFF => {
                if (self.timers) |timers| {
                    self.writeTimerReg(timers, address, value);
                }
            },
            // GPIO
            MemoryMap.GPIO_BASE...MemoryMap.GPIO_BASE + 0xFF => self.writeGpio(address, value),
            // Default - store in periph_regs
            else => {
                const offset = (address - 0x60000000) & 0xFFFF;
                std.mem.writeInt(u32, self.periph_regs[offset..][0..4], value, .little);
            },
        }
    }

    /// Read timer register
    fn readTimerReg(self: *Self, timers: *timer_sim.TimerSystem, address: u32) u32 {
        _ = self;
        const reg = (address - MemoryMap.TIMER_BASE) >> 2;
        return switch (reg) {
            0 => timers.timer1.cfg,
            1 => timers.readTimer1(),
            2 => timers.timer2.cfg,
            3 => timers.readTimer2(),
            4 => @truncate(timers.readUsecTimer()),
            5 => @truncate(timers.readUsecTimer() >> 32),
            else => 0,
        };
    }

    /// Write timer register
    fn writeTimerReg(self: *Self, timers: *timer_sim.TimerSystem, address: u32, value: u32) void {
        _ = self;
        const reg = (address - MemoryMap.TIMER_BASE) >> 2;
        switch (reg) {
            0 => timers.configureTimer1(value),
            2 => timers.configureTimer2(value),
            else => {},
        }
    }

    /// Read GPIO register
    fn readGpio(self: *Self, address: u32) u32 {
        const reg = (address - MemoryMap.GPIO_BASE) >> 2;
        const port = reg / 4;
        const offset = reg % 4;

        if (port >= 4) return 0;

        return switch (offset) {
            0 => self.gpio_out[port],
            1 => self.gpio_enable[port],
            2 => self.gpio_in[port],
            else => 0,
        };
    }

    /// Write GPIO register
    fn writeGpio(self: *Self, address: u32, value: u32) void {
        const reg = (address - MemoryMap.GPIO_BASE) >> 2;
        const port = reg / 4;
        const offset = reg % 4;

        if (port >= 4) return;

        switch (offset) {
            0 => self.gpio_out[port] = value,
            1 => self.gpio_enable[port] = value,
            else => {},
        }
    }

    /// Read IDE/ATA register
    /// PP5021C ATA register layout (offset from 0xC0000000):
    /// 0x00: Data (16-bit)
    /// 0x04: Error/Features
    /// 0x08: Sector Count
    /// 0x0C: Sector Number (LBA 7:0)
    /// 0x10: Cylinder Low (LBA 15:8)
    /// 0x14: Cylinder High (LBA 23:16)
    /// 0x18: Device/Head
    /// 0x1C: Status/Command
    fn readIde(self: *Self, address: u32) BusError!u32 {
        if (self.ata) |ata| {
            const reg = (address - 0xC0000000) >> 2;
            return switch (reg) {
                0 => ata.readDataWord(), // Data register
                1 => ata.getError(), // Error register
                7 => ata.getStatus(), // Status register
                else => 0,
            };
        }
        return 0;
    }

    /// Write IDE/ATA register
    fn writeIde(self: *Self, address: u32, value: u32) BusError!void {
        if (self.ata) |ata| {
            const reg = (address - 0xC0000000) >> 2;
            switch (reg) {
                0 => ata.writeDataWord(@truncate(value)), // Data register
                7 => ata.writeCommand(@truncate(value)), // Command register
                else => {},
            }
        }
    }

    /// Load binary into ROM
    pub fn loadRom(self: *Self, data: []const u8) void {
        const len = @min(data.len, self.rom.len);
        @memcpy(self.rom[0..len], data[0..len]);
    }

    /// Load binary into IRAM
    pub fn loadIram(self: *Self, offset: u32, data: []const u8) void {
        const start = @min(offset, self.iram.len);
        const len = @min(data.len, self.iram.len - start);
        @memcpy(self.iram[start..][0..len], data[0..len]);
    }

    /// Load binary into SDRAM
    pub fn loadSdram(self: *Self, offset: u32, data: []const u8) void {
        const start = @min(offset, self.sdram.len);
        const len = @min(data.len, self.sdram.len - start);
        @memcpy(self.sdram[start..][0..len], data[0..len]);
    }

    /// Get memory interface for CPU
    /// Returns a CpuMemoryBus (executor.MemoryBus) that wraps this bus
    pub fn getCpuInterface(self: *Self) CpuMemoryBus {
        return .{
            .context = self,
            .read32Fn = cpuRead32,
            .read16Fn = cpuRead16,
            .read8Fn = cpuRead8,
            .write32Fn = cpuWrite32,
            .write16Fn = cpuWrite16,
            .write8Fn = cpuWrite8,
        };
    }

    // CPU interface wrapper functions that convert BusError to MemoryError
    fn cpuRead32(ctx: *anyopaque, addr: u32) MemoryError!u32 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.read32(addr) catch |err| return busToMemoryError(err);
    }

    fn cpuRead16(ctx: *anyopaque, addr: u32) MemoryError!u16 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.read16(addr) catch |err| return busToMemoryError(err);
    }

    fn cpuRead8(ctx: *anyopaque, addr: u32) MemoryError!u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.read8(addr) catch |err| return busToMemoryError(err);
    }

    fn cpuWrite32(ctx: *anyopaque, addr: u32, value: u32) MemoryError!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write32(addr, value) catch |err| return busToMemoryError(err);
    }

    fn cpuWrite16(ctx: *anyopaque, addr: u32, value: u16) MemoryError!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write16(addr, value) catch |err| return busToMemoryError(err);
    }

    fn cpuWrite8(ctx: *anyopaque, addr: u32, value: u8) MemoryError!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write8(addr, value) catch |err| return busToMemoryError(err);
    }

    fn busToMemoryError(err: BusError) MemoryError {
        return switch (err) {
            BusError.AlignmentFault => MemoryError.AlignmentFault,
            BusError.UnmappedAddress => MemoryError.UnmappedAddress,
            BusError.WriteProtected, BusError.BusTimeout => MemoryError.AccessFault,
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "memory bus init" {
    const allocator = std.testing.allocator;
    var bus = try MemoryBus.init(allocator);
    defer bus.deinit();

    try std.testing.expectEqual(@as(usize, MemoryMap.ROM_SIZE), bus.rom.len);
    try std.testing.expectEqual(@as(usize, MemoryMap.IRAM_SIZE), bus.iram.len);
    try std.testing.expectEqual(@as(usize, MemoryMap.SDRAM_SIZE), bus.sdram.len);
}

test "iram read/write" {
    const allocator = std.testing.allocator;
    var bus = try MemoryBus.init(allocator);
    defer bus.deinit();

    // Write to IRAM
    try bus.write32(MemoryMap.IRAM_BASE, 0xDEADBEEF);
    const val = try bus.read32(MemoryMap.IRAM_BASE);

    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), val);
}

test "sdram read/write" {
    const allocator = std.testing.allocator;
    var bus = try MemoryBus.init(allocator);
    defer bus.deinit();

    try bus.write32(MemoryMap.SDRAM_BASE + 0x1000, 0x12345678);
    const val = try bus.read32(MemoryMap.SDRAM_BASE + 0x1000);

    try std.testing.expectEqual(@as(u32, 0x12345678), val);
}

test "rom write protected" {
    const allocator = std.testing.allocator;
    var bus = try MemoryBus.init(allocator);
    defer bus.deinit();

    try std.testing.expectError(BusError.WriteProtected, bus.write32(MemoryMap.ROM_BASE, 0));
}

test "unmapped address" {
    const allocator = std.testing.allocator;
    var bus = try MemoryBus.init(allocator);
    defer bus.deinit();

    try std.testing.expectError(BusError.UnmappedAddress, bus.read32(0x80000000));
}

test "alignment fault" {
    const allocator = std.testing.allocator;
    var bus = try MemoryBus.init(allocator);
    defer bus.deinit();

    try std.testing.expectError(BusError.AlignmentFault, bus.read32(MemoryMap.IRAM_BASE + 1));
}

test "byte access" {
    const allocator = std.testing.allocator;
    var bus = try MemoryBus.init(allocator);
    defer bus.deinit();

    try bus.write8(MemoryMap.IRAM_BASE, 0xAB);
    try bus.write8(MemoryMap.IRAM_BASE + 1, 0xCD);
    try bus.write8(MemoryMap.IRAM_BASE + 2, 0xEF);
    try bus.write8(MemoryMap.IRAM_BASE + 3, 0x12);

    const word = try bus.read32(MemoryMap.IRAM_BASE);
    try std.testing.expectEqual(@as(u32, 0x12EFCDAB), word);
}

test "halfword access" {
    const allocator = std.testing.allocator;
    var bus = try MemoryBus.init(allocator);
    defer bus.deinit();

    try bus.write16(MemoryMap.IRAM_BASE, 0x1234);
    try bus.write16(MemoryMap.IRAM_BASE + 2, 0x5678);

    const word = try bus.read32(MemoryMap.IRAM_BASE);
    try std.testing.expectEqual(@as(u32, 0x56781234), word);
}

test "load rom" {
    const allocator = std.testing.allocator;
    var bus = try MemoryBus.init(allocator);
    defer bus.deinit();

    const code = [_]u8{ 0x00, 0x00, 0xA0, 0xE3 }; // MOV R0, #0
    bus.loadRom(&code);

    const val = try bus.read32(MemoryMap.ROM_BASE);
    try std.testing.expectEqual(@as(u32, 0xE3A00000), val);
}

test "device controller id" {
    const allocator = std.testing.allocator;
    var bus = try MemoryBus.init(allocator);
    defer bus.deinit();

    const id = try bus.read32(MemoryMap.DEV_CTRL);
    try std.testing.expectEqual(@as(u32, 0x55020000), id);
}

test "gpio read/write" {
    const allocator = std.testing.allocator;
    var bus = try MemoryBus.init(allocator);
    defer bus.deinit();

    try bus.write32(MemoryMap.GPIO_BASE, 0xFF00FF00);
    const val = try bus.read32(MemoryMap.GPIO_BASE);

    try std.testing.expectEqual(@as(u32, 0xFF00FF00), val);
}
