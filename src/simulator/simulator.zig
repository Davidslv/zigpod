//! PP5021C Simulator
//!
//! This module provides a host-based simulation of the PP5021C SoC for testing
//! ZigPod OS without actual hardware. It simulates:
//! - Memory-mapped I/O registers
//! - Timer and timing
//! - LCD display (text-based visualization)
//! - Click wheel input (keyboard-based)
//! - Audio output (file or system audio)

const std = @import("std");
const hal = @import("../hal/hal.zig");

// Export terminal UI module
pub const terminal_ui = @import("terminal_ui.zig");

// Export CPU emulation modules
pub const cpu = struct {
    pub const registers = @import("cpu/registers.zig");
    pub const decoder = @import("cpu/decoder.zig");
    pub const executor = @import("cpu/executor.zig");
    pub const exceptions = @import("cpu/exceptions.zig");
    pub const arm7tdmi = @import("cpu/arm7tdmi.zig");
};

// Export memory bus
pub const memory_bus = @import("memory_bus.zig");

// Export storage simulation modules
pub const storage = struct {
    pub const disk_image = @import("storage/disk_image.zig");
    pub const identify = @import("storage/identify.zig");
    pub const ata_controller = @import("storage/ata_controller.zig");
    pub const mock_fat32 = @import("storage/mock_fat32.zig");
};

// Export interrupt simulation modules
pub const interrupts = struct {
    pub const interrupt_controller = @import("interrupts/interrupt_controller.zig");
    pub const timer_sim = @import("interrupts/timer_sim.zig");
};

// Export I2C device simulation modules
pub const i2c = struct {
    pub const wm8758_sim = @import("i2c/wm8758_sim.zig");
    pub const pcf50605_sim = @import("i2c/pcf50605_sim.zig");
};

// Export audio simulation modules
pub const audio = struct {
    pub const wav_writer = @import("audio/wav_writer.zig");
};

// Export profiling modules
pub const profiler_mod = struct {
    pub const profiler = @import("profiler/profiler.zig");
};

// Note: GUI modules (gui/gui.zig, gui/sdl_backend.zig) are imported directly
// by the simulator executable (main.zig) to avoid module conflicts.
// They are not re-exported here.

// ============================================================
// Simulator Configuration
// ============================================================

pub const SimulatorConfig = struct {
    /// Enable LCD visualization in terminal
    lcd_visualization: bool = true,
    /// Enable audio output to file
    audio_to_file: bool = true,
    /// Audio output file path
    audio_file_path: []const u8 = "simulator_audio.raw",
    /// Simulation speed multiplier (1.0 = real-time)
    speed_multiplier: f32 = 1.0,
    /// Enable debug logging
    debug_logging: bool = false,
    /// Disk image path (null for no disk or in-memory)
    disk_image_path: ?[]const u8 = null,
    /// In-memory disk size in sectors (if disk_image_path is null)
    memory_disk_sectors: u64 = 60 * 1024 * 1024 / 512, // 60MB default
    /// Path to audio samples directory to populate mock FAT32 (overrides disk_image_path)
    audio_samples_path: ?[]const u8 = null,
};

// ============================================================
// Simulator State
// ============================================================

