//! iTunesDB Integration Tests
//!
//! Tests the iTunesDB parser against a generated sample database
//! that matches the real iTunes binary format.

const std = @import("std");
const itunesdb = @import("itunesdb.zig");
const ITunesDB = itunesdb.ITunesDB;
const Magic = itunesdb.Magic;

// ============================================================
// Test Data Builder
// ============================================================

const TestDbBuilder = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) TestDbBuilder {
        return .{
            .buffer = .{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *TestDbBuilder) void {
        self.buffer.deinit(self.allocator);
    }

    fn appendSlice(self: *TestDbBuilder, slice: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, slice);
    }

    fn append(self: *TestDbBuilder, byte: u8) !void {
        try self.buffer.append(self.allocator, byte);
    }

    fn appendNTimes(self: *TestDbBuilder, byte: u8, count: usize) !void {
        try self.buffer.appendNTimes(self.allocator, byte, count);
    }

    fn appendU16(self: *TestDbBuilder, value: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .little);
        try self.appendSlice(&bytes);
    }

    fn appendU32(self: *TestDbBuilder, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.appendSlice(&bytes);
    }

    fn appendI32(self: *TestDbBuilder, value: i32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, value, .little);
        try self.appendSlice(&bytes);
    }

    fn appendU64(self: *TestDbBuilder, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.appendSlice(&bytes);
    }

    fn appendF32(self: *TestDbBuilder, value: f32) !void {
        const bytes: [4]u8 = @bitCast(value);
        try self.appendSlice(&bytes);
    }

    fn toOwnedSlice(self: *TestDbBuilder) ![]align(4) u8 {
        const data = try self.allocator.alignedAlloc(u8, .@"4", self.buffer.items.len);
        @memcpy(data, self.buffer.items);
        return data;
    }
};

