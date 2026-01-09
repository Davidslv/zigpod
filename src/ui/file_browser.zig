//! File Browser UI
//!
//! Browse files and directories on the storage device.
//! Supports navigation, file selection, and audio file playback.

const std = @import("std");
const ui = @import("ui.zig");
const lcd = @import("../drivers/display/lcd.zig");
const fat32 = @import("../drivers/storage/fat32.zig");
const audio = @import("../audio/audio.zig");

// ============================================================
// Constants
// ============================================================

pub const MAX_PATH_LENGTH: usize = 256;
pub const MAX_VISIBLE_FILES: usize = 10;
pub const MAX_FILENAME_DISPLAY: usize = 30;

// File type icons
pub const ICON_FOLDER = "[D]";
pub const ICON_AUDIO = "[♪]";
pub const ICON_FILE = "[F]";
pub const ICON_PARENT = "[..]";

// ============================================================
// File Entry
// ============================================================

pub const FileEntry = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    is_directory: bool = false,
    is_audio: bool = false,
    size: u32 = 0,

    pub fn getName(self: *const FileEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *FileEntry, name: []const u8) void {
        const len = @min(name.len, self.name.len);
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = @intCast(len);
    }

    pub fn getIcon(self: *const FileEntry) []const u8 {
        if (self.is_directory) return ICON_FOLDER;
        if (self.is_audio) return ICON_AUDIO;
        return ICON_FILE;
    }

    /// Check if filename has an audio extension
    pub fn checkAudioExtension(self: *FileEntry) void {
        const name = self.getName();
        if (name.len < 4) {
            self.is_audio = false;
            return;
        }

        const ext = name[name.len - 4 ..];
        self.is_audio = std.mem.eql(u8, ext, ".wav") or
            std.mem.eql(u8, ext, ".WAV") or
            std.mem.eql(u8, ext, ".mp3") or
            std.mem.eql(u8, ext, ".MP3") or
            std.mem.eql(u8, ext, ".fla") or // FLAC might be truncated
            std.mem.eql(u8, ext, ".FLA");

        // Check for .flac
        if (name.len >= 5) {
            const ext5 = name[name.len - 5 ..];
            if (std.mem.eql(u8, ext5, ".flac") or std.mem.eql(u8, ext5, ".FLAC")) {
                self.is_audio = true;
            }
        }
    }
};

// ============================================================
// File Browser State
// ============================================================

