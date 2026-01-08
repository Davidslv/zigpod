//! WAV Audio File Writer
//!
//! Writes audio samples to standard WAV format files.
//! Used by the simulator to capture audio output for testing.

const std = @import("std");

/// WAV file header structure
pub const WavHeader = extern struct {
    // RIFF chunk
    riff_id: [4]u8 = .{ 'R', 'I', 'F', 'F' },
    file_size: u32 align(1) = 0, // Will be filled in on finalize
    wave_id: [4]u8 = .{ 'W', 'A', 'V', 'E' },

    // fmt chunk
    fmt_id: [4]u8 = .{ 'f', 'm', 't', ' ' },
    fmt_size: u32 align(1) = 16, // PCM format
    audio_format: u16 align(1) = 1, // PCM = 1
    num_channels: u16 align(1) = 2, // Stereo default
    sample_rate: u32 align(1) = 44100, // Default
    byte_rate: u32 align(1) = 0, // Will be calculated
    block_align: u16 align(1) = 0, // Will be calculated
    bits_per_sample: u16 align(1) = 16, // 16-bit default

    // data chunk
    data_id: [4]u8 = .{ 'd', 'a', 't', 'a' },
    data_size: u32 align(1) = 0, // Will be filled in on finalize

    const Self = @This();

    /// Create a header with specified parameters
    pub fn init(sample_rate: u32, channels: u16, bits_per_sample: u16) Self {
        var header = Self{};
        header.sample_rate = sample_rate;
        header.num_channels = channels;
        header.bits_per_sample = bits_per_sample;
        header.block_align = channels * (bits_per_sample / 8);
        header.byte_rate = sample_rate * @as(u32, header.block_align);
        return header;
    }

    /// Update sizes after writing all data
    pub fn finalize(self: *Self, data_bytes: u32) void {
        self.data_size = data_bytes;
        self.file_size = 36 + data_bytes; // 36 = header size - 8 (RIFF/size)
    }

    /// Get header as bytes
    pub fn asBytes(self: *const Self) []const u8 {
        return std.mem.asBytes(self);
    }
};

/// WAV file writing errors
pub const WavError = error{
    /// Failed to create or open file
    FileError,
    /// Failed to write data
    WriteError,
    /// Failed to seek in file
    SeekError,
    /// File not open
    NotOpen,
    /// Invalid parameters
    InvalidParameter,
};

