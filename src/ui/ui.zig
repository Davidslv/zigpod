//! User Interface Framework
//!
//! A simple UI framework for iPod-style menu navigation and display.
//! Designed to work with the click wheel input and LCD display drivers.

const std = @import("std");
const hal = @import("../hal/hal.zig");
const lcd = @import("../drivers/display/lcd.zig");
const clickwheel = @import("../drivers/input/clickwheel.zig");

// Export UI modules
pub const now_playing = @import("now_playing.zig");
pub const file_browser = @import("file_browser.zig");
pub const music_browser = @import("music_browser.zig");
pub const settings = @import("settings.zig");
pub const system_info = @import("system_info.zig");
pub const theme_loader = @import("theme_loader.zig");
pub const state_machine = @import("state_machine.zig");

// ============================================================
// UI Constants
// ============================================================

pub const SCREEN_WIDTH: u16 = lcd.WIDTH;
pub const SCREEN_HEIGHT: u16 = lcd.HEIGHT;

/// Font metrics for 8x8 font
pub const CHAR_WIDTH: u16 = 8;
pub const CHAR_HEIGHT: u16 = 8;

/// Standard UI element heights
pub const HEADER_HEIGHT: u16 = 24;
pub const FOOTER_HEIGHT: u16 = 20;
pub const MENU_ITEM_HEIGHT: u16 = 20;
pub const CONTENT_START_Y: u16 = HEADER_HEIGHT;
pub const CONTENT_HEIGHT: u16 = SCREEN_HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT;

/// Maximum items visible in a menu
pub const MAX_VISIBLE_ITEMS: u8 = @intCast(CONTENT_HEIGHT / MENU_ITEM_HEIGHT);

// ============================================================
// Color Theme
// ============================================================

pub const Theme = struct {
    background: lcd.Color,
    foreground: lcd.Color,
    header_bg: lcd.Color,
    header_fg: lcd.Color,
    selected_bg: lcd.Color,
    selected_fg: lcd.Color,
    footer_bg: lcd.Color,
    footer_fg: lcd.Color,
    accent: lcd.Color,
    disabled: lcd.Color,
};

/// Default iPod-like light theme
pub const default_theme = Theme{
    .background = lcd.rgb(255, 255, 255),
    .foreground = lcd.rgb(0, 0, 0),
    .header_bg = lcd.rgb(200, 200, 200),
    .header_fg = lcd.rgb(0, 0, 0),
    .selected_bg = lcd.rgb(66, 133, 244),
    .selected_fg = lcd.rgb(255, 255, 255),
    .footer_bg = lcd.rgb(200, 200, 200),
    .footer_fg = lcd.rgb(80, 80, 80),
    .accent = lcd.rgb(66, 133, 244),
    .disabled = lcd.rgb(160, 160, 160),
};

/// Dark theme
pub const dark_theme = Theme{
    .background = lcd.rgb(20, 20, 20),
    .foreground = lcd.rgb(240, 240, 240),
    .header_bg = lcd.rgb(40, 40, 40),
    .header_fg = lcd.rgb(240, 240, 240),
    .selected_bg = lcd.rgb(66, 133, 244),
    .selected_fg = lcd.rgb(255, 255, 255),
    .footer_bg = lcd.rgb(40, 40, 40),
    .footer_fg = lcd.rgb(160, 160, 160),
    .accent = lcd.rgb(66, 133, 244),
    .disabled = lcd.rgb(100, 100, 100),
};

var current_theme: Theme = default_theme;

/// Set the UI theme
pub fn setTheme(theme: Theme) void {
    current_theme = theme;
}

/// Get current theme
pub fn getTheme() Theme {
    return current_theme;
}

// ============================================================
// Menu Item
// ============================================================

pub const MenuItemType = enum {
    action, // Triggers a callback when selected
    submenu, // Opens another menu
    toggle, // Boolean toggle
    value, // Displays a value (read-only or editable)
    separator, // Visual separator
};

pub const MenuItem = struct {
    label: []const u8,
    item_type: MenuItemType = .action,
    icon: ?[]const u8 = null, // Optional icon/prefix
    enabled: bool = true,

    // For toggle items
    toggle_state: bool = false,

    // For value items
    value_str: ?[]const u8 = null,

    // Callback when item is selected
    on_select: ?*const fn () void = null,

    // For submenu items
    submenu: ?*Menu = null,
};

