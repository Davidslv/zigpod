//! Settings Menu
//!
//! System settings and preferences for ZigPod OS.
//! Includes display, audio, playback, and system settings.

const std = @import("std");
const ui = @import("ui.zig");
const lcd = @import("../drivers/display/lcd.zig");
const audio = @import("../audio/audio.zig");
const codec = @import("../drivers/audio/codec.zig");

// ============================================================
// Settings Storage
// ============================================================

pub const Settings = struct {
    // Display settings
    brightness: u8 = 80, // 0-100
    backlight_timeout: u16 = 30, // seconds, 0 = always on
    theme: ThemeChoice = .light,

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
    crossfade: u8 = 0, // seconds, 0 = off
    replay_gain: ReplayGainMode = .off,

    // System settings
    sleep_timer: u16 = 0, // minutes, 0 = off
    hold_action: HoldAction = .lock,
    language: Language = .english,

    // Apply audio settings to codec
    pub fn applyAudioSettings(self: *const Settings) void {
        audio.setVolumeMono(self.volume) catch {};
        codec.setBass(self.bass) catch {};
        codec.setTreble(self.treble) catch {};
        _ = self.bass_cutoff; // TODO: Implement cutoff frequency setting
        _ = self.treble_cutoff;
    }

    // Apply display settings
    pub fn applyDisplaySettings(self: *const Settings) void {
        // TODO: Implement LCD brightness control when hardware supports it
        _ = self.brightness;
        switch (self.theme) {
            .light => ui.setTheme(ui.default_theme),
            .dark => ui.setTheme(ui.dark_theme),
        }
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
    display,
    audio,
    playback,
    system,
    about,
};

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

/// Cycle theme
pub fn cycleTheme() void {
    const settings = getSettings();
    settings.theme = settings.theme.next();
    settings.applyDisplaySettings();
}

/// Reset all settings to defaults
pub fn resetToDefaults() void {
    current_settings = Settings{};
    current_settings.applyDisplaySettings();
    current_settings.applyAudioSettings();
}

// ============================================================
// Tests
// ============================================================

test "theme cycling" {
    var theme = ThemeChoice.light;
    theme = theme.next();
    try std.testing.expectEqual(ThemeChoice.dark, theme);
    theme = theme.next();
    try std.testing.expectEqual(ThemeChoice.light, theme);
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
    try std.testing.expect(!settings.shuffle);
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
