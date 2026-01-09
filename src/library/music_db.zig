//! Music Library Database
//!
//! In-memory database for storing and querying music metadata.
//! Scans the filesystem to build an index of artists, albums, and tracks.

const std = @import("std");
const fat32 = @import("../drivers/storage/fat32.zig");
const audio = @import("../audio/audio.zig");
const decoders = audio.decoders;

// ============================================================
// Constants
// ============================================================

/// Maximum number of tracks in library
pub const MAX_TRACKS: usize = 1000;

/// Maximum number of artists
pub const MAX_ARTISTS: usize = 200;

/// Maximum number of albums
pub const MAX_ALBUMS: usize = 300;

/// Maximum path length
pub const MAX_PATH_LEN: usize = 256;

/// Maximum name length
pub const MAX_NAME_LEN: usize = 64;

// ============================================================
// Track Entry
// ============================================================

pub const Track = struct {
    // Path to the file
    path: [MAX_PATH_LEN]u8 = [_]u8{0} ** MAX_PATH_LEN,
    path_len: u16 = 0,

    // Metadata
    title: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    title_len: u8 = 0,
    artist_idx: u16 = 0, // Index into artists array
    album_idx: u16 = 0, // Index into albums array
    track_number: u8 = 0,
    duration_ms: u32 = 0,

    // Status
    valid: bool = false,

    pub fn getPath(self: *const Track) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn getTitle(self: *const Track) []const u8 {
        if (self.title_len > 0) return self.title[0..self.title_len];
        // Fall back to filename
        const path = self.getPath();
        var i: usize = self.path_len;
        while (i > 0) : (i -= 1) {
            if (path[i - 1] == '/') break;
        }
        const filename = path[i..self.path_len];
        // Strip extension
        var end = filename.len;
        var j: usize = filename.len;
        while (j > 0) : (j -= 1) {
            if (filename[j - 1] == '.') {
                end = j - 1;
                break;
            }
        }
        return filename[0..end];
    }

    pub fn setPath(self: *Track, path: []const u8) void {
        const len = @min(path.len, self.path.len);
        @memcpy(self.path[0..len], path[0..len]);
        self.path_len = @intCast(len);
    }

    pub fn setTitle(self: *Track, title: []const u8) void {
        const len = @min(title.len, self.title.len);
        @memcpy(self.title[0..len], title[0..len]);
        self.title_len = @intCast(len);
    }
};

// ============================================================
// Artist Entry
// ============================================================

pub const Artist = struct {
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: u8 = 0,
    track_count: u16 = 0,
    album_count: u16 = 0,
    valid: bool = false,

    pub fn getName(self: *const Artist) []const u8 {
        if (self.name_len > 0) return self.name[0..self.name_len];
        return "Unknown Artist";
    }

    pub fn setName(self: *Artist, name: []const u8) void {
        const len = @min(name.len, self.name.len);
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = @intCast(len);
        self.valid = true;
    }
};

// ============================================================
// Album Entry
// ============================================================

pub const Album = struct {
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: u8 = 0,
    artist_idx: u16 = 0,
    track_count: u16 = 0,
    year: u16 = 0,
    valid: bool = false,

    pub fn getName(self: *const Album) []const u8 {
        if (self.name_len > 0) return self.name[0..self.name_len];
        return "Unknown Album";
    }

    pub fn setName(self: *Album, name: []const u8) void {
        const len = @min(name.len, self.name.len);
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = @intCast(len);
        self.valid = true;
    }
};

// ============================================================
// Music Database
// ============================================================