pub const FileBrowser = struct {
    current_path: [MAX_PATH_LENGTH]u8 = [_]u8{0} ** MAX_PATH_LENGTH,
    path_len: usize = 0,
    entries: [128]FileEntry = [_]FileEntry{.{}} ** 128,
    entry_count: usize = 0,
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    is_loading: bool = false,
    error_message: ?[]const u8 = null,

    /// Initialize browser at root
    pub fn init() FileBrowser {
        var browser = FileBrowser{};
        browser.setPath("/");
        return browser;
    }

    /// Set current path
    pub fn setPath(self: *FileBrowser, path: []const u8) void {
        const len = @min(path.len, self.current_path.len - 1);
        @memcpy(self.current_path[0..len], path[0..len]);
        self.current_path[len] = 0;
        self.path_len = len;
    }

    /// Get current path
    pub fn getPath(self: *const FileBrowser) []const u8 {
        return self.current_path[0..self.path_len];
    }

    /// Refresh directory listing
    pub fn refresh(self: *FileBrowser) !void {
        self.is_loading = true;
        self.error_message = null;
        self.entry_count = 0;

        // Add parent directory entry if not at root
        if (self.path_len > 1) {
            var parent_entry = FileEntry{};
            parent_entry.setName("..");
            parent_entry.is_directory = true;
            self.entries[0] = parent_entry;
            self.entry_count = 1;
        }

        // Read directory from FAT32
        if (fat32.isInitialized()) {
            var fat_entries: [127]fat32.DirEntryInfo = undefined;
            const count = fat32.listDirectory(self.getPath(), &fat_entries) catch |err| {
                self.error_message = switch (err) {
                    fat32.FatError.file_not_found => "Directory not found",
                    fat32.FatError.not_a_directory => "Not a directory",
                    fat32.FatError.io_error => "Read error",
                    fat32.FatError.not_initialized => "Storage not ready",
                    else => "Error reading directory",
                };
                self.is_loading = false;
                return;
            };

            // Convert FAT32 entries to FileEntry format
            for (fat_entries[0..count]) |*fat_entry| {
                if (self.entry_count >= self.entries.len) break;

                var entry = FileEntry{};
                entry.setName(fat_entry.getName());
                entry.is_directory = fat_entry.is_directory;
                entry.size = fat_entry.size;

                // Check for audio extension
                if (!entry.is_directory) {
                    entry.checkAudioExtension();
                }

                self.entries[self.entry_count] = entry;
                self.entry_count += 1;
            }
        } else {
            // FAT32 not initialized - show placeholder for testing
            if (self.path_len == 1) {
                var music_entry = FileEntry{};
                music_entry.setName("MUSIC");
                music_entry.is_directory = true;
                self.entries[self.entry_count] = music_entry;
                self.entry_count += 1;

                var podcasts_entry = FileEntry{};
                podcasts_entry.setName("PODCASTS");
                podcasts_entry.is_directory = true;
                self.entries[self.entry_count] = podcasts_entry;
                self.entry_count += 1;
            }
        }

        // Sort entries: directories first, then files alphabetically
        self.sortEntries();

        self.selected_index = 0;
        self.scroll_offset = 0;
        self.is_loading = false;
    }

    /// Sort entries (directories first, then by name)
    fn sortEntries(self: *FileBrowser) void {
        if (self.entry_count <= 1) return;

        // Simple bubble sort (fine for small lists)
        const start: usize = if (self.path_len > 1) 1 else 0; // Skip ".." entry

        var i: usize = start;
        while (i < self.entry_count) : (i += 1) {
            var j = i + 1;
            while (j < self.entry_count) : (j += 1) {
                const a = &self.entries[i];
                const b = &self.entries[j];

                const should_swap = if (a.is_directory != b.is_directory)
                    !a.is_directory // Directories first
                else
                    std.mem.lessThan(u8, b.getName(), a.getName());

                if (should_swap) {
                    const tmp = self.entries[i];
                    self.entries[i] = self.entries[j];
                    self.entries[j] = tmp;
                }
            }
        }
    }

    /// Move selection up
    pub fn selectPrevious(self: *FileBrowser) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
            if (self.selected_index < self.scroll_offset) {
                self.scroll_offset = self.selected_index;
            }
        }
    }

    /// Move selection down
    pub fn selectNext(self: *FileBrowser) void {
        if (self.selected_index + 1 < self.entry_count) {
            self.selected_index += 1;
            if (self.selected_index >= self.scroll_offset + MAX_VISIBLE_FILES) {
                self.scroll_offset = self.selected_index - MAX_VISIBLE_FILES + 1;
            }
        }
    }

    /// Get currently selected entry
    pub fn getSelected(self: *const FileBrowser) ?*const FileEntry {
        if (self.selected_index < self.entry_count) {
            return &self.entries[self.selected_index];
        }
        return null;
    }

    /// Navigate into selected directory or go up
    pub fn enter(self: *FileBrowser) !BrowserAction {
        const selected = self.getSelected() orelse return .none;

        if (std.mem.eql(u8, selected.getName(), "..")) {
            // Go up
            return self.goUp();
        }

        if (selected.is_directory) {
            // Enter directory
            return try self.enterDirectory(selected.getName());
        }

        if (selected.is_audio) {
            return .play_file;
        }

        return .none;
    }

    /// Enter a subdirectory
    fn enterDirectory(self: *FileBrowser, name: []const u8) !BrowserAction {
        // Build new path
        var new_path: [MAX_PATH_LENGTH]u8 = undefined;
        var new_len: usize = 0;

        // Copy current path
        @memcpy(new_path[0..self.path_len], self.current_path[0..self.path_len]);
        new_len = self.path_len;

        // Add separator if needed
        if (new_len > 0 and new_path[new_len - 1] != '/') {
            new_path[new_len] = '/';
            new_len += 1;
        }

        // Add directory name
        @memcpy(new_path[new_len .. new_len + name.len], name);
        new_len += name.len;

        self.setPath(new_path[0..new_len]);
        try self.refresh();
        return .directory_changed;
    }

    /// Go up one directory level
    pub fn goUp(self: *FileBrowser) !BrowserAction {
        if (self.path_len <= 1) return .none;

        // Find last separator
        var i = self.path_len - 1;
        while (i > 0 and self.current_path[i] != '/') : (i -= 1) {}

        if (i == 0) {
            self.setPath("/");
        } else {
            self.path_len = i;
        }

        try self.refresh();
        return .directory_changed;
    }

    /// Get full path for selected file
    pub fn getSelectedPath(self: *const FileBrowser, buffer: []u8) ?[]u8 {
        const selected = self.getSelected() orelse return null;

        const path = self.getPath();
        const name = selected.getName();

        if (path.len + 1 + name.len > buffer.len) return null;

        var pos: usize = 0;
        @memcpy(buffer[0..path.len], path);
        pos = path.len;

        if (pos > 0 and buffer[pos - 1] != '/') {
            buffer[pos] = '/';
            pos += 1;
        }

        @memcpy(buffer[pos .. pos + name.len], name);
        pos += name.len;

        return buffer[0..pos];
    }
};

