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

    /// Debug: count timer wait loop iterations
    timer_loop_count: u64,

    /// Flag to track if we've fired the RTOS kickstart interrupt
    /// This is a workaround to break out of the scheduler loop
    rtos_kickstart_fired: bool,

    /// Flags for button injection in headless mode
    button_injected: bool,
    button_released: bool,

    /// Flag for firmware filename patch (apple_os.ipod -> rockbox.ipod)
    filename_patched: bool,

    /// Counter for Rockbox restart attempts (for COP sync fix)
    rockbox_restart_count: u32,

    /// Counter for COP wake function calls (to detect infinite loops)
    cop_wake_skip_count: u32,

    /// Counter for iterations in wake_core polling loop
    wake_loop_iterations: u32,

    /// Counter for scheduler skip count (to detect repeated scheduler calls)
    sched_skip_count: u32,

    /// Counter for idle loop iterations
    idle_loop_count: u32,

    /// Counter for IRAM loop iterations (0x40008928)
    iram_loop_count: u32,

    /// Counter for switch_thread skip iterations
    switch_thread_count: u32,

    /// Total cumulative scheduler skips (never resets - for LCD bypass trigger)
    total_sched_skips: u32,

    /// Flag: LCD bypass test has been done
    lcd_bypass_done: bool,

    /// Counter for consecutive caller loop escape failures (zero-stack situations)
    caller_loop_escape_failures: u32,

    /// Flag: Timer1 enabled by emulator to fix kernel initialization
    timer1_enabled_by_emulator: bool,

    /// Flag: main() has been entered (for tracing)
    main_entered: bool,

    /// Counter for main() trace (first N instructions)
    main_trace_count: u32,

    /// Flag: .init copy loop has started
    init_copy_started: bool,

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
            .timer_loop_count = 0,
            .rtos_kickstart_fired = false,
            .button_injected = false,
            .button_released = false,
            .filename_patched = false,
            .rockbox_restart_count = 0,
            .cop_wake_skip_count = 0,
            .wake_loop_iterations = 0,
            .sched_skip_count = 0,
            .idle_loop_count = 0,
            .iram_loop_count = 0,
            .switch_thread_count = 0,
            .total_sched_skips = 0,
            .lcd_bypass_done = false,
            .caller_loop_escape_failures = 0,
            .timer1_enabled_by_emulator = false,
            .main_entered = false,
            .main_trace_count = 0,
            .init_copy_started = false,
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
        self.wheel.setInterruptController(&self.int_ctrl);

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

        // NOTE: Don't press any button at boot - let bootloader auto-boot
        // With MENU pressed, it shows a menu. Without any button, it should
        // try to load Rockbox first (if present), then Apple firmware.
        // self.wheel.pressButton(.menu);

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

        // Boot phase tracing
        const pc = self.cpu.getPc();
        if (self.total_cycles < 1_000_000 and self.total_cycles % 100_000 == 0) {
            std.debug.print("BOOT TRACE: cycle {} PC=0x{X:0>8} R0=0x{X:0>8}\n", .{
                self.total_cycles, pc, self.cpu.getReg(0),
            });
        }

        // BOOT PATH DEBUG: Trace the exact decision point
        // Found via disassembly:
        //   0x40000D64: CMP R5, #2    - check btn == BUTTON_MENU
        //   0x40000D70: CMP R6, #0    - check button_was_held
        //   0x40000D78: CMP R3, #0    - combined check
        //   0x40000D7C: BEQ 0x40000E44 - branch to "Loading Rockbox" if r3==0
        //   0x40000D80: LDR R0, "Loading original firmware..."
        //
        // R5 = btn (from key_pressed())
        // R6 = button_was_held (from button_hold() called early)
        if (pc == 0x40000D64) {
            std.debug.print("BOOT_DECISION: At CMP R5, #2 - R5 (btn) = 0x{X:0>8}, R6 (button_was_held) = 0x{X:0>8}\n", .{
                self.cpu.getReg(5), self.cpu.getReg(6),
            });
        }
        if (pc == 0x40000D7C) {
            const will_branch = if (self.cpu.getReg(3) == 0) "will" else "will NOT";
            std.debug.print("BOOT_DECISION: At BEQ branch - R3 (combined) = 0x{X:0>8}, {s} branch to Rockbox path\n", .{
                self.cpu.getReg(3), will_branch,
            });
        }
        if (pc == 0x40000D80) {
            std.debug.print("BOOT_DECISION: TAKING 'Loading original firmware' PATH\n", .{});
        }
        if (pc == 0x40000E44) {
            std.debug.print("BOOT_DECISION: At 'Loading Rockbox' path entry point\n", .{});
        }

        // BOOT PATH FIX: Patch the boot decision branch to always take Rockbox path
        // At 0x40000D7C: BEQ to "Loading Rockbox" path (instruction 0x0A000030)
        // Change to unconditional B (instruction 0xEA000030) to bypass button_was_held check
        // Re-apply whenever we see the original instruction (bootloader may be reloaded on restart)
        if (pc >= 0x40000000 and pc < 0x40000100 and self.total_cycles > 50_000) {
            const branch_addr: u32 = 0x40000D7C;
            const current_instr = self.bus.read32(branch_addr);
            // Check if it's the BEQ instruction we want to patch
            if (current_instr == 0x0A000030) {
                // Change BEQ (condition 0) to B (condition 14 = always)
                // 0x0A000030 -> 0xEA000030
                self.bus.write32(branch_addr, 0xEA000030);
                std.debug.print("BOOT PATH PATCHED: Changed BEQ to B at 0x{X:0>8} (0x0A000030 -> 0xEA000030)\n", .{branch_addr});
            }
        }

        // Patch "apple_os.ipod" to "rockbox.ipod" after bootloader relocates to IRAM
        // NOTE: This patch is now backup only - the boot path patch above should make this unnecessary
        // The filename string is at IRAM 0x4000BEFC
        // NOTE: We re-apply this patch periodically because Rockbox may overwrite IRAM during startup
        if (pc >= 0x40000000 and pc < 0x40020000 and self.total_cycles > 100_000) {
            // Check if "apple" exists at 0x4000BEFC
            const addr: u32 = 0x4000BEFC;
            if (self.bus.read8(addr) == 'a' and self.bus.read8(addr + 1) == 'p' and
                self.bus.read8(addr + 2) == 'p' and self.bus.read8(addr + 3) == 'l' and
                self.bus.read8(addr + 4) == 'e') {
                // Patch "apple_os.ipod" to "rockbox.ipod"
                // Both are 13 chars so it fits perfectly
                const new_name = "rockbox.ipod";
                for (new_name, 0..) |c, i| {
                    self.bus.write8(addr + @as(u32, @intCast(i)), c);
                }
                self.bus.write8(addr + new_name.len, 0); // null terminator
                self.filename_patched = true;
                std.debug.print("FILENAME PATCHED: Changed apple_os.ipod to rockbox.ipod at 0x{X:0>8}\n", .{addr});
            }
        }
        // Periodic trace to understand where we're spending time
        if (self.total_cycles % 10_000_000 == 0 and self.total_cycles > 90_000_000) {
            std.debug.print("PERIODIC: cycle={} PC=0x{X:0>8} R0=0x{X:0>8} R1=0x{X:0>8} R2=0x{X:0>8} LR=0x{X:0>8}\n", .{
                self.total_cycles, pc, self.cpu.getReg(0), self.cpu.getReg(1), self.cpu.getReg(2), self.cpu.getReg(14),
            });
        }
        // Key address tracing
        if (pc == 0x4000002C) {
            std.debug.print("BOOT: Reached post-copy code at 0x2C (cycle {})\n", .{self.total_cycles});
        }
        // Trace calls to the delay wrapper at 0x40009668
        if (pc == 0x40009668) {
            std.debug.print("DELAY_WRAPPER_CALL: cycle={} LR=0x{X:0>8}\n", .{ self.total_cycles, self.cpu.getReg(14) });
        }
        // Trace delay wrapper return (after delay, checking R0)
        if (pc == 0x40009680) { // POP {PC} in wrapper
            std.debug.print("DELAY_WRAPPER_RETURN: cycle={} R0=0x{X:0>8}\n", .{ self.total_cycles, self.cpu.getReg(0) });
        }
        // Trace at 0xAB0 (CMP R0, #1) and 0xAB4 (BNE)
        if (pc == 0x40000AB0) {
            std.debug.print("CMP_R0_1: cycle={} R0=0x{X:0>8}\n", .{ self.total_cycles, self.cpu.getReg(0) });
        }
        if (pc == 0x40000AB8) { // After BNE - if we get here, branch was not taken
            std.debug.print("AFTER_BNE_NOT_TAKEN: cycle={} R0=0x{X:0>8}\n", .{ self.total_cycles, self.cpu.getReg(0) });
        }
        if (pc == 0x40000B00) { // BNE target - if we get here, branch was taken
            std.debug.print("BNE_TARGET: cycle={} R0=0x{X:0>8}\n", .{ self.total_cycles, self.cpu.getReg(0) });
        }
        // Trace exit from delay loop - branch at 0xB2C
        if (pc == 0x40000B2C) {
            std.debug.print("DELAY_LOOP_EXIT: cycle={} target=0x{X:0>8}\n", .{ self.total_cycles, self.cpu.getReg(2) });
        }
        // Trace entry to error halt at 0xB600
        if (pc == 0x4000B600) {
            std.debug.print("HALT_0xB600: cycle={} LR=0x{X:0>8}\n", .{ self.total_cycles, self.cpu.getReg(14) });
        }
        // Trace potential auto-boot path at 0xA70
        if (pc == 0x40000A70) {
            std.debug.print("AUTO_BOOT_PATH: cycle={} R0=0x{X:0>8}\n", .{ self.total_cycles, self.cpu.getReg(0) });
        }
        // Trace file load function at 0x40000444 (constructs "/.rockbox/%s" path)
        if (pc == 0x40000444) {
            std.debug.print("FILE_LOAD_FUNC: cycle={} R0=0x{X:0>8} R1=0x{X:0>8} R2=0x{X:0>8}\n", .{
                self.total_cycles, self.cpu.getReg(0), self.cpu.getReg(1), self.cpu.getReg(2)
            });
            // R1 should be the filename (e.g., "rockbox.ipod")
            const filename_addr = self.cpu.getReg(1);
            if (filename_addr >= 0x40000000 and filename_addr < 0x40020000) {
                var buf: [64]u8 = undefined;
                var i: usize = 0;
                while (i < 63) : (i += 1) {
                    const c = self.bus.read8(filename_addr + @as(u32, @intCast(i)));
                    if (c == 0) break;
                    buf[i] = c;
                }
                std.debug.print("  FILENAME (R1): \"{s}\"\n", .{buf[0..i]});
            }
        }
        // Trace open() at 0x40002174
        if (pc == 0x40002174) {
            std.debug.print("OPEN_CALL: cycle={} R0=0x{X:0>8} R1=0x{X:0>8}\n", .{
                self.total_cycles, self.cpu.getReg(0), self.cpu.getReg(1)
            });
            // R0 should be the path
            const path_addr = self.cpu.getReg(0);
            const is_valid = (path_addr >= 0x40000000 and path_addr < 0x40020000) or
                            (path_addr >= 0x10000000 and path_addr < 0x12000000);
            if (is_valid) {
                var buf: [128]u8 = undefined;
                var i: usize = 0;
                while (i < 127) : (i += 1) {
                    const c = self.bus.read8(path_addr + @as(u32, @intCast(i)));
                    if (c == 0) break;
                    buf[i] = c;
                }
                std.debug.print("  OPEN PATH: \"{s}\"\n", .{buf[0..i]});
            }
        }
        // Trace return from auto-boot function call at 0xA88 -> 0xA8C
        if (pc == 0x40000A8C) {
            std.debug.print("AUTO_BOOT_FUNC_RET: cycle={} R0=0x{X:0>8} (firmware load result?)\n", .{
                self.total_cycles, self.cpu.getReg(0)
            });
        }
        // Trace entry to the load_firmware function at 0x40004680
        if (pc == 0x40004680) {
            std.debug.print("LOAD_FIRMWARE_ENTRY: cycle={} R0=0x{X:0>8} R1=0x{X:0>8} R2=0x{X:0>8} LR=0x{X:0>8}\n", .{
                self.total_cycles, self.cpu.getReg(0), self.cpu.getReg(1), self.cpu.getReg(2), self.cpu.getReg(14)
            });
            // Print the path string at R2 (should be the firmware path)
            const path_addr = self.cpu.getReg(2);
            if ((path_addr >= 0x40000000 and path_addr < 0x40020000) or
                (path_addr >= 0x10000000 and path_addr < 0x12000000)) {
                var path_buf: [128]u8 = undefined;
                var i: usize = 0;
                while (i < 127) : (i += 1) {
                    const c = self.bus.read8(path_addr + @as(u32, @intCast(i)));
                    if (c == 0) break;
                    path_buf[i] = c;
                }
                std.debug.print("  FIRMWARE PATH (R2): \"{s}\"\n", .{path_buf[0..i]});
            }
        }
        // Trace the inner function at 0x400045D0 which does the actual work
        if (pc == 0x400045D0) {
            std.debug.print("LOAD_FW_INNER: cycle={} R0=0x{X:0>8} R1=0x{X:0>8} R2=0x{X:0>8} R3=0x{X:0>8}\n", .{
                self.total_cycles, self.cpu.getReg(0), self.cpu.getReg(1), self.cpu.getReg(2), self.cpu.getReg(3)
            });
            // Also dump what's at R2 to see if it's a path or display string
            const r2_addr = self.cpu.getReg(2);
            if (r2_addr >= 0x10000000 and r2_addr < 0x12000000) {
                var buf: [64]u8 = undefined;
                var j: usize = 0;
                while (j < 63) : (j += 1) {
                    const c = self.bus.read8(r2_addr + @as(u32, @intCast(j)));
                    if (c == 0 or c < 32 or c > 126) break;
                    buf[j] = c;
                }
                std.debug.print("  R2 CONTENT: \"{s}\"\n", .{buf[0..j]});
            }
        }
        // Trace the comparison result at 0x400045FC (CMP R5, #0 - checking if R2 was null)
        if (pc == 0x400045FC) {
            std.debug.print("LOAD_FW_CMP: cycle={} R0=0x{X:0>8} R5=0x{X:0>8} (R5==0 means early return)\n", .{
                self.total_cycles, self.cpu.getReg(0), self.cpu.getReg(5)
            });
        }
        // Trace what the function reads from 0x4000BC64 (disk mounted flag?)
        if (pc == 0x400045EC) {
            const ptr = self.cpu.getReg(3);
            const value = self.bus.read32(ptr);
            std.debug.print("LOAD_FW_DISK_STATE: [0x{X:0>8}]=0x{X:0>8} (disk state?)\n", .{ ptr, value });
        }
        // Trace the open_file call at 0x40004618 (BX R4 where R4=0x4000A260)
        if (pc == 0x40004618) {
            std.debug.print("LOAD_FW_OPEN_FILE: cycle={} R0=0x{X:0>8} (path) R1=0x{X:0>8} R2=0x{X:0>8} R4=0x{X:0>8}\n", .{
                self.total_cycles, self.cpu.getReg(0), self.cpu.getReg(1), self.cpu.getReg(2), self.cpu.getReg(4)
            });
            // Try to read the path string (from IRAM or SDRAM)
            const path_addr = self.cpu.getReg(0);
            const is_iram = path_addr >= 0x40000000 and path_addr < 0x40020000;
            const is_sdram = path_addr >= 0x10000000 and path_addr < 0x12000000;
            if (is_iram or is_sdram) {
                var path_buf: [128]u8 = undefined;
                var i: usize = 0;
                while (i < 127) : (i += 1) {
                    const c = self.bus.read8(path_addr + @as(u32, @intCast(i)));
                    if (c == 0) break;
                    path_buf[i] = c;
                }
                path_buf[i] = 0;
                std.debug.print("  PATH STRING: \"{s}\"\n", .{path_buf[0..i]});
            }
        }
        // Trace return from open_file
        if (pc == 0x4000461C) {
            std.debug.print("LOAD_FW_OPEN_FILE_RET: R0=0x{X:0>8} (fd or -1)\n", .{ self.cpu.getReg(0) });
        }
        // Trace the final call at 0x40004660 before return
        if (pc == 0x40004660) {
            std.debug.print("LOAD_FW_FINAL_CALL: R0=0x{X:0>8} R1=0x{X:0>8} R2=0x{X:0>8} R3=0x{X:0>8}\n", .{
                self.cpu.getReg(0), self.cpu.getReg(1), self.cpu.getReg(2), self.cpu.getReg(3)
            });
        }
        // Trace common return points in load_firmware
        if (pc >= 0x40004680 and pc <= 0x40004800) {
            // Look for BX LR or similar return patterns
            const instr = self.bus.read32(pc);
            // BX LR = 0xE12FFF1E, POP {PC} = 0xE8BD..80
            if (instr == 0xE12FFF1E or (instr & 0xFFFF8000) == 0xE8BD8000) {
                std.debug.print("LOAD_FIRMWARE_RETURN: cycle={} PC=0x{X:0>8} R0=0x{X:0>8} instr=0x{X:0>8}\n", .{
                    self.total_cycles, pc, self.cpu.getReg(0), instr
                });
            }
        }
        // Force button check to return 0 (no button) at 0x400009D4 (BX LR)
        // This makes the bootloader load apple_os.ipod (which we patch to rockbox.ipod)
        // Only patch when we're actually in the button check function (called from 0xA40)
        if (pc == 0x400009D4) {
            const lr = self.cpu.getReg(14);
            // Only patch when returning to the specific call site that checks for button
            if (lr >= 0x40000A40 and lr <= 0x40000A48) {
                self.cpu.setReg(0, 0); // Force R0 = 0 (no button pressed) -> loads apple_os.ipod
                std.debug.print("BUTTON_CHECK_FIX: Forcing R0=0 (no button) at cycle {}, LR=0x{X:0>8}\n", .{ self.total_cycles, lr });
            }
        }
        // Trace button check function call at 0xA3C-0xA40
        if (pc == 0x40000A3C) { // Just before BX R5
            std.debug.print("BUTTON_CHECK_CALL: cycle={} R5=0x{X:0>8} (button check func addr)\n", .{ self.total_cycles, self.cpu.getReg(5) });
        }
        if (pc == 0x40000A44) { // CMP R0, #0 after button check
            std.debug.print("BUTTON_CHECK: cycle={} R0=0x{X:0>8} (0=no button)\n", .{ self.total_cycles, self.cpu.getReg(0) });
        }
        // Trace branch target after delay loop (branch always goes to 0xA34)
        if (pc == 0x40000A34) {
            std.debug.print("OUTER_LOOP: cycle={} R0=0x{X:0>8} R4=0x{X:0>8} (CMP R4,R0)\n", .{
                self.total_cycles, self.cpu.getReg(0), self.cpu.getReg(4)
            });
        }
        // Trace branch target when R4 == R0 at 0xA34 (exit condition)
        if (pc == 0x40000A9C) {
            std.debug.print("OUTER_LOOP_EXIT: cycle={}\n", .{self.total_cycles});
        }
        if (pc == 0x400000A4 and self.total_cycles < 500_000) {
            std.debug.print("BOOT: Reached main() call at 0xA4 (cycle {})\n", .{self.total_cycles});
        }
        // Trace when execution enters SDRAM (0x10000000-0x12000000)
        if (pc >= 0x10000000 and pc < 0x12000000) {
            std.debug.print("SDRAM EXEC: cycle={} PC=0x{X:0>8} R0=0x{X:0>8} LR=0x{X:0>8}\n", .{
                self.total_cycles, pc, self.cpu.getReg(0), self.cpu.getReg(14),
            });
        }

        // Trace post-MMAP execution at low addresses (0x000001C4 onwards)
        // When MMAP is enabled, low addresses translate to SDRAM
        if (self.bus.mmap_enabled and pc < 0x01000000 and pc >= 0x000001C0) {
            // Only trace around key addresses to reduce noise
            if (pc >= 0x000002C0 and pc <= 0x000002F0) {
                std.debug.print("MMAP EXEC: cycle={} PC=0x{X:0>8} -> 0x{X:0>8} R2=0x{X:0>8} SP=0x{X:0>8}\n", .{
                    self.total_cycles, pc, pc + 0x10000000, self.cpu.getReg(2), self.cpu.getReg(13),
                });
            }
        }

        // Check for invalid PC values - but allow mapped ranges
        // Allow: 0x03E8xxxx-0x03EFxxxx (trampolines), 0x08xxxxxx (Rockbox code)
        if (pc >= 0x02000000 and pc < 0x10000000) {
            const in_trampoline = (pc >= 0x03E80000 and pc < 0x04000000);
            const in_rockbox_code = (pc >= 0x08000000 and pc < 0x0C000000);
            if (!in_trampoline and !in_rockbox_code) {
                std.debug.print("INVALID_PC: cycle={} PC=0x{X:0>8} LR=0x{X:0>8} - possible bad jump target\n", .{
                    self.total_cycles, pc, self.cpu.getReg(14),
                });
            }
        }

        // CRITICAL: Check for PC values that are clearly invalid (outside all memory regions)
        // Valid regions: 0x00-0x1C (vectors), IRAM (0x40000000), SDRAM (0x10000000-0x14000000),
        // MMAP regions (0x00-0x10000000 when MMAP enabled)
        // Values > 0x80000000 or == 0xE12FFF1C (looks like BX instruction) are definitely wrong
        if (pc >= 0x80000000 or (pc >= 0x14000000 and pc < 0x40000000)) {
            std.debug.print("\n!!! FATAL: PC=0x{X:0>8} is outside all valid memory regions !!!\n", .{pc});
            std.debug.print("    LR=0x{X:0>8}, R0=0x{X:0>8}, R1=0x{X:0>8}, R2=0x{X:0>8}\n", .{
                self.cpu.getReg(14), self.cpu.getReg(0), self.cpu.getReg(1), self.cpu.getReg(2),
            });
            std.debug.print("    R12=0x{X:0>8}, SP=0x{X:0>8}, cycle={}\n", .{
                self.cpu.getReg(12), self.cpu.getReg(13), self.total_cycles,
            });
            std.debug.print("    This likely indicates a corrupt return address or bad branch\n", .{});
            // Halt execution by setting a breakpoint or trap
            self.running = false;
            return 0;
        }
        // COP SYNC FIX: PP5021C has dual ARM cores (CPU + COP) that need to synchronize
        // at startup. Since we only emulate CPU, Rockbox's crt0 startup enters an infinite
        // loop waiting for COP. This fix detects the restart and skips past ALL sync code.
        // When PC enters Rockbox at 0x10000000 from bootloader (LR=0x400000AC), count restarts.
        if (pc == 0x10000000 and self.cpu.getReg(14) == 0x400000AC and self.total_cycles > 10_000_000) {
            self.rockbox_restart_count += 1;
            std.debug.print("COP_SYNC: Entry at 0x10000000, restart_count={} cycle={}\n", .{ self.rockbox_restart_count, self.total_cycles });
            // Don't skip on restart - let it run through normally but skip COP polling loops below
        }

        // Trace PROC_ID check at 0x10000110-0x10000118
        if (pc == 0x10000110) {
            std.debug.print("PROC_ID_CHECK: R0=0x{X:0>8} (0x55=CPU, 0xAA=COP)\n", .{self.cpu.getReg(0)});
        }
        if (pc == 0x10000118) {
            const path_name: []const u8 = if (self.cpu.getReg(0) == 0x55) "CPU" else "COP";
            std.debug.print("PROC_ID_BRANCH: Taking {s} path\n", .{path_name});
        }

        // Skip the IRAM remapping jump at 0x100001AC
        // The MOV PC, #0x40000000 jumps to remapping code which returns to bootloader
        // Since the IRAM code isn't loaded, we skip it and manually configure MMAP
        if (pc == 0x100001AC and self.rockbox_restart_count > 0) {
            std.debug.print("SKIP_IRAM_REMAP: Skipping MOV PC,#0x40000000, configuring MMAP manually\n", .{});

            // Manually configure MMAP to map 0x00000000+ to SDRAM 0x10000000+
            // This is what the IRAM remapping code would do:
            // - MMAP0_LOGICAL = 0x00003C00 (64MB mask) - required for .init at 0x03E8xxxx
            // - MMAP0_PHYSICAL = 0x10000F84 (base 0x10000000 + permissions: read/write/data/code)
            self.bus.mmap_logical[0] = 0x00003C00; // 64MB mask (0x03FFFFFF)
            self.bus.mmap_physical[0] = 0x10000F84; // SDRAM base + permissions
            self.bus.mmap_enabled = true;
            std.debug.print("MMAP: Manually configured - 0x00000000-0x03FFFFFF -> 0x10000000 (64MB SDRAM)\n", .{});

            self.cpu.setReg(15, 0x100001B0);
            return 1;
        }

        // Fix BX R1 at 0x100001BC - R1 contains post-remap address 0x000001C4
        // With MMAP enabled, addresses like 0x000001C4 auto-translate to 0x100001C4
        // Without MMAP, we need to manually fix the jump target
        if (pc == 0x100001BC) {
            const r1 = self.cpu.getReg(1);
            if (r1 == 0x000001C4) {
                if (self.bus.mmap_enabled) {
                    std.debug.print("FIX_BX_R1: MMAP enabled, 0x000001C4 will auto-translate\n", .{});
                } else {
                    std.debug.print("FIX_BX_R1: MMAP not enabled, fixing jump from 0x000001C4 to 0x100001C4\n", .{});
                    self.cpu.setReg(1, 0x100001C4);
                }
            }
        }

        // Skip second COP polling loop at 0x100001EC (after remapping)
        // Loop: LDR R3,[R4] / TST R3,#0x80000000 / BEQ (loop)
        if (pc == 0x100001EC) {
            std.debug.print("SKIP_COP_POLL_2: Skipping second COP polling loop\n", .{});
            self.cpu.setReg(15, 0x100001F8);
            return 1;
        }

        // Trace jump at 0x100002D4 - LDR PC, [PC, #204]
        // This should jump to main() but the address at 0x100003A8 is wrong (0x03E804DC)
        // Skip this complex crt0 and directly call a known safe continuation
        if (pc == 0x100002D4) {
            const jump_target = self.bus.read32(0x100003A8);
            std.debug.print("MAIN_JUMP: At 0x100002D4, target from mem = 0x{X:0>8}\n", .{jump_target});
            // The startup code is too complex with invalid addresses.
            // For now, let's just report the issue and continue to bootloader.
        }

        // COP polling loop at 0x10000148 - CPU waits for COP to sleep
        // The loop is: LDR R1,[R2] / TST R1,#0x80000000 / BEQ (loop)
        // With COP_CTL returning SLEEPING (bit 31=1), this loop exits naturally.
        // RE-ENABLED: Other loops at 0x200+ expect AWAKE, so we need to skip all.
        if (pc == 0x10000148) {
            // Note: 0x1004 is the offset from sys_ctrl base 0x60006000 for COP_CTL at 0x60007004
            const cop_status = self.sys_ctrl.read(0x1004);
            std.debug.print("COP_POLL_LOOP: Reading COP_STATUS=0x{X:0>8}, bit31={}\n", .{
                cop_status, (cop_status & 0x80000000) != 0,
            });
            // Skip the loop by jumping to the instruction after the BEQ at 0x10000150
            // The BEQ is at 0x10000150, so the exit is at 0x10000154
            std.debug.print("COP_POLL_LOOP: Skipping to 0x10000154\n", .{});
            self.cpu.setReg(15, 0x10000154);
            return 1;
        }
        // COP SYNC FIX #2: After the first sync skip, Rockbox has many COP polling loops
        // that read COP_CTL (0x60007004) in a tight loop waiting for COP to signal ready.
        // Detect the pattern and skip each loop.
        // When MMAP is enabled, virtual addresses 0x00000000-0x03FFFFFF are remapped to
        // physical SDRAM at 0x10000000-0x13FFFFFF. Translation is simple: phys = virt + 0x10000000
        var effective_pc: u32 = pc;
        if (self.bus.mmap_enabled) {
            // If PC is in the mapped virtual range (0-64MB), translate to physical SDRAM
            if (pc < 0x04000000) {
                effective_pc = pc + 0x10000000;
            }
        }

        // COP polling loops at 0x140-0x148 and 0x1EC-0x1F4 are handled by
        // COP_CTL read returning SLEEPING (bit 31 = 1) which breaks the loop naturally.
        // No explicit skip needed here anymore.

        // COP polling loops in Rockbox crt0 that read COP_CTL (0x60007004)
        // These loops wait for COP to signal ready, which never happens in single-core emulation
        // IMPORTANT: Only skip ACTUAL COP_CTL polling loops, not data copy/BSS loops!
        //
        // Actual COP polling loops (identified by TST instruction on COP_CTL read):
        // - 0x140-0x148: First COP sync (boot ROM wait for COP sleeping)
        // - 0x1EC-0x1F4: Second COP sync (kernel wait for COP ready)
        //
        // NOT COP loops (these are data copy/init loops - DO NOT SKIP):
        // - 0x188-0x194: Copy MMAP setup code to IRAM
        // - 0x204-0x210: Copy to IRAM (iram content)
        // - 0x220-0x22C: Copy to IRAM (more content)
        // - 0x23C-0x248: .init section copy (main() and other INIT_ATTR code!)
        // - 0x258-0x260, 0x270-0x278: BSS zeroing
        // - 0x288-0x290, 0x2C8-0x2D0: Stack filling
        //
        // We skip the first COP poll at 0x140-0x148 by returning SLEEPING from COP_CTL read
        // The second at 0x1EC-0x1F4 also uses COP_CTL read result

        // Trace CRT0 progress to verify init loops are running
        if (effective_pc >= 0x10000180 and effective_pc < 0x10000260 and self.total_cycles < 200000) {
            if (self.total_cycles % 1000 == 0) {
                std.debug.print("CRT0_LOOP: PC=0x{X:0>8} R2=0x{X:0>8} R3=0x{X:0>8} R4=0x{X:0>8} R5=0x{X:0>8}\n", .{
                    pc, self.cpu.getReg(2), self.cpu.getReg(3), self.cpu.getReg(4), self.cpu.getReg(5),
                });
            }
        }

        // KERNEL STARTUP FIX: Disabled for now - letting kernel run naturally to see progression
        // The Timer1/IRQ approach wasn't working because our minimal handler doesn't call scheduler
        // TODO: Re-enable this once we figure out how to properly invoke scheduler tick
        if (false and self.rockbox_restart_count >= 1 and self.bus.mmap_enabled and !self.timer1_enabled_by_emulator) {
            if (effective_pc == 0x10007694) {
                self.timer1_enabled_by_emulator = true;
                std.debug.print("KERNEL_FIX: DISABLED\n", .{});
            }
        }

        // IRAM LOOP DETECTION: Track if execution is stuck at 0x40008928
        // This address is in IRAM (bootloader area) and appears to be a wait loop
        if (pc == 0x40008928) {
            self.iram_loop_count += 1;
            if (self.iram_loop_count == 1 or self.iram_loop_count % 100000 == 0) {
                const instr = self.bus.read32(pc);
                const cpsr = self.cpu.regs.cpsr;
                std.debug.print("IRAM_LOOP[{}]: PC=0x{X:0>8} instr=0x{X:0>8} mode=0x{X:0>2} IRQ_dis={} FIQ_dis={}\n", .{
                    self.iram_loop_count,
                    pc,
                    instr,
                    cpsr.mode,
                    cpsr.irq_disable,
                    cpsr.fiq_disable,
                });
                std.debug.print("  R0=0x{X:0>8} R1=0x{X:0>8} R2=0x{X:0>8} R3=0x{X:0>8} LR=0x{X:0>8}\n", .{
                    self.cpu.getReg(0), self.cpu.getReg(1), self.cpu.getReg(2), self.cpu.getReg(3), self.cpu.getReg(14),
                });
            }
        }

        // KERNEL INIT DETECTION: Check if kernel init has completed
        // Milestones: IRQ vector installed + Timer1 enabled by firmware
        // When both are detected, mark kernel_init_complete for diagnostics.
        if (self.rockbox_restart_count >= 1 and self.bus.mmap_enabled) {
            // Check for IRQ vector installation
            const irq_installed = self.bus.isIrqVectorInstalled();

            // Check for Timer1 enable by firmware (not by us)
            const timer1_enabled = self.timer.timer1.isEnabled() and !self.timer1_enabled_by_emulator;
            if (timer1_enabled and !self.bus.timer1_enabled_by_firmware) {
                self.bus.markTimer1EnabledByFirmware();
            }

            // Mark kernel init complete when both milestones reached
            if (irq_installed and self.bus.timer1_enabled_by_firmware and !self.sys_ctrl.isKernelInitComplete()) {
                self.sys_ctrl.setKernelInitComplete();
                std.debug.print("KERNEL_INIT_COMPLETE: IRQ vector installed, Timer1 enabled by firmware\n", .{});
            }

            // SWITCH_THREAD SKIP at 0x84B5C (inner scheduler function that loops)
            // This function loops waiting for COP/thread sync
            // Skip immediately by returning success code
            if (effective_pc == 0x10084B5C or pc == 0x84B5C or pc == 0x00084B5C) {
                self.switch_thread_count += 1;
                if (self.switch_thread_count == 1 or self.switch_thread_count % 50000 == 0) {
                    std.debug.print("SWITCH_THREAD: iter={} PC=0x{X:0>8} R0=0x{X:0>8} LR=0x{X:0>8}\n", .{
                        self.switch_thread_count, pc, self.cpu.getReg(0), self.cpu.getReg(14),
                    });
                }
                // Skip after just 1000 iterations to let scheduler logic run but avoid blocking
                if (self.switch_thread_count > 1000) {
                    const lr = self.cpu.getReg(14);
                    self.sched_skip_count += 1;
                    self.total_sched_skips += 1; // Cumulative counter for LCD bypass
                    if (self.sched_skip_count <= 5 or self.sched_skip_count % 100 == 0) {
                        std.debug.print("SWITCH_THREAD_SKIP[{}]: returning to LR=0x{X:0>8} (total={})\n", .{
                            self.sched_skip_count, lr, self.total_sched_skips,
                        });
                    }
                    // Return success - allow caller to continue
                    self.cpu.setReg(0, 0);
                    self.cpu.setReg(15, lr);
                    self.switch_thread_count = 0;
                    return 1;
                }
            }

            // CALLER LOOP SKIP at 0x7C558 (caller of scheduler)
            // After multiple scheduler skips, the caller keeps calling it again.
            // Skip the caller loop by returning to ITS caller.
            if (effective_pc == 0x10007C558 or pc == 0x7C558 or effective_pc == 0x1007C558) {
                if (self.sched_skip_count > 3) {
                    const lr = self.cpu.getReg(14);
                    const sp = self.cpu.getReg(13);

                    // If LR == PC, we're in a self-loop. Pop return address from stack.
                    if (lr == pc or lr == effective_pc) {
                        // Look for saved LR on stack - typical ARM push is {r4-r11, lr}
                        // Stack grows down, so saved registers are at SP+offset
                        // Try reading at various offsets to find a valid return address
                        const saved_at_28 = self.bus.read32(sp + 28); // Offset for 7th pushed reg
                        const saved_at_32 = self.bus.read32(sp + 32); // Offset for 8th pushed reg
                        const saved_at_4 = self.bus.read32(sp + 4); // Just after SP

                        if (self.caller_loop_escape_failures < 5) {
                            std.debug.print("CALLER_LOOP_SELF: LR==PC, SP=0x{X:0>8}, stack[4]=0x{X:0>8}, stack[28]=0x{X:0>8}, stack[32]=0x{X:0>8}\n", .{
                                sp, saved_at_4, saved_at_28, saved_at_32,
                            });
                        }

                        // Try to find a plausible return address (should be in firmware range)
                        var return_addr: u32 = 0;
                        if (saved_at_28 >= 0x7000 and saved_at_28 < 0x100000 and saved_at_28 != pc) {
                            return_addr = saved_at_28;
                        } else if (saved_at_32 >= 0x7000 and saved_at_32 < 0x100000 and saved_at_32 != pc) {
                            return_addr = saved_at_32;
                        } else if (saved_at_4 >= 0x7000 and saved_at_4 < 0x100000 and saved_at_4 != pc) {
                            return_addr = saved_at_4;
                        }

                        if (return_addr != 0) {
                            std.debug.print("CALLER_LOOP_ESCAPE: Using stack return addr 0x{X:0>8}\n", .{return_addr});
                            self.cpu.setReg(0, 0);
                            self.cpu.setReg(13, sp + 36); // Pop 9 registers (36 bytes)
                            self.cpu.setReg(15, return_addr);

                            // Clear Timer1 interrupt to prevent immediate re-entry
                            self.int_ctrl.clearInterrupt(.timer1);

                            // Don't fully reset - allow faster escape on repeat
                            self.sched_skip_count = 2;
                            self.caller_loop_escape_failures = 0;
                            return 1;
                        }

                        // No valid return address found - increment failure counter
                        self.caller_loop_escape_failures += 1;

                        // FALLBACK ESCAPE: After multiple failures with zero stack,
                        // trigger LCD bypass directly since we can't reach idle loop
                        if (self.caller_loop_escape_failures >= 10 and !self.lcd_bypass_done) {
                            std.debug.print("\n*** LCD BYPASS FROM CALLER LOOP ***\n", .{});
                            std.debug.print("Stuck at 0x7C558 with zero stack after {} failures\n", .{self.caller_loop_escape_failures});
                            std.debug.print("Total scheduler skips: {}, LCD pixel writes: {}\n", .{
                                self.total_sched_skips, self.lcd_ctrl.debug_pixel_writes,
                            });

                            // Fill screen with red using LCD controller directly
                            const red = lcd.Color.fromRgb(255, 0, 0);
                            self.lcd_ctrl.clear(red);
                            self.lcd_ctrl.update();

                            std.debug.print("LCD clear+update called. Pixel writes: {}, Updates: {}\n", .{
                                self.lcd_ctrl.debug_pixel_writes, self.lcd_ctrl.debug_update_count,
                            });

                            self.lcd_bypass_done = true;
                        }

                        // After LCD bypass, try jumping to idle loop directly
                        if (self.caller_loop_escape_failures >= 15) {
                            std.debug.print("CALLER_LOOP_FORCE_IDLE: Jumping to idle loop at 0x7C7E0\n", .{});

                            // Clear IRQ mode - switch back to SVC mode
                            self.cpu.regs.switchMode(.supervisor);
                            self.cpu.regs.cpsr.irq_disable = false;

                            // Set up reasonable SP for supervisor mode
                            self.cpu.setReg(13, 0x08001000);

                            // Jump to idle loop
                            self.cpu.setReg(15, 0x7C7E0);

                            // Clear Timer1 interrupt
                            self.int_ctrl.clearInterrupt(.timer1);

                            self.caller_loop_escape_failures = 0;
                            self.sched_skip_count = 0;
                            return 1;
                        }
                    }

                    if (self.caller_loop_escape_failures < 5) {
                        std.debug.print("CALLER_LOOP_SKIP: sched_skip_count={}, PC=0x{X:0>8}, LR=0x{X:0>8}, SP=0x{X:0>8}\n", .{
                            self.sched_skip_count, pc, lr, sp,
                        });
                    }
                    self.cpu.setReg(0, 0);
                    self.cpu.setReg(15, lr);
                    // Don't fully reset
                    self.sched_skip_count = 2;
                    return 1;
                }
            }

            // IDLE LOOP SKIP at 0x7C7E0 (idle thread or main loop)
            // After scheduler skips, execution ends up here in a tight loop
            // This is likely the idle thread waiting for interrupts
            if (effective_pc == 0x10007C7E0 or pc == 0x7C7E0 or effective_pc == 0x1007C7E0) {
                self.idle_loop_count += 1;
                if (self.idle_loop_count == 1 or self.idle_loop_count % 100000 == 0) {
                    std.debug.print("IDLE_LOOP: iter={} PC=0x{X:0>8} R0=0x{X:0>8} LR=0x{X:0>8} IRQ_dis={}\n", .{
                        self.idle_loop_count,
                        pc,
                        self.cpu.getReg(0),
                        self.cpu.getReg(14),
                        self.cpu.regs.cpsr.irq_disable,
                    });
                }
                // After 50000 iterations, try enabling IRQ and setting pending
                if (self.idle_loop_count > 50000) {
                    // Debug: show bypass check status
                    if (self.idle_loop_count == 50001 and !self.lcd_bypass_done) {
                        std.debug.print("BYPASS_CHECK: done={} total_skips={} pixel_writes={}\n", .{
                            self.lcd_bypass_done, self.total_sched_skips, self.lcd_ctrl.debug_pixel_writes,
                        });
                    }
                    // After many scheduler skips with no progress, try direct LCD test
                    if (!self.lcd_bypass_done and self.total_sched_skips > 50 and self.lcd_ctrl.debug_pixel_writes == 0) {
                        std.debug.print("\n*** LCD BYPASS TEST ***\n", .{});
                        std.debug.print("Scheduler stuck after {} total skips with 0 LCD writes\n", .{self.total_sched_skips});
                        std.debug.print("Attempting direct LCD fill...\n", .{});

                        // Fill screen with red using LCD controller directly
                        const red = lcd.Color.fromRgb(255, 0, 0);
                        self.lcd_ctrl.clear(red);
                        self.lcd_ctrl.update();

                        std.debug.print("LCD clear+update called. Pixel writes now: {}\n", .{self.lcd_ctrl.debug_pixel_writes});
                        std.debug.print("LCD updates now: {}\n", .{self.lcd_ctrl.debug_update_count});

                        // Only do this once
                        self.lcd_bypass_done = true;
                    }

                    if (self.idle_loop_count == 50001) {
                        std.debug.print("IDLE_LOOP_SKIP: after {} iterations, enabling IRQ and triggering timer (total_sched_skips={})\n", .{ self.idle_loop_count, self.total_sched_skips });
                    }
                    self.cpu.enableIrq();
                    // Fire Timer1 to trigger scheduler
                    self.int_ctrl.assertInterrupt(.timer1);
                    self.idle_loop_count = 0;
                }
            }

            // IRAM LOOP SKIP at 0x400071DC-0x400071EC
            // This is an RNG/entropy loop that spins forever without hardware entropy
            // Skip it after 100000 iterations to allow kernel init to continue
            if (pc >= 0x400071D0 and pc <= 0x40007200) {
                self.wake_loop_iterations += 1;
                if (self.wake_loop_iterations == 1 or self.wake_loop_iterations == 100) {
                    std.debug.print("IRAM_LOOP: iter={} PC=0x{X:0>8} LR=0x{X:0>8}\n", .{
                        self.wake_loop_iterations,
                        pc,
                        self.cpu.getReg(14),
                    });
                }
                // Skip after 100000 iterations
                if (self.wake_loop_iterations > 100000) {
                    const lr = self.cpu.getReg(14);
                    std.debug.print("IRAM_LOOP_SKIP: Skipping after {} iterations, returning to 0x{X:0>8}\n", .{
                        self.wake_loop_iterations,
                        lr,
                    });
                    // Set R0 to a "success" value and return to caller
                    self.cpu.setReg(0, 0);
                    self.cpu.setReg(15, lr);
                    self.wake_loop_iterations = 0;
                    return 1;
                }
            }

            // WAKE_CORE HANDLING at 0x769C-0x76B8 (function body only, not idle thread)
            // wake_core polls COP_CTL and MBX_MSG_STAT in a loop.
            // The idle thread at 0x76BC+ calls wake_core, so we only skip the inner function.
            const in_wake_core = (pc >= 0x769C and pc <= 0x76B8) or
                (effective_pc >= 0x1000769C and effective_pc <= 0x100076B8);
            if (in_wake_core) {
                self.cop_wake_skip_count += 1;
                const lr = self.cpu.getReg(14);

                // Debug trace first 5 entries
                if (self.cop_wake_skip_count <= 5) {
                    std.debug.print("WAKE_CORE: iter={} PC=0x{X:0>8} R0=0x{X:0>8} LR=0x{X:0>8}\n", .{
                        self.cop_wake_skip_count,
                        pc,
                        self.cpu.getReg(0),
                        lr,
                    });
                }

                // COP sync loop skip: The loop at 0x76A4-0x76B0 is an infinite loop waiting for
                // IRQ/COP response. Without IRQ, we need to simulate a function return.
                // The function at 0x7694 pushed {R4, LR} - we need to pop them to return properly.
                // Re-enabled: need to skip the write-only infinite loop
                if (self.cop_wake_skip_count > 10000) {
                    // Read the saved return address from stack
                    // PUSH {R4, LR} = SP -= 8, then store R4 at SP, LR at SP+4
                    const sp = self.cpu.getReg(13);
                    const saved_lr = self.bus.read32(sp + 4);
                    const saved_r4 = self.bus.read32(sp);

                    std.debug.print("WAKE_CORE_SKIP: iter={} SP=0x{X:0>8} saved_R4=0x{X:0>8} saved_LR=0x{X:0>8}\n", .{
                        self.cop_wake_skip_count,
                        sp,
                        saved_r4,
                        saved_lr,
                    });

                    // Check if saved_LR is valid (not 0 and not inside wake_core)
                    const is_valid_lr = saved_lr != 0 and
                        (saved_lr < 0x7694 or saved_lr > 0x76B8) and
                        (saved_lr < 0x10007694 or saved_lr > 0x100076B8);

                    if (is_valid_lr) {
                        // Simulate POP {R4, PC} - return to caller
                        self.cpu.setReg(4, saved_r4);
                        self.cpu.setReg(15, saved_lr);
                        self.cpu.setReg(13, sp + 8);
                        std.debug.print("WAKE_CORE_SKIP: Returning to valid LR=0x{X:0>8}\n", .{saved_lr});
                    } else {
                        // saved_LR=0 or inside wake_core - this is a task entry point
                        // Skip to idle_thread at 0x76BC instead of returning
                        // Keep stack as-is since we're not returning
                        self.cpu.setReg(15, 0x76BC);
                        std.debug.print("WAKE_CORE_SKIP: Invalid LR, jumping to idle_thread at 0x76BC\n", .{});
                    }
                    self.cpu.enableIrq(); // Enable IRQs for scheduler
                    self.cop_wake_skip_count = 0;
                    return 1;
                }
            }

            // Track idle loop iterations (for debugging)
            const in_idle_loop = (pc >= 0x76C4 and pc <= 0x76DC) or
                (effective_pc >= 0x100076C4 and effective_pc <= 0x100076DC);
            if (in_idle_loop) {
                self.wake_loop_iterations += 1;
                if (self.wake_loop_iterations == 1 or self.wake_loop_iterations % 100000 == 0) {
                    std.debug.print("IDLE_LOOP: iter={} PC=0x{X:0>8} Timer1={} IRQ_vector={}\n", .{
                        self.wake_loop_iterations,
                        pc,
                        self.timer.timer1.isEnabled(),
                        self.bus.isIrqVectorInstalled(),
                    });
                }
            } else {
                // Include IRAM loop area in the "don't reset" check
                const in_wake_area = (pc >= 0x769C and pc <= 0x76DC) or
                    (effective_pc >= 0x1000769C and effective_pc <= 0x100076DC) or
                    (pc >= 0x400071D0 and pc <= 0x40007200);
                if (!in_wake_area and self.wake_loop_iterations > 0) {
                    self.wake_loop_iterations = 0;
                }
            }
        }

        // Trace when PC is in the checksum loop
        if (pc == 0x4000061C) {
            if (self.total_cycles % 10000000 == 0) { // Sample every 10M cycles
                const r2 = self.cpu.getReg(2); // counter
                const r7 = self.cpu.getReg(7); // limit
                const r4 = self.cpu.getReg(4); // checksum accumulator
                std.debug.print("CHECKSUM: c={} R2(cnt)=0x{X:0>8} R7(limit)=0x{X:0>8} R4(sum)=0x{X:0>8} progress={d}%\n", .{
                    self.total_cycles, r2, r7, r4,
                    if (r7 > 0) (r2 * 100) / r7 else 0,
                });
            }
        }

        // TRACE the stack fill loop at 0x2C8-0x2D0 to debug why it's stuck
        if ((effective_pc == 0x100002C8 or effective_pc == 0x100002D0 or pc == 0x2C8 or pc == 0x2D0) and self.total_cycles > 1000000) {
            const sp = self.cpu.getReg(13);
            const r2 = self.cpu.getReg(2);
            const r4 = self.cpu.getReg(4);
            if (self.total_cycles % 100000 < 10) { // Print first 10 of every 100k cycles
                std.debug.print("STACK_FILL_LOOP: PC=0x{X:0>8} SP=0x{X:0>8} R2=0x{X:0>8} R4=0x{X:0>8}\n", .{
                    pc, sp, r2, r4,
                });
            }
        }

        // TRACE the jump-to-main instruction at 0x2D4
        if (effective_pc == 0x100002D4 or pc == 0x2D4) {
            // This instruction is: ldr pc, [pc, #204] which loads from 0x3A8
            const load_addr = 0x100003A8; // PC+8+204 = 0x2DC+0xCC = 0x3A8, with MMAP prefix
            const main_addr = self.bus.read32(load_addr);
            std.debug.print("JUMP_TO_MAIN: PC=0x{X:0>8} loading from 0x{X:0>8} = 0x{X:0>8}\n", .{
                pc, load_addr, main_addr,
            });
        }

        // ROCKBOX BINARY FIX: The rockbox_raw.bin has a 3KB zero gap (0x420-0x101F) where
        // main() at 0x4DC should be. The crt0 startup jumps to 0x03E804DC (SDRAM 0x100004DC)
        // but that address contains zeros. Execution would slide through zeros until hitting
        // code at 0x10001020, but with garbage register values.
        //
        // NOTE: The "zero gap" issue was caused by incorrect MMAP translation.
        // With correct MMAP: virtual 0x03E804DC -> physical 0x13E804DC (in SDRAM at ~65MB offset)
        // The .init section is copied from _initcopy (~0xAB3CC) to _initstart (0x03E80000 virtual)
        // So main() should be at physical 0x13E804DC after the copy.
        // This workaround should no longer be needed, but keep it for debugging.
        if (self.rockbox_restart_count >= 1 and effective_pc >= 0x10000420 and effective_pc < 0x10001020) {
            const instr = self.bus.read32(effective_pc);
            if (instr == 0x00000000) {
                std.debug.print("ROCKBOX_ZERO_GAP: PC=0x{X:0>8} (effective=0x{X:0>8}) is in zero region\n", .{ pc, effective_pc });
                // Don't skip - let it continue to debug why we're here
            }
        }

        // Trace when entering the .init copy loop
        if (effective_pc == 0x1000023C and !self.init_copy_started) {
            self.init_copy_started = true;
            const main_phys: u32 = 0x13E804DC;
            const main_val = self.bus.read32(main_phys);
            const src_val = self.bus.read32(0x100AB8B4); // main() in source
            std.debug.print("INIT_COPY_START: main() dst=0x{X:0>8} (val=0x{X:0>8}), src=0x{X:0>8} (val=0x{X:0>8})\n", .{
                main_phys, main_val, @as(u32, 0x100AB8B4), src_val,
            });
        }

        // Trace .init section copy loop (crt0 lines 240-248)
        // Source: _initcopy (literal at ~0x378) ~= 0x000AB3CC -> physical 0x100AB3CC
        // Dest: _initstart (literal at ~0x370) ~= 0x03E80000 -> physical 0x13E80000
        // The loop is at offset ~0x230-0x240 in crt0
        if (effective_pc >= 0x10000230 and effective_pc <= 0x10000250) {
            const r2 = self.cpu.getReg(2); // _initstart (destination)
            const r3 = self.cpu.getReg(3); // _initend
            const r4 = self.cpu.getReg(4); // _initcopy (source)
            if (self.total_cycles % 100000 == 0) {
                std.debug.print("INIT_COPY_LOOP: PC=0x{X:0>8} R2(dst)=0x{X:0>8} R3(end)=0x{X:0>8} R4(src)=0x{X:0>8}\n", .{
                    effective_pc, r2, r3, r4,
                });
            }
            // Check if copy is done (R2 >= R3)
            if (r2 >= r3 and !self.main_entered) {
                const main_phys: u32 = 0x13E804DC;
                const main_val = self.bus.read32(main_phys);
                std.debug.print("INIT_COPY_DONE: R2=0x{X:0>8} >= R3=0x{X:0>8}, main() at 0x{X:0>8} = 0x{X:0>8}\n", .{
                    r2, r3, main_phys, main_val,
                });
            }
        }

        // KERNEL INIT PATH TRACING: Track if execution reaches key functions
        // These addresses are in the kernel init call chain:
        // - 0x7C144: tick_start() - enables Timer1
        // - 0x6976C, 0x697A4: callers of tick_start()
        // - 0x69734: kernel_init caller function entry
        // - 0x66DF8: higher level caller
        const kernel_init_addrs = [_]u32{ 0x7C144, 0x6976C, 0x697A4, 0x69734, 0x66DF8 };
        const kernel_init_names = [_][]const u8{ "tick_start", "tick_start_caller1", "tick_start_caller2", "kernel_init_fn", "higher_caller" };
        for (kernel_init_addrs, 0..) |addr, i| {
            if (effective_pc == 0x10000000 + addr or pc == addr) {
                std.debug.print("KERNEL_PATH: Reached {s}() at 0x{X:0>8} (PC=0x{X:0>8}) LR=0x{X:0>8}\n", .{
                    kernel_init_names[i], addr, pc, self.cpu.getReg(14),
                });
            }
        }

        // Also trace main() entry - loaded from 0x3A8 which contains 0x03E804DC
        // With correct MMAP: virtual 0x03E804DC -> physical 0x13E804DC
        // main() is in .init section which gets copied from _initcopy (~0xAB3CC) to ENDAUDIOADDR (0x03E80000)
        if (effective_pc == 0x13E804DC or pc == 0x03E804DC) {
            const instr = self.bus.read32(effective_pc);
            std.debug.print("KERNEL_PATH: Reached main() entry at PC=0x{X:0>8} (effective=0x{X:0>8}) instr=0x{X:0>8}\n", .{ pc, effective_pc, instr });
        }

        // Trace first 100 instructions after main() entry
        if (self.main_entered and self.main_trace_count < 100) {
            const instr = self.bus.read32(effective_pc);
            std.debug.print("MAIN_TRACE[{d}]: PC=0x{X:0>8} (eff=0x{X:0>8}) instr=0x{X:0>8} LR=0x{X:0>8}\n", .{
                self.main_trace_count, pc, effective_pc, instr, self.cpu.getReg(14),
            });
            self.main_trace_count += 1;
        }
        if (effective_pc == 0x13E804DC or pc == 0x03E804DC) {
            self.main_entered = true;
            self.main_trace_count = 0;
        }

        // TASK SEARCH LOOP at 0x1040: Trace to understand what's happening
        // This is where execution is stuck - searching task list
        if (effective_pc == 0x10001040 and self.total_cycles % 500000 == 0) {
            const r0 = self.cpu.getReg(0);
            const r1 = self.cpu.getReg(1);
            const r2 = self.cpu.getReg(2);
            const r3 = self.cpu.getReg(3);
            const r6 = self.cpu.getReg(6);
            const lr = self.cpu.getReg(14);
            std.debug.print("TASK_SEARCH: R0=0x{X:0>8} R1=0x{X:0>8} R2=0x{X:0>8} R3=0x{X:0>8} R6=0x{X:0>8} LR=0x{X:0>8}\n", .{
                r0, r1, r2, r3, r6, lr,
            });
        }

        // Trace task search function entry at 0x1020
        if (effective_pc == 0x10001020) {
            const r0 = self.cpu.getReg(0);
            const r1 = self.cpu.getReg(1);
            const r2 = self.cpu.getReg(2);
            const lr = self.cpu.getReg(14);
            std.debug.print("TASK_SEARCH_ENTRY: R0=0x{X:0>8} R1=0x{X:0>8} R2=0x{X:0>8} LR=0x{X:0>8}\n", .{
                r0, r1, r2, lr,
            });
            // Read R1[16] to see what task array pointer is being used
            const r1_val = r1;
            if (r1_val < 0x40010000) { // Only read if it's a valid IRAM/ROM address
                const task_array_ptr = self.bus.read32(r1_val + 0x10);
                const index = self.bus.read32(r2);
                std.debug.print("TASK_SEARCH_ENTRY: R1[16]=0x{X:0>8} *R2=0x{X:0>8}\n", .{
                    task_array_ptr, index,
                });
            }
        }

        // Trace the caller setup at 0x1250 (mov r0, sl before call)
        if (effective_pc == 0x10001250) {
            const r4 = self.cpu.getReg(4);
            const sl = self.cpu.getReg(10);
            const lr = self.cpu.getReg(14);
            std.debug.print("TASK_CALL_SETUP: R4=0x{X:0>8} SL=0x{X:0>8} LR=0x{X:0>8}\n", .{
                r4, sl, lr,
            });
        }

        // DELAY ACCELERATION: When in delay loop at 0x40000B1C, skip ahead
        // The delay loop structure is:
        //   0x40000B18: MOV R1, R6           ; setup (once before loop)
        //   0x40000B1C: LDR R3, [R1, #0x10]  ; R3 = timer
        //   0x40000B20: RSB R3, R2, R3       ; R3 = timer - target
        //   0x40000B24: CMP R3, #0
        //   0x40000B28: BLT 0x40000B1C       ; loop back if R3 < 0
        // We detect entry at 0x40000B1C, read target from R2, and advance timer
        if (pc == 0x40000B1C) {
            const target = self.cpu.getReg(2);
            const current = self.timer.usec_timer;
            self.timer_loop_count += 1;
            // Debug: Print state every 1M loops
            if (self.timer_loop_count % 1000000 == 0) {
                std.debug.print("DELAY_LOOP: count={} target=0x{X:0>8} current=0x{X:0>8} R1=0x{X:0>8}\n", .{
                    self.timer_loop_count, target, current, self.cpu.getReg(1),
                });
            }
            // If timer hasn't reached target, advance it
            // Note: Handle wrap-around correctly - check if delta is small (< 0x80000000)
            const delta = target -% current; // wrapping subtraction
            if (delta > 0 and delta < 0x80000000) {
                const needed = delta + 1; // +1 to ensure we pass target
                self.timer.usec_timer = target +% 1;
                // Also advance total_cycles to account for the time
                const skip_cycles = needed * 80; // 80 cycles per microsecond
                self.total_cycles += skip_cycles;
                std.debug.print("DELAY_SKIP: target=0x{X:0>8} skipped {} us ({} cycles) LR=0x{X:0>8}\n", .{ target, needed, skip_cycles, self.cpu.getReg(14) });
            } else if (self.timer_loop_count < 10) {
                // Debug: Print first few no-skip cases
                std.debug.print("DELAY_NO_SKIP: count={} target=0x{X:0>8} current=0x{X:0>8} delta=0x{X:0>8}\n", .{
                    self.timer_loop_count, target, current, delta,
                });
            }
        }

        // Update CPU IRQ/FIQ lines from interrupt controller
        self.cpu.setIrqLine(self.int_ctrl.hasPendingIrq());
        self.cpu.setFiqLine(self.int_ctrl.hasPendingFiq());

        // Execute CPU instruction
        const cycles = self.cpu.step(&cpu_bus);
        self.total_cycles += cycles;

        // Debug: Check if boot ROM address 0 was read - print CPU state
        if (self.bus.debug_boot_rom_addr0_read) {
            self.bus.debug_boot_rom_addr0_read = false;
            const new_pc = self.cpu.getPc();
            const prev_pc = if (new_pc >= 4) new_pc - 4 else 0; // Approximation of instruction that did the read
            const r0 = self.cpu.getReg(0);
            const r1 = self.cpu.getReg(1);
            const r2 = self.cpu.getReg(2);
            const r3 = self.cpu.getReg(3);
            const lr = self.cpu.getReg(14);
            std.debug.print("BOOT_ROM_READ_0: cycle={} prev_PC=0x{X:0>8} R0=0x{X:0>8} R1=0x{X:0>8} R2=0x{X:0>8} R3=0x{X:0>8} LR=0x{X:0>8}\n", .{
                self.total_cycles, prev_pc, r0, r1, r2, r3, lr,
            });
        }

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
        // Approach 3: Trace SDRAM data reads to find task state array
        // Approach 4: Direct TCB modification at 0x108701CC
        //
        // Enable tracing early (2000 cycles) to catch scheduler loop from start
        // Scheduler enters wait loop at ~3000 cycles
        if (!self.rtos_kickstart_fired and self.total_cycles >= 2_000) {
            self.rtos_kickstart_fired = true;
            // Enable SDRAM data read tracing to find task state array
            self.bus.enableSdramDataReadTracing();
            // Enable kickstart mode - hw_accel reads will return modified values
            self.bus.enableKickstart();
            // Enable I2C tracing
            self.i2c_ctrl.enableTracing();
            // Set button event immediately to wake scheduler when it starts polling
            self.bus.setButtonEvent();
            std.debug.print("RTOS KICKSTART: Enabled at cycle {} (tracing + kickstart + button event)\n", .{self.total_cycles});
        }

        // Scheduler Kickstart: Clear the scheduler skip flag at 0x1081D858
        // The scheduler at 0x102778C0 checks bit 0 of [0x1081D858].
        // If set, it skips task selection and returns immediately.
        // The firmware writes 1 here during init, causing the scheduler to loop.
        // Clear this bit to allow task selection to proceed.
        if (self.total_cycles >= 3_000 and self.total_cycles < 100_000) {
            self.bus.schedulerKickstart();
        }

        // TCB Kickstart: Continuously modify task state while scheduler is active
        // The scheduler at 0x400095BC reads task states from memory
        // Try modifying task state every 1M cycles to wake up tasks
        if (self.total_cycles >= 50_000_000 and self.total_cycles % 1_000_000 == 0) {
            self.bus.tcbKickstart();
        }

        // Button Press Injection for headless mode:
        // The Rockbox bootloader shows a menu and waits for button input.
        // NOTE: The bootloader doesn't have proper IRQ handlers - the IRAM vectors
        // contain boot init code that would wipe memory if triggered.
        // The bootloader might use polling instead, so we just set data_available.
        //
        // For proper interrupt-based input, we'd need the bootloader to set up
        // its own exception vectors, which it may not do.
        if (self.total_cycles >= 100_000_000 and self.total_cycles < 105_000_000) {
            if (!self.button_injected) {
                self.button_injected = true;
                // Dump IRAM exception vectors to understand what handlers are set up
                std.debug.print("\n=== IRAM Exception Vectors at {} cycles ===\n", .{self.total_cycles});
                const vector_offsets = [_]u32{ 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C };
                const vector_names = [_][]const u8{ "Reset", "Undef", "SWI", "PrefetchAbort", "DataAbort", "Reserved", "IRQ", "FIQ" };
                for (vector_offsets, 0..) |offset, i| {
                    const addr = 0x40000000 + offset;
                    const instr = self.bus.read32(addr);
                    std.debug.print("  0x{X:0>8} ({s:15}): 0x{X:0>8}\n", .{ addr, vector_names[i], instr });
                }
                // Also check int controller state
                std.debug.print("=== Interrupt Controller State ===\n", .{});
                std.debug.print("  CPU enable mask: 0x{X:0>8}\n", .{self.int_ctrl.getEnable()});
                std.debug.print("  Raw status:      0x{X:0>8}\n", .{self.int_ctrl.raw_status});
                std.debug.print("  Forced status:   0x{X:0>8}\n", .{self.int_ctrl.forced_status});
                std.debug.print("=======================================\n\n", .{});

                // Dump scheduler loop code
                std.debug.print("=== Scheduler Loop Code (0x400095B0-0x400095D0) ===\n", .{});
                var addr: u32 = 0x400095B0;
                while (addr <= 0x400095D0) : (addr += 4) {
                    const instr = self.bus.read32(addr);
                    std.debug.print("  0x{X:0>8}: 0x{X:0>8}\n", .{ addr, instr });
                }
                std.debug.print("=======================================\n\n", .{});

                // Also dump the LCD-related loop at 0x400092B0
                std.debug.print("=== New Loop Code (0x400092A0-0x400092D0) ===\n", .{});
                addr = 0x400092A0;
                while (addr <= 0x400092D0) : (addr += 4) {
                    const instr = self.bus.read32(addr);
                    std.debug.print("  0x{X:0>8}: 0x{X:0>8}\n", .{ addr, instr });
                }
                std.debug.print("=======================================\n\n", .{});

                // Just set the scheduler wake event without pressing any button
                // This should make the bootloader proceed with auto-boot
                // (loading Rockbox if present, or Apple firmware otherwise)
                self.bus.setButtonEvent();
                std.debug.print("SCHEDULER WAKE: Set at cycle {} (no button pressed - auto-boot mode)\n", .{self.total_cycles});
            }
        } else if (self.total_cycles >= 105_000_000 and self.button_injected and !self.button_released) {
            self.button_released = true;
            self.wheel.releaseButton(.select);
            std.debug.print("BUTTON INJECT: Released SELECT at cycle {}\n", .{self.total_cycles});
        }

        // Timer kickstart DISABLED - IRQ handler doesn't return properly
        // // Enable timer at ~90M cycles for a single interrupt, then disable
        // if (self.total_cycles >= 90_000_000 and self.total_cycles < 90_000_100 and !self.timer.timer1.isEnabled()) {
        //     const timer_config: u32 = (1 << 31) | 1_000;
        //     self.timer.timer1.setConfig(timer_config);
        //     self.int_ctrl.forceEnableCpuInterrupt(.timer1);
        // }

        // Debug: Log PC, timer, and IRQ state periodically
        if (self.total_cycles >= 80_000_000 and self.total_cycles % 5_000_000 == 0 and self.total_cycles < 150_000_000) {
            std.debug.print("DEBUG @ {}: PC=0x{X:0>8}, Mode={s}, IRQ_disabled={}, Timer1_enabled={}, IRQ_pending={}, R0=0x{X:0>8}, R2=0x{X:0>8}\n", .{
                self.total_cycles,
                self.cpu.regs.r[15],
                @tagName(self.cpu.regs.cpsr.getMode() orelse .user),
                self.cpu.regs.cpsr.irq_disable,
                self.timer.timer1.isEnabled(),
                self.int_ctrl.hasPendingIrq(),
                self.cpu.regs.r[0],
                self.cpu.regs.r[2],
            });
        }

        // NOTE: Earlier attempts at IRQ kickstart crashed because:
        // 1. Firmware enters scheduler wait loop at ~3000 cycles
        // 2. IRQ dispatch tables are set up by tasks that never run
        // 3. Firing IRQ causes crash to 0xE12FFF1C (uninitialized handler)
        //
        // Now trying later (10000 cycles) after scheduler has run

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
