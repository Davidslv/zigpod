# ZigPod Boot Process

This document describes the complete boot sequence for ZigPod on iPod Classic 5th/5.5th generation devices.

## Boot Sequence Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        POWER ON / RESET                              │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ STAGE 1: Boot ROM (0x00000000)                                       │
│ ─────────────────────────────────                                    │
│ • Factory-programmed, read-only                                      │
│ • Initializes minimal clocks and memory controller                   │
│ • Searches for valid firmware on storage                             │
│ • Loads bootloader to IRAM                                           │
│ • Duration: ~100ms                                                   │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ STAGE 2: ZigPod Bootloader (IRAM @ 0x10000000)                       │
│ ─────────────────────────────────────────────────                    │
│ • Loaded from firmware partition on storage                          │
│ • Checks button combos for boot mode selection                       │
│ • Validates firmware integrity                                       │
│ • Handles boot failures and fallback                                 │
│ • Loads ZigPod OS to DRAM                                            │
│ • Duration: ~200-500ms                                               │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    │   Boot Mode Selection │
                    └───────────┬───────────┘
            ┌───────────────────┼───────────────────┐
            ▼                   ▼                   ▼
┌───────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│    ZigPod OS      │ │ Original Apple  │ │  Recovery/DFU   │
│   (Default)       │ │   Firmware      │ │     Mode        │
└─────────┬─────────┘ └────────┬────────┘ └────────┬────────┘
          │                    │                    │
          ▼                    ▼                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ STAGE 3: Operating System                                            │
│ ─────────────────────────────                                        │
│ ZigPod: Full HAL init → Drivers → UI → Main loop                     │
│ Apple: Original firmware execution                                   │
│ Recovery: USB DFU mode for firmware updates                          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Stage 1: Boot ROM

### Location and Characteristics

- **Address**: 0x00000000 - 0x0001FFFF (128 KB)
- **Type**: Mask ROM (factory programmed, immutable)
- **Entry Point**: 0x00000000 (ARM reset vector)

### Boot ROM Functions

1. **Hardware Initialization**
   - Configure PLL for basic clock operation
   - Initialize SDRAM controller
   - Configure minimal GPIO for storage access

2. **Firmware Search**
   - Check for emergency recovery mode (button combo)
   - Read Master Boot Record from storage
   - Locate firmware partition
   - Validate firmware header

3. **Bootloader Loading**
   - Load bootloader image to IRAM
   - Verify checksum
   - Jump to bootloader entry point

### Emergency Mode

If `Menu + Select` is held during power-on, the Boot ROM enters emergency disk mode:
- Presents as USB mass storage device
- Allows firmware restoration via iTunes/computer
- Indicated by "Do not disconnect" screen

---

## Stage 2: ZigPod Bootloader

### Memory Layout

```
IRAM (0x10000000 - 0x10017FFF, 96 KB):
┌────────────────────────────────────┐ 0x10000000
│ Bootloader Code (~30 KB)           │
├────────────────────────────────────┤ 0x10008000
│ Bootloader Data/BSS (~8 KB)        │
├────────────────────────────────────┤ 0x1000A000
│ Stack (16 KB)                      │
├────────────────────────────────────┤ 0x1000E000
│ Boot Configuration (4 KB)          │
├────────────────────────────────────┤ 0x1000F000
│ Reserved                           │
└────────────────────────────────────┘ 0x10017FFF
```

### Boot Mode Selection

The bootloader checks button state immediately after initialization:

| Button Combo | Duration | Action |
|--------------|----------|--------|
| None | - | Boot ZigPod OS |
| Menu held | 2 sec | Boot Original Firmware |
| Play held | 2 sec | Enter DFU Mode |
| Menu + Select | 5 sec | Recovery Mode |
| Select held | 2 sec | Safe Mode (minimal drivers) |

### Boot Configuration Structure

