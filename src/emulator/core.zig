//! PP5021C Emulator Core
//!
//! Main emulator that integrates all components:
//! - ARM7TDMI CPU (main core and COP)
//! - Memory bus with correct PP5021C memory map
//! - All peripherals (timers, GPIO, ATA, I2S, LCD, click wheel, etc.)
//!
//! This is the entry point for the emulator.

const std = @import("std");

// CPU
const arm7tdmi = @import("cpu/arm7tdmi.zig");
const arm_executor = @import("cpu/arm_executor.zig");

// Memory
const bus_module = @import("memory/bus.zig");
const ram_module = @import("memory/ram.zig");

// Peripherals
const interrupt_ctrl = @import("peripherals/interrupt_ctrl.zig");
const timers = @import("peripherals/timers.zig");
const gpio = @import("peripherals/gpio.zig");
const system_ctrl = @import("peripherals/system_ctrl.zig");
const ata = @import("peripherals/ata.zig");
const i2s = @import("peripherals/i2s.zig");
const i2c = @import("peripherals/i2c.zig");
const clickwheel = @import("peripherals/clickwheel.zig");
const lcd = @import("peripherals/lcd.zig");
const cache_ctrl = @import("peripherals/cache_ctrl.zig");

pub const Arm7tdmi = arm7tdmi.Arm7tdmi;
pub const MemoryBus = bus_module.MemoryBus;
pub const Ram = ram_module.Ram;
pub const InterruptController = interrupt_ctrl.InterruptController;
pub const Timers = timers.Timers;
pub const GpioController = gpio.GpioController;
pub const SystemController = system_ctrl.SystemController;
pub const AtaController = ata.AtaController;
pub const I2sController = i2s.I2sController;
pub const I2cController = i2c.I2cController;
pub const ClickWheel = clickwheel.ClickWheel;
pub const LcdController = lcd.LcdController;
pub const CacheController = cache_ctrl.CacheController;

/// Emulator configuration
pub const EmulatorConfig = struct {
    /// SDRAM size (32MB for 30GB model, 64MB for 60/80GB)
    sdram_size: usize = 32 * 1024 * 1024,

    /// CPU frequency in MHz
    cpu_freq_mhz: u32 = 80,

    /// Boot ROM data (optional, can be null for headerless boot)
    boot_rom: ?[]const u8 = null,

    /// Disk image path (optional)
    disk_image: ?[]const u8 = null,

    /// Enable COP (second core)
    enable_cop: bool = false,
};