/// Build a minimal valid iTunesDB for testing
fn buildTestDatabase(allocator: std.mem.Allocator) ![]align(4) u8 {
    var builder = TestDbBuilder.init(allocator);
    defer builder.deinit();

    // Calculate sizes upfront
    const mhod_title1_size: u32 = 24 + 16 + 26; // header + string info + "Test Song One" UTF-16LE
    const mhod_artist1_size: u32 = 24 + 16 + 26; // "Test Artist A"
    const mhod_album1_size: u32 = 24 + 16 + 24; // "Test Album X"
    const mhod_path1_size: u32 = 24 + 16 + 66; // path (33 chars)

    const mhod_title2_size: u32 = 24 + 16 + 26; // "Test Song Two"
    const mhod_artist2_size: u32 = 24 + 16 + 26; // "Test Artist B"
    const mhod_album2_size: u32 = 24 + 16 + 24; // "Test Album Y"
    const mhod_path2_size: u32 = 24 + 16 + 66; // path (33 chars)

    // TrackItemHeader is 247 bytes (matches @sizeOf(TrackItemHeader))
    const mhit_header_size: u32 = 247;
    const mhit1_size: u32 = mhit_header_size + mhod_title1_size + mhod_artist1_size + mhod_album1_size + mhod_path1_size;
    const mhit2_size: u32 = mhit_header_size + mhod_title2_size + mhod_artist2_size + mhod_album2_size + mhod_path2_size;

    const mhlt_size: u32 = 12 + mhit1_size + mhit2_size;
    const mhsd_tracks_size: u32 = 16 + mhlt_size; // mhsd header is 16 bytes

    // Playlist sizes
    const mhod_pl_name_size: u32 = 24 + 16 + 32; // "My Test Playlist"
    const mhip1_size: u32 = 40;
    const mhip2_size: u32 = 40;
    const mhyp_size: u32 = 48 + mhod_pl_name_size + mhip1_size + mhip2_size;
    const mhlp_size: u32 = 12 + mhyp_size;
    const mhsd_playlists_size: u32 = 16 + mhlp_size; // mhsd header is 16 bytes

    const mhbd_header_size: u32 = 104;
    const total_size: u32 = mhbd_header_size + mhsd_tracks_size + mhsd_playlists_size;

    // ========================================
    // mhbd - Database Header
    // ========================================
    try builder.appendSlice(&Magic.DATABASE);
    try builder.appendU32(mhbd_header_size);
    try builder.appendU32(total_size);
    try builder.appendU32(1); // unknown1
    try builder.appendU32(0x19); // version
    try builder.appendU32(2); // child_count
    try builder.appendU64(0x1234567890ABCDEF); // database_id
    try builder.appendU16(0);
    try builder.appendU16(0);
    try builder.appendU64(0);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendSlice("en");
    try builder.appendU64(0xFEDCBA0987654321);
    try builder.appendU32(0);
    try builder.appendU32(0);
    // Pad to header_size
    const current = builder.buffer.items.len;
    try builder.appendNTimes(0, mhbd_header_size - current);

    // ========================================
    // mhsd - Track List Data Set
    // ========================================
    try builder.appendSlice(&Magic.DATA_SET);
    try builder.appendU32(16); // mhsd header size
    try builder.appendU32(mhsd_tracks_size);
    try builder.appendU32(1); // type = track_list

    // ========================================
    // mhlt - Track List
    // ========================================
    try builder.appendSlice(&Magic.TRACK_LIST);
    try builder.appendU32(12);
    try builder.appendU32(2); // track_count

    // ========================================
    // mhit - Track 1
    // ========================================
    try writeMhit(&builder, .{
        .unique_id = 1001,
        .duration_ms = 180000,
        .track_number = 1,
        .year = 2020,
        .rating = 80,
        .play_count = 42,
        .bitrate = 256,
        .sample_rate = 44100,
        .file_size = 5 * 1024 * 1024,
        .string_count = 4,
        .total_size = mhit1_size,
    });

    try writeMhodString(&builder, .title, "Test Song One");
    try writeMhodString(&builder, .artist, "Test Artist A");
    try writeMhodString(&builder, .album, "Test Album X");
    try writeMhodString(&builder, .location, ":iPod_Control:Music:F00:TEST1.mp3");

    // ========================================
    // mhit - Track 2
    // ========================================
    try writeMhit(&builder, .{
        .unique_id = 1002,
        .duration_ms = 240000,
        .track_number = 2,
        .year = 2021,
        .rating = 60,
        .play_count = 10,
        .bitrate = 320,
        .sample_rate = 48000,
        .file_size = 8 * 1024 * 1024,
        .string_count = 4,
        .total_size = mhit2_size,
    });

    try writeMhodString(&builder, .title, "Test Song Two");
    try writeMhodString(&builder, .artist, "Test Artist B");
    try writeMhodString(&builder, .album, "Test Album Y");
    try writeMhodString(&builder, .location, ":iPod_Control:Music:F01:TEST2.mp3");

    // ========================================
    // mhsd - Playlist Data Set
    // ========================================
    try builder.appendSlice(&Magic.DATA_SET);
    try builder.appendU32(16); // mhsd header size
    try builder.appendU32(mhsd_playlists_size);
    try builder.appendU32(2); // type = playlist_list

    // ========================================
    // mhlp - Playlist List
    // ========================================
    try builder.appendSlice(&Magic.PLAYLIST_LIST);
    try builder.appendU32(12);
    try builder.appendU32(1); // playlist_count

    // ========================================
    // mhyp - Playlist
    // ========================================
    try builder.appendSlice(&Magic.PLAYLIST);
    try builder.appendU32(48);
    try builder.appendU32(mhyp_size);
    try builder.appendU32(1); // string_count
    try builder.appendU32(2); // item_count
    try builder.append(0); // is_master
    try builder.appendNTimes(0, 3);
    try builder.appendU32(0);
    try builder.appendU64(0x1111222233334444);
    try builder.appendU32(0);
    try builder.appendU16(0);
    try builder.appendU16(0);
    try builder.appendU32(0);

    try writeMhodString(&builder, .title, "My Test Playlist");

    // mhip - Playlist Items
    try writeMhip(&builder, 1001);
    try writeMhip(&builder, 1002);

    return try builder.toOwnedSlice();
}

const MhitParams = struct {
    unique_id: u32,
    duration_ms: u32,
    track_number: u32,
    year: u32,
    rating: u8,
    play_count: u32,
    bitrate: u32,
    sample_rate: u32,
    file_size: u32,
    string_count: u32,
    total_size: u32,
};

