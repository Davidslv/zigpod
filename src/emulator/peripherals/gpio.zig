//! PP5021C GPIO Controller
//!
//! Implements the GPIO ports for the PP5021C SoC.
//! There are 12 GPIO ports (A-L), each with 8 pins.
//!
//! Reference: Rockbox firmware/export/pp5020.h
//!
//! Per-port registers (each port at 0x20 offset from previous):
//! - +0x00: ENABLE - Enable GPIO function
//! - +0x04: INT_EN - Interrupt enable
//! - +0x08: INT_LEV - Interrupt level (0=edge, 1=level)
//! - +0x0C: INT_CLR - Clear interrupt
//! - +0x10: OUTPUT_EN - Output enable (1=output, 0=input)
//! - +0x14: OUTPUT_VAL - Output value
//! - +0x18: INPUT_VAL - Input value (read-only)
//! - +0x1C: INT_STAT - Interrupt status
//!
//! Base addresses:
//! - GPIO A: 0x6000D000
//! - GPIO B: 0x6000D020
//! - ... (0x20 offset per port)
//! - GPIO L: 0x6000D160

const std = @import("std");
const bus = @import("../memory/bus.zig");

/// GPIO port identifier
pub const Port = enum(u4) {
    a = 0,
    b = 1,
    c = 2,
    d = 3,
    e = 4,
    f = 5,
    g = 6,
    h = 7,
    i = 8,
    j = 9,
    k = 10,
    l = 11,

    pub fn offset(self: Port) u32 {
        return @as(u32, @intFromEnum(self)) * 0x20;
    }
};

/// Single GPIO port state
const GpioPort = struct {
    enable: u32,
    int_en: u32,
    int_lev: u32,
    output_en: u32,
    output_val: u32,
    input_val: u32,
    int_stat: u32,

    /// External input pins (simulated hardware connections)
    external_input: u32,

    pub fn init() GpioPort {
        return .{
            .enable = 0,
            .int_en = 0,
            .int_lev = 0,
            .output_en = 0,
            .output_val = 0,
            .input_val = 0,
            .int_stat = 0,
            .external_input = 0,
        };
    }

    /// Update input value based on direction and external input
    pub fn updateInputs(self: *GpioPort) void {
        // For input pins (output_en = 0), use external input
        // For output pins (output_en = 1), read back output value
        self.input_val = (self.output_val & self.output_en) |
            (self.external_input & ~self.output_en);
    }
};

