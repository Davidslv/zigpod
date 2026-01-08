# Hardware Deployment Plan

## Overview

This document outlines the safe, methodical approach for deploying ZigPod to real iPod Classic hardware. The primary principle is **never risk bricking the device** - we progress through validation stages, each providing confidence before the next.

## Pre-Connection Checklist

Before connecting any iPod Classic:

### Required Tools
- [ ] USB cable (30-pin dock connector)
- [ ] macOS with iTunes installed (for recovery if needed)
- [ ] Disk imaging software (`dd`, `diskutil`)
- [ ] Hex editor for firmware analysis
- [ ] Serial/JTAG adapter (optional but recommended)

### Required Software State
- [ ] All ZigPod tests passing
- [ ] Simulator boot sequence verified
- [ ] Linker script validated for PP5021C memory map
- [ ] Binary size within flash constraints

---

## Phase 1: Read-Only Reconnaissance (Day 1)

**Goal**: Understand the specific device without modifying anything.

### Step 1.1: Enter Disk Mode
```
Hold MENU + SELECT for 6 seconds (reset)
Immediately hold SELECT + PLAY until Disk Mode appears
```

### Step 1.2: Identify Device
```bash
# macOS
diskutil list
# Look for Apple_HFS or Windows_FAT32 partitions

# Get device identifier (e.g., /dev/disk4)
IPOD_DISK=/dev/disk4
```

### Step 1.3: Create Full Disk Backup
```bash
# CRITICAL: Full bit-for-bit backup before ANY other operation
sudo dd if=$IPOD_DISK of=ipod_backup_$(date +%Y%m%d).img bs=1m status=progress

# Verify backup integrity
md5 ipod_backup_*.img > backup_checksum.md5
```

### Step 1.4: Analyze Partition Layout
```bash
# Read MBR
sudo dd if=$IPOD_DISK of=mbr.bin bs=512 count=1
hexdump -C mbr.bin

# Expected layout:
# Partition 1: Firmware (~128MB, type 0x00 or Apple-specific)
# Partition 2: FAT32 data (rest of disk)
```

### Step 1.5: Extract Firmware Partition
```bash
# Get firmware partition offset from MBR analysis
FIRMWARE_START=63        # LBA start (example)
FIRMWARE_SIZE=262144     # sectors (example)

sudo dd if=$IPOD_DISK of=firmware_partition.bin \
    bs=512 skip=$FIRMWARE_START count=$FIRMWARE_SIZE
```

### Step 1.6: Document Device Specifics
Create `device_profile.json`:
```json
{
  "model": "iPod Classic 6th Gen",
  "capacity": "80GB",
  "firmware_version": "1.1.2",
  "disk_device": "/dev/disk4",
  "partition_table": "MBR",
  "firmware_partition": {
    "start_lba": 63,
    "size_sectors": 262144,
    "type": "0x00"
  },
  "data_partition": {
    "start_lba": 262207,
    "filesystem": "FAT32"
  },
  "backup_file": "ipod_backup_20240115.img",
  "backup_checksum": "abc123..."
}
```

### Validation Checkpoint 1
- [ ] Full disk backup created and verified
- [ ] MBR parsed and matches expected layout
- [ ] Firmware partition extracted
- [ ] Device can still boot normally after Disk Mode exit

---

## Phase 2: Firmware Analysis (Day 2-3)

**Goal**: Understand the existing firmware structure.

### Step 2.1: Analyze Firmware Header
```bash
# Apple firmware has specific header structure
hexdump -C firmware_partition.bin | head -100

# Look for:
# - Magic bytes
# - Entry point address
# - Load address
# - Checksum locations
```

### Step 2.2: Identify Boot Stages
The iPod Classic boot process:
1. **Boot ROM** (0x00000000) - Cannot be modified, loads from flash
2. **Bootloader** (flash) - Loads main firmware
3. **Main Firmware** (flash) - The OS we want to replace

### Step 2.3: Create Firmware Map
```
Offset      Size        Content
0x0000      0x200       Firmware header
0x0200      0x10000     Bootloader (DO NOT TOUCH)
0x10200     0x1F0000    Main firmware image
...
```

### Step 2.4: Verify ZigPod Binary Compatibility
```bash
# Build ZigPod for hardware
zig build -Dtarget=arm-freestanding-none -Doptimize=ReleaseSmall

# Check binary properties
arm-none-eabi-objdump -h zig-out/bin/zigpod.elf
arm-none-eabi-size zig-out/bin/zigpod.elf

# Verify:
# - Entry point matches expected load address
# - .text section fits in available space
# - .data and .bss fit in SDRAM
```

