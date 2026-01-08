//! Power Management Driver
//!
//! Manages system power states, battery monitoring, and sleep modes.
//! Works with the PCF50605 PMU and PP5021C power controller.

const std = @import("std");
const hal = @import("../hal/hal.zig");
const pmu = @import("pmu.zig");
const lcd = @import("display/lcd.zig");

// ============================================================
// Power States
// ============================================================

pub const PowerState = enum {
    active, // Full power, all systems running
    idle, // Reduced power, waiting for input
    sleep, // Deep sleep, audio still playing
    standby, // Ultra-low power, quick wake
    off, // Power off (requires button to wake)
};

pub const ChargingState = enum {
    not_charging,
    charging,
    charge_complete,
    fault,
};

// ============================================================
// Battery Info
// ============================================================

pub const BatteryInfo = struct {
    voltage_mv: u16 = 0, // Battery voltage in millivolts
    percentage: u8 = 0, // Estimated percentage 0-100
    charging_state: ChargingState = .not_charging,
    temperature_c: i8 = 25, // Battery temperature
    is_low: bool = false, // Below low battery threshold
    is_critical: bool = false, // Below critical threshold

    /// Get battery icon based on percentage
    pub fn getIcon(self: *const BatteryInfo) []const u8 {
        if (self.charging_state == .charging) return "[CHG]";
        if (self.percentage > 80) return "[####]";
        if (self.percentage > 60) return "[### ]";
        if (self.percentage > 40) return "[##  ]";
        if (self.percentage > 20) return "[#   ]";
        return "[!   ]";
    }

    /// Get percentage string
    pub fn formatPercentage(self: *const BatteryInfo, buffer: []u8) []u8 {
        return std.fmt.bufPrint(buffer, "{d}%", .{self.percentage}) catch buffer[0..0];
    }

    /// Estimate battery from voltage (Li-Ion discharge curve)
    pub fn estimateFromVoltage(voltage_mv: u16) u8 {
        // Li-Ion battery curve (approximate):
        // 4200mV = 100%, 3700mV = 50%, 3400mV = 10%, 3000mV = 0%
        if (voltage_mv >= 4200) return 100;
        if (voltage_mv <= 3000) return 0;

        // Linear interpolation in segments
        if (voltage_mv >= 3900) {
            // 3900-4200: 80-100%
            return 80 + @as(u8, @intCast((voltage_mv - 3900) / 15));
        } else if (voltage_mv >= 3700) {
            // 3700-3900: 50-80%
            return 50 + @as(u8, @intCast((voltage_mv - 3700) * 30 / 200));
        } else if (voltage_mv >= 3400) {
            // 3400-3700: 10-50%
            return 10 + @as(u8, @intCast((voltage_mv - 3400) * 40 / 300));
        } else {
            // 3000-3400: 0-10%
            return @as(u8, @intCast((voltage_mv - 3000) * 10 / 400));
        }
    }
};

// ============================================================
// Power Manager State
// ============================================================

var current_state: PowerState = .active;
var battery_info = BatteryInfo{};
var backlight_timeout_ms: u32 = 30000; // Default 30 seconds
var last_activity_time: u64 = 0;
var backlight_on: bool = true;

// Thresholds
const LOW_BATTERY_PERCENT: u8 = 15;
const CRITICAL_BATTERY_PERCENT: u8 = 5;
const LOW_BATTERY_VOLTAGE: u16 = 3500;
const CRITICAL_BATTERY_VOLTAGE: u16 = 3300;

// ============================================================
// Initialization
// ============================================================

/// Initialize power management
pub fn init() !void {
    // Read initial battery state
    try updateBatteryInfo();

    // Set initial power state based on battery
    if (battery_info.is_critical) {
        // Don't fully boot if battery is critical
        current_state = .standby;
    } else {
        current_state = .active;
    }

    // Record activity time
    last_activity_time = hal.getTicksUs();
}

// ============================================================
// Battery Monitoring
// ============================================================

/// Update battery information from PMU
pub fn updateBatteryInfo() !void {
    const adc_value = try pmu.readAdc(.battery);
    battery_info.voltage_mv = adcToMillivolts(adc_value);
    battery_info.percentage = BatteryInfo.estimateFromVoltage(battery_info.voltage_mv);

    // Check charging state
    const status = try pmu.readStatus();
    battery_info.charging_state = if (status.charging)
        .charging
    else if (status.charge_complete)
        .charge_complete
    else
        .not_charging;

    // Check thresholds
    battery_info.is_low = battery_info.percentage <= LOW_BATTERY_PERCENT or
        battery_info.voltage_mv <= LOW_BATTERY_VOLTAGE;
    battery_info.is_critical = battery_info.percentage <= CRITICAL_BATTERY_PERCENT or
        battery_info.voltage_mv <= CRITICAL_BATTERY_VOLTAGE;
}

/// Convert ADC reading to millivolts
fn adcToMillivolts(adc: u16) u16 {
    // ADC is 10-bit, reference is 3.3V, with voltage divider
    // Actual conversion depends on hardware configuration
    return @intCast((@as(u32, adc) * 5000) / 1024);
}

