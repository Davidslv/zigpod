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
const storage_detect = @import("../drivers/storage/storage_detect.zig");

// Logging - see docs/LOGGING_GUIDE.md for usage
const log = @import("../debug/logger.zig").scoped(.audio);
const telemetry = @import("../debug/telemetry.zig");
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

// Export unified audio pipeline
pub const pipeline = @import("pipeline.zig");

// Export audio hardware (DMA-based output)
pub const audio_hw = @import("audio_hw.zig");

// Import FAT32 for file reading
const fat32 = @import("../drivers/storage/fat32.zig");

// ============================================================
// Audio Constants
// ============================================================

/// Default sample rate (CD quality)
pub const DEFAULT_SAMPLE_RATE: u32 = 44100;

/// Audio buffer size (samples, not bytes) - per slot
pub const BUFFER_SIZE: usize = 4096;

/// Number of audio channels
pub const CHANNELS: u8 = 2; // Stereo

/// Gapless pre-buffer time in milliseconds
/// This is the time before end of track when we start loading the next track
/// Note: For HDD storage, use longer pre-buffer to handle seek latency
/// For flash storage (iFlash, etc.), shorter pre-buffer is fine
pub const GAPLESS_PREBUFFER_MS: u32 = 2000;

/// Get recommended pre-buffer time based on storage type
/// HDD needs longer pre-buffer (2000ms) to handle seek latency
/// Flash storage (iFlash, SD) can use shorter pre-buffer (500ms)
pub fn getRecommendedPrebufferMs() u32 {
    return storage_detect.getRecommendedAudioBufferMs();
}

/// Calculate gapless threshold in samples for a given sample rate
/// This ensures consistent ~2 second prebuffer regardless of sample rate
pub fn gaplessThresholdSamples(sample_rate: u32) u64 {
    // samples = sample_rate * channels * (time_ms / 1000)
    // For stereo: samples = sample_rate * 2 * (GAPLESS_PREBUFFER_MS / 1000)
    return @as(u64, sample_rate) * CHANNELS * GAPLESS_PREBUFFER_MS / 1000;
}

/// Legacy constant for backwards compatibility (44.1kHz stereo)
/// DEPRECATED: Use gaplessThresholdSamples(sample_rate) instead
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

// DSP processing chain (EQ, bass boost, stereo widening, volume ramping)
var dsp_chain: dsp.DspChain = dsp.DspChain.init();
var dsp_enabled: bool = true;

// Gapless playback state
var slots: [2]DecoderSlot = .{ DecoderSlot{}, DecoderSlot{} };
var active_slot: u8 = 0;
var next_track_callback: ?NextTrackCallback = null;
var gapless_enabled: bool = true;
var next_track_requested: bool = false; // Prevent duplicate requests

// ============================================================
// File Loading State
// ============================================================

/// Maximum file size we can load (2MB - reasonable for embedded)
pub const MAX_FILE_SIZE: usize = 2 * 1024 * 1024;

/// File buffer for current track
var file_buffer: [MAX_FILE_SIZE]u8 = undefined;
var file_buffer_len: usize = 0;

/// Current decoder state
var current_decoder: CurrentDecoder = .{ .none = {} };

pub const CurrentDecoder = union(enum) {
    none: void,
    wav: decoders.wav.WavDecoder,
    // Future: flac, mp3, etc.
};

