//! Music Library
//!
//! Manages the music collection, including scanning, indexing, and browsing.
//! Supports organization by artist, album, genre, and playlist.

const std = @import("std");
const audio = @import("../audio/audio.zig");

// ============================================================
// Constants
// ============================================================

pub const MAX_TRACKS: usize = 10000;
pub const MAX_ARTISTS: usize = 1000;
pub const MAX_ALBUMS: usize = 2000;
pub const MAX_PLAYLISTS: usize = 100;

pub const MAX_TITLE_LEN: usize = 64;
pub const MAX_ARTIST_LEN: usize = 48;
pub const MAX_ALBUM_LEN: usize = 48;
pub const MAX_PATH_LEN: usize = 128;

// ============================================================
// Track Info
// ============================================================

pub const Track = struct {
    id: u32 = 0,
    title: [MAX_TITLE_LEN]u8 = [_]u8{0} ** MAX_TITLE_LEN,
    title_len: u8 = 0,
    artist: [MAX_ARTIST_LEN]u8 = [_]u8{0} ** MAX_ARTIST_LEN,
    artist_len: u8 = 0,
    album: [MAX_ALBUM_LEN]u8 = [_]u8{0} ** MAX_ALBUM_LEN,
    album_len: u8 = 0,
    path: [MAX_PATH_LEN]u8 = [_]u8{0} ** MAX_PATH_LEN,
    path_len: u8 = 0,
    track_number: u8 = 0,
    disc_number: u8 = 1,
    year: u16 = 0,
    duration_ms: u32 = 0,
    file_size: u32 = 0,
    format: audio.decoders.DecoderType = .unknown,
    play_count: u16 = 0,
    last_played: u32 = 0, // Unix timestamp

    pub fn getTitle(self: *const Track) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn setTitle(self: *Track, title: []const u8) void {
        const len = @min(title.len, MAX_TITLE_LEN);
        @memcpy(self.title[0..len], title[0..len]);
        self.title_len = @intCast(len);
    }

    pub fn getArtist(self: *const Track) []const u8 {
        return self.artist[0..self.artist_len];
    }

    pub fn setArtist(self: *Track, artist: []const u8) void {
        const len = @min(artist.len, MAX_ARTIST_LEN);
        @memcpy(self.artist[0..len], artist[0..len]);
        self.artist_len = @intCast(len);
    }

    pub fn getAlbum(self: *const Track) []const u8 {
        return self.album[0..self.album_len];
    }

    pub fn setAlbum(self: *Track, album_name: []const u8) void {
        const len = @min(album_name.len, MAX_ALBUM_LEN);
        @memcpy(self.album[0..len], album_name[0..len]);
        self.album_len = @intCast(len);
    }

    pub fn getPath(self: *const Track) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn setPath(self: *Track, file_path: []const u8) void {
        const len = @min(file_path.len, MAX_PATH_LEN);
        @memcpy(self.path[0..len], file_path[0..len]);
        self.path_len = @intCast(len);
    }

    /// Format duration as MM:SS
    pub fn formatDuration(self: *const Track, buffer: []u8) []u8 {
        const secs = self.duration_ms / 1000;
        const mins = secs / 60;
        const remaining_secs = secs % 60;
        return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}", .{ mins, remaining_secs }) catch buffer[0..0];
    }
};

// ============================================================
// Artist
// ============================================================

pub const Artist = struct {
    name: [MAX_ARTIST_LEN]u8 = [_]u8{0} ** MAX_ARTIST_LEN,
    name_len: u8 = 0,
    track_count: u16 = 0,
    album_count: u16 = 0,

    pub fn getName(self: *const Artist) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *Artist, artist_name: []const u8) void {
        const len = @min(artist_name.len, MAX_ARTIST_LEN);
        @memcpy(self.name[0..len], artist_name[0..len]);
        self.name_len = @intCast(len);
    }
};

// ============================================================
// Album
// ============================================================

