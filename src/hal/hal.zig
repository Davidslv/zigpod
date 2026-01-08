//! Hardware Abstraction Layer (HAL) Interface
//!
//! This module provides a unified interface to all hardware peripherals.
//! The actual implementation is selected at compile time based on the target:
//! - ARM freestanding: Real PP5021C hardware
//! - Other targets: Mock implementations for testing
//!
//! This design enables Test-Driven Development (TDD) by allowing all code
//! to be tested on the host machine before deployment to real hardware.

const std = @import("std");
const builtin = @import("builtin");

// Select implementation based on target
const is_hardware = builtin.cpu.arch == .arm and builtin.os.tag == .freestanding;

/// Real hardware implementation
pub const pp5021c = @import("pp5021c/pp5021c.zig");

/// Mock implementation for testing
pub const mock = @import("mock/mock.zig");

// ============================================================
// HAL Interface Types
// ============================================================

/// Error types that can occur during HAL operations
pub const HalError = error{
    /// I2C/peripheral timeout
    Timeout,
    /// Device not responding or not ready
    DeviceNotReady,
    /// Data transfer error
    TransferError,
    /// Invalid parameter passed to function
    InvalidParameter,
    /// Operation not supported
    NotSupported,
    /// Bus arbitration lost
    ArbitrationLost,
    /// NACK received
    Nack,
    /// Buffer overflow
    BufferOverflow,
    /// Hardware error
    HardwareError,
};

/// GPIO pin direction
pub const GpioDirection = enum {
    input,
    output,
};

/// GPIO interrupt trigger mode
pub const GpioInterruptMode = enum {
    none,
    rising_edge,
    falling_edge,
    both_edges,
    high_level,
    low_level,
};

/// I2S audio format
pub const I2sFormat = enum {
    i2s_standard,
    left_justified,
    right_justified,
};

/// I2S sample size
pub const I2sSampleSize = enum {
    bits_16,
    bits_24,
    bits_32,
};

/// ATA/IDE device information
pub const AtaDeviceInfo = struct {
    model: [40]u8,
    serial: [20]u8,
    firmware: [8]u8,
    total_sectors: u64,
    sector_size: u16,
    supports_lba48: bool,
    supports_dma: bool,
};

// ============================================================
// HAL Interface Structure
// ============================================================

