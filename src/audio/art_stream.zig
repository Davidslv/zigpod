//! Stream-Based Art Extraction
//!
//! This module provides memory-efficient streaming extraction of album art
//! from audio files. Instead of loading entire files into RAM, it streams
//! through the file to locate art data, then reads only the necessary bytes.
//!
//! # Complexity: MEDIUM (~200 lines)
//!
//! # Memory Efficiency
//!
//! Traditional approach:
//!   - Load 500KB file into RAM
//!   - Parse to find 50KB art
//!   - Peak RAM: 500KB
//!
//! Stream approach:
//!   - Read 8KB chunks sequentially
//!   - Parse headers to find art location
//!   - Seek to art, read only art bytes
//!   - Peak RAM: 8KB + art size (~58KB for 50KB art)
//!
//! This reduces peak RAM usage by ~8x for typical files.
//!
//! # Architecture
//!
//! ```
//!   File on FAT32
//!        │
//!        ▼
//!   ┌─────────────┐
//!   │ StreamReader│  8KB sliding window
//!   └─────────────┘
//!        │
//!        ▼
//!   ┌─────────────┐
//!   │ HeaderParse │  Find art offset/size in first pass
//!   └─────────────┘
//!        │
//!        ▼
//!   ┌─────────────┐
//!   │ SeekAndRead │  Read only art bytes
//!   └─────────────┘
//!        │
//!        ▼
//!   Art data (minimal RAM)
//! ```

const std = @import("std");
const fat32 = @import("../drivers/storage/fat32.zig");

// ============================================================
// Constants
// ============================================================

/// Stream buffer size (8KB - balance between RAM and I/O efficiency)
pub const STREAM_BUFFER_SIZE: usize = 8 * 1024;

/// Maximum art size we'll extract (500KB)
pub const MAX_ART_SIZE: usize = 500 * 1024;

// ============================================================
// Art Location Info
// ============================================================

/// Information about located art within a file
pub const ArtLocation = struct {
    /// Byte offset from start of file
    offset: usize,
    /// Size of art data in bytes
    size: usize,
    /// Detected image format
    format: ImageFormat,

    pub const ImageFormat = enum {
        jpeg,
        png,
        bmp,
        unknown,
    };
};

// ============================================================
// Stream Extraction API
// ============================================================

/// Extract art from MP3 file using streaming
/// Returns art location info, or null if no art found
pub fn locateArtInMp3(path: []const u8) ?ArtLocation {
    var buffer: [STREAM_BUFFER_SIZE]u8 = undefined;

    // Read first chunk to parse ID3v2 header
    const first_read = fat32.readFileAt(path, 0, &buffer) catch return null;
    if (first_read < 14) return null;

    const data = buffer[0..first_read];

    // Check ID3v2 magic
    if (!std.mem.eql(u8, data[0..3], "ID3")) return null;

    const version_major = data[3];
    const flags = data[5];
    const tag_size = readSyncSafe(data[6..10]);

    if (version_major < 2 or version_major > 4) return null;

    // Calculate frame parsing start
    var pos: usize = 10;

    // Skip extended header if present
    if (flags & 0x40 != 0) {
        if (pos + 4 > first_read) return null;
        const ext_size = if (version_major == 4)
            readSyncSafe(data[pos..][0..4])
        else
            readU32BE(data[pos..]);
        pos += ext_size;
    }

    const tag_end = 10 + tag_size;

    // Scan frames looking for APIC/PIC
    while (pos + 10 < @min(tag_end, first_read)) {
        if (data[pos] == 0) break; // Padding

        if (version_major == 2) {
            // ID3v2.2: 3-byte frame ID, 3-byte size
            const frame_id = data[pos..][0..3];
            const frame_size = (@as(usize, data[pos + 3]) << 16) |
                (@as(usize, data[pos + 4]) << 8) |
                @as(usize, data[pos + 5]);

            if (std.mem.eql(u8, frame_id, "PIC")) {
                return locateApicData(data[pos + 6 ..], pos + 6, frame_size, true);
            }

            pos += 6 + frame_size;
        } else {
            // ID3v2.3+: 4-byte frame ID, 4-byte size, 2-byte flags
            if (pos + 10 > first_read) break;

            const frame_id = data[pos..][0..4];
            const frame_size = if (version_major == 4)
                readSyncSafe(data[pos + 4 ..][0..4])
            else
                readU32BE(data[pos + 4 ..]);

            if (std.mem.eql(u8, frame_id, "APIC")) {
                return locateApicData(data[pos + 10 ..], pos + 10, frame_size, false);
            }

            pos += 10 + frame_size;
        }
    }

    return null;
}

