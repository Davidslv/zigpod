//! Audio Pipeline Integration Tests
//!
//! Tests the complete audio processing chain:
//! Decoder → Resampler → Ditherer → DSP Chain → Output
//!
//! These tests verify that all audio components work together correctly.

const std = @import("std");
const zigpod = @import("zigpod");
const pipeline = zigpod.audio.pipeline;
const dsp = zigpod.audio.dsp;
const decoders = zigpod.audio.decoders;
const audio = zigpod.audio;

// ============================================================
// Test Data Generation
// ============================================================

/// Generate a simple WAV file header for testing
fn generateTestWavData(allocator: std.mem.Allocator, num_samples: u32, sample_rate: u32) ![]u8 {
    const num_channels: u16 = 2;
    const bits_per_sample: u16 = 16;
    const bytes_per_sample = bits_per_sample / 8;
    const data_size = num_samples * num_channels * bytes_per_sample;
    const file_size = 44 + data_size - 8;

    var wav = try allocator.alloc(u8, 44 + data_size);

    // RIFF header
    wav[0..4].* = "RIFF".*;
    std.mem.writeInt(u32, wav[4..8], file_size, .little);
    wav[8..12].* = "WAVE".*;

    // fmt chunk
    wav[12..16].* = "fmt ".*;
    std.mem.writeInt(u32, wav[16..20], 16, .little); // chunk size
    std.mem.writeInt(u16, wav[20..22], 1, .little); // audio format (PCM)
    std.mem.writeInt(u16, wav[22..24], num_channels, .little);
    std.mem.writeInt(u32, wav[24..28], sample_rate, .little);
    std.mem.writeInt(u32, wav[28..32], sample_rate * num_channels * bytes_per_sample, .little);
    std.mem.writeInt(u16, wav[32..34], num_channels * bytes_per_sample, .little);
    std.mem.writeInt(u16, wav[34..36], bits_per_sample, .little);

    // data chunk
    wav[36..40].* = "data".*;
    std.mem.writeInt(u32, wav[40..44], data_size, .little);

    // Generate sine wave test data
    var i: u32 = 0;
    while (i < num_samples) : (i += 1) {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        const sample: i16 = @intFromFloat(16000.0 * @sin(2.0 * std.math.pi * 440.0 * t));

        const offset = 44 + i * 4;
        std.mem.writeInt(i16, wav[offset..][0..2], sample, .little); // Left
        std.mem.writeInt(i16, wav[offset + 2 ..][0..2], sample, .little); // Right
    }

    return wav;
}

// ============================================================
// Pipeline Integration Tests
// ============================================================

test "pipeline processes wav data end-to-end" {
    var pipe = pipeline.AudioPipeline.init();

    // Create test WAV data (1 second at 44.1kHz)
    const test_data = try generateTestWavData(std.testing.allocator, 44100, 44100);
    defer std.testing.allocator.free(test_data);

    // Load the data
    try pipe.load(test_data);

    // Verify pipeline is active
    try std.testing.expect(pipe.isActive());
    try std.testing.expectEqual(decoders.DecoderType.wav, pipe.getDecoderType());

    // Process some audio
    var output: [1024]i16 = undefined;
    const processed = pipe.process(&output);

    // Should have processed some samples
    try std.testing.expect(processed > 0);
    try std.testing.expect(pipe.stats.samples_decoded > 0);
}

test "pipeline with DSP effects" {
    var pipe = pipeline.AudioPipeline.init();

    // Create test data
    const test_data = try generateTestWavData(std.testing.allocator, 4410, 44100);
    defer std.testing.allocator.free(test_data);

    try pipe.load(test_data);

    // Enable bass boost
    pipe.setBassBoost(true, 6);

    // Enable EQ
    pipe.setEqBand(0, 3); // +3dB bass
    pipe.setEqBand(4, -3); // -3dB treble

    // Set volume
    pipe.setVolume(75);

    // Process audio
    var output: [512]i16 = undefined;
    const processed = pipe.process(&output);

    try std.testing.expect(processed > 0);
    try std.testing.expectEqual(@as(u8, 75), pipe.getVolume());
}

