# LCD Output Approaches Analysis

## Problem Statement

The Rockbox firmware running on the iPod emulator has a scheduler that can't find runnable threads because:
1. The COP (coprocessor) is not emulated
2. COP is responsible for calling `core_wake(CPU)` which adds threads to the CPU's RTR (Ready-To-Run) queue
3. Without threads in RTR queue, `switch_thread()` loops indefinitely

**Current State (as of 2026-01-15):**
- Timer1 fires correctly (800+ times)
- IRQ handling works (kernel panic fixed via LDMIA PC bug fix)
- `switch_thread` at 0x84B5C is called
- RTR queue head at 0x1012ACD8 = NULL (empty)
- No threads scheduled → No LCD output

---

## Three Approaches Analyzed

### Approach 1: COP Wake Response

**Mechanism:** Intercept `core_wake(COP)` calls from Timer1 handler and immediately respond with `core_wake(CPU)` to populate RTR queue through normal scheduler mechanism.

**Implementation:**
```zig
// In Timer1 IRQ handler detection:
// When firmware calls core_wake(COP), intercept and:
// 1. Find core_wake(CPU) function address
// 2. Call it to add threads to CPU's RTR queue
```

**Pros:**
- Uses Rockbox's own code paths
- Clean, doesn't manipulate data structures directly
- Maintains scheduler integrity

**Cons:**
- May not be the only COP dependency
- Requires understanding exactly where `core_wake` is called
- The existing `MBX_MSG_STAT` bypass attempts this but isn't sufficient

**Risk Level:** Medium
**Likelihood of Success:** ~60%

---

### Approach 2: Direct Thread Injection

**Mechanism:** RTR tracing identified `0x1012ACD8` as potential queue head. Find actual thread structures in SDRAM, set their state to "ready", and link them into RTR queue.

**Implementation:**
```zig
// After kernel init:
// 1. Scan SDRAM for thread control blocks (TCBs)
// 2. Identify LCD-related thread
// 3. Set thread state to READY
// 4. Link into RTR queue at 0x1012ACD8
```

**Pros:**
- Direct solution to "queue is empty" problem
- Can target specific threads (like LCD thread)

**Cons:**
- Previous attempt crashed (fragile to struct layout)
- Requires knowing exact Rockbox thread structure layout
- Version-dependent, breaks with firmware updates

**Risk Level:** High
**Likelihood of Success:** ~40%

---

### Approach 3: Direct LCD Function Call (RECOMMENDED)

**Mechanism:** Find the function that writes pixels to LCD hardware and call it directly, bypassing the scheduler entirely.

**Implementation:**
```zig
// After kernel init completes:
// 1. Find framebuffer address in SDRAM
// 2. Find lcd_update() function address
// 3. Call lcd_update() directly OR
// 4. Read framebuffer memory and push to LCD hardware
```

**Pros:**
- Bypasses entire scheduler complexity
- Most direct path to LCD output
- Doesn't care about COP or thread state
- LCD hardware emulation already complete

**Cons:**
- May miss initialization in normal thread context
- LCD buffer might not be populated yet

**Risk Level:** Low
**Likelihood of Success:** ~75%

---

## Comparison Matrix

| Approach | Effort | Risk | Correctness | Guarantee |
|----------|--------|------|-------------|-----------|
| COP Wake Response | Medium | Medium | High | No |
| Thread Injection | High | High | Medium | No |
| **Direct LCD Call** | **Low** | **Low** | Medium | **Best** |

---

## Recommended Strategy

**Primary:** Direct LCD Call (Approach 3)
- Fastest path to visible output
- Failure mode is informative (empty buffer = need more boot progress)
- Can be implemented incrementally

**Secondary:** COP Wake Response (Approach 1)
- Layer on after LCD works for proper scheduler operation
- Better long-term emulation accuracy

**Avoid:** Thread Injection (Approach 2)
- Too fragile, already crashed once
- Only consider if other approaches fail completely

---

## Implementation Plan for Direct LCD Call

### Step 1: Find Framebuffer Address
- Rockbox iPod Video uses 320x240 RGB565 (153,600 bytes)
- Likely in SDRAM range 0x10000000-0x11FFFFFF
- Search for LCD initialization code that sets framebuffer pointer

### Step 2: Find lcd_update() Address
- Search firmware for LCD2 bridge writes (0x70008A00)
- The function that writes to LCD2_BLOCK_DATA (0x70008B00) is our target
- Alternatively, find the higher-level `lcd_update()` wrapper

### Step 3: Implement Hook
- Detect kernel init complete (Timer1 enabled by firmware)
- After N timer ticks, call lcd_update() directly
- Or: Read framebuffer from SDRAM and push to LCD controller

### Step 4: Fallback
- If framebuffer empty, try calling earlier in boot
- If lcd_update crashes, try raw framebuffer read instead

---

## Key Addresses (iPod Video / PP5020)

| Symbol | Address | Notes |
|--------|---------|-------|
| switch_thread | 0x84B5C | Scheduler loop |
| RTR queue head | 0x1012ACD8 | Always NULL currently |
| LCD2 Bridge | 0x70008A00 | Rockbox LCD interface |
| LCD2_BLOCK_DATA | 0x70008B00 | Pixel data FIFO |
| Timer1 handler | TBD | Calls tick_tasks |
| lcd_update | TBD | Target function |
| framebuffer | TBD | 153,600 bytes RGB565 |