/// Locate actual image data within APIC frame
fn locateApicData(frame_data: []const u8, base_offset: usize, frame_size: usize, is_v22: bool) ?ArtLocation {
    if (frame_data.len < 4) return null;

    var pos: usize = 0;

    // Text encoding (1 byte)
    const encoding = frame_data[pos];
    pos += 1;

    // MIME type
    if (is_v22) {
        pos += 3; // 3-byte image format
    } else {
        while (pos < frame_data.len and frame_data[pos] != 0) {
            pos += 1;
        }
        pos += 1; // Skip null
    }

    if (pos >= frame_data.len) return null;

    // Picture type (1 byte)
    pos += 1;

    // Description
    if (encoding == 0 or encoding == 3) {
        while (pos < frame_data.len and frame_data[pos] != 0) {
            pos += 1;
        }
        pos += 1;
    } else {
        while (pos + 1 < frame_data.len) {
            if (frame_data[pos] == 0 and frame_data[pos + 1] == 0) {
                pos += 2;
                break;
            }
            pos += 2;
        }
    }

    if (pos >= frame_size) return null;

    const art_size = frame_size - pos;
    if (art_size > MAX_ART_SIZE or art_size < 4) return null;

    // Detect image format from magic bytes
    const format = detectImageFormat(frame_data[pos..]);

    return ArtLocation{
        .offset = base_offset + pos,
        .size = art_size,
        .format = format,
    };
}

/// Extract art from FLAC file using streaming
pub fn locateArtInFlac(path: []const u8) ?ArtLocation {
    var buffer: [STREAM_BUFFER_SIZE]u8 = undefined;

    const first_read = fat32.readFileAt(path, 0, &buffer) catch return null;
    if (first_read < 8) return null;

    const data = buffer[0..first_read];

    // Check FLAC magic
    if (!std.mem.eql(u8, data[0..4], "fLaC")) return null;

    var pos: usize = 4;

    // Parse metadata blocks
    while (pos + 4 <= first_read) {
        const header = data[pos];
        const is_last = (header & 0x80) != 0;
        const block_type = header & 0x7F;
        const block_len = (@as(usize, data[pos + 1]) << 16) |
            (@as(usize, data[pos + 2]) << 8) |
            @as(usize, data[pos + 3]);

        pos += 4;

        if (block_type == 6) {
            // PICTURE block - parse to find image data offset
            if (pos + 32 <= first_read) {
                return locateFlacPictureData(data[pos..], pos, block_len);
            }
        }

        pos += block_len;

        if (is_last) break;
    }

    return null;
}

fn locateFlacPictureData(block_data: []const u8, base_offset: usize, block_len: usize) ?ArtLocation {
    if (block_data.len < 32) return null;

    var pos: usize = 0;

    // Picture type (4 bytes)
    pos += 4;

    // MIME type
    if (pos + 4 > block_data.len) return null;
    const mime_len = readU32BE(block_data[pos..]);
    pos += 4 + mime_len;

    // Description
    if (pos + 4 > block_data.len) return null;
    const desc_len = readU32BE(block_data[pos..]);
    pos += 4 + desc_len;

    // Width, height, color depth, colors (16 bytes)
    pos += 16;

    // Data length
    if (pos + 4 > block_data.len) return null;
    const data_len = readU32BE(block_data[pos..]);
    pos += 4;

    if (data_len > MAX_ART_SIZE or data_len < 4) return null;
    if (pos + data_len > block_len) return null;

    // Detect format
    const format = if (pos + 4 <= block_data.len)
        detectImageFormat(block_data[pos..])
    else
        .unknown;

    return ArtLocation{
        .offset = base_offset + pos,
        .size = data_len,
        .format = format,
    };
}

