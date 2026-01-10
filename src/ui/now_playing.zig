//! Now Playing Screen
//!
//! Enhanced "Now Playing" screen with track info, progress bar,
//! playback controls, and volume display.

const std = @import("std");
const ui = @import("ui.zig");
const lcd = @import("../drivers/display/lcd.zig");
const audio = @import("../audio/audio.zig");
const playback_queue = audio.playback_queue;
const album_art = @import("../audio/album_art.zig");

// ============================================================
// Constants
// ============================================================

/// Album art dimensions (if supported)
pub const ALBUM_ART_SIZE: u16 = 80;
pub const ALBUM_ART_X: u16 = 20;
pub const ALBUM_ART_Y: u16 = 40;

/// Track info layout
pub const INFO_X: u16 = ALBUM_ART_X + ALBUM_ART_SIZE + 15;
pub const INFO_WIDTH: u16 = ui.SCREEN_WIDTH - INFO_X - 10;

/// Progress bar layout
pub const PROGRESS_Y: u16 = 160;
pub const PROGRESS_HEIGHT: u16 = 8;

/// Control icons layout
pub const CONTROLS_Y: u16 = 190;

// ============================================================
// Track Metadata
// ============================================================

pub const TrackMetadata = struct {
    title: []const u8 = "Unknown Title",
    artist: []const u8 = "Unknown Artist",
    album: []const u8 = "Unknown Album",
    track_number: u16 = 0,
    total_tracks: u16 = 0,
    year: u16 = 0,
    genre: []const u8 = "",
    has_album_art: bool = false,
};

// ============================================================
// Now Playing State
// ============================================================

pub const NowPlayingState = struct {
    metadata: TrackMetadata = .{},
    current_time_ms: u64 = 0,
    total_time_ms: u64 = 0,
    is_playing: bool = false,
    is_shuffled: bool = false,
    repeat_mode: RepeatMode = .off,
    volume: u8 = 50, // 0-100

    // Queue position
    queue_position: usize = 0,
    queue_total: usize = 0,

    /// Calculate progress percentage (0-100)
    pub fn getProgressPercent(self: *const NowPlayingState) u8 {
        if (self.total_time_ms == 0) return 0;
        return @intCast((self.current_time_ms * 100) / self.total_time_ms);
    }

    /// Format current time as string
    pub fn formatCurrentTime(self: *const NowPlayingState, buffer: []u8) []u8 {
        return formatTime(self.current_time_ms, buffer);
    }

    /// Format total time as string
    pub fn formatTotalTime(self: *const NowPlayingState, buffer: []u8) []u8 {
        return formatTime(self.total_time_ms, buffer);
    }

    /// Update from audio engine state
    pub fn syncWithAudio(self: *NowPlayingState) void {
        self.current_time_ms = audio.getPositionMs();
        self.is_playing = audio.isPlaying();

        if (audio.getTrackInfo()) |info| {
            self.total_time_ms = info.duration_ms;
        }

        // Update metadata from loaded track
        if (audio.hasLoadedTrack()) {
            const track_info = audio.getLoadedTrackInfo();
            self.metadata.title = track_info.getTitle();
            self.metadata.artist = track_info.getArtist();
            self.metadata.album = track_info.getAlbum();
        }

        // Update queue position, shuffle, and repeat state
        const queue = playback_queue.getQueue();
        self.queue_position = queue.getCurrentPosition();
        self.queue_total = queue.getCount();
        self.is_shuffled = queue.isShuffled();

        // Sync repeat mode from queue
        self.repeat_mode = switch (queue.getRepeatMode()) {
            .off => .off,
            .one => .one,
            .all => .all,
        };

        const vol = audio.getVolume();
        // Convert dB (-89 to +6) to percentage (0-100)
        const db = @divFloor(vol.left + vol.right, 2);
        self.volume = @intCast(@max(0, @min(100, @divFloor((db + 89) * 100, 95))));
    }
};

pub const RepeatMode = enum {
    off,
    one,
    all,

    pub fn next(self: RepeatMode) RepeatMode {
        return switch (self) {
            .off => .one,
            .one => .all,
            .all => .off,
        };
    }

    pub fn toString(self: RepeatMode) []const u8 {
        return switch (self) {
            .off => "Off",
            .one => "One",
            .all => "All",
        };
    }

    pub fn toIcon(self: RepeatMode) []const u8 {
        return switch (self) {
            .off => "  ",
            .one => "R1",
            .all => "RA",
        };
    }
};

// ============================================================
// Drawing Functions
// ============================================================

/// Draw the complete Now Playing screen
pub fn draw(state: *const NowPlayingState) void {
    const theme = ui.getTheme();

    // Clear screen
    lcd.clear(theme.background);

    // Draw header
    ui.drawHeader("Now Playing");

    // Draw album art placeholder (or actual art if available)
    drawAlbumArt(state, theme);

    // Draw track info
    drawTrackInfo(state, theme);

    // Draw progress bar and time
    drawProgress(state, theme);

    // Draw playback controls
    drawControls(state, theme);

    // Draw footer with status icons
    drawStatusBar(state, theme);
}

