//! Digital Signal Processing for Audio
//!
//! Provides equalizer, bass boost, stereo widening, and other audio effects.
//! Uses fixed-point math for efficiency on the ARM7TDMI processor.

const std = @import("std");
const fixed = @import("../lib/fixed_point.zig");

// ============================================================
// Constants
// ============================================================

/// Number of EQ bands
pub const EQ_BANDS: usize = 5;

/// Maximum gain in dB
pub const MAX_GAIN_DB: i8 = 12;

/// Minimum gain in dB
pub const MIN_GAIN_DB: i8 = -12;

/// Default sample rate (44100 Hz)
/// Note: EQ bands can be configured for different sample rates via setSampleRate()
pub const DEFAULT_SAMPLE_RATE: u32 = 44100;

/// Stereo sample pair used throughout DSP processing
pub const StereoSample = struct {
    left: i16,
    right: i16,
};

// ============================================================
// Equalizer Band
// ============================================================

pub const EqBand = struct {
    /// Center frequency in Hz
    frequency: u16,
    /// Gain in dB (-12 to +12)
    gain_db: i8,
    /// Q factor (bandwidth) - Q16.16 fixed point
    q: i32,
    /// Sample rate for coefficient calculation (default 44100)
    sample_rate: u32 = DEFAULT_SAMPLE_RATE,
    /// Filter coefficients (biquad)
    a0: i32,
    a1: i32,
    a2: i32,
    b1: i32,
    b2: i32,
    /// Filter state for left channel
    x1_l: i32 = 0,
    x2_l: i32 = 0,
    y1_l: i32 = 0,
    y2_l: i32 = 0,
    /// Filter state for right channel
    x1_r: i32 = 0,
    x2_r: i32 = 0,
    y1_r: i32 = 0,
    y2_r: i32 = 0,

    /// Initialize band with default coefficients at default sample rate
    pub fn init(frequency: u16, gain_db: i8, q: i32) EqBand {
        return initWithSampleRate(frequency, gain_db, q, DEFAULT_SAMPLE_RATE);
    }

    /// Initialize band with coefficients calculated for a specific sample rate
    pub fn initWithSampleRate(frequency: u16, gain_db: i8, q: i32, sample_rate: u32) EqBand {
        var band = EqBand{
            .frequency = frequency,
            .gain_db = gain_db,
            .q = q,
            .sample_rate = sample_rate,
            .a0 = 0x10000, // 1.0 in Q16.16
            .a1 = 0,
            .a2 = 0,
            .b1 = 0,
            .b2 = 0,
        };
        band.updateCoefficients();
        return band;
    }

    /// Set sample rate and recalculate coefficients
    /// Call this when switching between tracks with different sample rates
    pub fn setSampleRate(self: *EqBand, sample_rate: u32) void {
        if (self.sample_rate != sample_rate) {
            self.sample_rate = sample_rate;
            self.updateCoefficients();
        }
    }

    /// Update filter coefficients based on frequency, gain, Q, and sample rate
    pub fn updateCoefficients(self: *EqBand) void {
        // Calculate angular frequency: w0 = 2 * pi * f / fs
        // Using fixed point approximation
        const pi_fp: i64 = 205887; // pi in Q16.16
        const freq_fp: i64 = @as(i64, self.frequency) << 16;
        const sample_rate_fp: i64 = @as(i64, self.sample_rate) << 16;

        // w0 = 2 * pi * f / fs (result in Q16.16)
        const w0: i64 = @divTrunc(2 * pi_fp * freq_fp, sample_rate_fp);

        // Convert gain from dB to linear using approximation
        // 10^(gain/20) ≈ 2^(gain * 0.166)
        const gain_linear = dbToLinear(self.gain_db);

        // Calculate alpha = sin(w0) / (2 * Q)
        const sin_w0 = sinApprox(@intCast(w0));
        const alpha: i64 = @divTrunc(@as(i64, sin_w0) << 16, 2 * self.q);

        // Peaking EQ coefficients
        // b0 = 1 + alpha * A
        // b1 = -2 * cos(w0)
        // b2 = 1 - alpha * A
        // a0 = 1 + alpha / A
        // a1 = -2 * cos(w0)
        // a2 = 1 - alpha / A

        const cos_w0 = cosApprox(@intCast(w0));
        const one: i64 = 0x10000;

        const alpha_a = @divTrunc(alpha * gain_linear, 0x10000);
        const alpha_div_a = @divTrunc(alpha << 16, gain_linear);

        const b0 = one + alpha_a;
        const b1 = -2 * @as(i64, cos_w0);
        const b2 = one - alpha_a;
        const a0_calc = one + alpha_div_a;
        const a1_calc = -2 * @as(i64, cos_w0);
        const a2_calc = one - alpha_div_a;

        // Normalize coefficients by a0
        if (a0_calc != 0) {
            self.a0 = @intCast(@divTrunc(b0 << 16, a0_calc));
            self.a1 = @intCast(@divTrunc(b1 << 16, a0_calc));
            self.a2 = @intCast(@divTrunc(b2 << 16, a0_calc));
            self.b1 = @intCast(@divTrunc(a1_calc << 16, a0_calc));
            self.b2 = @intCast(@divTrunc(a2_calc << 16, a0_calc));
        }
    }

    /// Process a single stereo sample through the filter
    pub fn process(self: *EqBand, left: i16, right: i16) StereoSample {
        // Left channel
        const x_l: i32 = left;
        var y_l: i64 = @as(i64, self.a0) * x_l;
        y_l += @as(i64, self.a1) * self.x1_l;
        y_l += @as(i64, self.a2) * self.x2_l;
        y_l -= @as(i64, self.b1) * self.y1_l;
        y_l -= @as(i64, self.b2) * self.y2_l;
        y_l >>= 16; // Scale back from Q16.16

        self.x2_l = self.x1_l;
        self.x1_l = x_l;
        self.y2_l = self.y1_l;
        self.y1_l = @intCast(std.math.clamp(y_l, -32768, 32767));

        // Right channel
        const x_r: i32 = right;
        var y_r: i64 = @as(i64, self.a0) * x_r;
        y_r += @as(i64, self.a1) * self.x1_r;
        y_r += @as(i64, self.a2) * self.x2_r;
        y_r -= @as(i64, self.b1) * self.y1_r;
        y_r -= @as(i64, self.b2) * self.y2_r;
        y_r >>= 16;

        self.x2_r = self.x1_r;
        self.x1_r = x_r;
        self.y2_r = self.y1_r;
        self.y1_r = @intCast(std.math.clamp(y_r, -32768, 32767));

        return .{
            .left = @intCast(self.y1_l),
            .right = @intCast(self.y1_r),
        };
    }

    /// Reset filter state
    pub fn reset(self: *EqBand) void {
        self.x1_l = 0;
        self.x2_l = 0;
        self.y1_l = 0;
        self.y2_l = 0;
        self.x1_r = 0;
        self.x2_r = 0;
        self.y1_r = 0;
        self.y2_r = 0;
    }
};

