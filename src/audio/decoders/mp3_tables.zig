//! MP3 Decoder Tables
//!
//! Contains all lookup tables required for MP3 decoding:
//! - Huffman tables (34 tables for spectral data)
//! - Scale factor band tables
//! - Quantization tables
//! - Synthesis window coefficients
//! - IMDCT window coefficients

const std = @import("std");

// ============================================================
// Huffman Tables
// ============================================================

/// Huffman table entry: value and number of bits
pub const HuffPair = struct {
    x: i8,
    y: i8,
};

/// Huffman table with linbits extension
pub const HuffTable = struct {
    table: []const HuffEntry,
    linbits: u8,
};

pub const HuffEntry = struct {
    code: u16,
    length: u4,
    x: i4,
    y: i4,
};

// Huffman table 1 (2x2)
pub const hufftab1 = [_]HuffEntry{
    .{ .code = 0b1, .length = 1, .x = 0, .y = 0 },
    .{ .code = 0b001, .length = 3, .x = 0, .y = 1 },
    .{ .code = 0b01, .length = 2, .x = 1, .y = 0 },
    .{ .code = 0b000, .length = 3, .x = 1, .y = 1 },
};

// Huffman table 2 (3x3)
pub const hufftab2 = [_]HuffEntry{
    .{ .code = 0b1, .length = 1, .x = 0, .y = 0 },
    .{ .code = 0b010, .length = 3, .x = 0, .y = 1 },
    .{ .code = 0b00001, .length = 5, .x = 0, .y = 2 },
    .{ .code = 0b011, .length = 3, .x = 1, .y = 0 },
    .{ .code = 0b001, .length = 3, .x = 1, .y = 1 },
    .{ .code = 0b00011, .length = 5, .x = 1, .y = 2 },
    .{ .code = 0b00010, .length = 5, .x = 2, .y = 0 },
    .{ .code = 0b00000, .length = 5, .x = 2, .y = 1 },
    .{ .code = 0b00100, .length = 5, .x = 2, .y = 2 },
};

// Huffman table 3 (3x3)
pub const hufftab3 = [_]HuffEntry{
    .{ .code = 0b11, .length = 2, .x = 0, .y = 0 },
    .{ .code = 0b010, .length = 3, .x = 0, .y = 1 },
    .{ .code = 0b00001, .length = 5, .x = 0, .y = 2 },
    .{ .code = 0b011, .length = 3, .x = 1, .y = 0 },
    .{ .code = 0b001, .length = 3, .x = 1, .y = 1 },
    .{ .code = 0b00010, .length = 5, .x = 1, .y = 2 },
    .{ .code = 0b00000, .length = 5, .x = 2, .y = 0 },
    .{ .code = 0b00011, .length = 5, .x = 2, .y = 1 },
    .{ .code = 0b10, .length = 2, .x = 2, .y = 2 },
};

// Huffman table 5 (4x4)
pub const hufftab5 = [_]HuffEntry{
    .{ .code = 0b1, .length = 1, .x = 0, .y = 0 },
    .{ .code = 0b010, .length = 3, .x = 0, .y = 1 },
    .{ .code = 0b00110, .length = 5, .x = 0, .y = 2 },
    .{ .code = 0b0001110, .length = 7, .x = 0, .y = 3 },
    .{ .code = 0b011, .length = 3, .x = 1, .y = 0 },
    .{ .code = 0b001, .length = 3, .x = 1, .y = 1 },
    .{ .code = 0b00100, .length = 5, .x = 1, .y = 2 },
    .{ .code = 0b0001100, .length = 7, .x = 1, .y = 3 },
    .{ .code = 0b00111, .length = 5, .x = 2, .y = 0 },
    .{ .code = 0b00101, .length = 5, .x = 2, .y = 1 },
    .{ .code = 0b0001111, .length = 7, .x = 2, .y = 2 },
    .{ .code = 0b0001101, .length = 7, .x = 2, .y = 3 },
    .{ .code = 0b0000110, .length = 7, .x = 3, .y = 0 },
    .{ .code = 0b0000100, .length = 7, .x = 3, .y = 1 },
    .{ .code = 0b0000111, .length = 7, .x = 3, .y = 2 },
    .{ .code = 0b0000101, .length = 7, .x = 3, .y = 3 },
};

