//! MP3 Decoder Integration Tests
//!
//! Tests the MP3 decoder with real MP3 files to verify:
//! - Format detection
//! - ID3 tag parsing
//! - Audio frame decoding
//! - Various bitrates and sample rates
//!
//! Run with: zig build test-mp3

const std = @import("std");
const zigpod = @import("zigpod");
const decoders = zigpod.audio.decoders;
const mp3 = decoders.mp3;
const id3 = decoders.id3;

// ============================================================
// Test Utilities
// ============================================================

/// Read a test file from the audio-samples directory
fn readTestFile(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
        std.debug.print("Note: Test file '{s}' not found, skipping test\n", .{filename});
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size > 10 * 1024 * 1024) {
        return error.FileTooLarge;
    }

    const data = try allocator.alloc(u8, stat.size);
    const bytes_read = try file.readAll(data);
    if (bytes_read != stat.size) {
        allocator.free(data);
        return error.ShortRead;
    }

    return data;
}

// ============================================================
// MP3 Format Detection Tests
// ============================================================

test "mp3 format detection - ID3v2 header" {
    // ID3v2 tag at start of file
    const id3v2_header = [_]u8{ 'I', 'D', '3', 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expect(mp3.isMp3File(&id3v2_header));
}

test "mp3 format detection - sync word" {
    // MPEG-1 Layer 3 sync word
    const sync_word = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };
    try std.testing.expect(mp3.isMp3File(&sync_word));
}

test "mp3 format detection - not mp3" {
    const wav_header = [_]u8{ 'R', 'I', 'F', 'F', 0x00, 0x00, 0x00, 0x00, 'W', 'A', 'V', 'E' };
    try std.testing.expect(!mp3.isMp3File(&wav_header));
}

// ============================================================
// ID3 Tag Parsing Tests
// ============================================================

test "id3 parser - v1 tag" {
    // Create a minimal ID3v1 tag (128 bytes at "end" of file)
    var data: [128]u8 = [_]u8{0} ** 128;
    data[0] = 'T';
    data[1] = 'A';
    data[2] = 'G';
    @memcpy(data[3..13], "Test Title");
    @memcpy(data[33..44], "Test Artist");
    @memcpy(data[63..73], "Test Album");
    @memcpy(data[93..97], "2024");
    data[125] = 0;
    data[126] = 5; // Track number

    const metadata = id3.parse(&data);
    try std.testing.expectEqualStrings("Test Title", metadata.getTitle());
    try std.testing.expectEqualStrings("Test Artist", metadata.getArtist());
    try std.testing.expectEqualStrings("Test Album", metadata.getAlbum());
    try std.testing.expectEqualStrings("2024", metadata.getYear());
    try std.testing.expectEqual(@as(u8, 5), metadata.track);
}

test "id3 parser - no tags" {
    const data = [_]u8{ 0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const metadata = id3.parse(&data);
    try std.testing.expect(!metadata.hasMetadata());
}

// ============================================================
// MP3 Frame Header Tests
// ============================================================

test "mp3 frame header parsing" {
    // MPEG-1 Layer 3, 128kbps, 44100Hz, Stereo
    const frame_header = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };

    var decoder_data: [256]u8 = undefined;
    @memcpy(decoder_data[0..4], &frame_header);
    @memset(decoder_data[4..], 0);

    // The decoder needs more data to initialize properly
    // This is a basic header parsing test
    const header = mp3.FrameHeader{
        .version = .mpeg1,
        .layer = .layer3,
        .crc_protected = false,
        .bitrate_kbps = 128,
        .sample_rate = 44100,
        .padding = false,
        .channel_mode = .stereo,
        .mode_extension = 0,
        .copyright = false,
        .original = false,
        .emphasis = 0,
    };

    try std.testing.expectEqual(@as(u16, 1152), header.samplesPerFrame());
    try std.testing.expectEqual(@as(u8, 2), header.channels());
    try std.testing.expectEqual(@as(usize, 417), header.frameSize());
}

// ============================================================
// Real File Tests (require test MP3 files)
// ============================================================

