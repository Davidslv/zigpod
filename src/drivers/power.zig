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
// Wake Sources
// ============================================================

pub const WakeSource = enum {
    none,
    button, // Any button press
    wheel, // Click wheel touch
    usb, // USB connection
    alarm, // RTC alarm
    timer, // Sleep timer expired
};

var wake_source: WakeSource = .none;
var wake_mask: u8 = 0xFF; // All sources enabled by default

/// Enable/disable wake source
pub fn setWakeSourceEnabled(source: WakeSource, enabled: bool) void {
    const bit: u8 = @as(u8, 1) << @intFromEnum(source);
    if (enabled) {
        wake_mask |= bit;
    } else {
        wake_mask &= ~bit;
    }
}

/// Check if wake source is enabled
pub fn isWakeSourceEnabled(source: WakeSource) bool {
    const bit: u8 = @as(u8, 1) << @intFromEnum(source);
    return (wake_mask & bit) != 0;
}

/// Get what woke the device
pub fn getWakeSource() WakeSource {
    return wake_source;
}

/// Record wake source (called by interrupt handlers)
pub fn recordWakeSource(source: WakeSource) void {
    wake_source = source;
}

/// Clear wake source
pub fn clearWakeSource() void {
    wake_source = .none;
}

// ============================================================
// Power Profiles
// ============================================================

pub const PowerProfile = struct {
    name: []const u8,
    backlight_timeout_sec: u16,
    cpu_speed_mhz: u8,
    hold_to_sleep: bool,
    auto_sleep_minutes: u16, // 0 = disabled
    eq_enabled: bool,
};

pub const DEFAULT_PROFILES = [_]PowerProfile{
    .{
        .name = "Normal",
        .backlight_timeout_sec = 30,
        .cpu_speed_mhz = 80,
        .hold_to_sleep = true,
        .auto_sleep_minutes = 30,
        .eq_enabled = true,
    },
    .{
        .name = "Power Saver",
        .backlight_timeout_sec = 10,
        .cpu_speed_mhz = 30,
        .hold_to_sleep = true,
        .auto_sleep_minutes = 15,
        .eq_enabled = false,
    },
    .{
        .name = "Performance",
        .backlight_timeout_sec = 60,
        .cpu_speed_mhz = 80,
        .hold_to_sleep = false,
        .auto_sleep_minutes = 0,
        .eq_enabled = true,
    },
};

var current_profile: usize = 0; // Normal

/// Get current power profile
pub fn getProfile() PowerProfile {
    return DEFAULT_PROFILES[current_profile];
}

/// Set power profile by index
pub fn setProfile(index: usize) void {
    if (index < DEFAULT_PROFILES.len) {
        current_profile = index;
        const profile = DEFAULT_PROFILES[index];
        setBacklightTimeout(profile.backlight_timeout_sec);
        // CPU speed change would be done here
    }
}

// ============================================================
// Auto Sleep
// ============================================================

var auto_sleep_enabled: bool = true;
var last_playback_time: u64 = 0;

/// Update playback activity (call when audio is playing)
pub fn recordPlaybackActivity() void {
    last_playback_time = hal.getTicksUs();
}

/// Check if device should auto-sleep
pub fn checkAutoSleep() bool {
    const profile = getProfile();
    if (!auto_sleep_enabled or profile.auto_sleep_minutes == 0) return false;

    const current_time = hal.getTicksUs();

    // Check both activity and playback
    const activity_elapsed_min = (current_time - last_activity_time) / (1000 * 1000 * 60);
    const playback_elapsed_min = (current_time - last_playback_time) / (1000 * 1000 * 60);

    // Sleep if no activity and no playback for auto_sleep_minutes
    return activity_elapsed_min >= profile.auto_sleep_minutes and
        playback_elapsed_min >= profile.auto_sleep_minutes;
}

/// Enable/disable auto sleep
pub fn setAutoSleepEnabled(enabled: bool) void {
    auto_sleep_enabled = enabled;
}

// ============================================================
// Deep Sleep Mode
// ============================================================

/// Enter deep sleep mode (stops audio, minimal power)
pub fn enterDeepSleep() !void {
    // Save state for resume
    const was_playing = false; // Would check audio.isPlaying()

    // Stop audio
    // audio.stop();

    // Turn off peripherals
    lcd.setBacklight(false);
    lcd.clear(lcd.Colors.BLACK);

    // Configure wake sources with PMU
    // This would configure actual hardware wake pins

    // Enter low power mode
    current_state = .standby;

    // In real hardware, CPU would halt here until wake event
    hal.sleep();

    // Woke up - restore state
    if (was_playing) {
        // Resume playback
    }

    // Return to active state
    current_state = .active;
    lcd.setBacklight(true);
    backlight_on = true;
}

/// Handle hold switch (enter/exit sleep)
pub fn handleHoldSwitch(is_held: bool) !void {
    const profile = getProfile();

    if (is_held and profile.hold_to_sleep) {
        // Hold switch activated - enter sleep
        try setState(.sleep);
    } else if (!is_held and current_state == .sleep) {
        // Hold switch released - wake up
        try setState(.active);
    }
}

// ============================================================
// Statistics Tracking
// ============================================================

pub const PowerStats = struct {
    total_runtime_sec: u32 = 0,
    playback_time_sec: u32 = 0,
    sleep_time_sec: u32 = 0,
    charge_cycles: u16 = 0,
    last_full_charge_time: u32 = 0,
    boot_count: u32 = 0,

    pub fn getUptimeString(self: *const PowerStats, buffer: []u8) []u8 {
        const hours = self.total_runtime_sec / 3600;
        const minutes = (self.total_runtime_sec % 3600) / 60;
        return std.fmt.bufPrint(buffer, "{d}h {d}m", .{ hours, minutes }) catch buffer[0..0];
    }

    pub fn getPlaybackTimeString(self: *const PowerStats, buffer: []u8) []u8 {
        const hours = self.playback_time_sec / 3600;
        const minutes = (self.playback_time_sec % 3600) / 60;
        return std.fmt.bufPrint(buffer, "{d}h {d}m", .{ hours, minutes }) catch buffer[0..0];
    }
};

var power_stats = PowerStats{};

/// Get power statistics
pub fn getStats() PowerStats {
    return power_stats;
}

/// Update runtime statistics (call periodically, e.g., once per second)
pub fn updateStats(is_playing: bool) void {
    power_stats.total_runtime_sec += 1;

    if (is_playing) {
        power_stats.playback_time_sec += 1;
    }

    if (current_state == .sleep or current_state == .standby) {
        power_stats.sleep_time_sec += 1;
    }
}

/// Record a charge cycle
pub fn recordChargeCycle() void {
    power_stats.charge_cycles += 1;
    power_stats.last_full_charge_time = @intCast(hal.getTicksUs() / 1_000_000);
}

/// Increment boot count
pub fn recordBoot() void {
    power_stats.boot_count += 1;
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
