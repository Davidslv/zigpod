//! ID3 Tag Parser
//!
//! Parses ID3v1 and ID3v2 tags from MP3 files to extract metadata.
//! Supports:
//! - ID3v1 (128 bytes at end of file)
//! - ID3v1.1 (with track number)
//! - ID3v2.2, ID3v2.3, ID3v2.4 (at beginning of file)
//!
//! Extracts:
//! - Title (TIT2/TT2)
//! - Artist (TPE1/TP1)
//! - Album (TALB/TAL)
//! - Year (TYER/TYE/TDRC)
//! - Track number (TRCK/TRK)
//! - Genre (TCON/TCO)

const std = @import("std");

// ============================================================
// Tag Metadata Structure
// ============================================================

/// Parsed ID3 tag metadata
pub const Id3Metadata = struct {
    title: [128]u8 = [_]u8{0} ** 128,
    title_len: u8 = 0,
    artist: [128]u8 = [_]u8{0} ** 128,
    artist_len: u8 = 0,
    album: [128]u8 = [_]u8{0} ** 128,
    album_len: u8 = 0,
    year: [8]u8 = [_]u8{0} ** 8,
    year_len: u8 = 0,
    track: u8 = 0,
    genre: u8 = 0xFF, // 0xFF = unknown

    pub fn getTitle(self: *const Id3Metadata) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn getArtist(self: *const Id3Metadata) []const u8 {
        return self.artist[0..self.artist_len];
    }

    pub fn getAlbum(self: *const Id3Metadata) []const u8 {
        return self.album[0..self.album_len];
    }

    pub fn getYear(self: *const Id3Metadata) []const u8 {
        return self.year[0..self.year_len];
    }

    pub fn hasMetadata(self: *const Id3Metadata) bool {
        return self.title_len > 0 or self.artist_len > 0 or self.album_len > 0;
    }
};

// ============================================================
// ID3v2 Header Parsing
// ============================================================

/// ID3v2 header structure
const Id3v2Header = struct {
    version_major: u8,
    version_minor: u8,
    flags: u8,
    size: u32,

    fn hasExtendedHeader(self: Id3v2Header) bool {
        return (self.flags & 0x40) != 0;
    }

    fn isUnsynchronized(self: Id3v2Header) bool {
        return (self.flags & 0x80) != 0;
    }

    fn hasFooter(self: Id3v2Header) bool {
        return (self.flags & 0x10) != 0;
    }
};

/// Parse ID3v2 header
fn parseId3v2Header(data: []const u8) ?Id3v2Header {
    if (data.len < 10) return null;
    if (!std.mem.eql(u8, data[0..3], "ID3")) return null;

    const version_major = data[3];
    const version_minor = data[4];

    // Validate version (2.2, 2.3, or 2.4)
    if (version_major < 2 or version_major > 4) return null;

    const flags = data[5];

    // Parse syncsafe size (7 bits per byte)
    var size: u32 = 0;
    size |= @as(u32, data[6] & 0x7F) << 21;
    size |= @as(u32, data[7] & 0x7F) << 14;
    size |= @as(u32, data[8] & 0x7F) << 7;
    size |= @as(u32, data[9] & 0x7F);

    return Id3v2Header{
        .version_major = version_major,
        .version_minor = version_minor,
        .flags = flags,
        .size = size,
    };
}

// ============================================================
// ID3v2 Frame Parsing
// ============================================================

/// ID3v2 frame structure
const Id3v2Frame = struct {
    id: [4]u8,
    size: u32,
    flags: u16,
    data_offset: usize,
};

/// Parse ID3v2.3/2.4 frame header
fn parseFrameHeader(data: []const u8, version: u8) ?Id3v2Frame {
    if (version == 2) {
        // ID3v2.2 uses 3-byte frame IDs and sizes
        if (data.len < 6) return null;

        var id: [4]u8 = undefined;
        id[0] = data[0];
        id[1] = data[1];
        id[2] = data[2];
        id[3] = 0;

        // Check for padding
        if (id[0] == 0) return null;

        const size = (@as(u32, data[3]) << 16) | (@as(u32, data[4]) << 8) | data[5];

        return Id3v2Frame{
            .id = id,
            .size = size,
            .flags = 0,
            .data_offset = 6,
        };
    } else {
        // ID3v2.3/2.4 uses 4-byte frame IDs
        if (data.len < 10) return null;

        var id: [4]u8 = undefined;
        @memcpy(&id, data[0..4]);

        // Check for padding
        if (id[0] == 0) return null;

        var size: u32 = undefined;
        if (version == 4) {
            // ID3v2.4 uses syncsafe size
            size = @as(u32, data[4] & 0x7F) << 21 |
                @as(u32, data[5] & 0x7F) << 14 |
                @as(u32, data[6] & 0x7F) << 7 |
                @as(u32, data[7] & 0x7F);
        } else {
            // ID3v2.3 uses normal size
            size = std.mem.readInt(u32, data[4..8], .big);
        }

        const flags = std.mem.readInt(u16, data[8..10], .big);

        return Id3v2Frame{
            .id = id,
            .size = size,
            .flags = flags,
            .data_offset = 10,
        };
    }
}