pub const SimulatorState = struct {
    // Memory
    iram: [128 * 1024]u8 = undefined,
    sdram: [32 * 1024 * 1024]u8 = undefined,

    // Registers (simulated memory-mapped I/O)
    gpio_output: [12]u32 = [_]u32{0} ** 12,
    gpio_enable: [12]u32 = [_]u32{0} ** 12,

    // Timer state
    timer_value: [4]u32 = [_]u32{0} ** 4,
    timer_cfg: [4]u32 = [_]u32{0} ** 4,
    usec_timer: u64 = 0,
    start_time: i128 = 0,

    // LCD state
    lcd_framebuffer: [320 * 240]u16 = [_]u16{0} ** (320 * 240),
    lcd_backlight: bool = false,

    // I2C state
    i2c_devices: std.AutoHashMap(u7, I2cDevice) = undefined,

    // I2S/Audio state
    audio_buffer: std.ArrayList(i16) = undefined,
    audio_sample_rate: u32 = 44100,
    audio_enabled: bool = false,

    // Click wheel state
    wheel_position: u8 = 0,
    button_state: u8 = 0,

    // Interrupt state
    interrupt_status: u32 = 0,
    interrupt_mask: u32 = 0,
    irq_enabled: bool = false,

    // ATA/Storage state
    disk_image: ?storage.disk_image.DiskImage = null,
    ata_controller: ?storage.ata_controller.AtaController = null,

    // Interrupt/Timer state
    interrupt_controller: interrupts.interrupt_controller.InterruptController = interrupts.interrupt_controller.InterruptController.init(),
    timer_system: interrupts.timer_sim.TimerSystem = interrupts.timer_sim.TimerSystem.init(),

    // CPU emulation
    arm_cpu: ?cpu.arm7tdmi.Arm7Tdmi = null,
    bus: ?memory_bus.MemoryBus = null,
    cpu_memory_interface: ?memory_bus.CpuMemoryBus = null,

    // Allocator
    allocator: std.mem.Allocator = undefined,

    // Configuration
    config: SimulatorConfig = .{},

    // I2C device simulation
    pub const I2cDevice = struct {
        registers: [256]u8 = [_]u8{0} ** 256,
        device_type: DeviceType = .generic,

        pub const DeviceType = enum {
            generic,
            wm8758_codec,
            pcf50605_pmu,
        };
    };

    /// Initialize the simulator
    pub fn init(allocator: std.mem.Allocator, config: SimulatorConfig) !*SimulatorState {
        const self = try allocator.create(SimulatorState);
        self.* = SimulatorState{};
        self.allocator = allocator;
        self.config = config;
        self.start_time = std.time.nanoTimestamp();

        // Initialize I2C devices
        self.i2c_devices = std.AutoHashMap(u7, I2cDevice).init(allocator);

        // Add standard iPod devices
        try self.addI2cDevice(0x1A, .wm8758_codec); // Audio codec
        try self.addI2cDevice(0x08, .pcf50605_pmu); // PMU

        // Initialize audio buffer
        self.audio_buffer = .{};

        // Initialize disk image and ATA controller
        if (config.audio_samples_path) |audio_path| {
            // Create mock FAT32 disk populated with audio samples
            std.debug.print("Creating mock FAT32 with audio samples from: {s}\n", .{audio_path});
            self.disk_image = storage.mock_fat32.createMockDiskWithAudioSamples(allocator, audio_path) catch |err| blk: {
                std.debug.print("Failed to create mock FAT32: {}\n", .{err});
                break :blk null;
            };
        } else if (config.disk_image_path) |path| {
            // Open existing disk image file
            self.disk_image = storage.disk_image.DiskImage.open(path, false) catch null;
        } else if (config.memory_disk_sectors > 0) {
            // Create in-memory disk for testing
            self.disk_image = storage.disk_image.DiskImage.createInMemory(allocator, config.memory_disk_sectors) catch null;
        }

        if (self.disk_image) |*disk| {
            self.ata_controller = storage.ata_controller.AtaController.init(disk);
        }

        // Connect timer system to interrupt controller
        self.timer_system.connectInterruptController(&self.interrupt_controller);

        // Clear memory
        @memset(&self.iram, 0);
        @memset(&self.sdram, 0);

        // Initialize memory bus with simulator's memory
        self.bus = try memory_bus.MemoryBus.initWithMemory(
            allocator,
            &self.iram,
            &self.sdram,
        );

        // Connect peripherals to memory bus
        if (self.bus) |*bus| {
            bus.connectInterruptController(&self.interrupt_controller);
            bus.connectTimers(&self.timer_system);
            if (self.ata_controller) |*ata| {
                bus.connectAta(ata);
            }
            bus.connectLcd(&self.lcd_framebuffer);

            // Create CPU memory interface
            self.cpu_memory_interface = bus.getCpuInterface();
        }

        // Initialize ARM7TDMI CPU
        self.arm_cpu = cpu.arm7tdmi.Arm7Tdmi.init();
        if (self.arm_cpu) |*arm| {
            if (self.cpu_memory_interface) |*mem_iface| {
                arm.setMemory(mem_iface);
            }
        }

        return self;
    }

    /// Cleanup the simulator
    pub fn deinit(self: *SimulatorState) void {
        self.i2c_devices.deinit();
        self.audio_buffer.deinit(self.allocator);

        // Clean up CPU
        self.arm_cpu = null;
        self.cpu_memory_interface = null;

        // Clean up memory bus
        if (self.bus) |*bus| {
            bus.deinit();
            self.bus = null;
        }

        // Clean up ATA/storage
        self.ata_controller = null;
        if (self.disk_image) |*disk| {
            disk.close();
            self.disk_image = null;
        }

        self.allocator.destroy(self);
    }

    /// Add an I2C device to the simulation
    pub fn addI2cDevice(self: *SimulatorState, addr: u7, device_type: I2cDevice.DeviceType) !void {
        var device = I2cDevice{ .device_type = device_type };

        // Initialize device-specific default register values
        switch (device_type) {
            .wm8758_codec => {
                // WM8758 default register values
                device.registers[0x00] = 0x00; // Software reset
            },
            .pcf50605_pmu => {
                // PCF50605 default register values
                device.registers[0x00] = 0x00; // ID register
                device.registers[0x09] = 0x00; // DCDC1 control
            },
            .generic => {},
        }

        try self.i2c_devices.put(addr, device);
    }

    /// Get current simulation time in microseconds
    pub fn getTimeUs(self: *SimulatorState) u64 {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.start_time;
        const scaled = @as(f64, @floatFromInt(elapsed_ns)) * self.config.speed_multiplier;
        return @intFromFloat(scaled / 1000.0);
    }

    /// Simulate delay
    pub fn delay(self: *SimulatorState, us: u64) void {
        const scaled_ns = @as(u64, @intFromFloat(@as(f64, @floatFromInt(us * 1000)) / self.config.speed_multiplier));
        std.Thread.sleep(scaled_ns);
    }

    /// Write to LCD framebuffer
    pub fn lcdWritePixel(self: *SimulatorState, x: u16, y: u16, color: u16) void {
        if (x < 320 and y < 240) {
            self.lcd_framebuffer[@as(usize, y) * 320 + x] = color;
        }
    }

    /// Render LCD to terminal (ASCII art)
    pub fn renderLcdToTerminal(self: *SimulatorState) void {
        if (!self.config.lcd_visualization) return;

        const stdout = std.fs.File.stdout();

        // Clear screen and move cursor to top
        _ = stdout.write("\x1B[2J\x1B[H") catch {};

        // Draw top border
        _ = stdout.write("+" ++ ("-" ** 80) ++ "+\n") catch {};

        // Draw scaled framebuffer (320x240 -> 80x24)
        const x_scale = 4;
        const y_scale = 10;

        // Build line buffer for efficient output
        var line_buf: [82]u8 = undefined;
        line_buf[0] = '|';
        line_buf[81] = '\n';

        var y: usize = 0;
        while (y < 240) : (y += y_scale) {
            var x: usize = 0;
            var buf_idx: usize = 1;
            while (x < 320) : (x += x_scale) {
                const pixel = self.lcd_framebuffer[y * 320 + x];
                line_buf[buf_idx] = colorToChar(pixel);
                buf_idx += 1;
            }
            line_buf[buf_idx] = '|';
            _ = stdout.write(line_buf[0 .. buf_idx + 2]) catch {};
        }

        // Draw bottom border
        _ = stdout.write("+" ++ ("-" ** 80) ++ "+\n") catch {};

        // Status line
        var status_buf: [128]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "Backlight: {s} | Wheel: {d} | Buttons: 0x{X:0>2}\n", .{
            if (self.lcd_backlight) "ON " else "OFF",
            self.wheel_position,
            self.button_state,
        }) catch return;
        _ = stdout.write(status) catch {};
    }

    /// Convert RGB565 color to ASCII character
    fn colorToChar(color: u16) u8 {
        // Extract RGB components
        const r = (color >> 11) & 0x1F;
        const g = (color >> 5) & 0x3F;
        const b = color & 0x1F;

        // Calculate approximate luminance
        const lum = (@as(u16, r) * 2 + @as(u16, g) + @as(u16, b) * 2) / 6;

        // Map to ASCII characters
        const chars = " .:-=+*#%@";
        const idx = @min(lum * chars.len / 32, chars.len - 1);
        return chars[idx];
    }

    /// Process simulated input from keyboard
    pub fn processKeyboardInput(self: *SimulatorState) void {
        // This would be implemented with platform-specific non-blocking input
        // For now, just provide a way to set button state programmatically
        _ = self;
    }

    /// Set simulated button state
    pub fn setButtonState(self: *SimulatorState, buttons: u8) void {
        self.button_state = buttons;
    }

    /// Set simulated wheel position
    pub fn setWheelPosition(self: *SimulatorState, position: u8) void {
        self.wheel_position = position % 96;
    }

    /// Add audio samples to buffer
    pub fn writeAudioSamples(self: *SimulatorState, samples: []const i16) !void {
        try self.audio_buffer.appendSlice(self.allocator, samples);
    }

    /// Save audio buffer to file
    pub fn saveAudioToFile(self: *SimulatorState) !void {
        if (!self.config.audio_to_file) return;

        const file = try std.fs.cwd().createFile(self.config.audio_file_path, .{});
        defer file.close();

        const bytes = std.mem.sliceAsBytes(self.audio_buffer.items);
        try file.writeAll(bytes);
    }

    // ============================================================
    // CPU Emulation Run Loop
    // ============================================================

    /// Result of running the simulator
    pub const RunResult = struct {
        cycles: u64,
        instructions: u64,
        stop_reason: StopReason,
    };

    pub const StopReason = enum {
        cycle_limit,
        breakpoint,
        halted,
        error_no_cpu,
        error_execution,
    };

    /// Load binary code into ROM for execution
    pub fn loadRom(self: *SimulatorState, data: []const u8) void {
        if (self.bus) |*bus| {
            bus.loadRom(data);
        }
    }

    /// Load binary code into IRAM at offset
    pub fn loadIram(self: *SimulatorState, offset: u32, data: []const u8) void {
        if (self.bus) |*bus| {
            bus.loadIram(offset, data);
        }
    }

    /// Load binary code into SDRAM at offset
    pub fn loadSdram(self: *SimulatorState, offset: u32, data: []const u8) void {
        if (self.bus) |*bus| {
            bus.loadSdram(offset, data);
        }
    }

    /// Reset the CPU
    pub fn resetCpu(self: *SimulatorState) void {
        if (self.arm_cpu) |*arm| {
            arm.reset();
        }
    }

    /// Set CPU program counter
    pub fn setCpuPc(self: *SimulatorState, pc: u32) void {
        if (self.arm_cpu) |*arm| {
            arm.setPC(pc);
        }
    }

    /// Get CPU program counter
    pub fn getCpuPc(self: *SimulatorState) u32 {
        if (self.arm_cpu) |*arm| {
            return arm.getPC();
        }
        return 0;
    }

    /// Get CPU register
    pub fn getCpuReg(self: *SimulatorState, reg: u4) u32 {
        if (self.arm_cpu) |*arm| {
            return arm.getReg(reg);
        }
        return 0;
    }

    /// Set CPU register
    pub fn setCpuReg(self: *SimulatorState, reg: u4, value: u32) void {
        if (self.arm_cpu) |*arm| {
            arm.setReg(reg, value);
        }
    }

    /// Step CPU one instruction
    pub fn stepCpu(self: *SimulatorState) ?cpu.arm7tdmi.StepResult {
        // Check for pending interrupts and update CPU IRQ line
        self.updateCpuInterrupts();

        if (self.arm_cpu) |*arm| {
            return arm.step();
        }
        return null;
    }

    /// Run CPU for specified number of cycles
    pub fn run(self: *SimulatorState, max_cycles: u64) RunResult {
        if (self.arm_cpu == null) {
            return .{
                .cycles = 0,
                .instructions = 0,
                .stop_reason = .error_no_cpu,
            };
        }

        var arm = &self.arm_cpu.?;
        var cycles_run: u64 = 0;
        var instructions_run: u64 = 0;

        while (cycles_run < max_cycles) {
            // Update timers based on elapsed time (simplified - 1 cycle = 1us)
            self.timer_system.tick(1);

            // Check for pending interrupts
            self.updateCpuInterrupts();

            const result = arm.step();
            cycles_run += result.cycles;

            switch (result.status) {
                .ok, .interrupt_taken => {
                    instructions_run += 1;
                },
                .halted => {
                    return .{
                        .cycles = cycles_run,
                        .instructions = instructions_run,
                        .stop_reason = .halted,
                    };
                },
                .breakpoint => {
                    return .{
                        .cycles = cycles_run,
                        .instructions = instructions_run,
                        .stop_reason = .breakpoint,
                    };
                },
                else => {
                    return .{
                        .cycles = cycles_run,
                        .instructions = instructions_run,
                        .stop_reason = .error_execution,
                    };
                },
            }
        }

        return .{
            .cycles = cycles_run,
            .instructions = instructions_run,
            .stop_reason = .cycle_limit,
        };
    }

    /// Update CPU interrupt lines from interrupt controller
    fn updateCpuInterrupts(self: *SimulatorState) void {
        if (self.arm_cpu) |*arm| {
            // Check if any enabled interrupts are pending
            const irq_pending = self.interrupt_controller.hasPendingIrq();
            arm.assertIrq(irq_pending);

            const fiq_pending = self.interrupt_controller.hasPendingFiq();
            arm.assertFiq(fiq_pending);
        }
    }

    /// Add a breakpoint
    pub fn addBreakpoint(self: *SimulatorState, addr: u32) bool {
        if (self.arm_cpu) |*arm| {
            return arm.addBreakpoint(addr);
        }
        return false;
    }

    /// Remove a breakpoint
    pub fn removeBreakpoint(self: *SimulatorState, addr: u32) bool {
        if (self.arm_cpu) |*arm| {
            return arm.removeBreakpoint(addr);
        }
        return false;
    }

    /// Get CPU cycle count
    pub fn getCpuCycles(self: *SimulatorState) u64 {
        if (self.arm_cpu) |*arm| {
            return arm.cycles;
        }
        return 0;
    }

    /// Get CPU instruction count
    pub fn getCpuInstructions(self: *SimulatorState) u64 {
        if (self.arm_cpu) |*arm| {
            return arm.instructions;
        }
        return 0;
    }

    /// Check if CPU is running
    pub fn isCpuRunning(self: *SimulatorState) bool {
        if (self.arm_cpu) |*arm| {
            return arm.state == .running;
        }
        return false;
    }
};

