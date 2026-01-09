//! Unified Audio Pipeline
//!
//! Chains all audio processing components into a single unified pipeline:
//! Decoder → Resampler → Ditherer → DSP Chain → Output
//!
//! This module solves the integration problem where decoders, effects,
//! and output were previously disconnected components.

const std = @import("std");
const dsp = @import("dsp.zig");
const decoders = @import("decoders/decoders.zig");
const audio = @import("audio.zig");

// ============================================================
// Pipeline Configuration
// ============================================================

/// Pipeline configuration options
pub const PipelineConfig = struct {
    /// Target output sample rate (typically 44100 or 48000)
    output_sample_rate: u32 = 44100,
    /// Enable resampling when input rate differs from output
    enable_resampling: bool = true,
    /// Enable dithering when reducing bit depth
    enable_dithering: bool = true,
    /// Enable DSP effects (EQ, bass boost, etc.)
    enable_dsp: bool = true,
    /// Enable volume ramping to prevent clicks
    enable_volume_ramping: bool = true,
};

// ============================================================
// Pipeline Statistics
// ============================================================

/// Performance and health metrics
pub const PipelineStats = struct {
    /// Total samples decoded
    samples_decoded: u64 = 0,
    /// Total samples output
    samples_output: u64 = 0,
    /// Buffer underruns (output starved)
    underruns: u32 = 0,
    /// Buffer overruns (input overflow)
    overruns: u32 = 0,
    /// Current input sample rate
    input_sample_rate: u32 = 0,
    /// Current output sample rate
    output_sample_rate: u32 = 0,
    /// Peak CPU usage estimate (0-100)
    peak_cpu_percent: u8 = 0,
    /// Is resampling active
    resampling_active: bool = false,
    /// Is dithering active
    dithering_active: bool = false,

    pub fn reset(self: *PipelineStats) void {
        self.samples_decoded = 0;
        self.samples_output = 0;
        self.underruns = 0;
        self.overruns = 0;
        self.peak_cpu_percent = 0;
    }
};

// ============================================================
// Audio Pipeline
// ============================================================

