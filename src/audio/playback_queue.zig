//! Playback Queue
//!
//! Manages the list of tracks to play, supporting next/previous navigation.
//! The queue is populated based on playback context (album, artist, all songs, etc.)
//! Supports shuffle mode with Fisher-Yates algorithm and repeat modes.

const std = @import("std");
const music_db = @import("../library/music_db.zig");
const playlist_parser = @import("../library/playlist.zig");

// ============================================================
// Repeat Mode
// ============================================================

/// Repeat mode for playback
pub const RepeatMode = enum {
    off, // Stop at end of queue
    one, // Repeat current track
    all, // Repeat entire queue (loop)

    /// Cycle to next repeat mode
    pub fn next(self: RepeatMode) RepeatMode {
        return switch (self) {
            .off => .one,
            .one => .all,
            .all => .off,
        };
    }

    /// Get display string
    pub fn toString(self: RepeatMode) []const u8 {
        return switch (self) {
            .off => "Off",
            .one => "One",
            .all => "All",
        };
    }

    /// Get icon for status bar
    pub fn toIcon(self: RepeatMode) []const u8 {
        return switch (self) {
            .off => "  ",
            .one => "R1",
            .all => "RA",
        };
    }
};

// ============================================================
// Constants
// ============================================================

/// Maximum tracks in the queue
pub const MAX_QUEUE_SIZE: usize = 256;

// ============================================================
// Simple PRNG for shuffle (LCG - works in embedded context)
// ============================================================

var prng_state: u32 = 12345;

/// Seed the PRNG (call with timer value or similar)
pub fn seedRandom(seed: u32) void {
    prng_state = if (seed == 0) 12345 else seed;
}

/// Get next random number (LCG: x = (a*x + c) mod m)
fn nextRandom() u32 {
    // Parameters from Numerical Recipes
    prng_state = prng_state *% 1664525 +% 1013904223;
    return prng_state;
}

/// Get random number in range [0, max)
fn randomRange(max: usize) usize {
    if (max == 0) return 0;
    return nextRandom() % max;
}

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
    playlist, // From M3U/PLS playlist file
    custom, // Manual queue
};

// ============================================================
// Playback Queue
// ============================================================

