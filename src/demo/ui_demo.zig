//! ZigPod UI Demo - RetroFlow Edition
//!
//! "Technology disappears. Only music remains."
//!
//! RetroFlow Design Philosophy:
//! - Temporal Dissolution: Interface exists only when needed
//! - Anticipatory Design: Context shapes presentation
//! - Sensory Hierarchy: Audio → Haptic → Visual
//! - Constraint as Poetry: 320x240 becomes elegant canvas
//!
//! Navigation:
//!   Arrow Up/Down  : Navigate (with acceleration)
//!   Enter          : Select / Play
//!   Escape/Backsp  : Back (double-tap → Now Playing)
//!   Space          : Play/Pause
//!   Q              : Quit

const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const zigpod = @import("zigpod");
const ui = zigpod.ui;
const lcd = zigpod.lcd;
const hal = zigpod.hal;

const WIDTH = 320;
const HEIGHT = 240;
const SCALE = 2;

/// Convert RGB888 to RGB565
fn rgb(r: u8, g: u8, b: u8) u16 {
    return (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | @as(u16, b >> 3);
}

// ============================================================
// RetroFlow Design System
// "Technology disappears. Only music remains."
// ============================================================

const RetroFlowTheme = struct {
    // Foundation Layer
    obsidian: u16,        // Pure black base
    void_: u16,           // Subtle depth
    carbon: u16,          // Surface level
    slate: u16,           // Elevated surfaces

    // Typography Layer
    pure_white: u16,      // Primary text
    silver: u16,          // Secondary text
    pewter: u16,          // Tertiary/hints
    graphite: u16,        // Disabled

    // Accent Spectrum
    accent: u16,          // Primary accent (cyan/amber)
    accent_bright: u16,   // Highlight/glow
    accent_muted: u16,    // Subtle accent

    // Semantic
    selection_bg: u16,    // Selected item background
    separator: u16,       // Divider lines
};

// RetroFlow Cyan - The signature theme
const theme_retroflow_cyan = RetroFlowTheme{
    .obsidian = rgb(0, 0, 0),
    .void_ = rgb(10, 10, 12),
    .carbon = rgb(20, 20, 24),
    .slate = rgb(30, 30, 36),
    .pure_white = rgb(255, 255, 255),
    .silver = rgb(184, 184, 192),
    .pewter = rgb(110, 110, 120),
    .graphite = rgb(60, 60, 68),
    .accent = rgb(0, 191, 255),        // Electric cyan
    .accent_bright = rgb(0, 220, 255), // Aurora glow
    .accent_muted = rgb(0, 136, 184),  // Deep cyan
    .selection_bg = rgb(0, 40, 50),    // Cyan tinted black
    .separator = rgb(40, 40, 48),
};

// RetroFlow Amber - Warm alternative
const theme_retroflow_amber = RetroFlowTheme{
    .obsidian = rgb(0, 0, 0),
    .void_ = rgb(12, 10, 8),
    .carbon = rgb(24, 20, 16),
    .slate = rgb(36, 30, 24),
    .pure_white = rgb(255, 252, 245),
    .silver = rgb(192, 184, 168),
    .pewter = rgb(120, 110, 95),
    .graphite = rgb(68, 60, 50),
    .accent = rgb(255, 191, 0),        // Ambient amber
    .accent_bright = rgb(255, 220, 80),
    .accent_muted = rgb(204, 153, 0),
    .selection_bg = rgb(50, 40, 0),
    .separator = rgb(48, 42, 32),
};

// RetroFlow Light - Daytime mode
const theme_retroflow_light = RetroFlowTheme{
    .obsidian = rgb(255, 255, 255),    // Inverted: white base
    .void_ = rgb(250, 250, 252),
    .carbon = rgb(242, 242, 246),
    .slate = rgb(230, 230, 236),
    .pure_white = rgb(0, 0, 0),        // Inverted: black text
    .silver = rgb(60, 60, 70),
    .pewter = rgb(120, 120, 130),
    .graphite = rgb(180, 180, 190),
    .accent = rgb(0, 150, 220),
    .accent_bright = rgb(0, 180, 255),
    .accent_muted = rgb(0, 100, 160),
    .selection_bg = rgb(220, 240, 250),
    .separator = rgb(210, 210, 220),
};

// RetroFlow OLED - Maximum contrast
const theme_retroflow_oled = RetroFlowTheme{
    .obsidian = rgb(0, 0, 0),
    .void_ = rgb(0, 0, 0),             // True black everywhere
    .carbon = rgb(8, 8, 10),
    .slate = rgb(18, 18, 22),
    .pure_white = rgb(255, 255, 255),
    .silver = rgb(200, 200, 210),
    .pewter = rgb(130, 130, 140),
    .graphite = rgb(70, 70, 80),
    .accent = rgb(0, 255, 200),        // Vibrant teal
    .accent_bright = rgb(100, 255, 220),
    .accent_muted = rgb(0, 180, 140),
    .selection_bg = rgb(0, 30, 25),
    .separator = rgb(30, 30, 35),
};

// RetroFlow Rose - Elegant night mode
const theme_retroflow_rose = RetroFlowTheme{
    .obsidian = rgb(0, 0, 0),
    .void_ = rgb(12, 8, 12),
    .carbon = rgb(22, 16, 24),
    .slate = rgb(34, 26, 38),
    .pure_white = rgb(255, 248, 252),
    .silver = rgb(190, 175, 185),
    .pewter = rgb(120, 105, 115),
    .graphite = rgb(65, 55, 62),
    .accent = rgb(255, 100, 150),      // Soft rose
    .accent_bright = rgb(255, 140, 180),
    .accent_muted = rgb(200, 70, 110),
    .selection_bg = rgb(45, 20, 35),
    .separator = rgb(45, 35, 45),
};

// High Contrast Accessibility Mode
const theme_high_contrast = RetroFlowTheme{
    .obsidian = rgb(0, 0, 0),
    .void_ = rgb(0, 0, 0),
    .carbon = rgb(0, 0, 0),
    .slate = rgb(0, 0, 0),
    .pure_white = rgb(255, 255, 255),
    .silver = rgb(255, 255, 255),
    .pewter = rgb(200, 200, 200),
    .graphite = rgb(128, 128, 128),
    .accent = rgb(255, 255, 0),        // High-vis yellow
    .accent_bright = rgb(255, 255, 255),
    .accent_muted = rgb(200, 200, 0),
    .selection_bg = rgb(255, 255, 0),  // Yellow selection
    .separator = rgb(255, 255, 255),
};

const ThemeChoice = struct {
    name: []const u8,
    theme: RetroFlowTheme,
};

const available_themes = [_]ThemeChoice{
    .{ .name = "RetroFlow Cyan", .theme = theme_retroflow_cyan },
    .{ .name = "RetroFlow Amber", .theme = theme_retroflow_amber },
    .{ .name = "RetroFlow Light", .theme = theme_retroflow_light },
    .{ .name = "RetroFlow OLED", .theme = theme_retroflow_oled },
    .{ .name = "RetroFlow Rose", .theme = theme_retroflow_rose },
    .{ .name = "High Contrast", .theme = theme_high_contrast },
};

var current_theme: RetroFlowTheme = theme_retroflow_cyan;
var theme_index: usize = 0;

// ============================================================
// Screen States
// ============================================================

const Screen = enum {
    home,
    library,
    artists,
    artist_detail,
    albums,
    album_detail,
    songs,
    playlists,
    now_playing,
    settings,
    theme_picker,
};

// ============================================================
// Demo Data
// ============================================================

const Artist = struct { name: []const u8, albums: []const []const u8 };
const Album = struct { name: []const u8, artist: []const u8, year: []const u8, songs: []const []const u8 };

const demo_artists = [_]Artist{
    .{ .name = "The Beatles", .albums = &.{ "Abbey Road", "Rubber Soul" } },
    .{ .name = "Pink Floyd", .albums = &.{ "Dark Side of the Moon", "Wish You Were Here" } },
    .{ .name = "Radiohead", .albums = &.{ "OK Computer", "In Rainbows" } },
    .{ .name = "Fleetwood Mac", .albums = &.{ "Rumours" } },
    .{ .name = "David Bowie", .albums = &.{ "Ziggy Stardust", "Heroes" } },
    .{ .name = "Led Zeppelin", .albums = &.{ "Led Zeppelin IV" } },
};

const demo_albums = [_]Album{
    .{ .name = "Abbey Road", .artist = "The Beatles", .year = "1969", .songs = &.{ "Come Together", "Something", "Here Comes the Sun", "Because" } },
    .{ .name = "Dark Side of the Moon", .artist = "Pink Floyd", .year = "1973", .songs = &.{ "Speak to Me", "Breathe", "Time", "Money" } },
    .{ .name = "OK Computer", .artist = "Radiohead", .year = "1997", .songs = &.{ "Airbag", "Paranoid Android", "Karma Police", "No Surprises" } },
    .{ .name = "Rumours", .artist = "Fleetwood Mac", .year = "1977", .songs = &.{ "Dreams", "Go Your Own Way", "The Chain" } },
    .{ .name = "Ziggy Stardust", .artist = "David Bowie", .year = "1972", .songs = &.{ "Five Years", "Starman", "Ziggy Stardust" } },
    .{ .name = "Led Zeppelin IV", .artist = "Led Zeppelin", .year = "1971", .songs = &.{ "Black Dog", "Stairway to Heaven", "When the Levee Breaks" } },
};

const demo_playlists = [_][]const u8{
    "Recently Played",
    "Favorites",
    "Discover Weekly",
    "Chill Vibes",
};

// ============================================================
// Navigation State
// ============================================================

var current_screen: Screen = .home;
var screen_stack: [10]Screen = undefined;
var stack_depth: usize = 0;

var home_index: usize = 0;
var library_index: usize = 0;
var artists_index: usize = 0;
var artist_detail_index: usize = 0;
var albums_index: usize = 0;
var album_detail_index: usize = 0;
var songs_index: usize = 0;
var playlists_index: usize = 0;
var settings_index: usize = 0;

var selected_artist: usize = 0;
var selected_album: usize = 0;
var scroll_offset: usize = 0;

var now_playing_song: ?[]const u8 = null;
var now_playing_artist: ?[]const u8 = null;
var now_playing_album: ?[]const u8 = null;
var is_playing: bool = false;
var playback_progress: u8 = 35; // percentage

const MAX_VISIBLE: usize = 5; // Larger items = fewer visible

// Animation state
var frame_counter: u32 = 0;
var visualizer_bars: [16]u8 = [_]u8{0} ** 16;
var visualizer_targets: [16]u8 = [_]u8{0} ** 16;
var rng_state: u32 = 12345;

// Simple PRNG for visualizer
fn nextRandom() u8 {
    rng_state = rng_state *% 1103515245 +% 12345;
    return @truncate((rng_state >> 16) & 0xFF);
}

// ============================================================
// Main
// ============================================================

pub fn main() !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) return error.SDLInitFailed;
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("ZigPod", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, WIDTH * SCALE, HEIGHT * SCALE, c.SDL_WINDOW_SHOWN) orelse return error.SDLWindowFailed;
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse return error.SDLRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);

    const texture = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGB565, c.SDL_TEXTUREACCESS_STREAMING, WIDTH, HEIGHT) orelse return error.SDLTextureFailed;
    defer c.SDL_DestroyTexture(texture);

    hal.init();
    lcd.init() catch {};
    ui.init() catch {};

    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════╗\n", .{});
    std.debug.print("║     ZigPod · RetroFlow Design         ║\n", .{});
    std.debug.print("║   \"Technology disappears. Only        ║\n", .{});
    std.debug.print("║         music remains.\"               ║\n", .{});
    std.debug.print("╠═══════════════════════════════════════╣\n", .{});
    std.debug.print("║  Up/Down   Navigate with acceleration ║\n", .{});
    std.debug.print("║  Enter     Select / Confirm           ║\n", .{});
    std.debug.print("║  Escape    Back                       ║\n", .{});
    std.debug.print("║  Space     Play/Pause                 ║\n", .{});
    std.debug.print("║  Q         Quit                       ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    redraw();

    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    if (!handleInput(event.key.keysym.sym) and event.key.keysym.sym == c.SDLK_q) {
                        running = false;
                    }
                },
                else => {},
            }
        }

        // Animate visualizer when playing
        if (current_screen == .now_playing and is_playing) {
            frame_counter +%= 1;
            updateVisualizer();
            redraw();
        }

        const fb = hal.mock.getFramebuffer();
        _ = c.SDL_UpdateTexture(texture, null, fb.ptr, WIDTH * 2);
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderCopy(renderer, texture, null, null);
        c.SDL_RenderPresent(renderer);
        c.SDL_Delay(16);
    }
}

