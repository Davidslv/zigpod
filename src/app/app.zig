//! Application Controller
//!
//! Main application logic that coordinates UI screens, playback, and navigation.
//! Manages the overall application state and screen transitions.

const std = @import("std");
const hal = @import("../hal/hal.zig");
const ui = @import("../ui/ui.zig");
const audio = @import("../audio/audio.zig");
const lcd = @import("../drivers/display/lcd.zig");
const clickwheel = @import("../drivers/input/clickwheel.zig");
const power = @import("../drivers/power.zig");
const now_playing = @import("../ui/now_playing.zig");
const file_browser = @import("../ui/file_browser.zig");
const music_browser = @import("../ui/music_browser.zig");
const settings_ui = @import("../ui/settings.zig");
const music_db = @import("../library/music_db.zig");

// ============================================================
// Application Screens
// ============================================================

pub const Screen = enum {
    boot,
    main_menu,
    music,
    playlists,
    artists,
    albums,
    songs,
    file_browser,
    now_playing,
    settings,
    about,
};

// ============================================================
// Application State
// ============================================================

/// Error severity levels for tracking system health
pub const ErrorSeverity = enum {
    none,
    warning, // Recoverable, operation continues
    significant, // Significant but non-fatal
    critical, // May affect system stability
};

/// System error state for tracking errors
pub const ErrorState = struct {
    severity: ErrorSeverity = .none,
    error_count: u32 = 0,
    last_error_source: []const u8 = "",

    pub fn record(self: *ErrorState, source: []const u8, severity: ErrorSeverity) void {
        self.error_count += 1;
        self.last_error_source = source;
        // Keep highest severity
        if (@intFromEnum(severity) > @intFromEnum(self.severity)) {
            self.severity = severity;
        }
    }

    pub fn clear(self: *ErrorState) void {
        self.severity = .none;
    }

    pub fn hasErrors(self: *const ErrorState) bool {
        return self.severity != .none;
    }
};

pub const AppState = struct {
    current_screen: Screen = .boot,
    previous_screen: Screen = .boot,
    needs_redraw: bool = true,

    // Error tracking for system health
    error_state: ErrorState = .{},

    // Screen-specific state
    main_menu: ui.Menu = undefined,
    file_browser: file_browser.FileBrowser = undefined,
    music_browser_state: music_browser.MusicBrowser = undefined,
    settings_browser_state: settings_ui.SettingsBrowser = undefined,
    now_playing_state: now_playing.NowPlayingState = .{},

    // Navigation stack (for back button)
    screen_stack: [8]Screen = [_]Screen{.main_menu} ** 8,
    stack_depth: u8 = 0,

    pub fn pushScreen(self: *AppState, screen: Screen) void {
        if (self.stack_depth < self.screen_stack.len) {
            self.screen_stack[self.stack_depth] = self.current_screen;
            self.stack_depth += 1;
        }
        self.previous_screen = self.current_screen;
        self.current_screen = screen;
        self.needs_redraw = true;
    }

    pub fn popScreen(self: *AppState) void {
        if (self.stack_depth > 0) {
            self.stack_depth -= 1;
            self.previous_screen = self.current_screen;
            self.current_screen = self.screen_stack[self.stack_depth];
            self.needs_redraw = true;
        }
    }

    pub fn goToScreen(self: *AppState, screen: Screen) void {
        self.previous_screen = self.current_screen;
        self.current_screen = screen;
        self.needs_redraw = true;
    }
};

var app_state = AppState{};

// ============================================================
// Main Menu
// ============================================================

var main_menu_items = [_]ui.MenuItem{
    .{ .label = "Music", .icon = "[M]" },
    .{ .label = "Playlists", .icon = "[P]" },
    .{ .label = "Browse Files", .icon = "[F]" },
    .{ .label = "Now Playing", .icon = "[>]" },
    .{ .label = "", .item_type = .separator },
    .{ .label = "Settings", .icon = "[S]" },
};

// ============================================================
// Initialization
// ============================================================

/// Initialize the application
pub fn init() void {
    // Load settings from storage (or use defaults)
    settings_ui.initSettings();

    // Initialize main menu
    app_state.main_menu = ui.Menu{
        .title = "ZigPod",
        .items = &main_menu_items,
    };

    // Initialize file browser
    app_state.file_browser = file_browser.FileBrowser.init();

    // Initialize music browser
    app_state.music_browser_state = music_browser.MusicBrowser.init();

    // Initialize settings browser
    app_state.settings_browser_state = settings_ui.SettingsBrowser.init();

    // Scan music library in background
    music_db.scanDefaultPaths();

    // Set initial screen
    app_state.current_screen = .main_menu;
    app_state.needs_redraw = true;
}