/// Unified audio processing pipeline
/// Chains: Decoder → Resampler → Ditherer → DSP → Output
pub const AudioPipeline = struct {
    /// Pipeline configuration
    config: PipelineConfig,

    /// DSP effects chain (EQ, bass boost, stereo widener, volume)
    dsp_chain: dsp.DspChain,

    /// Sample rate converter
    resampler: dsp.Resampler,

    /// Ditherer for bit-depth reduction
    ditherer: dsp.Ditherer,

    /// Pipeline statistics
    stats: PipelineStats,

    /// Current decoder type
    decoder_type: decoders.DecoderType,

    /// Decoder state union
    decoder: DecoderState,

    /// Input sample rate from current source
    input_sample_rate: u32,

    /// Input bits per sample
    input_bits: u8,

    /// Is pipeline active
    active: bool,

    /// Intermediate buffer for resampling (32-bit for headroom)
    resample_buffer: [1024]i32,

    /// Output buffer (16-bit stereo)
    output_buffer: [2048]i16,

    /// Output buffer fill level
    output_fill: usize,

    /// Union of possible decoder states
    /// Now uses actual decoder implementations instead of placeholder stubs
    pub const DecoderState = union(enum) {
        none: void,
        wav: decoders.wav.WavDecoder,
        flac: decoders.flac.FlacDecoder,
        mp3: decoders.mp3.Mp3Decoder,
        aiff: decoders.aiff.AiffDecoder,
        aac: decoders.aac.AacDecoder,
    };

    /// Initialize pipeline with default configuration
    pub fn init() AudioPipeline {
        return initWithConfig(.{});
    }

    /// Initialize pipeline with custom configuration
    pub fn initWithConfig(config: PipelineConfig) AudioPipeline {
        var pipeline = AudioPipeline{
            .config = config,
            .dsp_chain = dsp.DspChain.init(),
            .resampler = dsp.Resampler.init(),
            .ditherer = dsp.Ditherer.init(),
            .stats = PipelineStats{},
            .decoder_type = .unknown,
            .decoder = .{ .none = {} },
            .input_sample_rate = 44100,
            .input_bits = 16,
            .active = false,
            .resample_buffer = undefined,
            .output_buffer = undefined,
            .output_fill = 0,
        };

        // Configure resampler for target output rate
        pipeline.resampler.configure(44100, config.output_sample_rate);

        return pipeline;
    }

    /// Load audio data and auto-detect format
    /// Now properly initializes actual decoder implementations
    pub fn load(self: *AudioPipeline, data: []const u8) !void {
        // Stop any current playback
        self.stop();

        // Detect format
        self.decoder_type = decoders.detectFormat(data);

        // Initialize appropriate decoder using actual implementations
        switch (self.decoder_type) {
            .wav => {
                const wav_decoder = try decoders.wav.WavDecoder.init(data);
                self.decoder = .{ .wav = wav_decoder };
                const info = wav_decoder.getTrackInfo();
                self.input_sample_rate = info.sample_rate;
                self.input_bits = info.bits_per_sample;
            },
            .flac => {
                const flac_decoder = try decoders.flac.FlacDecoder.init(data);
                self.decoder = .{ .flac = flac_decoder };
                const info = flac_decoder.getTrackInfo();
                self.input_sample_rate = info.sample_rate;
                self.input_bits = info.bits_per_sample;
            },
            .mp3 => {
                const mp3_decoder = try decoders.mp3.Mp3Decoder.init(data);
                self.decoder = .{ .mp3 = mp3_decoder };
                const info = mp3_decoder.getTrackInfo();
                self.input_sample_rate = info.sample_rate;
                self.input_bits = info.bits_per_sample;
            },
            .aiff => {
                const aiff_decoder = try decoders.aiff.AiffDecoder.init(data);
                self.decoder = .{ .aiff = aiff_decoder };
                const info = aiff_decoder.getTrackInfo();
                self.input_sample_rate = info.sample_rate;
                self.input_bits = info.bits_per_sample;
            },
            .aac, .m4a => {
                const aac_decoder = try decoders.aac.AacDecoder.init(data);
                self.decoder = .{ .aac = aac_decoder };
                const info = aac_decoder.getTrackInfo();
                self.input_sample_rate = info.sample_rate;
                self.input_bits = info.bits_per_sample;
            },
            .unknown => return error.UnsupportedFormat,
        }

        // Configure resampler if rates differ
        if (self.config.enable_resampling and
            self.input_sample_rate != self.config.output_sample_rate)
        {
            self.resampler.configure(self.input_sample_rate, self.config.output_sample_rate);
            self.stats.resampling_active = true;
        } else {
            self.resampler.configure(self.input_sample_rate, self.input_sample_rate);
            self.stats.resampling_active = false;
        }

        // Configure dithering if reducing bit depth
        self.stats.dithering_active = self.config.enable_dithering and self.input_bits > 16;
        self.ditherer.enabled = self.stats.dithering_active;

        // Update stats
        self.stats.input_sample_rate = self.input_sample_rate;
        self.stats.output_sample_rate = self.config.output_sample_rate;

        self.active = true;
    }

    /// Get track information from loaded decoder
    pub fn getTrackInfo(self: *const AudioPipeline) ?audio.TrackInfo {
        return switch (self.decoder) {
            .none => null,
            .wav => |d| d.getTrackInfo(),
            .flac => |d| d.getTrackInfo(),
            .mp3 => |d| d.getTrackInfo(),
            .aiff => |d| d.getTrackInfo(),
            .aac => |d| d.getTrackInfo(),
        };
    }

    /// Process audio through the pipeline
    /// Returns number of output samples written
    pub fn process(self: *AudioPipeline, output: []i16) usize {
        if (!self.active) return 0;

        var total_output: usize = 0;
        var decode_buffer: [512]i16 = undefined;

        while (total_output < output.len) {
            // Step 1: Decode from source
            const decoded = self.decodeFromSource(&decode_buffer);
            if (decoded == 0) {
                // End of stream
                self.active = false;
                break;
            }
            self.stats.samples_decoded += decoded;

            // Step 2: Resample if needed
            var resampled: []i16 = decode_buffer[0..decoded];
            var resample_out: [1024]i16 = undefined;

            if (self.stats.resampling_active) {
                const resample_count = self.resampler.resampleBuffer(
                    decode_buffer[0..decoded],
                    &resample_out,
                );
                resampled = resample_out[0 .. resample_count * 2];
            }

            // Step 3: Apply DSP chain (includes dithering via volume ramper)
            if (self.config.enable_dsp) {
                self.dsp_chain.processBuffer(resampled);
            }

            // Step 4: Copy to output
            const to_copy = @min(resampled.len, output.len - total_output);
            @memcpy(output[total_output..][0..to_copy], resampled[0..to_copy]);
            total_output += to_copy;
        }

        self.stats.samples_output += total_output / 2; // Stereo samples
        return total_output;
    }

    /// Decode samples from the current source
    /// Handles different return types from decoders (FLAC returns error union)
    fn decodeFromSource(self: *AudioPipeline, output: []i16) usize {
        return switch (self.decoder) {
            .none => 0,
            .wav => |*d| d.decode(output),
            .flac => |*d| d.decode(output) catch 0, // FLAC returns error union
            .mp3 => |*d| d.decode(output),
            .aiff => |*d| d.decode(output),
            .aac => |*d| d.decode(output),
        };
    }

    /// Stop the pipeline
    pub fn stop(self: *AudioPipeline) void {
        self.active = false;
        self.decoder = .{ .none = {} };
        self.decoder_type = .unknown;
        self.output_fill = 0;
        self.resampler.reset();
        self.ditherer.reset();
    }

    /// Check if pipeline is active
    pub fn isActive(self: *const AudioPipeline) bool {
        return self.active;
    }

    /// Get current decoder type
    pub fn getDecoderType(self: *const AudioPipeline) decoders.DecoderType {
        return self.decoder_type;
    }

    // ============================================================
    // DSP Control Pass-through
    // ============================================================

    /// Set volume (0-100%)
    pub fn setVolume(self: *AudioPipeline, percent: u8) void {
        self.dsp_chain.setVolume(percent);
    }

    /// Get current volume
    pub fn getVolume(self: *const AudioPipeline) u8 {
        return self.dsp_chain.getVolume();
    }

    /// Mute with fade out
    pub fn mute(self: *AudioPipeline) void {
        self.dsp_chain.mute();
    }

    /// Unmute with fade in
    pub fn unmute(self: *AudioPipeline, percent: u8) void {
        self.dsp_chain.unmute(percent);
    }

    /// Set EQ band gain
    pub fn setEqBand(self: *AudioPipeline, band: usize, gain_db: i8) void {
        self.dsp_chain.equalizer.setBandGain(band, gain_db);
    }

    /// Get EQ band gain
    pub fn getEqBand(self: *const AudioPipeline, band: usize) i8 {
        return self.dsp_chain.equalizer.getBandGain(band);
    }

    /// Apply EQ preset
    pub fn applyEqPreset(self: *AudioPipeline, preset_index: usize) void {
        self.dsp_chain.applyPreset(preset_index);
    }

    /// Enable/disable bass boost
    pub fn setBassBoost(self: *AudioPipeline, enabled: bool, db: i8) void {
        self.dsp_chain.bass_boost.enabled = enabled;
        self.dsp_chain.bass_boost.setBoost(db);
    }

    /// Enable/disable stereo widening
    pub fn setStereoWidth(self: *AudioPipeline, enabled: bool, percent: u8) void {
        self.dsp_chain.stereo_widener.enabled = enabled;
        self.dsp_chain.stereo_widener.setWidth(percent);
    }

    /// Enable/disable entire DSP chain
    pub fn setDspEnabled(self: *AudioPipeline, enabled: bool) void {
        self.dsp_chain.enabled = enabled;
    }

    // ============================================================
    // Statistics
    // ============================================================

    /// Get pipeline statistics
    pub fn getStats(self: *const AudioPipeline) PipelineStats {
        return self.stats;
    }

    /// Reset statistics
    pub fn resetStats(self: *AudioPipeline) void {
        self.stats.reset();
    }

    /// Record a buffer underrun
    pub fn recordUnderrun(self: *AudioPipeline) void {
        self.stats.underruns += 1;
    }

    /// Record a buffer overrun
    pub fn recordOverrun(self: *AudioPipeline) void {
        self.stats.overruns += 1;
    }
};

