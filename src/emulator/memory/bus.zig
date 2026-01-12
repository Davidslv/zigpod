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
    proc_id, // Processor ID at 0x60000000
    mailbox, // CPU/COP mailbox registers at 0x60001000-0x60001FFF
    interrupt_ctrl,
    timers,
    system_ctrl,
    cache_ctrl,
    mem_ctrl, // Undocumented memory controller at 0x60009000 (Apple firmware uses this)
    hw_accel, // Hardware accelerator at 0x60003000 (Apple firmware uses this)
    dma,
    gpio,
    device_init,
    gpo32,
    i2s,
    i2c,
    clickwheel,
    ata,
    flash_ctrl, // Flash/memory controller at 0xF000F000 (Apple firmware uses this)
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

    /// Flash controller registers (0xF000F000-0xF000F0FF)
    /// Offset 0x0C contains return address for boot ROM call
    flash_ctrl_regs: [64]u32,

    /// Hardware accelerator buffer (0x60003000-0x60003FFF)
    /// Apple firmware uses this for checksum/copy operations
    hw_accel_regs: [1024]u32,

    /// Mailbox registers for CPU/COP synchronization
    /// cpu_queue: bit 29 set by CPU writes, cleared by COP reads
    /// cop_queue: bit 29 set by COP writes, cleared by CPU reads
    cpu_queue: u32,
    cop_queue: u32,

    /// Access tracking for debugging
    last_access_addr: u32,
    last_access_region: Region,

    /// Debug: count of LCD writes
    lcd_write_count: u32,

    /// Debug: count of LCD bridge writes
    lcd_bridge_write_count: u32,

    /// Debug: count of SDRAM writes
    sdram_write_count: u32,

    /// Debug: count of IRAM writes
    iram_write_count: u32,

    /// Debug: track first few SDRAM writes
    first_sdram_write_addr: u32,
    first_sdram_write_value: u32,

    /// Flag indicating current access is from COP (for PROC_ID)
    is_cop_access: bool,

    /// Debug: track ATA-related writes
    debug_last_ata_read: bool,
    debug_ata_write_count: u32,
    debug_ata_first_write_addr: u32,
    debug_ata_first_write_value: u32,
    debug_ata_writes_to_sdram: u32,
    debug_ata_writes_to_iram: u32,
    /// Track writes around MBR boot signature offset (0x1FE)
    debug_mbr_area_writes: u32,
    /// Track first 8 write addresses/values after ATA reads
    debug_ata_write_addrs: [8]u32,
    debug_ata_write_vals: [8]u32,
    /// Track writes containing MBR-related values
    debug_mbr_value_writes: u32,
    debug_mbr_value_last_addr: u32,
    debug_mbr_value_last_val: u32,
    /// Track all writes to 0x11002000-0x11003000 (where we see some data)
    debug_region_writes: u32,
    debug_region_first_addr: u32,
    debug_region_first_val: u32,
    /// Track reads from partition struct area (0x11001A00-0x11001B00)
    debug_part_reads: u32,
    debug_part_read_addrs: [16]u32,
    debug_part_read_vals: [16]u32,
    /// Track writes containing partition size value (0x07FF = 2047)
    debug_part_size_writes: u32,
    debug_part_size_addrs: [8]u32,
    /// Track writes containing partition type (0x0B) in low byte
    debug_part_type_writes: u32,
    debug_part_type_addrs: [8]u32,
    /// Track writes to pinfo local variable area (0x11001A60-0x11001A70)
    debug_pinfo_writes: u32,
    debug_pinfo_write_addrs: [8]u32,
    debug_pinfo_write_vals: [8]u32,
    /// Track reads from part[0] area (0x11001A30-0x11001A3C)
    debug_part0_reads: u32,
    /// Track writes containing LFN entry pattern (0x41 byte)
    debug_lfn_write_count: u32,
    debug_lfn_write_addrs: [8]u32,
    debug_lfn_write_vals: [8]u32,
    /// Track reads from sector buffer area (0x11006F40-0x11006F80)
    debug_sector_read_count: u32,
    debug_sector_read_addrs: [32]u32,
    debug_sector_read_vals: [32]u32,
    /// Track reads where attr byte (offset 0x0B) == 0x0F
    debug_lfn_attr_read_count: u32,

    /// Debug: track peripheral access counts for Apple firmware analysis
    debug_timer_accesses: u32,
    debug_gpio_accesses: u32,
    debug_i2c_accesses: u32,
    debug_sys_ctrl_accesses: u32,
    debug_int_ctrl_accesses: u32,
    debug_mailbox_accesses: u32,
    debug_dev_init_accesses: u32,

    /// Debug: track which device_init offsets are being accessed
    debug_dev_init_offset_counts: [32]u32, // Histogram of accesses to offsets 0x00-0x7C (32 dwords)
    debug_int_ctrl_offset_counts: [64]u32, // Histogram of interrupt controller offsets

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

    /// Processor ID register
    const PROC_ID_ADDR: u32 = 0x60000000;

    /// Mailbox/Queue registers for CPU/COP communication
    /// CPU_QUEUE at 0x60001010: CPU sets bit 29, only COP read clears it
    /// COP_QUEUE at 0x60001020: COP sets bit 29, only CPU read clears it
    const MAILBOX_START: u32 = 0x60001000;
    const MAILBOX_END: u32 = 0x60001FFF;
    const CPU_QUEUE_OFFSET: u32 = 0x10; // 0x60001010
    const COP_QUEUE_OFFSET: u32 = 0x20; // 0x60001020

    /// System Controller (includes processor control at 0x60007000)
    const SYS_CTRL_START: u32 = 0x60006000;
    const SYS_CTRL_END: u32 = 0x60007FFF; // Extended to include CPU_CTL/COP_CTL

    /// Hardware accelerator/buffer at 0x60003000 (Apple firmware uses for checksum/copy)
    const HW_ACCEL_START: u32 = 0x60003000;
    const HW_ACCEL_END: u32 = 0x60003FFF;

    /// Cache Controller
    const CACHE_CTRL_START: u32 = 0x6000C000;
    const CACHE_CTRL_END: u32 = 0x6000C0FF;

    /// Undocumented memory/DMA controller at 0x60009000 (Apple firmware uses this)
    const MEM_CTRL_START: u32 = 0x60009000;
    const MEM_CTRL_END: u32 = 0x600090FF;

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

    /// Flash/Memory Controller (Apple firmware writes config here before jumping to ROM)
    const FLASH_CTRL_START: u32 = 0xF000F000;
    const FLASH_CTRL_END: u32 = 0xF000F0FF;

    /// Apple firmware encoded address range (0x04xxxxxx → 0x10xxxxxx)
    /// Apple firmware uses 0x04 prefix + offset to reference data within the firmware image
    /// Since firmware is loaded at 0x10000000, 0x04XXXXXX maps to 0x10XXXXXX
    const ENCODED_FW_START: u32 = 0x04000000;
    const ENCODED_FW_END: u32 = 0x04FFFFFF;
    const ENCODED_FW_MASK: u32 = 0x00FFFFFF; // Extract lower 24 bits

    /// Translate Apple firmware encoded addresses to real SDRAM addresses
    /// 0x04xxxxxx → 0x10xxxxxx (firmware offset within SDRAM)
    fn translateAddress(addr: u32) u32 {
        if (addr >= ENCODED_FW_START and addr <= ENCODED_FW_END) {
            // Extract offset from encoded address and add SDRAM base
            const offset = addr & ENCODED_FW_MASK;
            return SDRAM_START + offset;
        }
        return addr;
    }

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
            .flash_ctrl_regs = [_]u32{0} ** 64,
            .hw_accel_regs = [_]u32{0} ** 1024,
            .cpu_queue = 0,
            .cop_queue = 0,
            .last_access_addr = 0,
            .last_access_region = .unmapped,
            .lcd_write_count = 0,
            .lcd_bridge_write_count = 0,
            .sdram_write_count = 0,
            .iram_write_count = 0,
            .first_sdram_write_addr = 0,
            .first_sdram_write_value = 0,
            .is_cop_access = false,
            .debug_last_ata_read = false,
            .debug_ata_write_count = 0,
            .debug_ata_first_write_addr = 0,
            .debug_ata_first_write_value = 0,
            .debug_ata_writes_to_sdram = 0,
            .debug_ata_writes_to_iram = 0,
            .debug_mbr_area_writes = 0,
            .debug_ata_write_addrs = [_]u32{0} ** 8,
            .debug_ata_write_vals = [_]u32{0} ** 8,
            .debug_mbr_value_writes = 0,
            .debug_mbr_value_last_addr = 0,
            .debug_mbr_value_last_val = 0,
            .debug_region_writes = 0,
            .debug_region_first_addr = 0,
            .debug_region_first_val = 0,
            .debug_part_reads = 0,
            .debug_part_read_addrs = [_]u32{0} ** 16,
            .debug_part_read_vals = [_]u32{0} ** 16,
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
            .flash_ctrl_regs = [_]u32{0} ** 64,
            .hw_accel_regs = [_]u32{0} ** 1024,
            .cpu_queue = 0,
            .cop_queue = 0,
            .last_access_addr = 0,
            .last_access_region = .unmapped,
            .lcd_write_count = 0,
            .lcd_bridge_write_count = 0,
            .sdram_write_count = 0,
            .iram_write_count = 0,
            .first_sdram_write_addr = 0,
            .first_sdram_write_value = 0,
            .is_cop_access = false,
            .debug_last_ata_read = false,
            .debug_ata_write_count = 0,
            .debug_ata_first_write_addr = 0,
            .debug_ata_first_write_value = 0,
            .debug_ata_writes_to_sdram = 0,
            .debug_ata_writes_to_iram = 0,
            .debug_mbr_area_writes = 0,
            .debug_ata_write_addrs = [_]u32{0} ** 8,
            .debug_ata_write_vals = [_]u32{0} ** 8,
            .debug_mbr_value_writes = 0,
            .debug_mbr_value_last_addr = 0,
            .debug_mbr_value_last_val = 0,
            .debug_region_writes = 0,
            .debug_region_first_addr = 0,
            .debug_region_first_val = 0,
            .debug_part_reads = 0,
            .debug_part_read_addrs = [_]u32{0} ** 16,
            .debug_part_read_vals = [_]u32{0} ** 16,
            .debug_part_size_writes = 0,
            .debug_part_size_addrs = [_]u32{0} ** 8,
            .debug_part_type_writes = 0,
            .debug_part_type_addrs = [_]u32{0} ** 8,
            .debug_pinfo_writes = 0,
            .debug_pinfo_write_addrs = [_]u32{0} ** 8,
            .debug_pinfo_write_vals = [_]u32{0} ** 8,
            .debug_part0_reads = 0,
            .debug_lfn_write_count = 0,
            .debug_lfn_write_addrs = [_]u32{0} ** 8,
            .debug_lfn_write_vals = [_]u32{0} ** 8,
            .debug_sector_read_count = 0,
            .debug_sector_read_addrs = [_]u32{0} ** 32,
            .debug_sector_read_vals = [_]u32{0} ** 32,
            .debug_lfn_attr_read_count = 0,
            .debug_timer_accesses = 0,
            .debug_gpio_accesses = 0,
            .debug_i2c_accesses = 0,
            .debug_sys_ctrl_accesses = 0,
            .debug_int_ctrl_accesses = 0,
            .debug_mailbox_accesses = 0,
            .debug_dev_init_accesses = 0,
            .debug_dev_init_offset_counts = [_]u32{0} ** 32,
            .debug_int_ctrl_offset_counts = [_]u32{0} ** 64,
        };
    }

    /// Set COP access flag (used by emulator when COP is executing)
    pub fn setCopAccess(self: *Self, is_cop: bool) void {
        self.is_cop_access = is_cop;
    }

    /// Determine which region an address belongs to
    pub fn getRegion(addr: u32) Region {
        if (addr >= ROM_START and addr <= ROM_END) return .boot_rom;
        if (addr >= SDRAM_START and addr <= SDRAM_END) return .sdram;
        if (addr >= LCD_START and addr <= LCD_END) return .lcd;
        if (addr >= IRAM_START and addr <= IRAM_END) return .iram;
        if (addr == PROC_ID_ADDR) return .proc_id;
        if (addr >= MAILBOX_START and addr <= MAILBOX_END) return .mailbox;
        if (addr >= INT_CTRL_START and addr <= INT_CTRL_END) return .interrupt_ctrl;
        if (addr >= TIMER_START and addr <= TIMER_END) return .timers;
        if (addr >= SYS_CTRL_START and addr <= SYS_CTRL_END) return .system_ctrl;
        if (addr >= HW_ACCEL_START and addr <= HW_ACCEL_END) return .hw_accel;
        if (addr >= CACHE_CTRL_START and addr <= CACHE_CTRL_END) return .cache_ctrl;
        if (addr >= MEM_CTRL_START and addr <= MEM_CTRL_END) return .mem_ctrl;
        if (addr >= DMA_START and addr <= DMA_END) return .dma;
        if (addr >= GPIO_START and addr <= GPIO_END) return .gpio;
        if (addr >= DEV_INIT_START and addr <= DEV_INIT_END) return .device_init;
        if (addr >= GPO32_START and addr <= GPO32_END) return .gpo32;
        if (addr >= I2S_START and addr <= I2S_END) return .i2s;
        if (addr >= LCD_BRIDGE_START and addr <= LCD_BRIDGE_END) return .lcd_bridge;
        if (addr >= I2C_START and addr <= I2C_END) return .i2c;
        if (addr >= CLICKWHEEL_START and addr <= CLICKWHEEL_END) return .clickwheel;
        if (addr >= ATA_START and addr <= ATA_END) return .ata;
        if (addr >= FLASH_CTRL_START and addr <= FLASH_CTRL_END) return .flash_ctrl;
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
        // Translate Apple firmware encoded addresses (0x04xxxxxx → 0x10xxxxxx)
        const translated_addr = translateAddress(addr);
        const region = getRegion(translated_addr);
        self.last_access_addr = translated_addr;
        self.last_access_region = region;

        // Track ATA DATA register reads (offset 0x1E0 from ATA_START)
        if (region == .ata and (translated_addr - ATA_START) == 0x1E0) {
            self.debug_last_ata_read = true;
        }

        // Track reads from partition struct area (0x11001A00-0x11001B00)
        if (addr >= 0x11001A00 and addr < 0x11001B00) {
            if (self.debug_part_reads < 16) {
                self.debug_part_read_addrs[self.debug_part_reads] = addr;
                // We'll fill in the value after reading
            }
        }

        // Track reads from part[0] area (0x11001A30-0x11001A3C)
        if (addr >= 0x11001A30 and addr < 0x11001A3C) {
            self.debug_part0_reads += 1;
        }

        // Track peripheral access counts for debugging
        switch (region) {
            .timers => self.debug_timer_accesses += 1,
            .gpio => self.debug_gpio_accesses += 1,
            .i2c => self.debug_i2c_accesses += 1,
            .system_ctrl => self.debug_sys_ctrl_accesses += 1,
            .interrupt_ctrl => {
                self.debug_int_ctrl_accesses += 1;
                // Track offset histogram
                const offset = (translated_addr - INT_CTRL_START) >> 2;
                if (offset < 64) {
                    self.debug_int_ctrl_offset_counts[offset] += 1;
                }
            },
            .mailbox => self.debug_mailbox_accesses += 1,
            .device_init => {
                self.debug_dev_init_accesses += 1;
                // Track offset histogram
                const offset = (translated_addr - DEV_INIT_START) >> 2;
                if (offset < 32) {
                    self.debug_dev_init_offset_counts[offset] += 1;
                }
            },
            else => {},
        }

        const value = switch (region) {
            .boot_rom => self.readRom(translated_addr),
            .sdram => self.readSdram(translated_addr),
            .iram => self.readIram(translated_addr),
            .lcd => self.readPeripheral(self.lcd, translated_addr, LCD_START),
            .proc_id => if (self.is_cop_access) @as(u32, 0xAA) else @as(u32, 0x55),
            .mailbox => self.readMailbox(translated_addr),
            .interrupt_ctrl => self.readPeripheral(self.interrupt_ctrl, translated_addr, INT_CTRL_START),
            .timers => self.readPeripheral(self.timers, translated_addr, TIMER_START),
            .system_ctrl => self.readPeripheral(self.system_ctrl, translated_addr, SYS_CTRL_START),
            .cache_ctrl => self.readPeripheral(self.cache_ctrl, translated_addr, CACHE_CTRL_START),
            .mem_ctrl => self.readStub(translated_addr, MEM_CTRL_START),
            .hw_accel => self.readHwAccel(translated_addr),
            .dma => self.readPeripheral(self.dma, translated_addr, DMA_START),
            .gpio => self.readPeripheral(self.gpio, translated_addr, GPIO_START),
            .device_init => self.readPeripheral(self.device_init, translated_addr, DEV_INIT_START),
            .gpo32 => self.readPeripheral(self.gpo32, translated_addr, GPO32_START),
            .i2s => self.readPeripheral(self.i2s, translated_addr, I2S_START),
            .i2c => self.readPeripheral(self.i2c, translated_addr, I2C_START),
            .clickwheel => self.readPeripheral(self.clickwheel, translated_addr, CLICKWHEEL_START),
            .lcd_bridge => self.readPeripheral(self.lcd_bridge, translated_addr, LCD_BRIDGE_START),
            .ata => self.readPeripheral(self.ata, translated_addr, ATA_START),
            .flash_ctrl => self.readFlashCtrl(translated_addr),
            .unmapped => 0, // Return 0 for unmapped addresses
        };

        // Complete tracking for partition struct area reads
        if (addr >= 0x11001A00 and addr < 0x11001B00) {
            if (self.debug_part_reads < 16) {
                self.debug_part_read_vals[self.debug_part_reads] = value;
                self.debug_part_reads += 1;
            }
        }

        // Track reads from sector buffer area where .rockbox LFN entry should be
        // Buffer at 0x11006F14, LFN entry at offset 0x40 (addr 0x11006F54)
        // Track reads from 0x11006F40 to 0x11006F80 (covers entries at offset 0x2C-0x6C)
        if (addr >= 0x11006F40 and addr < 0x11006F80) {
            if (self.debug_sector_read_count < 32) {
                self.debug_sector_read_addrs[self.debug_sector_read_count] = addr;
                self.debug_sector_read_vals[self.debug_sector_read_count] = value;
                self.debug_sector_read_count += 1;
            }
            // Check if this read includes the attr byte position for an LFN check
            // LFN attr is at offset 0x0B within 32-byte entry
            // Entry at 0x11006F54 has attr at 0x11006F5F
            // Check if the value contains 0x0F at the expected position
            if (addr == 0x11006F5C) { // 0x11006F5F aligned down to 32-bit boundary
                const attr_byte = (value >> 24) & 0xFF; // byte at offset 3 (0x5F)
                if (attr_byte == 0x0F) {
                    self.debug_lfn_attr_read_count += 1;
                }
                // Print real-time trace showing LFN write count at time of read
                const print = std.debug.print;
                print("ATTR READ at 0x{X:0>8}: val=0x{X:0>8}, attr_byte=0x{X:0>2}, lfn_writes={d}\n", .{ addr, value, attr_byte, self.debug_lfn_write_count });
            }
            // Also trace reads from 0x11006F54 (LFN entry start)
            if (addr == 0x11006F54) {
                const print = std.debug.print;
                print("LFN_START READ at 0x{X:0>8}: val=0x{X:0>8}, lfn_writes={d}\n", .{ addr, value, self.debug_lfn_write_count });
            }
            // Trace reads from 0x11006F74 (SHORT entry at offset 0x60 in .rockbox dir)
            if (addr == 0x11006F74) {
                const print = std.debug.print;
                print("SHORT_ENTRY READ at 0x{X:0>8}: val=0x{X:0>8}, lfn_writes={d}\n", .{ addr, value, self.debug_lfn_write_count });
            }
        }
        // Trace reads from checksum area (entry+0x0C..0x0F contains checksum at byte 0x0D)
        if (addr == 0x11006F60) { // entry + 0x0C aligned
            const print = std.debug.print;
            const chksum_byte = (value >> 8) & 0xFF; // byte at offset 0x0D
            print("CHECKSUM READ at 0x{X:0>8}: val=0x{X:0>8}, checksum_byte=0x{X:0>2}, lfn_writes={d}\n", .{ addr, value, chksum_byte, self.debug_lfn_write_count });
        }
        // Trace directory entry first bytes (to see iteration pattern)
        // Buffer starts at ~0x11006F14, entries at 0x20 intervals
        // Entry 0 (.) at 0x11006F14, Entry 1 (..) at 0x11006F34, Entry 2 (LFN) at 0x11006F54
        const entry_offsets = [_]u32{ 0x11006F14, 0x11006F34, 0x11006F54, 0x11006F74, 0x11006F94 };
        for (entry_offsets) |entry_addr| {
            if (addr == entry_addr) {
                const print = std.debug.print;
                const first_byte = value & 0xFF;
                const char: u8 = if (first_byte >= 0x20 and first_byte < 0x7F) @truncate(first_byte) else '.';
                print("DIR_ENTRY[0x{X:0>8}]: first_byte=0x{X:0>2}('{c}'), val=0x{X:0>8}, lfn_writes={d}\n", .{ entry_addr, first_byte, char, value, self.debug_lfn_write_count });
            }
        }

        return value;
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
        // Translate Apple firmware encoded addresses (0x04xxxxxx → 0x10xxxxxx)
        const translated_addr = translateAddress(addr);
        const region = getRegion(translated_addr);
        self.last_access_addr = translated_addr;
        self.last_access_region = region;

        // Debug: track LCD writes
        if (region == .lcd) {
            self.lcd_write_count += 1;
        }
        if (region == .lcd_bridge) {
            self.lcd_bridge_write_count += 1;
        }

        // Debug: track writes containing LFN entry signature for "rockbox.ipod"
        // First 16-bit word of LFN entry is: 0x41 (ord) + 0x72 ('r') = 0x7241
        // Or as 32-bit: 0x006F7241 (two UTF-16LE chars: 'r' + 'o')
        // Check for 0x7241 pattern (LFN start) or 0x4E checksum pattern
        const lo16 = value & 0xFFFF;
        const hi16 = (value >> 16) & 0xFFFF;
        if (lo16 == 0x7241 or hi16 == 0x7241 or lo16 == 0x2E41 or hi16 == 0x2E41) {
            // 0x7241 = start of "rockbox.ipod" LFN, 0x2E41 = start of ".rockbox" LFN
            if (self.debug_lfn_write_count < 8) {
                self.debug_lfn_write_addrs[self.debug_lfn_write_count] = addr;
                self.debug_lfn_write_vals[self.debug_lfn_write_count] = value;
                self.debug_lfn_write_count += 1;
            }
        }

        // Track ALL writes to 0x11006F74 (where SHORT entry should be in .rockbox dir)
        if (addr == 0x11006F74) {
            const print = std.debug.print;
            print("WRITE to 0x11006F74: val=0x{X:0>8}, lfn_writes={d}\n", .{ value, self.debug_lfn_write_count });
        }
        // Track ALL writes containing LFN start pattern anywhere in SDRAM (to find other buffers)
        if (region == .sdram and value == 0x6F007241) {
            const print = std.debug.print;
            print("LFN_PATTERN WRITE at 0x{X:0>8}: val=0x{X:0>8}\n", .{ addr, value });
        }

        // Debug: track writes after ATA DATA reads
        if (self.debug_last_ata_read) {
            // Capture first 8 write addresses/values
            if (self.debug_ata_write_count < 8) {
                self.debug_ata_write_addrs[self.debug_ata_write_count] = addr;
                self.debug_ata_write_vals[self.debug_ata_write_count] = value;
            }
            self.debug_ata_write_count += 1;
            if (self.debug_ata_write_count == 1) {
                self.debug_ata_first_write_addr = addr;
                self.debug_ata_first_write_value = value;
            }
            if (region == .sdram) {
                self.debug_ata_writes_to_sdram += 1;
            } else if (region == .iram) {
                self.debug_ata_writes_to_iram += 1;
            }
            // Check if writing near MBR signature area (offset 0x1FC-0x200 in any buffer)
            const low_offset = addr & 0x1FF; // Offset within 512-byte boundary
            if (low_offset >= 0x1BC and low_offset <= 0x200) {
                self.debug_mbr_area_writes += 1;
            }
            self.debug_last_ata_read = false;
        }

        // Track writes containing MBR-related values (0xAA55 or 0x0B in specific positions)
        // Look for boot signature 0xAA55 in low 16 bits or high 16 bits
        const has_aa55 = ((value & 0xFFFF) == 0xAA55) or (((value >> 16) & 0xFFFF) == 0xAA55);
        // Look for partition type 0x0B followed by 0xFE (word = 0xFE0B)
        const has_fe0b = ((value & 0xFFFF) == 0xFE0B) or (((value >> 16) & 0xFFFF) == 0xFE0B);
        if (has_aa55 or has_fe0b) {
            self.debug_mbr_value_writes += 1;
            self.debug_mbr_value_last_addr = addr;
            self.debug_mbr_value_last_val = value;
        }

        // Track writes to 0x11002000-0x11003000 region
        if (addr >= 0x11002000 and addr < 0x11003000) {
            if (self.debug_region_writes == 0) {
                self.debug_region_first_addr = addr;
                self.debug_region_first_val = value;
            }
            self.debug_region_writes += 1;
        }

        // Track writes containing partition size (0x07FF = 2047) or partition type (0x0B)
        // Size could be in low 16 bits or as a full 32-bit value
        const has_size = (value == 0x000007FF) or ((value & 0xFFFF) == 0x07FF);
        if (has_size and (region == .sdram or region == .iram)) {
            if (self.debug_part_size_writes < 8) {
                self.debug_part_size_addrs[self.debug_part_size_writes] = addr;
            }
            self.debug_part_size_writes += 1;
        }
        // Track writes with partition type 0x0B in low byte (but not 0x0B00...)
        if ((value & 0xFF) == 0x0B and value != 0 and (region == .sdram or region == .iram)) {
            if (self.debug_part_type_writes < 8) {
                self.debug_part_type_addrs[self.debug_part_type_writes] = addr;
            }
            self.debug_part_type_writes += 1;
        }

        // Track writes to pinfo local variable area (0x11001A60-0x11001A70)
        if (addr >= 0x11001A60 and addr < 0x11001A70) {
            if (self.debug_pinfo_writes < 8) {
                self.debug_pinfo_write_addrs[self.debug_pinfo_writes] = addr;
                self.debug_pinfo_write_vals[self.debug_pinfo_writes] = value;
            }
            self.debug_pinfo_writes += 1;
        }

        // Track peripheral access counts for debugging (writes)
        switch (region) {
            .timers => self.debug_timer_accesses += 1,
            .gpio => self.debug_gpio_accesses += 1,
            .i2c => self.debug_i2c_accesses += 1,
            .system_ctrl => self.debug_sys_ctrl_accesses += 1,
            .interrupt_ctrl => {
                self.debug_int_ctrl_accesses += 1;
                const offset = (translated_addr - INT_CTRL_START) >> 2;
                if (offset < 64) {
                    self.debug_int_ctrl_offset_counts[offset] += 1;
                }
            },
            .mailbox => self.debug_mailbox_accesses += 1,
            .device_init => {
                self.debug_dev_init_accesses += 1;
                const offset = (translated_addr - DEV_INIT_START) >> 2;
                if (offset < 32) {
                    self.debug_dev_init_offset_counts[offset] += 1;
                }
            },
            else => {},
        }

        switch (region) {
            .boot_rom => {}, // ROM is read-only
            .proc_id => {}, // PROC_ID is read-only
            .mailbox => self.writeMailbox(translated_addr, value),
            .sdram => self.writeSdram(translated_addr, value),
            .iram => self.writeIram(translated_addr, value),
            .lcd => self.writePeripheral(self.lcd, translated_addr, LCD_START, value),
            .interrupt_ctrl => self.writePeripheral(self.interrupt_ctrl, translated_addr, INT_CTRL_START, value),
            .timers => self.writePeripheral(self.timers, translated_addr, TIMER_START, value),
            .system_ctrl => self.writePeripheral(self.system_ctrl, translated_addr, SYS_CTRL_START, value),
            .cache_ctrl => self.writePeripheral(self.cache_ctrl, translated_addr, CACHE_CTRL_START, value),
            .mem_ctrl => self.writeStub(translated_addr, MEM_CTRL_START, value),
            .hw_accel => self.writeHwAccel(translated_addr, value),
            .dma => self.writePeripheral(self.dma, translated_addr, DMA_START, value),
            .gpio => self.writePeripheral(self.gpio, translated_addr, GPIO_START, value),
            .device_init => self.writePeripheral(self.device_init, translated_addr, DEV_INIT_START, value),
            .gpo32 => self.writePeripheral(self.gpo32, translated_addr, GPO32_START, value),
            .i2s => self.writePeripheral(self.i2s, translated_addr, I2S_START, value),
            .i2c => self.writePeripheral(self.i2c, translated_addr, I2C_START, value),
            .clickwheel => self.writePeripheral(self.clickwheel, translated_addr, CLICKWHEEL_START, value),
            .lcd_bridge => self.writePeripheral(self.lcd_bridge, translated_addr, LCD_BRIDGE_START, value),
            .ata => self.writePeripheral(self.ata, translated_addr, ATA_START, value),
            .flash_ctrl => self.writeFlashCtrl(translated_addr, value),
            .unmapped => {}, // Ignore writes to unmapped addresses
        }
    }

    // Flash controller read/write (stores return address for boot ROM)
    fn readFlashCtrl(self: *const Self, addr: u32) u32 {
        const offset = (addr - FLASH_CTRL_START) >> 2;
        if (offset < 64) {
            return self.flash_ctrl_regs[offset];
        }
        return 0;
    }

    fn writeFlashCtrl(self: *Self, addr: u32, value: u32) void {
        const offset = (addr - FLASH_CTRL_START) >> 2;
        if (offset < 64) {
            self.flash_ctrl_regs[offset] = value;
            // Debug: log writes to help understand boot protocol
            const print = std.debug.print;
            print("FLASH_CTRL[0x{X:0>2}] = 0x{X:0>8}\n", .{ offset * 4, value });
        }
    }

    // Stub read/write for undocumented peripherals
    fn readStub(self: *const Self, addr: u32, base: u32) u32 {
        const idx = ((addr - base) >> 2) & 0xFF;
        return self.stub_registers[idx];
    }

    fn writeStub(self: *Self, addr: u32, base: u32, value: u32) void {
        const idx = ((addr - base) >> 2) & 0xFF;
        self.stub_registers[idx] = value;
    }

    // Hardware accelerator buffer at 0x60003000
    // Apple firmware uses this for checksum/copy operations
    fn readHwAccel(self: *const Self, addr: u32) u32 {
        const offset = (addr - HW_ACCEL_START) >> 2;
        if (offset < 1024) {
            return self.hw_accel_regs[offset];
        }
        return 0;
    }

    fn writeHwAccel(self: *Self, addr: u32, value: u32) void {
        const offset = (addr - HW_ACCEL_START) >> 2;
        if (offset < 1024) {
            self.hw_accel_regs[offset] = value;
        }
    }

    // Mailbox registers for CPU/COP synchronization
    // CPU_QUEUE at 0x60001010: CPU writes set bits, COP reads clear them
    // COP_QUEUE at 0x60001020: COP writes set bits, CPU reads clear them
    fn readMailbox(self: *Self, addr: u32) u32 {
        const offset = addr - MAILBOX_START;
        return switch (offset) {
            CPU_QUEUE_OFFSET => blk: {
                // COP reading CPU_QUEUE clears bit 29
                if (self.is_cop_access) {
                    const val = self.cpu_queue;
                    self.cpu_queue &= ~@as(u32, 1 << 29);
                    break :blk val;
                }
                break :blk self.cpu_queue;
            },
            COP_QUEUE_OFFSET => blk: {
                // CPU reading COP_QUEUE clears bit 29
                if (!self.is_cop_access) {
                    const val = self.cop_queue;
                    self.cop_queue &= ~@as(u32, 1 << 29);
                    break :blk val;
                }
                break :blk self.cop_queue;
            },
            else => 0, // Other mailbox registers return 0
        };
    }

    fn writeMailbox(self: *Self, addr: u32, value: u32) void {
        const offset = addr - MAILBOX_START;
        switch (offset) {
            CPU_QUEUE_OFFSET => {
                // CPU writing to CPU_QUEUE sets bits (OR operation for bit 29)
                if (!self.is_cop_access) {
                    self.cpu_queue |= value;
                }
            },
            COP_QUEUE_OFFSET => {
                // COP writing to COP_QUEUE sets bits (OR operation for bit 29)
                if (self.is_cop_access) {
                    self.cop_queue |= value;
                }
            },
            else => {}, // Ignore other mailbox addresses
        }
    }

    // Internal read/write helpers

    fn readRom(self: *const Self, addr: u32) u32 {
        const offset = addr - ROM_START;

        // If actual boot ROM is loaded, use it
        if (offset + 3 < self.boot_rom.len) {
            return @as(u32, self.boot_rom[offset]) |
                (@as(u32, self.boot_rom[offset + 1]) << 8) |
                (@as(u32, self.boot_rom[offset + 2]) << 16) |
                (@as(u32, self.boot_rom[offset + 3]) << 24);
        }

        // Boot ROM stub for Apple firmware - calls function at 0xF000F00C and continues
        // Apple firmware writes callback address to 0xF000F00C before jumping to ROM
        // ROM should call that function with R0 = flash_ctrl base (0xF000F000)
        // The callback uses R0 as a pointer to write back data at various offsets
        // After callback, ROM should return to firmware (MOV PC, #0x10000A3C or next instr)
        // Firmware jumped to ROM from 0x10000A38, so return to 0x10000A3C
        // Layout:
        //   0x23C: LDR R1, [PC, #0x14] ; R1 = 0xF000F00C (addr of callback ptr) from 0x258
        //   0x240: LDR R0, [PC, #0x14] ; R0 = 0xF000F000 (flash ctrl base) from 0x25C
        //   0x244: LDR R1, [R1]        ; R1 = callback address (dereference)
        //   0x248: MOV LR, PC          ; LR = 0x250 (return point after BX)
        //   0x24C: BX R1               ; Call callback with R0=flash_ctrl_base
        //   0x250: LDR PC, [PC, #0xC]  ; Return to firmware at 0x10000A3C (from 0x264)
        //   0x254: NOP                 ; Padding
        //   0x258: 0xF000F00C          ; Literal: address of callback pointer
        //   0x25C: 0xF000F000          ; Literal: flash_ctrl base address
        //   0x260: NOP                 ; Padding
        //   0x264: 0x10000A3C          ; Literal: firmware return address
        return switch (addr) {
            0x0000023C => 0xE59F1014, // LDR R1, [PC, #0x14] ; R1 = 0xF000F00C (from 0x258)
            0x00000240 => 0xE59F0014, // LDR R0, [PC, #0x14] ; R0 = 0xF000F000 (from 0x25C)
            0x00000244 => 0xE5911000, // LDR R1, [R1]        ; R1 = callback address
            0x00000248 => 0xE1A0E00F, // MOV LR, PC          ; LR = 0x250
            0x0000024C => 0xE12FFF11, // BX R1               ; Call callback
            0x00000250 => 0xE59FF00C, // LDR PC, [PC, #0xC]  ; Jump to 0x10000A3C (from 0x264)
            0x00000254 => 0xE1A00000, // NOP
            0x00000258 => 0xF000F00C, // Literal: &flash_ctrl_regs[3]
            0x0000025C => 0xF000F000, // Literal: flash_ctrl base
            0x00000260 => 0xE1A00000, // NOP
            0x00000264 => 0x10000A3C, // Literal: firmware return address
            else => 0, // Return 0 for other unmapped ROM addresses
        };
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
            // Capture first SDRAM write
            if (self.sdram_write_count == 0) {
                self.first_sdram_write_addr = addr;
                self.first_sdram_write_value = value;
            }
            self.sdram[offset] = @truncate(value);
            self.sdram[offset + 1] = @truncate(value >> 8);
            self.sdram[offset + 2] = @truncate(value >> 16);
            self.sdram[offset + 3] = @truncate(value >> 24);
            self.sdram_write_count += 1;
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
            self.iram_write_count += 1;
        }
    }

    fn readPeripheral(self: *Self, handler: ?PeripheralHandler, addr: u32, base: u32) u32 {
        if (handler) |h| {
            return h.read(addr - base);
        }
        // Device Init special handling - PP_VER1/PP_VER2 and other init registers
        if (base == DEV_INIT_START) {
            const offset = addr - base;
            return switch (offset) {
                0x00 => 0x00005021, // PP_VER1: PP5021
                0x04 => 0x000000C1, // PP_VER2: Revision C1
                0x08 => 0x00000000, // STRAP_OPT_A
                0x0C => 0x00000000, // STRAP_OPT_B
                0x10 => 0xFFFFFFFF, // DEV_INIT1: All devices enabled
                0x14 => 0xFFFFFFFF, // DEV_INIT1+4
                0x20 => 0xFFFFFFFF, // DEV_INIT2: All devices enabled
                0x24 => 0xFFFFFFFF, // DEV_INIT2+4
                0x30 => 0x80000000, // Unknown status register - bit 31 = ready
                0x34 => 0x00000000, // DEV_TIMING1
                0x38 => 0x00000000, // XMB_NOR_CFG
                0x3C => 0x00000000, // XMB_RAM_CFG
                else => blk: {
                    const idx = (offset >> 2) & 0xFF;
                    break :blk self.stub_registers[idx];
                },
            };
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
            .proc_id => "Processor ID",
            .mailbox => "Mailbox",
            .interrupt_ctrl => "Interrupt Controller",
            .timers => "Timers",
            .system_ctrl => "System Controller",
            .cache_ctrl => "Cache Controller",
            .mem_ctrl => "Memory Controller",
            .dma => "DMA",
            .gpio => "GPIO",
            .device_init => "Device Init",
            .gpo32 => "GPO32",
            .i2s => "I2S",
            .i2c => "I2C",
            .clickwheel => "Click Wheel",
            .ata => "ATA",
            .flash_ctrl => "Flash Controller",
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
