# Apple Firmware (osos.bin) Analysis

## Overview

This document captures analysis of Apple iPod firmware behavior in the ZigPod emulator.

**Firmware**: `firmware/osos.bin`
**Size**: 7,561,216 bytes
**Load Address**: 0x10000000 (SDRAM)
**Entry Point**: 0x10000800
**Version**: PP5020AF-05.00

## Test Configuration

```bash
./zig-out/bin/zigpod-emulator \
  --load-sdram firmware/osos.bin \
  --entry 0x10000800 \
  --enable-cop \
  --cycles 100000000
```

## Execution Results (100M Cycles)

### Final State
- **CPU PC**: 0x10082E98 (stuck in RTOS scheduler loop)
- **Mode**: Supervisor
- **Thumb**: false

### Memory Activity
| Region | Writes | Reads |
|--------|--------|-------|
| IRAM | 4,148,869 | - |
| SDRAM | 0 | - |

### Peripheral Access Counts
| Peripheral | Accesses |
|------------|----------|
| Interrupt Controller | 488,104 |
| Device Init | 549,117 |
| Mailbox | 0 |
| Timers | 0 |
| GPIO | 0 |
| I2C | 0 |
| System Controller | 0 |
| ATA/IDE | 0 |

### Interrupt Controller Register Histogram
| Offset | Register | Accesses |
|--------|----------|----------|
| 0x01C | INT_FORCED_CLR | 61,013 |
| 0x028 | CPU_INT_DIS | 61,013 |
| 0x038 | COP_INT_DIS | 61,013 |

### Device Init Register Histogram
| Offset | Accesses |
|--------|----------|
| 0x00 (PP_VER1) | 122,026 |
| 0x20 (DEV_INIT2) | 61,013 |
| 0x24 (DEV_INIT2+4) | 122,026 |
| 0x30 (Status) | 244,052 |

## Analysis

### Current Behavior

1. **Firmware boots successfully** - Entry point reached, initial setup executed
2. **RTOS initialization** - Firmware enters RTOS scheduler
3. **Stuck in loop** - PC stays at 0x10082E98, checking for ready tasks
4. **No COP wake** - 0 mailbox accesses indicates COP not woken
5. **No disk access** - ATA controller never accessed
6. **No display** - LCD never written to

### Root Cause Hypothesis

The firmware appears to be waiting for:
1. **Hardware interrupts** that never fire (timers, I2C events)
2. **COP tasks** that never become ready
3. **External events** (button presses, disk insertion)

The RTOS scheduler at 0x10082E98 repeatedly:
1. Checks task queues in hw_accel region (0x60003000)
2. Clears interrupt flags
3. Disables CPU/COP interrupts
4. Loops waiting for tasks

### Key Addresses

| Address | Description |
|---------|-------------|
| 0x10000800 | Firmware entry point |
| 0x10082E98 | RTOS scheduler (stuck here) |
| 0x10229B68 | Task readiness check function |
| 0x1027F344 | Earlier stuck point (before int ctrl fix) |

## COP State

- **Enabled**: Yes (via --enable-cop flag)
- **Entry Point**: 0x10000800 (same as CPU)
- **State**: Sleeping (never woken)
- **Mailbox Activity**: None

The COP starts at the same entry point as CPU. Firmware checks PROC_ID:
- CPU reads 0x55 → continues with CPU path
- COP reads 0xAA → goes to sleep waiting for wake

Since mailbox accesses = 0, CPU never sent wake signal to COP.

## Next Steps

To make further progress, we need to:

1. **Implement timer interrupts** - Timers need to fire and trigger IRQs
2. **Investigate hw_accel** - Understand task queue format at 0x60003000
3. **Trace RTOS scheduler** - Determine what tasks firmware is waiting for
4. **Add I2C devices** - WM8758 codec and PCF50605 PMU responses may be needed
5. **Enable DEV_EN bits** - Ensure all required devices are enabled

## Register Definitions

### Interrupt Controller (0x60004000)
```
0x01C: INT_FORCED_CLR - Clear forced interrupts (write 1 to clear)
0x028: CPU_INT_DIS    - Disable CPU interrupts (write 1 to disable)
0x038: COP_INT_DIS    - Disable COP interrupts (write 1 to disable)
```

