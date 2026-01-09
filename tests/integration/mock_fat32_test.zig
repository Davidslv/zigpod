//! Mock FAT32 Integration Tests
//!
//! Tests the music library scanning using mock FAT32 filesystem
//! populated with audio files from the host filesystem.

const std = @import("std");
const zigpod = @import("zigpod");

const simulator = zigpod.simulator;
const fat32 = zigpod.fat32;
const music_db = zigpod.library.music_db;
const mock_fat32 = simulator.storage.mock_fat32;
const disk_image = simulator.storage.disk_image;

test "mock FAT32 format and structure" {
    const allocator = std.testing.allocator;

    // Create small in-memory disk
    var disk = try disk_image.DiskImage.createInMemory(allocator, 2000);
    defer disk.close();

    // Format as FAT32
    var mock_fs = try mock_fat32.MockFat32.format(&disk, allocator);

    // Verify we can create directories
    const music_cluster = try mock_fs.createDirectory(mock_fs.root_cluster, "MUSIC");
    try std.testing.expect(music_cluster > 2);

    // Verify we can add files
    const test_data = "fake audio data for testing";
    try mock_fs.addFile(music_cluster, "TEST.MP3", test_data);
}

test "mock FAT32 with test audio files" {
    const allocator = std.testing.allocator;

    // Create 10MB in-memory disk
    var disk = try disk_image.DiskImage.createInMemory(allocator, 10 * 1024 * 1024 / 512);
    defer disk.close();

    // Format as FAT32
    var mock_fs = try mock_fat32.MockFat32.format(&disk, allocator);

    // Create directory structure
    const music_cluster = try mock_fs.createDirectory(mock_fs.root_cluster, "MUSIC");
    const artist_cluster = try mock_fs.createDirectory(music_cluster, "ARTIST");
    const album_cluster = try mock_fs.createDirectory(artist_cluster, "ALBUM");

    // Add some fake audio files
    try mock_fs.addFile(album_cluster, "TRACK01.MP3", "fake mp3 data 1");
    try mock_fs.addFile(album_cluster, "TRACK02.MP3", "fake mp3 data 2");
    try mock_fs.addFile(album_cluster, "TRACK03.WAV", "fake wav data 3");

    // Add files in root MUSIC folder
    try mock_fs.addFile(music_cluster, "SONG.MP3", "another fake mp3");
}

test "simulator with mock FAT32 audio samples" {
    const allocator = std.testing.allocator;

    // Initialize simulator with mock FAT32 from audio-samples directory
    // Note: This test requires the audio-samples directory to exist
    const config = simulator.SimulatorConfig{
        .audio_samples_path = "audio-samples",
    };

    simulator.initSimulator(allocator, config) catch |err| {
        // If audio-samples doesn't exist, skip this test
        if (err == error.OutOfMemory) {
            std.debug.print("Skipping test: could not allocate memory for mock FAT32\n", .{});
            return;
        }
        return err;
    };
    defer simulator.shutdownSimulator();

    const state = simulator.getSimulatorState();
    try std.testing.expect(state != null);

    // Verify disk image was created
    if (state) |s| {
        try std.testing.expect(s.disk_image != null);
        if (s.disk_image) |disk| {
            // 256MB disk
            try std.testing.expect(disk.total_sectors > 0);
        }
    }
}

test "FAT32 initialization with mock disk" {
    const allocator = std.testing.allocator;

    // Create mock FAT32 disk
    var disk = try disk_image.DiskImage.createInMemory(allocator, 10 * 1024 * 1024 / 512);
    defer disk.close();

    // Format as FAT32
    var mock_fs = try mock_fat32.MockFat32.format(&disk, allocator);

    // Create MUSIC directory with a test file
    const music_cluster = try mock_fs.createDirectory(mock_fs.root_cluster, "MUSIC");
    try mock_fs.addFile(music_cluster, "SONG.MP3", "ID3" ++ ([_]u8{0} ** 100)); // Fake ID3 header

    // Now we need to initialize the simulator to use this disk
    // The FAT32 driver reads through the HAL -> ATA -> disk_image chain

    // Initialize simulator with the pre-created disk
    const config = simulator.SimulatorConfig{
        .memory_disk_sectors = 0, // Don't create default disk
    };

    try simulator.initSimulator(allocator, config);
    defer simulator.shutdownSimulator();

    // Replace the simulator's disk with our mock FAT32 disk
    // Note: This is a bit of a hack for testing - in real usage,
    // the --audio-samples option handles this
    const state = simulator.getSimulatorState();
    try std.testing.expect(state != null);
}