/// Track metadata from loaded file
pub const LoadedTrackInfo = struct {
    title: [64]u8 = [_]u8{0} ** 64,
    title_len: u8 = 0,
    artist: [64]u8 = [_]u8{0} ** 64,
    artist_len: u8 = 0,
    album: [64]u8 = [_]u8{0} ** 64,
    album_len: u8 = 0,
    path: [256]u8 = [_]u8{0} ** 256,
    path_len: u16 = 0,

    pub fn getTitle(self: *const LoadedTrackInfo) []const u8 {
        if (self.title_len > 0) return self.title[0..self.title_len];
        // Fall back to filename from path
        return self.getFilename();
    }

    pub fn getArtist(self: *const LoadedTrackInfo) []const u8 {
        if (self.artist_len > 0) return self.artist[0..self.artist_len];
        return "Unknown Artist";
    }

    pub fn getAlbum(self: *const LoadedTrackInfo) []const u8 {
        if (self.album_len > 0) return self.album[0..self.album_len];
        return "Unknown Album";
    }

    pub fn getFilename(self: *const LoadedTrackInfo) []const u8 {
        const path = self.path[0..self.path_len];
        // Find last '/'
        var i: usize = self.path_len;
        while (i > 0) : (i -= 1) {
            if (path[i - 1] == '/') break;
        }
        return path[i..self.path_len];
    }

    pub fn setTitle(self: *LoadedTrackInfo, title: []const u8) void {
        const len = @min(title.len, self.title.len);
        @memcpy(self.title[0..len], title[0..len]);
        self.title_len = @intCast(len);
    }

    pub fn setArtist(self: *LoadedTrackInfo, artist: []const u8) void {
        const len = @min(artist.len, self.artist.len);
        @memcpy(self.artist[0..len], artist[0..len]);
        self.artist_len = @intCast(len);
    }

    pub fn setAlbum(self: *LoadedTrackInfo, album: []const u8) void {
        const len = @min(album.len, self.album.len);
        @memcpy(self.album[0..len], album[0..len]);
        self.album_len = @intCast(len);
    }

    pub fn setPath(self: *LoadedTrackInfo, path: []const u8) void {
        const len = @min(path.len, self.path.len);
        @memcpy(self.path[0..len], path[0..len]);
        self.path_len = @intCast(len);
    }
};

var loaded_track_info: LoadedTrackInfo = .{};

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
    log.info("Initializing audio engine", .{});

    // Initialize codec (pre-init phase)
    try codec.preinit();
    log.debug("Codec pre-init complete", .{});

    // Initialize I2S
    try i2s.init(.{
        .sample_rate = DEFAULT_SAMPLE_RATE,
        .format = .i2s_standard,
        .sample_size = .bits_16,
    });
    log.debug("I2S initialized at {d}Hz", .{DEFAULT_SAMPLE_RATE});

    // Enable I2S output
    i2s.enable();

    // Codec post-init
    try codec.postinit();
    log.debug("Codec post-init complete", .{});

    // Set initial volume
    try codec.setVolume(volume_left, volume_right);

    initialized = true;
    state = .stopped;

    // Log storage-aware buffer configuration
    const prebuffer_ms = getRecommendedPrebufferMs();
    log.info("Audio engine ready (buffer={d} samples, prebuffer={d}ms, flash={})", .{
        BUFFER_SIZE,
        prebuffer_ms,
        storage_detect.isFlashStorage(),
    });
}

/// Shutdown the audio engine
pub fn shutdown() void {
    if (!initialized) return;

    log.info("Shutting down audio engine", .{});
    stop();
    i2s.disable();
    codec.shutdown() catch {};
    initialized = false;
    log.debug("Audio engine shutdown complete", .{});
}

/// Check if audio engine is initialized
pub fn isInitialized() bool {
    return initialized;
}

// ============================================================
// File Loading
// ============================================================

pub const LoadError = error{
    FileNotFound,
    FileTooLarge,
    ReadError,
    UnsupportedFormat,
    DecoderError,
    NotInitialized,
};

