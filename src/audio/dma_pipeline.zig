//! DMA Audio Pipeline
//!
//! This module provides interrupt-driven audio playback using DMA with double-buffering.
//! It uses FIQ (Fast Interrupt) for the I2S/DMA completion to minimize audio latency.
//!
//! Architecture:
//! ```
//!   ┌─────────────────────────────────────────────────────────────────┐
//!   │                        Audio Pipeline                           │
//!   ├─────────────────────────────────────────────────────────────────┤
//!   │                                                                 │
//!   │  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐ │
//!   │  │  Decoder │───►│ Buffer A │───►│   DMA    │───►│  I2S TX  │ │
//!   │  │ Callback │    │ (active) │    │ Channel 0│    │   FIFO   │ │
//!   │  └──────────┘    └──────────┘    └──────────┘    └──────────┘ │
//!   │       │                                               │        │
//!   │       │          ┌──────────┐                         │        │
//!   │       └─────────►│ Buffer B │◄────────────────────────┘        │
//!   │       (refill)   │(pending) │     (FIQ: swap buffers)          │
//!   │                  └──────────┘                                  │
//!   └─────────────────────────────────────────────────────────────────┘
//! ```
//!
//! Buffer sizes are tuned for iPod:
//! - 2048 stereo samples per buffer = 8KB per buffer
//! - At 44.1kHz, each buffer = ~46ms of audio
//! - Double buffering gives ~92ms total latency tolerance
//!
//! The FIQ handler swaps buffers and signals the main thread to refill.
//! Buffer refill happens in the main loop, not in interrupt context.

const std = @import("std");
const builtin = @import("builtin");

const is_arm = builtin.cpu.arch == .arm;

// Hardware imports
const hal = @import("../hal/hal.zig");
const pp5021c = if (is_arm) @import("../hal/pp5021c/pp5021c.zig") else struct {
    pub const interrupts = struct {
        pub fn init() void {}
        pub fn enableSource(_: anytype) void {}
        pub fn disableSource(_: anytype) void {}
        pub fn clearPending(_: anytype) void {}
        pub fn routeToFiq(_: anytype) void {}
        pub fn enableFiq() void {}
        pub fn disableFiq() void {}
        pub fn enterCritical() void {}
        pub fn exitCritical() void {}
        pub fn recordFiq() void {}
        pub fn recordSource(_: anytype) void {}
        pub const IrqSource = enum { i2s, dma };
    };
};
const reg = if (is_arm) @import("../hal/pp5021c/registers.zig") else struct {
    pub const IISCONFIG: usize = 0;
    pub const IISFIFO_CFG: usize = 0;
    pub const IISFIFO_WR: usize = 0;
    pub const IIS_DMA_TX_EN: u32 = 0;
    pub const IIS_IRQTX_EMPTY: u32 = 0;
    pub const IIS_IRQTX: u32 = 0;
    pub const DMA_CHAN0_BASE: usize = 0;
    pub const DMA_MASTER_CTRL: usize = 0;
    pub const DMA_MASTER_EN: u32 = 0;
    pub const DMA_CMD_OFF: usize = 0;
    pub const DMA_STATUS_OFF: usize = 0;
    pub const DMA_RAM_ADDR_OFF: usize = 0;
    pub const DMA_FLAGS_OFF: usize = 0;
    pub const DMA_PER_ADDR_OFF: usize = 0;
    pub const DMA_INCR_OFF: usize = 0;
    pub const DMA_CMD_START: u32 = 0;
    pub const DMA_CMD_INTR: u32 = 0;
    pub const DMA_CMD_RAM_TO_PER: u32 = 0;
    pub const DMA_CMD_WAIT_REQ: u32 = 0;
    pub const DMA_STATUS_BUSY: u32 = 0;
    pub const DMA_STATUS_DONE: u32 = 0;
    pub const DMA_INCR_RAM: u32 = 0;
    pub const DMA_FLAGS_REQ_SHIFT: u5 = 0;
    pub const DMA_FLAGS_BURST_SHIFT: u5 = 0;
    pub const DMA_BURST_4: u32 = 0;
    pub const DMA_REQ_IIS: u8 = 0;
    pub const CPU_INT_CLR: usize = 0;
    pub const DMA_IRQ: u32 = 0;
    pub const IIS_IRQ: u32 = 0;
    pub fn readReg(_: type, _: usize) u32 { return 0; }
    pub fn writeReg(_: type, _: usize, _: u32) void {}
    pub fn modifyReg(_: usize, _: u32, _: u32) void {}
};