/// WAV file writer
pub const WavWriter = struct {
    file: ?std.fs.File = null,
    header: WavHeader = .{},
    samples_written: u64 = 0,
    finalized: bool = false,

    const Self = @This();

    /// Create a new WAV writer
    pub fn init(path: []const u8, sample_rate: u32, channels: u16) WavError!Self {
        return initWithBits(path, sample_rate, channels, 16);
    }

    /// Create a new WAV writer with custom bit depth
    pub fn initWithBits(path: []const u8, sample_rate: u32, channels: u16, bits_per_sample: u16) WavError!Self {
        if (channels == 0 or channels > 8) return WavError.InvalidParameter;
        if (bits_per_sample != 8 and bits_per_sample != 16 and bits_per_sample != 24 and bits_per_sample != 32) {
            return WavError.InvalidParameter;
        }
        if (sample_rate == 0 or sample_rate > 192000) return WavError.InvalidParameter;

        var self = Self{};
        self.header = WavHeader.init(sample_rate, channels, bits_per_sample);

        // Create and open file
        self.file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch {
            return WavError.FileError;
        };

        // Write initial header (will be updated on finalize)
        self.file.?.writeAll(self.header.asBytes()) catch {
            self.file.?.close();
            self.file = null;
            return WavError.WriteError;
        };

        return self;
    }

    /// Check if writer is open
    pub fn isOpen(self: *const Self) bool {
        return self.file != null and !self.finalized;
    }

    /// Write 16-bit stereo samples (interleaved)
    pub fn writeSamples(self: *Self, samples: []const i16) WavError!void {
        if (!self.isOpen()) return WavError.NotOpen;

        const bytes = std.mem.sliceAsBytes(samples);
        self.file.?.writeAll(bytes) catch return WavError.WriteError;
        self.samples_written += samples.len;
    }

    /// Write a single stereo sample pair
    pub fn writeSamplePair(self: *Self, left: i16, right: i16) WavError!void {
        if (!self.isOpen()) return WavError.NotOpen;

        const samples = [2]i16{ left, right };
        const bytes = std.mem.asBytes(&samples);
        self.file.?.writeAll(bytes) catch return WavError.WriteError;
        self.samples_written += 2;
    }

    /// Write mono samples (will be written as-is for mono, or duplicated for stereo)
    pub fn writeMonoSamples(self: *Self, samples: []const i16) WavError!void {
        if (!self.isOpen()) return WavError.NotOpen;

        if (self.header.num_channels == 1) {
            // Mono output
            const bytes = std.mem.sliceAsBytes(samples);
            self.file.?.writeAll(bytes) catch return WavError.WriteError;
            self.samples_written += samples.len;
        } else {
            // Duplicate to stereo
            for (samples) |sample| {
                try self.writeSamplePair(sample, sample);
            }
        }
    }

    /// Write 8-bit samples (unsigned)
    pub fn writeSamples8(self: *Self, samples: []const u8) WavError!void {
        if (!self.isOpen()) return WavError.NotOpen;
        if (self.header.bits_per_sample != 8) return WavError.InvalidParameter;

        self.file.?.writeAll(samples) catch return WavError.WriteError;
        self.samples_written += samples.len;
    }

    /// Get duration in seconds
    pub fn getDuration(self: *const Self) f64 {
        const samples_per_channel = self.samples_written / self.header.num_channels;
        return @as(f64, @floatFromInt(samples_per_channel)) / @as(f64, @floatFromInt(self.header.sample_rate));
    }

    /// Get total bytes written
    pub fn getBytesWritten(self: *const Self) u64 {
        const bytes_per_sample = self.header.bits_per_sample / 8;
        return self.samples_written * bytes_per_sample;
    }

    /// Finalize the WAV file (update header and close)
    pub fn finalize(self: *Self) WavError!void {
        if (self.file == null) return WavError.NotOpen;
        if (self.finalized) return;

        // Calculate data size
        const data_bytes: u32 = @intCast(self.getBytesWritten());

        // Update header
        self.header.finalize(data_bytes);

        // Seek to beginning and rewrite header
        self.file.?.seekTo(0) catch return WavError.SeekError;
        self.file.?.writeAll(self.header.asBytes()) catch return WavError.WriteError;

        self.finalized = true;
    }

    /// Close the writer (will finalize if not already done)
    pub fn close(self: *Self) void {
        if (self.file) |f| {
            if (!self.finalized) {
                self.finalize() catch {};
            }
            f.close();
            self.file = null;
        }
    }

    /// Cleanup (same as close)
    pub fn deinit(self: *Self) void {
        self.close();
    }
};

/// Helper to generate test tones
pub const ToneGenerator = struct {
    sample_rate: u32,
    phase: f64 = 0.0,

    const Self = @This();

    /// Create a tone generator
    pub fn init(sample_rate: u32) Self {
        return .{ .sample_rate = sample_rate };
    }

    /// Generate a sine wave sample at the given frequency
    pub fn nextSample(self: *Self, frequency: f64, amplitude: f64) i16 {
        const sample = @sin(self.phase * 2.0 * std.math.pi) * amplitude;
        self.phase += frequency / @as(f64, @floatFromInt(self.sample_rate));
        if (self.phase >= 1.0) self.phase -= 1.0;
        return @intFromFloat(sample * 32767.0);
    }

    /// Fill buffer with sine wave
    pub fn fillSine(self: *Self, buffer: []i16, frequency: f64, amplitude: f64) void {
        for (buffer) |*sample| {
            sample.* = self.nextSample(frequency, amplitude);
        }
    }

    /// Reset phase
    pub fn reset(self: *Self) void {
        self.phase = 0.0;
    }
};

