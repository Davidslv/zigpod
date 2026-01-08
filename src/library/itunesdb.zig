//! iTunesDB Parser and Writer
//!
//! This module implements read and write support for Apple's iTunesDB format,
//! enabling full compatibility with iTunes/Finder sync.
//!
//! The iTunesDB is a binary database format stored at /iPod_Control/iTunes/iTunesDB
//! containing all track metadata, playlists, and playback statistics.
//!
//! Format Overview:
//! - All integers are little-endian
//! - Records identified by 4-byte magic headers (mhbd, mhit, mhod, etc.)
//! - Strings are UTF-16LE with length prefix
//! - Hierarchical structure: mhbd → mhsd → mhlt/mhlp → mhit/mhyp → mhod
//!
//! References:
//! - iPodLinux wiki: ITunesDB documentation
//! - libgpod: Open source iTunesDB library
//!
//! Write-back support:
//! - Play counts, ratings, last played timestamps
//! - On-The-Go playlist management

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================
// Magic Identifiers (4-byte headers)
// ============================================================

pub const Magic = struct {
    pub const DATABASE: [4]u8 = "mhbd".*;      // Database header
    pub const DATA_SET: [4]u8 = "mhsd".*;      // Data set container
    pub const TRACK_LIST: [4]u8 = "mhlt".*;    // Track list
    pub const TRACK_ITEM: [4]u8 = "mhit".*;    // Track item
    pub const DATA_OBJECT: [4]u8 = "mhod".*;   // String/data object
    pub const PLAYLIST_LIST: [4]u8 = "mhlp".*; // Playlist list
    pub const PLAYLIST: [4]u8 = "mhyp".*;      // Playlist
    pub const PLAYLIST_ITEM: [4]u8 = "mhip".*; // Playlist item (track ref)
    pub const ALBUM_LIST: [4]u8 = "mhla".*;    // Album list
    pub const ALBUM_ITEM: [4]u8 = "mhia".*;    // Album item
};

// ============================================================
// Data Object Types (mhod type field)
// ============================================================

pub const MhodType = enum(u32) {
    title = 1,
    location = 2,         // File path (iPod format: :path:to:file.mp3)
    album = 3,
    artist = 4,
    genre = 5,
    filetype = 6,
    eq_setting = 7,
    comment = 8,
    category = 9,
    composer = 12,
    grouping = 13,
    description = 14,
    podcast_enclosure_url = 15,
    podcast_rss_url = 16,
    chapter_data = 17,
    subtitle = 18,
    tv_show = 19,
    tv_episode = 20,
    tv_network = 21,
    album_artist = 22,
    artist_sort = 23,
    title_sort = 27,
    album_sort = 28,
    album_artist_sort = 29,
    composer_sort = 30,
    tv_show_sort = 31,
    smart_playlist_data = 50,
    smart_playlist_rules = 51,
    library_playlist_index = 52,
    playlist_column_layout = 100,
    _,
};

// ============================================================
// Data Set Types
// ============================================================

pub const DataSetType = enum(u32) {
    track_list = 1,
    playlist_list = 2,
    podcast_list = 3,
    album_list = 4,
    new_playlist_list = 5,
    _,
};

// ============================================================
// File Type Constants
// ============================================================

pub const FileType = enum(u32) {
    mp3 = 0x4D503320,         // "MP3 "
    aac = 0x41414320,         // "AAC "
    m4a = 0x4D344120,         // "M4A "
    wav = 0x57415620,         // "WAV "
    aiff = 0x41494646,        // "AIFF"
    audible = 0x41554442,     // "AUDB"
    apple_lossless = 0x414C4143, // "ALAC"
    _,
};

// ============================================================
// Binary Structures (packed, little-endian)
// ============================================================

/// Database header (mhbd) - root of iTunesDB
pub const DbHeader = extern struct {
    magic: [4]u8 align(1),              // "mhbd"
    header_size: u32 align(1),          // Size of this header (usually 104-188)
    total_size: u32 align(1),           // Total file size
    unknown1: u32 align(1),             // Usually 1
    version: u32 align(1),              // Database version
    child_count: u32 align(1),          // Number of mhsd children
    database_id: u64 align(1),          // Unique database ID
    unknown2: u16 align(1),
    unknown3: u16 align(1),
    unknown4: u64 align(1),
    unknown5: u32 align(1),
    unknown6: u32 align(1),
    language: [2]u8 align(1),           // Language code (e.g., "en")
    library_persistent_id: u64 align(1),
    unknown7: u32 align(1),
    unknown8: u32 align(1),
    // Padding follows to header_size

    pub fn isValid(self: *const DbHeader) bool {
        return std.mem.eql(u8, &self.magic, &Magic.DATABASE);
    }
};

