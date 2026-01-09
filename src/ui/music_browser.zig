//! Music Browser UI
//!
//! Browse music library by Artists, Albums, and Songs.
//! Provides navigation through the music database.

const std = @import("std");
const ui = @import("ui.zig");
const lcd = @import("../drivers/display/lcd.zig");
const music_db = @import("../library/music_db.zig");
const audio = @import("../audio/audio.zig");
const clickwheel = @import("../drivers/input/clickwheel.zig");

// ============================================================
// Constants
// ============================================================

pub const MAX_VISIBLE_ITEMS: usize = 8;

// ============================================================
// Browse Mode
// ============================================================

pub const BrowseMode = enum {
    library_menu, // Main music menu (Artists, Albums, Songs, etc.)
    artists, // List of all artists
    albums, // List of all albums (or filtered by artist)
    songs, // List of all songs (or filtered by album)
    artist_albums, // Albums by specific artist
    album_songs, // Songs in specific album
};

// ============================================================
// Music Browser State
// ============================================================

pub const MusicBrowser = struct {
    mode: BrowseMode = .library_menu,
    selected_index: usize = 0,
    scroll_offset: usize = 0,

    // Filter context
    filter_artist_idx: ?u16 = null,
    filter_album_idx: ?u16 = null,

    // Cached counts for current view
    item_count: usize = 0,

    /// Initialize browser
    pub fn init() MusicBrowser {
        var browser = MusicBrowser{};
        browser.updateItemCount();
        return browser;
    }

    /// Update item count for current mode
    pub fn updateItemCount(self: *MusicBrowser) void {
        const db = music_db.getDb();
        self.item_count = switch (self.mode) {
            .library_menu => 5, // Artists, Albums, Songs, Shuffle All, separator
            .artists => db.getArtistCount(),
            .albums => db.getAlbumCount(),
            .songs => db.getTrackCount(),
            .artist_albums => blk: {
                if (self.filter_artist_idx) |idx| {
                    var count: usize = 0;
                    for (db.albums[0..db.album_count]) |album| {
                        if (album.valid and album.artist_idx == idx) count += 1;
                    }
                    break :blk count;
                }
                break :blk 0;
            },
            .album_songs => blk: {
                if (self.filter_album_idx) |idx| {
                    var count: usize = 0;
                    for (db.tracks[0..db.track_count]) |track| {
                        if (track.valid and track.album_idx == idx) count += 1;
                    }
                    break :blk count;
                }
                break :blk 0;
            },
        };
    }

    /// Move selection up
    pub fn selectPrevious(self: *MusicBrowser) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
            if (self.selected_index < self.scroll_offset) {
                self.scroll_offset = self.selected_index;
            }
        }
    }

    /// Move selection down
    pub fn selectNext(self: *MusicBrowser) void {
        if (self.selected_index + 1 < self.item_count) {
            self.selected_index += 1;
            if (self.selected_index >= self.scroll_offset + MAX_VISIBLE_ITEMS) {
                self.scroll_offset = self.selected_index - MAX_VISIBLE_ITEMS + 1;
            }
        }
    }

    /// Go back to previous level
    pub fn goBack(self: *MusicBrowser) BrowserAction {
        switch (self.mode) {
            .library_menu => return .exit_browser,
            .artists, .albums, .songs => {
                self.mode = .library_menu;
                self.selected_index = 0;
                self.scroll_offset = 0;
                self.filter_artist_idx = null;
                self.filter_album_idx = null;
                self.updateItemCount();
                return .none;
            },
            .artist_albums => {
                self.mode = .artists;
                self.selected_index = 0;
                self.scroll_offset = 0;
                self.filter_artist_idx = null;
                self.updateItemCount();
                return .none;
            },
            .album_songs => {
                if (self.filter_artist_idx != null) {
                    self.mode = .artist_albums;
                } else {
                    self.mode = .albums;
                }
                self.selected_index = 0;
                self.scroll_offset = 0;
                self.filter_album_idx = null;
                self.updateItemCount();
                return .none;
            },
        }
    }

    /// Handle selection
    pub fn select(self: *MusicBrowser) BrowserAction {
        switch (self.mode) {
            .library_menu => return self.handleLibraryMenuSelect(),
            .artists => return self.handleArtistSelect(),
            .albums => return self.handleAlbumSelect(),
            .songs => return self.handleSongSelect(),
            .artist_albums => return self.handleAlbumSelect(),
            .album_songs => return self.handleSongSelect(),
        }
    }

    fn handleLibraryMenuSelect(self: *MusicBrowser) BrowserAction {
        switch (self.selected_index) {
            0 => { // Artists
                self.mode = .artists;
                self.selected_index = 0;
                self.scroll_offset = 0;
                self.updateItemCount();
            },
            1 => { // Albums
                self.mode = .albums;
                self.selected_index = 0;
                self.scroll_offset = 0;
                self.updateItemCount();
            },
            2 => { // Songs
                self.mode = .songs;
                self.selected_index = 0;
                self.scroll_offset = 0;
                self.updateItemCount();
            },
            3 => { // Shuffle All
                return .shuffle_all;
            },
            else => {},
        }
        return .none;
    }

    fn handleArtistSelect(self: *MusicBrowser) BrowserAction {
        const db = music_db.getDb();
        if (self.selected_index < db.getArtistCount()) {
            self.filter_artist_idx = @intCast(self.selected_index);
            self.mode = .artist_albums;
            self.selected_index = 0;
            self.scroll_offset = 0;
            self.updateItemCount();
        }
        return .none;
    }

    fn handleAlbumSelect(self: *MusicBrowser) BrowserAction {
        const db = music_db.getDb();

        // Get the actual album index
        var album_idx: ?u16 = null;
        if (self.filter_artist_idx) |artist_idx| {
            // Filtered by artist - find nth album by this artist
            var count: usize = 0;
            for (db.albums[0..db.album_count], 0..) |album, i| {
                if (album.valid and album.artist_idx == artist_idx) {
                    if (count == self.selected_index) {
                        album_idx = @intCast(i);
                        break;
                    }
                    count += 1;
                }
            }
        } else {
            // All albums
            if (self.selected_index < db.getAlbumCount()) {
                album_idx = @intCast(self.selected_index);
            }
        }

        if (album_idx) |idx| {
            self.filter_album_idx = idx;
            self.mode = .album_songs;
            self.selected_index = 0;
            self.scroll_offset = 0;
            self.updateItemCount();
        }
        return .none;
    }

    fn handleSongSelect(self: *MusicBrowser) BrowserAction {
        const db = music_db.getDb();

        // Find the actual track
        var track_idx: ?usize = null;
        if (self.filter_album_idx) |album_idx| {
            // Filtered by album
            var count: usize = 0;
            for (db.tracks[0..db.track_count], 0..) |track, i| {
                if (track.valid and track.album_idx == album_idx) {
                    if (count == self.selected_index) {
                        track_idx = i;
                        break;
                    }
                    count += 1;
                }
            }
        } else {
            // All songs
            if (self.selected_index < db.getTrackCount()) {
                track_idx = self.selected_index;
            }
        }

        if (track_idx) |idx| {
            if (db.getTrack(idx)) |track| {
                // Try to play the track
                audio.loadFile(track.getPath()) catch {
                    return .play_error;
                };
                return .play_track;
            }
        }
        return .none;
    }

    /// Get current header title
    pub fn getTitle(self: *const MusicBrowser) []const u8 {
        const db = music_db.getDb();
        return switch (self.mode) {
            .library_menu => "Music",
            .artists => "Artists",
            .albums => "Albums",
            .songs => "Songs",
            .artist_albums => blk: {
                if (self.filter_artist_idx) |idx| {
                    if (db.getArtist(idx)) |artist| {
                        break :blk artist.getName();
                    }
                }
                break :blk "Albums";
            },
            .album_songs => blk: {
                if (self.filter_album_idx) |idx| {
                    if (db.getAlbum(idx)) |album| {
                        break :blk album.getName();
                    }
                }
                break :blk "Songs";
            },
        };
    }
};

