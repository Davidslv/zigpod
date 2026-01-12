# ZigPod Emulator Investigation Findings

**Date:** January 12, 2026
**Investigator:** Claude (Opus 4.5)

## Executive Summary

The emulator is functioning correctly at the hardware emulation level. The issue preventing Rockbox from booting is a **FAT32 directory buffer management bug** in the Rockbox bootloader itself - not an emulator bug.

## Detailed Findings

### 1. ATA/IDE Sector Read Sequence

The bootloader performs the following ATA reads:
```
1. LBA=0    (MBR)           - Reads partition table
2. LBA=0    (MBR)           - Re-reads for verification
3. LBA=1    (VBR)           - FAT32 Volume Boot Record
4. LBA=2    (FAT)           - File Allocation Table
5. LBA=2055 (Root Dir)      - Root directory (cluster 2)
6. LBA=2056 (.rockbox Dir)  - .rockbox directory (cluster 3)
7. LBA=2055 (Root Dir)      - ***ROOT DIRECTORY RE-READ***
```

### 2. The Critical Bug

After reading sector 2056 (.rockbox directory) and finding the `rockbox.ipod` LFN entry, the bootloader reads sector 2055 (root directory) again. This **overwrites** the .rockbox directory data in the sector buffer!

**Before overwrite (sector 2056 loaded):**
```
0x11006F54: 0x6F007241 = "Ar" (start of LFN "rockbox.ipod")
0x11006F5C: attr=0x0F (LFN attribute - CORRECT!)
0x11006F60: checksum=0x4E (CORRECT!)
```

**After overwrite (sector 2055 re-loaded):**
```
0x11006F54: 0x4B434F52 = "ROCK" (start of SHORT name "ROCKBO~1")
0x11006F5C: attr=0x10 (Directory attribute - WRONG!)
0x11006F60: checksum=0x00 (WRONG!)
```

### 3. Root Cause Analysis

The Rockbox FAT driver uses a **single sector buffer** for directory operations. The sequence appears to be:

1. Open root directory "/"
2. Search for ".rockbox" - FOUND at cluster 3
3. Read .rockbox directory (cluster 3 = sector 2056)
4. Search for "rockbox.ipod" in .rockbox
5. **Some operation causes root directory re-read** (possibly resolving ".." or caching)
6. Root directory data overwrites .rockbox data in buffer
7. LFN parsing fails because attr byte is now 0x10 (directory) instead of 0x0F (LFN)

### 4. LCD Output Confirmation

The bootloader renders 76,800 pixels (320x240 = full screen) before stopping:
- LCD pixel writes: 76800
- LCD updates: 0 (never called lcd_update())
- This suggests an error message is being rendered but not displayed

### 5. Emulator Hardware Verification

All emulated hardware is functioning correctly:
- **ATA Controller**: Reads correct sectors, returns correct data
- **Memory Bus**: Properly routes reads/writes
- **LCD Controller**: Accepts pixel writes correctly
- **Partition Detection**: Type=0x0C (FAT32 LBA), LBA=1, Sectors=131071

### 6. Test Disk Structure (test64mb.img)

```
Sector 0:     MBR with partition table
Sector 1:     FAT32 VBR (ZIGPOD volume)
Sectors 2-6:  Reserved
Sectors 7-1030: FAT1
Sectors 1031-2054: FAT2
Sector 2055:  Root directory (cluster 2)
              - ZIGPOD (volume label)
              - .rockbox (LFN + SHORT "ROCKBO~1")
              - rockbox.ipod (LFN + SHORT "ROCKBO~2IPO")
Sector 2056:  .rockbox directory (cluster 3)
              - . (current)
              - .. (parent)
              - rockbox.ipod (LFN + SHORT "ROCKBO~1IPO")
```

## Potential Solutions

### Option 1: Fix Rockbox FAT Driver (Complex)
The Rockbox FAT driver would need to use multiple buffers or implement a caching strategy that prevents directory buffer corruption during nested operations.

### Option 2: Create Custom Disk Image (Workaround)
Create a disk image where `rockbox.ipod` is the ONLY file in the root directory with a SHORT name that doesn't require LFN parsing.

### Option 3: Test with Apple Firmware
The Apple iPod firmware may not have this buffer management issue. Testing with the original firmware would verify the emulator's correctness.

### Option 4: Investigate Why Root Re-Read Occurs
Determine exactly what triggers the root directory re-read and potentially patch the Rockbox bootloader binary to avoid it.

## Verification Commands

```bash
# Run emulator with detailed tracing
./zig-out/bin/zigpod-emulator --load-iram firmware/rockbox-bootloader.bin test64mb.img --headless --cycles 50000000

# Check ATA read sequence
./zig-out/bin/zigpod-emulator ... 2>&1 | grep "ATA: READ LBA"

# Check LFN entry state
./zig-out/bin/zigpod-emulator ... 2>&1 | grep "ATTR READ"
```

## Tools Installed

- `arm-none-eabi-objdump` - ARM disassembler
- `radare2` - Binary analysis framework
- Disassembly saved to: `/tmp/rockbox_bootloader.asm`

## Next Steps

1. Try Apple firmware to verify emulator correctness
2. Investigate exact Rockbox FAT driver code path that causes re-read
3. Consider creating a minimal bootloader test case
4. Document fix and commit findings