fn updateVisualizer() void {
    // Update targets periodically
    if (frame_counter % 8 == 0) {
        for (&visualizer_targets) |*target| {
            // Generate new random target with some bias toward middle values
            const r = nextRandom();
            target.* = @min(100, r % 120 + 20);
        }
    }

    // Smooth interpolation toward targets
    for (&visualizer_bars, 0..) |*bar, i| {
        const target = visualizer_targets[i];
        if (bar.* < target) {
            bar.* = @min(target, bar.* + 8);
        } else if (bar.* > target) {
            bar.* = bar.* -| 4; // Slower decay
        }
    }
}

// ============================================================
// Navigation
// ============================================================

fn push(screen: Screen) void {
    if (stack_depth < screen_stack.len) {
        screen_stack[stack_depth] = current_screen;
        stack_depth += 1;
    }
    current_screen = screen;
    scroll_offset = 0;
}

fn pop() void {
    if (stack_depth > 0) {
        stack_depth -= 1;
        current_screen = screen_stack[stack_depth];
        scroll_offset = 0;
    }
}

fn navUp(idx: *usize, _: usize) void {
    if (idx.* > 0) {
        idx.* -= 1;
        if (idx.* < scroll_offset) scroll_offset = idx.*;
    }
}

fn navDown(idx: *usize, max: usize) void {
    if (idx.* < max - 1) {
        idx.* += 1;
        if (idx.* >= scroll_offset + MAX_VISIBLE) scroll_offset = idx.* - MAX_VISIBLE + 1;
    }
}

