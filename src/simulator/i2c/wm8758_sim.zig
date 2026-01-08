//! WM8758 Audio Codec Simulation
//!
//! Simulates the Wolfson WM8758 audio codec for the PP5021C simulator.
//! Tracks register state, power state, volume, and mute settings.

const std = @import("std");

/// WM8758 register addresses (from codec driver)
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

/// I2C address of WM8758
pub const I2C_ADDRESS: u7 = 0x1A;

/// Number of registers
pub const NUM_REGISTERS: usize = 64;

/// Power state
pub const PowerState = enum {
    off,
    standby,
    active,
};

/// WM8758 Codec Simulation
pub const Wm8758Sim = struct {
    /// Register values (9-bit registers stored as 16-bit)
    registers: [NUM_REGISTERS]u16 = [_]u16{0} ** NUM_REGISTERS,
    /// Current power state
    power_state: PowerState = .off,
    /// Muted flag
    muted: bool = true,
    /// Left volume in dB (-89 to +6)
    volume_left_db: i16 = -89,
    /// Right volume in dB
    volume_right_db: i16 = -89,
    /// Sample rate
    sample_rate: u32 = 44100,
    /// DAC enabled
    dac_enabled: bool = false,
    /// Output enabled
    output_enabled: bool = false,

    const Self = @This();

    /// Create a new codec simulation
    pub fn init() Self {
        var self = Self{};
        self.reset();
        return self;
    }

    /// Reset to power-on state
    pub fn reset(self: *Self) void {
        // Clear all registers to default
        @memset(&self.registers, 0);

        // Set default register values
        self.registers[Reg.PWRMGMT1] = 0x000;
        self.registers[Reg.PWRMGMT2] = 0x000;
        self.registers[Reg.PWRMGMT3] = 0x000;
        self.registers[Reg.AINTFCE] = 0x050; // Default I2S format
        self.registers[Reg.CLKCTRL] = 0x000;
        self.registers[Reg.LOUT1VOL] = 0x039; // -73dB muted
        self.registers[Reg.ROUT1VOL] = 0x039;
        self.registers[Reg.DACCTRL] = 0x000;

        self.power_state = .off;
        self.muted = true;
        self.volume_left_db = -89;
        self.volume_right_db = -89;
        self.dac_enabled = false;
        self.output_enabled = false;
    }

    /// Write to a register (WM8758 uses 7-bit addr + 9-bit data)
    /// I2C format: [addr<<1 | data[8], data[7:0]]
    pub fn writeRegI2c(self: *Self, byte1: u8, byte2: u8) void {
        const addr = byte1 >> 1;
        const data = (@as(u16, byte1 & 0x01) << 8) | @as(u16, byte2);

        self.writeReg(addr, data);
    }

    /// Write to a register directly
    pub fn writeReg(self: *Self, addr: u8, data: u16) void {
        if (addr >= NUM_REGISTERS) return;

        // Handle reset specially
        if (addr == Reg.RESET) {
            self.reset();
            return;
        }

        self.registers[addr] = data & 0x1FF; // 9-bit registers

        // Update internal state based on register written
        self.updateState(addr);
    }

    /// Read a register
    pub fn readReg(self: *const Self, addr: u8) u16 {
        if (addr >= NUM_REGISTERS) return 0;
        return self.registers[addr];
    }

    /// Update internal state based on register change
    fn updateState(self: *Self, addr: u8) void {
        switch (addr) {
            Reg.PWRMGMT1 => {
                const val = self.registers[addr];
                // Check VMID and bias enable
                if ((val & 0x00F) != 0) {
                    self.power_state = .standby;
                } else {
                    self.power_state = .off;
                }
            },
            Reg.PWRMGMT2 => {
                const val = self.registers[addr];
                // Check output enable
                self.output_enabled = (val & 0x180) != 0;
            },
            Reg.PWRMGMT3 => {
                const val = self.registers[addr];
                // Check DAC enable
                self.dac_enabled = (val & 0x060) != 0;
                if (self.dac_enabled and self.output_enabled) {
                    self.power_state = .active;
                }
            },
            Reg.LOUT1VOL => {
                const val = self.registers[addr];
                // Bit 6 = mute, bits 5:0 = volume (0-63, where 63 = +6dB)
                const mute_bit = (val & 0x040) != 0;
                const vol_reg = val & 0x03F;

                if (!mute_bit) {
                    // Convert register to dB: 0 = -89dB, 191 = +6dB
                    // Simplified: we store 0-63 as -89 + val
                    self.volume_left_db = @as(i16, @intCast(vol_reg)) - 89 + 26; // Approximate
                    if (self.volume_left_db > 6) self.volume_left_db = 6;
                }

                // Check update bit for immediate update
                if ((val & 0x100) != 0) {
                    self.muted = mute_bit;
                }
            },
            Reg.ROUT1VOL => {
                const val = self.registers[addr];
                const mute_bit = (val & 0x040) != 0;
                const vol_reg = val & 0x03F;

                if (!mute_bit) {
                    self.volume_right_db = @as(i16, @intCast(vol_reg)) - 89 + 26;
                    if (self.volume_right_db > 6) self.volume_right_db = 6;
                }

                if ((val & 0x100) != 0) {
                    self.muted = mute_bit;
                }
            },
            Reg.ADDCTRL => {
                const val = self.registers[addr];
                // Sample rate configuration
                self.sample_rate = switch (val & 0x1F) {
                    0x00 => 48000,
                    0x02 => 32000,
                    0x04 => 24000,
                    0x06 => 16000,
                    0x08 => 12000,
                    0x0A => 8000,
                    0x17 => 44100,
                    0x19 => 11025,
                    0x1B => 22050,
                    else => 44100,
                };
            },
            else => {},
        }
    }

    /// Get current volume in dB
    pub fn getVolume(self: *const Self) struct { left: i16, right: i16 } {
        return .{
            .left = self.volume_left_db,
            .right = self.volume_right_db,
        };
    }

    /// Check if codec is active and producing audio
    pub fn isActive(self: *const Self) bool {
        return self.power_state == .active and !self.muted and self.dac_enabled;
    }

    /// Get formatted status string for debugging
    pub fn getStatusString(self: *const Self, buffer: []u8) []u8 {
        const state_str = switch (self.power_state) {
            .off => "OFF",
            .standby => "STANDBY",
            .active => "ACTIVE",
        };

        const result = std.fmt.bufPrint(buffer, "WM8758: {s} Vol L:{d}dB R:{d}dB Mute:{}", .{
            state_str,
            self.volume_left_db,
            self.volume_right_db,
            self.muted,
        }) catch return buffer[0..0];

        return result;
    }
};

