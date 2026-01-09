# ZigPod Architecture Overview

This document describes the software architecture of ZigPod, a custom firmware for iPod Classic 5th/5.5th generation devices.

## Design Principles

1. **Memory Safety**: Leverage Zig's compile-time checks to prevent buffer overflows and memory corruption
2. **Hardware Abstraction**: Clean separation between hardware-specific and portable code
3. **Minimal Footprint**: Target < 400KB binary, < 5MB RAM usage
4. **Battery Efficiency**: Minimize CPU cycles, aggressive power management
5. **Testability**: Mock HAL enables cross-platform unit testing
6. **Reliability**: Graceful degradation, automatic recovery from failures

---

## System Layers

```
┌─────────────────────────────────────────────────────────────────────┐
│                        APPLICATION LAYER                             │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐   │
│  │   UI    │  │  Audio  │  │ Library │  │Settings │  │  App    │   │
│  │ System  │  │ Engine  │  │ Manager │  │         │  │  Main   │   │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘   │
└───────┼────────────┼────────────┼────────────┼────────────┼────────┘
        │            │            │            │            │
┌───────┼────────────┼────────────┼────────────┼────────────┼────────┐
│       │      SERVICE LAYER      │            │            │        │
│  ┌────▼────┐  ┌────▼────┐  ┌────▼────┐  ┌────▼────┐              │
│  │  Theme  │  │ Decoder │  │  File   │  │  Power  │              │
│  │ Engine  │  │ Manager │  │ System  │  │ Manager │              │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘              │
└───────┼────────────┼────────────┼────────────┼───────────────────┘
        │            │            │            │
┌───────┼────────────┼────────────┼────────────┼───────────────────┐
│       │       DRIVER LAYER      │            │                    │
│  ┌────▼────┐  ┌────▼────┐  ┌────▼────┐  ┌────▼────┐  ┌─────────┐ │
│  │   LCD   │  │  Codec  │  │   ATA   │  │   PMU   │  │ Click   │ │
│  │ Driver  │  │ Driver  │  │ Driver  │  │ Driver  │  │  Wheel  │ │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘ │
└───────┼────────────┼────────────┼────────────┼────────────┼──────┘
        │            │            │            │            │
┌───────┴────────────┴────────────┴────────────┴────────────┴──────┐
│                    HARDWARE ABSTRACTION LAYER                     │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │                     HAL Interface                             │ │
│  │  GPIO │ I2C │ I2S │ ATA │ LCD │ USB │ DMA │ Timer │ PMU     │ │
│  └──────────────────────────────────────────────────────────────┘ │
│         │                                                         │
│  ┌──────▼──────┐  ┌─────────────┐  ┌─────────────┐               │
│  │  PP5021C    │  │    Mock     │  │  Simulator  │               │
│  │    HAL      │  │    HAL      │  │    HAL      │               │
│  └─────────────┘  └─────────────┘  └─────────────┘               │
└──────────────────────────────────────────────────────────────────┘
        │                   │                 │
┌───────▼───────┐   ┌───────▼───────┐ ┌───────▼───────┐
│   PP5021C     │   │  Unit Tests   │ │  SDL2 Window  │
│   Hardware    │   │               │ │               │
└───────────────┘   └───────────────┘ └───────────────┘
```

---

## Directory Structure