// Logging
const log = @import("../debug/logger.zig").scoped(.dma_audio);

// ============================================================
// Configuration Constants
// ============================================================

/// Size of each DMA buffer in stereo samples
/// 2048 samples × 4 bytes = 8KB per buffer
/// At 44.1kHz: 2048 / 44100 = 46.4ms per buffer
pub const BUFFER_SAMPLES: usize = 2048;

/// Size of each DMA buffer in bytes (16-bit stereo)
pub const BUFFER_BYTES: usize = BUFFER_SAMPLES * 2 * @sizeOf(i16);

/// Number of buffers (double buffering)
pub const NUM_BUFFERS: usize = 2;

/// DMA channel for audio
pub const AUDIO_DMA_CHANNEL: u2 = 0;

/// Uncached memory base for DMA buffers (PP5021C specific)
/// DMA buffers must be in uncached memory for coherency
pub const UNCACHED_BASE: usize = 0x30000000;

// ============================================================
// Buffer Fill Callback
// ============================================================

/// Callback type for filling audio buffers
/// The callback receives a buffer of stereo i16 samples and returns
/// the number of samples actually written (may be less than buffer size)
pub const FillCallback = *const fn (buffer: []i16) usize;

// ============================================================
// Pipeline State
// ============================================================

/// DMA audio buffers - must be 32-byte aligned for DMA
/// These are allocated in uncached SDRAM for DMA coherency
var dma_buffers: [NUM_BUFFERS][BUFFER_SAMPLES * 2]i16 align(32) = undefined;

/// Index of buffer currently being played by DMA (0 or 1)
var active_buffer: u8 = 0;

/// Buffer that needs to be refilled (set by FIQ, cleared by main loop)
var buffer_needs_refill: [NUM_BUFFERS]bool = [_]bool{false} ** NUM_BUFFERS;

/// Fill callback (set by start())
var fill_callback: ?FillCallback = null;

/// Pipeline state
var running: bool = false;
var initialized: bool = false;
var paused: bool = false;

/// Statistics
var samples_played: u64 = 0;
var buffer_underruns: u32 = 0;
var fiq_count: u32 = 0;

// ============================================================
// Initialization
// ============================================================

/// Initialize the DMA audio pipeline
pub fn init() void {
    if (initialized) return;

    log.info("Initializing DMA audio pipeline", .{});

    // Clear buffers
    for (&dma_buffers) |*buf| {
        @memset(buf, 0);
    }

    // Reset state
    active_buffer = 0;
    buffer_needs_refill = [_]bool{false} ** NUM_BUFFERS;
    fill_callback = null;
    running = false;
    paused = false;
    samples_played = 0;
    buffer_underruns = 0;
    fiq_count = 0;

    if (is_arm) {
        // Initialize interrupt system
        pp5021c.interrupts.init();

        // Enable DMA controller
        reg.writeReg(u32, reg.DMA_MASTER_CTRL, reg.DMA_MASTER_EN);

        // Configure I2S for DMA mode
        configureI2sForDma();

        // Route I2S and DMA interrupts to FIQ for low latency
        pp5021c.interrupts.routeToFiq(.i2s);
        pp5021c.interrupts.routeToFiq(.dma);
    }

    initialized = true;
    log.info("DMA audio pipeline initialized (buffer={d}ms)", .{BUFFER_SAMPLES * 1000 / 44100});
}

