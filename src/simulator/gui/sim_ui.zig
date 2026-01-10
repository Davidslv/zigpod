//! Simulator UI Renderer
//!
//! Renders ZigPod-like UI screens to the simulator's LCD framebuffer.
//! Provides main menu, file browser, and now playing screens.

const std = @import("std");

// ============================================================
// Constants
// ============================================================

const WIDTH: usize = 320;
const HEIGHT: usize = 240;

// Colors (RGB565)
const COLOR_BG: u16 = rgb565(20, 20, 25);
const COLOR_HEADER_BG: u16 = rgb565(40, 40, 50);
const COLOR_HEADER_FG: u16 = rgb565(200, 200, 220);
const COLOR_TEXT: u16 = rgb565(220, 220, 230);
const COLOR_TEXT_DIM: u16 = rgb565(120, 120, 140);
const COLOR_SELECTED_BG: u16 = rgb565(60, 100, 180);
const COLOR_SELECTED_FG: u16 = rgb565(255, 255, 255);
const COLOR_ACCENT: u16 = rgb565(80, 140, 255);
const COLOR_FOOTER_BG: u16 = rgb565(30, 30, 40);

// Layout
const HEADER_HEIGHT: usize = 28;
const FOOTER_HEIGHT: usize = 24;
const ITEM_HEIGHT: usize = 24;
const CONTENT_Y: usize = HEADER_HEIGHT + 4;
const CONTENT_HEIGHT: usize = HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT - 8;

// ============================================================
// UI State
// ============================================================

pub const Screen = enum {
    main_menu,
    file_browser,
    now_playing,
};

