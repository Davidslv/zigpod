# ZigPod OS Design Specification

## Overview

This document specifies the complete user-facing operating system for ZigPod, including navigation, music management, playback features, UI/UX design, and supported formats.

---

## 1. Display & Visual Design

### 1.1 Screen Specifications
- **Resolution**: 220 x 176 pixels
- **Color depth**: 16-bit (RGB565)
- **Orientation**: Landscape
- **Refresh rate**: 30-60 FPS for animations

### 1.2 Visual Theme

#### Color Palette
```
Primary Background:   #1C1C1E (near-black)
Secondary Background: #2C2C2E (dark gray)
Text Primary:         #FFFFFF (white)
Text Secondary:       #8E8E93 (gray)
Accent:               #0A84FF (blue)
Now Playing Accent:   #FF453A (red)
Success:              #30D158 (green)
Warning:              #FF9F0A (orange)
```

#### Typography
```
Title Large:     18px, Bold
Title:           16px, Bold
Body:            14px, Regular
Caption:         12px, Regular
Mono (time):     14px, Monospace
```

#### Design Principles
1. **Minimal**: Reduce visual clutter
2. **Readable**: High contrast, clear hierarchy
3. **Responsive**: Instant feedback to input
4. **Consistent**: Same patterns everywhere
5. **Accessible**: Works in bright sunlight

### 1.3 Screen Layouts

#### Status Bar (Always Visible)
```
┌──────────────────────────────────────────┐
│ ♪ Artist - Song                    12:34 │  <- 16px height
├──────────────────────────────────────────┤
│                                          │
│              Main Content                │
│                                          │
│                                          │
└──────────────────────────────────────────┘
```

#### List View (Most Screens)
```
┌──────────────────────────────────────────┐
│ ♪ Artist - Song                    12:34 │
├──────────────────────────────────────────┤
│ > Albums                                 │
│   Artists                                │
│   Songs                                  │
│   Playlists                              │
│   Genres                                 │
│   Composers                              │
│   Podcasts                               │
│   Audiobooks                             │
└──────────────────────────────────────────┘
```

#### Now Playing Screen
```
┌──────────────────────────────────────────┐
│           NOW PLAYING                    │
├──────────────────────────────────────────┤
│                                          │
│         ┌────────────────┐               │
│         │                │               │
│         │   Album Art    │               │
│         │    100x100     │               │
│         │                │               │
│         └────────────────┘               │
│                                          │
│         Song Title                       │
│         Artist Name                      │
│         Album Name                       │
│                                          │
│  ▶ ━━━━━━━━○━━━━━━━━━━━━  2:34 / 4:12   │
│                                          │
└──────────────────────────────────────────┘
```

### 1.4 Animations

| Animation | Duration | Easing |
|-----------|----------|--------|
| Screen transition | 200ms | ease-out |
| List scroll | 16ms/frame | linear |
| Selection highlight | 100ms | ease-in-out |
| Volume overlay | 150ms | ease-out |
| Progress bar | continuous | linear |
| Album art fade | 300ms | ease-in |

---

## 2. Navigation & Interaction

### 2.1 Click Wheel Input
```
        [MENU]
           │
    ┌──────┼──────┐
    │      │      │
[<<]│   WHEEL   │[>>]
    │      │      │
    └──────┼──────┘
           │
    [PLAY/PAUSE]
           │
       [SELECT]
```

### 2.2 Control Mapping

| Input | Primary Action | Context Actions |
|-------|---------------|-----------------|
| MENU | Go back / Exit | Long: Main Menu |
| SELECT (Center) | Confirm / Enter | Long: Options menu |
| PLAY/PAUSE | Play/Pause | Long: Shutdown menu |
| << (Left) | Previous track | Long: Seek backward |
| >> (Right) | Next track | Long: Seek forward |
| Wheel CW | Scroll down / Vol+ | |
| Wheel CCW | Scroll up / Vol- | |

### 2.3 Context-Sensitive Actions

#### In List View
- Wheel: Scroll through items
- SELECT: Enter selected item
- MENU: Go back one level
- PLAY: Start playing selected item
- >>: Peek/preview (show info)