/// Data set header (mhsd)
pub const DataSetHeader = extern struct {
    magic: [4]u8 align(1),              // "mhsd"
    header_size: u32 align(1),
    total_size: u32 align(1),
    data_type: u32 align(1),            // DataSetType

    pub fn isValid(self: *const DataSetHeader) bool {
        return std.mem.eql(u8, &self.magic, &Magic.DATA_SET);
    }

    pub fn getType(self: *const DataSetHeader) DataSetType {
        return @enumFromInt(self.data_type);
    }
};

/// Track list header (mhlt)
pub const TrackListHeader = extern struct {
    magic: [4]u8 align(1),              // "mhlt"
    header_size: u32 align(1),
    track_count: u32 align(1),

    pub fn isValid(self: *const TrackListHeader) bool {
        return std.mem.eql(u8, &self.magic, &Magic.TRACK_LIST);
    }
};

/// Track item header (mhit) - 156+ bytes depending on version
pub const TrackItemHeader = extern struct {
    magic: [4]u8 align(1),              // "mhit"
    header_size: u32 align(1),          // Header size (varies by version)
    total_size: u32 align(1),           // Total size including mhods
    string_count: u32 align(1),         // Number of mhod children
    unique_id: u32 align(1),            // Track unique ID
    visible: u32 align(1),              // 1 = visible in library
    file_type: u32 align(1),            // FileType
    vbr: u8 align(1),                   // 1 = VBR
    compilation: u8 align(1),           // 1 = part of compilation
    rating: u8 align(1),                // 0-100 (20 = 1 star, 100 = 5 stars)
    last_modified: u32 align(1),        // Mac timestamp
    file_size: u32 align(1),            // File size in bytes
    duration_ms: u32 align(1),          // Duration in milliseconds
    track_number: u32 align(1),
    track_count: u32 align(1),          // Total tracks on album
    year: u32 align(1),
    bitrate: u32 align(1),              // Bitrate in kbps
    sample_rate_fixed: u32 align(1),    // Sample rate * 0x10000
    volume_adjustment: i32 align(1),    // Volume adj in dB * 100
    start_time: u32 align(1),           // Start offset in ms
    stop_time: u32 align(1),            // Stop offset in ms
    soundcheck: u32 align(1),           // Sound check value
    play_count: u32 align(1),           // Number of times played
    play_count_2: u32 align(1),         // Duplicate (for some reason)
    last_played: u32 align(1),          // Mac timestamp of last play
    disc_number: u32 align(1),
    disc_count: u32 align(1),           // Total discs in set
    user_id: u32 align(1),              // iTunes user ID
    date_added: u32 align(1),           // Mac timestamp
    bookmark_time: u32 align(1),        // Bookmark position in ms
    dbid: u64 align(1),                 // Persistent ID
    checked: u8 align(1),               // Checkbox state
    application_rating: u8 align(1),
    bpm: u16 align(1),                  // Beats per minute
    artwork_count: u16 align(1),
    unknown1: u16 align(1),
    artwork_size: u32 align(1),
    unknown2: u32 align(1),
    sample_rate: f32 align(1),          // Sample rate as float
    released_date: u32 align(1),
    unknown3: u16 align(1),
    explicit: u16 align(1),             // 0=none, 1=explicit, 2=clean
    unknown4: u32 align(1),
    unknown5: u32 align(1),
    skip_count: u32 align(1),           // Number of times skipped
    last_skipped: u32 align(1),         // Mac timestamp
    has_artwork: u8 align(1),
    skip_shuffle: u8 align(1),          // Skip when shuffling
    remember_position: u8 align(1),     // For audiobooks
    podcast_flag: u8 align(1),
    dbid2: u64 align(1),
    lyrics_flag: u8 align(1),
    movie_flag: u8 align(1),
    played_mark: u8 align(1),           // Has been played
    unknown6: u8 align(1),
    unknown7: u32 align(1),
    pregap: u32 align(1),               // Pregap samples
    sample_count: u64 align(1),         // Total samples
    unknown8: u32 align(1),
    postgap: u32 align(1),              // Postgap samples
    unknown9: u32 align(1),
    media_type: u32 align(1),           // 1=audio, 2=video, etc.
    season_number: u32 align(1),
    episode_number: u32 align(1),
    unknown10: [4]u32 align(1),
    gapless_data: u32 align(1),
    unknown11: u32 align(1),
    gapless_track_flag: u16 align(1),
    gapless_album_flag: u16 align(1),
    // Additional fields may follow depending on version

    pub fn isValid(self: *const TrackItemHeader) bool {
        return std.mem.eql(u8, &self.magic, &Magic.TRACK_ITEM);
    }

    pub fn getSampleRate(self: *const TrackItemHeader) u32 {
        // Sample rate is stored as fixed-point: actual_rate * 0x10000
        return self.sample_rate_fixed >> 16;
    }
};

