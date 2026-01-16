# COP Wake Investigation - Detailed Analysis

**Date:** 2026-01-14
**Status:** Blocking issue identified, multiple solution paths available

## Executive Summary

Rockbox firmware gets stuck in an infinite COP wake loop because:
1. The `wake_core` function has NO software exit condition
2. It's designed to be interrupted by Timer1 IRQ
3. Timer1 never gets enabled because kernel_init() never completes
4. kernel_init() never completes because it calls wake_core

This is a **chicken-and-egg problem** in the PP5021C dual-core synchronization.

---

## Detailed Findings

### 1. Boot ROM COP Sync (SOLVED)

**Location:** 0x08000140-0x08000148 (mapped from 0x140)

```arm
140: LDREQ R1, [R2]           ; Load COP_CTL (R2=0x60007004)
144: TSTEQ R1, #0x80000000    ; Test bit 31 (PROC_SLEEP)
148: BEQ 0x140                ; Loop while bit 31 = 0
```

**Behavior:** CPU waits for COP to signal SLEEPING (bit 31 = 1)

**Solution Applied:** Return SLEEPING when `cop_wake_count == 0`

### 2. wake_core Function (BLOCKING)

**Location:** 0x7694-0x76B8

```arm
7694: PUSH {R4, LR}           ; Save registers
7698: BL 0x7C618              ; Call setup function
769C: BL 0x7668               ; Call another setup
76A0: LDR R3, [PC, #12]       ; Load 0x60007004 (COP_CTL addr)
76A4: MOV R0, #0x80000000     ; ─┐
76A8: STR R0, [R3]            ;  │ INFINITE LOOP
76AC: NOP                     ;  │ Write-only, no read
76B0: B 0x76A4                ; ─┘ NO EXIT CONDITION
76B4: .word 0x60007004        ; Literal pool
76B8: BX LR                   ; Never reached normally
```

**Critical Insight:** This loop:
- Only WRITES to COP_CTL (never reads)
- Has NO conditional branch out
- Is designed to be broken ONLY by IRQ interrupt
- saved_LR = 0 (task entry point, no return address)

### 3. Context-Aware COP_CTL (IMPLEMENTED)

**File:** `src/emulator/peripherals/system_ctrl.zig`

```zig
if (self.cop_wake_count == 0) {
    // Boot ROM phase: return SLEEPING (bit 31 = 1)
    result = ready_flags | 0x80000000;
} else {
    // Kernel phase: return AWAKE (bit 31 = 0)
    result = ready_flags;
}
```

