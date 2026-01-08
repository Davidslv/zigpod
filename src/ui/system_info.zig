//! System Information Screen
//!
//! Displays runtime statistics, battery info, storage status, and system details.

const std = @import("std");
const ui_core = @import("ui.zig");
const lcd = @import("../drivers/display/lcd.zig");
const power = @import("../drivers/power.zig");

// ============================================================
// Constants
// ============================================================

const SECTION_HEIGHT: u16 = 60;
const HEADER_HEIGHT: u16 = 20;
const LINE_HEIGHT: u16 = 14;
const PADDING: u16 = 5;

// ============================================================
// System Info Screen
// ============================================================

pub const SystemInfoScreen = struct {
    scroll_position: u8 = 0,
    current_page: Page = .overview,

    pub const Page = enum {
        overview,
        battery,
        storage,
        about,
    };

    /// Initialize the system info screen
    pub fn init() SystemInfoScreen {
        return SystemInfoScreen{};
    }

    /// Render the system info screen
    pub fn render(self: *SystemInfoScreen) void {
        // Clear screen
        lcd.clear(lcd.Colors.BLACK);

        // Draw header
        drawHeader(self.current_page);

        // Draw current page content
        switch (self.current_page) {
            .overview => self.drawOverviewPage(),
            .battery => self.drawBatteryPage(),
            .storage => self.drawStoragePage(),
            .about => self.drawAboutPage(),
        }

        // Draw navigation hint
        drawNavigationHint();
    }

    fn drawOverviewPage(self: *SystemInfoScreen) void {
        _ = self;
        var y: u16 = HEADER_HEIGHT + PADDING;

        // Uptime
        const stats = power.getStats();
        var uptime_buf: [32]u8 = undefined;
        const uptime_str = stats.getUptimeString(&uptime_buf);
        drawLabelValue(PADDING, y, "Uptime:", uptime_str);
        y += LINE_HEIGHT;

        // Playback time
        var playback_buf: [32]u8 = undefined;
        const playback_str = stats.getPlaybackTimeString(&playback_buf);
        drawLabelValue(PADDING, y, "Playback:", playback_str);
        y += LINE_HEIGHT;

        // Battery
        const battery = power.getBatteryInfo();
        var battery_buf: [32]u8 = undefined;
        const battery_str = battery.formatPercentage(&battery_buf);
        drawLabelValue(PADDING, y, "Battery:", battery_str);
        y += LINE_HEIGHT;

        // Power state
        const state_str = switch (power.getState()) {
            .active => "Active",
            .idle => "Idle",
            .sleep => "Sleep",
            .standby => "Standby",
            .off => "Off",
        };
        drawLabelValue(PADDING, y, "State:", state_str);
        y += LINE_HEIGHT;

        // Boot count
        var boot_buf: [16]u8 = undefined;
        const boot_str = std.fmt.bufPrint(&boot_buf, "{d}", .{stats.boot_count}) catch "?";
        drawLabelValue(PADDING, y, "Boots:", boot_str);
        y += LINE_HEIGHT;

        // Current profile
        const profile = power.getProfile();
        drawLabelValue(PADDING, y, "Profile:", profile.name);
    }

    fn drawBatteryPage(self: *SystemInfoScreen) void {
        _ = self;
        var y: u16 = HEADER_HEIGHT + PADDING;
        const battery = power.getBatteryInfo();

        // Large battery indicator
        drawBatteryIcon(120, y, battery.percentage);
        y += 40;

        // Voltage
        var voltage_buf: [16]u8 = undefined;
        const voltage_str = std.fmt.bufPrint(&voltage_buf, "{d}.{d:0>2}V", .{
            battery.voltage_mv / 1000,
            (battery.voltage_mv % 1000) / 10,
        }) catch "?";
        drawLabelValue(PADDING, y, "Voltage:", voltage_str);
        y += LINE_HEIGHT;

        // Percentage
        var pct_buf: [16]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, "{d}%", .{battery.percentage}) catch "?";
        drawLabelValue(PADDING, y, "Level:", pct_str);
        y += LINE_HEIGHT;

        // Charging state
        const charge_str = switch (battery.charging_state) {
            .not_charging => "Not charging",
            .charging => "Charging",
            .charge_complete => "Full",
            .fault => "Fault!",
        };
        drawLabelValue(PADDING, y, "Status:", charge_str);
        y += LINE_HEIGHT;

        // Temperature
        var temp_buf: [16]u8 = undefined;
        const temp_str = std.fmt.bufPrint(&temp_buf, "{d}C", .{battery.temperature_c}) catch "?";
        drawLabelValue(PADDING, y, "Temp:", temp_str);
        y += LINE_HEIGHT;

        // Charge cycles
        const stats = power.getStats();
        var cycles_buf: [16]u8 = undefined;
        const cycles_str = std.fmt.bufPrint(&cycles_buf, "{d}", .{stats.charge_cycles}) catch "?";
        drawLabelValue(PADDING, y, "Cycles:", cycles_str);
    }

    fn drawStoragePage(self: *SystemInfoScreen) void {
        _ = self;
        var y: u16 = HEADER_HEIGHT + PADDING;

        // Storage would come from FAT32 driver
        // Using placeholder values for now
        drawLabelValue(PADDING, y, "Type:", "HDD 30GB");
        y += LINE_HEIGHT;

        drawLabelValue(PADDING, y, "Used:", "12.5 GB");
        y += LINE_HEIGHT;

        drawLabelValue(PADDING, y, "Free:", "17.5 GB");
        y += LINE_HEIGHT;

        // Draw usage bar
        y += 5;
        drawStorageBar(PADDING, y, 300, 15, 42); // 42% used
        y += 25;

        drawLabelValue(PADDING, y, "Tracks:", "1,234");
        y += LINE_HEIGHT;

        drawLabelValue(PADDING, y, "Playlists:", "15");
    }

    fn drawAboutPage(self: *SystemInfoScreen) void {
        _ = self;
        var y: u16 = HEADER_HEIGHT + PADDING;

        // ZigPod logo/name
        lcd.drawText(80, y, "ZigPod OS", lcd.Colors.WHITE);
        y += LINE_HEIGHT + 5;

        drawLabelValue(PADDING, y, "Version:", "0.1.0");
        y += LINE_HEIGHT;

        drawLabelValue(PADDING, y, "Codename:", "Genesis");
        y += LINE_HEIGHT;

        drawLabelValue(PADDING, y, "Build:", "Zig 0.15.2");
        y += LINE_HEIGHT;

        y += 10;
        lcd.drawText(PADDING, y, "github.com/zigpod", lcd.Colors.GRAY);
        y += LINE_HEIGHT + 10;

        lcd.drawText(PADDING, y, "Made with Zig for iPod", lcd.Colors.GRAY);
        y += LINE_HEIGHT;

        lcd.drawText(PADDING, y, "5th Generation", lcd.Colors.GRAY);
    }

    /// Handle input events
    pub fn handleInput(self: *SystemInfoScreen, event: ui_core.InputEvent) bool {
        switch (event.event_type) {
            .button_press => {
                if (event.buttons & ui_core.Button.MENU != 0) {
                    return false; // Exit screen
                }
                if (event.buttons & ui_core.Button.SELECT != 0) {
                    // Cycle to next page
                    self.nextPage();
                    return true;
                }
            },
            .wheel_scroll => {
                if (event.wheel_delta > 0) {
                    self.nextPage();
                } else {
                    self.prevPage();
                }
                return true;
            },
            else => {},
        }
        return true;
    }

    fn nextPage(self: *SystemInfoScreen) void {
        self.current_page = switch (self.current_page) {
            .overview => .battery,
            .battery => .storage,
            .storage => .about,
            .about => .overview,
        };
    }

    fn prevPage(self: *SystemInfoScreen) void {
        self.current_page = switch (self.current_page) {
            .overview => .about,
            .battery => .overview,
            .storage => .battery,
            .about => .storage,
        };
    }
};

