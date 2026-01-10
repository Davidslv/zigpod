//! Album Art Pipeline
//!
//! This module coordinates the complete album art pipeline for ZigPod:
//! extraction, decoding, scaling, caching, and rendering.
//!
//! # Architecture Overview
//!
//! ```
//!   Track File (.mp3/.flac/.m4a)
//!          │
//!          ▼
//!   ┌──────────────┐
//!   │ Cache Check  │ ──→ .cover.rgb565 exists? ──→ Load & Return
//!   └──────────────┘
//!          │ miss
//!          ▼
//!   ┌──────────────┐
//!   │  Extract     │  Parse ID3v2/FLAC/M4A tags for embedded art
//!   └──────────────┘
//!          │ raw JPEG/PNG/BMP bytes
//!          ▼
//!   ┌──────────────┐
//!   │  Decode      │  JPEG/PNG/BMP → RGB888 pixels
//!   └──────────────┘
//!          │ RGB888 buffer
//!          ▼
//!   ┌──────────────┐
//!   │  Scale       │  Bilinear interpolation → 80×80
//!   └──────────────┘
//!          │ 80×80 RGB888
//!          ▼
//!   ┌──────────────┐
//!   │  Convert     │  RGB888 → RGB565
//!   └──────────────┘
//!          │ 80×80 RGB565 (12,800 bytes)
//!          ▼
//!   ┌──────────────┐
//!   │  Cache       │  Write to .cover.rgb565
//!   └──────────────┘
//!          │
//!          ▼
//!      Return to UI
//! ```
//!
//! # Complexity Summary for Future Engineers
//!
//! | Component      | Complexity | Lines | Notes                              |
//! |----------------|------------|-------|-------------------------------------|
//! | Cache system   | Low        | ~100  | Simple file read/write             |
//! | BMP decoder    | Low        | ~80   | Just header + raw pixels           |
//! | ID3v2 extract  | Medium     | ~150  | Frame parsing, sync-safe integers  |
//! | FLAC extract   | Medium     | ~100  | Metadata block parsing             |
//! | M4A extract    | Medium     | ~120  | Atom tree traversal                |
//! | JPEG decoder   | HIGH       | ~800  | Huffman, DCT, YCbCr - the beast    |
//! | PNG decoder    | HIGH       | ~600  | Needs zlib/DEFLATE                 |
//! | Bilinear scale | Low        | ~60   | Simple interpolation               |
//! | RGB conversion | Trivial    | ~20   | Bit shifting                       |
//!
//! # Memory Budget
//!
//! - Decode buffer: 320×320×3 = 307,200 bytes max (for large embedded art)
//! - Scale buffer:  80×80×3   = 19,200 bytes
//! - Final buffer:  80×80×2   = 12,800 bytes (RGB565)
//! - Total: ~340KB peak during decode, 12.8KB persistent
//!
//! # Performance Targets
//!
//! - Cache hit: <5ms (just file read)
//! - Full decode: <500ms (acceptable for track change)
//! - CPU during playback: 0% (cached art is static)
//!

const std = @import("std");
const fat32 = @import("../drivers/storage/fat32.zig");
const art_extract = @import("art_extract.zig");
const art_decode = @import("art_decode.zig");
const art_scale = @import("art_scale.zig");

// ============================================================
// Constants
// ============================================================

/// Album art display size (matches now_playing.zig ALBUM_ART_SIZE)
pub const ART_SIZE: u16 = 80;

/// Maximum source image dimension we'll attempt to decode
pub const MAX_SOURCE_SIZE: u16 = 500;

/// Cache filename (hidden file in track's directory)
pub const CACHE_FILENAME = ".cover.rgb565";

/// Size of cached art file (80 * 80 * 2 bytes)
pub const CACHE_FILE_SIZE: usize = ART_SIZE * ART_SIZE * 2;

/// Maximum embedded art size we'll extract (500KB)
pub const MAX_EMBEDDED_ART_SIZE: usize = 512 * 1024;

// ============================================================
// Album Art Buffer
// ============================================================

/// RGB565 art buffer ready for LCD rendering
/// This is the final output format: 80x80 pixels, 2 bytes per pixel
pub const ArtBuffer = struct {
    pixels: [ART_SIZE * ART_SIZE]u16,
    valid: bool,
    source: ArtSource,

    pub const EMPTY = ArtBuffer{
        .pixels = [_]u16{0} ** (ART_SIZE * ART_SIZE),
        .valid = false,
        .source = .none,
    };

    /// Get pixel at (x, y)
    pub fn getPixel(self: *const ArtBuffer, x: u16, y: u16) u16 {
        if (x >= ART_SIZE or y >= ART_SIZE) return 0;
        return self.pixels[y * ART_SIZE + x];
    }
};