/// Draw album art or placeholder
fn drawAlbumArt(state: *const NowPlayingState, theme: ui.Theme) void {
    _ = state;

    // Try to load album art for current track
    const queue = playback_queue.getQueue();
    if (queue.getCurrentTrackPath()) |track_path| {
        const art = album_art.loadForTrack(track_path);

        if (art.valid) {
            // Render album art pixels
            renderAlbumArt(art);
            // Draw border around art
            lcd.drawRect(ALBUM_ART_X, ALBUM_ART_Y, ALBUM_ART_SIZE, ALBUM_ART_SIZE, theme.disabled);
            return;
        }
    }

    // No art available - draw placeholder
    drawPlaceholderArt(theme);
}

/// Render album art pixels to LCD
fn renderAlbumArt(art: *const album_art.ArtBuffer) void {
    // Render each pixel directly to LCD
    // This uses the art's RGB565 pixel buffer
    for (0..album_art.ART_SIZE) |y| {
        for (0..album_art.ART_SIZE) |x| {
            const color = art.getPixel(@intCast(x), @intCast(y));
            lcd.setPixel(ALBUM_ART_X + @as(u16, @intCast(x)), ALBUM_ART_Y + @as(u16, @intCast(y)), color);
        }
    }
}

/// Draw placeholder when no album art is available
fn drawPlaceholderArt(theme: ui.Theme) void {
    // Draw placeholder border
    lcd.drawRect(ALBUM_ART_X, ALBUM_ART_Y, ALBUM_ART_SIZE, ALBUM_ART_SIZE, theme.disabled);

    // Fill with gradient-like pattern (simulated)
    var y: u16 = ALBUM_ART_Y + 1;
    while (y < ALBUM_ART_Y + ALBUM_ART_SIZE - 1) : (y += 1) {
        const gradient: u8 = @intCast(@min(255, 100 + (y - ALBUM_ART_Y)));
        const color = lcd.rgb(gradient, gradient, @intCast(@min(255, gradient + 30)));
        lcd.drawHLine(ALBUM_ART_X + 1, y, ALBUM_ART_SIZE - 2, color);
    }

    // Draw music note icon in center
    lcd.drawStringCentered(ALBUM_ART_Y + ALBUM_ART_SIZE / 2 - 4, "♪", theme.foreground, null);
}

/// Draw track metadata
fn drawTrackInfo(state: *const NowPlayingState, theme: ui.Theme) void {
    const meta = state.metadata;

    // Title (bold/larger if possible, just draw it for now)
    lcd.drawString(INFO_X, ALBUM_ART_Y, meta.title, theme.foreground, null);

    // Artist
    lcd.drawString(INFO_X, ALBUM_ART_Y + 16, meta.artist, theme.disabled, null);

    // Album
    lcd.drawString(INFO_X, ALBUM_ART_Y + 32, meta.album, theme.disabled, null);

    // Queue position (show "Track X of Y" when playing from album/artist)
    if (state.queue_total > 1) {
        var buf: [32]u8 = undefined;
        const track_str = std.fmt.bufPrint(&buf, "Track {d} of {d}", .{ state.queue_position, state.queue_total }) catch "";
        lcd.drawString(INFO_X, ALBUM_ART_Y + 52, track_str, theme.disabled, null);
    } else if (meta.track_number > 0 and meta.total_tracks > 0) {
        // Fall back to metadata track number
        var buf: [32]u8 = undefined;
        const track_str = std.fmt.bufPrint(&buf, "Track {d}/{d}", .{ meta.track_number, meta.total_tracks }) catch "";
        lcd.drawString(INFO_X, ALBUM_ART_Y + 52, track_str, theme.disabled, null);
    }
}

/// Draw progress bar and time
fn drawProgress(state: *const NowPlayingState, theme: ui.Theme) void {
    // Progress bar
    const progress = state.getProgressPercent();
    lcd.drawProgressBar(
        20,
        PROGRESS_Y,
        ui.SCREEN_WIDTH - 40,
        PROGRESS_HEIGHT,
        progress,
        theme.accent,
        theme.disabled,
    );

    // Current time
    var current_buf: [16]u8 = undefined;
    const current_str = state.formatCurrentTime(&current_buf);
    lcd.drawString(20, PROGRESS_Y + PROGRESS_HEIGHT + 4, current_str, theme.foreground, null);

    // Total time
    var total_buf: [16]u8 = undefined;
    const total_str = state.formatTotalTime(&total_buf);
    const total_x = ui.SCREEN_WIDTH - 20 - @as(u16, @intCast(total_str.len * ui.CHAR_WIDTH));
    lcd.drawString(total_x, PROGRESS_Y + PROGRESS_HEIGHT + 4, total_str, theme.foreground, null);
}

