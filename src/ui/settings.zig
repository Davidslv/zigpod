//! Settings Menu
//!
//! System settings and preferences for ZigPod OS.
//! Includes display, audio, playback, and system settings.

const std = @import("std");
const ui = @import("ui.zig");
const lcd = @import("../drivers/display/lcd.zig");
const audio = @import("../audio/audio.zig");
const codec = @import("../drivers/audio/codec.zig");
const theme_loader = @import("theme_loader.zig");

// ============================================================
// Settings Storage
// ============================================================

pub const Settings = struct {
    // Display settings
    brightness: u8 = 80, // 0-100
    backlight_timeout: u16 = 30, // seconds, 0 = always on
    theme_index: u8 = 0, // Index into ThemeRegistry (0=light, 1=dark, 2+=custom)

    // Audio settings
    volume: i16 = -10, // dB (-89 to +6)
    bass: i8 = 0, // dB (-12 to +12)
    treble: i8 = 0, // dB (-12 to +12)
    bass_cutoff: BassFrequency = .hz_200,
    treble_cutoff: TrebleFrequency = .hz_4k,
    channel_mix: ChannelMix = .stereo,

    // Playback settings
    shuffle: bool = false,
    repeat: RepeatMode = .off,
    gapless: bool = true, // Enable gapless playback
    replay_gain: ReplayGainMode = .off,

    // System settings
    sleep_timer: u16 = 0, // minutes, 0 = off
    hold_action: HoldAction = .lock,
    language: Language = .english,

    // Apply audio settings to codec
    // Note: Audio setting errors are non-fatal - playback continues with defaults
    pub fn applyAudioSettings(self: *const Settings) void {
        // Volume setting failed - continue with current volume
        audio.setVolumeMono(self.volume) catch {};
        // Bass/treble settings - continue with current levels on failure
        codec.setBass(self.bass) catch {};
        codec.setTreble(self.treble) catch {};
        _ = self.bass_cutoff; // TODO: Implement cutoff frequency setting
        _ = self.treble_cutoff;
    }

    // Apply display settings using theme registry
    pub fn applyDisplaySettings(self: *const Settings) void {
        // TODO: Implement LCD brightness control when hardware supports it
        _ = self.brightness;
        // Apply theme from registry
        theme_loader.getRegistry().selectTheme(self.theme_index);
    }

    /// Get current theme name for display
    pub fn getThemeName(self: *const Settings) []const u8 {
        return theme_loader.getRegistry().getThemeName(self.theme_index);
    }
};

pub const ThemeChoice = enum {
    light,
    dark,

    pub fn toString(self: ThemeChoice) []const u8 {
        return switch (self) {
            .light => "Light",
            .dark => "Dark",
        };
    }

    pub fn next(self: ThemeChoice) ThemeChoice {
        return switch (self) {
            .light => .dark,
            .dark => .light,
        };
    }
};

pub const RepeatMode = enum {
    off,
    one,
    all,

    pub fn toString(self: RepeatMode) []const u8 {
        return switch (self) {
            .off => "Off",
            .one => "One",
            .all => "All",
        };
    }

    pub fn next(self: RepeatMode) RepeatMode {
        return switch (self) {
            .off => .one,
            .one => .all,
            .all => .off,
        };
    }
};

pub const BassFrequency = enum {
    hz_130,
    hz_200,

    pub fn toString(self: BassFrequency) []const u8 {
        return switch (self) {
            .hz_130 => "130 Hz",
            .hz_200 => "200 Hz",
        };
    }

    pub fn next(self: BassFrequency) BassFrequency {
        return switch (self) {
            .hz_130 => .hz_200,
            .hz_200 => .hz_130,
        };
    }
};

pub const TrebleFrequency = enum {
    hz_4k,
    hz_8k,

    pub fn toString(self: TrebleFrequency) []const u8 {
        return switch (self) {
            .hz_4k => "4 kHz",
            .hz_8k => "8 kHz",
        };
    }

    pub fn next(self: TrebleFrequency) TrebleFrequency {
        return switch (self) {
            .hz_4k => .hz_8k,
            .hz_8k => .hz_4k,
        };
    }
};

pub const ChannelMix = enum {
    stereo,
    mono,
    swap,

    pub fn toString(self: ChannelMix) []const u8 {
        return switch (self) {
            .stereo => "Stereo",
            .mono => "Mono",
            .swap => "Swap L/R",
        };
    }

    pub fn next(self: ChannelMix) ChannelMix {
        return switch (self) {
            .stereo => .mono,
            .mono => .swap,
            .swap => .stereo,
        };
    }
};

pub const ReplayGainMode = enum {
    off,
    track,
    album,

    pub fn toString(self: ReplayGainMode) []const u8 {
        return switch (self) {
            .off => "Off",
            .track => "Track",
            .album => "Album",
        };
    }

    pub fn next(self: ReplayGainMode) ReplayGainMode {
        return switch (self) {
            .off => .track,
            .track => .album,
            .album => .off,
        };
    }
};

