//! File to Playback Integration Tests
//!
//! Tests the complete user flow from file selection to playback:
//! Browse Files → Select Track → Load Audio → Play → Control
//!
//! These tests verify the integration between UI and audio systems.

const std = @import("std");
const zigpod = @import("zigpod");
const state_machine = zigpod.ui.state_machine;
const audio = zigpod.audio;
const pipeline = zigpod.audio.pipeline;
const decoders = zigpod.audio.decoders;

// ============================================================
// Test Data
// ============================================================

/// Generate test WAV file data
fn generateTestWav(allocator: std.mem.Allocator, duration_ms: u32) ![]u8 {
    const sample_rate: u32 = 44100;
    const num_channels: u16 = 2;
    const bits_per_sample: u16 = 16;
    const num_samples: u32 = (sample_rate * duration_ms) / 1000;
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
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], num_channels, .little);
    std.mem.writeInt(u32, wav[24..28], sample_rate, .little);
    std.mem.writeInt(u32, wav[28..32], sample_rate * num_channels * bytes_per_sample, .little);
    std.mem.writeInt(u16, wav[32..34], num_channels * bytes_per_sample, .little);
    std.mem.writeInt(u16, wav[34..36], bits_per_sample, .little);

    // data chunk
    wav[36..40].* = "data".*;
    std.mem.writeInt(u32, wav[40..44], data_size, .little);

    // Generate test tone
    var i: u32 = 0;
    while (i < num_samples) : (i += 1) {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        const sample: i16 = @intFromFloat(16000.0 * @sin(2.0 * std.math.pi * 440.0 * t));

        const offset = 44 + i * 4;
        std.mem.writeInt(i16, wav[offset..][0..2], sample, .little);
        std.mem.writeInt(i16, wav[offset + 2 ..][0..2], sample, .little);
    }

    return wav;
}

// ============================================================
// File Selection to Playback Flow Tests
// ============================================================

test "file browser to now playing flow" {
    // Setup state machine
    var sm = state_machine.StateMachine.init();
    _ = sm.handleEvent(.boot_complete);

    // Navigate to file browser
    _ = sm.selectMainMenuItem(2); // Files
    try std.testing.expectEqual(state_machine.State.file_browser, sm.getState());
    try std.testing.expectEqual(@as(u8, 1), sm.stack_depth);

    // Simulate track selection -> push to now playing (not direct transition)
    _ = sm.pushState(.now_playing);
    try std.testing.expectEqual(state_machine.State.now_playing, sm.getState());
    try std.testing.expectEqual(@as(u8, 2), sm.stack_depth);

    // Back to file browser
    _ = sm.popState();
    try std.testing.expectEqual(state_machine.State.file_browser, sm.getState());
}

test "file browser track load failure" {
    var sm = state_machine.StateMachine.init();
    _ = sm.handleEvent(.boot_complete);
    _ = sm.selectMainMenuItem(2);

    // Simulate load failure
    _ = sm.setError("File not found");
    try std.testing.expectEqual(state_machine.State.error_display, sm.getState());

    // Dismiss error
    _ = sm.clearError();
    try std.testing.expect(sm.getState() != state_machine.State.error_display);
}

// ============================================================
// Music Browser to Playback Flow Tests
// ============================================================

test "music browser to now playing flow" {
    var sm = state_machine.StateMachine.init();
    _ = sm.handleEvent(.boot_complete);

    // Navigate to music browser
    _ = sm.selectMainMenuItem(0); // Music
    try std.testing.expectEqual(state_machine.State.music_browser, sm.getState());

    // Simulate track selection
    _ = sm.handleEvent(.track_loaded);
    try std.testing.expectEqual(state_machine.State.now_playing, sm.getState());
}

// ============================================================
// Playback Control Tests
// ============================================================

test "playback state transitions" {
    // Test audio state (without hardware init)
    try std.testing.expectEqual(audio.PlaybackState.stopped, audio.getState());

    // These functions can be called without init for state checking
    try std.testing.expect(!audio.isPlaying());
    try std.testing.expect(!audio.isPaused());
}

test "track info formatting" {
    const info = audio.TrackInfo{
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

test "position formatting" {
    var buf: [10]u8 = undefined;

    // Test various positions
    try std.testing.expectEqualStrings("00:00", audio.formatPosition(0, &buf));
    try std.testing.expectEqualStrings("01:30", audio.formatPosition(90000, &buf));
    try std.testing.expectEqualStrings("05:00", audio.formatPosition(300000, &buf));
}

// ============================================================
// Pipeline Integration Tests
// ============================================================

test "pipeline load and process wav" {
    var pipe = pipeline.AudioPipeline.init();

    // Generate test WAV (100ms)
    const wav_data = try generateTestWav(std.testing.allocator, 100);
    defer std.testing.allocator.free(wav_data);

    // Load into pipeline
    try pipe.load(wav_data);

    // Verify state
    try std.testing.expect(pipe.isActive());
    try std.testing.expectEqual(decoders.DecoderType.wav, pipe.getDecoderType());

    // Get track info
    const info = pipe.getTrackInfo();
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(u32, 44100), info.?.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), info.?.channels);

    // Process some audio
    var output: [512]i16 = undefined;
    const processed = pipe.process(&output);
    try std.testing.expect(processed > 0);
}