/// Shutdown the DMA audio pipeline
pub fn deinit() void {
    if (!initialized) return;

    log.info("Shutting down DMA audio pipeline", .{});

    stop();

    if (is_arm) {
        // Disable DMA and I2S interrupts
        pp5021c.interrupts.disableSource(.i2s);
        pp5021c.interrupts.disableSource(.dma);
        pp5021c.interrupts.disableFiq();

        // Disable I2S DMA mode
        reg.modifyReg(reg.IISCONFIG, reg.IIS_DMA_TX_EN, 0);

        // Disable DMA controller
        reg.writeReg(u32, reg.DMA_MASTER_CTRL, 0);
    }

    initialized = false;
}

/// Configure I2S controller for DMA operation
fn configureI2sForDma() void {
    if (!is_arm) return;

    // Enable I2S DMA TX mode and TX FIFO empty interrupt
    reg.modifyReg(reg.IISCONFIG, 0, reg.IIS_DMA_TX_EN | reg.IIS_IRQTX_EMPTY);

    // Set FIFO threshold (interrupt when FIFO is half empty)
    // This gives us time to set up the next DMA transfer
    reg.writeReg(u32, reg.IISFIFO_CFG, 8); // Threshold = 8 samples
}

// ============================================================
// Playback Control
// ============================================================

/// Start DMA audio playback with the given fill callback
pub fn start(callback: FillCallback) !void {
    if (!initialized) {
        log.err("Cannot start - not initialized", .{});
        return error.NotInitialized;
    }
    if (running) {
        log.warn("Already running", .{});
        return;
    }

    log.info("Starting DMA audio playback", .{});

    fill_callback = callback;
    paused = false;

    // Pre-fill both buffers
    _ = fillBuffer(0);
    _ = fillBuffer(1);

    // Start with buffer 0
    active_buffer = 0;
    running = true;

    if (is_arm) {
        // Start first DMA transfer
        try startDmaTransfer(0);

        // Enable FIQ for audio
        pp5021c.interrupts.enableSource(.dma);
        pp5021c.interrupts.enableFiq();
    }

    log.info("DMA audio playback started", .{});
}

/// Stop DMA audio playback
pub fn stop() void {
    if (!running) return;

    log.info("Stopping DMA audio playback", .{});

    running = false;
    fill_callback = null;

    if (is_arm) {
        // Disable FIQ
        pp5021c.interrupts.disableFiq();
        pp5021c.interrupts.disableSource(.dma);

        // Abort any ongoing DMA transfer
        abortDmaTransfer();
    }

    // Clear buffers
    for (&dma_buffers) |*buf| {
        @memset(buf, 0);
    }

    log.info("DMA audio playback stopped (played {d} samples, {d} underruns)", .{
        samples_played,
        buffer_underruns,
    });
}

/// Pause playback (DMA continues but outputs silence)
pub fn pause() void {
    if (!running) return;
    paused = true;
    log.debug("DMA audio paused", .{});
}

/// Resume playback
pub fn unpause() void {
    if (!running) return;
    paused = false;
    log.debug("DMA audio resumed", .{});
}

/// Check if pipeline is running
pub fn isRunning() bool {
    return running;
}

/// Check if pipeline is paused
pub fn isPaused() bool {
    return paused;
}

// ============================================================
// DMA Operations
// ============================================================

/// Start DMA transfer from a buffer to I2S FIFO
fn startDmaTransfer(buffer_idx: u8) !void {
    if (!is_arm) return;

    const buf = &dma_buffers[buffer_idx];

    // Get uncached address for DMA
    const ram_addr = getUncachedAddress(@intFromPtr(buf.ptr));

    // DMA channel 0 registers
    const chan_base = reg.DMA_CHAN0_BASE;

    // Set RAM address (source)
    reg.writeReg(u32, chan_base + reg.DMA_RAM_ADDR_OFF, @truncate(ram_addr));

    // Set peripheral address (I2S FIFO)
    reg.writeReg(u32, chan_base + reg.DMA_PER_ADDR_OFF, @truncate(reg.IISFIFO_WR));

    // Configure address increment (increment RAM, not peripheral)
    reg.writeReg(u32, chan_base + reg.DMA_INCR_OFF, reg.DMA_INCR_RAM);

    // Configure flags: length, request source (I2S), burst size
    const length: u32 = BUFFER_BYTES;
    const req: u32 = @as(u32, reg.DMA_REQ_IIS) << reg.DMA_FLAGS_REQ_SHIFT;
    const burst: u32 = reg.DMA_BURST_4 << reg.DMA_FLAGS_BURST_SHIFT;
    reg.writeReg(u32, chan_base + reg.DMA_FLAGS_OFF, length | req | burst);

    // Start transfer with interrupt
    const cmd: u32 = reg.DMA_CMD_START | reg.DMA_CMD_INTR | reg.DMA_CMD_RAM_TO_PER | reg.DMA_CMD_WAIT_REQ;
    reg.writeReg(u32, chan_base + reg.DMA_CMD_OFF, cmd);
}