pub const ArtSource = enum {
    none,
    cache,       // Loaded from .cover.rgb565
    embedded,    // Extracted from audio file tags
    external,    // Found as cover.bmp/jpg in directory
    placeholder, // Default placeholder art
};

// ============================================================
// Error Types
// ============================================================

pub const ArtError = error{
    FileNotFound,
    InvalidFormat,
    ImageTooLarge,
    DecodeFailed,
    ScaleFailed,
    CacheWriteFailed,
    OutOfMemory,
    UnsupportedFormat,
};

// ============================================================
// Static Buffers (embedded-friendly, no allocator)
// ============================================================

/// Decode buffer for source image (RGB888)
/// Sized for MAX_SOURCE_SIZE × MAX_SOURCE_SIZE × 3 bytes
/// WARNING: This is large (~750KB) - consider reducing MAX_SOURCE_SIZE if RAM constrained
const DECODE_BUFFER_SIZE: usize = @as(usize, MAX_SOURCE_SIZE) * @as(usize, MAX_SOURCE_SIZE) * 3;
var decode_buffer: [DECODE_BUFFER_SIZE]u8 = undefined;

/// Intermediate buffer for extracted embedded art data
var extract_buffer: [MAX_EMBEDDED_ART_SIZE]u8 = undefined;

/// Final art buffer (persists for UI rendering)
var current_art: ArtBuffer = ArtBuffer.EMPTY;

// ============================================================
// Public API
// ============================================================

/// Load album art for a track
///
/// This is the main entry point. It will:
/// 1. Check cache for pre-rendered .cover.rgb565
/// 2. Look for external cover.bmp in track directory
/// 3. Extract embedded art from audio file tags
/// 4. Decode, scale, convert to RGB565
/// 5. Cache result for future loads
///
/// Returns pointer to static buffer - valid until next loadForTrack() call
pub fn loadForTrack(track_path: []const u8) *const ArtBuffer {
    // Extract directory from track path
    const dir = getDirectory(track_path);

    // Step 1: Check cache
    if (loadFromCache(dir)) |_| {
        current_art.source = .cache;
        current_art.valid = true;
        return &current_art;
    }

    // Step 2: Try external cover file (cover.bmp, folder.bmp, etc.)
    if (loadExternalArt(dir)) {
        current_art.source = .external;
        current_art.valid = true;
        cacheCurrentArt(dir);
        return &current_art;
    }

    // Step 3: Try embedded art extraction
    if (loadEmbeddedArt(track_path)) {
        current_art.source = .embedded;
        current_art.valid = true;
        cacheCurrentArt(dir);
        return &current_art;
    }

    // No art found - return empty
    current_art = ArtBuffer.EMPTY;
    return &current_art;
}

/// Check if we currently have valid art loaded
pub fn hasArt() bool {
    return current_art.valid;
}

/// Get the current art buffer
pub fn getCurrentArt() *const ArtBuffer {
    return &current_art;
}

/// Clear current art (free resources)
pub fn clear() void {
    current_art = ArtBuffer.EMPTY;
}

/// Invalidate cache for a directory (call after art changes)
pub fn invalidateCache(dir: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const cache_path = buildCachePath(dir, &path_buf) orelse return;
    fat32.deleteFile(cache_path) catch {};
}

// ============================================================
// Cache System
// ============================================================

/// Load art from cache file
fn loadFromCache(dir: []const u8) ?void {
    var path_buf: [256]u8 = undefined;
    const cache_path = buildCachePath(dir, &path_buf) orelse return null;

    // Read cache file directly into pixel buffer
    var read_buf: [CACHE_FILE_SIZE]u8 = undefined;
    const bytes_read = fat32.readFile(cache_path, &read_buf) catch return null;

    if (bytes_read != CACHE_FILE_SIZE) return null;

    // Copy to pixel buffer (reinterpret bytes as u16)
    const pixel_bytes = std.mem.sliceAsBytes(&current_art.pixels);
    @memcpy(pixel_bytes, read_buf[0..CACHE_FILE_SIZE]);

    return {};
}

/// Write current art to cache
fn cacheCurrentArt(dir: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const cache_path = buildCachePath(dir, &path_buf) orelse return;

    // Write pixel buffer to file
    const pixel_bytes = std.mem.sliceAsBytes(&current_art.pixels);
    fat32.writeFile(cache_path, pixel_bytes) catch {};
}