pub const BrowserAction = enum {
    none,
    exit_browser,
    play_track,
    play_error,
    shuffle_all,
};

// ============================================================
// Drawing Functions
// ============================================================

/// Draw the music browser screen
pub fn draw(browser: *const MusicBrowser) void {
    const theme = ui.getTheme();
    lcd.clear(theme.background);

    // Draw header
    ui.drawHeader(browser.getTitle());

    // Draw content based on mode
    switch (browser.mode) {
        .library_menu => drawLibraryMenu(browser, theme),
        .artists => drawArtistList(browser, theme),
        .albums, .artist_albums => drawAlbumList(browser, theme),
        .songs, .album_songs => drawSongList(browser, theme),
    }

    // Draw footer
    drawFooter(browser, theme);
}

fn drawLibraryMenu(browser: *const MusicBrowser, theme: ui.Theme) void {
    const db = music_db.getDb();

    const items = [_][]const u8{
        "Artists",
        "Albums",
        "Songs",
        "Shuffle All",
    };

    const counts = [_]usize{
        db.getArtistCount(),
        db.getAlbumCount(),
        db.getTrackCount(),
        0, // No count for shuffle
    };

    for (items, 0..) |item, i| {
        const y = ui.CONTENT_START_Y + @as(u16, @intCast(i)) * ui.MENU_ITEM_HEIGHT;
        const selected = i == browser.selected_index;
        const bg = if (selected) theme.selected_bg else theme.background;
        const fg = if (selected) theme.selected_fg else theme.foreground;

        lcd.fillRect(0, y, ui.SCREEN_WIDTH, ui.MENU_ITEM_HEIGHT, bg);

        // Item icon
        const icon: []const u8 = if (selected) ">" else " ";
        lcd.drawString(4, y + 6, icon, fg, bg);

        // Item label
        lcd.drawString(16, y + 6, item, fg, bg);

        // Count (except for shuffle)
        if (counts[i] > 0) {
            var buf: [16]u8 = undefined;
            const count_str = std.fmt.bufPrint(&buf, "({d})", .{counts[i]}) catch "";
            const count_x = ui.SCREEN_WIDTH - @as(u16, @intCast(count_str.len * ui.CHAR_WIDTH + 8));
            lcd.drawString(count_x, y + 6, count_str, if (selected) fg else theme.disabled, bg);
        }
    }
}