/// The HAL interface provides function pointers for all hardware operations.
/// This allows the implementation to be swapped at runtime (for testing)
/// or compile time (for firmware).
pub const Hal = struct {
    // --------------------------------------------------------
    // System Control
    // --------------------------------------------------------

    /// Initialize the entire system
    system_init: *const fn () HalError!void,

    /// Get current system tick count (microseconds)
    get_ticks_us: *const fn () u64,

    /// Delay for specified microseconds
    delay_us: *const fn (us: u32) void,

    /// Delay for specified milliseconds
    delay_ms: *const fn (ms: u32) void,

    /// Enter low-power sleep mode
    sleep: *const fn () void,

    /// Perform system reset
    reset: *const fn () noreturn,

    // --------------------------------------------------------
    // GPIO Operations
    // --------------------------------------------------------

    /// Set GPIO pin direction
    gpio_set_direction: *const fn (port: u4, pin: u5, direction: GpioDirection) void,

    /// Write to GPIO pin
    gpio_write: *const fn (port: u4, pin: u5, value: bool) void,

    /// Read from GPIO pin
    gpio_read: *const fn (port: u4, pin: u5) bool,

    /// Configure GPIO interrupt
    gpio_set_interrupt: *const fn (port: u4, pin: u5, mode: GpioInterruptMode) void,

    // --------------------------------------------------------
    // I2C Operations
    // --------------------------------------------------------

    /// Initialize I2C bus
    i2c_init: *const fn () HalError!void,

    /// Write bytes to I2C device
    i2c_write: *const fn (addr: u7, data: []const u8) HalError!void,

    /// Read bytes from I2C device
    i2c_read: *const fn (addr: u7, buffer: []u8) HalError!usize,

    /// Write then read (combined transaction)
    i2c_write_read: *const fn (addr: u7, write_data: []const u8, read_buffer: []u8) HalError!usize,

    // --------------------------------------------------------
    // I2S Audio Operations
    // --------------------------------------------------------

    /// Initialize I2S interface
    i2s_init: *const fn (sample_rate: u32, format: I2sFormat, sample_size: I2sSampleSize) HalError!void,

    /// Write audio samples to I2S FIFO
    i2s_write: *const fn (samples: []const i16) HalError!usize,

    /// Check if I2S TX FIFO has space
    i2s_tx_ready: *const fn () bool,

    /// Get number of free slots in TX FIFO
    i2s_tx_free_slots: *const fn () usize,

    /// Enable/disable I2S
    i2s_enable: *const fn (enable: bool) void,

    // --------------------------------------------------------
    // Timer Operations
    // --------------------------------------------------------

    /// Configure and start a timer
    timer_start: *const fn (timer_id: u2, period_us: u32, callback: ?*const fn () void) HalError!void,

    /// Stop a timer
    timer_stop: *const fn (timer_id: u2) void,

    // --------------------------------------------------------
    // ATA/IDE Operations
    // --------------------------------------------------------

    /// Initialize ATA controller
    ata_init: *const fn () HalError!void,

    /// Get device information
    ata_identify: *const fn () HalError!AtaDeviceInfo,

    /// Read sectors from storage
    ata_read_sectors: *const fn (lba: u64, count: u16, buffer: []u8) HalError!void,

    /// Write sectors to storage
    ata_write_sectors: *const fn (lba: u64, count: u16, data: []const u8) HalError!void,

    /// Flush write cache
    ata_flush: *const fn () HalError!void,

    /// Put drive in standby mode
    ata_standby: *const fn () HalError!void,

    // --------------------------------------------------------
    // LCD Operations
    // --------------------------------------------------------

    /// Initialize LCD controller
    lcd_init: *const fn () HalError!void,

    /// Write pixel to framebuffer
    lcd_write_pixel: *const fn (x: u16, y: u16, color: u16) void,

    /// Fill rectangle with color
    lcd_fill_rect: *const fn (x: u16, y: u16, width: u16, height: u16, color: u16) void,

    /// Update display from framebuffer
    lcd_update: *const fn (framebuffer: []const u8) HalError!void,

    /// Update rectangular region of display
    lcd_update_rect: *const fn (x: u16, y: u16, width: u16, height: u16, framebuffer: []const u8) HalError!void,

    /// Set backlight on/off
    lcd_set_backlight: *const fn (on: bool) void,

    /// Enter LCD sleep mode
    lcd_sleep: *const fn () void,

    /// Wake LCD from sleep
    lcd_wake: *const fn () HalError!void,

    // --------------------------------------------------------
    // Click Wheel Operations
    // --------------------------------------------------------

    /// Initialize click wheel
    clickwheel_init: *const fn () HalError!void,

    /// Read button state
    clickwheel_read_buttons: *const fn () u8,

    /// Read wheel position (0-95)
    clickwheel_read_position: *const fn () u8,

    /// Get current tick count (milliseconds)
    get_ticks: *const fn () u32,

    // --------------------------------------------------------
    // Cache Operations
    // --------------------------------------------------------

    /// Invalidate instruction cache
    cache_invalidate_icache: *const fn () void,

    /// Invalidate data cache
    cache_invalidate_dcache: *const fn () void,

    /// Flush data cache (write back)
    cache_flush_dcache: *const fn () void,

    /// Enable/disable cache
    cache_enable: *const fn (enable: bool) void,

    // --------------------------------------------------------
    // Interrupt Control
    // --------------------------------------------------------

    /// Enable global interrupts
    irq_enable: *const fn () void,

    /// Disable global interrupts
    irq_disable: *const fn () void,

    /// Check if interrupts are enabled
    irq_enabled: *const fn () bool,

    /// Register interrupt handler
    irq_register: *const fn (irq: u8, handler: *const fn () void) void,
};

// ============================================================
// Default HAL Instance
// ============================================================

/// Get the default HAL instance for the current target
pub fn getHal() *const Hal {
    if (is_hardware) {
        return &pp5021c.hal;
    } else {
        return &mock.hal;
    }
}

/// Global HAL instance - use this for all hardware access
pub var current_hal: *const Hal = undefined;

/// Initialize the HAL with the appropriate implementation
pub fn init() void {
    current_hal = getHal();
}

// ============================================================
// Convenience Functions
// ============================================================

/// Delay for specified microseconds using current HAL
pub inline fn delayUs(us: u32) void {
    current_hal.delay_us(us);
}

/// Delay for specified milliseconds using current HAL
pub inline fn delayMs(ms: u32) void {
    current_hal.delay_ms(ms);
}

/// Get current system time in microseconds
pub inline fn getTicksUs() u64 {
    return current_hal.get_ticks_us();
}

// ============================================================
// Tests
// ============================================================

test "HAL initialization" {
    init();
    try std.testing.expect(current_hal == &mock.hal);
}

test "HAL type sizes" {
    // Ensure our types are the expected sizes
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(GpioDirection));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(GpioInterruptMode));
}
