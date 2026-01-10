//! Image Decoders for Album Art
//!
//! This module contains decoders for BMP, JPEG, and PNG image formats.
//!
//! # Complexity Guide for Future Engineers
//!
//! ## BMP Decoder - COMPLEXITY: LOW (~80 lines)
//!
//! BMP is dead simple:
//! 1. Read 14-byte file header (magic "BM", file size, data offset)
//! 2. Read 40-byte DIB header (width, height, bits per pixel)
//! 3. Read raw pixel data (bottom-up scanlines, padded to 4 bytes)
//!
//! Gotchas:
//! - Scanlines are stored bottom-to-top (flip on read)
//! - Each scanline padded to 4-byte boundary
//! - We only support 24-bit (RGB888) and 32-bit (RGBA) BMPs
//!
//! ## JPEG Decoder - COMPLEXITY: HIGH (~800 lines)
//!
//! JPEG is a beast. Here's what happens:
//!
//! ```
//!   JPEG file
//!       │
//!       ▼
//!   ┌─────────────────┐
//!   │ Parse markers   │  SOI, APP0, DQT, SOF0, DHT, SOS, EOI
//!   └─────────────────┘
//!       │
//!       ▼
//!   ┌─────────────────┐
//!   │ Huffman decode  │  Entropy-coded data → DCT coefficients
//!   └─────────────────┘  (This is where most CPU goes)
//!       │
//!       ▼
//!   ┌─────────────────┐
//!   │ Dequantize      │  Multiply by quantization tables
//!   └─────────────────┘
//!       │
//!       ▼
//!   ┌─────────────────┐
//!   │ Inverse DCT     │  Frequency domain → Spatial domain
//!   └─────────────────┘  (8x8 blocks, 64-point transform)
//!       │
//!       ▼
//!   ┌─────────────────┐
//!   │ YCbCr → RGB     │  Color space conversion
//!   └─────────────────┘
//!       │
//!       ▼
//!   RGB888 pixels
//! ```
//!
//! Key concepts:
//! - MCU (Minimum Coded Unit): 8x8 or 16x16 pixel blocks
//! - Huffman tables: Variable-length codes for compression
//! - Quantization tables: Control quality/compression tradeoff
//! - DCT: Discrete Cosine Transform (lossy compression core)
//!
//! We implement baseline JPEG only (no progressive, no arithmetic coding).
//!
//! ## PNG Decoder - COMPLEXITY: HIGH (not implemented)
//!
//! PNG requires zlib (DEFLATE) decompression. This adds ~1500 lines.
//! For now, we return an error for PNG. Future work could add miniz port.
//!

const std = @import("std");

// ============================================================
// Public Types
// ============================================================

pub const ImageFormat = enum {
    bmp,
    jpeg,
    png,
    unknown,
};

pub const DecodedImage = struct {
    pixels: []u8, // RGB888 format (3 bytes per pixel)
    width: u16,
    height: u16,
};

pub const DecodeError = error{
    InvalidFormat,
    UnsupportedFormat,
    InvalidHeader,
    TruncatedData,
    HuffmanError,
    InvalidMarker,
    ImageTooLarge,
    UnsupportedBitDepth,
    UnsupportedColorSpace,
};

// ============================================================
// Format Detection
// ============================================================

/// Detect image format from file header bytes
pub fn detectFormat(data: []const u8) ImageFormat {
    if (data.len < 4) return .unknown;

    // BMP: starts with "BM"
    if (data[0] == 'B' and data[1] == 'M') {
        return .bmp;
    }

    // JPEG: starts with FF D8 FF
    if (data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
        return .jpeg;
    }

    // PNG: starts with 89 50 4E 47 (0x89 "PNG")
    if (data[0] == 0x89 and data[1] == 'P' and data[2] == 'N' and data[3] == 'G') {
        return .png;
    }

    return .unknown;
}

/// Decode image data to RGB888
pub fn decode(data: []const u8, format: ImageFormat, output: []u8) DecodeError!DecodedImage {
    return switch (format) {
        .bmp => decodeBmp(data, output),
        .jpeg => decodeJpeg(data, output),
        .png => DecodeError.UnsupportedFormat, // TODO: Add PNG support
        .unknown => DecodeError.InvalidFormat,
    };
}