pub const MusicDb = struct {
    tracks: [MAX_TRACKS]Track = [_]Track{.{}} ** MAX_TRACKS,
    track_count: usize = 0,

    artists: [MAX_ARTISTS]Artist = [_]Artist{.{}} ** MAX_ARTISTS,
    artist_count: usize = 0,

    albums: [MAX_ALBUMS]Album = [_]Album{.{}} ** MAX_ALBUMS,
    album_count: usize = 0,

    // Scan state
    scan_complete: bool = false,
    scan_progress: u8 = 0,
    scan_error: ?[]const u8 = null,

    /// Initialize a new database
    pub fn init() MusicDb {
        return MusicDb{};
    }

    /// Clear the database
    pub fn clear(self: *MusicDb) void {
        self.track_count = 0;
        self.artist_count = 0;
        self.album_count = 0;
        self.scan_complete = false;
        self.scan_progress = 0;
        self.scan_error = null;

        // Clear arrays
        for (&self.tracks) |*t| t.* = Track{};
        for (&self.artists) |*a| a.* = Artist{};
        for (&self.albums) |*a| a.* = Album{};
    }

    /// Get track count
    pub fn getTrackCount(self: *const MusicDb) usize {
        return self.track_count;
    }

    /// Get artist count
    pub fn getArtistCount(self: *const MusicDb) usize {
        return self.artist_count;
    }

    /// Get album count
    pub fn getAlbumCount(self: *const MusicDb) usize {
        return self.album_count;
    }

    /// Get track by index
    pub fn getTrack(self: *const MusicDb, index: usize) ?*const Track {
        if (index < self.track_count and self.tracks[index].valid) {
            return &self.tracks[index];
        }
        return null;
    }

    /// Get artist by index
    pub fn getArtist(self: *const MusicDb, index: usize) ?*const Artist {
        if (index < self.artist_count and self.artists[index].valid) {
            return &self.artists[index];
        }
        return null;
    }

    /// Get album by index
    pub fn getAlbum(self: *const MusicDb, index: usize) ?*const Album {
        if (index < self.album_count and self.albums[index].valid) {
            return &self.albums[index];
        }
        return null;
    }

    /// Find or create artist by name
    pub fn findOrCreateArtist(self: *MusicDb, name: []const u8) ?u16 {
        // Search for existing artist
        for (self.artists[0..self.artist_count], 0..) |*artist, i| {
            if (artist.valid and caseInsensitiveEqual(artist.getName(), name)) {
                return @intCast(i);
            }
        }

        // Create new artist
        if (self.artist_count >= MAX_ARTISTS) return null;
        const idx = self.artist_count;
        self.artists[idx].setName(name);
        self.artist_count += 1;
        return @intCast(idx);
    }

    /// Find or create album by name and artist
    pub fn findOrCreateAlbum(self: *MusicDb, name: []const u8, artist_idx: u16) ?u16 {
        // Search for existing album with same artist
        for (self.albums[0..self.album_count], 0..) |*album, i| {
            if (album.valid and album.artist_idx == artist_idx and
                caseInsensitiveEqual(album.getName(), name))
            {
                return @intCast(i);
            }
        }

        // Create new album
        if (self.album_count >= MAX_ALBUMS) return null;
        const idx = self.album_count;
        self.albums[idx].setName(name);
        self.albums[idx].artist_idx = artist_idx;
        self.album_count += 1;

        // Update artist album count
        if (artist_idx < self.artist_count) {
            self.artists[artist_idx].album_count += 1;
        }

        return @intCast(idx);
    }

    /// Add a track to the database
    pub fn addTrack(self: *MusicDb, path: []const u8, title: []const u8, artist_name: []const u8, album_name: []const u8) ?*Track {
        if (self.track_count >= MAX_TRACKS) return null;

        // Find or create artist and album
        const artist_idx = self.findOrCreateArtist(artist_name) orelse 0;
        const album_idx = self.findOrCreateAlbum(album_name, artist_idx) orelse 0;

        // Create track
        const idx = self.track_count;
        var track = &self.tracks[idx];
        track.setPath(path);
        track.setTitle(title);
        track.artist_idx = artist_idx;
        track.album_idx = album_idx;
        track.valid = true;

        self.track_count += 1;

        // Update counts
        if (artist_idx < self.artist_count) {
            self.artists[artist_idx].track_count += 1;
        }
        if (album_idx < self.album_count) {
            self.albums[album_idx].track_count += 1;
        }

        return track;
    }

    /// Get all tracks by artist index
    pub fn getTracksByArtist(self: *const MusicDb, artist_idx: u16, output: []?*const Track) usize {
        var count: usize = 0;
        for (self.tracks[0..self.track_count]) |*track| {
            if (track.valid and track.artist_idx == artist_idx) {
                if (count < output.len) {
                    output[count] = track;
                    count += 1;
                }
            }
        }
        return count;
    }

    /// Get all tracks by album index
    pub fn getTracksByAlbum(self: *const MusicDb, album_idx: u16, output: []?*const Track) usize {
        var count: usize = 0;
        for (self.tracks[0..self.track_count]) |*track| {
            if (track.valid and track.album_idx == album_idx) {
                if (count < output.len) {
                    output[count] = track;
                    count += 1;
                }
            }
        }
        return count;
    }

    /// Get all albums by artist index
    pub fn getAlbumsByArtist(self: *const MusicDb, artist_idx: u16, output: []?*const Album) usize {
        var count: usize = 0;
        for (self.albums[0..self.album_count]) |*album| {
            if (album.valid and album.artist_idx == artist_idx) {
                if (count < output.len) {
                    output[count] = album;
                    count += 1;
                }
            }
        }
        return count;
    }
};