/// PP5021C Emulator
pub const Emulator = struct {
    /// Allocator for dynamic allocations
    allocator: std.mem.Allocator,

    /// Main CPU
    cpu: Arm7tdmi,

    /// COP (second CPU core, optional)
    cop: ?Arm7tdmi,

    /// SDRAM
    sdram: Ram,

    /// Memory bus
    bus: MemoryBus,

    /// Interrupt controller
    int_ctrl: InterruptController,

    /// Timers
    timer: Timers,

    /// GPIO controller
    gpio_ctrl: GpioController,

    /// System controller
    sys_ctrl: SystemController,

    /// ATA/IDE controller
    ata_ctrl: AtaController,

    /// I2S audio controller
    i2s_ctrl: I2sController,

    /// I2C controller
    i2c_ctrl: I2cController,

    /// Cache controller
    cache: CacheController,

    /// Click wheel
    wheel: ClickWheel,

    /// LCD controller
    lcd_ctrl: LcdController,

    /// Boot ROM (may be empty)
    boot_rom: []const u8,

    /// Configuration
    config: EmulatorConfig,

    /// Running state
    running: bool,

    /// Total cycles executed
    total_cycles: u64,

    /// Cycles per frame (at 60fps)
    cycles_per_frame: u64,

    /// Next frame cycle count
    next_frame_cycles: u64,

    const Self = @This();

    /// Initialize the emulator
    pub fn init(allocator: std.mem.Allocator, config: EmulatorConfig) !Self {
        // Allocate SDRAM
        var sdram = try Ram.init(allocator, config.sdram_size);
        errdefer sdram.deinit();

        // Create memory bus
        const boot_rom = config.boot_rom orelse &[_]u8{};
        const bus_instance = MemoryBus.initWithSdram(sdram.slice(), boot_rom);

        // Create CPU
        const cpu = Arm7tdmi.init();

        // Create COP if enabled
        const cop: ?Arm7tdmi = if (config.enable_cop) Arm7tdmi.init() else null;

        // Create peripherals
        const int_ctrl_instance = InterruptController.init();
        const timer_instance = Timers.init(config.cpu_freq_mhz);
        const gpio_ctrl_instance = GpioController.init();
        const sys_ctrl_instance = SystemController.init();
        const ata_ctrl_instance = AtaController.init();
        const i2s_ctrl_instance = I2sController.init();
        const i2c_ctrl_instance = I2cController.init();
        const cache_instance = CacheController.init();
        const wheel_instance = ClickWheel.init();
        const lcd_ctrl_instance = LcdController.init();

        // Calculate cycles per frame (assuming 60fps)
        const cycles_per_frame = @as(u64, config.cpu_freq_mhz) * 1_000_000 / 60;

        return Self{
            .allocator = allocator,
            .cpu = cpu,
            .cop = cop,
            .sdram = sdram,
            .bus = bus_instance,
            .int_ctrl = int_ctrl_instance,
            .timer = timer_instance,
            .gpio_ctrl = gpio_ctrl_instance,
            .sys_ctrl = sys_ctrl_instance,
            .ata_ctrl = ata_ctrl_instance,
            .i2s_ctrl = i2s_ctrl_instance,
            .i2c_ctrl = i2c_ctrl_instance,
            .cache = cache_instance,
            .wheel = wheel_instance,
            .lcd_ctrl = lcd_ctrl_instance,
            .boot_rom = boot_rom,
            .config = config,
            .running = false,
            .total_cycles = 0,
            .cycles_per_frame = cycles_per_frame,
            .next_frame_cycles = cycles_per_frame,
        };
    }

    /// Deinitialize the emulator
    pub fn deinit(self: *Self) void {
        self.sdram.deinit();
    }

    /// Register all peripherals with the memory bus
    pub fn registerPeripherals(self: *Self) void {
        // Connect peripherals to interrupt controller
        self.timer.setInterruptController(&self.int_ctrl);
        self.ata_ctrl.setInterruptController(&self.int_ctrl);
        self.i2s_ctrl.setInterruptController(&self.int_ctrl);

        // Register with memory bus
        self.bus.registerPeripheral(.interrupt_ctrl, self.int_ctrl.createHandler());
        self.bus.registerPeripheral(.timers, self.timer.createHandler());
        self.bus.registerPeripheral(.gpio, self.gpio_ctrl.createHandler());
        self.bus.registerPeripheral(.system_ctrl, self.sys_ctrl.createHandler());
        self.bus.registerPeripheral(.cache_ctrl, self.cache.createHandler());
        self.bus.registerPeripheral(.ata, self.ata_ctrl.createHandler());
        self.bus.registerPeripheral(.i2s, self.i2s_ctrl.createHandler());
        self.bus.registerPeripheral(.i2c, self.i2c_ctrl.createHandler());
        self.bus.registerPeripheral(.clickwheel, self.wheel.createHandler());
        self.bus.registerPeripheral(.lcd, self.lcd_ctrl.createHandler());
    }

    /// Reset the emulator
    pub fn reset(self: *Self) void {
        self.cpu.reset();
        if (self.cop) |*cop| {
            cop.reset();
        }
        self.total_cycles = 0;
        self.next_frame_cycles = self.cycles_per_frame;
    }

    /// Create CPU memory bus interface
    fn createCpuBus(self: *Self) arm_executor.MemoryBus {
        return .{
            .context = @ptrCast(self),
            .read8Fn = cpuRead8,
            .read16Fn = cpuRead16,
            .read32Fn = cpuRead32,
            .write8Fn = cpuWrite8,
            .write16Fn = cpuWrite16,
            .write32Fn = cpuWrite32,
        };
    }

    fn cpuRead8(ctx: *anyopaque, addr: u32) u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.bus.read8(addr);
    }

    fn cpuRead16(ctx: *anyopaque, addr: u32) u16 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.bus.read16(addr);
    }

    fn cpuRead32(ctx: *anyopaque, addr: u32) u32 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.bus.read32(addr);
    }

    fn cpuWrite8(ctx: *anyopaque, addr: u32, value: u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.bus.write8(addr, value);
    }

    fn cpuWrite16(ctx: *anyopaque, addr: u32, value: u16) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.bus.write16(addr, value);
    }

    fn cpuWrite32(ctx: *anyopaque, addr: u32, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.bus.write32(addr, value);
    }

    /// Execute one CPU cycle
    pub fn step(self: *Self) u32 {
        var cpu_bus = self.createCpuBus();

        // Update IRQ line from interrupt controller
        self.cpu.setIrqLine(self.int_ctrl.hasPendingIrq());
        self.cpu.setFiqLine(self.int_ctrl.hasPendingFiq());

        // Execute CPU instruction
        const cycles = self.cpu.step(&cpu_bus);
        self.total_cycles += cycles;

        // Execute COP if enabled
        if (self.cop) |*cop| {
            if (self.sys_ctrl.isEnabled(.cop)) {
                cop.setIrqLine(self.int_ctrl.hasPendingIrq());
                _ = cop.step(&cpu_bus);
            }
        }

        // Tick peripherals
        self.timer.tick(cycles);

        return cycles;
    }

    /// Run for a number of cycles
    pub fn run(self: *Self, max_cycles: u64) u64 {
        const start_cycles = self.total_cycles;
        self.running = true;

        while (self.running and (self.total_cycles - start_cycles) < max_cycles) {
            _ = self.step();
        }

        return self.total_cycles - start_cycles;
    }

    /// Run one frame (at 60fps)
    pub fn runFrame(self: *Self) void {
        while (self.total_cycles < self.next_frame_cycles) {
            _ = self.step();
        }
        self.next_frame_cycles += self.cycles_per_frame;
    }

    /// Stop execution
    pub fn stop(self: *Self) void {
        self.running = false;
    }

    /// Load firmware into IRAM
    pub fn loadIram(self: *Self, data: []const u8) void {
        self.bus.loadIram(0, data);
    }

    /// Load firmware into SDRAM
    pub fn loadSdram(self: *Self, offset: u32, data: []const u8) void {
        self.bus.loadSdram(offset, data);
    }

    /// Set disk backend for ATA
    pub fn setDisk(self: *Self, disk: *ata.DiskBackend) void {
        self.ata_ctrl.setDisk(disk);
    }

    /// Get LCD framebuffer
    pub fn getFramebuffer(self: *const Self) *const [lcd.FRAMEBUFFER_SIZE]u8 {
        return &self.lcd_ctrl.framebuffer;
    }

    /// Press click wheel button
    pub fn pressButton(self: *Self, button: clickwheel.Button) void {
        self.wheel.pressButton(button);
    }

    /// Release click wheel button
    pub fn releaseButton(self: *Self, button: clickwheel.Button) void {
        self.wheel.releaseButton(button);
    }

    /// Rotate click wheel
    pub fn rotateWheel(self: *Self, delta: i8) void {
        self.wheel.rotateWheel(delta);
    }

    /// Get CPU program counter
    pub fn getPc(self: *const Self) u32 {
        return self.cpu.getPc();
    }

    /// Get CPU register
    pub fn getReg(self: *const Self, reg: u4) u32 {
        return self.cpu.getReg(reg);
    }

    /// Check if CPU is in Thumb mode
    pub fn isThumb(self: *const Self) bool {
        return self.cpu.isThumb();
    }
};