/// Build cache file path
fn buildCachePath(dir: []const u8, buffer: []u8) ?[]u8 {
    if (dir.len + 1 + CACHE_FILENAME.len > buffer.len) return null;

    var pos: usize = 0;
    @memcpy(buffer[0..dir.len], dir);
    pos = dir.len;

    if (pos > 0 and buffer[pos - 1] != '/') {
        buffer[pos] = '/';
        pos += 1;
    }

    @memcpy(buffer[pos .. pos + CACHE_FILENAME.len], CACHE_FILENAME);
    pos += CACHE_FILENAME.len;

    return buffer[0..pos];
}

// ============================================================
// External Art Loading
// ============================================================

/// External cover file names to search (in priority order)
const external_filenames = [_][]const u8{
    "cover.bmp",
    "Cover.bmp",
    "COVER.BMP",
    "folder.bmp",
    "Folder.bmp",
    "FOLDER.BMP",
    "album.bmp",
    "Album.bmp",
    "ALBUM.BMP",
    // JPEG support - requires decoder
    "cover.jpg",
    "Cover.jpg",
    "COVER.JPG",
    "folder.jpg",
    "Folder.jpg",
    "FOLDER.JPG",
};

/// Try to load external cover file from directory
fn loadExternalArt(dir: []const u8) bool {
    var path_buf: [256]u8 = undefined;

    for (external_filenames) |filename| {
        // Build full path
        var pos: usize = 0;
        if (dir.len + 1 + filename.len > path_buf.len) continue;

        @memcpy(path_buf[0..dir.len], dir);
        pos = dir.len;

        if (pos > 0 and path_buf[pos - 1] != '/') {
            path_buf[pos] = '/';
            pos += 1;
        }

        @memcpy(path_buf[pos .. pos + filename.len], filename);
        pos += filename.len;

        const path = path_buf[0..pos];

        // Try to read file
        const bytes_read = fat32.readFile(path, &extract_buffer) catch continue;
        if (bytes_read == 0) continue;

        const data = extract_buffer[0..bytes_read];

        // Detect format and decode
        const format = art_decode.detectFormat(data);
        if (format == .unknown) continue;

        // Decode to RGB888
        const decoded = art_decode.decode(data, format, &decode_buffer) catch continue;

        // Scale to 80x80
        const scaled = art_scale.bilinearScale(
            decoded.pixels,
            decoded.width,
            decoded.height,
            ART_SIZE,
            ART_SIZE,
        ) catch continue;

        // Convert to RGB565 and store
        convertToRgb565(scaled, &current_art.pixels);
        return true;
    }

    return false;
}

// ============================================================
// Embedded Art Loading
// ============================================================

/// Try to extract and decode embedded art from audio file
fn loadEmbeddedArt(track_path: []const u8) bool {
    // Detect audio format from extension
    const format = detectAudioFormat(track_path);
    if (format == .unknown) return false;

    // Read file header (enough for tag parsing)
    // We read a larger chunk to find embedded art
    var file_buffer: [MAX_EMBEDDED_ART_SIZE]u8 = undefined;
    const bytes_read = fat32.readFile(track_path, &file_buffer) catch return false;
    if (bytes_read < 128) return false;

    const file_data = file_buffer[0..bytes_read];

    // Extract embedded art based on format
    const art_data = switch (format) {
        .mp3 => art_extract.extractFromMp3(file_data),
        .flac => art_extract.extractFromFlac(file_data),
        .m4a => art_extract.extractFromM4a(file_data),
        .unknown => null,
    } orelse return false;

    // Detect image format
    const img_format = art_decode.detectFormat(art_data);
    if (img_format == .unknown) return false;

    // Decode
    const decoded = art_decode.decode(art_data, img_format, &decode_buffer) catch return false;

    // Scale
    const scaled = art_scale.bilinearScale(
        decoded.pixels,
        decoded.width,
        decoded.height,
        ART_SIZE,
        ART_SIZE,
    ) catch return false;

    // Convert and store
    convertToRgb565(scaled, &current_art.pixels);
    return true;
}

// ============================================================
// Format Detection
// ============================================================

const AudioFormat = enum {
    mp3,
    flac,
    m4a,
    unknown,
};

