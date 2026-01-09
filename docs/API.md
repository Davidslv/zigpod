# ZigPod API Reference

This document provides API documentation for ZigPod's core modules.

## Table of Contents

- [Hardware Abstraction Layer (HAL)](#hardware-abstraction-layer)
- [Kernel](#kernel)
  - [Memory](#memory)
  - [Clock](#clock)
  - [DMA](#dma)
  - [Timer](#timer)
- [Audio](#audio)
  - [Audio Engine](#audio-engine)
  - [DSP](#dsp)
  - [Decoders](#decoders)
- [Drivers](#drivers)
  - [LCD Display](#lcd-display)
  - [Click Wheel](#click-wheel)
  - [Storage](#storage)
- [UI Framework](#ui-framework)

---

## Hardware Abstraction Layer

**Module**: `src/hal/hal.zig`

The HAL provides a unified interface to hardware, supporting both real PP5021C hardware and mock implementations for testing.

### Core Functions

```zig
// Delay in milliseconds
pub fn delayMs(ms: u32) void;

// Delay in microseconds
pub fn delayUs(us: u32) void;

// Get system tick count (milliseconds since boot)
pub fn getTicks() u32;

// Enter low-power sleep
pub fn sleep() void;
```

### HAL Interface

```zig
pub const HalInterface = struct {
    // Display
    lcd_init: fn() HalError!void,
    lcd_set_pixel: fn(x: u16, y: u16, color: u16) void,
    lcd_fill_rect: fn(x: u16, y: u16, w: u16, h: u16, color: u16) void,

    // Audio
    audio_init: fn(sample_rate: u32, channels: u8) HalError!void,
    audio_write: fn(samples: []const i16) usize,

    // Input
    clickwheel_init: fn() HalError!void,
    clickwheel_read_buttons: fn() u8,
    clickwheel_read_position: fn() u8,

    // Storage
    storage_init: fn() HalError!void,
    storage_read: fn(lba: u32, buffer: []u8) HalError!void,
    storage_write: fn(lba: u32, data: []const u8) HalError!void,
};
```

---

## Kernel

### Memory

**Module**: `src/kernel/memory.zig`

Fixed-block allocator with multiple pool sizes and DMA-aligned allocation.

#### Constants

```zig
pub const SMALL_BLOCK_SIZE: usize = 64;      // For small allocations
pub const MEDIUM_BLOCK_SIZE: usize = 256;    // For medium allocations
pub const LARGE_BLOCK_SIZE: usize = 1024;    // For large allocations
pub const XLARGE_BLOCK_SIZE: usize = 4096;   // For audio buffers
pub const HUGE_BLOCK_SIZE: usize = 16384;    // For DMA buffers
pub const DMA_ALIGNMENT: usize = 32;         // ARM cache line
```

#### Functions

```zig
// Initialize memory subsystem (call once at boot)
pub fn init() void;

// Allocate memory of given size
// Returns null if allocation fails
pub fn alloc(size: usize) ?[*]u8;

// Allocate DMA-aligned memory (32-byte aligned)
pub fn allocDma(size: usize) ?[*]align(DMA_ALIGNMENT) u8;

// Free previously allocated memory
pub fn free(ptr: [*]u8, size: usize) void;

// Free DMA-aligned memory
pub fn freeDma(ptr: [*]align(DMA_ALIGNMENT) u8, size: usize) void;

// Get maximum allocatable size
pub fn maxAllocSize() usize;  // Returns 16384

// Get memory statistics
pub fn getStats() MemoryStats;
```

#### MemoryStats

```zig
pub const MemoryStats = struct {
    small_free: usize,
    small_total: usize,
    medium_free: usize,
    medium_total: usize,
    large_free: usize,
    large_total: usize,
    xlarge_free: usize,
    xlarge_total: usize,
    huge_free: usize,
    huge_total: usize,

    pub fn totalFreeBytes(self: MemoryStats) usize;
    pub fn totalBytes(self: MemoryStats) usize;
    pub fn largestAvailable(self: MemoryStats) usize;
};
```

### Clock

**Module**: `src/kernel/clock.zig`

CPU clock and frequency scaling management.

#### Frequency Profiles

```zig
pub const FrequencyProfile = enum {
    performance,   // 80 MHz - maximum performance
    balanced,      // 66 MHz - balance of performance and power
    powersave,     // 48 MHz - reduced power consumption
    ultralow,      // 24 MHz - minimum power (UI only)
};
```

#### Functions

```zig
// Initialize clock subsystem
pub fn init() void;

// Set frequency profile
pub fn setProfile(profile: FrequencyProfile) void;

// Get current profile
pub fn getProfile() FrequencyProfile;

// Get current frequency in Hz
pub fn getFrequency() u32;

// Report CPU load for dynamic scaling (0-100%)
pub fn reportLoad(load_percent: u8) void;

// Request temporary performance boost
pub fn requestBoost(duration_ms: u32) void;

// Get estimated power consumption (0-100%)
pub fn estimatedPowerPercent() u8;
```

### DMA

**Module**: `src/kernel/dma.zig`

DMA controller with address validation for secure transfers.

#### Channels

```zig
pub const Channel = enum(u2) {
    audio = 0,      // I2S audio output
    storage = 1,    // IDE/ATA storage
    general_0 = 2,  // General purpose
    general_1 = 3,  // General purpose
};
```

#### Configuration

```zig
pub const Config = struct {
    ram_addr: usize,           // RAM buffer address
    peripheral_addr: usize,    // Peripheral register address
    length: usize,             // Transfer length in bytes
    request: Request,          // DMA request source
    burst: BurstSize,          // Burst size
    direction: Direction,      // Transfer direction
    interrupt: bool = true,    // Generate interrupt on completion
    ram_increment: bool = true,
    peripheral_increment: bool = false,
};
```

#### Functions

```zig
// Initialize DMA controller
pub fn init() void;

// Start DMA transfer (validates addresses first)
pub fn start(channel: Channel, config: Config) !void;

// Wait for transfer to complete
pub fn wait(channel: Channel, timeout_us: u32) !void;

// Check if channel is busy
pub fn isBusy(channel: Channel) bool;

// Abort a transfer
pub fn abort(channel: Channel) void;

// Validate memory address for DMA
pub fn validateAddress(addr: usize, length: usize, is_write: bool) ValidationError!void;
```

---

## Audio

### Audio Engine

**Module**: `src/audio/audio.zig`

Core audio playback engine with ring buffer and DMA support.

#### State

```zig
pub const PlaybackState = enum {
    stopped,
    playing,
    paused,
    buffering,
};
```

#### Functions

```zig
// Initialize audio subsystem
pub fn init() !void;

// Start playback
pub fn play() !void;

// Pause playback
pub fn pause() void;

// Stop playback
pub fn stop() void;

// Get current state
pub fn getState() PlaybackState;

// Set volume (0-100)
pub fn setVolume(volume: u8) void;

// Get current volume
pub fn getVolume() u8;
```

### DSP

**Module**: `src/audio/dsp.zig`

Digital signal processing functions with fixed-point math.

#### Volume Control

```zig
pub const VolumeControl = struct {
    current_volume: u16,      // Q8 (256 = 1.0)
    target_volume: u16,
    ramp_step: u16,           // Step per sample for ramping

    pub fn setVolume(self: *VolumeControl, volume: u8) void;
    pub fn applyWithRamp(self: *VolumeControl, samples: []i16) void;
};
```

#### Dithering

```zig
pub const Ditherer = struct {
    // TPDF dithering for bit depth reduction
    pub fn apply(self: *Ditherer, sample: i32, target_bits: u5) i16;
};
```

#### Resampling

```zig
pub const Resampler = struct {
    input_rate: u32,
    output_rate: u32,

    pub fn configure(self: *Resampler, input_rate: u32, output_rate: u32) void;
    pub fn resampleBuffer(self: *Resampler, input: []const i16, output: []i16) usize;
};
```

### Decoders

**Module**: `src/audio/decoders/decoders.zig`

#### Supported Formats

```zig
pub const DecoderType = enum {
    wav,     // WAV/PCM
    aiff,    // AIFF/AIFF-C
    flac,    // FLAC
    mp3,     // MP3 (MPEG-1/2 Layer III)
    aac,     // AAC-LC
    m4a,     // M4A container (AAC)
    unknown,
};
```

#### Format Detection

```zig
// Detect format from file header
pub fn detectFormat(header: []const u8) DecoderType;

// Check file extension
pub fn isSupportedExtension(ext: []const u8) bool;
```

#### Individual Decoders

Each decoder implements this interface:

```zig
pub const Decoder = struct {
    pub fn init(data: []const u8) !Decoder;
    pub fn decode(self: *Decoder, output: []i16) !usize;
    pub fn seek(self: *Decoder, sample: u64) !void;
    pub fn getSampleRate(self: *Decoder) u32;
    pub fn getChannels(self: *Decoder) u8;
    pub fn getBitDepth(self: *Decoder) u8;
    pub fn getTotalSamples(self: *Decoder) u64;
};
```

---

## Drivers

### LCD Display

**Module**: `src/drivers/display/lcd.zig`

320x240 QVGA display driver.

#### Constants

```zig
pub const WIDTH: u16 = 320;
pub const HEIGHT: u16 = 240;
pub const Color = u16;  // RGB565 format
```

#### Functions

```zig
// Initialize display
pub fn init() !void;

// Clear screen with color
pub fn clear(color: Color) void;

// Set single pixel
pub fn setPixel(x: u16, y: u16, color: Color) void;

// Fill rectangle
pub fn fillRect(x: u16, y: u16, w: u16, h: u16, color: Color) void;

// Draw rectangle outline
pub fn drawRect(x: u16, y: u16, w: u16, h: u16, color: Color) void;

// Draw horizontal/vertical lines
pub fn drawHLine(x: u16, y: u16, length: u16, color: Color) void;
pub fn drawVLine(x: u16, y: u16, length: u16, color: Color) void;

// Text rendering
pub fn drawString(x: u16, y: u16, text: []const u8, fg: Color, bg: ?Color) void;
pub fn drawStringCentered(y: u16, text: []const u8, fg: Color, bg: ?Color) void;

// Progress bar
pub fn drawProgressBar(x: u16, y: u16, w: u16, h: u16, percent: u8, fg: Color, bg: Color) void;

// Backlight control
pub fn setBacklight(on: bool) void;

// Create RGB565 color
pub fn rgb(r: u8, g: u8, b: u8) Color;
```

### Click Wheel

**Module**: `src/drivers/input/clickwheel.zig`

iPod click wheel and button input driver.

#### Button Constants

```zig
pub const Button = struct {
    pub const SELECT: u8 = 0x01;
    pub const RIGHT: u8 = 0x02;
    pub const LEFT: u8 = 0x04;
    pub const PLAY: u8 = 0x08;
    pub const MENU: u8 = 0x10;
    pub const HOLD: u8 = 0x20;
};
```

#### Input Event

```zig
pub const InputEvent = struct {
    buttons: u8,
    wheel_position: u8,     // 0-95
    wheel_delta: i8,        // Movement since last poll
    timestamp: u32,

    pub fn buttonPressed(self: InputEvent, button: u8) bool;
    pub fn anyButtonPressed(self: InputEvent) bool;
    pub fn wheelEvent(self: InputEvent) WheelEvent;
};
```

#### Functions

```zig
// Initialize click wheel
pub fn init() !void;

// Poll for input
pub fn poll() !InputEvent;

// Wait for button press (blocking)
pub fn waitForButton() !InputEvent;

// Check hold switch
pub fn isHoldOn() bool;
```

#### Wheel Acceleration

```zig
pub const WheelAccelerator = struct {
    pub fn update(self: *WheelAccelerator, delta: i8, timestamp: u32) i16;
    pub fn getMultiplier(self: *const WheelAccelerator) u16;  // Q8, 256 = 1.0x
    pub fn getVelocity(self: *const WheelAccelerator) u32;    // positions/second
};
```

#### Gesture Detection

```zig
pub const GestureDetector = struct {
    pub const GestureType = enum {
        none,
        tap,
        long_press,
        double_tap,
        hold,
        scrub_cw,
        scrub_ccw,
    };

    pub fn update(self: *GestureDetector, event: InputEvent) GestureType;
    pub fn getLastButton(self: *const GestureDetector) u8;
};
```

### Storage

**Module**: `src/drivers/storage/fat32.zig`

FAT32 filesystem driver.

#### Functions

```zig
// Initialize filesystem
pub fn init() !Fat32;

// Open file
pub fn openFile(self: *Fat32, path: []const u8) !File;

// Open directory
pub fn openDir(self: *Fat32, path: []const u8) !Directory;
```

#### File Operations

```zig
pub const File = struct {
    pub fn read(self: *File, buffer: []u8) !usize;
    pub fn seek(self: *File, position: u32) !void;
    pub fn tell(self: *File) u32;
    pub fn size(self: *File) u32;
    pub fn close(self: *File) void;
};
```

#### Directory Operations

```zig
pub const Directory = struct {
    pub fn next(self: *Directory) !?DirEntry;
    pub fn rewind(self: *Directory) void;
};

pub const DirEntry = struct {
    name: [11]u8,
    attributes: u8,
    file_size: u32,

    pub fn isFile(self: *const DirEntry) bool;
    pub fn isDirectory(self: *const DirEntry) bool;
};
```

---

## UI Framework

**Module**: `src/ui/ui.zig`

iPod-style menu and display framework.

### Theme

```zig
pub const Theme = struct {
    background: lcd.Color,
    foreground: lcd.Color,
    header_bg: lcd.Color,
    header_fg: lcd.Color,
    selected_bg: lcd.Color,
    selected_fg: lcd.Color,
    footer_bg: lcd.Color,
    footer_fg: lcd.Color,
    accent: lcd.Color,
    disabled: lcd.Color,
};

pub const default_theme: Theme;
pub const dark_theme: Theme;

pub fn setTheme(theme: Theme) void;
pub fn getTheme() Theme;
```

### Menu

```zig
pub const MenuItem = struct {
    label: []const u8,
    item_type: MenuItemType,
    icon: ?[]const u8 = null,
    enabled: bool = true,
    toggle_state: bool = false,
    value_str: ?[]const u8 = null,
    on_select: ?*const fn() void = null,
};

pub const Menu = struct {
    title: []const u8,
    items: []MenuItem,
    selected_index: u8,

    pub fn selectPrevious(self: *Menu) void;
    pub fn selectNext(self: *Menu) void;
    pub fn activate(self: *Menu) ?*Menu;
    pub fn goBack(self: *Menu) ?*Menu;
};
```

### Drawing Functions

```zig
pub fn drawHeader(title: []const u8) void;
pub fn drawFooter(text: []const u8) void;
pub fn drawMenu(menu: *Menu) void;
pub fn drawMessageBox(title: []const u8, message: []const u8) void;
pub fn drawProgress(y: u16, progress: u8, label: []const u8) void;
pub fn drawNowPlaying(info: NowPlayingInfo) void;
```

### Overlay System

```zig
pub const OverlayState = struct {
    pub fn showVolume(self: *OverlayState, volume: u8, timestamp: u32) void;
    pub fn showBrightness(self: *OverlayState, brightness: u8, timestamp: u32) void;
    pub fn showHold(self: *OverlayState, timestamp: u32) void;
    pub fn showLowBattery(self: *OverlayState, percent: u8, timestamp: u32) void;
    pub fn showCharging(self: *OverlayState, percent: u8, timestamp: u32) void;
    pub fn isVisible(self: *const OverlayState, current_time: u32) bool;
};

pub fn drawOverlay(current_time: u32) void;
```

### Battery Status

```zig
pub const BatteryStatus = struct {
    percent: u8,
    is_charging: bool,
    is_low: bool,
};

pub fn updateBatteryStatus(percent: u8, charging: bool) void;
pub fn getBatteryStatus() BatteryStatus;
pub fn drawBatteryIcon(x: u16, y: u16, percent: u8, low: bool) void;
pub fn drawHeaderWithStatus(title: []const u8) void;
```

---

## Error Handling

Most ZigPod functions use error unions for fallible operations:

```zig
// Common error types
pub const HalError = error{
    NotInitialized,
    DeviceNotReady,
    Timeout,
    CommunicationError,
    InvalidParameter,
};

// Usage pattern
const result = try operation();
// or
if (operation()) |value| {
    // use value
} else |err| {
    // handle error
}
```

---

## Thread Safety

ZigPod is designed for single-threaded execution on ARM7TDMI. The dual-core PP5021C typically runs OS on one core. If using both cores:

1. Use interrupt-safe access patterns for shared data
2. Disable interrupts during critical sections
3. Use DMA completion callbacks for async operations

```zig
const interrupts = @import("kernel/interrupts.zig");

// Critical section
interrupts.disable();
defer interrupts.enable();
// ... critical code ...
```