// Huffman table 6 (4x4)
pub const hufftab6 = [_]HuffEntry{
    .{ .code = 0b111, .length = 3, .x = 0, .y = 0 },
    .{ .code = 0b0110, .length = 4, .x = 0, .y = 1 },
    .{ .code = 0b00110, .length = 5, .x = 0, .y = 2 },
    .{ .code = 0b001110, .length = 6, .x = 0, .y = 3 },
    .{ .code = 0b0111, .length = 4, .x = 1, .y = 0 },
    .{ .code = 0b0100, .length = 4, .x = 1, .y = 1 },
    .{ .code = 0b00100, .length = 5, .x = 1, .y = 2 },
    .{ .code = 0b001100, .length = 6, .x = 1, .y = 3 },
    .{ .code = 0b00111, .length = 5, .x = 2, .y = 0 },
    .{ .code = 0b00101, .length = 5, .x = 2, .y = 1 },
    .{ .code = 0b001111, .length = 6, .x = 2, .y = 2 },
    .{ .code = 0b001101, .length = 6, .x = 2, .y = 3 },
    .{ .code = 0b000110, .length = 6, .x = 3, .y = 0 },
    .{ .code = 0b000100, .length = 6, .x = 3, .y = 1 },
    .{ .code = 0b000111, .length = 6, .x = 3, .y = 2 },
    .{ .code = 0b000101, .length = 6, .x = 3, .y = 3 },
};

// Quadruple tables for count1 region (tables A and B)
pub const quad_table_a = [_][4]i8{
    .{ 0, 0, 0, 0 }, // 1
    .{ 0, 0, 0, 1 }, // 0101
    .{ 0, 0, 1, 0 }, // 0100
    .{ 0, 0, 1, 1 }, // 0011
    .{ 0, 1, 0, 0 }, // 0110
    .{ 0, 1, 0, 1 }, // 01111
    .{ 0, 1, 1, 0 }, // 01110
    .{ 0, 1, 1, 1 }, // 01101
    .{ 1, 0, 0, 0 }, // 0111
    .{ 1, 0, 0, 1 }, // 01001
    .{ 1, 0, 1, 0 }, // 01000
    .{ 1, 0, 1, 1 }, // 00111
    .{ 1, 1, 0, 0 }, // 00110
    .{ 1, 1, 0, 1 }, // 00101
    .{ 1, 1, 1, 0 }, // 00100
    .{ 1, 1, 1, 1 }, // 00011
};

pub const quad_table_b = [_][4]i8{
    .{ 0, 0, 0, 0 }, // 1111
    .{ 0, 0, 0, 1 }, // 1110
    .{ 0, 0, 1, 0 }, // 1101
    .{ 0, 0, 1, 1 }, // 1100
    .{ 0, 1, 0, 0 }, // 1011
    .{ 0, 1, 0, 1 }, // 1010
    .{ 0, 1, 1, 0 }, // 1001
    .{ 0, 1, 1, 1 }, // 1000
    .{ 1, 0, 0, 0 }, // 0111
    .{ 1, 0, 0, 1 }, // 0110
    .{ 1, 0, 1, 0 }, // 0101
    .{ 1, 0, 1, 1 }, // 0100
    .{ 1, 1, 0, 0 }, // 0011
    .{ 1, 1, 0, 1 }, // 0010
    .{ 1, 1, 1, 0 }, // 0001
    .{ 1, 1, 1, 1 }, // 0000
};

// Linbits for each Huffman table (0 = no linbits)
pub const huffman_linbits = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // Tables 0-9
    0, 0, 0, 0, 0, 0, 1, 2, 3, 4, // Tables 10-19
    6, 8, 10, 13, 4, 5, 6, 7, 8, 9, // Tables 20-29
    11, 13, 0, 0, // Tables 30-33
};