### Validation Checkpoint 2
- [ ] Firmware structure documented
- [ ] Boot stages identified
- [ ] ZigPod binary size acceptable
- [ ] Load addresses verified

---

## Phase 3: Simulator Validation (Day 4-5)

**Goal**: Ensure ZigPod works perfectly in simulation before hardware.

### Step 3.1: Boot Sequence Test
```bash
# Run full boot sequence in simulator
zig build run-simulator -- --trace-boot

# Verify all init stages complete:
# [BOOT] BSS cleared
# [BOOT] Clock: PLL locked at 80MHz
# [BOOT] SDRAM: 64MB detected
# [BOOT] Cache: I-cache and D-cache enabled
# [BOOT] HAL initialized
# [BOOT] Entering main
```

### Step 3.2: Load Real Firmware in Simulator
```bash
# Use extracted firmware as disk image
zig build run-simulator -- --disk firmware_partition.bin --analyze
```

### Step 3.3: Memory Map Verification
```bash
# Verify our linker script matches reality
zig build run-simulator -- --dump-memory-map

# Expected output:
# 0x00000000-0x00100000: IRAM (1MB)
# 0x40000000-0x44000000: SDRAM (64MB)
# 0x60000000-0x70000000: Peripherals
```

### Validation Checkpoint 3
- [ ] Simulator completes full boot
- [ ] Memory map matches hardware
- [ ] All peripheral simulations pass
- [ ] Can load and parse real firmware

---

## Phase 4: RAM-Only Testing (Day 6-7)

**Goal**: Execute ZigPod in RAM without modifying flash.

### Option A: Via Rockbox Bootloader (Safest)
If Rockbox bootloader is installed:
```bash
# Rockbox can load custom firmware from disk
# Place zigpod.bin in root of iPod data partition
cp zig-out/bin/zigpod.bin /Volumes/IPOD/zigpod.bin

# Create Rockbox config to load it
echo "zigpod.bin" > /Volumes/IPOD/.rockbox/load_firmware
```

### Option B: Via JTAG (Most Control)
```bash
# Connect JTAG adapter to dock connector
# (Requires custom cable or breakout board)

# Using OpenOCD
openocd -f interface/ftdi/ft2232h.cfg -f target/arm7tdmi.cfg

# In another terminal
telnet localhost 4444

> halt
> load_image zigpod.bin 0x40000000
> reg pc 0x40000000
> resume
```

### Option C: Via USB DFU (If Available)
Some iPod models support DFU mode for RAM loading.

### Step 4.1: Prepare Test Binary
```bash
# Build minimal test binary
zig build -Dtarget=arm-freestanding-none -Dtest-mode=ram-only

# This builds a version that:
# - Runs entirely from RAM
# - Outputs debug via GPIO/serial
# - Has visible LCD test pattern
```

### Step 4.2: Execute and Monitor
```bash
# If using JTAG, monitor execution
> mdw 0x60006000 4  # Read clock registers
> mdw 0x70008A00 4  # Read LCD status
```

### Step 4.3: LCD Test Pattern
The first RAM test should display a simple pattern:
- White screen = LCD controller working
- Color bars = Pixel format correct
- Text = Font rendering working

### Validation Checkpoint 4
- [ ] ZigPod executes from RAM
- [ ] LCD displays test pattern
- [ ] Clock initialization verified (timing correct)
- [ ] Device remains recoverable

---

## Phase 5: Persistent Installation (Day 8+)

**Goal**: Install ZigPod to flash, with full recovery capability.

### CRITICAL PRE-REQUISITES
Before ANY flash write:
1. Verified full disk backup exists and is readable
2. Recovery procedure tested (restore from backup)
3. RAM testing phase completed successfully
4. At least one "sacrificial" device if possible

### Step 5.1: Prepare Firmware Image
```bash
# Build release firmware
zig build -Dtarget=arm-freestanding-none -Doptimize=ReleaseSmall

# Create firmware image with correct header
python3 tools/make_firmware.py \
    --input zig-out/bin/zigpod.bin \
    --output zigpod_firmware.img \
    --load-address 0x40000000 \
    --entry-point 0x40000000
```

### Step 5.2: Dual-Boot Setup (Recommended)
Instead of replacing Apple firmware, install alongside:
```bash
# Modify bootloader to offer choice
# Hold MENU at boot = Original firmware
# Normal boot = ZigPod
```

### Step 5.3: Flash Installation
```bash
# ONLY after all validations pass
# Enter Disk Mode
# Write firmware to correct partition offset

sudo dd if=zigpod_firmware.img of=$IPOD_DISK \
    bs=512 seek=$FIRMWARE_START \
    conv=notrunc status=progress

# Sync and verify
sync
sudo dd if=$IPOD_DISK of=verify.bin bs=512 skip=$FIRMWARE_START count=$SIZE
diff zigpod_firmware.img verify.bin
```

