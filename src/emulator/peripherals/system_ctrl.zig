//! PP5021C System Controller
//!
//! Implements device enable, reset, and clock control.
//!
//! Reference: Rockbox firmware/export/pp5020.h
//!
//! Registers (base 0x60006000):
//! - 0x04: DEV_RS - Device reset (write 1 to reset)
//! - 0x08: DEV_RS2 - Device reset 2
//! - 0x0C: DEV_EN - Device enable (write 1 to enable)
//! - 0x10: DEV_EN2 - Device enable 2
//! - 0x20: CLOCK_SOURCE - Clock source selection
//! - 0x34: PLL_CONTROL - PLL configuration
//! - 0x38: PLL_DIV - PLL divider
//! - 0x3C: PLL_STATUS - PLL lock status (read-only)
//! - 0x40: DEV_INIT1 - Device init 1
//! - 0x44: DEV_INIT2 - Device init 2
//! - 0x80: CACHE_CTL - Cache control
//!
//! Additional registers for hardware identification:
//! - 0x00: Chip ID / Revision

const std = @import("std");
const bus = @import("../memory/bus.zig");

/// Device enable bits (DEV_EN)
pub const Device = enum(u5) {
    timer1 = 0,
    timer2 = 1,
    i2c = 2,
    i2s = 3,
    lcd = 4,
    firewire = 5,
    usb0 = 6,
    usb1 = 7,
    ide0 = 8,
    ide1 = 9,
    cop = 24, // Second CPU core
    // ... other devices

    pub fn mask(self: Device) u32 {
        return @as(u32, 1) << @intFromEnum(self);
    }
};

