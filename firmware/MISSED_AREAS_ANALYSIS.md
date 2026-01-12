# ZigPod Emulator: Potentially Missed Areas Analysis

**Date:** January 12, 2026
**Analyst:** Claude (Opus 4.5)
**Purpose:** Deep reverse engineering review to identify gaps in emulator implementation

---

## 1. CRITICAL: Missing Mailbox/Queue Registers

**Status: NOT IMPLEMENTED**

The PP5020/PP5021C has inter-processor communication mailbox registers that are **missing** from the current emulator memory map.

### Missing Registers

| Address | Name | Description |
|---------|------|-------------|
| 0x60001010 | CPU_QUEUE | CPU sets bit 29, only COP read clears it |
| 0x60001020 | COP_QUEUE | COP sets bit 29, only CPU read clears it |

### Source Reference (Rockbox pp5020.h)
```c
#define CPU_QUEUE           (*(volatile unsigned long *)(0x60001010))
#define COP_QUEUE           (*(volatile unsigned long *)(0x60001020))
#define PROC_QUEUE(core)    ((&CPU_QUEUE)[(core)*4])
```

### Impact
- These registers are used for CPU/COP synchronization
- Apple firmware's dual-core RTOS relies on these for task scheduling
- Without these, Apple firmware **cannot boot** (COP crash likely)
- Rockbox bootloader doesn't use COP, so this doesn't affect Rockbox boot

### Recommendation
Add mailbox region to memory bus (0x60001000-0x60001FFF) with proper semantics:
- Writes set bits in queue
- Reads from **other** core clear bits
- Bit 29 has special wake-up signaling

---

## 2. Stub Peripherals Needing Implementation

### 2.1 Device Init Registers (0x70000000-0x7000007F)

**Status: STUB (returns 0)**

| Offset | Register | Description | Impact |
|--------|----------|-------------|--------|
| 0x00 | PP_VER1 | PP5020 version register 1 | Firmware may check version |
| 0x04 | PP_VER2 | PP5020 version register 2 | Firmware may check version |

The Apple firmware string `PP5020AF-05.00` suggests it reads version registers.

### 2.2 GPO32 (0x70000080-0x700000FF)

**Status: STUB**

General Purpose Output registers - used for various hardware control signals.

### 2.3 Cache Controller (0x6000C000-0x6000C0FF)

**Status: STUB**

Cache control may need proper timing behavior for Apple firmware, which uses caches extensively.

---

## 3. Boot ROM Considerations

### Current Implementation
- Boot ROM region: 0x00000000-0x0001FFFF (128KB)
- Returns 0 if boot_rom is empty/not provided
- Firmware typically loaded directly to SDRAM/IRAM, bypassing ROM

### Apple Firmware Boot Sequence
The Apple firmware expects to be loaded at 0x10000000 with:
1. Exception vectors at 0x10000800 (offset 0x800 from load address)
2. Entry point at 0x10000800 (Reset vector)
3. NOT at 0x10000000 (which is the load address)

### Boot ROM Content (if needed)
For full Apple firmware boot, the ROM would need to:
1. Initialize minimal hardware
2. Copy osos.bin to SDRAM at 0x10000000
3. Jump to 0x10000800

For direct SDRAM loading (current approach), ROM content is not needed.

---

## 4. Interrupt Controller Verification

### Current Implementation
The emulator has separate CPU/COP interrupt registers:
- 0x60004000: CPU_INT_STAT
- 0x60004004: COP_INT_STAT
- 0x60004020-0x6000402C: CPU interrupt enable/disable/priority
- 0x60004030-0x6000403C: COP interrupt enable/disable/priority

### Apple Firmware Usage
```arm
; From disassembly at 0x980 (IRQ handler)
mov r0, #0x60000000     ; Processor ID register base
ldr r0, [r0]            ; Read core ID
tst r0, #1              ; Test bit 0
bne <cop_irq_handler>   ; Branch if COP (0xAA has bit 0 set)
```

### Verification Status
The interrupt controller appears correctly implemented based on Rockbox headers. The dual-core interrupt routing (CPU_INT vs COP_INT) is present.

---

## 5. Clock/PLL Configuration

### Current Implementation (system_ctrl.zig)
```
REG_CLOCK_SOURCE: 0x20
REG_PLL_CONTROL: 0x34
REG_PLL_DIV: 0x38
REG_PLL_STATUS: 0x3C (returns 0x80000000 = locked)
```

### Apple Firmware References
- String at 0x1fa384: `core_freq_khz`
- String at 0x1fa950: `core frequnecy (kHz):` [sic]
- Default frequency: 80 MHz (24 MHz * mult / div)

### Recommendation
PLL should always report locked (bit 31 set). Current implementation is correct.

---

## 6. I2C Device Verification