// ============================================================
// Tests
// ============================================================

test "wav header size" {
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(WavHeader));
}

test "wav header init" {
    const header = WavHeader.init(48000, 2, 16);

    try std.testing.expectEqual(@as(u32, 48000), header.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), header.num_channels);
    try std.testing.expectEqual(@as(u16, 16), header.bits_per_sample);
    try std.testing.expectEqual(@as(u16, 4), header.block_align);
    try std.testing.expectEqual(@as(u32, 192000), header.byte_rate);
}

test "wav header finalize" {
    var header = WavHeader.init(44100, 2, 16);

    // 1 second of stereo 16-bit audio = 44100 * 2 * 2 = 176400 bytes
    header.finalize(176400);

    try std.testing.expectEqual(@as(u32, 176400), header.data_size);
    try std.testing.expectEqual(@as(u32, 176436), header.file_size);
}

test "wav writer create and close" {
    const test_path = "/tmp/test_wav_writer.wav";

    var writer = try WavWriter.init(test_path, 44100, 2);
    defer std.fs.cwd().deleteFile(test_path) catch {};

    try std.testing.expect(writer.isOpen());

    // Write some samples
    const samples = [_]i16{ 0, 1000, 2000, 3000, -1000, -2000 };
    try writer.writeSamples(&samples);

    try std.testing.expectEqual(@as(u64, 6), writer.samples_written);

    writer.close();
    try std.testing.expect(!writer.isOpen());
}

test "wav writer with tone" {
    const test_path = "/tmp/test_wav_tone.wav";

    var writer = try WavWriter.init(test_path, 44100, 2);
    defer writer.deinit();
    defer std.fs.cwd().deleteFile(test_path) catch {};

    var gen = ToneGenerator.init(44100);
    var buffer: [1024]i16 = undefined;

    // Generate 1 second of 440Hz tone (stereo)
    for (0..86) |_| { // ~44100 samples / 512 stereo pairs ≈ 86 iterations
        gen.fillSine(&buffer, 440.0, 0.5);
        try writer.writeSamples(&buffer);
    }

    try writer.finalize();

    // Check duration is approximately 1 second
    const duration = writer.getDuration();
    try std.testing.expect(duration >= 0.9 and duration <= 1.1);
}

test "wav invalid parameters" {
    // Invalid channels
    try std.testing.expectError(WavError.InvalidParameter, WavWriter.init("/tmp/test.wav", 44100, 0));

    // Invalid bit depth
    try std.testing.expectError(WavError.InvalidParameter, WavWriter.initWithBits("/tmp/test.wav", 44100, 2, 12));

    // Invalid sample rate
    try std.testing.expectError(WavError.InvalidParameter, WavWriter.init("/tmp/test.wav", 0, 2));
}

test "tone generator" {
    var gen = ToneGenerator.init(44100);

    // First sample at 0 phase should be near 0
    const sample1 = gen.nextSample(440.0, 1.0);
    try std.testing.expect(@abs(sample1) < 100);

    // After 1/4 wavelength, should be near max
    // 440Hz period = 44100/440 ≈ 100 samples, 1/4 = 25 samples
    for (0..24) |_| {
        _ = gen.nextSample(440.0, 1.0);
    }
    const sample25 = gen.nextSample(440.0, 1.0);
    try std.testing.expect(sample25 > 30000);
}

test "mono to stereo conversion" {
    const test_path = "/tmp/test_wav_mono.wav";

    var writer = try WavWriter.init(test_path, 44100, 2);
    defer writer.deinit();
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Write mono samples (should be duplicated to stereo)
    const mono_samples = [_]i16{ 1000, 2000, 3000 };
    try writer.writeMonoSamples(&mono_samples);

    // Should have written 6 samples (3 stereo pairs)
    try std.testing.expectEqual(@as(u64, 6), writer.samples_written);
}