// ============================================================
// Simulator HAL Implementation
// ============================================================

var sim_state: ?*SimulatorState = null;

/// Initialize the simulator
pub fn initSimulator(allocator: std.mem.Allocator, config: SimulatorConfig) !void {
    sim_state = try SimulatorState.init(allocator, config);
}

/// Get the simulator state
pub fn getSimulatorState() ?*SimulatorState {
    return sim_state;
}

/// Shutdown the simulator
pub fn shutdownSimulator() void {
    if (sim_state) |state| {
        state.deinit();
        sim_state = null;
    }
}

// HAL function implementations for simulator
fn simSystemInit() hal.HalError!void {
    // Already initialized in initSimulator
}

fn simGetTicksUs() u64 {
    if (sim_state) |state| {
        return state.getTimeUs();
    }
    return 0;
}

fn simDelayUs(us: u32) void {
    if (sim_state) |state| {
        state.delay(us);
    }
}

fn simDelayMs(ms: u32) void {
    if (sim_state) |state| {
        state.delay(@as(u64, ms) * 1000);
    }
}

fn simSleep() void {
    std.Thread.sleep(1_000_000); // Sleep 1ms
}

fn simReset() noreturn {
    @panic("Simulator reset called");
}

fn simGpioSetDirection(port: u4, pin: u5, direction: hal.GpioDirection) void {
    if (sim_state) |state| {
        if (port < 12) {
            if (direction == .output) {
                state.gpio_enable[port] |= @as(u32, 1) << pin;
            } else {
                state.gpio_enable[port] &= ~(@as(u32, 1) << pin);
            }
        }
    }
}

