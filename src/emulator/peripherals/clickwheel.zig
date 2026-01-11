//! iPod Click Wheel Controller
//!
//! Implements the click wheel peripheral for iPod 5th/5.5th Gen.
//!
//! Reference: Rockbox firmware/target/arm/ipod/button-clickwheel.c
//!
//! Registers (base 0x7000C100):
//! - 0x00: WHEEL_CTRL - Control register (init = 0xC00A1F00)
//! - 0x04: WHEEL_STATUS - Status register (bit 26 = data available)
//! - 0x40: WHEEL_DATA - Button/wheel data
//!
//! Data packet format (32-bit):
//! - Bits 7:0 - Packet type (0x1A = valid wheel packet)
//! - Bits 15:8 - Button states
//! - Bits 22:16 - Wheel position (0-95)
//! - Bit 30 - Wheel is being touched
//! - Bit 31 - Data valid (may be unset on 5.5G for MENU button!)

const std = @import("std");
const bus = @import("../memory/bus.zig");

/// Click wheel buttons
pub const Button = enum(u3) {
    select = 0, // Center button
    menu = 1, // Top
    play = 2, // Bottom (play/pause)
    next = 3, // Right (next track)
    prev = 4, // Left (previous track)
    hold = 5, // Hold switch

    pub fn mask(self: Button) u8 {
        return @as(u8, 1) << @intFromEnum(self);
    }
};

/// Click wheel packet structure
pub const WheelPacket = packed struct(u32) {
    /// Packet type (0x1A for valid data)
    packet_type: u8,

    /// Button states (active low on some bits)
    buttons: u8,

    /// Wheel position (0-95, 96 positions around the wheel)
    wheel_pos: u7,

    /// Reserved
    _reserved: u1,

    /// Padding for higher bits
    _pad: u6,

    /// Wheel is being touched
    wheel_touched: bool,

    /// Data valid flag
    valid: bool,

    const VALID_PACKET_TYPE: u8 = 0x1A;

    pub fn init() WheelPacket {
        return @bitCast(@as(u32, 0));
    }
};

/// Click wheel controller state
pub const ClickWheel = struct {
    /// Control register
    ctrl: u32,

    /// Current button states (1 = pressed)
    buttons: u8,

    /// Current wheel position (0-95)
    wheel_pos: u7,

    /// Is wheel being touched
    wheel_touched: bool,

    /// Data available flag
    data_available: bool,

    /// Previous wheel position (for delta calculation)
    prev_wheel_pos: u7,

    /// Accumulated wheel delta
    wheel_delta: i8,

    const Self = @This();

    /// Register offsets
    const REG_CTRL: u32 = 0x00;
    const REG_STATUS: u32 = 0x04;
    const REG_DATA: u32 = 0x40;

    /// Control register init value (from Rockbox)
    const CTRL_INIT: u32 = 0xC00A1F00;

    /// Status bit for data available
    const STATUS_DATA_AVAILABLE: u32 = 1 << 26;

    pub fn init() Self {
        return .{
            .ctrl = CTRL_INIT,
            .buttons = 0,
            .wheel_pos = 0,
            .wheel_touched = false,
            .data_available = false,
            .prev_wheel_pos = 0,
            .wheel_delta = 0,
        };
    }

    /// Press a button
    pub fn pressButton(self: *Self, button: Button) void {
        self.buttons |= button.mask();
        self.data_available = true;
    }

    /// Release a button
    pub fn releaseButton(self: *Self, button: Button) void {
        self.buttons &= ~button.mask();
        self.data_available = true;
    }

    /// Set button state directly
    pub fn setButton(self: *Self, button: Button, pressed: bool) void {
        if (pressed) {
            self.pressButton(button);
        } else {
            self.releaseButton(button);
        }
    }

    /// Check if button is pressed
    pub fn isButtonPressed(self: *const Self, button: Button) bool {
        return (self.buttons & button.mask()) != 0;
    }

    /// Touch the wheel at a position
    pub fn touchWheel(self: *Self, position: u7) void {
        self.prev_wheel_pos = self.wheel_pos;
        self.wheel_pos = position;
        self.wheel_touched = true;
        self.data_available = true;

        // Calculate delta
        const delta = @as(i8, @intCast(@as(i16, position) - @as(i16, self.prev_wheel_pos)));
        // Handle wrap-around
        if (delta > 48) {
            self.wheel_delta = delta - 96;
        } else if (delta < -48) {
            self.wheel_delta = delta + 96;
        } else {
            self.wheel_delta = delta;
        }
    }

    /// Release wheel
    pub fn releaseWheel(self: *Self) void {
        self.wheel_touched = false;
        self.wheel_delta = 0;
        self.data_available = true;
    }

    /// Rotate wheel by delta positions (positive = clockwise)
    pub fn rotateWheel(self: *Self, delta: i8) void {
        var new_pos = @as(i16, self.wheel_pos) + delta;
        // Wrap around 0-95
        while (new_pos < 0) new_pos += 96;
        while (new_pos >= 96) new_pos -= 96;
        self.touchWheel(@intCast(new_pos));
    }

    /// Get wheel rotation delta since last read
    pub fn getWheelDelta(self: *const Self) i8 {
        return self.wheel_delta;
    }

    /// Build the data packet
    fn buildPacket(self: *const Self) u32 {
        var packet = WheelPacket.init();
        packet.packet_type = WheelPacket.VALID_PACKET_TYPE;
        packet.buttons = self.buttons;
        packet.wheel_pos = self.wheel_pos;
        packet.wheel_touched = self.wheel_touched;
        packet.valid = true;
        return @bitCast(packet);
    }

    /// Read register
    pub fn read(self: *Self, offset: u32) u32 {
        return switch (offset) {
            REG_CTRL => self.ctrl,
            REG_STATUS => blk: {
                var status: u32 = 0;
                if (self.data_available) {
                    status |= STATUS_DATA_AVAILABLE;
                }
                break :blk status;
            },
            REG_DATA => blk: {
                const packet = self.buildPacket();
                self.data_available = false;
                break :blk packet;
            },
            else => 0,
        };
    }

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        switch (offset) {
            REG_CTRL => self.ctrl = value,
            REG_STATUS => {
                // Writing may acknowledge/clear status
                // Specific behavior depends on bits written
            },
            REG_DATA => {}, // Read-only
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
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.read(offset);
    }

    fn writeWrapper(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write(offset, value);
    }
};

