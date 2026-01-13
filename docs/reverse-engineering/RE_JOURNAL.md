# Reverse Engineering Journal

This document tracks the chronological journey of reverse engineering Apple iPod firmware for the ZigPod emulator.

## Index of Investigations

| Date | Document | Status | Summary |
|------|----------|--------|---------|
| 2025-01-12 | [APPLE_FIRMWARE_ANALYSIS.md](APPLE_FIRMWARE_ANALYSIS.md) | Complete | Initial firmware analysis, entry point, RTOS discovery |
| 2025-01-12 | [COP_IMPLEMENTATION_PLAN.md](COP_IMPLEMENTATION_PLAN.md) | Complete | Coprocessor implementation |
| 2025-01-12 | [RTOS_SCHEDULER_INVESTIGATION.md](RTOS_SCHEDULER_INVESTIGATION.md) | In Progress | Breaking out of scheduler loop |
| 2026-01-13 | See below | **SUCCESS** | Rockbox bootloader LCD output working! |

---

## Timeline

### 2025-01-12: Initial Boot Analysis

**Goal**: Get Apple osos.bin firmware to boot

**Findings**:
1. Firmware stuck at 0x10082E98 in RTOS scheduler loop
2. CACHE_CTL (0x6000C000) bit 15 must be CLEAR - firmware polls waiting
3. PP_VER1/PP_VER2 (0x70000000) are ASCII strings "PP5021C", not numeric

**Fixes Applied**:
- `cache_ctrl.zig`: Always return bit 15 clear, clear on write
- `bus.zig`: Changed PP_VER values to ASCII (0x32314300, 0x50503530)

**Result**: Firmware progresses past cache/version checks, now stuck at 0x10229BB4

**Commit**: f50e35b

---

### 2025-01-12: RTOS Scheduler Investigation

**Goal**: Break out of RTOS scheduler loop to reach peripheral initialization

**Current State**:
- PC stuck at: 0x10229BB4 then 0x1000097C
- 0 Timer accesses
- 0 I2C accesses
- 0 LCD writes
- Firmware accessing hw_accel region (0x60003000)

**Investigation**: See [RTOS_SCHEDULER_INVESTIGATION.md](RTOS_SCHEDULER_INVESTIGATION.md)

---

### 2025-01-12: Scheduler Deep Dive and Filesystem Discovery (Current)

**Goal**: Understand why scheduler loop never finds a runnable task

**Key Discoveries**:

1. **Scheduler Mutex Mechanism**
   - 0x1081D858: Main scheduler mutex (test-and-set at 0x1025B348)
   - 0x1081D860: Task selection mutex
   - Function at 0x1025B348 checks if value == 0 (not just bit 0)
   - Must completely zero mutex for acquisition to succeed

2. **IRQ Chicken-and-Egg Problem**
   - Tasks are sleeping, waiting for events (timer IRQ, etc.)
   - IRQ dispatch tables are set up by tasks that never run
   - Firing IRQ without proper handlers crashes to 0xE12FFF1C

3. **CRITICAL DISCOVERY: Filesystem Access**
   - Firmware is actively trying to read FAT32 directory entries!
   - Reading from 0x11006Fxx (disk buffer area)
   - Looking for: DIR_ENTRY, LFN (Long File Name), attributes, checksum
   - All reads return 0x00000000 (empty/no data)
   - **The firmware is stuck because it can't find expected files!**

**Directory Entry Read Pattern**:
```
DIR_ENTRY[0x11006F14]: first_byte=0x00
DIR_ENTRY[0x11006F34]: first_byte=0x00
LFN_START READ at 0x11006F54
ATTR READ at 0x11006F5C
CHECKSUM READ at 0x11006F60
SHORT_ENTRY READ at 0x11006F74
```

**Next Steps**:
1. Create proper FAT32 filesystem with iPod directory structure
2. Include: iPod_Control/, iTunes database files
3. Or: Skip disk read by patching firmware to return "disk ready"

**Files Changed**:
- `bus.zig`: Updated schedulerKickstart() to fully zero mutexes
- `core.zig`: Disabled IRQ kickstart (crashes without proper handlers)

**Commits**: To be committed

---

### 2026-01-13: Rockbox Bootloader Success - LCD Output Working!

**Goal**: Get visual output on LCD by trying alternative firmware

**Background**: Apple firmware stuck in RTOS scheduler loop. Decided to try Rockbox as alternative.

**Key Achievements**:

1. **Downloaded Correct Rockbox Firmware**
   - Initial download was for iPod 6G Classic (S5L8702) - wrong architecture!
   - Correct firmware: `rockbox-ipodvideo.zip` and `bootloader-ipodvideo.ipod`
   - Target: iPod Video 5th Gen (PP5021C) - matches our emulator

2. **Bootloader Structure Discovered**
   - Header: 8 bytes (checksum + "ipvd" signature)
   - Self-relocating: copies itself from SDRAM (0x10000000) to IRAM (0x40000000)
   - PROC_ID check at 0x60000000 (0x55=CPU, 0xAA=COP)
   - BSS clear: 0x11000000 to 0x110481B0
   - Stack setup: SP = 0x4000EB14, canary = 0xDEADBEEF

