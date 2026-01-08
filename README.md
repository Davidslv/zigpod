# ZigPod OS

A custom operating system for the Apple iPod Video 5th Generation (2005), written entirely in Zig.

## Project Status

**Phase**: Integration & Polish (Phase 10)

The project has implemented all core OS components including hardware abstraction, kernel, drivers, audio engine, UI framework, and complete audio codec support. All 218 unit tests pass.

### Supported Audio Formats

| Format | Bit Depths | Features |
|--------|------------|----------|
| **WAV** | 8/16/24/32-bit PCM, 32-bit float | WAVE_FORMAT_EXTENSIBLE support |
| **AIFF** | 8/16/24/32-bit | AIFF-C support |
| **FLAC** | 8-32 bit | Lossless, all subframe types |
| **MP3** | VBR/CBR 32-320 kbps | MPEG 1/2/2.5 Layer III |

## Quick Start

### Prerequisites

- [Zig 0.15.2](https://ziglang.org/download/) or later
- Git

### Building

```bash
# Clone the repository
git clone https://github.com/Davidslv/zigpod.git
cd zigpod

# Run all tests
zig build test

# Build for ARM target (when ready for hardware)
zig build -Dtarget=arm-freestanding-eabi
```

### Running Tests

```bash
# Run all unit tests
zig build test

# Check code formatting
zig build fmt-check

# Auto-format code
zig build fmt
```

## Architecture

### Project Structure

```
zigpod/
├── build.zig           # Build configuration
├── build.zig.zon       # Package manifest
├── linker/
│   └── pp5021c.ld      # Linker script for PP5021C
├── src/
│   ├── main.zig        # Main entry point
│   ├── root.zig        # Root module (imports all modules for testing)
│   ├── hal/            # Hardware Abstraction Layer
│   │   ├── hal.zig     # HAL interface
│   │   ├── mock/       # Mock implementation for testing
│   │   └── pp5021c/    # PP5021C hardware implementation
│   ├── kernel/         # Kernel components
│   │   ├── boot.zig    # Boot sequence and exception handlers
│   │   ├── memory.zig  # Memory allocator
│   │   ├── interrupts.zig # Interrupt management
│   │   └── timer.zig   # Timer and delay functions
│   ├── drivers/        # Device drivers
│   │   ├── audio/      # Audio drivers (codec, I2S)
│   │   ├── display/    # LCD driver
│   │   ├── input/      # Click wheel driver
│   │   ├── storage/    # ATA and FAT32 drivers
│   │   ├── gpio.zig    # GPIO driver
│   │   ├── i2c.zig     # I2C driver
│   │   └── pmu.zig     # Power management driver
│   ├── audio/          # Audio playback engine
│   ├── ui/             # User interface framework
│   └── lib/            # Utility libraries
│       ├── ring_buffer.zig  # Ring buffer for streaming
│       ├── fixed_point.zig  # Fixed-point math for DSP
│       └── crc.zig          # CRC calculations
└── docs/               # Documentation
```

### Hardware Abstraction Layer (HAL)

The HAL provides a clean interface between hardware and software, enabling:
- **Mock HAL**: Run and test code on development machine
- **PP5021C HAL**: Run on actual iPod hardware

```zig
const hal = @import("hal/hal.zig");

// Use the current HAL (mock for testing, PP5021C on hardware)
hal.current_hal.delay_ms(100);
hal.current_hal.gpio_write(port, pin, true);
```

### Memory Management

The OS uses a fixed-block allocator suitable for embedded systems:

```zig
const memory = @import("kernel/memory.zig");

// Initialize the memory subsystem
memory.init();

// Allocate memory (automatically chooses appropriate block size)
const ptr = memory.alloc(128);

// Get memory statistics
const stats = memory.getStats();
```

Block sizes:
- Small: 64 bytes (256 blocks)
- Medium: 256 bytes (128 blocks)
- Large: 1024 bytes (64 blocks)

### Audio Playback

The audio engine handles codec control, I2S output, and buffering:

```zig
const audio = @import("audio/audio.zig");

// Initialize audio subsystem
try audio.init();

// Play audio with a decode callback
try audio.play(decodeCallback, trackInfo);

// Control playback
audio.pause();
audio.resumePlayback();
audio.togglePause();

// Volume control (-89 to +6 dB)
try audio.setVolumeMono(-10);
```

### UI Framework

The UI framework provides iPod-style menu navigation:

```zig
const ui = @import("ui/ui.zig");

// Initialize UI
try ui.init();

// Create and display menus
var menu = ui.createMenu("Main Menu");
_ = menu.addItem("Music", &musicCallback);
_ = menu.addItem("Settings", &settingsCallback);
ui.drawMenu(&menu);
```

### Click Wheel Input

The click wheel driver handles button presses and wheel gestures:

```zig
const clickwheel = @import("drivers/input/clickwheel.zig");

// Poll for input events
const event = try clickwheel.poll();

// Check button states
if (event.buttonPressed(clickwheel.Button.PLAY)) {
    // Handle play button
}

// Check wheel movement
const wheel_event = event.wheelEvent();
if (wheel_event == .clockwise) {
    // Handle scroll
}
```

### Storage and Filesystem

FAT32 filesystem support for reading music files:

```zig
const fat32 = @import("drivers/storage/fat32.zig");

// Mount the filesystem
try fat32.mount();

// Open and read files
const file = try fat32.openFile("/MUSIC/track.wav");
defer fat32.closeFile(file);

const bytes_read = try fat32.readFile(file, buffer);
```

## Target Hardware

| Component | Specification |
|-----------|---------------|
| Model | iPod Video 5th Generation (A1136) |
| SoC | PortalPlayer PP5021C |
| CPU | Dual ARM7TDMI @ 80 MHz |
| RAM | 32MB / 64MB SDRAM |
| Display | 320x240 QVGA LCD (BCM2722) |
| Audio | Wolfson WM8758 codec |
| Storage | 30-80GB HDD or iFlash SD adapter |
| PMU | Philips PCF50605 |
| Input | Capacitive click wheel (96 positions) |

## Memory Map

| Region | Start | End | Size | Description |
|--------|-------|-----|------|-------------|
| IRAM | 0x40000000 | 0x40020000 | 128KB | Internal RAM |
| SDRAM | 0x10000000 | 0x12000000 | 32MB | Main memory |
| Peripherals | 0x60000000 | 0x70000000 | - | I/O registers |
| ATA | 0xC0000000 | - | - | IDE interface |

## Troubleshooting

### Build Errors

**"unable to load 'X.zig': FileNotFound"**
- Ensure all source files are present
- Run `git status` to check for missing files

**"type has no member 'X'"**
- The API may have changed; check the module documentation
- Run `zig build test` to identify specific issues

### Test Failures

**"test 'X' failed"**
- Run with verbose output: `zig build test 2>&1 | less`
- Check test assertions match current implementation

### Hardware Issues (Future)

**Device not responding**
- Ensure Disk Mode works (hold SELECT+PLAY during boot)
- Check USB connection
- Verify device is detected by host OS

## Development Workflow

1. **Write tests first** - Create tests for new functionality
2. **Implement with mock HAL** - Use mock HAL for initial development
3. **Run tests** - `zig build test` must pass
4. **Format code** - `zig build fmt`
5. **Test on simulator** - (When available) Test in PP5021C simulator
6. **Test on hardware** - (When ready) Flash to iPod and test

## Documentation

| Document | Description |
|----------|-------------|
| [001-zigpod.md](docs/001-zigpod.md) | Project vision and guidelines |
| [002-plan.md](docs/002-plan.md) | High-level project plan |
| [003-implementation-plan.md](docs/003-implementation-plan.md) | Detailed implementation phases |
| [004-hardware-reference.md](docs/004-hardware-reference.md) | Hardware reference (registers, memory map) |
| [005-safe-init-sequences.md](docs/005-safe-init-sequences.md) | Verified safe initialization sequences |
| [006-recovery-guide.md](docs/006-recovery-guide.md) | Recovery procedures and safety guide |

## Safety Guidelines

**Before developing for real hardware:**

1. Read the [Safe Initialization Sequences](docs/005-safe-init-sequences.md)
2. Read the [Recovery Guide](docs/006-recovery-guide.md)
3. **ALWAYS** test in emulator/simulator first
4. **ALWAYS** verify Disk Mode works before testing
5. **ALWAYS** have a backup iPod for development
6. **NEVER** flash the boot ROM

## Research Sources

- [Rockbox Source Code](https://github.com/Rockbox/rockbox) - Primary hardware reference
- [iPodLoader2](https://github.com/crozone/ipodloader2) - Bootloader reference
- [WM8758 Datasheet](https://www.alldatasheet.com/view.jsp?Searchword=WM8758) - Audio codec
- [freemyipod.org](https://freemyipod.org) - Community resources and recovery

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Ensure all tests pass (`zig build test`)
5. Submit a pull request

## License

MIT License - See [LICENSE](LICENSE) for details.

## Acknowledgments

- The [Rockbox](https://www.rockbox.org/) project for extensive hardware documentation
- The iPod Linux and freemyipod.org communities
- Contributors to PortalPlayer reverse engineering efforts
