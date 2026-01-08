//! Audio Playback Engine
//!
//! High-level audio playback system that coordinates codec, I2S, and file reading.
//! Supports WAV and FLAC formats with room for adding more codecs.
//!
//! Gapless Playback Architecture:
//! - Dual decoder slots allow pre-buffering the next track
//! - When current track nears end, next track is loaded into alternate slot
//! - Seamless handoff when current track buffer empties
//! - No crossfade - pure gapless transition

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

/// Audio buffer size (samples, not bytes) - per slot
pub const BUFFER_SIZE: usize = 4096;

/// Number of audio channels
pub const CHANNELS: u8 = 2; // Stereo

/// Threshold for triggering next track pre-buffer (samples remaining)
/// At 44.1kHz stereo, ~2 seconds of audio
pub const GAPLESS_THRESHOLD: u64 = 88200;

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
// Gapless Playback Types
// ============================================================

/// Decode callback function type
pub const DecodeCallback = *const fn (output: []i16) usize;

/// Callback to request next track for gapless playback
/// Returns true if next track was queued, false if no more tracks
pub const NextTrackCallback = *const fn () bool;

/// State of a decoder slot
pub const SlotState = enum {
    empty, // No track loaded
    loading, // Track is being loaded/pre-buffered
    ready, // Pre-buffered and ready to play
    active, // Currently playing
    finishing, // Playing but no more data to decode
};

/// Decoder slot for gapless playback
/// Each slot has its own buffer and decoder state
pub const DecoderSlot = struct {
    callback: ?DecodeCallback = null,
    track_info: ?TrackInfo = null,
    buffer: RingBuffer(i16, BUFFER_SIZE * 2) = RingBuffer(i16, BUFFER_SIZE * 2).init(),
    position: u64 = 0, // Current sample position in track
    state: SlotState = .empty,

    /// Reset slot to empty state
    pub fn reset(self: *DecoderSlot) void {
        self.callback = null;
        self.track_info = null;
        self.buffer.clear();
        self.position = 0;
        self.state = .empty;
    }

    /// Check if this slot has audio ready to play
    pub fn hasAudio(self: *const DecoderSlot) bool {
        return self.state == .active or self.state == .finishing or
            (self.state == .ready and !self.buffer.isEmpty());
    }

    /// Get remaining samples in track
    pub fn remainingSamples(self: *const DecoderSlot) u64 {
        if (self.track_info) |info| {
            if (self.position < info.total_samples) {
                return info.total_samples - self.position;
            }
        }
        return 0;
    }
};

// ============================================================
// Audio Engine State
// ============================================================

var state: PlaybackState = .stopped;
var volume_left: i16 = -10; // Volume in dB (-89 to +6)
var volume_right: i16 = -10;
var muted: bool = false;
var initialized: bool = false;

// Gapless playback state
var slots: [2]DecoderSlot = .{ DecoderSlot{}, DecoderSlot{} };
var active_slot: u8 = 0;
var next_track_callback: ?NextTrackCallback = null;
var gapless_enabled: bool = true;
var next_track_requested: bool = false; // Prevent duplicate requests

// Legacy compatibility - these now reference the active slot
fn current_track() ?TrackInfo {
    return slots[active_slot].track_info;
}

fn current_position() u64 {
    return slots[active_slot].position;
}

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

    // Configure sample rate if different from current
    const current = current_track();
    if (current == null or current.?.sample_rate != track_info.sample_rate) {
        try i2s.setSampleRate(track_info.sample_rate);
        try codec.setSampleRate(track_info.sample_rate);
    }

    // Reset both slots and use slot 0
    slots[0].reset();
    slots[1].reset();
    active_slot = 0;
    next_track_requested = false;

    // Set up active slot
    slots[0].callback = callback;
    slots[0].track_info = track_info;
    slots[0].position = 0;
    slots[0].state = .active;

    // Pre-fill buffer
    fillSlotBuffer(0);

    state = .playing;
}