3. **LCD OUTPUT WORKING!**
   - 76800 pixel writes (320x240 = full screen)
   - Rockbox bootloader displays:
     - "Rockbox boot loader"
     - Version info
     - "No Rockbox detected" (because file parsing not complete)
   - PPM framebuffer saved to `/tmp/zigpod_lcd.ppm`

4. **ATA Working**
   - MBR detected: 0xAA55 signature
   - FAT32 partition recognized
   - Reads: MBR, boot sector, FSInfo, root directory
   - Total ATA commands: ~10, all successful

5. **FAT32 Disk Images Created**
   - `rockbox_disk.img` - 64MB FAT32 with MBR partition
   - Contains `.rockbox/rockbox.ipod` and `/rockbox.ipod`
   - Verified with mtools (mformat, mcopy, mdir)

**Current Issue**:
- Bootloader reads directory but shows "No Rockbox detected"
- Reads LBA 0, 2048, 2049, 4098, 4099 then stops
- File exists at correct location but parsing fails
- May be due to how emulator returns ATA data or directory parsing

**Files Added**:
- `firmware/rockbox/` - Rockbox firmware directory
  - `bootloader-ipodvideo.ipod` - Raw bootloader
  - `bootloader-ipodvideo.bin` - Stripped ARM binary (no header)
  - `rockbox-ipodvideo.zip` - Full Rockbox package
  - `rockbox_disk.img` - 64MB FAT32 disk image
  - `ipodvideo/.rockbox/` - Extracted Rockbox files

**Timer Access**: 44,758 reads - Rockbox actively using timers!
**GPIO Access**: 17 reads

**Next Steps**:
1. Debug ATA data return to ensure correct sector content
2. Trace bootloader's file search logic
3. Fix file detection to load full Rockbox firmware

---

## Key Memory Regions

| Address | Size | Purpose |
|---------|------|---------|
| 0x10000000 | 32MB | SDRAM (firmware loaded here) |
| 0x40000000 | 96KB | IRAM (fast internal RAM) |
| 0x60000000 | - | PROC_ID register |
| 0x60003000 | - | hw_accel / RTOS task queues |
| 0x60004000 | - | Interrupt Controller |
| 0x60005000 | - | Timers |
| 0x6000C000 | - | Cache Controller |
| 0x70000000 | - | Device Init / PP_VER |
| 0x7000C000 | - | I2C Controller |

## PROVEN FACTS - Apple Firmware (osos.bin)

**DO NOT RE-VERIFY THESE - they have been confirmed through testing**

### Entry Point and Structure
| Fact | Value | Source |
|------|-------|--------|
| Firmware load address | 0x10000000 (SDRAM) | Empirical testing |
| Entry point | 0x10000800 | Firmware header analysis |
| Header size | 0x800 bytes (2KB) | xxd analysis |
| Exception vectors | At 0x10000800-0x1000081C | ARM standard + testing |
| PROC_ID check | 0x55 = CPU, 0xAA = COP | Disassembly @ 0x10000A44 |

### Boot Sequence (verified)
1. Entry at 0x10000800 → Branch to 0x100009F0
2. Write callback to 0xF000F00C, jump to Boot ROM at 0x0000023C
3. Boot ROM calls callback at 0x10000F84 with R0 = 0xF000F000
4. Callback writes RTOS init data to FLASH_CTRL registers
5. Returns to 0x10000A3C
6. Reads PROC_ID (0x60000000) - value 0x55 = CPU path
7. CPU path: Load SP from 0x40003FF8, call early_init

### Hardware Register Quirks (Apple-specific)
| Register | Expected Value | Notes |
|----------|----------------|-------|
| PP_VER1 (0x70000000) | 0x32314300 | ASCII "21C\0" |
| PP_VER2 (0x70000004) | 0x50503530 | ASCII "PP50" |
| CACHE_CTL[15] (0x6000C000) | CLEAR | Firmware polls until clear |
| Status (0x70000030) | 0x80000000 | Bit 31 = ready |

### hw_accel (0x60003000) - RTOS Task Queues
| Offset | Stable Value | Meaning |
|--------|--------------|---------|
| 0x00 | 0x59 | Task states for tasks 0-15 (2 bits each) |
| 0x04 | 0xA6 | Task states for tasks 16-31 |
| 0x08 | 0xFF | Task states for tasks 32-47 (all "ready") |
| 0x0C | 0x00 | Task states for tasks 48-63 (all "inactive") |

Task state encoding: 00=inactive, 01=sleeping, 10=waiting, 11=ready

## PROVEN FACTS - Rockbox Sources (Reference)

| File | Contents |
|------|----------|
| firmware/export/pp5020.h | Register definitions |
| firmware/target/arm/pp/ata-pp5020.c | ATA driver, register offsets |
| firmware/target/arm/ipod/button-clickwheel.c | Click wheel protocol |
| firmware/drivers/ata.c | ATA protocol |

---

## Tools Used

- **radare2**: Disassembly and analysis
- **Ghidra**: Decompilation (optional)
- **Custom tracing**: Emulator instrumentation

## Methodology

1. Run emulator with cycle limit, capture final PC
2. Disassemble stuck address to understand loop
3. Identify peripheral accesses being polled
4. Determine expected values/conditions
5. Implement fix in emulator
6. Document findings
7. Commit and test