fn writeMhit(builder: *TestDbBuilder, params: MhitParams) !void {
    try builder.appendSlice(&Magic.TRACK_ITEM);
    try builder.appendU32(247); // header_size = @sizeOf(TrackItemHeader)
    try builder.appendU32(params.total_size);
    try builder.appendU32(params.string_count);
    try builder.appendU32(params.unique_id);
    try builder.appendU32(1); // visible
    try builder.appendU32(0x4D503320); // MP3
    try builder.append(0); // vbr
    try builder.append(0); // compilation
    try builder.append(params.rating);
    try builder.appendU32(0); // last_modified (no padding needed - struct is align(1))
    try builder.appendU32(params.file_size);
    try builder.appendU32(params.duration_ms);
    try builder.appendU32(params.track_number);
    try builder.appendU32(10);
    try builder.appendU32(params.year);
    try builder.appendU32(params.bitrate);
    try builder.appendU32(params.sample_rate << 16);
    try builder.appendI32(0);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendU32(params.play_count);
    try builder.appendU32(params.play_count);
    try builder.appendU32(0); // last_played
    try builder.appendU32(1);
    try builder.appendU32(1);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendU64(params.unique_id);
    try builder.append(1);
    try builder.append(0);
    try builder.appendU16(0);
    try builder.appendU16(0);
    try builder.appendU16(0);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendF32(@floatFromInt(params.sample_rate));
    try builder.appendU32(0);
    try builder.appendU16(0);
    try builder.appendU16(0);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.append(0);
    try builder.append(0);
    try builder.append(0);
    try builder.append(0);
    try builder.appendU64(0);
    try builder.append(0);
    try builder.append(0);
    try builder.append(0);
    try builder.append(0);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendU64(0);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendU32(1);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendNTimes(0, 16);
    try builder.appendU32(0);
    try builder.appendU32(0);
    try builder.appendU16(0);
    try builder.appendU16(0);
}

fn writeMhodString(builder: *TestDbBuilder, mhod_type: itunesdb.MhodType, str: []const u8) !void {
    // Convert to UTF-16LE
    var utf16_buf: [256]u8 = undefined;
    var utf16_len: usize = 0;
    for (str) |c| {
        utf16_buf[utf16_len] = c;
        utf16_buf[utf16_len + 1] = 0;
        utf16_len += 2;
    }

    const total_size: u32 = @intCast(24 + 16 + utf16_len);

    try builder.appendSlice(&Magic.DATA_OBJECT);
    try builder.appendU32(24);
    try builder.appendU32(total_size);
    try builder.appendU32(@intFromEnum(mhod_type));
    try builder.appendU32(0);
    try builder.appendU32(0);

    // String info
    try builder.appendU32(0);
    try builder.appendU32(@intCast(utf16_len));
    try builder.appendU32(0);
    try builder.appendU32(1); // UTF-16LE

    try builder.appendSlice(utf16_buf[0..utf16_len]);
}

fn writeMhip(builder: *TestDbBuilder, track_id: u32) !void {
    try builder.appendSlice(&Magic.PLAYLIST_ITEM);
    try builder.appendU32(40); // header_size = 40 bytes (actual struct size)
    try builder.appendU32(40); // total_size = 40 bytes
    try builder.appendU32(0);  // unknown1
    try builder.appendU32(0);  // string_count
    try builder.appendU32(0);  // podcast_group_flag
    try builder.appendU32(0);  // group_id
    try builder.appendU32(track_id);
    try builder.appendU32(0);  // timestamp
    try builder.appendU32(0);  // podcast_group_ref
}

// ============================================================
// Integration Tests
// ============================================================

