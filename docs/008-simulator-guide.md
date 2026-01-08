# ZigPod Simulator Guide

The ZigPod Simulator provides a complete PP5021C iPod Video emulation environment for development and testing without hardware.

## Overview

The simulator includes:
- **ARM7TDMI CPU Emulator**: Full instruction set support
- **Memory Bus**: IRAM, SDRAM, and peripheral simulation
- **LCD Display**: 320x240 RGB565 framebuffer visualization
- **Click Wheel**: Keyboard and mouse input mapping
- **Audio Output**: WAV file playback and capture
- **ATA Storage**: Disk image support for filesystem testing
- **I2C Devices**: WM8758 codec and PCF50605 PMU simulation

---

## Quick Start

### Building the Simulator

```bash
# Basic build (terminal mode only)
zig build sim

# Build with SDL2 GUI support
zig build sim -Dsdl2=true
```

### Running the Simulator

```bash
# Run with built-in demo program
zig build sim

# Run with SDL2 GUI
zig build sim -Dsdl2=true

# Play audio file (requires SDL2)
zig build sim -Dsdl2=true -- --audio music.wav
```

---

## Command Line Options

| Option | Short | Description |
|--------|-------|-------------|
| `--rom <file>` | `-r` | Load ROM/firmware binary |
| `--disk <file>` | `-d` | Attach disk image |
| `--audio <file>` | `-a` | Play WAV audio file (SDL2 only) |
| `--cycles <n>` | `-c` | Cycles per frame (default: 10000) |
| `--break <addr>` | `-b` | Set breakpoint at address |
| `--headless` | | Run without interactive mode |
| `--debug` | | Enable debug logging |
| `--help` | `-h` | Show help |

### Examples

```bash
# Basic simulator with demo
zig build sim

# Audio playback testing (GUI mode)
zig build sim -Dsdl2=true -- --audio test_audio.wav

# Debug mode with verbose logging
zig build sim -- --debug

# Set breakpoint for debugging
zig build sim -- --break 0x40000100

# Headless execution (CI/automated testing)
zig build sim -- --headless
```

> **Note**: The `--rom` option loads raw ARM binaries for advanced testing.
> The built-in demo program is sufficient for most development and testing.

---

## Operating Modes

### Terminal Mode (Default)

Text-based interface for debugging and development.

```
  ____  _       ____           _
 |_  / (_) __ _|  _ \ ___   __| |
  / /  | |/ _` | |_) / _ \ / _` |
 / /__ | | (_| |  __/ (_) | (_| |
/____||_|\__, |_|   \___/ \__,_|
         |___/   Simulator v0.1

Commands: [r]un, [s]tep, [c]ontinue, [p]rint regs, [m]emory, [l]cd, [q]uit

PC=0x00000000 >
```

**Commands:**

| Command | Description |
|---------|-------------|
| `r`, `run` | Run continuously |
| `s`, `step` | Single step instruction |
| `c`, `continue` | Run for one frame |
| `p`, `regs` | Print CPU registers |
| `m <addr>` | Dump memory at address |
| `l`, `lcd` | Show LCD display (ASCII art) |
| `h`, `help` | Show help |
| `q`, `quit` | Exit simulator |

### GUI Mode (SDL2)

Graphical interface with visual LCD and click wheel.

**Requirements:**
- SDL2 library installed
- Build with `-Dsdl2=true`

**Controls:**

| Input | Action |
|-------|--------|
| Arrow keys | Navigate (Menu/Play/Prev/Next) |
| Enter | Select |
| Space | Play/Pause |
| Escape / M | Menu |
| Mouse scroll | Rotate click wheel |
| Mouse drag on wheel | Rotate click wheel |
| Q | Quit |

### Headless Mode

For automated testing and CI pipelines.

```bash
zig build sim -- --headless -r test_suite.bin
```

Executes up to 1 million cycles and prints results.

---

## Simulator Architecture

### Memory Map

| Region | Start | End | Size | Description |
|--------|-------|-----|------|-------------|
| IRAM | `0x40000000` | `0x40020000` | 128KB | Internal RAM |
| SDRAM | `0x10000000` | `0x12000000` | 32MB | Main memory |
| Peripherals | `0x60000000` | `0x70000000` | - | I/O registers |

### Peripheral Registers

| Address | Register | Description |
|---------|----------|-------------|
| `0x60006000` | GPIO_OUT | GPIO output data |
| `0x60006004` | GPIO_EN | GPIO output enable |
| `0x60005000` | TIMER1_CFG | Timer 1 configuration |
| `0x60005004` | TIMER1_VAL | Timer 1 value |
| `0x60007000` | I2C_DATA | I2C data register |
| `0x60007004` | I2C_CTRL | I2C control register |
| `0xC0000000` | ATA_DATA | ATA data port |

---

## Creating Disk Images

### Empty Disk Image

```bash
# Create 60MB disk image
dd if=/dev/zero of=disk.img bs=1M count=60

# Format as FAT32 (macOS)
hdiutil attach -nomount disk.img
newfs_msdos -F 32 /dev/diskN
hdiutil detach /dev/diskN

# Format as FAT32 (Linux)
mkfs.vfat -F 32 disk.img
```

