//! Audio Hardware Interface
//!
//! This module provides low-level audio output using DMA on real hardware.
//! Uses double-buffering to ensure gapless audio playback:
//!
//! Buffer A playing → DMA interrupt → swap to Buffer B → refill A
//! Buffer B playing → DMA interrupt → swap to Buffer A → refill B
//!
//! On simulator/host, falls back to polling-based output.

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("../hal/hal.zig");

// Conditionally import kernel modules for ARM target
const is_arm = builtin.cpu.arch == .arm;
const dma = if (is_arm) @import("../kernel/dma.zig") else struct {
    pub const Channel = enum(u2) { audio = 0, storage = 1, general_0 = 2, general_1 = 3 };
    pub fn init() void {}
    pub fn configureAudio(_: []const u8) !void {}
    pub fn setCompletionCallback(_: Channel, _: ?*const fn (Channel) void) void {}
    pub fn isBusy(_: Channel) bool { return false; }
    pub fn abort(_: Channel) void {}
};

const reg = if (is_arm) @import("../hal/pp5021c/registers.zig") else struct {
    pub const IISFIFO_WR: usize = 0;
};

// ============================================================
// Audio DMA Configuration
// ============================================================

/// Size of each DMA buffer in samples (stereo pairs)
/// At 44.1kHz, 2048 samples = ~46ms of audio
pub const DMA_BUFFER_SAMPLES: usize = 2048;

/// Size of each DMA buffer in bytes (16-bit stereo)
pub const DMA_BUFFER_SIZE: usize = DMA_BUFFER_SAMPLES * 2 * 2;

/// Audio buffer fill callback
/// Called when a DMA buffer needs to be refilled
/// Should fill the buffer with stereo 16-bit samples
/// Returns number of samples written (0 if no more data)
pub const FillCallback = *const fn (buffer: []i16) usize;

// ============================================================
// Audio Hardware State
// ============================================================

/// Double buffer for DMA transfers
var dma_buffers: [2][DMA_BUFFER_SAMPLES * 2]i16 align(32) = undefined;

/// Which buffer is currently being played by DMA
var active_buffer: u8 = 0;

/// Buffer fill callback
var fill_callback: ?FillCallback = null;

/// Whether audio DMA is running
var running: bool = false;

/// Whether the module is initialized
var initialized: bool = false;

/// Sample rate
var sample_rate: u32 = 44100;

/// Samples transferred count
var samples_transferred: u64 = 0;

/// Underrun counter (DMA needed data but buffer was empty)
var underrun_count: u32 = 0;

// ============================================================
// Initialization
// ============================================================

/// Initialize audio hardware (DMA for real hardware, polling for sim)
pub fn init() void {
    if (initialized) return;

    if (is_arm) {
        // Initialize DMA controller
        dma.init();

        // Register our completion callback
        dma.setCompletionCallback(.audio, dmaCompleteCallback);

        // Clear buffers
        @memset(&dma_buffers[0], 0);
        @memset(&dma_buffers[1], 0);
    }

    active_buffer = 0;
    running = false;
    samples_transferred = 0;
    underrun_count = 0;
    initialized = true;
}

/// Shutdown audio hardware
pub fn deinit() void {
    if (!initialized) return;

    stop();

    if (is_arm) {
        dma.setCompletionCallback(.audio, null);
    }

    initialized = false;
}

// ============================================================
// Playback Control
// ============================================================

/// Start audio playback with the given fill callback
pub fn start(callback: FillCallback) !void {
    if (!initialized) return error.NotInitialized;
    if (running) return;

    fill_callback = callback;

    // Pre-fill both buffers
    _ = fillBuffer(0);
    _ = fillBuffer(1);

    active_buffer = 0;
    running = true;

    if (is_arm) {
        // Start DMA transfer from first buffer
        try startDmaTransfer(0);
    }
}