### Implemented Devices
| Address | Device | Status |
|---------|--------|--------|
| 0x08 | PCF50605 (PMU) | Implemented |
| 0x1A | WM8758 (Codec) | Implemented |

### Apple Firmware References
- String at 0x102bb8: `Wolfson Active`
- String at 0x4fc850: `I2C write Error`
- String at 0x4fc864: `I2C read Error %02x`

### Verification
I2C addresses match Rockbox documentation. PCF50605 returns ID 0x35.

---

## 7. DMA Controller

### Current Implementation
- 4 DMA channels at 0x6000B000-0x6000B07F
- Master registers at 0x6000A000
- Per-channel: CMD, STATUS, RAM_ADDR, FLAGS, PER_ADDR, INCR, COUNT

### Note
DMA transfers complete **instantly** in current implementation. This is a simplification but should work for functionality testing. Apple firmware may have timing-sensitive DMA code.

---

## 8. LCD Controller

### Current Implementation
Two LCD interfaces:
1. BCM2722 at 0x30000000 (Apple's direct interface)
2. LCD2 Bridge at 0x70008A00 (Rockbox's interface)

### Apple Firmware Usage
The firmware has multiple LCD drivers:
- `13LcdDriverSpHw`
- `13LcdDriverVC02`
- `16iMADisplayDriver`
- `17DisplayDriverVC02`

Some of these may use VideoCore (BCM2722) directly, which is partially implemented.

---

## 9. Dual-Core (CPU/COP) Synchronization

### Current Implementation
- PROC_ID at 0x60000000: Returns 0x55 (CPU) or 0xAA (COP)
- CPU_CTL at 0x60007000: CPU sleep/wake control
- COP_CTL at 0x60007004: COP sleep/wake control (default: 0x80000200)

### Missing Components
1. **Mailbox registers** (0x60001010, 0x60001020) - See Section 1
2. **Hardware semaphores** - No evidence of separate semaphore registers

### Apple Firmware COP Error Handling
Found at 0xe682c: `COP has crashed - (0x%X)`
Found at 0x285fbd: `_watchdog: No registered handlers for COP event!`

This indicates Apple firmware has COP monitoring that will trigger if COP doesn't respond properly.

---

## 10. RTOS Task Structure

### Identified Tasks in Apple Firmware
The Apple firmware runs a complex RTOS with 25+ tasks:

**System Tasks:**
- HostOSTask, DiskMgrTask, ATAWorkLoopTask, ATAWorkLoopIRQTask
- BacklightTask, HoldSwitchTask, AlarmTask, EventManager

**Audio/Media:**
- USBAudioTask, MP3ExampleTask, AudioCodecs
- Channel AudioPrompt, Channel DiskReaderTask

**USB/Connectivity:**
- FirewireTask, USB Secondary Interrupt Task, Hub Driver
- CIapIncomingProcessThread, CIapOutgoingProcessThread

**Display:**
- 13LcdDriverSpHw, 13LcdDriverVC02, 16iMADisplayDriver
- 17DisplayDriverVC02, ArtworkLoadTask

### Implication
Apple firmware boot requires:
1. Working interrupt system for task scheduling
2. Timer interrupts for RTOS tick
3. DMA for disk I/O
4. LCD for UI rendering
5. COP synchronization for audio processing

---

## 11. Summary: Priority Fixes for Apple Firmware

### Critical (Blocking Apple Boot)
1. **Implement mailbox registers** at 0x60001000-0x60001FFF
2. **Set correct entry point** to 0x10000800 (not 0x10000000)

### Important (May Cause Issues)
3. Implement PP_VER1/PP_VER2 at device_init
4. Verify interrupt routing between CPU/COP

### Nice to Have
5. Proper DMA timing (currently instant)
6. Cache controller timing
7. Full VideoCore BCM2722 emulation

---

## 12. Summary: Rockbox Boot Status

The current emulator is well-suited for Rockbox bootloader, which:
- Uses single CPU only (no COP)
- Uses LCD2 Bridge (implemented)
- Uses ATA PIO mode (implemented)
- Uses FAT32 file system (emulator reads sectors correctly)

The **blocking issue** for Rockbox is the FAT32 buffer management bug in the bootloader itself (documented in INVESTIGATION_FINDINGS.md), not missing emulator functionality.

---

## 13. Files Referenced

| File | Purpose |
|------|---------|
| `src/emulator/memory/bus.zig` | Memory map implementation |
| `src/emulator/peripherals/system_ctrl.zig` | Clock/PLL, CPU/COP control |
| `src/emulator/peripherals/i2c.zig` | I2C with PCF50605 and WM8758 |
| `src/emulator/peripherals/dma.zig` | DMA controller |
| `src/emulator/peripherals/gpio.zig` | GPIO ports A-L |
| `firmware/osos.bin` | Apple firmware (7.21 MB) |

---

*Analysis based on Rockbox pp5020.h, firmware string analysis, and ARM disassembly*