fn simGpioWrite(port: u4, pin: u5, value: bool) void {
    if (sim_state) |state| {
        if (port < 12) {
            if (value) {
                state.gpio_output[port] |= @as(u32, 1) << pin;
            } else {
                state.gpio_output[port] &= ~(@as(u32, 1) << pin);
            }
        }
    }
}

fn simGpioRead(port: u4, pin: u5) bool {
    if (sim_state) |state| {
        if (port < 12) {
            return (state.gpio_output[port] & (@as(u32, 1) << pin)) != 0;
        }
    }
    return false;
}

fn simGpioSetInterrupt(_: u4, _: u5, _: hal.GpioInterruptMode) void {
    // Interrupt simulation not implemented
}

fn simI2cInit() hal.HalError!void {
    // Already initialized
}

fn simI2cWrite(addr: u7, data: []const u8) hal.HalError!void {
    if (sim_state) |state| {
        if (state.i2c_devices.getPtr(addr)) |device| {
            if (data.len >= 2) {
                device.registers[data[0]] = data[1];
            }
        } else {
            return hal.HalError.Nack;
        }
    }
}

fn simI2cRead(addr: u7, buffer: []u8) hal.HalError!usize {
    if (sim_state) |state| {
        if (state.i2c_devices.get(addr)) |_| {
            @memset(buffer, 0);
            return buffer.len;
        }
        return hal.HalError.Nack;
    }
    return hal.HalError.DeviceNotReady;
}