/// Extract art from M4A file using streaming
pub fn locateArtInM4a(path: []const u8) ?ArtLocation {
    var buffer: [STREAM_BUFFER_SIZE]u8 = undefined;

    // M4A requires traversing atom tree: moov -> udta -> meta -> ilst -> covr -> data
    // This is more complex - we need to track positions

    const first_read = fat32.readFileAt(path, 0, &buffer) catch return null;
    if (first_read < 8) return null;

    // Find moov atom
    const file_pos: usize = 0;
    const moov_offset = findAtomOffset(path, &buffer, file_pos, first_read, "moov") orelse return null;

    // Read moov contents
    const moov_read = fat32.readFileAt(path, moov_offset.data_start, &buffer) catch return null;
    if (moov_read < 8) return null;

    // Find udta in moov
    const udta_offset = findAtomInBuffer(buffer[0..moov_read], "udta") orelse return null;

    // Find meta in udta
    const meta_start = udta_offset + 8;
    if (meta_start + 12 > moov_read) return null;

    const meta_offset = findAtomInBuffer(buffer[meta_start..moov_read], "meta") orelse return null;

    // meta has 4-byte version/flags
    const ilst_start = meta_start + meta_offset + 8 + 4;
    if (ilst_start + 8 > moov_read) return null;

    const ilst_offset = findAtomInBuffer(buffer[ilst_start..moov_read], "ilst") orelse return null;

    // Find covr in ilst
    const covr_start = ilst_start + ilst_offset + 8;
    if (covr_start + 8 > moov_read) return null;

    const covr_offset = findAtomInBuffer(buffer[covr_start..moov_read], "covr") orelse return null;

    // Find data in covr
    const data_start = covr_start + covr_offset + 8;
    if (data_start + 16 > moov_read) return null;

    const data_offset = findAtomInBuffer(buffer[data_start..moov_read], "data") orelse return null;

    // data atom: 4 bytes size, 4 bytes "data", 4 bytes type, 4 bytes locale, then image
    const art_start = data_start + data_offset + 16; // Skip header + type + locale
    const atom_size = readU32BE(buffer[data_start + data_offset ..]);
    const art_size = atom_size - 16;

    if (art_size > MAX_ART_SIZE or art_size < 4) return null;

    // Detect format
    const format = if (art_start + 4 <= moov_read)
        detectImageFormat(buffer[art_start..])
    else
        .unknown;

    return ArtLocation{
        .offset = moov_offset.data_start + art_start,
        .size = art_size,
        .format = format,
    };
}

const AtomInfo = struct {
    data_start: usize, // Absolute file offset of atom data
    size: usize,
};

fn findAtomOffset(path: []const u8, buffer: []u8, start: usize, buffer_len: usize, atom_type: *const [4]u8) ?AtomInfo {
    _ = path;
    var pos: usize = start;

    while (pos + 8 <= buffer_len) {
        const size = readU32BE(buffer[pos..]);
        const atype = buffer[pos + 4 ..][0..4];

        if (size < 8) return null;

        if (std.mem.eql(u8, atype, atom_type)) {
            return AtomInfo{
                .data_start = pos + 8,
                .size = size - 8,
            };
        }

        pos += size;
    }

    return null;
}

fn findAtomInBuffer(data: []const u8, atom_type: *const [4]u8) ?usize {
    var pos: usize = 0;

    while (pos + 8 <= data.len) {
        const size = readU32BE(data[pos..]);
        const atype = data[pos + 4 ..][0..4];

        if (size < 8) return null;
        if (pos + size > data.len) return null;

        if (std.mem.eql(u8, atype, atom_type)) {
            return pos;
        }

        pos += size;
    }

    return null;
}

// ============================================================
// Read Art Data
// ============================================================

/// Read art data from file at specified location into buffer
/// This is called after locateArt* finds the art
pub fn readArtData(path: []const u8, location: ArtLocation, buffer: []u8) ?[]u8 {
    if (buffer.len < location.size) return null;

    const bytes_read = fat32.readFileAt(path, location.offset, buffer[0..location.size]) catch return null;
    if (bytes_read != location.size) return null;

    return buffer[0..location.size];
}

// ============================================================
// Utility Functions
// ============================================================

fn detectImageFormat(data: []const u8) ArtLocation.ImageFormat {
    if (data.len < 4) return .unknown;

    // JPEG: FF D8 FF
    if (data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
        return .jpeg;
    }

    // PNG: 89 50 4E 47
    if (data[0] == 0x89 and data[1] == 'P' and data[2] == 'N' and data[3] == 'G') {
        return .png;
    }

    // BMP: 42 4D
    if (data[0] == 'B' and data[1] == 'M') {
        return .bmp;
    }

    return .unknown;
}

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

test "detectImageFormat" {
    // JPEG
    const jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 };
    try std.testing.expectEqual(ArtLocation.ImageFormat.jpeg, detectImageFormat(&jpeg));

    // PNG
    const png = [_]u8{ 0x89, 'P', 'N', 'G' };
    try std.testing.expectEqual(ArtLocation.ImageFormat.png, detectImageFormat(&png));

    // BMP
    const bmp = [_]u8{ 'B', 'M', 0, 0 };
    try std.testing.expectEqual(ArtLocation.ImageFormat.bmp, detectImageFormat(&bmp));

    // Unknown
    const unknown = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectEqual(ArtLocation.ImageFormat.unknown, detectImageFormat(&unknown));
}

test "readSyncSafe" {
    const data = [_]u8{ 0x00, 0x00, 0x02, 0x01 };
    try std.testing.expectEqual(@as(usize, 257), readSyncSafe(&data));
}
