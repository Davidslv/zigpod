//! Audio Metadata Parser
//!
//! Parses metadata from audio files including:
//! - ID3v1 and ID3v2 tags (MP3, WAV)
//! - Vorbis comments (FLAC, OGG)
//! - RIFF INFO chunks (WAV)

const std = @import("std");

// ============================================================
// Metadata Structure
// ============================================================

pub const Metadata = struct {
    title: [128]u8 = [_]u8{0} ** 128,
    title_len: u8 = 0,
    artist: [128]u8 = [_]u8{0} ** 128,
    artist_len: u8 = 0,
    album: [128]u8 = [_]u8{0} ** 128,
    album_len: u8 = 0,
    genre: [32]u8 = [_]u8{0} ** 32,
    genre_len: u8 = 0,
    year: u16 = 0,
    track_number: u8 = 0,
    disc_number: u8 = 0,
    duration_ms: u32 = 0,
    has_album_art: bool = false,
    album_art_offset: u32 = 0,
    album_art_size: u32 = 0,

    pub fn getTitle(self: *const Metadata) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn setTitle(self: *Metadata, value: []const u8) void {
        const len = @min(value.len, self.title.len);
        @memcpy(self.title[0..len], value[0..len]);
        self.title_len = @intCast(len);
    }

    pub fn getArtist(self: *const Metadata) []const u8 {
        return self.artist[0..self.artist_len];
    }

    pub fn setArtist(self: *Metadata, value: []const u8) void {
        const len = @min(value.len, self.artist.len);
        @memcpy(self.artist[0..len], value[0..len]);
        self.artist_len = @intCast(len);
    }

    pub fn getAlbum(self: *const Metadata) []const u8 {
        return self.album[0..self.album_len];
    }

    pub fn setAlbum(self: *Metadata, value: []const u8) void {
        const len = @min(value.len, self.album.len);
        @memcpy(self.album[0..len], value[0..len]);
        self.album_len = @intCast(len);
    }

    pub fn getGenre(self: *const Metadata) []const u8 {
        return self.genre[0..self.genre_len];
    }

    pub fn setGenre(self: *Metadata, value: []const u8) void {
        const len = @min(value.len, self.genre.len);
        @memcpy(self.genre[0..len], value[0..len]);
        self.genre_len = @intCast(len);
    }

    /// Check if metadata has any content
    pub fn isEmpty(self: *const Metadata) bool {
        return self.title_len == 0 and self.artist_len == 0 and self.album_len == 0;
    }

    /// Clear all metadata
    pub fn clear(self: *Metadata) void {
        self.title_len = 0;
        self.artist_len = 0;
        self.album_len = 0;
        self.genre_len = 0;
        self.year = 0;
        self.track_number = 0;
        self.disc_number = 0;
        self.has_album_art = false;
    }
};

// ============================================================
// ID3v1 Parser
// ============================================================

/// ID3v1 tag is always 128 bytes at the end of the file
const ID3V1_SIZE: usize = 128;
const ID3V1_MARKER = "TAG";

/// Parse ID3v1 tag from file data
pub fn parseId3v1(data: []const u8) ?Metadata {
    if (data.len < ID3V1_SIZE) return null;

    const tag_start = data.len - ID3V1_SIZE;
    const tag = data[tag_start..];

    // Check for "TAG" marker
    if (!std.mem.eql(u8, tag[0..3], ID3V1_MARKER)) return null;

    var meta = Metadata{};

    // Title: bytes 3-32 (30 bytes)
    const title = trimNullAndSpace(tag[3..33]);
    if (title.len > 0) meta.setTitle(title);

    // Artist: bytes 33-62 (30 bytes)
    const artist = trimNullAndSpace(tag[33..63]);
    if (artist.len > 0) meta.setArtist(artist);

    // Album: bytes 63-92 (30 bytes)
    const album = trimNullAndSpace(tag[63..93]);
    if (album.len > 0) meta.setAlbum(album);

    // Year: bytes 93-96 (4 bytes)
    const year_str = tag[93..97];
    meta.year = parseYearString(year_str);

    // Comment: bytes 97-126 (30 bytes) - or 28 bytes + track for ID3v1.1
    // Track number (ID3v1.1): if byte 125 is 0 and byte 126 is not 0
    if (tag[125] == 0 and tag[126] != 0) {
        meta.track_number = tag[126];
    }

    // Genre: byte 127
    if (tag[127] < 192) { // Valid genre ID
        meta.setGenre(getGenreName(tag[127]));
    }

    return meta;
}

// ============================================================
// ID3v2 Parser
// ============================================================

const ID3V2_MARKER = "ID3";

