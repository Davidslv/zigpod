//! PP5020/PP5021 Cache Controller
//!
//! The PP5020/PP5021 has separate instruction and data caches with control
//! registers at 0x6000C000. The bootloader checks these registers
//! to ensure cache operations complete before proceeding.
//!
//! Register layout at 0x6000C000:
//!   Offset 0x000: CACHE_CTL - Cache control register
//!     Bit 15 (0x8000): Cache busy/operation in progress
//!                      Firmware polls until this bit CLEARS
//!     Other bits control cache enable/disable
//!
//! The firmware polls CACHE_CTL waiting for bit 15 to clear:
//!   0x10001ba4: ldr r0, [r1]       ; Read [0x6000C000]
//!   0x10001ba8: tst r0, #0x8000    ; Test bit 15
//!   0x10001bac: bne 0x10001ba4     ; Loop while bit 15 is SET
//!
//! This implementation always reports operations complete (bit 15 clear).

const std = @import("std");
const bus = @import("../memory/bus.zig");

/// Cache controller register offsets
/// Note: CACHE_CTL is at offset 0 (address 0x6000C000)
const CACHE_CTL: u32 = 0x000; // Main control register - bit 15 = busy
const CACHE_FLUSH: u32 = 0x004;
const CACHE_INVALIDATE: u32 = 0x008;
const CACHE_STATUS: u32 = 0x00C; // Additional status register

/// Bit masks for CACHE_CTL register
const CACHE_CTL_BUSY: u32 = 0x8000; // Bit 15: cache operation in progress

/// Cache Controller
pub const CacheController = struct {
    /// Control register value (with busy bit always cleared on read)
    ctrl: u32,

    /// Status - always ready
    status: u32,

    const Self = @This();

    /// Initialize cache controller
    pub fn init() Self {
        return .{
            // Control register starts with cache disabled, not busy
            // Bit 15 (busy) is CLEAR indicating cache is ready
            .ctrl = 0,
            // Status register indicates cache is idle/ready
            .status = 0x00000001,
        };
    }

    /// Read register
    /// For CACHE_CTL (offset 0), always returns with bit 15 CLEAR
    /// to indicate cache operations are complete
    pub fn read(self: *const Self, offset: u32) u32 {
        return switch (offset) {
            CACHE_CTL => self.ctrl & ~CACHE_CTL_BUSY, // Always report not busy (bit 15 clear)
            CACHE_FLUSH => 0,
            CACHE_INVALIDATE => 0,
            CACHE_STATUS => self.status,
            else => 0,
        };
    }

    /// Write register
    /// Writes to CACHE_CTL are stored but bit 15 is immediately cleared
    /// (cache operations complete instantly in emulation)
    pub fn write(self: *Self, offset: u32, value: u32) void {
        switch (offset) {
            CACHE_CTL => {
                // Store the value but immediately clear the busy bit
                // since cache operations complete instantly in emulation
                self.ctrl = value & ~CACHE_CTL_BUSY;
            },
            CACHE_FLUSH, CACHE_INVALIDATE => {
                // Flush/invalidate operations complete immediately
                // No state change needed
            },
            else => {},
        }
    }

    /// Create peripheral handler for memory bus
    pub fn createHandler(self: *Self) bus.PeripheralHandler {
        return .{
            .context = @ptrCast(self),
            .readFn = readHandler,
            .writeFn = writeHandler,
        };
    }

    fn readHandler(ctx: *anyopaque, offset: u32) u32 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.read(offset);
    }

    fn writeHandler(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write(offset, value);
    }
};

// Tests
test "cache controller initialization" {
    const cache = CacheController.init();
    // Status should indicate ready
    try std.testing.expectEqual(@as(u32, 0x01), cache.status);
    // Control register should start at 0 (not busy)
    try std.testing.expectEqual(@as(u32, 0x00), cache.ctrl);
}

test "cache controller read CACHE_CTL has bit 15 clear" {
    var cache = CacheController.init();
    // Reading CACHE_CTL at offset 0 should always have bit 15 (0x8000) clear
    const value = cache.read(CACHE_CTL);
    try std.testing.expectEqual(@as(u32, 0), value & CACHE_CTL_BUSY);
}

test "cache controller write CACHE_CTL clears bit 15" {
    var cache = CacheController.init();
    // Write with bit 15 set (simulating start of cache operation)
    cache.write(CACHE_CTL, 0x12348000);
    // Read should return value with bit 15 cleared (operation complete)
    const value = cache.read(CACHE_CTL);
    try std.testing.expectEqual(@as(u32, 0x12340000), value);
    // Bit 15 should be clear
    try std.testing.expectEqual(@as(u32, 0), value & CACHE_CTL_BUSY);
}

test "cache controller read status register" {
    var cache = CacheController.init();
    // Status register at offset 0x0C should return ready status
    try std.testing.expectEqual(@as(u32, 0x01), cache.read(CACHE_STATUS));
}