/// Get the current application state
pub fn getState() *AppState {
    return &app_state;
}

// ============================================================
// Main Loop
// ============================================================

/// Process one frame of the application
pub fn update() void {
    // Record activity for power management
    power.recordActivity();

    // Poll input
    const event = clickwheel.poll() catch return;

    // Handle input for current screen
    if (event.anyButtonPressed() or event.wheel_delta != 0) {
        handleInput(event);
    }

    // Update now playing state if on that screen
    if (app_state.current_screen == .now_playing) {
        app_state.now_playing_state.syncWithAudio();
        app_state.needs_redraw = true;
    }

    // Process audio - errors are non-fatal, continue playback
    audio.process() catch {
        app_state.error_state.record("audio.process", .warning);
    };

    // Check power management
    power.checkBacklightTimeout();
    if (power.checkSleepTimer()) {
        audio.pause();
        power.setState(.standby) catch {
            app_state.error_state.record("power.setState", .significant);
        };
    }

    // Sync error state to UI for status bar indicator
    syncErrorStateToUI();

    // Draw if needed
    if (app_state.needs_redraw) {
        draw();
        app_state.needs_redraw = false;
    }
}

/// Sync error state to UI system for status bar display
fn syncErrorStateToUI() void {
    const error_state = app_state.error_state;
    const ui_severity: ui.ErrorIndicator.ErrorSeverity = switch (error_state.severity) {
        .none => .none,
        .warning => .warning,
        .significant => .significant,
        .critical => .critical,
    };
    ui.updateErrorStatus(
        error_state.hasErrors(),
        error_state.error_count,
        ui_severity,
    );
}

// ============================================================
// Input Handling
// ============================================================

fn handleInput(event: clickwheel.InputEvent) void {
    // Global PLAY button shortcut - jump to Now Playing from anywhere
    // (except when already on Now Playing screen)
    if (app_state.current_screen != .now_playing) {
        if (event.buttonPressed(clickwheel.Button.PLAY)) {
            // If something is playing/paused, go to Now Playing
            if (audio.hasLoadedTrack()) {
                app_state.pushScreen(.now_playing);
                app_state.needs_redraw = true;
                return;
            }
        }
    }

    switch (app_state.current_screen) {
        .main_menu => handleMainMenuInput(event),
        .music => handleMusicBrowserInput(event),
        .file_browser => handleFileBrowserInput(event),
        .now_playing => handleNowPlayingInput(event),
        .settings => handleSettingsInput(event),
        .about => handleAboutInput(event),
        else => handleGenericInput(event),
    }
}

fn handleMainMenuInput(event: clickwheel.InputEvent) void {
    const result = ui.handleMenuInput(&app_state.main_menu, event);

    if (result != &app_state.main_menu) {
        // Menu selection occurred
        switch (app_state.main_menu.selected_index) {
            0 => app_state.pushScreen(.music),
            1 => app_state.pushScreen(.playlists),
            2 => {
                app_state.file_browser.refresh() catch {
                    app_state.error_state.record("file_browser.refresh", .warning);
                };
                app_state.pushScreen(.file_browser);
            },
            3 => app_state.pushScreen(.now_playing),
            5 => app_state.pushScreen(.settings),
            else => {},
        }
    }

    app_state.needs_redraw = true;
}

fn handleMusicBrowserInput(event: clickwheel.InputEvent) void {
    const action = music_browser.handleInput(
        &app_state.music_browser_state,
        event.buttons,
        event.wheel_delta,
    );

    switch (action) {
        .exit_browser => app_state.popScreen(),
        .play_track => {
            // Update now playing metadata
            const track_info = audio.getLoadedTrackInfo();
            app_state.now_playing_state.metadata.title = track_info.getTitle();
            app_state.now_playing_state.metadata.artist = track_info.getArtist();
            app_state.now_playing_state.metadata.album = track_info.getAlbum();
            app_state.pushScreen(.now_playing);
        },
        .play_error => {
            showMessage("Error", "Could not play track");
        },
        .shuffle_all => {
            // TODO: Implement shuffle all
            showMessage("Shuffle", "Coming soon");
        },
        .none => {},
    }

    app_state.needs_redraw = true;
}