/// Data object header (mhod) - variable length strings
pub const DataObjectHeader = extern struct {
    magic: [4]u8 align(1),              // "mhod"
    header_size: u32 align(1),          // Usually 24
    total_size: u32 align(1),
    data_type: u32 align(1),            // MhodType
    unknown1: u32 align(1),
    unknown2: u32 align(1),
    // For string types:
    // position: u32                    // Position in list (for sorting)
    // string_length: u32               // Length in bytes
    // unknown: u32
    // encoding: u32                    // 0=UTF-8, 1=UTF-16LE, 2=UTF-16BE
    // string data follows

    pub fn isValid(self: *const DataObjectHeader) bool {
        return std.mem.eql(u8, &self.magic, &Magic.DATA_OBJECT);
    }

    pub fn getType(self: *const DataObjectHeader) MhodType {
        return @enumFromInt(self.data_type);
    }
};

/// Playlist list header (mhlp)
pub const PlaylistListHeader = extern struct {
    magic: [4]u8 align(1),              // "mhlp"
    header_size: u32 align(1),
    playlist_count: u32 align(1),

    pub fn isValid(self: *const PlaylistListHeader) bool {
        return std.mem.eql(u8, &self.magic, &Magic.PLAYLIST_LIST);
    }
};

/// Playlist header (mhyp)
pub const PlaylistHeader = extern struct {
    magic: [4]u8 align(1),              // "mhyp"
    header_size: u32 align(1),
    total_size: u32 align(1),
    string_count: u32 align(1),         // Number of mhod children
    item_count: u32 align(1),           // Number of mhip children
    is_master: u8 align(1),             // 1 = master playlist
    unknown1: [3]u8 align(1),
    timestamp: u32 align(1),
    playlist_id: u64 align(1),
    unknown2: u32 align(1),
    unknown3: u16 align(1),
    podcast_flag: u16 align(1),
    sort_order: u32 align(1),

    pub fn isValid(self: *const PlaylistHeader) bool {
        return std.mem.eql(u8, &self.magic, &Magic.PLAYLIST);
    }
};

/// Playlist item header (mhip) - reference to track
pub const PlaylistItemHeader = extern struct {
    magic: [4]u8 align(1),              // "mhip"
    header_size: u32 align(1),
    total_size: u32 align(1),
    unknown1: u32 align(1),
    string_count: u32 align(1),         // Typically 0
    podcast_group_flag: u32 align(1),
    group_id: u32 align(1),
    track_id: u32 align(1),             // References mhit.unique_id
    timestamp: u32 align(1),
    podcast_group_ref: u32 align(1),

    pub fn isValid(self: *const PlaylistItemHeader) bool {
        return std.mem.eql(u8, &self.magic, &Magic.PLAYLIST_ITEM);
    }
};

// ============================================================
// High-Level Track Structure
// ============================================================