fn drawArtistList(browser: *const MusicBrowser, theme: ui.Theme) void {
    const db = music_db.getDb();

    if (db.getArtistCount() == 0) {
        lcd.drawStringCentered(ui.SCREEN_HEIGHT / 2, "No artists found", theme.disabled, null);
        return;
    }

    const visible_count = @min(browser.item_count - browser.scroll_offset, MAX_VISIBLE_ITEMS);

    for (0..visible_count) |i| {
        const idx = browser.scroll_offset + i;
        if (db.getArtist(idx)) |artist| {
            const y = ui.CONTENT_START_Y + @as(u16, @intCast(i)) * ui.MENU_ITEM_HEIGHT;
            const selected = idx == browser.selected_index;
            drawListItem(y, artist.getName(), artist.track_count, selected, theme);
        }
    }

    drawScrollIndicators(browser, theme);
}

fn drawAlbumList(browser: *const MusicBrowser, theme: ui.Theme) void {
    const db = music_db.getDb();

    if (browser.item_count == 0) {
        lcd.drawStringCentered(ui.SCREEN_HEIGHT / 2, "No albums found", theme.disabled, null);
        return;
    }

    const visible_count = @min(browser.item_count - browser.scroll_offset, MAX_VISIBLE_ITEMS);

    // Get albums (filtered or all)
    var display_idx: usize = 0;
    var album_idx: usize = 0;
    for (db.albums[0..db.album_count]) |album| {
        if (!album.valid) continue;

        // Filter by artist if set
        if (browser.filter_artist_idx) |artist_idx| {
            if (album.artist_idx != artist_idx) continue;
        }

        if (album_idx >= browser.scroll_offset and display_idx < visible_count) {
            const y = ui.CONTENT_START_Y + @as(u16, @intCast(display_idx)) * ui.MENU_ITEM_HEIGHT;
            const selected = album_idx == browser.selected_index;
            drawListItem(y, album.getName(), album.track_count, selected, theme);
            display_idx += 1;
        }
        album_idx += 1;
    }

    drawScrollIndicators(browser, theme);
}

fn drawSongList(browser: *const MusicBrowser, theme: ui.Theme) void {
    const db = music_db.getDb();

    if (browser.item_count == 0) {
        lcd.drawStringCentered(ui.SCREEN_HEIGHT / 2, "No songs found", theme.disabled, null);
        return;
    }

    const visible_count = @min(browser.item_count - browser.scroll_offset, MAX_VISIBLE_ITEMS);

    // Get tracks (filtered or all)
    var display_idx: usize = 0;
    var track_idx: usize = 0;
    for (db.tracks[0..db.track_count]) |track| {
        if (!track.valid) continue;

        // Filter by album if set
        if (browser.filter_album_idx) |album_idx| {
            if (track.album_idx != album_idx) continue;
        }

        if (track_idx >= browser.scroll_offset and display_idx < visible_count) {
            const y = ui.CONTENT_START_Y + @as(u16, @intCast(display_idx)) * ui.MENU_ITEM_HEIGHT;
            const selected = track_idx == browser.selected_index;

            // For songs, show track number instead of count
            drawSongItem(y, track.getTitle(), track.track_number, selected, theme);
            display_idx += 1;
        }
        track_idx += 1;
    }

    drawScrollIndicators(browser, theme);
}