// ============================================================
// Tests
// ============================================================

test "wm8758 init and reset" {
    var codec = Wm8758Sim.init();

    try std.testing.expectEqual(PowerState.off, codec.power_state);
    try std.testing.expect(codec.muted);

    // Write some registers
    codec.writeReg(Reg.PWRMGMT1, 0x00D);
    try std.testing.expectEqual(PowerState.standby, codec.power_state);

    // Reset should restore defaults
    codec.writeReg(Reg.RESET, 0);
    try std.testing.expectEqual(PowerState.off, codec.power_state);
}

test "wm8758 power sequence" {
    var codec = Wm8758Sim.init();

    // Enable VMID and bias
    codec.writeReg(Reg.PWRMGMT1, 0x00D);
    try std.testing.expectEqual(PowerState.standby, codec.power_state);

    // Enable outputs
    codec.writeReg(Reg.PWRMGMT2, 0x180);
    try std.testing.expect(codec.output_enabled);

    // Enable DAC
    codec.writeReg(Reg.PWRMGMT3, 0x060);
    try std.testing.expect(codec.dac_enabled);
    try std.testing.expectEqual(PowerState.active, codec.power_state);
}

test "wm8758 volume control" {
    var codec = Wm8758Sim.init();

    // Power up the codec
    codec.writeReg(Reg.PWRMGMT1, 0x00D);
    codec.writeReg(Reg.PWRMGMT2, 0x180);
    codec.writeReg(Reg.PWRMGMT3, 0x060);

    // Set volume (register value + update bit + no mute)
    codec.writeReg(Reg.LOUT1VOL, 0x13F); // Update + no mute + max vol
    codec.writeReg(Reg.ROUT1VOL, 0x13F);

    try std.testing.expect(!codec.muted);
    try std.testing.expect(codec.isActive());
}

test "wm8758 i2c write format" {
    var codec = Wm8758Sim.init();

    // WM8758 I2C format: [addr<<1 | data[8], data[7:0]]
    // Write PWRMGMT1 (0x01) with value 0x00D
    // byte1 = 0x01 << 1 | (0x00D >> 8) = 0x02 | 0 = 0x02
    // byte2 = 0x0D
    codec.writeRegI2c(0x02, 0x0D);

    try std.testing.expectEqual(@as(u16, 0x00D), codec.readReg(Reg.PWRMGMT1));
    try std.testing.expectEqual(PowerState.standby, codec.power_state);
}

test "wm8758 sample rate" {
    var codec = Wm8758Sim.init();

    codec.writeReg(Reg.ADDCTRL, 0x17); // 44100 Hz
    try std.testing.expectEqual(@as(u32, 44100), codec.sample_rate);

    codec.writeReg(Reg.ADDCTRL, 0x00); // 48000 Hz
    try std.testing.expectEqual(@as(u32, 48000), codec.sample_rate);

    codec.writeReg(Reg.ADDCTRL, 0x1B); // 22050 Hz
    try std.testing.expectEqual(@as(u32, 22050), codec.sample_rate);
}

test "wm8758 mute control" {
    var codec = Wm8758Sim.init();

    // Unmute with update
    codec.writeReg(Reg.LOUT1VOL, 0x139); // Update + unmute + some vol
    try std.testing.expect(!codec.muted);

    // Mute
    codec.writeReg(Reg.LOUT1VOL, 0x140); // Update + mute
    try std.testing.expect(codec.muted);
}
