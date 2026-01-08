//! WM8758 Audio Codec Driver
//!
//! This driver controls the Wolfson WM8758 audio codec used in iPod Video.
//! The codec provides high-quality DAC output for audio playback.

const std = @import("std");
const hal = @import("../../hal/hal.zig");
const i2c = @import("../i2c.zig");

// ============================================================
// WM8758 Constants
// ============================================================

/// I2C address of WM8758
pub const I2C_ADDRESS: u7 = 0x1A;

/// Register addresses (7-bit)
pub const Reg = struct {
    pub const RESET: u8 = 0x00;
    pub const PWRMGMT1: u8 = 0x01;
    pub const PWRMGMT2: u8 = 0x02;
    pub const PWRMGMT3: u8 = 0x03;
    pub const AINTFCE: u8 = 0x04;
    pub const COMPCTRL: u8 = 0x05;
    pub const CLKCTRL: u8 = 0x06;
    pub const ADDCTRL: u8 = 0x07;
    pub const GPIOCTRL: u8 = 0x08;
    pub const JACKDETECTCTRL1: u8 = 0x09;
    pub const DACCTRL: u8 = 0x0A;
    pub const LDACVOL: u8 = 0x0B;
    pub const RDACVOL: u8 = 0x0C;
    pub const JACKDETECTCTRL2: u8 = 0x0D;
    pub const ADCCTRL: u8 = 0x0E;
    pub const LADCVOL: u8 = 0x0F;
    pub const RADCVOL: u8 = 0x10;
    pub const EQ1: u8 = 0x12;
    pub const EQ2: u8 = 0x13;
    pub const EQ3: u8 = 0x14;
    pub const EQ4: u8 = 0x15;
    pub const EQ5: u8 = 0x16;
    pub const DACLIMITER1: u8 = 0x18;
    pub const DACLIMITER2: u8 = 0x19;
    pub const NOTCHFILTER1: u8 = 0x1B;
    pub const NOTCHFILTER2: u8 = 0x1C;
    pub const NOTCHFILTER3: u8 = 0x1D;
    pub const NOTCHFILTER4: u8 = 0x1E;
    pub const ALCCONTROL1: u8 = 0x20;
    pub const ALCCONTROL2: u8 = 0x21;
    pub const ALCCONTROL3: u8 = 0x22;
    pub const NOISEGATE: u8 = 0x23;
    pub const PLLN: u8 = 0x24;
    pub const PLLK1: u8 = 0x25;
    pub const PLLK2: u8 = 0x26;
    pub const PLLK3: u8 = 0x27;
    pub const THREEDCTRL: u8 = 0x29;
    pub const OUT4TOADC: u8 = 0x2A;
    pub const BEEPCTRL: u8 = 0x2B;
    pub const INCTRL: u8 = 0x2C;
    pub const LINPGAVOL: u8 = 0x2D;
    pub const RINPGAVOL: u8 = 0x2E;
    pub const LADCBOOST: u8 = 0x2F;
    pub const RADCBOOST: u8 = 0x30;
    pub const OUTCTRL: u8 = 0x31;
    pub const LOUTMIX: u8 = 0x32;
    pub const ROUTMIX: u8 = 0x33;
    pub const LOUT1VOL: u8 = 0x34;
    pub const ROUT1VOL: u8 = 0x35;
    pub const LOUT2VOL: u8 = 0x36;
    pub const ROUT2VOL: u8 = 0x37;
    pub const OUT3MIX: u8 = 0x38;
    pub const OUT4MIX: u8 = 0x39;
    pub const BIASCTRL: u8 = 0x3D;
};

/// Audio interface format
pub const AudioFormat = enum(u16) {
    right_justified = 0x0000,
    left_justified = 0x0008,
    i2s = 0x0010,
    dsp = 0x0018,
};

/// Word length
pub const WordLength = enum(u16) {
    bits_16 = 0x0000,
    bits_20 = 0x0020,
    bits_24 = 0x0040,
    bits_32 = 0x0060,
};

// ============================================================
// Codec Driver
// ============================================================

var device: i2c.I2cDevice = undefined;
var initialized: bool = false;
var current_volume_l: i16 = 0;
var current_volume_r: i16 = 0;

/// Write to a WM8758 register
/// The WM8758 uses 16-bit I2C writes: [addr<<1 | data[8], data[7:0]]
fn writeCodecReg(reg: u8, value: u16) hal.HalError!void {
    const byte1 = (reg << 1) | @as(u8, @truncate(value >> 8));
    const byte2: u8 = @truncate(value);
    try device.write(&[_]u8{ byte1, byte2 });
}