pub const BrowserAction = enum {
    none,
    directory_changed,
    play_file,
    back,
};

// ============================================================
// Drawing Functions
// ============================================================

/// Draw the file browser screen
pub fn draw(browser: *const FileBrowser) void {
    const theme = ui.getTheme();

    // Clear screen
    lcd.clear(theme.background);

    // Draw header with current path
    drawPathHeader(browser, theme);

    // Draw file list
    drawFileList(browser, theme);

    // Draw footer
    ui.drawFooter("Select: Open  Menu: Back");
}

/// Draw path header
fn drawPathHeader(browser: *const FileBrowser, theme: ui.Theme) void {
    lcd.fillRect(0, 0, ui.SCREEN_HEIGHT, ui.HEADER_HEIGHT, theme.header_bg);

    // Truncate path if too long
    const path = browser.getPath();
    const max_chars = (ui.SCREEN_WIDTH - 20) / ui.CHAR_WIDTH;

    if (path.len <= max_chars) {
        lcd.drawString(10, 8, path, theme.header_fg, theme.header_bg);
    } else {
        // Show "..." prefix
        lcd.drawString(10, 8, "...", theme.header_fg, theme.header_bg);
        const start = path.len - max_chars + 3;
        lcd.drawString(34, 8, path[start..], theme.header_fg, theme.header_bg);
    }

    lcd.drawHLine(0, ui.HEADER_HEIGHT - 1, ui.SCREEN_WIDTH, theme.disabled);
}

/// Draw file list
fn drawFileList(browser: *const FileBrowser, theme: ui.Theme) void {
    if (browser.is_loading) {
        lcd.drawStringCentered(ui.SCREEN_HEIGHT / 2, "Loading...", theme.foreground, null);
        return;
    }

    if (browser.error_message) |msg| {
        lcd.drawStringCentered(ui.SCREEN_HEIGHT / 2, msg, theme.accent, null);
        return;
    }

    if (browser.entry_count == 0) {
        lcd.drawStringCentered(ui.SCREEN_HEIGHT / 2, "Empty directory", theme.disabled, null);
        return;
    }

    const visible_count = @min(browser.entry_count - browser.scroll_offset, MAX_VISIBLE_FILES);

    for (0..visible_count) |i| {
        const entry_index = browser.scroll_offset + i;
        const entry = &browser.entries[entry_index];
        const y = ui.CONTENT_START_Y + @as(u16, @intCast(i)) * ui.MENU_ITEM_HEIGHT;
        const is_selected = entry_index == browser.selected_index;

        drawFileEntry(y, entry, is_selected, theme);
    }

    // Draw scroll indicators
    if (browser.scroll_offset > 0) {
        lcd.drawString(ui.SCREEN_WIDTH - 16, ui.CONTENT_START_Y, "^", theme.accent, null);
    }
    if (browser.scroll_offset + MAX_VISIBLE_FILES < browser.entry_count) {
        lcd.drawString(ui.SCREEN_WIDTH - 16, ui.SCREEN_HEIGHT - ui.FOOTER_HEIGHT - 12, "v", theme.accent, null);
    }
}

