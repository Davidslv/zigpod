//! Embedded Art Extraction
//!
//! This module extracts album art from audio file metadata tags.
//!
//! # Complexity Guide for Future Engineers
//!
//! ## MP3 (ID3v2) - COMPLEXITY: MEDIUM (~150 lines)
//!
//! ID3v2 structure:
//! ```
//!   ┌──────────────┐
//!   │ ID3v2 Header │ 10 bytes: "ID3" + version + flags + size
//!   ├──────────────┤
//!   │ Frame 1      │ 10-byte header + data
//!   ├──────────────┤
//!   │ Frame 2      │ We're looking for "APIC" frame
//!   ├──────────────┤
//!   │ ...          │
//!   └──────────────┘
//! ```
//!
//! The APIC frame contains:
//! - Text encoding (1 byte)
//! - MIME type (null-terminated string)
//! - Picture type (1 byte: 0x03 = front cover)
//! - Description (null-terminated string)
//! - Image data (raw JPEG/PNG bytes)
//!
//! Gotchas:
//! - Size uses "sync-safe" integers (7 bits per byte, MSB always 0)
//! - Can have extended header (check flags)
//! - ID3v2.2 uses 3-byte frame IDs ("PIC" not "APIC")
//!
//! ## FLAC - COMPLEXITY: MEDIUM (~100 lines)
//!
//! FLAC structure:
//! ```
//!   ┌──────────────┐
//!   │ "fLaC"       │ 4-byte magic
//!   ├──────────────┤
//!   │ Metadata     │ Type + length + data
//!   │ Block 1      │
//!   ├──────────────┤
//!   │ Metadata     │ Type 6 = PICTURE
//!   │ Block 2      │
//!   ├──────────────┤
//!   │ ...          │ Last block has bit 7 set
//!   └──────────────┘
//! ```
//!
//! PICTURE block contains:
//! - Picture type (4 bytes, big-endian)
//! - MIME type length + MIME type
//! - Description length + description
//! - Width, height, depth, colors (16 bytes)
//! - Data length + image data
//!
//! ## M4A/AAC - COMPLEXITY: MEDIUM (~120 lines)
//!
//! M4A uses the MP4/QuickTime atom structure:
//! ```
//!   moov
//!    └── udta
//!         └── meta
//!              └── ilst
//!                   └── covr
//!                        └── data (image bytes)
//! ```
//!
//! Each atom has: 4-byte size + 4-byte type + data
//! The covr atom's data child contains raw image bytes.
//!

const std = @import("std");

// ============================================================
// Public API
// ============================================================

/// Extract embedded art from MP3 file (ID3v2 tag)
pub fn extractFromMp3(data: []const u8) ?[]const u8 {
    return parseId3v2(data);
}

/// Extract embedded art from FLAC file
pub fn extractFromFlac(data: []const u8) ?[]const u8 {
    return parseFlacPicture(data);
}

/// Extract embedded art from M4A/AAC file
pub fn extractFromM4a(data: []const u8) ?[]const u8 {
    return parseM4aCovr(data);
}

// ============================================================
// ID3v2 Parser (MP3)
// ============================================================
//
// Reference: https://id3.org/id3v2.3.0
//
// ID3v2 Header (10 bytes):
//   Bytes 0-2:   "ID3" magic
//   Byte 3:      Version major (e.g., 3 for ID3v2.3)
//   Byte 4:      Version minor
//   Byte 5:      Flags (bit 7: unsync, bit 6: extended header, bit 5: experimental)
//   Bytes 6-9:   Tag size (sync-safe integer, excludes header)
//
// Frame Header (10 bytes for ID3v2.3+, 6 bytes for ID3v2.2):
//   Bytes 0-3:   Frame ID (e.g., "APIC")
//   Bytes 4-7:   Frame size
//   Bytes 8-9:   Flags
//

fn parseId3v2(data: []const u8) ?[]const u8 {
    // Minimum size: 10-byte header + at least some frames
    if (data.len < 14) return null;

    // Check ID3v2 magic
    if (!std.mem.eql(u8, data[0..3], "ID3")) return null;

    const version_major = data[3];
    const flags = data[5];
    const tag_size = readSyncSafe(data[6..10]);

    // We support ID3v2.2, 2.3, and 2.4
    if (version_major < 2 or version_major > 4) return null;

    // Calculate start of frames
    var pos: usize = 10;

    // Skip extended header if present
    if (flags & 0x40 != 0) {
        if (pos + 4 > data.len) return null;
        const ext_size = if (version_major == 4)
            readSyncSafe(data[pos..][0..4])
        else
            readU32BE(data[pos..]);
        pos += ext_size;
    }

    const tag_end = @min(10 + tag_size, data.len);

    // Parse frames
    while (pos + 10 < tag_end) {
        // Check for padding (all zeros)
        if (data[pos] == 0) break;

        if (version_major == 2) {
            // ID3v2.2: 3-byte frame ID, 3-byte size
            if (pos + 6 > tag_end) break;

            const frame_id = data[pos..][0..3];
            const frame_size = (@as(usize, data[pos + 3]) << 16) |
                (@as(usize, data[pos + 4]) << 8) |
                @as(usize, data[pos + 5]);

            pos += 6;

            if (std.mem.eql(u8, frame_id, "PIC")) {
                return parsePicFrame(data[pos..@min(pos + frame_size, tag_end)], true);
            }

            pos += frame_size;
        } else {
            // ID3v2.3+: 4-byte frame ID, 4-byte size, 2-byte flags
            if (pos + 10 > tag_end) break;

            const frame_id = data[pos..][0..4];
            const frame_size = if (version_major == 4)
                readSyncSafe(data[pos + 4 ..][0..4])
            else
                readU32BE(data[pos + 4 ..]);

            pos += 10;

            if (std.mem.eql(u8, frame_id, "APIC")) {
                return parsePicFrame(data[pos..@min(pos + frame_size, tag_end)], false);
            }

            pos += frame_size;
        }
    }

    return null;
}