/// Load and play an audio file from the filesystem
/// This is the main entry point for playing a file from the UI
pub fn loadFile(path: []const u8) LoadError!void {
    log.info("Loading file: {s}", .{path});

    if (!initialized) {
        log.err("Cannot load file - audio engine not initialized", .{});
        return LoadError.NotInitialized;
    }

    // Stop any current playback
    stop();

    // Store path in track info
    loaded_track_info = .{};
    loaded_track_info.setPath(path);

    // Read file from FAT32
    file_buffer_len = fat32.readFile(path, &file_buffer) catch |err| {
        log.err("Failed to read file: {s}", .{@errorName(err)});
        return switch (err) {
            fat32.FatError.file_not_found => LoadError.FileNotFound,
            else => LoadError.ReadError,
        };
    };

    if (file_buffer_len == 0) {
        log.err("File is empty", .{});
        return LoadError.ReadError;
    }
    if (file_buffer_len > MAX_FILE_SIZE) {
        log.err("File too large: {d} bytes (max {d})", .{ file_buffer_len, MAX_FILE_SIZE });
        return LoadError.FileTooLarge;
    }

    log.debug("Read {d} bytes from file", .{file_buffer_len});

    // Detect format and initialize decoder
    const format = decoders.detectFormat(file_buffer[0..file_buffer_len]);
    log.debug("Detected format: {s}", .{@tagName(format)});

    switch (format) {
        .wav => {
            var wav_decoder = decoders.wav.WavDecoder.init(file_buffer[0..file_buffer_len]) catch {
                log.err("Failed to initialize WAV decoder", .{});
                return LoadError.DecoderError;
            };
            current_decoder = .{ .wav = wav_decoder };

            // Extract title from filename (remove extension)
            const filename = loaded_track_info.getFilename();
            if (filename.len > 4) {
                loaded_track_info.setTitle(filename[0 .. filename.len - 4]);
            } else {
                loaded_track_info.setTitle(filename);
            }

            // Start playback with decoder callback
            const track_info = wav_decoder.getTrackInfo();
            log.info("Playing WAV: {d}Hz, {d}-bit, {d}ch, {d}ms", .{
                track_info.sample_rate,
                track_info.bits_per_sample,
                track_info.channels,
                track_info.duration_ms,
            });

            play(wavDecodeCallback, track_info) catch {
                log.err("Failed to start playback", .{});
                return LoadError.DecoderError;
            };
        },
        .flac, .mp3, .aiff, .aac, .m4a => {
            log.warn("Unsupported format: {s}", .{@tagName(format)});
            return LoadError.UnsupportedFormat;
        },
        .unknown => {
            log.err("Unknown audio format", .{});
            return LoadError.UnsupportedFormat;
        },
    }
}

/// WAV decoder callback for audio engine
fn wavDecodeCallback(output: []i16) usize {
    switch (current_decoder) {
        .wav => |*decoder| {
            return decoder.decode(output);
        },
        .none => return 0,
    }
}

/// Get current loaded track metadata
pub fn getLoadedTrackInfo() *const LoadedTrackInfo {
    return &loaded_track_info;
}

/// Check if a file is loaded and ready
pub fn hasLoadedTrack() bool {
    return current_decoder != .none;
}

/// Restart current track from beginning
pub fn restartTrack() void {
    switch (current_decoder) {
        .wav => |*decoder| {
            decoder.seek(0);
            slots[active_slot].position = 0;
            slots[active_slot].buffer.clear();
        },
        .none => {},
    }
}

/// Skip to next track (requires playlist, for now just stops)
pub fn nextTrack() void {
    // For now, stop playback - full implementation needs playlist
    stop();
}

/// Go to previous track or restart current
/// Restarts if more than 3 seconds into track, otherwise would go to previous
pub fn prevTrack() void {
    const position_ms = getPositionMs();
    if (position_ms > 3000) {
        // More than 3 seconds in - restart current track
        restartTrack();
    } else {
        // Less than 3 seconds - for now just restart (needs playlist for prev)
        restartTrack();
    }
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
    if (state != .stopped) {
        log.info("Stopping playback", .{});
    }
    state = .stopped;
    slots[0].reset();
    slots[1].reset();
    active_slot = 0;
    next_track_requested = false;
}

/// Pause playback
pub fn pause() void {
    if (state == .playing) {
        log.info("Pausing playback", .{});
        state = .paused;
    }
}