fn handleInput(key: c_int) bool {
    if (key == c.SDLK_SPACE) {
        is_playing = !is_playing;
        redraw();
        return true;
    }

    return switch (current_screen) {
        .home => handleHome(key),
        .library => handleLibrary(key),
        .artists => handleArtists(key),
        .artist_detail => handleArtistDetail(key),
        .albums => handleAlbums(key),
        .album_detail => handleAlbumDetail(key),
        .songs => handleSongs(key),
        .playlists => handlePlaylists(key),
        .now_playing => handleNowPlaying(key),
        .settings => handleSettings(key),
        .theme_picker => handleThemePicker(key),
    };
}

fn handleHome(key: c_int) bool {
    const items = 5; // Now Playing, Library, Playlists, Search, Settings
    switch (key) {
        c.SDLK_UP => { navUp(&home_index, items); redraw(); return true; },
        c.SDLK_DOWN => { navDown(&home_index, items); redraw(); return true; },
        c.SDLK_RETURN => {
            switch (home_index) {
                0 => push(.now_playing),
                1 => { push(.library); library_index = 0; },
                2 => { push(.playlists); playlists_index = 0; },
                3 => {}, // Search (not implemented)
                4 => { push(.settings); settings_index = 0; },
                else => {},
            }
            redraw();
            return true;
        },
        else => return false,
    }
}