pub const SimulatorUI = struct {
    screen: Screen = .main_menu,
    main_menu_selection: usize = 0,
    file_browser_selection: usize = 0,
    file_browser_scroll: usize = 0,
    files: [32]FileEntry = undefined,
    file_count: usize = 0,
    current_path: [256]u8 = undefined,
    current_path_len: usize = 0,
    audio_playing: bool = false,

    // Playback queue (all audio files in current directory)
    queue: [32]FileEntry = undefined,
    queue_count: usize = 0,
    queue_position: usize = 0,

    // Shuffle mode
    shuffle_enabled: bool = false,
    shuffle_order: [32]usize = [_]usize{0} ** 32, // Shuffled indices
    original_order: [32]usize = [_]usize{0} ** 32, // Original indices for unshuffle

    const Self = @This();

    pub fn init() Self {
        var ui = Self{};
        // Set initial path to audio-samples
        const default_path = "audio-samples";
        @memcpy(ui.current_path[0..default_path.len], default_path);
        ui.current_path_len = default_path.len;
        return ui;
    }

    /// Build queue from current directory's audio files
    fn buildQueue(self: *Self, start_file: []const u8) void {
        self.queue_count = 0;
        self.queue_position = 0;

        // Copy audio files from file list to queue
        for (self.files[0..self.file_count]) |entry| {
            if (!entry.is_dir) {
                if (self.queue_count < self.queue.len) {
                    self.queue[self.queue_count] = entry;
                    // Check if this is the starting file
                    if (std.mem.eql(u8, entry.getName(), start_file)) {
                        self.queue_position = self.queue_count;
                    }
                    self.queue_count += 1;
                }
            }
        }
    }

    /// Get next track in queue
    pub fn nextTrack(self: *Self) ?[]const u8 {
        if (self.queue_count == 0) return null;
        if (self.queue_position + 1 < self.queue_count) {
            self.queue_position += 1;
            return self.getQueueTrackPath();
        }
        return null;
    }

    /// Get previous track in queue
    pub fn prevTrack(self: *Self) ?[]const u8 {
        if (self.queue_count == 0) return null;
        if (self.queue_position > 0) {
            self.queue_position -= 1;
            return self.getQueueTrackPath();
        }
        return null;
    }

    /// Get full path of current queue track
    fn getQueueTrackPath(self: *Self) []const u8 {
        if (self.queue_position >= self.queue_count) return "";
        const actual_idx = self.getActualIndex(self.queue_position);
        const entry = &self.queue[actual_idx];
        return self.getFullPath(entry.getName());
    }

    /// Check if there's a next track
    pub fn hasNext(self: *const Self) bool {
        return self.queue_count > 0 and self.queue_position + 1 < self.queue_count;
    }

    /// Check if there's a previous track
    pub fn hasPrevious(self: *const Self) bool {
        return self.queue_count > 0 and self.queue_position > 0;
    }

    /// Toggle shuffle mode
    pub fn toggleShuffle(self: *Self) void {
        if (self.shuffle_enabled) {
            self.disableShuffle();
        } else {
            self.enableShuffle();
        }
    }

    /// Enable shuffle
    pub fn enableShuffle(self: *Self) void {
        if (self.queue_count <= 1) return;

        // Save original order
        for (0..self.queue_count) |i| {
            self.original_order[i] = i;
            self.shuffle_order[i] = i;
        }

        // Get current track index before shuffle
        const current_actual = self.shuffle_order[self.queue_position];

        // Fisher-Yates shuffle, keeping current track at position 0
        self.shuffle_order[self.queue_position] = self.shuffle_order[0];
        self.shuffle_order[0] = current_actual;

        // Shuffle the rest
        var prng: u32 = @truncate(@as(u64, @bitCast(std.time.milliTimestamp())));
        var i: usize = self.queue_count - 1;
        while (i > 1) : (i -= 1) {
            prng = prng *% 1664525 +% 1013904223;
            const j = 1 + (prng % i);
            const tmp = self.shuffle_order[i];
            self.shuffle_order[i] = self.shuffle_order[j];
            self.shuffle_order[j] = tmp;
        }

        self.queue_position = 0;
        self.shuffle_enabled = true;
    }

    /// Disable shuffle
    pub fn disableShuffle(self: *Self) void {
        if (!self.shuffle_enabled) return;

        // Find current track in shuffled order
        const current_shuffled_idx = self.shuffle_order[self.queue_position];

        // Restore original order
        for (0..self.queue_count) |i| {
            self.shuffle_order[i] = i;
        }

        // Find position of current track in original order
        self.queue_position = current_shuffled_idx;
        self.shuffle_enabled = false;
    }

    /// Get the actual queue index for current position (handles shuffle)
    fn getActualIndex(self: *const Self, pos: usize) usize {
        if (self.shuffle_enabled and pos < self.queue_count) {
            return self.shuffle_order[pos];
        }
        return pos;
    }

    pub fn handleInput(self: *Self, button: Button, wheel_delta: i8) ?Action {
        switch (self.screen) {
            .main_menu => return self.handleMainMenuInput(button, wheel_delta),
            .file_browser => return self.handleFileBrowserInput(button, wheel_delta),
            .now_playing => return self.handleNowPlayingInput(button, wheel_delta),
        }
    }

    fn handleMainMenuInput(self: *Self, button: Button, wheel_delta: i8) ?Action {
        // Wheel navigation
        if (wheel_delta > 0) {
            if (self.main_menu_selection < main_menu_items.len - 1) {
                self.main_menu_selection += 1;
            }
        } else if (wheel_delta < 0) {
            if (self.main_menu_selection > 0) {
                self.main_menu_selection -= 1;
            }
        }

        // Button handling
        switch (button) {
            .select, .right => {
                switch (self.main_menu_selection) {
                    0 => { // Music
                        self.screen = .file_browser;
                        self.scanDirectory();
                        return null;
                    },
                    1 => { // Files
                        self.screen = .file_browser;
                        self.scanDirectory();
                        return null;
                    },
                    2 => { // Now Playing
                        self.screen = .now_playing;
                        return null;
                    },
                    else => {},
                }
            },
            .play_pause => {
                if (self.audio_playing) {
                    return .toggle_play;
                }
            },
            else => {},
        }
        return null;
    }

    fn handleFileBrowserInput(self: *Self, button: Button, wheel_delta: i8) ?Action {
        const visible_items = (CONTENT_HEIGHT / ITEM_HEIGHT);

        // Wheel navigation
        if (wheel_delta > 0) {
            if (self.file_browser_selection < self.file_count -| 1) {
                self.file_browser_selection += 1;
                // Scroll if needed
                if (self.file_browser_selection >= self.file_browser_scroll + visible_items) {
                    self.file_browser_scroll = self.file_browser_selection - visible_items + 1;
                }
            }
        } else if (wheel_delta < 0) {
            if (self.file_browser_selection > 0) {
                self.file_browser_selection -= 1;
                // Scroll if needed
                if (self.file_browser_selection < self.file_browser_scroll) {
                    self.file_browser_scroll = self.file_browser_selection;
                }
            }
        }

        // Button handling
        switch (button) {
            .select, .right => {
                if (self.file_count > 0 and self.file_browser_selection < self.file_count) {
                    const entry = &self.files[self.file_browser_selection];
                    if (entry.is_dir) {
                        // Navigate into directory
                        self.navigateToDir(entry.getName());
                    } else {
                        // Build queue from all audio files in this folder
                        self.buildQueue(entry.getName());
                        // Play audio file
                        return Action{ .play_file = self.getFullPath(entry.getName()) };
                    }
                }
            },
            .menu, .left => {
                // Go back
                if (self.current_path_len > 0) {
                    self.navigateUp();
                } else {
                    self.screen = .main_menu;
                }
            },
            else => {},
        }
        return null;
    }

    fn handleNowPlayingInput(self: *Self, button: Button, wheel_delta: i8) ?Action {
        // Volume control with wheel
        if (wheel_delta != 0) {
            return Action{ .volume_change = wheel_delta * 5 };
        }

        switch (button) {
            .play_pause => return .toggle_play,
            .select => return .toggle_shuffle,
            .menu => {
                self.screen = .file_browser;
            },
            .left => {
                // Previous track
                if (self.prevTrack()) |path| {
                    return Action{ .play_file = path };
                }
            },
            .right => {
                // Next track
                if (self.nextTrack()) |path| {
                    return Action{ .play_file = path };
                }
            },
            else => {},
        }
        return null;
    }

    fn scanDirectory(self: *Self) void {
        self.file_count = 0;
        self.file_browser_selection = 0;
        self.file_browser_scroll = 0;

        const path = self.current_path[0..self.current_path_len];

        // Open directory
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (self.file_count >= self.files.len) break;

            // Filter: show directories and audio files
            const is_audio = std.mem.endsWith(u8, entry.name, ".wav") or
                std.mem.endsWith(u8, entry.name, ".mp3") or
                std.mem.endsWith(u8, entry.name, ".flac");

            if (entry.kind == .directory or is_audio) {
                var fe = &self.files[self.file_count];
                const len = @min(entry.name.len, fe.name.len - 1);
                @memcpy(fe.name[0..len], entry.name[0..len]);
                fe.name[len] = 0;
                fe.name_len = len;
                fe.is_dir = entry.kind == .directory;
                self.file_count += 1;
            }
        }

        // Sort: directories first, then alphabetically
        std.mem.sort(FileEntry, self.files[0..self.file_count], {}, struct {
            fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.mem.lessThan(u8, a.getName(), b.getName());
            }
        }.lessThan);
    }

    fn navigateToDir(self: *Self, dirname: []const u8) void {
        if (self.current_path_len + 1 + dirname.len < self.current_path.len) {
            if (self.current_path_len > 0) {
                self.current_path[self.current_path_len] = '/';
                self.current_path_len += 1;
            }
            @memcpy(self.current_path[self.current_path_len..][0..dirname.len], dirname);
            self.current_path_len += dirname.len;
            self.scanDirectory();
        }
    }

    fn navigateUp(self: *Self) void {
        // Find last '/'
        var i = self.current_path_len;
        while (i > 0) : (i -= 1) {
            if (self.current_path[i - 1] == '/') {
                self.current_path_len = i - 1;
                self.scanDirectory();
                return;
            }
        }
        // No slash found - go to root
        self.current_path_len = 0;
        self.screen = .main_menu;
    }

    fn getFullPath(self: *Self, filename: []const u8) []const u8 {
        var path_buf: [512]u8 = undefined;
        const path = self.current_path[0..self.current_path_len];
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ path, filename }) catch return filename;
        // Copy to static buffer for return
        @memcpy(self.current_path[0..full.len], full);
        return self.current_path[0..full.len];
    }
};

