# ZigPod Production Roadmap

This document outlines the path from current state to production-ready firmware for the iPod Classic 5th/5.5th generation.

## Current State: Alpha (75% Complete)

**What Works:**
- Complete bootloader with dual-boot and fallback
- Full HAL for PP5021C
- All hardware drivers (LCD, codec, clickwheel, storage)
- WAV/AIFF audio playback (in simulator)
- UI system with menus and file browser
- iFlash/flash storage detection and optimization

**What's Missing:**
- Interrupt-driven I/O (currently polling)
- MP3/FLAC/AAC decoders
- Real hardware testing
- Power management optimization

---

## Phase 1: First Sound on Real Hardware

**Duration**: 2 weeks
**Goal**: Play an MP3 file on actual iPod hardware

### Week 1: Interrupt & DMA Foundation

#### Day 1-2: Interrupt Handler Framework

**Task**: Create interrupt vector table and dispatcher

```
Files to create:
├── src/hal/pp5021c/interrupts.zig      (NEW)
│   ├── Vector table (ARM exception vectors)
│   ├── IRQ dispatcher
│   ├── FIQ handler (audio DMA)
│   └── Handler registration API
└── Update: src/hal/pp5021c/pp5021c.zig
    └── Wire interrupt init into HAL
```

**Deliverables**:
- [ ] Exception vector table at 0x00000000 or remapped
- [ ] IRQ handler that dispatches to registered handlers
- [ ] FIQ handler for time-critical audio
- [ ] API: `hal.registerIrqHandler(irq_num, handler_fn)`

#### Day 3-4: DMA Audio Pipeline

**Task**: Connect I2S output to DMA for gapless audio

```
Files to modify:
├── src/hal/pp5021c/pp5021c.zig
│   └── Wire DMA channel to I2S TX
├── src/drivers/audio/i2s.zig
│   └── Add DMA transfer mode
└── src/audio/audio.zig
    └── Use DMA for buffer output
```

**Deliverables**:
- [ ] DMA channel 0 configured for I2S TX
- [ ] Double-buffer setup (ping-pong)
- [ ] Interrupt on half-buffer empty
- [ ] Seamless buffer switching

#### Day 5-7: MP3 Decoder Integration

**Task**: Port minimp3 decoder to ZigPod

```
Files to create:
├── src/audio/decoders/mp3.zig          (NEW)
│   ├── Wrapper around minimp3
│   ├── Streaming decode interface
│   └── Error handling
└── lib/minimp3/                         (EXTERNAL)
    └── minimp3.h (single-header library)
```

**Decoder Selection**: minimp3
- Single header file, no dependencies
- Public domain license
- ~15KB compiled
- Supports all MP3 formats

**Deliverables**:
- [ ] minimp3 compiles with Zig build
- [ ] `Mp3Decoder` struct implementing decoder interface
- [ ] Frame-by-frame decoding
- [ ] ID3 tag parsing (basic)

### Week 2: Integration & Hardware Test

#### Day 1-2: File Browser → Playback

**Task**: Wire file selection to audio engine

```
Files to modify:
├── src/app/app.zig
│   └── Handle file selection event
├── src/audio/audio.zig
│   └── loadFile() implementation
└── src/ui/now_playing.zig
    └── Real-time audio sync
```

**Deliverables**:
- [ ] Select MP3 in file browser → starts playback
- [ ] Now Playing shows real track info
- [ ] Progress bar updates in real-time
- [ ] Play/Pause button works

#### Day 3-4: Build & Flash to Hardware

**Task**: Create actual ARM binary and test on device

```
Build process:
1. zig build -Dtarget=arm-freestanding-eabi
2. Create firmware.bin with header
3. Install via ipodpatcher or DFU
4. Boot and test
```

**Debug Setup**:
- Serial output via UART (GPIO pins)
- LED blink codes for early boot
- Safe mode for recovery

**Deliverables**:
- [ ] ARM binary builds successfully
- [ ] Firmware.bin with valid header
- [ ] Boots on real hardware
- [ ] Serial debug output working

#### Day 5-7: Debug & Stabilize

**Task**: Fix issues discovered on real hardware

**Common Issues**:
- Timing-sensitive code (I2C, ATA)
- Cache coherency with DMA
- Interrupt priority conflicts
- Power sequencing

**Deliverables**:
- [ ] Stable boot on hardware
- [ ] Audio plays without glitches
- [ ] All buttons responsive
- [ ] No crashes during playback

---

## Phase 2: Usable Music Player

**Duration**: 2 weeks
**Goal**: Feature-complete for daily use

