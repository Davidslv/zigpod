//! ARM7TDMI Exception Handling
//!
//! Implements ARM exception vector processing for:
//! - Reset, Undefined Instruction, SWI, Prefetch Abort, Data Abort, IRQ, FIQ

const std = @import("std");
const registers = @import("registers.zig");

const RegisterFile = registers.RegisterFile;
const Psr = registers.Psr;
const Mode = registers.Mode;

/// ARM7TDMI exception types
pub const Exception = enum(u3) {
    reset = 0,
    undefined_instruction = 1,
    software_interrupt = 2,
    prefetch_abort = 3,
    data_abort = 4,
    // 5 is reserved
    irq = 6,
    fiq = 7,

    /// Get the exception vector address
    pub fn vectorAddress(self: Exception, base: u32) u32 {
        const offset: u32 = switch (self) {
            .reset => 0x00,
            .undefined_instruction => 0x04,
            .software_interrupt => 0x08,
            .prefetch_abort => 0x0C,
            .data_abort => 0x10,
            .irq => 0x18,
            .fiq => 0x1C,
        };
        return base + offset;
    }

    /// Get the processor mode to switch to for this exception
    pub fn targetMode(self: Exception) Mode {
        return switch (self) {
            .reset => .supervisor,
            .undefined_instruction => .undefined,
            .software_interrupt => .supervisor,
            .prefetch_abort => .abort,
            .data_abort => .abort,
            .irq => .irq,
            .fiq => .fiq,
        };
    }

    /// Get the LR offset for this exception (subtracted from PC)
    /// This is used to calculate the return address
    pub fn lrOffset(self: Exception) u32 {
        return switch (self) {
            .reset => 0, // N/A
            .undefined_instruction => 4, // Return to next instruction
            .software_interrupt => 4, // Return to next instruction
            .prefetch_abort => 4, // Return to faulting instruction
            .data_abort => 8, // Return to faulting instruction + 4
            .irq => 4, // Return to next instruction
            .fiq => 4, // Return to next instruction
        };
    }

    /// Check if this exception disables IRQ
    pub fn disablesIrq(self: Exception) bool {
        return switch (self) {
            .reset, .irq, .fiq, .data_abort, .prefetch_abort => true,
            .undefined_instruction, .software_interrupt => true,
        };
    }

    /// Check if this exception disables FIQ
    pub fn disablesFiq(self: Exception) bool {
        return switch (self) {
            .reset, .fiq => true,
            else => false,
        };
    }

    /// Get exception priority (lower = higher priority)
    pub fn priority(self: Exception) u3 {
        return switch (self) {
            .reset => 1,
            .data_abort => 2,
            .fiq => 3,
            .irq => 4,
            .prefetch_abort => 5,
            .software_interrupt => 6,
            .undefined_instruction => 6,
        };
    }
};

/// Exception handler context
pub const ExceptionHandler = struct {
    /// Vector table base address (0x00000000 or 0xFFFF0000 with high vectors)
    vector_base: u32 = 0x00000000,

    /// High vectors enabled (vector base at 0xFFFF0000)
    high_vectors: bool = false,

    /// Create with default settings
    pub fn init() ExceptionHandler {
        return .{};
    }

    /// Get the effective vector base address
    pub fn getVectorBase(self: *const ExceptionHandler) u32 {
        return if (self.high_vectors) 0xFFFF0000 else self.vector_base;
    }

    /// Process an exception - save state and prepare for handler
    /// Returns the new PC (vector address)
    pub fn raiseException(
        self: *const ExceptionHandler,
        regs: *RegisterFile,
        exception: Exception,
    ) u32 {
        const target_mode = exception.targetMode();
        const vector_addr = exception.vectorAddress(self.getVectorBase());

        // Save current CPSR to SPSR of new mode
        const saved_cpsr = regs.cpsr;

        // Switch to exception mode (this banks the registers)
        regs.switchMode(target_mode);

        // Save CPSR to SPSR
        regs.setSPSR(saved_cpsr);

        // Calculate return address and save to LR
        // PC points to current instruction + 8 in ARM mode
        // Use wrapping arithmetic to handle edge cases near address 0
        const pc = regs.getPC();
        const lr = (pc +% 4) -% exception.lrOffset();
        regs.setLR(lr);

        // Update CPSR
        regs.cpsr.thumb = false; // ARM state for exception handler

        if (exception.disablesIrq()) {
            regs.cpsr.irq_disable = true;
        }

        if (exception.disablesFiq()) {
            regs.cpsr.fiq_disable = true;
        }

        // Set PC to vector address
        regs.setPC(vector_addr);

        return vector_addr;
    }

    /// Return from exception using the data loaded to PC (with S bit in LDM)
    /// This restores CPSR from SPSR
    pub fn returnFromException(regs: *RegisterFile) void {
        // Restore CPSR from SPSR (mode switch happens automatically)
        if (regs.getSPSR()) |spsr| {
            const old_mode = regs.getMode();
            regs.cpsr = spsr;
            const new_mode = regs.cpsr.getMode() orelse .user;

            if (old_mode != new_mode) {
                // Bank switch back to original mode
                regs.switchMode(new_mode);
            }
        }
    }
};

