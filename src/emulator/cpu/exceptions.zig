//! ARM7TDMI Exception Handling
//!
//! Implements exception entry and return for:
//! - Reset
//! - Undefined Instruction
//! - Software Interrupt (SWI)
//! - Prefetch Abort
//! - Data Abort
//! - IRQ
//! - FIQ
//!
//! Reference: ARM7TDMI Technical Reference Manual (ARM DDI 0029E) Section 5

const std = @import("std");
const registers = @import("registers.zig");
const Mode = registers.Mode;
const PSR = registers.PSR;
const RegisterFile = registers.RegisterFile;

/// Exception types
pub const Exception = enum(u3) {
    reset = 0,
    undefined = 1,
    swi = 2,
    prefetch_abort = 3,
    data_abort = 4,
    irq = 5,
    fiq = 6,

    /// Get the exception vector address
    pub fn vectorAddress(self: Exception) u32 {
        return switch (self) {
            .reset => 0x00000000,
            .undefined => 0x00000004,
            .swi => 0x00000008,
            .prefetch_abort => 0x0000000C,
            .data_abort => 0x00000010,
            // 0x00000014 is reserved
            .irq => 0x00000018,
            .fiq => 0x0000001C,
        };
    }

    /// Get the target mode for this exception
    pub fn targetMode(self: Exception) Mode {
        return switch (self) {
            .reset, .swi => .supervisor,
            .undefined => .undefined,
            .prefetch_abort, .data_abort => .abort,
            .irq => .irq,
            .fiq => .fiq,
        };
    }

    /// Get the priority (lower = higher priority)
    /// Used when multiple exceptions occur simultaneously
    pub fn priority(self: Exception) u3 {
        return switch (self) {
            .reset => 1,
            .data_abort => 2,
            .fiq => 3,
            .irq => 4,
            .prefetch_abort => 5,
            .swi, .undefined => 6,
        };
    }

    /// Calculate the return address offset
    /// This is subtracted from PC to get the actual return address
    pub fn returnOffset(self: Exception, is_thumb: bool) u32 {
        return switch (self) {
            .reset => 0,
            .undefined => if (is_thumb) 2 else 4,
            .swi => if (is_thumb) 2 else 4,
            .prefetch_abort => 4,
            .data_abort => 8,
            .irq => 4,
            .fiq => 4,
        };
    }
};

/// Enter an exception handler
/// Returns the number of cycles taken (typically 3)
pub fn enterException(regs: *RegisterFile, exception: Exception) u32 {
    const target_mode = exception.targetMode();

    // 1. Save current CPSR to target mode's SPSR
    const old_cpsr = @as(u32, @bitCast(regs.cpsr));

    // 2. Calculate return address and save to LR
    //    For most exceptions, LR = PC at time of exception
    //    The actual return address depends on exception type
    const pc = regs.r[15];
    const return_addr = pc -% exception.returnOffset(regs.cpsr.thumb);

    // 3. Switch to target mode (this does register banking)
    regs.switchMode(target_mode);

    // 4. Save CPSR to SPSR of new mode
    regs.setSpsr(old_cpsr);

    // 5. Set LR to return address
    regs.r[14] = return_addr;

    // 6. Disable interrupts as appropriate
    regs.cpsr.irq_disable = true;
    if (exception == .reset or exception == .fiq) {
        regs.cpsr.fiq_disable = true;
    }

    // 7. Switch to ARM state (exceptions always entered in ARM state)
    regs.cpsr.thumb = false;

    // 8. Set PC to exception vector
    regs.r[15] = exception.vectorAddress();

    // Exception entry takes 3 cycles
    return 3;
}

/// Return from exception
/// Restores CPSR from SPSR and returns to saved address
/// Call this when executing:
/// - MOVS PC, LR
/// - SUBS PC, LR, #offset
/// - LDM with PC and S bit
pub fn returnFromException(regs: *RegisterFile) void {
    // Get SPSR
    if (regs.getSpsr()) |spsr| {
        // Get return address from current LR
        const return_addr = regs.r[14];

        // Restore CPSR from SPSR (this also changes mode)
        const new_psr: PSR = @bitCast(spsr);
        if (new_psr.getMode()) |new_mode| {
            // Switch mode with banking
            regs.switchMode(new_mode);
        }

        // Fully restore CPSR
        regs.cpsr = new_psr;

        // Set PC to return address
        regs.set(15, return_addr);
    }
}