test "verify test database structure" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    defer allocator.free(data);

    // Verify mhbd at offset 0
    try std.testing.expectEqualSlices(u8, "mhbd", data[0..4]);

    // Verify mhsd at offset 104 (mhbd_header_size)
    try std.testing.expectEqualSlices(u8, "mhsd", data[104..108]);

    // mhsd header_size should be 16 (at offset 108-111)
    const mhsd_header_size = std.mem.readInt(u32, data[108..112], .little);
    try std.testing.expectEqual(@as(u32, 16), mhsd_header_size);

    // Verify mhlt at offset 104 + 16 = 120
    try std.testing.expectEqualSlices(u8, "mhlt", data[120..124]);

    // mhlt header_size should be 12 (at offset 124-127)
    const mhlt_header_size = std.mem.readInt(u32, data[124..128], .little);
    try std.testing.expectEqual(@as(u32, 12), mhlt_header_size);

    // Verify mhit at offset 120 + 12 = 132
    try std.testing.expectEqualSlices(u8, "mhit", data[132..136]);

    // Verify mhit header_size should be 247 (at offset 136-139)
    const mhit_header_size = std.mem.readInt(u32, data[136..140], .little);
    try std.testing.expectEqual(@as(u32, 247), mhit_header_size);

    // Read total_size at offset 140-143
    const mhit1_total_size = std.mem.readInt(u32, data[140..144], .little);

    // Calculate expected size
    const mhod_title1_size: u32 = 24 + 16 + 26;
    const mhod_artist1_size: u32 = 24 + 16 + 26;
    const mhod_album1_size: u32 = 24 + 16 + 24;
    const mhod_path1_size: u32 = 24 + 16 + 66; // 33 chars
    const expected_mhit1_size = 247 + mhod_title1_size + mhod_artist1_size + mhod_album1_size + mhod_path1_size;
    try std.testing.expectEqual(expected_mhit1_size, mhit1_total_size);

    // Verify second mhit starts at correct offset (132 + mhit1_total_size)
    const mhit2_offset = 132 + mhit1_total_size;
    try std.testing.expectEqualSlices(u8, "mhit", data[mhit2_offset .. mhit2_offset + 4]);
}

test "writeMhit byte count" {
    const allocator = std.testing.allocator;
    var builder = TestDbBuilder.init(allocator);
    defer builder.deinit();

    const start = builder.buffer.items.len;
    try writeMhit(&builder, .{
        .unique_id = 1,
        .duration_ms = 1000,
        .track_number = 1,
        .year = 2020,
        .rating = 80,
        .play_count = 0,
        .bitrate = 256,
        .sample_rate = 44100,
        .file_size = 1000,
        .string_count = 0,
        .total_size = 247,
    });
    const bytes_written = builder.buffer.items.len - start;
    try std.testing.expectEqual(@as(usize, 247), bytes_written);
}

test "writeMhodString byte count" {
    const allocator = std.testing.allocator;

    // Test each exact string used in mhit1
    {
        var builder = TestDbBuilder.init(allocator);
        defer builder.deinit();
        const start = builder.buffer.items.len;
        try writeMhodString(&builder, itunesdb.MhodType.title, "Test Song One");
        const bytes_written = builder.buffer.items.len - start;
        // 13 chars * 2 = 26; 24 + 16 + 26 = 66
        try std.testing.expectEqual(@as(usize, 66), bytes_written);
    }
    {
        var builder = TestDbBuilder.init(allocator);
        defer builder.deinit();
        const start = builder.buffer.items.len;
        try writeMhodString(&builder, itunesdb.MhodType.artist, "Test Artist A");
        const bytes_written = builder.buffer.items.len - start;
        // 13 chars * 2 = 26; 24 + 16 + 26 = 66
        try std.testing.expectEqual(@as(usize, 66), bytes_written);
    }
    {
        var builder = TestDbBuilder.init(allocator);
        defer builder.deinit();
        const start = builder.buffer.items.len;
        try writeMhodString(&builder, itunesdb.MhodType.album, "Test Album X");
        const bytes_written = builder.buffer.items.len - start;
        // 12 chars * 2 = 24; 24 + 16 + 24 = 64
        try std.testing.expectEqual(@as(usize, 64), bytes_written);
    }
    {
        var builder = TestDbBuilder.init(allocator);
        defer builder.deinit();
        const start = builder.buffer.items.len;
        try writeMhodString(&builder, itunesdb.MhodType.location, ":iPod_Control:Music:F00:TEST1.mp3");
        const bytes_written = builder.buffer.items.len - start;
        // 33 chars * 2 = 66; 24 + 16 + 66 = 106
        try std.testing.expectEqual(@as(usize, 106), bytes_written);
    }
}