// ============================================================
// Menu
// ============================================================

pub const Menu = struct {
    title: []const u8,
    items: []MenuItem,
    selected_index: u8 = 0,
    scroll_offset: u8 = 0,
    parent: ?*Menu = null,

    /// Move selection up
    pub fn selectPrevious(self: *Menu) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;

            // Skip separators
            while (self.selected_index > 0 and
                self.items[self.selected_index].item_type == .separator)
            {
                self.selected_index -= 1;
            }

            // Adjust scroll
            if (self.selected_index < self.scroll_offset) {
                self.scroll_offset = self.selected_index;
            }
        }
    }

    /// Move selection down
    pub fn selectNext(self: *Menu) void {
        if (self.selected_index < self.items.len - 1) {
            self.selected_index += 1;

            // Skip separators
            while (self.selected_index < self.items.len - 1 and
                self.items[self.selected_index].item_type == .separator)
            {
                self.selected_index += 1;
            }

            // Adjust scroll
            if (self.selected_index >= self.scroll_offset + MAX_VISIBLE_ITEMS) {
                self.scroll_offset = self.selected_index - MAX_VISIBLE_ITEMS + 1;
            }
        }
    }

    /// Select item at index
    pub fn selectIndex(self: *Menu, index: u8) void {
        if (index < self.items.len and self.items[index].item_type != .separator) {
            self.selected_index = index;

            // Adjust scroll to show selected item
            if (index < self.scroll_offset) {
                self.scroll_offset = index;
            } else if (index >= self.scroll_offset + MAX_VISIBLE_ITEMS) {
                self.scroll_offset = index - MAX_VISIBLE_ITEMS + 1;
            }
        }
    }

    /// Get currently selected item
    pub fn getSelected(self: *Menu) *MenuItem {
        return &self.items[self.selected_index];
    }

    /// Activate the selected item
    pub fn activate(self: *Menu) ?*Menu {
        var item = self.getSelected();

        if (!item.enabled) return null;

        switch (item.item_type) {
            .action => {
                if (item.on_select) |callback| {
                    callback();
                }
                return null;
            },
            .submenu => {
                if (item.submenu) |submenu| {
                    submenu.parent = self;
                    return submenu;
                }
                return null;
            },
            .toggle => {
                item.toggle_state = !item.toggle_state;
                if (item.on_select) |callback| {
                    callback();
                }
                return null;
            },
            .value => {
                if (item.on_select) |callback| {
                    callback();
                }
                return null;
            },
            .separator => return null,
        }
    }

    /// Go back to parent menu
    pub fn goBack(self: *Menu) ?*Menu {
        return self.parent;
    }
};

// ============================================================
// Drawing Functions
// ============================================================

/// Draw the header bar
pub fn drawHeader(title: []const u8) void {
    lcd.fillRect(0, 0, SCREEN_WIDTH, HEADER_HEIGHT, current_theme.header_bg);
    lcd.drawStringCentered(8, title, current_theme.header_fg, current_theme.header_bg);
    lcd.drawHLine(0, HEADER_HEIGHT - 1, SCREEN_WIDTH, current_theme.disabled);
}

/// Draw the footer bar
pub fn drawFooter(text: []const u8) void {
    const y = SCREEN_HEIGHT - FOOTER_HEIGHT;
    lcd.fillRect(0, y, SCREEN_WIDTH, FOOTER_HEIGHT, current_theme.footer_bg);
    lcd.drawHLine(0, y, SCREEN_WIDTH, current_theme.disabled);
    lcd.drawStringCentered(y + 6, text, current_theme.footer_fg, current_theme.footer_bg);
}