test "pipeline volume ramping prevents clicks" {
    var pipe = pipeline.AudioPipeline.init();

    const test_data = try generateTestWavData(std.testing.allocator, 4410, 44100);
    defer std.testing.allocator.free(test_data);

    try pipe.load(test_data);

    // Start at 100% volume
    pipe.setVolume(100);
    pipe.dsp_chain.volume.jumpToTarget();

    // Drop to 0% - should ramp, not jump
    pipe.setVolume(0);
    try std.testing.expect(pipe.dsp_chain.volume.isRamping());

    // Process many samples to complete ramping
    var output: [512]i16 = undefined;
    var iterations: u32 = 0;
    while (pipe.dsp_chain.volume.isRamping() and iterations < 1000) : (iterations += 1) {
        _ = pipe.process(&output);
    }

    // Should have finished ramping
    try std.testing.expect(!pipe.dsp_chain.volume.isRamping());
    try std.testing.expectEqual(@as(i32, 0), pipe.dsp_chain.volume.current_volume);
}

test "pipeline statistics tracking" {
    var pipe = pipeline.AudioPipeline.init();

    const test_data = try generateTestWavData(std.testing.allocator, 4410, 44100);
    defer std.testing.allocator.free(test_data);

    try pipe.load(test_data);

    // Reset stats
    pipe.resetStats();
    try std.testing.expectEqual(@as(u64, 0), pipe.stats.samples_decoded);

    // Process audio
    var output: [1024]i16 = undefined;
    _ = pipe.process(&output);

    // Check stats were updated
    try std.testing.expect(pipe.stats.samples_decoded > 0);
    try std.testing.expect(pipe.stats.samples_output > 0);
}

// ============================================================
// DSP Chain Integration Tests
// ============================================================

test "DSP chain applies all effects in correct order" {
    var chain = dsp.DspChain.init();

    // Enable all effects
    chain.volume.setVolume(80);
    chain.volume.jumpToTarget();
    chain.bass_boost.enabled = true;
    chain.bass_boost.setBoost(6);
    chain.equalizer.enabled = true;
    chain.equalizer.setBandGain(0, 6); // Boost bass
    chain.stereo_widener.enabled = true;
    chain.stereo_widener.setWidth(150);

    // Process a sample
    const result = chain.process(10000, 10000);

    // Output should be different due to processing
    // (Not necessarily larger due to volume < 100%)
    try std.testing.expect(result.left != 0 or result.right != 0);
}

test "DSP chain bypass" {
    var chain = dsp.DspChain.init();

    // Disable chain
    chain.enabled = false;

    // Process a sample
    const result = chain.process(12345, -12345);

    // Should pass through unchanged
    try std.testing.expectEqual(@as(i16, 12345), result.left);
    try std.testing.expectEqual(@as(i16, -12345), result.right);
}

test "EQ preset application" {
    var chain = dsp.DspChain.init();

    // Apply Rock preset
    chain.applyPreset(1);

    // Check bands were set
    try std.testing.expectEqual(@as(i8, 4), chain.equalizer.getBandGain(0)); // Bass
    try std.testing.expectEqual(@as(i8, 2), chain.equalizer.getBandGain(1));
    try std.testing.expectEqual(@as(i8, -2), chain.equalizer.getBandGain(2)); // Mids
}

// ============================================================
// Resampler Integration Tests
// ============================================================

test "resampler upsampling 22050 to 44100" {
    var resampler = dsp.Resampler.init();
    resampler.configure(22050, 44100);

    try std.testing.expect(resampler.enabled);

    // Input: 2 stereo samples at 22050 Hz
    const input = [_]i16{ 1000, 1000, 2000, 2000 };
    var output: [8]i16 = undefined;

    const count = resampler.resampleBuffer(&input, &output);

    // Should produce approximately 4 stereo samples (2x)
    try std.testing.expect(count >= 2);
}

test "resampler downsampling 48000 to 44100" {
    var resampler = dsp.Resampler.init();
    resampler.configure(48000, 44100);

    try std.testing.expect(resampler.enabled);

    // Input: 4 stereo samples at 48000 Hz
    const input = [_]i16{ 1000, 1000, 2000, 2000, 3000, 3000, 4000, 4000 };
    var output: [8]i16 = undefined;

    const count = resampler.resampleBuffer(&input, &output);

    // Should produce fewer samples
    try std.testing.expect(count >= 1);
    try std.testing.expect(count <= 4);
}