// Tests
test "button press and release" {
    var wheel = ClickWheel.init();

    // Initially no buttons pressed
    try std.testing.expect(!wheel.isButtonPressed(.select));
    try std.testing.expect(!wheel.isButtonPressed(.menu));

    // Press select button
    wheel.pressButton(.select);
    try std.testing.expect(wheel.isButtonPressed(.select));
    try std.testing.expect(wheel.data_available);

    // Release select button
    wheel.releaseButton(.select);
    try std.testing.expect(!wheel.isButtonPressed(.select));
}

test "wheel touch and rotate" {
    var wheel = ClickWheel.init();

    // Touch at position 0
    wheel.touchWheel(0);
    try std.testing.expect(wheel.wheel_touched);
    try std.testing.expectEqual(@as(u7, 0), wheel.wheel_pos);

    // Rotate clockwise by 10 positions
    wheel.rotateWheel(10);
    try std.testing.expectEqual(@as(u7, 10), wheel.wheel_pos);
    try std.testing.expectEqual(@as(i8, 10), wheel.getWheelDelta());

    // Rotate counter-clockwise by 5
    wheel.rotateWheel(-5);
    try std.testing.expectEqual(@as(u7, 5), wheel.wheel_pos);
}

test "wheel wrap-around" {
    var wheel = ClickWheel.init();

    // Start at position 90
    wheel.touchWheel(90);

    // Rotate by 10 (should wrap to 4)
    wheel.rotateWheel(10);
    try std.testing.expectEqual(@as(u7, 4), wheel.wheel_pos);
}

test "data packet format" {
    var wheel = ClickWheel.init();

    // Set some state
    wheel.pressButton(.menu);
    wheel.touchWheel(48);

    // Read data register
    const data = wheel.read(ClickWheel.REG_DATA);
    const packet: WheelPacket = @bitCast(data);

    try std.testing.expectEqual(@as(u8, 0x1A), packet.packet_type);
    try std.testing.expect((packet.buttons & Button.menu.mask()) != 0);
    try std.testing.expectEqual(@as(u7, 48), packet.wheel_pos);
    try std.testing.expect(packet.wheel_touched);
    try std.testing.expect(packet.valid);
}

test "status register" {
    var wheel = ClickWheel.init();

    // Initially no data
    try std.testing.expect(!wheel.data_available);

    // Press button makes data available
    wheel.pressButton(.play);
    var status = wheel.read(ClickWheel.REG_STATUS);
    try std.testing.expect((status & ClickWheel.STATUS_DATA_AVAILABLE) != 0);

    // Reading data clears available flag
    _ = wheel.read(ClickWheel.REG_DATA);
    status = wheel.read(ClickWheel.REG_STATUS);
    try std.testing.expect((status & ClickWheel.STATUS_DATA_AVAILABLE) == 0);
}