/// Draw a menu
pub fn drawMenu(menu: *Menu) void {
    // Clear content area
    lcd.fillRect(0, CONTENT_START_Y, SCREEN_WIDTH, CONTENT_HEIGHT, current_theme.background);

    // Draw header
    drawHeader(menu.title);

    // Draw visible menu items
    const visible_count = @min(@as(u8, @intCast(menu.items.len)) - menu.scroll_offset, MAX_VISIBLE_ITEMS);

    for (0..visible_count) |i| {
        const item_index = menu.scroll_offset + @as(u8, @intCast(i));
        const item = menu.items[item_index];
        const y: u16 = CONTENT_START_Y + @as(u16, @intCast(i)) * MENU_ITEM_HEIGHT;
        const is_selected = item_index == menu.selected_index;

        drawMenuItem(y, item, is_selected);
    }

    // Draw scroll indicators if needed
    if (menu.scroll_offset > 0) {
        // Up arrow indicator
        lcd.drawString(SCREEN_WIDTH - 16, CONTENT_START_Y, "^", current_theme.accent, null);
    }
    if (menu.scroll_offset + MAX_VISIBLE_ITEMS < menu.items.len) {
        // Down arrow indicator
        lcd.drawString(SCREEN_WIDTH - 16, SCREEN_HEIGHT - FOOTER_HEIGHT - 10, "v", current_theme.accent, null);
    }

    // Draw footer with hint
    drawFooter("Select: OK  Menu: Back");
}

/// Draw a single menu item
fn drawMenuItem(y: u16, item: MenuItem, selected: bool) void {
    const bg = if (selected) current_theme.selected_bg else current_theme.background;
    const fg = if (!item.enabled)
        current_theme.disabled
    else if (selected)
        current_theme.selected_fg
    else
        current_theme.foreground;

    // Background
    lcd.fillRect(0, y, SCREEN_WIDTH, MENU_ITEM_HEIGHT, bg);

    if (item.item_type == .separator) {
        // Draw separator line
        lcd.drawHLine(20, y + MENU_ITEM_HEIGHT / 2, SCREEN_WIDTH - 40, current_theme.disabled);
        return;
    }

    // Icon/prefix (if any)
    var x: u16 = 10;
    if (item.icon) |icon| {
        lcd.drawString(x, y + 6, icon, fg, bg);
        x += @intCast(icon.len * CHAR_WIDTH + 4);
    }

    // Label
    lcd.drawString(x, y + 6, item.label, fg, bg);

    // Right side content based on type
    switch (item.item_type) {
        .toggle => {
            const toggle_str = if (item.toggle_state) "[X]" else "[ ]";
            lcd.drawString(SCREEN_WIDTH - 40, y + 6, toggle_str, fg, bg);
        },
        .value => {
            if (item.value_str) |val| {
                const val_x = SCREEN_WIDTH - @as(u16, @intCast(val.len * CHAR_WIDTH + 10));
                lcd.drawString(val_x, y + 6, val, fg, bg);
            }
        },
        .submenu => {
            lcd.drawString(SCREEN_WIDTH - 16, y + 6, ">", fg, bg);
        },
        else => {},
    }
}

/// Draw a message box
pub fn drawMessageBox(title: []const u8, message: []const u8) void {
    const box_width: u16 = 280;
    const box_height: u16 = 100;
    const box_x: u16 = (SCREEN_WIDTH - box_width) / 2;
    const box_y: u16 = (SCREEN_HEIGHT - box_height) / 2;

    // Shadow
    lcd.fillRect(box_x + 4, box_y + 4, box_width, box_height, current_theme.disabled);

    // Box background
    lcd.fillRect(box_x, box_y, box_width, box_height, current_theme.background);

    // Border
    lcd.drawRect(box_x, box_y, box_width, box_height, current_theme.foreground);

    // Title bar
    lcd.fillRect(box_x + 1, box_y + 1, box_width - 2, 20, current_theme.header_bg);
    lcd.drawString(box_x + 10, box_y + 6, title, current_theme.header_fg, current_theme.header_bg);

    // Message
    lcd.drawString(box_x + 10, box_y + 40, message, current_theme.foreground, current_theme.background);
}

/// Draw a progress indicator
pub fn drawProgress(y: u16, progress: u8, label: []const u8) void {
    const bar_x: u16 = 20;
    const bar_width: u16 = SCREEN_WIDTH - 40;
    const bar_height: u16 = 16;

    // Label
    lcd.drawStringCentered(y, label, current_theme.foreground, null);

    // Progress bar
    lcd.drawProgressBar(bar_x, y + 12, bar_width, bar_height, progress, current_theme.accent, current_theme.background);
}

// ============================================================
// Now Playing Screen
// ============================================================