/// Abort current DMA transfer
fn abortDmaTransfer() void {
    if (!is_arm) return;

    // Clear command register to stop transfer
    reg.writeReg(u32, reg.DMA_CHAN0_BASE + reg.DMA_CMD_OFF, 0);

    // Wait for busy to clear (with timeout)
    var timeout: u32 = 10000;
    while (timeout > 0) : (timeout -= 1) {
        const status = reg.readReg(u32, reg.DMA_CHAN0_BASE + reg.DMA_STATUS_OFF);
        if ((status & reg.DMA_STATUS_BUSY) == 0) break;
    }
}

/// Get uncached memory address for DMA coherency
fn getUncachedAddress(addr: usize) usize {
    // PP5021C: Add 0x20000000 offset to get uncached alias
    // SDRAM: 0x10000000-0x12000000 -> Uncached: 0x30000000-0x32000000
    if (addr >= 0x10000000 and addr < 0x12000000) {
        return addr + 0x20000000;
    }
    return addr;
}

// ============================================================
// FIQ Handler (called from boot.zig)
// ============================================================

/// FIQ handler for DMA/I2S completion
/// This is called from the FIQ entry in boot.zig
/// Must be fast - just swap buffers and set refill flag
pub export fn handleAudioFiq() void {
    if (!running) return;

    fiq_count += 1;

    if (is_arm) {
        pp5021c.interrupts.recordFiq();

        // Clear interrupt sources
        reg.writeReg(u32, reg.CPU_INT_CLR, reg.DMA_IRQ | reg.IIS_IRQ);
    }

    // Update sample count
    samples_played += BUFFER_SAMPLES;

    // Mark completed buffer for refill
    buffer_needs_refill[active_buffer] = true;

    // Switch to next buffer
    active_buffer = @intCast((active_buffer + 1) % NUM_BUFFERS);

    // Start DMA on the next buffer
    if (is_arm) {
        startDmaTransfer(active_buffer) catch {
            // DMA start failed - increment underrun counter
            buffer_underruns += 1;
        };
    }
}

// ============================================================
// Main Loop Processing
// ============================================================

/// Process audio pipeline - call this from main loop
/// This refills buffers that were marked by the FIQ handler
pub fn process() void {
    if (!running) return;

    // Check each buffer for refill request
    for (0..NUM_BUFFERS) |i| {
        if (buffer_needs_refill[i]) {
            // Enter critical section to safely clear flag
            if (is_arm) pp5021c.interrupts.enterCritical();
            buffer_needs_refill[i] = false;
            if (is_arm) pp5021c.interrupts.exitCritical();

            // Refill the buffer
            const samples = fillBuffer(@intCast(i));
            if (samples == 0 and !paused) {
                // Buffer underrun - no data available
                buffer_underruns += 1;
                log.warn("Buffer underrun (count={d})", .{buffer_underruns});
            }
        }
    }
}

/// Fill a buffer using the callback
fn fillBuffer(buffer_idx: u8) usize {
    const buf = &dma_buffers[buffer_idx];

    if (paused) {
        // Output silence when paused
        @memset(buf, 0);
        return buf.len;
    }

    if (fill_callback) |callback| {
        const samples = callback(buf);

        // Zero-fill remainder if not full
        if (samples < buf.len) {
            @memset(buf[samples..], 0);
        }

        return samples;
    }

    // No callback - output silence
    @memset(buf, 0);
    return 0;
}