pub const HoldAction = enum {
    lock,
    pause,

    pub fn toString(self: HoldAction) []const u8 {
        return switch (self) {
            .lock => "Lock Controls",
            .pause => "Pause Playback",
        };
    }

    pub fn next(self: HoldAction) HoldAction {
        return switch (self) {
            .lock => .pause,
            .pause => .lock,
        };
    }
};

pub const Language = enum {
    english,
    spanish,
    french,
    german,

    pub fn toString(self: Language) []const u8 {
        return switch (self) {
            .english => "English",
            .spanish => "Español",
            .french => "Français",
            .german => "Deutsch",
        };
    }

    pub fn next(self: Language) Language {
        return switch (self) {
            .english => .spanish,
            .spanish => .french,
            .french => .german,
            .german => .english,
        };
    }
};

// ============================================================
// Global Settings Instance
// ============================================================

var current_settings = Settings{};

pub fn getSettings() *Settings {
    return &current_settings;
}

// ============================================================
// Settings Menus
// ============================================================

/// Settings menu categories
pub const SettingsCategory = enum {
    main,
    display,
    audio,
    playback,
    system,
    about,
};

// ============================================================
// Settings Browser State
// ============================================================

pub const SettingsBrowser = struct {
    category: SettingsCategory = .main,
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    editing: bool = false, // True when adjusting a value

    /// Initialize browser
    pub fn init() SettingsBrowser {
        return SettingsBrowser{};
    }

    /// Get item count for current category
    pub fn getItemCount(self: *const SettingsBrowser) usize {
        return switch (self.category) {
            .main => 6, // Display, Audio, Playback, System, separator, About
            .display => 3, // Brightness, Backlight timeout, Theme
            .audio => 4, // Volume, Bass, Treble, Channel
            .playback => 4, // Shuffle, Repeat, Gapless, ReplayGain
            .system => 3, // Sleep timer, Hold action, Language
            .about => 0,
        };
    }

    /// Move selection up
    pub fn selectPrevious(self: *SettingsBrowser) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
        }
    }

    /// Move selection down
    pub fn selectNext(self: *SettingsBrowser) void {
        const count = self.getItemCount();
        if (self.selected_index + 1 < count) {
            self.selected_index += 1;
        }
    }

    /// Go back to previous level
    pub fn goBack(self: *SettingsBrowser) SettingsAction {
        if (self.editing) {
            self.editing = false;
            return .none;
        }

        switch (self.category) {
            .main => return .exit,
            else => {
                self.category = .main;
                self.selected_index = 0;
                self.scroll_offset = 0;
                return .none;
            },
        }
    }

    /// Handle selection
    pub fn select(self: *SettingsBrowser) SettingsAction {
        if (self.editing) {
            self.editing = false;
            return .none;
        }

        return switch (self.category) {
            .main => self.handleMainSelect(),
            .display => self.handleDisplaySelect(),
            .audio => self.handleAudioSelect(),
            .playback => self.handlePlaybackSelect(),
            .system => self.handleSystemSelect(),
            .about => .none,
        };
    }

    fn handleMainSelect(self: *SettingsBrowser) SettingsAction {
        switch (self.selected_index) {
            0 => { // Display
                self.category = .display;
                self.selected_index = 0;
            },
            1 => { // Audio
                self.category = .audio;
                self.selected_index = 0;
            },
            2 => { // Playback
                self.category = .playback;
                self.selected_index = 0;
            },
            3 => { // System
                self.category = .system;
                self.selected_index = 0;
            },
            // 4 is separator
            5 => { // About
                return .show_about;
            },
            else => {},
        }
        return .none;
    }

    fn handleDisplaySelect(self: *SettingsBrowser) SettingsAction {
        switch (self.selected_index) {
            0 => self.editing = true, // Brightness
            1 => self.editing = true, // Backlight timeout
            2 => { // Theme - cycle
                cycleTheme();
            },
            else => {},
        }
        return .none;
    }

    fn handleAudioSelect(self: *SettingsBrowser) SettingsAction {
        switch (self.selected_index) {
            0 => self.editing = true, // Volume
            1 => self.editing = true, // Bass
            2 => self.editing = true, // Treble
            3 => { // Channel - cycle
                const settings = getSettings();
                settings.channel_mix = settings.channel_mix.next();
            },
            else => {},
        }
        return .none;
    }

    fn handlePlaybackSelect(self: *SettingsBrowser) SettingsAction {
        switch (self.selected_index) {
            0 => toggleShuffle(),
            1 => cycleRepeat(),
            2 => toggleGapless(),
            3 => { // ReplayGain - cycle
                const settings = getSettings();
                settings.replay_gain = settings.replay_gain.next();
            },
            else => {},
        }
        return .none;
    }

    fn handleSystemSelect(self: *SettingsBrowser) SettingsAction {
        switch (self.selected_index) {
            0 => self.editing = true, // Sleep timer
            1 => { // Hold action - cycle
                const settings = getSettings();
                settings.hold_action = settings.hold_action.next();
            },
            2 => { // Language - cycle
                const settings = getSettings();
                settings.language = settings.language.next();
            },
            else => {},
        }
        return .none;
    }

    /// Handle wheel for value adjustment
    pub fn adjustValue(self: *SettingsBrowser, delta: i8) void {
        if (!self.editing) return;

        switch (self.category) {
            .display => switch (self.selected_index) {
                0 => adjustBrightness(delta),
                1 => { // Backlight timeout
                    const settings = getSettings();
                    if (delta > 0) {
                        settings.backlight_timeout = @min(300, settings.backlight_timeout + 5);
                    } else {
                        settings.backlight_timeout = if (settings.backlight_timeout > 5) settings.backlight_timeout - 5 else 0;
                    }
                },
                else => {},
            },
            .audio => switch (self.selected_index) {
                0 => adjustVolume(delta),
                1 => adjustBass(delta),
                2 => adjustTreble(delta),
                else => {},
            },
            .system => switch (self.selected_index) {
                0 => { // Sleep timer
                    const settings = getSettings();
                    if (delta > 0) {
                        settings.sleep_timer = @min(120, settings.sleep_timer + 5);
                    } else {
                        settings.sleep_timer = if (settings.sleep_timer > 5) settings.sleep_timer - 5 else 0;
                    }
                },
                else => {},
            },
            else => {},
        }
    }

    /// Get title for current category
    pub fn getTitle(self: *const SettingsBrowser) []const u8 {
        return switch (self.category) {
            .main => "Settings",
            .display => "Display",
            .audio => "Audio",
            .playback => "Playback",
            .system => "System",
            .about => "About",
        };
    }
};