/// Parse ID3v2 tag from file data
pub fn parseId3v2(data: []const u8) ?Metadata {
    if (data.len < 10) return null;

    // Check for "ID3" marker
    if (!std.mem.eql(u8, data[0..3], ID3V2_MARKER)) return null;

    const version_major = data[3];
    const version_minor = data[4];
    _ = version_minor;

    const flags = data[5];
    const unsync = (flags & 0x80) != 0;
    _ = unsync;
    const has_extended_header = (flags & 0x40) != 0;

    // Syncsafe integer for size (4 bytes, 7 bits each)
    const tag_size = (@as(u32, data[6] & 0x7F) << 21) |
        (@as(u32, data[7] & 0x7F) << 14) |
        (@as(u32, data[8] & 0x7F) << 7) |
        @as(u32, data[9] & 0x7F);

    if (data.len < 10 + tag_size) return null;

    var meta = Metadata{};
    var offset: usize = 10;

    // Skip extended header if present
    if (has_extended_header) {
        if (offset + 4 > data.len) return meta;
        const ext_size = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4 + ext_size;
    }

    // Parse frames
    const frame_header_size: usize = if (version_major >= 3) 10 else 6;

    while (offset + frame_header_size < 10 + tag_size and offset + frame_header_size < data.len) {
        const frame_id = data[offset .. offset + (if (version_major >= 3) @as(usize, 4) else 3)];

        // Check for padding (all zeros)
        if (frame_id[0] == 0) break;

        var frame_size: u32 = undefined;
        if (version_major >= 4) {
            // ID3v2.4: syncsafe integer
            frame_size = (@as(u32, data[offset + 4] & 0x7F) << 21) |
                (@as(u32, data[offset + 5] & 0x7F) << 14) |
                (@as(u32, data[offset + 6] & 0x7F) << 7) |
                @as(u32, data[offset + 7] & 0x7F);
        } else if (version_major == 3) {
            // ID3v2.3: regular integer
            frame_size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .big);
        } else {
            // ID3v2.2: 3-byte size
            frame_size = (@as(u32, data[offset + 3]) << 16) |
                (@as(u32, data[offset + 4]) << 8) |
                @as(u32, data[offset + 5]);
        }

        offset += frame_header_size;

        if (offset + frame_size > data.len) break;

        const frame_data = data[offset .. offset + frame_size];

        // Parse known frames
        if (version_major >= 3) {
            if (std.mem.eql(u8, frame_id[0..4], "TIT2")) {
                parseTextFrame(frame_data, &meta.title, &meta.title_len);
            } else if (std.mem.eql(u8, frame_id[0..4], "TPE1")) {
                parseTextFrame(frame_data, &meta.artist, &meta.artist_len);
            } else if (std.mem.eql(u8, frame_id[0..4], "TALB")) {
                parseTextFrame(frame_data, &meta.album, &meta.album_len);
            } else if (std.mem.eql(u8, frame_id[0..4], "TYER") or std.mem.eql(u8, frame_id[0..4], "TDRC")) {
                var year_buf: [8]u8 = undefined;
                var year_len: u8 = 0;
                parseTextFrame(frame_data, &year_buf, &year_len);
                if (year_len >= 4) {
                    meta.year = parseYearString(year_buf[0..4]);
                }
            } else if (std.mem.eql(u8, frame_id[0..4], "TRCK")) {
                var track_buf: [8]u8 = undefined;
                var track_len: u8 = 0;
                parseTextFrame(frame_data, &track_buf, &track_len);
                if (track_len > 0) {
                    meta.track_number = parseTrackNumber(track_buf[0..track_len]);
                }
            } else if (std.mem.eql(u8, frame_id[0..4], "TCON")) {
                parseTextFrame(frame_data, &meta.genre, &meta.genre_len);
            } else if (std.mem.eql(u8, frame_id[0..4], "APIC")) {
                // Album art - just mark its presence and location
                meta.has_album_art = true;
                meta.album_art_offset = @intCast(offset);
                meta.album_art_size = frame_size;
            }
        }

        offset += frame_size;
    }

    return meta;
}

fn parseTextFrame(data: []const u8, out: []u8, out_len: *u8) void {
    if (data.len < 2) return;

    const encoding = data[0];
    const text_data = data[1..];

    switch (encoding) {
        0 => {
            // ISO-8859-1
            const text = trimNullAndSpace(text_data);
            const len = @min(text.len, out.len);
            @memcpy(out[0..len], text[0..len]);
            out_len.* = @intCast(len);
        },
        1 => {
            // UTF-16 with BOM
            if (text_data.len < 2) return;
            // Skip BOM and do simple conversion (ASCII only)
            var i: usize = 2;
            var j: usize = 0;
            while (i + 1 < text_data.len and j < out.len) {
                const c = text_data[i];
                if (c == 0 and text_data[i + 1] == 0) break;
                if (c < 128) {
                    out[j] = c;
                    j += 1;
                }
                i += 2;
            }
            out_len.* = @intCast(j);
        },
        3 => {
            // UTF-8
            const text = trimNullAndSpace(text_data);
            const len = @min(text.len, out.len);
            @memcpy(out[0..len], text[0..len]);
            out_len.* = @intCast(len);
        },
        else => {},
    }
}