test "complete mhit1 with mhods byte count" {
    const allocator = std.testing.allocator;
    var builder = TestDbBuilder.init(allocator);
    defer builder.deinit();

    const mhod_title1_size: u32 = 24 + 16 + 26;
    const mhod_artist1_size: u32 = 24 + 16 + 26;
    const mhod_album1_size: u32 = 24 + 16 + 24;
    const mhod_path1_size: u32 = 24 + 16 + 66; // 33 chars
    const mhit_header_size: u32 = 247;
    const expected_total = mhit_header_size + mhod_title1_size + mhod_artist1_size + mhod_album1_size + mhod_path1_size;

    const start = builder.buffer.items.len;
    try writeMhit(&builder, .{
        .unique_id = 1001,
        .duration_ms = 180000,
        .track_number = 1,
        .year = 2020,
        .rating = 80,
        .play_count = 42,
        .bitrate = 256,
        .sample_rate = 44100,
        .file_size = 5 * 1024 * 1024,
        .string_count = 4,
        .total_size = expected_total,
    });
    try writeMhodString(&builder, itunesdb.MhodType.title, "Test Song One");
    try writeMhodString(&builder, itunesdb.MhodType.artist, "Test Artist A");
    try writeMhodString(&builder, itunesdb.MhodType.album, "Test Album X");
    try writeMhodString(&builder, itunesdb.MhodType.location, ":iPod_Control:Music:F00:TEST1.mp3");
    const bytes_written = builder.buffer.items.len - start;
    try std.testing.expectEqual(@as(usize, expected_total), bytes_written);
}

test "parse test database - track count" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    // Note: db.deinit() will free data, so don't defer free here

    var db = try ITunesDB.openFromData(allocator, data);
    defer db.deinit();

    try std.testing.expectEqual(@as(usize, 2), db.getTrackCount());
}

test "parse test database - track 1 metadata" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    // db.deinit() frees data, so no defer here

    var db = try ITunesDB.openFromData(allocator, data);
    defer db.deinit();

    const track = db.getTrack(1001) orelse return error.TrackNotFound;

    try std.testing.expectEqual(@as(u32, 1001), track.id);
    try std.testing.expectEqual(@as(u32, 180000), track.duration_ms);
    try std.testing.expectEqual(@as(u32, 1), track.track_number);
    try std.testing.expectEqual(@as(u32, 2020), track.year);
    try std.testing.expectEqual(@as(u8, 80), track.rating);
    try std.testing.expectEqual(@as(u32, 42), track.play_count);
    try std.testing.expectEqual(@as(u32, 256), track.bitrate);
    try std.testing.expectEqual(@as(u32, 44100), track.sample_rate);

    try std.testing.expectEqualStrings("Test Song One", track.title orelse "");
    try std.testing.expectEqualStrings("Test Artist A", track.artist orelse "");
    try std.testing.expectEqualStrings("Test Album X", track.album orelse "");
}

test "parse test database - track 2 metadata" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    // db.deinit() frees data, so no defer here

    var db = try ITunesDB.openFromData(allocator, data);
    defer db.deinit();

    const track = db.getTrack(1002) orelse return error.TrackNotFound;

    try std.testing.expectEqual(@as(u32, 1002), track.id);
    try std.testing.expectEqual(@as(u32, 240000), track.duration_ms);
    try std.testing.expectEqual(@as(u8, 60), track.rating);
    try std.testing.expectEqual(@as(u32, 10), track.play_count);

    try std.testing.expectEqualStrings("Test Song Two", track.title orelse "");
    try std.testing.expectEqualStrings("Test Artist B", track.artist orelse "");
    try std.testing.expectEqualStrings("Test Album Y", track.album orelse "");
}