pub const NowPlayingInfo = struct {
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    current_time_str: []const u8,
    total_time_str: []const u8,
    progress_percent: u8,
    is_playing: bool,
};

/// Draw the "Now Playing" screen
pub fn drawNowPlaying(info: NowPlayingInfo) void {
    // Clear screen
    lcd.clear(current_theme.background);

    // Draw header
    drawHeader("Now Playing");

    // Track info
    const title_y: u16 = 50;
    lcd.drawStringCentered(title_y, info.title, current_theme.foreground, null);
    lcd.drawStringCentered(title_y + 16, info.artist, current_theme.disabled, null);
    lcd.drawStringCentered(title_y + 32, info.album, current_theme.disabled, null);

    // Progress bar
    const progress_y: u16 = 140;
    lcd.drawProgressBar(20, progress_y, SCREEN_WIDTH - 40, 10, info.progress_percent, current_theme.accent, current_theme.disabled);

    // Time display
    lcd.drawString(20, progress_y + 14, info.current_time_str, current_theme.foreground, null);

    const total_x = SCREEN_WIDTH - @as(u16, @intCast(info.total_time_str.len * CHAR_WIDTH + 20));
    lcd.drawString(total_x, progress_y + 14, info.total_time_str, current_theme.foreground, null);

    // Play/Pause indicator
    const indicator = if (info.is_playing) "||" else ">";
    lcd.drawStringCentered(180, indicator, current_theme.accent, null);

    // Footer
    drawFooter("Menu: Options");
}

// ============================================================
// Input Handling
// ============================================================

/// Process input for a menu and return the new active menu (if changed)
pub fn handleMenuInput(menu: *Menu, input: clickwheel.InputEvent) ?*Menu {
    // Check for wheel scrolling
    if (input.wheel_delta > 0) {
        // Clockwise - scroll down
        const steps = @abs(input.wheel_delta) / 4 + 1;
        var i: u8 = 0;
        while (i < steps) : (i += 1) {
            menu.selectNext();
        }
    } else if (input.wheel_delta < 0) {
        // Counter-clockwise - scroll up
        const steps = @abs(input.wheel_delta) / 4 + 1;
        var i: u8 = 0;
        while (i < steps) : (i += 1) {
            menu.selectPrevious();
        }
    }

    // Check for button presses
    if (input.buttonPressed(clickwheel.Button.SELECT)) {
        return menu.activate();
    }

    if (input.buttonPressed(clickwheel.Button.MENU)) {
        return menu.goBack();
    }

    if (input.buttonPressed(clickwheel.Button.RIGHT)) {
        // Right acts like select for submenus
        if (menu.getSelected().item_type == .submenu) {
            return menu.activate();
        }
    }

    if (input.buttonPressed(clickwheel.Button.LEFT)) {
        return menu.goBack();
    }

    return menu; // Stay on current menu
}

// ============================================================
// UI Manager
// ============================================================

pub const ScreenType = enum {
    menu,
    now_playing,
    message,
    custom,
};

pub const UIState = struct {
    current_screen: ScreenType = .menu,
    current_menu: ?*Menu = null,
    needs_redraw: bool = true,

    pub fn setMenu(self: *UIState, menu: *Menu) void {
        self.current_menu = menu;
        self.current_screen = .menu;
        self.needs_redraw = true;
    }

    pub fn showNowPlaying(self: *UIState) void {
        self.current_screen = .now_playing;
        self.needs_redraw = true;
    }

    pub fn requestRedraw(self: *UIState) void {
        self.needs_redraw = true;
    }
};

var ui_state = UIState{};

/// Get the UI state
pub fn getState() *UIState {
    return &ui_state;
}

/// Initialize the UI
pub fn init() hal.HalError!void {
    try lcd.init();
    lcd.setBacklight(true);
    lcd.clear(current_theme.background);
}

// ============================================================
// Overlay System
// ============================================================

/// Overlay types
pub const OverlayType = enum {
    none,
    volume,
    brightness,
    hold,
    low_battery,
    charging,
};

