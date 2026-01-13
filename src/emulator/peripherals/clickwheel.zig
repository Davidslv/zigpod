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
const interrupt_ctrl = @import("interrupt_ctrl.zig");

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

    /// Interrupt controller for serial0 interrupt
    int_ctrl: ?*interrupt_ctrl.InterruptController,

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
            .int_ctrl = null,
        };
    }

    /// Set interrupt controller for serial0 interrupts
    pub fn setInterruptController(self: *Self, ctrl: *interrupt_ctrl.InterruptController) void {
        self.int_ctrl = ctrl;
    }

    /// Fire serial0 interrupt to notify firmware of data
    fn fireInterrupt(self: *Self) void {
        if (self.int_ctrl) |ctrl| {
            ctrl.assertInterrupt(.serial0);
            std.debug.print("CLICKWHEEL: Fired serial0 interrupt\n", .{});
        }
    }

    /// Press a button
    pub fn pressButton(self: *Self, button: Button) void {
        self.buttons |= button.mask();
        self.data_available = true;
        self.fireInterrupt();
    }

    /// Release a button
    pub fn releaseButton(self: *Self, button: Button) void {
        self.buttons &= ~button.mask();
        self.data_available = true;
        self.fireInterrupt();
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
    /// Format for iPod Video (read by opto_keypad_read):
    /// - Bits 0-9: Echo back command identifier (0x23a)
    /// - Bits 10-15: Reserved
    /// - Bits 16-20: Button states (0 = not pressed, 1 = pressed for software)
    /// - Bits 21-30: Wheel position / other data
    /// - Bit 31: Valid packet flag
    ///
    /// opto_keypad_read does: result = (packet << 11) >> 27 ^ 0x1F
    /// For no buttons pressed, we want result bits to be SET (non-zero) so
    /// that checks like (state & 0x10) == 0 return FALSE.
    ///
    /// So we need: ((packet << 11) >> 27) ^ 0x1F to have bits SET when no buttons
    /// This means (packet << 11) >> 27 should have bits CLEAR (0) when no buttons
    /// So bits 16-20 in packet should be 0 when no buttons pressed
    fn buildPacket(self: *const Self) u32 {
        // opto_keypad_read expects (value & 0x8000FFFF) == 0x8000023a for valid packet
        // and extracts button state from bits 16-20 via (value << 11) >> 27, then XORs with 0x1F

        // Start with base pattern that opto_keypad_read expects
        var packet: u32 = 0x8000023a; // Valid bit + echo pattern (bits 16-20 = 0 by default)

        // Button mapping (active HIGH in packet - 1 means pressed):
        // After extraction and XOR, a SET bit means NOT pressed
        // So for correct behavior: packet bits 16-20 = 0 when no buttons pressed
        // When pressed: set the corresponding bit

        // Bit 16 (0x01 after shift): SELECT
        // Bit 17 (0x02 after shift): RIGHT
        // Bit 18 (0x04 after shift): LEFT
        // Bit 19 (0x08 after shift): PLAY
        // Bit 20 (0x10 after shift): MENU

        var buttons: u32 = 0; // Default: no buttons pressed (all 0)

        // If buttons are pressed, SET corresponding bits
        if ((self.buttons & Button.select.mask()) != 0) buttons |= 0x01;
        if ((self.buttons & Button.next.mask()) != 0) buttons |= 0x02; // RIGHT
        if ((self.buttons & Button.prev.mask()) != 0) buttons |= 0x04; // LEFT
        if ((self.buttons & Button.play.mask()) != 0) buttons |= 0x08;
        if ((self.buttons & Button.menu.mask()) != 0) buttons |= 0x10;

        // Place button state in bits 16-20
        packet |= (buttons << 16);

        return packet;
    }

    /// Read register
    pub fn read(self: *Self, offset: u32) u32 {
        const value = switch (offset) {
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

        // Debug: trace click wheel reads
        if (offset == REG_STATUS or offset == REG_DATA) {
            std.debug.print("ClickWheel read offset=0x{X:0>2}: 0x{X:0>8} (avail={})\n", .{ offset, value, self.data_available });
        }

        return value;
    }

    /// Register for command (ser_opto_keypad_cfg writes here)
    const REG_CMD: u32 = 0x20;

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        // Debug: trace click wheel writes
        if (offset == REG_CMD) {
            std.debug.print("ClickWheel write offset=0x{X:0>2}: 0x{X:0>8}\n", .{ offset, value });
        }

        switch (offset) {
            REG_CTRL => self.ctrl = value,
            REG_STATUS => {
                // Writing may acknowledge/clear status
                // Specific behavior depends on bits written
            },
            REG_CMD => {
                // ser_opto_keypad_cfg writes command here (e.g., 0x8000023a)
                // This triggers data availability for response
                // value is the command, but we just care that a command was sent
                self.data_available = true;
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
