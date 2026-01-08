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

/// Sample rate (assumed 44100 Hz)
pub const SAMPLE_RATE: u32 = 44100;

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

    /// Initialize band with default coefficients
    pub fn init(frequency: u16, gain_db: i8, q: i32) EqBand {
        var band = EqBand{
            .frequency = frequency,
            .gain_db = gain_db,
            .q = q,
            .a0 = 0x10000, // 1.0 in Q16.16
            .a1 = 0,
            .a2 = 0,
            .b1 = 0,
            .b2 = 0,
        };
        band.updateCoefficients();
        return band;
    }

    /// Update filter coefficients based on frequency, gain, and Q
    pub fn updateCoefficients(self: *EqBand) void {
        // Calculate angular frequency: w0 = 2 * pi * f / fs
        // Using fixed point approximation
        const pi_fp: i64 = 205887; // pi in Q16.16
        const freq_fp: i64 = @as(i64, self.frequency) << 16;
        const sample_rate_fp: i64 = @as(i64, SAMPLE_RATE) << 16;

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
    pub fn process(self: *EqBand, left: i16, right: i16) struct { left: i16, right: i16 } {
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
    pub fn process(self: *Equalizer, left: i16, right: i16) struct { left: i16, right: i16 } {
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
    pub fn process(self: *const StereoWidener, left: i16, right: i16) struct { left: i16, right: i16 } {
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

    fn updateCoefficient(self: *BassBoost) void {
        // Simple RC low-pass: alpha = dt / (RC + dt)
        // where RC = 1 / (2 * pi * cutoff)
        // Simplified for fixed sample rate
        const cutoff_fp: i64 = @as(i64, self.cutoff_hz) << 16;
        self.alpha = @intCast(@divTrunc(cutoff_fp * 6, SAMPLE_RATE));
    }

    pub fn process(self: *BassBoost, left: i16, right: i16) struct { left: i16, right: i16 } {
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
// Complete DSP Chain
// ============================================================

pub const DspChain = struct {
    equalizer: Equalizer,
    stereo_widener: StereoWidener,
    bass_boost: BassBoost,
    enabled: bool,

    pub fn init() DspChain {
        return DspChain{
            .equalizer = Equalizer.init(),
            .stereo_widener = StereoWidener.init(),
            .bass_boost = BassBoost.init(),
            .enabled = true,
        };
    }

    /// Process a stereo sample through the entire DSP chain
    pub fn process(self: *DspChain, left: i16, right: i16) struct { left: i16, right: i16 } {
        if (!self.enabled) {
            return .{ .left = left, .right = right };
        }

        // Order: Bass Boost -> Equalizer -> Stereo Widener
        var result = self.bass_boost.process(left, right);
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
};

// ============================================================
// Math Utilities (Fixed Point)
// ============================================================

/// Convert dB to linear (Q16.16 fixed point)
/// Uses approximation: 10^(x/20) ≈ 2^(x * 0.166)
fn dbToLinear(db: i8) i32 {
    if (db == 0) return 0x10000; // 1.0

    // Lookup table for common values
    const db_table = [_]i32{
        0x0411,  // -12 dB = 0.251
        0x0521,  // -11 dB = 0.282
        0x0673,  // -10 dB = 0.316
        0x0804,  // -9 dB = 0.355
        0x0A12,  // -8 dB = 0.398
        0x0CB6,  // -7 dB = 0.447
        0x1000,  // -6 dB = 0.501
        0x143D,  // -5 dB = 0.562
        0x1959,  // -4 dB = 0.631
        0x1FD9,  // -3 dB = 0.708
        0x287A,  // -2 dB = 0.794
        0x32F5,  // -1 dB = 0.891
        0x10000, // 0 dB = 1.0
        0x14A0,  // +1 dB = 1.122 (shifted to use same table)
        0x1A36,  // +2 dB = 1.259
        0x2109,  // +3 dB = 1.413
        0x2999,  // +4 dB = 1.585
        0x346D,  // +5 dB = 1.778
        0x4000,  // +6 dB = 1.995
        0x5082,  // +7 dB = 2.239
        0x65A5,  // +8 dB = 2.512
        0x7FF6,  // +9 dB = 2.818
        0xA12D,  // +10 dB = 3.162
        0xCB63,  // +11 dB = 3.548
        0x10000, // +12 dB = 3.981 (clamped for safety)
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