/// Queue next track for gapless playback (called by playlist controller)
/// This loads the track into the inactive slot for seamless transition
pub fn queueNextTrack(callback: DecodeCallback, track_info: TrackInfo) hal.HalError!void {
    if (!initialized) return hal.HalError.DeviceNotReady;

    const next_slot = (active_slot + 1) % 2;

    // Only queue if next slot is empty or ready to be replaced
    if (slots[next_slot].state != .empty and slots[next_slot].state != .ready) {
        return; // Slot is busy
    }

    // Reset and prepare next slot
    slots[next_slot].reset();
    slots[next_slot].callback = callback;
    slots[next_slot].track_info = track_info;
    slots[next_slot].position = 0;
    slots[next_slot].state = .loading;

    // Pre-fill the next track's buffer
    fillSlotBuffer(next_slot);

    // Mark as ready
    slots[next_slot].state = .ready;
}

/// Check if a track is queued for gapless playback
pub fn hasQueuedTrack() bool {
    const next_slot = (active_slot + 1) % 2;
    return slots[next_slot].state == .ready;
}

/// Set callback for requesting next track
pub fn setNextTrackCallback(callback: ?NextTrackCallback) void {
    next_track_callback = callback;
}

/// Enable or disable gapless playback
pub fn setGaplessEnabled(enabled: bool) void {
    gapless_enabled = enabled;
}

/// Check if gapless playback is enabled
pub fn isGaplessEnabled() bool {
    return gapless_enabled;
}

/// Stop playback
pub fn stop() void {
    state = .stopped;
    slots[0].reset();
    slots[1].reset();
    active_slot = 0;
    next_track_requested = false;
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
    if (current_track()) |track| {
        return (current_position() * 1000) / track.sample_rate;
    }
    return 0;
}

/// Get current position as percentage (0-100)
pub fn getPositionPercent() u8 {
    if (current_track()) |track| {
        if (track.total_samples > 0) {
            return @intCast((current_position() * 100) / track.total_samples);
        }
    }
    return 0;
}

