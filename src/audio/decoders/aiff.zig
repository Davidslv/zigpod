//! AIFF Audio Decoder
//!
//! Decodes PCM audio from AIFF (Audio Interchange File Format) files.
//! AIFF is Apple's standard uncompressed audio format, using big-endian byte order.
//! Supports 8-bit, 16-bit, and 24-bit signed PCM.

const std = @import("std");
const audio = @import("../audio.zig");

// ============================================================
// Constants
// ============================================================

/// FORM chunk ID
const FORM_ID = "FORM";
/// AIFF format ID
const AIFF_ID = "AIFF";
/// AIFF-C (compressed) format ID
const AIFC_ID = "AIFC";
/// Common chunk ID
const COMM_ID = "COMM";
/// Sound data chunk ID
const SSND_ID = "SSND";
/// Name chunk ID
const NAME_ID = "NAME";
/// Author chunk ID
const AUTH_ID = "AUTH";

// ============================================================
// AIFF Decoder
// ============================================================

pub const AiffDecoder = struct {
    data: []const u8,
    data_offset: usize,
    data_size: usize,
    position: usize,
    track_info: audio.TrackInfo,
    format: Format,

    pub const Format = struct {
        channels: u16,
        sample_frames: u32,
        bits_per_sample: u16,
        sample_rate: u32,
        is_aifc: bool,
        compression_type: [4]u8,
    };

    pub const Error = error{
        InvalidHeader,
        UnsupportedFormat,
        InvalidChunk,
        EndOfData,
    };

    /// Initialize decoder with AIFF file data
    pub fn init(data: []const u8) Error!AiffDecoder {
        if (data.len < 12) return Error.InvalidHeader;

        // Validate FORM header
        if (!std.mem.eql(u8, data[0..4], FORM_ID)) return Error.InvalidHeader;

        const form_type = data[8..12];
        const is_aifc = std.mem.eql(u8, form_type, AIFC_ID);
        if (!std.mem.eql(u8, form_type, AIFF_ID) and !is_aifc) {
            return Error.InvalidHeader;
        }

        // Find COMM and SSND chunks
        var offset: usize = 12;
        var format: ?Format = null;
        var data_offset: usize = 0;
        var data_size: usize = 0;

        while (offset + 8 <= data.len) {
            const chunk_id = data[offset..][0..4];
            const chunk_size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .big);

            if (std.mem.eql(u8, chunk_id, COMM_ID)) {
                if (offset + 8 + chunk_size > data.len) return Error.InvalidChunk;

                const comm_data = data[offset + 8 ..];
                const channels = std.mem.readInt(u16, comm_data[0..2], .big);
                const sample_frames = std.mem.readInt(u32, comm_data[2..6], .big);
                const bits_per_sample = std.mem.readInt(u16, comm_data[6..8], .big);

                // Sample rate is stored as 80-bit extended float
                const sample_rate = parseExtendedFloat(comm_data[8..18]);

                var compression: [4]u8 = .{ 'N', 'O', 'N', 'E' };
                if (is_aifc and chunk_size >= 22) {
                    @memcpy(&compression, comm_data[18..22]);
                }

                format = Format{
                    .channels = channels,
                    .sample_frames = sample_frames,
                    .bits_per_sample = bits_per_sample,
                    .sample_rate = sample_rate,
                    .is_aifc = is_aifc,
                    .compression_type = compression,
                };

                // Only support uncompressed AIFF
                if (is_aifc and !std.mem.eql(u8, &compression, "NONE") and !std.mem.eql(u8, &compression, "raw ")) {
                    return Error.UnsupportedFormat;
                }
            } else if (std.mem.eql(u8, chunk_id, SSND_ID)) {
                // SSND chunk has 8 bytes of offset/block info before sample data
                data_offset = offset + 8 + 8;
                data_size = chunk_size - 8;
            }

            // Move to next chunk (AIFF chunks are word-aligned)
            offset += 8 + chunk_size;
            if (chunk_size % 2 != 0) offset += 1;
        }

        if (format == null) return Error.InvalidHeader;
        if (data_offset == 0) return Error.InvalidHeader;

        const fmt = format.?;
        const duration_ms = if (fmt.sample_rate > 0)
            (@as(u64, fmt.sample_frames) * 1000) / fmt.sample_rate
        else
            0;

        return AiffDecoder{
            .data = data,
            .data_offset = data_offset,
            .data_size = data_size,
            .position = 0,
            .format = fmt,
            .track_info = audio.TrackInfo{
                .sample_rate = fmt.sample_rate,
                .channels = @intCast(fmt.channels),
                .bits_per_sample = @intCast(fmt.bits_per_sample),
                .total_samples = fmt.sample_frames,
                .duration_ms = duration_ms,
                .format = switch (fmt.bits_per_sample) {
                    8 => .u8_pcm,
                    16 => .s16_be,
                    24 => .s24_le, // We convert to LE during decode
                    else => .s16_be,
                },
            },
        };
    }

    /// Decode samples into output buffer
    /// Returns number of samples written (stereo pairs count as 2)
    pub fn decode(self: *AiffDecoder, output: []i16) usize {
        const bytes_per_sample = self.format.bits_per_sample / 8;
        const bytes_per_frame = bytes_per_sample * self.format.channels;
        const remaining_bytes = self.data_size - self.position;
        const remaining_frames = remaining_bytes / bytes_per_frame;

        const frames_to_decode = @min(remaining_frames, output.len / self.format.channels);
        if (frames_to_decode == 0) return 0;

        const src_start = self.data_offset + self.position;
        const src = self.data[src_start..];
        var samples_written: usize = 0;

        for (0..frames_to_decode) |frame_idx| {
            for (0..self.format.channels) |channel| {
                const sample_offset = frame_idx * bytes_per_frame + channel * bytes_per_sample;
                const sample = self.decodeSample(src[sample_offset..]);
                output[samples_written] = sample;
                samples_written += 1;
            }
        }

        self.position += frames_to_decode * bytes_per_frame;
        return samples_written;
    }

    /// Decode a single sample based on bit depth (AIFF is big-endian)
    fn decodeSample(self: *AiffDecoder, data: []const u8) i16 {
        return switch (self.format.bits_per_sample) {
            8 => {
                // 8-bit signed (AIFF uses signed, unlike WAV)
                const signed: i8 = @bitCast(data[0]);
                return @as(i16, signed) * 256;
            },
            16 => {
                // 16-bit signed big-endian
                return std.mem.readInt(i16, data[0..2], .big);
            },
            24 => {
                // 24-bit signed big-endian, scale to 16-bit
                const high = data[0];
                const mid = data[1];
                const low = data[2];
                const value: i32 = (@as(i32, @as(i8, @bitCast(high))) << 16) |
                    (@as(i32, mid) << 8) |
                    @as(i32, low);
                return @intCast(value >> 8);
            },
            else => 0,
        };
    }

    /// Seek to sample position
    pub fn seek(self: *AiffDecoder, sample: u64) void {
        const bytes_per_sample = self.format.bits_per_sample / 8;
        const bytes_per_frame = bytes_per_sample * self.format.channels;
        const byte_position = sample * bytes_per_frame;
        self.position = @min(byte_position, self.data_size);
    }

    /// Seek to position in milliseconds
    pub fn seekMs(self: *AiffDecoder, ms: u64) void {
        const sample = (ms * self.format.sample_rate) / 1000;
        self.seek(sample);
    }

    /// Get current position in samples
    pub fn getPosition(self: *const AiffDecoder) u64 {
        const bytes_per_sample = self.format.bits_per_sample / 8;
        const bytes_per_frame = bytes_per_sample * self.format.channels;
        return self.position / bytes_per_frame;
    }

    /// Get current position in milliseconds
    pub fn getPositionMs(self: *const AiffDecoder) u64 {
        return (self.getPosition() * 1000) / self.format.sample_rate;
    }

    /// Check if at end of data
    pub fn isEof(self: *const AiffDecoder) bool {
        return self.position >= self.data_size;
    }

    /// Reset decoder to beginning
    pub fn reset(self: *AiffDecoder) void {
        self.position = 0;
    }

    /// Get track info
    pub fn getTrackInfo(self: *const AiffDecoder) audio.TrackInfo {
        return self.track_info;
    }
};

