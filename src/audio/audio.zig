//! Audio Playback Engine
//!
//! High-level audio playback system that coordinates codec, I2S, and file reading.
//! Supports WAV and FLAC formats with room for adding more codecs.

const std = @import("std");
const hal = @import("../hal/hal.zig");
const RingBuffer = @import("../lib/ring_buffer.zig").RingBuffer;
const fixed = @import("../lib/fixed_point.zig");
const codec = @import("../drivers/audio/codec.zig");
const i2s = @import("../drivers/audio/i2s.zig");

// Export decoders
pub const decoders = @import("decoders/decoders.zig");

// Export metadata parser
pub const metadata = @import("metadata.zig");

// Export DSP effects
pub const dsp = @import("dsp.zig");

// ============================================================
// Audio Constants
// ============================================================

/// Default sample rate (CD quality)
pub const DEFAULT_SAMPLE_RATE: u32 = 44100;

/// Audio buffer size (samples, not bytes)
pub const BUFFER_SIZE: usize = 4096;

/// Number of audio channels
pub const CHANNELS: u8 = 2; // Stereo

/// Audio format
pub const SampleFormat = enum {
    s16_le, // 16-bit signed, little-endian
    s16_be, // 16-bit signed, big-endian
    s24_le, // 24-bit signed, little-endian
    u8_pcm, // 8-bit unsigned

    pub fn bytesPerSample(self: SampleFormat) u8 {
        return switch (self) {
            .s16_le, .s16_be => 2,
            .s24_le => 3,
            .u8_pcm => 1,
        };
    }
};

// ============================================================
// Playback State
// ============================================================

pub const PlaybackState = enum {
    stopped,
    playing,
    paused,
    error_state,
};

/// Audio track information
pub const TrackInfo = struct {
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    total_samples: u64,
    duration_ms: u64,
    format: SampleFormat,

    /// Get duration in seconds
    pub fn durationSeconds(self: TrackInfo) u32 {
        return @intCast(self.duration_ms / 1000);
    }

    /// Format duration as MM:SS string
    pub fn formatDuration(self: TrackInfo, buffer: []u8) []u8 {
        const secs = self.durationSeconds();
        const mins = secs / 60;
        const remaining_secs = secs % 60;
        return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}", .{ mins, remaining_secs }) catch buffer[0..0];
    }
};

// ============================================================
// Audio Engine State
// ============================================================

var state: PlaybackState = .stopped;
var current_track: ?TrackInfo = null;
var current_position: u64 = 0; // Current sample position
var volume_left: i16 = -10; // Volume in dB (-89 to +6)
var volume_right: i16 = -10;
var muted: bool = false;
var initialized: bool = false;

/// Audio sample buffer (double-buffered)
var sample_buffer: RingBuffer(i16, BUFFER_SIZE * 2) = RingBuffer(i16, BUFFER_SIZE * 2).init();

/// Decode callback function type
pub const DecodeCallback = *const fn (output: []i16) usize;
var decode_callback: ?DecodeCallback = null;

// ============================================================
// Initialization
// ============================================================

/// Initialize the audio engine
pub fn init() hal.HalError!void {
    // Initialize codec (pre-init phase)
    try codec.preinit();

    // Initialize I2S
    try i2s.init(.{
        .sample_rate = DEFAULT_SAMPLE_RATE,
        .format = .i2s_standard,
        .sample_size = .bits_16,
    });

    // Enable I2S output
    i2s.enable();

    // Codec post-init
    try codec.postinit();

    // Set initial volume
    try codec.setVolume(volume_left, volume_right);

    initialized = true;
    state = .stopped;
}

/// Shutdown the audio engine
pub fn shutdown() void {
    if (!initialized) return;

    stop();
    i2s.disable();
    codec.shutdown() catch {};
    initialized = false;
}

/// Check if audio engine is initialized
pub fn isInitialized() bool {
    return initialized;
}

// ============================================================
// Playback Control
// ============================================================

/// Start playing with the given decode callback
pub fn play(callback: DecodeCallback, track_info: TrackInfo) hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;

    // Configure sample rate if different
    if (current_track == null or current_track.?.sample_rate != track_info.sample_rate) {
        try i2s.setSampleRate(track_info.sample_rate);
        try codec.setSampleRate(track_info.sample_rate);
    }

    decode_callback = callback;
    current_track = track_info;
    current_position = 0;
    sample_buffer.clear();

    // Pre-fill buffer
    fillBuffer();

    state = .playing;
}

/// Stop playback
pub fn stop() void {
    state = .stopped;
    decode_callback = null;
    current_track = null;
    current_position = 0;
    sample_buffer.clear();
}

/// Pause playback
pub fn pause() void {
    if (state == .playing) {
        state = .paused;
    }
}

/// Resume playback
pub fn resumePlayback() void {
    if (state == .paused) {
        state = .playing;
    }
}

/// Toggle pause/play
pub fn togglePause() void {
    if (state == .playing) {
        pause();
    } else if (state == .paused) {
        resumePlayback();
    }
}