fn handleFileBrowserInput(event: clickwheel.InputEvent) void {
    const action = file_browser.handleInput(
        &app_state.file_browser,
        event.buttons,
        event.wheel_delta,
    ) catch .none;

    switch (action) {
        .play_file => {
            // Get the full path of the selected file
            var path_buffer: [256]u8 = undefined;
            if (app_state.file_browser.getSelectedPath(&path_buffer)) |path| {
                // Set single file in playback queue (no next/prev from file browser)
                const queue = audio.playback_queue.getQueue();
                queue.setSingleFile(path);

                // Load and play the file
                audio.loadFile(path) catch |err| {
                    // Show error message
                    const msg = switch (err) {
                        audio.LoadError.FileNotFound => "File not found",
                        audio.LoadError.UnsupportedFormat => "Unsupported format",
                        audio.LoadError.FileTooLarge => "File too large",
                        audio.LoadError.DecoderError => "Decoder error",
                        audio.LoadError.NotInitialized => "Audio not ready",
                        else => "Load failed",
                    };
                    showMessage("Error", msg);
                    return;
                };

                // Update now playing metadata from loaded track
                const track_info = audio.getLoadedTrackInfo();
                app_state.now_playing_state.metadata.title = track_info.getTitle();
                app_state.now_playing_state.metadata.artist = track_info.getArtist();
                app_state.now_playing_state.metadata.album = track_info.getAlbum();

                // Switch to now playing screen
                app_state.pushScreen(.now_playing);
            }
        },
        .back => app_state.popScreen(),
        else => {},
    }

    app_state.needs_redraw = true;
}

fn handleNowPlayingInput(event: clickwheel.InputEvent) void {
    const action = now_playing.handleInput(
        &app_state.now_playing_state,
        event.buttons,
        event.wheel_delta,
    );

    switch (action) {
        .toggle_play => audio.togglePause(),
        .next_track => {
            audio.nextTrack();
        },
        .prev_track => {
            audio.prevTrack();
        },
        .volume_up, .volume_down => {
            // Volume is already adjusted in handleInput
            const vol_db: i16 = @as(i16, @intCast(app_state.now_playing_state.volume)) - 50;
            audio.setVolumeMono(vol_db) catch {
                app_state.error_state.record("audio.setVolumeMono", .warning);
            };
            // Show volume overlay
            const timestamp: u32 = @intCast(hal.getTicksUs() / 1000);
            ui.getOverlay().showVolume(app_state.now_playing_state.volume, timestamp);
        },
        .toggle_shuffle => {
            const queue = audio.playback_queue.getQueue();
            queue.toggleShuffle();
        },
        .toggle_repeat => {
            const queue = audio.playback_queue.getQueue();
            queue.toggleRepeat();
        },
        .open_menu => app_state.popScreen(),
        .back => app_state.popScreen(),
        else => {},
    }

    app_state.needs_redraw = true;
}

fn handleSettingsInput(event: clickwheel.InputEvent) void {
    const action = settings_ui.handleSettingsBrowserInput(
        &app_state.settings_browser_state,
        event.buttons,
        event.wheel_delta,
    );

    switch (action) {
        .exit => {
            // Save settings when exiting settings screen
            settings_ui.saveSettings();
            app_state.popScreen();
        },
        .show_about => {
            app_state.settings_browser_state.category = .about;
            app_state.pushScreen(.about);
        },
        .none => {},
    }

    app_state.needs_redraw = true;
}

fn handleAboutInput(event: clickwheel.InputEvent) void {
    // Any button goes back
    if (event.anyButtonPressed()) {
        app_state.popScreen();
    }
}

fn handleGenericInput(event: clickwheel.InputEvent) void {
    // Generic back handling
    if (event.buttonPressed(clickwheel.Button.MENU)) {
        app_state.popScreen();
    }
    app_state.needs_redraw = true;
}

// ============================================================
// Drawing
// ============================================================