```
zigpod/
├── src/
│   ├── main.zig                 # Entry point (firmware)
│   ├── root.zig                 # Module exports
│   │
│   ├── kernel/                  # Core system
│   │   ├── bootloader.zig       # Boot sequence, dual-boot
│   │   └── usb_dfu.zig          # USB firmware update
│   │
│   ├── hal/                     # Hardware Abstraction
│   │   ├── hal.zig              # HAL interface definition
│   │   ├── pp5021c/             # Real hardware HAL
│   │   │   ├── pp5021c.zig      # Implementation
│   │   │   └── registers.zig    # Register definitions
│   │   └── mock/                # Testing HAL
│   │       └── mock.zig         # Mock implementation
│   │
│   ├── drivers/                 # Device drivers
│   │   ├── storage/
│   │   │   ├── ata.zig          # ATA/IDE driver
│   │   │   ├── storage_detect.zig # HDD/Flash detection
│   │   │   ├── fat32.zig        # FAT32 filesystem
│   │   │   └── mbr.zig          # Partition table
│   │   ├── display/
│   │   │   └── lcd.zig          # LCD driver
│   │   ├── audio/
│   │   │   ├── codec.zig        # WM8758 codec
│   │   │   └── i2s.zig          # I2S interface
│   │   ├── input/
│   │   │   └── clickwheel.zig   # Click wheel driver
│   │   ├── power.zig            # Power management
│   │   └── pmu.zig              # PCF50605 PMU
│   │
│   ├── audio/                   # Audio subsystem
│   │   ├── audio.zig            # Audio engine
│   │   ├── decoders/
│   │   │   ├── wav.zig          # WAV decoder
│   │   │   ├── aiff.zig         # AIFF decoder
│   │   │   ├── mp3.zig          # MP3 decoder (stub)
│   │   │   ├── flac.zig         # FLAC decoder (stub)
│   │   │   └── aac.zig          # AAC decoder (stub)
│   │   └── effects/
│   │       └── eq.zig           # Equalizer
│   │
│   ├── ui/                      # User interface
│   │   ├── ui.zig               # UI system core
│   │   ├── menu.zig             # Menu system
│   │   ├── now_playing.zig      # Now Playing screen
│   │   ├── file_browser.zig     # File browser
│   │   ├── settings.zig         # Settings screen
│   │   └── install_progress.zig # Firmware update UI
│   │
│   ├── app/                     # Application logic
│   │   └── app.zig              # Main application
│   │
│   ├── fs/                      # Filesystem
│   │   ├── fat32.zig            # FAT32 implementation
│   │   └── itunesdb.zig         # iTunes database
│   │
│   ├── lib/                     # Utilities
│   │   ├── ring_buffer.zig      # Circular buffer
│   │   └── fixed_point.zig      # Fixed-point math
│   │
│   ├── debug/                   # Debugging
│   │   ├── logger.zig           # Logging system
│   │   ├── telemetry.zig        # Event recording
│   │   └── crash_store.zig      # Crash logging
│   │
│   ├── simulator/               # Desktop simulator
│   │   ├── main.zig             # Simulator entry
│   │   └── simulator.zig        # SDL2 implementation
│   │
│   └── tools/                   # Utilities
│       └── flasher/             # Firmware flasher
│
├── linker/
│   └── pp5021c.ld               # Linker script
│
├── docs/                        # Documentation
│   ├── hardware/                # Hardware docs
│   └── ...                      # Other docs
│
├── build.zig                    # Build configuration
└── tests/                       # Additional tests
```

---

## Component Details

### Hardware Abstraction Layer (HAL)

The HAL provides a uniform interface to hardware, enabling:
- Real hardware execution (PP5021C)
- Unit testing (Mock HAL)
- Desktop development (Simulator)

```zig
// HAL interface (src/hal/hal.zig)
pub const Hal = struct {
    // System
    init: *const fn () HalError!void,
    get_ticks_us: *const fn () u64,
    sleep_us: *const fn (us: u32) void,

    // GPIO
    gpio_set_direction: *const fn (port: u8, pin: u8, dir: Direction) void,
    gpio_read: *const fn (port: u8, pin: u8) bool,
    gpio_write: *const fn (port: u8, pin: u8, value: bool) void,

    // I2C
    i2c_write: *const fn (addr: u7, data: []const u8) HalError!void,
    i2c_read: *const fn (addr: u7, buffer: []u8) HalError!void,

    // I2S
    i2s_init: *const fn (config: I2sConfig) HalError!void,
    i2s_write: *const fn (samples: []const i16) HalError!usize,

    // ATA
    ata_init: *const fn () HalError!void,
    ata_identify: *const fn () HalError!AtaDeviceInfo,
    ata_read_sectors: *const fn (lba: u64, count: u16, buffer: []u8) HalError!void,
    ata_write_sectors: *const fn (lba: u64, count: u16, data: []const u8) HalError!void,

    // ... more interfaces
};

// Global HAL instance
pub var current_hal: Hal = undefined;
```

### Driver Layer

Drivers provide high-level interfaces to hardware peripherals:

```zig
// ATA driver example (src/drivers/storage/ata.zig)
pub fn init() !void {
    try hal.current_hal.ata_init();
    device_info = try hal.current_hal.ata_identify();
    storage_detect.initFromAtaInfo(device_info.?);
}

pub fn readSectors(lba: u64, count: u16, buffer: []u8) !void {
    // Validation, logging, telemetry
    try hal.current_hal.ata_read_sectors(lba, count, buffer);
}
```