/// Get current playback state
pub fn getState() PlaybackState {
    return state;
}

/// Check if playing
pub fn isPlaying() bool {
    return state == .playing;
}

/// Check if paused
pub fn isPaused() bool {
    return state == .paused;
}

// ============================================================
// Position Control
// ============================================================

/// Get current position in milliseconds
pub fn getPositionMs() u64 {
    if (current_track) |track| {
        return (current_position * 1000) / track.sample_rate;
    }
    return 0;
}

/// Get current position as percentage (0-100)
pub fn getPositionPercent() u8 {
    if (current_track) |track| {
        if (track.total_samples > 0) {
            return @intCast((current_position * 100) / track.total_samples);
        }
    }
    return 0;
}

/// Seek to position (in milliseconds)
pub fn seekMs(position_ms: u64) void {
    if (current_track) |track| {
        const target_sample = (position_ms * track.sample_rate) / 1000;
        current_position = @min(target_sample, track.total_samples);
        sample_buffer.clear();
    }
}

/// Seek forward/backward by delta milliseconds
pub fn seekRelativeMs(delta_ms: i32) void {
    const current = getPositionMs();
    if (delta_ms < 0) {
        const abs_delta: u64 = @intCast(-delta_ms);
        if (current >= abs_delta) {
            seekMs(current - abs_delta);
        } else {
            seekMs(0);
        }
    } else {
        seekMs(current + @as(u64, @intCast(delta_ms)));
    }
}

/// Get current track info
pub fn getTrackInfo() ?TrackInfo {
    return current_track;
}

// ============================================================
// Volume Control
// ============================================================

/// Set volume (dB, -89 to +6)
pub fn setVolume(left_db: i16, right_db: i16) hal.HalError!void {
    volume_left = std.math.clamp(left_db, -89, 6);
    volume_right = std.math.clamp(right_db, -89, 6);

    if (initialized and !muted) {
        try codec.setVolume(volume_left, volume_right);
    }
}

/// Set volume (same for both channels)
pub fn setVolumeMono(db: i16) hal.HalError!void {
    try setVolume(db, db);
}

/// Adjust volume by delta
pub fn adjustVolume(delta: i8) hal.HalError!void {
    const new_left = std.math.clamp(@as(i16, volume_left) + delta, -89, 6);
    const new_right = std.math.clamp(@as(i16, volume_right) + delta, -89, 6);
    try setVolume(new_left, new_right);
}

/// Get current volume
pub fn getVolume() struct { left: i16, right: i16 } {
    return .{ .left = volume_left, .right = volume_right };
}

/// Set mute state
pub fn setMute(enable: bool) hal.HalError!void {
    muted = enable;
    if (initialized) {
        try codec.mute(enable);
    }
}

/// Toggle mute
pub fn toggleMute() hal.HalError!void {
    try setMute(!muted);
}

/// Check if muted
pub fn isMuted() bool {
    return muted;
}

// ============================================================
// Audio Processing (called from main loop or interrupt)
// ============================================================

/// Process audio - call this regularly from main loop
pub fn process() hal.HalError!void {
    if (!initialized or state != .playing) return;

    // Fill buffer if needed
    if (sample_buffer.len() < BUFFER_SIZE) {
        fillBuffer();
    }

    // Write samples to I2S
    while (i2s.txReady() and !sample_buffer.isEmpty()) {
        var samples: [64]i16 = undefined;
        const count = sample_buffer.read(&samples);
        if (count > 0) {
            _ = try i2s.write(samples[0..count]);
        }
    }

    // Check for end of track
    if (current_track) |track| {
        if (current_position >= track.total_samples and sample_buffer.isEmpty()) {
            state = .stopped;
        }
    }
}

/// Fill the sample buffer from decoder
fn fillBuffer() void {
    if (decode_callback) |callback| {
        while (sample_buffer.free() >= 256) {
            var temp_buffer: [256]i16 = undefined;
            const decoded = callback(&temp_buffer);
            if (decoded == 0) break; // End of data

            _ = sample_buffer.write(temp_buffer[0..decoded]);
            current_position += decoded / CHANNELS;
        }
    }
}

// ============================================================
// Audio Format Parsers
// ============================================================

/// WAV file header (RIFF format)
pub const WavHeader = extern struct {
    riff_id: [4]u8, // "RIFF"
    file_size: u32 align(1),
    wave_id: [4]u8, // "WAVE"

    pub fn isValid(self: *const WavHeader) bool {
        return std.mem.eql(u8, &self.riff_id, "RIFF") and
            std.mem.eql(u8, &self.wave_id, "WAVE");
    }
};

/// WAV format chunk
pub const WavFmtChunk = extern struct {
    chunk_id: [4]u8, // "fmt "
    chunk_size: u32 align(1),
    audio_format: u16 align(1), // 1 = PCM
    num_channels: u16 align(1),
    sample_rate: u32 align(1),
    byte_rate: u32 align(1),
    block_align: u16 align(1),
    bits_per_sample: u16 align(1),

    pub fn isValid(self: *const WavFmtChunk) bool {
        return std.mem.eql(u8, &self.chunk_id, "fmt ") and
            self.audio_format == 1; // PCM
    }
};

