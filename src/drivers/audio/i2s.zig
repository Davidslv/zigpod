//! I2S Audio Interface Driver
//!
//! This module handles the I2S (Inter-IC Sound) interface for audio output.
//! The I2S interface connects to the WM8758 audio codec via:
//! - MCLK: Master clock (256 × sample rate)
//! - BCLK: Bit clock (32 × sample rate for 16-bit stereo)
//! - LRCLK: Left/Right clock (sample rate)
//! - SDATA: Serial data

const std = @import("std");
const hal = @import("../../hal/hal.zig");
const clock = @import("../../kernel/clock.zig");

// ============================================================
// I2S Configuration
// ============================================================

pub const Config = struct {
    sample_rate: u32 = 44100,
    format: hal.I2sFormat = .i2s_standard,
    sample_size: hal.I2sSampleSize = .bits_16,
};

// ============================================================
// I2S Driver State
// ============================================================

var current_config: Config = .{};
var initialized: bool = false;
var enabled: bool = false;

/// Initialize I2S with given configuration
pub fn init(config: Config) hal.HalError!void {
    // Configure MCLK for the requested sample rate
    // MCLK = 256 × sample_rate (required by WM8758)
    clock.configureI2sClock(config.sample_rate);

    // Initialize I2S peripheral
    try hal.current_hal.i2s_init(config.sample_rate, config.format, config.sample_size);
    current_config = config;
    initialized = true;
}

/// Enable I2S output
pub fn enable() void {
    if (initialized) {
        hal.current_hal.i2s_enable(true);
        enabled = true;
    }
}

/// Disable I2S output
pub fn disable() void {
    hal.current_hal.i2s_enable(false);
    enabled = false;
}

/// Check if I2S is enabled
pub fn isEnabled() bool {
    return enabled;
}

/// Write audio samples to I2S FIFO
pub fn write(samples: []const i16) hal.HalError!usize {
    if (!initialized) return hal.HalError.DeviceNotReady;
    if (!enabled) return hal.HalError.DeviceNotReady;
    return hal.current_hal.i2s_write(samples);
}

/// Check if I2S TX FIFO is ready for data
pub fn txReady() bool {
    return hal.current_hal.i2s_tx_ready();
}

/// Get number of free slots in TX FIFO
pub fn txFreeSlots() usize {
    return hal.current_hal.i2s_tx_free_slots();
}

/// Write samples, blocking until all are written
pub fn writeBlocking(samples: []const i16) hal.HalError!void {
    var written: usize = 0;
    while (written < samples.len) {
        while (!txReady()) {
            // Busy wait - could yield here
        }
        const n = try write(samples[written..]);
        written += n;
    }
}

/// Get current sample rate
pub fn getSampleRate() u32 {
    return current_config.sample_rate;
}

/// Change sample rate (requires reinit)
pub fn setSampleRate(rate: u32) hal.HalError!void {
    const was_enabled = enabled;
    if (was_enabled) disable();

    // Reconfigure MCLK for new sample rate
    clock.configureI2sClock(rate);

    current_config.sample_rate = rate;
    try hal.current_hal.i2s_init(rate, current_config.format, current_config.sample_size);

    if (was_enabled) enable();
}

/// Get MCLK frequency for current sample rate
pub fn getMclkFrequency() u32 {
    return current_config.sample_rate * 256;
}

// ============================================================
// Tests
// ============================================================

test "I2S configuration" {
    const config = Config{
        .sample_rate = 48000,
        .format = .i2s_standard,
        .sample_size = .bits_16,
    };

    try std.testing.expectEqual(@as(u32, 48000), config.sample_rate);
}
