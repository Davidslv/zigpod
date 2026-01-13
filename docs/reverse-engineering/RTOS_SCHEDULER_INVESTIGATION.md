# RTOS Scheduler Investigation

## Problem Statement

Apple firmware (osos.bin) is stuck in RTOS scheduler loop, never reaching peripheral initialization (LCD, timers, I2C).

**Stuck PC**: 0x10229BB4 (file offset 0x229BB4)
**Peripheral accesses**: All zero (timers, GPIO, I2C, LCD)

## Investigation Log

### Session 1: Initial Analysis

**Date**: 2025-01-12

#### Disassembly of Stuck Region

```
File offset: 0x229B68 - 0x229C10
SDRAM address: 0x10229B68 - 0x10229C10
```

```asm
0x229B68: push {r4, r5, lr}
0x229B6C: movs r4, r1
0x229B70: mov  r5, r0
0x229B74: moveq r0, #2
0x229B78: popeq {r4, r5, pc}      ; Return if r1 was 0
0x229B7C: mov  r1, r4
0x229B80: mov  r0, r5
0x229B84: bl   0x229C10           ; Call subroutine
0x229B88: cmp  r0, #0
0x229B8C: popne {r4, r5, pc}      ; Return if r0 != 0
0x229B90: ldr  r1, [0x229C0C]     ; r1 = 0x60003000 (hw_accel)
0x229B94: ldr  ip, [r1]           ; Read [0x60003000]
0x229B98: ldrb r2, [r5]           ; Read byte from input
0x229B9C: ldrb lr, [r4]           ; Read byte from input
0x229BA0: lsl  r3, r2, #1
0x229BA4: mov  r2, #3
0x229BA8: bic  ip, ip, r2, lsl r3
0x229BAC: orr  r3, ip, lr, lsl r3
0x229BB0: str  r3, [r1]           ; Write to [0x60003000]
0x229BB4: ldr  ip, [r1, #4]       ; <-- STUCK HERE: Read [0x60003004]
...continues manipulating 0x60003000 region...
```

#### Key Observation

The code at 0x229B90 loads address `0x60003000` from a literal pool. This is the **hw_accel** region - used by Apple's RTOS for task queue management.

The function:
1. Calls a subroutine at 0x229C10
2. If it returns 0, manipulates data at 0x60003000-0x6000303F
3. This appears to be task state manipulation

#### Questions to Answer

1. What does the subroutine at 0x229C10 do?
2. What values in 0x60003000 region indicate "task ready"?
3. Is this the scheduler main loop or a helper function?
4. What triggers tasks to become ready?

---

### Session 2: hw_accel Region Tracing

**Date**: 2025-01-12

#### Objective

Add tracing to emulator to log all accesses to 0x60003000 region.

#### Implementation

TODO: Add hw_accel access logging

#### Findings

**hw_accel Access Pattern:**

```
Initialization sequence:
  [0x00] 0x00 -> 0x01 -> 0x09 -> 0x19 -> 0x59 (stabilizes)
  [0x04] 0x00 -> 0x02 -> 0x06 -> 0x26 -> 0xA6 (stabilizes)
  [0x08] 0x00 -> 0x03 -> 0x0F -> 0x3F -> 0xFF (stabilizes)
  [0x0C] 0x00 (never changes)

Stable loop pattern:
  READ  [0x60003000] = 0x59, WRITE 0x59
  READ  [0x60003004] = 0xA6, WRITE 0xA6
  READ  [0x60003008] = 0xFF, WRITE 0xFF
  READ  [0x6000300C] = 0x00, WRITE 0x00
  (repeats infinitely)
```

**Interpretation:**
- Task states use 2 bits per task (4 states per task)
- 4 words x 32 bits / 2 bits = 64 task slots
- The scheduler is waiting for task states to CHANGE
- No interrupts/events are triggering state changes

**Stable values decoded:**
```
0x59 = 0b01011001 = tasks 0,3,4,6 in state 01
0xA6 = 0b10100110 = tasks 1,2,5,7 in state 10
0xFF = 0b11111111 = all tasks in state 11
0x00 = 0b00000000 = all tasks in state 00
```

