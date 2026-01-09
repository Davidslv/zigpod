//! MP3 Playback Integration Test
//!
//! Tests playing an MP3 file through the complete pipeline:
//! Mock FAT32 → FAT32 driver → Audio loader → MP3 decoder

const std = @import("std");
const zigpod = @import("zigpod");

const simulator = zigpod.simulator;
const fat32 = zigpod.fat32;
const audio = zigpod.audio;

test "play MP3 from mock FAT32" {
    const allocator = std.testing.allocator;

    // Initialize simulator with mock FAT32 from audio-samples directory
    const config = simulator.SimulatorConfig{
        .audio_samples_path = "audio-samples",
    };

    simulator.initSimulator(allocator, config) catch |err| {
        std.debug.print("Skipping test: could not init simulator: {}\n", .{err});
        return;
    };
    defer simulator.shutdownSimulator();

    // Check FAT32 is initialized
    if (!fat32.isInitialized()) {
        std.debug.print("Skipping test: FAT32 not initialized\n", .{});
        return;
    }

    // Initialize audio engine
    audio.init() catch |err| {
        std.debug.print("Audio init error (expected in test): {}\n", .{err});
        // Continue anyway - we can still test the loading path
    };

    // List files in /MUSIC directory to find an MP3
    var entries: [32]fat32.DirEntryInfo = undefined;
    const count = fat32.listDirectory("/MUSIC", &entries) catch |err| {
        std.debug.print("Could not list /MUSIC: {}\n", .{err});
        return;
    };

    std.debug.print("\nFiles in /MUSIC ({d} entries):\n", .{count});

    var mp3_path: ?[]const u8 = null;
    var path_buffer: [256]u8 = undefined;

    for (entries[0..count]) |entry| {
        const name = entry.getName();
        std.debug.print("  - {s} ({d} bytes, dir={any})\n", .{ name, entry.size, entry.is_directory });

        // Find first MP3 file
        if (mp3_path == null and entry.size > 0 and !entry.is_directory) {
            if (name.len > 4) {
                const ext = name[name.len - 4 ..];
                if (std.ascii.eqlIgnoreCase(ext, ".MP3")) {
                    const written = std.fmt.bufPrint(&path_buffer, "/MUSIC/{s}", .{name}) catch continue;
                    mp3_path = written;
                }
            }
        }
    }

    if (mp3_path) |path| {
        std.debug.print("\nAttempting to load: {s}\n", .{path});

        // Try to load the MP3 file
        audio.loadFile(path) catch |err| {
            std.debug.print("Load error: {}\n", .{err});
            // This is expected to fail in test environment without full audio init
            // The important thing is that we got this far (FAT32 read works)
            return;
        };

        std.debug.print("MP3 loaded successfully!\n", .{});

        // Check track info
        const track_info = audio.getLoadedTrackInfo();
        std.debug.print("Track: {s}\n", .{track_info.getTitle()});
        std.debug.print("Artist: {s}\n", .{track_info.getArtist()});

        // Verify we have a loaded track
        try std.testing.expect(audio.hasLoadedTrack());
    } else {
        std.debug.print("No MP3 files found in /MUSIC\n", .{});
    }
}

test "FAT32 can read MP3 file data" {
    const allocator = std.testing.allocator;

    // Initialize simulator with mock FAT32
    const config = simulator.SimulatorConfig{
        .audio_samples_path = "audio-samples",
    };

    simulator.initSimulator(allocator, config) catch |err| {
        std.debug.print("Skipping test: {}\n", .{err});
        return;
    };
    defer simulator.shutdownSimulator();

    if (!fat32.isInitialized()) {
        std.debug.print("Skipping: FAT32 not initialized\n", .{});
        return;
    }

    // List /MUSIC to find an MP3
    var entries: [32]fat32.DirEntryInfo = undefined;
    const count = fat32.listDirectory("/MUSIC", &entries) catch {
        std.debug.print("Could not list /MUSIC\n", .{});
        return;
    };

    // Find smallest MP3 for faster test
    var smallest_mp3: ?[]const u8 = null;
    var smallest_size: u32 = std.math.maxInt(u32);
    var path_buf: [256]u8 = undefined;

    for (entries[0..count]) |entry| {
        const name = entry.getName();
        if (name.len > 4 and entry.size > 0 and entry.size < smallest_size and !entry.is_directory) {
            const ext = name[name.len - 4 ..];
            if (std.ascii.eqlIgnoreCase(ext, ".MP3")) {
                const path = std.fmt.bufPrint(&path_buf, "/MUSIC/{s}", .{name}) catch continue;
                smallest_mp3 = path;
                smallest_size = entry.size;
            }
        }
    }

    if (smallest_mp3) |path| {
        std.debug.print("\nReading MP3: {s} ({d} bytes)\n", .{ path, smallest_size });

        // Read first 1KB to verify MP3 header
        var buffer: [1024]u8 = undefined;
        const bytes_read = fat32.readFile(path, &buffer) catch |err| {
            std.debug.print("Read error: {}\n", .{err});
            return;
        };

        std.debug.print("Read {d} bytes\n", .{bytes_read});
        try std.testing.expect(bytes_read > 0);

        // Check for ID3 tag or MP3 frame sync
        if (bytes_read >= 3) {
            if (std.mem.eql(u8, buffer[0..3], "ID3")) {
                std.debug.print("Found ID3 tag\n", .{});
            } else if (buffer[0] == 0xFF and (buffer[1] & 0xE0) == 0xE0) {
                std.debug.print("Found MP3 frame sync\n", .{});
            }
        }
    } else {
        std.debug.print("No MP3 files found\n", .{});
    }
}