// ============================================================
// 5-Band Equalizer
// ============================================================

pub const Equalizer = struct {
    bands: [EQ_BANDS]EqBand,
    enabled: bool,
    preamp_db: i8,
    preamp_linear: i32, // Q16.16

    /// Standard 5-band EQ frequencies
    pub const STANDARD_FREQUENCIES = [EQ_BANDS]u16{ 60, 230, 910, 4000, 14000 };

    /// Initialize equalizer with flat response
    pub fn init() Equalizer {
        var eq = Equalizer{
            .bands = undefined,
            .enabled = true,
            .preamp_db = 0,
            .preamp_linear = 0x10000, // 1.0
        };

        // Initialize bands at standard frequencies with 0dB gain
        for (0..EQ_BANDS) |i| {
            eq.bands[i] = EqBand.init(
                STANDARD_FREQUENCIES[i],
                0,
                0x10000, // Q = 1.0 in Q16.16
            );
        }

        return eq;
    }

    /// Set gain for a specific band
    pub fn setBandGain(self: *Equalizer, band: usize, gain_db: i8) void {
        if (band < EQ_BANDS) {
            self.bands[band].gain_db = std.math.clamp(gain_db, MIN_GAIN_DB, MAX_GAIN_DB);
            self.bands[band].updateCoefficients();
        }
    }

    /// Get gain for a specific band
    pub fn getBandGain(self: *const Equalizer, band: usize) i8 {
        if (band < EQ_BANDS) {
            return self.bands[band].gain_db;
        }
        return 0;
    }

    /// Set sample rate for all bands and recalculate coefficients
    /// Call this when switching to a track with a different sample rate
    /// to ensure EQ center frequencies remain correct
    pub fn setSampleRate(self: *Equalizer, sample_rate: u32) void {
        for (&self.bands) |*band| {
            band.setSampleRate(sample_rate);
        }
    }

    /// Get current sample rate (from first band)
    pub fn getSampleRate(self: *const Equalizer) u32 {
        return self.bands[0].sample_rate;
    }

    /// Set preamp gain
    pub fn setPreamp(self: *Equalizer, db: i8) void {
        self.preamp_db = std.math.clamp(db, MIN_GAIN_DB, MAX_GAIN_DB);
        self.preamp_linear = dbToLinear(self.preamp_db);
    }

    /// Set all bands from an array
    pub fn setAllBands(self: *Equalizer, gains: [EQ_BANDS]i8) void {
        for (0..EQ_BANDS) |i| {
            self.setBandGain(i, gains[i]);
        }
    }

    /// Reset to flat response
    pub fn reset(self: *Equalizer) void {
        for (0..EQ_BANDS) |i| {
            self.bands[i].gain_db = 0;
            self.bands[i].updateCoefficients();
            self.bands[i].reset();
        }
        self.preamp_db = 0;
        self.preamp_linear = 0x10000;
    }

    /// Process a stereo sample pair
    pub fn process(self: *Equalizer, left: i16, right: i16) StereoSample {
        if (!self.enabled) {
            return .{ .left = left, .right = right };
        }

        // Apply preamp
        var l: i32 = @divTrunc(@as(i32, left) * self.preamp_linear, 0x10000);
        var r: i32 = @divTrunc(@as(i32, right) * self.preamp_linear, 0x10000);

        // Clamp after preamp
        l = std.math.clamp(l, -32768, 32767);
        r = std.math.clamp(r, -32768, 32767);

        // Process through each band
        var current_left: i16 = @intCast(l);
        var current_right: i16 = @intCast(r);

        for (&self.bands) |*band| {
            if (band.gain_db != 0) {
                const result = band.process(current_left, current_right);
                current_left = result.left;
                current_right = result.right;
            }
        }

        return .{ .left = current_left, .right = current_right };
    }

    /// Process a buffer of stereo samples
    pub fn processBuffer(self: *Equalizer, samples: []i16) void {
        if (!self.enabled) return;

        var i: usize = 0;
        while (i + 1 < samples.len) : (i += 2) {
            const result = self.process(samples[i], samples[i + 1]);
            samples[i] = result.left;
            samples[i + 1] = result.right;
        }
    }
};

