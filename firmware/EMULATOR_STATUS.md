# ZigPod Emulator Status Report

## Overview

This document provides a comprehensive analysis of the ZigPod iPod emulator status, firmware findings, and recommendations for completion.

**Report Date:** January 2026
**Branch:** emulator-sdl2
**Target Hardware:** iPod Classic 5th/5.5th Gen (PP5021C SoC)

---

## 1. Emulator Architecture Summary

### 1.1 Core Components

| Component | File | Status | Notes |
|-----------|------|--------|-------|
| **CPU** | `cpu/arm7tdmi.zig` | Complete | ARM + Thumb modes, all exceptions |
| **Memory Bus** | `memory/bus.zig` | Complete | Full PP5021C memory map |
| **SDRAM** | `memory/ram.zig` | Complete | 32/64 MB configurable |
| **IRAM** | Internal to bus | Complete | 96 KB fast RAM |

### 1.2 Peripherals

| Peripheral | Address Range | File | Status |
|------------|---------------|------|--------|
| Interrupt Controller | 0x60004000-0x600041FF | `interrupt_ctrl.zig` | Complete |
| Timers | 0x60005000-0x6000503F | `timers.zig` | Complete |
| System Controller | 0x60006000-0x60007FFF | `system_ctrl.zig` | Complete |
| Cache Controller | 0x6000C000-0x6000C0FF | `cache_ctrl.zig` | Stub |
| DMA Controller | 0x6000A000-0x6000BFFF | `dma.zig` | Complete |
| GPIO | 0x6000D000-0x6000D2FF | `gpio.zig` | Complete |
| Device Init | 0x70000000-0x7000007F | `device_init.zig` | Stub |
| GPO32 | 0x70000080-0x700000FF | `gpo32.zig` | Stub |
| I2S Audio | 0x70002800-0x700028FF | `i2s.zig` | Complete |
| I2C | 0x7000C000-0x7000C0FF | `i2c.zig` | Complete |
| Click Wheel | 0x7000C100-0x7000C1FF | `clickwheel.zig` | Complete |
| LCD Controller | 0x30000000-0x30070000 | `lcd.zig` | Complete |
| LCD2 Bridge | 0x70008A00-0x70008BFF | `lcd.zig` | Complete |
| ATA/IDE | 0xC3000000-0xC30003FF | `ata.zig` | Complete |

### 1.3 Frontend

| Component | File | Status |
|-----------|------|--------|
| SDL2 Display | `frontend/sdl_display.zig` | Complete |
| SDL2 Audio | `frontend/sdl_audio.zig` | Complete |
| SDL2 Input | `frontend/sdl_input.zig` | Complete |
| GDB Stub | `debug/gdb_stub.zig` | Complete |

---

## 2. Firmware Analysis Summary

### 2.1 Apple iPod Firmware (osos.bin)

| Property | Value |
|----------|-------|
| Size | 7.21 MB (7,561,216 bytes) |
| Architecture | ARM32 (ARMv5TE) |
| Load Address | 0x10000000 (SDRAM) |
| Encryption | None |
| SoC | PortalPlayer PP5020AF |
| Build | M25Firmware-153 |

#### Key Structures

```
Offset      Description
0x000       Compressed/encrypted header
0x800       ARM exception vectors
0x820       PortalPlayer identification
0x1000      Main code entry
0x2B0000    Localized strings
0x3C0000    Data section
```

### 2.2 Rockbox Bootloader

The emulator is primarily targeting **Rockbox** firmware rather than the Apple firmware. The Rockbox bootloader:

- Size: 51,988 bytes
- Entry: Configured via `--load-iram` or `--load-sdram`
- Function: Locates and loads `rockbox.ipod` from FAT32 partition

---

## 3. Current Development Focus

### 3.1 Active Issue: FAT32 Long Filename (LFN) Parsing

Based on git history and debug instrumentation, the current blocker is **FAT32 LFN parsing** in the Rockbox bootloader.

#### Problem Description

The Rockbox bootloader uses `longent_char_next()` to iterate through UTF-16LE characters in FAT32 LFN entries. The emulator reads disk sectors correctly, but there appears to be an issue with how the data is being processed in memory.

#### LFN Entry Structure (32 bytes)

```
Offset  Size  Description
0x00    1     Ordinal (0x01-0x14, OR'd with 0x40 for last entry)
0x01    10    Name chars 1-5 (UTF-16LE)
0x0B    1     Attribute (0x0F for LFN)
0x0C    1     Type (0x00)
0x0D    1     Checksum
0x0E    12    Name chars 6-11 (UTF-16LE)
0x1A    2     First cluster (0x0000)
0x1C    4     Name chars 12-13 (UTF-16LE)
```

#### Test Disk Structure

The test64mb.img contains:
- MBR with partition type 0x0C (FAT32 LBA)
- FAT32 VBR at sector 1
- Root directory at sector 2055 (cluster 2)
- `.rockbox` directory at sector 2056 (cluster 3)
- `rockbox.ipod` file at cluster 4

#### Debug Output Tracking

The emulator tracks:
1. ATA data reads and sector loads
2. Memory writes containing LFN patterns (0x7241, 0x2E41)
3. Reads from sector buffer areas
4. LFN attribute byte checks (0x0F)

### 3.2 Verification Tests

| Test | File | Purpose |
|------|------|---------|
| LFN Character Iterator | `firmware/lfn_test.s` | Tests `longent_char_next()` pattern |
| ATA Test | `firmware/ata_test.bin` | Verifies MBR reading |
| Audio Test | `firmware/audio_test.bin` | Verifies I2S output |

