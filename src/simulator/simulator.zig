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

// Export storage simulation modules
pub const storage = struct {
    pub const disk_image = @import("storage/disk_image.zig");
    pub const identify = @import("storage/identify.zig");
    pub const ata_controller = @import("storage/ata_controller.zig");
};

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
        if (config.disk_image_path) |path| {
            // Open existing disk image file
            self.disk_image = storage.disk_image.DiskImage.open(path, false) catch null;
        } else if (config.memory_disk_sectors > 0) {
            // Create in-memory disk for testing
            self.disk_image = storage.disk_image.DiskImage.createInMemory(allocator, config.memory_disk_sectors) catch null;
        }

        if (self.disk_image) |*disk| {
            self.ata_controller = storage.ata_controller.AtaController.init(disk);
        }

        // Clear memory
        @memset(&self.iram, 0);
        @memset(&self.sdram, 0);

        return self;
    }

    /// Cleanup the simulator
    pub fn deinit(self: *SimulatorState) void {
        self.i2c_devices.deinit();
        self.audio_buffer.deinit(self.allocator);

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

        const writer = std.io.getStdOut().writer();

        // Clear screen and move cursor to top
        writer.writeAll("\x1B[2J\x1B[H") catch {};

        // Draw top border
        writer.writeAll("+" ++ ("-" ** 80) ++ "+\n") catch {};

        // Draw scaled framebuffer (320x240 -> 80x24)
        const x_scale = 4;
        const y_scale = 10;

        var y: usize = 0;
        while (y < 240) : (y += y_scale) {
            writer.writeAll("|") catch {};
            var x: usize = 0;
            while (x < 320) : (x += x_scale) {
                const pixel = self.lcd_framebuffer[y * 320 + x];
                const char = colorToChar(pixel);
                writer.writeByte(char) catch {};
            }
            writer.writeAll("|\n") catch {};
        }

        // Draw bottom border
        writer.writeAll("+" ++ ("-" ** 80) ++ "+\n") catch {};

        // Status line
        writer.print("Backlight: {} | Wheel: {} | Buttons: 0x{X:0>2}\n", .{
            if (self.lcd_backlight) "ON " else "OFF",
            self.wheel_position,
            self.button_state,
        }) catch {};
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

test {
    // Reference CPU emulation modules to include their tests
    std.testing.refAllDecls(cpu);
    // Reference storage modules to include their tests
    std.testing.refAllDecls(storage);
}
