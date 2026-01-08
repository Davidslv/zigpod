//! PCF50605 Power Management Unit Simulation
//!
//! Simulates the Philips PCF50605 PMU for the PP5021C simulator.
//! Tracks power state, voltage regulators, ADC, and interrupts.

const std = @import("std");

/// PCF50605 register addresses (from pmu driver)
pub const Reg = struct {
    pub const INT1: u8 = 0x02;
    pub const INT2: u8 = 0x03;
    pub const INT3: u8 = 0x04;
    pub const OOCC1: u8 = 0x08;
    pub const DCDC1: u8 = 0x1E;
    pub const DCDC2: u8 = 0x1F;
    pub const DCUDC1: u8 = 0x20;
    pub const D1REGC1: u8 = 0x21;
    pub const D2REGC1: u8 = 0x22;
    pub const D3REGC1: u8 = 0x23;
    pub const LPREGC1: u8 = 0x24;
    pub const IOREGC: u8 = 0x26;
    pub const ADC: u8 = 0x30;
    pub const ADC_RESULT_H: u8 = 0x31;
    pub const ADC_RESULT_L: u8 = 0x32;
};

/// I2C address of PCF50605
pub const I2C_ADDRESS: u7 = 0x08;

/// Number of registers
pub const NUM_REGISTERS: usize = 64;

/// OOCC1 control bits
pub const OOCC1_GOSTDBY: u8 = 0x01;
pub const OOCC1_CHGWAK: u8 = 0x02;
pub const OOCC1_EXTONWAK: u8 = 0x04;

/// ADC channels
pub const AdcChannel = enum(u8) {
    battery = 0,
    temperature = 1,
    charger_current = 2,
};

/// Power state
pub const PowerState = enum {
    off,
    standby,
    running,
};

/// Charging state
pub const ChargingState = enum {
    not_connected,
    charging,
    charged,
};