/// Maximum path length for playlist entries
pub const MAX_PATH_LENGTH: usize = 256;

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

    /// For playlist playback - stores resolved file paths
    playlist_paths: [MAX_QUEUE_SIZE][MAX_PATH_LENGTH]u8 = undefined,
    playlist_path_lens: [MAX_QUEUE_SIZE]u8 = [_]u8{0} ** MAX_QUEUE_SIZE,

    /// Base directory for resolving relative playlist paths
    playlist_base_dir: [MAX_PATH_LENGTH]u8 = [_]u8{0} ** MAX_PATH_LENGTH,
    playlist_base_dir_len: usize = 0,

    /// Shuffle mode
    shuffle_enabled: bool = false,
    /// Original order backup (for unshuffling)
    original_order: [MAX_QUEUE_SIZE]u16 = [_]u16{0} ** MAX_QUEUE_SIZE,
    /// Original position of current track (to restore after unshuffle)
    original_current_track: u16 = 0,

    /// Repeat mode
    repeat_mode: RepeatMode = .off,

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
        self.shuffle_enabled = false;
        self.repeat_mode = .off;
    }

    /// Get current repeat mode
    pub fn getRepeatMode(self: *const PlaybackQueue) RepeatMode {
        return self.repeat_mode;
    }

    /// Set repeat mode
    pub fn setRepeatMode(self: *PlaybackQueue, mode: RepeatMode) void {
        self.repeat_mode = mode;
    }

    /// Cycle to next repeat mode
    pub fn toggleRepeat(self: *PlaybackQueue) void {
        self.repeat_mode = self.repeat_mode.next();
    }

    /// Check if shuffle is enabled
    pub fn isShuffled(self: *const PlaybackQueue) bool {
        return self.shuffle_enabled;
    }

    /// Toggle shuffle mode
    pub fn toggleShuffle(self: *PlaybackQueue) void {
        if (self.shuffle_enabled) {
            self.unshuffle();
        } else {
            self.shuffle();
        }
    }

    /// Enable shuffle - randomize queue order
    pub fn shuffle(self: *PlaybackQueue) void {
        if (self.count <= 1 or self.source == .single_file) return;

        // Save original order
        @memcpy(self.original_order[0..self.count], self.track_indices[0..self.count]);

        // Remember current track to keep it at current position
        const current_track = self.track_indices[self.current_index];
        self.original_current_track = current_track;

        // Fisher-Yates shuffle, but keep current track in place
        // Move current track to position 0 first
        self.track_indices[self.current_index] = self.track_indices[0];
        self.track_indices[0] = current_track;

        // Shuffle the rest (from index 1 onwards)
        var i: usize = self.count - 1;
        while (i > 1) : (i -= 1) {
            const j = 1 + randomRange(i); // Random index from 1 to i
            const tmp = self.track_indices[i];
            self.track_indices[i] = self.track_indices[j];
            self.track_indices[j] = tmp;
        }

        // Current track is now at index 0
        self.current_index = 0;
        self.shuffle_enabled = true;
    }

    /// Disable shuffle - restore original order
    pub fn unshuffle(self: *PlaybackQueue) void {
        if (!self.shuffle_enabled or self.count <= 1) return;

        // Get current track before restoring
        const current_track = self.track_indices[self.current_index];

        // Restore original order
        @memcpy(self.track_indices[0..self.count], self.original_order[0..self.count]);

        // Find current track in original order
        for (self.track_indices[0..self.count], 0..) |track, i| {
            if (track == current_track) {
                self.current_index = i;
                break;
            }
        }

        self.shuffle_enabled = false;
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

    /// Check if there's a next track (for manual navigation)
    pub fn hasNext(self: *const PlaybackQueue) bool {
        return self.count > 0 and self.current_index + 1 < self.count;
    }

    /// Check if there's a previous track
    pub fn hasPrevious(self: *const PlaybackQueue) bool {
        return self.count > 0 and self.current_index > 0;
    }

    /// Check if auto-advance should continue (respects repeat mode)
    pub fn canAutoAdvance(self: *const PlaybackQueue) bool {
        if (self.count == 0) return false;
        return switch (self.repeat_mode) {
            .off => self.current_index + 1 < self.count,
            .one => true, // Always can repeat current track
            .all => true, // Always can wrap around
        };
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

        if (self.source == .playlist) {
            const path_len = self.playlist_path_lens[self.current_index];
            if (path_len > 0) {
                return self.playlist_paths[self.current_index][0..path_len];
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

    /// Move to next track (manual skip - ignores repeat one)
    /// Returns the track path if successful, null if at end
    pub fn next(self: *PlaybackQueue) ?[]const u8 {
        if (self.count == 0) return null;

        if (self.current_index + 1 < self.count) {
            // More tracks ahead
            self.current_index += 1;
            return self.getCurrentTrackPath();
        } else if (self.repeat_mode == .all) {
            // Wrap to beginning
            self.current_index = 0;
            return self.getCurrentTrackPath();
        }

        return null;
    }

    /// Move to previous track
    /// Returns the track path if successful, null if at beginning
    pub fn previous(self: *PlaybackQueue) ?[]const u8 {
        if (self.count == 0) return null;

        if (self.current_index > 0) {
            self.current_index -= 1;
            return self.getCurrentTrackPath();
        } else if (self.repeat_mode == .all) {
            // Wrap to end
            self.current_index = self.count - 1;
            return self.getCurrentTrackPath();
        }

        return null;
    }

    /// Auto-advance to next track when current finishes (respects repeat mode)
    /// Returns: .same_track for repeat one, .next_track with path, or .end_of_queue
    pub const AutoAdvanceResult = union(enum) {
        same_track: []const u8, // Repeat one - play same track again
        next_track: []const u8, // Advanced to next track
        end_of_queue, // No more tracks (repeat off, at end)
    };

    pub fn autoAdvance(self: *PlaybackQueue) AutoAdvanceResult {
        if (self.count == 0) return .end_of_queue;

        switch (self.repeat_mode) {
            .one => {
                // Repeat current track
                if (self.getCurrentTrackPath()) |path| {
                    return .{ .same_track = path };
                }
                return .end_of_queue;
            },
            .all => {
                // Advance, wrap if at end
                if (self.current_index + 1 < self.count) {
                    self.current_index += 1;
                } else {
                    self.current_index = 0; // Wrap to beginning
                }
                if (self.getCurrentTrackPath()) |path| {
                    return .{ .next_track = path };
                }
                return .end_of_queue;
            },
            .off => {
                // Stop at end
                if (self.current_index + 1 < self.count) {
                    self.current_index += 1;
                    if (self.getCurrentTrackPath()) |path| {
                        return .{ .next_track = path };
                    }
                }
                return .end_of_queue;
            },
        }
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

    /// Populate queue from a parsed playlist
    /// `playlist_path` is used to resolve relative paths in the playlist
    /// `parsed` contains the parsed playlist entries
    pub fn setFromPlaylist(
        self: *PlaybackQueue,
        playlist_path: []const u8,
        parsed: *const playlist_parser.M3uParser.ParseResult,
    ) void {
        self.clear();
        self.source = .playlist;

        // Extract base directory from playlist path
        self.setPlaylistBaseDir(playlist_path);

        // Add entries from parsed playlist
        for (parsed.entries[0..parsed.count]) |entry| {
            if (self.count >= MAX_QUEUE_SIZE) break;

            // Resolve the path (relative to playlist directory if not absolute)
            const resolved = self.resolvePlaylistPath(entry.path);
            if (resolved) |path| {
                const idx = self.count;
                const len = @min(path.len, MAX_PATH_LENGTH);
                @memcpy(self.playlist_paths[idx][0..len], path[0..len]);
                self.playlist_path_lens[idx] = @intCast(len);
                self.count += 1;
            }
        }

        self.current_index = 0;
    }

    /// Set the base directory for playlist path resolution
    fn setPlaylistBaseDir(self: *PlaybackQueue, playlist_path: []const u8) void {
        // Find last path separator
        var last_sep: usize = 0;
        for (playlist_path, 0..) |c, i| {
            if (c == '/' or c == '\\') last_sep = i;
        }

        if (last_sep > 0) {
            const len = @min(last_sep, self.playlist_base_dir.len);
            @memcpy(self.playlist_base_dir[0..len], playlist_path[0..len]);
            self.playlist_base_dir_len = len;
        } else {
            self.playlist_base_dir_len = 0;
        }
    }

    /// Resolve a playlist entry path (handle relative vs absolute)
    /// Returns a slice into a static buffer
    fn resolvePlaylistPath(self: *PlaybackQueue, path: []const u8) ?[]const u8 {
        if (path.len == 0) return null;

        // Check if absolute path
        if (path[0] == '/' or (path.len > 1 and path[1] == ':')) {
            return path;
        }

        // Relative path - prepend base directory
        if (self.playlist_base_dir_len == 0) {
            return path;
        }

        // Build absolute path in static buffer
        const ResolveBuffer = struct {
            var buf: [MAX_PATH_LENGTH]u8 = undefined;
        };

        var pos: usize = 0;

        // Copy base dir
        const base_len = @min(self.playlist_base_dir_len, ResolveBuffer.buf.len);
        @memcpy(ResolveBuffer.buf[0..base_len], self.playlist_base_dir[0..base_len]);
        pos = base_len;

        // Add separator
        if (pos < ResolveBuffer.buf.len) {
            ResolveBuffer.buf[pos] = '/';
            pos += 1;
        }

        // Add relative path
        const path_len = @min(path.len, ResolveBuffer.buf.len - pos);
        @memcpy(ResolveBuffer.buf[pos .. pos + path_len], path[0..path_len]);
        pos += path_len;

        return ResolveBuffer.buf[0..pos];
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

test "playback queue shuffle" {
    var queue = PlaybackQueue.init();

    // Manually populate for testing
    for (0..10) |i| {
        queue.track_indices[i] = @intCast(i);
    }
    queue.count = 10;
    queue.current_index = 3;
    queue.source = .album;

    // Current track before shuffle
    const current_before = queue.track_indices[queue.current_index];

    // Enable shuffle
    queue.shuffle();
    try std.testing.expect(queue.isShuffled());
    try std.testing.expectEqual(@as(usize, 10), queue.count);

    // Current track should still be accessible (at position 0 after shuffle)
    try std.testing.expectEqual(current_before, queue.track_indices[0]);
    try std.testing.expectEqual(@as(usize, 0), queue.current_index);

    // Unshuffle
    queue.unshuffle();
    try std.testing.expect(!queue.isShuffled());

    // Original order should be restored
    for (0..10) |i| {
        try std.testing.expectEqual(@as(u16, @intCast(i)), queue.track_indices[i]);
    }
}

test "playback queue toggle shuffle" {
    var queue = PlaybackQueue.init();

    for (0..5) |i| {
        queue.track_indices[i] = @intCast(i);
    }
    queue.count = 5;
    queue.source = .album;

    try std.testing.expect(!queue.isShuffled());

    queue.toggleShuffle();
    try std.testing.expect(queue.isShuffled());

    queue.toggleShuffle();
    try std.testing.expect(!queue.isShuffled());
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

test "repeat mode toggle" {
    var queue = PlaybackQueue.init();

    try std.testing.expectEqual(RepeatMode.off, queue.getRepeatMode());

    queue.toggleRepeat();
    try std.testing.expectEqual(RepeatMode.one, queue.getRepeatMode());

    queue.toggleRepeat();
    try std.testing.expectEqual(RepeatMode.all, queue.getRepeatMode());

    queue.toggleRepeat();
    try std.testing.expectEqual(RepeatMode.off, queue.getRepeatMode());
}

test "repeat mode cleared on queue clear" {
    var queue = PlaybackQueue.init();
    queue.setRepeatMode(.all);

    try std.testing.expectEqual(RepeatMode.all, queue.getRepeatMode());

    queue.clear();
    try std.testing.expectEqual(RepeatMode.off, queue.getRepeatMode());
}

test "next with repeat all wraps around" {
    var queue = PlaybackQueue.init();

    // Manually populate for testing
    queue.track_indices[0] = 0;
    queue.track_indices[1] = 1;
    queue.track_indices[2] = 2;
    queue.count = 3;
    queue.source = .album;
    queue.setRepeatMode(.all);

    // Move to last position
    queue.current_index = 2;

    // Next should wrap to beginning
    _ = queue.next();
    try std.testing.expectEqual(@as(usize, 0), queue.current_index);
}

test "previous with repeat all wraps around" {
    var queue = PlaybackQueue.init();

    // Manually populate for testing
    queue.track_indices[0] = 0;
    queue.track_indices[1] = 1;
    queue.track_indices[2] = 2;
    queue.count = 3;
    queue.source = .album;
    queue.setRepeatMode(.all);

    // At first position
    queue.current_index = 0;

    // Previous should wrap to end
    _ = queue.previous();
    try std.testing.expectEqual(@as(usize, 2), queue.current_index);
}

test "auto advance repeat one" {
    var queue = PlaybackQueue.init();

    // Use single file for simpler testing
    queue.setSingleFile("/test.mp3");
    queue.setRepeatMode(.one);

    const result = queue.autoAdvance();
    // Repeat one returns same_track with current path
    switch (result) {
        .same_track => |path| {
            try std.testing.expectEqualStrings("/test.mp3", path);
        },
        else => try std.testing.expect(false), // Should be same_track
    }
}

test "auto advance repeat all at end" {
    var queue = PlaybackQueue.init();

    // Use single file approach - simpler for testing
    queue.setSingleFile("/music/track.mp3");
    queue.setRepeatMode(.all);

    const result = queue.autoAdvance();
    // With single file and repeat all, wraps to same track
    switch (result) {
        .next_track => |path| {
            try std.testing.expectEqualStrings("/music/track.mp3", path);
        },
        else => try std.testing.expect(false), // Should be next_track
    }
}

test "auto advance repeat off at end" {
    var queue = PlaybackQueue.init();

    queue.track_indices[0] = 0;
    queue.track_indices[1] = 1;
    queue.track_indices[2] = 2;
    queue.count = 3;
    queue.source = .album;
    queue.current_index = 2; // At last position
    queue.setRepeatMode(.off);

    const result = queue.autoAdvance();
    switch (result) {
        .end_of_queue => {}, // Expected
        else => try std.testing.expect(false), // Should be end_of_queue
    }
}

test "can auto advance" {
    var queue = PlaybackQueue.init();

    queue.track_indices[0] = 0;
    queue.track_indices[1] = 1;
    queue.count = 2;
    queue.source = .album;
    queue.current_index = 1; // At last position

    // Repeat off - can't advance at end
    queue.setRepeatMode(.off);
    try std.testing.expect(!queue.canAutoAdvance());

    // Repeat one - can always advance (replay same)
    queue.setRepeatMode(.one);
    try std.testing.expect(queue.canAutoAdvance());

    // Repeat all - can always advance (wrap)
    queue.setRepeatMode(.all);
    try std.testing.expect(queue.canAutoAdvance());
}

test "playlist path resolution absolute" {
    var queue = PlaybackQueue.init();
    queue.setPlaylistBaseDir("/music/playlists/myplaylist.m3u");

    // Absolute path should remain unchanged
    const resolved = queue.resolvePlaylistPath("/other/song.mp3");
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings("/other/song.mp3", resolved.?);
}

test "playlist path resolution relative" {
    var queue = PlaybackQueue.init();
    queue.setPlaylistBaseDir("/music/playlists/myplaylist.m3u");

    // Relative path should be prepended with base dir
    const resolved = queue.resolvePlaylistPath("track1.mp3");
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings("/music/playlists/track1.mp3", resolved.?);
}

test "playlist set from parsed" {
    var queue = PlaybackQueue.init();

    // Create a mock parsed result
    var parsed = playlist_parser.M3uParser.ParseResult{
        .entries = undefined,
        .count = 0,
        .name = "",
        .is_extended = false,
    };

    // Initialize entries
    for (&parsed.entries) |*entry| {
        entry.* = playlist_parser.PlaylistEntry.init();
    }

    // Add some entries
    parsed.entries[0].path = "/music/song1.mp3";
    parsed.entries[1].path = "song2.mp3"; // Relative
    parsed.entries[2].path = "/music/song3.mp3";
    parsed.count = 3;

    queue.setFromPlaylist("/playlists/test.m3u", &parsed);

    try std.testing.expectEqual(@as(usize, 3), queue.count);
    try std.testing.expectEqual(QueueSource.playlist, queue.source);

    // Check first path (absolute)
    try std.testing.expectEqualStrings("/music/song1.mp3", queue.getCurrentTrackPath().?);

    // Navigate and check second path (was relative, now resolved)
    _ = queue.next();
    try std.testing.expectEqualStrings("/playlists/song2.mp3", queue.getCurrentTrackPath().?);

    // Third path
    _ = queue.next();
    try std.testing.expectEqualStrings("/music/song3.mp3", queue.getCurrentTrackPath().?);
}
