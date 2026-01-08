//! FLAC Audio Decoder
//!
//! Decodes lossless audio from FLAC (Free Lossless Audio Codec) files.
//! Implements core FLAC decoding: frames, subframes, and entropy coding.

const std = @import("std");
const audio = @import("../audio.zig");

// ============================================================
// FLAC Constants
// ============================================================

/// FLAC stream marker
const FLAC_MARKER = "fLaC";

/// Maximum block size (samples)
const MAX_BLOCK_SIZE: usize = 65535;

/// Maximum channels
const MAX_CHANNELS: u8 = 8;

/// Subframe types
const SubframeType = enum(u8) {
    constant = 0,
    verbatim = 1,
    fixed = 2,
    lpc = 3,
};

// ============================================================
// FLAC Metadata
// ============================================================

pub const StreamInfo = struct {
    min_block_size: u16,
    max_block_size: u16,
    min_frame_size: u32, // 24 bits
    max_frame_size: u32, // 24 bits
    sample_rate: u32, // 20 bits
    channels: u8, // 3 bits
    bits_per_sample: u8, // 5 bits
    total_samples: u64, // 36 bits
    md5_signature: [16]u8,
};

// ============================================================
// Bit Reader
// ============================================================

const BitReader = struct {
    data: []const u8,
    byte_pos: usize,
    bit_pos: u8, // 0-7

    fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .byte_pos = 0,
            .bit_pos = 0,
        };
    }

    fn readBits(self: *BitReader, comptime T: type, n: u6) !T {
        if (n == 0) return 0;

        var result: u64 = 0;
        var bits_remaining: u8 = n;

        while (bits_remaining > 0) {
            if (self.byte_pos >= self.data.len) return error.EndOfData;

            const bits_available: u8 = 8 - self.bit_pos;
            const bits_to_read: u8 = @min(bits_remaining, bits_available);

            const byte = self.data[self.byte_pos];
            const shift: u3 = @intCast(bits_available - bits_to_read);
            const mask: u8 = @as(u8, 0xFF) >> @intCast(8 - bits_to_read);
            const value: u64 = (byte >> shift) & mask;

            result = (result << @intCast(bits_to_read)) | value;

            self.bit_pos += bits_to_read;
            if (self.bit_pos >= 8) {
                self.bit_pos = 0;
                self.byte_pos += 1;
            }
            bits_remaining -= bits_to_read;
        }

        return @intCast(result);
    }

    fn readUnary(self: *BitReader) !u32 {
        var count: u32 = 0;
        while (true) {
            if (self.byte_pos >= self.data.len) return error.EndOfData;

            const bit = try self.readBits(u1, 1);
            if (bit == 1) return count;
            count += 1;
            if (count > 32) return error.InvalidData;
        }
    }

    fn readUtf8(self: *BitReader) !u64 {
        const first = try self.readBits(u8, 8);

        if (first & 0x80 == 0) {
            return first;
        }

        var value: u64 = undefined;
        var bytes: u8 = undefined;

        if (first & 0xC0 == 0x80) return error.InvalidUtf8;
        if (first & 0xE0 == 0xC0) {
            value = first & 0x1F;
            bytes = 2;
        } else if (first & 0xF0 == 0xE0) {
            value = first & 0x0F;
            bytes = 3;
        } else if (first & 0xF8 == 0xF0) {
            value = first & 0x07;
            bytes = 4;
        } else if (first & 0xFC == 0xF8) {
            value = first & 0x03;
            bytes = 5;
        } else if (first & 0xFE == 0xFC) {
            value = first & 0x01;
            bytes = 6;
        } else if (first == 0xFE) {
            value = 0;
            bytes = 7;
        } else {
            return error.InvalidUtf8;
        }

        var i: u8 = 1;
        while (i < bytes) : (i += 1) {
            const b = try self.readBits(u8, 8);
            if (b & 0xC0 != 0x80) return error.InvalidUtf8;
            value = (value << 6) | (b & 0x3F);
        }

        return value;
    }

    fn skipBytes(self: *BitReader, n: usize) void {
        self.alignToByte();
        self.byte_pos = @min(self.byte_pos + n, self.data.len);
    }

    fn alignToByte(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
    }

    fn position(self: *const BitReader) usize {
        return self.byte_pos;
    }
};

