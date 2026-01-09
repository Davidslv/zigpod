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
// Library Scanner
// ============================================================

/// Scan error types
pub const ScanError = error{
    storage_not_ready,
    scan_in_progress,
    io_error,
};

/// Scan the music library starting from the given path
/// Recursively scans directories for audio files and extracts metadata
pub fn scanLibrary(root_path: []const u8) ScanError!void {
    if (!fat32.isInitialized()) {
        global_db.scan_error = "Storage not initialized";
        return ScanError.storage_not_ready;
    }

    // Clear existing database
    global_db.clear();
    global_db.scan_progress = 0;
    global_db.scan_error = null;

    // Scan the directory tree
    scanDirectory(root_path, 0) catch |err| {
        global_db.scan_error = switch (err) {
            fat32.FatError.file_not_found => "Music folder not found",
            fat32.FatError.not_a_directory => "Invalid music path",
            fat32.FatError.io_error => "Storage read error",
            else => "Scan failed",
        };
        return ScanError.io_error;
    };

    global_db.scan_complete = true;
    global_db.scan_progress = 100;
}

/// Recursively scan a directory for audio files
fn scanDirectory(path: []const u8, depth: u8) fat32.FatError!void {
    // Limit recursion depth to prevent stack overflow
    if (depth > 8) return;

    var entries: [64]fat32.DirEntryInfo = undefined;
    const count = try fat32.listDirectory(path, &entries);

    for (entries[0..count]) |*entry| {
        // Build full path
        var full_path: [MAX_PATH_LEN]u8 = undefined;
        const path_len = buildPath(&full_path, path, entry.getName());
        if (path_len == 0) continue;

        if (entry.is_directory) {
            // Skip . and .. directories
            const name = entry.getName();
            if (name.len == 1 and name[0] == '.') continue;
            if (name.len == 2 and name[0] == '.' and name[1] == '.') continue;

            // Recurse into subdirectory
            scanDirectory(full_path[0..path_len], depth + 1) catch continue;
        } else {
            // Check if it's an audio file
            if (isAudioFile(entry.getName())) {
                addAudioFile(full_path[0..path_len], entry.size);

                // Update progress (rough estimate based on track count)
                if (global_db.track_count < MAX_TRACKS) {
                    global_db.scan_progress = @intCast(@min(99, (global_db.track_count * 100) / MAX_TRACKS));
                }
            }
        }
    }
}

/// Build a full path from directory and filename
fn buildPath(buffer: []u8, dir: []const u8, name: []const u8) usize {
    if (dir.len + 1 + name.len >= buffer.len) return 0;

    var pos: usize = 0;

    // Copy directory
    @memcpy(buffer[0..dir.len], dir);
    pos = dir.len;

    // Add separator if needed
    if (pos > 0 and buffer[pos - 1] != '/') {
        buffer[pos] = '/';
        pos += 1;
    }

    // Copy filename
    @memcpy(buffer[pos .. pos + name.len], name);
    pos += name.len;

    return pos;
}

/// Check if a filename has an audio extension
fn isAudioFile(name: []const u8) bool {
    if (name.len < 4) return false;

    // Get extension (last 4 chars including dot)
    const ext = name[name.len - 4 ..];

    // Check common extensions
    if (caseInsensitiveEqual(ext, ".mp3")) return true;
    if (caseInsensitiveEqual(ext, ".wav")) return true;
    if (caseInsensitiveEqual(ext, ".m4a")) return true;
    if (caseInsensitiveEqual(ext, ".aac")) return true;

    // Check 5-char extensions
    if (name.len >= 5) {
        const ext5 = name[name.len - 5 ..];
        if (caseInsensitiveEqual(ext5, ".flac")) return true;
    }

    return false;
}

/// Add an audio file to the database, extracting metadata
fn addAudioFile(path: []const u8, file_size: u32) void {
    if (global_db.track_count >= MAX_TRACKS) return;

    // Default metadata (filename-based)
    var title: []const u8 = extractFilename(path);
    var artist: []const u8 = "Unknown Artist";
    var album: []const u8 = extractParentFolder(path);
    var track_num: u8 = 0;

    // Try to extract ID3 metadata for MP3 files
    if (isMp3File(path)) {
        extractMp3Metadata(path, file_size, &title, &artist, &album, &track_num);
    }

    // Add track to database
    if (global_db.addTrack(path, title, artist, album)) |track| {
        track.track_number = track_num;
    }
}

/// Check if file is an MP3
fn isMp3File(path: []const u8) bool {
    if (path.len < 4) return false;
    const ext = path[path.len - 4 ..];
    return caseInsensitiveEqual(ext, ".mp3");
}

/// Extract filename without extension from path
fn extractFilename(path: []const u8) []const u8 {
    // Find last separator
    var start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/') start = i + 1;
    }

    // Find extension
    var end: usize = path.len;
    var i: usize = path.len;
    while (i > start) : (i -= 1) {
        if (path[i - 1] == '.') {
            end = i - 1;
            break;
        }
    }

    if (end <= start) return path[start..];
    return path[start..end];
}