### Step 5.4: First Boot
```bash
# Exit Disk Mode
# Device should boot into ZigPod
# If black screen for >30 seconds, enter Disk Mode and restore
```

---

## Recovery Procedures

### Recovery Level 1: Disk Mode Still Works
```bash
# Device boots to Disk Mode = flash is readable
# Simply restore from backup
sudo dd if=ipod_backup_*.img of=$IPOD_DISK bs=1m status=progress
```

### Recovery Level 2: Disk Mode Fails, DFU Works
```bash
# Hold SELECT + PLAY for 10+ seconds
# Connect to iTunes
# iTunes will offer restore
```

### Recovery Level 3: DFU Fails
```bash
# JTAG recovery required
# Connect JTAG adapter
# Use OpenOCD to reflash bootloader
openocd -f ipod_recovery.cfg
> flash write_image erase bootloader_backup.bin 0x00000000
```

### Recovery Level 4: Total Brick
- Device shows no signs of life
- Likely hardware damage or corrupted boot ROM (rare)
- Boot ROM cannot be reflashed
- Device may be unrecoverable

---

## Feedback Loop Strategy

### Short Feedback Loops

1. **Compile Check** (seconds)
   ```bash
   zig build --target=arm-freestanding-none
   ```

2. **Simulator Test** (seconds)
   ```bash
   zig build run-simulator -- --quick-boot
   ```

3. **RAM Load Test** (minutes)
   - Via JTAG or Rockbox loader
   - No flash modification
   - Instant iteration

4. **Integration Test** (minutes)
   - Full simulator with disk image
   - Tests all subsystems

5. **Hardware Test** (only when needed)
   - Flash update
   - Requires recovery readiness

### Debug Output Methods

1. **LCD Debug**: Display status on screen
2. **Audio Debug**: Beep codes for boot stages
3. **GPIO Debug**: Toggle GPIO pins for logic analyzer
4. **Serial Debug**: Via dock connector if wired
5. **JTAG Debug**: Full debugging capability

### Recommended Development Workflow
```
Code Change
    │
    ▼
[Compile] ──fail──> Fix
    │
    pass
    ▼
[Unit Tests] ──fail──> Fix
    │
    pass
    ▼
[Simulator Boot] ──fail──> Fix
    │
    pass
    ▼
[Integration Tests] ──fail──> Fix
    │
    pass
    ▼
[RAM Load on Device] ──fail──> Fix
    │
    pass
    ▼
[Flash Install] ──fail──> Restore & Fix
    │
    pass
    ▼
Success!
```

---

## Troubleshooting Guide

### Symptom: Black Screen After Flash
1. Wait 30 seconds (init may be slow)
2. Try reset (MENU + SELECT)
3. Enter Disk Mode
4. Check firmware was written correctly
5. Restore from backup

### Symptom: Boot Loop
1. Clock initialization likely failed
2. Enter Disk Mode
3. Check PLL configuration
4. Restore and fix clock.zig

### Symptom: Garbled Display
1. LCD controller timing wrong
2. Pixel format mismatch
3. Check lcd.zig configuration

### Symptom: No Audio
1. Check I2S clock configuration
2. Verify WM8758 initialization
3. Check audio routing in PMU

### Symptom: Disk Not Mounting
1. ATA initialization failed
2. FAT32 parsing error
3. Check ata.zig and fat32.zig

---

## Success Criteria

### Minimum Viable Boot
- [ ] LCD shows ZigPod logo
- [ ] Click wheel responds
- [ ] Can navigate basic menu
- [ ] Can play audio file
- [ ] Device remains stable for 10 minutes

### Full Validation
- [ ] All boot stages complete
- [ ] LCD displays correctly
- [ ] Click wheel fully functional
- [ ] Audio plays at correct sample rate
- [ ] Battery status reads correctly
- [ ] Sleep/wake works
- [ ] USB connection works
- [ ] No memory leaks over 1 hour

---

## Timeline Summary

| Day | Phase | Risk Level | Reversible |
|-----|-------|------------|------------|
| 1 | Read-only reconnaissance | None | Yes |
| 2-3 | Firmware analysis | None | Yes |
| 4-5 | Simulator validation | None | Yes |
| 6-7 | RAM-only testing | Low | Yes |
| 8+ | Persistent installation | Medium | Usually |

---

## Emergency Contacts & Resources

- **Rockbox Wiki**: https://www.rockbox.org/wiki/IpodClassic
- **iFixit Guides**: Device disassembly if needed
- **Apple Support**: iTunes restore
- **ZigPod Issues**: Document any problems for future reference
