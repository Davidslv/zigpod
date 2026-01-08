//! I2C Bus Driver
//!
//! High-level I2C bus operations built on top of the HAL.

const std = @import("std");
const hal = @import("../hal/hal.zig");

// ============================================================
// I2C Device Abstraction
// ============================================================

pub const I2cDevice = struct {
    address: u7,

    /// Create a new I2C device handle
    pub fn init(address: u7) I2cDevice {
        return .{ .address = address };
    }

    /// Write bytes to the device
    pub fn write(self: I2cDevice, data: []const u8) hal.HalError!void {
        return hal.current_hal.i2c_write(self.address, data);
    }

    /// Read bytes from the device
    pub fn read(self: I2cDevice, buffer: []u8) hal.HalError!usize {
        return hal.current_hal.i2c_read(self.address, buffer);
    }

    /// Write a single byte
    pub fn writeByte(self: I2cDevice, byte: u8) hal.HalError!void {
        return self.write(&[_]u8{byte});
    }

    /// Read a single byte
    pub fn readByte(self: I2cDevice) hal.HalError!u8 {
        var buf: [1]u8 = undefined;
        _ = try self.read(&buf);
        return buf[0];
    }

    /// Write to a register (8-bit address, 8-bit value)
    pub fn writeReg8(self: I2cDevice, reg: u8, value: u8) hal.HalError!void {
        return self.write(&[_]u8{ reg, value });
    }

    /// Read from a register (8-bit address)
    pub fn readReg8(self: I2cDevice, reg: u8) hal.HalError!u8 {
        try self.writeByte(reg);
        return self.readByte();
    }

    /// Write to a register (8-bit address, 16-bit value, big-endian)
    pub fn writeReg16BE(self: I2cDevice, reg: u8, value: u16) hal.HalError!void {
        const high: u8 = @truncate(value >> 8);
        const low: u8 = @truncate(value);
        return self.write(&[_]u8{ reg, high, low });
    }

    /// Read from a register (8-bit address, 16-bit value, big-endian)
    pub fn readReg16BE(self: I2cDevice, reg: u8) hal.HalError!u16 {
        try self.writeByte(reg);
        var buf: [2]u8 = undefined;
        _ = try self.read(&buf);
        return (@as(u16, buf[0]) << 8) | buf[1];
    }
};

// ============================================================
// Bus Management
// ============================================================

var bus_initialized: bool = false;

/// Initialize the I2C bus
pub fn init() hal.HalError!void {
    try hal.current_hal.i2c_init();
    bus_initialized = true;
}

/// Check if bus is initialized
pub fn isInitialized() bool {
    return bus_initialized;
}

/// Scan the I2C bus for devices
pub fn scan(found: *std.ArrayList(u7)) hal.HalError!void {
    var addr: u8 = 1;
    while (addr < 128) : (addr += 1) {
        const device = I2cDevice.init(@truncate(addr));
        // Try to read a single byte
        var buf: [1]u8 = undefined;
        if (device.read(&buf)) |_| {
            try found.append(@truncate(addr));
        } else |_| {
            // Device didn't respond
        }
    }
}

// ============================================================
// Tests
// ============================================================

test "I2C device initialization" {
    const device = I2cDevice.init(0x1A);
    try std.testing.expectEqual(@as(u7, 0x1A), device.address);
}