pub const SettingsAction = enum {
    none,
    exit,
    show_about,
};

/// Draw the settings browser screen
pub fn drawSettingsBrowser(browser: *const SettingsBrowser) void {
    const theme = ui.getTheme();
    const settings = getSettings();

    lcd.clear(theme.background);
    ui.drawHeader(browser.getTitle());

    switch (browser.category) {
        .main => {
            const items = [_][]const u8{ "Display", "Audio", "Playback", "System", "", "About ZigPod" };
            const icons = [_][]const u8{ "[D]", "[A]", "[P]", "[S]", "", "[i]" };

            for (items, 0..) |item, i| {
                const y = ui.CONTENT_START_Y + @as(u16, @intCast(i)) * ui.MENU_ITEM_HEIGHT;
                const selected = i == browser.selected_index;

                if (item.len == 0) {
                    // Separator
                    lcd.drawHLine(20, y + ui.MENU_ITEM_HEIGHT / 2, ui.SCREEN_WIDTH - 40, theme.disabled);
                    continue;
                }

                const bg = if (selected) theme.selected_bg else theme.background;
                const fg = if (selected) theme.selected_fg else theme.foreground;

                lcd.fillRect(0, y, ui.SCREEN_WIDTH, ui.MENU_ITEM_HEIGHT, bg);
                lcd.drawString(4, y + 6, icons[i], theme.disabled, bg);
                lcd.drawString(32, y + 6, item, fg, bg);
                lcd.drawString(ui.SCREEN_WIDTH - 16, y + 6, ">", theme.disabled, bg);
            }
        },
        .display => {
            drawSettingItem(0, "Brightness", formatPercent(settings.brightness), browser.selected_index == 0, browser.editing and browser.selected_index == 0, theme);
            drawSettingItem(1, "Backlight", formatTimeout(settings.backlight_timeout), browser.selected_index == 1, browser.editing and browser.selected_index == 1, theme);
            drawSettingItem(2, "Theme", settings.getThemeName(), browser.selected_index == 2, false, theme);
        },
        .audio => {
            drawSettingItem(0, "Volume", formatDb(settings.volume), browser.selected_index == 0, browser.editing and browser.selected_index == 0, theme);
            drawSettingItem(1, "Bass", formatDbSigned(settings.bass), browser.selected_index == 1, browser.editing and browser.selected_index == 1, theme);
            drawSettingItem(2, "Treble", formatDbSigned(settings.treble), browser.selected_index == 2, browser.editing and browser.selected_index == 2, theme);
            drawSettingItem(3, "Channel", settings.channel_mix.toString(), browser.selected_index == 3, false, theme);
        },
        .playback => {
            drawSettingItem(0, "Shuffle", if (settings.shuffle) "On" else "Off", browser.selected_index == 0, false, theme);
            drawSettingItem(1, "Repeat", settings.repeat.toString(), browser.selected_index == 1, false, theme);
            drawSettingItem(2, "Gapless", if (settings.gapless) "On" else "Off", browser.selected_index == 2, false, theme);
            drawSettingItem(3, "ReplayGain", settings.replay_gain.toString(), browser.selected_index == 3, false, theme);
        },
        .system => {
            drawSettingItem(0, "Sleep Timer", formatTimeout(settings.sleep_timer), browser.selected_index == 0, browser.editing and browser.selected_index == 0, theme);
            drawSettingItem(1, "Hold Action", settings.hold_action.toString(), browser.selected_index == 1, false, theme);
            drawSettingItem(2, "Language", settings.language.toString(), browser.selected_index == 2, false, theme);
        },
        .about => {},
    }

    // Footer hint
    if (browser.editing) {
        ui.drawFooter("Wheel: Adjust  Select: Done");
    } else {
        ui.drawFooter("Select: Enter  Menu: Back");
    }
}