fn handleLibrary(key: c_int) bool {
    const items = 3; // Artists, Albums, Songs
    switch (key) {
        c.SDLK_UP => { navUp(&library_index, items); redraw(); return true; },
        c.SDLK_DOWN => { navDown(&library_index, items); redraw(); return true; },
        c.SDLK_RETURN => {
            switch (library_index) {
                0 => { push(.artists); artists_index = 0; },
                1 => { push(.albums); albums_index = 0; },
                2 => { push(.songs); songs_index = 0; },
                else => {},
            }
            redraw();
            return true;
        },
        c.SDLK_ESCAPE, c.SDLK_BACKSPACE => { pop(); redraw(); return true; },
        else => return false,
    }
}

fn handleArtists(key: c_int) bool {
    switch (key) {
        c.SDLK_UP => { navUp(&artists_index, demo_artists.len); redraw(); return true; },
        c.SDLK_DOWN => { navDown(&artists_index, demo_artists.len); redraw(); return true; },
        c.SDLK_RETURN => {
            selected_artist = artists_index;
            artist_detail_index = 0;
            push(.artist_detail);
            redraw();
            return true;
        },
        c.SDLK_ESCAPE, c.SDLK_BACKSPACE => { pop(); redraw(); return true; },
        else => return false,
    }
}

fn handleArtistDetail(key: c_int) bool {
    const artist = &demo_artists[selected_artist];
    switch (key) {
        c.SDLK_UP => { navUp(&artist_detail_index, artist.albums.len); redraw(); return true; },
        c.SDLK_DOWN => { navDown(&artist_detail_index, artist.albums.len); redraw(); return true; },
        c.SDLK_RETURN => {
            // Find album and show detail
            const album_name = artist.albums[artist_detail_index];
            for (demo_albums, 0..) |alb, i| {
                if (std.mem.eql(u8, alb.name, album_name)) {
                    selected_album = i;
                    album_detail_index = 0;
                    push(.album_detail);
                    break;
                }
            }
            redraw();
            return true;
        },
        c.SDLK_ESCAPE, c.SDLK_BACKSPACE => { pop(); redraw(); return true; },
        else => return false,
    }
}

fn handleAlbums(key: c_int) bool {
    switch (key) {
        c.SDLK_UP => { navUp(&albums_index, demo_albums.len); redraw(); return true; },
        c.SDLK_DOWN => { navDown(&albums_index, demo_albums.len); redraw(); return true; },
        c.SDLK_RETURN => {
            selected_album = albums_index;
            album_detail_index = 0;
            push(.album_detail);
            redraw();
            return true;
        },
        c.SDLK_ESCAPE, c.SDLK_BACKSPACE => { pop(); redraw(); return true; },
        else => return false,
    }
}