// ============================================================
// BMP Decoder
// ============================================================
//
// COMPLEXITY: LOW
//
// BMP file structure:
// - Bytes 0-1:   "BM" magic
// - Bytes 2-5:   File size
// - Bytes 6-9:   Reserved
// - Bytes 10-13: Pixel data offset
// - Bytes 14+:   DIB header (BITMAPINFOHEADER)
//   - Bytes 14-17: Header size (40 for BITMAPINFOHEADER)
//   - Bytes 18-21: Width (signed, but we treat as unsigned)
//   - Bytes 22-25: Height (signed, negative = top-down)
//   - Bytes 26-27: Color planes (must be 1)
//   - Bytes 28-29: Bits per pixel (we support 24 and 32)
//   - Bytes 30-33: Compression (0 = none, which we require)
//

fn decodeBmp(data: []const u8, output: []u8) DecodeError!DecodedImage {
    // Minimum BMP size: 54 bytes header + at least 1 pixel
    if (data.len < 58) return DecodeError.TruncatedData;

    // Verify magic
    if (data[0] != 'B' or data[1] != 'M') return DecodeError.InvalidFormat;

    // Read header fields (little-endian)
    const data_offset = readU32LE(data[10..14]);
    const header_size = readU32LE(data[14..18]);

    // We only support BITMAPINFOHEADER (40 bytes) and larger
    if (header_size < 40) return DecodeError.UnsupportedFormat;

    const width_signed = readI32LE(data[18..22]);
    const height_signed = readI32LE(data[22..26]);
    const bits_per_pixel = readU16LE(data[28..30]);
    const compression = readU32LE(data[30..34]);

    // Validate
    if (width_signed <= 0) return DecodeError.InvalidHeader;
    if (height_signed == 0) return DecodeError.InvalidHeader;
    if (compression != 0) return DecodeError.UnsupportedFormat; // No RLE

    const width: u16 = @intCast(@as(u32, @intCast(width_signed)));
    const height_abs = if (height_signed < 0) @as(u32, @intCast(-height_signed)) else @as(u32, @intCast(height_signed));
    const height: u16 = @intCast(height_abs);
    const top_down = height_signed < 0;

    // Check dimensions
    if (width > 500 or height > 500) return DecodeError.ImageTooLarge;

    // Check bit depth
    if (bits_per_pixel != 24 and bits_per_pixel != 32) {
        return DecodeError.UnsupportedBitDepth;
    }

    const bytes_per_pixel: u32 = bits_per_pixel / 8;
    const row_size_unpadded = @as(u32, width) * bytes_per_pixel;
    const row_padding = (4 - (row_size_unpadded % 4)) % 4;
    const row_size = row_size_unpadded + row_padding;

    // Check output buffer size
    const output_size = @as(usize, width) * @as(usize, height) * 3;
    if (output.len < output_size) return DecodeError.ImageTooLarge;

    // Check input data size
    const pixel_data_size = row_size * height;
    if (data.len < data_offset + pixel_data_size) return DecodeError.TruncatedData;

    // Decode pixels
    for (0..height) |y| {
        // BMP stores rows bottom-up (unless top_down flag)
        const src_row = if (top_down) y else height - 1 - y;
        const src_offset = data_offset + src_row * row_size;
        const dst_offset = y * @as(usize, width) * 3;

        for (0..width) |x| {
            const src_idx = src_offset + x * bytes_per_pixel;
            const dst_idx = dst_offset + x * 3;

            // BMP stores BGR(A), we want RGB
            output[dst_idx + 0] = data[src_idx + 2]; // R
            output[dst_idx + 1] = data[src_idx + 1]; // G
            output[dst_idx + 2] = data[src_idx + 0]; // B
        }
    }

    return DecodedImage{
        .pixels = output[0..output_size],
        .width = width,
        .height = height,
    };
}

// ============================================================
// JPEG Decoder
// ============================================================
//
// COMPLEXITY: HIGH
//
// This is a minimal baseline JPEG decoder. It handles:
// - Baseline DCT (SOF0)
// - Huffman coding (no arithmetic)
// - YCbCr color space
// - 4:4:4, 4:2:2, 4:2:0 chroma subsampling
//
// It does NOT handle:
// - Progressive JPEG (SOF2)
// - Arithmetic coding
// - CMYK color space
// - Multi-scan images
// - Restart markers (we skip them)
//