// ============================================================
// Drawing Helpers
// ============================================================

fn drawHeader(page: SystemInfoScreen.Page) void {
    // Background bar
    lcd.fillRect(0, 0, 320, HEADER_HEIGHT, lcd.Colors.DARK_GRAY);

    // Title
    const title = switch (page) {
        .overview => "System Info",
        .battery => "Battery",
        .storage => "Storage",
        .about => "About",
    };
    lcd.drawText(10, 3, title, lcd.Colors.WHITE);

    // Page indicator
    const page_num = @intFromEnum(page) + 1;
    var buf: [8]u8 = undefined;
    const page_str = std.fmt.bufPrint(&buf, "{d}/4", .{page_num}) catch "?/4";
    lcd.drawText(280, 3, page_str, lcd.Colors.GRAY);
}

fn drawNavigationHint() void {
    lcd.drawText(10, 220, "Scroll: Pages  Menu: Back", lcd.Colors.GRAY);
}

fn drawLabelValue(x: u16, y: u16, label: []const u8, value: []const u8) void {
    lcd.drawText(x, y, label, lcd.Colors.GRAY);
    lcd.drawText(x + 100, y, value, lcd.Colors.WHITE);
}

fn drawBatteryIcon(x: u16, y: u16, percentage: u8) void {
    const width: u16 = 80;
    const height: u16 = 30;

    // Battery outline
    lcd.drawRect(x, y, width, height, lcd.Colors.WHITE);
    // Battery terminal
    lcd.fillRect(x + width, y + 8, 5, 14, lcd.Colors.WHITE);

    // Fill based on percentage
    const fill_width: u16 = @intCast((@as(u32, percentage) * (width - 4)) / 100);
    const fill_color: u16 = if (percentage > 20)
        lcd.Colors.GREEN
    else if (percentage > 10)
        lcd.Colors.YELLOW
    else
        lcd.Colors.RED;

    if (fill_width > 0) {
        lcd.fillRect(x + 2, y + 2, fill_width, height - 4, fill_color);
    }

    // Percentage text
    var buf: [8]u8 = undefined;
    const pct_str = std.fmt.bufPrint(&buf, "{d}%", .{percentage}) catch "?";
    lcd.drawText(x + width / 2 - 10, y + 8, pct_str, lcd.Colors.WHITE);
}

