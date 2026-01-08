//! PCF50605 Power Management Unit Driver
//!
//! This driver controls the Philips PCF50605 PMU used in iPod Video.
//! CRITICAL: Use only verified voltage values from Rockbox to avoid hardware damage.

const std = @import("std");
const hal = @import("../hal/hal.zig");
const i2c = @import("i2c.zig");

// ============================================================
// PCF50605 Constants
// ============================================================

/// I2C address of PCF50605
pub const I2C_ADDRESS: u7 = 0x08;

/// Register addresses
pub const Reg = struct {
    pub const OOCC1: u8 = 0x08; // On/off control
    pub const IOREGC: u8 = 0x26; // I/O regulator (3.0V)
    pub const DCDC1: u8 = 0x1E; // Core voltage 1
    pub const DCDC2: u8 = 0x1F; // Core voltage 2
    pub const DCUDC1: u8 = 0x20; // Unknown DC-DC
    pub const D1REGC1: u8 = 0x21; // Codec voltage
    pub const D2REGC1: u8 = 0x22; // Accessory voltage
    pub const D3REGC1: u8 = 0x23; // LCD/ATA voltage
    pub const LPREGC1: u8 = 0x24; // Low-power regulator
    pub const INT1: u8 = 0x02; // Interrupt status 1
    pub const INT2: u8 = 0x03; // Interrupt status 2
    pub const INT3: u8 = 0x04; // Interrupt status 3
};

/// OOCC1 control bits
pub const OOCC1_GOSTDBY: u8 = 0x01;
pub const OOCC1_CHGWAK: u8 = 0x02;
pub const OOCC1_EXTONWAK: u8 = 0x04;

// ============================================================
// Verified Safe Voltage Values (from Rockbox)
// ============================================================

/// VERIFIED SAFE voltage configuration for iPod Video
/// DO NOT MODIFY without understanding consequences!
pub const SafeConfig = struct {
    pub const IOREGC: u8 = 0x15; // 3.0V ON
    pub const DCDC1: u8 = 0x08; // 1.2V ON
    pub const DCDC2: u8 = 0x00; // OFF
    pub const DCUDC1: u8 = 0x0C; // 1.8V ON
    pub const D1REGC1: u8 = 0x11; // 2.5V ON (codec)
    pub const D3REGC1: u8 = 0x13; // 2.6V ON (LCD/ATA)
};

// ============================================================
// PMU Driver
// ============================================================

var device: i2c.I2cDevice = undefined;
var initialized: bool = false;

/// Initialize the PMU with safe defaults
pub fn init() hal.HalError!void {
    device = i2c.I2cDevice.init(I2C_ADDRESS);

    // Apply safe voltage configuration
    // Order matters! Apply in specific sequence.

    // I/O voltage first
    try device.writeReg8(Reg.IOREGC, SafeConfig.IOREGC);
    hal.delayMs(5);

    // Core voltages
    try device.writeReg8(Reg.DCDC1, SafeConfig.DCDC1);
    hal.delayMs(5);

    try device.writeReg8(Reg.DCDC2, SafeConfig.DCDC2);
    hal.delayMs(5);

    try device.writeReg8(Reg.DCUDC1, SafeConfig.DCUDC1);
    hal.delayMs(5);

    // Codec voltage
    try device.writeReg8(Reg.D1REGC1, SafeConfig.D1REGC1);
    hal.delayMs(5);

    // LCD/ATA voltage
    try device.writeReg8(Reg.D3REGC1, SafeConfig.D3REGC1);
    hal.delayMs(10);

    initialized = true;
}

/// Read a PMU register
pub fn readReg(reg: u8) hal.HalError!u8 {
    if (!initialized) return hal.HalError.DeviceNotReady;
    return device.readReg8(reg);
}

/// Write a PMU register
/// WARNING: Writing incorrect values can damage hardware!
pub fn writeReg(reg: u8, value: u8) hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;
    try device.writeReg8(reg, value);
}

/// Enter standby mode (power off)
pub fn standby() hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;

    // Enable wake sources and enter standby
    const standby_val = OOCC1_GOSTDBY | OOCC1_CHGWAK | OOCC1_EXTONWAK;
    try device.writeReg8(Reg.OOCC1, standby_val);
}

/// Check if charger is connected
pub fn chargerConnected() hal.HalError!bool {
    if (!initialized) return hal.HalError.DeviceNotReady;
    // Read interrupt status to check charger
    const int1 = try device.readReg8(Reg.INT1);
    return (int1 & 0x04) != 0;
}

/// Clear interrupt flags
pub fn clearInterrupts() hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;
    // Read all interrupt registers to clear them
    _ = try device.readReg8(Reg.INT1);
    _ = try device.readReg8(Reg.INT2);
    _ = try device.readReg8(Reg.INT3);
}

/// Get wakeup source after resume
pub fn getWakeupSource() hal.HalError!WakeupSource {
    if (!initialized) return hal.HalError.DeviceNotReady;

    const int1 = try device.readReg8(Reg.INT1);

    if ((int1 & 0x04) != 0) return .charger;
    if ((int1 & 0x02) != 0) return .button;
    if ((int1 & 0x01) != 0) return .alarm;
    return .unknown;
}

pub const WakeupSource = enum {
    unknown,
    button,
    charger,
    alarm,
};

// ============================================================
// Tests
// ============================================================

test "PMU safe config values" {
    // Verify our safe values match expected patterns
    try std.testing.expectEqual(@as(u8, 0x15), SafeConfig.IOREGC);
    try std.testing.expectEqual(@as(u8, 0x08), SafeConfig.DCDC1);
    try std.testing.expectEqual(@as(u8, 0x00), SafeConfig.DCDC2);
}