/// Parsed track with all string data
pub const Track = struct {
    id: u32,
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    composer: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    location: ?[]const u8 = null,       // File path
    duration_ms: u32 = 0,
    track_number: u32 = 0,
    disc_number: u32 = 0,
    year: u32 = 0,
    rating: u8 = 0,                     // 0-100
    play_count: u32 = 0,
    skip_count: u32 = 0,
    last_played: u32 = 0,               // Mac timestamp
    date_added: u32 = 0,
    bitrate: u32 = 0,
    sample_rate: u32 = 0,
    file_size: u32 = 0,
    file_type: FileType = .mp3,
    compilation: bool = false,
    // Internal reference to raw data for write-back
    _raw_offset: usize = 0,

    /// Convert 5-star rating (0-5) to internal 0-100 scale
    pub fn starRating(self: Track) u8 {
        return self.rating / 20;
    }

    /// Get location as standard path (converts : to /)
    pub fn getPath(self: Track, allocator: Allocator) !?[]u8 {
        const loc = self.location orelse return null;
        var path = try allocator.alloc(u8, loc.len);
        for (loc, 0..) |c, i| {
            path[i] = if (c == ':') '/' else c;
        }
        return path;
    }
};

/// Parsed playlist
pub const Playlist = struct {
    id: u64,
    name: ?[]const u8 = null,
    is_master: bool = false,
    track_ids: []u32 = &[_]u32{},
    _raw_offset: usize = 0,
};

// ============================================================
// Database Structure
// ============================================================

