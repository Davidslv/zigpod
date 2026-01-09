# ZigPod Logging Integration Guide

This guide explains how to use ZigPod's logging system for debugging, monitoring, and troubleshooting both during development and on real hardware.

## Overview

ZigPod uses a dual-mode logging system:

| Mode | When | Destination | Latency |
|------|------|-------------|---------|
| **Real-time** | USB connected | USB CDC serial | Immediate |
| **Persistent** | Any time | Disk `/ZIGPOD/LOGS/` | Buffered |
| **Crash** | On fatal error | Reserved disk area | Immediate |

Since JTAG is not accessible on iPod Classic 5.5G, all debugging must use USB-based logging.

---

## Quick Start

### 1. Add Logging to Your Module

```zig
const std = @import("std");

// Import scoped logger for your category
const log = @import("debug/logger.zig").scoped(.audio);  // or .storage, .ui, .power, etc.

pub fn myFunction() !void {
    log.info("Starting operation", .{});

    const result = doSomething() catch |err| {
        log.err("Operation failed: {s}", .{@errorName(err)});
        return err;
    };

    log.debug("Got result: {d}", .{result});
}
```

### 2. View Logs in Real-Time (USB Connected)

```bash
# macOS
screen /dev/tty.usbmodem* 115200

# Linux
screen /dev/ttyACM0 115200

# Or use the ZigPod tool
./zigpod-serial --port /dev/tty.usbmodem*
```

### 3. Extract Logs After Testing (USB Disk Mode)

```bash
# Reboot iPod into Apple firmware (Menu+Select)
# Connect USB, mount as disk
cp /Volumes/IPOD/ZIGPOD/LOGS/* ~/debug/

# Analyze
./zigpod-telemetry analyze ~/debug/telemetry.bin
cat ~/debug/session.txt
```

---

## Log Levels

| Level | Function | When to Use | Destinations |
|-------|----------|-------------|--------------|
| `trace` | `log.trace()` | Very verbose, per-frame/per-sample | CDC only |
| `debug` | `log.debug()` | Detailed debugging info | CDC + Disk |
| `info` | `log.info()` | Normal operation events | CDC + Disk |
| `warn` | `log.warn()` | Potential issues, recoverable | CDC + Disk + Telemetry |
| `err` | `log.err()` | Failures, handled errors | CDC + Disk + Telemetry |
| `fatal` | `log.fatal()` | Unrecoverable, triggers crash store | All + Crash Store |

### Guidelines

- **TRACE**: Use sparingly. Per-sector reads, per-sample processing. Disabled by default.
- **DEBUG**: Function entry/exit, intermediate values, state changes.
- **INFO**: User-visible operations: "Loading file", "Playback started", "Connected".
- **WARN**: Unexpected but handled: buffer underrun, retry, fallback.
- **ERROR**: Operation failed but system continues: file not found, decode error.
- **FATAL**: System cannot continue: stack overflow, hardware fault.

---

## Categories

Use the appropriate category for filtering and organization:

| Category | Constant | Use For |
|----------|----------|---------|
| System | `.system` | Boot, shutdown, general system events |
| Audio | `.audio` | Playback, decoding, DSP, codec |
| Storage | `.storage` | ATA, FAT32, file operations |
| UI | `.ui` | Screen changes, input handling |
| Power | `.power` | Battery, charging, sleep |
| USB | `.usb` | USB connection, CDC, MSC |
| Input | `.input` | Click wheel, buttons |

### Creating a Scoped Logger

```zig
// At the top of your file
const log = @import("debug/logger.zig").scoped(.audio);

// Then use throughout the file
log.info("Message", .{});  // Automatically tagged as [AUD]
```

---

## Telemetry Events

For structured data that needs post-mortem analysis, use telemetry:

```zig
const telemetry = @import("debug/telemetry.zig");

// Record an event
telemetry.record(.audio_buffer_underrun, count, buffer_level);
telemetry.record(.ata_read, sector_count, @truncate(lba));

// Record errors
telemetry.recordError(error_code, context);

// Performance markers
telemetry.perfStart(1);  // Start marker ID 1
// ... do work ...
telemetry.perfEnd(1);    // End marker ID 1
```