// ============================================================
// EQ Presets
// ============================================================

pub const EqPreset = struct {
    name: []const u8,
    gains: [EQ_BANDS]i8,
    preamp: i8,
};

pub const PRESETS = [_]EqPreset{
    .{ .name = "Flat", .gains = .{ 0, 0, 0, 0, 0 }, .preamp = 0 },
    .{ .name = "Rock", .gains = .{ 4, 2, -2, 2, 4 }, .preamp = 0 },
    .{ .name = "Pop", .gains = .{ -2, 2, 4, 2, -2 }, .preamp = 0 },
    .{ .name = "Jazz", .gains = .{ 2, 0, 2, 2, 4 }, .preamp = 0 },
    .{ .name = "Classical", .gains = .{ 0, 0, 0, 2, 4 }, .preamp = 0 },
    .{ .name = "Electronic", .gains = .{ 4, 2, 0, 2, 4 }, .preamp = 0 },
    .{ .name = "Bass Boost", .gains = .{ 6, 4, 0, 0, 0 }, .preamp = -2 },
    .{ .name = "Treble Boost", .gains = .{ 0, 0, 0, 4, 6 }, .preamp = -2 },
    .{ .name = "Vocal", .gains = .{ -2, 0, 4, 2, 0 }, .preamp = 0 },
};

// ============================================================
// Stereo Widening
// ============================================================

pub const StereoWidener = struct {
    /// Width factor: 0 = mono, 0x10000 = normal, 0x20000 = extra wide
    width: i32,
    enabled: bool,

    pub fn init() StereoWidener {
        return StereoWidener{
            .width = 0x10000, // Normal stereo
            .enabled = false,
        };
    }

    /// Set stereo width (0-200%, where 100% is normal)
    pub fn setWidth(self: *StereoWidener, percent: u8) void {
        self.width = @divTrunc(@as(i32, percent) << 16, 100);
    }

    /// Process a stereo sample pair
    pub fn process(self: *const StereoWidener, left: i16, right: i16) StereoSample {
        if (!self.enabled or self.width == 0x10000) {
            return .{ .left = left, .right = right };
        }

        // Calculate mid (mono) and side (stereo difference)
        const mid: i32 = (@as(i32, left) + @as(i32, right)) >> 1;
        const side: i32 = (@as(i32, left) - @as(i32, right)) >> 1;

        // Apply width to side signal
        const wide_side: i32 = @divTrunc(side * self.width, 0x10000);

        // Reconstruct stereo
        const new_left = std.math.clamp(mid + wide_side, -32768, 32767);
        const new_right = std.math.clamp(mid - wide_side, -32768, 32767);

        return .{
            .left = @intCast(new_left),
            .right = @intCast(new_right),
        };
    }
};

// ============================================================
// Bass Boost
// ============================================================

pub const BassBoost = struct {
    /// Boost amount in dB
    boost_db: i8,
    /// Cutoff frequency
    cutoff_hz: u16,
    /// Sample rate for coefficient calculation
    sample_rate: u32 = DEFAULT_SAMPLE_RATE,
    /// Low-pass filter state
    lp_state_l: i32,
    lp_state_r: i32,
    /// Filter coefficient
    alpha: i32,
    enabled: bool,

    pub fn init() BassBoost {
        var bb = BassBoost{
            .boost_db = 0,
            .cutoff_hz = 120,
            .sample_rate = DEFAULT_SAMPLE_RATE,
            .lp_state_l = 0,
            .lp_state_r = 0,
            .alpha = 0,
            .enabled = false,
        };
        bb.updateCoefficient();
        return bb;
    }

    /// Set boost amount
    pub fn setBoost(self: *BassBoost, db: i8) void {
        self.boost_db = std.math.clamp(db, 0, 12);
    }

    /// Set cutoff frequency
    pub fn setCutoff(self: *BassBoost, hz: u16) void {
        self.cutoff_hz = std.math.clamp(hz, 40, 200);
        self.updateCoefficient();
    }

    /// Set sample rate and recalculate coefficient
    pub fn setSampleRate(self: *BassBoost, sample_rate: u32) void {
        if (self.sample_rate != sample_rate) {
            self.sample_rate = sample_rate;
            self.updateCoefficient();
        }
    }

    fn updateCoefficient(self: *BassBoost) void {
        // Simple RC low-pass: alpha = dt / (RC + dt)
        // where RC = 1 / (2 * pi * cutoff)
        // Simplified using configurable sample rate
        const cutoff_fp: i64 = @as(i64, self.cutoff_hz) << 16;
        self.alpha = @intCast(@divTrunc(cutoff_fp * 6, self.sample_rate));
    }

    pub fn process(self: *BassBoost, left: i16, right: i16) StereoSample {
        if (!self.enabled or self.boost_db == 0) {
            return .{ .left = left, .right = right };
        }

        // Simple low-pass filter to extract bass
        self.lp_state_l += @divTrunc((@as(i32, left) - self.lp_state_l) * self.alpha, 0x10000);
        self.lp_state_r += @divTrunc((@as(i32, right) - self.lp_state_r) * self.alpha, 0x10000);

        // Apply boost to bass and add back
        const boost = dbToLinear(self.boost_db);
        const bass_l = @divTrunc(self.lp_state_l * (boost - 0x10000), 0x10000);
        const bass_r = @divTrunc(self.lp_state_r * (boost - 0x10000), 0x10000);

        const new_left = std.math.clamp(@as(i32, left) + bass_l, -32768, 32767);
        const new_right = std.math.clamp(@as(i32, right) + bass_r, -32768, 32767);

        return .{
            .left = @intCast(new_left),
            .right = @intCast(new_right),
        };
    }
};

