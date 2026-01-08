//! Fixed-Point Math Library
//!
//! Provides fixed-point arithmetic for audio processing and other DSP operations
//! on the ARM7TDMI which lacks a floating-point unit.

const std = @import("std");

/// Q16.16 fixed-point type (16 integer bits, 16 fractional bits)
pub const Q16 = FixedPoint(i32, 16);

/// Q8.24 fixed-point type (8 integer bits, 24 fractional bits) - high precision
pub const Q24 = FixedPoint(i32, 24);

/// Q1.15 fixed-point type (1 integer bit, 15 fractional bits) - for audio samples
pub const Q15 = FixedPoint(i16, 15);

/// Q1.31 fixed-point type (1 integer bit, 31 fractional bits) - high precision audio
pub const Q31 = FixedPoint(i32, 31);

/// Generic fixed-point number type
pub fn FixedPoint(comptime T: type, comptime frac_bits: comptime_int) type {
    const info = @typeInfo(T);
    if (info != .int) {
        @compileError("FixedPoint requires an integer type");
    }

    const int_info = info.int;
    const total_bits = int_info.bits;

    if (frac_bits >= total_bits) {
        @compileError("Fractional bits must be less than total bits");
    }

    // Use larger types for intermediate calculations
    const WideT = if (int_info.signedness == .signed)
        std.meta.Int(.signed, total_bits * 2)
    else
        std.meta.Int(.unsigned, total_bits * 2);

    return struct {
        const Self = @This();

        /// The raw fixed-point value
        raw: T,

        /// Number of fractional bits
        pub const FRAC_BITS = frac_bits;
        /// Scale factor (1.0 in fixed-point)
        pub const SCALE: T = 1 << frac_bits;
        /// Maximum representable value
        pub const MAX: T = std.math.maxInt(T);
        /// Minimum representable value
        pub const MIN: T = std.math.minInt(T);

        /// Zero constant
        pub const ZERO: Self = .{ .raw = 0 };
        /// One constant
        pub const ONE: Self = .{ .raw = SCALE };
        /// Negative one constant
        pub const NEG_ONE: Self = .{ .raw = -SCALE };
        /// Half constant
        pub const HALF: Self = .{ .raw = SCALE >> 1 };

        // ============================================================
        // Construction
        // ============================================================

        /// Create from raw fixed-point value
        pub fn fromRaw(raw: T) Self {
            return Self{ .raw = raw };
        }

        /// Create from integer
        pub fn fromInt(value: anytype) Self {
            const casted: T = @intCast(value);
            return Self{ .raw = casted << frac_bits };
        }

        /// Create from floating-point (compile-time only for constants)
        pub fn fromFloat(comptime value: f64) Self {
            const scaled = value * @as(f64, @floatFromInt(SCALE));
            return Self{ .raw = @intFromFloat(scaled) };
        }

        /// Convert to integer (truncate fractional part)
        pub fn toInt(self: Self) T {
            return self.raw >> frac_bits;
        }

        /// Convert to integer (round to nearest)
        pub fn toIntRounded(self: Self) T {
            const half: T = SCALE >> 1;
            if (self.raw >= 0) {
                return (self.raw + half) >> frac_bits;
            } else {
                return (self.raw + half - 1) >> frac_bits;
            }
        }

        /// Convert to floating-point (for debugging/display)
        pub fn toFloat(self: Self) f64 {
            return @as(f64, @floatFromInt(self.raw)) / @as(f64, @floatFromInt(SCALE));
        }

        // ============================================================
        // Basic Arithmetic
        // ============================================================

        /// Addition
        pub fn add(self: Self, other: Self) Self {
            return Self{ .raw = self.raw +| other.raw }; // Saturating add
        }

        /// Subtraction
        pub fn sub(self: Self, other: Self) Self {
            return Self{ .raw = self.raw -| other.raw }; // Saturating sub
        }

        /// Negation
        pub fn neg(self: Self) Self {
            return Self{ .raw = -self.raw };
        }

        /// Absolute value
        pub fn abs(self: Self) Self {
            return Self{ .raw = if (self.raw < 0) -self.raw else self.raw };
        }

        /// Multiplication
        pub fn mul(self: Self, other: Self) Self {
            // Use wider type for intermediate calculation
            const wide_result: WideT = @as(WideT, self.raw) * @as(WideT, other.raw);
            const shifted = wide_result >> frac_bits;
            return Self{ .raw = @intCast(std.math.clamp(shifted, MIN, MAX)) };
        }

        /// Division
        pub fn div(self: Self, other: Self) Self {
            if (other.raw == 0) {
                // Return max/min on division by zero
                return if (self.raw >= 0) Self{ .raw = MAX } else Self{ .raw = MIN };
            }
            const wide_num: WideT = @as(WideT, self.raw) << frac_bits;
            const result = @divTrunc(wide_num, @as(WideT, other.raw));
            return Self{ .raw = @intCast(std.math.clamp(result, MIN, MAX)) };
        }

        /// Multiply by integer
        pub fn mulInt(self: Self, scalar: anytype) Self {
            const wide: WideT = @as(WideT, self.raw) * @as(WideT, @intCast(scalar));
            return Self{ .raw = @intCast(std.math.clamp(wide, MIN, MAX)) };
        }

        /// Divide by integer
        pub fn divInt(self: Self, scalar: anytype) Self {
            return Self{ .raw = @divTrunc(self.raw, @as(T, @intCast(scalar))) };
        }

        // ============================================================
        // Comparison
        // ============================================================

        pub fn eq(self: Self, other: Self) bool {
            return self.raw == other.raw;
        }

        pub fn lt(self: Self, other: Self) bool {
            return self.raw < other.raw;
        }

        pub fn lte(self: Self, other: Self) bool {
            return self.raw <= other.raw;
        }

        pub fn gt(self: Self, other: Self) bool {
            return self.raw > other.raw;
        }

        pub fn gte(self: Self, other: Self) bool {
            return self.raw >= other.raw;
        }

        pub fn min(self: Self, other: Self) Self {
            return if (self.raw < other.raw) self else other;
        }

        pub fn max(self: Self, other: Self) Self {
            return if (self.raw > other.raw) self else other;
        }

        pub fn clamp(self: Self, lo: Self, hi: Self) Self {
            return self.max(lo).min(hi);
        }

        // ============================================================
        // Advanced Math
        // ============================================================

        /// Square root (Newton-Raphson approximation)
        pub fn sqrt(self: Self) Self {
            if (self.raw <= 0) return ZERO;

            // Initial guess
            var guess = Self{ .raw = self.raw >> 1 };
            if (guess.raw == 0) guess = ONE;

            // Newton-Raphson iterations
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                const new_guess = guess.add(self.div(guess)).divInt(2);
                if (new_guess.raw == guess.raw) break;
                guess = new_guess;
            }

            return guess;
        }

        /// Linear interpolation: self + t * (other - self)
        pub fn lerp(self: Self, other: Self, t: Self) Self {
            return self.add(other.sub(self).mul(t));
        }

        /// Sign function: returns -1, 0, or 1
        pub fn sign(self: Self) Self {
            if (self.raw > 0) return ONE;
            if (self.raw < 0) return NEG_ONE;
            return ZERO;
        }

        /// Floor to integer boundary
        pub fn floor(self: Self) Self {
            const mask: T = ~@as(T, SCALE - 1);
            return Self{ .raw = self.raw & mask };
        }

        /// Ceiling to integer boundary
        pub fn ceil(self: Self) Self {
            return self.add(Self{ .raw = SCALE - 1 }).floor();
        }

        /// Fractional part
        pub fn frac(self: Self) Self {
            const mask: T = SCALE - 1;
            return Self{ .raw = self.raw & mask };
        }
    };
}