### Audio Engine

The audio engine manages playback with these responsibilities:
- Decoder selection based on file type
- Sample buffer management (double-buffering)
- Sample rate conversion
- Volume and effects processing
- Output to I2S via DMA

```zig
// Audio state machine
pub const AudioState = enum {
    stopped,
    playing,
    paused,
    seeking,
    loading,
};

// Playback control
pub fn play() !void {
    if (state == .stopped) {
        try loadCurrentTrack();
    }
    state = .playing;
    startDmaTransfer();
}
```

### UI System

The UI system uses a screen-based architecture:

```zig
pub const Screen = enum {
    main_menu,
    now_playing,
    file_browser,
    settings,
    // ...
};

// Each screen implements:
pub const ScreenInterface = struct {
    draw: *const fn () void,
    handleInput: *const fn (event: InputEvent) void,
    update: *const fn (dt: u32) void,
};
```

**Rendering Pipeline**:
1. Clear framebuffer (or dirty regions only)
2. Draw background
3. Draw UI elements (menus, text, icons)
4. Draw overlays (volume, notifications)
5. Flush to LCD

---

## Memory Management

### Static Allocation

ZigPod primarily uses static allocation for predictability:

```zig
// Audio buffer (compile-time sized)
var audio_buffer: [BUFFER_SIZE]i16 = undefined;

// UI element pool
var menu_items: [MAX_MENU_ITEMS]MenuItem = undefined;
```

### Heap Usage

Limited heap for dynamic needs:

```zig
// File paths, temporary buffers
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
```

### Memory Map

```
0x40000000 ┌─────────────────────┐
           │ Reserved (4 KB)     │
0x40001000 ├─────────────────────┤
           │ Code + RO Data      │  ~300 KB
           │ (Firmware)          │
0x4004D000 ├─────────────────────┤
           │ RW Data + BSS       │  ~100 KB
           │                     │
0x40065000 ├─────────────────────┤
           │ Heap                │  ~27 MB
           │ (Dynamic allocation)│
           │                     │
0x41B00000 ├─────────────────────┤
           │ Audio Buffer        │  512 KB
           │ (Uncached for DMA)  │
0x41B80000 ├─────────────────────┤
           │ Framebuffer         │  150 KB
           │ (320x240x16)        │
0x41BA6000 ├─────────────────────┤
           │ Stacks              │  22 KB
           │ Main: 16KB          │
           │ IRQ: 4KB            │
           │ FIQ: 2KB            │
0x41FFFFFF └─────────────────────┘
```

---

## Concurrency Model

### Current: Single-Threaded with Polling

```
Main Loop:
┌────────────────────────────────────┐
│  while (true) {                    │
│    input.poll();      // ~1ms      │
│    audio.process();   // ~5ms      │
│    ui.update();       // ~10ms     │
│    ui.draw();         // ~16ms     │
│  }                                 │
└────────────────────────────────────┘
```

### Target: Interrupt-Driven

```
Main Loop (Idle):
┌────────────────────────────────────┐
│  while (true) {                    │
│    wfi();  // Wait for interrupt   │
│  }                                 │
└────────────────────────────────────┘

IRQ Handler:
┌────────────────────────────────────┐
│  switch (irq_source) {             │
│    .timer => ui.tick(),            │
│    .gpio => input.handleButton(),  │
│    .ata => storage.handleComplete()│
│  }                                 │
└────────────────────────────────────┘

FIQ Handler (High Priority):
┌────────────────────────────────────┐
│  // Audio DMA complete             │
│  audio.fillNextBuffer();           │
│  dma.ack();                        │
└────────────────────────────────────┘
```

---

## Data Flow

### Audio Playback Pipeline

```
┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐
│  File   │───▶│ Decoder │───▶│ Effects │───▶│ Buffer  │───▶│   I2S   │
│ System  │    │(MP3/FLAC)   │ (EQ/Vol)│    │ (DMA)   │    │ (Codec) │
└─────────┘    └─────────┘    └─────────┘    └─────────┘    └─────────┘
     │              │              │              │              │
     │              │              │              │              │
   Read          Decode         Process        Transfer       Output
  Sectors        Frames         Samples        to DMA        to DAC
```

### User Input Flow

