//! Playlist File Parser
//!
//! Parses M3U and M3U8 playlist files to extract track paths.
//! Supports both simple M3U and extended M3U (EXTM3U) formats.

const std = @import("std");

// ============================================================
// Playlist Entry
// ============================================================

pub const PlaylistEntry = struct {
    /// File path (relative or absolute)
    path: []const u8,
    /// Track title (from EXTINF or filename)
    title: []const u8,
    /// Artist name (from EXTINF if available)
    artist: []const u8,
    /// Duration in seconds (from EXTINF, 0 if unknown)
    duration_secs: u32,

    pub fn init() PlaylistEntry {
        return PlaylistEntry{
            .path = "",
            .title = "",
            .artist = "",
            .duration_secs = 0,
        };
    }
};

// ============================================================
// Playlist
// ============================================================

pub const Playlist = struct {
    /// Playlist name (from file or first comment)
    name: []const u8,
    /// Entries in the playlist
    entries: []PlaylistEntry,
    /// Entry count
    count: usize,
    /// Is extended M3U format
    is_extended: bool,

    /// Maximum entries per playlist
    pub const MAX_ENTRIES: usize = 1000;

    pub fn init() Playlist {
        return Playlist{
            .name = "",
            .entries = &[_]PlaylistEntry{},
            .count = 0,
            .is_extended = false,
        };
    }
};

// ============================================================
// M3U Parser
// ============================================================

pub const M3uParser = struct {
    data: []const u8,
    position: usize,

    /// Parse result with static storage for entries
    pub const ParseResult = struct {
        entries: [Playlist.MAX_ENTRIES]PlaylistEntry,
        count: usize,
        name: []const u8,
        is_extended: bool,
    };

    pub fn init(data: []const u8) M3uParser {
        return M3uParser{
            .data = data,
            .position = 0,
        };
    }

    /// Parse the entire playlist file
    pub fn parse(self: *M3uParser) ParseResult {
        var result = ParseResult{
            .entries = undefined,
            .count = 0,
            .name = "",
            .is_extended = false,
        };

        // Initialize entries
        for (&result.entries) |*entry| {
            entry.* = PlaylistEntry.init();
        }

        // Check for EXTM3U header
        if (self.peekLine()) |first_line| {
            if (std.mem.startsWith(u8, first_line, "#EXTM3U")) {
                result.is_extended = true;
                _ = self.readLine(); // Skip header
            }
        }

        // Parse entries
        var pending_extinf: ?ExtinfData = null;

        while (self.readLine()) |line| {
            // Skip empty lines
            if (line.len == 0) continue;

            if (line[0] == '#') {
                // Comment or directive
                if (std.mem.startsWith(u8, line, "#EXTINF:")) {
                    pending_extinf = parseExtinf(line);
                } else if (std.mem.startsWith(u8, line, "#PLAYLIST:")) {
                    result.name = trimPrefix(line, "#PLAYLIST:");
                }
            } else {
                // File path
                if (result.count < Playlist.MAX_ENTRIES) {
                    var entry = &result.entries[result.count];
                    entry.path = line;

                    if (pending_extinf) |extinf| {
                        entry.duration_secs = extinf.duration;
                        entry.title = extinf.title;
                        entry.artist = extinf.artist;
                        pending_extinf = null;
                    } else {
                        // Extract title from filename
                        entry.title = extractFilename(line);
                    }

                    result.count += 1;
                }
            }
        }

        return result;
    }

    /// Peek at the next line without consuming it
    fn peekLine(self: *M3uParser) ?[]const u8 {
        const saved_pos = self.position;
        const line = self.readLine();
        self.position = saved_pos;
        return line;
    }

    /// Read the next line from the data
    fn readLine(self: *M3uParser) ?[]const u8 {
        if (self.position >= self.data.len) return null;

        const start = self.position;
        var end = start;

        // Find end of line
        while (end < self.data.len and self.data[end] != '\n' and self.data[end] != '\r') {
            end += 1;
        }

        const line = self.data[start..end];

        // Skip line ending
        if (end < self.data.len) {
            if (self.data[end] == '\r') end += 1;
            if (end < self.data.len and self.data[end] == '\n') end += 1;
        }

        self.position = end;
        return line;
    }
};

// ============================================================
// EXTINF Parsing
// ============================================================

const ExtinfData = struct {
    duration: u32,
    title: []const u8,
    artist: []const u8,
};

