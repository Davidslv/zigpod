# ZigPod Black Screen Postmortem

## Date: 2026-01-10

## Summary
Two hardware tests resulted in black screen. iPod did not display anything after ZigPod bootloader was installed.

---

## Hardware Test #2: 2026-01-10 (Second Attempt)

### What We Did
After the first failure, we researched Rockbox source code and discovered:
1. iPod Video uses BCM2722 Broadcom graphics chip (not a simple LCD controller)
2. BCM requires 3-stage bootstrap and firmware upload from ROM
3. PP5021C needs specific device enable sequence

We implemented:
- `src/drivers/display/bcm.zig` - Full BCM2722 driver with bootstrap sequence
- `src/kernel/pp5021c_init.zig` - PP5021C hardware initialization
- Updated HAL to use BCM driver for LCD operations

### Result: Black Screen Again

### Why It Still Failed

The BCM driver fix was **correct but insufficient**. The fundamental architecture problem remained:

```
Apple ROM → Apple Bootloader → ZigPod Bootloader → tries to load firmware → NOTHING THERE
                                      ↓
                              BCM init code exists in firmware.bin
                              but firmware.bin is on disk, not in RAM!
```

**The bootloader itself never runs the BCM initialization code** because:
1. Bootloader is tiny (664 bytes) - just tries to jump to firmware
2. Firmware (31KB with BCM driver) sits on HFS+ filesystem
3. Bootloader has no code to read from filesystem
4. Bootloader tries to read from RAM address 0x40100000
5. Nothing is there → crash → black screen

### Key Insight

We fixed the wrong layer. The BCM driver in `firmware.bin` is correct, but:
- `firmware.bin` never gets loaded
- `bootloader.bin` doesn't contain BCM init
- `bootloader.bin` can't read `firmware.bin` from disk

### Solution: Single Binary Approach

Instead of:
```
bootloader.bin (664B) + firmware.bin (31KB on disk)
```

We need:
```
zigpod.bin (single binary with everything)
```

The single binary:
1. Gets appended to Apple firmware by ipodpatcher
2. Apple bootloader loads it directly to RAM
3. Contains PP5021C init + BCM init + full ZigPod OS
4. No filesystem access needed for boot

---

---

## Root Cause Analysis

### Primary Issue: Bootloader Architecture Mismatch

The ZigPod bootloader was designed with assumptions that don't match how ipodpatcher works.

#### How ipodpatcher Works
```
Boot ROM → Apple Bootloader → [Appended Rockbox/Custom Bootloader] → Firmware
```

ipodpatcher **appends** our bootloader binary to the end of the Apple bootloader in the firmware partition. The Apple bootloader then chain-loads it.

#### What ZigPod Bootloader Expects
```zig
// bootloader.zig expects:
pub const ZIGPOD_FW_ADDR: u32 = 0x40100000;  // Firmware pre-loaded here
pub const ORIG_FW_ADDR: u32 = 0x40010000;    // Apple firmware here

fn bootZigPod() noreturn {
    const header: *const FirmwareHeader = @ptrFromInt(ZIGPOD_FW_ADDR);
    // Tries to read firmware header from RAM address
    // But firmware is on filesystem, not in RAM!
}
```

**The bootloader never loads firmware from the filesystem!**

It expects:
1. Firmware already in RAM at `0x40100000`
2. A `FirmwareHeader` struct at that address with magic bytes `ZPOD`
3. Apple firmware at `0x40010000`

But in reality:
1. Firmware is on HFS filesystem at `/.zigpod/firmware.bin`
2. Nothing is at those RAM addresses
3. Apple firmware is in the firmware partition, not at that RAM address

---

### Secondary Issues

#### 1. No LCD Initialization in Bootloader
The bootloader doesn't initialize the LCD controller. It relies on `hal.current_hal` which may not be initialized.

```zig
// No direct LCD init in bootloader
// Just uses hal abstraction that may not work on real hardware
```

#### 2. No Filesystem Access
The bootloader has no code to:
- Initialize ATA/storage
- Parse the Apple partition map
- Mount HFS+ filesystem
- Read `.zigpod/firmware.bin`