// ============================================================
// Audio Processing Helpers
// ============================================================

/// Convert 16-bit audio sample to Q15
pub fn sampleToQ15(sample: i16) Q15 {
    return Q15.fromRaw(sample);
}

/// Convert Q15 to 16-bit audio sample
pub fn q15ToSample(value: Q15) i16 {
    return value.raw;
}

/// Apply gain to audio sample
pub fn applyGain(sample: i16, gain: Q16) i16 {
    const wide: i32 = @as(i32, sample) * gain.raw;
    const result = wide >> Q16.FRAC_BITS;
    return @intCast(std.math.clamp(result, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// Mix two audio samples (average)
pub fn mixSamples(a: i16, b: i16) i16 {
    return @intCast((@as(i32, a) + @as(i32, b)) >> 1);
}

/// Soft clip audio sample to prevent harsh clipping
pub fn softClip(sample: i16) i16 {
    const x = Q15.fromRaw(sample);
    // Simple soft clipper: y = 1.5x - 0.5x^3
    const x_cubed = x.mul(x).mul(x);
    const result = x.mulInt(3).divInt(2).sub(x_cubed.divInt(2));
    return result.raw;
}

// ============================================================
// Decibel Conversion
// ============================================================

/// Pre-computed dB to linear gain table (0 to -48 dB in 1 dB steps)
/// Values are in Q16 format
const db_to_linear_table = [_]i32{
    65536, // 0 dB = 1.0
    58409, // -1 dB
    52057, // -2 dB
    46396, // -3 dB
    41350, // -4 dB
    36854, // -5 dB
    32846, // -6 dB
    29274, // -7 dB
    26090, // -8 dB
    23253, // -9 dB
    20724, // -10 dB
    18471, // -11 dB
    16462, // -12 dB
    14672, // -13 dB
    13076, // -14 dB
    11654, // -15 dB
    10387, // -16 dB
    9258, // -17 dB
    8250, // -18 dB
    7353, // -19 dB
    6554, // -20 dB
    5841, // -21 dB
    5206, // -22 dB
    4640, // -23 dB
    4135, // -24 dB
    3685, // -25 dB
    3285, // -26 dB
    2927, // -27 dB
    2609, // -28 dB
    2325, // -29 dB
    2072, // -30 dB
    1847, // -31 dB
    1646, // -32 dB
    1467, // -33 dB
    1308, // -34 dB
    1165, // -35 dB
    1039, // -36 dB
    926, // -37 dB
    825, // -38 dB
    735, // -39 dB
    655, // -40 dB
    584, // -41 dB
    521, // -42 dB
    464, // -43 dB
    414, // -44 dB
    369, // -45 dB
    328, // -46 dB
    293, // -47 dB
    261, // -48 dB
};

/// Convert dB attenuation (0 to -48) to linear gain (Q16)
pub fn dbToLinear(db: i8) Q16 {
    const clamped = std.math.clamp(-db, 0, 48);
    return Q16.fromRaw(db_to_linear_table[@intCast(clamped)]);
}

// ============================================================
// Tests
// ============================================================

test "Q16 basic operations" {
    const a = Q16.fromInt(3);
    const b = Q16.fromInt(2);

    // Addition
    try std.testing.expectEqual(@as(i32, 5), a.add(b).toInt());

    // Subtraction
    try std.testing.expectEqual(@as(i32, 1), a.sub(b).toInt());

    // Multiplication
    try std.testing.expectEqual(@as(i32, 6), a.mul(b).toInt());

    // Division
    try std.testing.expectEqual(@as(i32, 1), a.div(b).toInt()); // 3/2 truncates to 1
}

test "Q16 from float" {
    const half = Q16.fromFloat(0.5);
    try std.testing.expectEqual(@as(i32, 32768), half.raw);

    const quarter = Q16.fromFloat(0.25);
    try std.testing.expectEqual(@as(i32, 16384), quarter.raw);

    const three_halves = Q16.fromFloat(1.5);
    try std.testing.expectEqual(@as(i32, 98304), three_halves.raw);
}

test "Q16 rounding" {
    const val = Q16.fromFloat(2.7);
    try std.testing.expectEqual(@as(i32, 2), val.toInt()); // Truncates to 2
    try std.testing.expectEqual(@as(i32, 3), val.toIntRounded()); // Rounds to 3
}

test "Q16 lerp" {
    const a = Q16.fromInt(0);
    const b = Q16.fromInt(10);
    const half = Q16.fromFloat(0.5);

    const result = a.lerp(b, half);
    try std.testing.expectEqual(@as(i32, 5), result.toInt());
}

test "Q16 sqrt" {
    const four = Q16.fromInt(4);
    const two = four.sqrt();
    try std.testing.expectEqual(@as(i32, 2), two.toInt());

    const nine = Q16.fromInt(9);
    const three = nine.sqrt();
    try std.testing.expectEqual(@as(i32, 3), three.toInt());
}

test "Q16 clamp" {
    const val = Q16.fromInt(5);
    const lo = Q16.fromInt(0);
    const hi = Q16.fromInt(3);

    try std.testing.expectEqual(@as(i32, 3), val.clamp(lo, hi).toInt());
}

test "audio gain" {
    // Full gain (0 dB)
    const sample: i16 = 1000;
    const full_gain = dbToLinear(0);
    try std.testing.expectEqual(@as(i16, 1000), applyGain(sample, full_gain));

    // -6 dB (roughly half)
    const half_gain = dbToLinear(-6);
    const result = applyGain(sample, half_gain);
    try std.testing.expect(result >= 490 and result <= 510);
}

test "dB to linear conversion" {
    // 0 dB = 1.0
    try std.testing.expectEqual(Q16.ONE.raw, dbToLinear(0).raw);

    // -6 dB ~= 0.5
    const minus_6db = dbToLinear(-6);
    try std.testing.expect(minus_6db.toFloat() > 0.49 and minus_6db.toFloat() < 0.51);
}

test "sample mixing" {
    const a: i16 = 1000;
    const b: i16 = 2000;
    try std.testing.expectEqual(@as(i16, 1500), mixSamples(a, b));

    // Test overflow handling
    const max: i16 = std.math.maxInt(i16);
    const mixed = mixSamples(max, max);
    try std.testing.expectEqual(max, mixed);
}
