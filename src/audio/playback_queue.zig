//! Playback Queue
//!
//! Manages the list of tracks to play, supporting next/previous navigation.
//! The queue is populated based on playback context (album, artist, all songs, etc.)

const std = @import("std");
const music_db = @import("../library/music_db.zig");

// ============================================================
// Constants
// ============================================================

/// Maximum tracks in the queue
pub const MAX_QUEUE_SIZE: usize = 256;

// ============================================================
// Queue Source
// ============================================================

/// Where the queue was populated from
pub const QueueSource = enum {
    none, // Empty/cleared queue
    single_file, // Single file from file browser
    album, // All tracks from an album
    artist, // All tracks from an artist
    all_songs, // All songs in library
    custom, // Manual/playlist queue
};

// ============================================================
// Playback Queue
// ============================================================

pub const PlaybackQueue = struct {
    /// Track indices into music_db (or paths for single files)
    track_indices: [MAX_QUEUE_SIZE]u16 = [_]u16{0} ** MAX_QUEUE_SIZE,
    count: usize = 0,

    /// Current position in queue
    current_index: usize = 0,

    /// Source of the queue
    source: QueueSource = .none,

    /// Filter context (album/artist index when relevant)
    source_filter: u16 = 0,

    /// For single file playback (not in music_db)
    single_file_path: [256]u8 = [_]u8{0} ** 256,
    single_file_path_len: usize = 0,

    /// Initialize empty queue
    pub fn init() PlaybackQueue {
        return PlaybackQueue{};
    }

    /// Clear the queue
    pub fn clear(self: *PlaybackQueue) void {
        self.count = 0;
        self.current_index = 0;
        self.source = .none;
        self.source_filter = 0;
        self.single_file_path_len = 0;
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *const PlaybackQueue) bool {
        return self.count == 0;
    }

    /// Get total track count
    pub fn getCount(self: *const PlaybackQueue) usize {
        return self.count;
    }

    /// Get current position (1-indexed for display)
    pub fn getCurrentPosition(self: *const PlaybackQueue) usize {
        if (self.count == 0) return 0;
        return self.current_index + 1;
    }

    /// Check if there's a next track
    pub fn hasNext(self: *const PlaybackQueue) bool {
        return self.count > 0 and self.current_index + 1 < self.count;
    }

    /// Check if there's a previous track
    pub fn hasPrevious(self: *const PlaybackQueue) bool {
        return self.count > 0 and self.current_index > 0;
    }

    /// Get current track path
    pub fn getCurrentTrackPath(self: *const PlaybackQueue) ?[]const u8 {
        if (self.count == 0) return null;

        if (self.source == .single_file) {
            if (self.single_file_path_len > 0) {
                return self.single_file_path[0..self.single_file_path_len];
            }
            return null;
        }

        const db = music_db.getDb();
        const track_idx = self.track_indices[self.current_index];
        if (db.getTrack(track_idx)) |track| {
            return track.getPath();
        }
        return null;
    }

    /// Move to next track
    /// Returns the track path if successful, null if at end
    pub fn next(self: *PlaybackQueue) ?[]const u8 {
        if (!self.hasNext()) return null;
        self.current_index += 1;
        return self.getCurrentTrackPath();
    }

    /// Move to previous track
    /// Returns the track path if successful, null if at beginning
    pub fn previous(self: *PlaybackQueue) ?[]const u8 {
        if (!self.hasPrevious()) return null;
        self.current_index -= 1;
        return self.getCurrentTrackPath();
    }

    /// Set a single file (from file browser)
    pub fn setSingleFile(self: *PlaybackQueue, path: []const u8) void {
        self.clear();
        self.source = .single_file;
        self.count = 1;
        self.current_index = 0;

        const len = @min(path.len, self.single_file_path.len);
        @memcpy(self.single_file_path[0..len], path[0..len]);
        self.single_file_path_len = len;
    }

    /// Populate queue from an album
    /// `start_track_idx` is the track within the album to start from
    pub fn setFromAlbum(self: *PlaybackQueue, album_idx: u16, start_track_idx: usize) void {
        self.clear();
        self.source = .album;
        self.source_filter = album_idx;

        const db = music_db.getDb();

        // Collect all tracks from this album
        for (db.tracks[0..db.track_count], 0..) |track, i| {
            if (track.valid and track.album_idx == album_idx) {
                if (self.count < MAX_QUEUE_SIZE) {
                    self.track_indices[self.count] = @intCast(i);
                    self.count += 1;
                }
            }
        }

        // Sort by track number
        self.sortByTrackNumber();

        // Set starting position
        self.current_index = @min(start_track_idx, if (self.count > 0) self.count - 1 else 0);
    }

    /// Populate queue from an artist (all their tracks)
    pub fn setFromArtist(self: *PlaybackQueue, artist_idx: u16, start_track_idx: usize) void {
        self.clear();
        self.source = .artist;
        self.source_filter = artist_idx;

        const db = music_db.getDb();

        // Collect all tracks from this artist
        for (db.tracks[0..db.track_count], 0..) |track, i| {
            if (track.valid and track.artist_idx == artist_idx) {
                if (self.count < MAX_QUEUE_SIZE) {
                    self.track_indices[self.count] = @intCast(i);
                    self.count += 1;
                }
            }
        }

        // Sort by album, then track number
        self.sortByAlbumAndTrack();

        self.current_index = @min(start_track_idx, if (self.count > 0) self.count - 1 else 0);
    }

    /// Populate queue from all songs
    pub fn setFromAllSongs(self: *PlaybackQueue, start_track_idx: usize) void {
        self.clear();
        self.source = .all_songs;

        const db = music_db.getDb();

        // Add all valid tracks
        for (db.tracks[0..db.track_count], 0..) |track, i| {
            if (track.valid) {
                if (self.count < MAX_QUEUE_SIZE) {
                    self.track_indices[self.count] = @intCast(i);
                    self.count += 1;
                }
            }
        }

        self.current_index = @min(start_track_idx, if (self.count > 0) self.count - 1 else 0);
    }

    /// Sort queue by track number (for album playback)
    fn sortByTrackNumber(self: *PlaybackQueue) void {
        if (self.count <= 1) return;

        const db = music_db.getDb();

        // Simple bubble sort (queue is small)
        var i: usize = 0;
        while (i < self.count - 1) : (i += 1) {
            var j: usize = 0;
            while (j < self.count - 1 - i) : (j += 1) {
                const track_a = db.getTrack(self.track_indices[j]);
                const track_b = db.getTrack(self.track_indices[j + 1]);

                const num_a = if (track_a) |t| t.track_number else 0;
                const num_b = if (track_b) |t| t.track_number else 0;

                if (num_a > num_b) {
                    const tmp = self.track_indices[j];
                    self.track_indices[j] = self.track_indices[j + 1];
                    self.track_indices[j + 1] = tmp;
                }
            }
        }
    }

    /// Sort queue by album index, then track number
    fn sortByAlbumAndTrack(self: *PlaybackQueue) void {
        if (self.count <= 1) return;

        const db = music_db.getDb();

        var i: usize = 0;
        while (i < self.count - 1) : (i += 1) {
            var j: usize = 0;
            while (j < self.count - 1 - i) : (j += 1) {
                const track_a = db.getTrack(self.track_indices[j]);
                const track_b = db.getTrack(self.track_indices[j + 1]);

                const album_a = if (track_a) |t| t.album_idx else 0;
                const album_b = if (track_b) |t| t.album_idx else 0;
                const num_a = if (track_a) |t| t.track_number else 0;
                const num_b = if (track_b) |t| t.track_number else 0;

                // Sort by album first, then track number
                const should_swap = if (album_a != album_b)
                    album_a > album_b
                else
                    num_a > num_b;

                if (should_swap) {
                    const tmp = self.track_indices[j];
                    self.track_indices[j] = self.track_indices[j + 1];
                    self.track_indices[j + 1] = tmp;
                }
            }
        }
    }

    /// Find position of a track in the queue by its db index
    pub fn findTrackPosition(self: *const PlaybackQueue, db_track_idx: usize) ?usize {
        for (self.track_indices[0..self.count], 0..) |idx, i| {
            if (idx == db_track_idx) return i;
        }
        return null;
    }
};

