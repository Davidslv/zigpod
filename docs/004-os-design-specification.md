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

#### Storage Location
```
/Music/
├── ZigPod/
│   ├── library.db          # SQLite database
│   ├── artwork/            # Cached album art
│   │   ├── {hash}.art      # 100x100 RGB565
│   │   └── thumbs/         # 50x50 thumbnails
│   ├── playlists/
│   │   ├── on-the-go.m3u
│   │   └── *.m3u
│   └── state/
│       ├── now_playing.dat
│       └── play_counts.dat
└── [User's music files]
```

#### Database Schema
```sql
-- Tracks table
CREATE TABLE tracks (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    title TEXT,
    artist TEXT,
    album TEXT,
    album_artist TEXT,
    genre TEXT,
    composer TEXT,
    year INTEGER,
    track_number INTEGER,
    disc_number INTEGER,
    duration_ms INTEGER,
    file_size INTEGER,
    bitrate INTEGER,
    sample_rate INTEGER,
    format TEXT,
    artwork_hash TEXT,
    play_count INTEGER DEFAULT 0,
    last_played INTEGER,
    rating INTEGER DEFAULT 0,
    added_date INTEGER,
    modified_date INTEGER
);

-- Albums table (derived, cached)
CREATE TABLE albums (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    artist TEXT,
    year INTEGER,
    track_count INTEGER,
    artwork_hash TEXT,
    UNIQUE(name, artist)
);

-- Artists table (derived, cached)
CREATE TABLE artists (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    album_count INTEGER,
    track_count INTEGER
);

-- Playlists table
CREATE TABLE playlists (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    track_count INTEGER,
    duration_ms INTEGER,
    created_date INTEGER,
    modified_date INTEGER
);

-- Playlist tracks
CREATE TABLE playlist_tracks (
    playlist_id INTEGER,
    track_id INTEGER,
    position INTEGER,
    FOREIGN KEY(playlist_id) REFERENCES playlists(id),
    FOREIGN KEY(track_id) REFERENCES tracks(id)
);

-- Indexes for fast lookup
CREATE INDEX idx_tracks_artist ON tracks(artist);
CREATE INDEX idx_tracks_album ON tracks(album);
CREATE INDEX idx_tracks_genre ON tracks(genre);
CREATE INDEX idx_tracks_title ON tracks(title);
```

### 3.2 Library Scanning

#### Scan Process
1. Walk `/Music/` directory recursively
2. For each supported file:
   - Parse metadata (ID3, Vorbis, FLAC tags)
   - Extract embedded artwork (if present)
   - Generate artwork hash
   - Insert/update database
3. Remove entries for deleted files
4. Rebuild derived tables (albums, artists)
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

### 5.1 Audio Formats

| Format | Extensions | Max Bitrate | Sample Rates | Notes |
|--------|------------|-------------|--------------|-------|
| MP3 | .mp3 | 320 kbps | 8-48 kHz | MPEG-1/2 Layer III |
| AAC | .m4a, .aac | 320 kbps | 8-48 kHz | LC-AAC only |
| FLAC | .flac | Lossless | 8-96 kHz | Up to 24-bit |
| ALAC | .m4a | Lossless | 8-96 kHz | Apple Lossless |
| WAV | .wav | Uncompressed | 8-96 kHz | PCM only |
| Ogg Vorbis | .ogg | 500 kbps | 8-48 kHz | |
| WMA | .wma | 320 kbps | 8-48 kHz | Non-DRM only |

### 5.2 Metadata Formats

| Container | Tag Format |
|-----------|------------|
| MP3 | ID3v1, ID3v2.3, ID3v2.4 |
| M4A/AAC | iTunes metadata atoms |
| FLAC | Vorbis comments |
| OGG | Vorbis comments |
| WAV | INFO chunk, ID3 |

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
