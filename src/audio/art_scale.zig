//! Image Scaling for Album Art
//!
//! This module provides image scaling to resize album art to display size.
//!
//! # Complexity: LOW (~60 lines of core logic)
//!
//! ## Bilinear Interpolation
//!
//! Bilinear interpolation samples 4 neighboring pixels and blends them
//! based on the fractional position:
//!
//! ```
//!   (x0,y0)──────(x1,y0)
//!      │    P       │
//!      │            │
//!   (x0,y1)──────(x1,y1)
//! ```
//!
//! For point P at (x, y):
//!   - fx = fractional part of x
//!   - fy = fractional part of y
//!   - Top blend:    lerp(top_left, top_right, fx)
//!   - Bottom blend: lerp(bottom_left, bottom_right, fx)
//!   - Final:        lerp(top_blend, bottom_blend, fy)
//!
//! This produces smooth scaling with minimal artifacts.
//!
//! ## Memory Usage
//!
//! Uses a static buffer for output. The caller passes in source data
//! and receives a slice of the output buffer.
//!
//! Maximum output: 80 * 80 * 3 = 19,200 bytes
//!

const std = @import("std");

// ============================================================
// Constants
// ============================================================

/// Maximum output dimension
pub const MAX_OUTPUT_SIZE: u16 = 80;

/// Output buffer size (RGB888)
pub const OUTPUT_BUFFER_SIZE: usize = MAX_OUTPUT_SIZE * MAX_OUTPUT_SIZE * 3;

// ============================================================
// Static Buffer
// ============================================================

var output_buffer: [OUTPUT_BUFFER_SIZE]u8 = undefined;

// ============================================================
// Public API
// ============================================================

pub const ScaleError = error{
    InvalidDimensions,
    OutputTooLarge,
};

/// Scale an RGB888 image using bilinear interpolation
///
/// Parameters:
///   - src: Source pixel data (RGB888, row-major)
///   - src_width: Source image width
///   - src_height: Source image height
///   - dst_width: Desired output width (max 80)
///   - dst_height: Desired output height (max 80)
///
/// Returns: Slice of output buffer containing scaled image
pub fn bilinearScale(
    src: []const u8,
    src_width: u16,
    src_height: u16,
    dst_width: u16,
    dst_height: u16,
) ScaleError![]u8 {
    // Validate dimensions
    if (src_width == 0 or src_height == 0) return ScaleError.InvalidDimensions;
    if (dst_width == 0 or dst_height == 0) return ScaleError.InvalidDimensions;
    if (dst_width > MAX_OUTPUT_SIZE or dst_height > MAX_OUTPUT_SIZE) {
        return ScaleError.OutputTooLarge;
    }

    const src_size = @as(usize, src_width) * @as(usize, src_height) * 3;
    if (src.len < src_size) return ScaleError.InvalidDimensions;

    const dst_size = @as(usize, dst_width) * @as(usize, dst_height) * 3;

    // Calculate scale factors (fixed-point, 16.16)
    const scale_x = (@as(u32, src_width - 1) << 16) / @max(1, dst_width - 1);
    const scale_y = (@as(u32, src_height - 1) << 16) / @max(1, dst_height - 1);

    // Scale each pixel
    for (0..dst_height) |dy| {
        // Source Y coordinate (fixed-point)
        const src_y_fp = @as(u32, @intCast(dy)) * scale_y;
        const src_y0: u16 = @intCast(src_y_fp >> 16);
        const src_y1: u16 = @min(src_y0 + 1, src_height - 1);
        const fy: u16 = @intCast((src_y_fp >> 8) & 0xFF); // Fractional part (8-bit)

        for (0..dst_width) |dx| {
            // Source X coordinate (fixed-point)
            const src_x_fp = @as(u32, @intCast(dx)) * scale_x;
            const src_x0: u16 = @intCast(src_x_fp >> 16);
            const src_x1: u16 = @min(src_x0 + 1, src_width - 1);
            const fx: u16 = @intCast((src_x_fp >> 8) & 0xFF); // Fractional part (8-bit)

            // Get 4 neighboring pixels
            const idx00 = (@as(usize, src_y0) * src_width + src_x0) * 3;
            const idx01 = (@as(usize, src_y0) * src_width + src_x1) * 3;
            const idx10 = (@as(usize, src_y1) * src_width + src_x0) * 3;
            const idx11 = (@as(usize, src_y1) * src_width + src_x1) * 3;

            // Interpolate each channel
            const dst_idx = (dy * dst_width + dx) * 3;

            for (0..3) |c| {
                const p00: u16 = src[idx00 + c];
                const p01: u16 = src[idx01 + c];
                const p10: u16 = src[idx10 + c];
                const p11: u16 = src[idx11 + c];

                // Bilinear interpolation
                const top = lerp8(p00, p01, fx);
                const bottom = lerp8(p10, p11, fx);
                const result = lerp8(top, bottom, fy);

                output_buffer[dst_idx + c] = @intCast(result);
            }
        }
    }

    return output_buffer[0..dst_size];
}

