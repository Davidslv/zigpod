//! PP5020 I2C Controller
//!
//! The PP5020/PP5021C has an I2C controller for communication with:
//! - PCF50605 Power Management IC (address 0x08)
//! - WM8758 Audio Codec (address 0x1A)
//!
//! This is a minimal implementation that responds to basic probes.
//!
//! Base address: 0x7000C000
//!
//! Registers:
//! - 0x00: I2C_CTRL - Control register
//! - 0x04: I2C_ADDR - Slave address
//! - 0x0C-0x1C: I2C_DATA0-DATA3 - Data registers
//! - 0x1C: I2C_STATUS - Status register

const std = @import("std");
const bus = @import("../memory/bus.zig");

/// I2C device addresses
const I2C_ADDR_PCF50605: u8 = 0x08; // Power management
const I2C_ADDR_WM8758: u8 = 0x1A; // Audio codec

/// I2C register offsets
const I2C_CTRL: u32 = 0x00;
const I2C_ADDR: u32 = 0x04;
const I2C_DATA0: u32 = 0x0C;
const I2C_DATA1: u32 = 0x10;
const I2C_DATA2: u32 = 0x14;
const I2C_DATA3: u32 = 0x18;
const I2C_STATUS: u32 = 0x1C;

/// I2C status bits (from Rockbox i2c-pp.c)
const STATUS_BUSY: u32 = 0x40; // Bit 6: Transfer in progress
const STATUS_ACK: u32 = 0x01; // Bit 0: ACK received
const STATUS_DONE: u32 = 0x00; // Transfer complete (not busy)

