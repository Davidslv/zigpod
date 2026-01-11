//! PP5020 Cache Controller
//!
//! The PP5020 has separate instruction and data caches with control
//! registers at 0x6000C000. The bootloader checks these registers
//! to ensure cache operations complete before proceeding.
//!
//! This is a minimal implementation that always reports cache ready.

const std = @import("std");
const bus = @import("../memory/bus.zig");

/// Cache controller register offsets
const CACHE_STATUS: u32 = 0x000;
const CACHE_CTRL: u32 = 0x004;
const CACHE_FLUSH: u32 = 0x008;
const CACHE_INVALIDATE: u32 = 0x00C;

/// Cache Controller
pub const CacheController = struct {
    /// Control register
    ctrl: u32,

    /// Status - always ready (all ready bits set)
    status: u32,

    const Self = @This();

    /// Initialize cache controller
    pub fn init() Self {
        return .{
            .ctrl = 0,
            // Return status indicating cache is idle/ready
            // Bit 9 (0x200) must be CLEAR - it's the busy flag
            // Bit 0 set means ready
            .status = 0x00000001,
        };
    }

    /// Read register
    pub fn read(self: *const Self, offset: u32) u32 {
        return switch (offset) {
            CACHE_STATUS => self.status,
            CACHE_CTRL => self.ctrl,
            else => 0,
        };
    }

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        switch (offset) {
            CACHE_CTRL => self.ctrl = value,
            CACHE_FLUSH, CACHE_INVALIDATE => {
                // Flush/invalidate operations complete immediately
                // Status remains ready
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
    try std.testing.expectEqual(@as(u32, 0x01), cache.status);
}

test "cache controller read status" {
    var cache = CacheController.init();
    try std.testing.expectEqual(@as(u32, 0x01), cache.read(CACHE_STATUS));
}

test "cache controller write ctrl" {
    var cache = CacheController.init();
    cache.write(CACHE_CTRL, 0x12345678);
    try std.testing.expectEqual(@as(u32, 0x12345678), cache.read(CACHE_CTRL));
}