/// Stop audio playback
pub fn stop() void {
    running = false;
    fill_callback = null;

    if (is_arm) {
        dma.abort(.audio);
    }

    // Clear buffers
    @memset(&dma_buffers[0], 0);
    @memset(&dma_buffers[1], 0);
}

/// Check if audio is running
pub fn isRunning() bool {
    return running;
}

/// Set sample rate
pub fn setSampleRate(rate: u32) void {
    sample_rate = rate;
}

/// Get samples transferred
pub fn getSamplesTransferred() u64 {
    return samples_transferred;
}

/// Get underrun count
pub fn getUnderrunCount() u32 {
    return underrun_count;
}

// ============================================================
// DMA Operations
// ============================================================

/// Start DMA transfer from specified buffer
fn startDmaTransfer(buffer_idx: u8) !void {
    const buffer = &dma_buffers[buffer_idx];
    const buffer_bytes = std.mem.sliceAsBytes(buffer);

    try dma.configureAudio(buffer_bytes);
}

/// DMA completion callback - called from interrupt context
fn dmaCompleteCallback(channel: dma.Channel) void {
    _ = channel;

    if (!running) return;

    // Update sample count
    samples_transferred += DMA_BUFFER_SAMPLES;

    // The completed buffer can now be refilled
    const completed_buffer = active_buffer;

    // Switch to the other buffer
    active_buffer = (active_buffer + 1) % 2;

    // Start DMA on the next buffer
    startDmaTransfer(active_buffer) catch {
        // DMA start failed - stop playback
        running = false;
        return;
    };

    // Refill the completed buffer for next time
    const samples_filled = fillBuffer(completed_buffer);
    if (samples_filled == 0) {
        // No more data - we'll stop after current buffer finishes
        underrun_count += 1;
    }
}

/// Fill a buffer using the callback
fn fillBuffer(buffer_idx: u8) usize {
    if (fill_callback) |callback| {
        const buffer = &dma_buffers[buffer_idx];
        const samples = callback(buffer);

        // Zero-fill remainder if not full
        if (samples < buffer.len) {
            @memset(buffer[samples..], 0);
        }

        return samples;
    }
    return 0;
}

// ============================================================
// Polling Mode (for simulator/host)
// ============================================================

/// Process audio for polling mode (call from main loop on simulator)
/// On real hardware, DMA handles this automatically
pub fn process() !void {
    if (!initialized or !running) return;

    // On real hardware, DMA handles everything
    if (is_arm) return;

    // For simulator, we use polling
    if (fill_callback) |callback| {
        var temp_buffer: [256]i16 = undefined;
        const samples = callback(&temp_buffer);

        if (samples > 0) {
            // Write to HAL (simulator will handle buffering)
            _ = try hal.current_hal.i2s_write(temp_buffer[0..samples]);
            samples_transferred += samples / 2; // Stereo pairs
        }
    }
}

// ============================================================
// Buffer Access (for advanced use)
// ============================================================

/// Get pointer to a DMA buffer (for zero-copy operations)
pub fn getBuffer(idx: u8) []i16 {
    return &dma_buffers[idx % 2];
}

/// Get the currently playing buffer index
pub fn getActiveBufferIndex() u8 {
    return active_buffer;
}

/// Get the buffer that's not currently playing (safe to fill)
pub fn getInactiveBuffer() []i16 {
    return &dma_buffers[(active_buffer + 1) % 2];
}

// ============================================================
// Tests
// ============================================================

test "buffer sizes" {
    // Verify buffer size calculations
    try std.testing.expectEqual(@as(usize, 2048), DMA_BUFFER_SAMPLES);
    try std.testing.expectEqual(@as(usize, 8192), DMA_BUFFER_SIZE);
}

test "init and deinit" {
    init();
    try std.testing.expect(initialized);

    deinit();
    try std.testing.expect(!initialized);
}

test "sample rate" {
    init();
    defer deinit();

    setSampleRate(48000);
    try std.testing.expectEqual(@as(u32, 48000), sample_rate);
}