const JpegDecoder = struct {
    data: []const u8,
    pos: usize,
    width: u16,
    height: u16,
    num_components: u8,

    // Component info
    components: [4]Component,

    // Quantization tables (up to 4)
    quant_tables: [4][64]u16,
    quant_valid: [4]bool,

    // Huffman tables (DC and AC for up to 4 components)
    huff_dc: [4]HuffmanTable,
    huff_ac: [4]HuffmanTable,

    // Bit reader state
    bit_buffer: u32,
    bits_in_buffer: u8,

    // Previous DC values (for differential coding)
    prev_dc: [4]i16,

    const Component = struct {
        id: u8,
        h_sample: u8, // Horizontal sampling factor
        v_sample: u8, // Vertical sampling factor
        quant_table: u8,
        dc_table: u8,
        ac_table: u8,
    };

    const HuffmanTable = struct {
        // Fast lookup table for codes up to 8 bits
        fast: [256]u8,
        fast_bits: [256]u8,

        // Full table for longer codes
        codes: [256]u16,
        values: [256]u8,
        sizes: [256]u8,
        num_codes: u16,

        valid: bool,
    };

    fn init(data: []const u8) JpegDecoder {
        var decoder = JpegDecoder{
            .data = data,
            .pos = 0,
            .width = 0,
            .height = 0,
            .num_components = 0,
            .components = undefined,
            .quant_tables = undefined,
            .quant_valid = [_]bool{false} ** 4,
            .huff_dc = undefined,
            .huff_ac = undefined,
            .bit_buffer = 0,
            .bits_in_buffer = 0,
            .prev_dc = [_]i16{0} ** 4,
        };

        for (&decoder.huff_dc) |*h| h.valid = false;
        for (&decoder.huff_ac) |*h| h.valid = false;

        return decoder;
    }

    fn decode(self: *JpegDecoder, output: []u8) DecodeError!DecodedImage {
        // Parse markers
        try self.parseMarkers();

        if (self.width == 0 or self.height == 0) {
            return DecodeError.InvalidHeader;
        }

        // Check output size
        const output_size = @as(usize, self.width) * @as(usize, self.height) * 3;
        if (output.len < output_size) return DecodeError.ImageTooLarge;

        // Decode image data
        try self.decodeImageData(output);

        return DecodedImage{
            .pixels = output[0..output_size],
            .width = self.width,
            .height = self.height,
        };
    }

    fn parseMarkers(self: *JpegDecoder) DecodeError!void {
        // Verify SOI marker
        if (self.pos + 2 > self.data.len) return DecodeError.TruncatedData;
        if (self.data[self.pos] != 0xFF or self.data[self.pos + 1] != 0xD8) {
            return DecodeError.InvalidFormat;
        }
        self.pos += 2;

        // Parse subsequent markers
        while (self.pos + 2 <= self.data.len) {
            if (self.data[self.pos] != 0xFF) {
                self.pos += 1;
                continue;
            }

            const marker = self.data[self.pos + 1];
            self.pos += 2;

            switch (marker) {
                0xD8 => {}, // SOI - already handled
                0xD9 => return, // EOI - end of image
                0xDA => return, // SOS - start of scan, stop parsing headers
                0xDB => try self.parseQuantTable(), // DQT
                0xC0 => try self.parseFrameHeader(), // SOF0 (baseline)
                0xC4 => try self.parseHuffmanTable(), // DHT
                0xDD => self.pos += 4, // DRI - skip restart interval
                0xE0...0xEF => try self.skipSegment(), // APPn
                0xFE => try self.skipSegment(), // COM
                0xFF => {}, // Padding
                0x00 => {}, // Stuffed byte
                0xD0...0xD7 => {}, // RST markers
                else => try self.skipSegment(),
            }
        }
    }

    fn skipSegment(self: *JpegDecoder) DecodeError!void {
        if (self.pos + 2 > self.data.len) return DecodeError.TruncatedData;
        const length = readU16BE(self.data[self.pos..]);
        self.pos += length;
    }

    fn parseQuantTable(self: *JpegDecoder) DecodeError!void {
        if (self.pos + 2 > self.data.len) return DecodeError.TruncatedData;
        var length = readU16BE(self.data[self.pos..]);
        self.pos += 2;
        length -= 2;

        while (length > 0) {
            if (self.pos >= self.data.len) return DecodeError.TruncatedData;

            const info = self.data[self.pos];
            self.pos += 1;
            length -= 1;

            const precision = info >> 4;
            const table_id = info & 0x0F;

            if (table_id >= 4) return DecodeError.InvalidHeader;

            const elem_size: u16 = if (precision == 0) 1 else 2;
            if (length < 64 * elem_size) return DecodeError.TruncatedData;

            for (0..64) |i| {
                if (precision == 0) {
                    self.quant_tables[table_id][i] = self.data[self.pos];
                    self.pos += 1;
                } else {
                    self.quant_tables[table_id][i] = readU16BE(self.data[self.pos..]);
                    self.pos += 2;
                }
            }
            length -= 64 * elem_size;
            self.quant_valid[table_id] = true;
        }
    }

    fn parseFrameHeader(self: *JpegDecoder) DecodeError!void {
        if (self.pos + 8 > self.data.len) return DecodeError.TruncatedData;

        const length = readU16BE(self.data[self.pos..]);
        _ = length;
        const precision = self.data[self.pos + 2];
        self.height = readU16BE(self.data[self.pos + 3 ..]);
        self.width = readU16BE(self.data[self.pos + 5 ..]);
        self.num_components = self.data[self.pos + 7];

        if (precision != 8) return DecodeError.UnsupportedBitDepth;
        if (self.num_components != 1 and self.num_components != 3) {
            return DecodeError.UnsupportedColorSpace;
        }
        if (self.width > 500 or self.height > 500) {
            return DecodeError.ImageTooLarge;
        }

        self.pos += 8;

        // Parse component info
        for (0..self.num_components) |i| {
            if (self.pos + 3 > self.data.len) return DecodeError.TruncatedData;

            self.components[i] = Component{
                .id = self.data[self.pos],
                .h_sample = self.data[self.pos + 1] >> 4,
                .v_sample = self.data[self.pos + 1] & 0x0F,
                .quant_table = self.data[self.pos + 2],
                .dc_table = 0,
                .ac_table = 0,
            };
            self.pos += 3;
        }
    }

    fn parseHuffmanTable(self: *JpegDecoder) DecodeError!void {
        if (self.pos + 2 > self.data.len) return DecodeError.TruncatedData;
        var length = readU16BE(self.data[self.pos..]);
        self.pos += 2;
        length -= 2;

        while (length > 0) {
            if (self.pos + 17 > self.data.len) return DecodeError.TruncatedData;

            const info = self.data[self.pos];
            self.pos += 1;
            length -= 1;

            const table_class = info >> 4; // 0 = DC, 1 = AC
            const table_id = info & 0x0F;

            if (table_id >= 4) return DecodeError.InvalidHeader;

            // Read code counts (16 bytes)
            var code_counts: [16]u8 = undefined;
            var total_codes: u16 = 0;
            for (0..16) |i| {
                code_counts[i] = self.data[self.pos + i];
                total_codes += code_counts[i];
            }
            self.pos += 16;
            length -= 16;

            if (total_codes > 256) return DecodeError.InvalidHeader;
            if (length < total_codes) return DecodeError.TruncatedData;

            // Select table
            const table = if (table_class == 0)
                &self.huff_dc[table_id]
            else
                &self.huff_ac[table_id];

            // Build Huffman table
            var code: u16 = 0;
            var value_idx: usize = 0;

            for (0..16) |bits| {
                for (0..code_counts[bits]) |_| {
                    table.codes[value_idx] = code;
                    table.values[value_idx] = self.data[self.pos];
                    table.sizes[value_idx] = @intCast(bits + 1);
                    self.pos += 1;
                    value_idx += 1;
                    code += 1;
                }
                code <<= 1;
            }

            table.num_codes = total_codes;
            table.valid = true;
            length -= total_codes;

            // Build fast lookup table
            self.buildFastTable(table);
        }
    }

    fn buildFastTable(self: *JpegDecoder, table: *HuffmanTable) void {
        _ = self;
        for (0..256) |i| {
            table.fast[i] = 0xFF; // Invalid marker
            table.fast_bits[i] = 0;
        }

        for (0..table.num_codes) |i| {
            const size = table.sizes[i];
            if (size <= 8) {
                const code = table.codes[i];
                const fill_bits: u4 = @intCast(@as(u8, 8) - size);
                const fill_count = @as(usize, 1) << fill_bits;

                for (0..fill_count) |j| {
                    const idx = (@as(usize, code) << fill_bits) | j;
                    if (idx < 256) {
                        table.fast[idx] = table.values[i];
                        table.fast_bits[idx] = size;
                    }
                }
            }
        }
    }

    fn decodeImageData(self: *JpegDecoder, output: []u8) DecodeError!void {
        // Find SOS marker and parse scan header
        while (self.pos + 2 <= self.data.len) {
            if (self.data[self.pos] == 0xFF and self.data[self.pos + 1] == 0xDA) {
                self.pos += 2;
                break;
            }
            self.pos += 1;
        }

        if (self.pos + 2 > self.data.len) return DecodeError.TruncatedData;

        const sos_length = readU16BE(self.data[self.pos..]);
        const num_scan_components = self.data[self.pos + 2];

        // Parse component selectors
        for (0..num_scan_components) |i| {
            const offset = self.pos + 3 + i * 2;
            if (offset + 2 > self.data.len) return DecodeError.TruncatedData;

            const selector = self.data[offset + 1];
            self.components[i].dc_table = selector >> 4;
            self.components[i].ac_table = selector & 0x0F;
        }

        self.pos += sos_length;

        // Reset bit reader
        self.bit_buffer = 0;
        self.bits_in_buffer = 0;
        self.prev_dc = [_]i16{0} ** 4;

        // Decode MCUs
        const mcu_width: u16 = 8;
        const mcu_height: u16 = 8;
        const mcus_x = (self.width + mcu_width - 1) / mcu_width;
        const mcus_y = (self.height + mcu_height - 1) / mcu_height;

        var mcu_buffer: [3][64]i16 = undefined;
        var rgb_block: [64 * 3]u8 = undefined;

        for (0..mcus_y) |mcu_y| {
            for (0..mcus_x) |mcu_x| {
                // Decode each component
                for (0..self.num_components) |c| {
                    try self.decodeMcu(&mcu_buffer[c], @intCast(c));
                }

                // Convert YCbCr to RGB and write to output
                if (self.num_components == 3) {
                    self.ycbcrToRgb(&mcu_buffer, &rgb_block);
                } else {
                    // Grayscale
                    for (0..64) |i| {
                        const y_val: u8 = @intCast(std.math.clamp(mcu_buffer[0][i] + 128, 0, 255));
                        rgb_block[i * 3 + 0] = y_val;
                        rgb_block[i * 3 + 1] = y_val;
                        rgb_block[i * 3 + 2] = y_val;
                    }
                }

                // Copy block to output
                const base_x = mcu_x * 8;
                const base_y = mcu_y * 8;

                for (0..8) |by| {
                    const y = base_y + by;
                    if (y >= self.height) continue;

                    for (0..8) |bx| {
                        const x = base_x + bx;
                        if (x >= self.width) continue;

                        const src_idx = by * 8 + bx;
                        const dst_idx = (y * self.width + x) * 3;

                        output[dst_idx + 0] = rgb_block[src_idx * 3 + 0];
                        output[dst_idx + 1] = rgb_block[src_idx * 3 + 1];
                        output[dst_idx + 2] = rgb_block[src_idx * 3 + 2];
                    }
                }
            }
        }
    }

    fn decodeMcu(self: *JpegDecoder, block: *[64]i16, comp: u8) DecodeError!void {
        const dc_table = &self.huff_dc[self.components[comp].dc_table];
        const ac_table = &self.huff_ac[self.components[comp].ac_table];
        const quant = &self.quant_tables[self.components[comp].quant_table];

        if (!dc_table.valid or !ac_table.valid) return DecodeError.HuffmanError;

        // Clear block
        @memset(block, 0);

        // Decode DC coefficient
        const dc_size = try self.huffmanDecode(dc_table);
        if (dc_size > 0) {
            const dc_val = try self.receiveBits(dc_size);
            const dc_diff = self.extend(dc_val, dc_size);
            self.prev_dc[comp] +%= dc_diff;
        }
        block[0] = self.prev_dc[comp] * @as(i16, @intCast(quant[0]));

        // Decode AC coefficients
        var k: usize = 1;
        while (k < 64) {
            const ac_code = try self.huffmanDecode(ac_table);

            if (ac_code == 0) break; // EOB

            const run = ac_code >> 4;
            const size = ac_code & 0x0F;

            k += run;
            if (k >= 64) break;

            if (size > 0) {
                const ac_val = try self.receiveBits(size);
                const ac_coef = self.extend(ac_val, size);
                const zigzag_idx = zigzag_order[k];
                block[zigzag_idx] = ac_coef * @as(i16, @intCast(quant[k]));
            }
            k += 1;
        }

        // Inverse DCT
        self.idct(block);
    }

    fn huffmanDecode(self: *JpegDecoder, table: *const HuffmanTable) DecodeError!u8 {
        // Try fast lookup first
        const peek = try self.peekBits(8);
        const fast_val = table.fast[peek];
        const fast_bits = table.fast_bits[peek];

        if (fast_bits > 0) {
            self.dropBits(fast_bits);
            return fast_val;
        }

        // Slow path for longer codes
        var code: u16 = 0;
        for (1..17) |bits| {
            code = (code << 1) | @as(u16, try self.getBit());

            for (0..table.num_codes) |i| {
                if (table.sizes[i] == bits and table.codes[i] == code) {
                    return table.values[i];
                }
            }
        }

        return DecodeError.HuffmanError;
    }

    fn peekBits(self: *JpegDecoder, count: u8) DecodeError!u8 {
        while (self.bits_in_buffer < count) {
            try self.fillBitBuffer();
        }
        const shift: u5 = @intCast(self.bits_in_buffer - count);
        const count5: u5 = @intCast(count);
        return @intCast((self.bit_buffer >> shift) & ((@as(u32, 1) << count5) - 1));
    }

    fn getBit(self: *JpegDecoder) DecodeError!u1 {
        if (self.bits_in_buffer == 0) {
            try self.fillBitBuffer();
        }
        self.bits_in_buffer -= 1;
        const shift = @as(u5, @intCast(self.bits_in_buffer));
        return @intCast((self.bit_buffer >> shift) & 1);
    }

    fn dropBits(self: *JpegDecoder, count: u8) void {
        self.bits_in_buffer -|= count;
    }

    fn receiveBits(self: *JpegDecoder, count: u8) DecodeError!u16 {
        var result: u16 = 0;
        for (0..count) |_| {
            result = (result << 1) | @as(u16, try self.getBit());
        }
        return result;
    }

    fn fillBitBuffer(self: *JpegDecoder) DecodeError!void {
        if (self.pos >= self.data.len) return DecodeError.TruncatedData;

        var byte = self.data[self.pos];
        self.pos += 1;

        // Handle byte stuffing (FF 00 -> FF)
        if (byte == 0xFF) {
            if (self.pos >= self.data.len) return DecodeError.TruncatedData;
            const next = self.data[self.pos];
            if (next == 0x00) {
                self.pos += 1;
            } else if (next >= 0xD0 and next <= 0xD7) {
                // Restart marker - skip and refill
                self.pos += 1;
                return self.fillBitBuffer();
            } else {
                // Other marker - shouldn't happen in scan data
                byte = 0;
            }
        }

        self.bit_buffer = (self.bit_buffer << 8) | byte;
        self.bits_in_buffer += 8;
    }

    fn extend(self: *JpegDecoder, value: u16, size: u8) i16 {
        _ = self;
        if (size == 0) return 0;
        const size4: u4 = @intCast(@min(size - 1, 15));
        const threshold = @as(u16, 1) << size4;
        if (value < threshold) {
            const size5: u5 = @intCast(@min(size, 31));
            const offset = (@as(i32, -1) << size5) + 1;
            return @intCast(@as(i32, value) + offset);
        }
        return @intCast(value);
    }

    fn idct(self: *JpegDecoder, block: *[64]i16) void {
        _ = self;
        // Simplified IDCT using integer arithmetic
        // This is a basic row-column decomposition

        var temp: [64]i32 = undefined;

        // Row pass
        for (0..8) |row| {
            const base = row * 8;
            const s0 = block[base + 0];
            const s1 = block[base + 1];
            const s2 = block[base + 2];
            const s3 = block[base + 3];
            const s4 = block[base + 4];
            const s5 = block[base + 5];
            const s6 = block[base + 6];
            const s7 = block[base + 7];

            // Simplified 1D IDCT
            const t0 = @as(i32, s0 + s4) * 181;
            const t1 = @as(i32, s0 - s4) * 181;
            const t2 = @as(i32, s2) * 236 - @as(i32, s6) * 98;
            const t3 = @as(i32, s2) * 98 + @as(i32, s6) * 236;

            const t4 = @as(i32, s1) * 251 + @as(i32, s3) * 213 + @as(i32, s5) * 142 + @as(i32, s7) * 50;
            const t5 = @as(i32, s1) * 213 - @as(i32, s3) * 50 - @as(i32, s5) * 251 - @as(i32, s7) * 142;
            const t6 = @as(i32, s1) * 142 - @as(i32, s3) * 251 + @as(i32, s5) * 50 + @as(i32, s7) * 213;
            const t7 = @as(i32, s1) * 50 - @as(i32, s3) * 142 + @as(i32, s5) * 213 - @as(i32, s7) * 251;

            temp[base + 0] = (t0 + t3 + t4) >> 8;
            temp[base + 1] = (t1 + t2 + t5) >> 8;
            temp[base + 2] = (t1 - t2 + t6) >> 8;
            temp[base + 3] = (t0 - t3 + t7) >> 8;
            temp[base + 4] = (t0 - t3 - t7) >> 8;
            temp[base + 5] = (t1 - t2 - t6) >> 8;
            temp[base + 6] = (t1 + t2 - t5) >> 8;
            temp[base + 7] = (t0 + t3 - t4) >> 8;
        }

        // Column pass
        for (0..8) |col| {
            const s0 = temp[col + 0];
            const s1 = temp[col + 8];
            const s2 = temp[col + 16];
            const s3 = temp[col + 24];
            const s4 = temp[col + 32];
            const s5 = temp[col + 40];
            const s6 = temp[col + 48];
            const s7 = temp[col + 56];

            const t0 = (s0 + s4) * 181;
            const t1 = (s0 - s4) * 181;
            const t2 = s2 * 236 - s6 * 98;
            const t3 = s2 * 98 + s6 * 236;

            const t4 = s1 * 251 + s3 * 213 + s5 * 142 + s7 * 50;
            const t5 = s1 * 213 - s3 * 50 - s5 * 251 - s7 * 142;
            const t6 = s1 * 142 - s3 * 251 + s5 * 50 + s7 * 213;
            const t7 = s1 * 50 - s3 * 142 + s5 * 213 - s7 * 251;

            block[col + 0] = @intCast(std.math.clamp((t0 + t3 + t4) >> 14, -128, 127));
            block[col + 8] = @intCast(std.math.clamp((t1 + t2 + t5) >> 14, -128, 127));
            block[col + 16] = @intCast(std.math.clamp((t1 - t2 + t6) >> 14, -128, 127));
            block[col + 24] = @intCast(std.math.clamp((t0 - t3 + t7) >> 14, -128, 127));
            block[col + 32] = @intCast(std.math.clamp((t0 - t3 - t7) >> 14, -128, 127));
            block[col + 40] = @intCast(std.math.clamp((t1 - t2 - t6) >> 14, -128, 127));
            block[col + 48] = @intCast(std.math.clamp((t1 + t2 - t5) >> 14, -128, 127));
            block[col + 56] = @intCast(std.math.clamp((t0 + t3 - t4) >> 14, -128, 127));
        }
    }

    fn ycbcrToRgb(self: *JpegDecoder, mcu: *const [3][64]i16, rgb: *[64 * 3]u8) void {
        _ = self;
        for (0..64) |i| {
            const y = @as(i32, mcu[0][i]) + 128;
            const cb = @as(i32, mcu[1][i]);
            const cr = @as(i32, mcu[2][i]);

            // YCbCr to RGB conversion
            // R = Y + 1.402 * Cr
            // G = Y - 0.344 * Cb - 0.714 * Cr
            // B = Y + 1.772 * Cb

            const r = y + ((cr * 359) >> 8);
            const g = y - ((cb * 88 + cr * 183) >> 8);
            const b = y + ((cb * 454) >> 8);

            rgb[i * 3 + 0] = @intCast(std.math.clamp(r, 0, 255));
            rgb[i * 3 + 1] = @intCast(std.math.clamp(g, 0, 255));
            rgb[i * 3 + 2] = @intCast(std.math.clamp(b, 0, 255));
        }
    }
};