fn simI2cWriteRead(addr: u7, write_data: []const u8, read_buffer: []u8) hal.HalError!usize {
    try simI2cWrite(addr, write_data);
    return try simI2cRead(addr, read_buffer);
}

fn simI2sInit(_: u32, _: hal.I2sFormat, _: hal.I2sSampleSize) hal.HalError!void {
    if (sim_state) |state| {
        state.audio_enabled = true;
    }
}

fn simI2sWrite(samples: []const i16) hal.HalError!usize {
    if (sim_state) |state| {
        state.writeAudioSamples(samples) catch return hal.HalError.BufferOverflow;
        return samples.len;
    }
    return hal.HalError.DeviceNotReady;
}

fn simI2sTxReady() bool {
    return true;
}

fn simI2sTxFreeSlots() usize {
    return 256;
}

fn simI2sEnable(enable: bool) void {
    if (sim_state) |state| {
        state.audio_enabled = enable;
    }
}

fn simTimerStart(_: u2, _: u32, _: ?*const fn () void) hal.HalError!void {
    // Timer simulation not implemented
}

fn simTimerStop(_: u2) void {}

fn simAtaInit() hal.HalError!void {
    if (sim_state) |state| {
        if (state.ata_controller != null) {
            return; // Already initialized
        }
    }
    return hal.HalError.DeviceNotReady;
}

fn simAtaIdentify() hal.HalError!hal.AtaDeviceInfo {
    if (sim_state) |state| {
        if (state.ata_controller) |*controller| {
            if (state.disk_image) |disk| {
                var info: hal.AtaDeviceInfo = undefined;

                // Copy model/serial/firmware
                @memcpy(&info.model, &disk.model);
                @memcpy(&info.serial, &disk.serial);
                @memcpy(&info.firmware, &disk.firmware);

                info.total_sectors = disk.total_sectors;
                info.sector_size = 512;
                info.supports_lba48 = disk.requiresLba48();
                info.supports_dma = true;
                // Simulator defaults to flash storage for faster testing
                info.rotation_rate = 0x0001; // Non-rotating (SSD/flash)
                info.supports_trim = true;

                // Run identify command to verify controller works
                controller.writeCommand(@intFromEnum(storage.ata_controller.AtaCommand.identify));

                return info;
            }
        }
    }
    return hal.HalError.DeviceNotReady;
}

fn simAtaReadSectors(lba: u64, count: u16, buffer: []u8) hal.HalError!void {
    if (sim_state) |state| {
        if (state.ata_controller) |*controller| {
            controller.setLba(lba, count, lba > 0x0FFFFFFF);
            controller.writeCommand(@intFromEnum(storage.ata_controller.AtaCommand.read_sectors));

            // Read all sectors
            var offset: usize = 0;
            for (0..count) |_| {
                const bytes_read = controller.readData(buffer[offset..][0..512]);
                if (bytes_read != 512) {
                    return hal.HalError.TransferError;
                }
                offset += 512;
            }
            return;
        }
    }
    return hal.HalError.DeviceNotReady;
}