fn drawStorageBar(x: u16, y: u16, width: u16, height: u16, used_percent: u8) void {
    // Background
    lcd.fillRect(x, y, width, height, lcd.Colors.DARK_GRAY);

    // Used portion
    const used_width: u16 = @intCast((@as(u32, used_percent) * width) / 100);
    if (used_width > 0) {
        const color: u16 = if (used_percent > 90)
            lcd.Colors.RED
        else if (used_percent > 75)
            lcd.Colors.YELLOW
        else
            lcd.Colors.BLUE;
        lcd.fillRect(x, y, used_width, height, color);
    }

    // Border
    lcd.drawRect(x, y, width, height, lcd.Colors.WHITE);
}

// ============================================================
// Tests
// ============================================================

test "system info screen initialization" {
    const screen = SystemInfoScreen.init();
    try std.testing.expectEqual(SystemInfoScreen.Page.overview, screen.current_page);
}

test "page cycling" {
    var screen = SystemInfoScreen.init();

    screen.nextPage();
    try std.testing.expectEqual(SystemInfoScreen.Page.battery, screen.current_page);

    screen.nextPage();
    try std.testing.expectEqual(SystemInfoScreen.Page.storage, screen.current_page);

    screen.prevPage();
    try std.testing.expectEqual(SystemInfoScreen.Page.battery, screen.current_page);
}