#### 3. Hardware-Specific Init Missing
```zig
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ldr sp, =__stack_top
        \\b _bootloader_main
    );
}
```

Missing:
- Clock initialization (PP5021C needs PLL setup)
- Memory controller init
- GPIO configuration
- Interrupt controller setup

#### 4. Linker Script May Be Wrong
```
// bootloader.ld places code at IRAM 0x10000000
// But ipodpatcher may load at different address
```

---

## What Actually Happened

1. iPod powered on
2. Boot ROM loaded firmware partition
3. Apple bootloader ran
4. Apple bootloader jumped to appended ZigPod bootloader
5. ZigPod bootloader executed `_start()`
6. Stack was set up (maybe - address may be wrong)
7. `_bootloader_main()` called `init()`
8. `init()` tried to use `hal.current_hal` functions
9. **CRASH** - HAL not initialized, invalid memory access, or infinite loop
10. Black screen (LCD never initialized)

---

## Lessons Learned

### 1. Rockbox is the Reference
We should have studied how Rockbox bootloader works first:
- It initializes hardware from scratch
- It has its own LCD driver (doesn't use HAL)
- It loads firmware from filesystem
- It's been tested on real iPods

### 2. Can't Use HAL in Bootloader
The HAL abstraction layer requires initialization. Bootloader must use direct hardware access.

### 3. Firmware Location
Options:
- **Rockbox style**: Load from filesystem (`.zigpod/firmware.bin`)
- **Embedded style**: Embed firmware in firmware partition
- **Simple style**: Just put all code in firmware partition, no separate bootloader

### 4. Need Hardware Init
Bare metal on PP5021C requires:
```c
// Minimum init sequence (from Rockbox)
void system_init(void) {
    // Disable interrupts
    // Set up clocks
    // Initialize memory controller
    // Configure GPIO
    // Initialize LCD controller
    // ...
}
```

---

## Recommended Fixes

### Option A: Fix the Bootloader (Complex)
1. Add direct hardware initialization (no HAL)
2. Add LCD driver in bootloader
3. Add FAT32/HFS filesystem reader
4. Load firmware from `.zigpod/firmware.bin`
5. Jump to loaded firmware

### Option B: Single Binary Approach (Simpler)
1. Skip separate bootloader entirely
2. Put all ZigPod code in firmware partition
3. Apple bootloader → ZigPod directly
4. Use ipodpatcher to install complete firmware

### Option C: Study Rockbox First (Recommended)
1. Get Rockbox booting on this iPod
2. Understand the hardware init sequence
3. Port the init code to Zig
4. Then build ZigPod bootloader

---

## Action Items

- [x] Study Rockbox bootloader source (`bootloader/ipod.c`)
- [x] Document PP5021C initialization sequence
- [x] Decide on bootloader architecture → **Single Binary Approach**
- [x] Add LCD init (BCM driver created)
- [ ] ~~Add filesystem loading capability~~ (Not needed with single binary)
- [x] Implement single binary firmware build
- [ ] Test single binary on hardware (Test #3)

---

## Files Involved

| File | Issue |
|------|-------|
| `src/kernel/bootloader.zig` | Missing hardware init, wrong firmware loading |
| `linker/bootloader.ld` | May have wrong load address |
| `src/hal/hal.zig` | Not usable in bootloader context |
| `src/drivers/display/lcd.zig` | Never called from bootloader |

---

## Recovery Procedure (Documented)

If ZigPod causes black screen:

1. **Hard Reset**: Hold Menu + Select (10 sec)
2. **Enter Disk Mode**: Hold Select + Play immediately after Apple logo
3. **Restore**:
   ```bash
   diskutil unmount /dev/disk10s3
   sudo dd if=/path/to/firmware_backup.img of=/dev/disk10s2 bs=1m
   diskutil eject /dev/disk10
   ```
4. **Reboot**: Hold Menu + Select

---

## References

- [Rockbox iPod Bootloader](https://git.rockbox.org/cgit/rockbox.git/tree/bootloader/ipod.c)
- [Rockbox PP5021C Init](https://git.rockbox.org/cgit/rockbox.git/tree/firmware/target/arm/pp/system-pp502x.c)
- [iPod Linux Wiki](http://www.ipodlinux.org/PP5021/)