#### In Now Playing
- Wheel: Volume control
- SELECT: Toggle time/remaining
- MENU: Return to browser
- PLAY: Play/Pause
- <<: Previous (tap) / Seek back (hold)
- >>: Next (tap) / Seek forward (hold)

#### In Options Menu
- Wheel: Navigate options
- SELECT: Confirm selection
- MENU: Cancel and close

### 2.4 Navigation Hierarchy

```
Main Menu
├── Music
│   ├── Albums
│   │   └── [Album] → Songs in album
│   ├── Artists
│   │   └── [Artist] → Albums by artist → Songs
│   ├── Songs (all songs A-Z)
│   ├── Playlists
│   │   ├── On-The-Go
│   │   └── [Playlist] → Songs in playlist
│   ├── Genres
│   │   └── [Genre] → Artists → Albums
│   ├── Composers
│   │   └── [Composer] → Songs
│   ├── Podcasts
│   │   └── [Show] → Episodes
│   └── Audiobooks
│       └── [Book] → Chapters
├── Now Playing
├── Shuffle Songs
├── Settings
│   ├── Sound
│   │   ├── EQ Preset
│   │   ├── Volume Limit
│   │   └── Sound Check
│   ├── Playback
│   │   ├── Shuffle
│   │   ├── Repeat
│   │   └── Crossfade
│   ├── Display
│   │   ├── Brightness
│   │   ├── Backlight Timer
│   │   └── Contrast
│   ├── Date & Time
│   ├── Language
│   ├── About
│   └── Reset
└── Sleep Timer
```

---

## 3. Music Library Management

### 3.1 Library Database

> **Design Decision**: We use a binary database format inspired by Apple's iTunesDB rather than SQLite.
>
> **Why not SQLite?**
> - SQLite requires ~200KB+ of code (SQL parser, query planner, B-tree engine)
> - Higher memory overhead for query processing
> - Overkill for a music library with known, fixed queries
> - The original iPod ran successfully for 15+ years with iTunesDB
>
> **Benefits of binary format:**
> - Smaller code footprint (~10KB vs 200KB+)
> - Direct memory-mapped access
> - Predictable performance (no query planning)
> - Compatible with existing iPod ecosystem

#### Storage Location (iTunes-Compatible)
```
/iPod_Control/
├── iTunes/
│   ├── iTunesDB           # Main track/playlist database (binary)
│   ├── iTunesSD           # Shuffle database (if needed)
│   ├── ArtworkDB          # Album artwork database
│   └── DeviceInfo         # Device identification
├── Music/
│   ├── F00/               # Music files (obfuscated names)
│   ├── F01/               # Distributed across ~50 folders
│   ├── ...
│   └── F49/
└── Artwork/
    └── Cache/             # Processed artwork cache
```

#### iTunesDB Binary Format

The database uses a hierarchical object structure with 4-byte magic headers:

```
┌─────────────────────────────────────────────────────────┐
│ mhbd (Database Header)                                  │
│   ├── Header size, version, track count                 │
│   │                                                     │
│   ├── mhsd (Data Set - Tracks)                         │
│   │   └── mhlt (Track List)                            │
│   │       ├── mhit (Track 1)                           │
│   │       │   ├── mhod (Title string)                  │
│   │       │   ├── mhod (Artist string)                 │
│   │       │   ├── mhod (Album string)                  │
│   │       │   └── mhod (Path string)                   │
│   │       ├── mhit (Track 2)                           │
│   │       │   └── ...                                  │
│   │       └── ...                                      │
│   │                                                     │
│   └── mhsd (Data Set - Playlists)                      │
│       └── mhlp (Playlist List)                         │
│           ├── mhyp (Master Playlist)                   │
│           │   └── mhip (Track references)              │
│           └── mhyp (User Playlist)                     │
│               └── mhip (Track references)              │
└─────────────────────────────────────────────────────────┘
```

#### Zig Structure Definitions