fn handleAlbumDetail(key: c_int) bool {
    const album = &demo_albums[selected_album];
    switch (key) {
        c.SDLK_UP => { navUp(&album_detail_index, album.songs.len); redraw(); return true; },
        c.SDLK_DOWN => { navDown(&album_detail_index, album.songs.len); redraw(); return true; },
        c.SDLK_RETURN => {
            now_playing_song = album.songs[album_detail_index];
            now_playing_artist = album.artist;
            now_playing_album = album.name;
            is_playing = true;
            push(.now_playing);
            redraw();
            return true;
        },
        c.SDLK_ESCAPE, c.SDLK_BACKSPACE => { pop(); redraw(); return true; },
        else => return false,
    }
}

fn handleSongs(key: c_int) bool {
    // Flatten all songs
    var total: usize = 0;
    for (demo_albums) |a| total += a.songs.len;

    switch (key) {
        c.SDLK_UP => { navUp(&songs_index, total); redraw(); return true; },
        c.SDLK_DOWN => { navDown(&songs_index, total); redraw(); return true; },
        c.SDLK_RETURN => {
            // Find and play selected song
            var idx: usize = 0;
            for (demo_albums) |alb| {
                for (alb.songs) |song| {
                    if (idx == songs_index) {
                        now_playing_song = song;
                        now_playing_artist = alb.artist;
                        now_playing_album = alb.name;
                        is_playing = true;
                        push(.now_playing);
                        redraw();
                        return true;
                    }
                    idx += 1;
                }
            }
            return true;
        },
        c.SDLK_ESCAPE, c.SDLK_BACKSPACE => { pop(); redraw(); return true; },
        else => return false,
    }
}

fn handlePlaylists(key: c_int) bool {
    switch (key) {
        c.SDLK_UP => { navUp(&playlists_index, demo_playlists.len); redraw(); return true; },
        c.SDLK_DOWN => { navDown(&playlists_index, demo_playlists.len); redraw(); return true; },
        c.SDLK_RETURN => {
            // Start playing playlist
            now_playing_song = "Dreams";
            now_playing_artist = "Fleetwood Mac";
            now_playing_album = "Rumours";
            is_playing = true;
            push(.now_playing);
            redraw();
            return true;
        },
        c.SDLK_ESCAPE, c.SDLK_BACKSPACE => { pop(); redraw(); return true; },
        else => return false,
    }
}

fn handleNowPlaying(key: c_int) bool {
    switch (key) {
        c.SDLK_RETURN => { is_playing = !is_playing; redraw(); return true; },
        c.SDLK_ESCAPE, c.SDLK_BACKSPACE => { pop(); redraw(); return true; },
        else => return false,
    }
}

fn handleSettings(key: c_int) bool {
    const items = 4; // Theme, Display, Playback, About
    switch (key) {
        c.SDLK_UP => { navUp(&settings_index, items); redraw(); return true; },
        c.SDLK_DOWN => { navDown(&settings_index, items); redraw(); return true; },
        c.SDLK_RETURN => {
            if (settings_index == 0) push(.theme_picker);
            redraw();
            return true;
        },
        c.SDLK_ESCAPE, c.SDLK_BACKSPACE => { pop(); redraw(); return true; },
        else => return false,
    }
}

fn handleThemePicker(key: c_int) bool {
    switch (key) {
        c.SDLK_UP => {
            if (theme_index > 0) theme_index -= 1;
            current_theme = available_themes[theme_index].theme;
            redraw();
            return true;
        },
        c.SDLK_DOWN => {
            if (theme_index < available_themes.len - 1) theme_index += 1;
            current_theme = available_themes[theme_index].theme;
            redraw();
            return true;
        },
        c.SDLK_RETURN, c.SDLK_ESCAPE, c.SDLK_BACKSPACE => { pop(); redraw(); return true; },
        else => return false,
    }
}

// ============================================================
// Drawing - Modern Minimal Style
// ============================================================

fn redraw() void {
    switch (current_screen) {
        .home => drawHome(),
        .library => drawLibrary(),
        .artists => drawArtists(),
        .artist_detail => drawArtistDetail(),
        .albums => drawAlbums(),
        .album_detail => drawAlbumDetail(),
        .songs => drawSongs(),
        .playlists => drawPlaylists(),
        .now_playing => drawNowPlaying(),
        .settings => drawSettings(),
        .theme_picker => drawThemePicker(),
    }
}