**Hypothesis:** State bits meaning:
- 00 = inactive/not created
- 01 = sleeping/blocked
- 10 = waiting
- 11 = ready to run

The scheduler loops because no tasks reach "ready" (11) state in words 0-1

---

## hw_accel Region Analysis

### Memory Layout (0x60003000)

Based on Rockbox and observed access patterns:

| Offset | Purpose (Hypothesis) |
|--------|---------------------|
| 0x00 | Task 0 state/priority? |
| 0x04 | Task 1 state/priority? |
| 0x08 | Task 2 state/priority? |
| ... | ... |
| 0x3C | Task 15 state/priority? |

### Access Pattern from Firmware

The firmware performs bit manipulation:
```c
// Pseudocode from disassembly
uint32_t* hw_accel = (uint32_t*)0x60003000;
for (int i = 0; i < 16; i++) {
    uint32_t val = hw_accel[i];
    // Clear 2 bits at position (index * 2)
    val &= ~(3 << (index * 2));
    // Set new value
    val |= (new_state << (index * 2));
    hw_accel[i] = val;
}
```

This suggests each 32-bit word holds state for multiple tasks (2 bits each = 16 tasks per word).

---

## Hypotheses

### Hypothesis 1: Timer Interrupt Needed

The RTOS scheduler relies on timer interrupts to:
1. Wake sleeping tasks
2. Trigger task switches
3. Update tick counter

**Test**: Pre-fire timer interrupt after N cycles

### Hypothesis 2: I2C Device Response Needed

Early boot may require PMU (PCF50605) to respond before proceeding:
1. Power rail status
2. Battery level
3. Button state

**Test**: Implement basic I2C device responses

### Hypothesis 3: hw_accel Pre-initialization

The hw_accel region may need specific initial values for scheduler to find ready tasks.

**Test**: Pre-populate 0x60003000 with "task ready" pattern

---

## Implementation: hw_accel Kickstart

### Approach

Added `kickstart_enabled` flag to MemoryBus. After 1M cycles, reads to
hw_accel offset 0 return modified value 0x5B instead of 0x59:

```zig
// In readHwAccel():
if (self.kickstart_enabled and offset == 0) {
    // Change bits 0-1 from 01 to 11 (task 0 ready)
    value = (value & ~@as(u32, 0x3)) | 0x3;
}
```

- Original: 0x59 = 0b01011001 (task 0 state = 01 = sleeping)
- Modified: 0x5B = 0b01011011 (task 0 state = 11 = ready)

### Results

```
RTOS KICKSTART: Enabled at cycle 1000001
HW_ACCEL READ [0x60003000] = 0x0000005B [KICKSTART #1]
...continues reading 0x5B...
```

| Cycles | Final PC | Notes |
|--------|----------|-------|
| 5M | 0x10001688 | Progress! Left scheduler |
| 50M | 0x10229BB4 | Returned to scheduler |

### Analysis

The kickstart successfully breaks the scheduler loop temporarily:
1. Task 0 is marked ready (state 11)
2. Scheduler dispatches task 0
3. Task 0 runs briefly (reaches 0x10001688 - delay loop)
4. Task 0 blocks/completes, returns to sleeping (state 01)
5. Scheduler loop resumes waiting for tasks

### Conclusion

The task state modification works, but task 0 immediately blocks on something
(likely I2C response, timer, or external event). Need to investigate what
task 0 does when it runs and why it immediately blocks.

---

## Implementation: IRQ Enable Fix

### Root Cause Discovery

Parallel agent investigation revealed:
- **CPU starts with IRQ disabled** (CPSR I-bit = 1, ARM standard)
- **Boot ROM would enable IRQ** before jumping to firmware
- **Emulator skips Boot ROM** → IRQ never enabled → all interrupts ignored

### Fix Applied

Added to kickstart sequence in core.zig:
```zig
self.cpu.enableIrq();    // Clear CPSR I-bit
self.cpu.enableFiq();    // Clear CPSR F-bit
self.int_ctrl.forceEnableCpuInterrupt(Interrupt.timer1);
self.int_ctrl.assertInterrupt(Interrupt.timer1);
```

