# ZigPod User Guide

This guide covers using ZigPod OS on your iPod Video (5th Generation).

## Getting Started

### Supported Devices

| Model | Storage | Status |
|-------|---------|--------|
| iPod Video 5th Gen (A1136) | 30GB/60GB/80GB | Supported |
| iPod Video 5.5th Gen (A1136) | 30GB/80GB | Supported |
| iPod Classic 6th Gen | 80GB/160GB | Experimental |

### First Boot

When ZigPod starts for the first time:

1. **Library Scan**: ZigPod scans your music folder for supported audio files
2. **Database Build**: Creates an index of your music library
3. **Ready**: Main menu appears

This process takes 1-2 minutes depending on library size.

---

## Navigation

### Click Wheel Controls

| Action | Function |
|--------|----------|
| **Scroll clockwise** | Move down / Increase volume |
| **Scroll counter-clockwise** | Move up / Decrease volume |
| **Center button** | Select / Play/Pause |
| **Menu button** | Back / Main menu |
| **Play/Pause button** | Play/Pause playback |
| **Forward button** | Next track / Seek forward |
| **Back button** | Previous track / Seek backward |

### Button Combinations

| Combination | Action |
|-------------|--------|
| Menu + Select (hold 6s) | Reset device |
| Menu + Play (hold 6s) | Enter Disk Mode |
| Select + Play (hold 6s) | Force shutdown |

---

## Main Menu

```
ZigPod
├── Music
│   ├── Artists
│   ├── Albums
│   ├── Songs
│   ├── Genres
│   └── Playlists
├── Now Playing
├── Settings
│   ├── Sound
│   ├── Display
│   ├── Power
│   └── About
└── Files
```

---

## Music Playback

### Supported Formats

| Format | Extensions | Bit Depths | Notes |
|--------|------------|------------|-------|
| WAV | .wav | 8/16/24/32-bit, float | Uncompressed PCM |
| AIFF | .aiff, .aif | 8/16/24/32-bit | Apple lossless |
| FLAC | .flac | 8-32 bit | Lossless compression |
| MP3 | .mp3 | VBR/CBR 32-320 kbps | MPEG Layer III |

### Now Playing Screen

```
┌─────────────────────────────────┐
│          Album Art              │
│                                 │
├─────────────────────────────────┤
│ Song Title                      │
│ Artist Name                     │
│ Album Name                      │
├─────────────────────────────────┤
│ ▶ 1:23 ══════●══════════ 4:56  │
│         [Volume: 75%]           │
└─────────────────────────────────┘
```

### Playback Controls

While on Now Playing screen:
- **Center**: Play/Pause
- **Scroll**: Adjust volume
- **Forward (hold)**: Seek forward
- **Back (hold)**: Seek backward
- **Forward (tap)**: Next track
- **Back (tap)**: Previous track

---

## Settings

### Sound Settings

| Setting | Options | Description |
|---------|---------|-------------|
| **Volume Limit** | Off / 50% / 75% | Maximum volume cap |
| **EQ Preset** | Flat / Rock / Pop / Jazz / Classical / Custom | Sound profile |
| **Stereo Width** | 0-200% | Stereo enhancement |
| **Bass Boost** | Off / Low / Medium / High | Low frequency boost |
| **Sound Check** | On / Off | Normalize volume across tracks |

### Display Settings

| Setting | Options | Description |
|---------|---------|-------------|
| **Backlight** | 5s / 10s / 30s / Always On | Auto-off timeout |
| **Brightness** | 1-10 | Screen brightness |
| **Contrast** | 1-10 | Screen contrast |
| **Theme** | Classic / Dark / Light | UI color scheme |

### Power Settings

| Setting | Options | Description |
|---------|---------|-------------|
| **Sleep Timer** | Off / 15m / 30m / 1h / 2h | Auto-sleep during playback |
| **Auto Shutdown** | Off / 1h / 2h / 4h | Shutdown when idle |
| **Battery Saver** | On / Off | Reduce CPU speed when idle |

---

## File Management

### Disk Mode

To access your iPod as a USB drive:

1. Connect USB cable
2. Hold **Menu + Play** for 6 seconds
3. "Disk Mode" appears on screen
4. iPod mounts as removable drive

### File Structure

```
iPod_Control/
├── iTunes/
│   └── iTunesDB          # Music database (auto-managed)
├── Music/
│   └── F00-F49/          # Music files (hashed folders)
└── Device/
    └── zigpod.cfg        # ZigPod settings
```

### Adding Music

**Option 1: iTunes/Finder Sync**
- Use iTunes (Windows) or Finder (macOS) to sync music
- ZigPod reads the standard iTunesDB format

**Option 2: Direct Copy (Disk Mode)**
1. Enter Disk Mode
2. Copy audio files to `iPod_Control/Music/`
3. Eject and reboot
4. ZigPod will scan and index new files

---

## Troubleshooting

### Device Won't Boot

1. **Hard Reset**: Hold Menu + Select for 10 seconds
2. **Charge**: Connect to power for 30 minutes
3. **Disk Mode**: Hold Menu + Play during boot
4. **Recovery**: See [Hardware Testing Protocol](006-hardware-testing-protocol.md)

### No Audio

1. Check volume isn't muted (scroll up)
2. Check headphone connection
3. Try a different audio file
4. Reset audio settings to defaults

### Library Not Updating

1. Go to Settings > About > Rescan Library
2. Wait for scan to complete
3. If issue persists, rebuild database:
   - Settings > About > Rebuild Database

### Battery Drains Quickly

1. Reduce backlight timeout
2. Enable Battery Saver mode
3. Disable EQ processing (use Flat preset)
4. Check for stuck processes (Settings > About > System Info)

---

## Keyboard Shortcuts (Simulator)

When running in the simulator:

| Key | Action |
|-----|--------|
| **Arrow Up/Down** | Scroll wheel |
| **Enter** | Select |
| **Escape / M** | Menu |
| **Space** | Play/Pause |
| **Left/Right** | Prev/Next |
| **Q** | Quit simulator |

---

## Technical Information

### Memory Usage

| Component | RAM Usage |
|-----------|-----------|
| Kernel | ~64 KB |
| Audio Engine | ~256 KB |
| UI Framework | ~128 KB |
| File Cache | ~1 MB |
| Audio Buffer | ~512 KB |

### Battery Life (Estimated)

| Usage | Battery Life |
|-------|--------------|
| Audio playback | 14-20 hours |
| Idle (screen off) | 48+ hours |
| Active browsing | 6-8 hours |

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 0.1.0 | 2025-01 | Initial release |

---

## Getting Help

- **GitHub Issues**: Report bugs and feature requests
- **Documentation**: See `/docs` folder for technical details
- **Recovery**: See [Hardware Testing Protocol](006-hardware-testing-protocol.md)
