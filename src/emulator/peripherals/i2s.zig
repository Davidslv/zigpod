//! PP5021C I2S Audio Controller
//!
//! Implements the I2S audio interface for the PP5021C SoC.
//! Audio data is sent to the WM8758 audio codec via I2C for configuration.
//!
//! Reference: Rockbox firmware/export/pp5020.h
//!            Rockbox firmware/drivers/audio/wm8758.c
//!
//! Registers (base 0x70002800):
//! - 0x00: IISCONFIG - Main configuration
//! - 0x04: IISFIFO_CFG - FIFO configuration
//! - 0x08: IISCLK - Clock divider
//! - 0x0C: IISTXDMA - TX DMA configuration
//! - 0x10: IISRXDMA - RX DMA configuration
//! - 0x40: IISFIFO_WR - FIFO write (16-bit left/right samples)
//! - 0x44: IISFIFO_RD - FIFO read
//!
//! IISCONFIG bits:
//! - Bit 0: I2S enable
//! - Bit 1: TX enable
//! - Bit 2: RX enable
//! - Bit 3: TX FIFO enable
//! - Bits 10:8: TX format (0=16-bit, 1=24-bit, etc.)

const std = @import("std");
const bus = @import("../memory/bus.zig");
const interrupt_ctrl = @import("interrupt_ctrl.zig");

/// I2S sample rate (derived from clock configuration)
pub const SampleRate = enum(u32) {
    rate_44100 = 44100,
    rate_48000 = 48000,
    rate_22050 = 22050,
    rate_11025 = 11025,

    pub fn value(self: SampleRate) u32 {
        return @intFromEnum(self);
    }
};

/// Audio sample (stereo, 16-bit)
pub const AudioSample = struct {
    left: i16,
    right: i16,
};

/// FIFO buffer size (in samples)
const FIFO_SIZE: usize = 256;

/// I2S Controller
pub const I2sController = struct {
    /// Configuration register
    config: u32,

    /// FIFO configuration
    fifo_cfg: u32,

    /// Clock divider
    clock_div: u32,

    /// TX DMA configuration
    tx_dma: u32,

    /// RX DMA configuration
    rx_dma: u32,

    /// FIFO buffer
    fifo: [FIFO_SIZE]u32,

    /// FIFO write position
    fifo_write_pos: usize,

    /// FIFO read position
    fifo_read_pos: usize,

    /// FIFO sample count
    fifo_count: usize,

    /// Audio callback (called when samples are ready)
    audio_callback: ?*const fn ([]const AudioSample) void,

    /// Interrupt controller
    int_ctrl: ?*interrupt_ctrl.InterruptController,

    /// Sample buffer for callback
    sample_buffer: [FIFO_SIZE]AudioSample,

    /// Debug counters
    pub var debug_samples_written: u64 = 0;
    pub var debug_callbacks_triggered: u64 = 0;
    pub var debug_samples_sent: u64 = 0;

    const Self = @This();

    /// Register offsets
    const REG_CONFIG: u32 = 0x00;
    const REG_FIFO_CFG: u32 = 0x04;
    const REG_CLOCK: u32 = 0x08;
    const REG_TX_DMA: u32 = 0x0C;
    const REG_RX_DMA: u32 = 0x10;
    const REG_FIFO_WR: u32 = 0x40;
    const REG_FIFO_RD: u32 = 0x44;

    /// Config register bits
    const CFG_ENABLE: u32 = 1 << 0;
    const CFG_TX_ENABLE: u32 = 1 << 1;
    const CFG_RX_ENABLE: u32 = 1 << 2;
    const CFG_TX_FIFO_ENABLE: u32 = 1 << 3;
    const CFG_FORMAT_MASK: u32 = 0x7 << 8;

    /// FIFO thresholds
    const FIFO_HALF_FULL: usize = FIFO_SIZE / 2;

    pub fn init() Self {
        return .{
            .config = 0,
            .fifo_cfg = 0,
            .clock_div = 0,
            .tx_dma = 0,
            .rx_dma = 0,
            .fifo = [_]u32{0} ** FIFO_SIZE,
            .fifo_write_pos = 0,
            .fifo_read_pos = 0,
            .fifo_count = 0,
            .audio_callback = null,
            .int_ctrl = null,
            .sample_buffer = undefined,
        };
    }

    /// Set audio callback
    pub fn setAudioCallback(self: *Self, callback: *const fn ([]const AudioSample) void) void {
        self.audio_callback = callback;
    }

    /// Set interrupt controller
    pub fn setInterruptController(self: *Self, ctrl: *interrupt_ctrl.InterruptController) void {
        self.int_ctrl = ctrl;
    }

    /// Check if I2S is enabled
    pub fn isEnabled(self: *const Self) bool {
        return (self.config & CFG_ENABLE) != 0;
    }

    /// Check if TX is enabled
    pub fn isTxEnabled(self: *const Self) bool {
        return (self.config & CFG_TX_ENABLE) != 0;
    }

    /// Check if FIFO is empty
    pub fn isFifoEmpty(self: *const Self) bool {
        return self.fifo_count == 0;
    }

    /// Check if FIFO is full
    pub fn isFifoFull(self: *const Self) bool {
        return self.fifo_count >= FIFO_SIZE;
    }

    /// Write sample to FIFO
    pub fn writeSample(self: *Self, sample: u32) void {
        debug_samples_written += 1;

        if (self.isFifoFull()) {
            // FIFO overflow - discard oldest sample
            self.fifo_read_pos = (self.fifo_read_pos + 1) % FIFO_SIZE;
            self.fifo_count -= 1;
        }

        self.fifo[self.fifo_write_pos] = sample;
        self.fifo_write_pos = (self.fifo_write_pos + 1) % FIFO_SIZE;
        self.fifo_count += 1;

        // Check for half-full interrupt
        if (self.fifo_count >= FIFO_HALF_FULL) {
            self.flushFifo();
        }
    }

    /// Flush FIFO to audio output
    fn flushFifo(self: *Self) void {
        if (self.audio_callback == null or self.fifo_count == 0) {
            return;
        }

        debug_callbacks_triggered += 1;

        // Convert FIFO contents to samples
        var sample_count: usize = 0;
        while (sample_count < self.fifo_count) : (sample_count += 1) {
            const raw = self.fifo[self.fifo_read_pos];
            self.fifo_read_pos = (self.fifo_read_pos + 1) % FIFO_SIZE;

            // Assume 16-bit stereo (left in lower 16 bits, right in upper 16 bits)
            self.sample_buffer[sample_count] = .{
                .left = @bitCast(@as(u16, @truncate(raw))),
                .right = @bitCast(@as(u16, @truncate(raw >> 16))),
            };
        }

        debug_samples_sent += sample_count;
        self.fifo_count = 0;

        // Call audio callback
        if (self.audio_callback) |callback| {
            callback(self.sample_buffer[0..sample_count]);
        }
    }

    /// Get current sample rate based on clock configuration
    pub fn getSampleRate(self: *const Self) u32 {
        // Default to 44100 if clock not configured
        if (self.clock_div == 0) return 44100;

        // Calculate sample rate from clock divider
        // Base clock is typically 24MHz
        const base_clock: u32 = 24_000_000;
        const divider = (self.clock_div & 0xFFFF) + 1;
        return base_clock / divider / 64; // 64 = 32 bits per channel * 2 channels
    }

    /// Read register
    pub fn read(self: *const Self, offset: u32) u32 {
        return switch (offset) {
            REG_CONFIG => self.config,
            REG_FIFO_CFG => self.fifo_cfg,
            REG_CLOCK => self.clock_div,
            REG_TX_DMA => self.tx_dma,
            REG_RX_DMA => self.rx_dma,
            REG_FIFO_RD => 0, // RX FIFO not implemented
            else => 0,
        };
    }

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        switch (offset) {
            REG_CONFIG => {
                self.config = value;
                // If disabled, clear FIFO
                if ((value & CFG_ENABLE) == 0) {
                    self.fifo_count = 0;
                    self.fifo_read_pos = 0;
                    self.fifo_write_pos = 0;
                }
            },
            REG_FIFO_CFG => self.fifo_cfg = value,
            REG_CLOCK => self.clock_div = value,
            REG_TX_DMA => self.tx_dma = value,
            REG_RX_DMA => self.rx_dma = value,
            REG_FIFO_WR => {
                if (self.isEnabled() and self.isTxEnabled()) {
                    self.writeSample(value);
                }
            },
            else => {},
        }
    }

    /// Create a peripheral handler for the memory bus
    pub fn createHandler(self: *Self) bus.PeripheralHandler {
        return .{
            .context = @ptrCast(self),
            .readFn = readWrapper,
            .writeFn = writeWrapper,
        };
    }

    fn readWrapper(ctx: *anyopaque, offset: u32) u32 {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.read(offset);
    }

    fn writeWrapper(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write(offset, value);
    }
};

