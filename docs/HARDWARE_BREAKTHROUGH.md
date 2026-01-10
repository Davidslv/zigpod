# ZigPod Hardware Breakthrough - January 2026

## Executive Summary

After multiple failed attempts, ZigPod successfully runs on real iPod Video hardware. This document captures the debugging journey, root causes of failures, and the working solution.

**Final Result:** Working display output with UI mockup on iPod Video 5th Generation.

---

## Timeline of Hardware Tests

### Test 1: Full Bootloader + Firmware (Failed)
- **Approach:** Separate bootloader and firmware binaries
- **Result:** Black screen, recovery mode
- **Root Cause:** Complex two-stage boot, HAL abstraction issues

### Test 2: Single Binary Approach (Failed)
- **Approach:** Combined bootloader + firmware in one binary
- **Result:** Recovery mode ("Connect to iTunes")
- **Root Cause:** Re-initializing hardware Apple already set up

### Test 3: Minimal Test Binary (Success!)
- **Approach:** 12-byte infinite loop to test if code executes
- **Result:** Black screen (not recovery) - code IS running!
- **Key Discovery:** Apple bootloader initializes LCD, our code executes

### Test 4: BCM Drawing Test (Failed Initially)
- **Approach:** Write red pixels to BCM framebuffer
- **Result:** Apple logo still visible, no red screen
- **Root Cause:** Wrong LCD update command value

### Test 5: BCM Command Fix (Success!)
- **Approach:** Fixed BCMCMD_LCD_UPDATE from 0x34F to 0xFFFF0000
- **Result:** RED SCREEN! First successful display output!
- **Key Discovery:** BCM_CMD(x) macro = `(~x << 16) | x`

### Test 6: Full Firmware with BCM Fix (Failed)
- **Approach:** Use fixed BCM code in boot.zig
- **Result:** Recovery mode
- **Root Cause:** ARMv6+ instructions in boot.zig

### Test 7: ARM7TDMI Instruction Fix (Failed)
- **Approach:** Replace `cpsid if` with `msr cpsr_c, #0xdf`
- **Result:** Still recovery mode
- **Root Cause:** boot.zig module imports causing issues

### Test 8: Use minimal_boot.zig for Firmware (Success!)
- **Approach:** Build firmware using minimal_boot.zig directly
- **Result:** Working UI mockup on real hardware!

---

## Root Causes Identified

### 1. Wrong BCM LCD Update Command

**Problem:**
```zig
// WRONG - causes no display update
const BCMCMD_LCD_UPDATE: u32 = 0x34F;
```

**Solution:**
```zig
// CORRECT - BCM_CMD(0) = (~0 << 16) | 0 = 0xFFFF0000
const BCMCMD_LCD_UPDATE: u32 = 0xFFFF0000;
```

The BCM2722 uses a command encoding where the command value is duplicated:
- Upper 16 bits: bitwise NOT of command
- Lower 16 bits: command value

### 2. ARMv6+ Instructions on ARM7TDMI

**Problem:**
```zig
// WRONG - cpsid is ARMv6+ only, crashes on ARM7TDMI
asm volatile ("cpsid if");
```

**Solution:**
```zig
// CORRECT - ARM7TDMI compatible
asm volatile ("msr cpsr_c, #0xdf");
```

The iPod Video uses ARM7TDMI cores (ARMv4T architecture). Instructions like `cpsid`, `cpsie`, `wfi`, `wfe` don't exist and cause undefined instruction exceptions.

### 3. Re-initializing Apple-Initialized Hardware

**Problem:**
The original boot sequence called:
- `clock.init()` - Reconfigures PLL
- `sdram.init()` - Reconfigures SDRAM controller
- `cache.init()` - Reconfigures cache
- `pp5021c_init.enableDevices()` - Resets peripherals

**Solution:**
Skip all re-initialization. Apple's bootloader already:
- Set up 80MHz PLL
- Initialized SDRAM
- Configured cache
- Powered on BCM2722 and displayed Apple logo
- Initialized all required peripherals

### 4. Module Import Side Effects

**Problem:**
boot.zig imports many modules:
```zig
const hal = @import("../hal/hal.zig");
const clock = @import("clock.zig");
const sdram = @import("sdram.zig");
// etc.
```

These imports pull in code that may contain:
- ARMv6+ assembly instructions
- Global initializers
- Comptime code that generates problematic output

**Solution:**
Use self-contained minimal_boot.zig with no external imports except `builtin`.

### 5. Linker Script Differences

**Problem:**
single_binary.ld has complex section layout that may cause issues.

**Solution:**
Use minimal.ld with simple layout:
```
MEMORY {
    IRAM (rwx) : ORIGIN = 0x10000000, LENGTH = 96K
    SDRAM (rwx) : ORIGIN = 0x40000000, LENGTH = 32M
}
```

---

## Working Configuration

### Build Command
```bash
zig build firmware
```

### Build Configuration (build.zig)
```zig
const firmware = b.addExecutable(.{
    .name = "zigpod",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/minimal_boot.zig"),
        .target = arm_target,
        .optimize = .ReleaseSmall,
    }),
});
firmware.setLinkerScript(b.path("linker/minimal.ld"));
```

