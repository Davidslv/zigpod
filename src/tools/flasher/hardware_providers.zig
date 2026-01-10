//! Hardware Providers for Flasher
//!
//! This module provides real hardware implementations of the battery and
//! watchdog providers used by the flasher. These connect directly to the
//! PP5021C HAL layer for actual hardware control.
//!
//! For host testing, use the mock providers in flasher.zig instead.

const std = @import("std");
const hal = @import("../../hal/hal.zig");
const flasher = @import("flasher.zig");
const lcd = @import("../../drivers/display/lcd.zig");

// ============================================================
// Real Hardware Battery Provider
// ============================================================
//
// Connects to PCF50605 PMU via HAL for actual battery status.
// This should be used on real iPod hardware only.
//

/// Real hardware battery provider using PP5021C PMU
pub const HardwareBatteryProvider = flasher.BatteryProvider{
    .get_percent = hwGetBatteryPercent,
    .get_voltage_mv = hwGetBatteryVoltage,
    .is_charging = hwIsCharging,
    .external_power_present = hwExternalPowerPresent,
};

fn hwGetBatteryPercent() u8 {
    return hal.pmuGetBatteryPercent();
}

fn hwGetBatteryVoltage() u16 {
    return hal.pmuGetBatteryVoltage();
}

fn hwIsCharging() bool {
    return hal.pmuIsCharging();
}

fn hwExternalPowerPresent() bool {
    return hal.pmuExternalPowerPresent();
}

// ============================================================
// Real Hardware Watchdog Provider
// ============================================================
//
// Connects to PP5021C watchdog timer via HAL.
// The watchdog will reset the system if not refreshed within the timeout.
//

/// Real hardware watchdog provider using PP5021C WDT
pub const HardwareWatchdogProvider = flasher.WatchdogProvider{
    .init = hwWdtInit,
    .start = hwWdtStart,
    .stop = hwWdtStop,
    .refresh = hwWdtRefresh,
};

fn hwWdtInit(timeout_ms: u32) void {
    hal.wdtInit(timeout_ms) catch {
        // Log error but don't fail - watchdog is optional safety
    };
}

fn hwWdtStart() void {
    hal.wdtStart();
}

fn hwWdtStop() void {
    hal.wdtStop();
}

fn hwWdtRefresh() void {
    hal.wdtRefresh();
}

// ============================================================
// LCD Progress Display
// ============================================================
//
// Provides visual feedback during flash operations.
// Shows progress bar, status text, and battery level on LCD.
//

