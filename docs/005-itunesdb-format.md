# iTunesDB Format Documentation

This document describes the iTunesDB binary format used by iPod devices and the ZigPod implementation.

## Overview

The iTunesDB is Apple's proprietary binary database format for storing music library metadata on iPod devices. It contains:

- Track metadata (title, artist, album, ratings, play counts)
- Playlist definitions and track references
- Playback statistics (last played, skip counts)

**Location**: `/iPod_Control/iTunes/iTunesDB`

## Binary Format

### General Structure

- All integers are **little-endian**
- Records are identified by 4-byte magic headers
- Strings are **UTF-16LE** encoded with length prefix
- Hierarchical structure with parent/child relationships

### Record Hierarchy

```
mhbd (Database Header)
├── mhsd (Data Set - Tracks)
│   └── mhlt (Track List)
│       └── mhit (Track Item)
│           ├── mhod (Title string)
│           ├── mhod (Artist string)
│           ├── mhod (Album string)
│           └── mhod (File path)
└── mhsd (Data Set - Playlists)
    └── mhlp (Playlist List)
        └── mhyp (Playlist)
            ├── mhod (Playlist name)
            └── mhip (Track reference)
```

### Magic Headers

| Magic | Description | Size (min) |
|-------|-------------|------------|
| mhbd | Database header | 104 bytes |
| mhsd | Data set container | 16 bytes |
| mhlt | Track list | 12 bytes |
| mhit | Track item | 247 bytes |
| mhod | Data object (strings) | 24 bytes |
| mhlp | Playlist list | 12 bytes |
| mhyp | Playlist | 48 bytes |
| mhip | Playlist item | 40 bytes |

### Database Header (mhbd)

```
Offset  Size  Field
0       4     Magic "mhbd"
4       4     Header size (typically 104-188)
8       4     Total file size
12      4     Unknown (usually 1)
16      4     Database version
20      4     Child count (number of mhsd)
24      8     Database ID
32      16    Various unknowns
48      2     Language code
50      8     Library persistent ID
58+     var   Padding to header_size
```

### Track Item (mhit)

The track header contains extensive metadata:

```
Offset  Size  Field
0       4     Magic "mhit"
4       4     Header size (247 bytes)
8       4     Total size (including mhods)
12      4     String count (mhod children)
16      4     Unique track ID
20      4     Visible flag
24      4     File type (MP3, AAC, etc.)
28      1     VBR flag
29      1     Compilation flag
30      1     Rating (0-100, where 20=1 star)
31      4     Last modified timestamp
35      4     File size (bytes)
39      4     Duration (milliseconds)
43      4     Track number
47      4     Total tracks on album
51      4     Year
55      4     Bitrate (kbps)
59      4     Sample rate (fixed-point)
63      4     Volume adjustment
67      4     Start time offset
71      4     Stop time offset
75      4     Sound check value
79      4     Play count
83      4     Play count (duplicate)
87      4     Last played timestamp
91      4     Disc number
95      4     Total discs
...     ...   Additional fields
```

### String Data Object (mhod)

```
Offset  Size  Field
0       4     Magic "mhod"
4       4     Header size (24)
8       4     Total size
12      4     Type (1=title, 2=location, etc.)
16      4     Unknown
20      4     Unknown
24      4     Unknown
28      4     String length (bytes)
32      4     Unknown
36      4     Encoding (1=UTF-16LE, 2=UTF-16BE)
40      var   String data (UTF-16)
```

### mhod Types

| Type | Description |
|------|-------------|
| 1 | Title |
| 2 | File location (iPod path format) |
| 3 | Album |
| 4 | Artist |
| 5 | Genre |
| 6 | File type |
| 7 | EQ preset |
| 8 | Comment |
| 12 | Composer |
| 13 | Grouping |
| 14 | Description |
| 22 | Album artist |
| 27 | Keywords |
| 52 | Sort title |
| 53 | Sort album |
| 54 | Sort artist |
| 55 | Sort album artist |
| 56 | Sort composer |
| 100 | Playlist title |

## Timestamps

iTunesDB uses **Mac timestamps** (seconds since January 1, 1904 00:00:00 UTC).

Conversion:
```
Unix timestamp = Mac timestamp - 2082844800
Mac timestamp = Unix timestamp + 2082844800
```

## File Paths

Track locations use iPod path format:
- Colon (`:`) as path separator
- Relative to iPod root
- Example: `:iPod_Control:Music:F00:ABCD.mp3`

## ZigPod API

### Opening a Database

```zig
const ITunesDB = @import("library/itunesdb.zig").ITunesDB;

var db = try ITunesDB.open(allocator, "/Volumes/IPOD/iPod_Control/iTunes/iTunesDB");
defer db.deinit();
```

### Reading Tracks

```zig
// By ID
if (db.getTrack(1001)) |track| {
    std.debug.print("Title: {s}\n", .{track.title orelse "Unknown"});
}

// Iterate all
for (db.getAllTracks()) |track| {
    std.debug.print("{s} - {s}\n", .{
        track.artist orelse "Unknown",
        track.title orelse "Unknown",
    });
}
```

### Modifying Playback Statistics

```zig
// Record a play
try db.incrementPlayCount(track_id);
try db.setLastPlayed(track_id, ITunesDB.getCurrentMacTimestamp());

// Set rating (5 stars)
try db.setStarRating(track_id, 5);

// Save changes
try db.save("/Volumes/IPOD/iPod_Control/iTunes/iTunesDB");
```

### Working with Playlists

```zig
// Get master playlist (all tracks)
if (db.getMasterPlaylist()) |master| {
    for (master.track_ids) |id| {
        if (db.getTrack(id)) |track| {
            // Process track
        }
    }
}

// Get named playlist
for (0..db.getPlaylistCount()) |i| {
    if (db.getPlaylist(i)) |playlist| {
        std.debug.print("Playlist: {s}\n", .{playlist.name orelse "Untitled"});
    }
}
```

## Compatibility

The ZigPod implementation is compatible with:

- iPod Classic (5th-7th generation)
- iPod nano (various generations)
- iPod shuffle (with adaptations)
- iTunes for Windows/Mac
- Finder (macOS 10.15+)

## References

- [iPodLinux Wiki - ITunesDB](http://www.ipodlinux.org/ITunesDB)
- [libgpod](https://sourceforge.net/projects/gtkpod/)
- [iPod Classic Technical Specifications](https://support.apple.com/kb/SP594)