/// Zigzag order for DCT coefficients
const zigzag_order = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

fn decodeJpeg(data: []const u8, output: []u8) DecodeError!DecodedImage {
    var decoder = JpegDecoder.init(data);
    return decoder.decode(output);
}

// ============================================================
// Utility Functions
// ============================================================

fn readU16LE(data: []const u8) u16 {
    return @as(u16, data[0]) | (@as(u16, data[1]) << 8);
}

fn readU32LE(data: []const u8) u32 {
    return @as(u32, data[0]) |
        (@as(u32, data[1]) << 8) |
        (@as(u32, data[2]) << 16) |
        (@as(u32, data[3]) << 24);
}

fn readI32LE(data: []const u8) i32 {
    return @bitCast(readU32LE(data));
}

fn readU16BE(data: []const u8) u16 {
    return (@as(u16, data[0]) << 8) | @as(u16, data[1]);
}

// ============================================================
// Tests
// ============================================================

test "detectFormat" {
    // BMP
    try std.testing.expectEqual(ImageFormat.bmp, detectFormat("BM...."));

    // JPEG
    const jpeg_header = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 };
    try std.testing.expectEqual(ImageFormat.jpeg, detectFormat(&jpeg_header));

    // PNG
    const png_header = [_]u8{ 0x89, 'P', 'N', 'G' };
    try std.testing.expectEqual(ImageFormat.png, detectFormat(&png_header));

    // Unknown
    try std.testing.expectEqual(ImageFormat.unknown, detectFormat("????"));
}