// ============================================================
// Global Database
// ============================================================

var global_db: MusicDb = MusicDb{};

/// Get the global music database
pub fn getDb() *MusicDb {
    return &global_db;
}

/// Check if database is ready
pub fn isReady() bool {
    return global_db.scan_complete;
}

/// Get scan progress (0-100)
pub fn getScanProgress() u8 {
    return global_db.scan_progress;
}

// ============================================================
// Utility Functions
// ============================================================

/// Case-insensitive string comparison
fn caseInsensitiveEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

// ============================================================
// Tests
// ============================================================

test "music db basic operations" {
    var db = MusicDb.init();

    // Add a track
    const track = db.addTrack("/MUSIC/song.wav", "My Song", "Artist", "Album");
    try std.testing.expect(track != null);
    try std.testing.expectEqual(@as(usize, 1), db.getTrackCount());
    try std.testing.expectEqual(@as(usize, 1), db.getArtistCount());
    try std.testing.expectEqual(@as(usize, 1), db.getAlbumCount());
}

test "music db find or create artist" {
    var db = MusicDb.init();

    // Create first artist
    const idx1 = db.findOrCreateArtist("Test Artist");
    try std.testing.expect(idx1 != null);
    try std.testing.expectEqual(@as(usize, 1), db.getArtistCount());

    // Find existing artist
    const idx2 = db.findOrCreateArtist("Test Artist");
    try std.testing.expect(idx2 != null);
    try std.testing.expectEqual(idx1.?, idx2.?);
    try std.testing.expectEqual(@as(usize, 1), db.getArtistCount());

    // Create new artist
    const idx3 = db.findOrCreateArtist("Another Artist");
    try std.testing.expect(idx3 != null);
    try std.testing.expect(idx3.? != idx1.?);
    try std.testing.expectEqual(@as(usize, 2), db.getArtistCount());
}

test "music db case insensitive" {
    var db = MusicDb.init();

    const idx1 = db.findOrCreateArtist("The Beatles");
    const idx2 = db.findOrCreateArtist("THE BEATLES");
    const idx3 = db.findOrCreateArtist("the beatles");

    try std.testing.expectEqual(idx1.?, idx2.?);
    try std.testing.expectEqual(idx1.?, idx3.?);
    try std.testing.expectEqual(@as(usize, 1), db.getArtistCount());
}

test "music db clear" {
    var db = MusicDb.init();

    _ = db.addTrack("/a.wav", "A", "Art", "Alb");
    _ = db.addTrack("/b.wav", "B", "Art", "Alb");
    try std.testing.expectEqual(@as(usize, 2), db.getTrackCount());

    db.clear();
    try std.testing.expectEqual(@as(usize, 0), db.getTrackCount());
    try std.testing.expectEqual(@as(usize, 0), db.getArtistCount());
    try std.testing.expectEqual(@as(usize, 0), db.getAlbumCount());
}

test "track get title fallback" {
    var track = Track{};
    track.setPath("/MUSIC/My_Song.wav");

    // Without explicit title, should return filename without extension
    try std.testing.expectEqualStrings("My_Song", track.getTitle());

    // With explicit title
    track.setTitle("My Song");
    try std.testing.expectEqualStrings("My Song", track.getTitle());
}