/// Parse APIC/PIC frame data to extract image
fn parsePicFrame(data: []const u8, is_v22: bool) ?[]const u8 {
    if (data.len < 4) return null;

    var pos: usize = 0;

    // Text encoding (1 byte)
    const encoding = data[pos];
    pos += 1;

    // MIME type
    if (is_v22) {
        // ID3v2.2: 3-byte image format (e.g., "JPG", "PNG")
        pos += 3;
    } else {
        // ID3v2.3+: null-terminated MIME string
        while (pos < data.len and data[pos] != 0) {
            pos += 1;
        }
        pos += 1; // Skip null terminator
    }

    if (pos >= data.len) return null;

    // Picture type (1 byte)
    // 0x03 = front cover, but we accept any type
    pos += 1;

    if (pos >= data.len) return null;

    // Description (null-terminated, encoding-dependent)
    if (encoding == 0 or encoding == 3) {
        // ISO-8859-1 or UTF-8: single null terminator
        while (pos < data.len and data[pos] != 0) {
            pos += 1;
        }
        pos += 1;
    } else {
        // UTF-16: double null terminator
        while (pos + 1 < data.len) {
            if (data[pos] == 0 and data[pos + 1] == 0) {
                pos += 2;
                break;
            }
            pos += 2;
        }
    }

    if (pos >= data.len) return null;

    // Remaining data is the image
    return data[pos..];
}

// ============================================================
// FLAC Parser
// ============================================================
//
// Reference: https://xiph.org/flac/format.html
//
// FLAC file structure:
//   Bytes 0-3:   "fLaC" magic
//   Then:        Metadata blocks until audio frames
//
// Metadata block header (4 bytes):
//   Bit 0 of byte 0:     Last block flag
//   Bits 1-7 of byte 0:  Block type (6 = PICTURE)
//   Bytes 1-3:           Block length (24 bits)
//
// PICTURE block:
//   Bytes 0-3:   Picture type (3 = front cover)
//   Bytes 4-7:   MIME type length
//   Then:        MIME type string
//   Next 4:      Description length
//   Then:        Description string
//   Next 16:     Width, height, color depth, colors (4 bytes each)
//   Next 4:      Data length
//   Then:        Image data
//

fn parseFlacPicture(data: []const u8) ?[]const u8 {
    // Check FLAC magic
    if (data.len < 8) return null;
    if (!std.mem.eql(u8, data[0..4], "fLaC")) return null;

    var pos: usize = 4;

    // Parse metadata blocks
    while (pos + 4 <= data.len) {
        const header = data[pos];
        const is_last = (header & 0x80) != 0;
        const block_type = header & 0x7F;
        const block_len = (@as(usize, data[pos + 1]) << 16) |
            (@as(usize, data[pos + 2]) << 8) |
            @as(usize, data[pos + 3]);

        pos += 4;

        if (pos + block_len > data.len) return null;

        if (block_type == 6) {
            // PICTURE block
            return parseFlacPictureBlock(data[pos..][0..block_len]);
        }

        pos += block_len;

        if (is_last) break;
    }

    return null;
}

fn parseFlacPictureBlock(data: []const u8) ?[]const u8 {
    if (data.len < 32) return null;

    var pos: usize = 0;

    // Picture type (4 bytes) - we accept any type
    pos += 4;

    // MIME type
    const mime_len = readU32BE(data[pos..]);
    pos += 4;
    if (pos + mime_len > data.len) return null;
    pos += mime_len;

    // Description
    if (pos + 4 > data.len) return null;
    const desc_len = readU32BE(data[pos..]);
    pos += 4;
    if (pos + desc_len > data.len) return null;
    pos += desc_len;

    // Width, height, color depth, colors (16 bytes total)
    if (pos + 16 > data.len) return null;
    pos += 16;

    // Data length
    if (pos + 4 > data.len) return null;
    const data_len = readU32BE(data[pos..]);
    pos += 4;

    if (pos + data_len > data.len) return null;

    return data[pos..][0..data_len];
}