/// Initialize the codec (pre-init phase)
pub fn preinit() hal.HalError!void {
    device = i2c.I2cDevice.init(I2C_ADDRESS);

    // Software reset
    try writeCodecReg(Reg.RESET, 0x000);
    hal.delayMs(10);

    // Configure low bias mode
    try writeCodecReg(Reg.BIASCTRL, 0x100);

    // Power management - enable VMID, bias, buffers
    try writeCodecReg(Reg.PWRMGMT1, 0x00D);
    hal.delayMs(5);

    // Enable output stages
    try writeCodecReg(Reg.PWRMGMT2, 0x180); // LOUT1, ROUT1 enable
    try writeCodecReg(Reg.PWRMGMT3, 0x060); // DACL, DACR enable

    // Configure audio interface - I2S, 16-bit
    try writeCodecReg(Reg.AINTFCE, @intFromEnum(AudioFormat.i2s) | @intFromEnum(WordLength.bits_16));

    // Clock control - MCLK = 256fs
    try writeCodecReg(Reg.CLKCTRL, 0x000);

    // Mute outputs initially
    try writeCodecReg(Reg.LOUT1VOL, 0x140); // Muted
    try writeCodecReg(Reg.ROUT1VOL, 0x140); // Muted

    // Configure mixer - DAC to outputs
    try writeCodecReg(Reg.LOUTMIX, 0x001); // DACL to LMIX
    try writeCodecReg(Reg.ROUTMIX, 0x001); // DACR to RMIX

    initialized = true;
}

/// Post-initialization (after I2S is ready)
pub fn postinit() hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;

    // Reduce VMID impedance for lower power
    try writeCodecReg(Reg.PWRMGMT1, 0x00C); // 500k VMID

    // Unmute DAC
    try writeCodecReg(Reg.DACCTRL, 0x000);

    // Set initial volume (moderate level)
    try setVolume(-20, -20);
}

/// Set output volume in dB (-89 to +6, in 0.5dB steps)
/// The WM8758 supports -89dB to +6dB
pub fn setVolume(left_db: i16, right_db: i16) hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;

    // Clamp to valid range (-890 to +60 in tenth-dB)
    const l_db = std.math.clamp(left_db, -89, 6);
    const r_db = std.math.clamp(right_db, -89, 6);

    // Convert dB to register value (0 = -89dB, 191 = +6dB)
    const l_reg: u16 = @intCast(l_db + 89);
    const r_reg: u16 = @intCast(r_db + 89);

    // Write with update flag (bit 8 = update both channels)
    try writeCodecReg(Reg.LOUT1VOL, l_reg | 0x100);
    try writeCodecReg(Reg.ROUT1VOL, r_reg | 0x100);

    current_volume_l = l_db;
    current_volume_r = r_db;
}

/// Get current volume setting
pub fn getVolume() struct { left: i16, right: i16 } {
    return .{ .left = current_volume_l, .right = current_volume_r };
}

/// Mute output
pub fn mute(enable: bool) hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;

    if (enable) {
        try writeCodecReg(Reg.LOUT1VOL, 0x140);
        try writeCodecReg(Reg.ROUT1VOL, 0x140);
    } else {
        try setVolume(current_volume_l, current_volume_r);
    }
}

/// Shutdown the codec
pub fn shutdown() hal.HalError!void {
    if (!initialized) return;

    // Mute outputs
    try mute(true);
    hal.delayMs(10);

    // Disable DAC
    try writeCodecReg(Reg.PWRMGMT3, 0x000);

    // Disable outputs
    try writeCodecReg(Reg.PWRMGMT2, 0x000);

    // Disable VMID
    try writeCodecReg(Reg.PWRMGMT1, 0x000);

    initialized = false;
}

/// Set bass enhancement (-6 to +9 dB)
pub fn setBass(db: i8) hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;

    const clamped = std.math.clamp(db, -6, 9);
    // Convert to register value
    const reg_val: u16 = @intCast(@as(i16, clamped + 6));
    try writeCodecReg(Reg.EQ1, reg_val | 0x100); // Low shelf
}

/// Set treble enhancement (-6 to +9 dB)
pub fn setTreble(db: i8) hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;

    const clamped = std.math.clamp(db, -6, 9);
    const reg_val: u16 = @intCast(@as(i16, clamped + 6));
    try writeCodecReg(Reg.EQ5, reg_val | 0x100); // High shelf
}

/// Configure sample rate
pub fn setSampleRate(rate: u32) hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;

    // Configure clock dividers based on sample rate
    // Assuming MCLK = 11.2896 MHz for 44.1kHz family
    // or MCLK = 12.288 MHz for 48kHz family
    const sr_config: u16 = switch (rate) {
        8000 => 0x0A,
        11025 => 0x19,
        12000 => 0x08,
        16000 => 0x06,
        22050 => 0x1B,
        24000 => 0x04,
        32000 => 0x02,
        44100 => 0x17,
        48000 => 0x00,
        else => 0x17, // Default to 44100
    };

    try writeCodecReg(Reg.ADDCTRL, sr_config);
}

// ============================================================
// Tests
// ============================================================

test "volume conversion" {
    // Test volume clamping
    try std.testing.expectEqual(@as(i16, 6), std.math.clamp(@as(i16, 10), -89, 6));
    try std.testing.expectEqual(@as(i16, -89), std.math.clamp(@as(i16, -100), -89, 6));
    try std.testing.expectEqual(@as(i16, 0), std.math.clamp(@as(i16, 0), -89, 6));
}