// ============================================================
// Dithering for Bit-Depth Reduction
// ============================================================

/// TPDF (Triangular Probability Density Function) Dithering
/// Used when reducing bit-depth (e.g., 24-bit to 16-bit) to minimize
/// quantization noise and avoid correlation with the signal.
pub const Ditherer = struct {
    /// LFSR state for pseudo-random noise generation
    lfsr_state: u32,
    /// Previous random value for TPDF calculation
    prev_rand: i32,
    /// Whether dithering is enabled
    enabled: bool,
    /// Noise shaping feedback (for optional noise shaping)
    error_l: i32,
    error_r: i32,

    pub fn init() Ditherer {
        return Ditherer{
            .lfsr_state = 0x12345678, // Initial seed
            .prev_rand = 0,
            .enabled = true,
            .error_l = 0,
            .error_r = 0,
        };
    }

    /// Generate pseudo-random noise using LFSR
    fn nextRandom(self: *Ditherer) i32 {
        // Galois LFSR with taps at 32, 22, 2, 1 (maximal period)
        const bit = self.lfsr_state & 1;
        self.lfsr_state >>= 1;
        if (bit == 1) {
            self.lfsr_state ^= 0xD0000001;
        }
        // Convert to signed and scale to +/- 1 LSB range
        return @as(i32, @bitCast(self.lfsr_state)) >> 16;
    }

    /// Apply TPDF dithering to convert 32-bit sample to 16-bit
    /// TPDF uses two random values subtracted to create triangular distribution
    pub fn ditherToI16(self: *Ditherer, sample: i32) i16 {
        if (!self.enabled) {
            // Simple truncation
            return @intCast(std.math.clamp(sample >> 16, -32768, 32767));
        }

        // Generate TPDF noise (triangular distribution)
        const rand1 = self.nextRandom();
        const rand2 = self.prev_rand;
        self.prev_rand = rand1;

        // TPDF = rand1 - rand2 (creates triangular distribution)
        const dither_noise = rand1 - rand2;

        // Add dither noise scaled to LSB of output (for 32->16 bit, scale by 2^15)
        // Since we're going from 32-bit to 16-bit, we need 16-bit of dither
        const dithered = sample + (dither_noise >> 1);

        // Round and truncate
        const rounded = (dithered + 0x8000) >> 16;

        return @intCast(std.math.clamp(rounded, -32768, 32767));
    }

    /// Apply TPDF dithering with noise shaping for 24-bit to 16-bit
    /// Noise shaping moves quantization noise to less audible frequencies
    pub fn ditherWithNoiseShaping(self: *Ditherer, sample: i32, ch: u1) i16 {
        if (!self.enabled) {
            return @intCast(std.math.clamp(sample >> 8, -32768, 32767));
        }

        // Add feedback error from previous sample (first-order noise shaping)
        const error_ptr = if (ch == 0) &self.error_l else &self.error_r;
        const shaped = sample - error_ptr.*;

        // Generate TPDF dither
        const rand1 = self.nextRandom();
        const rand2 = self.prev_rand;
        self.prev_rand = rand1;
        const dither = (rand1 - rand2) >> 8; // Scale for 24->16 bit

        // Add dither and round
        const dithered = shaped + dither;
        const output = (dithered + 128) >> 8;
        const clamped = std.math.clamp(output, -32768, 32767);

        // Calculate and store error for next sample
        error_ptr.* = (clamped << 8) - sample;

        return @intCast(clamped);
    }

    /// Process stereo pair with dithering (assumes 32-bit input, 16-bit output)
    pub fn process32to16(self: *Ditherer, left: i32, right: i32) StereoSample {
        return .{
            .left = self.ditherToI16(left),
            .right = self.ditherToI16(right),
        };
    }

    /// Process stereo pair from 24-bit to 16-bit with noise shaping
    pub fn process24to16(self: *Ditherer, left: i32, right: i32) StereoSample {
        return .{
            .left = self.ditherWithNoiseShaping(left, 0),
            .right = self.ditherWithNoiseShaping(right, 1),
        };
    }

    /// Reset ditherer state
    pub fn reset(self: *Ditherer) void {
        self.error_l = 0;
        self.error_r = 0;
        self.prev_rand = 0;
    }
};

// ============================================================
// Sample Rate Converter
// ============================================================

