//! MP3 Decoder Integration Test
//!
//! Tests the MP3 decoder with real MP3 files to verify decoding works correctly.

const std = @import("std");
const mp3 = @import("mp3.zig");
const id3 = @import("id3.zig");

/// Test MP3 decoder initialization and basic decoding
pub fn testMp3Decoder(allocator: std.mem.Allocator, file_path: []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n=== MP3 Decoder Test ===\n", .{});
    try stdout.print("File: {s}\n", .{file_path});

    // Read the file
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        try stdout.print("Failed to open file: {}\n", .{err});
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;
    try stdout.print("File size: {d} bytes\n", .{file_size});

    if (file_size > 10 * 1024 * 1024) {
        try stdout.print("File too large (max 10MB)\n", .{});
        return error.FileTooLarge;
    }

    const data = try allocator.alloc(u8, file_size);
    defer allocator.free(data);

    const bytes_read = try file.readAll(data);
    if (bytes_read != file_size) {
        try stdout.print("Short read: {d}/{d} bytes\n", .{ bytes_read, file_size });
        return error.ShortRead;
    }

    // Parse ID3 tags
    try stdout.print("\n--- ID3 Tags ---\n", .{});
    const metadata = id3.parse(data);
    if (metadata.hasMetadata()) {
        if (metadata.title_len > 0) {
            try stdout.print("Title:  {s}\n", .{metadata.getTitle()});
        }
        if (metadata.artist_len > 0) {
            try stdout.print("Artist: {s}\n", .{metadata.getArtist()});
        }
        if (metadata.album_len > 0) {
            try stdout.print("Album:  {s}\n", .{metadata.getAlbum()});
        }
        if (metadata.year_len > 0) {
            try stdout.print("Year:   {s}\n", .{metadata.getYear()});
        }
        if (metadata.track > 0) {
            try stdout.print("Track:  {d}\n", .{metadata.track});
        }
    } else {
        try stdout.print("No ID3 tags found\n", .{});
    }

    // Initialize MP3 decoder
    try stdout.print("\n--- MP3 Decoder ---\n", .{});
    var decoder = mp3.Mp3Decoder.init(data) catch |err| {
        try stdout.print("Failed to initialize MP3 decoder: {s}\n", .{@errorName(err)});
        return err;
    };

    // Print track info
    const info = decoder.getTrackInfo();
    try stdout.print("Sample rate:  {d} Hz\n", .{info.sample_rate});
    try stdout.print("Channels:     {d}\n", .{info.channels});
    try stdout.print("Duration:     {d} ms ({d}:{d:0>2})\n", .{
        info.duration_ms,
        info.duration_ms / 60000,
        (info.duration_ms / 1000) % 60,
    });
    try stdout.print("Total samples: {d}\n", .{info.total_samples});

    if (decoder.current_header) |header| {
        try stdout.print("Bitrate:      {d} kbps\n", .{header.bitrate_kbps});
        try stdout.print("MPEG version: {s}\n", .{switch (header.version) {
            .mpeg1 => "MPEG-1",
            .mpeg2 => "MPEG-2",
            .mpeg25 => "MPEG-2.5",
            .reserved => "Reserved",
        }});
        try stdout.print("Channel mode: {s}\n", .{switch (header.channel_mode) {
            .stereo => "Stereo",
            .joint_stereo => "Joint Stereo",
            .dual_channel => "Dual Channel",
            .mono => "Mono",
        }});
    }

    // Decode a few frames
    try stdout.print("\n--- Decoding Test ---\n", .{});

    var output_buffer: [4096]i16 = undefined;
    var total_samples_decoded: usize = 0;
    var frames_decoded: usize = 0;
    var max_sample: i16 = 0;
    var min_sample: i16 = 0;

    // Decode up to 10 frames or 1 second of audio
    while (frames_decoded < 50 and !decoder.isEof()) {
        const samples = decoder.decode(&output_buffer);
        if (samples == 0) break;

        total_samples_decoded += samples;
        frames_decoded += 1;

        // Track min/max for level check
        for (output_buffer[0..samples]) |s| {
            if (s > max_sample) max_sample = s;
            if (s < min_sample) min_sample = s;
        }
    }

    try stdout.print("Frames decoded:  {d}\n", .{frames_decoded});
    try stdout.print("Samples decoded: {d}\n", .{total_samples_decoded});
    try stdout.print("Sample range:    {d} to {d}\n", .{ min_sample, max_sample });

    // Calculate approximate duration decoded
    const ms_decoded = if (info.sample_rate > 0)
        (total_samples_decoded * 1000) / (info.sample_rate * info.channels)
    else
        0;
    try stdout.print("Time decoded:    {d} ms\n", .{ms_decoded});

    // Success check
    if (frames_decoded > 0 and total_samples_decoded > 0) {
        try stdout.print("\n[PASS] MP3 decoding successful!\n", .{});
    } else {
        try stdout.print("\n[FAIL] No samples decoded\n", .{});
        return error.DecodeFailed;
    }
}

/// Main entry point for standalone testing
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Usage: mp3_test <mp3_file>\n", .{});
        try stdout.print("\nExample:\n", .{});
        try stdout.print("  zig build-exe src/audio/decoders/mp3_test.zig -OReleaseFast\n", .{});
        try stdout.print("  ./mp3_test audio-samples/test-formats/test-mp3-128kbps.mp3\n", .{});
        return;
    }

    try testMp3Decoder(allocator, args[1]);
}

// Also make it work as a module test
test "mp3 decoder - sample file" {
    // This test is skipped if the sample file doesn't exist
    const test_file = "audio-samples/test-formats/test-mp3-128kbps.mp3";

    std.fs.cwd().access(test_file, .{}) catch {
        // Skip test if file doesn't exist
        return;
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    testMp3Decoder(gpa.allocator(), test_file) catch |err| {
        std.debug.print("MP3 test failed: {}\n", .{err});
        return err;
    };
}