test "parse test database - playlist" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    // db.deinit() frees data, so no defer here

    var db = try ITunesDB.openFromData(allocator, data);
    defer db.deinit();

    try std.testing.expectEqual(@as(usize, 1), db.getPlaylistCount());

    const playlist = db.getPlaylist(0) orelse return error.PlaylistNotFound;
    try std.testing.expectEqualStrings("My Test Playlist", playlist.name orelse "");
    try std.testing.expectEqual(@as(usize, 2), playlist.track_ids.len);
    try std.testing.expectEqual(@as(u32, 1001), playlist.track_ids[0]);
    try std.testing.expectEqual(@as(u32, 1002), playlist.track_ids[1]);
}

test "track iterator" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    // db.deinit() frees data, so no defer here

    var db = try ITunesDB.openFromData(allocator, data);
    defer db.deinit();

    var iter = db.iterateTracks();
    var count: usize = 0;

    while (iter.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "write-back play count" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    // db.deinit() frees data, so no defer here

    var db = try ITunesDB.openFromData(allocator, data);
    defer db.deinit();

    const track_before = db.getTrack(1001) orelse return error.TrackNotFound;
    try std.testing.expectEqual(@as(u32, 42), track_before.play_count);

    try db.incrementPlayCount(1001);

    const track_after = db.getTrack(1001) orelse return error.TrackNotFound;
    try std.testing.expectEqual(@as(u32, 43), track_after.play_count);
    try std.testing.expect(db.isDirty());
}

test "write-back rating" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    // db.deinit() frees data, so no defer here

    var db = try ITunesDB.openFromData(allocator, data);
    defer db.deinit();

    try db.setStarRating(1002, 5);

    const track = db.getTrack(1002) orelse return error.TrackNotFound;
    try std.testing.expectEqual(@as(u8, 100), track.rating);
    try std.testing.expectEqual(@as(u8, 5), track.starRating());
}

test "write-back last played" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    // db.deinit() frees data, so no defer here

    var db = try ITunesDB.openFromData(allocator, data);
    defer db.deinit();

    const timestamp: u32 = 3800000000;
    try db.setLastPlayed(1001, timestamp);

    const track = db.getTrack(1001) orelse return error.TrackNotFound;
    try std.testing.expectEqual(timestamp, track.last_played);
}

test "database version and id" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    // db.deinit() frees data, so no defer here

    var db = try ITunesDB.openFromData(allocator, data);
    defer db.deinit();

    try std.testing.expectEqual(@as(u32, 0x19), db.version);
    try std.testing.expectEqual(@as(u64, 0x1234567890ABCDEF), db.database_id);
}

test "star rating conversion" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    // db.deinit() frees data, so no defer here

    var db = try ITunesDB.openFromData(allocator, data);
    defer db.deinit();

    const track = db.getTrack(1001) orelse return error.TrackNotFound;
    try std.testing.expectEqual(@as(u8, 4), track.starRating());
}

test "mac timestamp conversion" {
    const unix_timestamp: i64 = 1704067200;
    const mac_timestamp = ITunesDB.unixToMacTimestamp(unix_timestamp);
    try std.testing.expectEqual(@as(u32, 3786912000), mac_timestamp);

    const back_to_unix = ITunesDB.macToUnixTimestamp(mac_timestamp);
    try std.testing.expectEqual(unix_timestamp, back_to_unix);
}

test "track not found error" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    // db.deinit() frees data, so no defer here

    var db = try ITunesDB.openFromData(allocator, data);
    defer db.deinit();

    try std.testing.expectEqual(@as(?*const itunesdb.Track, null), db.getTrack(9999));
    try std.testing.expectError(error.TrackNotFound, db.incrementPlayCount(9999));
}

test "file path location format" {
    const allocator = std.testing.allocator;
    const data = try buildTestDatabase(allocator);
    // db.deinit() frees data, so no defer here

    var db = try ITunesDB.openFromData(allocator, data);
    defer db.deinit();

    const track = db.getTrack(1001) orelse return error.TrackNotFound;
    try std.testing.expectEqualStrings(":iPod_Control:Music:F00:TEST1.mp3", track.location orelse "");

    const path = try track.getPath(allocator);
    defer if (path) |p| allocator.free(p);
    try std.testing.expectEqualStrings("/iPod_Control/Music/F00/TEST1.mp3", path orelse "");
}
