# ZigPod

> **WARNING: This project is under active development and is NOT ready for general use.**
>
> This repository contains two related projects:
> 1. **ZigPod OS** - A custom operating system for iPod (early development, not functional)
> 2. **PP5021C Emulator** - An iPod hardware emulator (functional, runs Rockbox firmware)
>
> **Neither component is ready for end-user use.** See [Current Status](#current-status) for details.

A custom operating system and hardware emulator for the Apple iPod Video (5th Generation), written entirely in Zig.

<p align="center">
  <img src="docs/assets/zigpod-simulator.png" alt="ZigPod Simulator - RetroFlow Design" width="500">
  <br>
  <em>ZigPod Simulator with RetroFlow design - featuring animated waveform visualizer</em>
</p>

## What Actually Works Today

| Component | Status | Notes |
|-----------|--------|-------|
| **PP5021C Emulator** | ✅ Partial | Boots Rockbox, LCD works, threads blocked by missing COP |
| **ZigPod OS** | ❌ Early Dev | UI framework exists, not bootable on real hardware |
| **Simulator** | ✅ Works | SDL2 GUI displays output |
| **Hardware Flash** | ⚠️ Risky | Untested, may brick device |

**Read the full development journey: [JOURNEY.md](JOURNEY.md)**

## Features

> **Note**: Features marked with 🚧 are implemented but not fully tested or working end-to-end.

### PP5021C Emulator
- ✅ **ARM7TDMI CPU**: Full 32-bit ARM and 16-bit Thumb instruction sets
- ✅ **Memory System**: SDRAM (32/64MB), IRAM (128KB), Boot ROM
- ✅ **LCD Display**: 320x240 RGB565 via SDL2 window
- ✅ **Storage**: ATA controller reads FAT32 disk images
- ✅ **Peripherals**: Timers, GPIO, I2C, I2S, DMA, Interrupt Controller
- ✅ **Firmware Boot**: Loads and executes Rockbox bootloader + main firmware
- 🚧 **COP Emulation**: Not implemented - blocks thread scheduling

### ZigPod OS (Planned Features)

These features are implemented in code but **not functional on real hardware**:

#### Audio Playback 🚧
- **Multiple Formats**: WAV, AIFF, FLAC, and MP3 support
- **Gapless Playback**: Seamless track transitions with dual-decoder architecture
- **DSP Effects**: 5-band EQ, bass boost, stereo widening, volume ramping
- **Playlist Support**: M3U and PLS playlist parsing

#### Music Library 🚧
- **Library Browser**: Browse by Artists, Albums, or Songs
- **Music Database**: Scan and index tracks with metadata extraction
- **Shuffle & Repeat**: All playback modes (off, one, all)
- **Playback Queue**: Full queue management with next/previous navigation

#### Album Art 🚧
- **Embedded Art Extraction**: ID3v2 (MP3), FLAC PICTURE, M4A covr atoms
- **Image Decoding**: BMP and JPEG with optimized IDCT
- **Smart Scaling**: Bilinear interpolation to 80x80 with Floyd-Steinberg dithering
- **Caching System**: Persistent cache with idle-time pre-loading

#### User Interface 🚧
- **iPod-like Navigation**: Click wheel with acceleration, 5-button input
- **Now Playing Screen**: Real-time position, metadata, album art display
- **Settings Menus**: Display, Audio, Playback, System with persistence
- **Volume Overlay**: Global volume control from any screen
- **Theme Support**: Customizable UI themes

#### Hardware Support 🚧
- **LCD Driver**: BCM2722 interface written
- **Click Wheel**: Input handling implemented
- **Audio Codec**: WM8758 driver written
- **Storage**: ATA driver in progress
- **Power Management**: PCF50605 PMU integration planned

### Developer Experience
- ✅ **PP5021C Emulator**: Runs Rockbox firmware with SDL2 GUI
- ✅ **ZigPod Simulator**: Test ZigPod OS in simulation
- ✅ **Extensive Tests**: 820+ unit tests across all modules
- ✅ **Clean Codebase**: ~67,000 lines of documented Zig code

## Current Status

### PP5021C Emulator (runs Rockbox firmware)

| Component | Status | Notes |
|-----------|--------|-------|
| ARM7TDMI CPU | ✅ Working | Full ARM + Thumb instruction sets |
| Memory Bus | ✅ Working | SDRAM, IRAM, Boot ROM mapping |
| LCD Controller | ✅ Working | 320x240 output via SDL2 |
| ATA/Storage | ✅ Working | Reads FAT32 disk images |
| Timer/IRQ | ✅ Working | Timer1 fires, interrupts handled |
| Firmware Loading | ✅ Working | Boots Rockbox bootloader + main firmware |
| **COP (Coprocessor)** | ❌ Not Emulated | **Blocks thread scheduling** |
| Thread Scheduling | ❌ Blocked | Needs COP to wake threads |
| Rockbox UI | ❌ Blocked | Needs threads to run |

**Current blocker**: The iPod has dual ARM cores (CPU + COP). Rockbox's scheduler requires both cores. Without COP emulation, threads cannot be scheduled, so the Rockbox UI never renders. LCD hardware is proven working via test patterns.

### ZigPod OS (custom firmware)

| Component | Simulator | Hardware | Notes |
|-----------|-----------|----------|-------|
| LCD Display | Works | Untested | BCM2722 driver written |
| Click Wheel | Works | Untested | Input handling works in sim |
| Menu UI | Works | Untested | Navigation functional in sim |
| Storage (ATA) | Partial | Untested | MBR parsing in progress |
| Audio Playback | Partial | Untested | DMA pipeline not wired |
| Boot on Hardware | N/A | ❌ Not Working | Not yet bootable |

**Current blocker**: ZigPod OS is not bootable on real hardware. Development is focused on the emulator.

## Quick Start

### Prerequisites

- [Zig 0.15.2](https://ziglang.org/download/) or later
- Git
- SDL2 (for GUI display)

### Build and Run the Emulator

```bash
# Clone the repository
git clone https://github.com/Davidslv/zigpod.git
cd zigpod

# Build with SDL2 GUI support
zig build -Dsdl2=true

# Run the emulator with Rockbox firmware
./zig-out/bin/zigpod-emulator \
  --firmware firmware/rockbox/bootloader-ipodvideo.ipod \
  firmware/rockbox/rockbox_disk.img

# Or run headless (no GUI, outputs to PPM file)
./zig-out/bin/zigpod-emulator --headless --cycles 100000000 \
  --firmware firmware/rockbox/bootloader-ipodvideo.ipod \
  firmware/rockbox/rockbox_disk.img
```

### Build and Test ZigPod OS (Simulator)

```bash
# Run all tests
zig build test

# Run the ZigPod OS simulator
zig build sim

# Run simulator with GUI (requires SDL2)
zig build sim -Dsdl2=true

# Detect connected iPod (useful for hardware development)
zig build ipod-detect
./zig-out/bin/ipod-detect -v   # Verbose mode with partition layout
```

## Using the Simulator

The simulator provides a complete PP5021C iPod emulation environment:

```bash
# Basic simulator with demo program
zig build sim

# With SDL2 graphical interface
zig build sim -Dsdl2=true

# Play audio file (GUI mode)
zig build sim -Dsdl2=true -- --audio path/to/music.wav

# Full options
zig build sim -- --help
```

**Simulator Controls:**

| Input | Action |
|-------|--------|
| Arrow keys / Mouse wheel | Navigate / Scroll |
| Enter/Space | Select / Play-Pause |
| Left/Right | Previous/Next track |
| Escape | Menu / Back |
| Q | Quit |

See [Simulator Guide](docs/008-simulator-guide.md) for complete documentation.

## Installing on Hardware

> **⚠️ WARNING: Hardware installation is NOT recommended at this time.**
>
> ZigPod OS is not bootable on real hardware. The instructions below are for **future reference only**.
> Attempting to flash may brick your device. Always have a full backup and recovery plan.
>
> **Note**: ZigPod uses a dual-boot approach that preserves your original Apple firmware. You can always boot back to the original OS by holding Menu during startup.

### Prerequisites

1. iPod Video 5th/5.5th Generation (A1136)
2. USB cable
3. Working Disk Mode (hold Menu+Select, then Select+Play)

### Installation Steps

1. **Test in simulator first** - Verify your build works in the simulator
2. **Create full backup** - Essential for recovery

```bash
# Put iPod in Disk Mode:
# Hold MENU + SELECT until Apple logo, then immediately hold SELECT + PLAY

# Create full disk backup (macOS - find your disk number first)
diskutil list | grep -i ipod
sudo dd if=/dev/diskX of=ipod_backup.img bs=1m status=progress
```

3. **Build ZigPod**

```bash
# Build firmware for ARM
zig build firmware

# Build the bootloader
zig build bootloader
```

4. **Install bootloader** (preserves original firmware)

```bash
# Install dual-boot bootloader using ipodpatcher
ipodpatcher -a zig-out/bin/zigpod-bootloader.bin
```

5. **Copy ZigPod firmware to iPod**

```bash
# Mount iPod in Disk Mode, then:
mkdir -p /Volumes/IPOD/.zigpod
cp zig-out/bin/firmware.bin /Volumes/IPOD/.zigpod/

# Safely eject
diskutil eject /dev/diskX
```

6. **Boot ZigPod** - Reset iPod (Menu + Select). ZigPod boots by default.

### Boot Mode Selection

| Button | Hold Duration | Action |
|--------|---------------|--------|
| None | - | Boot ZigPod (default) |
| Menu | 2 seconds | Boot original Apple firmware |
| Play | 2 seconds | Enter DFU update mode |
| Menu + Select | 5 seconds | Recovery mode |

### Uninstallation

```bash
# Restore original bootloader
ipodpatcher -u

# Optionally remove ZigPod files
rm -rf /Volumes/IPOD/.zigpod
```

### Recovery

If ZigPod fails to boot 3 times consecutively, the bootloader automatically falls back to Apple firmware. You can also:

1. **Enter Disk Mode manually**: Hold Menu+Select → when Apple logo appears → hold Select+Play
2. **Restore from backup**: `sudo dd if=ipod_backup.img of=/dev/diskX bs=1m status=progress`
3. **Full restore via iTunes**: iTunes can restore the iPod to factory state from Disk Mode

See [Boot Process](docs/hardware/BOOT_PROCESS.md) for detailed boot sequence documentation.

## Supported Audio Formats

| Format | Bit Depths | Sample Rates | Notes |
|--------|------------|--------------|-------|
| **WAV** | 8/16/24/32-bit, float | Up to 192kHz | PCM and WAVE_FORMAT_EXTENSIBLE |
| **AIFF** | 8/16/24/32-bit | Up to 192kHz | AIFF and AIFF-C |
| **FLAC** | 8-24 bit | Up to 192kHz | All compression levels |
| **MP3** | N/A | 32-48kHz | VBR/CBR 32-320 kbps, ID3v1/v2 tags |

## Project Structure

```
zigpod/
├── src/
│   ├── main.zig           # Entry point
│   ├── hal/               # Hardware Abstraction Layer
│   ├── kernel/            # Kernel (memory, interrupts, timer, DMA)
│   ├── drivers/           # Device drivers (LCD, click wheel, codec, storage)
│   ├── audio/             # Audio engine, decoders, DSP, album art
│   ├── ui/                # User interface (screens, menus, themes)
│   ├── library/           # Music library and database
│   ├── simulator/         # PP5021C simulator with SDL2 GUI
│   └── tools/             # iPod detection, flasher, recovery tools
├── docs/                  # Documentation
├── linker/                # Linker scripts
└── build.zig              # Build configuration
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Application Layer                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ File Browser│  │Music Browser│  │    Now Playing      │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                       UI Framework                           │
│  ┌────────┐  ┌────────┐  ┌─────────┐  ┌────────────────┐   │
│  │ Menus  │  │ Themes │  │ Overlays│  │ Settings/Persist│   │
│  └────────┘  └────────┘  └─────────┘  └────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                      Audio Engine                            │
│  ┌─────────┐  ┌─────────┐  ┌─────┐  ┌─────────┐  ┌──────┐  │
│  │ Decoders│  │   DSP   │  │Queue│  │Album Art│  │ DMA  │  │
│  │WAV/MP3/ │  │EQ/Bass/ │  │Mgmt │  │Extract/ │  │Pipe- │  │
│  │FLAC/AAC │  │Stereo   │  │     │  │Decode   │  │line  │  │
│  └─────────┘  └─────────┘  └─────┘  └─────────┘  └──────┘  │
├─────────────────────────────────────────────────────────────┤
│                   Hardware Abstraction                       │
│  ┌─────┐  ┌──────────┐  ┌───────┐  ┌───────┐  ┌─────────┐  │
│  │ LCD │  │Click Wheel│  │ Codec │  │  I2S  │  │ Storage │  │
│  └─────┘  └──────────┘  └───────┘  └───────┘  └─────────┘  │
├─────────────────────────────────────────────────────────────┤
│                     Kernel / Drivers                         │
│  ┌────────┐  ┌──────────┐  ┌─────┐  ┌─────┐  ┌──────────┐  │
│  │ Memory │  │Interrupts│  │Timer│  │ DMA │  │  FAT32   │  │
│  └────────┘  └──────────┘  └─────┘  └─────┘  └──────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Documentation

### Project Overview

| Document | Description |
|----------|-------------|
| [Mission Statement](MISSION.md) | Project vision and principles |
| [Audiophile Vision](docs/AUDIOPHILE_VISION.md) | Audio quality goals and technical roadmap |
| [Development Roadmap](docs/ROADMAP.md) | Current status and next steps |
| [Architecture](docs/ARCHITECTURE.md) | System design and components |

### User Documentation

| Document | Description |
|----------|-------------|
| [User Guide](docs/007-user-guide.md) | Using ZigPod on your device |
| [Simulator Guide](docs/008-simulator-guide.md) | Running and using the simulator |
| [Installation Guide](docs/INSTALLATION_GUIDE.md) | Installing on hardware |

### Developer Documentation

| Document | Description |
|----------|-------------|
| [PP5020 Hardware Reference](docs/hardware/PP5020_COMPLETE_REFERENCE.md) | Complete register reference (from Rockbox) |
| [Hardware Reference](docs/004-hardware-reference.md) | PP5021C registers and memory map |
| [Audio System](docs/AUDIO_SYSTEM.md) | Audio pipeline architecture |
| [iTunesDB Format](docs/005-itunesdb-format.md) | Music database format specification |

### Hardware Documentation

| Document | Description |
|----------|-------------|
| [Hardware Testing Protocol](docs/006-hardware-testing-protocol.md) | Safe hardware validation procedures |
| [Safe Init Sequences](docs/005-safe-init-sequences.md) | Verified initialization sequences |
| [Recovery Guide](docs/006-recovery-guide.md) | Device recovery procedures |

## Target Hardware

| Component | Specification |
|-----------|---------------|
| **Model** | iPod Video 5th Gen (A1136) |
| **SoC** | PortalPlayer PP5021C |
| **CPU** | Dual ARM7TDMI @ 80 MHz |
| **RAM** | 32MB / 64MB SDRAM |
| **Display** | 320x240 QVGA LCD |
| **Audio** | Wolfson WM8758 codec |
| **Storage** | 30-80GB HDD or iFlash adapter |

## Development

### Running Tests

```bash
# Run all tests (820+ tests)
zig build test

# Run with verbose output
zig build test 2>&1 | less
```

### Code Quality

```bash
# Check formatting
zig build fmt-check

# Auto-format
zig build fmt
```

### Development Workflow

1. Write tests first
2. Implement with mock HAL
3. Test in simulator
4. Deploy to hardware (with backup!)

## Safety Guidelines

Before deploying to real hardware:

1. **Always test in simulator first**
2. **Create and verify backups**
3. **Follow the [Hardware Testing Protocol](docs/006-hardware-testing-protocol.md)**
4. **Never flash the boot ROM**
5. **Keep a recovery device available**

## Contributing

Contributions welcome! The main areas needing work are:

### High Priority
- **COP Emulation** - The #1 blocker for full Rockbox support. Requires implementing the second ARM7TDMI core with mailbox communication.
- **Thread Context Synthesis** - Alternative to COP: manually create valid thread contexts so scheduler can run.

### Medium Priority
- **Audio Output** - Wire I2S controller to SDL2 audio
- **Additional Firmware** - Test with Apple's original firmware
- **Performance** - Optimize hot paths in CPU emulation

### How to Contribute
1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Ensure all tests pass (`zig build test`)
5. Submit a pull request

Read [JOURNEY.md](JOURNEY.md) for technical context on the architecture and challenges.

## Research Sources

- [Rockbox](https://github.com/Rockbox/rockbox) - Primary hardware reference
- [iPodLoader2](https://github.com/crozone/ipodloader2) - Bootloader reference
- [freemyipod.org](https://freemyipod.org) - Community resources

## License

MIT License - See [LICENSE](LICENSE) for details.

## Acknowledgments

- The [Rockbox](https://www.rockbox.org/) project for hardware documentation
- iPod Linux and freemyipod.org communities
- PortalPlayer reverse engineering contributors