/// Parse EXTINF line: #EXTINF:duration,Artist - Title or #EXTINF:duration,Title
fn parseExtinf(line: []const u8) ExtinfData {
    var result = ExtinfData{
        .duration = 0,
        .title = "",
        .artist = "",
    };

    // Skip "#EXTINF:"
    const content = trimPrefix(line, "#EXTINF:");
    if (content.len == 0) return result;

    // Find comma separator
    var comma_pos: ?usize = null;
    for (content, 0..) |c, i| {
        if (c == ',') {
            comma_pos = i;
            break;
        }
    }

    // Parse duration
    if (comma_pos) |pos| {
        result.duration = parseUint(content[0..pos]) catch 0;
        if (pos + 1 < content.len) {
            const title_part = content[pos + 1 ..];
            // Check for "Artist - Title" format
            if (findSubstring(title_part, " - ")) |sep_pos| {
                result.artist = title_part[0..sep_pos];
                if (sep_pos + 3 < title_part.len) {
                    result.title = title_part[sep_pos + 3 ..];
                }
            } else {
                result.title = title_part;
            }
        }
    } else {
        result.duration = parseUint(content) catch 0;
    }

    return result;
}

// ============================================================
// PLS Parser
// ============================================================

pub const PlsParser = struct {
    data: []const u8,
    position: usize,

    pub fn init(data: []const u8) PlsParser {
        return PlsParser{
            .data = data,
            .position = 0,
        };
    }

    /// Parse PLS format playlist
    pub fn parse(self: *PlsParser) M3uParser.ParseResult {
        var result = M3uParser.ParseResult{
            .entries = undefined,
            .count = 0,
            .name = "",
            .is_extended = false,
        };

        for (&result.entries) |*entry| {
            entry.* = PlaylistEntry.init();
        }

        // Parse lines looking for File1=, Title1=, Length1=, etc.
        while (self.readLine()) |line| {
            if (line.len == 0) continue;

            if (std.mem.startsWith(u8, line, "File")) {
                // FileN=path
                if (parseIndexedLine(line, "File")) |indexed| {
                    const idx = indexed.index;
                    if (idx > 0 and idx <= Playlist.MAX_ENTRIES) {
                        const entry_idx = idx - 1;
                        if (entry_idx >= result.count) {
                            result.count = entry_idx + 1;
                        }
                        result.entries[entry_idx].path = indexed.value;
                    }
                }
            } else if (std.mem.startsWith(u8, line, "Title")) {
                // TitleN=title
                if (parseIndexedLine(line, "Title")) |indexed| {
                    const idx = indexed.index;
                    if (idx > 0 and idx <= Playlist.MAX_ENTRIES) {
                        result.entries[idx - 1].title = indexed.value;
                    }
                }
            } else if (std.mem.startsWith(u8, line, "Length")) {
                // LengthN=duration
                if (parseIndexedLine(line, "Length")) |indexed| {
                    const idx = indexed.index;
                    if (idx > 0 and idx <= Playlist.MAX_ENTRIES) {
                        result.entries[idx - 1].duration_secs = parseUint(indexed.value) catch 0;
                    }
                }
            }
        }

        return result;
    }

    fn readLine(self: *PlsParser) ?[]const u8 {
        if (self.position >= self.data.len) return null;

        const start = self.position;
        var end = start;

        while (end < self.data.len and self.data[end] != '\n' and self.data[end] != '\r') {
            end += 1;
        }

        const line = self.data[start..end];

        if (end < self.data.len) {
            if (self.data[end] == '\r') end += 1;
            if (end < self.data.len and self.data[end] == '\n') end += 1;
        }

        self.position = end;
        return line;
    }
};

const IndexedLine = struct {
    index: usize,
    value: []const u8,
};

fn parseIndexedLine(line: []const u8, prefix: []const u8) ?IndexedLine {
    if (!std.mem.startsWith(u8, line, prefix)) return null;

    const after_prefix = line[prefix.len..];

    // Find = sign
    var equals_pos: ?usize = null;
    for (after_prefix, 0..) |c, i| {
        if (c == '=') {
            equals_pos = i;
            break;
        }
    }

    if (equals_pos) |pos| {
        const index = parseUint(after_prefix[0..pos]) catch return null;
        if (pos + 1 < after_prefix.len) {
            return IndexedLine{
                .index = index,
                .value = after_prefix[pos + 1 ..],
            };
        }
    }

    return null;
}

// ============================================================
// Utility Functions
// ============================================================

/// Detect playlist format from content
pub fn detectFormat(data: []const u8) PlaylistFormat {
    if (data.len < 4) return .unknown;

    if (std.mem.startsWith(u8, data, "#EXTM3U") or
        std.mem.startsWith(u8, data, "#"))
    {
        return .m3u;
    }

    if (std.mem.startsWith(u8, data, "[playlist]")) {
        return .pls;
    }

    // Check if it looks like a path list
    if (data[0] != '#' and data[0] != '[') {
        // Might be simple M3U
        return .m3u;
    }

    return .unknown;
}

pub const PlaylistFormat = enum {
    m3u,
    pls,
    unknown,
};