pub const Album = struct {
    name: [MAX_ALBUM_LEN]u8 = [_]u8{0} ** MAX_ALBUM_LEN,
    name_len: u8 = 0,
    artist: [MAX_ARTIST_LEN]u8 = [_]u8{0} ** MAX_ARTIST_LEN,
    artist_len: u8 = 0,
    year: u16 = 0,
    track_count: u8 = 0,

    pub fn getName(self: *const Album) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *Album, album_name: []const u8) void {
        const len = @min(album_name.len, MAX_ALBUM_LEN);
        @memcpy(self.name[0..len], album_name[0..len]);
        self.name_len = @intCast(len);
    }

    pub fn getArtist(self: *const Album) []const u8 {
        return self.artist[0..self.artist_len];
    }

    pub fn setArtist(self: *Album, artist_name: []const u8) void {
        const len = @min(artist_name.len, MAX_ARTIST_LEN);
        @memcpy(self.artist[0..len], artist_name[0..len]);
        self.artist_len = @intCast(len);
    }
};

// ============================================================
// Playlist
// ============================================================

pub const Playlist = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    track_ids: [500]u32 = [_]u32{0} ** 500,
    track_count: u16 = 0,

    pub fn getName(self: *const Playlist) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *Playlist, playlist_name: []const u8) void {
        const len = @min(playlist_name.len, 64);
        @memcpy(self.name[0..len], playlist_name[0..len]);
        self.name_len = @intCast(len);
    }

    pub fn addTrack(self: *Playlist, track_id: u32) bool {
        if (self.track_count >= self.track_ids.len) return false;
        self.track_ids[self.track_count] = track_id;
        self.track_count += 1;
        return true;
    }

    pub fn removeTrack(self: *Playlist, index: u16) bool {
        if (index >= self.track_count) return false;

        // Shift remaining tracks
        var i = index;
        while (i < self.track_count - 1) : (i += 1) {
            self.track_ids[i] = self.track_ids[i + 1];
        }
        self.track_count -= 1;
        return true;
    }

    pub fn clear(self: *Playlist) void {
        self.track_count = 0;
    }
};

// ============================================================
// Library
// ============================================================

pub const Library = struct {
    tracks: [MAX_TRACKS]Track = [_]Track{.{}} ** MAX_TRACKS,
    track_count: u32 = 0,

    artists: [MAX_ARTISTS]Artist = [_]Artist{.{}} ** MAX_ARTISTS,
    artist_count: u16 = 0,

    albums: [MAX_ALBUMS]Album = [_]Album{.{}} ** MAX_ALBUMS,
    album_count: u16 = 0,

    playlists: [MAX_PLAYLISTS]Playlist = [_]Playlist{.{}} ** MAX_PLAYLISTS,
    playlist_count: u8 = 0,

    is_scanning: bool = false,
    last_scan_time: u32 = 0,

    /// Add a track to the library
    pub fn addTrack(self: *Library, track: Track) ?u32 {
        if (self.track_count >= MAX_TRACKS) return null;

        var new_track = track;
        new_track.id = self.track_count;

        self.tracks[self.track_count] = new_track;
        self.track_count += 1;

        // Update artist and album indexes
        self.updateIndexes(&new_track);

        return new_track.id;
    }

    /// Get track by ID
    pub fn getTrack(self: *const Library, id: u32) ?*const Track {
        if (id >= self.track_count) return null;
        return &self.tracks[id];
    }

    /// Find tracks by artist
    pub fn findTracksByArtist(self: *const Library, artist_name: []const u8, results: []u32) u32 {
        var count: u32 = 0;
        for (self.tracks[0..self.track_count]) |*track| {
            if (std.mem.eql(u8, track.getArtist(), artist_name)) {
                if (count < results.len) {
                    results[count] = track.id;
                    count += 1;
                }
            }
        }
        return count;
    }

    /// Find tracks by album
    pub fn findTracksByAlbum(self: *const Library, album_name: []const u8, results: []u32) u32 {
        var count: u32 = 0;
        for (self.tracks[0..self.track_count]) |*track| {
            if (std.mem.eql(u8, track.getAlbum(), album_name)) {
                if (count < results.len) {
                    results[count] = track.id;
                    count += 1;
                }
            }
        }
        return count;
    }

    /// Update artist and album indexes
    fn updateIndexes(self: *Library, track: *const Track) void {
        // Check if artist exists
        var artist_found = false;
        for (self.artists[0..self.artist_count]) |*artist| {
            if (std.mem.eql(u8, artist.getName(), track.getArtist())) {
                artist.track_count += 1;
                artist_found = true;
                break;
            }
        }

        if (!artist_found and self.artist_count < MAX_ARTISTS) {
            var new_artist = Artist{};
            new_artist.setName(track.getArtist());
            new_artist.track_count = 1;
            self.artists[self.artist_count] = new_artist;
            self.artist_count += 1;
        }

        // Check if album exists
        var album_found = false;
        for (self.albums[0..self.album_count]) |*album| {
            if (std.mem.eql(u8, album.getName(), track.getAlbum()) and
                std.mem.eql(u8, album.getArtist(), track.getArtist()))
            {
                album.track_count += 1;
                album_found = true;
                break;
            }
        }

        if (!album_found and self.album_count < MAX_ALBUMS) {
            var new_album = Album{};
            new_album.setName(track.getAlbum());
            new_album.setArtist(track.getArtist());
            new_album.year = track.year;
            new_album.track_count = 1;
            self.albums[self.album_count] = new_album;
            self.album_count += 1;
        }
    }

    /// Create a new playlist
    pub fn createPlaylist(self: *Library, name: []const u8) ?u8 {
        if (self.playlist_count >= MAX_PLAYLISTS) return null;

        var playlist = Playlist{};
        playlist.setName(name);

        const id = self.playlist_count;
        self.playlists[id] = playlist;
        self.playlist_count += 1;

        return id;
    }

    /// Get playlist by index
    pub fn getPlaylist(self: *Library, index: u8) ?*Playlist {
        if (index >= self.playlist_count) return null;
        return &self.playlists[index];
    }

    /// Get statistics
    pub fn getStats(self: *const Library) LibraryStats {
        var total_duration: u64 = 0;
        var total_size: u64 = 0;

        for (self.tracks[0..self.track_count]) |track| {
            total_duration += track.duration_ms;
            total_size += track.file_size;
        }

        return LibraryStats{
            .track_count = self.track_count,
            .artist_count = self.artist_count,
            .album_count = self.album_count,
            .playlist_count = self.playlist_count,
            .total_duration_ms = total_duration,
            .total_size_bytes = total_size,
        };
    }

    /// Clear all library data
    pub fn clear(self: *Library) void {
        self.track_count = 0;
        self.artist_count = 0;
        self.album_count = 0;
        // Keep playlists
    }
};