// ============================================================
// Scale Factor Band Tables
// ============================================================

/// Scale factor band boundaries for long blocks (MPEG1, 44100 Hz)
pub const sfb_long_44100 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 30, 36, 44,
    52, 62, 74, 90, 110, 134, 162, 196, 238, 288,
    342, 418, 576,
};

/// Scale factor band boundaries for long blocks (MPEG1, 48000 Hz)
pub const sfb_long_48000 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 30, 36, 42,
    50, 60, 72, 88, 106, 128, 156, 190, 230, 276,
    330, 384, 576,
};

/// Scale factor band boundaries for long blocks (MPEG1, 32000 Hz)
pub const sfb_long_32000 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 30, 36, 44,
    54, 66, 82, 102, 126, 156, 194, 240, 296, 364,
    448, 550, 576,
};

/// Scale factor band boundaries for short blocks (MPEG1, 44100 Hz)
pub const sfb_short_44100 = [_]u16{
    0, 4, 8, 12, 16, 22, 30, 40, 52, 66, 84, 106, 136, 192,
};

/// Scale factor band boundaries for short blocks (MPEG1, 48000 Hz)
pub const sfb_short_48000 = [_]u16{
    0, 4, 8, 12, 16, 22, 28, 38, 50, 64, 80, 100, 126, 192,
};

/// Scale factor band boundaries for short blocks (MPEG1, 32000 Hz)
pub const sfb_short_32000 = [_]u16{
    0, 4, 8, 12, 16, 22, 30, 42, 58, 78, 104, 138, 180, 192,
};

/// MPEG2 scale factor band boundaries (22050 Hz long blocks)
pub const sfb_long_22050 = [_]u16{
    0, 6, 12, 18, 24, 30, 36, 44, 54, 66,
    80, 96, 116, 140, 168, 200, 238, 284, 336, 396,
    464, 522, 576,
};

/// MPEG2 scale factor band boundaries (24000 Hz long blocks)
pub const sfb_long_24000 = [_]u16{
    0, 6, 12, 18, 24, 30, 36, 44, 54, 66,
    80, 96, 114, 136, 162, 194, 232, 278, 332, 394,
    464, 540, 576,
};

/// MPEG2 scale factor band boundaries (16000 Hz long blocks)
pub const sfb_long_16000 = [_]u16{
    0, 6, 12, 18, 24, 30, 36, 44, 54, 66,
    80, 96, 116, 140, 168, 200, 238, 284, 336, 396,
    464, 522, 576,
};

// ============================================================
// Quantization Tables
// ============================================================

/// Requantization power table: i^(4/3) for requantization
/// Used for: sample = sign * |sample|^(4/3) * 2^((global_gain-210)/4) * 2^(-scalefac * scalefac_scale)
/// Computed at runtime initialization to avoid comptime branch limits
pub var pow43_table: [8207]i32 = undefined;
pub var pow43_initialized: bool = false;

pub fn initPow43Table() void {
    if (pow43_initialized) return;
    for (0..8207) |i| {
        // Calculate i^(4/3) scaled with 8 fractional bits
        const f: f64 = @floatFromInt(i);
        const pow = std.math.pow(f64, f, 4.0 / 3.0);
        pow43_table[i] = @intFromFloat(pow * 256.0);
    }
    pow43_initialized = true;
}

/// Power of 2 table for gain calculations (Q8.24 fixed point)
/// Index = gain value, output = 2^(gain/4)
pub const pow2_table = blk: {
    var table: [256]i32 = undefined;
    for (0..256) |i| {
        const exp: f64 = @as(f64, @floatFromInt(i)) / 4.0;
        const val = std.math.pow(f64, 2.0, exp);
        // Normalize to reasonable range
        if (val > 2147483647.0) {
            table[i] = 2147483647;
        } else {
            table[i] = @intFromFloat(val);
        }
    }
    break :blk table;
};

/// Scalefactor pretab (used for certain windows)
pub const pretab = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0,
};

// ============================================================
// IMDCT Tables
// ============================================================