// ============================================================
// Statistics
// ============================================================

/// Get total samples played
pub fn getSamplesPlayed() u64 {
    return samples_played;
}

/// Get playback position in milliseconds (at 44.1kHz stereo)
pub fn getPositionMs() u64 {
    // samples_played is in stereo samples
    return (samples_played * 1000) / 44100;
}

/// Get buffer underrun count
pub fn getUnderrunCount() u32 {
    return buffer_underruns;
}

/// Get FIQ count (for debugging)
pub fn getFiqCount() u32 {
    return fiq_count;
}

/// Reset statistics
pub fn resetStats() void {
    samples_played = 0;
    buffer_underruns = 0;
    fiq_count = 0;
}

/// Get current active buffer index
pub fn getActiveBuffer() u8 {
    return active_buffer;
}

/// Get buffer fill status for debugging
pub fn getBufferStatus() struct {
    active: u8,
    needs_refill: [NUM_BUFFERS]bool,
} {
    return .{
        .active = active_buffer,
        .needs_refill = buffer_needs_refill,
    };
}

// ============================================================
// Tests
// ============================================================

test "buffer constants" {
    const testing = std.testing;

    // Verify buffer sizing
    try testing.expectEqual(@as(usize, 2048), BUFFER_SAMPLES);
    try testing.expectEqual(@as(usize, 8192), BUFFER_BYTES);
    try testing.expectEqual(@as(usize, 2), NUM_BUFFERS);
}

test "init and deinit" {
    init();
    try std.testing.expect(initialized);

    deinit();
    try std.testing.expect(!initialized);
}

test "fill buffer with silence" {
    init();
    defer deinit();

    // With no callback, buffer should be zeroed
    const samples = fillBuffer(0);
    try std.testing.expectEqual(@as(usize, 0), samples);

    // Verify buffer is zeroed
    for (dma_buffers[0]) |sample| {
        try std.testing.expectEqual(@as(i16, 0), sample);
    }
}

test "fill buffer with callback" {
    init();
    defer deinit();

    // Set up a test callback that fills with a pattern
    const TestCallback = struct {
        fn fill(buffer: []i16) usize {
            for (buffer, 0..) |*sample, i| {
                sample.* = @intCast(i % 1000);
            }
            return buffer.len;
        }
    };

    fill_callback = TestCallback.fill;

    const samples = fillBuffer(0);
    try std.testing.expectEqual(dma_buffers[0].len, samples);

    // Verify pattern
    try std.testing.expectEqual(@as(i16, 0), dma_buffers[0][0]);
    try std.testing.expectEqual(@as(i16, 1), dma_buffers[0][1]);
    try std.testing.expectEqual(@as(i16, 999), dma_buffers[0][999]);

    fill_callback = null;
}

test "statistics tracking" {
    init();
    defer deinit();

    // Reset stats
    resetStats();

    try std.testing.expectEqual(@as(u64, 0), getSamplesPlayed());
    try std.testing.expectEqual(@as(u32, 0), getUnderrunCount());
    try std.testing.expectEqual(@as(u32, 0), getFiqCount());

    // Simulate some playback
    samples_played = 44100;
    buffer_underruns = 2;
    fiq_count = 10;

    try std.testing.expectEqual(@as(u64, 44100), getSamplesPlayed());
    try std.testing.expectEqual(@as(u64, 1000), getPositionMs()); // 1 second
    try std.testing.expectEqual(@as(u32, 2), getUnderrunCount());
    try std.testing.expectEqual(@as(u32, 10), getFiqCount());
}

test "uncached address conversion" {
    // Test SDRAM address conversion
    try std.testing.expectEqual(@as(usize, 0x30000000), getUncachedAddress(0x10000000));
    try std.testing.expectEqual(@as(usize, 0x31000000), getUncachedAddress(0x11000000));

    // Non-SDRAM addresses should be unchanged
    try std.testing.expectEqual(@as(usize, 0x40000000), getUncachedAddress(0x40000000));
}