### Week 3: Additional Decoders & Polish

#### Day 1-2: FLAC Decoder

**Task**: Port dr_flac or similar

```
Files to create:
├── src/audio/decoders/flac.zig         (NEW)
└── lib/dr_flac/                         (EXTERNAL)
```

**Deliverables**:
- [ ] FLAC playback working
- [ ] Supports 16/24-bit
- [ ] Supports 44.1/48/96 kHz

#### Day 3-4: Settings Persistence

**Task**: Save/load settings to storage

```
Files to modify:
├── src/ui/settings.zig
│   └── Save on change
└── src/app/app.zig
    └── Load on startup

Config file: /.zigpod/settings.cfg
```

**Settings to persist**:
- Volume level
- EQ settings
- Theme selection
- Last played track
- Shuffle/repeat mode

**Deliverables**:
- [ ] Settings survive reboot
- [ ] Config file format defined
- [ ] Graceful handling of missing/corrupt config

#### Day 5-7: Volume Overlay & UI Polish

**Task**: Implement global volume control

```
Files to modify:
├── src/ui/ui.zig
│   └── drawVolumeOverlay()
├── src/app/app.zig
│   └── Global wheel handler during playback
└── src/ui/themes.zig
    └── Overlay styling
```

**Deliverables**:
- [ ] Wheel adjusts volume on any screen
- [ ] Semi-transparent overlay appears
- [ ] Auto-hide after 1.5 seconds
- [ ] Smooth volume transitions

### Week 4: Power Management & Stability

#### Day 1-2: Power State Management

**Task**: Implement sleep modes for battery life

```
Files to modify:
├── src/drivers/power.zig
│   ├── Idle detection
│   ├── Screen dimming
│   └── Deep sleep entry/exit
└── src/hal/pp5021c/pp5021c.zig
    └── CPU frequency scaling
```

**Power States**:
1. **Active**: Full speed, screen on
2. **Idle**: Reduced clock, screen dimmed
3. **Playing**: Audio active, screen off
4. **Sleep**: Ultra-low power, quick wake

**Deliverables**:
- [ ] Automatic screen dim after 30s
- [ ] Screen off during playback (press any button to wake)
- [ ] CPU frequency reduced when idle
- [ ] Battery life improvement measurable

#### Day 3-4: Battery Monitoring

**Task**: Accurate battery percentage and warnings

```
Files to modify:
├── src/drivers/pmu.zig
│   └── Calibrated voltage curve
└── src/ui/status_bar.zig
    └── Battery indicator
```

**Deliverables**:
- [ ] Accurate percentage (within 5%)
- [ ] Low battery warning at 15%
- [ ] Critical warning at 5%
- [ ] Graceful shutdown at 3%

#### Day 5-7: Stability Testing

**Task**: Extended playback and stress testing

**Test Cases**:
- [ ] 8-hour continuous playback
- [ ] Rapid track skipping
- [ ] Large library navigation (1000+ files)
- [ ] Hot plug of USB during playback
- [ ] Resume after deep sleep

---

## Phase 3: Production Ready

**Duration**: 2 weeks
**Goal**: Release-quality firmware

### Week 5: Security & Recovery

#### Day 1-2: Firmware Signing

**Task**: Implement Ed25519 signature verification

```
Files to create:
├── src/crypto/ed25519.zig              (NEW)
└── tools/sign_firmware.zig             (NEW)
```

**Deliverables**:
- [ ] Ed25519 verification in bootloader
- [ ] Signing tool for release builds
- [ ] Key management documentation

#### Day 3-4: Recovery Mode UI

**Task**: Usable recovery interface

```
Files to create:
└── src/ui/recovery.zig                 (NEW)
    ├── Firmware update option
    ├── Factory reset option
    ├── Boot original firmware
    └── Diagnostic info display
```

**Deliverables**:
- [ ] Menu-driven recovery UI
- [ ] USB firmware update from recovery
- [ ] Factory reset option
- [ ] Hardware diagnostic display

#### Day 5-7: AAC Decoder

**Task**: Port FAAD2 or fdk-aac

```
Files to create:
├── src/audio/decoders/aac.zig          (NEW)
└── lib/faad2/ or lib/fdk-aac/          (EXTERNAL)
```

**Deliverables**:
- [ ] AAC-LC playback
- [ ] M4A container support
- [ ] iTunes-purchased music works

### Week 6: Polish & Release

#### Day 1-2: Documentation

**Task**: Complete all documentation

