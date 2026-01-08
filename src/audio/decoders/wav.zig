//! WAV Audio Decoder
//!
//! Decodes PCM audio from WAV (RIFF) files.
//! Supports 8-bit unsigned, 16-bit signed, and 24-bit signed PCM.

const std = @import("std");
const audio = @import("../audio.zig");

// ============================================================
// Constants
// ============================================================

/// RIFF chunk ID
const RIFF_ID = "RIFF";
/// WAVE format ID
const WAVE_ID = "WAVE";
/// Format chunk ID
const FMT_ID = "fmt ";
/// Data chunk ID
const DATA_ID = "data";

/// Audio format codes
const FORMAT_PCM: u16 = 1;
const FORMAT_IEEE_FLOAT: u16 = 3;
const FORMAT_EXTENSIBLE: u16 = 0xFFFE;

// ============================================================
// WAV Decoder
// ============================================================

pub const WavDecoder = struct {
    data: []const u8,
    data_offset: usize,
    data_size: usize,
    position: usize,
    track_info: audio.TrackInfo,
    format: Format,

    pub const Format = struct {
        audio_format: u16,
        channels: u16,
        sample_rate: u32,
        byte_rate: u32,
        block_align: u16,
        bits_per_sample: u16,
        valid_bits_per_sample: u16, // For EXTENSIBLE format
        is_float: bool,
    };

    pub const Error = error{
        InvalidHeader,
        UnsupportedFormat,
        InvalidChunk,
        EndOfData,
    };

    /// Initialize decoder with WAV file data
    pub fn init(data: []const u8) Error!WavDecoder {
        if (data.len < 44) return Error.InvalidHeader;

        // Validate RIFF header
        if (!std.mem.eql(u8, data[0..4], RIFF_ID)) return Error.InvalidHeader;
        if (!std.mem.eql(u8, data[8..12], WAVE_ID)) return Error.InvalidHeader;

        // Find fmt chunk
        var offset: usize = 12;
        var format: ?Format = null;
        var data_offset: usize = 0;
        var data_size: usize = 0;

        while (offset + 8 <= data.len) {
            const chunk_id = data[offset..][0..4];
            const chunk_size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);

            if (std.mem.eql(u8, chunk_id, FMT_ID)) {
                if (offset + 8 + chunk_size > data.len) return Error.InvalidChunk;
                if (chunk_size < 16) return Error.InvalidChunk;

                const fmt_data = data[offset + 8 ..];
                const audio_fmt = std.mem.readInt(u16, fmt_data[0..2], .little);
                const bits = std.mem.readInt(u16, fmt_data[14..16], .little);

                var is_float = false;
                var valid_bits = bits;
                var actual_format = audio_fmt;

                // Handle EXTENSIBLE format
                if (audio_fmt == FORMAT_EXTENSIBLE and chunk_size >= 40) {
                    valid_bits = std.mem.readInt(u16, fmt_data[18..20], .little);
                    // SubFormat GUID - first 2 bytes indicate actual format
                    const sub_format = std.mem.readInt(u16, fmt_data[24..26], .little);
                    actual_format = sub_format;
                    is_float = (sub_format == FORMAT_IEEE_FLOAT);
                } else if (audio_fmt == FORMAT_IEEE_FLOAT) {
                    is_float = true;
                }

                format = Format{
                    .audio_format = actual_format,
                    .channels = std.mem.readInt(u16, fmt_data[2..4], .little),
                    .sample_rate = std.mem.readInt(u32, fmt_data[4..8], .little),
                    .byte_rate = std.mem.readInt(u32, fmt_data[8..12], .little),
                    .block_align = std.mem.readInt(u16, fmt_data[12..14], .little),
                    .bits_per_sample = bits,
                    .valid_bits_per_sample = valid_bits,
                    .is_float = is_float,
                };

                // Validate format - support PCM and IEEE float
                if (actual_format != FORMAT_PCM and actual_format != FORMAT_IEEE_FLOAT) {
                    return Error.UnsupportedFormat;
                }
            } else if (std.mem.eql(u8, chunk_id, DATA_ID)) {
                data_offset = offset + 8;
                data_size = chunk_size;
            }

            // Move to next chunk (aligned to 2 bytes)
            offset += 8 + chunk_size;
            if (chunk_size % 2 != 0) offset += 1;
        }

        if (format == null) return Error.InvalidHeader;
        if (data_offset == 0) return Error.InvalidHeader;

        const fmt = format.?;
        const bytes_per_sample = fmt.bits_per_sample / 8;
        const total_samples = data_size / (bytes_per_sample * fmt.channels);

        return WavDecoder{
            .data = data,
            .data_offset = data_offset,
            .data_size = data_size,
            .position = 0,
            .format = fmt,
            .track_info = audio.TrackInfo{
                .sample_rate = fmt.sample_rate,
                .channels = @intCast(fmt.channels),
                .bits_per_sample = @intCast(fmt.bits_per_sample),
                .total_samples = total_samples,
                .duration_ms = (@as(u64, total_samples) * 1000) / fmt.sample_rate,
                .format = if (fmt.is_float) .s16_le else switch (fmt.bits_per_sample) {
                    8 => .u8_pcm,
                    16 => .s16_le,
                    24 => .s24_le,
                    32 => .s16_le, // 32-bit PCM converted to 16-bit
                    else => .s16_le,
                },
            },
        };
    }

    /// Decode samples into output buffer
    /// Returns number of samples written (stereo pairs count as 2)
    pub fn decode(self: *WavDecoder, output: []i16) usize {
        const bytes_per_sample = self.format.bits_per_sample / 8;
        const bytes_per_frame = bytes_per_sample * self.format.channels;
        const remaining_bytes = self.data_size - self.position;
        const remaining_frames = remaining_bytes / bytes_per_frame;

        // Calculate how many frames we can output
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

    /// Decode a single sample based on bit depth
    /// Uses proper rounding for bit-depth reduction to maintain quality
    fn decodeSample(self: *WavDecoder, data: []const u8) i16 {
        if (self.format.is_float) {
            return self.decodeFloatSample(data);
        }

        return switch (self.format.bits_per_sample) {
            8 => {
                // 8-bit unsigned to 16-bit signed
                const unsigned: i32 = data[0];
                return @intCast((unsigned - 128) << 8);
            },
            16 => {
                // 16-bit signed little-endian - bit-perfect
                return std.mem.readInt(i16, data[0..2], .little);
            },
            24 => {
                // 24-bit signed little-endian, scale to 16-bit with rounding
                const low = data[0];
                const mid = data[1];
                const high = data[2];
                const value: i32 = (@as(i32, @as(i8, @bitCast(high))) << 16) |
                    (@as(i32, mid) << 8) |
                    @as(i32, low);
                // Add half LSB for proper rounding before truncation
                const rounded = value + 128; // 0x80 = half of 256 (8 bits being discarded)
                return @intCast(std.math.clamp(rounded >> 8, -32768, 32767));
            },
            32 => {
                // 32-bit signed little-endian, scale to 16-bit with rounding
                const value = std.mem.readInt(i32, data[0..4], .little);
                // Add half LSB for proper rounding
                const rounded: i64 = @as(i64, value) + 32768; // half of 65536
                return @intCast(std.math.clamp(rounded >> 16, -32768, 32767));
            },
            else => 0,
        };
    }

    /// Decode IEEE 754 floating-point sample to 16-bit
    fn decodeFloatSample(self: *WavDecoder, data: []const u8) i16 {
        _ = self;
        // 32-bit IEEE 754 float
        const bits = std.mem.readInt(u32, data[0..4], .little);
        const float_val: f32 = @bitCast(bits);

        // Convert float (-1.0 to 1.0) to i16 with proper clipping
        // Multiply by 32767 (not 32768) to avoid overflow on positive full-scale
        const scaled = float_val * 32767.0;
        const clamped = std.math.clamp(scaled, -32768.0, 32767.0);
        return @intFromFloat(clamped);
    }

    /// Seek to sample position
    pub fn seek(self: *WavDecoder, sample: u64) void {
        const bytes_per_sample = self.format.bits_per_sample / 8;
        const bytes_per_frame = bytes_per_sample * self.format.channels;
        const byte_position = sample * bytes_per_frame;
        self.position = @min(byte_position, self.data_size);
    }

    /// Seek to position in milliseconds
    pub fn seekMs(self: *WavDecoder, ms: u64) void {
        const sample = (ms * self.format.sample_rate) / 1000;
        self.seek(sample);
    }

    /// Get current position in samples
    pub fn getPosition(self: *const WavDecoder) u64 {
        const bytes_per_sample = self.format.bits_per_sample / 8;
        const bytes_per_frame = bytes_per_sample * self.format.channels;
        return self.position / bytes_per_frame;
    }

    /// Get current position in milliseconds
    pub fn getPositionMs(self: *const WavDecoder) u64 {
        return (self.getPosition() * 1000) / self.format.sample_rate;
    }

    /// Check if at end of data
    pub fn isEof(self: *const WavDecoder) bool {
        return self.position >= self.data_size;
    }

    /// Reset decoder to beginning
    pub fn reset(self: *WavDecoder) void {
        self.position = 0;
    }

    /// Get track info
    pub fn getTrackInfo(self: *const WavDecoder) audio.TrackInfo {
        return self.track_info;
    }
};