### Results After Fix

| Cycles | Final PC | Notes |
|--------|----------|-------|
| 10M | 0x10001A68 | New location! |
| 100M | 0x1000166C | Different stuck point |

Still 0 peripheral accesses - likely waiting for I2C device responses.

### Next Steps

Implement I2C device responses for:
- PCF50605 PMU: Battery voltage, power rails, RTC
- WM8758 codec: Initialization responses

---

---

## Session 3: Deep Dive Analysis (2026-01-12)

### Problem: hw_accel Kickstart Not Working

The previous kickstart at 1M cycles no longer works. Investigation revealed:

#### Timeline Discovery

| Cycles | State |
|--------|-------|
| ~500 | Boot sequence running |
| ~1000 | Peripheral init |
| ~2000 | hw_accel init loop |
| ~3000 | **Enters scheduler wait loop** |
| 100k+ | Still at 0x1000097C |

The firmware enters the SWI wait loop at ~3000 cycles, BEFORE our kickstart at 100k cycles.

#### hw_accel Analysis

**Access Pattern:**
```
Read  0x00 → Write 0x01
Read  0x01 → Write 0x09
Read  0x09 → Write 0x19
Read  0x19 → Write 0x59 (final)
```

**Key Finding:** After the init loop (16 reads/writes), **NO MORE hw_accel reads occur**.

The scheduler does NOT read hw_accel to check for ready tasks - it uses a different data structure in RAM.

#### SWI Handler Loop Analysis

**Stuck Address:** 0x1000097C

```asm
; SWI entry at 0x10000960:
LDR  R12, [R10]           ; Read PROC_ID (0x60000000)
CMP  R12, #0x55           ; Is CPU?
BNE  elsewhere            ; No, branch
SUB  LR, LR, #4           ; Adjust return address
PUSH {R0-R8, LR}          ; Save context
BL   0x100277C0           ; Call wait_for_event
LDM  SP!, {R0-R8, LR, PC}^ ; Exception return ← STUCK HERE
```

The `wait_for_event` function at 0x100277C0 blocks until a task is ready. It never returns success, so the loop continues forever.

#### IRQ Kickstart Failure

Tried enabling IRQ at 200k and 500k cycles:

| Cycle | Result |
|-------|--------|
| 200k | Crash: PC=0xE12FFF1C, Mode=unknown |
| 500k | Crash: PC=0xE12FFF1C, Mode=unknown |

**Root Cause:** IRQ dispatch tables are NOT initialized.
- The IRQ handler at 0x10000980 eventually calls uninitialized function pointers
- Dispatch tables would be set up by tasks that never run (chicken-egg problem)

### Conclusions

1. **hw_accel is only used during initialization** - scheduler doesn't poll it
2. **Task state lives in RAM** - need to find the address
3. **IRQ cannot work** until dispatch tables are initialized
4. **The scheduler wait loop starts at ~3000 cycles** - too early for any kickstart

### Potential Solutions

1. **Find task state RAM address**: The scheduler reads task state from somewhere in SDRAM (possibly around 0x108xxxxx). Modifying this directly might work.

2. **Implement I2C device responses**: Tasks may be waiting for PMU (PCF50605) or codec (WM8758) responses. With proper I2C emulation, tasks might complete and mark themselves ready.

3. **Manual dispatch table initialization**: Find where the IRQ dispatch tables should be and pre-initialize them so IRQ can work.

4. **Different firmware path**: Maybe there's a boot flag or memory location that controls whether the scheduler waits for tasks.

---

## Session 4: SDRAM Data Read Tracing (2026-01-12)

### Objective

Add targeted SDRAM data read tracing to identify where task state arrays live in RAM, since hw_accel is only used during initialization.

### Implementation

Added SDRAM read tracing in `bus.zig`:
- Filters out obvious code (ARM instructions with 0xE condition code)
- Focuses on data regions (0x10800000+ = BSS/heap)
- Logs first 64 unique addresses with values
- Tracks page-level heat map