fn drawSettingItem(index: usize, label: []const u8, value: []const u8, selected: bool, editing: bool, theme: ui.Theme) void {
    const y = ui.CONTENT_START_Y + @as(u16, @intCast(index)) * ui.MENU_ITEM_HEIGHT;
    const bg = if (selected) theme.selected_bg else theme.background;
    const fg = if (selected) theme.selected_fg else theme.foreground;
    const value_fg = if (editing) theme.accent else if (selected) fg else theme.disabled;

    lcd.fillRect(0, y, ui.SCREEN_WIDTH, ui.MENU_ITEM_HEIGHT, bg);

    // Selection indicator
    if (selected) {
        lcd.drawString(4, y + 6, ">", fg, bg);
    }

    // Label
    lcd.drawString(16, y + 6, label, fg, bg);

    // Value (right-aligned)
    const value_x = ui.SCREEN_WIDTH - @as(u16, @intCast(value.len * ui.CHAR_WIDTH + 16));
    lcd.drawString(value_x, y + 6, value, value_fg, bg);

    // Editing brackets
    if (editing) {
        lcd.drawString(value_x - 12, y + 6, "[", theme.accent, bg);
        lcd.drawString(value_x + @as(u16, @intCast(value.len * ui.CHAR_WIDTH)), y + 6, "]", theme.accent, bg);
    }
}

// Format helpers
fn formatPercent(value: u8) []const u8 {
    return formatPercentBuf(value);
}

var percent_buf: [8]u8 = undefined;
fn formatPercentBuf(value: u8) []const u8 {
    return std.fmt.bufPrint(&percent_buf, "{d}%", .{value}) catch "?";
}

fn formatTimeout(secs: u16) []const u8 {
    return formatTimeoutBuf(secs);
}

var timeout_buf: [16]u8 = undefined;
fn formatTimeoutBuf(secs: u16) []const u8 {
    if (secs == 0) return "Off";
    if (secs < 60) {
        return std.fmt.bufPrint(&timeout_buf, "{d}s", .{secs}) catch "?";
    } else {
        return std.fmt.bufPrint(&timeout_buf, "{d}m", .{secs / 60}) catch "?";
    }
}

fn formatDb(value: i16) []const u8 {
    return formatDbBuf(value);
}

var db_buf: [16]u8 = undefined;
fn formatDbBuf(value: i16) []const u8 {
    return std.fmt.bufPrint(&db_buf, "{d} dB", .{value}) catch "?";
}

fn formatDbSigned(value: i8) []const u8 {
    return formatDbSignedBuf(value);
}

var db_signed_buf: [16]u8 = undefined;
fn formatDbSignedBuf(value: i8) []const u8 {
    if (value >= 0) {
        return std.fmt.bufPrint(&db_signed_buf, "+{d} dB", .{value}) catch "?";
    } else {
        return std.fmt.bufPrint(&db_signed_buf, "{d} dB", .{value}) catch "?";
    }
}

/// Handle input for settings browser
pub fn handleSettingsBrowserInput(browser: *SettingsBrowser, buttons: u8, wheel_delta: i8) SettingsAction {
    const clickwheel = @import("../drivers/input/clickwheel.zig");

    // Wheel handling - navigation or value adjustment
    if (wheel_delta != 0) {
        if (browser.editing) {
            browser.adjustValue(wheel_delta);
        } else {
            if (wheel_delta > 0) {
                browser.selectNext();
            } else {
                browser.selectPrevious();
            }
        }
        return .none;
    }

    // Button handling
    if (buttons & clickwheel.Button.SELECT != 0) {
        return browser.select();
    }

    if (buttons & clickwheel.Button.RIGHT != 0) {
        return browser.select();
    }

    if (buttons & clickwheel.Button.LEFT != 0) {
        return browser.goBack();
    }

    if (buttons & clickwheel.Button.MENU != 0) {
        return browser.goBack();
    }

    return .none;
}

/// Create the main settings menu
pub fn createMainMenu() ui.Menu {
    const items = [_]ui.MenuItem{
        .{
            .label = "Display",
            .item_type = .submenu,
            .icon = "[D]",
        },
        .{
            .label = "Audio",
            .item_type = .submenu,
            .icon = "[A]",
        },
        .{
            .label = "Playback",
            .item_type = .submenu,
            .icon = "[P]",
        },
        .{
            .label = "System",
            .item_type = .submenu,
            .icon = "[S]",
        },
        .{
            .label = "",
            .item_type = .separator,
        },
        .{
            .label = "About ZigPod",
            .item_type = .action,
            .icon = "[i]",
        },
        .{
            .label = "Reset Settings",
            .item_type = .action,
            .icon = "[!]",
        },
    };

    _ = items;

    return ui.Menu{
        .title = "Settings",
        .items = &[_]ui.MenuItem{},
    };
}

// ============================================================
// Settings Screens
// ============================================================