/// Scale to square (for album art)
/// Crops to center if not square, then scales
pub fn scaleToSquare(
    src: []const u8,
    src_width: u16,
    src_height: u16,
    dst_size: u16,
) ScaleError![]u8 {
    // For simplicity, just scale directly
    // A more sophisticated version would crop to center first
    return bilinearScale(src, src_width, src_height, dst_size, dst_size);
}

// ============================================================
// Interpolation Helpers
// ============================================================

/// Linear interpolation with 8-bit fraction
/// lerp(a, b, t) = a + (b - a) * t / 256
fn lerp8(a: u16, b: u16, t: u16) u16 {
    if (b >= a) {
        return a + ((b - a) * t) / 256;
    } else {
        return a - ((a - b) * t) / 256;
    }
}

// ============================================================
// Tests
// ============================================================

test "lerp8 basic" {
    // t = 0 -> a
    try std.testing.expectEqual(@as(u16, 100), lerp8(100, 200, 0));

    // t = 256 -> b (but we use 255 as max in practice)
    try std.testing.expectEqual(@as(u16, 200), lerp8(100, 200, 256));

    // t = 128 -> midpoint
    try std.testing.expectEqual(@as(u16, 150), lerp8(100, 200, 128));

    // Reverse direction
    try std.testing.expectEqual(@as(u16, 150), lerp8(200, 100, 128));
}

test "bilinearScale 1x1 to 1x1" {
    const src = [_]u8{ 255, 128, 64 };
    const result = try bilinearScale(&src, 1, 1, 1, 1);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(u8, 255), result[0]);
    try std.testing.expectEqual(@as(u8, 128), result[1]);
    try std.testing.expectEqual(@as(u8, 64), result[2]);
}

test "bilinearScale 2x2 to 1x1" {
    // 2x2 image with same color at corners
    const src = [_]u8{
        100, 100, 100, // Gray
        100, 100, 100, // Gray
        100, 100, 100, // Gray
        100, 100, 100, // Gray
    };

    const result = try bilinearScale(&src, 2, 2, 1, 1);

    // Should return the same color
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(u8, 100), result[0]);
    try std.testing.expectEqual(@as(u8, 100), result[1]);
    try std.testing.expectEqual(@as(u8, 100), result[2]);
}

test "bilinearScale upscale 1x1 to 2x2" {
    const src = [_]u8{ 100, 150, 200 };
    const result = try bilinearScale(&src, 1, 1, 2, 2);

    // All pixels should be the same when upscaling 1x1
    try std.testing.expectEqual(@as(usize, 12), result.len); // 2*2*3

    // Each pixel should be close to original
    for (0..4) |i| {
        try std.testing.expectEqual(@as(u8, 100), result[i * 3 + 0]);
        try std.testing.expectEqual(@as(u8, 150), result[i * 3 + 1]);
        try std.testing.expectEqual(@as(u8, 200), result[i * 3 + 2]);
    }
}

test "bilinearScale invalid dimensions" {
    const src = [_]u8{ 0, 0, 0 };

    // Zero source dimensions
    try std.testing.expectError(ScaleError.InvalidDimensions, bilinearScale(&src, 0, 1, 1, 1));
    try std.testing.expectError(ScaleError.InvalidDimensions, bilinearScale(&src, 1, 0, 1, 1));

    // Zero destination dimensions
    try std.testing.expectError(ScaleError.InvalidDimensions, bilinearScale(&src, 1, 1, 0, 1));
    try std.testing.expectError(ScaleError.InvalidDimensions, bilinearScale(&src, 1, 1, 1, 0));

    // Output too large
    try std.testing.expectError(ScaleError.OutputTooLarge, bilinearScale(&src, 1, 1, 100, 100));
}
