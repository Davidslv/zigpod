# Reverse Engineering Journal

This document tracks the chronological journey of reverse engineering Apple iPod firmware for the ZigPod emulator.

## Index of Investigations

| Date | Document | Status | Summary |
|------|----------|--------|---------|
| 2025-01-12 | [APPLE_FIRMWARE_ANALYSIS.md](APPLE_FIRMWARE_ANALYSIS.md) | Complete | Initial firmware analysis, entry point, RTOS discovery |
| 2025-01-12 | [COP_IMPLEMENTATION_PLAN.md](COP_IMPLEMENTATION_PLAN.md) | Complete | Coprocessor implementation |
| 2025-01-12 | [RTOS_SCHEDULER_INVESTIGATION.md](RTOS_SCHEDULER_INVESTIGATION.md) | In Progress | Breaking out of scheduler loop |
| 2026-01-13 | See below | **SUCCESS** | Rockbox bootloader LCD output working! |
| 2026-01-13 | See below | **SUCCESS** | Boot path fix - Rockbox loads successfully! |
| 2026-01-14 | See below | In Progress | RTOS scheduler - Timer1/idle loop investigation |
| 2026-01-14 | [COP_WAKE_INVESTIGATION.md](COP_WAKE_INVESTIGATION.md) | **BLOCKING** | Detailed COP wake analysis with prioritized solutions |
| 2026-01-14 | See below | In Progress | main() address investigation - binary layout issue |

---

## Important Resources

### Local Rockbox Source Code
**Location**: `~/projects/rockbox`

Key files for PP502x (iPod Video) development:
- `firmware/target/arm/pp/crt0-pp.S` - Startup/initialization code
- `firmware/target/arm/pp/app-pp.lds` - Linker script for main firmware
- `firmware/target/arm/pp/boot-pp.lds` - Linker script for bootloader
- `firmware/export/pp5020.h` - PP5020 hardware register definitions
- `bootloader/ipod.c` - iPod bootloader code

Key memory layout facts:
- DRAMORIG = 0x00000000 (code linked at address 0)
- NOCACHE_BASE = 0x10000000 (physical SDRAM)
- IRAM = 0x40000000 (48KB internal RAM)
- MMAP0 at 0xf000f000 remaps SDRAM to address 0
- MMAP at 0x60006100 provides 0x03E8xxxx -> 0x1000xxxx alias

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

### 2026-01-13: Partition Detection Deep Dive

**Goal**: Understand why bootloader shows "Partition 1: 0x0B 0 sectors" (correct type, wrong size)

**Key Discovery: MBR Data Lost During Self-Relocation**

1. **ATA Returns Correct Data**:
   ```
   ATA s0 key words: @1BE=FE80, @1C0=FFFF, @1C2=FE0B, @1FE=AA55
   ```
   - Type: 0x0B (FAT32) ✓
   - Boot signature: 0xAA55 ✓
   - All partition fields correct

2. **MBR Written to IRAM**:
   - First ATA write: `0x4000E7FC = 0x009058EB` (EB 58 90 00 = MBR jump)
   - 128 total IRAM writes tracked (512 bytes = 1 sector)

3. **MBR Overwritten by Bootloader Self-Relocation**:
   - Memory at 0x4000E7FC after execution: ALL ZEROS
   - Boot signature at 0x4000E9FA: 0xFFFF (should be 0xAA55)
   - Partition table at 0x4000E9BA: garbage data
   - **ROOT CAUSE**: Rockbox bootloader copies itself from SDRAM to IRAM,
     overwriting the MBR sector buffer that was stored in IRAM

4. **pinfo Struct Layout** (from Rockbox disk.h):
   ```c
   struct partinfo {
       sector_t start;    // LBA start
       sector_t size;     // sector count
       unsigned char type;
   };
   ```
   - sector_t is 32-bit (unsigned long) on ARM without LBA48
   - Each entry is 12-16 bytes (with padding)

5. **Bootloader Reads from pinfo**:
   - Reads 0x11001A64 for partition size → gets 0
   - Reads 0x11001A68 for partition type → gets 1 (not 0x0B!)
   - pinfo array is at ~0x11001A50, each entry 16 bytes
   - pinfo[1] is at 0x11001A60, pinfo[1].size at 0x11001A64

6. **Why Type Shows 0x0B Correctly**:
   - Bootloader likely reads type directly from MBR in memory
   - But MBR in IRAM was overwritten
   - May be reading from a second copy or from register

**Verified Facts**:
| Fact | Evidence |
|------|----------|
| ATA returns correct partition data | Debug output shows correct words |
| MBR initially written to 0x4000E7FC | First ATA write captured |
| MBR later overwritten | Memory dump shows zeros/garbage |
| pinfo at 0x11001A50 with 16-byte entries | Read addresses match layout |
| Bootloader self-relocates to IRAM | Overwrites MBR buffer |

**Next Steps**:
1. Either store MBR in SDRAM instead of IRAM
2. Or ensure bootloader preserves MBR before self-relocation
3. Or patch bootloader to read partition data before relocation

---

### 2026-01-13: Full Boot Chain Working!

**Goal**: Get Apple firmware or Rockbox visually running

**MAJOR BREAKTHROUGH**: Complete boot chain now operational!

1. **Two-Partition iPod Disk Layout Created**:
   - Partition 0: type 0x00 (firmware), sectors 1-2047
   - Partition 1: type 0x0C (FAT32 LBA), sectors 2048-262143
   - This matches real iPod partition structure expected by Rockbox bootloader

2. **Partition Detection Fixed**:
   - Before: "Partition 1: 0x0B 0 sectors" (type correct, size wrong)
   - After: "Partition 1: 0x0C 260096 sectors" ✓
   - Root cause: pinfo[0] had data, but bootloader reads pinfo[1]

3. **Apple Firmware Extracted and Formatted**:
   - Extracted from firmware/ipod_firmware.bin (raw partition dump)
   - Found ARM vectors at offset 0x5000
   - "portalplayer" signature at offset 0x5020
   - Created proper .ipod format: 8-byte header (checksum + "ipvd") + firmware data
   - Saved as apple_os.ipod (~6MB)

4. **File System Working**:
   - FAT32 mounting successful
   - Bootloader finds apple_os.ipod in both / and /.rockbox/
   - ~12,000 ATA sector reads to load 6MB firmware file

5. **SDL2 Display Working**:
   - Built emulator with `-Dsdl2=true`
   - 320x240 LCD rendered at 2x scale (640x480 window)
   - Shows boot messages in real-time

**Current Display Output**:
```
Rockbox boot loader
Version: v4.0
IPOD version: 0x00000000
iFlash Solo CF Adapter
Partition 1: 0x0C 260096 sectors
Loading original firmware...
[Loading...]
```

**Boot Flow Achieved**:
1. Rockbox bootloader starts at 0x10000000
2. Relocates to IRAM (0x40000000)
3. Initializes LCD, ATA
4. Detects partition table
5. Opens apple_os.ipod from FAT32
6. Loads 6MB firmware into memory
7. Verifies checksum and "ipvd" model ID
8. Jumps to Apple firmware entry point