pub const FileEntry = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    is_dir: bool = false,

    pub fn getName(self: *const FileEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Button = enum {
    none,
    menu,
    play_pause,
    left,
    right,
    select,
};

pub const Action = union(enum) {
    toggle_play: void,
    play_file: []const u8,
    seek_forward: void,
    volume_change: i8,
    toggle_shuffle: void,
};

// ============================================================
// Main Menu Items
// ============================================================

const main_menu_items = [_][]const u8{
    "Music",
    "Browse Files",
    "Now Playing",
    "Settings",
};

// ============================================================
// Rendering
// ============================================================

pub fn render(framebuffer: []u16, ui: *const SimulatorUI, player_info: ?PlayerInfo) void {
    switch (ui.screen) {
        .main_menu => renderMainMenu(framebuffer, ui),
        .file_browser => renderFileBrowser(framebuffer, ui),
        .now_playing => renderNowPlaying(framebuffer, player_info),
    }
}

fn renderMainMenu(framebuffer: []u16, ui: *const SimulatorUI) void {
    // Background
    fillRect(framebuffer, 0, 0, WIDTH, HEIGHT, COLOR_BG);

    // Header
    fillRect(framebuffer, 0, 0, WIDTH, HEADER_HEIGHT, COLOR_HEADER_BG);
    drawText(framebuffer, 10, 8, "ZigPod", COLOR_HEADER_FG);

    // Menu items
    for (main_menu_items, 0..) |item, i| {
        const y = CONTENT_Y + i * ITEM_HEIGHT;
        const selected = i == ui.main_menu_selection;

        if (selected) {
            fillRect(framebuffer, 0, y, WIDTH, ITEM_HEIGHT, COLOR_SELECTED_BG);
            drawText(framebuffer, 20, y + 6, item, COLOR_SELECTED_FG);
        } else {
            drawText(framebuffer, 20, y + 6, item, COLOR_TEXT);
        }
    }

    // Footer
    fillRect(framebuffer, 0, HEIGHT - FOOTER_HEIGHT, WIDTH, FOOTER_HEIGHT, COLOR_FOOTER_BG);
    drawText(framebuffer, 10, HEIGHT - FOOTER_HEIGHT + 6, "SELECT: Enter", COLOR_TEXT_DIM);
}

fn renderFileBrowser(framebuffer: []u16, ui: *const SimulatorUI) void {
    // Background
    fillRect(framebuffer, 0, 0, WIDTH, HEIGHT, COLOR_BG);

    // Header with current path
    fillRect(framebuffer, 0, 0, WIDTH, HEADER_HEIGHT, COLOR_HEADER_BG);
    const path = if (ui.current_path_len > 0) ui.current_path[0..ui.current_path_len] else "Files";
    drawText(framebuffer, 10, 8, path, COLOR_HEADER_FG);

    // File list
    const visible_items = CONTENT_HEIGHT / ITEM_HEIGHT;
    const start_idx = ui.file_browser_scroll;
    const end_idx = @min(start_idx + visible_items, ui.file_count);

    for (start_idx..end_idx) |i| {
        const entry = &ui.files[i];
        const y = CONTENT_Y + (i - start_idx) * ITEM_HEIGHT;
        const selected = i == ui.file_browser_selection;

        if (selected) {
            fillRect(framebuffer, 0, y, WIDTH, ITEM_HEIGHT, COLOR_SELECTED_BG);
        }

        // Icon
        const icon: []const u8 = if (entry.is_dir) "[D]" else "[>]";
        const text_color = if (selected) COLOR_SELECTED_FG else if (entry.is_dir) COLOR_TEXT else COLOR_ACCENT;
        drawText(framebuffer, 10, y + 6, icon, text_color);

        // Name
        drawText(framebuffer, 40, y + 6, entry.getName(), if (selected) COLOR_SELECTED_FG else COLOR_TEXT);
    }

    // Empty message
    if (ui.file_count == 0) {
        drawTextCentered(framebuffer, HEIGHT / 2, "No audio files", COLOR_TEXT_DIM);
    }

    // Footer
    fillRect(framebuffer, 0, HEIGHT - FOOTER_HEIGHT, WIDTH, FOOTER_HEIGHT, COLOR_FOOTER_BG);
    drawText(framebuffer, 10, HEIGHT - FOOTER_HEIGHT + 6, "MENU: Back  SELECT: Play", COLOR_TEXT_DIM);
}

pub const PlayerInfo = struct {
    title: []const u8 = "Unknown",
    artist: []const u8 = "Unknown Artist",
    position_ms: u64 = 0,
    duration_ms: u64 = 0,
    is_playing: bool = false,
    volume: u8 = 100,
    queue_position: usize = 0,
    queue_total: usize = 0,
    shuffle_enabled: bool = false,
};

fn renderNowPlaying(framebuffer: []u16, info: ?PlayerInfo) void {
    const player = info orelse PlayerInfo{};

    // Background
    fillRect(framebuffer, 0, 0, WIDTH, HEIGHT, COLOR_BG);

    // Header
    fillRect(framebuffer, 0, 0, WIDTH, HEADER_HEIGHT, COLOR_HEADER_BG);
    drawText(framebuffer, 10, 8, "Now Playing", COLOR_HEADER_FG);

    // Queue position in header (right side)
    if (player.queue_total > 1) {
        var queue_buf: [16]u8 = undefined;
        const queue_str = std.fmt.bufPrint(&queue_buf, "{d}/{d}", .{ player.queue_position + 1, player.queue_total }) catch "";
        drawTextRight(framebuffer, WIDTH - 10, 8, queue_str, COLOR_TEXT_DIM);
    }

    // Album art placeholder
    const art_size: usize = 80;
    const art_x = (WIDTH - art_size) / 2;
    const art_y: usize = 40;
    fillRect(framebuffer, art_x, art_y, art_size, art_size, rgb565(50, 50, 70));
    drawMusicNote(framebuffer, art_x + art_size / 2, art_y + art_size / 2);

    // Track info
    drawTextCentered(framebuffer, 130, player.title, COLOR_TEXT);
    drawTextCentered(framebuffer, 145, player.artist, COLOR_TEXT_DIM);

    // Track position text
    if (player.queue_total > 1) {
        var track_buf: [32]u8 = undefined;
        const track_str = std.fmt.bufPrint(&track_buf, "Track {d} of {d}", .{ player.queue_position + 1, player.queue_total }) catch "";
        drawTextCentered(framebuffer, 160, track_str, COLOR_TEXT_DIM);
    }

    // Progress bar
    const bar_y: usize = 180;
    const bar_x: usize = 20;
    const bar_w: usize = WIDTH - 40;
    const bar_h: usize = 6;
    fillRect(framebuffer, bar_x, bar_y, bar_w, bar_h, rgb565(50, 50, 60));

    if (player.duration_ms > 0) {
        const progress = (player.position_ms * bar_w) / player.duration_ms;
        fillRect(framebuffer, bar_x, bar_y, progress, bar_h, COLOR_ACCENT);
    }

    // Time
    var pos_buf: [16]u8 = undefined;
    var dur_buf: [16]u8 = undefined;
    const pos_str = formatTime(player.position_ms, &pos_buf);
    const dur_str = formatTime(player.duration_ms, &dur_buf);
    drawText(framebuffer, bar_x, bar_y + 10, pos_str, COLOR_TEXT_DIM);
    drawTextRight(framebuffer, bar_x + bar_w, bar_y + 10, dur_str, COLOR_TEXT_DIM);

    // Play/Pause indicator with prev/next arrows
    const ctrl_y: usize = 205;

    // Previous arrow (if available)
    if (player.queue_position > 0) {
        drawText(framebuffer, WIDTH / 2 - 50, ctrl_y, "|<", COLOR_TEXT);
    } else {
        drawText(framebuffer, WIDTH / 2 - 50, ctrl_y, "|<", COLOR_TEXT_DIM);
    }

    // Play/Pause
    if (player.is_playing) {
        // Pause bars
        fillRect(framebuffer, WIDTH / 2 - 6, ctrl_y, 4, 10, COLOR_TEXT);
        fillRect(framebuffer, WIDTH / 2 + 2, ctrl_y, 4, 10, COLOR_TEXT);
    } else {
        // Play triangle
        drawPlayTriangle(framebuffer, WIDTH / 2, ctrl_y + 5);
    }

    // Next arrow (if available)
    if (player.queue_position + 1 < player.queue_total) {
        drawText(framebuffer, WIDTH / 2 + 35, ctrl_y, ">|", COLOR_TEXT);
    } else {
        drawText(framebuffer, WIDTH / 2 + 35, ctrl_y, ">|", COLOR_TEXT_DIM);
    }

    // Shuffle indicator (bottom left, before controls)
    if (player.shuffle_enabled) {
        drawText(framebuffer, 10, ctrl_y, "[S]", COLOR_ACCENT);
    } else {
        drawText(framebuffer, 10, ctrl_y, "[S]", COLOR_TEXT_DIM);
    }

    // Footer with controls hint
    fillRect(framebuffer, 0, HEIGHT - FOOTER_HEIGHT, WIDTH, FOOTER_HEIGHT, COLOR_FOOTER_BG);
    const hint = if (player.shuffle_enabled) "<< Prev  Space  Next >>  [Shuffle ON]" else "<< Prev  Space  Next >>  Enter:Shuffle";
    drawText(framebuffer, 10, HEIGHT - FOOTER_HEIGHT + 6, hint, COLOR_TEXT_DIM);
}

// ============================================================
// Drawing Primitives
// ============================================================

fn rgb565(r: u16, g: u16, b: u16) u16 {
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
}

fn fillRect(framebuffer: []u16, x: usize, y: usize, w: usize, h: usize, color: u16) void {
    for (y..@min(y + h, HEIGHT)) |py| {
        for (x..@min(x + w, WIDTH)) |px| {
            framebuffer[py * WIDTH + px] = color;
        }
    }
}

fn drawMusicNote(framebuffer: []u16, cx: usize, cy: usize) void {
    const color = COLOR_TEXT_DIM;

    // Note head
    for (0..8) |dy| {
        for (0..10) |dx| {
            const px = cx - 5 + dx;
            const py = cy + 15 - 4 + dy;
            if (px < WIDTH and py < HEIGHT) {
                framebuffer[py * WIDTH + px] = color;
            }
        }
    }

    // Stem
    for (0..30) |dy| {
        const px = cx + 4;
        const py = cy - 10 + dy;
        if (px < WIDTH and py < HEIGHT) {
            framebuffer[py * WIDTH + px] = color;
            if (px + 1 < WIDTH) framebuffer[py * WIDTH + px + 1] = color;
        }
    }
}

fn drawPlayTriangle(framebuffer: []u16, cx: usize, cy: usize) void {
    for (0..12) |i| {
        const width = 12 - i;
        for (0..width) |j| {
            const px = cx - 6 + j;
            const py = cy - 6 + i;
            if (px < WIDTH and py < HEIGHT) {
                framebuffer[py * WIDTH + px] = COLOR_TEXT;
            }
        }
    }
}

// Simple 5x7 font
const FONT_WIDTH = 5;
const FONT_HEIGHT = 7;

fn drawText(framebuffer: []u16, x: usize, y: usize, text: []const u8, color: u16) void {
    var cx = x;
    for (text) |char| {
        if (cx + FONT_WIDTH >= WIDTH) break;
        drawChar(framebuffer, cx, y, char, color);
        cx += FONT_WIDTH + 1;
    }
}

fn drawTextCentered(framebuffer: []u16, y: usize, text: []const u8, color: u16) void {
    if (text.len == 0) return;
    const char_width: usize = FONT_WIDTH + 1;
    const max_chars: usize = WIDTH / char_width;
    const len: usize = @min(text.len, max_chars);
    const text_width: usize = len *% char_width; // Use wrapping multiply
    const x: usize = if (text_width < WIDTH) (WIDTH -% text_width) / 2 else 0;
    drawText(framebuffer, x, y, text[0..len], color);
}

fn drawTextRight(framebuffer: []u16, x: usize, y: usize, text: []const u8, color: u16) void {
    if (text.len == 0) return;
    const text_width = text.len *% (FONT_WIDTH + 1);
    const start_x = if (x >= text_width) x -% text_width else 0;
    drawText(framebuffer, start_x, y, text, color);
}

fn drawChar(framebuffer: []u16, x: usize, y: usize, char: u8, color: u16) void {
    const patterns = getCharPattern(char);
    for (0..FONT_HEIGHT) |row| {
        for (0..FONT_WIDTH) |col| {
            if ((patterns[row] >> @intCast(FONT_WIDTH - 1 - col)) & 1 == 1) {
                const px = x + col;
                const py = y + row;
                if (px < WIDTH and py < HEIGHT) {
                    framebuffer[py * WIDTH + px] = color;
                }
            }
        }
    }
}

fn getCharPattern(char: u8) [7]u8 {
    return switch (char) {
        'A' => .{ 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
        'B' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E },
        'C' => .{ 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E },
        'D' => .{ 0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C },
        'E' => .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F },
        'F' => .{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10 },
        'G' => .{ 0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E },
        'H' => .{ 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
        'I' => .{ 0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E },
        'J' => .{ 0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C },
        'K' => .{ 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11 },
        'L' => .{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F },
        'M' => .{ 0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11 },
        'N' => .{ 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11 },
        'O' => .{ 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
        'P' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10 },
        'Q' => .{ 0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D },
        'R' => .{ 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11 },
        'S' => .{ 0x0E, 0x11, 0x10, 0x0E, 0x01, 0x11, 0x0E },
        'T' => .{ 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
        'U' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
        'V' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04 },
        'W' => .{ 0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11 },
        'X' => .{ 0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11 },
        'Y' => .{ 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04 },
        'Z' => .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F },
        'a' => .{ 0x00, 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F },
        'b' => .{ 0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x1E },
        'c' => .{ 0x00, 0x00, 0x0E, 0x10, 0x10, 0x10, 0x0E },
        'd' => .{ 0x01, 0x01, 0x0F, 0x11, 0x11, 0x11, 0x0F },
        'e' => .{ 0x00, 0x00, 0x0E, 0x11, 0x1F, 0x10, 0x0E },
        'f' => .{ 0x06, 0x08, 0x1E, 0x08, 0x08, 0x08, 0x08 },
        'g' => .{ 0x00, 0x00, 0x0F, 0x11, 0x0F, 0x01, 0x0E },
        'h' => .{ 0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x11 },
        'i' => .{ 0x04, 0x00, 0x0C, 0x04, 0x04, 0x04, 0x0E },
        'j' => .{ 0x02, 0x00, 0x06, 0x02, 0x02, 0x12, 0x0C },
        'k' => .{ 0x10, 0x10, 0x12, 0x14, 0x18, 0x14, 0x12 },
        'l' => .{ 0x0C, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E },
        'm' => .{ 0x00, 0x00, 0x1A, 0x15, 0x15, 0x11, 0x11 },
        'n' => .{ 0x00, 0x00, 0x16, 0x19, 0x11, 0x11, 0x11 },
        'o' => .{ 0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E },
        'p' => .{ 0x00, 0x00, 0x1E, 0x11, 0x1E, 0x10, 0x10 },
        'q' => .{ 0x00, 0x00, 0x0F, 0x11, 0x0F, 0x01, 0x01 },
        'r' => .{ 0x00, 0x00, 0x16, 0x19, 0x10, 0x10, 0x10 },
        's' => .{ 0x00, 0x00, 0x0F, 0x10, 0x0E, 0x01, 0x1E },
        't' => .{ 0x08, 0x08, 0x1E, 0x08, 0x08, 0x09, 0x06 },
        'u' => .{ 0x00, 0x00, 0x11, 0x11, 0x11, 0x13, 0x0D },
        'v' => .{ 0x00, 0x00, 0x11, 0x11, 0x11, 0x0A, 0x04 },
        'w' => .{ 0x00, 0x00, 0x11, 0x11, 0x15, 0x15, 0x0A },
        'x' => .{ 0x00, 0x00, 0x11, 0x0A, 0x04, 0x0A, 0x11 },
        'y' => .{ 0x00, 0x00, 0x11, 0x11, 0x0F, 0x01, 0x0E },
        'z' => .{ 0x00, 0x00, 0x1F, 0x02, 0x04, 0x08, 0x1F },
        '0' => .{ 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E },
        '1' => .{ 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E },
        '2' => .{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F },
        '3' => .{ 0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E },
        '4' => .{ 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 },
        '5' => .{ 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E },
        '6' => .{ 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E },
        '7' => .{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
        '8' => .{ 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E },
        '9' => .{ 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C },
        ':' => .{ 0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00 },
        '.' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C },
        '-' => .{ 0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00 },
        '_' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F },
        '/' => .{ 0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10 },
        '[' => .{ 0x0E, 0x08, 0x08, 0x08, 0x08, 0x08, 0x0E },
        ']' => .{ 0x0E, 0x02, 0x02, 0x02, 0x02, 0x02, 0x0E },
        '>' => .{ 0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08 },
        ' ' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
        else => .{ 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E }, // Default: 'O'
    };
}

fn formatTime(ms: u64, buf: []u8) []const u8 {
    const secs = ms / 1000;
    const mins = secs / 60;
    const remaining_secs = secs % 60;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ mins, remaining_secs }) catch "0:00";
}