// ============================================================
// Global Queue
// ============================================================

var global_queue: PlaybackQueue = PlaybackQueue{};

/// Get the global playback queue
pub fn getQueue() *PlaybackQueue {
    return &global_queue;
}

// ============================================================
// Tests
// ============================================================

test "playback queue init" {
    const queue = PlaybackQueue.init();
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), queue.getCount());
}

test "playback queue single file" {
    var queue = PlaybackQueue.init();

    queue.setSingleFile("/MUSIC/test.mp3");

    try std.testing.expect(!queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), queue.getCount());
    try std.testing.expectEqual(QueueSource.single_file, queue.source);
    try std.testing.expect(!queue.hasNext());
    try std.testing.expect(!queue.hasPrevious());

    const path = queue.getCurrentTrackPath();
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/MUSIC/test.mp3", path.?);
}

test "playback queue navigation" {
    var queue = PlaybackQueue.init();

    // Manually populate for testing
    queue.track_indices[0] = 0;
    queue.track_indices[1] = 1;
    queue.track_indices[2] = 2;
    queue.count = 3;
    queue.source = .album;

    try std.testing.expectEqual(@as(usize, 1), queue.getCurrentPosition());
    try std.testing.expect(queue.hasNext());
    try std.testing.expect(!queue.hasPrevious());

    // Move to next
    _ = queue.next();
    try std.testing.expectEqual(@as(usize, 2), queue.getCurrentPosition());
    try std.testing.expect(queue.hasNext());
    try std.testing.expect(queue.hasPrevious());

    // Move to last
    _ = queue.next();
    try std.testing.expectEqual(@as(usize, 3), queue.getCurrentPosition());
    try std.testing.expect(!queue.hasNext());
    try std.testing.expect(queue.hasPrevious());

    // Move back
    _ = queue.previous();
    try std.testing.expectEqual(@as(usize, 2), queue.getCurrentPosition());
}

test "playback queue clear" {
    var queue = PlaybackQueue.init();
    queue.setSingleFile("/test.mp3");

    try std.testing.expect(!queue.isEmpty());

    queue.clear();
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(QueueSource.none, queue.source);
}