/// Draw settings value editor
pub fn drawValueEditor(title: []const u8, value: []const u8, min_label: []const u8, max_label: []const u8, percent: u8) void {
    const theme = ui.getTheme();

    lcd.clear(theme.background);
    ui.drawHeader(title);

    // Current value centered
    lcd.drawStringCentered(80, value, theme.foreground, null);

    // Value bar
    lcd.drawProgressBar(40, 120, ui.SCREEN_WIDTH - 80, 16, percent, theme.accent, theme.disabled);

    // Min/max labels
    lcd.drawString(40, 140, min_label, theme.disabled, null);
    const max_x = ui.SCREEN_WIDTH - 40 - @as(u16, @intCast(max_label.len * ui.CHAR_WIDTH));
    lcd.drawString(max_x, 140, max_label, theme.disabled, null);

    ui.drawFooter("Wheel: Adjust  Select: Done");
}

/// Draw about screen
pub fn drawAboutScreen() void {
    const theme = ui.getTheme();

    lcd.clear(theme.background);
    ui.drawHeader("About ZigPod");

    const start_y: u16 = 50;
    const line_height: u16 = 18;

    lcd.drawStringCentered(start_y, "ZigPod OS", theme.foreground, null);
    lcd.drawStringCentered(start_y + line_height, "Version 0.1.0 \"Genesis\"", theme.disabled, null);
    lcd.drawStringCentered(start_y + line_height * 3, "A custom OS for", theme.foreground, null);
    lcd.drawStringCentered(start_y + line_height * 4, "iPod Video 5th Gen", theme.foreground, null);
    lcd.drawStringCentered(start_y + line_height * 6, "Written in Zig", theme.accent, null);
    lcd.drawStringCentered(start_y + line_height * 8, "github.com/Davidslv/zigpod", theme.disabled, null);

    ui.drawFooter("Menu: Back");
}

/// Draw theme selector screen
pub fn drawThemeSelector(selected_idx: u8) void {
    const theme = ui.getTheme();
    const registry = theme_loader.getRegistry();
    const count = registry.getThemeCount();
    const current_idx = registry.getSelectedIndex();

    lcd.clear(theme.background);
    ui.drawHeader("Select Theme");

    // Calculate visible range
    const max_visible = ui.MAX_VISIBLE_ITEMS;
    const visible_start: u8 = if (selected_idx >= max_visible) selected_idx - max_visible + 1 else 0;

    var i: u8 = 0;
    while (i < max_visible and visible_start + i < count) : (i += 1) {
        const idx = visible_start + i;
        const y: u16 = ui.CONTENT_START_Y + @as(u16, i) * ui.MENU_ITEM_HEIGHT;
        const is_selected = idx == selected_idx;

        const bg = if (is_selected) theme.selected_bg else theme.background;
        const fg = if (is_selected) theme.selected_fg else theme.foreground;

        // Draw item background
        lcd.fillRect(0, y, ui.SCREEN_WIDTH, ui.MENU_ITEM_HEIGHT, bg);

        // Draw theme name
        const name = registry.getThemeName(idx);
        lcd.drawString(10, y + 6, name, fg, bg);

        // Draw checkmark for currently active theme
        if (idx == current_idx) {
            lcd.drawString(ui.SCREEN_WIDTH - 24, y + 6, "*", theme.accent, bg);
        }

        // Show custom indicator for non-built-in themes
        if (idx >= theme_loader.ThemeRegistry.BUILTIN_COUNT) {
            lcd.drawString(ui.SCREEN_WIDTH - 48, y + 6, "[C]", theme.disabled, bg);
        }
    }

    // Scroll indicators
    if (visible_start > 0) {
        lcd.drawString(ui.SCREEN_WIDTH - 16, ui.CONTENT_START_Y, "^", theme.accent, null);
    }
    if (visible_start + max_visible < count) {
        lcd.drawString(ui.SCREEN_WIDTH - 16, ui.SCREEN_HEIGHT - ui.FOOTER_HEIGHT - 12, "v", theme.accent, null);
    }

    ui.drawFooter("Wheel: Browse  Select: Apply");
}

/// Theme selector state
pub const ThemeSelectorState = struct {
    selected_idx: u8 = 0,
    applied: bool = false,

    pub fn init() ThemeSelectorState {
        return .{
            .selected_idx = theme_loader.getRegistry().getSelectedIndex(),
        };
    }

    /// Handle input, returns true if should exit
    pub fn handleInput(self: *ThemeSelectorState, wheel_delta: i8, select_pressed: bool, back_pressed: bool) bool {
        const registry = theme_loader.getRegistry();
        const count = registry.getThemeCount();

        // Handle wheel navigation
        if (wheel_delta > 0) {
            if (self.selected_idx < count - 1) {
                self.selected_idx += 1;
            }
        } else if (wheel_delta < 0) {
            if (self.selected_idx > 0) {
                self.selected_idx -= 1;
            }
        }

        // Handle select - apply theme
        if (select_pressed) {
            selectTheme(self.selected_idx);
            self.applied = true;
            return true;
        }

        // Handle back - exit without applying
        if (back_pressed) {
            return true;
        }

        return false;
    }
};