```
┌───────────┐    ┌───────────┐    ┌───────────┐    ┌───────────┐
│  Click    │───▶│  Driver   │───▶│   App     │───▶│    UI     │
│  Wheel    │    │           │    │  Router   │    │  Screen   │
└───────────┘    └───────────┘    └───────────┘    └───────────┘
      │               │               │               │
      │               │               │               │
   Hardware        Debounce        Dispatch        Handle
    Event          + Parse          Event          Action
```

---

## Error Handling

### Error Types

```zig
pub const HalError = error{
    NotInitialized,
    DeviceNotReady,
    Timeout,
    InvalidParameter,
    HardwareError,
    TransferError,
};

pub const AudioError = error{
    InvalidFormat,
    DecoderError,
    BufferOverrun,
    BufferUnderrun,
};
```

### Error Propagation

```zig
// Errors propagate up the call stack
pub fn playFile(path: []const u8) !void {
    const file = try fs.open(path);      // May fail
    defer file.close();

    const header = try parseHeader(file); // May fail
    try decoder.init(header);             // May fail
    try audio.play();                     // May fail
}

// Caller handles or propagates
app.playFile(path) catch |err| {
    ui.showError("Playback failed: {}", .{err});
};
```

### Recovery Strategies

1. **Retry**: Transient errors (I2C timeout)
2. **Fallback**: Use alternative (skip corrupt track)
3. **User Notification**: Display error message
4. **Safe Mode**: Boot with minimal features
5. **Factory Reset**: Last resort recovery

---

## Testing Strategy

### Unit Tests

```zig
// In-file tests with Mock HAL
test "ata read sectors" {
    mock.init();
    defer mock.deinit();

    try ata.init();

    var buffer: [512]u8 = undefined;
    try ata.readSectors(0, 1, &buffer);

    try testing.expect(buffer[0] == expected_value);
}
```

### Integration Tests

```zig
// Simulator-based integration tests
test "play wav file" {
    simulator.init();
    defer simulator.deinit();

    try audio.loadFile("test.wav");
    try audio.play();

    // Verify audio output
    const samples = simulator.getAudioOutput();
    try testing.expect(samples.len > 0);
}
```

### Hardware Tests

```zig
// Run on actual device
pub fn runHardwareTests() void {
    testLcd();
    testAudio();
    testStorage();
    testButtons();
    testBattery();
}
```

---

## Build System

### Build Targets

```bash
# Firmware for real hardware
zig build                        # Default: ARM release build

# Simulator for development
zig build sim                    # Desktop simulator

# Tests
zig build test                   # Run all tests

# Specific configurations
zig build -Dtarget=arm-freestanding-eabi  # Cross-compile
zig build -Doptimize=Debug                # Debug build
```

### Build Outputs

```
zig-out/
├── bin/
│   ├── zigpod                   # ARM firmware binary
│   └── zigpod-sim               # Desktop simulator
└── lib/
    └── libzigpod.a              # Static library
```

---

## Security Considerations

### Firmware Integrity

- Bootloader validates firmware checksum
- Optional Ed25519 signature verification
- Rollback protection via version checking

### Memory Safety

- Zig's bounds checking prevents buffer overflows
- No dynamic memory in critical paths
- Stack canaries for overflow detection

### USB Security

- DFU mode requires minimum battery level
- Firmware validation before write
- No arbitrary code execution via USB

---

## Performance Optimization

### Critical Paths

1. **Audio Output**: Must be interrupt-driven, < 1ms latency
2. **Decoder**: Must keep up with sample rate (e.g., 44.1 kHz)
3. **UI Rendering**: Target 30 FPS (33ms per frame)

### Optimization Techniques

- IRAM for hot code paths
- DMA for bulk transfers
- Lookup tables for math operations
- Dirty rectangle rendering
- Lazy initialization

### Profiling

```zig
// Built-in timing instrumentation
const start = hal.current_hal.get_ticks_us();
// ... code to measure ...
const elapsed = hal.current_hal.get_ticks_us() - start;
log.debug("Operation took {d}us", .{elapsed});
```

---

## References

- [Rockbox Source Code](https://github.com/Rockbox/rockbox) - Reference implementation
- [iPodLoader2](https://github.com/crozone/ipodloader2) - Bootloader reference
- [ARM7TDMI Technical Reference](https://developer.arm.com/documentation/ddi0210/c/)
- [Zig Language Reference](https://ziglang.org/documentation/master/)
