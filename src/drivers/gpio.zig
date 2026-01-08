//! GPIO Driver
//!
//! High-level GPIO operations for ZigPod OS.

const std = @import("std");
const hal = @import("../hal/hal.zig");

// ============================================================
// GPIO Pin Abstraction
// ============================================================

pub const Pin = struct {
    port: u4,
    pin: u5,

    /// Create a pin reference
    pub fn init(port: u4, pin: u5) Pin {
        return .{ .port = port, .pin = pin };
    }

    /// Set pin as input
    pub fn setInput(self: Pin) void {
        hal.current_hal.gpio_set_direction(self.port, self.pin, .input);
    }

    /// Set pin as output
    pub fn setOutput(self: Pin) void {
        hal.current_hal.gpio_set_direction(self.port, self.pin, .output);
    }

    /// Write to pin (high or low)
    pub fn write(self: Pin, value: bool) void {
        hal.current_hal.gpio_write(self.port, self.pin, value);
    }

    /// Set pin high
    pub fn setHigh(self: Pin) void {
        self.write(true);
    }

    /// Set pin low
    pub fn setLow(self: Pin) void {
        self.write(false);
    }

    /// Toggle pin
    pub fn toggle(self: Pin) void {
        self.write(!self.read());
    }

    /// Read pin state
    pub fn read(self: Pin) bool {
        return hal.current_hal.gpio_read(self.port, self.pin);
    }

    /// Configure interrupt
    pub fn setInterrupt(self: Pin, mode: hal.GpioInterruptMode) void {
        hal.current_hal.gpio_set_interrupt(self.port, self.pin, mode);
    }
};

// ============================================================
// Port Constants
// ============================================================

pub const Port = struct {
    pub const A: u4 = 0;
    pub const B: u4 = 1;
    pub const C: u4 = 2;
    pub const D: u4 = 3;
    pub const E: u4 = 4;
    pub const F: u4 = 5;
    pub const G: u4 = 6;
    pub const H: u4 = 7;
    pub const I: u4 = 8;
    pub const J: u4 = 9;
    pub const K: u4 = 10;
    pub const L: u4 = 11;
};

// ============================================================
// Predefined Pins (iPod Video specific)
// ============================================================

pub const pins = struct {
    /// Main charger detection (Port C, Pin 2)
    pub const charger_main = Pin.init(Port.C, 2);

    /// USB charger detection (Port L)
    pub const charger_usb = Pin.init(Port.L, 0);

    /// Headphone detection (Port H)
    pub const headphone_detect = Pin.init(Port.H, 0);

    /// Hold switch
    pub const hold_switch = Pin.init(Port.H, 5);
};

// ============================================================
// Tests
// ============================================================

test "GPIO pin operations" {
    hal.init();

    const pin = Pin.init(0, 5);
    pin.setOutput();
    pin.setHigh();

    // Can't easily test actual values without mock state access
    try std.testing.expectEqual(@as(u4, 0), pin.port);
    try std.testing.expectEqual(@as(u5, 5), pin.pin);
}