/// Draw a single file entry
fn drawFileEntry(y: u16, entry: *const FileEntry, selected: bool, theme: ui.Theme) void {
    const bg = if (selected) theme.selected_bg else theme.background;
    const fg = if (selected) theme.selected_fg else theme.foreground;

    // Background
    lcd.fillRect(0, y, ui.SCREEN_WIDTH, ui.MENU_ITEM_HEIGHT, bg);

    // Icon
    lcd.drawString(4, y + 6, entry.getIcon(), fg, bg);

    // Name (truncated if needed)
    const name = entry.getName();
    const max_name_chars: usize = 32;

    if (name.len <= max_name_chars) {
        lcd.drawString(36, y + 6, name, fg, bg);
    } else {
        // Truncate with "..."
        var truncated: [35]u8 = undefined;
        @memcpy(truncated[0 .. max_name_chars - 3], name[0 .. max_name_chars - 3]);
        truncated[max_name_chars - 3] = '.';
        truncated[max_name_chars - 2] = '.';
        truncated[max_name_chars - 1] = '.';
        lcd.drawString(36, y + 6, truncated[0..max_name_chars], fg, bg);
    }

    // File size for non-directories
    if (!entry.is_directory and entry.size > 0) {
        var size_buf: [16]u8 = undefined;
        const size_str = formatFileSize(entry.size, &size_buf);
        const size_x = ui.SCREEN_WIDTH - @as(u16, @intCast(size_str.len * ui.CHAR_WIDTH + 8));
        lcd.drawString(size_x, y + 6, size_str, if (selected) fg else theme.disabled, bg);
    }
}

/// Format file size for display
fn formatFileSize(bytes: u32, buffer: []u8) []u8 {
    if (bytes >= 1024 * 1024) {
        const mb = bytes / (1024 * 1024);
        return std.fmt.bufPrint(buffer, "{d}MB", .{mb}) catch "";
    } else if (bytes >= 1024) {
        const kb = bytes / 1024;
        return std.fmt.bufPrint(buffer, "{d}KB", .{kb}) catch "";
    } else {
        return std.fmt.bufPrint(buffer, "{d}B", .{bytes}) catch "";
    }
}

// ============================================================
// Input Handling
// ============================================================

/// Handle input for file browser
pub fn handleInput(browser: *FileBrowser, button: u8, wheel_delta: i8) !BrowserAction {
    const clickwheel = @import("../drivers/input/clickwheel.zig");

    // Wheel scrolling
    if (wheel_delta > 0) {
        browser.selectNext();
        return .none;
    } else if (wheel_delta < 0) {
        browser.selectPrevious();
        return .none;
    }

    // Button handling
    if (button & clickwheel.Button.SELECT != 0) {
        return try browser.enter();
    }

    if (button & clickwheel.Button.RIGHT != 0) {
        return try browser.enter();
    }

    if (button & clickwheel.Button.LEFT != 0) {
        return try browser.goUp();
    }

    if (button & clickwheel.Button.MENU != 0) {
        return .back;
    }

    return .none;
}

// ============================================================
// Tests
// ============================================================

test "file entry audio detection" {
    var entry = FileEntry{};

    entry.setName("track.wav");
    entry.checkAudioExtension();
    try std.testing.expect(entry.is_audio);

    entry.setName("track.mp3");
    entry.checkAudioExtension();
    try std.testing.expect(entry.is_audio);

    entry.setName("track.flac");
    entry.checkAudioExtension();
    try std.testing.expect(entry.is_audio);

    entry.setName("document.txt");
    entry.checkAudioExtension();
    try std.testing.expect(!entry.is_audio);
}

test "file entry icons" {
    var dir_entry = FileEntry{};
    dir_entry.is_directory = true;
    try std.testing.expectEqualStrings(ICON_FOLDER, dir_entry.getIcon());

    var audio_entry = FileEntry{};
    audio_entry.is_audio = true;
    try std.testing.expectEqualStrings(ICON_AUDIO, audio_entry.getIcon());

    var file_entry = FileEntry{};
    try std.testing.expectEqualStrings(ICON_FILE, file_entry.getIcon());
}

test "format file size" {
    var buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("512B", formatFileSize(512, &buf));
    try std.testing.expectEqualStrings("1KB", formatFileSize(1024, &buf));
    try std.testing.expectEqualStrings("5MB", formatFileSize(5 * 1024 * 1024, &buf));
}

test "browser navigation" {
    var browser = FileBrowser.init();
    try std.testing.expectEqualStrings("/", browser.getPath());

    browser.selected_index = 0;
    browser.selectNext();
    // No entries yet, should stay at 0
    try std.testing.expectEqual(@as(usize, 0), browser.selected_index);
}