test "mp3 decoder - 128kbps file" {
    const allocator = std.testing.allocator;
    const data = readTestFile(allocator, "audio-samples/test-formats/test-mp3-128kbps.mp3") catch return;
    defer allocator.free(data);

    // Parse ID3 tags
    const metadata = id3.parse(data);
    std.debug.print("\n=== 128kbps MP3 Test ===\n", .{});
    if (metadata.hasMetadata()) {
        std.debug.print("Title: {s}\n", .{metadata.getTitle()});
        std.debug.print("Artist: {s}\n", .{metadata.getArtist()});
    }

    // Initialize decoder
    var decoder = try mp3.Mp3Decoder.init(data);

    const info = decoder.getTrackInfo();
    std.debug.print("Sample rate: {d} Hz\n", .{info.sample_rate});
    std.debug.print("Channels: {d}\n", .{info.channels});
    std.debug.print("Duration: {d} ms\n", .{info.duration_ms});

    try std.testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), info.channels);

    if (decoder.current_header) |header| {
        try std.testing.expectEqual(@as(u16, 128), header.bitrate_kbps);
    }

    // Decode some frames
    var output: [4096]i16 = undefined;
    var total_samples: usize = 0;
    var frame_count: usize = 0;

    while (frame_count < 10 and !decoder.isEof()) {
        const samples = decoder.decode(&output);
        if (samples == 0) break;
        total_samples += samples;
        frame_count += 1;
    }

    std.debug.print("Decoded {d} frames, {d} samples\n", .{ frame_count, total_samples });
    try std.testing.expect(frame_count > 0);
    try std.testing.expect(total_samples > 0);
}

test "mp3 decoder - 320kbps file" {
    const allocator = std.testing.allocator;
    const data = readTestFile(allocator, "audio-samples/test-formats/test-mp3-320kbps.mp3") catch return;
    defer allocator.free(data);

    var decoder = try mp3.Mp3Decoder.init(data);

    if (decoder.current_header) |header| {
        std.debug.print("\n=== 320kbps MP3 Test ===\n", .{});
        std.debug.print("Bitrate: {d} kbps\n", .{header.bitrate_kbps});
        try std.testing.expectEqual(@as(u16, 320), header.bitrate_kbps);
    }

    // Decode some frames
    var output: [4096]i16 = undefined;
    const samples = decoder.decode(&output);
    try std.testing.expect(samples > 0);
}

test "mp3 decoder - VBR file" {
    const allocator = std.testing.allocator;
    const data = readTestFile(allocator, "audio-samples/test-formats/test-mp3-vbr-q0.mp3") catch return;
    defer allocator.free(data);

    var decoder = try mp3.Mp3Decoder.init(data);

    std.debug.print("\n=== VBR MP3 Test ===\n", .{});

    // VBR files may have varying bitrates per frame
    var output: [4096]i16 = undefined;
    var total_samples: usize = 0;
    var frame_count: usize = 0;

    while (frame_count < 20 and !decoder.isEof()) {
        const samples = decoder.decode(&output);
        if (samples == 0) break;
        total_samples += samples;
        frame_count += 1;
    }

    std.debug.print("Decoded {d} frames, {d} samples\n", .{ frame_count, total_samples });
    try std.testing.expect(frame_count > 0);
}

test "mp3 decoder - seek and reset" {
    const allocator = std.testing.allocator;
    const data = readTestFile(allocator, "audio-samples/test-formats/test-mp3-128kbps.mp3") catch return;
    defer allocator.free(data);

    var decoder = try mp3.Mp3Decoder.init(data);

    // Decode some frames
    var output: [4096]i16 = undefined;
    _ = decoder.decode(&output);
    _ = decoder.decode(&output);

    const pos_after_decode = decoder.getPosition();
    try std.testing.expect(pos_after_decode > 0);

    // Reset and verify position
    decoder.reset();
    const pos_after_reset = decoder.getPosition();
    try std.testing.expectEqual(@as(u64, 0), pos_after_reset);

    // Should be able to decode again
    const samples = decoder.decode(&output);
    try std.testing.expect(samples > 0);
}

// ============================================================
// Decoder Type Detection Tests
// ============================================================

test "decoder type detection - mp3" {
    const id3_data = [_]u8{ 'I', 'D', '3', 0x04, 0x00, 0x00, 0, 0, 0, 0 };
    try std.testing.expectEqual(decoders.DecoderType.mp3, decoders.detectFormat(&id3_data));

    const sync_data = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };
    try std.testing.expectEqual(decoders.DecoderType.mp3, decoders.detectFormat(&sync_data));
}

test "supported extensions - mp3" {
    try std.testing.expect(decoders.isSupportedExtension(".mp3"));
    try std.testing.expect(decoders.isSupportedExtension(".MP3"));
}