fn drawHome() void {
    const t = current_theme;
    lcd.clear(t.obsidian);

    // Minimal status bar - pure black with subtle typography
    lcd.fillRect(0, 0, WIDTH, 24, t.obsidian);
    lcd.drawString(16, 6, "ZigPod", t.pure_white, t.obsidian);

    // Time on right (simulated)
    lcd.drawString(WIDTH - 45, 6, "12:34", t.pewter, t.obsidian);

    // Main content area with accent bar selection
    const items = [_][]const u8{ "Now Playing", "Library", "Playlists", "Search", "Settings" };

    var y: u16 = 36;
    for (items, 0..) |item, i| {
        const selected = i == home_index;
        const bg = if (selected) t.selection_bg else t.obsidian;

        // Full-width row
        lcd.fillRect(0, y, WIDTH, 38, bg);

        // Cyan accent bar on left when selected
        if (selected) {
            lcd.fillRect(0, y, 3, 38, t.accent);
        }

        // Text with proper hierarchy
        lcd.drawString(20, y + 12, item, if (selected) t.pure_white else t.silver, bg);

        // Chevron indicator
        if (selected) {
            lcd.drawString(WIDTH - 24, y + 12, ">", t.accent, bg);
        }

        // Subtle separator
        lcd.fillRect(20, y + 37, WIDTH - 40, 1, t.separator);

        y += 40;
    }

    lcd.update() catch {};
}

fn drawLibrary() void {
    const t = current_theme;
    lcd.clear(t.obsidian);

    // Header
    drawHeader("Library");

    const items = [_][]const u8{ "Artists", "Albums", "Songs" };
    const counts = [_][]const u8{ "6 artists", "6 albums", "21 songs" };

    var y: u16 = 44;
    for (items, 0..) |item, i| {
        const selected = i == library_index;
        drawListItem(y, item, counts[i], selected, true);
        y += 48;
    }

    lcd.update() catch {};
}

fn drawArtists() void {
    const t = current_theme;
    lcd.clear(t.obsidian);
    drawHeader("Artists");

    const start = scroll_offset;
    const end = @min(start + MAX_VISIBLE, demo_artists.len);

    var y: u16 = 44;
    for (demo_artists[start..end], start..) |artist, i| {
        const selected = i == artists_index;
        var buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&buf, "{d} albums", .{artist.albums.len}) catch "";
        drawListItem(y, artist.name, count, selected, true);
        y += 40;
    }

    drawScrollHint(end < demo_artists.len);
    lcd.update() catch {};
}

fn drawArtistDetail() void {
    const t = current_theme;
    const artist = &demo_artists[selected_artist];
    lcd.clear(t.obsidian);

    // Large artist header with subtle depth
    lcd.fillRect(0, 0, WIDTH, 70, t.carbon);
    lcd.drawStringCentered(20, artist.name, t.pure_white, t.carbon);
    var buf: [24]u8 = undefined;
    const info = std.fmt.bufPrint(&buf, "{d} albums", .{artist.albums.len}) catch "";
    lcd.drawStringCentered(42, info, t.silver, t.carbon);

    // Albums list
    var y: u16 = 82;
    for (artist.albums, 0..) |album, i| {
        const selected = i == artist_detail_index;
        drawListItem(y, album, "", selected, true);
        y += 40;
    }

    lcd.update() catch {};
}

fn drawAlbums() void {
    const t = current_theme;
    lcd.clear(t.obsidian);
    drawHeader("Albums");

    const start = scroll_offset;
    const end = @min(start + MAX_VISIBLE, demo_albums.len);

    var y: u16 = 44;
    for (demo_albums[start..end], start..) |album, i| {
        const selected = i == albums_index;
        drawListItem(y, album.name, album.artist, selected, true);
        y += 40;
    }

    drawScrollHint(end < demo_albums.len);
    lcd.update() catch {};
}

fn drawAlbumDetail() void {
    const t = current_theme;
    const album = &demo_albums[selected_album];
    lcd.clear(t.obsidian);

    // Album header with art placeholder
    lcd.fillRect(0, 0, WIDTH, 85, t.carbon);

    // Album art placeholder
    lcd.fillRect(16, 12, 60, 60, t.slate);
    lcd.drawStringCentered(35, "Art", t.pewter, t.slate);

    // Album info
    lcd.drawString(88, 18, album.name, t.pure_white, t.carbon);
    lcd.drawString(88, 36, album.artist, t.silver, t.carbon);
    lcd.drawString(88, 52, album.year, t.pewter, t.carbon);

    // Songs list
    var y: u16 = 95;
    for (album.songs, 0..) |song, i| {
        const selected = i == album_detail_index;
        const bg = if (selected) t.selection_bg else t.obsidian;

        lcd.fillRect(0, y, WIDTH, 32, bg);

        // Accent bar for selected
        if (selected) {
            lcd.fillRect(0, y, 3, 32, t.accent);
        }

        // Track number
        var num_buf: [4]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "";
        lcd.drawString(20, y + 10, num, t.pewter, bg);

        // Song name
        lcd.drawString(44, y + 10, song, if (selected) t.pure_white else t.silver, bg);

        y += 34;
    }

    lcd.update() catch {};
}