/// Overlay display state
pub const OverlayState = struct {
    overlay_type: OverlayType = .none,
    value: u8 = 0, // 0-100 for volume/brightness
    show_time: u32 = 0, // Timestamp when overlay was shown
    duration_ms: u32 = 1500, // How long to show overlay

    /// Check if overlay should still be visible
    pub fn isVisible(self: *const OverlayState, current_time: u32) bool {
        if (self.overlay_type == .none) return false;
        return (current_time - self.show_time) < self.duration_ms;
    }

    /// Show volume overlay
    pub fn showVolume(self: *OverlayState, volume: u8, timestamp: u32) void {
        self.overlay_type = .volume;
        self.value = volume;
        self.show_time = timestamp;
    }

    /// Show brightness overlay
    pub fn showBrightness(self: *OverlayState, brightness: u8, timestamp: u32) void {
        self.overlay_type = .brightness;
        self.value = brightness;
        self.show_time = timestamp;
    }

    /// Show hold switch indicator
    pub fn showHold(self: *OverlayState, timestamp: u32) void {
        self.overlay_type = .hold;
        self.show_time = timestamp;
        self.duration_ms = 2000;
    }

    /// Show low battery warning
    pub fn showLowBattery(self: *OverlayState, percent: u8, timestamp: u32) void {
        self.overlay_type = .low_battery;
        self.value = percent;
        self.show_time = timestamp;
        self.duration_ms = 3000;
    }

    /// Show charging indicator
    pub fn showCharging(self: *OverlayState, percent: u8, timestamp: u32) void {
        self.overlay_type = .charging;
        self.value = percent;
        self.show_time = timestamp;
    }

    /// Hide overlay
    pub fn hide(self: *OverlayState) void {
        self.overlay_type = .none;
    }
};

var overlay_state = OverlayState{};

/// Get overlay state
pub fn getOverlay() *OverlayState {
    return &overlay_state;
}

/// Draw the current overlay (if visible)
pub fn drawOverlay(current_time: u32) void {
    if (!overlay_state.isVisible(current_time)) return;

    switch (overlay_state.overlay_type) {
        .volume => drawVolumeOverlay(overlay_state.value),
        .brightness => drawBrightnessOverlay(overlay_state.value),
        .hold => drawHoldOverlay(),
        .low_battery => drawLowBatteryOverlay(overlay_state.value),
        .charging => drawChargingOverlay(overlay_state.value),
        .none => {},
    }
}

/// Draw volume overlay
fn drawVolumeOverlay(volume: u8) void {
    const box_width: u16 = 180;
    const box_height: u16 = 70;
    const box_x: u16 = (SCREEN_WIDTH - box_width) / 2;
    const box_y: u16 = (SCREEN_HEIGHT - box_height) / 2;

    // Semi-transparent overlay effect (dark background)
    lcd.fillRect(box_x, box_y, box_width, box_height, lcd.rgb(30, 30, 30));
    lcd.drawRect(box_x, box_y, box_width, box_height, current_theme.accent);

    // Speaker icon (simple representation)
    const icon_x = box_x + 15;
    const icon_y = box_y + 25;
    lcd.fillRect(icon_x, icon_y, 8, 20, lcd.rgb(200, 200, 200));
    lcd.fillRect(icon_x + 8, icon_y - 5, 10, 30, lcd.rgb(200, 200, 200));

    // Volume label
    lcd.drawString(icon_x + 30, box_y + 12, "Volume", lcd.rgb(200, 200, 200), lcd.rgb(30, 30, 30));

    // Volume bar
    const bar_x: u16 = box_x + 40;
    const bar_y: u16 = box_y + 35;
    const bar_width: u16 = 120;
    const bar_height: u16 = 20;

    // Background bar
    lcd.fillRect(bar_x, bar_y, bar_width, bar_height, lcd.rgb(60, 60, 60));

    // Filled portion
    const filled_width: u16 = (bar_width * volume) / 100;
    if (filled_width > 0) {
        lcd.fillRect(bar_x, bar_y, filled_width, bar_height, current_theme.accent);
    }

    // Volume percentage
    var buf: [4]u8 = undefined;
    const percent_str = formatNumber(volume, &buf);
    lcd.drawString(bar_x + bar_width + 5, bar_y + 6, percent_str, lcd.rgb(200, 200, 200), lcd.rgb(30, 30, 30));
}