/// LCD progress display state
pub const LcdProgress = struct {
    /// Current operation message
    message: [64]u8 = [_]u8{0} ** 64,
    message_len: usize = 0,
    /// Progress percentage (0-100)
    progress_percent: u8 = 0,
    /// Current battery percentage
    battery_percent: u8 = 100,
    /// Is operation in progress
    active: bool = false,

    const Self = @This();

    /// Screen dimensions
    const SCREEN_WIDTH: u16 = 320;
    const SCREEN_HEIGHT: u16 = 240;

    /// Progress bar dimensions
    const BAR_X: u16 = 20;
    const BAR_Y: u16 = 140;
    const BAR_WIDTH: u16 = 280;
    const BAR_HEIGHT: u16 = 20;

    /// Colors (RGB565)
    const COLOR_BG = lcd.rgb(0, 0, 0); // Black
    const COLOR_TEXT = lcd.rgb(255, 255, 255); // White
    const COLOR_BAR_BG = lcd.rgb(32, 32, 32); // Dark gray
    const COLOR_BAR_FG = lcd.rgb(0, 255, 0); // Green
    const COLOR_BAR_WARN = lcd.rgb(255, 200, 0); // Yellow/Orange
    const COLOR_BAR_CRIT = lcd.rgb(255, 0, 0); // Red
    const COLOR_BATTERY = lcd.rgb(0, 255, 0); // Green
    const COLOR_BATTERY_LOW = lcd.rgb(255, 0, 0); // Red

    /// Initialize LCD progress display
    pub fn init(self: *Self) void {
        self.active = true;
        self.progress_percent = 0;
        self.battery_percent = hwGetBatteryPercent();
        self.clearScreen();
        self.drawHeader();
    }

    /// Deinitialize
    pub fn deinit(self: *Self) void {
        self.active = false;
    }

    /// Clear screen to black
    fn clearScreen(self: *Self) void {
        _ = self;
        lcd.fillRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, COLOR_BG);
    }

    /// Draw header with ZigPod logo and battery
    fn drawHeader(self: *Self) void {
        // Title
        lcd.drawString(20, 20, "ZigPod Flasher", COLOR_TEXT, COLOR_BG);

        // Battery indicator
        self.drawBattery();
    }

    /// Draw battery indicator in top-right
    fn drawBattery(self: *Self) void {
        const bat_x: u16 = SCREEN_WIDTH - 50;
        const bat_y: u16 = 15;
        const bat_w: u16 = 30;
        const bat_h: u16 = 14;

        // Battery outline
        lcd.drawRect(bat_x, bat_y, bat_w, bat_h, COLOR_TEXT);
        lcd.fillRect(bat_x + bat_w, bat_y + 3, 3, 8, COLOR_TEXT); // Battery tip

        // Battery fill
        const fill_color = if (self.battery_percent < 20) COLOR_BATTERY_LOW else COLOR_BATTERY;
        const fill_width = @as(u16, @intCast((@as(u32, bat_w - 4) * self.battery_percent) / 100));
        lcd.fillRect(bat_x + 2, bat_y + 2, fill_width, bat_h - 4, fill_color);

        // Percentage text
        var buf: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}%", .{self.battery_percent}) catch "??%";
        lcd.drawString(bat_x - 35, bat_y + 2, text, COLOR_TEXT, COLOR_BG);
    }

    /// Update status message
    pub fn setMessage(self: *Self, msg: []const u8) void {
        const len = @min(msg.len, self.message.len);
        @memcpy(self.message[0..len], msg[0..len]);
        self.message_len = len;

        // Clear old message area and draw new
        lcd.fillRect(20, 80, SCREEN_WIDTH - 40, 40, COLOR_BG);
        lcd.drawString(20, 90, msg, COLOR_TEXT, COLOR_BG);
    }

    /// Update progress bar
    pub fn setProgress(self: *Self, current: u64, total: u64) void {
        if (total == 0) return;

        const percent: u8 = @intCast(@min(100, (current * 100) / total));
        if (percent == self.progress_percent) return; // No change

        self.progress_percent = percent;

        // Determine bar color based on state
        const bar_color = if (percent >= 100)
            COLOR_BAR_FG // Complete - green
        else
            COLOR_BAR_WARN; // In progress - yellow

        // Draw progress bar background
        lcd.fillRect(BAR_X, BAR_Y, BAR_WIDTH, BAR_HEIGHT, COLOR_BAR_BG);

        // Draw progress bar fill
        const fill_width = @as(u16, @intCast((@as(u32, BAR_WIDTH - 4) * percent) / 100));
        if (fill_width > 0) {
            lcd.fillRect(BAR_X + 2, BAR_Y + 2, fill_width, BAR_HEIGHT - 4, bar_color);
        }

        // Draw progress bar border
        lcd.drawRect(BAR_X, BAR_Y, BAR_WIDTH, BAR_HEIGHT, COLOR_TEXT);

        // Draw percentage text centered in bar
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}%", .{percent}) catch "??%";
        const text_x = BAR_X + (BAR_WIDTH / 2) - 15;
        const text_bg = if (fill_width > BAR_WIDTH / 2) bar_color else COLOR_BAR_BG;
        lcd.drawString(text_x, BAR_Y + 4, text, COLOR_TEXT, text_bg);

        // Update battery periodically
        const new_bat = hwGetBatteryPercent();
        if (new_bat != self.battery_percent) {
            self.battery_percent = new_bat;
            self.drawBattery();
        }
    }

    /// Show error message
    pub fn showError(self: *Self, error_msg: []const u8) void {
        _ = self;
        // Red background for error
        lcd.fillRect(20, 180, SCREEN_WIDTH - 40, 40, COLOR_BAR_CRIT);
        lcd.drawString(30, 185, "ERROR:", COLOR_TEXT, COLOR_BAR_CRIT);
        lcd.drawString(30, 200, error_msg, COLOR_TEXT, COLOR_BAR_CRIT);
    }

    /// Show success message
    pub fn showSuccess(self: *Self, msg: []const u8) void {
        _ = self;
        // Green background for success
        lcd.fillRect(20, 180, SCREEN_WIDTH - 40, 40, COLOR_BAR_FG);
        lcd.drawString(30, 192, msg, COLOR_BG, COLOR_BAR_FG);
    }
};

