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
            if (pc >= 0x000002D0 and pc <= 0x000002F0) {
                std.debug.print("MMAP EXEC: cycle={} PC=0x{X:0>8} -> 0x{X:0>8} R0=0x{X:0>8} LR=0x{X:0>8}\n", .{
                    self.total_cycles, pc, pc + 0x10000000, self.cpu.getReg(0), self.cpu.getReg(14),
                });
            }
        }

        // Check for invalid PC values (0x03E804DC is a known bad address from constant pool)
        if (pc == 0x03E804DC or (pc >= 0x02000000 and pc < 0x10000000)) {
            std.debug.print("INVALID_PC: cycle={} PC=0x{X:0>8} LR=0x{X:0>8} - possible bad jump target\n", .{
                self.total_cycles, pc, self.cpu.getReg(14),
            });
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
            // - MMAP0_LOGICAL = 0x00003E00 (32MB mask) or 0x00003C00 (64MB)
            // - MMAP0_PHYSICAL = 0x00000F84 (permissions: read/write/data/code)
            self.bus.mmap_logical[0] = 0x00003E00;
            self.bus.mmap_physical[0] = 0x00000F84;
            self.bus.mmap_enabled = true;
            std.debug.print("MMAP: Manually configured - 0x00000000-0x00FFFFFF -> 0x10000000 (SDRAM)\n", .{});

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
        // We need bit 31 set in COP_STATUS for the loop to exit
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
        // When MMAP is enabled, PC can be either 0x10000xxx (direct) or 0x00000xxx (remapped)
        const effective_pc = if (self.bus.mmap_enabled and pc < 0x01000000) pc + 0x10000000 else pc;
        if (self.rockbox_restart_count >= 1 and effective_pc >= 0x10000200 and effective_pc < 0x10000400) {
            // Detected loop start addresses (found empirically):
            // 0x10000204, 0x1000023C, 0x10000258, 0x10000270, 0x10000288, 0x100002C8
            // 0x10000320 (additional loop found after 0x10000300)
            const loop_starts = [_]u32{ 0x10000204, 0x1000023C, 0x10000258, 0x10000270, 0x10000288, 0x100002C8, 0x100002DC, 0x10000320 };
            // Note: 0x100002C8 loop exits to 0x100002DC, and 0x100002DC is ANOTHER loop that exits to 0x100002E8
            const loop_exits = [_]u32{ 0x10000214, 0x1000024C, 0x10000264, 0x1000027C, 0x10000294, 0x100002DC, 0x100002E8, 0x1000032C };
            for (loop_starts, 0..) |start, i| {
                if (effective_pc == start) {
                    // Exit to remapped address if MMAP is enabled, otherwise to direct address
                    const exit_addr = if (self.bus.mmap_enabled and pc < 0x01000000) loop_exits[i] - 0x10000000 else loop_exits[i];
                    std.debug.print("COP_POLL_SKIP: PC=0x{X:0>8} -> exit 0x{X:0>8}\n", .{ pc, exit_addr });
                    self.cpu.setReg(15, exit_addr);
                    return 1;
                }
            }
        }

        // COP WAKE LOOP SKIP: DISABLED FOR DEBUGGING
        // The kernel tries to wake the COP in a tight loop at 0x769C-0x76B0.
        // This loop writes 0x80000000 to COP_CTL (0x60007004) repeatedly.
        // Without a real COP, this loops forever. Skip to the function return (BX LR at 0x76B8).
        // Addresses are in remapped space (MMAP enabled), physical = 0x1000xxxx.
        // if (self.rockbox_restart_count >= 1 and self.bus.mmap_enabled) {
        //     const cop_wake_loop_start: u32 = 0x769C; // BL in the loop
        //     const cop_wake_loop_body: u32 = 0x76A8; // STR in the loop
        //     const cop_wake_loop_exit: u32 = 0x76B8; // BX LR after the loop
        //     if (effective_pc >= 0x10007690 and effective_pc <= 0x100076B8) {
        //         // Detect the loop (PC in the range 0x769C-0x76B0)
        //         if (pc == cop_wake_loop_start or pc == cop_wake_loop_body or
        //             pc == 0x769C or pc == 0x76A0 or pc == 0x76A4 or
        //             pc == 0x76A8 or pc == 0x76AC or pc == 0x76B0)
        //         {
        //             std.debug.print("COP_WAKE_SKIP: PC=0x{X:0>8} -> exit 0x{X:0>8}\n", .{ pc, cop_wake_loop_exit });
        //             self.cpu.setReg(15, cop_wake_loop_exit);
        //             return 1;
        //         }
        //     }
        // }

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