```zig
/// Database header (mhbd)
pub const DbHeader = extern struct {
    magic: [4]u8 = "mhbd".*,     // Magic identifier
    header_size: u32,            // Size of this header
    total_size: u32,             // Total database size
    version: u32,                // Database version
    child_count: u32,            // Number of mhsd children
    id: u64,                     // Database ID
    // ... padding to header_size
};

/// Track item (mhit)
pub const TrackItem = extern struct {
    magic: [4]u8 = "mhit".*,
    header_size: u32,
    total_size: u32,
    string_count: u32,           // Number of mhod children
    track_id: u32,               // Unique track ID
    visible: u32,                // 1 = visible in library
    file_type: u32,              // MP3, AAC, etc.
    duration_ms: u32,
    bitrate: u32,
    sample_rate: u32,
    year: u16,
    track_number: u16,
    disc_number: u16,
    rating: u8,                  // 0-100
    play_count: u32,
    last_played: u32,            // Mac timestamp
    added_date: u32,
    file_size: u32,
    // ... additional fields
};

/// String data (mhod)
pub const StringData = extern struct {
    magic: [4]u8 = "mhod".*,
    header_size: u32,
    total_size: u32,
    string_type: u32,            // 1=title, 2=path, 3=album, 4=artist...
    // Followed by UTF-16LE string data
};
```

#### String Types (mhod)
| Type | Value | Description |
|------|-------|-------------|
| Title | 1 | Track title |
| Location | 2 | File path (iPod format) |
| Album | 3 | Album name |
| Artist | 4 | Artist name |
| Genre | 5 | Genre |
| Comment | 6 | Comment |
| Composer | 12 | Composer name |
| Album Artist | 22 | Album artist |

#### Database Operations

```zig
pub const ItunesDb = struct {
    data: []align(4) u8,         // Memory-mapped file
    track_index: []u32,          // Offset to each mhit

    pub fn open(path: []const u8) !ItunesDb;
    pub fn getTrackCount(self: *ItunesDb) u32;
    pub fn getTrack(self: *ItunesDb, id: u32) ?*TrackItem;
    pub fn getTrackString(self: *ItunesDb, track: *TrackItem, string_type: u32) ?[]const u16;
    pub fn iterateTracks(self: *ItunesDb) TrackIterator;

    // Playlist operations
    pub fn getPlaylistCount(self: *ItunesDb) u32;
    pub fn getPlaylistTracks(self: *ItunesDb, playlist_id: u32) []u32;
};
```

### 3.2 Library Scanning

#### Scan Process
1. Walk `/iPod_Control/Music/` directory recursively
2. For each supported file:
   - Parse metadata (ID3v2 for MP3, iTunes atoms for M4A/AAC, AIFF/WAV chunks)
   - Extract embedded artwork (if present)
   - Generate artwork hash
   - Insert/update iTunesDB
3. Remove entries for deleted files
4. Rebuild master playlist
5. Update statistics

#### Incremental Updates
- Store file modification time
- On boot, quick-scan for changes
- Full rescan only when requested

### 3.3 Artwork Management

#### Artwork Sources (Priority Order)
1. Embedded artwork in audio file
2. `cover.jpg` / `folder.jpg` in same directory
3. `AlbumArt*.jpg` in same directory
4. No artwork → use genre icon placeholder

#### Artwork Processing
```
Source Image
     │
     ▼
[Decode JPEG/PNG]
     │
     ▼
[Scale to 100x100]
     │
     ▼
[Convert to RGB565]
     │
     ▼
[Write to artwork cache]
```

#### Memory Constraints
- Keep only current album art in RAM
- Preload next album art during playback
- LRU cache for recently viewed (5 items max)

---

## 4. Playback Features

### 4.1 Audio Pipeline

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Source    │───▶│   Decoder   │───▶│    DSP      │
│  (File IO)  │    │ (MP3/FLAC)  │    │  (EQ/Vol)   │
└─────────────┘    └─────────────┘    └─────────────┘
                                             │
                                             ▼
                   ┌─────────────┐    ┌─────────────┐
                   │    I2S      │◀───│   Buffer    │
                   │  (Output)   │    │  (Ring)     │
                   └─────────────┘    └─────────────┘