// ============================================================
// FLAC Decoder
// ============================================================

pub const FlacDecoder = struct {
    data: []const u8,
    stream_info: StreamInfo,
    frame_offset: usize,
    samples_decoded: u64,
    current_block: [MAX_BLOCK_SIZE * MAX_CHANNELS]i32,
    current_block_size: usize,
    current_block_pos: usize,
    track_info: audio.TrackInfo,

    pub const Error = error{
        InvalidHeader,
        InvalidMetadata,
        InvalidFrame,
        UnsupportedFormat,
        EndOfData,
        InvalidData,
        InvalidUtf8,
    };

    /// Initialize decoder with FLAC file data
    pub fn init(data: []const u8) Error!FlacDecoder {
        if (data.len < 42) return Error.InvalidHeader;

        // Check FLAC marker
        if (!std.mem.eql(u8, data[0..4], FLAC_MARKER)) {
            return Error.InvalidHeader;
        }

        // Parse STREAMINFO metadata block
        const metadata_header = data[4];
        const is_last = (metadata_header & 0x80) != 0;
        const block_type = metadata_header & 0x7F;

        if (block_type != 0) return Error.InvalidMetadata; // Must start with STREAMINFO

        const block_length = (@as(u32, data[5]) << 16) |
            (@as(u32, data[6]) << 8) |
            @as(u32, data[7]);

        if (block_length != 34) return Error.InvalidMetadata;

        const si_data = data[8..42];
        const stream_info = StreamInfo{
            .min_block_size = std.mem.readInt(u16, si_data[0..2], .big),
            .max_block_size = std.mem.readInt(u16, si_data[2..4], .big),
            .min_frame_size = (@as(u32, si_data[4]) << 16) |
                (@as(u32, si_data[5]) << 8) |
                @as(u32, si_data[6]),
            .max_frame_size = (@as(u32, si_data[7]) << 16) |
                (@as(u32, si_data[8]) << 8) |
                @as(u32, si_data[9]),
            .sample_rate = (@as(u32, si_data[10]) << 12) |
                (@as(u32, si_data[11]) << 4) |
                (@as(u32, si_data[12]) >> 4),
            .channels = @intCast(((si_data[12] >> 1) & 0x07) + 1),
            .bits_per_sample = @intCast((((si_data[12] & 0x01) << 4) | (si_data[13] >> 4)) + 1),
            .total_samples = (@as(u64, si_data[13] & 0x0F) << 32) |
                (@as(u64, si_data[14]) << 24) |
                (@as(u64, si_data[15]) << 16) |
                (@as(u64, si_data[16]) << 8) |
                @as(u64, si_data[17]),
            .md5_signature = si_data[18..34].*,
        };

        // Skip remaining metadata blocks
        var offset: usize = 42;
        var last_block = is_last;
        while (!last_block and offset < data.len) {
            if (offset + 4 > data.len) break;
            const header = data[offset];
            last_block = (header & 0x80) != 0;
            const length = (@as(u32, data[offset + 1]) << 16) |
                (@as(u32, data[offset + 2]) << 8) |
                @as(u32, data[offset + 3]);
            offset += 4 + length;
        }

        const duration_ms = if (stream_info.sample_rate > 0)
            (stream_info.total_samples * 1000) / stream_info.sample_rate
        else
            0;

        return FlacDecoder{
            .data = data,
            .stream_info = stream_info,
            .frame_offset = offset,
            .samples_decoded = 0,
            .current_block = undefined,
            .current_block_size = 0,
            .current_block_pos = 0,
            .track_info = audio.TrackInfo{
                .sample_rate = stream_info.sample_rate,
                .channels = stream_info.channels,
                .bits_per_sample = stream_info.bits_per_sample,
                .total_samples = stream_info.total_samples,
                .duration_ms = duration_ms,
                .format = .s16_le,
            },
        };
    }

    /// Decode samples to 16-bit output
    pub fn decode(self: *FlacDecoder, output: []i16) Error!usize {
        var samples_written: usize = 0;

        while (samples_written < output.len) {
            // If current block is exhausted, decode next frame
            if (self.current_block_pos >= self.current_block_size * self.stream_info.channels) {
                if (!try self.decodeFrame()) {
                    break; // End of stream
                }
            }

            // Copy samples from current block
            const samples_available = (self.current_block_size * self.stream_info.channels) - self.current_block_pos;
            const samples_to_copy = @min(samples_available, output.len - samples_written);

            for (0..samples_to_copy) |i| {
                const sample = self.current_block[self.current_block_pos + i];
                output[samples_written + i] = self.scaleToI16(sample);
            }

            samples_written += samples_to_copy;
            self.current_block_pos += samples_to_copy;
        }

        return samples_written;
    }

    /// Scale sample to 16-bit based on bits per sample
    /// Uses proper rounding for bit-depth reduction to maintain audiophile quality
    fn scaleToI16(self: *FlacDecoder, sample: i32) i16 {
        return switch (self.stream_info.bits_per_sample) {
            8 => @intCast(sample << 8),
            16 => @intCast(sample),
            20 => {
                // 20-bit to 16-bit with rounding
                const rounded = sample + 8; // half of 16 (4 bits being discarded)
                return @intCast(std.math.clamp(rounded >> 4, -32768, 32767));
            },
            24 => {
                // 24-bit to 16-bit with rounding
                const rounded = sample + 128; // half of 256 (8 bits being discarded)
                return @intCast(std.math.clamp(rounded >> 8, -32768, 32767));
            },
            32 => {
                // 32-bit to 16-bit with rounding
                const rounded: i64 = @as(i64, sample) + 32768; // half of 65536
                return @intCast(std.math.clamp(rounded >> 16, -32768, 32767));
            },
            else => @intCast(sample),
        };
    }

    /// Decode a single FLAC frame
    fn decodeFrame(self: *FlacDecoder) Error!bool {
        if (self.frame_offset >= self.data.len) return false;

        var reader = BitReader.init(self.data[self.frame_offset..]);

        // Frame header sync code (14 bits: 0x3FFE)
        const sync = reader.readBits(u14, 14) catch return false;
        if (sync != 0x3FFE) return false;

        // Reserved bit
        _ = try reader.readBits(u1, 1);

        // Blocking strategy
        _ = try reader.readBits(u1, 1); // blocking_strategy

        // Block size
        const block_size_code = try reader.readBits(u4, 4);

        // Sample rate
        const sample_rate_code = try reader.readBits(u4, 4);

        // Channel assignment
        const channel_assignment = try reader.readBits(u4, 4);

        // Sample size
        _ = try reader.readBits(u3, 3);

        // Reserved
        _ = try reader.readBits(u1, 1);

        // Sample/frame number (UTF-8)
        _ = try reader.readUtf8();

        // Block size (if coded)
        const block_size: usize = switch (block_size_code) {
            0 => return Error.InvalidFrame,
            1 => 192,
            2...5 => @as(usize, 576) << @intCast(block_size_code - 2),
            6 => (try reader.readBits(u8, 8)) + 1,
            7 => (try reader.readBits(u16, 16)) + 1,
            else => @as(usize, 256) << @intCast(block_size_code - 8),
        };

        // Sample rate (if coded)
        _ = switch (sample_rate_code) {
            12 => try reader.readBits(u8, 8),
            13 => try reader.readBits(u16, 16),
            14 => try reader.readBits(u16, 16),
            else => 0,
        };

        // CRC-8
        _ = try reader.readBits(u8, 8);

        // Determine number of channels from channel assignment
        const channels: u8 = if (channel_assignment < 8)
            channel_assignment + 1
        else
            2; // Stereo decorrelation modes

        // Decode subframes for each channel
        self.current_block_size = @min(block_size, MAX_BLOCK_SIZE);

        for (0..channels) |ch| {
            // For stereo decorrelation modes, side channel has +1 bit
            // Channel assignment 8: left-side stereo (ch 1 has +1 bit)
            // Channel assignment 9: right-side stereo (ch 0 has +1 bit)
            // Channel assignment 10: mid-side stereo (ch 1 has +1 bit)
            const extra_bit: u8 = if (channel_assignment == 9 and ch == 0)
                1
            else if ((channel_assignment == 8 or channel_assignment == 10) and ch == 1)
                1
            else
                0;
            try self.decodeSubframe(&reader, ch, block_size, extra_bit);
        }

        // Handle stereo decorrelation
        if (channel_assignment >= 8 and channel_assignment <= 10) {
            self.applyDecorrelation(channel_assignment, block_size);
        }

        // Skip CRC-16 and align
        reader.alignToByte();
        reader.skipBytes(2);

        self.frame_offset += reader.position();
        self.current_block_pos = 0;
        self.samples_decoded += block_size;

        return true;
    }

    /// Decode a subframe
    fn decodeSubframe(self: *FlacDecoder, reader: *BitReader, channel: usize, block_size: usize, extra_bit: u8) Error!void {
        // Subframe header
        _ = try reader.readBits(u1, 1); // Zero padding
        const subframe_type = try reader.readBits(u6, 6);
        const wasted_bits = try reader.readBits(u1, 1);

        var wasted: u5 = 0;
        if (wasted_bits == 1) {
            wasted = @intCast(try reader.readUnary() + 1);
        }

        const offset = channel * MAX_BLOCK_SIZE;
        // Bits per sample for this subframe (may have +1 for side channel in stereo)
        const bps = self.stream_info.bits_per_sample + extra_bit;

        if (subframe_type == 0) {
            // CONSTANT
            const sample = try self.readSignedBits(reader, bps);
            for (0..block_size) |i| {
                self.current_block[offset + i] = sample << wasted;
            }
        } else if (subframe_type == 1) {
            // VERBATIM
            for (0..block_size) |i| {
                const sample = try self.readSignedBits(reader, bps);
                self.current_block[offset + i] = sample << wasted;
            }
        } else if (subframe_type >= 8 and subframe_type <= 12) {
            // FIXED predictor
            const order = subframe_type - 8;
            try self.decodeFixed(reader, offset, block_size, @intCast(order), wasted, bps);
        } else if (subframe_type >= 32) {
            // LPC
            const order = (subframe_type - 31);
            try self.decodeLpc(reader, offset, block_size, @intCast(order), wasted, bps);
        } else {
            return Error.InvalidFrame;
        }
    }

    /// Read signed bits
    fn readSignedBits(self: *FlacDecoder, reader: *BitReader, bits: u8) Error!i32 {
        _ = self;
        const unsigned = try reader.readBits(u32, @intCast(bits));
        const sign_bit: u32 = @as(u32, 1) << @intCast(bits - 1);
        if (unsigned & sign_bit != 0) {
            return @bitCast(unsigned | ~(sign_bit - 1 | sign_bit));
        }
        return @intCast(unsigned);
    }

    /// Decode FIXED subframe
    fn decodeFixed(self: *FlacDecoder, reader: *BitReader, offset: usize, block_size: usize, order: u4, wasted: u5, bps: u8) Error!void {
        // Read warmup samples
        for (0..order) |i| {
            const sample = try self.readSignedBits(reader, bps);
            self.current_block[offset + i] = sample << wasted;
        }

        // Decode residuals
        try self.decodeResidual(reader, offset, block_size, order);

        // Apply fixed predictor
        switch (order) {
            0 => {},
            1 => {
                for (1..block_size) |i| {
                    self.current_block[offset + i] += self.current_block[offset + i - 1];
                }
            },
            2 => {
                for (2..block_size) |i| {
                    self.current_block[offset + i] += 2 * self.current_block[offset + i - 1] -
                        self.current_block[offset + i - 2];
                }
            },
            3 => {
                for (3..block_size) |i| {
                    self.current_block[offset + i] += 3 * self.current_block[offset + i - 1] -
                        3 * self.current_block[offset + i - 2] +
                        self.current_block[offset + i - 3];
                }
            },
            4 => {
                for (4..block_size) |i| {
                    self.current_block[offset + i] += 4 * self.current_block[offset + i - 1] -
                        6 * self.current_block[offset + i - 2] +
                        4 * self.current_block[offset + i - 3] -
                        self.current_block[offset + i - 4];
                }
            },
            else => {},
        }
    }

    /// Decode LPC subframe
    fn decodeLpc(self: *FlacDecoder, reader: *BitReader, offset: usize, block_size: usize, order: u6, wasted: u5, bps: u8) Error!void {
        // Read warmup samples
        for (0..order) |i| {
            const sample = try self.readSignedBits(reader, bps);
            self.current_block[offset + i] = sample << wasted;
        }

        // LPC precision (4 bits) and shift (5 bits, signed)
        const precision = (try reader.readBits(u4, 4)) + 1;
        const shift_unsigned = try reader.readBits(u5, 5);
        // Sign extend: if bit 4 is set, it's negative
        const shift: i6 = if (shift_unsigned & 0x10 != 0)
            @as(i6, @bitCast(@as(u6, shift_unsigned) | 0x20)) // Sign extend to i6
        else
            @intCast(shift_unsigned);

        // Read LPC coefficients (signed, need proper sign extension)
        var coefficients: [32]i32 = undefined;
        for (0..order) |i| {
            const unsigned = try reader.readBits(u32, precision);
            // Sign extend from precision bits to 32 bits
            const sign_bit: u32 = @as(u32, 1) << @intCast(precision - 1);
            if (unsigned & sign_bit != 0) {
                coefficients[i] = @bitCast(unsigned | ~((sign_bit << 1) - 1));
            } else {
                coefficients[i] = @intCast(unsigned);
            }
        }

        // Decode residuals
        try self.decodeResidual(reader, offset, block_size, order);

        // Apply LPC predictor
        for (order..block_size) |i| {
            var sum: i64 = 0;
            for (0..order) |j| {
                sum += @as(i64, coefficients[j]) * @as(i64, self.current_block[offset + i - 1 - j]);
            }
            if (shift >= 0) {
                self.current_block[offset + i] += @intCast(sum >> @intCast(shift));
            } else {
                self.current_block[offset + i] += @intCast(sum << @intCast(-shift));
            }
        }
    }

    /// Decode residual using Rice coding
    fn decodeResidual(self: *FlacDecoder, reader: *BitReader, offset: usize, block_size: usize, predictor_order: u6) Error!void {
        const method = try reader.readBits(u2, 2);

        if (method > 1) return Error.InvalidFrame;

        const partition_order = try reader.readBits(u4, 4);
        const num_partitions: usize = @as(usize, 1) << partition_order;

        // Escape value depends on method (15 for method 0, 31 for method 1)
        const escape_value: u5 = if (method == 0) 15 else 31;

        var sample_idx: usize = predictor_order;

        for (0..num_partitions) |p| {
            const rice_param = if (method == 0)
                try reader.readBits(u4, 4)
            else
                try reader.readBits(u5, 5);

            const partition_samples = if (partition_order == 0)
                block_size - predictor_order
            else if (p == 0)
                (block_size >> partition_order) - predictor_order
            else
                block_size >> partition_order;

            if (rice_param == escape_value) {
                // Escape: read raw bits
                const bits = try reader.readBits(u5, 5);
                for (0..partition_samples) |_| {
                    self.current_block[offset + sample_idx] = try self.readSignedBits(reader, bits);
                    sample_idx += 1;
                }
            } else {
                // Rice-coded residuals
                for (0..partition_samples) |_| {
                    const q = try reader.readUnary();
                    const r = try reader.readBits(u32, @intCast(rice_param));
                    const unsigned = (q << @intCast(rice_param)) | r;
                    const signed: i32 = if (unsigned & 1 != 0)
                        -@as(i32, @intCast((unsigned + 1) >> 1))
                    else
                        @intCast(unsigned >> 1);
                    self.current_block[offset + sample_idx] = signed;
                    sample_idx += 1;
                }
            }
        }
    }

    /// Apply stereo decorrelation
    fn applyDecorrelation(self: *FlacDecoder, mode: u4, block_size: usize) void {
        const left_offset: usize = 0;
        const right_offset: usize = MAX_BLOCK_SIZE;

        switch (mode) {
            8 => { // Left-side stereo
                for (0..block_size) |i| {
                    self.current_block[right_offset + i] = self.current_block[left_offset + i] -
                        self.current_block[right_offset + i];
                }
            },
            9 => { // Side-right stereo
                for (0..block_size) |i| {
                    self.current_block[left_offset + i] = self.current_block[left_offset + i] +
                        self.current_block[right_offset + i];
                }
            },
            10 => { // Mid-side stereo
                for (0..block_size) |i| {
                    const mid = self.current_block[left_offset + i];
                    const side = self.current_block[right_offset + i];
                    self.current_block[left_offset + i] = mid + (side >> 1) + (side & 1);
                    self.current_block[right_offset + i] = mid - (side >> 1);
                }
            },
            else => {},
        }
    }

    /// Seek to sample position
    pub fn seek(self: *FlacDecoder, sample: u64) void {
        // Simple seek: reset to beginning and skip frames
        // A proper implementation would use seek tables
        if (sample < self.samples_decoded) {
            self.frame_offset = 42; // After STREAMINFO
            self.samples_decoded = 0;
            self.current_block_pos = 0;
            self.current_block_size = 0;
        }
        // TODO: Implement proper seeking with seek tables
    }

    /// Get track info
    pub fn getTrackInfo(self: *const FlacDecoder) audio.TrackInfo {
        return self.track_info;
    }

    /// Check if at end
    pub fn isEof(self: *const FlacDecoder) bool {
        return self.samples_decoded >= self.stream_info.total_samples and
            self.current_block_pos >= self.current_block_size * self.stream_info.channels;
    }
};