// ============================================================
// M4A/AAC Parser
// ============================================================
//
// Reference: ISO/IEC 14496-12 (ISO Base Media File Format)
//
// M4A files use the QuickTime/MP4 atom structure.
// Each atom: 4-byte size + 4-byte type + data
// If size == 1, extended 64-bit size follows.
// If size == 0, atom extends to end of file.
//
// Cover art path:
//   moov → udta → meta → ilst → covr → data
//
// The "data" atom has:
//   Bytes 0-3:   Type indicator (13 = JPEG, 14 = PNG)
//   Bytes 4-7:   Locale (usually 0)
//   Bytes 8+:    Image data
//

fn parseM4aCovr(data: []const u8) ?[]const u8 {
    // Find moov atom
    const moov = findAtom(data, "moov") orelse return null;

    // Find udta inside moov
    const udta = findAtom(moov, "udta") orelse return null;

    // Find meta inside udta
    const meta_full = findAtom(udta, "meta") orelse return null;

    // meta has 4-byte version/flags before children
    if (meta_full.len < 4) return null;
    const meta = meta_full[4..];

    // Find ilst inside meta
    const ilst = findAtom(meta, "ilst") orelse return null;

    // Find covr inside ilst
    const covr = findAtom(ilst, "covr") orelse return null;

    // Find data inside covr
    const art_data = findAtom(covr, "data") orelse return null;

    // Skip type indicator and locale (8 bytes)
    if (art_data.len < 8) return null;

    return art_data[8..];
}

/// Find an atom in a container, returning its data (excluding header)
fn findAtom(data: []const u8, atom_type: *const [4]u8) ?[]const u8 {
    var pos: usize = 0;

    while (pos + 8 <= data.len) {
        var size = readU32BE(data[pos..]);
        const atype = data[pos + 4 ..][0..4];

        var header_size: usize = 8;

        // Handle extended size
        if (size == 1 and pos + 16 <= data.len) {
            // 64-bit size (rare, skip for simplicity)
            size = @intCast(readU32BE(data[pos + 12 ..]));
            header_size = 16;
        } else if (size == 0) {
            // Extends to end of data
            size = @intCast(data.len - pos);
        }

        if (size < header_size) return null;
        if (pos + size > data.len) return null;

        if (std.mem.eql(u8, atype, atom_type)) {
            return data[pos + header_size .. pos + size];
        }

        pos += size;
    }

    return null;
}

// ============================================================
// Utility Functions
// ============================================================

/// Read sync-safe integer (7 bits per byte)
/// Used in ID3v2 to avoid false sync patterns
fn readSyncSafe(data: *const [4]u8) usize {
    return (@as(usize, data[0] & 0x7F) << 21) |
        (@as(usize, data[1] & 0x7F) << 14) |
        (@as(usize, data[2] & 0x7F) << 7) |
        @as(usize, data[3] & 0x7F);
}

fn readU32BE(data: []const u8) u32 {
    return (@as(u32, data[0]) << 24) |
        (@as(u32, data[1]) << 16) |
        (@as(u32, data[2]) << 8) |
        @as(u32, data[3]);
}

// ============================================================
// Tests
// ============================================================

test "readSyncSafe" {
    // Example: 0x00 0x00 0x02 0x01 = 257
    const data = [_]u8{ 0x00, 0x00, 0x02, 0x01 };
    try std.testing.expectEqual(@as(usize, 257), readSyncSafe(&data));

    // Maximum sync-safe value for 4 bytes
    const max = [_]u8{ 0x7F, 0x7F, 0x7F, 0x7F };
    try std.testing.expectEqual(@as(usize, 0x0FFFFFFF), readSyncSafe(&max));
}

test "readU32BE" {
    const data = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    try std.testing.expectEqual(@as(u32, 0x00010203), readU32BE(&data));
}

test "id3v2 detection" {
    // Valid ID3v2.3 header (no art)
    const header = [_]u8{
        'I', 'D', '3', // Magic
        3,   0, // Version 2.3.0
        0, // Flags
        0,   0, 0, 10, // Size: 10 bytes (sync-safe)
    };

    // Should not crash, just return null (no APIC frame)
    const result = parseId3v2(&header);
    try std.testing.expect(result == null);
}

test "flac detection" {
    // Valid FLAC header (no picture block)
    const header = [_]u8{
        'f', 'L', 'a', 'C', // Magic
        0x80, // Last block, type 0 (STREAMINFO)
        0,    0, 34, // Length: 34 bytes
    } ++ [_]u8{0} ** 34;

    // Should not crash, just return null (no PICTURE block)
    const result = parseFlacPicture(&header);
    try std.testing.expect(result == null);
}

test "findAtom" {
    // Simple atom structure
    const atoms = [_]u8{
        // First atom: type "test", 16 bytes total
        0, 0, 0, 16, // Size
        't', 'e', 's', 't', // Type
        1, 2, 3, 4, 5, 6, 7, 8, // Data (8 bytes)
        // Second atom: type "find", 12 bytes total
        0, 0, 0, 12, // Size
        'f', 'i', 'n', 'd', // Type
        0xAA, 0xBB, 0xCC, 0xDD, // Data (4 bytes)
    };

    const found = findAtom(&atoms, "find");
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(usize, 4), found.?.len);
    try std.testing.expectEqual(@as(u8, 0xAA), found.?[0]);
}