**Result:**
- Boot ROM sync passes ✅
- wake_core still loops (doesn't read COP_CTL) ❌

### 4. Current Skip Mechanism

**File:** `src/emulator/core.zig` (lines 904-942)

After 10,001 iterations in wake_core range (0x769C-0x76B8):
- Read saved_LR from stack
- If valid LR: simulate POP {R4, PC} return
- If LR = 0: jump to 0x76BC (idle_thread helper)

**Problem:** 0x76BC returns via `BX LR`, which still points to 0x76A0 (inside wake_core), creating infinite loop.

### 5. Evidence of Progress

Despite the loop, FAT32 directory reads DO occur:
```
DIR_ENTRY[0x11006F54]: first_byte=0x41('A')
ATTR READ at 0x11006F5C: attr_byte=0x0F
CHECKSUM READ at 0x11006F60: checksum_byte=0xA9
```

This suggests SOME code runs between wake_core cycles.

---

## The Chicken-and-Egg Problem

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  kernel_init() ──────► wake_core() ──────► waits for IRQ   │
│       │                                         │           │
│       │                                         │           │
│       ▼                                         │           │
│  tick_start() ◄─── never reached ◄──── stuck ◄─┘           │
│       │                                                     │
│       ▼                                                     │
│  Timer1 enabled ──► IRQ fires ──► breaks wake_core loop    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Prioritized Solution Options

### Priority 1: Find and Force tick_start() (RECOMMENDED)

**Rationale:** Most direct path to enabling Timer1 and breaking the loop.

**Approach:**
1. Search Rockbox binary for writes to 0x60005010 (TIMER1_CFG)
2. Disassemble surrounding code to find tick_start() function
3. Either:
   - Patch emulator to call tick_start() directly
   - Or find what blocks it and fix that

**Search commands:**
```bash
# Find Timer1 config address in literal pools
arm-none-eabi-objdump -D -b binary -m arm firmware/rockbox/rockbox_raw.bin | grep -B20 "60005010"

# Find Timer1 enable pattern (write to CFG register)
arm-none-eabi-objdump -D -b binary -m arm firmware/rockbox/rockbox_raw.bin | grep -E "str.*\[r[0-9]+\]" | head -100
```

**Expected location:** Based on Rockbox source, tick_start() is in `kernel/kernel.c` and calls timer setup in `target/arm/pp/system-pp502x.c`.

### Priority 2: Trace kernel_init() Path

**Rationale:** Understand exactly where initialization stops.

**Approach:**
1. Find kernel_init() entry point (likely called from main())
2. Add PC tracing for key functions
3. Identify the exact point where COP dependency blocks progress

**Key addresses to find:**
- main() entry point (loaded from 0x100003A8 after MMAP)
- kernel_init() call
- tick_start() call
- thread_create() calls

### Priority 3: Implement Timer1 IRQ + Scheduler Hook

**Rationale:** Force the scheduler to run even without proper init.

**Approach:**
1. Force Timer1 enable in emulator startup
2. Find scheduler tick function address in Rockbox binary
3. Install IRQ handler that calls scheduler tick
4. May need to fake thread context

**Challenge:** Need to find scheduler_tick() or timer1_tick() address.

### Priority 4: Use Bootloader Path

**Rationale:** Bootloader works correctly; use it to load firmware.

**Approach:**
1. Continue using bootloader to load Apple firmware or Rockbox
2. Debug why loaded firmware fails
3. May reveal different issue than direct load

**Status:** Bootloader shows "Loading Rockbox..." but then firmware gets stuck in same wake_core loop.

---

## Key Files to Examine

| File | Purpose |
|------|---------|
| `src/emulator/peripherals/system_ctrl.zig` | COP_CTL handling |
| `src/emulator/core.zig` | wake_core skip logic (lines 885-942) |
| `src/emulator/peripherals/timer.zig` | Timer1 emulation |
| `firmware/rockbox/rockbox_raw.bin` | Rockbox binary to disassemble |

## Key Addresses

| Address | Description |
|---------|-------------|
| 0x7694 | wake_core function entry |
| 0x76A4-0x76B0 | Infinite write loop |
| 0x76BC | idle_thread helper (bad skip target) |
| 0x60007004 | COP_CTL register |
| 0x60005010 | TIMER1_CFG register |
| 0x60005000 | TIMER1_VAL register |

## Recommended Next Steps

1. **Search for tick_start()** - grep for 0x60005010 in disassembly
2. **Find the function that enables Timer1** - trace backwards from literal pool
3. **Determine if tick_start() is called** - add tracing at Timer1 register writes
4. **If not called, find why** - trace kernel_init path
5. **If called but fails, fix** - may be another COP check

---

## Commands for Next Investigation

```bash
# Rebuild and test
zig build && ./zig-out/bin/zigpod-emulator --load-sdram firmware/rockbox/rockbox_raw.bin --headless --cycles 100000000

# Search for Timer1 setup code
arm-none-eabi-objdump -D -b binary -m arm firmware/rockbox/rockbox_raw.bin 2>/dev/null | grep -B30 "60005010"

# Trace Timer1 register accesses
./zig-out/bin/zigpod-emulator ... 2>&1 | grep -E "TIMER1|0x60005"

# Find main() address
arm-none-eabi-objdump -D -b binary -m arm --start-address=0x3A0 --stop-address=0x3B0 firmware/rockbox/rockbox_raw.bin
```