fn simAtaWriteSectors(lba: u64, count: u16, data: []const u8) hal.HalError!void {
    if (sim_state) |state| {
        if (state.ata_controller) |*controller| {
            controller.setLba(lba, count, lba > 0x0FFFFFFF);
            controller.writeCommand(@intFromEnum(storage.ata_controller.AtaCommand.write_sectors));

            // Write all sectors
            var offset: usize = 0;
            for (0..count) |_| {
                const bytes_written = controller.writeData(data[offset..][0..512]);
                if (bytes_written != 512) {
                    return hal.HalError.TransferError;
                }
                offset += 512;
            }
            return;
        }
    }
    return hal.HalError.DeviceNotReady;
}

fn simAtaFlush() hal.HalError!void {
    if (sim_state) |state| {
        if (state.ata_controller) |*controller| {
            controller.writeCommand(@intFromEnum(storage.ata_controller.AtaCommand.flush_cache));
            return;
        }
    }
}

fn simAtaStandby() hal.HalError!void {
    if (sim_state) |state| {
        if (state.ata_controller) |*controller| {
            controller.writeCommand(@intFromEnum(storage.ata_controller.AtaCommand.standby_immediate));
            return;
        }
    }
}

fn simLcdInit() hal.HalError!void {
    if (sim_state) |state| {
        @memset(&state.lcd_framebuffer, 0);
    }
}

fn simLcdWritePixel(x: u16, y: u16, color: u16) void {
    if (sim_state) |state| {
        state.lcdWritePixel(x, y, color);
    }
}

fn simLcdFillRect(x: u16, y: u16, width: u16, height: u16, color: u16) void {
    if (sim_state) |state| {
        var py: u16 = y;
        while (py < y + height and py < 240) : (py += 1) {
            var px: u16 = x;
            while (px < x + width and px < 320) : (px += 1) {
                state.lcdWritePixel(px, py, color);
            }
        }
    }
}

fn simLcdUpdate(framebuffer: []const u8) hal.HalError!void {
    if (sim_state) |state| {
        const pixel_count = @min(framebuffer.len / 2, state.lcd_framebuffer.len);
        for (0..pixel_count) |i| {
            const offset = i * 2;
            if (offset + 1 < framebuffer.len) {
                state.lcd_framebuffer[i] = @as(u16, framebuffer[offset]) | (@as(u16, framebuffer[offset + 1]) << 8);
            }
        }
        state.renderLcdToTerminal();
    }
}

fn simLcdUpdateRect(_: u16, _: u16, _: u16, _: u16, _: []const u8) hal.HalError!void {}

fn simLcdSetBacklight(on: bool) void {
    if (sim_state) |state| {
        state.lcd_backlight = on;
    }
}

fn simLcdSleep() void {
    if (sim_state) |state| {
        state.lcd_backlight = false;
    }
}

fn simLcdWake() hal.HalError!void {
    if (sim_state) |state| {
        state.lcd_backlight = true;
    }
}

fn simClickwheelInit() hal.HalError!void {}

fn simClickwheelReadButtons() u8 {
    if (sim_state) |state| {
        return state.button_state;
    }
    return 0;
}

fn simClickwheelReadPosition() u8 {
    if (sim_state) |state| {
        return state.wheel_position;
    }
    return 0;
}

fn simGetTicks() u32 {
    if (sim_state) |state| {
        return @intCast(state.getTimeUs() / 1000);
    }
    return 0;
}

fn simCacheInvalidateIcache() void {}
fn simCacheInvalidateDcache() void {}
fn simCacheFlushDcache() void {}
fn simCacheEnable(_: bool) void {}

fn simIrqEnable() void {
    if (sim_state) |state| {
        state.irq_enabled = true;
    }
}

fn simIrqDisable() void {
    if (sim_state) |state| {
        state.irq_enabled = false;
    }
}

fn simIrqEnabled() bool {
    if (sim_state) |state| {
        return state.irq_enabled;
    }
    return false;
}

fn simIrqRegister(_: u8, _: *const fn () void) void {}

// ============================================================
// Simulator HAL Instance
// ============================================================