/// IMDCT window coefficients for long blocks (36 samples)
pub const imdct_win_long = blk: {
    var win: [36]i32 = undefined;
    for (0..36) |i| {
        const fi: f64 = @floatFromInt(i);
        const val = @sin(std.math.pi / 36.0 * (fi + 0.5));
        win[i] = @intFromFloat(val * 32768.0);
    }
    break :blk win;
};

/// IMDCT window coefficients for short blocks (12 samples)
pub const imdct_win_short = blk: {
    var win: [12]i32 = undefined;
    for (0..12) |i| {
        const fi: f64 = @floatFromInt(i);
        const val = @sin(std.math.pi / 12.0 * (fi + 0.5));
        win[i] = @intFromFloat(val * 32768.0);
    }
    break :blk win;
};

/// IMDCT window for start block (transition long->short)
pub const imdct_win_start = [_]i32{
    // First 18: sine window
    1608, 4808, 7962, 11039, 14010, 16846, 19519, 22005, 24279,
    26319, 28105, 29621, 30852, 31785, 32412, 32724, 32724, 32412,
    // Next 6: flat at 1.0
    32768, 32768, 32768, 32768, 32768, 32768,
    // Last 12: short window descending
    31164, 27246, 20860, 12540, 3212, 0, 0, 0, 0, 0, 0, 0,
};

/// IMDCT window for stop block (transition short->long)
pub const imdct_win_stop = [_]i32{
    // First 6: zeros
    0, 0, 0, 0, 0, 0,
    // Next 12: short window ascending
    3212, 12540, 20860, 27246, 31164, 32768,
    // Last 18: sine window descending
    32768, 32768, 32768, 32768, 32768, 32768,
    32412, 32724, 32724, 32412, 31785, 30852,
    29621, 28105, 26319, 24279, 22005, 19519,
};

/// IMDCT cosine table for 36-point transform
pub const imdct_cos36 = blk: {
    var table: [36][18]i32 = undefined;
    for (0..36) |i| {
        for (0..18) |k| {
            const fi: f64 = @floatFromInt(i);
            const fk: f64 = @floatFromInt(k);
            const val = @cos(std.math.pi / 72.0 * (2.0 * fi + 19.0) * (2.0 * fk + 1.0));
            table[i][k] = @intFromFloat(val * 32768.0);
        }
    }
    break :blk table;
};

/// IMDCT cosine table for 12-point transform
pub const imdct_cos12 = blk: {
    var table: [12][6]i32 = undefined;
    for (0..12) |i| {
        for (0..6) |k| {
            const fi: f64 = @floatFromInt(i);
            const fk: f64 = @floatFromInt(k);
            const val = @cos(std.math.pi / 24.0 * (2.0 * fi + 7.0) * (2.0 * fk + 1.0));
            table[i][k] = @intFromFloat(val * 32768.0);
        }
    }
    break :blk table;
};

// ============================================================
// Synthesis Filterbank Tables
// ============================================================