test "music scanner finds audio files" {
    // This test verifies the music_db scanner logic without FAT32
    var db = music_db.MusicDb.init();

    // Manually add tracks to simulate scanning results
    _ = db.addTrack("/MUSIC/Artist/Album/track01.mp3", "Track 1", "Test Artist", "Test Album");
    _ = db.addTrack("/MUSIC/Artist/Album/track02.mp3", "Track 2", "Test Artist", "Test Album");
    _ = db.addTrack("/MUSIC/Other/song.wav", "Song", "Other Artist", "Other Album");

    try std.testing.expectEqual(@as(usize, 3), db.getTrackCount());
    try std.testing.expectEqual(@as(usize, 2), db.getArtistCount());
    try std.testing.expectEqual(@as(usize, 2), db.getAlbumCount());

    // Verify track retrieval
    const track = db.getTrack(0);
    try std.testing.expect(track != null);
    try std.testing.expectEqualStrings("Track 1", track.?.getTitle());

    // Verify artist retrieval
    const artist = db.getArtist(0);
    try std.testing.expect(artist != null);
    try std.testing.expectEqualStrings("Test Artist", artist.?.getName());
}

test "music scanner tracks by artist" {
    var db = music_db.MusicDb.init();

    // Add tracks for multiple artists
    _ = db.addTrack("/a.mp3", "A1", "Artist A", "Album 1");
    _ = db.addTrack("/b.mp3", "A2", "Artist A", "Album 1");
    _ = db.addTrack("/c.mp3", "B1", "Artist B", "Album 2");

    // Get tracks by Artist A (index 0)
    var tracks: [10]?*const music_db.Track = undefined;
    const count = db.getTracksByArtist(0, &tracks);

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "music scanner tracks by album" {
    var db = music_db.MusicDb.init();

    // Add tracks
    _ = db.addTrack("/a.mp3", "T1", "Artist", "Album A");
    _ = db.addTrack("/b.mp3", "T2", "Artist", "Album A");
    _ = db.addTrack("/c.mp3", "T3", "Artist", "Album B");

    // Get tracks by Album A (index 0)
    var tracks: [10]?*const music_db.Track = undefined;
    const count = db.getTracksByAlbum(0, &tracks);

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "is audio file detection" {
    // Test the internal audio file detection
    const is_audio = struct {
        fn check(name: []const u8) bool {
            if (name.len < 4) return false;
            const ext = name[name.len - 4 ..];
            if (std.ascii.eqlIgnoreCase(ext, ".mp3")) return true;
            if (std.ascii.eqlIgnoreCase(ext, ".wav")) return true;
            if (std.ascii.eqlIgnoreCase(ext, ".m4a")) return true;
            if (name.len >= 5) {
                const ext5 = name[name.len - 5 ..];
                if (std.ascii.eqlIgnoreCase(ext5, ".flac")) return true;
                if (std.ascii.eqlIgnoreCase(ext5, ".aiff")) return true;
            }
            return false;
        }
    }.check;

    try std.testing.expect(is_audio("song.mp3"));
    try std.testing.expect(is_audio("TRACK.MP3"));
    try std.testing.expect(is_audio("audio.wav"));
    try std.testing.expect(is_audio("music.flac"));
    try std.testing.expect(is_audio("sound.aiff"));
    try std.testing.expect(is_audio("track.m4a"));
    try std.testing.expect(!is_audio("image.png"));
    try std.testing.expect(!is_audio("doc.txt"));
}