/// Decode text frame content
fn decodeTextFrame(data: []const u8, out: []u8) u8 {
    if (data.len == 0) return 0;

    const encoding = data[0];
    var text_data = data[1..];

    // Handle BOM and encoding
    switch (encoding) {
        0x00 => {
            // ISO-8859-1 (Latin-1) - copy directly
            return copyTrimmedString(text_data, out);
        },
        0x01 => {
            // UTF-16 with BOM
            if (text_data.len >= 2) {
                const bom = std.mem.readInt(u16, text_data[0..2], .little);
                if (bom == 0xFEFF or bom == 0xFFFE) {
                    text_data = text_data[2..];
                }
            }
            return decodeUtf16(text_data, out);
        },
        0x02 => {
            // UTF-16BE without BOM
            return decodeUtf16Be(text_data, out);
        },
        0x03 => {
            // UTF-8
            return copyTrimmedString(text_data, out);
        },
        else => {
            // Unknown encoding, try as ISO-8859-1
            return copyTrimmedString(text_data, out);
        },
    }
}

/// Copy string, trimming nulls and whitespace
fn copyTrimmedString(src: []const u8, dst: []u8) u8 {
    var len: usize = 0;
    for (src) |c| {
        if (c == 0) break;
        if (len < dst.len) {
            dst[len] = c;
            len += 1;
        }
    }

    // Trim trailing whitespace
    while (len > 0 and (dst[len - 1] == ' ' or dst[len - 1] == '\t')) {
        len -= 1;
    }

    return @intCast(len);
}

/// Decode UTF-16LE to ASCII (simple conversion)
fn decodeUtf16(src: []const u8, dst: []u8) u8 {
    var len: usize = 0;
    var i: usize = 0;

    while (i + 1 < src.len and len < dst.len) {
        const lo = src[i];
        const hi = src[i + 1];

        // Skip null terminator
        if (lo == 0 and hi == 0) break;

        // Simple ASCII conversion (ignore high byte for non-ASCII)
        if (hi == 0 and lo >= 0x20 and lo < 0x7F) {
            dst[len] = lo;
            len += 1;
        } else if (lo >= 0x20 and lo < 0x7F) {
            dst[len] = lo;
            len += 1;
        }

        i += 2;
    }

    return @intCast(len);
}

/// Decode UTF-16BE to ASCII
fn decodeUtf16Be(src: []const u8, dst: []u8) u8 {
    var len: usize = 0;
    var i: usize = 0;

    while (i + 1 < src.len and len < dst.len) {
        const hi = src[i];
        const lo = src[i + 1];

        if (lo == 0 and hi == 0) break;

        if (hi == 0 and lo >= 0x20 and lo < 0x7F) {
            dst[len] = lo;
            len += 1;
        }

        i += 2;
    }

    return @intCast(len);
}

// ============================================================
// ID3v1 Parsing
// ============================================================

/// Parse ID3v1 tag (128 bytes at end of file)
fn parseId3v1(data: []const u8, meta: *Id3Metadata) bool {
    if (data.len < 128) return false;

    const tag_offset = data.len - 128;
    const tag = data[tag_offset..];

    // Check for "TAG" identifier
    if (!std.mem.eql(u8, tag[0..3], "TAG")) return false;

    // Title (30 bytes)
    meta.title_len = copyTrimmedString(tag[3..33], &meta.title);

    // Artist (30 bytes)
    meta.artist_len = copyTrimmedString(tag[33..63], &meta.artist);

    // Album (30 bytes)
    meta.album_len = copyTrimmedString(tag[63..93], &meta.album);

    // Year (4 bytes)
    meta.year_len = copyTrimmedString(tag[93..97], &meta.year);

    // Check for ID3v1.1 track number
    if (tag[125] == 0 and tag[126] != 0) {
        meta.track = tag[126];
    }

    // Genre
    meta.genre = tag[127];

    return true;
}

// ============================================================
// Main Parse Function
// ============================================================