/// Check if an IRQ should be taken
pub fn shouldTakeIrq(regs: *const RegisterFile, irq_pending: bool) bool {
    return irq_pending and !regs.cpsr.irq_disable;
}

/// Check if an FIQ should be taken
pub fn shouldTakeFiq(regs: *const RegisterFile, fiq_pending: bool) bool {
    return fiq_pending and !regs.cpsr.fiq_disable;
}

// Tests
test "exception vector addresses" {
    try std.testing.expectEqual(@as(u32, 0x00), Exception.reset.vectorAddress());
    try std.testing.expectEqual(@as(u32, 0x04), Exception.undefined.vectorAddress());
    try std.testing.expectEqual(@as(u32, 0x08), Exception.swi.vectorAddress());
    try std.testing.expectEqual(@as(u32, 0x0C), Exception.prefetch_abort.vectorAddress());
    try std.testing.expectEqual(@as(u32, 0x10), Exception.data_abort.vectorAddress());
    try std.testing.expectEqual(@as(u32, 0x18), Exception.irq.vectorAddress());
    try std.testing.expectEqual(@as(u32, 0x1C), Exception.fiq.vectorAddress());
}

test "exception target modes" {
    try std.testing.expectEqual(Mode.supervisor, Exception.reset.targetMode());
    try std.testing.expectEqual(Mode.supervisor, Exception.swi.targetMode());
    try std.testing.expectEqual(Mode.undefined, Exception.undefined.targetMode());
    try std.testing.expectEqual(Mode.abort, Exception.prefetch_abort.targetMode());
    try std.testing.expectEqual(Mode.abort, Exception.data_abort.targetMode());
    try std.testing.expectEqual(Mode.irq, Exception.irq.targetMode());
    try std.testing.expectEqual(Mode.fiq, Exception.fiq.targetMode());
}

test "IRQ exception entry" {
    var regs = RegisterFile.init();

    // Set up initial state
    regs.cpsr.setMode(.user);
    regs.cpsr.irq_disable = false;
    regs.cpsr.thumb = false;
    regs.r[15] = 0x1000;

    // Enter IRQ
    const cycles = enterException(&regs, .irq);
    try std.testing.expectEqual(@as(u32, 3), cycles);

    // Should be in IRQ mode
    try std.testing.expectEqual(Mode.irq, regs.cpsr.getMode().?);

    // Should be at IRQ vector
    try std.testing.expectEqual(@as(u32, 0x18), regs.r[15]);

    // IRQ should be disabled
    try std.testing.expect(regs.cpsr.irq_disable);

    // Should be in ARM state
    try std.testing.expect(!regs.cpsr.thumb);

    // LR should contain return address
    try std.testing.expectEqual(@as(u32, 0x1000 - 4), regs.r[14]);
}

test "FIQ exception entry" {
    var regs = RegisterFile.init();

    regs.cpsr.setMode(.user);
    regs.cpsr.fiq_disable = false;
    regs.r[15] = 0x2000;

    _ = enterException(&regs, .fiq);

    // Should be in FIQ mode
    try std.testing.expectEqual(Mode.fiq, regs.cpsr.getMode().?);

    // Both IRQ and FIQ should be disabled
    try std.testing.expect(regs.cpsr.irq_disable);
    try std.testing.expect(regs.cpsr.fiq_disable);
}

test "exception from Thumb mode" {
    var regs = RegisterFile.init();

    regs.cpsr.setMode(.user);
    regs.cpsr.thumb = true;
    regs.r[15] = 0x1000;

    _ = enterException(&regs, .swi);

    // Should be in ARM state after exception
    try std.testing.expect(!regs.cpsr.thumb);

    // SPSR should have Thumb bit set
    const spsr = regs.getSpsr().?;
    const saved_psr: PSR = @bitCast(spsr);
    try std.testing.expect(saved_psr.thumb);
}