/// Draw reset confirmation
pub fn drawResetConfirmation(selected: bool) void {
    const theme = ui.getTheme();

    lcd.clear(theme.background);

    // Warning message
    ui.drawMessageBox("Reset Settings?", "All settings will be restored to defaults.");

    // Confirmation buttons
    const button_y: u16 = 160;
    const cancel_x: u16 = 60;
    const confirm_x: u16 = 180;

    // Cancel button
    if (!selected) {
        lcd.fillRect(cancel_x - 5, button_y - 2, 60, 20, theme.selected_bg);
        lcd.drawString(cancel_x, button_y, "Cancel", theme.selected_fg, theme.selected_bg);
    } else {
        lcd.drawString(cancel_x, button_y, "Cancel", theme.foreground, null);
    }

    // Confirm button
    if (selected) {
        lcd.fillRect(confirm_x - 5, button_y - 2, 60, 20, theme.accent);
        lcd.drawString(confirm_x, button_y, "Reset", theme.selected_fg, theme.accent);
    } else {
        lcd.drawString(confirm_x, button_y, "Reset", theme.foreground, null);
    }
}

// ============================================================
// Settings Adjustment
// ============================================================

/// Adjust brightness
pub fn adjustBrightness(delta: i8) void {
    const settings = getSettings();
    if (delta > 0) {
        settings.brightness = @min(100, settings.brightness + 5);
    } else if (delta < 0) {
        settings.brightness = @max(10, settings.brightness -| 5);
    }
    settings.applyDisplaySettings();
}

/// Adjust volume
pub fn adjustVolume(delta: i8) void {
    const settings = getSettings();
    settings.volume = std.math.clamp(settings.volume + delta, -89, 6);
    settings.applyAudioSettings();
}

/// Adjust bass
pub fn adjustBass(delta: i8) void {
    const settings = getSettings();
    settings.bass = std.math.clamp(settings.bass + delta, -12, 12);
    settings.applyAudioSettings();
}

/// Adjust treble
pub fn adjustTreble(delta: i8) void {
    const settings = getSettings();
    settings.treble = std.math.clamp(settings.treble + delta, -12, 12);
    settings.applyAudioSettings();
}

/// Toggle shuffle
pub fn toggleShuffle() void {
    const settings = getSettings();
    settings.shuffle = !settings.shuffle;
}

/// Cycle repeat mode
pub fn cycleRepeat() void {
    const settings = getSettings();
    settings.repeat = settings.repeat.next();
}

/// Cycle to next theme (built-in + custom)
pub fn cycleTheme() void {
    const settings = getSettings();
    const registry = theme_loader.getRegistry();
    const count = registry.getThemeCount();
    settings.theme_index = (settings.theme_index + 1) % count;
    settings.applyDisplaySettings();
}

/// Cycle to previous theme
pub fn cyclePrevTheme() void {
    const settings = getSettings();
    const registry = theme_loader.getRegistry();
    const count = registry.getThemeCount();
    if (settings.theme_index == 0) {
        settings.theme_index = count - 1;
    } else {
        settings.theme_index -= 1;
    }
    settings.applyDisplaySettings();
}

/// Select theme by index
pub fn selectTheme(index: u8) void {
    const settings = getSettings();
    const registry = theme_loader.getRegistry();
    if (index < registry.getThemeCount()) {
        settings.theme_index = index;
        settings.applyDisplaySettings();
    }
}

/// Toggle gapless playback
pub fn toggleGapless() void {
    const settings = getSettings();
    settings.gapless = !settings.gapless;
}

/// Reset all settings to defaults
pub fn resetToDefaults() void {
    current_settings = Settings{};
    current_settings.applyDisplaySettings();
    current_settings.applyAudioSettings();
    saveSettings(); // Persist the reset
}

// ============================================================
// Settings Persistence
// ============================================================

/// Settings file path on storage
pub const SETTINGS_FILE_PATH = "/.zigpod/settings.bin";

/// Settings file magic number for validation
const SETTINGS_MAGIC: u32 = 0x5A504F44; // "ZPOD"

/// Settings file version for forward compatibility
const SETTINGS_VERSION: u8 = 1;

/// Serialized settings structure (packed for storage)
const SerializedSettings = extern struct {
    magic: u32 = SETTINGS_MAGIC,
    version: u8 = SETTINGS_VERSION,
    _reserved: [3]u8 = [_]u8{0} ** 3,

    // Display settings
    brightness: u8,
    backlight_timeout_lo: u8,
    backlight_timeout_hi: u8,
    theme_index: u8,

    // Audio settings (volume is i16, split into two bytes)
    volume_lo: u8,
    volume_hi: u8,
    bass: i8,
    treble: i8,
    bass_cutoff: u8,
    treble_cutoff: u8,
    channel_mix: u8,
    _pad1: u8 = 0,

    // Playback settings
    shuffle: u8,
    repeat: u8,
    gapless: u8,
    replay_gain: u8,

    // System settings
    sleep_timer_lo: u8,
    sleep_timer_hi: u8,
    hold_action: u8,
    language: u8,

    // Checksum for data integrity
    checksum: u8,
    _pad2: [3]u8 = [_]u8{0} ** 3,

    /// Calculate checksum of settings data
    fn calculateChecksum(self: *const SerializedSettings) u8 {
        const bytes: [*]const u8 = @ptrCast(self);
        var sum: u8 = 0;
        // Sum all bytes except the checksum field itself
        for (0..@offsetOf(SerializedSettings, "checksum")) |i| {
            sum +%= bytes[i];
        }
        return sum;
    }

    /// Validate the serialized settings
    fn isValid(self: *const SerializedSettings) bool {
        if (self.magic != SETTINGS_MAGIC) return false;
        if (self.version > SETTINGS_VERSION) return false;
        if (self.checksum != self.calculateChecksum()) return false;
        return true;
    }
};