/// Simulator HAL instance
pub const simulator_hal = hal.Hal{
    .system_init = simSystemInit,
    .get_ticks_us = simGetTicksUs,
    .delay_us = simDelayUs,
    .delay_ms = simDelayMs,
    .sleep = simSleep,
    .reset = simReset,

    .gpio_set_direction = simGpioSetDirection,
    .gpio_write = simGpioWrite,
    .gpio_read = simGpioRead,
    .gpio_set_interrupt = simGpioSetInterrupt,

    .i2c_init = simI2cInit,
    .i2c_write = simI2cWrite,
    .i2c_read = simI2cRead,
    .i2c_write_read = simI2cWriteRead,

    .i2s_init = simI2sInit,
    .i2s_write = simI2sWrite,
    .i2s_tx_ready = simI2sTxReady,
    .i2s_tx_free_slots = simI2sTxFreeSlots,
    .i2s_enable = simI2sEnable,

    .timer_start = simTimerStart,
    .timer_stop = simTimerStop,

    .ata_init = simAtaInit,
    .ata_identify = simAtaIdentify,
    .ata_read_sectors = simAtaReadSectors,
    .ata_write_sectors = simAtaWriteSectors,
    .ata_flush = simAtaFlush,
    .ata_standby = simAtaStandby,

    .lcd_init = simLcdInit,
    .lcd_write_pixel = simLcdWritePixel,
    .lcd_fill_rect = simLcdFillRect,
    .lcd_update = simLcdUpdate,
    .lcd_update_rect = simLcdUpdateRect,
    .lcd_set_backlight = simLcdSetBacklight,
    .lcd_sleep = simLcdSleep,
    .lcd_wake = simLcdWake,

    .clickwheel_init = simClickwheelInit,
    .clickwheel_read_buttons = simClickwheelReadButtons,
    .clickwheel_read_position = simClickwheelReadPosition,
    .get_ticks = simGetTicks,

    .cache_invalidate_icache = simCacheInvalidateIcache,
    .cache_invalidate_dcache = simCacheInvalidateDcache,
    .cache_flush_dcache = simCacheFlushDcache,
    .cache_enable = simCacheEnable,

    .irq_enable = simIrqEnable,
    .irq_disable = simIrqDisable,
    .irq_enabled = simIrqEnabled,
    .irq_register = simIrqRegister,
};

// ============================================================
// Tests
// ============================================================

test "simulator initialization" {
    const allocator = std.testing.allocator;

    try initSimulator(allocator, .{});
    defer shutdownSimulator();

    try std.testing.expect(sim_state != null);
}

test "simulator timing" {
    const allocator = std.testing.allocator;

    try initSimulator(allocator, .{});
    defer shutdownSimulator();

    const start = simGetTicksUs();
    std.Thread.sleep(10_000_000); // 10ms
    const elapsed = simGetTicksUs() - start;

    // Should be approximately 10ms (10000us) with generous tolerance for CI/slow systems
    try std.testing.expect(elapsed >= 5000);
    try std.testing.expect(elapsed <= 50000);
}

test "simulator GPIO" {
    const allocator = std.testing.allocator;

    try initSimulator(allocator, .{});
    defer shutdownSimulator();

    simGpioSetDirection(0, 5, .output);
    simGpioWrite(0, 5, true);
    try std.testing.expect(simGpioRead(0, 5));

    simGpioWrite(0, 5, false);
    try std.testing.expect(!simGpioRead(0, 5));
}

test "simulator I2C" {
    const allocator = std.testing.allocator;

    try initSimulator(allocator, .{});
    defer shutdownSimulator();

    // Write to codec
    try simI2cWrite(0x1A, &[_]u8{ 0x00, 0x55 });

    // Verify device exists
    var buffer: [2]u8 = undefined;
    const len = try simI2cRead(0x1A, &buffer);
    try std.testing.expectEqual(@as(usize, 2), len);

    // Non-existent device should NACK
    try std.testing.expectError(hal.HalError.Nack, simI2cWrite(0x50, &[_]u8{0x00}));
}

test "simulator ATA" {
    const allocator = std.testing.allocator;

    // Initialize simulator with in-memory disk
    try initSimulator(allocator, .{ .memory_disk_sectors = 1000 });
    defer shutdownSimulator();

    // Initialize ATA
    try simAtaInit();

    // Get device info
    const info = try simAtaIdentify();
    try std.testing.expectEqual(@as(u64, 1000), info.total_sectors);
    try std.testing.expectEqual(@as(u16, 512), info.sector_size);

    // Write a sector
    var write_buf: [512]u8 = undefined;
    @memset(&write_buf, 0xDD);
    write_buf[0] = 0xEE;
    try simAtaWriteSectors(5, 1, &write_buf);

    // Read it back
    var read_buf: [512]u8 = undefined;
    try simAtaReadSectors(5, 1, &read_buf);
    try std.testing.expectEqual(@as(u8, 0xEE), read_buf[0]);
    try std.testing.expectEqual(@as(u8, 0xDD), read_buf[1]);

    // Flush and standby should work
    try simAtaFlush();
    try simAtaStandby();
}

test "simulator CPU initialization" {
    const allocator = std.testing.allocator;

    try initSimulator(allocator, .{});
    defer shutdownSimulator();

    const state = sim_state.?;

    // CPU should be initialized
    try std.testing.expect(state.arm_cpu != null);
    try std.testing.expect(state.bus != null);
    try std.testing.expect(state.cpu_memory_interface != null);
}