### Device Init (0x70000000)
```
0x00: PP_VER1    - Returns 0x00005021 (PP5021)
0x04: PP_VER2    - Returns 0x000000C1 (Revision C1)
0x20: DEV_INIT2  - Device initialization register 2
0x30: Status     - Bit 31 = ready flag
```

## Deep Dive: Why Timer Interrupts Alone Won't Help

### The Chicken-and-Egg Problem

Analysis of peripheral access patterns reveals a fundamental issue:

1. **0 timer accesses** - Firmware hasn't configured TIMER1_CFG or TIMER2_CFG
2. **0 I2C accesses** - Firmware hasn't initialized PMU/codec
3. **Interrupts actively disabled** - 61K writes to CPU_INT_DIS and COP_INT_DIS

The RTOS scheduler is running but **no tasks are ready**. Timer configuration happens in tasks that need the scheduler to already be working.

### Access Pattern Analysis

The access counts show a clear pattern:
- Device Init Status (0x30): **244,052** accesses
- PP_VER1 (0x00): **122,026** accesses
- DEV_INIT2+4 (0x24): **122,026** accesses
- INT_FORCED_CLR: **61,013** accesses
- CPU_INT_DIS: **61,013** accesses
- COP_INT_DIS: **61,013** accesses

The ratios suggest: 244K = 4 × 61K, 122K = 2 × 61K

This indicates a tight loop:
```c
for (iterations) {
    read PP_VER1;           // 122K
    read DEV_INIT2+4;       // 122K
    read Status;            // 122K
    read Status;            // 122K (second check)

    clear_int_forced();     // 61K
    disable_cpu_int();      // 61K
    disable_cop_int();      // 61K
}
```

### Entry Point Analysis (0x10000800)

Disassembly of the entry point shows:
```asm
0x10000800: b 0x100009f0           ; Jump to main init

; At 0x100009f0 (initialization):
0x10000a40: mov r0, #0x60000000    ; Load PROC_ID address
0x10000a44: ldrb r2, [r0]          ; Read processor ID
0x10000a48: cmp r2, #0x55          ; Is it CPU?
0x10000a4c: beq cpu_init           ; CPU path

; COP path (if r2 != 0x55):
0x10000a50: ldr sp, [0x40005ff8]   ; COP stack
0x10000a54: bl cop_sleep           ; COP goes to sleep

; CPU path:
0x10000a5c: ldr sp, [0x40003ff8]   ; CPU stack
0x10000a60: bl early_init          ; Start initialization...
```

### The Status Register Mystery

The firmware heavily polls **0x70000030** (244K times) - an **undocumented** register not in Rockbox headers. The emulator returns `0x80000000` (bit 31 = ready), but this may not be what Apple firmware expects.

### Recommended Fix Approach

#### Option 1: Fix Status Register Value (Quick Test)
```zig
// In bus.zig, try different values:
0x30 => 0xFFFFFFFF,  // All bits set
// or
0x30 => 0x00000000,  // All bits clear
```

#### Option 2: Pre-fire Timer Interrupt (Force Scheduler)
```zig
// In core.zig step():
if (self.total_cycles == 1_000_000) {
    self.int_ctrl.setTimerInterrupt(true);
}
```

#### Option 3: Pre-initialize Timers (More Realistic)
```zig
// In timers.zig init():
// Auto-configure TIMER1 for 10ms tick
self.timer1_cfg = 0xC000_2710;  // Enable, repeat, 10000 count
```

#### Option 4: I2C Device Responses (Most Complete)
Ensure PCF50605 and WM8758 return valid responses when polled. The firmware may need PMU status before enabling other hardware.

## Conclusion

The COP implementation is working correctly. The firmware simply doesn't reach the point where it needs to wake COP within 100M cycles. The primary blocker is the RTOS scheduler waiting for tasks that depend on:
- Device Init status register returning expected value
- Timer interrupts (but timers aren't configured - chicken-egg)
- I2C device responses (PMU/codec)
- Other hardware events

The most likely fix is understanding what value the firmware expects from the undocumented status register at 0x70000030.