### Discovered Task Control Block Addresses

SDRAM reads during initialization reveal task control block (TCB) structures:

**Primary TCB Region: 0x1087xxxx**
```
0x108701B0 = 0x00000000  (field at offset 0x00?)
0x108701B4 = 0x00000000  (field at offset 0x04?)
0x108701C4 = 0x1086C154  (pointer - next TCB?)
0x108701C8 = 0x00004000  (stack size or flags?)
0x108701CC = 0x00000001  (STATE FIELD? value=1)
0x108701D0 = 0x00000000
0x108701D4 = 0x00000000
0x10870138 = 0x00000014  (priority or tick count? value=20)
0x1087014C = 0x00000000
0x10870154 = 0x00000000
0x10870158 = 0x00000000
0x1087015C = 0x00000000
```

**Secondary TCB Region: 0x1086xxxx**
```
0x1086C154 = ???        (pointed to by 0x108701C4)
0x1086C158 = 0x00003FF4 (stack pointer or size?)
0x1086C15C = 0x00000000
0x1086C160 = 0x108701D0 (pointer - forms linked list)
```

**Other Data Structures:**
```
0x1081DA98 = 0x00000000 (global variable)
0x1081D85C = 0x1084BE48 (pointer to another structure)
0x1084BE4C = 0x00000000
```

### Key Finding: Linked List of TCBs

The TCB structures form a linked list:
```
TCB at 0x108701B0:
  - pointer at +0x14 (0x108701C4) -> 0x1086C154
  - state at +0x1C (0x108701CC) = 0x00000001

Secondary structure at 0x1086C154:
  - pointer at +0x0C (0x1086C160) -> 0x108701D0
```

### Task State Hypothesis

Based on the values observed:
- **0x00000000** = inactive/not created
- **0x00000001** = sleeping/waiting (seen at 0x108701CC)
- **0x00000002** = ???
- **0x00000003** = ready to run (target for kickstart)

### TCB Modification Results (FAILED)

Attempted to modify task state field at 0x108701CC:
- Changed from 0x00000001 (sleeping) to 0x00000003 (ready)
- Result: **Scheduler still stuck at 0x1000097C**

Also tried aggressive hw_accel modification:
- Always return task 0 as "ready" (state 11) on every read
- Result: **No effect - hw_accel not polled after init**

### Key Insight

The scheduler at 0x1000097C is NOT polling:
- hw_accel region (0x60003000) - only used during init
- TCB state at 0x108701CC - modification has no effect

The wait_for_event function (0x100277C0) must be waiting for:
1. **Interrupt** - Timer/IRQ, but dispatch tables not initialized
2. **I2C completion** - PMU or codec device response
3. **Event flag** - Set by peripheral driver we're not emulating

### Next Approach: I2C Device Response

Since peripheral access counts show 0 I2C accesses during the scheduler
wait, the firmware might be waiting for I2C initialization to complete
before reaching the scheduler. Need to investigate early boot I2C sequence.

---

## Session 5: Scheduler Mutex and Filesystem Discovery (2025-01-12)

### Objective

Deep dive into scheduler mechanics to understand why tasks never become ready.

### Scheduler Mutex Analysis

**Function 0x1025B348** - Test-and-Set Mutex:
```asm
0x1025B348: LDR R1, [R0]      ; Load mutex value
0x1025B34C: CMP R1, #0        ; Is it free (zero)?
0x1025B350: MOVEQ R1, #1      ; If free, set to locked
0x1025B354: STREQ R1, [R0]    ; Store back
0x1025B358: MOVEQ R0, #1      ; Return 1 (acquired)
0x1025B35C: MOVNE R0, #0      ; Return 0 (failed)
0x1025B360: MOV PC, LR        ; Return
```

**Key Insight:** Mutex acquisition checks `value == 0`, NOT just bit 0.