// ============================================================
// Helper Functions
// ============================================================

/// Parse 80-bit IEEE 754 extended float to u32 sample rate
/// AIFF uses this format for sample rate
fn parseExtendedFloat(data: []const u8) u32 {
    if (data.len < 10) return 0;

    // Extended float: 1 sign bit, 15 exponent bits, 64 mantissa bits
    const exponent_raw: u16 = std.mem.readInt(u16, data[0..2], .big);
    const exponent: i16 = @as(i16, @intCast(exponent_raw & 0x7FFF)) - 16383;

    // Read high 32 bits of mantissa
    const mantissa: u32 = std.mem.readInt(u32, data[2..6], .big);

    // For typical sample rates, we can use simplified conversion
    if (exponent < 0 or exponent > 31) return 0;

    // Sample rate = mantissa >> (31 - exponent)
    const shift: u5 = @intCast(31 - exponent);
    return mantissa >> shift;
}

/// Check if data is a valid AIFF file
pub fn isAiffFile(data: []const u8) bool {
    if (data.len < 12) return false;
    if (!std.mem.eql(u8, data[0..4], FORM_ID)) return false;
    return std.mem.eql(u8, data[8..12], AIFF_ID) or
        std.mem.eql(u8, data[8..12], AIFC_ID);
}