pub const LibraryStats = struct {
    track_count: u32,
    artist_count: u16,
    album_count: u16,
    playlist_count: u8,
    total_duration_ms: u64,
    total_size_bytes: u64,

    /// Format total duration as HH:MM:SS
    pub fn formatTotalDuration(self: *const LibraryStats, buffer: []u8) []u8 {
        const secs = self.total_duration_ms / 1000;
        const hours = secs / 3600;
        const mins = (secs % 3600) / 60;
        const remaining_secs = secs % 60;

        return std.fmt.bufPrint(buffer, "{d}:{d:0>2}:{d:0>2}", .{
            hours,
            mins,
            remaining_secs,
        }) catch buffer[0..0];
    }

    /// Format total size as human-readable string
    pub fn formatTotalSize(self: *const LibraryStats, buffer: []u8) []u8 {
        if (self.total_size_bytes >= 1024 * 1024 * 1024) {
            const gb = self.total_size_bytes / (1024 * 1024 * 1024);
            return std.fmt.bufPrint(buffer, "{d} GB", .{gb}) catch buffer[0..0];
        } else if (self.total_size_bytes >= 1024 * 1024) {
            const mb = self.total_size_bytes / (1024 * 1024);
            return std.fmt.bufPrint(buffer, "{d} MB", .{mb}) catch buffer[0..0];
        } else {
            return std.fmt.bufPrint(buffer, "{d} KB", .{self.total_size_bytes / 1024}) catch buffer[0..0];
        }
    }
};

// ============================================================
// Global Library Instance
// ============================================================

var library = Library{};

pub fn getLibrary() *Library {
    return &library;
}

// ============================================================
// Queue (Now Playing Queue)
// ============================================================