/// Convert Settings to serialized format
fn serializeSettings(settings: *const Settings) SerializedSettings {
    var s = SerializedSettings{
        .brightness = settings.brightness,
        .backlight_timeout_lo = @truncate(settings.backlight_timeout),
        .backlight_timeout_hi = @truncate(settings.backlight_timeout >> 8),
        .theme_index = settings.theme_index,

        .volume_lo = @bitCast(@as(u8, @truncate(@as(u16, @bitCast(settings.volume))))),
        .volume_hi = @bitCast(@as(u8, @truncate(@as(u16, @bitCast(settings.volume)) >> 8))),
        .bass = settings.bass,
        .treble = settings.treble,
        .bass_cutoff = @intFromEnum(settings.bass_cutoff),
        .treble_cutoff = @intFromEnum(settings.treble_cutoff),
        .channel_mix = @intFromEnum(settings.channel_mix),

        .shuffle = if (settings.shuffle) 1 else 0,
        .repeat = @intFromEnum(settings.repeat),
        .gapless = if (settings.gapless) 1 else 0,
        .replay_gain = @intFromEnum(settings.replay_gain),

        .sleep_timer_lo = @truncate(settings.sleep_timer),
        .sleep_timer_hi = @truncate(settings.sleep_timer >> 8),
        .hold_action = @intFromEnum(settings.hold_action),
        .language = @intFromEnum(settings.language),

        .checksum = 0,
    };
    s.checksum = s.calculateChecksum();
    return s;
}

/// Convert serialized format back to Settings
fn deserializeSettings(s: *const SerializedSettings) Settings {
    return Settings{
        .brightness = s.brightness,
        .backlight_timeout = @as(u16, s.backlight_timeout_hi) << 8 | s.backlight_timeout_lo,
        .theme_index = s.theme_index,

        .volume = @bitCast(@as(u16, s.volume_hi) << 8 | s.volume_lo),
        .bass = s.bass,
        .treble = s.treble,
        .bass_cutoff = @enumFromInt(s.bass_cutoff),
        .treble_cutoff = @enumFromInt(s.treble_cutoff),
        .channel_mix = @enumFromInt(s.channel_mix),

        .shuffle = s.shuffle != 0,
        .repeat = @enumFromInt(s.repeat),
        .gapless = s.gapless != 0,
        .replay_gain = @enumFromInt(s.replay_gain),

        .sleep_timer = @as(u16, s.sleep_timer_hi) << 8 | s.sleep_timer_lo,
        .hold_action = @enumFromInt(s.hold_action),
        .language = @enumFromInt(s.language),
    };
}

/// Storage interface for settings persistence
/// TODO: Implement actual storage when FAT32 write support is added
const SettingsStorage = struct {
    /// Write settings to storage
    fn write(data: []const u8) bool {
        // TODO: Implement when FAT32 write support is available
        // For now, settings are volatile (lost on power off)
        _ = data;
        return false;
    }

    /// Read settings from storage
    fn read(buffer: []u8) ?usize {
        // TODO: Implement when FAT32 read for config files is available
        _ = buffer;
        return null;
    }
};

/// Save current settings to storage
pub fn saveSettings() void {
    const serialized = serializeSettings(&current_settings);
    const bytes: [*]const u8 = @ptrCast(&serialized);
    _ = SettingsStorage.write(bytes[0..@sizeOf(SerializedSettings)]);
}

/// Load settings from storage
/// Returns true if settings were loaded successfully
pub fn loadSettings() bool {
    var buffer: [@sizeOf(SerializedSettings)]u8 = undefined;

    const bytes_read = SettingsStorage.read(&buffer) orelse return false;
    if (bytes_read != @sizeOf(SerializedSettings)) return false;

    const serialized: *const SerializedSettings = @ptrCast(@alignCast(&buffer));
    if (!serialized.isValid()) return false;

    current_settings = deserializeSettings(serialized);
    current_settings.applyDisplaySettings();
    current_settings.applyAudioSettings();
    return true;
}

/// Initialize settings - try to load from storage, fall back to defaults
pub fn initSettings() void {
    if (!loadSettings()) {
        // Use defaults
        current_settings = Settings{};
    }
    current_settings.applyDisplaySettings();
    current_settings.applyAudioSettings();
}

/// Mark settings as dirty (needs save)
/// Call this after any setting change
var settings_dirty: bool = false;

pub fn markDirty() void {
    settings_dirty = true;
}

pub fn isDirty() bool {
    return settings_dirty;
}