/// Parse ID3 tags from MP3 file data
/// Tries ID3v2 first (at beginning), then falls back to ID3v1 (at end)
pub fn parse(data: []const u8) Id3Metadata {
    var meta = Id3Metadata{};

    // Try ID3v2 first (preferred, more detailed)
    if (parseId3v2Header(data)) |header| {
        var offset: usize = 10;

        // Skip extended header if present
        if (header.hasExtendedHeader() and offset + 4 <= data.len) {
            const ext_size = if (header.version_major == 4)
                (@as(u32, data[offset] & 0x7F) << 21) |
                    (@as(u32, data[offset + 1] & 0x7F) << 14) |
                    (@as(u32, data[offset + 2] & 0x7F) << 7) |
                    @as(u32, data[offset + 3] & 0x7F)
            else
                std.mem.readInt(u32, data[offset..][0..4], .big);
            offset += ext_size;
        }

        // Parse frames
        const tag_end = @min(10 + header.size, data.len);
        const frame_header_size: usize = if (header.version_major == 2) 6 else 10;

        while (offset + frame_header_size <= tag_end) {
            const frame = parseFrameHeader(data[offset..], header.version_major) orelse break;

            if (frame.size == 0) break;

            const frame_data_start = offset + frame.data_offset;
            const frame_data_end = @min(frame_data_start + frame.size, data.len);

            if (frame_data_start < frame_data_end) {
                const frame_data = data[frame_data_start..frame_data_end];

                // Map frame IDs (ID3v2.2 uses 3-char, v2.3/v2.4 uses 4-char)
                const is_title = std.mem.eql(u8, frame.id[0..4], "TIT2") or std.mem.eql(u8, frame.id[0..3], "TT2");
                const is_artist = std.mem.eql(u8, frame.id[0..4], "TPE1") or std.mem.eql(u8, frame.id[0..3], "TP1");
                const is_album = std.mem.eql(u8, frame.id[0..4], "TALB") or std.mem.eql(u8, frame.id[0..3], "TAL");
                const is_year = std.mem.eql(u8, frame.id[0..4], "TYER") or
                    std.mem.eql(u8, frame.id[0..4], "TDRC") or
                    std.mem.eql(u8, frame.id[0..3], "TYE");
                const is_track = std.mem.eql(u8, frame.id[0..4], "TRCK") or std.mem.eql(u8, frame.id[0..3], "TRK");

                if (is_title and meta.title_len == 0) {
                    meta.title_len = decodeTextFrame(frame_data, &meta.title);
                } else if (is_artist and meta.artist_len == 0) {
                    meta.artist_len = decodeTextFrame(frame_data, &meta.artist);
                } else if (is_album and meta.album_len == 0) {
                    meta.album_len = decodeTextFrame(frame_data, &meta.album);
                } else if (is_year and meta.year_len == 0) {
                    meta.year_len = decodeTextFrame(frame_data, &meta.year);
                } else if (is_track and meta.track == 0) {
                    var track_buf: [16]u8 = undefined;
                    const track_len = decodeTextFrame(frame_data, &track_buf);
                    if (track_len > 0) {
                        // Parse track number (may be "NN" or "NN/MM")
                        var track_num: u8 = 0;
                        for (track_buf[0..track_len]) |c| {
                            if (c >= '0' and c <= '9') {
                                track_num = track_num * 10 + (c - '0');
                            } else {
                                break;
                            }
                        }
                        meta.track = track_num;
                    }
                }
            }

            offset += frame.data_offset + frame.size;
        }

        // If we got metadata from ID3v2, we're done
        if (meta.hasMetadata()) {
            return meta;
        }
    }

    // Fall back to ID3v1
    _ = parseId3v1(data, &meta);

    return meta;
}

/// Get the size of the ID3v2 header (for skipping)
pub fn getHeaderSize(data: []const u8) usize {
    if (parseId3v2Header(data)) |header| {
        var size: usize = 10 + header.size;
        if (header.hasFooter()) size += 10;
        return size;
    }
    return 0;
}

// ============================================================
// Tests
// ============================================================

test "parse ID3v1 tag" {
    // Create a minimal ID3v1 tag
    var data: [128]u8 = [_]u8{0} ** 128;
    data[0] = 'T';
    data[1] = 'A';
    data[2] = 'G';
    // Title at offset 3
    @memcpy(data[3..13], "Test Title");
    // Artist at offset 33
    @memcpy(data[33..44], "Test Artist");
    // Album at offset 63
    @memcpy(data[63..73], "Test Album");
    // Year at offset 93
    @memcpy(data[93..97], "2024");
    // Track (ID3v1.1)
    data[125] = 0;
    data[126] = 5;

    var meta = Id3Metadata{};
    try std.testing.expect(parseId3v1(&data, &meta));
    try std.testing.expectEqualStrings("Test Title", meta.getTitle());
    try std.testing.expectEqualStrings("Test Artist", meta.getArtist());
    try std.testing.expectEqualStrings("Test Album", meta.getAlbum());
    try std.testing.expectEqualStrings("2024", meta.getYear());
    try std.testing.expectEqual(@as(u8, 5), meta.track);
}

test "parse ID3v2 header" {
    const header_data = [_]u8{
        'I', 'D', '3', // ID3 identifier
        0x04, 0x00, // Version 2.4.0
        0x00, // Flags
        0x00, 0x00, 0x02, 0x00, // Size = 256 (syncsafe)
    };

    const header = parseId3v2Header(&header_data);
    try std.testing.expect(header != null);
    try std.testing.expectEqual(@as(u8, 4), header.?.version_major);
    try std.testing.expectEqual(@as(u32, 256), header.?.size);
}

test "decode text frame ISO-8859-1" {
    const frame = [_]u8{ 0x00, 'H', 'e', 'l', 'l', 'o', 0 };
    var out: [32]u8 = undefined;
    const len = decodeTextFrame(&frame, &out);
    try std.testing.expectEqualStrings("Hello", out[0..len]);
}

test "decode text frame UTF-8" {
    const frame = [_]u8{ 0x03, 'H', 'e', 'l', 'l', 'o', 0 };
    var out: [32]u8 = undefined;
    const len = decodeTextFrame(&frame, &out);
    try std.testing.expectEqualStrings("Hello", out[0..len]);
}