fn draw() void {
    switch (app_state.current_screen) {
        .boot => drawBootScreen(),
        .main_menu => ui.drawMenu(&app_state.main_menu),
        .music => music_browser.draw(&app_state.music_browser_state),
        .file_browser => file_browser.draw(&app_state.file_browser),
        .now_playing => now_playing.draw(&app_state.now_playing_state),
        .settings => settings_ui.drawSettingsBrowser(&app_state.settings_browser_state),
        .about => settings_ui.drawAboutScreen(),
        else => drawPlaceholder(),
    }

    // Draw battery indicator in header
    drawBatteryIndicator();

    // Draw overlay (volume, battery warning, etc.) on top of all screens
    const timestamp: u32 = @intCast(hal.getTicksUs() / 1000);
    ui.drawOverlay(timestamp);

    lcd.update() catch {
        app_state.error_state.record("lcd.update", .warning);
    };
}

fn drawBootScreen() void {
    const theme = ui.getTheme();
    lcd.clear(theme.background);
    lcd.drawStringCentered(100, "ZigPod OS", theme.foreground, null);
    lcd.drawStringCentered(120, "v0.1.0", theme.disabled, null);
}

fn drawSettingsScreen() void {
    // For now, just show the main settings menu
    var settings_items = [_]ui.MenuItem{
        .{ .label = "Display", .item_type = .submenu },
        .{ .label = "Audio", .item_type = .submenu },
        .{ .label = "Playback", .item_type = .submenu },
        .{ .label = "System", .item_type = .submenu },
        .{ .label = "", .item_type = .separator },
        .{ .label = "About ZigPod" },
    };

    var settings_menu = ui.Menu{
        .title = "Settings",
        .items = &settings_items,
    };

    ui.drawMenu(&settings_menu);
}

fn drawPlaceholder() void {
    const theme = ui.getTheme();
    lcd.clear(theme.background);

    const screen_name = switch (app_state.current_screen) {
        .music => "Music",
        .playlists => "Playlists",
        .artists => "Artists",
        .albums => "Albums",
        .songs => "Songs",
        else => "Screen",
    };

    ui.drawHeader(screen_name);
    lcd.drawStringCentered(ui.SCREEN_HEIGHT / 2, "Coming Soon", theme.disabled, null);
    ui.drawFooter("Menu: Back");
}

fn drawBatteryIndicator() void {
    const info = power.getBatteryInfo();
    const theme = ui.getTheme();

    // Draw in top-right corner
    const icon = info.getIcon();
    const x = ui.SCREEN_WIDTH - @as(u16, @intCast(icon.len * ui.CHAR_WIDTH + 4));
    lcd.drawString(x, 2, icon, theme.header_fg, theme.header_bg);
}

// ============================================================
// Utility Functions
// ============================================================

/// Play a file from the file browser
pub fn playFile(path: []const u8) !void {
    // Load and play the file
    audio.loadFile(path) catch |err| {
        const msg = switch (err) {
            audio.LoadError.FileNotFound => "File not found",
            audio.LoadError.UnsupportedFormat => "Unsupported format",
            audio.LoadError.FileTooLarge => "File too large",
            audio.LoadError.DecoderError => "Decoder error",
            audio.LoadError.NotInitialized => "Audio not ready",
            else => "Load failed",
        };
        showMessage("Error", msg);
        return err;
    };

    // Update now playing metadata from loaded track
    const track_info = audio.getLoadedTrackInfo();
    app_state.now_playing_state.metadata.title = track_info.getTitle();
    app_state.now_playing_state.metadata.artist = track_info.getArtist();
    app_state.now_playing_state.metadata.album = track_info.getAlbum();

    // Switch to Now Playing screen
    app_state.goToScreen(.now_playing);
}

/// Show a temporary message
pub fn showMessage(title: []const u8, message: []const u8) void {
    ui.drawMessageBox(title, message);
    lcd.update() catch {
        app_state.error_state.record("lcd.update", .warning);
    };
}

// ============================================================
// Tests
// ============================================================

test "app state screen navigation" {
    var state = AppState{};

    state.pushScreen(.settings);
    try std.testing.expectEqual(Screen.settings, state.current_screen);
    try std.testing.expectEqual(@as(u8, 1), state.stack_depth);

    state.pushScreen(.about);
    try std.testing.expectEqual(Screen.about, state.current_screen);
    try std.testing.expectEqual(@as(u8, 2), state.stack_depth);

    state.popScreen();
    try std.testing.expectEqual(Screen.settings, state.current_screen);
    try std.testing.expectEqual(@as(u8, 1), state.stack_depth);

    state.popScreen();
    try std.testing.expectEqual(Screen.boot, state.current_screen);
    try std.testing.expectEqual(@as(u8, 0), state.stack_depth);
}