// ============================================================
// Global Pipeline Instance
// ============================================================

var global_pipeline: ?AudioPipeline = null;

/// Initialize the global pipeline
pub fn initGlobal() void {
    global_pipeline = AudioPipeline.init();
}

/// Initialize the global pipeline with config
pub fn initGlobalWithConfig(config: PipelineConfig) void {
    global_pipeline = AudioPipeline.initWithConfig(config);
}

/// Get the global pipeline
pub fn getGlobal() ?*AudioPipeline {
    if (global_pipeline) |*p| {
        return p;
    }
    return null;
}

/// Shutdown the global pipeline
pub fn shutdownGlobal() void {
    if (global_pipeline) |*p| {
        p.stop();
    }
    global_pipeline = null;
}

// ============================================================
// Tests
// ============================================================

test "pipeline initialization" {
    const pipeline = AudioPipeline.init();
    try std.testing.expect(!pipeline.active);
    try std.testing.expectEqual(decoders.DecoderType.unknown, pipeline.decoder_type);
}

test "pipeline config" {
    const config = PipelineConfig{
        .output_sample_rate = 48000,
        .enable_dsp = false,
    };

    const pipeline = AudioPipeline.initWithConfig(config);
    try std.testing.expectEqual(@as(u32, 48000), pipeline.config.output_sample_rate);
    try std.testing.expect(!pipeline.config.enable_dsp);
}

test "pipeline volume control" {
    var pipeline = AudioPipeline.init();

    pipeline.setVolume(75);
    try std.testing.expectEqual(@as(u8, 75), pipeline.getVolume());

    pipeline.setVolume(50);
    try std.testing.expectEqual(@as(u8, 50), pipeline.getVolume());
}

test "pipeline EQ control" {
    var pipeline = AudioPipeline.init();

    pipeline.setEqBand(0, 6);
    try std.testing.expectEqual(@as(i8, 6), pipeline.getEqBand(0));

    pipeline.setEqBand(2, -3);
    try std.testing.expectEqual(@as(i8, -3), pipeline.getEqBand(2));
}

test "pipeline statistics" {
    var pipeline = AudioPipeline.init();

    try std.testing.expectEqual(@as(u64, 0), pipeline.stats.samples_decoded);
    try std.testing.expectEqual(@as(u32, 0), pipeline.stats.underruns);

    pipeline.recordUnderrun();
    try std.testing.expectEqual(@as(u32, 1), pipeline.stats.underruns);

    pipeline.resetStats();
    try std.testing.expectEqual(@as(u32, 0), pipeline.stats.underruns);
}

test "global pipeline" {
    initGlobal();
    defer shutdownGlobal();

    const pipeline = getGlobal();
    try std.testing.expect(pipeline != null);
}