/// Linear interpolation resampler for sample rate conversion
/// Supports conversion between any pair of common sample rates
/// Uses fixed-point math for ARM7TDMI efficiency
pub const Resampler = struct {
    /// Source sample rate
    input_rate: u32,
    /// Target sample rate
    output_rate: u32,
    /// Phase accumulator (Q16.16 fixed-point)
    phase: u32,
    /// Phase increment per output sample
    phase_inc: u32,
    /// Previous sample for interpolation (left)
    prev_l: i16,
    /// Previous sample for interpolation (right)
    prev_r: i16,
    /// Current sample for interpolation (left)
    curr_l: i16,
    /// Current sample for interpolation (right)
    curr_r: i16,
    /// Whether resampling is needed (rates differ)
    enabled: bool,

    /// Common sample rates
    pub const RATE_8000: u32 = 8000;
    pub const RATE_11025: u32 = 11025;
    pub const RATE_16000: u32 = 16000;
    pub const RATE_22050: u32 = 22050;
    pub const RATE_32000: u32 = 32000;
    pub const RATE_44100: u32 = 44100;
    pub const RATE_48000: u32 = 48000;
    pub const RATE_96000: u32 = 96000;

    pub fn init() Resampler {
        return Resampler{
            .input_rate = RATE_44100,
            .output_rate = RATE_44100,
            .phase = 0,
            .phase_inc = 0x10000, // 1.0 in Q16.16
            .prev_l = 0,
            .prev_r = 0,
            .curr_l = 0,
            .curr_r = 0,
            .enabled = false,
        };
    }

    /// Configure resampler for specific input/output rates
    pub fn configure(self: *Resampler, input_rate: u32, output_rate: u32) void {
        self.input_rate = input_rate;
        self.output_rate = output_rate;

        if (input_rate == output_rate) {
            self.enabled = false;
            self.phase_inc = 0x10000;
        } else {
            self.enabled = true;
            // phase_inc = input_rate / output_rate in Q16.16
            // For accuracy: (input_rate << 16) / output_rate
            self.phase_inc = @truncate((@as(u64, input_rate) << 16) / output_rate);
        }

        self.reset();
    }

    /// Reset resampler state
    pub fn reset(self: *Resampler) void {
        self.phase = 0;
        self.prev_l = 0;
        self.prev_r = 0;
        self.curr_l = 0;
        self.curr_r = 0;
    }

    /// Push a new input sample pair
    pub fn pushSample(self: *Resampler, left: i16, right: i16) void {
        self.prev_l = self.curr_l;
        self.prev_r = self.curr_r;
        self.curr_l = left;
        self.curr_r = right;
    }

    /// Generate next output sample using linear interpolation
    /// Returns null if no output sample is ready (need more input)
    pub fn pullSample(self: *Resampler) ?StereoSample {
        if (!self.enabled) {
            return .{ .left = self.curr_l, .right = self.curr_r };
        }

        // Check if we've passed the current input sample
        if (self.phase >= 0x10000) {
            return null; // Need more input samples
        }

        // Linear interpolation: output = prev + (curr - prev) * phase
        const frac: i32 = @intCast(self.phase & 0xFFFF);
        const inv_frac: i32 = 0x10000 - frac;

        const left = @as(i32, self.prev_l) * inv_frac + @as(i32, self.curr_l) * frac;
        const right = @as(i32, self.prev_r) * inv_frac + @as(i32, self.curr_r) * frac;

        // Advance phase
        self.phase += self.phase_inc;

        return .{
            .left = @intCast(left >> 16),
            .right = @intCast(right >> 16),
        };
    }

    /// Advance phase and check if we need next input sample
    pub fn needsInput(self: *const Resampler) bool {
        return self.phase >= 0x10000;
    }

    /// Consume input sample (call after pushSample when phase indicates)
    pub fn consumeInput(self: *Resampler) void {
        if (self.phase >= 0x10000) {
            self.phase -= 0x10000;
        }
    }

    /// Resample a buffer of stereo samples
    /// Input buffer is in format [L0, R0, L1, R1, ...]
    /// Returns number of output samples written
    pub fn resampleBuffer(
        self: *Resampler,
        input: []const i16,
        output: []i16,
    ) usize {
        if (!self.enabled) {
            // No resampling needed, just copy
            const to_copy = @min(input.len, output.len);
            @memcpy(output[0..to_copy], input[0..to_copy]);
            return to_copy / 2; // Return stereo samples
        }

        var in_idx: usize = 0;
        var out_idx: usize = 0;

        while (out_idx + 1 < output.len) {
            // Generate output samples while phase < 1.0
            while (self.phase < 0x10000 and out_idx + 1 < output.len) {
                const frac: i32 = @intCast(self.phase & 0xFFFF);
                const inv_frac: i32 = 0x10000 - frac;

                const left = @as(i32, self.prev_l) * inv_frac + @as(i32, self.curr_l) * frac;
                const right = @as(i32, self.prev_r) * inv_frac + @as(i32, self.curr_r) * frac;

                output[out_idx] = @intCast(left >> 16);
                output[out_idx + 1] = @intCast(right >> 16);
                out_idx += 2;

                self.phase += self.phase_inc;
            }

            // Need next input sample
            if (self.phase >= 0x10000) {
                self.phase -= 0x10000;

                if (in_idx + 1 < input.len) {
                    self.prev_l = self.curr_l;
                    self.prev_r = self.curr_r;
                    self.curr_l = input[in_idx];
                    self.curr_r = input[in_idx + 1];
                    in_idx += 2;
                } else {
                    break; // No more input
                }
            }
        }

        return out_idx / 2;
    }

    /// Get ratio for buffer size calculation
    /// Returns the ratio as Q16.16 fixed-point
    pub fn getRatio(self: *const Resampler) u32 {
        if (!self.enabled) return 0x10000;
        return @truncate((@as(u64, self.output_rate) << 16) / self.input_rate);
    }

    /// Calculate required output buffer size for given input size
    pub fn calcOutputSize(self: *const Resampler, input_samples: usize) usize {
        if (!self.enabled) return input_samples;
        const ratio = self.getRatio();
        return @intCast((@as(u64, input_samples) * ratio + 0xFFFF) >> 16);
    }

    /// Calculate required input buffer size for given output size
    pub fn calcInputSize(self: *const Resampler, output_samples: usize) usize {
        if (!self.enabled) return output_samples;
        return @intCast((@as(u64, output_samples) * self.phase_inc + 0xFFFF) >> 16);
    }
};

// ============================================================
// Volume Ramping
// ============================================================