/// Seek to position (in milliseconds)
pub fn seekMs(position_ms: u64) void {
    if (current_track()) |track| {
        const target_sample = (position_ms * track.sample_rate) / 1000;
        slots[active_slot].position = @min(target_sample, track.total_samples);
        slots[active_slot].buffer.clear();
        // Disable gapless for this transition since we're seeking
        next_track_requested = false;
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
    return current_track();
}

/// Get the active decoder slot (for advanced use)
pub fn getActiveSlot() *const DecoderSlot {
    return &slots[active_slot];
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

    const slot = &slots[active_slot];

    // Fill active slot buffer if needed
    if (slot.buffer.len() < BUFFER_SIZE) {
        fillSlotBuffer(active_slot);
    }

    // Check if we need to request next track for gapless playback
    if (gapless_enabled and !next_track_requested) {
        const remaining = slot.remainingSamples();
        if (remaining < GAPLESS_THRESHOLD and remaining > 0) {
            // Request next track from playlist controller
            if (next_track_callback) |callback| {
                next_track_requested = true;
                _ = callback();
            }
        }
    }

    // Write samples to I2S from active slot
    while (i2s.txReady() and !slot.buffer.isEmpty()) {
        var samples: [64]i16 = undefined;
        const count = slot.buffer.read(&samples);
        if (count > 0) {
            _ = try i2s.write(samples[0..count]);
        }
    }

    // Check for end of track and gapless transition
    if (slot.track_info) |track| {
        const finished = slot.position >= track.total_samples and slot.buffer.isEmpty();

        if (finished) {
            // Mark current slot as finished
            slot.state = .finishing;

            // Attempt gapless transition
            if (gapless_enabled and tryGaplessTransition()) {
                // Successfully transitioned to next track
                next_track_requested = false;
            } else {
                // No next track, stop playback
                state = .stopped;
                slot.state = .empty;
            }
        }
    }
}

/// Attempt gapless transition to next track
/// Returns true if transition successful
fn tryGaplessTransition() bool {
    const next_slot_idx = (active_slot + 1) % 2;
    const next_slot = &slots[next_slot_idx];

    // Check if next slot has a track ready
    if (next_slot.state != .ready) {
        return false;
    }

    // Handle sample rate change if needed
    if (next_slot.track_info) |next_info| {
        if (current_track()) |curr_info| {
            if (next_info.sample_rate != curr_info.sample_rate) {
                // Sample rate differs - configure hardware
                // Note: This may cause a brief gap, but it's unavoidable
                i2s.setSampleRate(next_info.sample_rate) catch return false;
                codec.setSampleRate(next_info.sample_rate) catch return false;
            }
        }
    }

    // Clear old slot
    slots[active_slot].reset();

    // Switch to next slot
    active_slot = next_slot_idx;
    next_slot.state = .active;

    return true;
}

/// Fill a specific slot's buffer from its decoder
fn fillSlotBuffer(slot_idx: u8) void {
    const slot = &slots[slot_idx];

    if (slot.callback) |callback| {
        while (slot.buffer.free() >= 256) {
            var temp_buffer: [256]i16 = undefined;
            const decoded = callback(&temp_buffer);
            if (decoded == 0) {
                // End of data - mark slot as finishing if active
                if (slot.state == .active) {
                    slot.state = .finishing;
                }
                break;
            }

            _ = slot.buffer.write(temp_buffer[0..decoded]);
            slot.position += decoded / CHANNELS;
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

test "decoder slot reset" {
    var slot = DecoderSlot{};

    // Set up slot with some state
    slot.track_info = TrackInfo{
        .sample_rate = 44100,
        .channels = 2,
        .bits_per_sample = 16,
        .total_samples = 44100,
        .duration_ms = 1000,
        .format = .s16_le,
    };
    slot.position = 1000;
    slot.state = .active;

    // Reset and verify
    slot.reset();

    try std.testing.expectEqual(@as(?TrackInfo, null), slot.track_info);
    try std.testing.expectEqual(@as(u64, 0), slot.position);
    try std.testing.expectEqual(SlotState.empty, slot.state);
    try std.testing.expect(slot.buffer.isEmpty());
}

test "decoder slot remaining samples" {
    var slot = DecoderSlot{};

    // No track info - should return 0
    try std.testing.expectEqual(@as(u64, 0), slot.remainingSamples());

    // Set up track
    slot.track_info = TrackInfo{
        .sample_rate = 44100,
        .channels = 2,
        .bits_per_sample = 16,
        .total_samples = 44100,
        .duration_ms = 1000,
        .format = .s16_le,
    };
    slot.position = 0;

    try std.testing.expectEqual(@as(u64, 44100), slot.remainingSamples());

    // Advance position
    slot.position = 22050;
    try std.testing.expectEqual(@as(u64, 22050), slot.remainingSamples());

    // At end
    slot.position = 44100;
    try std.testing.expectEqual(@as(u64, 0), slot.remainingSamples());
}

test "decoder slot hasAudio" {
    var slot = DecoderSlot{};

    // Empty slot - no audio
    try std.testing.expect(!slot.hasAudio());

    // Active slot - has audio
    slot.state = .active;
    try std.testing.expect(slot.hasAudio());

    // Finishing slot - has audio
    slot.state = .finishing;
    try std.testing.expect(slot.hasAudio());

    // Ready slot with buffer data - has audio
    slot.state = .ready;
    var data: [10]i16 = undefined;
    _ = slot.buffer.write(&data);
    try std.testing.expect(slot.hasAudio());

    // Ready slot with empty buffer - no audio
    slot.buffer.clear();
    try std.testing.expect(!slot.hasAudio());
}

test "gapless enabled state" {
    // Default should be enabled
    try std.testing.expect(isGaplessEnabled());

    // Disable and verify
    setGaplessEnabled(false);
    try std.testing.expect(!isGaplessEnabled());

    // Re-enable
    setGaplessEnabled(true);
    try std.testing.expect(isGaplessEnabled());
}
