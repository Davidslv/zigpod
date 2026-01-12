# Reverse Engineering Journal

This document tracks the chronological journey of reverse engineering Apple iPod firmware for the ZigPod emulator.

## Index of Investigations

| Date | Document | Status | Summary |
|------|----------|--------|---------|
| 2025-01-12 | [APPLE_FIRMWARE_ANALYSIS.md](APPLE_FIRMWARE_ANALYSIS.md) | Complete | Initial firmware analysis, entry point, RTOS discovery |
| 2025-01-12 | [COP_IMPLEMENTATION_PLAN.md](COP_IMPLEMENTATION_PLAN.md) | Complete | Coprocessor implementation |
| 2025-01-12 | [RTOS_SCHEDULER_INVESTIGATION.md](RTOS_SCHEDULER_INVESTIGATION.md) | In Progress | Breaking out of scheduler loop |

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

### 2025-01-12: RTOS Scheduler Investigation (Current)

**Goal**: Break out of RTOS scheduler loop to reach peripheral initialization

**Current State**:
- PC stuck at: 0x10229BB4
- 0 Timer accesses
- 0 I2C accesses
- 0 LCD writes
- Firmware accessing hw_accel region (0x60003000)

**Investigation**: See [RTOS_SCHEDULER_INVESTIGATION.md](RTOS_SCHEDULER_INVESTIGATION.md)

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