/// Draw brightness overlay
fn drawBrightnessOverlay(brightness: u8) void {
    const box_width: u16 = 180;
    const box_height: u16 = 70;
    const box_x: u16 = (SCREEN_WIDTH - box_width) / 2;
    const box_y: u16 = (SCREEN_HEIGHT - box_height) / 2;

    lcd.fillRect(box_x, box_y, box_width, box_height, lcd.rgb(30, 30, 30));
    lcd.drawRect(box_x, box_y, box_width, box_height, current_theme.accent);

    // Sun icon (simple circle)
    const icon_x = box_x + 15;
    const icon_y = box_y + 25;
    lcd.fillRect(icon_x + 5, icon_y + 5, 10, 10, lcd.rgb(255, 200, 0));

    // Brightness label
    lcd.drawString(icon_x + 30, box_y + 12, "Brightness", lcd.rgb(200, 200, 200), lcd.rgb(30, 30, 30));

    // Brightness bar
    const bar_x: u16 = box_x + 40;
    const bar_y: u16 = box_y + 35;
    const bar_width: u16 = 120;
    const bar_height: u16 = 20;

    lcd.fillRect(bar_x, bar_y, bar_width, bar_height, lcd.rgb(60, 60, 60));

    const filled_width: u16 = (bar_width * brightness) / 100;
    if (filled_width > 0) {
        lcd.fillRect(bar_x, bar_y, filled_width, bar_height, lcd.rgb(255, 200, 0));
    }

    var buf: [4]u8 = undefined;
    const percent_str = formatNumber(brightness, &buf);
    lcd.drawString(bar_x + bar_width + 5, bar_y + 6, percent_str, lcd.rgb(200, 200, 200), lcd.rgb(30, 30, 30));
}

/// Draw hold switch overlay
fn drawHoldOverlay() void {
    const box_width: u16 = 160;
    const box_height: u16 = 60;
    const box_x: u16 = (SCREEN_WIDTH - box_width) / 2;
    const box_y: u16 = (SCREEN_HEIGHT - box_height) / 2;

    lcd.fillRect(box_x, box_y, box_width, box_height, lcd.rgb(40, 40, 40));
    lcd.drawRect(box_x, box_y, box_width, box_height, lcd.rgb(255, 165, 0));

    // Lock icon (simple padlock shape)
    const lock_x = box_x + 20;
    const lock_y = box_y + 20;
    lcd.drawRect(lock_x, lock_y - 8, 16, 10, lcd.rgb(255, 165, 0));
    lcd.fillRect(lock_x - 2, lock_y, 20, 20, lcd.rgb(255, 165, 0));

    lcd.drawString(lock_x + 35, box_y + 22, "Hold On", lcd.rgb(255, 165, 0), lcd.rgb(40, 40, 40));
}

/// Draw low battery warning overlay
fn drawLowBatteryOverlay(percent: u8) void {
    const box_width: u16 = 200;
    const box_height: u16 = 70;
    const box_x: u16 = (SCREEN_WIDTH - box_width) / 2;
    const box_y: u16 = (SCREEN_HEIGHT - box_height) / 2;

    lcd.fillRect(box_x, box_y, box_width, box_height, lcd.rgb(50, 20, 20));
    lcd.drawRect(box_x, box_y, box_width, box_height, lcd.rgb(255, 50, 50));

    // Battery icon
    drawBatteryIcon(box_x + 15, box_y + 20, percent, true);

    lcd.drawString(box_x + 55, box_y + 15, "Low Battery", lcd.rgb(255, 100, 100), lcd.rgb(50, 20, 20));

    var buf: [8]u8 = undefined;
    const percent_str = formatNumber(percent, buf[0..4]);
    lcd.drawString(box_x + 55, box_y + 35, percent_str, lcd.rgb(200, 200, 200), lcd.rgb(50, 20, 20));
    lcd.drawString(box_x + 80, box_y + 35, "% remaining", lcd.rgb(200, 200, 200), lcd.rgb(50, 20, 20));
}