test "pipeline volume during playback" {
    var pipe = pipeline.AudioPipeline.init();

    const wav_data = try generateTestWav(std.testing.allocator, 100);
    defer std.testing.allocator.free(wav_data);

    try pipe.load(wav_data);

    // Adjust volume during processing (with immediate jump)
    pipe.setVolume(50);
    pipe.dsp_chain.volume.jumpToTarget();
    try std.testing.expectEqual(@as(u8, 50), pipe.getVolume());

    var output: [256]i16 = undefined;
    _ = pipe.process(&output);

    // Change volume again
    pipe.setVolume(100);
    pipe.dsp_chain.volume.jumpToTarget();
    try std.testing.expectEqual(@as(u8, 100), pipe.getVolume());
}

test "pipeline EQ during playback" {
    var pipe = pipeline.AudioPipeline.init();

    const wav_data = try generateTestWav(std.testing.allocator, 100);
    defer std.testing.allocator.free(wav_data);

    try pipe.load(wav_data);

    // Enable EQ with some settings
    pipe.setEqBand(0, 6); // Bass boost
    pipe.setEqBand(4, -3); // Treble cut

    try std.testing.expectEqual(@as(i8, 6), pipe.getEqBand(0));
    try std.testing.expectEqual(@as(i8, -3), pipe.getEqBand(4));

    var output: [256]i16 = undefined;
    _ = pipe.process(&output);
}

test "pipeline mute/unmute" {
    var pipe = pipeline.AudioPipeline.init();

    const wav_data = try generateTestWav(std.testing.allocator, 100);
    defer std.testing.allocator.free(wav_data);

    try pipe.load(wav_data);

    // Mute
    pipe.mute();
    try std.testing.expectEqual(@as(i32, 0), pipe.dsp_chain.volume.target_volume);

    // Unmute
    pipe.unmute(75);
    try std.testing.expect(pipe.dsp_chain.volume.target_volume > 0);
}

// ============================================================
// End-to-End Flow Tests
// ============================================================

test "complete browse select play flow" {
    // 1. State machine navigation
    var sm = state_machine.StateMachine.init();
    _ = sm.handleEvent(.boot_complete);
    _ = sm.selectMainMenuItem(2); // Files
    try std.testing.expectEqual(state_machine.State.file_browser, sm.getState());

    // 2. Create pipeline
    var pipe = pipeline.AudioPipeline.init();

    // 3. Load audio
    const wav_data = try generateTestWav(std.testing.allocator, 500);
    defer std.testing.allocator.free(wav_data);
    try pipe.load(wav_data);

    // 4. Transition to Now Playing (push to maintain back navigation)
    _ = sm.pushState(.now_playing);
    try std.testing.expectEqual(state_machine.State.now_playing, sm.getState());

    // 5. Set volume
    pipe.setVolume(80);
    pipe.dsp_chain.volume.jumpToTarget();

    // 6. Process some audio
    var output: [1024]i16 = undefined;
    var total_processed: usize = 0;
    for (0..10) |_| {
        total_processed += pipe.process(&output);
    }
    try std.testing.expect(total_processed > 0);

    // 7. Check stats
    try std.testing.expect(pipe.stats.samples_decoded > 0);
    try std.testing.expect(pipe.stats.samples_output > 0);

    // 8. Go back to file browser
    _ = sm.popState();
    try std.testing.expectEqual(state_machine.State.file_browser, sm.getState());

    // 9. Stop pipeline
    pipe.stop();
    try std.testing.expect(!pipe.isActive());
}

// ============================================================
// Error Handling Tests
// ============================================================

test "unsupported format handling" {
    var pipe = pipeline.AudioPipeline.init();

    // Invalid data
    const bad_data = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };

    const result = pipe.load(&bad_data);
    try std.testing.expectError(error.UnsupportedFormat, result);
}

test "pipeline stop and restart" {
    var pipe = pipeline.AudioPipeline.init();

    const wav_data = try generateTestWav(std.testing.allocator, 100);
    defer std.testing.allocator.free(wav_data);

    // First load
    try pipe.load(wav_data);
    try std.testing.expect(pipe.isActive());

    // Stop
    pipe.stop();
    try std.testing.expect(!pipe.isActive());

    // Reload
    try pipe.load(wav_data);
    try std.testing.expect(pipe.isActive());
}

// ============================================================
// Gapless Playback State Tests
// ============================================================

test "gapless enabled state" {
    try std.testing.expect(audio.isGaplessEnabled());

    audio.setGaplessEnabled(false);
    try std.testing.expect(!audio.isGaplessEnabled());

    audio.setGaplessEnabled(true);
    try std.testing.expect(audio.isGaplessEnabled());
}

// ============================================================
// Sample Rate String Tests
// ============================================================

test "sample rate display strings" {
    try std.testing.expectEqualStrings("44.1 kHz", audio.sampleRateString(44100));
    try std.testing.expectEqualStrings("48 kHz", audio.sampleRateString(48000));
    try std.testing.expectEqualStrings("22.05 kHz", audio.sampleRateString(22050));
    try std.testing.expectEqualStrings("Unknown", audio.sampleRateString(12345));
}