test "simulator CPU simple execution" {
    const allocator = std.testing.allocator;

    try initSimulator(allocator, .{});
    defer shutdownSimulator();

    const state = sim_state.?;

    // Load a simple program: MOV R0, #42; MOV R1, #100; ADD R2, R0, R1
    // MOV R0, #42  = E3A0002A
    // MOV R1, #100 = E3A01064
    // ADD R2, R0, R1 = E0802001
    // MOV R3, #0 (infinite loop back to this) = E3A03000
    const program = [_]u8{
        0x2A, 0x00, 0xA0, 0xE3, // MOV R0, #42
        0x64, 0x10, 0xA0, 0xE3, // MOV R1, #100
        0x01, 0x20, 0x80, 0xE0, // ADD R2, R0, R1
        0x00, 0x30, 0xA0, 0xE3, // MOV R3, #0
    };

    // Load into ROM (at address 0)
    state.loadRom(&program);

    // Set PC to ROM start
    state.setCpuPc(0);

    // Run a few instructions
    const result = state.run(10);

    // Should have executed some instructions
    try std.testing.expect(result.instructions >= 3);

    // Check register values
    try std.testing.expectEqual(@as(u32, 42), state.getCpuReg(0));
    try std.testing.expectEqual(@as(u32, 100), state.getCpuReg(1));
    try std.testing.expectEqual(@as(u32, 142), state.getCpuReg(2));
}

test "simulator CPU memory access" {
    const allocator = std.testing.allocator;

    try initSimulator(allocator, .{});
    defer shutdownSimulator();

    const state = sim_state.?;

    // Program to store R0 to IRAM and load it back to R1
    // MOV R0, #0x5A     = E3A0005A
    // LDR R2, =0x40000000 (IRAM base) - use MOV to build address
    // MOV R2, #0x40000000 (need to use multiple instructions due to immediate encoding)
    // Actually: MOV R2, #0x40, ROR #6 = MOV R2, #0x40000000 = E3A02101
    // STR R0, [R2]      = E5820000
    // LDR R1, [R2]      = E5921000
    const program = [_]u8{
        0x5A, 0x00, 0xA0, 0xE3, // MOV R0, #0x5A
        0x01, 0x21, 0xA0, 0xE3, // MOV R2, #0x40000000 (1 rotated left by 2*1 = 0x40000000)
        0x00, 0x00, 0x82, 0xE5, // STR R0, [R2]
        0x00, 0x10, 0x92, 0xE5, // LDR R1, [R2]
    };

    state.loadRom(&program);
    state.setCpuPc(0);

    const result = state.run(10);
    try std.testing.expect(result.instructions >= 4);

    // R1 should have the value from R0
    try std.testing.expectEqual(@as(u32, 0x5A), state.getCpuReg(1));
}

test "simulator CPU step execution" {
    const allocator = std.testing.allocator;

    try initSimulator(allocator, .{});
    defer shutdownSimulator();

    const state = sim_state.?;

    // Load MOV R0, #1 at address 0
    const program = [_]u8{
        0x01, 0x00, 0xA0, 0xE3, // MOV R0, #1
        0x02, 0x00, 0xA0, 0xE3, // MOV R0, #2
    };

    state.loadRom(&program);
    state.setCpuPc(0);

    // Step once
    _ = state.stepCpu();
    try std.testing.expectEqual(@as(u32, 1), state.getCpuReg(0));
    try std.testing.expectEqual(@as(u32, 4), state.getCpuPc());

    // Step again
    _ = state.stepCpu();
    try std.testing.expectEqual(@as(u32, 2), state.getCpuReg(0));
}

test "simulator CPU breakpoint" {
    const allocator = std.testing.allocator;

    try initSimulator(allocator, .{});
    defer shutdownSimulator();

    const state = sim_state.?;

    // Load program
    const program = [_]u8{
        0x01, 0x00, 0xA0, 0xE3, // 0x00: MOV R0, #1
        0x02, 0x00, 0xA0, 0xE3, // 0x04: MOV R0, #2
        0x03, 0x00, 0xA0, 0xE3, // 0x08: MOV R0, #3
        0x04, 0x00, 0xA0, 0xE3, // 0x0C: MOV R0, #4
    };

    state.loadRom(&program);
    state.setCpuPc(0);

    // Set breakpoint at address 0x08
    try std.testing.expect(state.addBreakpoint(0x08));

    // Run until breakpoint
    const result = state.run(100);

    // Should stop at breakpoint
    try std.testing.expectEqual(SimulatorState.StopReason.breakpoint, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 0x08), state.getCpuPc());

    // R0 should be 2 (from instructions before breakpoint)
    try std.testing.expectEqual(@as(u32, 2), state.getCpuReg(0));
}

test {
    // Reference CPU emulation modules to include their tests
    std.testing.refAllDecls(cpu);
    // Reference memory bus to include its tests
    std.testing.refAllDecls(memory_bus);
    // Reference storage modules to include their tests
    std.testing.refAllDecls(storage);
    // Reference interrupt modules to include their tests
    std.testing.refAllDecls(interrupts);
    // Reference I2C device modules to include their tests
    std.testing.refAllDecls(i2c);
    // Reference audio modules to include their tests
    std.testing.refAllDecls(audio);
    // Reference profiler modules to include their tests
    std.testing.refAllDecls(profiler_mod);
    // Note: GUI module tests are run separately via the gui/gui.zig test target
}