### Available Event Types

```zig
// System
.boot_start, .boot_complete, .shutdown, .hard_fault, .watchdog_reset

// Audio
.audio_init, .audio_start, .audio_stop
.audio_buffer_underrun, .audio_buffer_overrun
.audio_decode_error, .audio_dma_complete
.audio_sample_rate_change

// Storage
.ata_init, .ata_read, .ata_write
.ata_error, .ata_timeout
.fat32_mount, .fat32_error

// Display
.lcd_init, .lcd_refresh, .lcd_error

// Input
.button_press, .button_release, .wheel_move

// Power
.battery_read, .power_state_change
.charging_start, .charging_stop, .low_battery

// Errors
.error_recorded, .panic, .assertion_failed

// Performance
.perf_mark_start, .perf_mark_end, .frame_time, .cpu_load
```

---

## Crash Store

For fatal errors, use the crash store to preserve debugging info across reboots:

```zig
const crash_store = @import("debug/crash_store.zig");

// Record a panic (called automatically by panic handler)
crash_store.recordPanic(pc_address, "Error message");

// Record an assertion failure
crash_store.recordAssertion(@src().file, @src().line, "condition failed");

// Record general crash
crash_store.recordCrash(
    .data_abort,  // Exception type
    pc,           // Program counter
    lr,           // Link register
    sp,           // Stack pointer
    cpsr,         // Status register
    error_code,
    "Description of what happened"
);
```

### Exception Types

```zig
.unknown
.undefined_instruction
.software_interrupt
.prefetch_abort
.data_abort
.irq
.fiq
.panic
.watchdog
.assertion
.stack_overflow
.out_of_memory
.hardware_error
```

---

## Integration Examples

### Audio Module (src/audio/audio.zig)

```zig
const log = @import("../debug/logger.zig").scoped(.audio);
const telemetry = @import("../debug/telemetry.zig");

pub fn init() !void {
    log.info("Initializing audio engine", .{});

    try codec.preinit();
    log.debug("Codec pre-init complete", .{});

    try i2s.init(.{ .sample_rate = 44100 });
    log.debug("I2S initialized at {d}Hz", .{44100});

    log.info("Audio engine ready", .{});
}

pub fn loadFile(path: []const u8) !void {
    log.info("Loading file: {s}", .{path});

    const data = fs.readFile(path) catch |err| {
        log.err("Failed to read file: {s}", .{@errorName(err)});
        return err;
    };

    log.debug("Read {d} bytes", .{data.len});

    const format = detectFormat(data);
    log.debug("Detected format: {s}", .{@tagName(format)});

    // ... decode and play
    log.info("Playing: {d}Hz, {d}-bit", .{sample_rate, bits});
}

pub fn process() !void {
    // Detect buffer underrun
    if (buffer.isEmpty() and state == .playing) {
        underrun_count += 1;
        log.warn("Buffer underrun (count={d})", .{underrun_count});
        telemetry.record(.audio_buffer_underrun, underrun_count, 0);
    }
}
```

### Storage Module (src/drivers/storage/ata.zig)

```zig
const log = @import("../../debug/logger.zig").scoped(.storage);
const telemetry = @import("../../debug/telemetry.zig");

pub fn init() !void {
    log.info("Initializing ATA driver", .{});
    telemetry.record(.ata_init, 0, 0);

    try hal.ata_init();
    const info = try hal.ata_identify();

    const capacity_gb = info.total_sectors * 512 / (1024 * 1024 * 1024);
    log.info("ATA device: {d}GB", .{capacity_gb});
}

pub fn readSectors(lba: u64, count: u16, buffer: []u8) !void {
    log.trace("Reading {d} sectors at LBA {d}", .{count, lba});
    telemetry.record(.ata_read, count, @truncate(lba));

    hal.ata_read_sectors(lba, count, buffer) catch |err| {
        read_errors += 1;
        log.err("Read failed at LBA {d}: {s}", .{lba, @errorName(err)});
        telemetry.record(.ata_error, read_errors, @truncate(lba));
        return err;
    };
}
```