/// Draw charging indicator overlay
fn drawChargingOverlay(percent: u8) void {
    const box_width: u16 = 180;
    const box_height: u16 = 70;
    const box_x: u16 = (SCREEN_WIDTH - box_width) / 2;
    const box_y: u16 = (SCREEN_HEIGHT - box_height) / 2;

    lcd.fillRect(box_x, box_y, box_width, box_height, lcd.rgb(20, 40, 20));
    lcd.drawRect(box_x, box_y, box_width, box_height, lcd.rgb(50, 200, 50));

    // Battery icon with lightning bolt
    drawBatteryIcon(box_x + 15, box_y + 20, percent, false);

    lcd.drawString(box_x + 55, box_y + 15, "Charging", lcd.rgb(100, 255, 100), lcd.rgb(20, 40, 20));

    var buf: [4]u8 = undefined;
    const percent_str = formatNumber(percent, &buf);
    lcd.drawString(box_x + 55, box_y + 35, percent_str, lcd.rgb(200, 200, 200), lcd.rgb(20, 40, 20));
    lcd.drawString(box_x + 80, box_y + 35, "%", lcd.rgb(200, 200, 200), lcd.rgb(20, 40, 20));
}

// ============================================================
// Status Bar Indicators
// ============================================================

/// Battery status
pub const BatteryStatus = struct {
    percent: u8 = 100,
    is_charging: bool = false,
    is_low: bool = false,
};

var battery_status = BatteryStatus{};

/// Update battery status
pub fn updateBatteryStatus(percent: u8, charging: bool) void {
    battery_status.percent = percent;
    battery_status.is_charging = charging;
    battery_status.is_low = percent <= 20;
}

/// Get current battery status
pub fn getBatteryStatus() BatteryStatus {
    return battery_status;
}

/// Draw battery icon at specified position
pub fn drawBatteryIcon(x: u16, y: u16, percent: u8, low: bool) void {
    // Battery outline (28x14 pixels)
    const width: u16 = 28;
    const height: u16 = 14;

    // Choose color based on state
    const color = if (low)
        lcd.rgb(255, 50, 50)
    else if (percent < 30)
        lcd.rgb(255, 165, 0)
    else
        lcd.rgb(100, 200, 100);

    // Outline
    lcd.drawRect(x, y, width, height, color);

    // Terminal nub
    lcd.fillRect(x + width, y + 4, 3, 6, color);

    // Fill level (inside the outline)
    const inner_width = width - 4;
    const fill_width: u16 = (inner_width * percent) / 100;
    if (fill_width > 0) {
        lcd.fillRect(x + 2, y + 2, fill_width, height - 4, color);
    }
}

/// Draw status bar with battery and other indicators
pub fn drawStatusBar() void {
    // Battery icon in top-right corner
    const battery_x = SCREEN_WIDTH - 40;
    const battery_y: u16 = 5;
    drawBatteryIcon(battery_x, battery_y, battery_status.percent, battery_status.is_low);

    // Charging indicator (lightning bolt)
    if (battery_status.is_charging) {
        lcd.drawString(battery_x - 12, battery_y, "+", lcd.rgb(50, 200, 50), current_theme.header_bg);
    }
}

/// Draw header with status bar
pub fn drawHeaderWithStatus(title: []const u8) void {
    lcd.fillRect(0, 0, SCREEN_WIDTH, HEADER_HEIGHT, current_theme.header_bg);

    // Title (left-aligned to leave room for status)
    lcd.drawString(8, 8, title, current_theme.header_fg, current_theme.header_bg);

    // Status indicators on the right
    drawStatusBar();

    lcd.drawHLine(0, HEADER_HEIGHT - 1, SCREEN_WIDTH, current_theme.disabled);
}

// ============================================================
// Helper Functions
// ============================================================

/// Format a number as a string (up to 3 digits)
fn formatNumber(value: u8, buf: []u8) []const u8 {
    if (value >= 100) {
        buf[0] = '1';
        buf[1] = '0';
        buf[2] = '0';
        return buf[0..3];
    } else if (value >= 10) {
        buf[0] = '0' + (value / 10);
        buf[1] = '0' + (value % 10);
        return buf[0..2];
    } else {
        buf[0] = '0' + value;
        return buf[0..1];
    }
}

// ============================================================
// Tests
// ============================================================