/// PCF50605 PMU Simulation
pub const Pcf50605Sim = struct {
    /// Register values
    registers: [NUM_REGISTERS]u8 = [_]u8{0} ** NUM_REGISTERS,
    /// Current power state
    power_state: PowerState = .off,
    /// Charging state
    charging_state: ChargingState = .not_connected,
    /// Battery voltage in millivolts
    battery_mv: u16 = 4200,
    /// Temperature (simulated, in tenths of degrees C)
    temperature_c10: i16 = 250, // 25.0C
    /// USB connected
    usb_connected: bool = false,
    /// Charger connected
    charger_connected: bool = false,
    /// ADC conversion result
    adc_result: u16 = 0,
    /// ADC channel being converted
    adc_channel: u8 = 0,
    /// Interrupt flags set
    int1_flags: u8 = 0,
    int2_flags: u8 = 0,
    int3_flags: u8 = 0,

    const Self = @This();

    /// Create a new PMU simulation
    pub fn init() Self {
        var self = Self{};
        self.reset();
        return self;
    }

    /// Reset to power-on state
    pub fn reset(self: *Self) void {
        @memset(&self.registers, 0);

        // Set default register values (safe config from pmu.zig)
        self.registers[Reg.IOREGC] = 0x15; // 3.0V ON
        self.registers[Reg.DCDC1] = 0x08; // 1.2V ON
        self.registers[Reg.DCDC2] = 0x00; // OFF
        self.registers[Reg.DCUDC1] = 0x0C; // 1.8V ON
        self.registers[Reg.D1REGC1] = 0x11; // 2.5V ON (codec)
        self.registers[Reg.D3REGC1] = 0x13; // 2.6V ON (LCD/ATA)

        self.power_state = .running;
        self.charging_state = .not_connected;
        self.battery_mv = 4200;
        self.temperature_c10 = 250;
        self.usb_connected = false;
        self.charger_connected = false;
        self.int1_flags = 0;
        self.int2_flags = 0;
        self.int3_flags = 0;
    }

    /// Write to a register
    pub fn writeReg(self: *Self, addr: u8, value: u8) void {
        if (addr >= NUM_REGISTERS) return;

        self.registers[addr] = value;

        // Handle special registers
        switch (addr) {
            Reg.OOCC1 => {
                // Check for standby command
                if ((value & OOCC1_GOSTDBY) != 0) {
                    self.power_state = .standby;
                }
            },
            Reg.ADC => {
                // Start ADC conversion
                if ((value & 0x80) != 0) {
                    self.adc_channel = value & 0x0F;
                    self.performAdcConversion();
                }
            },
            else => {},
        }
    }

    /// Read a register
    pub fn readReg(self: *Self, addr: u8) u8 {
        if (addr >= NUM_REGISTERS) return 0;

        // Handle interrupt registers (reading clears them)
        switch (addr) {
            Reg.INT1 => {
                const val = self.int1_flags;
                self.int1_flags = 0;
                return val;
            },
            Reg.INT2 => {
                const val = self.int2_flags;
                self.int2_flags = 0;
                return val;
            },
            Reg.INT3 => {
                const val = self.int3_flags;
                self.int3_flags = 0;
                return val;
            },
            Reg.ADC_RESULT_H => {
                return @truncate(self.adc_result >> 2);
            },
            Reg.ADC_RESULT_L => {
                return @truncate((self.adc_result & 0x03) << 6);
            },
            else => return self.registers[addr],
        }
    }

    /// Perform ADC conversion
    fn performAdcConversion(self: *Self) void {
        self.adc_result = switch (self.adc_channel) {
            0 => self.getBatteryAdcValue(), // battery
            1 => self.getTemperatureAdcValue(), // temperature
            2 => if (self.charging_state == .charging) @as(u16, 512) else @as(u16, 0), // charger_current
            else => 0,
        };
    }

    /// Convert battery voltage to ADC value (10-bit)
    fn getBatteryAdcValue(self: *const Self) u16 {
        // Simplified conversion: 0-4200mV maps to 0-1023
        // Use u32 to avoid overflow
        const mv32: u32 = self.battery_mv;
        return @intCast(@min(@as(u32, 1023), mv32 * 1023 / 4200));
    }

    /// Convert temperature to ADC value
    fn getTemperatureAdcValue(self: *const Self) u16 {
        // Simplified: 0C = 512, increases with temperature
        const offset: i32 = @divTrunc(@as(i32, self.temperature_c10), 10);
        const adc_val: i32 = 512 + offset * 4;
        return @intCast(std.math.clamp(adc_val, 0, 1023));
    }

    // --------------------------------------------------------
    // Simulation control
    // --------------------------------------------------------

    /// Set battery voltage (for simulation)
    pub fn setBatteryVoltage(self: *Self, mv: u16) void {
        self.battery_mv = @min(4200, mv);

        // Set low battery interrupt if below threshold
        if (mv < 3300) {
            self.int1_flags |= 0x01; // Low battery
        }
    }

    /// Set temperature (for simulation)
    pub fn setTemperature(self: *Self, temp_c10: i16) void {
        self.temperature_c10 = temp_c10;

        // Set temperature warning if too high
        if (temp_c10 > 450) { // > 45C
            self.int2_flags |= 0x01;
        }
    }

    /// Connect/disconnect USB
    pub fn setUsbConnected(self: *Self, connected: bool) void {
        const was_connected = self.usb_connected;
        self.usb_connected = connected;

        if (connected and !was_connected) {
            self.int1_flags |= 0x10; // USB connect
        } else if (!connected and was_connected) {
            self.int1_flags |= 0x20; // USB disconnect
        }
    }

    /// Connect/disconnect charger
    pub fn setChargerConnected(self: *Self, connected: bool) void {
        const was_connected = self.charger_connected;
        self.charger_connected = connected;

        if (connected and !was_connected) {
            self.int1_flags |= 0x04; // Charger connect
            self.charging_state = .charging;
        } else if (!connected and was_connected) {
            self.charging_state = .not_connected;
        }
    }

    /// Simulate charging (call periodically)
    pub fn tickCharging(self: *Self, ms: u32) void {
        if (self.charging_state == .charging) {
            // Simple charge simulation: ~1mV per 10ms when charging
            const charge_amount = @min(4200 - self.battery_mv, ms / 10);
            self.battery_mv += @as(u16, @intCast(charge_amount));

            if (self.battery_mv >= 4200) {
                self.charging_state = .charged;
                self.int1_flags |= 0x08; // Charge complete
            }
        }
    }

    /// Wake from standby
    pub fn wakeUp(self: *Self) void {
        if (self.power_state == .standby) {
            self.power_state = .running;
            self.int1_flags |= 0x02; // Button wake
        }
    }

    /// Check if running
    pub fn isRunning(self: *const Self) bool {
        return self.power_state == .running;
    }

    /// Get battery percentage (0-100)
    pub fn getBatteryPercent(self: *const Self) u8 {
        // Simple linear mapping: 3000-4200mV = 0-100%
        if (self.battery_mv <= 3000) return 0;
        if (self.battery_mv >= 4200) return 100;
        return @intCast((self.battery_mv - 3000) * 100 / 1200);
    }

    /// Get regulator voltage for a given register
    pub fn getRegulatorVoltage(self: *const Self, reg: u8) ?u16 {
        const val = self.registers[reg];
        const enabled = (val & 0x10) != 0;
        if (!enabled) return null;

        // Voltage depends on register
        return switch (reg) {
            Reg.IOREGC => 3000, // 3.0V
            Reg.DCDC1 => 1200, // 1.2V
            Reg.DCUDC1 => 1800, // 1.8V
            Reg.D1REGC1 => 2500, // 2.5V (codec)
            Reg.D3REGC1 => 2600, // 2.6V (LCD/ATA)
            else => null,
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "pcf50605 init and reset" {
    var pmu = Pcf50605Sim.init();

    try std.testing.expectEqual(PowerState.running, pmu.power_state);
    try std.testing.expectEqual(@as(u16, 4200), pmu.battery_mv);

    // Check default register values
    try std.testing.expectEqual(@as(u8, 0x15), pmu.readReg(Reg.IOREGC));
    try std.testing.expectEqual(@as(u8, 0x08), pmu.readReg(Reg.DCDC1));
}

test "pcf50605 standby" {
    var pmu = Pcf50605Sim.init();

    // Enter standby
    pmu.writeReg(Reg.OOCC1, OOCC1_GOSTDBY);
    try std.testing.expectEqual(PowerState.standby, pmu.power_state);

    // Wake up
    pmu.wakeUp();
    try std.testing.expectEqual(PowerState.running, pmu.power_state);
}

test "pcf50605 battery adc" {
    var pmu = Pcf50605Sim.init();

    // Full battery
    pmu.setBatteryVoltage(4200);
    pmu.writeReg(Reg.ADC, 0x80); // Start battery ADC

    const high = pmu.readReg(Reg.ADC_RESULT_H);
    const low = pmu.readReg(Reg.ADC_RESULT_L);
    const result = (@as(u16, high) << 2) | (@as(u16, low) >> 6);

    try std.testing.expectEqual(@as(u16, 1023), result);
}

test "pcf50605 charging" {
    var pmu = Pcf50605Sim.init();

    pmu.setBatteryVoltage(3500);
    pmu.setChargerConnected(true);

    try std.testing.expectEqual(ChargingState.charging, pmu.charging_state);

    // Simulate charging for "12 seconds" (will add ~1200mV)
    pmu.tickCharging(12000);

    // Should be fully charged
    try std.testing.expectEqual(@as(u16, 4200), pmu.battery_mv);
    try std.testing.expectEqual(ChargingState.charged, pmu.charging_state);
}

test "pcf50605 interrupts" {
    var pmu = Pcf50605Sim.init();

    // Set low battery
    pmu.setBatteryVoltage(3200);
    try std.testing.expect((pmu.int1_flags & 0x01) != 0);

    // Reading clears interrupt
    _ = pmu.readReg(Reg.INT1);
    try std.testing.expectEqual(@as(u8, 0), pmu.int1_flags);
}

test "pcf50605 usb connection" {
    var pmu = Pcf50605Sim.init();

    pmu.setUsbConnected(true);
    try std.testing.expect(pmu.usb_connected);
    try std.testing.expect((pmu.int1_flags & 0x10) != 0);
}

test "pcf50605 battery percent" {
    var pmu = Pcf50605Sim.init();

    pmu.setBatteryVoltage(4200);
    try std.testing.expectEqual(@as(u8, 100), pmu.getBatteryPercent());

    pmu.setBatteryVoltage(3600);
    try std.testing.expectEqual(@as(u8, 50), pmu.getBatteryPercent());

    pmu.setBatteryVoltage(3000);
    try std.testing.expectEqual(@as(u8, 0), pmu.getBatteryPercent());
}

test "pcf50605 temperature" {
    var pmu = Pcf50605Sim.init();

    // Room temperature (25C)
    pmu.setTemperature(250);
    pmu.writeReg(Reg.ADC, 0x81); // Start temperature ADC

    // Should be around 512 + 25*4 = 612
    const high = pmu.readReg(Reg.ADC_RESULT_H);
    const low = pmu.readReg(Reg.ADC_RESULT_L);
    const result = (@as(u16, high) << 2) | (@as(u16, low) >> 6);

    try std.testing.expect(result >= 600 and result <= 620);
}
