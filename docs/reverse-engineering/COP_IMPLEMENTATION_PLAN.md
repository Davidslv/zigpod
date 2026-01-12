# COP (Coprocessor) Implementation Plan

## Overview

The PP5021C SoC has a dual-core ARM7TDMI architecture:
- **CPU**: Main processor (PROC_ID = 0x55)
- **COP**: Coprocessor (PROC_ID = 0xAA)

Apple firmware requires both cores running to function correctly. The RTOS scheduler uses the COP for background tasks, and the firmware hangs if COP tasks never become ready.

## Current State

### What Exists
- `cop: ?Arm7tdmi` field in `Emulator` struct
- `cop_ctl: u32` register in `SystemController`
- `isCopSleeping()` and `wakeCop()` methods
- Basic COP stepping in main loop (but incomplete)

### What's Missing
1. Proper COP sleep/wake state machine
2. Mailbox inter-processor communication
3. Per-core interrupt enable handling
4. COP entry point initialization
5. hw_accel task queue integration

## Architecture

### PP5021C Dual-Core Registers

| Register | Address | Purpose |
|----------|---------|---------|
| PROC_ID | 0x60000000 | Returns 0x55 (CPU) or 0xAA (COP) |
| CPU_CTL | 0x60007000 | CPU sleep/wake control |
| COP_CTL | 0x60007004 | COP sleep/wake control |
| CPU_QUEUE | 0x60001010 | CPU mailbox |
| COP_QUEUE | 0x60001020 | COP mailbox |

### COP_CTL Register Bits

```
Bit 31 (0x80000000): PROC_SLEEP
  - 1 = Core is sleeping/WFI state
  - 0 = Core is awake/running

Bit 9 (0x200): Ready/acknowledged flag
  - Set by COP when it acknowledges a command
```

### Mailbox Protocol

From Rockbox source (`firmware/target/arm/crt0-pp.S`):

```
CPU wake sequence:
  1. CPU writes to COP_CTL to clear sleep bit
  2. CPU writes to COP_QUEUE with bit 29 set (0x20000000)
  3. COP wakes and reads COP_QUEUE
  4. COP clears bit 29 by writing back

COP sleep sequence:
  1. COP sets PROC_SLEEP bit in COP_CTL
  2. COP writes to CPU_QUEUE with bit 29 set
  3. COP enters WFI state
  4. CPU reads CPU_QUEUE and sees bit 29
```

## Implementation Plan

### Phase 1: COP State Machine

Create proper COP state tracking in `system_ctrl.zig`:

```zig
pub const CopState = enum {
    disabled,      // COP not enabled via DEV_EN
    sleeping,      // COP sleeping (PROC_SLEEP bit set)
    waking,        // Wake request pending
    running,       // COP executing instructions
    halted,        // COP halted (crash/debug)
};

// In SystemController:
cop_state: CopState = .disabled,
```

### Phase 2: Register Semantics

Update `system_ctrl.zig` to handle COP_CTL properly:

```zig
// Write to COP_CTL
REG_COP_CTL => {
    const old = self.cop_ctl;
    self.cop_ctl = value;

    // Check for wake request (clearing PROC_SLEEP)
    if ((old & 0x80000000) != 0 and (value & 0x80000000) == 0) {
        self.cop_state = .waking;
    }

    // Check for sleep request (setting PROC_SLEEP)
    if ((old & 0x80000000) == 0 and (value & 0x80000000) != 0) {
        self.cop_state = .sleeping;
    }
},
```

### Phase 3: Mailbox Implementation

Add mailbox registers to `bus.zig`:

```zig
// At 0x60001000:
const REG_CPU_QUEUE: u32 = 0x10;   // 0x60001010
const REG_COP_QUEUE: u32 = 0x20;   // 0x60001020

cpu_queue: u32 = 0,
cop_queue: u32 = 0,

// Mailbox semantics:
// Bit 29 (0x20000000) = wake/acknowledge signal
```

### Phase 4: COP Stepping Logic

Update `core.zig` step function:

```zig
pub fn step(self: *Self) u32 {
    var cpu_bus = self.createCpuBus();

    // Update CPU IRQ/FIQ
    self.cpu.setIrqLine(self.int_ctrl.hasPendingIrq());
    self.cpu.setFiqLine(self.int_ctrl.hasPendingFiq());

    // Execute CPU
    const cycles = self.cpu.step(&cpu_bus);
    self.total_cycles += cycles;

    // Execute COP if enabled and not sleeping
    if (self.cop) |*cop| {
        switch (self.sys_ctrl.cop_state) {
            .running => {
                // Set COP PROC_ID for memory accesses
                self.bus.setCopAccess(true);

                // Check COP-specific interrupts
                cop.setIrqLine(self.int_ctrl.hasCopPendingIrq());
                cop.setFiqLine(self.int_ctrl.hasCopPendingFiq());

                _ = cop.step(&cpu_bus);
                self.bus.setCopAccess(false);
            },
            .waking => {
                // Transition to running
                self.sys_ctrl.cop_state = .running;
            },
            .sleeping, .disabled, .halted => {
                // COP does not execute
            },
        }
    }

    self.timer.tick(cycles);
    return cycles;
}
```

### Phase 5: Interrupt Controller Updates

Add COP-specific interrupt checking to `interrupt_ctrl.zig`:

```zig
/// Check if COP IRQ is pending
pub fn hasCopPendingIrq(self: *const Self) bool {
    const status = self.raw_status | self.forced_status;
    const pending = status & self.cop_enable & ~self.cop_fiq_enable;
    return pending != 0;
}

/// Check if COP FIQ is pending
pub fn hasCopPendingFiq(self: *const Self) bool {
    const status = self.raw_status | self.forced_status;
    const pending = status & self.cop_enable & self.cop_fiq_enable;
    return pending != 0;
}
```

### Phase 6: COP Entry Point

From Rockbox analysis, COP starts at a different entry point or needs initialization:

1. Apple firmware: COP may start at same entry as CPU or at designated COP vector
2. Need to reverse engineer actual COP entry from firmware

Typical pattern:
```zig
// COP init (in core.zig)
pub fn initCop(self: *Self, entry_point: u32) void {
    if (self.cop) |*cop| {
        cop.reset();
        cop.setReg(15, entry_point);
        self.sys_ctrl.cop_state = .sleeping; // Start sleeping
    }
}
```

## Testing Plan

### Unit Tests

1. COP state transitions (disabled -> sleeping -> waking -> running)
2. Mailbox read/write with wake signaling
3. Per-core interrupt enable/disable
4. PROC_ID returns correct value for each core

### Integration Tests

1. Simple dual-core program that communicates via mailbox
2. Timer interrupt handled by both cores
3. RTOS scheduler can wake COP for tasks

### Validation

1. Run Apple firmware with COP enabled
2. Monitor COP_CTL register changes
3. Check if RTOS tasks become ready
4. Verify firmware progresses past init loop

## Files to Modify

1. `src/emulator/peripherals/system_ctrl.zig`
   - Add CopState enum
   - Implement full COP_CTL semantics
   - Add CPU_CTL semantics

2. `src/emulator/memory/bus.zig`
   - Add mailbox registers (CPU_QUEUE, COP_QUEUE)
   - Implement mailbox read/write with signaling

3. `src/emulator/peripherals/interrupt_ctrl.zig`
   - Add hasCopPendingIrq(), hasCopPendingFiq()

4. `src/emulator/core.zig`
   - Update step() for proper COP state handling
   - Add initCop() for COP entry point setup

5. `src/emulator/main.zig`
   - Enable COP by default for Apple firmware
   - Add COP initialization

## References

- Rockbox: `firmware/target/arm/crt0-pp.S` - Boot code with COP init
- Rockbox: `firmware/target/arm/pp/system-pp502x.c` - core_sleep/wake
- Apple firmware strings: "COP has crashed - (0x%X)"
- PP5020 datasheet (limited public info)