### From Real iPod

```bash
# Create image from iPod (macOS)
sudo dd if=/dev/diskN of=ipod_backup.img bs=4M

# Create image from iPod (Linux)
sudo dd if=/dev/sdX of=ipod_backup.img bs=4M
```

---

## Debugging

### Setting Breakpoints

```bash
# Command line
zig build sim -- -b 0x40000100

# Interactive
PC=0x00000000 > b 0x40000100
Breakpoint set at 0x40000100
```

### Examining State

```
PC=0x40000100 > p
Registers:
  R0:       0x00000000
  R1:       0x00000001
  R2:       0x40000000
  ...
  R13 (SP): 0x40017FF0
  R14 (LR): 0x40000050
  R15 (PC): 0x40000100

PC=0x40000100 > m 0x40000000
Memory at 0x40000000:
  40000000: E3A00001 E3A01002 E5801000 EAFFFFFC
  40000010: 00000000 00000000 00000000 00000000
```

### LCD Visualization

In terminal mode, use the `l` command to render the LCD:

```
PC=0x40000100 > l
┌────────────────────────────────────────┐
│▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│
│▓                                      ▓│
│▓   ████  ZigPod  ████                ▓│
│▓                                      ▓│
│▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│
└────────────────────────────────────────┘
```

---

## Audio Testing

### Playing Audio Files

```bash
# Play WAV file in GUI mode
zig build sim -Dsdl2=true -- --audio song.wav
```

**Controls during playback:**
- Space/Enter: Play/Pause
- Scroll wheel: Adjust volume
- Left/Right arrows: Seek 10 seconds
- Menu/Escape: Stop playback

### Capturing Audio Output

The simulator can capture audio output to WAV files for verification:

```zig
const wav_writer = @import("simulator/audio/wav_writer.zig");

var writer = try wav_writer.WavWriter.create("output.wav", 44100, 2);
defer writer.close();

// Write samples during simulation
try writer.writeSamples(samples);
```

---

## Profiling

The simulator includes a built-in profiler:

```zig
const profiler = @import("simulator/profiler/profiler.zig");

var prof = profiler.Profiler.init(allocator);
defer prof.deinit();

// Record during execution
prof.recordInstruction(cpu.pc, instruction);

// Generate report
try prof.dumpReport(stdout);
```

**Report output:**
```
Instruction Profile:
  Total instructions: 1,234,567
  Unique addresses: 456

  Top 10 hot spots:
    0x40001234: 45,678 (3.7%)
    0x40001238: 34,567 (2.8%)
    ...
```

---

## Integration with CI

### GitHub Actions Example

```yaml
name: Simulator Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Zig
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.2

      - name: Run Tests
        run: zig build test

      - name: Run Simulator Tests
        run: |
          zig build sim -- --headless -r tests/boot_test.bin
          zig build sim -- --headless -r tests/audio_test.bin
```

---

## Troubleshooting

### SDL2 Not Found

```
error: SDL2 library not found
```

**Solution:**
```bash
# macOS
brew install sdl2

# Ubuntu/Debian
sudo apt install libsdl2-dev

# Then rebuild
zig build sim -Dsdl2=true
```

### Simulator Hangs

If the simulator appears to hang:
1. Check for infinite loops in your code
2. Use breakpoints to identify the location
3. Run with `--debug` for verbose output
4. Use `--cycles` to limit execution

### No Display Output

If the LCD shows nothing:
1. Verify framebuffer writes to `0x40000000`
2. Check that your code initializes the display
3. Use `l` command in terminal mode to verify

---

## API Reference

### SimulatorState

```zig
pub const SimulatorState = struct {
    // Memory
    iram: [128 * 1024]u8,
    sdram: [32 * 1024 * 1024]u8,

    // LCD
    lcd_framebuffer: [320 * 240]u16,

    // Input
    button_state: u8,
    wheel_position: u8,

    // Methods
    pub fn run(cycles: u64) RunResult;
    pub fn stepCpu() ?StepResult;
    pub fn getCpuPc() u32;
    pub fn setCpuPc(pc: u32) void;
    pub fn getCpuReg(reg: u4) u32;
    pub fn addBreakpoint(addr: u32) bool;
    pub fn loadRom(data: []const u8) void;
};
```

### SimulatorConfig

```zig
pub const SimulatorConfig = struct {
    lcd_visualization: bool = true,
    audio_to_file: bool = true,
    audio_file_path: []const u8 = "simulator_audio.raw",
    speed_multiplier: f32 = 1.0,
    debug_logging: bool = false,
    disk_image_path: ?[]const u8 = null,
};
```

---

## See Also

- [Hardware Testing Protocol](006-hardware-testing-protocol.md) - For real hardware testing
- [User Guide](007-user-guide.md) - End-user documentation
- [Hardware Reference](004-hardware-reference.md) - PP5021C register documentation