```

### 4.2 Playback Modes

| Mode | Behavior |
|------|----------|
| Normal | Play queue in order, stop at end |
| Repeat One | Repeat current track |
| Repeat All | Loop entire queue |
| Shuffle | Random order, no repeats until all played |
| Shuffle Repeat | Random order, continuous |

### 4.3 Queue Management

```zig
const PlayQueue = struct {
    tracks: ArrayList(TrackId),
    current_index: usize,
    shuffle_order: ArrayList(usize),  // Shuffled indices
    repeat_mode: RepeatMode,
    shuffle_enabled: bool,

    pub fn next(self: *PlayQueue) ?TrackId;
    pub fn previous(self: *PlayQueue) ?TrackId;
    pub fn jumpTo(self: *PlayQueue, index: usize) void;
    pub fn addToQueue(self: *PlayQueue, track: TrackId) void;
    pub fn clearQueue(self: *PlayQueue) void;
    pub fn moveTrack(self: *PlayQueue, from: usize, to: usize) void;
};
```

### 4.4 Gapless Playback

Requirements for gapless:
1. Decode next track before current ends
2. Handle LAME encoder delay compensation
3. Crossfade option (0-12 seconds)
4. Seamless buffer handoff

Implementation:
```
Track A playing ─────────────────────┐
                                     │
Track B decoding      ────────────────┼────────────
                                     │
                              Crossfade/Gap
