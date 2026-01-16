# Plan: Get Rockbox LCD Output Working in ZigPod Emulator

**Date:** 2026-01-15
**Time Budget:** 4 hours
**Status:** Pending Approval

## Executive Summary

The Rockbox kernel gets stuck because it uses dual-core (CPU/COP) synchronization throughout initialization and scheduling. Since we don't emulate COP, the CPU blocks waiting for COP responses that never come. The uncommitted changes have a misguided fix - **PP502x does NOT use a `cores_awake` variable** - it uses mailbox registers (MBX_MSG_STAT) instead.

## Root Cause Analysis

### The Real Problem (from Rockbox source analysis)

In `core_thread_init()` (thread-pp.c:55-72):
```c
if (core == CPU) {
    MBX_MSG_CLR = 0x3f;    // Clear mailbox bits
    wake_core(COP);         // Write 0 to COP_CTL
    sleep_core(CPU);        // CPU SLEEPS HERE waiting for COP!
}
```

The CPU puts itself to sleep waiting for COP to complete initialization and wake it. **COP never runs, so CPU never wakes.**

### Key Insight: PP502x Uses Mailboxes, NOT cores_awake

From Rockbox source:
- PP5002: Uses `cores_awake` semaphore bytes
- **PP502x (iPod Video): Uses mailbox registers (MBX_MSG_STAT at 0x60001000)**

The uncommitted `fixCoresAwakeForCopWake()` function is targeting the wrong mechanism!

### Current State

1. **CPU_CTL auto-wake (commit 1f89ce6)**: When CPU writes SLEEP (0x80000000) to CPU_CTL, we immediately clear it. This gives 298 scheduler iterations.

2. **MBX_MSG_STAT = 0 (uncommitted)**: Always returns 0, bypassing mailbox sync. This is **correct**.

3. **cores_awake fix (uncommitted)**: Tracks SDRAM/IRAM writes to find cores_awake. This is **wrong for PP502x**.

4. **Result**: 298 scheduler iterations, but no LCD output. Something still blocking.

---

## Phase 1: Clean Up Uncommitted Changes (30 min)

### 1.1 Remove Misguided cores_awake Fix

Remove from `bus.zig`:
- `last_sdram_write_addr/value`, `prev_sdram_write_addr/value` fields
- `last_iram_write_addr/value`, `prev_iram_write_addr/value` fields
- `cores_awake_addr`, `cores_awake_fix_applied`, `cop_ctl_wake_count` fields
- `fixCoresAwakeForCopWake()` function
- Tracking in `writeWord()` for SDRAM/IRAM writes
- COP_CTL_ADDR detection in `writeWord()`

### 1.2 Keep the Good Fix
- Keep `MBX_MSG_STAT` always returning 0 - this is correct for PP502x

### 1.3 Verify system_ctrl.zig
- COP_CTL should always return SLEEPING (0xC000FE00) - this is correct
- CPU_CTL auto-wake should remain active

---

## Phase 2: Add Targeted Diagnostic Tracing (45 min)

### 2.1 Timer1 Setup Tracing
Add tracing to detect when `tick_start()` runs:
- Watch for writes to TIMER1_CFG (0x60005000) with enable bit (0xC0000000)
- Log: "TIMER1_ENABLED: config=0x{X}, interval={} cycles"

### 2.2 IRQ Handler Installation Tracing
Add tracing to detect when IRQ vector is installed:
- Watch for writes to 0x40000018 (IRQ vector in IRAM)
- Log: "IRQ_VECTOR_INSTALLED: address=0x{X}, handler=0x{X}"

### 2.3 Thread Creation Tracing
Add tracing for key kernel functions:
- main() entry: PC = 0x03E804DC (after MMAP translation)
- kernel_init() entry: Look for BL to 0x7C618 pattern
- tick_start() entry: Look for writes to 0x60005000

### 2.4 LCD Register Access Tracing
Add tracing for LCD controller access:
- LCD controller registers at 0x70008000-0x70008FFF
- Log first write: "LCD_FIRST_WRITE: addr=0x{X}, value=0x{X}"

---

## Phase 3: Investigate Kernel Init Completion (1 hour)

### 3.1 Build with Diagnostics and Run
```bash
zig build emulator
timeout 60s ./zig-out/bin/zigpod-emulator \
  --firmware firmware/rockbox/bootloader-ipodvideo.ipod \
  firmware/rockbox/rockbox_disk.img 2>&1 | tee /tmp/test1.log
```

### 3.2 Analyze Results
Check the log for:
1. Does TIMER1_ENABLED message appear?
2. Does IRQ_VECTOR_INSTALLED message appear?
3. Does LCD_FIRST_WRITE message appear?
4. What is the final PC location?

### 3.3 Expected Outcomes

**Scenario A: Timer1 enabled, IRQ installed, but no LCD**
- Kernel init completes, but GUI thread never scheduled
- Need to investigate thread scheduling

**Scenario B: Timer1 NOT enabled**
- Kernel init incomplete
- Need to trace where it stalls