/// Volume control with smooth ramping to avoid audible clicks
/// Uses exponential ramping for natural-sounding transitions
pub const VolumeRamper = struct {
    /// Target volume (0x0000 = silence, 0x10000 = unity, max 0x20000 = +6dB)
    target_volume: i32,
    /// Current volume (ramping towards target)
    current_volume: i32,
    /// Ramp rate per sample (higher = faster transition)
    ramp_rate: i32,
    /// Sample rate for time-based calculations
    sample_rate: u32 = DEFAULT_SAMPLE_RATE,
    /// Whether ramping is enabled
    enabled: bool,

    /// Default ramp time in samples (~10ms at 44.1kHz = 441 samples)
    pub const DEFAULT_RAMP_SAMPLES: i32 = 441;

    pub fn init() VolumeRamper {
        return VolumeRamper{
            .target_volume = 0x10000, // Unity gain
            .current_volume = 0x10000,
            .ramp_rate = 0x10000 / DEFAULT_RAMP_SAMPLES,
            .sample_rate = DEFAULT_SAMPLE_RATE,
            .enabled = true,
        };
    }

    /// Set target volume (0-100%, can exceed 100% for gain)
    pub fn setVolume(self: *VolumeRamper, percent: u8) void {
        // Map 0-100 to 0x0000-0x10000
        self.target_volume = @divTrunc(@as(i32, percent) << 16, 100);
    }

    /// Set volume in fixed-point directly (for precise control)
    pub fn setVolumeFixed(self: *VolumeRamper, volume_fp: i32) void {
        self.target_volume = std.math.clamp(volume_fp, 0, 0x20000);
    }

    /// Set sample rate for time-based calculations
    pub fn setSampleRate(self: *VolumeRamper, sample_rate: u32) void {
        self.sample_rate = sample_rate;
    }

    /// Set ramp time in milliseconds
    pub fn setRampTimeMs(self: *VolumeRamper, ms: u16) void {
        const samples = @divTrunc(@as(i32, ms) * @as(i32, @intCast(self.sample_rate)), 1000);
        if (samples > 0) {
            self.ramp_rate = @divTrunc(0x10000, samples);
        }
    }

    /// Immediately jump to target (no ramping)
    pub fn jumpToTarget(self: *VolumeRamper) void {
        self.current_volume = self.target_volume;
    }

    /// Check if currently ramping
    pub fn isRamping(self: *const VolumeRamper) bool {
        return self.current_volume != self.target_volume;
    }

    /// Get current volume as percentage
    pub fn getVolumePercent(self: *const VolumeRamper) u8 {
        return @intCast(@divTrunc(self.current_volume * 100, 0x10000));
    }

    /// Process a stereo sample with volume ramping
    pub fn process(self: *VolumeRamper, left: i16, right: i16) StereoSample {
        if (!self.enabled) {
            return .{ .left = left, .right = right };
        }

        // Ramp current volume towards target
        if (self.current_volume < self.target_volume) {
            self.current_volume += self.ramp_rate;
            if (self.current_volume > self.target_volume) {
                self.current_volume = self.target_volume;
            }
        } else if (self.current_volume > self.target_volume) {
            self.current_volume -= self.ramp_rate;
            if (self.current_volume < self.target_volume) {
                self.current_volume = self.target_volume;
            }
        }

        // Apply volume
        const l: i32 = @divTrunc(@as(i32, left) * self.current_volume, 0x10000);
        const r: i32 = @divTrunc(@as(i32, right) * self.current_volume, 0x10000);

        return .{
            .left = @intCast(std.math.clamp(l, -32768, 32767)),
            .right = @intCast(std.math.clamp(r, -32768, 32767)),
        };
    }

    /// Process a buffer of stereo samples
    pub fn processBuffer(self: *VolumeRamper, samples: []i16) void {
        var i: usize = 0;
        while (i + 1 < samples.len) : (i += 2) {
            const result = self.process(samples[i], samples[i + 1]);
            samples[i] = result.left;
            samples[i + 1] = result.right;
        }
    }

    /// Mute with ramping (fade out)
    pub fn mute(self: *VolumeRamper) void {
        self.target_volume = 0;
    }

    /// Unmute with ramping (fade in to previous level)
    pub fn unmute(self: *VolumeRamper, percent: u8) void {
        self.setVolume(percent);
    }
};

// ============================================================
// Complete DSP Chain
// ============================================================

