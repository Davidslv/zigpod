# RTOS Scheduler Investigation - Handoff Note

**Date**: 2026-01-14
**Status**: IN PROGRESS - Timer1 fires but scheduler tick not invoked
**Priority**: HIGH

## Current State Summary

The Rockbox bootloader successfully loads rockbox.ipod from disk and displays "Rockbox loaded." on the LCD. However, after jumping to the Rockbox firmware, the CPU gets stuck in an idle loop with **zero LCD writes** because the RTOS scheduler never runs.

### What's Working

| Component | Status | Notes |
|-----------|--------|-------|
| Rockbox bootloader | ✅ | Displays UI, loads files from FAT32 |
| FAT32 filesystem | ✅ | Reads rockbox.ipod correctly |
| Timer1 interrupt | ✅ | Fires after kickstart (raw_status=0x00800001) |
| IRQ handling | ✅ | CPU enters IRQ mode when Timer1 fires |
| MMAP remapping | ✅ | 0x00xxxxxx → 0x10xxxxxx translation works |

### What's NOT Working

| Component | Status | Notes |
|-----------|--------|-------|
| Scheduler tick | ❌ | IRQ handler at vector is garbage (0x84813004) |
| Thread creation | ❌ | Kernel init incomplete |
| LCD pixel writes | ❌ | Still 0 after "Rockbox loaded." |
| COP synchronization | ⚠️ | Faked but may be causing kernel init issues |

## Technical Details

### The Problem: Chicken-and-Egg

```
┌─────────────────────────────────────────────────────────┐
│ 1. CPU reaches wake_core (0x769C) during kernel init    │
│ 2. wake_core polls COP_CTL waiting for COP to respond   │
│ 3. COP never responds (not emulated)                    │
│ 4. We skip wake_core to break the infinite loop         │
│ 5. But this skips kernel_init() which sets up:          │
│    - IRQ handlers                                       │
│    - Thread list                                        │
│    - Timer1 tick function                               │
│ 6. Without these, Timer1 interrupts don't help          │
└─────────────────────────────────────────────────────────┘
```

### Key Addresses

| Address | Function | Notes |
|---------|----------|-------|
| 0x769C | wake_core entry | Infinite COP poll loop |
| 0x76C4-0x76DC | Idle loop | WFI equivalent, waits for IRQ |
| 0x40000018 | IRQ vector | Contains 0x84813004 (garbage) |
| 0x60007004 | COP_CTL | PROC_SLEEP bit checked here |
| 0x60001000 | MBX_MSG_STAT | CPU/COP mailbox |

### Current Workarounds

1. **COP_WAKE_SKIP** (`core.zig`): Skip wake_core at entry, jump to idle loop
2. **Timer1 Kickstart** (`core.zig`): After 10000 idle iterations, enable Timer1
3. **Mailbox Fake COP** (`bus.zig`): Auto-clear COP wake bit after 10 reads
4. **COP_CTL PROC_SLEEP** (`system_ctrl.zig`): Always return bit 31 = 1

## Files Modified This Session

| File | Changes |
|------|---------|
| `src/emulator/memory/bus.zig` | Added mailbox registers, fake COP responses |
| `src/emulator/core.zig` | Timer1 kickstart, COP_WAKE_SKIP with IRQ enable |
| `src/emulator/peripherals/system_ctrl.zig` | COP_CTL read tracing |
| `docs/reverse-engineering/RE_JOURNAL.md` | Documented findings |

## Recommended Next Steps

### Option A - Let Kernel Initialize (Recommended)

The cleanest solution is to let the kernel complete initialization before skipping wake_core:

1. **Remove early wake_core skip**: Don't skip at 0x769C entry
2. **Make COP_CTL return "awake"**: After ~1000 reads, return bit 31 = 0
3. **Track kernel progress**: Watch for specific kernel init milestones
4. **Enable wake skip later**: Only skip wake_core AFTER kernel installs IRQ handlers

**How to detect kernel init complete**:
- Watch for write to 0x40000018 (IRQ vector installation)
- Or watch for Timer1 enable by firmware
- Or track cycle count after specific address reached

### Option B - Install Custom IRQ Handler

Write a minimal IRQ handler that calls the Rockbox scheduler:

```arm
; Minimal IRQ handler at 0x40000018
push {r0-r3, r12, lr}
ldr r0, =0x60005010     ; Timer1 value register
mov r1, #0
str r1, [r0]            ; Acknowledge Timer1
ldr r0, =timer1_tick    ; Address TBD from disassembly
blx r0                  ; Call scheduler tick
pop {r0-r3, r12, lr}
subs pc, lr, #4         ; Return from IRQ
```

Requires finding `timer1_tick()` address in Rockbox binary (~750KB).

### Option C - Direct Thread Start

Bypass the scheduler entirely:
1. Find main thread entry point (likely `main_menu()` or similar)
2. Set up minimal stack/context
3. Force PC to that address

## Commands to Test

```bash
# Build
zig build -p zig-out

# Run with Rockbox bootloader + disk
./zig-out/bin/zigpod-emulator \
  --firmware firmware/rockbox-bootloader.bin \
  --headless --debug --cycles 300000000 \
  rockbox_disk.img 2>&1 | tee /tmp/rockbox.log

# Check for Timer1 fires
grep "TIMER1_FIRE" /tmp/rockbox.log

# Check for IRQ mode
grep "Mode=" /tmp/rockbox.log | grep "0x12"

# Check LCD output
./zig-out/bin/zigpod-emulator ... --sdl2  # If SDL2 build available
```

## Reference Documents

- `docs/reverse-engineering/RE_JOURNAL.md` - Full investigation history
- `docs/reverse-engineering/RTOS_SCHEDULER_INVESTIGATION.md` - Earlier scheduler analysis
- Rockbox source: `firmware/kernel.c`, `firmware/crt0-pp.S`

## Success Criteria

1. LCD shows Rockbox main menu (not just bootloader)
2. Pixel write count > 0 after "Rockbox loaded."
3. Timer1 tick function actually invoked (not just IRQ taken)
4. No infinite loops after boot

## If You Get Stuck

1. Check RE_JOURNAL.md section "2026-01-14: Fake COP Responses and Timer1 Kickstart"
2. The key insight is: kernel init installs IRQ handlers, but we skip kernel init
3. Either let kernel init complete, or install handlers manually