// ============================================================
// FLAC Vorbis Comments
// ============================================================

/// Parse Vorbis comments from FLAC metadata
pub fn parseVorbisComments(data: []const u8) ?Metadata {
    if (data.len < 4) return null;

    // Check for FLAC marker
    if (!std.mem.eql(u8, data[0..4], "fLaC")) return null;

    var meta = Metadata{};
    var offset: usize = 4;

    // Parse metadata blocks
    while (offset + 4 <= data.len) {
        const block_header = data[offset];
        const is_last = (block_header & 0x80) != 0;
        const block_type = block_header & 0x7F;

        const block_size = (@as(u32, data[offset + 1]) << 16) |
            (@as(u32, data[offset + 2]) << 8) |
            @as(u32, data[offset + 3]);

        offset += 4;

        if (offset + block_size > data.len) break;

        if (block_type == 4) { // VORBIS_COMMENT
            parseVorbisCommentBlock(data[offset .. offset + block_size], &meta);
        } else if (block_type == 6) { // PICTURE
            meta.has_album_art = true;
            meta.album_art_offset = @intCast(offset);
            meta.album_art_size = block_size;
        }

        offset += block_size;

        if (is_last) break;
    }

    return meta;
}

fn parseVorbisCommentBlock(data: []const u8, meta: *Metadata) void {
    if (data.len < 8) return;

    // Vendor string length (little-endian)
    const vendor_len = std.mem.readInt(u32, data[0..4], .little);
    var offset: usize = 4 + vendor_len;

    if (offset + 4 > data.len) return;

    // Number of comments
    const comment_count = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    var i: u32 = 0;
    while (i < comment_count and offset + 4 <= data.len) : (i += 1) {
        const comment_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        if (offset + comment_len > data.len) break;

        const comment = data[offset .. offset + comment_len];
        parseVorbisComment(comment, meta);

        offset += comment_len;
    }
}

fn parseVorbisComment(comment: []const u8, meta: *Metadata) void {
    // Find '=' separator
    var eq_pos: ?usize = null;
    for (comment, 0..) |c, i| {
        if (c == '=') {
            eq_pos = i;
            break;
        }
    }

    if (eq_pos == null or eq_pos.? == 0) return;

    const key = comment[0..eq_pos.?];
    const value = comment[eq_pos.? + 1 ..];

    // Case-insensitive comparison
    if (eqlIgnoreCase(key, "TITLE")) {
        meta.setTitle(value);
    } else if (eqlIgnoreCase(key, "ARTIST")) {
        meta.setArtist(value);
    } else if (eqlIgnoreCase(key, "ALBUM")) {
        meta.setAlbum(value);
    } else if (eqlIgnoreCase(key, "DATE") or eqlIgnoreCase(key, "YEAR")) {
        if (value.len >= 4) {
            meta.year = parseYearString(value[0..4]);
        }
    } else if (eqlIgnoreCase(key, "TRACKNUMBER")) {
        meta.track_number = parseTrackNumber(value);
    } else if (eqlIgnoreCase(key, "DISCNUMBER")) {
        meta.disc_number = parseTrackNumber(value);
    } else if (eqlIgnoreCase(key, "GENRE")) {
        meta.setGenre(value);
    }
}

// ============================================================
// Utility Functions
// ============================================================

fn trimNullAndSpace(data: []const u8) []const u8 {
    var end = data.len;
    while (end > 0 and (data[end - 1] == 0 or data[end - 1] == ' ')) {
        end -= 1;
    }
    var start: usize = 0;
    while (start < end and (data[start] == 0 or data[start] == ' ')) {
        start += 1;
    }
    return data[start..end];
}

fn parseYearString(data: []const u8) u16 {
    if (data.len < 4) return 0;

    var year: u16 = 0;
    for (data[0..4]) |c| {
        if (c >= '0' and c <= '9') {
            year = year * 10 + (c - '0');
        } else {
            break;
        }
    }
    return year;
}