test "menu navigation" {
    var items = [_]MenuItem{
        .{ .label = "Item 1" },
        .{ .label = "Item 2" },
        .{ .label = "Item 3" },
    };

    var menu = Menu{
        .title = "Test Menu",
        .items = &items,
    };

    try std.testing.expectEqual(@as(u8, 0), menu.selected_index);

    menu.selectNext();
    try std.testing.expectEqual(@as(u8, 1), menu.selected_index);

    menu.selectNext();
    try std.testing.expectEqual(@as(u8, 2), menu.selected_index);

    menu.selectNext(); // Should stay at 2
    try std.testing.expectEqual(@as(u8, 2), menu.selected_index);

    menu.selectPrevious();
    try std.testing.expectEqual(@as(u8, 1), menu.selected_index);
}

test "menu separator skip" {
    var items = [_]MenuItem{
        .{ .label = "Item 1" },
        .{ .label = "", .item_type = .separator },
        .{ .label = "Item 2" },
    };

    var menu = Menu{
        .title = "Test",
        .items = &items,
    };

    menu.selectNext(); // Should skip separator and go to Item 2
    try std.testing.expectEqual(@as(u8, 2), menu.selected_index);

    menu.selectPrevious(); // Should skip separator and go back to Item 1
    try std.testing.expectEqual(@as(u8, 0), menu.selected_index);
}

test "toggle item" {
    var items = [_]MenuItem{
        .{ .label = "Toggle", .item_type = .toggle, .toggle_state = false },
    };

    var menu = Menu{
        .title = "Test",
        .items = &items,
    };

    try std.testing.expect(!menu.items[0].toggle_state);

    _ = menu.activate(); // Toggle it
    try std.testing.expect(menu.items[0].toggle_state);

    _ = menu.activate(); // Toggle again
    try std.testing.expect(!menu.items[0].toggle_state);
}

test "theme colors" {
    const theme = default_theme;
    try std.testing.expectEqual(lcd.rgb(255, 255, 255), theme.background);
    try std.testing.expectEqual(lcd.rgb(0, 0, 0), theme.foreground);
}

test "overlay visibility" {
    var overlay = OverlayState{};

    // Initially not visible
    try std.testing.expect(!overlay.isVisible(0));

    // Show volume overlay
    overlay.showVolume(50, 1000);
    try std.testing.expect(overlay.isVisible(1000));
    try std.testing.expect(overlay.isVisible(1500)); // Still within duration
    try std.testing.expect(overlay.isVisible(2400)); // Still within 1500ms duration
    try std.testing.expect(!overlay.isVisible(2600)); // After duration

    // Hide overlay
    overlay.hide();
    try std.testing.expect(!overlay.isVisible(2600));
}

test "overlay types" {
    var overlay = OverlayState{};

    overlay.showVolume(75, 0);
    try std.testing.expectEqual(OverlayType.volume, overlay.overlay_type);
    try std.testing.expectEqual(@as(u8, 75), overlay.value);

    overlay.showBrightness(50, 0);
    try std.testing.expectEqual(OverlayType.brightness, overlay.overlay_type);

    overlay.showHold(0);
    try std.testing.expectEqual(OverlayType.hold, overlay.overlay_type);
    try std.testing.expectEqual(@as(u32, 2000), overlay.duration_ms);

    overlay.showLowBattery(15, 0);
    try std.testing.expectEqual(OverlayType.low_battery, overlay.overlay_type);
    try std.testing.expectEqual(@as(u32, 3000), overlay.duration_ms);

    overlay.showCharging(80, 0);
    try std.testing.expectEqual(OverlayType.charging, overlay.overlay_type);
}

test "battery status" {
    updateBatteryStatus(100, false);
    var status = getBatteryStatus();
    try std.testing.expectEqual(@as(u8, 100), status.percent);
    try std.testing.expect(!status.is_charging);
    try std.testing.expect(!status.is_low);

    updateBatteryStatus(15, true);
    status = getBatteryStatus();
    try std.testing.expectEqual(@as(u8, 15), status.percent);
    try std.testing.expect(status.is_charging);
    try std.testing.expect(status.is_low); // <= 20%
}

test "format number" {
    var buf: [4]u8 = undefined;

    const one = formatNumber(5, &buf);
    try std.testing.expectEqualStrings("5", one);

    const two = formatNumber(42, &buf);
    try std.testing.expectEqualStrings("42", two);

    const three = formatNumber(100, &buf);
    try std.testing.expectEqualStrings("100", three);
}