/// Global LCD progress instance
var lcd_progress: LcdProgress = .{};

/// Flasher progress callback that updates LCD
pub fn lcdProgressCallback(
    state: flasher.FlashState,
    current: u64,
    total: u64,
    message: []const u8,
) void {
    // Initialize on first call
    if (!lcd_progress.active) {
        lcd_progress.init();
    }

    // Update message based on state
    const state_msg: []const u8 = switch (state) {
        .idle => "Ready",
        .checking_safety => "Checking safety...",
        .backing_up => "Creating backup...",
        .verifying_backup => "Verifying backup...",
        .flashing => "Flashing firmware...",
        .verifying_flash => "Verifying flash...",
        .rolling_back => "Rolling back...",
        .completed => "Complete!",
        .failed => "FAILED",
        .aborted_low_battery => "LOW BATTERY!",
        .aborted_safety => "Safety check failed",
    };

    // Use custom message if provided, otherwise state message
    if (message.len > 0) {
        lcd_progress.setMessage(message);
    } else {
        lcd_progress.setMessage(state_msg);
    }

    // Update progress bar
    lcd_progress.setProgress(current, total);

    // Show final status
    switch (state) {
        .completed => lcd_progress.showSuccess("Flash completed successfully!"),
        .failed => lcd_progress.showError("Flash operation failed"),
        .aborted_low_battery => lcd_progress.showError("Battery too low - aborted"),
        .aborted_safety => lcd_progress.showError("Safety check failed"),
        else => {},
    }
}

/// Get LCD progress callback for flasher options
pub fn getLcdProgressCallback() flasher.ProgressCallback {
    return lcdProgressCallback;
}

/// Reset LCD progress display
pub fn resetLcdProgress() void {
    lcd_progress.deinit();
    lcd_progress = .{};
}

// ============================================================
// Convenience Functions
// ============================================================

/// Create a SafeFlasher configured for real hardware
pub fn createHardwareFlasher(allocator: std.mem.Allocator, backup_dir: []const u8) flasher.SafeFlasher {
    return flasher.SafeFlasher.initWithProviders(
        allocator,
        backup_dir,
        HardwareBatteryProvider,
        HardwareWatchdogProvider,
    );
}

/// Get default flash options with LCD progress enabled
pub fn getHardwareFlashOptions() flasher.FlashOptions {
    return .{
        .progress_callback = lcdProgressCallback,
        .check_battery = true,
        .enable_watchdog = true,
        .require_external_power = false, // Recommended but not required
        .abort_on_critical_battery = true,
        .auto_rollback_on_failure = true,
    };
}

// ============================================================
// Tests
// ============================================================

test "hardware providers exist" {
    // Just verify the providers compile and have correct signatures
    const bat = HardwareBatteryProvider;
    const wdt = HardwareWatchdogProvider;

    try std.testing.expect(@TypeOf(bat.get_percent) == *const fn () u8);
    try std.testing.expect(@TypeOf(wdt.init) == *const fn (u32) void);
}

test "lcd progress initialization" {
    var progress = LcdProgress{};
    try std.testing.expect(!progress.active);
    try std.testing.expectEqual(@as(u8, 0), progress.progress_percent);
}