// Tests
test "emulator initialization" {
    const allocator = std.testing.allocator;
    var emu = try Emulator.init(allocator, .{
        .sdram_size = 1024 * 1024, // 1MB for testing
        .cpu_freq_mhz = 80,
    });
    defer emu.deinit();

    // Check initial state
    try std.testing.expectEqual(@as(u32, 0), emu.getPc());
    try std.testing.expect(!emu.isThumb());
}

test "emulator step" {
    const allocator = std.testing.allocator;
    var emu = try Emulator.init(allocator, .{
        .sdram_size = 1024 * 1024,
    });
    defer emu.deinit();

    // Load a simple instruction at address 0
    // MOV R0, #0x42 (ARM: 0xE3A00042)
    const code = [_]u8{ 0x42, 0x00, 0xA0, 0xE3 };
    emu.bus.loadIram(0, &code);

    // Map IRAM to address 0 for boot (in real hardware, ROM is at 0)
    // For testing, we'll write directly to where PC starts

    // Reset and step
    emu.reset();
    _ = emu.step();

    // PC should have advanced
    try std.testing.expect(emu.getPc() > 0);
}

test "peripheral registration" {
    const allocator = std.testing.allocator;
    var emu = try Emulator.init(allocator, .{
        .sdram_size = 1024 * 1024,
    });
    defer emu.deinit();

    emu.registerPeripherals();

    // Write to a timer register and read it back
    emu.bus.write32(0x60005000, 0x12345678);
    try std.testing.expectEqual(@as(u32, 0x12345678), emu.bus.read32(0x60005000));
}