/// Extract parent folder name from path
fn extractParentFolder(path: []const u8) []const u8 {
    // Find last separator
    var last_sep: usize = 0;
    var second_last_sep: usize = 0;

    for (path, 0..) |c, i| {
        if (c == '/') {
            second_last_sep = last_sep;
            last_sep = i;
        }
    }

    if (last_sep > second_last_sep + 1) {
        return path[second_last_sep + 1 .. last_sep];
    }

    return "Unknown Album";
}

/// Extract metadata from MP3 file using ID3 tags
fn extractMp3Metadata(path: []const u8, file_size: u32, title: *[]const u8, artist: *[]const u8, album: *[]const u8, track_num: *u8) void {
    // Read beginning of file for ID3v2 tags
    const read_size: usize = @min(file_size, 4096);
    var buffer: [4096]u8 = undefined;

    const bytes_read = fat32.readFile(path, buffer[0..read_size]) catch return;
    if (bytes_read < 10) return;

    // Parse ID3 tags
    const metadata = decoders.id3.parse(buffer[0..bytes_read]);

    if (metadata.hasMetadata()) {
        if (metadata.title_len > 0) {
            // Store in static buffers (not ideal but works for scanning)
            const t = metadata.getTitle();
            if (t.len > 0) {
                @memcpy(title_buffer[0..t.len], t);
                title.* = title_buffer[0..t.len];
            }
        }
        if (metadata.artist_len > 0) {
            const a = metadata.getArtist();
            if (a.len > 0) {
                @memcpy(artist_buffer[0..a.len], a);
                artist.* = artist_buffer[0..a.len];
            }
        }
        if (metadata.album_len > 0) {
            const ab = metadata.getAlbum();
            if (ab.len > 0) {
                @memcpy(album_buffer[0..ab.len], ab);
                album.* = album_buffer[0..ab.len];
            }
        }
        track_num.* = metadata.track;
    }
}

// Static buffers for metadata extraction (reused per file)
var title_buffer: [MAX_NAME_LEN]u8 = undefined;
var artist_buffer: [MAX_NAME_LEN]u8 = undefined;
var album_buffer: [MAX_NAME_LEN]u8 = undefined;

/// Start a background scan (non-blocking)
/// Call getScanProgress() to check progress
pub fn startScan(root_path: []const u8) void {
    // For now, do synchronous scan
    // TODO: Implement async scanning with progress callback
    scanLibrary(root_path) catch {};
}

/// Scan default music directories
pub fn scanDefaultPaths() void {
    // Try common music folder locations
    const paths = [_][]const u8{
        "/MUSIC",
        "/Music",
        "/music",
        "/iPod_Control/Music",
    };

    for (paths) |path| {
        if (fat32.isInitialized()) {
            // Try to open directory to see if it exists
            var entries: [1]fat32.DirEntryInfo = undefined;
            if (fat32.listDirectory(path, &entries)) |_| {
                scanLibrary(path) catch continue;
                if (global_db.track_count > 0) return; // Found music
            } else |_| {
                continue;
            }
        }
    }

    // If no music found, mark scan complete anyway
    global_db.scan_complete = true;
    global_db.scan_progress = 100;
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

test "extract filename" {
    try std.testing.expectEqualStrings("song", extractFilename("/MUSIC/album/song.mp3"));
    try std.testing.expectEqualStrings("track01", extractFilename("/track01.wav"));
    try std.testing.expectEqualStrings("My Song", extractFilename("/MUSIC/Artist/Album/My Song.flac"));
}

test "extract parent folder" {
    try std.testing.expectEqualStrings("album", extractParentFolder("/MUSIC/album/song.mp3"));
    try std.testing.expectEqualStrings("Album", extractParentFolder("/MUSIC/Artist/Album/song.mp3"));
    try std.testing.expectEqualStrings("Unknown Album", extractParentFolder("/song.mp3"));
}

test "is audio file" {
    try std.testing.expect(isAudioFile("song.mp3"));
    try std.testing.expect(isAudioFile("TRACK.MP3"));
    try std.testing.expect(isAudioFile("song.wav"));
    try std.testing.expect(isAudioFile("song.WAV"));
    try std.testing.expect(isAudioFile("song.flac"));
    try std.testing.expect(isAudioFile("song.FLAC"));
    try std.testing.expect(isAudioFile("song.m4a"));
    try std.testing.expect(isAudioFile("song.aac"));
    try std.testing.expect(!isAudioFile("song.txt"));
    try std.testing.expect(!isAudioFile("song.jpg"));
    try std.testing.expect(!isAudioFile("readme"));
}

test "build path" {
    var buffer: [256]u8 = undefined;

    var len = buildPath(&buffer, "/MUSIC", "song.mp3");
    try std.testing.expectEqualStrings("/MUSIC/song.mp3", buffer[0..len]);

    len = buildPath(&buffer, "/MUSIC/", "song.mp3");
    try std.testing.expectEqualStrings("/MUSIC/song.mp3", buffer[0..len]);

    len = buildPath(&buffer, "/", "song.mp3");
    try std.testing.expectEqualStrings("/song.mp3", buffer[0..len]);
}