```
Docs to finalize:
├── README.md                           (Update)
├── docs/USER_GUIDE.md                  (NEW)
├── docs/INSTALLATION.md                (NEW)
├── docs/TROUBLESHOOTING.md             (NEW)
└── docs/BUILDING.md                    (NEW)
```

**Deliverables**:
- [ ] User guide with screenshots
- [ ] Installation instructions (all platforms)
- [ ] Troubleshooting guide
- [ ] Build instructions for developers

#### Day 3-4: Testing & Bug Fixes

**Task**: Final QA pass

**Test Matrix**:
| Test | 5G 30GB | 5G 60GB | 5.5G 30GB | 5.5G 80GB | iFlash |
|------|---------|---------|-----------|-----------|--------|
| Boot | | | | | |
| Playback | | | | | |
| UI | | | | | |
| Battery | | | | | |
| USB | | | | | |

**Deliverables**:
- [ ] All tests pass on all hardware variants
- [ ] No known critical bugs
- [ ] Performance meets targets

#### Day 5-7: Release

**Task**: Package and release v1.0

```
Release artifacts:
├── zigpod-1.0.0-bootloader.bin
├── zigpod-1.0.0-firmware.bin
├── zigpod-1.0.0-source.tar.gz
├── CHANGELOG.md
└── SHA256SUMS
```

**Deliverables**:
- [ ] Signed release binaries
- [ ] GitHub release with changelog
- [ ] Installation instructions verified
- [ ] Community announcement

---

## Future Roadmap (Post 1.0)

### Version 1.1: Enhanced Audio
- [ ] Gapless playback across all formats
- [ ] ReplayGain support
- [ ] Crossfade option
- [ ] Custom EQ presets

### Version 1.2: Library Management
- [ ] Music library scanning
- [ ] Artist/Album/Genre browsing
- [ ] Playlist support
- [ ] Search functionality

### Version 1.3: Visual Enhancements
- [ ] Album art display
- [ ] Multiple themes
- [ ] Custom fonts
- [ ] Visualizations

### Version 2.0: Advanced Features
- [ ] Podcast support
- [ ] Audiobook support (bookmarking)
- [ ] Bluetooth transmitter support (with adapter)
- [ ] USB audio mode

---

## Resource Requirements

### Development Hardware
- [ ] iPod Video 5G or 5.5G (primary test device)
- [ ] iFlash Solo + SD card (flash storage testing)
- [ ] USB-UART adapter (debugging)
- [ ] USB cable (data transfer)

### Development Software
- [ ] Zig compiler (0.11+)
- [ ] ARM cross-compilation toolchain
- [ ] ipodpatcher (bootloader installation)
- [ ] Serial terminal (debug output)

### External Libraries
| Library | Purpose | License | Size |
|---------|---------|---------|------|
| minimp3 | MP3 decoding | Public Domain | ~15KB |
| dr_flac | FLAC decoding | Public Domain | ~20KB |
| FAAD2 | AAC decoding | GPL | ~100KB |

---

## Risk Assessment

### High Risk
1. **Interrupt timing issues**: ARM7 has no NVIC, manual priority management
   - Mitigation: Extensive testing, FIQ for audio

2. **Cache coherency with DMA**: ARM7 cache is write-through but needs management
   - Mitigation: Use uncached memory region for DMA buffers

### Medium Risk
3. **Audio quality issues**: Codec configuration sensitivity
   - Mitigation: Reference Rockbox implementation

4. **Battery life regression**: Power management complexity
   - Mitigation: Incremental optimization, measurements

### Low Risk
5. **iFlash compatibility**: Various adapters in market
   - Mitigation: Already implemented detection

6. **File system corruption**: FAT32 edge cases
   - Mitigation: Read-mostly, safe write patterns

---

## Success Criteria

### Minimum Viable Product (v1.0)
- [ ] Boots reliably on all 5G/5.5G variants
- [ ] Plays MP3 and FLAC files
- [ ] 8+ hours battery life
- [ ] No data loss
- [ ] Dual-boot with Apple firmware

### Quality Targets
- [ ] Boot time < 1 second
- [ ] Zero crashes in 8-hour playback
- [ ] CPU usage < 50% during playback
- [ ] Memory usage < 5 MB
- [ ] Binary size < 400 KB

---

## Timeline Summary

| Phase | Duration | End State |
|-------|----------|-----------|
| Phase 1: First Sound | 2 weeks | MP3 plays on hardware |
| Phase 2: Usable Player | 2 weeks | Daily driver ready |
| Phase 3: Production | 2 weeks | v1.0 release |
| **Total** | **6 weeks** | **Production firmware** |

*Note: Timeline assumes focused, full-time development. Part-time work will extend proportionally.*