fn drawSongs() void {
    const t = current_theme;
    lcd.clear(t.obsidian);
    drawHeader("Songs");

    // Flatten songs
    var all_songs: [32]struct { song: []const u8, artist: []const u8 } = undefined;
    var total: usize = 0;
    for (demo_albums) |alb| {
        for (alb.songs) |song| {
            if (total < 32) {
                all_songs[total] = .{ .song = song, .artist = alb.artist };
                total += 1;
            }
        }
    }

    const start = scroll_offset;
    const end = @min(start + MAX_VISIBLE, total);

    var y: u16 = 44;
    var idx: usize = start;
    while (idx < end) : (idx += 1) {
        const selected = idx == songs_index;
        drawListItem(y, all_songs[idx].song, all_songs[idx].artist, selected, false);
        y += 38;
    }

    drawScrollHint(end < total);
    lcd.update() catch {};
}

fn drawPlaylists() void {
    const t = current_theme;
    lcd.clear(t.obsidian);
    drawHeader("Playlists");

    var y: u16 = 44;
    for (demo_playlists, 0..) |playlist, i| {
        const selected = i == playlists_index;
        drawListItem(y, playlist, "", selected, true);
        y += 40;
    }

    lcd.update() catch {};
}

fn drawNowPlaying() void {
    const t = current_theme;
    lcd.clear(t.obsidian);

    // Full-width mirrored waveform visualizer - RetroFlow signature
    const viz_height: u16 = 90;
    lcd.fillRect(0, 0, WIDTH, viz_height, t.void_);

    // Draw animated visualizer bars with mirror effect
    const bar_count: u16 = 16;
    const bar_width: u16 = 14;
    const bar_gap: u16 = 4;
    const total_width = bar_count * (bar_width + bar_gap) - bar_gap;
    const start_x: u16 = (WIDTH - total_width) / 2;
    const center_y: u16 = viz_height / 2;

    for (0..bar_count) |i| {
        const bar_value = visualizer_bars[i];
        const half_height = @as(u16, bar_value) * 35 / 100; // Max 35px each direction
        const x = start_x + @as(u16, @intCast(i)) * (bar_width + bar_gap);

        if (half_height > 0) {
            // Upper bar (extends up from center)
            lcd.fillRect(x, center_y - half_height, bar_width, half_height, t.accent);

            // Lower bar (mirror, extends down from center)
            lcd.fillRect(x, center_y, bar_width, half_height, t.accent_muted);

            // Glowing tips
            if (half_height > 3) {
                lcd.fillRect(x, center_y - half_height, bar_width, 2, t.accent_bright);
                lcd.fillRect(x, center_y + half_height - 2, bar_width, 2, t.accent_muted);
            }
        }

        // Center line reflection
        lcd.fillRect(x, center_y - 1, bar_width, 2, t.carbon);
    }

    // Song info section
    const info_y: u16 = viz_height + 8;

    // Album art thumbnail
    const thumb_size: u16 = 56;
    lcd.fillRect(16, info_y, thumb_size, thumb_size, t.slate);

    // Song details
    if (now_playing_song) |song| {
        lcd.drawString(80, info_y + 6, song, t.pure_white, t.obsidian);
    } else {
        lcd.drawString(80, info_y + 6, "Not Playing", t.silver, t.obsidian);
    }

    if (now_playing_artist) |artist| {
        lcd.drawString(80, info_y + 24, artist, t.silver, t.obsidian);
    }

    if (now_playing_album) |album| {
        lcd.drawString(80, info_y + 40, album, t.pewter, t.obsidian);
    }

    // Progress section
    const progress_y: u16 = 178;

    // Time elapsed
    lcd.drawString(16, progress_y, "1:24", t.pewter, t.obsidian);

    // Progress bar - sleek cyan line
    const bar_x: u16 = 50;
    const bar_w: u16 = WIDTH - 100;
    lcd.fillRect(bar_x, progress_y + 6, bar_w, 2, t.carbon);

    const progress_w: u16 = @intCast((bar_w * playback_progress) / 100);
    lcd.fillRect(bar_x, progress_y + 6, progress_w, 2, t.accent);

    // Progress indicator dot
    if (progress_w > 0) {
        lcd.fillRect(bar_x + progress_w - 4, progress_y + 2, 8, 10, t.accent);
    }

    // Time remaining
    lcd.drawString(WIDTH - 42, progress_y, "3:45", t.pewter, t.obsidian);

    // Playback controls
    const ctrl_y: u16 = 208;

    // Previous
    lcd.drawString(WIDTH / 2 - 60, ctrl_y, "|<", t.pewter, t.obsidian);

    // Play/Pause
    if (is_playing) {
        // Pause bars in accent color
        lcd.fillRect(WIDTH / 2 - 8, ctrl_y - 2, 5, 16, t.accent);
        lcd.fillRect(WIDTH / 2 + 3, ctrl_y - 2, 5, 16, t.accent);
    } else {
        lcd.drawString(WIDTH / 2 - 4, ctrl_y, ">", t.accent, t.obsidian);
    }

    // Next
    lcd.drawString(WIDTH / 2 + 50, ctrl_y, ">|", t.pewter, t.obsidian);

    // State indicators at bottom
    const state_y: u16 = 228;
    lcd.drawString(WIDTH / 2 - 50, state_y, "Shuffle", if (is_playing) t.pewter else t.graphite, t.obsidian);
    lcd.drawString(WIDTH / 2 + 20, state_y, "Repeat", t.graphite, t.obsidian);

    lcd.update() catch {};
}