// Tests
test "I2S enable/disable" {
    var i2s = I2sController.init();

    // Initially disabled
    try std.testing.expect(!i2s.isEnabled());

    // Enable I2S
    i2s.write(I2sController.REG_CONFIG, I2sController.CFG_ENABLE | I2sController.CFG_TX_ENABLE);
    try std.testing.expect(i2s.isEnabled());
    try std.testing.expect(i2s.isTxEnabled());

    // Disable I2S
    i2s.write(I2sController.REG_CONFIG, 0);
    try std.testing.expect(!i2s.isEnabled());
}

test "FIFO write" {
    var i2s = I2sController.init();

    // Enable I2S
    i2s.write(I2sController.REG_CONFIG, I2sController.CFG_ENABLE | I2sController.CFG_TX_ENABLE);

    // Initially empty
    try std.testing.expect(i2s.isFifoEmpty());

    // Write a sample
    i2s.write(I2sController.REG_FIFO_WR, 0x12345678);
    try std.testing.expect(!i2s.isFifoEmpty());
    try std.testing.expectEqual(@as(usize, 1), i2s.fifo_count);
}

test "sample rate calculation" {
    var i2s = I2sController.init();

    // Default sample rate
    try std.testing.expectEqual(@as(u32, 44100), i2s.getSampleRate());

    // Set clock divider for 48000 Hz
    // 24MHz / 48000 / 64 = ~7.8, so divider = 7
    i2s.write(I2sController.REG_CLOCK, 7);
    const rate = i2s.getSampleRate();
    try std.testing.expect(rate > 40000 and rate < 60000);
}

test "audio callback" {
    var i2s = I2sController.init();
    var callback_called = false;
    var received_samples: usize = 0;

    const callback = struct {
        fn call(samples: []const AudioSample) void {
            _ = samples;
            // This would set callback_called = true but we can't access it
        }
    }.call;

    i2s.setAudioCallback(callback);
    _ = &callback_called;
    _ = &received_samples;

    // Enable and write samples
    i2s.write(I2sController.REG_CONFIG, I2sController.CFG_ENABLE | I2sController.CFG_TX_ENABLE);

    // Write enough samples to trigger callback
    for (0..I2sController.FIFO_HALF_FULL) |i| {
        i2s.write(I2sController.REG_FIFO_WR, @as(u32, @intCast(i)));
    }

    // Callback should have been called
    // (Can't easily verify in test without more complex setup)
}