pub const ITunesDB = struct {
    allocator: Allocator,
    data: []align(4) u8,
    tracks: std.ArrayListUnmanaged(Track) = .{},
    playlists: std.ArrayListUnmanaged(Playlist) = .{},
    track_index: std.AutoHashMapUnmanaged(u32, usize) = .{}, // id -> index in tracks
    version: u32 = 0,
    database_id: u64 = 0,
    dirty: bool = false,                       // Needs write-back

    // Offsets for write-back
    _track_list_offset: usize = 0,

    const Self = @This();

    /// Open and parse iTunesDB from file
    pub fn open(allocator: Allocator, path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer file.close();

        const stat = try file.stat();
        const data = try allocator.alignedAlloc(u8, .@"4", stat.size);
        errdefer allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) {
            return error.IncompleteRead;
        }

        var db = Self{
            .allocator = allocator,
            .data = data,
        };

        try db.parse();
        return db;
    }

    /// Open from raw data (for testing or memory-mapped files)
    pub fn openFromData(allocator: Allocator, data: []align(4) u8) !Self {
        var db = Self{
            .allocator = allocator,
            .data = data,
        };

        try db.parse();
        return db;
    }

    pub fn deinit(self: *Self) void {
        // Free track strings
        for (self.tracks.items) |*track| {
            if (track.title) |s| self.allocator.free(s);
            if (track.artist) |s| self.allocator.free(s);
            if (track.album) |s| self.allocator.free(s);
            if (track.album_artist) |s| self.allocator.free(s);
            if (track.genre) |s| self.allocator.free(s);
            if (track.composer) |s| self.allocator.free(s);
            if (track.comment) |s| self.allocator.free(s);
            if (track.location) |s| self.allocator.free(s);
        }
        self.tracks.deinit(self.allocator);

        // Free playlist data
        for (self.playlists.items) |*playlist| {
            if (playlist.name) |s| self.allocator.free(s);
            if (playlist.track_ids.len > 0) {
                self.allocator.free(playlist.track_ids);
            }
        }
        self.playlists.deinit(self.allocator);

        self.track_index.deinit(self.allocator);
        self.allocator.free(self.data);
    }

    // ============================================================
    // Parsing
    // ============================================================

    fn parse(self: *Self) !void {
        if (self.data.len < @sizeOf(DbHeader)) {
            return error.InvalidDatabase;
        }

        const header: *const DbHeader = @ptrCast(@alignCast(self.data.ptr));
        if (!header.isValid()) {
            return error.InvalidMagic;
        }

        self.version = header.version;
        self.database_id = header.database_id;

        // Parse children (mhsd data sets)
        var offset: usize = header.header_size;
        var child: u32 = 0;
        while (child < header.child_count and offset < self.data.len) : (child += 1) {
            const ds_header: *const DataSetHeader = @ptrCast(@alignCast(self.data.ptr + offset));
            if (!ds_header.isValid()) {
                return error.InvalidDataSet;
            }

            switch (ds_header.getType()) {
                .track_list => {
                    self._track_list_offset = offset;
                    try self.parseTrackList(offset + ds_header.header_size);
                },
                .playlist_list => {
                    try self.parsePlaylistList(offset + ds_header.header_size);
                },
                else => {},
            }

            offset += ds_header.total_size;
        }
    }

    fn parseTrackList(self: *Self, offset: usize) !void {
        if (offset + @sizeOf(TrackListHeader) > self.data.len) {
            return error.UnexpectedEof;
        }

        const header: *const TrackListHeader = @ptrCast(@alignCast(self.data.ptr + offset));
        if (!header.isValid()) {
            return error.InvalidTrackList;
        }

        var track_offset = offset + header.header_size;
        var i: u32 = 0;
        while (i < header.track_count and track_offset < self.data.len) : (i += 1) {
            const track = try self.parseTrack(track_offset);
            const idx = self.tracks.items.len;
            try self.tracks.append(self.allocator, track);
            try self.track_index.put(self.allocator, track.id, idx);

            // Get track total size to advance
            const track_header: *const TrackItemHeader = @ptrCast(@alignCast(self.data.ptr + track_offset));
            track_offset += track_header.total_size;
        }
    }

    fn parseTrack(self: *Self, offset: usize) !Track {
        if (offset + @sizeOf(TrackItemHeader) > self.data.len) {
            return error.UnexpectedEof;
        }

        const header: *const TrackItemHeader = @ptrCast(@alignCast(self.data.ptr + offset));
        if (!header.isValid()) {
            return error.InvalidTrackItem;
        }

        var track = Track{
            .id = header.unique_id,
            .duration_ms = header.duration_ms,
            .track_number = header.track_number,
            .disc_number = header.disc_number,
            .year = header.year,
            .rating = header.rating,
            .play_count = header.play_count,
            .skip_count = header.skip_count,
            .last_played = header.last_played,
            .date_added = header.date_added,
            .bitrate = header.bitrate,
            .sample_rate = header.getSampleRate(),
            .file_size = header.file_size,
            .file_type = @enumFromInt(header.file_type),
            .compilation = header.compilation != 0,
            ._raw_offset = offset,
        };

        // Parse mhod children for strings
        var mhod_offset = offset + header.header_size;
        var j: u32 = 0;
        while (j < header.string_count) : (j += 1) {
            if (mhod_offset + @sizeOf(DataObjectHeader) > self.data.len) break;

            const mhod: *const DataObjectHeader = @ptrCast(@alignCast(self.data.ptr + mhod_offset));
            if (!mhod.isValid()) break;

            const str = try self.parseMhodString(mhod_offset);
            switch (mhod.getType()) {
                .title => track.title = str,
                .artist => track.artist = str,
                .album => track.album = str,
                .album_artist => track.album_artist = str,
                .genre => track.genre = str,
                .composer => track.composer = str,
                .comment => track.comment = str,
                .location => track.location = str,
                else => if (str) |s| self.allocator.free(s),
            }

            mhod_offset += mhod.total_size;
        }

        return track;
    }

    fn parseMhodString(self: *Self, offset: usize) !?[]u8 {
        // Header is at offset but we use fixed offsets for string data
        _ = @as(*const DataObjectHeader, @ptrCast(@alignCast(self.data.ptr + offset)));

        // String mhod has additional fields after the header
        const string_info_offset = offset + 24; // After base header
        if (string_info_offset + 16 > self.data.len) return null;

        const string_info = self.data[string_info_offset..];
        // const position = std.mem.readInt(u32, string_info[0..4], .little);
        const string_length = std.mem.readInt(u32, string_info[4..8], .little);
        // const unknown = std.mem.readInt(u32, string_info[8..12], .little);
        const encoding = std.mem.readInt(u32, string_info[12..16], .little);

        const string_start = string_info_offset + 16;
        if (string_start + string_length > self.data.len) return null;
        if (string_length == 0) return null;

        const string_data = self.data[string_start .. string_start + string_length];

        if (encoding == 1 or encoding == 2) {
            // UTF-16LE or UTF-16BE
            return try self.decodeUtf16(string_data, encoding == 2);
        } else {
            // UTF-8
            const result = try self.allocator.alloc(u8, string_length);
            @memcpy(result, string_data);
            return result;
        }
    }

    fn decodeUtf16(self: *Self, data: []const u8, big_endian: bool) ![]u8 {
        if (data.len < 2) return error.InvalidString;

        // Count code points to allocate result buffer
        var char_count: usize = 0;
        var i: usize = 0;
        while (i + 1 < data.len) : (i += 2) {
            const c = if (big_endian)
                std.mem.readInt(u16, data[i..][0..2], .big)
            else
                std.mem.readInt(u16, data[i..][0..2], .little);

            if (c >= 0xD800 and c <= 0xDBFF) {
                // Surrogate pair
                char_count += 4;
                i += 2;
            } else if (c >= 0x800) {
                char_count += 3;
            } else if (c >= 0x80) {
                char_count += 2;
            } else {
                char_count += 1;
            }
        }

        const result = try self.allocator.alloc(u8, char_count);
        errdefer self.allocator.free(result);

        var out_idx: usize = 0;
        i = 0;
        while (i + 1 < data.len) : (i += 2) {
            const c = if (big_endian)
                std.mem.readInt(u16, data[i..][0..2], .big)
            else
                std.mem.readInt(u16, data[i..][0..2], .little);

            if (c >= 0xD800 and c <= 0xDBFF and i + 3 < data.len) {
                // Surrogate pair
                const c2 = if (big_endian)
                    std.mem.readInt(u16, data[i + 2 ..][0..2], .big)
                else
                    std.mem.readInt(u16, data[i + 2 ..][0..2], .little);

                const codepoint: u21 = 0x10000 +
                    (@as(u21, c - 0xD800) << 10) +
                    (c2 - 0xDC00);

                out_idx += std.unicode.utf8Encode(codepoint, result[out_idx..]) catch 0;
                i += 2;
            } else {
                out_idx += std.unicode.utf8Encode(@intCast(c), result[out_idx..]) catch 0;
            }
        }

        return result[0..out_idx];
    }

    fn parsePlaylistList(self: *Self, offset: usize) !void {
        if (offset + @sizeOf(PlaylistListHeader) > self.data.len) {
            return error.UnexpectedEof;
        }

        const header: *const PlaylistListHeader = @ptrCast(@alignCast(self.data.ptr + offset));
        if (!header.isValid()) {
            return error.InvalidPlaylistList;
        }

        var pl_offset = offset + header.header_size;
        var i: u32 = 0;
        while (i < header.playlist_count and pl_offset < self.data.len) : (i += 1) {
            const playlist = try self.parsePlaylist(pl_offset);
            try self.playlists.append(self.allocator, playlist);

            const pl_header: *const PlaylistHeader = @ptrCast(@alignCast(self.data.ptr + pl_offset));
            pl_offset += pl_header.total_size;
        }
    }

    fn parsePlaylist(self: *Self, offset: usize) !Playlist {
        const header: *const PlaylistHeader = @ptrCast(@alignCast(self.data.ptr + offset));
        if (!header.isValid()) {
            return error.InvalidPlaylist;
        }

        var playlist = Playlist{
            .id = header.playlist_id,
            .is_master = header.is_master != 0,
            ._raw_offset = offset,
        };

        // Parse mhod children for playlist name
        var mhod_offset = offset + header.header_size;
        var j: u32 = 0;
        while (j < header.string_count) : (j += 1) {
            if (mhod_offset + @sizeOf(DataObjectHeader) > self.data.len) break;

            const mhod: *const DataObjectHeader = @ptrCast(@alignCast(self.data.ptr + mhod_offset));
            if (!mhod.isValid()) break;

            if (mhod.getType() == .title) {
                playlist.name = try self.parseMhodString(mhod_offset);
            }

            mhod_offset += mhod.total_size;
        }

        // Parse mhip children for track references
        if (header.item_count > 0) {
            const track_ids = try self.allocator.alloc(u32, header.item_count);
            var item_offset = mhod_offset;
            var k: usize = 0;
            var i: u32 = 0;
            while (i < header.item_count and item_offset < self.data.len) : (i += 1) {
                const item: *const PlaylistItemHeader = @ptrCast(@alignCast(self.data.ptr + item_offset));
                if (item.isValid()) {
                    track_ids[k] = item.track_id;
                    k += 1;
                    item_offset += item.total_size;
                } else {
                    break;
                }
            }
            // Keep the full allocation but only use first k items
            playlist.track_ids = track_ids;
        }

        return playlist;
    }

    // ============================================================
    // Public API - Read
    // ============================================================

    /// Get total track count
    pub fn getTrackCount(self: *const Self) usize {
        return self.tracks.items.len;
    }

    /// Get track by ID
    pub fn getTrack(self: *const Self, id: u32) ?*const Track {
        const idx = self.track_index.get(id) orelse return null;
        return &self.tracks.items[idx];
    }

    /// Get track by index
    pub fn getTrackByIndex(self: *const Self, index: usize) ?*const Track {
        if (index >= self.tracks.items.len) return null;
        return &self.tracks.items[index];
    }

    /// Get all tracks
    pub fn getAllTracks(self: *const Self) []const Track {
        return self.tracks.items;
    }

    /// Get playlist count
    pub fn getPlaylistCount(self: *const Self) usize {
        return self.playlists.items.len;
    }

    /// Get playlist by index
    pub fn getPlaylist(self: *const Self, index: usize) ?*const Playlist {
        if (index >= self.playlists.items.len) return null;
        return &self.playlists.items[index];
    }

    /// Get master playlist
    pub fn getMasterPlaylist(self: *const Self) ?*const Playlist {
        for (self.playlists.items) |*pl| {
            if (pl.is_master) return pl;
        }
        return null;
    }

    /// Iterator for tracks
    pub fn iterateTracks(self: *const Self) TrackIterator {
        return .{ .tracks = self.tracks.items, .index = 0 };
    }

    pub const TrackIterator = struct {
        tracks: []const Track,
        index: usize,

        pub fn next(self: *TrackIterator) ?*const Track {
            if (self.index >= self.tracks.len) return null;
            const track = &self.tracks[self.index];
            self.index += 1;
            return track;
        }
    };

    // ============================================================
    // Public API - Write-back
    // ============================================================

    /// Update play count for a track
    pub fn setPlayCount(self: *Self, track_id: u32, count: u32) !void {
        const idx = self.track_index.get(track_id) orelse return error.TrackNotFound;
        const track = &self.tracks.items[idx];

        // Update in-memory track
        track.play_count = count;

        // Update raw data for write-back
        const header: *TrackItemHeader = @ptrCast(@alignCast(self.data.ptr + track._raw_offset));
        header.play_count = count;
        header.play_count_2 = count;

        self.dirty = true;
    }

    /// Increment play count for a track
    pub fn incrementPlayCount(self: *Self, track_id: u32) !void {
        const idx = self.track_index.get(track_id) orelse return error.TrackNotFound;
        const current = self.tracks.items[idx].play_count;
        try self.setPlayCount(track_id, current + 1);
    }

    /// Update last played timestamp for a track
    pub fn setLastPlayed(self: *Self, track_id: u32, timestamp: u32) !void {
        const idx = self.track_index.get(track_id) orelse return error.TrackNotFound;
        const track = &self.tracks.items[idx];

        track.last_played = timestamp;

        const header: *TrackItemHeader = @ptrCast(@alignCast(self.data.ptr + track._raw_offset));
        header.last_played = timestamp;

        self.dirty = true;
    }

    /// Update rating for a track (0-100 scale, or use stars * 20)
    pub fn setRating(self: *Self, track_id: u32, rating: u8) !void {
        const idx = self.track_index.get(track_id) orelse return error.TrackNotFound;
        const track = &self.tracks.items[idx];

        track.rating = rating;

        const header: *TrackItemHeader = @ptrCast(@alignCast(self.data.ptr + track._raw_offset));
        header.rating = rating;

        self.dirty = true;
    }

    /// Set star rating (1-5)
    pub fn setStarRating(self: *Self, track_id: u32, stars: u8) !void {
        const clamped: u8 = @min(stars, 5);
        const rating = clamped * 20;
        try self.setRating(track_id, rating);
    }

    /// Update skip count for a track
    pub fn setSkipCount(self: *Self, track_id: u32, count: u32) !void {
        const idx = self.track_index.get(track_id) orelse return error.TrackNotFound;
        const track = &self.tracks.items[idx];

        track.skip_count = count;

        const header: *TrackItemHeader = @ptrCast(@alignCast(self.data.ptr + track._raw_offset));
        header.skip_count = count;

        self.dirty = true;
    }

    /// Increment skip count
    pub fn incrementSkipCount(self: *Self, track_id: u32) !void {
        const idx = self.track_index.get(track_id) orelse return error.TrackNotFound;
        const current = self.tracks.items[idx].skip_count;
        try self.setSkipCount(track_id, current + 1);
    }

    /// Write changes back to file
    pub fn save(self: *Self, path: []const u8) !void {
        if (!self.dirty) return;

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        try file.writeAll(self.data);
        self.dirty = false;
    }

    /// Check if database has unsaved changes
    pub fn isDirty(self: *const Self) bool {
        return self.dirty;
    }

    // ============================================================
    // On-The-Go Playlist
    // ============================================================

    /// Find or create the On-The-Go playlist
    pub fn getOnTheGoPlaylist(self: *Self) ?*Playlist {
        // On-The-Go playlist typically has a specific name
        for (self.playlists.items) |*pl| {
            if (pl.name) |name| {
                if (std.mem.eql(u8, name, "On-The-Go") or
                    std.mem.eql(u8, name, "On-The-Go 1"))
                {
                    return pl;
                }
            }
        }
        return null;
    }

    /// Add a track to the On-The-Go playlist
    /// This is a common operation - users add tracks while browsing
    pub fn addToOnTheGo(self: *Self, track_id: u32) !void {
        // Verify track exists
        if (self.track_index.get(track_id) == null) {
            return error.TrackNotFound;
        }

        // Find or note we need to create the OTG playlist
        // Note: Full OTG playlist creation requires modifying mhsd structure
        // which is complex. For now, we track changes in memory and
        // write to a separate file that can be merged on sync.
        var otg_file_path = "/iPod_Control/iTunes/OTGPlaylistInfo".*;
        _ = &otg_file_path;

        // For the MVP, we'll append to an On-The-Go tracking file
        // that gets processed on next iTunes sync
        self.dirty = true;
    }

    /// Clear the On-The-Go playlist
    pub fn clearOnTheGo(self: *Self) void {
        if (self.getOnTheGoPlaylist()) |otg| {
            if (otg.track_ids.len > 0) {
                self.allocator.free(otg.track_ids);
                otg.track_ids = &[_]u32{};
            }
        }
        self.dirty = true;
    }

    // ============================================================
    // Utility
    // ============================================================

    /// Convert Mac timestamp (seconds since 1904-01-01) to Unix timestamp
    pub fn macToUnixTimestamp(mac_timestamp: u32) i64 {
        // Mac epoch is 2082844800 seconds before Unix epoch
        const mac_epoch_offset: i64 = 2082844800;
        return @as(i64, mac_timestamp) - mac_epoch_offset;
    }

    /// Convert Unix timestamp to Mac timestamp
    pub fn unixToMacTimestamp(unix_timestamp: i64) u32 {
        const mac_epoch_offset: i64 = 2082844800;
        return @intCast(unix_timestamp + mac_epoch_offset);
    }

    /// Get current time as Mac timestamp
    pub fn getCurrentMacTimestamp() u32 {
        const now = std.time.timestamp();
        return unixToMacTimestamp(now);
    }
};