fn detectAudioFormat(path: []const u8) AudioFormat {
    if (path.len < 4) return .unknown;

    const ext = path[path.len - 4 ..];

    if (std.mem.eql(u8, ext, ".mp3") or std.mem.eql(u8, ext, ".MP3")) {
        return .mp3;
    }
    if (std.mem.eql(u8, ext, ".m4a") or std.mem.eql(u8, ext, ".M4A")) {
        return .m4a;
    }

    // Check for .flac (5 chars)
    if (path.len >= 5) {
        const ext5 = path[path.len - 5 ..];
        if (std.mem.eql(u8, ext5, ".flac") or std.mem.eql(u8, ext5, ".FLAC")) {
            return .flac;
        }
    }

    return .unknown;
}

// ============================================================
// RGB Conversion
// ============================================================

/// Convert RGB888 buffer to RGB565
/// This is the final step before caching/rendering
///
/// # Complexity: Trivial
///
/// RGB565 format: RRRRRGGGGGGBBBBB (5-6-5 bits)
/// - Red:   bits 15-11 (5 bits, >> 3 from 8-bit)
/// - Green: bits 10-5  (6 bits, >> 2 from 8-bit)
/// - Blue:  bits 4-0   (5 bits, >> 3 from 8-bit)
fn convertToRgb565(rgb888: []const u8, rgb565: []u16) void {
    const pixel_count = @min(rgb888.len / 3, rgb565.len);

    for (0..pixel_count) |i| {
        const r = rgb888[i * 3 + 0];
        const g = rgb888[i * 3 + 1];
        const b = rgb888[i * 3 + 2];

        rgb565[i] = (@as(u16, r >> 3) << 11) |
            (@as(u16, g >> 2) << 5) |
            @as(u16, b >> 3);
    }
}

// ============================================================
// Utility Functions
// ============================================================

/// Extract directory from file path
fn getDirectory(path: []const u8) []const u8 {
    var last_sep: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') last_sep = i;
    }

    if (last_sep == 0) return "/";
    return path[0..last_sep];
}

// ============================================================
// Tests
// ============================================================

test "getDirectory" {
    try std.testing.expectEqualStrings("/music/album", getDirectory("/music/album/track.mp3"));
    try std.testing.expectEqualStrings("/music", getDirectory("/music/track.mp3"));
    try std.testing.expectEqualStrings("/", getDirectory("/track.mp3"));
    try std.testing.expectEqualStrings("/", getDirectory("track.mp3"));
}

test "detectAudioFormat" {
    try std.testing.expectEqual(AudioFormat.mp3, detectAudioFormat("/music/song.mp3"));
    try std.testing.expectEqual(AudioFormat.mp3, detectAudioFormat("/music/song.MP3"));
    try std.testing.expectEqual(AudioFormat.flac, detectAudioFormat("/music/song.flac"));
    try std.testing.expectEqual(AudioFormat.m4a, detectAudioFormat("/music/song.m4a"));
    try std.testing.expectEqual(AudioFormat.unknown, detectAudioFormat("/music/song.wav"));
}

test "convertToRgb565" {
    // Pure red (255, 0, 0) -> 0xF800
    var rgb888 = [_]u8{ 255, 0, 0 };
    var rgb565: [1]u16 = undefined;
    convertToRgb565(&rgb888, &rgb565);
    try std.testing.expectEqual(@as(u16, 0xF800), rgb565[0]);

    // Pure green (0, 255, 0) -> 0x07E0
    rgb888 = [_]u8{ 0, 255, 0 };
    convertToRgb565(&rgb888, &rgb565);
    try std.testing.expectEqual(@as(u16, 0x07E0), rgb565[0]);

    // Pure blue (0, 0, 255) -> 0x001F
    rgb888 = [_]u8{ 0, 0, 255 };
    convertToRgb565(&rgb888, &rgb565);
    try std.testing.expectEqual(@as(u16, 0x001F), rgb565[0]);

    // White (255, 255, 255) -> 0xFFFF
    rgb888 = [_]u8{ 255, 255, 255 };
    convertToRgb565(&rgb888, &rgb565);
    try std.testing.expectEqual(@as(u16, 0xFFFF), rgb565[0]);
}

test "buildCachePath" {
    var buf: [256]u8 = undefined;

    const path1 = buildCachePath("/music/album", &buf);
    try std.testing.expect(path1 != null);
    try std.testing.expectEqualStrings("/music/album/.cover.rgb565", path1.?);

    const path2 = buildCachePath("/", &buf);
    try std.testing.expect(path2 != null);
    try std.testing.expectEqualStrings("/.cover.rgb565", path2.?);
}