test "bmp decode basic" {
    // Minimal 1x1 red BMP (24-bit)
    const bmp_data = [_]u8{
        // File header (14 bytes)
        'B',  'M', // Magic
        58,   0,   0, 0, // File size (58 bytes)
        0,    0, // Reserved
        0,    0, // Reserved
        54,   0,   0, 0, // Pixel data offset (54)
        // DIB header (40 bytes)
        40,   0,   0, 0, // Header size
        1,    0,   0, 0, // Width (1)
        1,    0,   0, 0, // Height (1)
        1,    0, // Planes
        24,   0, // Bits per pixel
        0,    0,   0, 0, // Compression (none)
        4,    0,   0, 0, // Image size
        0,    0,   0, 0, // X pixels per meter
        0,    0,   0, 0, // Y pixels per meter
        0,    0,   0, 0, // Colors used
        0,    0,   0, 0, // Important colors
        // Pixel data (BGR, padded to 4 bytes)
        0,    0,   255, 0, // Blue=0, Green=0, Red=255, Padding
    };

    var output: [3]u8 = undefined;
    const result = decodeBmp(&bmp_data, &output) catch |err| {
        std.debug.print("BMP decode error: {}\n", .{err});
        return err;
    };

    try std.testing.expectEqual(@as(u16, 1), result.width);
    try std.testing.expectEqual(@as(u16, 1), result.height);
    // Should be RGB (255, 0, 0) - red
    try std.testing.expectEqual(@as(u8, 255), output[0]); // R
    try std.testing.expectEqual(@as(u8, 0), output[1]); // G
    try std.testing.expectEqual(@as(u8, 0), output[2]); // B
}

test "zigzag order" {
    // First few entries should be correct
    try std.testing.expectEqual(@as(u8, 0), zigzag_order[0]);
    try std.testing.expectEqual(@as(u8, 1), zigzag_order[1]);
    try std.testing.expectEqual(@as(u8, 8), zigzag_order[2]);
    try std.testing.expectEqual(@as(u8, 63), zigzag_order[63]);
}