```zig
pub const BootConfig = struct {
    magic: u32 = BOOT_CONFIG_MAGIC,      // 0x5A504F44 ("ZPOD")
    version: u8 = 1,

    // Boot selection
    default_os: BootTarget = .zigpod,
    timeout_ms: u16 = 3000,

    // Failure tracking
    boot_count: u32 = 0,
    consecutive_failures: u8 = 0,
    last_failure_reason: FailureReason = .none,

    // Flags
    flags: BootFlags = .{},

    // Integrity
    checksum: u32 = 0,
};
```

### Boot Failure Handling

The bootloader implements automatic fallback on repeated failures:

```
Boot Attempt #1 → Failure → Increment counter (1)
Boot Attempt #2 → Failure → Increment counter (2)
Boot Attempt #3 → Failure → Increment counter (3) → FALLBACK TO APPLE OS
```

**Failure Detection Methods:**
1. **Watchdog Timeout**: Boot doesn't complete within 30 seconds
2. **Hardware Check Failure**: Battery too low, memory error, storage error
3. **Firmware Validation Failure**: Invalid header, checksum mismatch

### Pre-Boot Hardware Checks

Before loading ZigPod OS, the bootloader performs:

1. **Battery Check**
   - Minimum: 5% charge
   - If below, display warning and halt

2. **Memory Check**
   - Write test pattern to DRAM
   - Verify readback matches
   - Test multiple regions

3. **Storage Check**
   - Send ATA IDENTIFY command
   - Verify device responds
   - Check for timeout

### Firmware Loading

```
1. Mount FAT32 filesystem on data partition
2. Open /.zigpod/firmware.bin
3. Read firmware header (256 bytes)
4. Validate:
   - Magic number (0x5A504F44)
   - Version compatibility
   - Size within limits
   - Entry point in valid range
5. Load firmware to DRAM @ 0x40001000
6. Verify checksum (optional: signature)
7. Disable interrupts
8. Jump to entry point
```

### Firmware Header Format

```zig
pub const FirmwareHeader = struct {
    magic: [4]u8 = "ZPOD",           // Magic identifier
    version_major: u8,                // Firmware version
    version_minor: u8,
    version_patch: u8,
    flags: u8,                        // Feature flags

    entry_point: u32,                 // Execution start address
    load_address: u32,                // Where to load in memory
    firmware_size: u32,               // Size in bytes (excluding header)

    checksum: u32,                    // CRC32 of firmware body
    signature: [64]u8,                // Ed25519 signature (optional)

    build_timestamp: u32,             // Unix timestamp
    min_bootloader_version: u8,       // Minimum compatible bootloader

    reserved: [177]u8,                // Pad to 256 bytes
};
```

---

## Stage 3: ZigPod OS Initialization

### Memory Layout (DRAM)

```
DRAM (0x40000000 - 0x41FFFFFF, 32 MB):
┌────────────────────────────────────┐ 0x40000000
│ Reserved (4 KB)                    │
├────────────────────────────────────┤ 0x40001000
│ ZigPod Firmware (~512 KB)          │
├────────────────────────────────────┤ 0x40081000
│ Heap (~27 MB)                      │
├────────────────────────────────────┤ 0x41B00000
│ Audio Buffer (512 KB, uncached)    │
├────────────────────────────────────┤ 0x41B80000
│ Framebuffer (150 KB)               │
├────────────────────────────────────┤ 0x41BA6000
│ Stack Space (22 KB)                │
│   Main Stack: 16 KB                │
│   IRQ Stack: 4 KB                  │
│   FIQ Stack: 2 KB                  │
└────────────────────────────────────┘ 0x41FFFFFF
```

### Initialization Sequence

```zig
pub fn main() void {
    // 1. Critical hardware (already done by bootloader)
    // Clock, memory controller, basic GPIO

    // 2. HAL initialization
    hal.init();                    // ~50ms

    // 3. Driver initialization
    ata.init();                    // ~100ms (includes storage detection)
    lcd.init();                    // ~20ms
    codec.init();                  // ~10ms
    clickwheel.init();             // ~5ms

    // 4. Filesystem mount
    fat32.mount();                 // ~50ms

    // 5. Load configuration
    settings.load();               // ~10ms

    // 6. UI initialization
    ui.init();                     // ~30ms

    // 7. Audio engine
    audio.init();                  // ~20ms

    // 8. Mark boot successful
    bootloader.markBootSuccessful();

    // 9. Enter main loop
    mainLoop();
}
```