/// Get AIFF file duration in milliseconds without full decode
pub fn getDuration(data: []const u8) ?u64 {
    const decoder = AiffDecoder.init(data) catch return null;
    return decoder.track_info.duration_ms;
}

// ============================================================
// Tests
// ============================================================

test "aiff decoder - valid 16-bit stereo" {
    // Minimal valid AIFF file
    const aiff_data = [_]u8{
        // FORM header
        'F', 'O', 'R', 'M',
        0x00, 0x00, 0x00, 0x3E, // Size
        'A', 'I', 'F', 'F',
        // COMM chunk
        'C', 'O', 'M', 'M',
        0x00, 0x00, 0x00, 0x12, // Size = 18
        0x00, 0x02, // 2 channels
        0x00, 0x00, 0x00, 0x01, // 1 sample frame
        0x00, 0x10, // 16 bits
        // Sample rate 44100 as 80-bit extended float
        0x40, 0x0E, // Exponent: 16398 - 16383 = 15
        0xAC, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // Mantissa
        // SSND chunk
        'S', 'S', 'N', 'D',
        0x00, 0x00, 0x00, 0x0C, // Size = 12 (8 header + 4 data)
        0x00, 0x00, 0x00, 0x00, // Offset
        0x00, 0x00, 0x00, 0x00, // Block size
        0x00, 0x00, // Left sample
        0x00, 0x00, // Right sample
    };

    const decoder = try AiffDecoder.init(&aiff_data);
    try std.testing.expectEqual(@as(u16, 2), decoder.format.channels);
    try std.testing.expectEqual(@as(u16, 16), decoder.format.bits_per_sample);
    try std.testing.expectEqual(@as(u32, 1), decoder.format.sample_frames);
}

test "aiff file detection" {
    const valid_aiff = [_]u8{ 'F', 'O', 'R', 'M', 0, 0, 0, 0, 'A', 'I', 'F', 'F' };
    const valid_aifc = [_]u8{ 'F', 'O', 'R', 'M', 0, 0, 0, 0, 'A', 'I', 'F', 'C' };
    const invalid = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E' };

    try std.testing.expect(isAiffFile(&valid_aiff));
    try std.testing.expect(isAiffFile(&valid_aifc));
    try std.testing.expect(!isAiffFile(&invalid));
}

test "extended float parsing - 44100" {
    // 44100 Hz as 80-bit extended float
    const ext_float = [_]u8{
        0x40, 0x0E, // Exponent
        0xAC, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // Mantissa
    };
    const sample_rate = parseExtendedFloat(&ext_float);
    // Should be approximately 44100
    try std.testing.expect(sample_rate >= 44000 and sample_rate <= 44200);
}

test "extended float parsing - 48000" {
    // 48000 Hz as 80-bit extended float
    const ext_float = [_]u8{
        0x40, 0x0E, // Exponent
        0xBB, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // Mantissa
    };
    const sample_rate = parseExtendedFloat(&ext_float);
    // Should be approximately 48000
    try std.testing.expect(sample_rate >= 47900 and sample_rate <= 48100);
}