/// Get current battery info
pub fn getBatteryInfo() BatteryInfo {
    return battery_info;
}

// ============================================================
// Power State Management
// ============================================================

/// Get current power state
pub fn getState() PowerState {
    return current_state;
}

/// Request transition to a new power state
pub fn setState(new_state: PowerState) !void {
    if (new_state == current_state) return;

    switch (new_state) {
        .active => try enterActive(),
        .idle => try enterIdle(),
        .sleep => try enterSleep(),
        .standby => try enterStandby(),
        .off => try enterOff(),
    }

    current_state = new_state;
}

fn enterActive() !void {
    // Full power mode
    lcd.setBacklight(true);
    backlight_on = true;

    // Increase CPU frequency if needed
    // (PP5021C can run at 24, 30, or 80 MHz)
}

fn enterIdle() !void {
    // Reduce power but stay responsive
    // CPU can sleep between events
}

fn enterSleep() !void {
    // Turn off display but keep audio playing
    lcd.setBacklight(false);
    backlight_on = false;
}

fn enterStandby() !void {
    // Ultra-low power, quick wake
    lcd.setBacklight(false);
    backlight_on = false;

    // Could reduce CPU frequency here
}

fn enterOff() !void {
    // Power off (will need button press to wake)
    lcd.setBacklight(false);
    lcd.clear(lcd.Colors.BLACK);

    // Request PMU to power off
    try pmu.powerOff();
}

// ============================================================
// Backlight Management
// ============================================================

/// Set backlight timeout (0 = always on)
pub fn setBacklightTimeout(timeout_seconds: u16) void {
    backlight_timeout_ms = @as(u32, timeout_seconds) * 1000;
}

/// Get backlight timeout
pub fn getBacklightTimeout() u16 {
    return @intCast(backlight_timeout_ms / 1000);
}

/// Record user activity (resets backlight timeout)
pub fn recordActivity() void {
    last_activity_time = hal.getTicksUs();

    // Turn on backlight if it was off
    if (!backlight_on and current_state != .off) {
        lcd.setBacklight(true);
        backlight_on = true;
    }
}

/// Check if backlight should be turned off
pub fn checkBacklightTimeout() void {
    if (backlight_timeout_ms == 0) return; // Always on

    const current_time = hal.getTicksUs();
    const elapsed_ms = (current_time - last_activity_time) / 1000;

    if (elapsed_ms >= backlight_timeout_ms and backlight_on) {
        lcd.setBacklight(false);
        backlight_on = false;
    }
}

/// Check if backlight is currently on
pub fn isBacklightOn() bool {
    return backlight_on;
}

// ============================================================
// Sleep Timer
// ============================================================

var sleep_timer_minutes: u16 = 0;
var sleep_timer_start: u64 = 0;

/// Set sleep timer (0 = off)
pub fn setSleepTimer(minutes: u16) void {
    sleep_timer_minutes = minutes;
    if (minutes > 0) {
        sleep_timer_start = hal.getTicksUs();
    }
}

/// Get remaining sleep timer time in minutes
pub fn getSleepTimerRemaining() u16 {
    if (sleep_timer_minutes == 0) return 0;

    const current_time = hal.getTicksUs();
    const elapsed_minutes = (current_time - sleep_timer_start) / (1000 * 1000 * 60);

    if (elapsed_minutes >= sleep_timer_minutes) {
        return 0;
    }
    return @intCast(sleep_timer_minutes - elapsed_minutes);
}

/// Check if sleep timer has expired
pub fn checkSleepTimer() bool {
    return sleep_timer_minutes > 0 and getSleepTimerRemaining() == 0;
}

// ============================================================
// Tests
// ============================================================

test "battery voltage to percentage" {
    // Full charge
    try std.testing.expectEqual(@as(u8, 100), BatteryInfo.estimateFromVoltage(4200));

    // Half
    try std.testing.expect(BatteryInfo.estimateFromVoltage(3700) >= 45);
    try std.testing.expect(BatteryInfo.estimateFromVoltage(3700) <= 55);

    // Empty
    try std.testing.expectEqual(@as(u8, 0), BatteryInfo.estimateFromVoltage(3000));
    try std.testing.expectEqual(@as(u8, 0), BatteryInfo.estimateFromVoltage(2800));
}

test "battery icon" {
    var info = BatteryInfo{};

    info.percentage = 90;
    try std.testing.expectEqualStrings("[####]", info.getIcon());

    info.percentage = 15;
    try std.testing.expectEqualStrings("[!   ]", info.getIcon());

    info.charging_state = .charging;
    try std.testing.expectEqualStrings("[CHG]", info.getIcon());
}

test "backlight timeout" {
    backlight_timeout_ms = 5000;
    try std.testing.expectEqual(@as(u16, 5), getBacklightTimeout());

    setBacklightTimeout(30);
    try std.testing.expectEqual(@as(u32, 30000), backlight_timeout_ms);
}