/// Draw playback control icons
fn drawControls(state: *const NowPlayingState, theme: ui.Theme) void {
    const center_x = ui.SCREEN_WIDTH / 2;

    // Previous track
    lcd.drawString(center_x - 60, CONTROLS_Y, "|<", theme.foreground, null);

    // Play/Pause
    const play_icon = if (state.is_playing) "||" else "> ";
    lcd.drawString(center_x - 8, CONTROLS_Y, play_icon, theme.accent, null);

    // Next track
    lcd.drawString(center_x + 44, CONTROLS_Y, ">|", theme.foreground, null);
}

/// Draw status bar with shuffle, repeat, volume icons
fn drawStatusBar(state: *const NowPlayingState, theme: ui.Theme) void {
    const y = ui.SCREEN_HEIGHT - ui.FOOTER_HEIGHT;

    // Background
    lcd.fillRect(0, y, ui.SCREEN_WIDTH, ui.FOOTER_HEIGHT, theme.footer_bg);
    lcd.drawHLine(0, y, ui.SCREEN_WIDTH, theme.disabled);

    // Shuffle indicator
    const shuffle_str = if (state.is_shuffled) "SH" else "  ";
    lcd.drawString(10, y + 6, shuffle_str, theme.footer_fg, theme.footer_bg);

    // Repeat indicator
    lcd.drawString(40, y + 6, state.repeat_mode.toIcon(), theme.footer_fg, theme.footer_bg);

    // Volume bar (simplified)
    lcd.drawString(ui.SCREEN_WIDTH - 80, y + 6, "Vol:", theme.footer_fg, theme.footer_bg);

    const vol_bar_width: u16 = 40;
    const vol_bar_x = ui.SCREEN_WIDTH - 45;
    const filled_width = @as(u16, @intCast((state.volume * vol_bar_width) / 100));

    lcd.fillRect(vol_bar_x, y + 8, filled_width, 6, theme.accent);
    lcd.drawRect(vol_bar_x, y + 8, vol_bar_width, 6, theme.disabled);
}

// ============================================================
// Input Handling
// ============================================================

pub const NowPlayingAction = enum {
    none,
    toggle_play,
    next_track,
    prev_track,
    seek_forward,
    seek_backward,
    volume_up,
    volume_down,
    toggle_shuffle,
    toggle_repeat,
    open_menu,
    back,
};

/// Handle input for Now Playing screen
pub fn handleInput(state: *NowPlayingState, button: u8, wheel_delta: i8) NowPlayingAction {
    const clickwheel = @import("../drivers/input/clickwheel.zig");

    // Button handling
    if (button & clickwheel.Button.PLAY != 0) {
        return .toggle_play;
    }

    if (button & clickwheel.Button.RIGHT != 0) {
        return .next_track;
    }

    if (button & clickwheel.Button.LEFT != 0) {
        return .prev_track;
    }

    if (button & clickwheel.Button.MENU != 0) {
        return .open_menu;
    }

    if (button & clickwheel.Button.SELECT != 0) {
        // Could toggle options or show track details
        return .none;
    }

    // Wheel handling - volume control
    if (wheel_delta > 0) {
        state.volume = @min(100, state.volume + 2);
        return .volume_up;
    } else if (wheel_delta < 0) {
        state.volume = @max(0, state.volume -| 2);
        return .volume_down;
    }

    return .none;
}

// ============================================================
// Utility Functions
// ============================================================

/// Format time in milliseconds to MM:SS string
fn formatTime(ms: u64, buffer: []u8) []u8 {
    const secs = ms / 1000;
    const mins = secs / 60;
    const remaining_secs = secs % 60;

    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}", .{
        @min(mins, 99), // Cap at 99 minutes for display
        remaining_secs,
    }) catch buffer[0..0];
}

// ============================================================
// Tests
// ============================================================

test "now playing state progress" {
    var state = NowPlayingState{
        .current_time_ms = 30000,
        .total_time_ms = 120000,
    };

    try std.testing.expectEqual(@as(u8, 25), state.getProgressPercent());
}

test "now playing state progress zero total" {
    const state = NowPlayingState{
        .current_time_ms = 30000,
        .total_time_ms = 0,
    };

    try std.testing.expectEqual(@as(u8, 0), state.getProgressPercent());
}

test "format time" {
    var buf: [16]u8 = undefined;

    const result1 = formatTime(0, &buf);
    try std.testing.expectEqualStrings("00:00", result1);

    const result2 = formatTime(65000, &buf);
    try std.testing.expectEqualStrings("01:05", result2);

    const result3 = formatTime(3661000, &buf);
    try std.testing.expectEqualStrings("61:01", result3);
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