pub const DspChain = struct {
    equalizer: Equalizer,
    stereo_widener: StereoWidener,
    bass_boost: BassBoost,
    volume: VolumeRamper,
    enabled: bool,

    pub fn init() DspChain {
        return DspChain{
            .equalizer = Equalizer.init(),
            .stereo_widener = StereoWidener.init(),
            .bass_boost = BassBoost.init(),
            .volume = VolumeRamper.init(),
            .enabled = true,
        };
    }

    /// Set volume with smooth ramping (0-100%)
    pub fn setVolume(self: *DspChain, percent: u8) void {
        self.volume.setVolume(percent);
    }

    /// Get current volume percentage
    pub fn getVolume(self: *const DspChain) u8 {
        return self.volume.getVolumePercent();
    }

    /// Check if volume is currently ramping
    pub fn isVolumeRamping(self: *const DspChain) bool {
        return self.volume.isRamping();
    }

    /// Process a stereo sample through the entire DSP chain
    pub fn process(self: *DspChain, left: i16, right: i16) StereoSample {
        if (!self.enabled) {
            return .{ .left = left, .right = right };
        }

        // Order: Volume -> Bass Boost -> Equalizer -> Stereo Widener
        // Volume first to avoid clipping in subsequent stages
        var result = self.volume.process(left, right);
        result = self.bass_boost.process(result.left, result.right);
        result = self.equalizer.process(result.left, result.right);
        result = self.stereo_widener.process(result.left, result.right);

        return result;
    }

    /// Process a buffer of stereo samples
    pub fn processBuffer(self: *DspChain, samples: []i16) void {
        if (!self.enabled) return;

        var i: usize = 0;
        while (i + 1 < samples.len) : (i += 2) {
            const result = self.process(samples[i], samples[i + 1]);
            samples[i] = result.left;
            samples[i + 1] = result.right;
        }
    }

    /// Apply an EQ preset
    pub fn applyPreset(self: *DspChain, preset_index: usize) void {
        if (preset_index < PRESETS.len) {
            const preset = PRESETS[preset_index];
            self.equalizer.setAllBands(preset.gains);
            self.equalizer.setPreamp(preset.preamp);
        }
    }

    /// Mute audio with smooth fade out
    pub fn mute(self: *DspChain) void {
        self.volume.mute();
    }

    /// Unmute audio with smooth fade in
    pub fn unmute(self: *DspChain, percent: u8) void {
        self.volume.unmute(percent);
    }

    /// Set sample rate for all sample-rate-dependent components
    /// Call this when loading a track with a different sample rate
    /// to ensure EQ, filters, and timing operate correctly
    pub fn setSampleRate(self: *DspChain, sample_rate: u32) void {
        self.equalizer.setSampleRate(sample_rate);
        self.bass_boost.setSampleRate(sample_rate);
        self.volume.setSampleRate(sample_rate);
        // Stereo widener is sample-rate-independent
        // (operates on sample relationships, not absolute frequencies)
    }

    /// Get current sample rate from EQ
    pub fn getSampleRate(self: *const DspChain) u32 {
        return self.equalizer.getSampleRate();
    }
};

// ============================================================
// Math Utilities (Fixed Point)
// ============================================================

/// Convert dB to linear (Q16.16 fixed point)
/// Uses approximation: 10^(x/20) ≈ 2^(x * 0.166)
fn dbToLinear(db: i8) i32 {
    if (db == 0) return 0x10000; // 1.0

    // Lookup table for common values (Q16.16 fixed point, 0x10000 = 1.0)
    // Formula: round(10^(dB/20) * 65536)
    const db_table = [_]i32{
        0x4027,  // -12 dB = 0.251
        0x47FB,  // -11 dB = 0.282
        0x50C3,  // -10 dB = 0.316
        0x5AB0,  // -9 dB = 0.355
        0x65EA,  // -8 dB = 0.398
        0x72A5,  // -7 dB = 0.447
        0x8000,  // -6 dB = 0.501
        0x8F9E,  // -5 dB = 0.562
        0xA124,  // -4 dB = 0.631
        0xB4CE,  // -3 dB = 0.708
        0xCADD,  // -2 dB = 0.794
        0xE39E,  // -1 dB = 0.891
        0x10000, // 0 dB = 1.0
        0x11F60, // +1 dB = 1.122
        0x14249, // +2 dB = 1.259
        0x16C31, // +3 dB = 1.413
        0x19B8C, // +4 dB = 1.585
        0x1D2F7, // +5 dB = 1.778
        0x1FEDF, // +6 dB = 1.995
        0x23BC1, // +7 dB = 2.239
        0x28185, // +8 dB = 2.512
        0x2D4EF, // +9 dB = 2.818
        0x32D64, // +10 dB = 3.162
        0x39178, // +11 dB = 3.548
        0x3FFF0, // +12 dB = 3.981
    };

    const idx = @as(usize, @intCast(@as(i32, db) + 12));
    if (idx < db_table.len) {
        return db_table[idx];
    }

    // Out of range, return 1.0
    return 0x10000;
}

/// Sine approximation using Taylor series (input in Q16.16 radians)
fn sinApprox(x: i32) i32 {
    // Normalize to [-pi, pi]
    var angle = x;
    const pi: i32 = 205887; // pi in Q16.16

    while (angle > pi) angle -= 2 * pi;
    while (angle < -pi) angle += 2 * pi;

    // Taylor series: sin(x) ≈ x - x^3/6 + x^5/120
    const x2: i64 = @divTrunc(@as(i64, angle) * angle, 0x10000);
    const x3: i64 = @divTrunc(x2 * angle, 0x10000);
    const x5: i64 = @divTrunc(x3 * x2, 0x10000);

    var result: i64 = angle;
    result -= @divTrunc(x3, 6);
    result += @divTrunc(x5, 120);

    return @intCast(std.math.clamp(result, -0x10000, 0x10000));
}

/// Cosine approximation
fn cosApprox(x: i32) i32 {
    const pi_half: i32 = 102943; // pi/2 in Q16.16
    return sinApprox(x + pi_half);
}

// ============================================================
// Tests
// ============================================================

test "equalizer initialization" {
    const eq = Equalizer.init();
    try std.testing.expect(eq.enabled);
    try std.testing.expectEqual(@as(i8, 0), eq.preamp_db);

    for (0..EQ_BANDS) |i| {
        try std.testing.expectEqual(@as(i8, 0), eq.bands[i].gain_db);
    }
}

test "equalizer flat response" {
    var eq = Equalizer.init();

    // With 0dB on all bands, output should equal input
    const result = eq.process(1000, -1000);

    // Allow small tolerance due to fixed-point math
    try std.testing.expect(@abs(@as(i32, result.left) - 1000) < 10);
    try std.testing.expect(@abs(@as(i32, result.right) + 1000) < 10);
}

test "equalizer band gain" {
    var eq = Equalizer.init();

    eq.setBandGain(0, 6);
    try std.testing.expectEqual(@as(i8, 6), eq.getBandGain(0));

    eq.setBandGain(0, 20); // Should clamp to MAX_GAIN_DB
    try std.testing.expectEqual(@as(i8, 12), eq.getBandGain(0));
}