/// GPIO Controller
pub const GpioController = struct {
    ports: [12]GpioPort,

    /// Callback for output changes (for driving other peripherals)
    output_callback: ?*const fn (Port, u32) void,

    const Self = @This();

    /// Register offsets within each port
    const REG_ENABLE: u32 = 0x00;
    const REG_INT_EN: u32 = 0x04;
    const REG_INT_LEV: u32 = 0x08;
    const REG_INT_CLR: u32 = 0x0C;
    const REG_OUTPUT_EN: u32 = 0x10;
    const REG_OUTPUT_VAL: u32 = 0x14;
    const REG_INPUT_VAL: u32 = 0x18;
    const REG_INT_STAT: u32 = 0x1C;

    pub fn init() Self {
        var gpio = Self{
            .ports = undefined,
            .output_callback = null,
        };
        for (&gpio.ports) |*port| {
            port.* = GpioPort.init();
        }

        // Set default GPIO states for iPod hardware:
        // - GPIOA bit 5 (0x20) HIGH = hold switch OFF
        // - GPIOA all bits HIGH = no buttons pressed (active low)
        // - GPIOB similar defaults for other hardware signals
        gpio.ports[0].external_input = 0xFF; // GPIOA: all high (no buttons, hold OFF)
        gpio.ports[1].external_input = 0xFF; // GPIOB: all high
        gpio.ports[0].updateInputs();
        gpio.ports[1].updateInputs();

        return gpio;
    }

    /// Set output change callback
    pub fn setOutputCallback(self: *Self, callback: *const fn (Port, u32) void) void {
        self.output_callback = callback;
    }

    /// Set external input for a port (simulates hardware signals)
    pub fn setExternalInput(self: *Self, port: Port, value: u32) void {
        const p = &self.ports[@intFromEnum(port)];
        const old_input = p.input_val;
        p.external_input = value;
        p.updateInputs();

        // Check for interrupt conditions
        const changed = old_input ^ p.input_val;
        if ((changed & p.int_en & p.enable) != 0) {
            // Edge detected on enabled interrupt pins
            p.int_stat |= changed & p.int_en;
        }
    }

    /// Set specific pin as input
    pub fn setPin(self: *Self, port: Port, pin: u3, value: bool) void {
        const p = &self.ports[@intFromEnum(port)];
        const mask = @as(u32, 1) << pin;
        if (value) {
            p.external_input |= mask;
        } else {
            p.external_input &= ~mask;
        }
        p.updateInputs();
    }

    /// Read specific output pin
    pub fn readOutputPin(self: *const Self, port: Port, pin: u3) bool {
        const p = &self.ports[@intFromEnum(port)];
        const mask = @as(u32, 1) << pin;
        return (p.output_val & mask) != 0;
    }

    /// Read register
    pub fn read(self: *const Self, offset: u32) u32 {
        const port_idx = (offset / 0x20) & 0xF;
        const reg_offset = offset % 0x20;

        if (port_idx >= 12) return 0;
        const port = &self.ports[port_idx];

        const value = switch (reg_offset) {
            REG_ENABLE => port.enable,
            REG_INT_EN => port.int_en,
            REG_INT_LEV => port.int_lev,
            REG_INT_CLR => 0, // Write-only
            REG_OUTPUT_EN => port.output_en,
            REG_OUTPUT_VAL => port.output_val,
            REG_INPUT_VAL => port.input_val,
            REG_INT_STAT => port.int_stat,
            else => 0,
        };

        // Debug: trace ALL GPIO A reads (to find button_hold() behavior)
        if (port_idx == 0) {
            const reg_name = switch (reg_offset) {
                REG_ENABLE => "ENABLE",
                REG_INT_EN => "INT_EN",
                REG_INT_LEV => "INT_LEV",
                REG_INT_CLR => "INT_CLR",
                REG_OUTPUT_EN => "OUTPUT_EN",
                REG_OUTPUT_VAL => "OUTPUT_VAL",
                REG_INPUT_VAL => "INPUT_VAL",
                REG_INT_STAT => "INT_STAT",
                else => "UNKNOWN",
            };
            std.debug.print("GPIO_A_READ: reg={s}(0x{X:0>2}) val=0x{X:0>8} (ext={X:0>8}, out_en={X:0>8})\n", .{ reg_name, reg_offset, value, port.external_input, port.output_en });
        }

        return value;
    }

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        const port_idx = (offset / 0x20) & 0xF;
        const reg_offset = offset % 0x20;

        if (port_idx >= 12) return;
        const port = &self.ports[port_idx];

        switch (reg_offset) {
            REG_ENABLE => port.enable = value,
            REG_INT_EN => port.int_en = value,
            REG_INT_LEV => port.int_lev = value,
            REG_INT_CLR => {
                // Write 1 to clear interrupt status
                port.int_stat &= ~value;
            },
            REG_OUTPUT_EN => {
                port.output_en = value;
                port.updateInputs();
            },
            REG_OUTPUT_VAL => {
                const old_val = port.output_val;
                port.output_val = value;
                port.updateInputs();

                // Notify if changed
                if (old_val != value) {
                    if (self.output_callback) |callback| {
                        callback(@enumFromInt(port_idx), value);
                    }
                }
            },
            REG_INPUT_VAL => {}, // Read-only
            REG_INT_STAT => {}, // Use INT_CLR to clear
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
test "GPIO output" {
    var gpio = GpioController.init();

    // Configure Port A as output
    gpio.write(Port.a.offset() + GpioController.REG_ENABLE, 0xFF);
    gpio.write(Port.a.offset() + GpioController.REG_OUTPUT_EN, 0xFF);
    gpio.write(Port.a.offset() + GpioController.REG_OUTPUT_VAL, 0x55);

    // Read back
    try std.testing.expectEqual(@as(u32, 0x55), gpio.read(Port.a.offset() + GpioController.REG_OUTPUT_VAL));
    try std.testing.expectEqual(@as(u32, 0x55), gpio.read(Port.a.offset() + GpioController.REG_INPUT_VAL));
}

test "GPIO input" {
    var gpio = GpioController.init();

    // Configure Port B as input
    gpio.write(Port.b.offset() + GpioController.REG_ENABLE, 0xFF);
    gpio.write(Port.b.offset() + GpioController.REG_OUTPUT_EN, 0x00);

    // Set external input
    gpio.setExternalInput(.b, 0xAA);

    // Read input value
    try std.testing.expectEqual(@as(u32, 0xAA), gpio.read(Port.b.offset() + GpioController.REG_INPUT_VAL));
}

test "GPIO interrupt" {
    var gpio = GpioController.init();

    // Configure Port C with interrupts
    gpio.write(Port.c.offset() + GpioController.REG_ENABLE, 0xFF);
    gpio.write(Port.c.offset() + GpioController.REG_INT_EN, 0x01); // Enable interrupt on pin 0

    // Trigger edge
    gpio.setExternalInput(.c, 0x00);
    gpio.setExternalInput(.c, 0x01);

    // Check interrupt status
    try std.testing.expect((gpio.read(Port.c.offset() + GpioController.REG_INT_STAT) & 0x01) != 0);

    // Clear interrupt
    gpio.write(Port.c.offset() + GpioController.REG_INT_CLR, 0x01);
    try std.testing.expectEqual(@as(u32, 0), gpio.read(Port.c.offset() + GpioController.REG_INT_STAT));
}