/// Resume playback
pub fn resumePlayback() void {
    if (state == .paused) {
        log.info("Resuming playback", .{});
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
// DSP Effects Control
// ============================================================

/// Get the DSP chain for direct access
pub fn getDspChain() *dsp.DspChain {
    return &dsp_chain;
}

/// Enable/disable DSP processing
pub fn setDspEnabled(enabled: bool) void {
    dsp_enabled = enabled;
}

/// Check if DSP is enabled
pub fn isDspEnabled() bool {
    return dsp_enabled;
}

/// Set software volume via DSP (0-100%)
/// This uses smooth ramping to prevent clicks
pub fn setDspVolume(percent: u8) void {
    dsp_chain.setVolume(percent);
}

/// Get current DSP volume
pub fn getDspVolume() u8 {
    return dsp_chain.getVolume();
}

/// Set EQ band gain (-12 to +12 dB)
pub fn setEqBand(band: usize, gain_db: i8) void {
    dsp_chain.equalizer.setBandGain(band, gain_db);
}

/// Get EQ band gain
pub fn getEqBand(band: usize) i8 {
    return dsp_chain.equalizer.getBandGain(band);
}

/// Apply an EQ preset by index
pub fn applyEqPreset(preset_index: usize) void {
    dsp_chain.applyPreset(preset_index);
}

/// Enable/disable EQ
pub fn setEqEnabled(enabled: bool) void {
    dsp_chain.equalizer.enabled = enabled;
}

/// Check if EQ is enabled
pub fn isEqEnabled() bool {
    return dsp_chain.equalizer.enabled;
}

/// Set bass boost (0-12 dB)
pub fn setBassBoost(db: i8) void {
    dsp_chain.bass_boost.setBoost(db);
    dsp_chain.bass_boost.enabled = db > 0;
}

/// Get bass boost level
pub fn getBassBoost() i8 {
    return dsp_chain.bass_boost.boost_db;
}

/// Set stereo width (0-200%, 100 = normal)
pub fn setStereoWidth(percent: u8) void {
    dsp_chain.stereo_widener.setWidth(percent);
    dsp_chain.stereo_widener.enabled = percent != 100;
}

/// Check if volume is currently ramping
pub fn isVolumeRamping() bool {
    return dsp_chain.isVolumeRamping();
}

/// Mute via DSP with smooth fade out
pub fn dspMute() void {
    dsp_chain.mute();
}

/// Unmute via DSP with smooth fade in
pub fn dspUnmute(percent: u8) void {
    dsp_chain.unmute(percent);
}

// ============================================================
// Audio Processing (called from main loop or interrupt)
// ============================================================

// Track buffer underrun statistics
var underrun_count: u32 = 0;
var last_buffer_level: usize = 0;

/// Process audio - call this regularly from main loop
pub fn process() hal.HalError!void {
    if (!initialized or state != .playing) return;

    const slot = &slots[active_slot];

    // Fill active slot buffer if needed
    if (slot.buffer.len() < BUFFER_SIZE) {
        fillSlotBuffer(active_slot);
    }

    // Detect buffer underrun (buffer critically low while playing)
    const buffer_level = slot.buffer.len();
    if (buffer_level == 0 and last_buffer_level > 0 and slot.state == .active) {
        underrun_count += 1;
        log.warn("Buffer underrun detected (count={d})", .{underrun_count});
        telemetry.record(.audio_buffer_underrun, @truncate(underrun_count), @truncate(buffer_level));
    }
    last_buffer_level = buffer_level;

    // Check if we need to request next track for gapless playback
    if (gapless_enabled and !next_track_requested) {
        const remaining = slot.remainingSamples();
        // Use storage-aware threshold for gapless prebuffer
        // HDD needs larger threshold (2000ms) for seek latency
        // Flash storage (iFlash, etc.) can use smaller threshold (500ms)
        const prebuffer_ms = getRecommendedPrebufferMs();
        const threshold = if (slot.track_info) |info|
            gaplessThresholdSamples(info.sample_rate) * prebuffer_ms / GAPLESS_PREBUFFER_MS
        else
            GAPLESS_THRESHOLD;

        if (remaining < threshold and remaining > 0) {
            log.debug("Requesting next track for gapless (remaining={d} samples, threshold={d})", .{ remaining, threshold });
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
            // Apply DSP processing (EQ, bass boost, stereo widening, volume)
            if (dsp_enabled) {
                dsp_chain.processBuffer(samples[0..count]);
            }
            _ = try i2s.write(samples[0..count]);
        }
    }

    // Check for end of track and gapless transition
    if (slot.track_info) |track| {
        const finished = slot.position >= track.total_samples and slot.buffer.isEmpty();

        if (finished) {
            // Mark current slot as finished
            slot.state = .finishing;
            log.debug("Track finished, attempting gapless transition", .{});

            // Attempt gapless transition
            if (gapless_enabled and tryGaplessTransition()) {
                // Successfully transitioned to next track
                log.info("Gapless transition successful", .{});
                next_track_requested = false;
            } else {
                // No next track, stop playback
                log.info("Playback complete (no next track)", .{});
                state = .stopped;
                slot.state = .empty;
            }
        }
    }
}

/// Get buffer underrun count (for diagnostics)
pub fn getUnderrunCount() u32 {
    return underrun_count;
}

/// Reset underrun counter
pub fn resetUnderrunCount() void {
    underrun_count = 0;
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