test "stereo widener mono" {
    var widener = StereoWidener.init();
    widener.enabled = true;
    widener.setWidth(0); // Mono

    const result = widener.process(100, -100);

    // Should be mono (both channels same)
    try std.testing.expectEqual(result.left, result.right);
}

test "db to linear conversion" {
    // 0 dB should be 1.0
    try std.testing.expectEqual(@as(i32, 0x10000), dbToLinear(0));

    // -6 dB should be approximately 0.5
    const minus6 = dbToLinear(-6);
    try std.testing.expect(minus6 > 0x7000 and minus6 < 0x9000);

    // +6 dB should be approximately 2.0
    const plus6 = dbToLinear(6);
    try std.testing.expect(plus6 > 0x1C000 and plus6 < 0x24000);
}

test "dsp chain" {
    var dsp = DspChain.init();
    try std.testing.expect(dsp.enabled);

    // Process silence
    const result = dsp.process(0, 0);
    try std.testing.expectEqual(@as(i16, 0), result.left);
    try std.testing.expectEqual(@as(i16, 0), result.right);
}

test "preset application" {
    var dsp = DspChain.init();

    dsp.applyPreset(1); // Rock preset
    try std.testing.expectEqual(@as(i8, 4), dsp.equalizer.getBandGain(0));
}

test "volume ramper initialization" {
    const vol = VolumeRamper.init();
    try std.testing.expectEqual(@as(i32, 0x10000), vol.target_volume);
    try std.testing.expectEqual(@as(i32, 0x10000), vol.current_volume);
    try std.testing.expect(vol.enabled);
}

test "volume ramper set volume" {
    var vol = VolumeRamper.init();

    vol.setVolume(50);
    try std.testing.expectEqual(@as(i32, 0x8000), vol.target_volume);

    vol.setVolume(100);
    try std.testing.expectEqual(@as(i32, 0x10000), vol.target_volume);
}

test "volume ramper ramping" {
    var vol = VolumeRamper.init();
    vol.jumpToTarget(); // Ensure current == target

    // Set lower volume
    vol.setVolume(0);
    try std.testing.expect(vol.isRamping());

    // Process samples - should ramp down
    for (0..1000) |_| {
        _ = vol.process(1000, 1000);
    }

    // Should have ramped down significantly
    try std.testing.expect(vol.current_volume < 0x10000);
}

test "volume ramper mute" {
    var vol = VolumeRamper.init();
    vol.mute();

    try std.testing.expectEqual(@as(i32, 0), vol.target_volume);
}

test "ditherer initialization" {
    const dither = Ditherer.init();
    try std.testing.expect(dither.enabled);
    try std.testing.expect(dither.lfsr_state != 0);
}

test "ditherer generates varied output" {
    var dither = Ditherer.init();

    // Same input should produce slightly varied output due to dithering
    const out1 = dither.ditherToI16(0x7FFF0000);
    const out2 = dither.ditherToI16(0x7FFF0000);

    // Values should be close but potentially different due to dither noise
    try std.testing.expect(@abs(@as(i32, out1) - @as(i32, out2)) < 10);
}

test "ditherer disabled pass-through" {
    var dither = Ditherer.init();
    dither.enabled = false;

    // With dithering disabled, should just truncate
    const out = dither.ditherToI16(0x40000000);
    try std.testing.expectEqual(@as(i16, 0x4000), out);
}

test "resampler initialization" {
    const resampler = Resampler.init();
    try std.testing.expectEqual(@as(u32, 44100), resampler.input_rate);
    try std.testing.expectEqual(@as(u32, 44100), resampler.output_rate);
    try std.testing.expect(!resampler.enabled);
}

test "resampler same rate passthrough" {
    var resampler = Resampler.init();
    resampler.configure(44100, 44100);

    try std.testing.expect(!resampler.enabled);
    try std.testing.expectEqual(@as(u32, 0x10000), resampler.phase_inc);
}

test "resampler 48k to 44.1k" {
    var resampler = Resampler.init();
    resampler.configure(48000, 44100);

    try std.testing.expect(resampler.enabled);
    // phase_inc = 48000/44100 ≈ 1.088 in Q16.16 = ~71330
    try std.testing.expect(resampler.phase_inc > 0x10000);
    try std.testing.expect(resampler.phase_inc < 0x12000);
}

test "resampler 22050 to 44100" {
    var resampler = Resampler.init();
    resampler.configure(22050, 44100);

    try std.testing.expect(resampler.enabled);
    // phase_inc = 22050/44100 = 0.5 in Q16.16 = 0x8000
    try std.testing.expectEqual(@as(u32, 0x8000), resampler.phase_inc);
}

test "resampler buffer upsampling" {
    var resampler = Resampler.init();
    resampler.configure(22050, 44100); // 2x upsampling

    // Input: 2 stereo samples
    const input = [_]i16{ 1000, 2000, 3000, 4000 };
    var output: [8]i16 = undefined;

    const count = resampler.resampleBuffer(&input, &output);

    // Should produce approximately 4 stereo samples (2x input)
    try std.testing.expect(count >= 2);
    try std.testing.expect(count <= 4);
}

test "resampler calc output size" {
    var resampler = Resampler.init();
    resampler.configure(44100, 48000);

    const out_size = resampler.calcOutputSize(100);
    // 100 samples at 44100 -> ~109 samples at 48000
    try std.testing.expect(out_size >= 108);
    try std.testing.expect(out_size <= 110);
}