// ============================================================
// Helper Functions
// ============================================================

/// Check if data is a valid FLAC file
pub fn isFlacFile(data: []const u8) bool {
    if (data.len < 4) return false;
    return std.mem.eql(u8, data[0..4], FLAC_MARKER);
}

// ============================================================
// Tests
// ============================================================

test "flac - is flac file" {
    const valid = [_]u8{ 'f', 'L', 'a', 'C', 0, 0, 0, 0 };
    const invalid = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0 };

    try std.testing.expect(isFlacFile(&valid));
    try std.testing.expect(!isFlacFile(&invalid));
}

test "flac - invalid header" {
    const invalid_data = [_]u8{ 'N', 'O', 'T', ' ', 'F', 'L', 'A', 'C' };
    const result = FlacDecoder.init(&invalid_data);
    try std.testing.expectError(FlacDecoder.Error.InvalidHeader, result);
}

test "bit reader - read bits" {
    const data = [_]u8{ 0b10110101, 0b01001110 };
    var reader = BitReader.init(&data);

    // Read 4 bits: 1011 = 11
    const val1 = try reader.readBits(u4, 4);
    try std.testing.expectEqual(@as(u4, 0b1011), val1);

    // Read 4 bits: 0101 = 5
    const val2 = try reader.readBits(u4, 4);
    try std.testing.expectEqual(@as(u4, 0b0101), val2);

    // Read 8 bits from second byte
    const val3 = try reader.readBits(u8, 8);
    try std.testing.expectEqual(@as(u8, 0b01001110), val3);
}

test "bit reader - unary" {
    const data = [_]u8{ 0b00001111 }; // 4 zeros then a one
    var reader = BitReader.init(&data);

    const val = try reader.readUnary();
    try std.testing.expectEqual(@as(u32, 4), val);
}