/// Parse WAV header and return track info
pub fn parseWavHeader(data: []const u8) ?TrackInfo {
    if (data.len < @sizeOf(WavHeader) + @sizeOf(WavFmtChunk) + 8) {
        return null;
    }

    const header: *const WavHeader = @ptrCast(@alignCast(data.ptr));
    if (!header.isValid()) return null;

    // Find fmt chunk
    var offset: usize = @sizeOf(WavHeader);
    while (offset + 8 < data.len) {
        const chunk_id = data[offset..][0..4];
        const chunk_size: u32 = @bitCast(data[offset + 4 ..][0..4].*);

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            const fmt: *const WavFmtChunk = @ptrCast(@alignCast(&data[offset]));
            if (!fmt.isValid()) return null;

            // Find data chunk to get total samples
            var data_offset = offset + 8 + chunk_size;
            while (data_offset + 8 < data.len) {
                const data_chunk_id = data[data_offset..][0..4];
                const data_chunk_size: u32 = @bitCast(data[data_offset + 4 ..][0..4].*);

                if (std.mem.eql(u8, data_chunk_id, "data")) {
                    const bytes_per_sample = fmt.bits_per_sample / 8;
                    const total_samples = data_chunk_size / (bytes_per_sample * fmt.num_channels);

                    return TrackInfo{
                        .sample_rate = fmt.sample_rate,
                        .channels = @intCast(fmt.num_channels),
                        .bits_per_sample = @intCast(fmt.bits_per_sample),
                        .total_samples = total_samples,
                        .duration_ms = (@as(u64, total_samples) * 1000) / fmt.sample_rate,
                        .format = if (fmt.bits_per_sample == 16) .s16_le else .u8_pcm,
                    };
                }

                data_offset += 8 + data_chunk_size;
                if (data_chunk_size % 2 != 0) data_offset += 1; // Padding
            }
        }

        offset += 8 + chunk_size;
        if (chunk_size % 2 != 0) offset += 1; // Padding
    }

    return null;
}

/// AIFF file header
pub const AiffHeader = extern struct {
    form_id: [4]u8, // "FORM"
    file_size: u32 align(1), // Big-endian
    aiff_id: [4]u8, // "AIFF"

    pub fn isValid(self: *const AiffHeader) bool {
        return std.mem.eql(u8, &self.form_id, "FORM") and
            std.mem.eql(u8, &self.aiff_id, "AIFF");
    }
};

// ============================================================
// Utility Functions
// ============================================================

/// Convert sample rate to string
pub fn sampleRateString(rate: u32) []const u8 {
    return switch (rate) {
        8000 => "8 kHz",
        11025 => "11.025 kHz",
        16000 => "16 kHz",
        22050 => "22.05 kHz",
        32000 => "32 kHz",
        44100 => "44.1 kHz",
        48000 => "48 kHz",
        else => "Unknown",
    };
}

/// Format position as MM:SS
pub fn formatPosition(position_ms: u64, buffer: []u8) []u8 {
    const secs = position_ms / 1000;
    const mins = secs / 60;
    const remaining_secs = secs % 60;
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}", .{ mins, remaining_secs }) catch buffer[0..0];
}

// ============================================================
// Tests
// ============================================================

test "track info duration" {
    const info = TrackInfo{
        .sample_rate = 44100,
        .channels = 2,
        .bits_per_sample = 16,
        .total_samples = 44100 * 60 * 3, // 3 minutes
        .duration_ms = 180000,
        .format = .s16_le,
    };

    try std.testing.expectEqual(@as(u32, 180), info.durationSeconds());

    var buf: [10]u8 = undefined;
    const formatted = info.formatDuration(&buf);
    try std.testing.expectEqualStrings("03:00", formatted);
}

test "sample format bytes" {
    try std.testing.expectEqual(@as(u8, 2), SampleFormat.s16_le.bytesPerSample());
    try std.testing.expectEqual(@as(u8, 3), SampleFormat.s24_le.bytesPerSample());
    try std.testing.expectEqual(@as(u8, 1), SampleFormat.u8_pcm.bytesPerSample());
}

test "format position" {
    var buf: [10]u8 = undefined;

    const result1 = formatPosition(0, &buf);
    try std.testing.expectEqualStrings("00:00", result1);

    const result2 = formatPosition(125000, &buf);
    try std.testing.expectEqualStrings("02:05", result2);

    const result3 = formatPosition(3661000, &buf); // 1 hour, 1 minute, 1 second
    try std.testing.expectEqualStrings("61:01", result3);
}

test "sample rate string" {
    try std.testing.expectEqualStrings("44.1 kHz", sampleRateString(44100));
    try std.testing.expectEqualStrings("48 kHz", sampleRateString(48000));
    try std.testing.expectEqualStrings("Unknown", sampleRateString(12345));
}