fn drawListItem(y: u16, label: []const u8, count: u16, selected: bool, theme: ui.Theme) void {
    const bg = if (selected) theme.selected_bg else theme.background;
    const fg = if (selected) theme.selected_fg else theme.foreground;

    lcd.fillRect(0, y, ui.SCREEN_WIDTH, ui.MENU_ITEM_HEIGHT, bg);

    // Selection indicator
    const icon: []const u8 = if (selected) ">" else " ";
    lcd.drawString(4, y + 6, icon, fg, bg);

    // Truncate label if needed
    const max_chars: usize = 28;
    if (label.len <= max_chars) {
        lcd.drawString(16, y + 6, label, fg, bg);
    } else {
        var buf: [32]u8 = undefined;
        @memcpy(buf[0 .. max_chars - 3], label[0 .. max_chars - 3]);
        buf[max_chars - 3] = '.';
        buf[max_chars - 2] = '.';
        buf[max_chars - 1] = '.';
        lcd.drawString(16, y + 6, buf[0..max_chars], fg, bg);
    }

    // Count or > indicator
    if (count > 0) {
        var buf: [8]u8 = undefined;
        const count_str = std.fmt.bufPrint(&buf, "{d}", .{count}) catch "";
        const count_x = ui.SCREEN_WIDTH - @as(u16, @intCast(count_str.len * ui.CHAR_WIDTH + 16));
        lcd.drawString(count_x, y + 6, count_str, theme.disabled, bg);
    }
    lcd.drawString(ui.SCREEN_WIDTH - 12, y + 6, ">", theme.disabled, bg);
}

fn drawSongItem(y: u16, title: []const u8, track_num: u8, selected: bool, theme: ui.Theme) void {
    const bg = if (selected) theme.selected_bg else theme.background;
    const fg = if (selected) theme.selected_fg else theme.foreground;

    lcd.fillRect(0, y, ui.SCREEN_WIDTH, ui.MENU_ITEM_HEIGHT, bg);

    // Track number
    if (track_num > 0) {
        var buf: [4]u8 = undefined;
        const num_str = std.fmt.bufPrint(&buf, "{d:2}", .{track_num}) catch "";
        lcd.drawString(4, y + 6, num_str, theme.disabled, bg);
    }

    // Title
    const title_x: u16 = if (track_num > 0) 28 else 16;
    const max_chars: usize = 30;
    if (title.len <= max_chars) {
        lcd.drawString(title_x, y + 6, title, fg, bg);
    } else {
        var buf: [34]u8 = undefined;
        @memcpy(buf[0 .. max_chars - 3], title[0 .. max_chars - 3]);
        buf[max_chars - 3] = '.';
        buf[max_chars - 2] = '.';
        buf[max_chars - 1] = '.';
        lcd.drawString(title_x, y + 6, buf[0..max_chars], fg, bg);
    }
}

fn drawScrollIndicators(browser: *const MusicBrowser, theme: ui.Theme) void {
    if (browser.scroll_offset > 0) {
        lcd.drawString(ui.SCREEN_WIDTH - 16, ui.CONTENT_START_Y, "^", theme.accent, null);
    }
    if (browser.scroll_offset + MAX_VISIBLE_ITEMS < browser.item_count) {
        lcd.drawString(ui.SCREEN_WIDTH - 16, ui.SCREEN_HEIGHT - ui.FOOTER_HEIGHT - 12, "v", theme.accent, null);
    }
}

fn drawFooter(browser: *const MusicBrowser, theme: ui.Theme) void {
    _ = browser;
    ui.drawFooter("Select: Enter  Menu: Back");
    _ = theme;
}

// ============================================================
// Input Handling
// ============================================================

/// Handle input for music browser
pub fn handleInput(browser: *MusicBrowser, buttons: u8, wheel_delta: i8) BrowserAction {
    // Wheel scrolling
    if (wheel_delta > 0) {
        browser.selectNext();
        return .none;
    } else if (wheel_delta < 0) {
        browser.selectPrevious();
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

// ============================================================
// Tests
// ============================================================

test "music browser init" {
    const browser = MusicBrowser.init();
    try std.testing.expectEqual(BrowseMode.library_menu, browser.mode);
    try std.testing.expectEqual(@as(usize, 0), browser.selected_index);
}

test "music browser navigation" {
    var browser = MusicBrowser.init();

    browser.selectNext();
    try std.testing.expectEqual(@as(usize, 1), browser.selected_index);

    browser.selectPrevious();
    try std.testing.expectEqual(@as(usize, 0), browser.selected_index);

    // Can't go below 0
    browser.selectPrevious();
    try std.testing.expectEqual(@as(usize, 0), browser.selected_index);
}