/// Synthesis window coefficients (512 entries)
/// These are the D[i] coefficients from the ISO standard
pub const synth_window = [_]i32{
    // Subband 0
    0, -1, -1, -1, -1, -1, -1, -2, -2, -2, -2, -3, -3, -4, -4, -5,
    -5, -6, -7, -7, -8, -9, -10, -11, -13, -14, -16, -17, -19, -21, -24, -26,
    -29, -31, -35, -38, -41, -45, -49, -53, -58, -63, -68, -73, -79, -85, -91, -97,
    -104, -111, -117, -125, -132, -139, -147, -154, -161, -169, -176, -183, -190, -196, -202, -208,
    213, 218, 222, 225, 227, 228, 228, 227, 224, 221, 215, 208, 200, 189, 177, 163,
    146, 127, 106, 83, 57, 29, -2, -36, -72, -111, -153, -197, -244, -294, -347, -401,
    -459, -519, -581, -645, -711, -779, -848, -919, -991, -1064, -1137, -1210, -1283, -1356, -1428, -1498,
    -1567, -1634, -1698, -1759, -1817, -1870, -1919, -1962, -2001, -2032, -2057, -2075, -2085, -2087, -2080, -2063,
    2037, 2000, 1952, 1893, 1822, 1739, 1644, 1535, 1414, 1280, 1131, 970, 794, 605, 402, 185,
    -45, -288, -545, -814, -1095, -1388, -1692, -2006, -2330, -2663, -3004, -3351, -3705, -4063, -4425, -4788,
    -5153, -5517, -5879, -6237, -6589, -6935, -7271, -7597, -7910, -8209, -8491, -8755, -8998, -9219, -9416, -9585,
    -9727, -9838, -9916, -9959, -9966, -9935, -9863, -9750, -9592, -9389, -9139, -8840, -8492, -8092, -7640, -7134,
    6574, 5959, 5288, 4561, 3776, 2935, 2037, 1082, 70, -998, -2122, -3300, -4533, -5818, -7154, -8540,
    -9975, -11455, -12980, -14548, -16155, -17799, -19478, -21189, -22929, -24694, -26482, -28289, -30112, -31947, -33791, -35640,
    -37489, -39336, -41176, -43006, -44821, -46617, -48390, -50137, -51853, -53534, -55178, -56778, -58333, -59838, -61289, -62684,
    -64019, -65290, -66494, -67629, -68692, -69679, -70590, -71420, -72169, -72835, -73415, -73908, -74313, -74630, -74856, -74992,
    75038, 74992, 74856, 74630, 74313, 73908, 73415, 72835, 72169, 71420, 70590, 69679, 68692, 67629, 66494, 65290,
    64019, 62684, 61289, 59838, 58333, 56778, 55178, 53534, 51853, 50137, 48390, 46617, 44821, 43006, 41176, 39336,
    37489, 35640, 33791, 31947, 30112, 28289, 26482, 24694, 22929, 21189, 19478, 17799, 16155, 14548, 12980, 11455,
    9975, 8540, 7154, 5818, 4533, 3300, 2122, 998, -70, -1082, -2037, -2935, -3776, -4561, -5288, -5959,
    -6574, -7134, -7640, -8092, -8492, -8840, -9139, -9389, -9592, -9750, -9863, -9935, -9966, -9959, -9916, -9838,
    -9727, -9585, -9416, -9219, -8998, -8755, -8491, -8209, -7910, -7597, -7271, -6935, -6589, -6237, -5879, -5517,
    -5153, -4788, -4425, -4063, -3705, -3351, -3004, -2663, -2330, -2006, -1692, -1388, -1095, -814, -545, -288,
    45, 185, 402, 605, 794, 970, 1131, 1280, 1414, 1535, 1644, 1739, 1822, 1893, 1952, 2000,
    -2037, -2063, -2080, -2087, -2085, -2075, -2057, -2032, -2001, -1962, -1919, -1870, -1817, -1759, -1698, -1634,
    -1567, -1498, -1428, -1356, -1283, -1210, -1137, -1064, -991, -919, -848, -779, -711, -645, -581, -519,
    -459, -401, -347, -294, -244, -197, -153, -111, -72, -36, -2, 29, 57, 83, 106, 127,
    146, 163, 177, 189, 200, 208, 215, 221, 224, 227, 228, 228, 227, 225, 222, 218,
    -213, -208, -202, -196, -190, -183, -176, -169, -161, -154, -147, -139, -132, -125, -117, -111,
    -104, -97, -91, -85, -79, -73, -68, -63, -58, -53, -49, -45, -41, -38, -35, -31,
    -29, -26, -24, -21, -19, -17, -16, -14, -13, -11, -10, -9, -8, -7, -7, -6,
    -5, -5, -4, -4, -3, -3, -2, -2, -2, -2, -1, -1, -1, -1, -1, -1,
};