/// Save if dirty and clear the flag
pub fn saveIfDirty() void {
    if (settings_dirty) {
        saveSettings();
        settings_dirty = false;
    }
}

// ============================================================
// Tests
// ============================================================

test "theme cycling with registry" {
    // Reset to defaults for testing
    current_settings = Settings{};
    try std.testing.expectEqual(@as(u8, 0), current_settings.theme_index);

    // Cycle through built-in themes (at minimum light and dark)
    cycleTheme();
    try std.testing.expectEqual(@as(u8, 1), current_settings.theme_index);

    cycleTheme();
    try std.testing.expectEqual(@as(u8, 0), current_settings.theme_index);
}

test "repeat mode cycling" {
    var mode = RepeatMode.off;
    mode = mode.next();
    try std.testing.expectEqual(RepeatMode.one, mode);
    mode = mode.next();
    try std.testing.expectEqual(RepeatMode.all, mode);
    mode = mode.next();
    try std.testing.expectEqual(RepeatMode.off, mode);
}

test "settings defaults" {
    const settings = Settings{};
    try std.testing.expectEqual(@as(u8, 80), settings.brightness);
    try std.testing.expectEqual(@as(i16, -10), settings.volume);
    try std.testing.expectEqual(@as(u8, 0), settings.theme_index);
    try std.testing.expect(!settings.shuffle);
    try std.testing.expect(settings.gapless);
}

test "volume clamping" {
    current_settings = Settings{};
    current_settings.volume = 0;

    // Increase beyond max
    adjustVolume(10);
    try std.testing.expectEqual(@as(i16, 6), current_settings.volume);

    // Decrease beyond min
    current_settings.volume = -80;
    adjustVolume(-20);
    try std.testing.expectEqual(@as(i16, -89), current_settings.volume);
}

test "brightness clamping" {
    current_settings = Settings{};
    current_settings.brightness = 100;

    adjustBrightness(10);
    try std.testing.expectEqual(@as(u8, 100), current_settings.brightness);

    current_settings.brightness = 10;
    adjustBrightness(-10);
    try std.testing.expectEqual(@as(u8, 10), current_settings.brightness);
}

test "settings serialization roundtrip" {
    // Create settings with non-default values
    const original = Settings{
        .brightness = 75,
        .backlight_timeout = 45,
        .theme_index = 1,
        .volume = -20,
        .bass = 6,
        .treble = -3,
        .bass_cutoff = .hz_130,
        .treble_cutoff = .hz_8k,
        .channel_mix = .mono,
        .shuffle = true,
        .repeat = .all,
        .gapless = false,
        .replay_gain = .album,
        .sleep_timer = 60,
        .hold_action = .pause,
        .language = .french,
    };

    // Serialize
    const serialized = serializeSettings(&original);

    // Validate magic and checksum
    try std.testing.expectEqual(SETTINGS_MAGIC, serialized.magic);
    try std.testing.expectEqual(SETTINGS_VERSION, serialized.version);
    try std.testing.expect(serialized.isValid());

    // Deserialize
    const restored = deserializeSettings(&serialized);

    // Verify all fields match
    try std.testing.expectEqual(original.brightness, restored.brightness);
    try std.testing.expectEqual(original.backlight_timeout, restored.backlight_timeout);
    try std.testing.expectEqual(original.theme_index, restored.theme_index);
    try std.testing.expectEqual(original.volume, restored.volume);
    try std.testing.expectEqual(original.bass, restored.bass);
    try std.testing.expectEqual(original.treble, restored.treble);
    try std.testing.expectEqual(original.bass_cutoff, restored.bass_cutoff);
    try std.testing.expectEqual(original.treble_cutoff, restored.treble_cutoff);
    try std.testing.expectEqual(original.channel_mix, restored.channel_mix);
    try std.testing.expectEqual(original.shuffle, restored.shuffle);
    try std.testing.expectEqual(original.repeat, restored.repeat);
    try std.testing.expectEqual(original.gapless, restored.gapless);
    try std.testing.expectEqual(original.replay_gain, restored.replay_gain);
    try std.testing.expectEqual(original.sleep_timer, restored.sleep_timer);
    try std.testing.expectEqual(original.hold_action, restored.hold_action);
    try std.testing.expectEqual(original.language, restored.language);
}

test "settings checksum validation" {
    const settings = Settings{};
    var serialized = serializeSettings(&settings);

    // Valid checksum
    try std.testing.expect(serialized.isValid());

    // Corrupt data - should fail validation
    serialized.brightness = 50;
    try std.testing.expect(!serialized.isValid());

    // Fix checksum
    serialized.checksum = serialized.calculateChecksum();
    try std.testing.expect(serialized.isValid());
}

test "settings invalid magic" {
    var serialized = serializeSettings(&Settings{});

    // Corrupt magic
    serialized.magic = 0x12345678;
    try std.testing.expect(!serialized.isValid());
}

test "serialized settings size" {
    // Ensure the serialized struct is a reasonable size
    try std.testing.expect(@sizeOf(SerializedSettings) <= 64);
    try std.testing.expect(@sizeOf(SerializedSettings) >= 24);
}