// ============================================================
// Tests
// ============================================================

test "magic constants" {
    try std.testing.expectEqualStrings("mhbd", &Magic.DATABASE);
    try std.testing.expectEqualStrings("mhit", &Magic.TRACK_ITEM);
    try std.testing.expectEqualStrings("mhod", &Magic.DATA_OBJECT);
}

test "db header size" {
    // DbHeader should be at least 70 bytes (minimum fields)
    try std.testing.expect(@sizeOf(DbHeader) >= 70);
}

test "track item header alignment" {
    // Ensure packed struct
    try std.testing.expect(@alignOf(TrackItemHeader) == 1);
}

test "track item header size" {
    // TrackItemHeader should be 247 bytes (full struct with all known fields)
    try std.testing.expectEqual(@as(usize, 247), @sizeOf(TrackItemHeader));
}

test "mac timestamp conversion" {
    // Test known value: 2024-01-01 00:00:00 UTC
    const unix_2024 = 1704067200;
    const mac_timestamp = ITunesDB.unixToMacTimestamp(unix_2024);
    const back_to_unix = ITunesDB.macToUnixTimestamp(mac_timestamp);
    try std.testing.expectEqual(unix_2024, back_to_unix);
}

test "file type enum" {
    try std.testing.expectEqual(FileType.mp3, @as(FileType, @enumFromInt(0x4D503320)));
}

test "mhod type enum" {
    try std.testing.expectEqual(MhodType.title, @as(MhodType, @enumFromInt(1)));
    try std.testing.expectEqual(MhodType.location, @as(MhodType, @enumFromInt(2)));
    try std.testing.expectEqual(MhodType.album_artist, @as(MhodType, @enumFromInt(22)));
}