**Scenario C: Timer1 enabled, IRQ NOT installed**
- Interrupt setup failed
- Need to trace IRQ setup code

---

## Phase 4: Implement Targeted Fixes (1.5 hours)

Based on Phase 3 findings, implement ONE of these:

### Option A: If kernel init completes but GUI never runs

**Hypothesis**: Scheduler can't find runnable threads without COP

**Fix**: Fake thread ready status
- Find thread list in memory (look for thread control blocks)
- Mark main/GUI thread as runnable
- May need to understand Rockbox thread struct layout

### Option B: If kernel init stalls in sleep_core()

**Hypothesis**: Mailbox-based sleep_core() not fully bypassed

**Fix**: Make sleep_core() return immediately
- Trace PP502x sleep_core() implementation pattern
- Add PC-based skip at sleep_core() entry
- Or make CPU_CTL reads return AWAKE immediately after sleep write

### Option C: If IRQ handler not installed

**Hypothesis**: Skip mechanism prevents handler installation

**Fix**: Let kernel run longer before applying skips
- Add cycle count threshold before COP sync skips
- Allow kernel_init() to complete naturally with mailbox=0

### Option D: If Timer1 never enabled

**Hypothesis**: tick_start() never called

**Fix**: Force Timer1 enable after kernel entry
- Detect when main() is reached (PC = 0x03E804DC after MMAP)
- After N cycles, forcibly enable Timer1 via timer registers
- Install minimal IRQ handler that just acknowledges timer

---

## Phase 5: Verification (45 min)

### 5.1 Test with Timeout
```bash
timeout 120s ./zig-out/bin/zigpod-emulator \
  --firmware firmware/rockbox/bootloader-ipodvideo.ipod \
  firmware/rockbox/rockbox_disk.img 2>&1 | tee /tmp/test2.log
```

### 5.2 Check for LCD Output
- Look for LCD pixel write messages
- Check if lcd_output.ppm is generated
- Verify pixel count > 0

### 5.3 If Still No LCD
- Document findings
- Identify next blocking issue
- Provide clear explanation of what's preventing progress

---

## Files to Modify

| File | Changes |
|------|---------|
| `src/emulator/memory/bus.zig` | Remove cores_awake fix, keep MBX_MSG_STAT=0, add tracing |
| `src/emulator/peripherals/timers.zig` | Add TIMER1_CFG write tracing |
| `src/emulator/core.zig` | Add main() entry detection, IRQ vector tracing |
| `src/emulator/peripherals/lcd_controller.zig` | Add first-write tracing |

---

## Success Criteria

1. **Minimum**: Identify exactly where/why kernel init stalls
2. **Target**: Get Timer1 running and IRQ handler installed
3. **Ideal**: LCD pixel writes from Rockbox firmware (any output)

---

## Safety Rules

1. **NEVER run emulator in background without timeout**
   ```bash
   # CORRECT
   timeout 60s zig build emulator -- [args] 2>&1

   # WRONG - NEVER DO THIS
   zig build emulator -- [args] 2>&1 &
   ```

2. **Use controlled cycle counts for testing**
   - Default: 100 million cycles (~30 seconds)
   - Maximum: 500 million cycles (~2-3 minutes)

3. **Always check output size before reading**
   - Use `wc -l` or `head` first
   - Don't cat full logs

---

## Rockbox Source References

- `firmware/target/arm/pp/thread-pp.c:55-72` - core_thread_init()
- `firmware/target/arm/pp/thread-pp.c:159-278` - sleep_core() PP502x
- `firmware/target/arm/pp/kernel-pp.c:26-56` - Timer1 IRQ handler, tick_start()
- `firmware/export/pp5020.h` - Register definitions

---

## Appendix: Key Rockbox Code Snippets

### core_thread_init() - CPU/COP Coordination
```c
// firmware/target/arm/pp/thread-pp.c:55-72
static void INIT_ATTR core_thread_init(unsigned int core)
{
    if (core == CPU)
    {
        /* Wake up coprocessor and let it initialize kernel and threads */
#ifdef CPU_PP502x
        MBX_MSG_CLR = 0x3f;
#endif
        wake_core(COP);
        /* Sleep until COP has finished */
        sleep_core(CPU);
    }
    else
    {
        /* Wake the CPU and return */
        wake_core(CPU);
    }
}
```

### tick_start() - Timer1 Enable
```c
// firmware/target/arm/pp/kernel-pp.c:41-49
void tick_start(unsigned int interval_in_ms)
{
    TIMER1_CFG = 0x0;
    TIMER1_VAL;
    /* enable timer */
    TIMER1_CFG = 0xc0000000 | (interval_in_ms*1000 - 1);
    /* unmask interrupt source */
    CPU_INT_EN = TIMER1_MASK;
}
```

### Timer1 IRQ Handler
```c
// firmware/target/arm/pp/kernel-pp.c:26-38
void TIMER1(void)
{
    TIMER1_VAL; /* Read value to ack IRQ */
    call_tick_tasks();

#if NUM_CORES > 1
    /* Pulse the COP */
    core_wake(COP);
#endif
}
```
