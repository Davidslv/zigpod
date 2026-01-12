//! RAM Implementation
//!
//! Provides allocatable RAM regions for SDRAM and IRAM.

const std = @import("std");

/// SDRAM sizes for different iPod models
pub const SdramSize = enum(u32) {
    mb32 = 32 * 1024 * 1024, // 30GB model
    mb64 = 64 * 1024 * 1024, // 60GB and 80GB models

    pub fn bytes(self: SdramSize) u32 {
        return @intFromEnum(self);
    }
};

/// IRAM size (same for all PP5021C variants)
pub const IRAM_SIZE: u32 = 96 * 1024;

/// Allocatable RAM region
pub const Ram = struct {
    data: []u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Allocate RAM region
    pub fn init(allocator: std.mem.Allocator, byte_size: usize) !Self {
        const data = try allocator.alloc(u8, byte_size);
        @memset(data, 0);
        return .{
            .data = data,
            .allocator = allocator,
        };
    }

    /// Free RAM region
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
        self.data = &.{};
    }

    /// Read 8-bit value
    pub fn read8(self: *const Self, offset: u32) u8 {
        if (offset < self.data.len) {
            return self.data[offset];
        }
        return 0;
    }

    /// Read 16-bit value (little-endian)
    pub fn read16(self: *const Self, offset: u32) u16 {
        if (offset + 1 < self.data.len) {
            return @as(u16, self.data[offset]) |
                (@as(u16, self.data[offset + 1]) << 8);
        }
        return 0;
    }

    /// Read 32-bit value (little-endian)
    pub fn read32(self: *const Self, offset: u32) u32 {
        if (offset + 3 < self.data.len) {
            return @as(u32, self.data[offset]) |
                (@as(u32, self.data[offset + 1]) << 8) |
                (@as(u32, self.data[offset + 2]) << 16) |
                (@as(u32, self.data[offset + 3]) << 24);
        }
        return 0;
    }

    /// Write 8-bit value
    pub fn write8(self: *Self, offset: u32, value: u8) void {
        if (offset < self.data.len) {
            self.data[offset] = value;
        }
    }

    /// Write 16-bit value (little-endian)
    pub fn write16(self: *Self, offset: u32, value: u16) void {
        if (offset + 1 < self.data.len) {
            self.data[offset] = @truncate(value);
            self.data[offset + 1] = @truncate(value >> 8);
        }
    }

    /// Write 32-bit value (little-endian)
    pub fn write32(self: *Self, offset: u32, value: u32) void {
        if (offset + 3 < self.data.len) {
            self.data[offset] = @truncate(value);
            self.data[offset + 1] = @truncate(value >> 8);
            self.data[offset + 2] = @truncate(value >> 16);
            self.data[offset + 3] = @truncate(value >> 24);
        }
    }

    /// Load binary data into RAM
    pub fn load(self: *Self, offset: u32, data: []const u8) void {
        const start = @min(offset, @as(u32, @intCast(self.data.len)));
        const end = @min(offset + @as(u32, @intCast(data.len)), @as(u32, @intCast(self.data.len)));
        const len = end - start;
        if (len > 0) {
            @memcpy(self.data[start..end], data[0..len]);
        }
    }

    /// Clear RAM (fill with zeros)
    pub fn clear(self: *Self) void {
        @memset(self.data, 0);
    }

    /// Get size
    pub fn size(self: *const Self) usize {
        return self.data.len;
    }

    /// Get slice
    pub fn slice(self: *Self) []u8 {
        return self.data;
    }
};

// Tests
test "RAM allocation and access" {
    const allocator = std.testing.allocator;
    var ram = try Ram.init(allocator, 1024);
    defer ram.deinit();

    // Test 32-bit access
    ram.write32(0, 0x12345678);
    try std.testing.expectEqual(@as(u32, 0x12345678), ram.read32(0));

    // Test 16-bit access
    ram.write16(4, 0xABCD);
    try std.testing.expectEqual(@as(u16, 0xABCD), ram.read16(4));

    // Test 8-bit access
    ram.write8(6, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), ram.read8(6));
}

test "RAM load" {
    const allocator = std.testing.allocator;
    var ram = try Ram.init(allocator, 1024);
    defer ram.deinit();

    const data = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    ram.load(0, &data);

    try std.testing.expectEqual(@as(u32, 0x44332211), ram.read32(0));
}

test "RAM bounds checking" {
    const allocator = std.testing.allocator;
    var ram = try Ram.init(allocator, 16);
    defer ram.deinit();

    // Out of bounds read returns 0
    try std.testing.expectEqual(@as(u8, 0), ram.read8(100));
    try std.testing.expectEqual(@as(u32, 0), ram.read32(100));

    // Out of bounds write is silently ignored
    ram.write32(100, 0xDEADBEEF);
}
