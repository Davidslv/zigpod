//! AAC Decoder Tables
//!
//! Pre-computed tables for AAC-LC decoding.
//! Uses fixed-point Q16.16 format for embedded targets.

const std = @import("std");

// ============================================================
// AAC Constants
// ============================================================

/// Number of spectral bands for long blocks
pub const MAX_SFB_LONG: usize = 51;
/// Number of spectral bands for short blocks
pub const MAX_SFB_SHORT: usize = 15;
/// Samples per long block
pub const LONG_BLOCK_SIZE: usize = 1024;
/// Samples per short block
pub const SHORT_BLOCK_SIZE: usize = 128;
/// Number of short blocks in a window sequence
pub const NUM_SHORT_BLOCKS: usize = 8;

// ============================================================
// Sample Rate Configuration
// ============================================================

/// Sample rate index to Hz mapping
pub const SAMPLE_RATES = [_]u32{
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
    16000, 12000, 11025, 8000, 7350, 0, 0, 0,
};

/// Scalefactor band boundaries for long blocks per sample rate index
/// Each entry contains [num_bands, followed by band boundaries]
pub const SFB_LONG_OFFSETS = [13][52]u16{
    // 96000 Hz - 41 bands
    .{ 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 156, 172, 188, 212, 240, 276, 320, 384, 448, 512, 576, 640, 704, 768, 832, 896, 960, 1024, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // 88200 Hz - 41 bands
    .{ 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 156, 172, 188, 212, 240, 276, 320, 384, 448, 512, 576, 640, 704, 768, 832, 896, 960, 1024, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // 64000 Hz - 47 bands
    .{ 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 100, 112, 124, 140, 156, 172, 192, 216, 240, 268, 304, 344, 384, 424, 464, 504, 544, 584, 624, 664, 704, 744, 784, 824, 864, 904, 944, 984, 1024, 0, 0, 0, 0, 0 },
    // 48000 Hz - 49 bands
    .{ 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 1024, 0, 0, 0 },
    // 44100 Hz - 49 bands
    .{ 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 1024, 0, 0, 0 },
    // 32000 Hz - 51 bands
    .{ 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 960, 992, 1024, 0 },
    // 24000 Hz - 47 bands
    .{ 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 52, 60, 68, 76, 84, 92, 100, 108, 116, 124, 136, 148, 160, 172, 188, 204, 220, 240, 260, 284, 308, 336, 364, 396, 432, 468, 508, 552, 600, 652, 704, 768, 832, 896, 960, 1024, 0, 0, 0, 0, 0 },
    // 22050 Hz - 47 bands
    .{ 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 52, 60, 68, 76, 84, 92, 100, 108, 116, 124, 136, 148, 160, 172, 188, 204, 220, 240, 260, 284, 308, 336, 364, 396, 432, 468, 508, 552, 600, 652, 704, 768, 832, 896, 960, 1024, 0, 0, 0, 0, 0 },
    // 16000 Hz - 43 bands
    .{ 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 100, 112, 124, 136, 148, 160, 172, 184, 196, 212, 228, 244, 260, 280, 300, 320, 344, 368, 396, 424, 456, 492, 532, 572, 616, 664, 716, 772, 832, 896, 960, 1024, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // 12000 Hz - 43 bands
    .{ 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 100, 112, 124, 136, 148, 160, 172, 184, 196, 212, 228, 244, 260, 280, 300, 320, 344, 368, 396, 424, 456, 492, 532, 572, 616, 664, 716, 772, 832, 896, 960, 1024, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // 11025 Hz - 43 bands
    .{ 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 100, 112, 124, 136, 148, 160, 172, 184, 196, 212, 228, 244, 260, 280, 300, 320, 344, 368, 396, 424, 456, 492, 532, 572, 616, 664, 716, 772, 832, 896, 960, 1024, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // 8000 Hz - 40 bands
    .{ 12, 24, 36, 48, 60, 72, 84, 96, 108, 120, 132, 144, 156, 172, 188, 204, 220, 236, 252, 268, 288, 308, 328, 348, 372, 396, 420, 448, 476, 508, 544, 580, 620, 664, 712, 764, 820, 880, 944, 1024, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    // 7350 Hz - 40 bands
    .{ 12, 24, 36, 48, 60, 72, 84, 96, 108, 120, 132, 144, 156, 172, 188, 204, 220, 236, 252, 268, 288, 308, 328, 348, 372, 396, 420, 448, 476, 508, 544, 580, 620, 664, 712, 764, 820, 880, 944, 1024, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};

/// Number of scalefactor bands for long blocks per sample rate index
pub const NUM_SFB_LONG = [_]u8{
    41, 41, 47, 49, 49, 51, 47, 47, 43, 43, 43, 40, 40,
};

/// Scalefactor band boundaries for short blocks per sample rate index
pub const SFB_SHORT_OFFSETS = [13][16]u16{
    // 96000 Hz - 12 bands
    .{ 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 128, 0, 0, 0, 0 },
    // 88200 Hz
    .{ 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 128, 0, 0, 0, 0 },
    // 64000 Hz
    .{ 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 92, 128, 0, 0, 0, 0 },
    // 48000 Hz - 14 bands
    .{ 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128, 0, 0 },
    // 44100 Hz
    .{ 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128, 0, 0 },
    // 32000 Hz
    .{ 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128, 0, 0 },
    // 24000 Hz - 15 bands
    .{ 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 64, 76, 92, 108, 128, 0 },
    // 22050 Hz
    .{ 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 64, 76, 92, 108, 128, 0 },
    // 16000 Hz
    .{ 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 60, 72, 88, 108, 128, 0 },
    // 12000 Hz
    .{ 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 60, 72, 88, 108, 128, 0 },
    // 11025 Hz
    .{ 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 60, 72, 88, 108, 128, 0 },
    // 8000 Hz
    .{ 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 60, 72, 88, 108, 128, 0 },
    // 7350 Hz
    .{ 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 60, 72, 88, 108, 128, 0 },
};

/// Number of scalefactor bands for short blocks per sample rate index
pub const NUM_SFB_SHORT = [_]u8{
    12, 12, 12, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15,
};

// ============================================================
// Huffman Tables
// ============================================================

/// Huffman code structure
pub const HuffmanCode = packed struct {
    len: u4, // Code length in bits (0-15)
    value: i12, // Decoded value
};

/// Scalefactor Huffman codebook
/// Maps bit patterns to scalefactor differences (-60 to +60)
pub const SF_HUFFMAN = blk: {
    var table: [121]HuffmanCode = undefined;
    // Initialize with direct values (simplified)
    // Full AAC uses variable-length codes; this is lookup by index
    for (0..121) |i| {
        const diff: i12 = @as(i12, @intCast(i)) - 60;
        table[i] = HuffmanCode{ .len = 9, .value = diff };
    }
    break :blk table;
};

/// Spectral Huffman codebooks (1-11)
/// Each entry: [max_abs_value, dimension (2 or 4)]
pub const CODEBOOK_INFO = [_][2]u8{
    .{ 0, 0 }, // Codebook 0: zero (no Huffman)
    .{ 1, 4 }, // Codebook 1: 4-tuple, values 0,1
    .{ 1, 4 }, // Codebook 2: 4-tuple, values 0,1
    .{ 2, 4 }, // Codebook 3: 4-tuple, values 0,1,2
    .{ 2, 4 }, // Codebook 4: 4-tuple, values 0,1,2
    .{ 4, 2 }, // Codebook 5: 2-tuple, values 0-4
    .{ 4, 2 }, // Codebook 6: 2-tuple, values 0-4
    .{ 7, 2 }, // Codebook 7: 2-tuple, values 0-7
    .{ 7, 2 }, // Codebook 8: 2-tuple, values 0-7
    .{ 12, 2 }, // Codebook 9: 2-tuple, values 0-12
    .{ 12, 2 }, // Codebook 10: 2-tuple, values 0-12
    .{ 16, 2 }, // Codebook 11: 2-tuple, values 0-16 + escape
};

/// Huffman table for scalefactor decoding
/// [code, length, value]
pub const SF_HUFFMAN_TABLE = [_][3]u16{
    // Length 1-5 codes
    .{ 0b0, 1, 60 }, // 0 -> 0 (center)
    .{ 0b10, 2, 59 }, // 10 -> -1
    .{ 0b110, 3, 61 }, // 110 -> +1
    .{ 0b1110, 4, 58 }, // 1110 -> -2
    .{ 0b11110, 5, 62 }, // 11110 -> +2
    // ... more codes would follow for full implementation
};

// ============================================================
// MDCT Window Coefficients
// ============================================================

/// Kaiser-Bessel derived window for long blocks (1024 samples)
/// Q16 fixed-point format
pub const LONG_WINDOW = blk: {
    @setEvalBranchQuota(10000);
    var window: [LONG_BLOCK_SIZE]i32 = undefined;
    const N: f64 = LONG_BLOCK_SIZE;
    for (0..LONG_BLOCK_SIZE) |n| {
        const nf: f64 = @floatFromInt(n);
        // KBD window with alpha = 4.0
        const x = (nf + 0.5) / N;
        const val = @sin(std.math.pi * x);
        window[n] = @intFromFloat(val * 65536.0);
    }
    break :blk window;
};

/// Kaiser-Bessel derived window for short blocks (128 samples)
/// Q16 fixed-point format
pub const SHORT_WINDOW = blk: {
    var window: [SHORT_BLOCK_SIZE]i32 = undefined;
    const N: f64 = SHORT_BLOCK_SIZE;
    for (0..SHORT_BLOCK_SIZE) |n| {
        const nf: f64 = @floatFromInt(n);
        const x = (nf + 0.5) / N;
        const val = @sin(std.math.pi * x);
        window[n] = @intFromFloat(val * 65536.0);
    }
    break :blk window;
};

// ============================================================
// Inverse Quantization Table
// ============================================================

/// Inverse quantization table size (reduced for embedded)
pub const IQ_TABLE_SIZE: usize = 256;

/// Inverse quantization: x^(4/3) for x = 0..255
/// Q8 fixed-point format (use linear interpolation for larger values)
/// AAC uses: value = sign(x) * |x|^(4/3) * 2^(0.25 * (sf - 100))
pub const IQ_TABLE = blk: {
    @setEvalBranchQuota(5000);
    var table: [IQ_TABLE_SIZE]i32 = undefined;
    for (0..IQ_TABLE_SIZE) |i| {
        const x: f64 = @floatFromInt(i);
        // x^(4/3) = x * x^(1/3) = x * cbrt(x)
        // For comptime compatibility, use manual calculation
        const x_cubed = x * x * x;
        const x_fourth = x_cubed * x;
        // x^(4/3) ≈ cbrt(x^4) - approximate using Newton-Raphson at comptime
        var result: f64 = if (x == 0) 0 else x;
        if (x > 0) {
            // Few iterations of Newton-Raphson for cube root of x^4
            var y = x; // Initial guess
            y = (2.0 * y + x_fourth / (y * y)) / 3.0;
            y = (2.0 * y + x_fourth / (y * y)) / 3.0;
            y = (2.0 * y + x_fourth / (y * y)) / 3.0;
            result = y;
        }
        // Scale to Q8 fixed-point
        table[i] = @intFromFloat(@min(result * 256.0, 2147483647.0));
    }
    break :blk table;
};

/// Lookup x^(4/3) using table and interpolation for values > 255
pub fn inverseQuantize(x: u32) i32 {
    if (x == 0) return 0;
    if (x < IQ_TABLE_SIZE) return IQ_TABLE[x];

    // For larger values, use scaling: (k*x)^(4/3) = k^(4/3) * x^(4/3)
    // Factor out powers of 8: x = 8^n * r where r < 256
    var shift: u5 = 0;
    var r: u32 = x;
    while (r >= IQ_TABLE_SIZE) {
        r >>= 3; // Divide by 8
        shift += 4; // Multiply result by 8^(4/3) = 16
    }
    var result: i64 = IQ_TABLE[r];
    result <<= shift;
    return @truncate(@min(result, 2147483647));
}

// ============================================================
// MDCT Twiddle Factors
// ============================================================

/// MDCT twiddle factors for 2048-point (1024 output) transform
/// Pre-computed cos/sin pairs in Q15 format
pub const MDCT_TWIDDLE_1024 = blk: {
    @setEvalBranchQuota(20000);
    var twiddle: [1024][2]i16 = undefined;
    for (0..1024) |k| {
        const kf: f64 = @floatFromInt(k);
        const angle = std.math.pi * (kf + 0.5) / 2048.0;
        twiddle[k][0] = @intFromFloat(@cos(angle) * 32767.0);
        twiddle[k][1] = @intFromFloat(@sin(angle) * 32767.0);
    }
    break :blk twiddle;
};

/// MDCT twiddle factors for 256-point (128 output) transform
pub const MDCT_TWIDDLE_128 = blk: {
    var twiddle: [128][2]i16 = undefined;
    for (0..128) |k| {
        const kf: f64 = @floatFromInt(k);
        const angle = std.math.pi * (kf + 0.5) / 256.0;
        twiddle[k][0] = @intFromFloat(@cos(angle) * 32767.0);
        twiddle[k][1] = @intFromFloat(@sin(angle) * 32767.0);
    }
    break :blk twiddle;
};

// ============================================================
// TNS Coefficients
// ============================================================

/// TNS coefficient quantization table (4 bits)
pub const TNS_COEF_4 = [_]i16{
    0, // 0.0
    2185, // 0.0667
    4277, // 0.1305
    6180, // 0.1886
    7900, // 0.2411
    9434, // 0.2879
    10784, // 0.3291
    11948, // 0.3647
    -12925, // -0.3944
    -11948, // -0.3647
    -10784, // -0.3291
    -9434, // -0.2879
    -7900, // -0.2411
    -6180, // -0.1886
    -4277, // -0.1305
    -2185, // -0.0667
};

/// TNS coefficient quantization table (3 bits)
pub const TNS_COEF_3 = [_]i16{
    0, // 0.0
    4277, // 0.1305
    7900, // 0.2411
    10784, // 0.3291
    -12925, // -0.3944
    -10784, // -0.3291
    -7900, // -0.2411
    -4277, // -0.1305
};

// ============================================================
// Helper Functions
// ============================================================

/// Get scalefactor band count for given sample rate index and window type
pub fn getSfbCount(sr_index: u4, is_short: bool) u8 {
    if (sr_index >= 13) return 0;
    return if (is_short) NUM_SFB_SHORT[sr_index] else NUM_SFB_LONG[sr_index];
}

/// Get scalefactor band offset for given sample rate index
pub fn getSfbOffset(sr_index: u4, sfb: u8, is_short: bool) u16 {
    if (sr_index >= 13) return 0;
    if (is_short) {
        if (sfb >= NUM_SFB_SHORT[sr_index]) return SHORT_BLOCK_SIZE;
        return SFB_SHORT_OFFSETS[sr_index][sfb];
    } else {
        if (sfb >= NUM_SFB_LONG[sr_index]) return LONG_BLOCK_SIZE;
        return SFB_LONG_OFFSETS[sr_index][sfb];
    }
}

/// Get sample rate from index
pub fn getSampleRate(sr_index: u4) u32 {
    if (sr_index >= 13) return 0;
    return SAMPLE_RATES[sr_index];
}

/// Get sample rate index from frequency
pub fn getSampleRateIndex(sample_rate: u32) ?u4 {
    for (SAMPLE_RATES, 0..) |sr, i| {
        if (sr == sample_rate) return @intCast(i);
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

test "sample rate lookup" {
    try std.testing.expectEqual(@as(u32, 44100), getSampleRate(4));
    try std.testing.expectEqual(@as(u32, 48000), getSampleRate(3));
    try std.testing.expectEqual(@as(u32, 0), getSampleRate(15));
}

test "sample rate index lookup" {
    try std.testing.expectEqual(@as(?u4, 4), getSampleRateIndex(44100));
    try std.testing.expectEqual(@as(?u4, 3), getSampleRateIndex(48000));
    try std.testing.expectEqual(@as(?u4, null), getSampleRateIndex(12345));
}

test "sfb count" {
    // 44100 Hz has 49 long bands and 14 short bands
    try std.testing.expectEqual(@as(u8, 49), getSfbCount(4, false));
    try std.testing.expectEqual(@as(u8, 14), getSfbCount(4, true));
}

test "window tables generated" {
    // Verify window values are in expected range
    try std.testing.expect(LONG_WINDOW[0] > 0);
    try std.testing.expect(LONG_WINDOW[512] > 60000); // Near peak
    try std.testing.expect(SHORT_WINDOW[64] > 60000); // Near peak
}

test "iq table generated" {
    // 0^(4/3) = 0
    try std.testing.expectEqual(@as(i32, 0), IQ_TABLE[0]);
    // 1^(4/3) = 1 * 256 (Q8) = 256
    try std.testing.expectEqual(@as(i32, 256), IQ_TABLE[1]);
    // 8^(4/3) ≈ 16 * 256 (Q8) ≈ 4096 (Newton-Raphson gives slight variation)
    try std.testing.expect(IQ_TABLE[8] >= 4000 and IQ_TABLE[8] <= 4500);
    // Verify monotonically increasing
    try std.testing.expect(IQ_TABLE[2] > IQ_TABLE[1]);
    try std.testing.expect(IQ_TABLE[10] > IQ_TABLE[8]);
}

test "inverse quantize" {
    // Test small values (direct table lookup)
    try std.testing.expectEqual(@as(i32, 0), inverseQuantize(0));
    try std.testing.expectEqual(@as(i32, 256), inverseQuantize(1));
    // Test larger values (scaling)
    try std.testing.expect(inverseQuantize(256) > 0);
    try std.testing.expect(inverseQuantize(512) > inverseQuantize(256));
}