---

## 4. Identified Gaps

### 4.1 Critical (Blocking Rockbox Boot)

1. **LFN Parsing Bug** - The Rockbox FAT driver fails to correctly parse long filenames for files (works for directories). This may be:
   - Memory alignment issue in sector buffer access
   - Timing issue with ATA data transfer
   - Buffer overwrite between sector reads

### 4.2 Non-Critical

1. **VFP (Floating Point)** - Not implemented, not needed for iPod
2. **COP (Second Core)** - Minimal implementation, not fully synchronized
3. **CPU Disassembly** - Not implemented for trace output
4. **Power Management** - Stub implementation

---

## 5. Hardware Register Reference

### 5.1 ATA Controller (0xC3000000)

**CRITICAL: PP5021C uses 4-byte aligned ATA registers!**

```
Offset  Register          Description
0x000   IDE0_PRI_TIMING0  PIO timing
0x004   IDE0_PRI_TIMING1  DMA timing
0x028   IDE0_CFG          Configuration
0x1E0   ATA_DATA          Data register (16-bit)
0x1E4   ATA_ERROR         Error (read) / Feature (write)
0x1E8   ATA_NSECTOR       Sector count
0x1EC   ATA_SECTOR        LBA bits 0-7
0x1F0   ATA_LCYL          LBA bits 8-15
0x1F4   ATA_HCYL          LBA bits 16-23
0x1F8   ATA_SELECT        Drive/head select
0x1FC   ATA_COMMAND       Command (write) / Status (read)
0x3F8   ATA_CONTROL       Device control
0x3FC   ATA_ALT_STATUS    Alternate status
```

### 5.2 LCD Controller (0x30000000)

```
Offset   Register       Description
0x00000  BCM_DATA32     32-bit data write
0x10000  BCM_WR_ADDR32  Write address
0x30000  BCM_CONTROL    Control register
```

### 5.3 LCD2 Bridge (0x70008A00) - Used by Rockbox

```
Offset  Register           Description
0x0C    LCD2_PORT          Command/data port
0x20    LCD2_BLOCK_CTRL    Block transfer control
0x24    LCD2_BLOCK_CONFIG  Block transfer config
0x100   LCD2_BLOCK_DATA    Block data FIFO
```

---

## 6. Boot Sequence

### 6.1 Apple Firmware Boot

1. ROM bootloader at 0x00000000
2. Read firmware header from disk
3. Validate checksums
4. Copy osos to 0x10000000 (SDRAM)
5. Jump to 0x10000800 (exception vectors)
6. Initialize RTOS and hardware
7. Start UI

### 6.2 Rockbox Bootloader Boot

1. Load bootloader to IRAM (0x40000000) or SDRAM (0x10000000)
2. Initialize ATA controller
3. Read MBR, find FAT32 partition
4. Parse FAT32 VBR
5. Navigate to root directory
6. Find `.rockbox` directory
7. Find `rockbox.ipod` file  **<-- Current failure point**
8. Load and execute main Rockbox firmware

---

## 7. Testing Commands

### Run with Rockbox Bootloader

```bash
zig build run -- --load-iram firmware/rockbox-bootloader.bin test64mb.img --trace 1000
```

### Run LFN Test

```bash
zig build run -- --load-iram firmware/lfn_test.bin --cycles 10000
```

### Debug with GDB

```bash
zig build run -- --load-iram firmware/rockbox-bootloader.bin test64mb.img --gdb-port 1234
# In another terminal:
arm-none-eabi-gdb -ex 'target remote :1234'
```

---

## 8. Recommendations

### 8.1 Immediate Priority

1. **Debug LFN parsing** - Add more granular tracing to identify exactly where the character iteration fails
2. **Verify sector buffer integrity** - Ensure sector data isn't being overwritten between ATA reads and FAT parsing
3. **Compare with working implementation** - Trace Rockbox on real hardware or another emulator

### 8.2 Medium Priority

1. **Implement disassembly output** - Would help with debugging ARM instruction execution
2. **Add breakpoint conditions** - GDB conditional breakpoints for FAT code paths

### 8.3 Future Enhancements

1. **Apple firmware support** - Currently focused on Rockbox
2. **Audio playback testing** - I2S is implemented but needs end-to-end testing
3. **Click wheel refinement** - Basic support exists, may need tuning

---

## 9. File Reference

### Source Files

```
src/emulator/
├── main.zig              # Entry point, CLI
├── core.zig              # Emulator integration
├── cpu/                  # ARM7TDMI implementation
├── memory/               # Bus and RAM
├── peripherals/          # Hardware emulation
├── frontend/             # SDL2 display/audio/input
├── storage/              # FAT32 support
└── debug/                # GDB stub
```

### Firmware Files

```
firmware/
├── ipod_firmware.bin     # Extracted Apple firmware (gitignored)
├── osos.bin              # Extracted OS image (gitignored)
├── rockbox-bootloader.bin # Rockbox bootloader
├── FIRMWARE_ANALYSIS.md  # Apple firmware analysis
├── OSOS_ANALYSIS.md      # OS image analysis
└── *.s, *.bin            # Test programs
```

### Test Disk Images

```
test64mb.img              # 64MB FAT32 test disk
test.img                  # 1MB minimal test disk
```

---

*Report generated from codebase analysis*