fn drawSettings() void {
    const t = current_theme;
    lcd.clear(t.obsidian);
    drawHeader("Settings");

    const items = [_][]const u8{ "Theme", "Display", "Playback", "About" };
    const values = [_][]const u8{ available_themes[theme_index].name, "Auto", "Gapless On", "v0.1" };

    var y: u16 = 44;
    for (items, 0..) |item, i| {
        const selected = i == settings_index;
        const bg = if (selected) t.selection_bg else t.obsidian;

        lcd.fillRect(0, y, WIDTH, 40, bg);

        // Accent bar for selected
        if (selected) {
            lcd.fillRect(0, y, 3, 40, t.accent);
        }

        lcd.drawString(20, y + 12, item, if (selected) t.pure_white else t.silver, bg);
        lcd.drawString(WIDTH - 120, y + 12, values[i], t.pewter, bg);

        // Separator
        if (i < items.len - 1) {
            lcd.fillRect(20, y + 39, WIDTH - 40, 1, t.separator);
        }

        y += 42;
    }

    lcd.update() catch {};
}

fn drawThemePicker() void {
    const t = current_theme;
    lcd.clear(t.obsidian);
    drawHeader("Choose Theme");

    var y: u16 = 44;
    for (available_themes, 0..) |th, i| {
        const selected = i == theme_index;
        const bg = if (selected) t.selection_bg else t.obsidian;

        lcd.fillRect(0, y, WIDTH, 36, bg);

        // Accent bar for selected
        if (selected) {
            lcd.fillRect(0, y, 3, 36, t.accent);
        }

        // Color preview swatch
        lcd.fillRect(20, y + 8, 20, 20, th.theme.accent);

        lcd.drawString(50, y + 11, th.name, if (selected) t.pure_white else t.silver, bg);

        if (selected) {
            lcd.drawString(WIDTH - 30, y + 11, "*", t.accent, bg);
        }

        y += 38;
    }

    lcd.update() catch {};
}

// ============================================================
// Drawing Helpers - RetroFlow Style
// ============================================================

fn drawHeader(title: []const u8) void {
    const t = current_theme;
    lcd.fillRect(0, 0, WIDTH, 36, t.obsidian);

    // Back indicator with accent
    lcd.drawString(12, 10, "<", t.accent, t.obsidian);

    // Title - prominent white text
    lcd.drawStringCentered(10, title, t.pure_white, t.obsidian);

    // Separator - subtle line
    lcd.fillRect(0, 35, WIDTH, 1, t.separator);
}

fn drawListItem(y: u16, primary: []const u8, secondary: []const u8, selected: bool, show_arrow: bool) void {
    const t = current_theme;
    const bg = if (selected) t.selection_bg else t.obsidian;

    lcd.fillRect(0, y, WIDTH, 38, bg);

    // Accent bar for selected item
    if (selected) {
        lcd.fillRect(0, y, 3, 38, t.accent);
    }

    // Primary text
    lcd.drawString(20, y + 6, primary, if (selected) t.pure_white else t.silver, bg);

    // Secondary text
    if (secondary.len > 0) {
        lcd.drawString(20, y + 22, secondary, t.pewter, bg);
    }

    // Chevron arrow in accent color
    if (show_arrow and selected) {
        lcd.drawString(WIDTH - 24, y + 12, ">", t.accent, bg);
    }

    // Separator
    lcd.fillRect(20, y + 37, WIDTH - 40, 1, t.separator);
}

fn drawScrollHint(has_more: bool) void {
    if (has_more) {
        const t = current_theme;
        lcd.drawString(WIDTH / 2 - 4, HEIGHT - 16, "v", t.pewter, t.obsidian);
    }
}