/// System Controller
pub const SystemController = struct {
    /// Device reset registers
    dev_rs: u32,
    dev_rs2: u32,

    /// Device enable registers
    dev_en: u32,
    dev_en2: u32,

    /// Device init registers
    dev_init1: u32,
    dev_init2: u32,

    /// Clock configuration
    clock_source: u32,
    pll_control: u32,
    pll_div: u32,
    pll_mult: u32,
    clock_status: u32,

    /// Cache control
    cache_ctl: u32,

    /// Device reset callback (called when a device is reset)
    reset_callback: ?*const fn (Device) void,

    /// Device enable callback (called when device enable changes)
    enable_callback: ?*const fn (Device, bool) void,

    const Self = @This();

    /// Register offsets (PP5020/PP5021C)
    const REG_CHIP_ID: u32 = 0x00;
    const REG_DEV_RS: u32 = 0x04;
    const REG_DEV_RS2: u32 = 0x08;
    const REG_DEV_EN: u32 = 0x0C;
    const REG_DEV_EN2: u32 = 0x10;
    const REG_CLOCK_SOURCE: u32 = 0x20;
    const REG_PLL_CONTROL: u32 = 0x34;
    const REG_PLL_DIV: u32 = 0x38;
    const REG_PLL_STATUS: u32 = 0x3C;
    const REG_DEV_INIT1: u32 = 0x40;
    const REG_DEV_INIT2: u32 = 0x44;
    const REG_CACHE_CTL: u32 = 0x80;

    /// PP5021C Chip ID (returned by hardware)
    const CHIP_ID_PP5021C: u32 = 0x5021C;

    /// Default PLL status indicating PLL is locked and stable
    const DEFAULT_PLL_STATUS: u32 = 0x80000000; // Bit 31 = PLL locked

    pub fn init() Self {
        return .{
            .dev_rs = 0,
            .dev_rs2 = 0,
            .dev_en = 0,
            .dev_en2 = 0,
            .dev_init1 = 0,
            .dev_init2 = 0,
            .clock_source = 0,
            .pll_control = 0,
            .pll_div = 1,
            .pll_mult = 1,
            .clock_status = DEFAULT_PLL_STATUS,
            .cache_ctl = 0,
            .reset_callback = null,
            .enable_callback = null,
        };
    }

    /// Set reset callback
    pub fn setResetCallback(self: *Self, callback: *const fn (Device) void) void {
        self.reset_callback = callback;
    }

    /// Set enable callback
    pub fn setEnableCallback(self: *Self, callback: *const fn (Device, bool) void) void {
        self.enable_callback = callback;
    }

    /// Check if device is enabled
    pub fn isEnabled(self: *const Self, device: Device) bool {
        return (self.dev_en & device.mask()) != 0;
    }

    /// Enable a device
    pub fn enableDevice(self: *Self, device: Device) void {
        const mask = device.mask();
        if ((self.dev_en & mask) == 0) {
            self.dev_en |= mask;
            if (self.enable_callback) |callback| {
                callback(device, true);
            }
        }
    }

    /// Disable a device
    pub fn disableDevice(self: *Self, device: Device) void {
        const mask = device.mask();
        if ((self.dev_en & mask) != 0) {
            self.dev_en &= ~mask;
            if (self.enable_callback) |callback| {
                callback(device, false);
            }
        }
    }

    /// Reset a device
    pub fn resetDevice(self: *Self, device: Device) void {
        if (self.reset_callback) |callback| {
            callback(device);
        }
    }

    /// Get calculated CPU frequency in MHz
    pub fn getCpuFreqMhz(self: *const Self) u32 {
        // Default to 80 MHz if PLL not configured
        if (self.pll_div == 0) return 80;

        // Calculate frequency based on PLL settings
        // Base frequency is typically 24 MHz crystal
        const base_freq: u32 = 24;
        const mult = if (self.pll_mult == 0) 1 else self.pll_mult;
        const div = if (self.pll_div == 0) 1 else self.pll_div;

        return (base_freq * mult) / div;
    }

    /// Read register
    pub fn read(self: *const Self, offset: u32) u32 {
        return switch (offset) {
            REG_CHIP_ID => CHIP_ID_PP5021C,
            REG_DEV_RS => self.dev_rs,
            REG_DEV_RS2 => self.dev_rs2,
            REG_DEV_EN => self.dev_en,
            REG_DEV_EN2 => self.dev_en2,
            REG_CLOCK_SOURCE => self.clock_source,
            REG_PLL_CONTROL => self.pll_control,
            REG_PLL_DIV => self.pll_div,
            REG_PLL_STATUS => self.clock_status, // PLL locked status
            REG_DEV_INIT1 => self.dev_init1,
            REG_DEV_INIT2 => self.dev_init2,
            REG_CACHE_CTL => self.cache_ctl,
            else => 0,
        };
    }

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        switch (offset) {
            REG_DEV_RS => {
                self.dev_rs = value;
                // Trigger resets for each bit that is set
                var bits = value;
                while (bits != 0) {
                    const bit: u5 = @intCast(@ctz(bits));
                    if (self.reset_callback) |callback| {
                        callback(@enumFromInt(bit));
                    }
                    bits &= bits - 1; // Clear lowest bit
                }
            },
            REG_DEV_RS2 => {
                self.dev_rs2 = value;
            },
            REG_DEV_EN => {
                const changed = self.dev_en ^ value;
                self.dev_en = value;
                // Notify for changed devices
                if (self.enable_callback) |callback| {
                    var bits = changed;
                    while (bits != 0) {
                        const bit: u5 = @intCast(@ctz(bits));
                        const enabled = (value & (@as(u32, 1) << bit)) != 0;
                        callback(@enumFromInt(bit), enabled);
                        bits &= bits - 1;
                    }
                }
            },
            REG_DEV_EN2 => self.dev_en2 = value,
            REG_DEV_INIT1 => self.dev_init1 = value,
            REG_DEV_INIT2 => self.dev_init2 = value,
            REG_CLOCK_SOURCE => self.clock_source = value,
            REG_PLL_CONTROL => {
                self.pll_control = value;
                // When PLL is configured, set lock status
                self.clock_status = DEFAULT_PLL_STATUS;
            },
            REG_PLL_DIV => self.pll_div = value,
            REG_PLL_STATUS => {}, // Read-only
            REG_CACHE_CTL => self.cache_ctl = value,
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
test "device enable/disable" {
    var sys = SystemController.init();

    // Enable IDE0
    sys.write(SystemController.REG_DEV_EN, Device.ide0.mask());
    try std.testing.expect(sys.isEnabled(.ide0));
    try std.testing.expect(!sys.isEnabled(.i2s));

    // Enable I2S
    sys.write(SystemController.REG_DEV_EN, Device.ide0.mask() | Device.i2s.mask());
    try std.testing.expect(sys.isEnabled(.ide0));
    try std.testing.expect(sys.isEnabled(.i2s));
}

test "clock status" {
    const sys = SystemController.init();

    // PLL should report locked
    const status = sys.read(SystemController.REG_PLL_STATUS);
    try std.testing.expect((status & 0x80000000) != 0);
}

test "CPU frequency calculation" {
    var sys = SystemController.init();

    // Set PLL divider directly - pll_mult defaults to 1
    // 24 * 1 / 1 = 24 MHz with defaults
    try std.testing.expectEqual(@as(u32, 24), sys.getCpuFreqMhz());

    // Manually set the internal mult/div for testing
    sys.pll_mult = 10;
    sys.pll_div = 3;
    // 24 * 10 / 3 = 80 MHz
    try std.testing.expectEqual(@as(u32, 80), sys.getCpuFreqMhz());
}