### Installation
```bash
# Put iPod in disk mode (Menu + Select, then Select + Play)
diskutil unmountDisk /dev/diskN
sudo ./tools/ipodpatcher-build/ipodpatcher-arm64 /dev/diskN -ab zig-out/bin/zigpod.bin
diskutil eject /dev/diskN
```

### Working Entry Point (minimal_boot.zig)
```zig
fn _start() callconv(.naked) noreturn {
    // ARM7TDMI-compatible interrupt disable
    asm volatile ("msr cpsr_c, #0xdf");

    // Hardcoded stack in SDRAM
    asm volatile ("ldr sp, =0x40008000");

    // Jump to main
    asm volatile ("bl _zigpod_main");

    // Infinite loop fallback
    asm volatile ("1: b 1b");
}
```

### Working BCM Access
```zig
const BCM_DATA32: *volatile u32 = @ptrFromInt(0x30000000);
const BCM_WR_ADDR32: *volatile u32 = @ptrFromInt(0x30010000);
const BCM_CONTROL: *volatile u16 = @ptrFromInt(0x30030000);

const BCMA_CMDPARAM: u32 = 0xE0000;
const BCMA_COMMAND: u32 = 0x1F8;
const BCMCMD_LCD_UPDATE: u32 = 0xFFFF0000;

fn bcmWriteAddr(addr: u32) void {
    BCM_WR_ADDR32.* = addr;
    while ((BCM_CONTROL.* & 0x2) == 0) {
        asm volatile ("nop");
    }
}

fn fillScreen(color: u32) void {
    bcmWriteAddr(BCMA_CMDPARAM);
    var i: u32 = 0;
    while (i < 320 * 240 / 2) : (i += 1) {
        BCM_DATA32.* = color;  // Two pixels per write
    }
    bcmWriteAddr(BCMA_COMMAND);
    BCM_DATA32.* = BCMCMD_LCD_UPDATE;
    BCM_CONTROL.* = 0x31;
}
```

---

## Key Learnings

### 1. Apple Bootloader Does Heavy Lifting
The Apple bootloader initializes almost everything before loading our code:
- PLL/clocks at 80MHz
- SDRAM controller
- Cache
- BCM2722 LCD controller (displays Apple logo)
- GPIO configuration

**Implication:** Don't re-initialize - just use what's already set up.

### 2. ARM7TDMI Limitations
The PP5021C uses ARM7TDMI cores (ARMv4T). Many "modern" ARM instructions don't exist:
- No `cpsid`/`cpsie` (use `msr cpsr_c`)
- No `wfi`/`wfe` (use spin loops)
- No Thumb-2 extensions
- No NEON/VFP

### 3. BCM2722 Command Encoding
Commands use inverted upper bits for error detection:
```
BCM_CMD(x) = (~x << 16) | x
```

### 4. Incremental Testing is Essential
Each hardware test should change ONE thing. The breakthrough came from:
1. Testing if code runs at all (infinite loop)
2. Testing if we can see anything (backlight)
3. Testing if BCM responds (Apple logo visible)
4. Testing pixel writes with correct command

### 5. Keep It Simple
The working solution is ~160 lines of self-contained Zig code with:
- No external module imports
- No complex initialization
- Direct hardware register access
- Hardcoded addresses

---

## Memory Map (Confirmed Working)

| Address | Size | Description |
|---------|------|-------------|
| 0x10000000 | 96KB | IRAM - Where Apple loads our code |
| 0x30000000 | - | BCM2722 data register |
| 0x30010000 | - | BCM2722 write address register |
| 0x30030000 | - | BCM2722 control register |
| 0x40000000 | 32MB | SDRAM - Stack and data |

---

## Next Steps

1. **Add Click Wheel Input** - Read GPIO for wheel rotation and button presses
2. **Menu Navigation** - Make UI interactive
3. **Integrate Audio** - Add I2S/DAC support incrementally
4. **File System** - Add ATA/FAT32 support
5. **Fix boot.zig** - Audit all imports for ARMv6+ instructions

---

## Files Modified

| File | Changes |
|------|---------|
| `src/kernel/minimal_boot.zig` | Self-contained working boot + UI |
| `linker/minimal.ld` | Simple linker script with IRAM + SDRAM |
| `build.zig` | Use minimal_boot.zig for firmware build |
| `src/drivers/display/bcm.zig` | Fixed BCMCMD_LCD_UPDATE value |
| `src/kernel/boot.zig` | Added inline BCM code, fixed ARM7TDMI asm |

---

## Recovery Procedure

If the iPod shows "Connect to iTunes to restore":
1. The iPod is NOT bricked - just in recovery mode
2. Connect USB and put in disk mode (Menu + Select, then Select + Play immediately)
3. The Apple firmware partition is intact
4. Just flash a fixed binary with ipodpatcher

---

## Conclusion

After 8 hardware tests, ZigPod runs on real iPod Video hardware. The key breakthroughs were:
1. Discovering BCM_CMD encoding (0xFFFF0000, not 0x34F)
2. Using ARM7TDMI-compatible assembly
3. Not re-initializing Apple-configured hardware
4. Using self-contained code without problematic imports

The foundation is now solid for building a complete music player OS.
