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
pub const settings = @import("settings.zig");
pub const system_info = @import("system_info.zig");

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