/// DCT-32 cosine table for synthesis filterbank
pub const dct32_cos = blk: {
    @setEvalBranchQuota(10000);
    var table: [32][32]i32 = undefined;
    for (0..32) |i| {
        for (0..32) |k| {
            const fi: f64 = @floatFromInt(i);
            const fk: f64 = @floatFromInt(k);
            const val = @cos(std.math.pi / 64.0 * (2.0 * fi + 1.0) * (2.0 * fk + 1.0));
            table[i][k] = @intFromFloat(val * 32768.0);
        }
    }
    break :blk table;
};

// ============================================================
// Antialias Coefficients
// ============================================================

/// Antialias butterfly coefficients (cs)
pub const antialias_cs = [_]i32{
    28098, 28893, 31117, 32221, 32621, 32740, 32765, 32768,
};

/// Antialias butterfly coefficients (ca)
pub const antialias_ca = [_]i32{
    -15447, -10268, -5765, -2896, -1315, -546, -191, -60,
};

// ============================================================
// Stereo Processing Tables
// ============================================================

/// Intensity stereo ratio table (is_ratio)
/// is_ratio[i] = tan(i * PI/12) for i = 0..6
pub const is_ratio = [_]i32{
    0, 5765, 11585, 18919, 28377, 42432, 65536, // Q16 format
};

/// MS stereo normalization: 1/sqrt(2) in Q15
pub const ms_norm: i32 = 23170;

// ============================================================
// Miscellaneous Tables
// ============================================================

/// Reorder table for short blocks
/// Maps frequency-interleaved samples to window-interleaved
pub fn getReorderTable(sample_rate: u32) []const u16 {
    // Generate reorder indices based on scale factor bands
    return switch (sample_rate) {
        44100 => &reorder_44100,
        48000 => &reorder_48000,
        32000 => &reorder_32000,
        else => &reorder_44100,
    };
}

const reorder_44100 = blk: {
    var table: [576]u16 = undefined;
    var idx: usize = 0;
    for (0..13) |sfb| {
        const width = sfb_short_44100[sfb + 1] - sfb_short_44100[sfb];
        for (0..3) |win| {
            for (0..width) |i| {
                table[idx] = @intCast(sfb_short_44100[sfb] * 3 + win + i * 3);
                idx += 1;
            }
        }
    }
    break :blk table;
};

const reorder_48000 = blk: {
    var table: [576]u16 = undefined;
    var idx: usize = 0;
    for (0..13) |sfb| {
        const width = sfb_short_48000[sfb + 1] - sfb_short_48000[sfb];
        for (0..3) |win| {
            for (0..width) |i| {
                table[idx] = @intCast(sfb_short_48000[sfb] * 3 + win + i * 3);
                idx += 1;
            }
        }
    }
    break :blk table;
};

const reorder_32000 = blk: {
    var table: [576]u16 = undefined;
    var idx: usize = 0;
    for (0..13) |sfb| {
        const width = sfb_short_32000[sfb + 1] - sfb_short_32000[sfb];
        for (0..3) |win| {
            for (0..width) |i| {
                table[idx] = @intCast(sfb_short_32000[sfb] * 3 + win + i * 3);
                idx += 1;
            }
        }
    }
    break :blk table;
};

// ============================================================
// Tests
// ============================================================

test "pow43 table sanity" {
    // Initialize the runtime table
    initPow43Table();
    // 0^(4/3) = 0
    try std.testing.expectEqual(@as(i32, 0), pow43_table[0]);
    // 1^(4/3) = 1, scaled by 256 = 256
    try std.testing.expectEqual(@as(i32, 256), pow43_table[1]);
    // 8^(4/3) = 16, scaled = 4096 (allow +-1 for floating point rounding)
    try std.testing.expect(pow43_table[8] >= 4095 and pow43_table[8] <= 4097);
}

test "imdct window long" {
    // Window should be symmetric around center
    try std.testing.expect(imdct_win_long[0] > 0);
    try std.testing.expect(imdct_win_long[17] > imdct_win_long[0]);
    // Peak should be near center
    try std.testing.expect(imdct_win_long[17] > 30000);
}

test "synth window length" {
    try std.testing.expectEqual(@as(usize, 512), synth_window.len);
}
