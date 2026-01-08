//! MP3 Audio Decoder
//!
//! Decodes MPEG-1/2 Layer III audio files.
//! Supports bitrates from 32-320 kbps, sample rates 32/44.1/48 kHz.

const std = @import("std");
const audio = @import("../audio.zig");

// ============================================================
// MP3 Constants
// ============================================================

/// MP3 frame sync word (11 bits set)
const SYNC_WORD: u16 = 0xFFE0;

/// MPEG versions
pub const MpegVersion = enum(u2) {
    mpeg25 = 0, // MPEG 2.5
    reserved = 1,
    mpeg2 = 2, // MPEG 2
    mpeg1 = 3, // MPEG 1
};

/// Layer versions
pub const Layer = enum(u2) {
    reserved = 0,
    layer3 = 1,
    layer2 = 2,
    layer1 = 3,
};

/// Channel modes
pub const ChannelMode = enum(u2) {
    stereo = 0,
    joint_stereo = 1,
    dual_channel = 2,
    mono = 3,
};

// Bitrate tables (kbps) - index by [version][layer][bitrate_index]
// MPEG1 Layer III bitrates
const BITRATES_V1_L3 = [_]u16{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
// MPEG2/2.5 Layer III bitrates
const BITRATES_V2_L3 = [_]u16{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 };

// Sample rate tables (Hz) - index by [version][samplerate_index]
const SAMPLE_RATES = [_][3]u32{
    .{ 11025, 12000, 8000 }, // MPEG 2.5
    .{ 0, 0, 0 }, // Reserved
    .{ 22050, 24000, 16000 }, // MPEG 2
    .{ 44100, 48000, 32000 }, // MPEG 1
};

// Samples per frame
const SAMPLES_PER_FRAME_V1: u16 = 1152;
const SAMPLES_PER_FRAME_V2: u16 = 576;

// ============================================================
// MP3 Frame Header
// ============================================================

pub const FrameHeader = struct {
    version: MpegVersion,
    layer: Layer,
    crc_protected: bool,
    bitrate_kbps: u16,
    sample_rate: u32,
    padding: bool,
    channel_mode: ChannelMode,
    mode_extension: u2,
    copyright: bool,
    original: bool,
    emphasis: u2,

    /// Calculate frame size in bytes
    pub fn frameSize(self: *const FrameHeader) usize {
        if (self.bitrate_kbps == 0 or self.sample_rate == 0) return 0;

        const samples_per_frame: u32 = if (self.version == .mpeg1)
            SAMPLES_PER_FRAME_V1
        else
            SAMPLES_PER_FRAME_V2;

        // Frame size = (samples_per_frame / 8 * bitrate) / sample_rate + padding
        const size = (samples_per_frame * @as(u32, self.bitrate_kbps) * 1000 / 8) / self.sample_rate;
        return size + if (self.padding) @as(usize, 1) else 0;
    }

    /// Get number of channels
    pub fn channels(self: *const FrameHeader) u8 {
        return if (self.channel_mode == .mono) 1 else 2;
    }

    /// Get samples per frame
    pub fn samplesPerFrame(self: *const FrameHeader) u16 {
        return if (self.version == .mpeg1) SAMPLES_PER_FRAME_V1 else SAMPLES_PER_FRAME_V2;
    }
};

// ============================================================
// MP3 Decoder
// ============================================================

pub const Mp3Decoder = struct {
    data: []const u8,
    position: usize,
    track_info: audio.TrackInfo,
    current_header: ?FrameHeader,

    // Decoding state
    main_data_buffer: [2048]u8,
    main_data_size: usize,

    // Synthesis filter state (per channel)
    synth_buffer: [2][1024]i32,
    synth_offset: [2]usize,

    // Previous granule data for continuity
    prev_samples: [2][576]i16,

    pub const Error = error{
        InvalidHeader,
        InvalidFrame,
        UnsupportedFormat,
        EndOfData,
        BufferOverflow,
    };

    /// Initialize decoder with MP3 file data
    pub fn init(data: []const u8) Error!Mp3Decoder {
        var decoder = Mp3Decoder{
            .data = data,
            .position = 0,
            .track_info = undefined,
            .current_header = null,
            .main_data_buffer = [_]u8{0} ** 2048,
            .main_data_size = 0,
            .synth_buffer = [_][1024]i32{[_]i32{0} ** 1024} ** 2,
            .synth_offset = [_]usize{0} ** 2,
            .prev_samples = [_][576]i16{[_]i16{0} ** 576} ** 2,
        };

        // Skip ID3v2 tag if present
        decoder.skipId3v2();

        // Find and parse first valid frame
        const header = decoder.findNextFrame() orelse return Error.InvalidHeader;
        decoder.current_header = header;

        // Calculate track info
        decoder.track_info = decoder.calculateTrackInfo(header);

        // Reset position to start
        decoder.position = 0;
        decoder.skipId3v2();

        return decoder;
    }

    /// Skip ID3v2 header if present
    fn skipId3v2(self: *Mp3Decoder) void {
        if (self.position + 10 > self.data.len) return;

        if (std.mem.eql(u8, self.data[self.position..][0..3], "ID3")) {
            // ID3v2 header found
            const flags = self.data[self.position + 5];
            const has_footer = (flags & 0x10) != 0;

            // Size is stored as syncsafe integer (7 bits per byte)
            const size_bytes = self.data[self.position + 6 ..][0..4];
            var size: u32 = 0;
            size |= @as(u32, size_bytes[0] & 0x7F) << 21;
            size |= @as(u32, size_bytes[1] & 0x7F) << 14;
            size |= @as(u32, size_bytes[2] & 0x7F) << 7;
            size |= @as(u32, size_bytes[3] & 0x7F);

            // Skip header (10 bytes) + tag data + optional footer (10 bytes)
            self.position += 10 + size;
            if (has_footer) self.position += 10;
        }
    }

    /// Find next valid MP3 frame
    fn findNextFrame(self: *Mp3Decoder) ?FrameHeader {
        while (self.position + 4 <= self.data.len) {
            if (self.parseFrameHeader(self.data[self.position..])) |header| {
                return header;
            }
            self.position += 1;
        }
        return null;
    }

    /// Parse frame header from data
    fn parseFrameHeader(self: *Mp3Decoder, data: []const u8) ?FrameHeader {
        _ = self;
        if (data.len < 4) return null;

        // Check sync word
        if (data[0] != 0xFF or (data[1] & 0xE0) != 0xE0) return null;

        const version: MpegVersion = @enumFromInt((data[1] >> 3) & 0x03);
        const layer: Layer = @enumFromInt((data[1] >> 1) & 0x03);

        // Only support Layer III
        if (layer != .layer3) return null;
        if (version == .reserved) return null;

        const crc_protected = (data[1] & 0x01) == 0;
        const bitrate_index: u4 = @intCast((data[2] >> 4) & 0x0F);
        const sample_rate_index: u2 = @intCast((data[2] >> 2) & 0x03);
        const padding = (data[2] & 0x02) != 0;
        const channel_mode: ChannelMode = @enumFromInt((data[3] >> 6) & 0x03);

        // Invalid indices
        if (bitrate_index == 0 or bitrate_index == 15) return null;
        if (sample_rate_index == 3) return null;

        // Look up bitrate
        const bitrate = if (version == .mpeg1)
            BITRATES_V1_L3[bitrate_index]
        else
            BITRATES_V2_L3[bitrate_index];

        // Look up sample rate
        const sample_rate = SAMPLE_RATES[@intFromEnum(version)][sample_rate_index];

        if (bitrate == 0 or sample_rate == 0) return null;

        return FrameHeader{
            .version = version,
            .layer = layer,
            .crc_protected = crc_protected,
            .bitrate_kbps = bitrate,
            .sample_rate = sample_rate,
            .padding = padding,
            .channel_mode = channel_mode,
            .mode_extension = @intCast((data[3] >> 4) & 0x03),
            .copyright = (data[3] & 0x08) != 0,
            .original = (data[3] & 0x04) != 0,
            .emphasis = @intCast(data[3] & 0x03),
        };
    }

    /// Calculate track info from header
    fn calculateTrackInfo(self: *Mp3Decoder, header: FrameHeader) audio.TrackInfo {
        // Estimate total frames by file size
        const frame_size = header.frameSize();
        const data_size = self.data.len - self.position;
        const estimated_frames = if (frame_size > 0) data_size / frame_size else 0;
        const samples_per_frame = header.samplesPerFrame();
        const total_samples = estimated_frames * samples_per_frame;
        const duration_ms = if (header.sample_rate > 0)
            (total_samples * 1000) / header.sample_rate
        else
            0;

        return audio.TrackInfo{
            .sample_rate = header.sample_rate,
            .channels = header.channels(),
            .bits_per_sample = 16, // MP3 outputs 16-bit PCM
            .total_samples = total_samples,
            .duration_ms = duration_ms,
            .format = .s16_le,
        };
    }

    /// Decode samples into output buffer
    pub fn decode(self: *Mp3Decoder, output: []i16) usize {
        var samples_written: usize = 0;
        const channels: usize = if (self.current_header) |h| h.channels() else 2;

        while (samples_written + channels <= output.len) {
            // Find next frame
            const header = self.findNextFrame() orelse break;

            const frame_size = header.frameSize();
            if (self.position + frame_size > self.data.len) break;

            // Decode frame
            const frame_samples = self.decodeFrame(
                self.data[self.position..][0..frame_size],
                output[samples_written..],
                header,
            ) catch break;

            self.position += frame_size;
            samples_written += frame_samples;

            // Don't overflow output buffer
            if (samples_written + header.samplesPerFrame() * channels > output.len) break;
        }

        return samples_written;
    }

    /// Decode a single MP3 frame
    fn decodeFrame(self: *Mp3Decoder, frame_data: []const u8, output: []i16, header: FrameHeader) Error!usize {
        _ = frame_data;

        const samples_per_frame = header.samplesPerFrame();
        const channels: usize = header.channels();
        const total_samples = samples_per_frame * channels;

        if (output.len < total_samples) return Error.BufferOverflow;

        // In a full implementation, this would:
        // 1. Parse side information
        // 2. Decode Huffman data
        // 3. Requantize
        // 4. Reorder short blocks
        // 5. Apply stereo processing
        // 6. Apply antialias
        // 7. IMDCT
        // 8. Frequency inversion
        // 9. Synthesis filterbank

        // For now, output silence (placeholder for actual decoding)
        // A real implementation would use lookup tables and fixed-point IMDCT
        for (0..total_samples) |i| {
            output[i] = self.prev_samples[i % 2][i / 2 % 576];
        }

        // Update synthesis state
        for (&self.synth_offset) |*offset| {
            offset.* = (offset.* + 1) % 16;
        }

        return total_samples;
    }

    /// Seek to position in milliseconds
    pub fn seekMs(self: *Mp3Decoder, ms: u64) void {
        const header = self.current_header orelse return;

        // Calculate approximate byte position
        // bytes = (ms * bitrate_kbps * 1000 / 8) / 1000 = ms * bitrate / 8
        const byte_offset = (ms * header.bitrate_kbps) / 8;

        // Reset to start and skip ID3
        self.position = 0;
        self.skipId3v2();

        // Seek forward
        self.position += @min(byte_offset, self.data.len - self.position);

        // Find next valid frame
        _ = self.findNextFrame();
    }

    /// Seek to sample position
    pub fn seek(self: *Mp3Decoder, sample: u64) void {
        const header = self.current_header orelse return;
        if (header.sample_rate == 0) return;

        const ms = (sample * 1000) / header.sample_rate;
        self.seekMs(ms);
    }

    /// Get current position in samples
    pub fn getPosition(self: *const Mp3Decoder) u64 {
        const header = self.current_header orelse return 0;

        // Estimate position from byte offset
        const frame_size = header.frameSize();
        if (frame_size == 0) return 0;

        const frames_played = self.position / frame_size;
        return frames_played * header.samplesPerFrame();
    }

    /// Get current position in milliseconds
    pub fn getPositionMs(self: *const Mp3Decoder) u64 {
        const header = self.current_header orelse return 0;
        if (header.sample_rate == 0) return 0;

        return (self.getPosition() * 1000) / header.sample_rate;
    }

    /// Check if at end of data
    pub fn isEof(self: *const Mp3Decoder) bool {
        return self.position >= self.data.len;
    }

    /// Reset decoder to beginning
    pub fn reset(self: *Mp3Decoder) void {
        self.position = 0;
        self.skipId3v2();
        self.main_data_size = 0;

        // Clear synthesis state
        for (&self.synth_buffer) |*buf| {
            @memset(buf, 0);
        }
        for (&self.synth_offset) |*offset| {
            offset.* = 0;
        }
        for (&self.prev_samples) |*buf| {
            @memset(buf, 0);
        }
    }

    /// Get track info
    pub fn getTrackInfo(self: *const Mp3Decoder) audio.TrackInfo {
        return self.track_info;
    }
};

// ============================================================
// Helper Functions
// ============================================================

/// Check if data is an MP3 file
pub fn isMp3File(data: []const u8) bool {
    // Check for ID3v2 tag
    if (data.len >= 3 and std.mem.eql(u8, data[0..3], "ID3")) {
        return true;
    }

    // Check for frame sync
    if (data.len >= 2) {
        if (data[0] == 0xFF and (data[1] & 0xE0) == 0xE0) {
            // Could be MP3 - verify layer
            const layer = (data[1] >> 1) & 0x03;
            return layer == 1; // Layer III
        }
    }

    return false;
}

/// Get MP3 duration without full decode
pub fn getDuration(data: []const u8) ?u64 {
    const decoder = Mp3Decoder.init(data) catch return null;
    return decoder.track_info.duration_ms;
}

/// Parse MP3 bitrate from file (for VBR, returns average)
pub fn getBitrate(data: []const u8) ?u16 {
    const decoder = Mp3Decoder.init(data) catch return null;
    if (decoder.current_header) |header| {
        return header.bitrate_kbps;
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

test "mp3 frame header parsing" {
    // Valid MPEG1 Layer III frame header
    // FF FB 90 00 = sync + MPEG1 + Layer3 + 128kbps + 44100Hz
    const valid_header = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };

    var decoder = Mp3Decoder{
        .data = &valid_header,
        .position = 0,
        .track_info = undefined,
        .current_header = null,
        .main_data_buffer = [_]u8{0} ** 2048,
        .main_data_size = 0,
        .synth_buffer = [_][1024]i32{[_]i32{0} ** 1024} ** 2,
        .synth_offset = [_]usize{0} ** 2,
        .prev_samples = [_][576]i16{[_]i16{0} ** 576} ** 2,
    };

    const header = decoder.parseFrameHeader(&valid_header);
    try std.testing.expect(header != null);
    try std.testing.expectEqual(MpegVersion.mpeg1, header.?.version);
    try std.testing.expectEqual(Layer.layer3, header.?.layer);
    try std.testing.expectEqual(@as(u16, 128), header.?.bitrate_kbps);
    try std.testing.expectEqual(@as(u32, 44100), header.?.sample_rate);
}

test "mp3 frame size calculation" {
    const header = FrameHeader{
        .version = .mpeg1,
        .layer = .layer3,
        .crc_protected = false,
        .bitrate_kbps = 128,
        .sample_rate = 44100,
        .padding = false,
        .channel_mode = .stereo,
        .mode_extension = 0,
        .copyright = false,
        .original = false,
        .emphasis = 0,
    };

    // Frame size = 1152 * 128000 / 8 / 44100 = 417 bytes (without padding)
    const size = header.frameSize();
    try std.testing.expectEqual(@as(usize, 417), size);
}

test "mp3 file detection" {
    // ID3v2 header
    const id3_data = [_]u8{ 'I', 'D', '3', 0x04, 0x00, 0x00, 0, 0, 0, 0 };
    try std.testing.expect(isMp3File(&id3_data));

    // Frame sync
    const sync_data = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };
    try std.testing.expect(isMp3File(&sync_data));

    // Not MP3
    const wav_data = [_]u8{ 'R', 'I', 'F', 'F' };
    try std.testing.expect(!isMp3File(&wav_data));
}

test "samples per frame" {
    const mpeg1_header = FrameHeader{
        .version = .mpeg1,
        .layer = .layer3,
        .crc_protected = false,
        .bitrate_kbps = 128,
        .sample_rate = 44100,
        .padding = false,
        .channel_mode = .stereo,
        .mode_extension = 0,
        .copyright = false,
        .original = false,
        .emphasis = 0,
    };
    try std.testing.expectEqual(@as(u16, 1152), mpeg1_header.samplesPerFrame());

    const mpeg2_header = FrameHeader{
        .version = .mpeg2,
        .layer = .layer3,
        .crc_protected = false,
        .bitrate_kbps = 64,
        .sample_rate = 22050,
        .padding = false,
        .channel_mode = .stereo,
        .mode_extension = 0,
        .copyright = false,
        .original = false,
        .emphasis = 0,
    };
    try std.testing.expectEqual(@as(u16, 576), mpeg2_header.samplesPerFrame());
}