// ============================================================
// Helper Functions
// ============================================================

/// Check if data is a valid WAV file
pub fn isWavFile(data: []const u8) bool {
    if (data.len < 12) return false;
    return std.mem.eql(u8, data[0..4], RIFF_ID) and
        std.mem.eql(u8, data[8..12], WAVE_ID);
}

/// Get WAV file duration in milliseconds without full decode
pub fn getDuration(data: []const u8) ?u64 {
    const decoder = WavDecoder.init(data) catch return null;
    return decoder.track_info.duration_ms;
}

// ============================================================
// Tests
// ============================================================

test "wav decoder - valid 16-bit stereo" {
    // Minimal valid WAV file: 44 bytes header + 4 bytes of silence
    const wav_data = [_]u8{
        // RIFF header
        'R', 'I', 'F', 'F',
        0x2C, 0x00, 0x00, 0x00, // File size - 8 = 44
        'W', 'A', 'V', 'E',
        // fmt chunk
        'f', 'm', 't', ' ',
        0x10, 0x00, 0x00, 0x00, // Chunk size = 16
        0x01, 0x00, // Audio format = 1 (PCM)
        0x02, 0x00, // Channels = 2
        0x44, 0xAC, 0x00, 0x00, // Sample rate = 44100
        0x10, 0xB1, 0x02, 0x00, // Byte rate = 176400
        0x04, 0x00, // Block align = 4
        0x10, 0x00, // Bits per sample = 16
        // data chunk
        'd', 'a', 't', 'a',
        0x04, 0x00, 0x00, 0x00, // Data size = 4 bytes (1 stereo sample)
        0x00, 0x00, // Left channel = 0
        0x00, 0x00, // Right channel = 0
    };

    var decoder = try WavDecoder.init(&wav_data);
    try std.testing.expectEqual(@as(u32, 44100), decoder.format.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), decoder.format.channels);
    try std.testing.expectEqual(@as(u16, 16), decoder.format.bits_per_sample);

    var output: [4]i16 = undefined;
    const samples = decoder.decode(&output);
    try std.testing.expectEqual(@as(usize, 2), samples);
    try std.testing.expect(decoder.isEof());
}