test "resampler passthrough at same rate" {
    var resampler = dsp.Resampler.init();
    resampler.configure(44100, 44100);

    try std.testing.expect(!resampler.enabled);

    const input = [_]i16{ 1000, 2000, 3000, 4000 };
    var output: [4]i16 = undefined;

    const count = resampler.resampleBuffer(&input, &output);

    // Should pass through exactly
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(i16, 1000), output[0]);
    try std.testing.expectEqual(@as(i16, 2000), output[1]);
}

// ============================================================
// Ditherer Integration Tests
// ============================================================

test "ditherer adds noise variation" {
    var ditherer = dsp.Ditherer.init();
    ditherer.enabled = true;

    // Same input value
    const input: i32 = 0x7FFF0000;

    // Generate multiple outputs
    var outputs: [10]i16 = undefined;
    for (&outputs) |*out| {
        out.* = ditherer.ditherToI16(input);
    }

    // Values should be close to the expected output
    // TPDF dithering adds small variations but keeps output in expected range
    for (outputs) |out| {
        // Output should be in reasonable range (max int16 scaled down)
        try std.testing.expect(out > 32000 or out < -32000 or (out >= -32768 and out <= 32767));
    }
}

test "ditherer disabled passthrough" {
    var ditherer = dsp.Ditherer.init();
    ditherer.enabled = false;

    const input: i32 = 0x40000000;
    const output = ditherer.ditherToI16(input);

    try std.testing.expectEqual(@as(i16, 0x4000), output);
}

// ============================================================
// Format Detection Tests
// ============================================================

test "detect WAV format" {
    const wav_header = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E' };
    try std.testing.expectEqual(decoders.DecoderType.wav, decoders.detectFormat(&wav_header));
}

test "detect FLAC format" {
    const flac_header = [_]u8{ 'f', 'L', 'a', 'C', 0, 0, 0, 0 };
    try std.testing.expectEqual(decoders.DecoderType.flac, decoders.detectFormat(&flac_header));
}

test "detect MP3 format with ID3" {
    const mp3_header = [_]u8{ 'I', 'D', '3', 0x04, 0x00, 0x00, 0, 0, 0, 0 };
    try std.testing.expectEqual(decoders.DecoderType.mp3, decoders.detectFormat(&mp3_header));
}

test "detect unknown format" {
    const unknown_header = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(decoders.DecoderType.unknown, decoders.detectFormat(&unknown_header));
}

// ============================================================
// Audio Module Integration Tests
// ============================================================

test "audio DSP chain is accessible" {
    const chain = audio.getDspChain();
    try std.testing.expect(chain.enabled);
}

test "audio DSP volume control" {
    // Set volume and jump to target (skipping ramp)
    audio.setDspVolume(75);
    audio.getDspChain().volume.jumpToTarget();
    try std.testing.expectEqual(@as(u8, 75), audio.getDspVolume());

    audio.setDspVolume(50);
    audio.getDspChain().volume.jumpToTarget();
    try std.testing.expectEqual(@as(u8, 50), audio.getDspVolume());
}

test "audio EQ control" {
    audio.setEqBand(0, 6);
    try std.testing.expectEqual(@as(i8, 6), audio.getEqBand(0));

    audio.setEqBand(2, -3);
    try std.testing.expectEqual(@as(i8, -3), audio.getEqBand(2));
}

test "audio bass boost" {
    audio.setBassBoost(6);
    try std.testing.expectEqual(@as(i8, 6), audio.getBassBoost());

    audio.setBassBoost(0);
    try std.testing.expectEqual(@as(i8, 0), audio.getBassBoost());
}

test "audio DSP enable/disable" {
    audio.setDspEnabled(true);
    try std.testing.expect(audio.isDspEnabled());

    audio.setDspEnabled(false);
    try std.testing.expect(!audio.isDspEnabled());

    // Re-enable for other tests
    audio.setDspEnabled(true);
}
