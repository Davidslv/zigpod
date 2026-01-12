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