---

---

## Implementation Results (2026-01-15)

### Direct LCD Approach: SUCCESS

The Direct LCD Approach was implemented and tested successfully:

```
KERNEL_INIT_COMPLETE: IRQ vector installed, Timer1 enabled by firmware
=== DIRECT LCD APPROACH TRIGGERED ===
=== FRAMEBUFFER SCAN ===
Test pattern drawn! LCD updates: 1, pixel_writes: 76800
Framebuffer saved to /tmp/zigpod_lcd.ppm
```

**Key Findings:**

1. **LCD2 Bridge received 0 writes** - Rockbox never called `lcd_update()` because:
   - The scheduler couldn't find runnable threads (RTR queue empty)
   - No threads ran, so no code path reached the LCD drawing functions

2. **Framebuffer scan found nothing** - As expected, since threads never executed:
   - Rockbox's internal framebuffer was never populated
   - No splash screen or boot logo was drawn

3. **Test pattern successfully displayed** - Proves the LCD pipeline works:
   - Color bars: Red, Green, Blue, Yellow, Magenta, Cyan, White, Gray
   - PPM output saved correctly with proper RGB565→RGB888 conversion
   - LCD controller emulation is complete and functional

### Conclusion

The Direct LCD Approach confirmed:
- **LCD hardware emulation: WORKING**
- **LCD output pipeline: WORKING**
- **Root cause confirmed: Scheduler/COP dependency**

To get actual Rockbox LCD output, we need to solve the scheduler problem. The options remain:
1. COP Wake Response (recommended next step)
2. Thread Injection (risky)

### Files Modified

- `src/emulator/core.zig` - Added:
  - `scanForFramebuffer()` - Scans SDRAM for framebuffer content
  - `copyFramebufferToLcd()` - Copies found framebuffer to LCD
  - `drawTestPattern()` - Draws color bars for testing
  - `findLcdUpdateFunction()` - Monitors LCD2 bridge writes
  - Trigger logic after kernel init + 10M cycles

---

## COP Wake Response Implementation (2026-01-15)

### Overview

The COP Wake Response mechanism was implemented to simulate COP's behavior when Timer1 handler calls `core_wake(COP)`. In real hardware, COP would respond by calling `core_wake(CPU)` to add threads to the RTR queue.

### Implementation

**Files Modified:**

1. **`src/emulator/peripherals/system_ctrl.zig`**
   - Added `pending_thread_wakeup: bool` field to track wake request
   - Added `thread_wakeup_countdown: u32` for delayed response
   - Modified COP_CTL write handler to detect wake requests (writing 0)
   - Triggers after kernel_init_complete and cop_wake_count >= 10

2. **`src/emulator/core.zig`**
   - Added `performThreadWakeup()` function that:
     - Scans SDRAM for TCB (Thread Control Block) structures
     - Looks for valid SP (SDRAM stack pointer) and PC (code pointer)
     - Adds found TCBs to RTR queue at correct offset (+0x18 for embedded linked list)
   - Added wakeup check in `step()` function after countdown expires

3. **`src/emulator/memory/bus.zig`**
   - Added debug trace for RTR head writes (0x1012ACD8)

### Key Technical Discoveries

1. **RTR Queue Structure**: Rockbox uses embedded linked lists within TCBs. The RTR queue head points to `tcb + 0x18` (the thread_list structure), not the TCB base address. Initial attempts writing the TCB address were "corrected" by the scheduler to `tcb + 0x18`.

2. **TCB Scanning**: Generic TCB scanning finds false positives (bootloader data, not valid threads). Real Rockbox threads need:
   - SP pointing to valid SDRAM stack (0x10000000-0x11FFFFFF)
   - PC pointing to valid code (IRAM 0x40000000+ or SDRAM code)
   - Proper state field at correct offset

3. **Timing**: The COP Wake Response must trigger after the main firmware (rockbox.ipod) has initialized its threads, not during bootloader execution.

### Current Status: BLOCKED

**What Works:**
- COP Wake Response triggers correctly after kernel init
- RTR queue structure is correctly understood (tcb + 0x18)
- TCB scanner finds candidates
- Firmware loading works ("Rockbox loaded." appears)

**Blocking Issue:**
The main Rockbox firmware (rockbox.ipod) crashes during execution:
```
BX: Mode switch to THUMB at PC=0x00003230, target=0x00003231
BX: Mode switch to THUMB at PC=0x00000002, target=0x00000003
Final PC: 0xFFFFFB42, Mode: undefined, Thumb: true
```

The execution jumps to invalid addresses (0x00000002 → 0xFFFFFB42), indicating a separate emulator bug that prevents the main firmware from running past early init.

**Next Steps to Unblock:**
1. Debug the BX to 0x00000002 - find what instruction leads there
2. Check for missing ARM instruction emulation (MRS/MSR, coprocessor, etc.)
3. Verify MMAP translation for low addresses doesn't cause issues

---

## References

- `docs/reverse-engineering/LCD_OUTPUT_PLAN.md` - Original LCD strategy
- `docs/reverse-engineering/COP_WAKE_INVESTIGATION.md` - COP analysis
- `src/emulator/peripherals/lcd.zig` - LCD controller emulation
- `src/emulator/core.zig` - Scheduler bypass logic