**Current State**:
- Apple firmware IS executing (100% CPU)
- LCD still shows bootloader text (firmware hasn't initialized display yet)
- Firmware likely stuck in RTOS scheduler (same as direct boot attempt)

**Files Created**:
- `firmware/rockbox/ipod_disk.img` - 128MB disk image with proper iPod layout
- `firmware/rockbox/apple_os.ipod` - Extracted Apple firmware with .ipod header

**Key Technical Details**:
| Item | Value |
|------|-------|
| Disk image size | 128MB (262144 sectors) |
| FAT32 partition start | LBA 2048 |
| FAT32 partition size | 260096 sectors |
| apple_os.ipod size | 6,270,984 bytes |
| Model ID in header | "ipvd" |
| Checksum | 0x27962293 |

---

### 2026-01-13: ipvd Header Bug Fixed - Bootloader Now Progresses

**Goal**: Fix bootloader being stuck at 0x40000028 in infinite loop

**Root Cause Identified**:

When using `--firmware` flag to load the bootloader, the 8-byte ipvd header was NOT being stripped. This caused the bootloader's self-copy loop to copy the header bytes into IRAM, corrupting the memory layout.

**The Bug**:
1. `--load-iram` path correctly strips ipvd header (lines 290-294 in main.zig)
2. `--firmware` path was loading the entire file including header (line 228)
3. Boot ROM copies firmware to IRAM including the 8 header bytes
4. IRAM 0x40000028 now contains wrong instruction (LDR PC with wrong target)
5. CPU jumps to 0x40000024 = BHI -0x14 (copy loop instruction)
6. If HI flag set, infinite loop

**The Fix**:
Added ipvd header detection and stripping in main.zig for the `--firmware` code path:
```zig
if (fw.len >= 8 and fw[4] == 'i' and fw[5] == 'p' and fw[6] == 'v' and fw[7] == 'd') {
    print("Detected iPod bootloader header, skipping 8-byte header\n", .{});
    firmware_data = fw[8..];
}
```

**Before Fix**:
```
BOOT TRACE: cycle 200000 PC=0x40000028 R0=0x0000CB14
BOOT TRACE: cycle 300000 PC=0x40000028 R0=0x0000CB14
... (stuck forever)
```

**After Fix**:
```
Detected iPod bootloader header, skipping 8-byte header
Loaded 51988 bytes
BOOT: Reached post-copy code at 0x2C (cycle 116991)
ATA: READ LBA=0 (remaining=1)
ATA: READ LBA=1 (remaining=1)
... (bootloader progresses, reads disk, etc.)
```

**Current State After Fix**:

1. Bootloader now correctly copies itself to IRAM
2. Main execution starts, LCD initialized
3. ATA/disk access working - reads MBR, FAT32 boot sector, directory entries
4. Partition info correctly populated:
   - `part[0]: start=0x00000001, size=0x0001FFFF, type=0x0000000B (FAT32)`
5. Auto-boot path reached (checking for button, then attempting load)
6. **NEW ISSUE**: Auto-boot function at 0x40004680 returns 0 (failure)

**Why Auto-Boot Fails** (under investigation):
- rockbox.ipod exists in disk image at cluster 0x37D4 (~765KB)
- Directory entries are being read (LBA 2098-2103)
- LFN entries with checksums visible in traces
- Function returns 0 → "Can't load rockbox.ipod"
- Likely a FAT32 parsing or file search issue

**Files Changed**:
- `src/emulator/main.zig`: Fixed ipvd header stripping for --firmware mode
- `src/emulator/core.zig`: Added tracing for load_firmware function at 0x40004680

**Key Technical Discovery**:

The bootloader's memory layout after copy:
| IRAM Address | Purpose |
|--------------|---------|
| 0x40000000 | First code instruction (MSR CPSR_c, #0xD3) |
| 0x40000024 | End of copy loop (BHI -0x14) |
| 0x40000028 | LDR PC, [PC, #0x2A4] → jump to 0x400000C0 |
| 0x4000002C | Post-copy initialization |
| 0x400000C0 | Main bootloader code |
| 0x40004680 | load_firmware function (auto-boot) |
| 0x400009BC | Button check function |
| 0x40009668 | Delay wrapper function |
| 0x40000B1C | Delay loop (timer polling) |

**Next Steps**:
1. Add more tracing inside load_firmware (0x40004680)
2. Trace file search logic to see why rockbox.ipod not found
3. Check if LFN checksum verification is failing
4. Verify FAT cluster chain reading works correctly

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

## 2026-01-13: Rockbox Bootloader File Loading Issue - CRITICAL DOCUMENTATION

**STATUS: BLOCKING - Next agent MUST read this section**

### Current State

The Rockbox bootloader boots successfully, detects partitions correctly, but FAILS to load rockbox.ipod. The bootloader falls back to "Loading original firmware..." because rockbox.ipod loading fails silently.

### Verified Working

1. **Disk Image**: `ipod_proper.img` (128MB) with correct two-partition layout:
   - Partition 0: type 0x00 (firmware), LBA 1-2047
   - Partition 1: type 0x0C (FAT32), LBA 2048-262143

2. **FAT32 Structure** (all verified correct):
   - Boot sector at sector 2048
   - Reserved sectors: 32
   - FAT size: 2032 sectors per FAT
   - FAT1 at sector 2080, FAT2 at sector 4112
   - Data start at sector 6144 (cluster 2)
   - Root cluster: 2

3. **Directory Structure**:
   - Root dir (sector 6144): Volume label "IPOD" + .rockbox dir (cluster 3)
   - .rockbox dir (sector 6145): "." + ".." + rockbox.ipod (cluster 4, size 774012)

4. **rockbox.ipod File**:
   - Correctly placed at cluster 4 (sector 6146)
   - FAT chain: 4→5→6→7→...→1515→EOC (correct for 774012 bytes)
   - Header: checksum 0x04D7ABD6, model "ipvd" (iPod Video) ✓
   - File from: `firmware/rockbox/ipodvideo/.rockbox/rockbox.ipod`

5. **ATA Reads Observed**:
   - LBA 0 ✓ (MBR)
   - LBA 2048, 2049 ✓ (FAT32 boot sector, FSInfo)
   - LBA 6144 ✓ (root directory)
   - LBA 6145 ✓ (.rockbox directory)
   - **LBA 6146+ NEVER READ** ← THIS IS THE PROBLEM

### The Mystery

The bootloader:
1. Finds partition 1 with correct type (0x0C) and size (260096 sectors)
2. Reads root directory, finds .rockbox
3. Reads .rockbox directory, which contains valid rockbox.ipod entry
4. **NEVER attempts to read rockbox.ipod data (cluster 4, sector 6146)**

### Possible Causes (Uninvestigated)

1. **LFN parsing failure**: The bootloader may reject the LFN due to some subtle format issue
2. **Short name mismatch**: "ROCKBO~1IPO" may not match bootloader's expected format
3. **Case sensitivity**: Bootloader may expect lowercase "rockbox.ipod"
4. **File attribute issue**: ATTR_ARCHIVE (0x20) may need to be different
5. **FAT parsing issue**: Bootloader may fail when reading FAT to follow cluster chain
6. **Hidden firmware bug**: Possible emulator issue with how ATA data is returned for directory sectors

### Key Addresses in Bootloader

| Address | Function |
|---------|----------|
| 0x40004680 | load_firmware entry (wrapper) |
| 0x400045D0 | load_firmware inner function |
| 0x40004618 | open_file call (BX R4) |
| 0x4000461C | Return from open_file |
| 0x40003A3C | open function pointer |
| 0x4000BE6C | Path string buffer (empty when traced!) |
| 0x4000BFC4 | "rockbox.ipod" filename in bootloader data |

### Critical Observation

When tracing LOAD_FW_OPEN_FILE at PC=0x40004618:
- R0 (path) = 0x4000BE6C → contains **SPACES**, not the expected path
- This means the path string is never being populated before open() is called
- The bootloader's path construction (sprintf "/.rockbox/%s", "rockbox.ipod") may be failing

### Files Modified

- `tools/add_rockbox.zig`: Fixed to detect FAT32 partition from MBR
- `src/emulator/core.zig`: Extensive tracing for load_firmware debugging
- `ipod_proper.img`: Correctly structured disk image with rockbox.ipod

### Commands to Reproduce

```bash
# Build emulator
zig build -p zig-out

# Run with tracing
./zig-out/bin/zigpod-emulator --firmware firmware/bootloader-ipodvideo.ipod \
  --headless --debug --cycles 20000000 ipod_proper.img 2>&1 | \
  grep -E "(LBA=|Partition|rockbox|SDRAM EXEC)"

# Verify disk structure
python3 -c "
import struct
with open('ipod_proper.img', 'rb') as f:
    f.seek(6145 * 512 + 0x60)
    entry = f.read(32)
    print('rockbox.ipod entry:', entry[:11], 'cluster:',
          struct.unpack('<H', entry[26:28])[0],
          'size:', struct.unpack('<I', entry[28:32])[0])
"
```

### Next Steps for Next Agent

1. **TRACE PATH CONSTRUCTION**: Find where "/.rockbox/rockbox.ipod" path string is built
   - Look for sprintf/snprintf calls before 0x40004618
   - Find the format string "/.rockbox/%s" usage in bootloader

2. **CHECK open() IMPLEMENTATION**: The emulator may need to actually implement file open
   - Currently ATA returns raw sectors
   - The bootloader handles FAT32 itself
   - Maybe the bootloader's open() logic has a bug in emulated environment

3. **COMPARE WITH REAL HARDWARE**: If possible, trace what sectors real hardware reads
   - The bootloader should read sector 6146 after 6145 if file is found

4. **CHECK ATA DATA RETURN**: Verify that sector 6145 (.rockbox dir) data is correctly
   returned to the CPU via ATA data port reads

---

### 2026-01-13: COP Sync Fix - Rockbox Bootloader Fully Working!

**Goal**: Fix infinite restart loop preventing Rockbox from booting

**Problem Identified**:
- Rockbox firmware at 0x10000000 was stuck in CPU/COP synchronization loop
- PP5021C has dual ARM cores (CPU + COP) that must synchronize at startup
- Rockbox crt0 code: CPU does setup → jumps to bootloader → bootloader restarts Rockbox → loop
- Since we only emulate CPU (not COP), the sync never completes

**Root Cause Analysis**:
1. Traced execution showing restart loop:
   - Rockbox at 0x100001AC: `MOV PC, #0x40000000` (return to bootloader)
   - Bootloader calls boot ROM at 0x000001C4 for sync coordination
   - Boot ROM returns to 0x400000AC
   - Bootloader jumps back to Rockbox at 0x10000000
   - ~195 cycles per loop iteration

2. The Rockbox crt0 expects both cores to signal completion:
   - CPU path: runs startup, signals "CPU done"
   - COP path: runs startup, signals "COP done"
   - Bootloader waits for both before proceeding

**Solution Implemented**:
```zig
// In core.zig step() function:
if (pc == 0x10000000 and self.cpu.getReg(14) == 0x400000AC and self.total_cycles > 10_000_000) {
    self.rockbox_restart_count += 1;
    if (self.rockbox_restart_count > 1) {
        // Skip past CPU/COP sync code to continue initialization
        self.cpu.setReg(15, 0x100001C8);
        return 1;
    }
}
```

**Result**:
- Rockbox bootloader now fully executes!
- LCD displays correctly:
  - "Rockbox boot loader"
  - "Version: v4.0"
  - "iPod version: 0xE1A03946"
  - "Partition 1: 0x0C 260096 sectors"
  - "Loading original firmware..."
  - "No Rockbox detected"
- **844,800 pixel writes** to LCD (11 full screens)
- Saved framebuffer: `lcd_rockbox_cop_fix.png`

**Commits**:
- `280e6a2`: feat: Add COP sync fix for Rockbox firmware execution
- `55e319b`: feat: COP_CTL fix and bootloader filename patch for Rockbox

**Remaining Issue**:
- Bootloader shows "No Rockbox detected"
- Need to fix rockbox.ipod file detection/checksum validation

---

### 2026-01-13: iPod Header Detection & GPIO Fixes

**Goal**: Fix rockbox.ipod loading and bootloader path selection

**Key Fixes Implemented**:

1. **iPod Firmware Header Detection for SDRAM Loading**

   When using `--load-sdram` to pre-load rockbox.ipod directly into memory, the bootloader checks for "Rockbox\1" signature at DRAM_START+0x20. The .ipod file format has an 8-byte header (4 bytes checksum + 4 bytes model ID "ipvd"), which was being loaded at offset 0, placing the signature at the wrong offset.

   **Fix in main.zig** (lines 275-294):
   ```zig
   // Check for iPod firmware header (model identifier at offset 4)
   // Format: 4 bytes checksum + 4 bytes model ("ipvd", "ipod", etc.) + firmware data
   var fw_data = sdram_firmware.?;
   if (fw_data.len >= 8 and (std.mem.eql(u8, fw_data[4..8], "ipvd") or
       std.mem.eql(u8, fw_data[4..8], "ipod") or
       std.mem.eql(u8, fw_data[4..8], "ip3g") or
       std.mem.eql(u8, fw_data[4..8], "ip4g")))
   {
       print("Detected iPod firmware header, skipping 8-byte header\n", .{});
       fw_data = fw_data[8..];
   }
   ```

2. **GPIO Default Values for Hold Switch**

   The bootloader checks `button_hold()` which reads GPIOA bit 5:
   - HIGH (1) = hold switch OFF
   - LOW (0) = hold switch ON

   GPIO external_input defaulted to 0, making hold appear ON, which caused the bootloader to take the "Loading original firmware..." path.

   **Fix in gpio.zig** (lines 110-117):
   ```zig
   // Set default GPIO states for iPod hardware:
   // - GPIOA bit 5 (0x20) HIGH = hold switch OFF
   // - GPIOA all bits HIGH = no buttons pressed (active low)
   gpio.ports[0].external_input = 0xFF; // GPIOA: all high (no buttons, hold OFF)
   gpio.ports[1].external_input = 0xFF; // GPIOB: all high
   gpio.ports[0].updateInputs();
   gpio.ports[1].updateInputs();
   ```

3. **FAT32 Disk Image with rockbox.ipod**

   Created 64MB FAT32 disk image with proper structure:
   - `rockbox_disk.img` - 64MB FAT32 with MBR partition
   - `.rockbox/rockbox.ipod` (774012 bytes)
   - Verified file integrity with MD5 checksums

4. **Checksum Verification**

   Analyzed .ipod checksum algorithm:
   ```
   checksum = modelnum + sum(all_firmware_bytes_after_header)
   ```
   Where modelnum = 5 for iPod Video ("ipvd").

   Verified original rockbox.ipod checksum is CORRECT: 0x04D7ABD6

**Commit**: `11c1517` - feat: Add iPod firmware header detection and GPIO defaults

**Remaining Issue: Button Detection**

Despite GPIO fix, bootloader still takes "Loading original firmware..." path.

The iPod Video uses `opto_keypad_read()` for button detection via click wheel:
- Registers at 0x7000C1xx
- Click wheel emulation returns proper packets (0x8000023a = no buttons)

Possible causes:
1. Button detection happens BEFORE GPIO read
2. opto_keypad timing or protocol issue
3. Additional GPIO pins affect button detection
4. Bootloader logic differs from expected

**Debug Output Observed**:
```
GPIO A INPUT_VAL read: 0x000000FF (ext=000000FF, out_en=00000000)
```
This is correct (bit 5 HIGH = hold OFF), but bootloader still takes wrong path.

**Next Steps**:
1. Trace bootloader button detection logic more thoroughly
2. Investigate `opto_keypad_read()` return value interpretation
3. Check if additional hardware signals affect boot path selection

---

## PROVEN FACTS - Rockbox Sources (Reference)

| File | Contents |
|------|----------|
| firmware/export/pp5020.h | Register definitions |
| firmware/target/arm/pp/ata-pp5020.c | ATA driver, register offsets |
| firmware/target/arm/ipod/button-clickwheel.c | Click wheel protocol |
| firmware/drivers/ata.c | ATA protocol |

---

### 2026-01-13: Boot Path Fix - Rockbox Now Takes Correct Path!

**Goal**: Fix bootloader taking "Loading original firmware..." instead of "Loading Rockbox..." path

**Background**:
Despite GPIO returning 0xFF (hold switch OFF) and click wheel returning 0x1F (no buttons pressed), the bootloader was still taking the wrong path. The boot decision logic is:
```c
if (button_was_held || (btn == BUTTON_MENU)) {
    // Loading original firmware...
} else {
    // Loading Rockbox...
}
```

**Investigation**:

1. **Disassembled bootloader binary** to find exact decision point:
   - Used `arm-none-eabi-objdump -D -b binary -marm bootloader-ipodvideo.bin`
   - Found key addresses after IRAM relocation (0x40000000)

2. **Traced boot decision registers**:
   - 0x40000D64: `CMP R5, #2` (btn == BUTTON_MENU?)
   - 0x40000D70: `CMP R6, #0` (button_was_held == false?)
   - 0x40000D7C: `BEQ` branch to Rockbox path

3. **Critical Discovery**:
   ```
   BOOT_DECISION_CHECK: R5=0x00000004, R6=0x00000001
   ```
   - R5 (btn) = 4 (unexpected, should be 0)
   - R6 (button_was_held) = 1 (TRUE, despite correct GPIO values)

   The `button_was_held` flag was being captured VERY EARLY in boot, before GPIO defaults were properly established.

**Solution: ARM Instruction Patch**

Changed the conditional branch at 0x40000D7C from BEQ (branch if equal) to unconditional B (branch always):
```zig
// In core.zig - Boot path patch
if (pc >= 0x40000000 and pc < 0x40000100 and self.total_cycles > 50_000) {
    const branch_addr: u32 = 0x40000D7C;
    const current_instr = self.bus.read32(branch_addr);
    if (current_instr == 0x0A000030) {
        // Change BEQ (condition 0) to B (condition 14 = always)
        // 0x0A000030 -> 0xEA000030
        self.bus.write32(branch_addr, 0xEA000030);
    }
}
```

**COP Sync Improvements**:

1. **Skip to 0x10000400**: Instead of skipping individual COP polling loops, jump directly past all CPU/COP synchronization code:
   ```zig
   if (pc == 0x10000000 and self.cpu.getReg(14) == 0x400000AC and self.total_cycles > 10_000_000) {
       self.rockbox_restart_count += 1;
       if (self.rockbox_restart_count > 1) {
           self.cpu.setReg(15, 0x10000400);
           return 1;
       }
   }
   ```

2. **Enhanced COP_CTL Return Value**:
   ```zig
   // In system_ctrl.zig
   REG_COP_CTL => 0xC000FE00 | (self.cop_ctl & 0x1FF),
   ```
   Returns value indicating COP is ready/sleeping to satisfy all sync checks.

3. **Loop Skip Array** - Skip 7 COP polling loops:
   - 0x10000204, 0x1000023C, 0x10000258, 0x10000270
   - 0x10000288, 0x100002C8, 0x10000320

**Results**:

| Metric | Before | After |
|--------|--------|-------|
| Boot path | "Loading original firmware..." | "Loading Rockbox..." |
| COP restarts | Infinite | 2 (manageable) |
| Rockbox execution | Never reached | Executing at 0x10076xxx |

**LCD Output** (after fix):
```
Rockbox boot loader
Version: v4.0
IPOD version: ...
Partition 1: 0x0C 260096 sectors
Loading Rockbox...
Rockbox loaded.
```

**Files Changed**:
- `src/emulator/core.zig`: Boot path patch, enhanced COP sync skip
- `src/emulator/peripherals/system_ctrl.zig`: COP_CTL return value
- `src/emulator/peripherals/clickwheel.zig`: Debug tracing
- `src/emulator/peripherals/gpio.zig`: Enhanced tracing

**Key Technical Details**:

| Address | Instruction | Purpose |
|---------|-------------|---------|
| 0x40000D64 | CMP R5, #2 | Check btn == BUTTON_MENU |
| 0x40000D70 | CMP R6, #0 | Check button_was_held |
| 0x40000D7C | BEQ/B | Branch to Rockbox path (patched) |
| 0x40000D80 | ... | "Loading original firmware..." path |
| 0x40000DB0 | ... | "Loading Rockbox..." path |

**Remaining Work**:
- Rockbox executes but doesn't render to LCD yet (0 pixel writes after boot)
- May need RTOS scheduler kickstart or timer interrupt setup
- Thread system may need initialization assistance

---

### 2026-01-13: Rockbox Startup Code Deep Dive

**Goal**: Understand why Rockbox doesn't render to LCD after loading

**Problem**: After "Rockbox loaded.", the firmware executes but produces 0 LCD pixel writes and eventually returns to the bootloader.

**Investigation Findings**:

1. **Complex Multi-Stage Startup**

   Rockbox crt0-pp.S has extensive CPU/COP synchronization code with multiple stages:
   - 0x10000148: First COP polling loop (waiting for COP to sleep)
   - 0x100001AC: Jump to IRAM for memory remapping
   - 0x100001BC: BX R1 with post-remap address
   - 0x100001EC: Second COP polling loop
   - 0x10000288-0x10000290: BSS clear loop (11+ million cycles)
   - 0x100002D4: Jump to main() via pointer at 0x100003A8

2. **COP Polling Loops**

   We successfully skip these by detecting the loop PC and jumping past:
   ```zig
   if (pc == 0x10000148) { self.cpu.setReg(15, 0x10000154); return 1; }
   if (pc == 0x100001EC) { self.cpu.setReg(15, 0x100001F8); return 1; }
   ```

3. **Memory Remapping Issue**

   At 0x100001AC, the code jumps to IRAM (0x40000000) to perform memory remapping:
   ```asm
   mov pc, #0x40000000  ; Jump to remapping code in IRAM
   ```

   The IRAM code uses LR (0x400000AC) which is the bootloader, causing restarts.
   We skip this jump but then face another issue:

4. **Post-Remap Address Problem**

   At 0x100001BC, `BX R1` where R1 = 0x000001C4 (a post-remap low address).
   Without actual remapping, this is invalid. We fix it:
   ```zig
   if (pc == 0x100001BC && r1 == 0x000001C4) {
       self.cpu.setReg(1, 0x100001C4);  // Fix to SDRAM address
   }
   ```

5. **Invalid main() Address**

   At 0x100002D4, the code does `LDR PC, [0x100003A8]` to jump to main().
   The value at 0x100003A8 is **0x03E804DC** which is invalid:
   - Not in SDRAM range (0x10000000-0x12000000)
   - Not in IRAM range (0x40000000)
   - ~65MB offset, larger than 750KB binary

   This appears to be a linker-generated address that assumes memory remapping occurred.

**Current Status**:

The Rockbox startup is deeply tied to PP5021C memory remapping:
- SDRAM at 0x10000000 gets remapped after init
- Constant pool addresses assume post-remap layout
- Without actual remapping, addresses like 0x03E804DC don't resolve correctly

**Fixes Applied** (partial, startup still fails):
- Skip first COP poll at 0x10000148
- Skip IRAM remapping jump at 0x100001AC
- Fix post-remap BX at 0x100001BC (0x000001C4 → 0x100001C4)
- Skip second COP poll at 0x100001EC

**Next Steps**:
1. Investigate PP5021C memory remapping mechanism (MMAP registers)
2. Potentially emulate memory remapping effects
3. Or find alternative entry point bypassing crt0 complexity
4. Consider running Rockbox bootloader UI only (which works) until main firmware issues resolved

---

### 2026-01-13: PP5021C Memory Remapping (MMAP) Implementation

**Goal**: Implement memory remapping to allow Rockbox main firmware to execute

**Background**:
Rockbox crt0 startup code relies on PP5021C memory remapping to remap SDRAM from physical 0x10000000 to logical 0x00000000. Without this, addresses like 0x03E804DC (relative to remapped base) are invalid.

**Implementation**:

1. **MMAP Register Block** (0xF000F000-0xF000F03C)

   Added full MMAP emulation to bus.zig:
   ```zig
   // MMAP register offsets
   const MMAP_0 = 0x00;      // Base address for region 0
   const MMAP_1 = 0x04;      // Base address for region 1
   const MMAP_2 = 0x08;      // Base address for region 2
   const MMAP_3 = 0x0C;      // Base address for region 3
   const MMAP_MASK_0 = 0x10; // Mask for region 0
   // ... etc
   ```

2. **Address Translation**:

   When MMAP is enabled (MMAP_0 written), addresses in range 0x00000000-0x01FFFFFF are translated to 0x10000000-0x11FFFFFF:
   ```zig
   fn translateAddress(self: *Self, addr: u32) u32 {
       if (self.mmap_enabled and addr < 0x02000000) {
           return addr | 0x10000000;
       }
       return addr;
   }
   ```

3. **MMAP Activation**:

   The bootloader writes to MMAP registers at 0xF000F000, which triggers remapping:
   - Write to MMAP_0 (0xF000F00C) activates remapping callback
   - PP_VER read (0x70000000) with value 0x50503530 confirms PP5021

**Results**:

| Before MMAP | After MMAP |
|-------------|------------|
| PC=0x03E804DC → crash | PC=0x03E804DC → translated to 0x13E804DC |
| Invalid main() address | Valid execution continues |

**Files Changed**:
- `src/emulator/memory/bus.zig`: Full MMAP register emulation
- `src/emulator/core.zig`: Address translation in step()

---

### 2026-01-13: COP Sync Loop Skips - Complete Implementation

**Goal**: Skip all COP synchronization loops in Rockbox startup

**Problem**:
Rockbox crt0-pp.S has 8+ COP polling loops where CPU waits for COP to complete actions. Since we only emulate CPU, these loops are infinite.

**Solution**:

Added comprehensive loop detection and skip in core.zig:
```zig
// COP poll loop skip - addresses where CPU waits for COP
const loop_starts = [_]u32{
    0x10000204, 0x1000023C, 0x10000258, 0x10000270,
    0x10000288, 0x100002C8, 0x100002DC, 0x10000320
};
const loop_exits = [_]u32{
    0x10000214, 0x1000024C, 0x10000264, 0x1000027C,
    0x10000294, 0x100002DC, 0x100002E8, 0x1000032C
};

// When PC matches a loop start, jump to corresponding exit
for (loop_starts, loop_exits) |start, exit| {
    if (effective_pc == start) {
        self.cpu.setReg(15, exit);
        return 1;
    }
}
```

**Loop Addresses Identified**:

| Loop Start | Loop Exit | Purpose |
|------------|-----------|---------|
| 0x10000204 | 0x10000214 | First COP sync |
| 0x1000023C | 0x1000024C | Second COP sync |
| 0x10000258 | 0x10000264 | Third COP sync |
| 0x10000270 | 0x1000027C | Fourth COP sync |
| 0x10000288 | 0x10000294 | Fifth COP sync |
| 0x100002C8 | 0x100002DC | Sixth COP sync |
| 0x100002DC | 0x100002E8 | Seventh COP sync (self-poll) |
| 0x10000320 | 0x1000032C | Eighth COP sync |

**Results**:
- Firmware progresses through all COP sync stages
- BSS clear completes (millions of cycles)
- main() reached and begins executing

---

### 2026-01-13: Current State - Kernel COP Wake Loop (In Progress)

**Status**: Rockbox loads and starts kernel, but gets stuck in COP wake loop

**Progress**:
1. ✅ Bootloader executes correctly
2. ✅ rockbox.ipod loaded from disk (774KB)
3. ✅ MMAP remapping working
4. ✅ COP startup sync loops skipped (8 total)
5. ✅ main() called, kernel initializing
6. ⏳ **STUCK**: COP wake loop at 0x769C-0x76B8

**The Wake Loop Problem**:

After kernel initialization, Rockbox tries to wake the COP for dual-core operation:
```arm
@ Function at 0x769C (wake_core):
769C:  MOV R3, #0x60007000    ; COP_CTL base
76A0:  ADD R3, R3, #4         ; COP_CTL = 0x60007004
76A4:  MOV R2, #0x80000000    ; PROC_SLEEP bit
76A8:  STR R2, [R3]           ; Write sleep bit (wake request)
76AC:  LDR R2, [R3]           ; Read back
76B0:  TST R2, #0x80000000    ; Check if still sleeping
76B4:  BNE 76A8               ; Loop if sleeping
76B8:  BX LR                  ; Return when awake
```

The kernel calls this function repeatedly from a higher-level loop:
- Caller at ~0x7690 calls wake_core
- Checks COP_CTL bit 31
- If still sleeping, calls again
- Never exits because COP never actually wakes

**Attempted Solutions**:

1. **COP_WAKE_SKIP**: Force return from 0x769C function
   - Result: Millions of function calls, caller keeps calling

2. **cop_wake_count**: Track wake attempts, change COP_CTL read
   - Count increments on each COP_CTL write
   - After threshold, return bit 31 = 0 (awake)
   - Result: Count not incrementing properly due to write pattern mismatch

**COP_CTL Register Behavior**:
```zig
// In system_ctrl.zig
REG_COP_CTL => blk: {
    const ready_flags: u32 = 0x4000FE00 | (self.cop_ctl & 0x1FF);
    if (self.cop_wake_count >= 2) {
        break :blk ready_flags; // bit 31 = 0 (awake)
    } else {
        break :blk ready_flags | 0x80000000; // bit 31 = 1 (sleeping)
    }
},
```

**Debug Output**:
```
Final PC: 0x0000769C, Mode: system, Thumb: false
Executed 150000000 cycles
Timers: 45200 accesses
```

**Analysis of the wake_core Function**:

The function at 0x769C (wake_core) is designed to NEVER return. It's the COP sleep loop:
```arm
769C: push {r4, lr}
76A0: bl 0x7c620        ; Call CPU/COP init
76A4: bl 0x7670         ; Call PROC_ID check function
76A8: ldr r3, =0x60007004
76AC: mov r0, #0x80000000
76B0: str r0, [r3]       ; Write to COP_CTL
76B4: nop
76B8: b 0x76AC           ; INFINITE LOOP
```

It's called via a tail-call chain where LR is set to 0x769C before jumping to an init function. The init function eventually returns via `bx lr`, landing at wake_core.

**Key Discovery**:
- Both CPU and COP paths end up at wake_core via the tail-call chain
- wake_core has NO CPU/COP check - it unconditionally loops
- The LR is always 0x769C (self-referential), so returning via LR doesn't help

**Extended MMAP for Trampolines**:

Rockbox uses trampolines at addresses 0x03E8xxxx-0x03EFxxxx. These are SDRAM-relative addresses that need mapping:
```zig
// Handle Rockbox's trampolines at 0x03E8xxxx-0x03EFxxxx
if (addr >= 0x03E80000 and addr < 0x04000000) {
    translated = (addr - 0x03E80000) + SDRAM_START;
}
```

**Current Approach**:
Skip wake_core entirely at entry (0x769C) and jump to 0x76C4. However, the caller keeps returning to 0x769C creating a loop.

**Next Steps**:
1. Find the original caller that sets up LR=0x769C
2. Modify that caller's behavior to skip the COP path for CPU
3. Or patch the kernel to not call wake_core when running on CPU

**Files Changed**:
- `src/emulator/core.zig`: COP poll skips, MMAP detection, wake skip
- `src/emulator/peripherals/system_ctrl.zig`: COP_CTL always returns sleeping
- `src/emulator/memory/bus.zig`: Extended MMAP for trampolines (0x03E8xxxx)

---

---

### 2026-01-14: Direct Rockbox Loading and MMAP Improvements

**Goal**: Enable direct loading of rockbox.ipod into SDRAM, bypassing the bootloader's FAT32 filesystem

**Problem Discovered**:
When using `--load-sdram rockbox.ipod`, the firmware wasn't executing correctly:
1. Header detection missing "ip6g" model ID (iPod Video 5th gen)
2. MMAP only translated 0x00000000-0x07FFFFFF, but Rockbox is linked at 0x08000000
3. PC was set to 0x10000000 (physical SDRAM) instead of 0x08000000 (Rockbox's linked address)
4. MMAP permission bits not initialized when enabling directly

**Fixes Applied**:

1. **iPod Firmware Header Detection** (`main.zig`):
   - Added "ip5g" and "ip6g" model IDs to header detection
   - Rockbox for iPod Video uses "ip6g" magic bytes
   ```zig
   // Check for iPod firmware header (model identifier at offset 4)
   if (std.mem.eql(u8, fw_data[4..8], "ip5g") or
       std.mem.eql(u8, fw_data[4..8], "ip6g"))
   ```

2. **Extended MMAP Translation** (`bus.zig`):
   - Added translation for 0x08000000-0x0FFFFFFF range
   - Rockbox is linked at 0x08000000, not 0x10000000
   ```zig
   // Handle Rockbox's main code linked at 0x08000000
   if (addr >= 0x08000000 and addr < 0x10000000) {
       translated = (addr - 0x08000000) + SDRAM_START;
   }
   ```

3. **MMAP Permission Initialization** (`main.zig`):
   - When enabling MMAP directly, must also set permission bits
   ```zig
   emu.bus.mmap_enabled = true;
   emu.bus.mmap_physical[0] = 0x0F00; // Set permission bits
   ```

4. **Correct Entry Point** (`main.zig`):
   - PC must be set to 0x08000000 (Rockbox's linked address), not 0x10000000
   - MMAP translates 0x08000000 → 0x10000000 for memory access
   ```zig
   emu.cpu.setPc(0x08000000);
   ```

5. **effective_pc Calculation** (`core.zig`):
   - Added 0x08xxxxxx range to effective_pc translation for COP skip logic

**Current Status**:
- Header detection: Working
- MMAP translation: Working for 0x00-0x0F range
- Entry execution: Progresses through startup code
- **Issue**: Execution eventually hits exception cascade (bouncing between vectors 0x04 and 0x08)
- Root cause: Need to investigate why exception handlers enter infinite loop

**MMAP Translation Summary**:
| Virtual Address | Physical Address | Description |
|----------------|------------------|-------------|
| 0x00000000-0x00FFFFFF | 0x10000000+ | Standard MMAP remap |
| 0x03E80000-0x03FFFFFF | 0x10000000+ | Rockbox trampolines |
| 0x08000000-0x0FFFFFFF | 0x10000000+ | Rockbox linked code |
| 0x10000000+ | Direct | Physical SDRAM |

**Files Changed**:
- `src/emulator/main.zig`: Header detection, MMAP init, entry point
- `src/emulator/memory/bus.zig`: Extended MMAP for 0x08xxxxxx
- `src/emulator/core.zig`: effective_pc translation, INVALID_PC check

---

### 2026-01-14: CP15 Coprocessor Emulation & SDRAM Stack Fix

**Goal**: Fix exception cascade when loading Rockbox directly via --load-sdram

**Problem Identified**:
When loading rockbox.ipod directly, execution bounced between exception vectors 0x04 (undefined)
and 0x08 (SWI). Investigation revealed two issues:

1. **CP15 Coprocessor Instructions**: Rockbox uses CP15 (System Control Coprocessor) instructions
   for cache/MMU control. ARM7TDMI doesn't have CP15, but PP5021C does. Without emulation,
   these triggered undefined instruction exceptions.

2. **SDRAM Stack Out of Bounds**: Initial SP was set to 0x0BFFFFE0 (top of 64MB SDRAM),
   but emulator defaults to 32MB. Stack writes went to unmapped memory, corrupting LR.

**Root Cause Analysis**:

The exception cascade was caused by MRC/MCR p15 instructions at Rockbox startup:
```asm
MRC p15, 0, R0, c1, c0, 0   ; Read control register
BIC R0, R0, #...            ; Clear cache bits
MCR p15, 0, R0, c1, c0, 0   ; Write control register
MRC p15, 0, PC, c7, c10, 3  ; Test clean with PC = set flags
```

The MRC with Rd=PC is a special case that sets condition flags instead of writing to PC.
Rockbox uses this to test cache state in a loop.

**Solution Implemented**:

1. **CP15 Emulation** (`arm_executor.zig`):
   - Added `executeCoprocessor15()` function
   - Handles MRC (read) and MCR (write) for key registers:
     - CRn=0: ID register (returns 0x41007000 for ARM720T-like ID)
     - CRn=1: Control register (returns 0 = cache/MMU disabled)
     - CRn=2: Page table base
     - CRn=3: Domain access control
     - CRn=7: Cache operations
     - CRn=8: TLB operations
   - MRC with Rd=PC sets NZCV flags from result (Z=1 for cache test = pass)
   - MCR writes are logged but ignored (no actual cache in emulator)

2. **Stack Location Fix** (`main.zig`):
   - Changed initial SP from 0x0BFFFFE0 to 0x09FFFFE0
   - 0x09FFFFE0 is within 32MB SDRAM (maps to physical 0x11FFFFE0)
   - Works with both 32MB and 64MB configurations

3. **Invalid PC Detection** (`core.zig`):
   - Added check for PC values > 0x80000000 or in unmapped ranges
   - Logs detailed register state and halts cleanly on invalid jump

**Result**:
- Rockbox successfully executes through CP15 setup
- Page table initialization works (writes to 0x0BFFC000)
- MMU/cache enable sequence completes
- Execution progresses to FAT32 filesystem scanning
- No more exception cascade!

**CP15 Register Reference (PP5021C)**:

| CRn | CRm | op2 | Name | Emulated Value |
|-----|-----|-----|------|----------------|
| 0 | 0 | 0 | Main ID | 0x41007000 |
| 0 | 0 | 1 | Cache Type | 0x00000000 |
| 1 | 0 | 0 | Control | 0x00000000 |
| 2 | 0 | 0 | TTB | (ignored) |
| 3 | 0 | 0 | Domain Access | (ignored) |
| 7 | * | * | Cache Ops | Z=1 for test |
| 8 | * | * | TLB Ops | (ignored) |

**Files Changed**:
- `src/emulator/cpu/arm_executor.zig`: CP15 emulation
- `src/emulator/main.zig`: SP initialization within 32MB
- `src/emulator/core.zig`: Invalid PC detection

**Next Steps**:
1. Rockbox now reaches filesystem scanning
2. Need proper FAT32 disk image with .rockbox directory
3. Or investigate further what files Rockbox is looking for

---

### 2026-01-14: RTOS Scheduler Investigation - Timer1 and Idle Loop

**Goal**: Get LCD pixel writes to occur in Rockbox firmware

**Problem Identified**:
After Rockbox loads successfully (checksum OK, "Rockbox loaded." printed), the CPU gets stuck
in an idle loop at 0x769C (wake_core function) with zero LCD writes. The RTOS scheduler never runs.

**Root Cause Analysis**:

1. **Timer1 Never Enabled**: The debug trace shows `Timer1_enabled=false` even after Rockbox
   starts. Rockbox's `tick_start()` function never runs, which means `kernel_init()` is
   either not called or exits early.

2. **COP Synchronization Issue**: The Rockbox kernel uses COP (Coprocessor) synchronization
   during initialization. Without proper COP responses, the kernel enters a fallback path
   that skips thread creation and scheduler setup.

3. **Idle Loop Structure**: The CPU ends up in `wake_core()` at 0x769C which is the COP
   idle function. This is designed to never return - it waits for interrupts. But since
   Timer1 is never enabled, no scheduler tick interrupts occur.

**Execution Flow Traced**:
```
1. Bootloader loads rockbox.ipod to 0x10000000
2. Bootloader jumps to Rockbox via COP_CTL write
3. Rockbox starts at 0x10000000 (MSR CPSR, #0xD3)
4. COP polling loop at 0x10000148 - SKIPPED by emulator
5. Early init code runs (0x10000154-0x100001BC)
6. [Gap - kernel init should happen here]
7. CPU reaches wake_core at 0x1000769C via MMAP
8. COP_WAKE_SKIP triggers, jumps to 0x76C4
9. Code at 0x76C4 loops back to 0x769C
10. Stuck in idle loop forever
```

**Approaches Attempted**:

1. **Install Minimal IRQ Handler**: Wrote ARM code to SDRAM at 0x10000018 that acknowledges
   Timer1 and returns. Handler works but doesn't invoke scheduler.
   - IRQ fires correctly
   - Handler executes (LDR R0, STR to TIMER1_VAL, SUBS PC, LR, #4)
   - CPU returns to idle loop - no progress

2. **Skip Idle Loop**: Tried jumping past wake_core to 0x76C4, 0x7700
   - 0x76C4: Still part of idle loop, cycles back to 0x769C
   - 0x7700: Causes crash (invalid PC 0x2FFF1EE0) due to missing setup

3. **Protect Timer1 Interrupt**: Added protection in interrupt controller to prevent
   firmware from disabling Timer1.
   - Works: Firmware writes 0xFFFFFFFF to CPU_INT_DIS but Timer1 stays enabled
   - Still doesn't help: No scheduler to invoke

**Key Technical Details**:

Mailbox registers (0x60001000):
- MBX_MSG_STAT: Read to check COP intend_sleep bit (0x8)
- MBX_MSG_SET/CLR: Set/clear mailbox bits
- CPU uses these to synchronize with COP

PROC_CTL registers (0x60007000):
- CPU_CTL: 0x60007000
- COP_CTL: 0x60007004
- PROC_SLEEP bit (0x80000000): Set when core enters sleep

wake_core loop condition:
```c
while ((MBX_MSG_STAT & (0x4 << othercore)) != 0 &&
       (PROC_CTL(othercore) & PROC_SLEEP) == 0);
```

**Current Status**:

The fundamental issue is that Rockbox requires proper COP synchronization during kernel
initialization. Without the COP responding correctly:
1. Thread creation may be skipped
2. Timer1 (scheduler tick) is never enabled
3. CPU enters idle loop with no way to make progress

**Possible Solutions** (not yet implemented):

1. **Full COP Emulation**: Emulate the COP as a second ARM7TDMI core that responds
   to synchronization requests.

2. **Fake COP Responses**: Make mailbox and PROC_CTL registers return values that
   simulate a responsive COP.

3. **Direct Thread Invocation**: Identify the main thread entry point and force
   the CPU to jump there, bypassing the scheduler.

4. **Alternative Firmware**: Use a simpler Rockbox build that doesn't require COP
   synchronization (single-core build).

**Files Changed**:
- `src/emulator/core.zig`: KERNEL_FIX (Timer1 enable), COP_WAKE_SKIP
- `src/emulator/peripherals/interrupt_ctrl.zig`: Protected interrupt mask
- `src/emulator/peripherals/timers.zig`: Debug output for Timer1 fires

**Next Steps**:
1. Investigate COP emulation approach
2. Or find Rockbox single-core build options
3. Or trace deeper into kernel_init() to find exact failure point

---

### 2026-01-14: Fake COP Responses and Timer1 Kickstart

**Goal**: Break out of wake_core idle loop by faking COP responses and forcibly enabling Timer1

**Background**:
The previous investigation identified that the CPU was stuck in wake_core (0x769C-0x76DC) because:
1. COP never responds to wake signals
2. Timer1 never enabled by firmware (kernel init incomplete)
3. RTOS scheduler never runs

**Implementation**:

1. **Fake COP Mailbox Responses** (`bus.zig`):

   Added mailbox register emulation to simulate COP acknowledging wake requests:
   ```zig
   // New fields in MemoryBus struct
   mbx_msg_stat: u32,           // MBX_MSG_STAT - Message status register
   mbx_cop_clear_countdown: u32, // Cycle counter for auto-clearing COP response bits

   // Constants
   const MBX_MSG_STAT_OFFSET: u32 = 0x00;  // 0x60001000 - Status register
   const MBX_MSG_SET_OFFSET: u32 = 0x04;   // 0x60001004 - Set bits in status
   const MBX_MSG_CLR_OFFSET: u32 = 0x08;   // 0x60001008 - Clear bits in status
   const MBX_CPU_WAKE_BIT: u32 = 0x4;      // Bit 2: CPU wake signal
   const MBX_COP_WAKE_BIT: u32 = 0x8;      // Bit 3: COP wake signal
   ```

   When CPU sets the COP wake bit (0x8), the emulator auto-clears it after 10 reads to simulate COP acknowledging the wake request.

2. **COP_CTL PROC_SLEEP Bit** (`system_ctrl.zig`):

   Made COP_CTL always return PROC_SLEEP=1 (bit 31 set):
   ```zig
   REG_COP_CTL => blk: {
       const ready_flags: u32 = 0x4000FE00 | (self.cop_ctl & 0x1FF);
       const result = ready_flags | 0x80000000; // bit 31 = 1 (sleeping)
       break :blk result;
   },
   ```

   This makes wake_core exit its inner loop immediately (COP is always "sleeping" so no need to wait).

3. **Timer1 Kickstart** (`core.zig`):

   When CPU stuck in idle loop for too long, forcibly enable Timer1:
   ```zig
   // Detect idle loop at 0x76C4-0x76DC
   const in_idle_loop = (pc >= 0x76C4 and pc <= 0x76DC) or
       (effective_pc >= 0x100076C4 and effective_pc <= 0x100076DC);

   if (in_idle_loop and !self.timer1_enabled_by_emulator) {
       self.wake_loop_iterations += 1;
       if (self.wake_loop_iterations > 10000) {
           self.timer1_enabled_by_emulator = true;
           // Configure Timer1 for 10ms tick (count=10000)
           const timer_config: u32 = 0xC0000000 | 10000; // Enable + Repeat + 10000
           self.timer.timer1.setConfig(timer_config);
           self.int_ctrl.cpu_enable |= 0x00000001; // Timer1 is bit 0
           self.int_ctrl.protectInterrupt(.timer1);
       }
   }
   ```

4. **IRQ Enable in COP_WAKE_SKIP** (`core.zig`):

   Force IRQ enable when skipping wake_core:
   ```zig
   if (pc == 0x769C or effective_pc == 0x1000769C) {
       // ... skip logic ...
       self.cpu.enableIrq();  // Ensure IRQs are enabled
       return 1;
   }
   ```

**Results**:

| Metric | Status |
|--------|--------|
| Timer1 fires | ✅ Working (TIMER1_FIRE messages in output) |
| IRQs taken | ✅ CPU enters IRQ mode (Mode=0x12) |
| Scheduler tick | ❌ Not invoked |
| LCD writes | ❌ Still 0 |

**Why Scheduler Tick Doesn't Work**:

The Timer1 fires correctly and IRQs are taken, but the scheduler tick function is never invoked because:

1. **IRQ Vector Not Set Up**: The IRQ vector at 0x40000018 contains 0x84813004 (garbage/boot ROM code), not the kernel's IRQ handler
2. **Kernel Init Incomplete**: Because we skip wake_core at entry, the kernel never completes initialization including installing interrupt handlers
3. **Thread List Empty**: Without full kernel init, no threads are created, so even if scheduler ran, there's nothing to schedule

**Debug Output Observed**:
```
WAKE_CORE: entry #1, LR=0x0000769C
PERIODIC: cycle=110000000 PC=0x400071DC R0=0xFE40FF31 ...
TIMER1_FIRE: raw_status=0x00800001, cpu_enabled=0x00000001
WAKE_CORE: Forcing exit after 1001 loop iterations
```

The periodic trace shows PC stuck in 0x400071DC-0x400071EC range (bootloader code, not kernel).

**Key Insight**:

The fundamental problem is a chicken-and-egg issue:
- To break out of wake_core, we skip kernel initialization code
- But kernel initialization is what installs IRQ handlers and creates threads
- Without IRQ handlers and threads, Timer1 interrupts don't help

**Files Changed**:
- `src/emulator/memory/bus.zig`: Mailbox fake COP responses
- `src/emulator/peripherals/system_ctrl.zig`: COP_CTL PROC_SLEEP tracing
- `src/emulator/core.zig`: Timer1 kickstart, COP_WAKE_SKIP with IRQ enable

**Next Steps for Next Agent**:

1. **Option A - Let Kernel Initialize**: Instead of skipping wake_core at entry (0x769C), let the kernel run until it naturally reaches the idle loop. This requires:
   - Making COP_CTL return "awake" after first few checks
   - Or detecting when kernel init is complete before enabling wake_core skip

2. **Option B - Install Custom IRQ Handler**: Write a minimal IRQ handler that calls the Rockbox scheduler tick:
   - Find address of `timer1_tick()` function in Rockbox binary
   - Install trampoline at 0x40000018 that calls it
   - Requires disassembling Rockbox to find function address

3. **Option C - Direct Thread Start**: Find the main thread entry point and force execution there:
   - Bypass scheduler entirely
   - Set up minimal thread context
   - Jump to main menu/UI code

---

---

### 2026-01-14: COP Always-Awake Fix - Major Progress!

**Goal**: Fix kernel initialization getting stuck in wake_core COP synchronization loop

**Background**:
Previous investigations identified a chicken-and-egg problem:
- wake_core function at 0x7694-0x76B8 loops forever writing to COP_CTL waiting for IRQ
- Skipping wake_core caused the caller to loop back and call it again infinitely
- The saved LR on stack was 0 (task entry point), so returning from the function didn't help

**Root Cause Analysis**:

Traced the actual COP_CTL read/write pattern:
1. System does only 2 COP_CTL reads BEFORE entering wake_core
2. Both reads returned SLEEPING (bit 31 = 1)
3. This caused the system to call wake_core to "wake up" the COP
4. wake_core function structure:
   ```arm
   7694: PUSH {R4, LR}           ; Function entry
   7698: BL 0x7C618              ; Call setup function
   769C: BL 0x7668               ; Call another setup
   76A0: LDR R3, [PC, #12]       ; Load COP_CTL address (0x60007004)
   76A4: MOV R0, #0x80000000     ; Load wake signal
   76A8: STR R0, [R3]            ; Write to COP_CTL
   76AC: NOP
   76B0: B 0x76A4                ; INFINITE LOOP - no exit condition!
   ```

**Key Insight**:
The infinite loop at 0x76A4-0x76B0 has NO SOFTWARE EXIT CONDITION. It's designed to:
1. Send wake signal to COP continuously
2. Be interrupted by Timer1 IRQ or COP response IRQ
3. Never exit through normal control flow

Since we don't emulate the COP or have proper IRQ support, this loop is genuinely infinite.

**Solution: COP Always-Awake**:

Instead of trying to skip wake_core (which kept getting re-called), we prevent it from being called in the first place by making COP_CTL always return "awake":

```zig
// In system_ctrl.zig - COP_CTL read
REG_COP_CTL => blk: {
    // EXPERIMENT: Always return COP awake (bit 31 = 0)
    // This prevents the system from needing to call wake_core
    result = ready_flags; // bit 31 = 0 (awake)
    sleep_state = "AWAKE";
    break :blk result;
},
```

**Results**:

| Before | After |
|--------|-------|
| 2 COP_CTL reads → stuck in wake_core | Many COP_CTL reads → system progresses |
| PC stuck at 0x769C-0x76B8 | Execution reaches FAT32 filesystem scanning |
| 0 LCD writes | System actively reading directory entries |
| kernel_init=false | System progresses through initialization |

**Debug Output After Fix**:
```
COP_CTL READ #1: 0x4000FE00 (AWAKE, ack_countdown=0, kernel_init=false)
COP_CTL READ #2: 0x4000FE00 (AWAKE, ack_countdown=0, kernel_init=false)
...
COP_CTL READ #20: 0x4000FE00 (AWAKE, ack_countdown=0, kernel_init=false)
...
DIR_ENTRY[0x11006F54]: first_byte=0x41('A'), val=0x50006941
LFN_START READ at 0x11006F54: val=0x50006941
ATTR READ at 0x11006F5C: val=0x0F005F00, attr_byte=0x0F
```

The system is now:
1. Progressing past COP synchronization
2. Initializing FAT32 filesystem
3. Reading directory entries from SDRAM
4. Searching for iPod_Control and .rockbox directories

**Remaining Work**:
- Timer1 still shows `enabled=false` - scheduler not running yet
- IRQ_vector not installed - interrupt handlers not set up
- PC eventually reaches ~0x08000144-0x08000148 in early init code
- May need additional fixes to complete kernel initialization

**Technical Details**:

The COP_CTL register at 0x60007004:
- Bit 31 (PROC_SLEEP): 1 = COP sleeping, 0 = COP awake
- By always returning bit 31 = 0, the firmware sees COP as already awake
- This lets initialization proceed without blocking on COP sync

**Files Changed**:
- `src/emulator/peripherals/system_ctrl.zig`: COP_CTL always returns AWAKE
- `src/emulator/core.zig`: Updated wake_core skip logic (now rarely triggers)

**Commit**: b360f1d

---

### 2026-01-14: SDRAM 64MB Fix - Major Breakthrough!

**Goal**: Debug why Rockbox main firmware crashes after "Rockbox loaded."

**Critical Bug Found: SDRAM_END Hardcoded to 32MB**

The main() function at virtual address 0x03E804DC was executing `BX LR` (return) immediately
instead of actual code. Investigation revealed:

1. **The .init section copy loop WAS running** (R2 destination pointer advanced)
2. **But destination memory never changed** (main() still had 0xE12FFF1E garbage)
3. **Root cause**: `SDRAM_END` in bus.zig was hardcoded to `0x11FFFFFF` (32MB)
4. **Problem**: Rockbox iPod Video is compiled for 64MB RAM
   - ENDAUDIOADDR = 0x03E80000 (where .init section goes)
   - With MMAP, this translates to physical 0x13E8xxxx
   - 0x13E8xxxx > 0x11FFFFFF, so `getRegion()` returned `.unmapped`
   - Writes to unmapped memory were silently dropped!

**Fixes Applied**:

1. **SDRAM_END**: `0x11FFFFFF` → `0x13FFFFFF` (64MB)
   ```zig
   const SDRAM_END: u32 = 0x13FFFFFF; // 64MB maximum
   ```

2. **MMAP mask**: `0x00003E00` (32MB) → `0x00003C00` (64MB)
   Required for addresses in 0x03E8xxxx range to translate correctly.

3. **COP_CTL kernel-phase response**: Return AWAKE after kernel_init_complete
   The scheduler loops wait for COP to be AWAKE, not SLEEPING.

**Results After Fix**:

| Before Fix | After Fix |
|------------|-----------|
| main() = 0xE12FFF1E (BX LR) | main() = 0xE92D4880 (PUSH {R7,R11,LR}) |
| Execution returns immediately | Execution enters kernel init |
| 0 LCD writes from firmware | Timer1 enabled, IRQ handler running |

**Current State**:

- ✅ Bootloader LCD: 460,800 pixel writes (working perfectly)
- ✅ .init section copy: Working (main() has valid code)
- ✅ main() execution: Starts correctly
- ✅ kernel_init: Progresses (Timer1 enabled, IRQ vector installed)
- ❌ LCD from Rockbox: 0 writes (stuck in IRQ handler loops)

**IRQ Handler Loop Analysis**:

After kernel init, CPU enters IRQ mode and gets stuck around 0x84B5C-0x84BA4.
This code is in the scheduler/threading system and polls for COP coordination:
- Reads from process control array at R12 + R0*4
- Tests bit 31 (PROC_SLEEP) for each task/core
- Loops waiting for specific conditions

The fundamental issue: **Rockbox assumes dual-core operation throughout the kernel**,
not just at startup. The scheduler tries to coordinate work with COP continuously.

**Potential Solutions** (not yet implemented):

1. **Full COP emulation**: Emulate COP as second ARM core responding to coordination
2. **Single-core Rockbox build**: Compile Rockbox with single-core option
3. **Aggressive loop skipping**: Detect and skip all COP coordination loops
4. **Fake scheduler tick**: Inject thread context switches without COP

**Commit**: b360f1d

---

### 2026-01-14: Scheduler Loop Analysis and Skip Implementation (continued)

**Goal**: Break out of scheduler loops to allow GUI thread to run and produce LCD output

**Analysis Summary**:

After extensive investigation, the execution flow was traced:

1. **main() Execution**:
   - main() at 0x03E804DC is reached and executing
   - Calls kernel_init() at 0x7C618
   - kernel_init() performs ~100 initialization instructions
   - Enables Timer1, installs IRQ handler
   - Then blocks on scheduler

2. **Scheduler Flow Identified**:
   - IRQ handler at 0x7C528 calls scheduler polling at 0x89A20
   - Scheduler at 0x89A20 calls switch_thread at 0x84B5C
   - switch_thread at 0x84B5C loops waiting for COP/thread sync
   - This creates an infinite loop: IRQ → scheduler → switch_thread → loop

3. **Skip Implementation Attempts**:

   | Address | Skip Type | Effect |
   |---------|-----------|--------|
   | 0x89A20 | Scheduler skip | Prevented thread switching entirely |
   | 0x84B5C | switch_thread skip | Returns immediately, scheduler continues |
   | 0x7C558 | Caller loop escape | Uses stack to find return address |
   | 0x7C7E0 | Idle loop skip | Triggers timer to attempt thread switch |

4. **Counter Separation**:
   - Separated `main_trace_count` from `switch_thread_count` to avoid interference
   - main() trace now shows 100 instructions of kernel initialization

5. **Key Observation - No Thread Switching**:
   - When we skip switch_thread, we return "no thread to run"
   - The scheduler accepts this and returns to idle loop
   - No other threads (like GUI thread) ever get scheduled
   - Result: 0 LCD pixel writes

**Root Cause Identified**:

The Rockbox kernel's thread scheduler is deeply intertwined with COP (Coprocessor) synchronization:
- switch_thread at 0x84B5C expects COP responses to determine runnable threads
- Without real COP, the scheduler cannot identify which threads are ready
- Skipping switch_thread returns "no threads" which prevents any work from happening

**Current State**:

- ✅ main() reached and executes ~100 instructions of kernel init
- ✅ Timer1 enabled, IRQ handler installed
- ✅ Timer IRQ fires and enters handler
- ✅ Scheduler is called from IRQ handler
- ❌ switch_thread cannot find runnable threads without COP
- ❌ GUI thread never scheduled
- ❌ 0 LCD pixel writes from Rockbox main firmware

**Skips Currently Active**:

1. **switch_thread at 0x84B5C**: Skip after 1000 iterations, return 0
2. **Caller loop at 0x7C558**: Escape using stack after 4 switch_thread skips
3. **Idle loop at 0x7C7E0**: Enable IRQ and trigger Timer1 after 50001 iterations

**Required Next Steps**:

1. **Implement Real Thread Queue Simulation**:
   - Instead of skipping switch_thread, simulate finding a runnable thread
   - Return thread context pointer instead of 0
   - This requires understanding Rockbox's thread control block layout

2. **Alternative: Disable COP-Dependent Scheduling**:
   - Patch Rockbox to use single-core scheduling mode
   - Or modify COP_CTL responses to satisfy all scheduler checks

3. **Alternative: Direct LCD Test**:
   - Skip kernel init entirely and jump directly to LCD driver code
   - Test LCD output without going through scheduler

**Files Modified This Session**:

- `src/emulator/core.zig`: Added switch_thread skip, separated counters
- `src/emulator/peripherals/system_ctrl.zig`: COP_CTL context-aware responses

**Commit**: 2c640cf

---

### 2026-01-14: SDRAM Configuration - 32MB vs 64MB and Runtime Detection

**Goal**: Configure emulator for 30GB iPod 5G (32MB SDRAM)

**Critical Discovery: Rockbox Runtime RAM Detection**

Rockbox uses a **single unified build** for all iPod Video models. It detects RAM size at runtime using a clever technique in `crt0-pp.S`:

```asm
/* detect 32mb vs 64mb model */
mov    r2, #0x12000000
mov    r3, #64
strb   r3, [r2, #-1]   /* write 64 to 0x11FFFFFF (last byte of first 32MB) */

mov    r2, #0x14000000
mov    r3, #32
strb   r3, [r2, #-1]   /* write 32 to 0x13FFFFFF (last byte of second 32MB) */

/* If 32MB RAM: 0x13FFFFFF wraps to 0x11FFFFFF, value becomes 32 */
/* If 64MB RAM: 0x13FFFFFF is separate location, value stays 64 */
```

The detection is read later in `system_init()` (`system-pp502x.c:598`):
```c
volatile unsigned char *end32 = (volatile unsigned char *)0x01ffffff;
probed_ramsize = *end32;
```

And used in `core_allocator_init()` (`core_alloc.c:48`):
```c
if(MEMORYSIZE==64 && probed_ramsize!=64)
{
    audiobufend -= (32<<20);  // Reduce audio buffer by 32MB
}
```

**iPod Video Memory Configurations**:

| Model | Storage | RAM | Logic Board |
|-------|---------|-----|-------------|
| 5G | 30GB | 32MB | 820-1763-A |
| 5G | 60GB | 64MB | 820-1763-A |
| 5.5G | 30GB | 32MB | 820-1975-A |
| 5.5G | 80GB | 64MB | 820-1975-A |

**Emulator Fixes Applied**:

1. **Default SDRAM to 32MB** (`main.zig`):
   ```zig
   var sdram_mb: usize = 32; // For 30GB iPod 5G
   ```

2. **Address Wrapping** (`bus.zig`):
   ```zig
   // Apply address wrapping for smaller SDRAM sizes
   // Rockbox uses this for RAM detection
   const raw_offset = addr - SDRAM_START;
   const offset = raw_offset % self.sdram.len;
   ```

   On 32MB: Address 0x13FFFFFF wraps to 0x11FFFFFF (offset 0x1FFFFFF)

**iFlash Solo Note**: Storage mods do NOT affect RAM. The 32MB vs 64MB is determined by physical RAM chips on the logic board, not storage.

**Results**:
- Address wrapping works correctly
- main() at 0x13E804DC (wraps to 0x11E804DC) = 0xE92D4880 (correct code!)
- Kernel initialization proceeds with 32MB detection

**Sources from Rockbox**:
- `firmware/target/arm/pp/crt0-pp.S:145-160` - RAM detection algorithm
- `firmware/target/arm/pp/system-pp502x.c:594-599` - probed_ramsize reading
- `firmware/core_alloc.c:46-52` - Runtime audiobufend adjustment
- `tools/configure:1980` - "memory=64 # always. This is reduced at runtime if needed"

---

### 2026-01-14: iPod Video Direct Firmware Loading - Entry Point and PROC_ID Fixed

**Goal**: Load iPod Video Rockbox firmware directly via --load-sdram bypassing bootloader

**Background**:
The bootloader approach works but has COP synchronization issues. Attempting direct firmware loading to:
1. Bypass bootloader complexity
2. Test PROC_ID register behavior
3. Understand crt0 initialization sequence

**Critical Discoveries**:

1. **iPod 6G vs iPod Video Firmware Confusion**

   Initially loaded wrong firmware causing immediate crash:
   - iPod 6G (Classic) firmware: Linked at 0x08000000 (S5L8702 SDRAM base)
   - iPod Video firmware: Linked at 0x10000000 (PP5021C SDRAM base)

   File locations:
   | Firmware | Location | SDRAM Base |
   |----------|----------|------------|
   | iPod 6G (wrong) | firmware/rockbox/.rockbox/rockbox.ipod | 0x08000000 |
   | iPod Video (correct) | firmware/rockbox/ipodvideo/.rockbox/rockbox.ipod | 0x10000000 |

2. **Entry Point Correction**

   Initial entry point was wrong:
   - Before: 0x10000100 (middle of BSS clear loop!)
   - After: 0x10000000 (actual crt0 entry point)

   The code at 0x10000000 is `MSR CPSR, #0xD3` (supervisor mode, IRQ disabled).

3. **PROC_ID Register Working**

   The PROC_ID register at 0x60000000 now returns correct values:
   ```
   PROC_ID_READ: addr=0x60000000 returning 0x55
   PROC_ID_CHECK: R0=0x00000055 (0x55=CPU, 0xAA=COP)
   PROC_ID_BRANCH: Taking CPU path
   ```

   Implementation in bus.zig:
   ```zig
   .proc_id => blk: {
       const proc_val: u32 = if (self.is_cop_access) 0xAA else 0x55;
       break :blk proc_val;
   },
   ```

4. **crt0 Initialization Sequence Traced**

   Full startup sequence now works:
   | Step | Address | Action | Status |
   |------|---------|--------|--------|
   | 1 | 0x10000000 | MSR CPSR (mode setup) | ✅ |
   | 2 | 0x10000004 | LDR R0, [PC, #0x14] → PROC_ID | ✅ |
   | 3 | 0x10000008 | LDR R0, [R0] = 0x55 | ✅ |
   | 4 | 0x1000000C | CMP R0, #0x55 | ✅ |
   | 5 | 0x10000010 | BNE to COP path | ✅ (takes CPU path) |
   | 6 | 0x10000148 | COP poll loop | ✅ (skipped) |
   | 7 | 0x10000154 | MMAP configuration | ✅ |
   | 8 | 0x10000220 | .init section copy | ✅ |
   | 9 | 0x100002C8 | Stack fill (0xDEADBEEF) | ✅ |
   | 10 | 0x100002D4 | Jump to main() | ❌ (invalid address) |

5. **Stack Fill Loop Analysis**

   The loop at 0x100002C8-0x100002D0 fills stack with 0xDEADBEEF:
   ```arm
   2C8: CMP R2, SP           ; Compare current addr with SP
   2CC: STRLO R0, [R2], #4   ; Store 0xDEADBEEF, increment R2
   2D0: BLO 0x2C8            ; Loop if R2 < SP
   ```

   Traced progress:
   - Initial R2 = 0x4000B0D0 (stack bottom)
   - Target SP = 0x40010000 (top of IRAM stack)
   - ~8KB filled in ~12K cycles

**CRITICAL BUG FOUND: main() Address Invalid**

At 0x100002D4, the code does `LDR PC, [0x100003A8]` to jump to main().
The value at 0x100003A8 is **0x03E804DC**.

Problem:
- 0x03E804DC with MMAP translates to physical 0x13E804DC
- This address is ~65MB offset from SDRAM base
- But the firmware binary is only ~751KB (770,564 bytes)
- The value at 0x13E804DC is 0xE12FFF1E = `BX LR` (just a return!)

This means:
1. main() address is in a region that was never populated with firmware data
2. The address 0x03E804DC assumes the .init section copy populated it
3. But .init section range (0x03E88694-0x03E91BA8) doesn't include main()
4. main() is **outside** the loaded firmware file!

**Execution Result**:
```
JUMP_TO_MAIN: PC=0x000002D4 loading from 0x100003A8 = 0x03E804DC
KERNEL_PATH: Reached main() entry at PC=0x03E804DC (effective=0x13E804DC) instr=0xE12FFF1E
```

After `BX LR` returns, execution falls back to reset vector (0x00000000).

**Conclusion**:

The iPod Video Rockbox firmware (rockbox.ipod) is a **partial** binary that assumes:
1. The bootloader has already set up memory
2. Additional code sections are loaded from somewhere else
3. OR the binary is meant to be loaded differently (not raw to SDRAM)

The bootloader-based approach is likely the correct path forward, as it:
1. Properly handles the .ipod file format
2. Loads all required sections
3. Sets up MMAP before jumping to firmware

**Files Changed**:
- `src/emulator/main.zig`: Fixed entry point to 0x10000000
- `src/emulator/memory/bus.zig`: Added PROC_ID read tracing
- `src/emulator/core.zig`: Expanded MMAP EXEC trace for R2/SP debugging

**Commits**: 94aadc1 (fix: BSS clear loop skip was skipping past main() jump)

---

### 2026-01-14: LCD Bypass Test Implementation

**Goal**: Test LCD output directly, bypassing scheduler issues

**Rationale**:
Since the RTOS scheduler is blocked waiting for COP responses, and all attempts to skip scheduler loops result in "no runnable threads", try a different approach: directly test LCD functionality.

**Implementation**:

Added LCD bypass trigger in CALLER_LOOP_SKIP after 10 consecutive failures:
```zig
// In core.zig - CALLER_LOOP_SKIP handler
if (self.caller_loop_escape_failures >= 10 and !self.lcd_bypass_done) {
    std.debug.print("\n*** LCD BYPASS FROM CALLER LOOP ***\n", .{});
    // Fill screen with red using LCD controller directly
    const red = lcd.Color.fromRgb(255, 0, 0);
    self.lcd_ctrl.clear(red);
    self.lcd_ctrl.update();
    self.lcd_bypass_done = true;
}

// After LCD bypass, try jumping to idle loop directly
if (self.caller_loop_escape_failures >= 15) {
    self.cpu.regs.switchMode(.supervisor);
    self.cpu.regs.cpsr.irq_disable = false;
    self.cpu.setReg(13, 0x08001000);
    self.cpu.setReg(15, 0x7C7E0);
    self.int_ctrl.clearInterrupt(.timer1);
    self.caller_loop_escape_failures = 0;
    self.sched_skip_count = 0;
    return 1;
}
```

**Added Tracking**:
- `caller_loop_escape_failures: u32` - Counter for consecutive zero-stack escape failures
- `lcd_bypass_done: bool` - Flag to prevent repeated LCD bypass attempts

**Results**:
- LCD bypass logic is in place but hasn't triggered yet in current test runs
- The fundamental issue remains: firmware doesn't reach LCD initialization

**Current Test Output** (iPod Video firmware):
```
MMAP disabled - crt0 will configure it
PROC_ID_READ: addr=0x60000000 returning 0x55
PROC_ID_CHECK: R0=0x00000055 (0x55=CPU, 0xAA=COP)
PROC_ID_BRANCH: Taking CPU path
...
COP_POLL_LOOP: Skipping to 0x10000154
...
INIT_COPY_DONE: R2=0x03E91BA8 >= R3=0x03E91BA8
...
MMAP EXEC: cycle=1095900 PC=0x000002D0 -> 0x100002D0 R2=0x... SP=0x...
(stuck in MMAP execution loop)
```

**Commit**: feat: LCD bypass fallback and iPod Video firmware support

---

### 2026-01-14: CPU_CTL Auto-Wake Fix for RTOS Scheduler

**Goal**: Fix scheduler blocking on CPU sleep/wake synchronization

**Problem**:
The RTOS scheduler was blocking because `core_thread_init()` calls `sleep_core(CPU)` which writes 0x80000000 to CPU_CTL (0x60007000). On real hardware, the COP would wake the CPU by writing 0 to CPU_CTL. Since we don't emulate COP execution, the CPU was stuck forever waiting for a wake signal that never came.

**Root Cause Analysis** (from Rockbox source `firmware/target/arm/pp/system-target.h`):
```c
static inline void sleep_core(unsigned int core) {
    *(core ? &COP_CTL : &CPU_CTL) = PROC_SLEEP;  // Write 0x80000000
}

static inline void wake_core(unsigned int core) {
    *(core ? &COP_CTL : &CPU_CTL) = 0;  // Write 0x00000000
}
```

The scheduler flow in `firmware/target/arm/pp/thread-pp.c`:
```c
void core_thread_init(void) {
    // CPU wakes COP, then puts itself to sleep waiting for COP to wake it
    wake_core(COP);
    sleep_core(CPU);
    // ... continues after COP wakes CPU ...
}
```

**Solution**:
Added CPU_CTL auto-wake in `system_ctrl.zig`:

```zig
REG_CPU_CTL => {
    const PROC_SLEEP: u32 = 0x80000000;
    if ((value & PROC_SLEEP) != 0) {
        // CPU trying to sleep - immediately wake it (simulate COP writing 0)
        std.debug.print("CPU_CTL WRITE: value=0x{X:0>8} (SLEEP) -> auto-wake to 0\n", .{value});
        self.cpu_ctl = 0; // Auto-wake
    } else {
        self.cpu_ctl = value;
    }
},
```

**Results** (15-second test with bootloader + disk image):
- CPU_CTL auto-wake working: 298 scheduler iterations logged
- BSS clear loop completes successfully
- main() has correct value: 0xE92D4880
- INIT_COPY phase completes: R2=0x03E91BA8 >= R3=0x03E91BA8
- "Rockbox boot loa..." strings visible in SDRAM

**Remaining Issues**:
- No LCD output yet (LCD2 bridge not accessed)
- No ATA disk I/O yet (0xC3xxxxxx registers not accessed)
- May need more emulation cycles or additional initialization fixes

**Files Changed**:
- `src/emulator/peripherals/system_ctrl.zig`: Added CPU_CTL auto-wake logic

**Commit**: feat: CPU_CTL auto-wake for RTOS scheduler bypass

---

## Tools Used

- **radare2**: Disassembly and analysis
- **Ghidra**: Decompilation (optional)
- **Custom tracing**: Emulator instrumentation
- **arm-none-eabi-objdump**: Bootloader binary disassembly

## Methodology

1. Run emulator with cycle limit, capture final PC
2. Disassemble stuck address to understand loop
3. Identify peripheral accesses being polled
4. Determine expected values/conditions
5. Implement fix in emulator
6. Document findings
7. Commit and test