```

### 4.5 Seeking

| Action | Behavior |
|--------|----------|
| Hold << | Seek backward 2s/second, accelerating |
| Hold >> | Seek forward 2s/second, accelerating |
| Tap << | Previous track (or restart if >3s in) |
| Tap >> | Next track |

### 4.6 Bookmarking (Podcasts/Audiobooks)

- Auto-save position every 30 seconds
- Resume from saved position on playback
- Separate position tracking per file
- Speed adjustment (0.5x - 2.0x)

---

## 5. Supported Formats

> **Note**: These formats match the original iPod Classic specifications exactly.
> See [Apple's official specs](https://support.apple.com/en-us/112601) for reference.

### 5.1 Audio Formats

| Format | Extensions | Bitrate | Sample Rates | Notes |
|--------|------------|---------|--------------|-------|
| **AAC** | .m4a, .aac | 8-320 kbps | 8-48 kHz | LC-AAC, includes Protected AAC |
| **MP3** | .mp3 | 8-320 kbps | 8-48 kHz | MPEG-1/2 Layer III, VBR supported |
| **Apple Lossless** | .m4a | Lossless | 8-48 kHz | Up to 24-bit/48kHz max |
| **AIFF** | .aiff, .aif | Uncompressed | 8-48 kHz | PCM audio |
| **WAV** | .wav | Uncompressed | 8-48 kHz | PCM audio |
| **Audible** | .aa, .aax | Variable | 22-44 kHz | Audiobook formats 2, 3, 4, AAX |

#### Formats NOT Supported (by design)
| Format | Reason |
|--------|--------|
| FLAC | Not supported by original iPod hardware/firmware |
| Ogg Vorbis | Not supported by original iPod |
| WMA | Not supported by original iPod (requires license) |
| MPEG-1/2 Layer I/II | Only Layer III (MP3) supported |

### 5.2 Metadata Formats

| Container | Tag Format |
|-----------|------------|
| MP3 | ID3v1, ID3v2.3, ID3v2.4 |
| M4A/AAC/ALAC | iTunes metadata atoms (moov/udta/meta) |
| AIFF | ID3v2, AIFF chunks |
| WAV | INFO chunk (RIFF), ID3v2 |

### 5.3 Playlist Formats

| Format | Extensions | Notes |
|--------|------------|-------|
| M3U | .m3u, .m3u8 | Extended M3U with #EXTINF |
| PLS | .pls | Winamp format |

### 5.4 Image Formats (Artwork)

| Format | Max Size |
|--------|----------|
| JPEG | 1000x1000 |
| PNG | 1000x1000 |
| BMP | 500x500 |

---

## 6. Search & Findability

### 6.1 Quick Search

Access: Hold MENU from any music browser screen

```
┌──────────────────────────────────────────┐
│ SEARCH                                   │
├──────────────────────────────────────────┤
│                                          │
│  [A][B][C][D][E][F][G][H][I]            │
│  [J][K][L][M][N][O][P][Q][R]            │
│  [S][T][U][V][W][X][Y][Z][_]            │
│  [0][1][2][3][4][5][6][7][8][9]         │
│                                          │
│  Query: BEAT___                          │
│                                          │
│  Results:                                │
│  > "Beatles, The" (Artist)              │
│    "Beat It" (Song)                     │
│    "Heartbeat" (Album)                  │
│                                          │
└──────────────────────────────────────────┘
```

Navigation:
- Wheel: Move through alphabet grid
- SELECT: Add letter
- <<: Backspace
- >>: Space
- MENU: Exit search
- PLAY: Jump to selected result

### 6.2 Alphabet Jump

In any alphabetical list:
- Hold wheel in one direction to activate
- Shows large letter overlay
- Jump to section starting with letter

```
┌──────────────────────────────────────────┐
│ Artists                                  │
├──────────────────────────────────────────┤
│   ABBA                      ┌───┐        │
│   AC/DC                     │ B │        │
│ > Beatles, The              └───┘        │
│   Beck                                   │
│   Beyoncé                                │
│   Björk                                  │
│   Black Keys, The                        │
│   Blur                                   │
└──────────────────────────────────────────┘
```

### 6.3 Recently Added

Automatically maintained list:
- Last 100 tracks added
- Sorted by add date (newest first)
- Accessible from Music menu

### 6.4 Recently Played

Automatically maintained list:
- Last 50 tracks played
- Sorted by play date (most recent first)
- Accessible from Music menu

### 6.5 Top Rated

User-rated tracks:
- Rate with SELECT + Wheel in Now Playing
- Shows top 100 rated tracks
- Ties broken by play count

---

## 7. Settings & Configuration

### 7.1 Sound Settings

#### EQ Presets
| Preset | 60Hz | 230Hz | 910Hz | 4kHz | 14kHz |
|--------|------|-------|-------|------|-------|
| Off | 0 | 0 | 0 | 0 | 0 |
| Bass Boost | +6 | +3 | 0 | 0 | 0 |
| Treble Boost | 0 | 0 | 0 | +3 | +6 |
| Classical | 0 | 0 | 0 | -2 | -2 |
| Jazz | +2 | 0 | 0 | +2 | +4 |
| Pop | -1 | +2 | +4 | +2 | -1 |
| Rock | +4 | +2 | -1 | +2 | +4 |
| Electronic | +4 | +2 | 0 | +2 | +4 |
| Custom | User-defined |

#### Volume Limit
- Range: 25% - 100% (default 100%)
- Prevents hearing damage
- EU compliance option

#### Sound Check (Volume Normalization)
- Analyzes ReplayGain tags
- Falls back to track analysis
- Normalizes perceived loudness

### 7.2 Playback Settings

| Setting | Options | Default |
|---------|---------|---------|
| Shuffle | On / Off | Off |
| Repeat | Off / One / All | Off |
| Crossfade | 0-12 seconds | 0 |
| Audiobook Speed | 0.5x - 2.0x | 1.0x |
| Start at | Beginning / Resume | Resume |

### 7.3 Display Settings

| Setting | Options | Default |
|---------|---------|---------|
| Brightness | 1-10 | 7 |
| Backlight Timer | 5s, 10s, 15s, 30s, Always On | 10s |
| Contrast | 1-10 | 5 |
| Now Playing View | Simple / Detailed / Artwork | Artwork |
| Theme | Dark / Light | Dark |

### 7.4 System Settings

| Setting | Options |
|---------|---------|
| Language | English, Spanish, French, German, Japanese, Chinese |
| Date & Time | Set manually |
| Sleep Timer | Off, 15m, 30m, 60m, 90m, 120m |
| USB Mode | Auto / Mass Storage / Charge Only |
| Reset | Reset Settings / Reset Library / Factory Reset |

### 7.5 About Screen

```
┌──────────────────────────────────────────┐
│ About ZigPod                             │
├──────────────────────────────────────────┤
│                                          │
│  Version:     1.0.0                      │
│  Build:       2024.01.15                 │
│                                          │
│  Songs:       3,482                      │
│  Albums:      312                        │
│  Artists:     187                        │
│  Playlists:   12                         │
│                                          │
│  Capacity:    80 GB                      │
│  Available:   42.3 GB                    │
│                                          │
│  Serial:      XXXXXXXXXXXX               │
│                                          │
│  zigpod.org                              │
│                                          │
└──────────────────────────────────────────┘
```

---

## 8. Special Features

### 8.1 On-The-Go Playlist

- Quick add from any browser: Hold SELECT on track
- Quick add from Now Playing: Hold SELECT
- Clear On-The-Go from menu
- Save On-The-Go as named playlist

### 8.2 Sleep Timer

- Set from main menu
- Shows countdown on Now Playing
- Fades volume over last 30 seconds
- Saves position before sleep

### 8.3 Album Art Slideshow (Screensaver)

- Activates after 30s inactivity during playback
- Cycles through album art
- Shows artist/album text
- Any input returns to Now Playing

### 8.4 Battery & Power Management

Battery indicator in status bar:
```
Full:    ████
75%:     ███░
50%:     ██░░
25%:     █░░░
Low:     ░░░░ (blinks)
Charging: ████⚡
```

Low battery behavior:
- Warning at 10%
- Save state at 5%
- Graceful shutdown at 3%

### 8.5 Lyrics Display (Future)

If embedded lyrics present:
- Scrolling lyrics view
- Synced lyrics if timestamped
- Toggle with SELECT in Now Playing

---

## 9. Error Handling

### 9.1 User-Facing Errors

| Error | Message | Action |
|-------|---------|--------|
| Corrupt file | "Cannot play: File corrupted" | Skip to next |
| Unsupported format | "Cannot play: Format not supported" | Skip to next |
| Disk full | "Cannot save: Disk full" | Show storage info |
| Database error | "Library error: Rebuilding..." | Auto-rebuild |
| No music found | "No music found. Connect to computer." | Show help |

### 9.2 Recovery Behavior

- Crash → Auto-restart, resume playback
- Corrupt database → Rebuild from files
- Corrupt settings → Reset to defaults
- Disk error → Mark track, skip, continue

---

## 10. Implementation Priority

### Phase 1: Core Playback (MVP)
- [ ] Basic list navigation
- [ ] MP3 playback
- [ ] Now Playing screen
- [ ] Volume control
- [ ] Play/Pause/Skip

### Phase 2: Library Management
- [ ] Database implementation
- [ ] Library scanning
- [ ] Album/Artist/Song browsing
- [ ] Metadata display

### Phase 3: Enhanced Features
- [ ] Shuffle/Repeat
- [ ] Search
- [ ] Playlists
- [ ] EQ

### Phase 4: Polish
- [ ] Album artwork
- [ ] Animations
- [ ] Gapless playback
- [ ] Crossfade

### Phase 5: Complete
- [ ] All audio formats
- [ ] Lyrics
- [ ] Podcasts
- [ ] Audiobooks

---

## Appendix A: File Size Estimates

| Component | Size |
|-----------|------|
| OS Binary | ~256 KB |
| Fonts | ~64 KB |
| UI Assets | ~32 KB |
| Audio Decoders | ~128 KB |
| **Total Firmware** | **~512 KB** |

## Appendix B: Memory Budget

| Component | RAM Usage |
|-----------|-----------|
| Audio buffers | 128 KB |
| Display buffer | 77 KB (220×176×2) |
| Database cache | 64 KB |
| Artwork cache | 40 KB (2 × 100×100×2) |
| Stack | 16 KB |
| Heap | ~32 KB |
| **Total** | **~360 KB** |

Available SDRAM: 32-64 MB → Plenty of headroom