---

## Configuring Log Level

At runtime, you can adjust the minimum log level:

```zig
const logger = @import("debug/logger.zig");

// Set minimum level (default is .info)
logger.configure(.{
    .min_level = .debug,      // Show debug and above
    .colors = true,           // ANSI colors in terminal
    .timestamps = true,       // Include timestamps
    .categories = true,       // Show category tags
    .immediate_flush = true,  // Flush on every error
});
```

---

## Log Output Format

```
[    1234] INFO  [AUD] Audio engine ready (buffer=4096 samples)
[    1235] DEBUG [STO] Reading 8 sectors at LBA 12345
[    1240] WARN  [AUD] Buffer underrun detected (count=1)
[    1250] ERROR [STO] Read failed at LBA 99999: Timeout (errors=1)
```

Format: `[timestamp_ms] LEVEL [CATEGORY] Message`

---

## Debugging Workflow

### During Development (Simulator)

1. Set log level to DEBUG or TRACE
2. Run simulator: `zig build sim`
3. Logs appear in terminal

### On Hardware (USB Connected)

1. Connect USB cable
2. Open serial terminal: `screen /dev/tty.usbmodem* 115200`
3. Logs stream in real-time
4. Type `help` for interactive commands

### On Hardware (Standalone)

1. Run tests on device
2. Observe error indicator in status bar (if issues)
3. Reboot to Apple firmware (Menu+Select)
4. Connect USB, mount as disk
5. Copy `/ZIGPOD/LOGS/*` to computer
6. Analyze with `zigpod-telemetry analyze telemetry.bin`

### Crash Analysis

1. If crash occurred, check `/ZIGPOD/LOGS/crash.log`
2. Note PC address from crash log
3. Convert to source line: `arm-none-eabi-addr2line -e zigpod.elf 0x40001234`
4. Review telemetry events leading up to crash

---

## Best Practices

### DO

- Log at function boundaries (entry/exit for important functions)
- Include relevant values in log messages
- Use appropriate log levels
- Add telemetry for events you'll need to analyze later
- Log errors before returning them
- Include context (file names, sizes, addresses)

### DON'T

- Log inside tight loops (use TRACE level if needed)
- Log sensitive data
- Use string formatting for TRACE logs in production
- Forget to handle the case where logging fails
- Log the same error multiple times

### Performance

- TRACE logs are skipped entirely when min_level > TRACE (no formatting overhead)
- Telemetry uses fixed-size ring buffer (no allocation)
- Disk writes are buffered and flushed periodically
- CDC writes are non-blocking (drops if buffer full)

---

## Files Reference

| File | Purpose |
|------|---------|
| `src/debug/logger.zig` | Unified logging API |
| `src/debug/telemetry.zig` | Event ring buffer |
| `src/debug/crash_store.zig` | Persistent crash storage |
| `src/debug/disk_telemetry.zig` | Disk-based log persistence |
| `src/drivers/usb_cdc.zig` | USB serial for real-time logging |
| `src/tools/telemetry_parser.zig` | CLI tool for analysis |

---

## Troubleshooting

### Logs not appearing on serial

1. Check USB connection
2. Verify correct port: `ls /dev/tty.usbmodem*`
3. Check baud rate (115200)
4. Ensure ZigPod is running (not in Disk Mode)

### Telemetry file empty/corrupt

1. Ensure clean shutdown (logs flush on shutdown)
2. Check `/ZIGPOD/LOGS/` directory exists
3. Verify FAT32 filesystem is healthy

### Can't find source line from PC address

1. Ensure you built with debug symbols: `zig build -Doptimize=Debug`
2. Use the same ELF file that was flashed
3. Check that addr2line is for ARM: `arm-none-eabi-addr2line`

---

## Contact

When reporting issues, include:

1. Output of `zigpod-telemetry analyze telemetry.bin`
2. Contents of `crash.log` (if applicable)
3. Last 100 lines of `session.txt`
4. Steps to reproduce
5. ZigPod version/commit hash