/// I2C Controller
pub const I2cController = struct {
    /// Control register
    ctrl: u32,

    /// Slave address
    addr: u32,

    /// Data registers
    data: [4]u32,

    /// Status register
    status: u32,

    /// PCF50605 register values (power management)
    pcf_regs: [256]u8,

    /// WM8758 register values (audio codec)
    wm_regs: [256]u16,

    /// Current register address for multi-byte ops
    current_reg: u8,

    const Self = @This();

    /// Initialize I2C controller
    pub fn init() Self {
        var self = Self{
            .ctrl = 0,
            .addr = 0,
            .data = [_]u32{0} ** 4,
            .status = STATUS_ACK, // Idle, ready with ACK
            .pcf_regs = [_]u8{0} ** 256,
            .wm_regs = [_]u16{0} ** 256,
            .current_reg = 0,
        };

        // Initialize PCF50605 with default values
        self.initPcf50605();

        // Initialize WM8758 with default values
        self.initWm8758();

        return self;
    }

    /// Initialize PCF50605 power management defaults
    fn initPcf50605(self: *Self) void {
        // ID register (0x00) - PCF50605 identification
        self.pcf_regs[0x00] = 0x35; // PCF50605 ID

        // OOCS register (0x01) - On/Off control status
        self.pcf_regs[0x01] = 0x00;

        // INT1-INT3 registers (0x02-0x04) - Interrupt status
        self.pcf_regs[0x02] = 0x00;
        self.pcf_regs[0x03] = 0x00;
        self.pcf_regs[0x04] = 0x00;

        // OOCC1-OOCC2 (0x05-0x06) - On/Off control config
        self.pcf_regs[0x05] = 0x00;
        self.pcf_regs[0x06] = 0x00;

        // RTC registers (0x0A-0x11)
        self.pcf_regs[0x0A] = 0; // seconds
        self.pcf_regs[0x0B] = 0; // minutes
        self.pcf_regs[0x0C] = 12; // hours
        self.pcf_regs[0x0D] = 1; // weekday
        self.pcf_regs[0x0E] = 1; // day
        self.pcf_regs[0x0F] = 1; // month
        self.pcf_regs[0x10] = 24; // year (2024 - 2000)

        // GPOOD register (0x39) - GPIO state
        self.pcf_regs[0x39] = 0xFF; // All GPIOs high

        // ADC results (0x30-0x31)
        self.pcf_regs[0x30] = 0x80; // ADC low byte
        self.pcf_regs[0x31] = 0x03; // ADC high byte (battery ~3.8V)

        // DCDCTIM (various regulator timing)
        self.pcf_regs[0x20] = 0x00;

        // LEDC registers (0x36-0x37) - LED driver for backlight
        // LEDC1: LED control 1 - bits control PWM mode
        self.pcf_regs[0x36] = 0x00; // Off initially
        // LEDC2: LED control 2 - brightness level
        self.pcf_regs[0x37] = 0x00; // Zero brightness initially

        // BVMC register (battery voltage monitor)
        self.pcf_regs[0x32] = 0x00;
    }

    /// Initialize WM8758 audio codec defaults
    fn initWm8758(self: *Self) void {
        // Default codec register values
        // Register 0x00: Software Reset (write-only)
        self.wm_regs[0x00] = 0x0000;

        // Register 0x01: Power Management 1
        self.wm_regs[0x01] = 0x0000;

        // Register 0x02: Power Management 2
        self.wm_regs[0x02] = 0x0000;

        // Register 0x03: Power Management 3
        self.wm_regs[0x03] = 0x0000;

        // Register 0x04: Audio Interface
        self.wm_regs[0x04] = 0x0050;

        // Register 0x05: Companding
        self.wm_regs[0x05] = 0x0000;

        // Register 0x06: Clock Gen Control
        self.wm_regs[0x06] = 0x0140;

        // Register 0x07: Additional Control
        self.wm_regs[0x07] = 0x0000;

        // Left/Right volume controls
        self.wm_regs[0x0A] = 0x00FF; // DACL volume
        self.wm_regs[0x0B] = 0x00FF; // DACR volume
    }

    /// Handle I2C read from device
    fn i2cDeviceRead(self: *Self, addr: u8, reg: u8) u8 {
        return switch (addr) {
            I2C_ADDR_PCF50605 => self.pcf_regs[reg],
            I2C_ADDR_WM8758 => @truncate(self.wm_regs[reg] & 0xFF),
            else => 0xFF, // NACK - unknown device
        };
    }

    /// Handle I2C write to device
    fn i2cDeviceWrite(self: *Self, addr: u8, reg: u8, value: u8) void {
        switch (addr) {
            I2C_ADDR_PCF50605 => {
                // PCF50605 - some registers are read-only
                switch (reg) {
                    0x00 => {}, // ID is read-only
                    0x02, 0x03, 0x04 => {}, // INT status is read-to-clear
                    else => self.pcf_regs[reg] = value,
                }
            },
            I2C_ADDR_WM8758 => {
                // WM8758 uses 9-bit register values, but we'll accept 8-bit for simplicity
                self.wm_regs[reg] = value;
            },
            else => {}, // Unknown device - ignore
        }
    }

    /// Read I2C register
    pub fn read(self: *const Self, offset: u32) u32 {
        return switch (offset) {
            I2C_CTRL => self.ctrl,
            I2C_ADDR => self.addr,
            I2C_DATA0 => self.data[0],
            I2C_DATA1 => self.data[1],
            I2C_DATA2 => self.data[2],
            I2C_DATA3 => self.data[3],
            I2C_STATUS => self.status,
            else => 0,
        };
    }

    /// Write I2C register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        switch (offset) {
            I2C_CTRL => {
                self.ctrl = value;
                // Check for start condition
                if ((value & 0x80) != 0) {
                    self.executeTransfer();
                }
            },
            I2C_ADDR => self.addr = value,
            I2C_DATA0 => self.data[0] = value,
            I2C_DATA1 => self.data[1] = value,
            I2C_DATA2 => self.data[2] = value,
            I2C_DATA3 => self.data[3] = value,
            I2C_STATUS => {
                // Writing clears status bits
                self.status &= ~(value & 0xFF);
            },
            else => {},
        }
    }

    /// Execute I2C transfer based on control register
    fn executeTransfer(self: *Self) void {
        const slave_addr: u8 = @truncate(self.addr & 0x7F);
        const is_read = (self.addr & 0x80) != 0;

        // Set busy, then immediately complete (no real I2C timing)
        self.status = STATUS_BUSY;

        if (is_read) {
            // Read operation - fill data registers from device
            const reg_addr = self.current_reg;
            self.data[0] = self.i2cDeviceRead(slave_addr, reg_addr);
            self.data[1] = self.i2cDeviceRead(slave_addr, reg_addr +% 1);
            self.data[2] = self.i2cDeviceRead(slave_addr, reg_addr +% 2);
            self.data[3] = self.i2cDeviceRead(slave_addr, reg_addr +% 3);
        } else {
            // Write operation - first byte is register address
            self.current_reg = @truncate(self.data[0] & 0xFF);

            // Check if there's more data to write
            const data_len = (self.ctrl >> 8) & 0xF;
            if (data_len > 1) {
                // Write remaining bytes to device
                var i: u8 = 1;
                while (i < data_len) : (i += 1) {
                    const data_byte = switch (i) {
                        1 => @as(u8, @truncate((self.data[0] >> 8) & 0xFF)),
                        2 => @as(u8, @truncate((self.data[0] >> 16) & 0xFF)),
                        3 => @as(u8, @truncate((self.data[0] >> 24) & 0xFF)),
                        4 => @as(u8, @truncate(self.data[1] & 0xFF)),
                        else => 0,
                    };
                    self.i2cDeviceWrite(slave_addr, self.current_reg +% (i - 1), data_byte);
                }
            }
        }

        // Transfer complete with ACK (not busy, ACK received)
        self.status = STATUS_ACK;
    }

    /// Get WM8758 left DAC volume (0-255)
    pub fn getWm8758VolumeLeft(self: *const Self) u8 {
        return @truncate(self.wm_regs[0x0A] & 0xFF);
    }

    /// Get WM8758 right DAC volume (0-255)
    pub fn getWm8758VolumeRight(self: *const Self) u8 {
        return @truncate(self.wm_regs[0x0B] & 0xFF);
    }

    /// Get WM8758 master volume as a fraction (0.0 to 1.0)
    pub fn getWm8758VolumeFraction(self: *const Self) f32 {
        const left = self.getWm8758VolumeLeft();
        const right = self.getWm8758VolumeRight();
        // Average the two channels, normalize to 0.0-1.0
        const avg: f32 = @as(f32, @floatFromInt(left)) + @as(f32, @floatFromInt(right));
        return avg / 510.0; // 255 * 2 = 510
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
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.read(offset);
    }

    fn writeHandler(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write(offset, value);
    }
};

// Tests
test "I2C controller initialization" {
    const i2c = I2cController.init();
    try std.testing.expectEqual(@as(u32, STATUS_ACK), i2c.status);
}

test "I2C read PCF50605 ID" {
    var i2c = I2cController.init();

    // Set address to PCF50605 + read
    i2c.addr = I2C_ADDR_PCF50605 | 0x80;
    i2c.data[0] = 0x00; // Register 0 (ID)
    i2c.current_reg = 0;

    // Trigger read
    i2c.write(I2C_CTRL, 0x80);

    // Check result
    try std.testing.expectEqual(@as(u32, 0x35), i2c.data[0]);
    try std.testing.expectEqual(@as(u32, STATUS_ACK), i2c.status);
}

test "I2C write PCF50605 register" {
    var i2c = I2cController.init();

    // Set address to PCF50605 + write
    i2c.addr = I2C_ADDR_PCF50605;
    i2c.data[0] = 0x4205; // Register 0x05, value 0x42
    i2c.ctrl = 0x0280; // Start + 2 bytes

    i2c.executeTransfer();

    // Check that register was written
    try std.testing.expectEqual(@as(u8, 0x42), i2c.pcf_regs[0x05]);
}