fn parseTrackNumber(data: []const u8) u8 {
    var num: u16 = 0;
    for (data) |c| {
        if (c >= '0' and c <= '9') {
            num = num * 10 + (c - '0');
            if (num > 255) return 255;
        } else if (c == '/') {
            break; // Stop at "track/total" separator
        }
    }
    return @intCast(num);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

// ID3v1 genre lookup table
fn getGenreName(id: u8) []const u8 {
    const genres = [_][]const u8{
        "Blues",        "Classic Rock", "Country",      "Dance",
        "Disco",        "Funk",         "Grunge",       "Hip-Hop",
        "Jazz",         "Metal",        "New Age",      "Oldies",
        "Other",        "Pop",          "R&B",          "Rap",
        "Reggae",       "Rock",         "Techno",       "Industrial",
        "Alternative",  "Ska",          "Death Metal",  "Pranks",
        "Soundtrack",   "Euro-Techno",  "Ambient",      "Trip-Hop",
        "Vocal",        "Jazz+Funk",    "Fusion",       "Trance",
        "Classical",    "Instrumental", "Acid",         "House",
        "Game",         "Sound Clip",   "Gospel",       "Noise",
        "AlternRock",   "Bass",         "Soul",         "Punk",
        "Space",        "Meditative",   "Instrum Pop",  "Instrum Rock",
        "Ethnic",       "Gothic",       "Darkwave",     "Techno-Indust",
        "Electronic",   "Pop-Folk",     "Eurodance",    "Dream",
        "Southern Rock", "Comedy",      "Cult",         "Gangsta",
        "Top 40",       "Christian Rap", "Pop/Funk",    "Jungle",
    };

    if (id < genres.len) {
        return genres[id];
    }
    return "Unknown";
}

// ============================================================
// High-Level Parser
// ============================================================

/// Parse metadata from any supported format
pub fn parse(data: []const u8) Metadata {
    // Try ID3v2 first (at beginning of file)
    if (parseId3v2(data)) |meta| {
        if (!meta.isEmpty()) return meta;
    }

    // Try Vorbis comments (FLAC)
    if (parseVorbisComments(data)) |meta| {
        if (!meta.isEmpty()) return meta;
    }

    // Try ID3v1 (at end of file)
    if (parseId3v1(data)) |meta| {
        if (!meta.isEmpty()) return meta;
    }

    // No metadata found
    return Metadata{};
}

// ============================================================
// Tests
// ============================================================

test "metadata set and get" {
    var meta = Metadata{};

    meta.setTitle("Test Song");
    try std.testing.expectEqualStrings("Test Song", meta.getTitle());

    meta.setArtist("Test Artist");
    try std.testing.expectEqualStrings("Test Artist", meta.getArtist());

    try std.testing.expect(!meta.isEmpty());

    meta.clear();
    try std.testing.expect(meta.isEmpty());
}

test "parse year string" {
    try std.testing.expectEqual(@as(u16, 2024), parseYearString("2024"));
    try std.testing.expectEqual(@as(u16, 1999), parseYearString("1999-01-15"));
    try std.testing.expectEqual(@as(u16, 0), parseYearString("abc"));
}

test "parse track number" {
    try std.testing.expectEqual(@as(u8, 5), parseTrackNumber("5"));
    try std.testing.expectEqual(@as(u8, 12), parseTrackNumber("12/24"));
    try std.testing.expectEqual(@as(u8, 0), parseTrackNumber(""));
}

test "trim null and space" {
    const result1 = trimNullAndSpace("  hello  ");
    try std.testing.expectEqualStrings("hello", result1);

    const result2 = trimNullAndSpace("test\x00\x00");
    try std.testing.expectEqualStrings("test", result2);
}

test "case insensitive equal" {
    try std.testing.expect(eqlIgnoreCase("TITLE", "title"));
    try std.testing.expect(eqlIgnoreCase("Artist", "ARTIST"));
    try std.testing.expect(!eqlIgnoreCase("foo", "bar"));
}

test "id3v1 parse" {
    // Create minimal ID3v1 tag
    var data: [128]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..3], "TAG");
    @memcpy(data[3..13], "Test Title");
    @memcpy(data[33..44], "Test Artist");
    @memcpy(data[63..73], "Test Album");
    @memcpy(data[93..97], "2024");
    data[125] = 0;
    data[126] = 5; // Track 5 (ID3v1.1)
    data[127] = 17; // Rock

    const meta = parseId3v1(&data);
    try std.testing.expect(meta != null);
    try std.testing.expectEqualStrings("Test Title", meta.?.getTitle());
    try std.testing.expectEqualStrings("Test Artist", meta.?.getArtist());
    try std.testing.expectEqual(@as(u16, 2024), meta.?.year);
    try std.testing.expectEqual(@as(u8, 5), meta.?.track_number);
}

test "genre lookup" {
    try std.testing.expectEqualStrings("Rock", getGenreName(17));
    try std.testing.expectEqualStrings("Blues", getGenreName(0));
    try std.testing.expectEqualStrings("Unknown", getGenreName(200));
}