pub const Queue = struct {
    track_ids: [1000]u32 = [_]u32{0} ** 1000,
    count: u16 = 0,
    current_index: u16 = 0,
    shuffle_enabled: bool = false,
    repeat_mode: RepeatMode = .off,

    pub const RepeatMode = enum {
        off,
        one,
        all,
    };

    pub fn addTrack(self: *Queue, track_id: u32) bool {
        if (self.count >= self.track_ids.len) return false;
        self.track_ids[self.count] = track_id;
        self.count += 1;
        return true;
    }

    pub fn clear(self: *Queue) void {
        self.count = 0;
        self.current_index = 0;
    }

    pub fn getCurrentTrackId(self: *const Queue) ?u32 {
        if (self.count == 0) return null;
        return self.track_ids[self.current_index];
    }

    pub fn next(self: *Queue) bool {
        if (self.count == 0) return false;

        if (self.repeat_mode == .one) {
            return true; // Stay on same track
        }

        if (self.current_index + 1 < self.count) {
            self.current_index += 1;
            return true;
        } else if (self.repeat_mode == .all) {
            self.current_index = 0;
            return true;
        }

        return false; // End of queue
    }

    pub fn previous(self: *Queue) bool {
        if (self.count == 0) return false;

        if (self.current_index > 0) {
            self.current_index -= 1;
            return true;
        } else if (self.repeat_mode == .all) {
            self.current_index = self.count - 1;
            return true;
        }

        return false;
    }

    pub fn jumpTo(self: *Queue, index: u16) bool {
        if (index >= self.count) return false;
        self.current_index = index;
        return true;
    }
};

var queue = Queue{};

pub fn getQueue() *Queue {
    return &queue;
}

// ============================================================
// Tests
// ============================================================

test "track operations" {
    var track = Track{};

    track.setTitle("Test Song");
    try std.testing.expectEqualStrings("Test Song", track.getTitle());

    track.setArtist("Test Artist");
    try std.testing.expectEqualStrings("Test Artist", track.getArtist());

    track.setAlbum("Test Album");
    try std.testing.expectEqualStrings("Test Album", track.getAlbum());

    track.duration_ms = 185000;
    var buf: [16]u8 = undefined;
    const duration = track.formatDuration(&buf);
    try std.testing.expectEqualStrings("03:05", duration);
}

test "library add track" {
    var lib = Library{};

    var track1 = Track{};
    track1.setTitle("Song 1");
    track1.setArtist("Artist A");
    track1.setAlbum("Album X");

    const id1 = lib.addTrack(track1);
    try std.testing.expect(id1 != null);
    try std.testing.expectEqual(@as(u32, 0), id1.?);
    try std.testing.expectEqual(@as(u32, 1), lib.track_count);
    try std.testing.expectEqual(@as(u16, 1), lib.artist_count);
    try std.testing.expectEqual(@as(u16, 1), lib.album_count);

    var track2 = Track{};
    track2.setTitle("Song 2");
    track2.setArtist("Artist A");
    track2.setAlbum("Album X");

    _ = lib.addTrack(track2);
    try std.testing.expectEqual(@as(u16, 1), lib.artist_count); // Same artist
    try std.testing.expectEqual(@as(u16, 1), lib.album_count); // Same album
}

test "playlist operations" {
    var playlist = Playlist{};
    playlist.setName("My Playlist");

    try std.testing.expectEqualStrings("My Playlist", playlist.getName());

    try std.testing.expect(playlist.addTrack(1));
    try std.testing.expect(playlist.addTrack(2));
    try std.testing.expect(playlist.addTrack(3));
    try std.testing.expectEqual(@as(u16, 3), playlist.track_count);

    try std.testing.expect(playlist.removeTrack(1));
    try std.testing.expectEqual(@as(u16, 2), playlist.track_count);
    try std.testing.expectEqual(@as(u32, 1), playlist.track_ids[0]);
    try std.testing.expectEqual(@as(u32, 3), playlist.track_ids[1]);
}

test "queue navigation" {
    var q = Queue{};

    _ = q.addTrack(10);
    _ = q.addTrack(20);
    _ = q.addTrack(30);

    try std.testing.expectEqual(@as(?u32, 10), q.getCurrentTrackId());

    try std.testing.expect(q.next());
    try std.testing.expectEqual(@as(?u32, 20), q.getCurrentTrackId());

    try std.testing.expect(q.previous());
    try std.testing.expectEqual(@as(?u32, 10), q.getCurrentTrackId());
}

test "library stats" {
    var lib = Library{};

    var track = Track{};
    track.duration_ms = 180000;
    track.file_size = 5 * 1024 * 1024;
    track.setArtist("Artist");
    track.setAlbum("Album");
    _ = lib.addTrack(track);

    const stats = lib.getStats();
    try std.testing.expectEqual(@as(u32, 1), stats.track_count);
    try std.testing.expectEqual(@as(u64, 180000), stats.total_duration_ms);
    try std.testing.expectEqual(@as(u64, 5 * 1024 * 1024), stats.total_size_bytes);
}