### Boot Success Signal

After successful initialization, ZigPod calls `bootloader.markBootSuccessful()` which:
1. Stops the watchdog timer
2. Resets the consecutive failure counter
3. Clears the `last_boot_failed` flag
4. Saves updated boot configuration

This prevents fallback to Apple firmware on next boot.

---

## Dual Boot: Original Apple Firmware

### How It Works

When booting Apple firmware:
1. Bootloader locates Apple firmware in firmware partition
2. Loads to original load address (as expected by Apple OS)
3. Restores any modified hardware state
4. Jumps to Apple entry point

### User Experience

- Hold `Menu` during boot to select Apple firmware
- Original UI appears
- All original functionality available
- ZigPod files remain on disk but are ignored

---

## Recovery Mode

### DFU (Device Firmware Upgrade)

Entry: Hold `Play` during boot

```
┌─────────────────────────────────────┐
│         ZigPod DFU Mode             │
│                                     │
│   Connect USB to update firmware    │
│                                     │
│   Battery: 75%                      │
│   Status: Waiting for host...       │
└─────────────────────────────────────┘
```

### DFU Protocol

1. Device enumerates as USB DFU class device
2. Host sends firmware image in 4KB chunks
3. Device validates each chunk
4. On complete image, device verifies CRC32
5. Device writes firmware to storage
6. Device reboots to new firmware

### Safety Features

- **Minimum Battery**: 25% required for DFU operations
- **Checksum Verification**: CRC32 on complete image
- **Atomic Updates**: Old firmware preserved until new is verified
- **Watchdog**: Reset if DFU hangs

---

## Installation Process

### Prerequisites

1. iPod formatted as **FAT32** (Windows format via iTunes)
2. Backup of original firmware (recommended)
3. ZigPod bootloader binary (`bootloader-ipod5g.bin`)
4. ZigPod firmware (`firmware.bin`)

### Installation Steps

```bash
# 1. Install bootloader using ipodpatcher
ipodpatcher -a bootloader-ipod5g.bin

# 2. Mount iPod as disk

# 3. Create ZigPod directory
mkdir -p /Volumes/IPOD/.zigpod

# 4. Copy firmware
cp firmware.bin /Volumes/IPOD/.zigpod/

# 5. Safely eject

# 6. Reboot iPod (Menu + Select)
```

### Uninstallation

```bash
# 1. Restore original bootloader
ipodpatcher -u

# 2. (Optional) Remove ZigPod files
rm -rf /Volumes/IPOD/.zigpod
```

---

## Troubleshooting

### Boot Hangs at Apple Logo

**Cause**: ZigPod firmware not found or corrupted
**Solution**:
1. Force reboot (Menu + Select, 10 seconds)
2. Hold Menu to boot Apple firmware
3. Verify `.zigpod/firmware.bin` exists and is valid

### Automatic Fallback to Apple Firmware

**Cause**: Three consecutive boot failures
**Solution**:
1. Boot Apple firmware (it will work after fallback)
2. Connect USB and check `.zigpod/firmware.bin`
3. Re-copy firmware
4. Try again

### DFU Mode Won't Start

**Cause**: Battery too low
**Solution**: Charge device to at least 25%

### Bootloader Corruption

**Cause**: Power loss during update
**Solution**:
1. Enter emergency disk mode (Menu + Select at power on)
2. Restore via iTunes
3. Re-install ZigPod bootloader

---

## Boot Timing Reference

| Stage | Duration | Cumulative |
|-------|----------|------------|
| Boot ROM | ~100ms | 100ms |
| Bootloader init | ~50ms | 150ms |
| Button check | ~100ms | 250ms |
| Firmware load | ~200ms | 450ms |
| HAL init | ~50ms | 500ms |
| Driver init | ~200ms | 700ms |
| UI init | ~100ms | 800ms |
| **Total to usable** | **~800ms** | - |

*Note: Times are approximate and vary with storage speed (flash is faster than HDD).*
