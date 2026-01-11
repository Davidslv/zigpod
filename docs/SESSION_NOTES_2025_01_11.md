# ZigPod Development Session Notes - January 11, 2025

## Session Summary

**Goal**: Get storage (ATA) working on iPod Video 5th Gen hardware

**Major Achievement**: ATA read is NOW WORKING! We successfully read 512 bytes from the disk.

---

## Current State

### What's Working
| Component | Status | Notes |
|-----------|--------|-------|
| LCD Display | ✅ VERIFIED | BCM2722 working on hardware |
| Click Wheel | ✅ VERIFIED | All 5 buttons working |
| Menu UI | ✅ VERIFIED | Navigation with LEFT/RIGHT, SELECT enters screens |
| ATA Init | ✅ VERIFIED | Drive responds, ready signal received |
| ATA Read | ✅ VERIFIED | Successfully read 512 bytes from sector 0 |
| MBR Signature | ❌ ISSUE | Read data but signature bytes not matching 0x55AA |

### Debug Bar Results (Screenshot Captured)
When running storage test, we see these colored bars:

| Y Position | Color Seen | Meaning | Status |
|------------|------------|---------|--------|
| 50 | White | Test started | ✅ |
| 70 | Yellow | Waiting for ready | ✅ |
| 90 | Green | ATA Ready OK | ✅ |
| 110 | Cyan | Command sent | ✅ |
| 130 | Magenta | Waiting for DRQ | ✅ |
| 150 | Blue | DRQ OK (data ready) | ✅ |
| 170 | Purple | Read complete | ✅ |
| 190 | Reddish | Byte 510 value | ❓ Not 0x55 |
| 200 | (not seen yet) | Byte 511 value | ❓ |
| 210 | White | Test function done | ✅ |

---

## Key Findings

### 1. ATA Register Addresses (Rockbox Verified)
**CRITICAL**: PP5020/PP5022 uses 4-byte aligned registers, NOT 1-byte offsets!

```zig
const IDE_BASE: u32 = 0xC3000000;
const ATA_DATA: u32 = IDE_BASE + 0x1E0;     // 0xC30001E0
const ATA_ERROR: u32 = IDE_BASE + 0x1E4;    // 0xC30001E4
const ATA_NSECTOR: u32 = IDE_BASE + 0x1E8;  // 0xC30001E8
const ATA_SECTOR: u32 = IDE_BASE + 0x1EC;   // 0xC30001EC (LBA 0-7)
const ATA_LCYL: u32 = IDE_BASE + 0x1F0;     // 0xC30001F0 (LBA 8-15)
const ATA_HCYL: u32 = IDE_BASE + 0x1F4;     // 0xC30001F4 (LBA 16-23)
const ATA_SELECT: u32 = IDE_BASE + 0x1F8;   // 0xC30001F8
const ATA_COMMAND: u32 = IDE_BASE + 0x1FC;  // 0xC30001FC
const ATA_CONTROL: u32 = IDE_BASE + 0x3F8;  // 0xC30003F8
```

### 2. Device Enable Bits (DEV_EN at 0x6000600C)
```zig
const DEV_ATA: u32 = 0x00004000;   // ATA controller clock
const DEV_IDE0: u32 = 0x02000000;  // IDE0 interface enable
```

**Previous bug**: Had DEV_ATA as 0x00000004 (wrong! that's DEV_SYSTEM)

### 3. IDE Power Enable Sequence (iPod Video Specific)
From Rockbox `power-ipod.c`:

```zig
// Step 1: Enable IDE power via GPO32
GPO32_VAL &= ~0x40000000;  // Clear bit 30 = power ON

// Step 2: Wait ~10ms for power stabilization
sleep(10ms);

// Step 3: Enable IDE0 device
DEV_EN |= DEV_IDE0;

// Step 4: Configure GPIO ports for IDE function
GPIOG_ENABLE = 0;           // 0x6000D088
GPIOH_ENABLE = 0;           // 0x6000D08C
GPIOI_ENABLE &= ~0xBF;      // 0x6000D100
GPIOK_ENABLE &= ~0x1F;      // 0x6000D108
```

### 4. ATA Initialization Sequence (from Rockbox)
```zig
// ata_device_init() from ata-pp5020.c
IDE0_CFG |= 0x20;              // Enable bit 5
IDE0_CFG &= ~0x10000000;       // Clear bit 28 (iPod Video is < 65MHz)
IDE0_PRI_TIMING0 = 0xC293;     // PIO mode 0 timing
IDE0_PRI_TIMING1 = 0x80002150; // Standard timing

// perform_soft_reset() from ata.c
ATA_SELECT = 0x40;             // SELECT_LBA | device 0
ATA_CONTROL = 0x06;            // SRST + nIEN
wait(5us);
ATA_CONTROL = 0x02;            // Clear SRST, keep nIEN
wait(2ms);
```

---

## Files Modified This Session

1. **`src/kernel/minimal_boot.zig`** - Main firmware with:
   - Corrected ATA register addresses (4-byte aligned)
   - Corrected DEV_ATA bit (0x00004000)
   - Added DEV_IDE0 enable
   - Added GPIO configuration for IDE
   - Added debug bar visualization
   - Storage test function with visual feedback

2. **`src/hal/pp5021c/registers.zig`** - Fixed ATA register definitions

3. **`docs/hardware/PP5020_COMPLETE_REFERENCE.md`** - Updated with correct ATA addresses

---

## Next Steps (When Resuming)

### Immediate: Debug the MBR signature issue
The last firmware shows byte values at positions 510, 511, and 0. Need to:

1. **Flash latest build** and observe the three debug bars at y=190, y=200, y=220
2. **Analyze colors**:
   - If all black (0x00) = not reading real data
   - If all bright = reading 0xFF (error condition)
   - If varied colors = reading real data, just not MBR

3. **Possible issues to investigate**:
   - Byte order swap in 16-bit reads
   - Reading wrong sector (firmware partition instead of sector 0)
   - iPod disk layout specifics

### After Storage Works
1. Read FAT32 boot sector
2. Parse directory entries
3. List files on screen
4. Load and parse audio files

---

## Build & Flash Commands

```bash
# Build firmware
zig build firmware

# Flash to iPod (in Disk Mode: Menu+Select → Select+Play)
diskutil list | grep -i ipod
diskutil unmountDisk /dev/diskX
sudo ./tools/ipodpatcher-build/ipodpatcher-arm64 /dev/diskX -ab zig-out/bin/zigpod.bin
diskutil eject /dev/diskX
# Reset iPod: Menu+Select
```

---

## Test Procedure

1. Boot iPod with ZigPod firmware
2. Menu appears with 4 items
3. Press RIGHT to select item 1 (second item)
4. Press SELECT or PLAY to run storage test
5. Observe debug bars
6. Press MENU to return to main menu

---

## Rockbox Source Reference

Local copy at: `/Users/davidslv/projects/rockbox`

Key files:
- `firmware/export/pp5020.h` - Register definitions
- `firmware/target/arm/pp/ata-pp5020.c` - ATA device init
- `firmware/target/arm/pp/ata-target.h` - ATA register addresses
- `firmware/target/arm/ipod/power-ipod.c` - IDE power control
- `firmware/drivers/ata.c` - ATA driver (soft reset, read/write)
- `bootloader/ipod.c` - Bootloader init sequence

---

## Session Timestamp
- Date: January 11, 2025
- Last build: `zig-out/bin/zigpod.bin` (1868 bytes)
- Git status: Changes uncommitted