/// Check if an IRQ should be taken
pub fn shouldTakeIrq(regs: *const RegisterFile, irq_pending: bool) bool {
    return irq_pending and regs.irqEnabled();
}

/// Check if an FIQ should be taken
pub fn shouldTakeFiq(regs: *const RegisterFile, fiq_pending: bool) bool {
    return fiq_pending and regs.fiqEnabled();
}

// ============================================================
// Tests
// ============================================================

test "exception vector addresses" {
    const base: u32 = 0;
    try std.testing.expectEqual(@as(u32, 0x00), Exception.reset.vectorAddress(base));
    try std.testing.expectEqual(@as(u32, 0x04), Exception.undefined_instruction.vectorAddress(base));
    try std.testing.expectEqual(@as(u32, 0x08), Exception.software_interrupt.vectorAddress(base));
    try std.testing.expectEqual(@as(u32, 0x0C), Exception.prefetch_abort.vectorAddress(base));
    try std.testing.expectEqual(@as(u32, 0x10), Exception.data_abort.vectorAddress(base));
    try std.testing.expectEqual(@as(u32, 0x18), Exception.irq.vectorAddress(base));
    try std.testing.expectEqual(@as(u32, 0x1C), Exception.fiq.vectorAddress(base));
}

test "exception target modes" {
    try std.testing.expectEqual(Mode.supervisor, Exception.reset.targetMode());
    try std.testing.expectEqual(Mode.undefined, Exception.undefined_instruction.targetMode());
    try std.testing.expectEqual(Mode.supervisor, Exception.software_interrupt.targetMode());
    try std.testing.expectEqual(Mode.abort, Exception.prefetch_abort.targetMode());
    try std.testing.expectEqual(Mode.abort, Exception.data_abort.targetMode());
    try std.testing.expectEqual(Mode.irq, Exception.irq.targetMode());
    try std.testing.expectEqual(Mode.fiq, Exception.fiq.targetMode());
}

test "raise IRQ exception" {
    var regs = RegisterFile.init();
    const handler = ExceptionHandler.init();

    // Start in User mode with IRQ and FIQ enabled
    regs.switchMode(.user);
    regs.cpsr.irq_disable = false;
    regs.cpsr.fiq_disable = false;
    regs.r[15] = 0x1000; // PC at some address

    const vector = handler.raiseException(&regs, .irq);

    // Should jump to IRQ vector
    try std.testing.expectEqual(@as(u32, 0x18), vector);
    try std.testing.expectEqual(@as(u32, 0x18), regs.r[15]);

    // Should be in IRQ mode
    try std.testing.expectEqual(Mode.irq, regs.getMode());

    // IRQ should now be disabled
    try std.testing.expect(regs.cpsr.irq_disable);

    // FIQ should NOT be disabled by IRQ
    try std.testing.expect(!regs.cpsr.fiq_disable);

    // Should be in ARM state
    try std.testing.expect(!regs.cpsr.thumb);
}

test "raise SWI exception" {
    var regs = RegisterFile.init();
    const handler = ExceptionHandler.init();

    regs.switchMode(.user);
    regs.r[15] = 0x2000;

    const vector = handler.raiseException(&regs, .software_interrupt);

    // Should jump to SWI vector
    try std.testing.expectEqual(@as(u32, 0x08), vector);

    // Should be in Supervisor mode
    try std.testing.expectEqual(Mode.supervisor, regs.getMode());

    // SPSR should contain original User mode CPSR
    const spsr = regs.getSPSR().?;
    try std.testing.expectEqual(Mode.user, spsr.getMode().?);
}

test "raise FIQ exception" {
    var regs = RegisterFile.init();
    const handler = ExceptionHandler.init();

    regs.switchMode(.user);
    regs.cpsr.fiq_disable = false;
    regs.r[15] = 0x3000;

    const vector = handler.raiseException(&regs, .fiq);

    // Should be in FIQ mode
    try std.testing.expectEqual(Mode.fiq, regs.getMode());
    try std.testing.expectEqual(@as(u32, 0x1C), vector);

    // Both IRQ and FIQ should be disabled
    try std.testing.expect(regs.cpsr.irq_disable);
    try std.testing.expect(regs.cpsr.fiq_disable);
}

test "high vectors" {
    var regs = RegisterFile.init();
    var handler = ExceptionHandler.init();
    handler.high_vectors = true;

    regs.switchMode(.user);
    regs.r[15] = 0x1000;

    const vector = handler.raiseException(&regs, .irq);

    // Should use high vector base
    try std.testing.expectEqual(@as(u32, 0xFFFF0018), vector);
}

test "exception priorities" {
    // Reset has highest priority
    try std.testing.expect(Exception.reset.priority() < Exception.data_abort.priority());
    try std.testing.expect(Exception.data_abort.priority() < Exception.fiq.priority());
    try std.testing.expect(Exception.fiq.priority() < Exception.irq.priority());
}

test "IRQ check" {
    var regs = RegisterFile.init();

    // IRQ disabled
    regs.cpsr.irq_disable = true;
    try std.testing.expect(!shouldTakeIrq(&regs, true));

    // IRQ enabled
    regs.cpsr.irq_disable = false;
    try std.testing.expect(shouldTakeIrq(&regs, true));

    // No pending IRQ
    try std.testing.expect(!shouldTakeIrq(&regs, false));
}