test "wav decoder - 8-bit mono conversion" {
    const wav_data = [_]u8{
        // RIFF header
        'R', 'I', 'F', 'F',
        0x26, 0x00, 0x00, 0x00,
        'W', 'A', 'V', 'E',
        // fmt chunk
        'f', 'm', 't', ' ',
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00, // PCM
        0x01, 0x00, // Mono
        0x40, 0x1F, 0x00, 0x00, // 8000 Hz
        0x40, 0x1F, 0x00, 0x00, // Byte rate
        0x01, 0x00, // Block align
        0x08, 0x00, // 8 bits
        // data chunk
        'd', 'a', 't', 'a',
        0x02, 0x00, 0x00, 0x00, // 2 bytes
        0x80, // Middle (silence in unsigned 8-bit)
        0xFF, // Maximum
    };

    var decoder = try WavDecoder.init(&wav_data);
    try std.testing.expectEqual(@as(u16, 8), decoder.format.bits_per_sample);
    try std.testing.expectEqual(@as(u16, 1), decoder.format.channels);

    var output: [2]i16 = undefined;
    const samples = decoder.decode(&output);
    try std.testing.expectEqual(@as(usize, 2), samples);

    // 0x80 (128) -> (128 - 128) * 256 = 0
    try std.testing.expectEqual(@as(i16, 0), output[0]);
    // 0xFF (255) -> (255 - 128) * 256 = 32512
    try std.testing.expectEqual(@as(i16, 32512), output[1]);
}

test "wav decoder - invalid header" {
    const invalid_data = [_]u8{ 'N', 'O', 'T', ' ', 'W', 'A', 'V' };
    const result = WavDecoder.init(&invalid_data);
    try std.testing.expectError(WavDecoder.Error.InvalidHeader, result);
}

test "wav decoder - seek" {
    const wav_data = [_]u8{
        'R', 'I', 'F', 'F',
        0x30, 0x00, 0x00, 0x00,
        'W', 'A', 'V', 'E',
        'f', 'm', 't', ' ',
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00, // PCM
        0x02, 0x00, // Stereo
        0x44, 0xAC, 0x00, 0x00, // 44100 Hz
        0x10, 0xB1, 0x02, 0x00,
        0x04, 0x00,
        0x10, 0x00, // 16-bit
        'd', 'a', 't', 'a',
        0x08, 0x00, 0x00, 0x00, // 8 bytes (2 stereo frames)
        0x01, 0x00, 0x02, 0x00, // Frame 0
        0x03, 0x00, 0x04, 0x00, // Frame 1
    };

    var decoder = try WavDecoder.init(&wav_data);

    // Seek to second frame
    decoder.seek(1);
    try std.testing.expectEqual(@as(u64, 1), decoder.getPosition());

    var output: [2]i16 = undefined;
    _ = decoder.decode(&output);
    try std.testing.expectEqual(@as(i16, 3), output[0]);
    try std.testing.expectEqual(@as(i16, 4), output[1]);
}

test "is wav file" {
    const valid = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E' };
    const invalid = [_]u8{ 'N', 'O', 'T', ' ', 'W', 'A', 'V', 'E', 0, 0, 0, 0 };

    try std.testing.expect(isWavFile(&valid));
    try std.testing.expect(!isWavFile(&invalid));
}