/// Check if file extension is a playlist
pub fn isPlaylistExtension(filename: []const u8) bool {
    const lower = toLowerExtension(filename);
    return std.mem.eql(u8, lower, ".m3u") or
        std.mem.eql(u8, lower, ".m3u8") or
        std.mem.eql(u8, lower, ".pls");
}

fn toLowerExtension(filename: []const u8) []const u8 {
    // Find last dot
    var last_dot: ?usize = null;
    for (filename, 0..) |c, i| {
        if (c == '.') last_dot = i;
    }

    if (last_dot) |dot| {
        return filename[dot..];
    }
    return "";
}

fn trimPrefix(str: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.startsWith(u8, str, prefix)) {
        return str[prefix.len..];
    }
    return str;
}

fn extractFilename(path: []const u8) []const u8 {
    // Find last path separator
    var last_sep: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') last_sep = i;
    }

    const filename = if (last_sep) |sep|
        path[sep + 1 ..]
    else
        path;

    // Remove extension
    var last_dot: ?usize = null;
    for (filename, 0..) |c, i| {
        if (c == '.') last_dot = i;
    }

    if (last_dot) |dot| {
        return filename[0..dot];
    }
    return filename;
}

fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    if (needle.len == 0) return 0;

    for (0..haystack.len - needle.len + 1) |i| {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            return i;
        }
    }
    return null;
}

fn parseUint(str: []const u8) !u32 {
    var result: u32 = 0;
    for (str) |c| {
        if (c >= '0' and c <= '9') {
            result = result * 10 + (c - '0');
        } else if (c == '-') {
            // Negative duration means unknown
            return 0;
        } else {
            break; // Stop at non-digit
        }
    }
    return result;
}

// ============================================================
// Tests
// ============================================================

test "parse simple m3u" {
    const data =
        \\/music/song1.mp3
        \\/music/song2.mp3
        \\/music/song3.mp3
    ;

    var parser = M3uParser.init(data);
    const result = parser.parse();

    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqualStrings("/music/song1.mp3", result.entries[0].path);
    try std.testing.expectEqualStrings("/music/song2.mp3", result.entries[1].path);
    try std.testing.expectEqualStrings("/music/song3.mp3", result.entries[2].path);
}

test "parse extended m3u" {
    const data =
        \\#EXTM3U
        \\#PLAYLIST:My Playlist
        \\#EXTINF:180,Artist - Song Title
        \\/music/song.mp3
    ;

    var parser = M3uParser.init(data);
    const result = parser.parse();

    try std.testing.expect(result.is_extended);
    try std.testing.expectEqualStrings("My Playlist", result.name);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(@as(u32, 180), result.entries[0].duration_secs);
    try std.testing.expectEqualStrings("Artist", result.entries[0].artist);
    try std.testing.expectEqualStrings("Song Title", result.entries[0].title);
}

test "parse extinf without artist" {
    const data =
        \\#EXTM3U
        \\#EXTINF:240,Just a Title
        \\/music/song.mp3
    ;

    var parser = M3uParser.init(data);
    const result = parser.parse();

    try std.testing.expectEqualStrings("Just a Title", result.entries[0].title);
    try std.testing.expectEqualStrings("", result.entries[0].artist);
}

test "extract filename" {
    try std.testing.expectEqualStrings("song", extractFilename("/music/song.mp3"));
    try std.testing.expectEqualStrings("track", extractFilename("C:\\Music\\track.flac"));
    try std.testing.expectEqualStrings("file", extractFilename("file.wav"));
    try std.testing.expectEqualStrings("noext", extractFilename("noext"));
}

test "detect format" {
    try std.testing.expectEqual(PlaylistFormat.m3u, detectFormat("#EXTM3U\n"));
    try std.testing.expectEqual(PlaylistFormat.pls, detectFormat("[playlist]\n"));
    try std.testing.expectEqual(PlaylistFormat.m3u, detectFormat("/path/to/file.mp3\n"));
}

test "is playlist extension" {
    try std.testing.expect(isPlaylistExtension("playlist.m3u"));
    try std.testing.expect(isPlaylistExtension("playlist.M3U8"));
    try std.testing.expect(isPlaylistExtension("playlist.pls"));
    try std.testing.expect(!isPlaylistExtension("song.mp3"));
}

test "parse pls format" {
    const data =
        \\[playlist]
        \\NumberOfEntries=2
        \\File1=/music/song1.mp3
        \\Title1=First Song
        \\Length1=180
        \\File2=/music/song2.mp3
        \\Title2=Second Song
        \\Length2=240
    ;

    var parser = PlsParser.init(data);
    const result = parser.parse();

    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("/music/song1.mp3", result.entries[0].path);
    try std.testing.expectEqualStrings("First Song", result.entries[0].title);
    try std.testing.expectEqual(@as(u32, 180), result.entries[0].duration_secs);
}
