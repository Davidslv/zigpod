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
const dma = @import("peripherals/dma.zig");

// Debug
const gdb_stub = @import("debug/gdb_stub.zig");

pub const Arm7tdmi = arm7tdmi.Arm7tdmi;
pub const MemoryBus = bus_module.MemoryBus;
pub const Ram = ram_module.Ram;
pub const InterruptController = interrupt_ctrl.InterruptController;
pub const Interrupt = interrupt_ctrl.Interrupt;
pub const Timers = timers.Timers;
pub const GpioController = gpio.GpioController;
pub const SystemController = system_ctrl.SystemController;
pub const AtaController = ata.AtaController;
pub const I2sController = i2s.I2sController;
pub const I2cController = i2c.I2cController;
pub const ClickWheel = clickwheel.ClickWheel;
pub const LcdController = lcd.LcdController;
pub const Lcd2Bridge = lcd.Lcd2Bridge;
pub const CacheController = cache_ctrl.CacheController;
pub const DmaController = dma.DmaController;
pub const GdbStub = gdb_stub.GdbStub;
pub const GdbCallbacks = gdb_stub.GdbCallbacks;

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

    /// DMA controller
    dma_ctrl: DmaController,

    /// Click wheel
    wheel: ClickWheel,

    /// LCD controller
    lcd_ctrl: LcdController,

    /// LCD2 Bridge (used by Rockbox)
    lcd_bridge: Lcd2Bridge,

    /// GDB stub (optional, for debugging)
    gdb: ?GdbStub,

    /// Boot ROM (may be empty)
    boot_rom: []const u8,

    /// Configuration
    config: EmulatorConfig,

    /// Running state
    running: bool,

    /// Total cycles executed
    total_cycles: u64,

    /// Flag to track if we've fired the RTOS kickstart interrupt
    /// This is a workaround to break out of the scheduler loop
    rtos_kickstart_fired: bool,

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
        const dma_ctrl_instance = DmaController.init();
        const wheel_instance = ClickWheel.init();
        const lcd_ctrl_instance = LcdController.init();
        // Note: lcd_bridge is initialized after struct creation
        // because it needs a pointer to the lcd_ctrl in the struct

        // Calculate cycles per frame (assuming 60fps)
        const cycles_per_frame = @as(u64, config.cpu_freq_mhz) * 1_000_000 / 60;

        var self = Self{
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
            .dma_ctrl = dma_ctrl_instance,
            .wheel = wheel_instance,
            .lcd_ctrl = lcd_ctrl_instance,
            .lcd_bridge = undefined, // Will be initialized below
            .gdb = null,
            .boot_rom = boot_rom,
            .config = config,
            .running = false,
            .total_cycles = 0,
            .rtos_kickstart_fired = false,
            .cycles_per_frame = cycles_per_frame,
            .next_frame_cycles = cycles_per_frame,
        };

        // Note: lcd_bridge.lcd_ctrl pointer is set up by setupLcdBridge()
        // after the Emulator is in its final memory location
        self.lcd_bridge = Lcd2Bridge.init(undefined);

        return self;
    }

    /// Setup LCD bridge pointer after emulator is in final location
    /// Must be called after init() before running the emulator
    pub fn setupLcdBridge(self: *Self) void {
        self.lcd_bridge.lcd_ctrl = &self.lcd_ctrl;
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
        self.dma_ctrl.setInterruptController(&self.int_ctrl);

        // Connect I2S to I2C codec for volume control
        self.i2s_ctrl.setCodec(&self.i2c_ctrl);

        // Register with memory bus
        self.bus.registerPeripheral(.interrupt_ctrl, self.int_ctrl.createHandler());
        self.bus.registerPeripheral(.timers, self.timer.createHandler());
        self.bus.registerPeripheral(.gpio, self.gpio_ctrl.createHandler());
        self.bus.registerPeripheral(.system_ctrl, self.sys_ctrl.createHandler());
        self.bus.registerPeripheral(.cache_ctrl, self.cache.createHandler());
        self.bus.registerPeripheral(.dma, self.dma_ctrl.createHandler());
        self.bus.registerPeripheral(.ata, self.ata_ctrl.createHandler());
        self.bus.registerPeripheral(.i2s, self.i2s_ctrl.createHandler());
        self.bus.registerPeripheral(.i2c, self.i2c_ctrl.createHandler());
        self.bus.registerPeripheral(.clickwheel, self.wheel.createHandler());
        self.bus.registerPeripheral(.lcd, self.lcd_ctrl.createHandler());
        self.bus.registerPeripheral(.lcd_bridge, self.lcd_bridge.createHandler());

        // Initialize GPIO defaults for iPod hardware:
        // GPIO A bit 5 = hold switch (1 = not held, 0 = held)
        // GPIO A bits 0-4 = button inputs (active low on 1G-3G models)
        //   Bit 4 (0x10) = MENU
        //   Bit 3 (0x08) = LEFT
        //   Bit 2 (0x04) = PLAY
        //   Bit 1 (0x02) = unused
        //   Bit 0 (0x01) = RIGHT
        // Set all high so no buttons are "pressed" and hold switch is OFF
        self.gpio_ctrl.setPin(.a, 0, true); // RIGHT not pressed
        self.gpio_ctrl.setPin(.a, 1, true); // unused
        self.gpio_ctrl.setPin(.a, 2, true); // PLAY not pressed
        self.gpio_ctrl.setPin(.a, 3, true); // LEFT not pressed
        self.gpio_ctrl.setPin(.a, 4, true); // MENU not pressed
        self.gpio_ctrl.setPin(.a, 5, true); // Hold switch OFF
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

        // Update CPU IRQ/FIQ lines from interrupt controller
        self.cpu.setIrqLine(self.int_ctrl.hasPendingIrq());
        self.cpu.setFiqLine(self.int_ctrl.hasPendingFiq());

        // Execute CPU instruction
        const cycles = self.cpu.step(&cpu_bus);
        self.total_cycles += cycles;

        // Execute COP if enabled and not sleeping
        if (self.cop) |*cop| {
            // Use the COP state machine to determine if COP should execute
            if (self.sys_ctrl.tickCopState()) {
                // COP uses its own interrupt enable mask
                cop.setIrqLine(self.int_ctrl.hasCopPendingIrq());
                cop.setFiqLine(self.int_ctrl.hasCopPendingFiq());

                // Set COP access flag for PROC_ID and mailbox operations
                self.bus.setCopAccess(true);
                _ = cop.step(&cpu_bus);
                self.bus.setCopAccess(false);
            }
        }

        // Tick peripherals
        self.timer.tick(cycles);

        // RTOS Kickstart: Try multiple approaches to break the scheduler wait loop
        // The Apple firmware RTOS scheduler waits for tasks to become ready.
        // Tasks need timer interrupts to wake up, but IRQ was disabled because
        // dispatch tables weren't ready. Let's try enabling IRQ later when
        // more initialization has completed.
        //
        // Approach 1: Enable hw_accel kickstart (modifies reads)
        // Approach 2: Enable IRQ and fire timer (may have valid dispatch tables now)
        if (!self.rtos_kickstart_fired and self.total_cycles >= 100_000) {
            self.rtos_kickstart_fired = true;
            // Enable kickstart mode - hw_accel reads will return modified values
            self.bus.enableKickstart();
            // Enable I2C tracing
            self.i2c_ctrl.enableTracing();
            std.debug.print("RTOS KICKSTART: Enabled hw_accel kickstart at cycle {}\n", .{self.total_cycles});
        }

        // NOTE: IRQ kickstart is DISABLED because:
        // 1. Firmware enters scheduler wait loop at ~3000 cycles
        // 2. IRQ dispatch tables are set up by tasks that never run
        // 3. Firing IRQ causes crash to 0xE12FFF1C (uninitialized handler)
        //
        // The scheduler wait loop at 0x1000097C calls wait_for_event (0x100277C0)
        // which blocks until task state changes. Task state lives in RAM somewhere,
        // not in hw_accel (which is only used during init).
        //
        // Possible solutions:
        // 1. Find task state RAM address and modify it directly
        // 2. Implement I2C device responses - tasks may be waiting for PMU/codec
        // 3. Find where dispatch tables should be and initialize them manually

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

    // === COP (Coprocessor) Support ===

    /// Initialize COP with a specific entry point
    /// This sets up the COP to start executing at the given address
    /// COP starts in sleeping state and must be woken via COP_CTL
    pub fn initCop(self: *Self, entry_point: u32) void {
        if (self.cop) |*cop| {
            cop.reset();
            cop.setReg(15, entry_point);
            // COP starts sleeping, waiting for wake from CPU
            self.sys_ctrl.cop_state = .sleeping;
        }
    }

    /// Get COP program counter (if COP exists)
    pub fn getCopPc(self: *const Self) ?u32 {
        if (self.cop) |*cop| {
            return cop.getPc();
        }
        return null;
    }

    /// Get COP state
    pub fn getCopState(self: *const Self) system_ctrl.CopState {
        return self.sys_ctrl.getCopState();
    }

    /// Check if COP is running
    pub fn isCopRunning(self: *const Self) bool {
        return self.sys_ctrl.isCopRunning();
    }

    /// Check if COP is sleeping
    pub fn isCopSleeping(self: *const Self) bool {
        return self.sys_ctrl.isCopSleeping();
    }

    // === GDB Debugging Support ===

    /// Enable GDB debugging on the specified port
    pub fn enableGdb(self: *Self, port: u16) !void {
        // Create GDB callbacks
        const callbacks = GdbCallbacks{
            .context = @ptrCast(self),
            .readRegFn = gdbReadReg,
            .writeRegFn = gdbWriteReg,
            .readMemFn = gdbReadMem,
            .writeMemFn = gdbWriteMem,
            .stepFn = gdbStep,
            .getPcFn = gdbGetPc,
        };

        self.gdb = GdbStub.init(callbacks);
        try self.gdb.?.listen(port);
    }

    /// Close GDB connection
    pub fn disableGdb(self: *Self) void {
        if (self.gdb) |*g| {
            g.close();
        }
        self.gdb = null;
    }

    /// Check if GDB is enabled
    pub fn isGdbEnabled(self: *const Self) bool {
        return self.gdb != null;
    }

    /// Poll GDB stub for commands (non-blocking)
    pub fn pollGdb(self: *Self) void {
        if (self.gdb) |*g| {
            // Accept new connections
            if (!g.isConnected()) {
                _ = g.acceptNonBlocking();
            }

            // Process incoming commands
            g.poll();
        }
    }

    /// Check if GDB is halted (waiting for commands)
    pub fn isGdbHalted(self: *const Self) bool {
        if (self.gdb) |*g| {
            return g.isHalted();
        }
        return false;
    }

    /// GDB callback: read register
    fn gdbReadReg(ctx: *anyopaque, reg: u8) u32 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (reg < 16) {
            return self.cpu.getReg(@intCast(reg));
        } else if (reg == 16) {
            // CPSR
            return self.cpu.getCpsr();
        }
        return 0;
    }

    /// GDB callback: write register
    fn gdbWriteReg(ctx: *anyopaque, reg: u8, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (reg < 16) {
            self.cpu.setReg(@intCast(reg), value);
        } else if (reg == 16) {
            // CPSR
            self.cpu.setCpsr(value);
        }
    }

    /// GDB callback: read memory byte
    fn gdbReadMem(ctx: *anyopaque, addr: u32) u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.bus.read8(addr);
    }

    /// GDB callback: write memory byte
    fn gdbWriteMem(ctx: *anyopaque, addr: u32, value: u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.bus.write8(addr, value);
    }

    /// GDB callback: single step
    fn gdbStep(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self.step();
    }

    /// GDB callback: get PC
    fn gdbGetPc(ctx: *anyopaque) u32 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.cpu.getPc();
    }

    /// Run with GDB debugging support
    /// Returns cycles executed, stops when GDB halts or max_cycles reached
    pub fn runWithGdb(self: *Self, max_cycles: u64) u64 {
        const start_cycles = self.total_cycles;
        self.running = true;

        while (self.running and (self.total_cycles - start_cycles) < max_cycles) {
            // Poll GDB for commands
            self.pollGdb();

            // Check if GDB wants us halted (only when connected)
            if (self.gdb) |*g| {
                if (g.isConnected() and g.isHalted()) {
                    // When halted with GDB connected, just poll and don't execute
                    // Use Thread.sleep to avoid busy-waiting
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }

                // Execute one step
                _ = self.step();

                // Check for breakpoints (only when connected)
                if (g.isConnected() and g.checkBreakpoint()) {
                    g.setHalted(true);
                    g.running = false;
                    g.notifyBreakpoint();
                }
            } else {
                // No GDB, just run
                _ = self.step();
            }
        }

        return self.total_cycles - start_cycles;
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