**Scheduler Flow at 0x102778C0:**
1. Load R4 from PC+0x34 = 0x1081D850 (scheduler data structure)
2. Load R0 = [0x1081D858] (skip flag)
3. TST R0, #0x1 - if bit 0 set, skip task selection
4. If not set, try to acquire mutex at 0x1081D858
5. Call task selection at 0x10127E18
6. Task selection also checks [0x1081D860]

**Updated schedulerKickstart():**
- Changed from clearing bit 0 to completely zeroing both addresses
- This allows mutex acquisition to succeed

### IRQ Chicken-and-Egg Problem

**Observation:** Enabling IRQ and firing timer1 causes crash to 0xE12FFF1C.

**Reason:** This address looks like a BX instruction opcode being executed as a PC address. The IRQ handler tries to dispatch to uninitialized function pointers.

**IRQ Handler Flow:**
1. Exception to 0x00000018
2. LDR PC, [PC, #0x18] loads from literal pool
3. Jumps to 0x10000818 (EA000058 = B 0x10000980)
4. 0x10000980 eventually calls through dispatch table
5. Dispatch table not initialized → jumps to garbage

### CRITICAL DISCOVERY: Filesystem Access

**Major Breakthrough:** The firmware is actively trying to read FAT32 directory entries!

**Evidence from trace:**
```
DIR_ENTRY[0x11006F14]: first_byte=0x00('.'), val=0x00000000
DIR_ENTRY[0x11006F34]: first_byte=0x00('.'), val=0x00000000
LFN_START READ at 0x11006F54: val=0x00000000
ATTR READ at 0x11006F5C: val=0x00000000
CHECKSUM READ at 0x11006F60: val=0x00000000
SHORT_ENTRY READ at 0x11006F74: val=0x00000000
DIR_ENTRY[0x11006F94]: first_byte=0x00('.'), val=0x00000000
```

**Interpretation:**
- Address range 0x11006Fxx is disk buffer/flash emulation
- Firmware is scanning FAT32 directory entries
- All entries return 0x00 (empty/no files)
- The firmware is stuck in a loop looking for expected files

**Expected iPod Directory Structure:**
- `/iPod_Control/` - Main iPod directory
- `/iPod_Control/iTunes/` - iTunes database files
- `/iPod_Control/Music/` - Music files (Fxx/yyyy.mp3)
- `/iPod_Control/Device/` - Device info
- Various system files (iTunesDB, iTunesSD, etc.)

### Root Cause Identified

**The firmware is NOT stuck in scheduler wait loop due to RTOS mechanics.**

**The REAL issue:** The firmware is trying to read the iPod filesystem and finding nothing. It's in a loop scanning directory entries, all of which are empty.

### Solution Path

1. **Create proper FAT32 filesystem** with expected iPod structure
2. **Populate required files**: iTunesDB, device info, etc.
3. **Mount filesystem image** in emulator at appropriate addresses
4. Or: **Patch firmware** to skip disk checks

### Code Changes

**bus.zig - schedulerKickstart():**
- Now completely zeros mutex values instead of just clearing bit 0
- This allows mutex acquisition to succeed

**core.zig:**
- Disabled timer IRQ kickstart (causes crash without initialized handlers)
- Added debug logging at 50k cycles

---

## Next Steps

1. [x] Add hw_accel access tracing to emulator
2. [ ] Disassemble subroutine at 0x229C10
3. [x] Test hw_accel kickstart (partial success)
4. [x] Investigate task 0 blocking reason (blocked on unknown RAM state)
5. [~] Implement I2C device responses (PMU/codec) ← **PRIORITY**
6. [x] Find task state RAM address (found: 0x108701CC and related TCB fields)
7. [ ] Find and initialize IRQ dispatch tables
8. [x] Try direct TCB modification at 0x108701CC ← **FAILED - no effect**
9. [ ] Analyze wait_for_event function at 0x100277C0
10. [ ] Trace what conditions wait_for_event is checking

---

## References

- [APPLE_FIRMWARE_ANALYSIS.md](APPLE_FIRMWARE_ANALYSIS.md) - Initial analysis
- Rockbox source: `firmware/target/arm/pp/` - PP5020 drivers
- ARM7TDMI TRM - Instruction set reference
