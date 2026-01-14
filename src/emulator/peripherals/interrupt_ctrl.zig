//! PP5021C Interrupt Controller
//!
//! Implements the interrupt controller for the PP5021C SoC.
//!
//! Reference: Rockbox firmware/export/pp5020.h
//!
//! Registers (base 0x60004000):
//! - 0x000: CPU_INT_STAT - CPU interrupt status (pending & enabled)
//! - 0x004: COP_INT_STAT - COP interrupt status
//! - 0x008: CPU_FIQ_STAT - CPU FIQ status
//! - 0x00C: COP_FIQ_STAT - COP FIQ status
//! - 0x010: INT_STAT - Raw interrupt status (all pending)
//! - 0x014: INT_FORCED_STAT - Forced interrupt status
//! - 0x018: INT_FORCED_SET - Set forced interrupt (write 1 to force)
//! - 0x01C: INT_FORCED_CLR - Clear forced interrupt (write 1 to clear)
//! - 0x020: CPU_INT_EN_STAT - CPU enable status (read-only)
//! - 0x024: CPU_INT_EN - Enable CPU interrupts (write 1 to enable)
//! - 0x028: CPU_INT_DIS - Disable CPU interrupts (write 1 to disable)
//! - 0x02C: CPU_INT_PRIORITY - CPU priority configuration
//! - 0x030: COP_INT_EN_STAT - COP enable status (read-only)
//! - 0x034: COP_INT_EN - Enable COP interrupts (write 1 to enable)
//! - 0x038: COP_INT_DIS - Disable COP interrupts (write 1 to disable)
//! - 0x03C: COP_INT_PRIORITY - COP priority configuration
//!
//! High priority interrupt registers at offset 0x100:
//! - 0x100: CPU_HI_INT_STAT
//! - 0x104: CPU_HI_INT_EN
//! - 0x108: CPU_HI_INT_CLR

const std = @import("std");
const bus = @import("../memory/bus.zig");

/// Interrupt sources (bit positions)
pub const Interrupt = enum(u5) {
    timer1 = 0,
    timer2 = 1,
    // 2-3 reserved
    mailbox = 4,
    // 5-9 reserved
    i2s = 10,
    // 11 reserved
    serial0 = 12, // Click wheel / keypad serial
    serial1 = 13,
    i2c = 14,
    // 15-22 reserved
    ide = 23,
    // 24-25 reserved
    dma = 26,
    // 27-29 reserved
    hi_irq = 30, // High priority interrupt pending

    pub fn mask(self: Interrupt) u32 {
        return @as(u32, 1) << @intFromEnum(self);
    }
};

/// Interrupt Controller state
pub const InterruptController = struct {
    /// Raw interrupt status (all pending interrupts from peripherals)
    raw_status: u32,

    /// Forced interrupt status (software-triggered)
    forced_status: u32,

    /// CPU interrupt enable mask
    cpu_enable: u32,

    /// COP interrupt enable mask
    cop_enable: u32,

    /// Protected interrupt mask - these interrupts cannot be disabled by firmware writes
    /// Used by emulator to keep Timer1 enabled for RTOS scheduler kickstart
    protected_mask: u32,

    /// Debug: count Timer1 fires
    debug_timer1_fires: u32,

    /// CPU FIQ enable mask
    cpu_fiq_enable: u32,

    /// COP FIQ enable mask
    cop_fiq_enable: u32,

    /// CPU priority configuration
    cpu_priority: u32,

    /// COP priority configuration
    cop_priority: u32,

    /// High priority status
    hi_status: u32,

    /// High priority enable
    hi_enable: u32,

    /// Callback to update CPU IRQ/FIQ lines
    irq_callback: ?*const fn (bool) void,
    fiq_callback: ?*const fn (bool) void,

    const Self = @This();

    /// Register offsets (from base 0x60004000)
    const REG_CPU_INT_STAT: u32 = 0x000;
    const REG_COP_INT_STAT: u32 = 0x004;
    const REG_CPU_FIQ_STAT: u32 = 0x008;
    const REG_COP_FIQ_STAT: u32 = 0x00C;
    const REG_INT_STAT: u32 = 0x010;
    const REG_INT_FORCED_STAT: u32 = 0x014;
    const REG_INT_FORCED_SET: u32 = 0x018;
    const REG_INT_FORCED_CLR: u32 = 0x01C;
    const REG_CPU_INT_EN_STAT: u32 = 0x020;
    const REG_CPU_INT_EN: u32 = 0x024;
    const REG_CPU_INT_DIS: u32 = 0x028;
    const REG_CPU_INT_PRIORITY: u32 = 0x02C;
    const REG_COP_INT_EN_STAT: u32 = 0x030;
    const REG_COP_INT_EN: u32 = 0x034;
    const REG_COP_INT_DIS: u32 = 0x038;
    const REG_COP_INT_PRIORITY: u32 = 0x03C;
    const REG_CPU_FIQ_EN: u32 = 0x040;
    const REG_COP_FIQ_EN: u32 = 0x044;
    const REG_CPU_HI_INT_STAT: u32 = 0x100;
    const REG_CPU_HI_INT_EN: u32 = 0x104;
    const REG_CPU_HI_INT_CLR: u32 = 0x108;

    pub fn init() Self {
        return .{
            .raw_status = 0,
            .forced_status = 0,
            .cpu_enable = 0,
            .cop_enable = 0,
            .protected_mask = 0,
            .debug_timer1_fires = 0,
            .cpu_fiq_enable = 0,
            .cop_fiq_enable = 0,
            .cpu_priority = 0,
            .cop_priority = 0,
            .hi_status = 0,
            .hi_enable = 0,
            .irq_callback = null,
            .fiq_callback = null,
        };
    }

    // Legacy accessors for compatibility
    pub fn getStatus(self: *const Self) u32 {
        return self.raw_status | self.forced_status;
    }

    pub fn getEnable(self: *const Self) u32 {
        return self.cpu_enable;
    }

    /// Set IRQ line callback
    pub fn setIrqCallback(self: *Self, callback: *const fn (bool) void) void {
        self.irq_callback = callback;
    }

    /// Set FIQ line callback
    pub fn setFiqCallback(self: *Self, callback: *const fn (bool) void) void {
        self.fiq_callback = callback;
    }

    /// Assert an interrupt from a peripheral
    pub fn assertInterrupt(self: *Self, irq: Interrupt) void {
        self.raw_status |= irq.mask();
        self.updateLines();
    }

    /// Force-enable a CPU interrupt (used for RTOS kickstart)
    pub fn forceEnableCpuInterrupt(self: *Self, irq: Interrupt) void {
        self.cpu_enable |= irq.mask();
        self.updateLines();
    }

    /// Protect an interrupt from being disabled by firmware writes
    /// Protected interrupts stay enabled even when firmware writes to CPU_INT_DIS
    pub fn protectInterrupt(self: *Self, irq: Interrupt) void {
        self.protected_mask |= irq.mask();
    }

    /// Clear an interrupt (usually called by peripheral when acknowledged)
    pub fn clearInterrupt(self: *Self, irq: Interrupt) void {
        self.raw_status &= ~irq.mask();
        self.updateLines();
    }

    /// Assert a high-priority interrupt
    pub fn assertHiInterrupt(self: *Self, bit: u5) void {
        self.hi_status |= @as(u32, 1) << bit;
        // Also set the HI_IRQ bit in main status
        self.raw_status |= Interrupt.hi_irq.mask();
        self.updateLines();
    }

    /// Clear a high-priority interrupt
    pub fn clearHiInterrupt(self: *Self, bit: u5) void {
        self.hi_status &= ~(@as(u32, 1) << bit);
        if (self.hi_status == 0) {
            self.raw_status &= ~Interrupt.hi_irq.mask();
        }
        self.updateLines();
    }

    /// Update CPU IRQ/FIQ lines based on current state
    fn updateLines(self: *Self) void {
        // Combined status includes raw (peripheral) and forced (software) interrupts
        const status = self.raw_status | self.forced_status;

        // Calculate CPU pending interrupts
        const cpu_pending = status & self.cpu_enable;
        const hi_pending = self.hi_status & self.hi_enable;

        // Separate CPU FIQ and IRQ
        const cpu_fiq_pending = cpu_pending & self.cpu_fiq_enable;
        const cpu_irq_pending = (cpu_pending & ~self.cpu_fiq_enable) | (if (hi_pending != 0) Interrupt.hi_irq.mask() else @as(u32, 0));

        // Notify CPU
        if (self.irq_callback) |callback| {
            callback(cpu_irq_pending != 0);
        }
        if (self.fiq_callback) |callback| {
            callback(cpu_fiq_pending != 0);
        }
    }

    /// Check if any CPU interrupt is pending
    pub fn hasPendingIrq(self: *const Self) bool {
        const status = self.raw_status | self.forced_status;
        const pending = status & self.cpu_enable & ~self.cpu_fiq_enable;
        return pending != 0;
    }

    /// Check if CPU FIQ is pending
    pub fn hasPendingFiq(self: *const Self) bool {
        const status = self.raw_status | self.forced_status;
        const pending = status & self.cpu_enable & self.cpu_fiq_enable;
        return pending != 0;
    }

    /// Check if any COP interrupt is pending
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

    /// Get highest priority pending interrupt
    pub fn getHighestPending(self: *const Self) ?Interrupt {
        const status = self.raw_status | self.forced_status;
        const pending = status & self.cpu_enable;
        if (pending == 0) return null;

        // Find lowest set bit (highest priority)
        const bit: u5 = @intCast(@ctz(pending));
        return @enumFromInt(bit);
    }

    /// Read register
    pub fn read(self: *const Self, offset: u32) u32 {
        const status = self.raw_status | self.forced_status;
        return switch (offset) {
            // CPU status registers
            REG_CPU_INT_STAT => status & self.cpu_enable & ~self.cpu_fiq_enable,
            REG_COP_INT_STAT => status & self.cop_enable & ~self.cop_fiq_enable,
            REG_CPU_FIQ_STAT => status & self.cpu_enable & self.cpu_fiq_enable,
            REG_COP_FIQ_STAT => status & self.cop_enable & self.cop_fiq_enable,

            // Raw/forced status
            REG_INT_STAT => status,
            REG_INT_FORCED_STAT => self.forced_status,
            REG_INT_FORCED_SET => 0, // Write-only
            REG_INT_FORCED_CLR => 0, // Write-only

            // CPU enable/priority
            REG_CPU_INT_EN_STAT => self.cpu_enable,
            REG_CPU_INT_EN => 0, // Write-only
            REG_CPU_INT_DIS => 0, // Write-only
            REG_CPU_INT_PRIORITY => self.cpu_priority,

            // COP enable/priority
            REG_COP_INT_EN_STAT => self.cop_enable,
            REG_COP_INT_EN => 0, // Write-only
            REG_COP_INT_DIS => 0, // Write-only
            REG_COP_INT_PRIORITY => self.cop_priority,

            // FIQ enables
            REG_CPU_FIQ_EN => self.cpu_fiq_enable,
            REG_COP_FIQ_EN => self.cop_fiq_enable,

            // High priority
            REG_CPU_HI_INT_STAT => self.hi_status,
            REG_CPU_HI_INT_EN => self.hi_enable,
            REG_CPU_HI_INT_CLR => 0, // Write-only

            else => 0,
        };
    }

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        switch (offset) {
            // CPU status - writing clears raw status bits (write 1 to clear)
            REG_CPU_INT_STAT => {
                self.raw_status &= ~value;
                self.updateLines();
            },
            REG_COP_INT_STAT => {
                self.raw_status &= ~value;
                self.updateLines();
            },

            // Forced interrupt control
            REG_INT_FORCED_SET => {
                self.forced_status |= value;
                self.updateLines();
            },
            REG_INT_FORCED_CLR => {
                self.forced_status &= ~value;
                self.updateLines();
            },

            // CPU enable/disable
            REG_CPU_INT_EN => {
                std.debug.print("CPU_INT_EN: enabling 0x{X:0>8} (was 0x{X:0>8})\n", .{ value, self.cpu_enable });
                self.cpu_enable |= value;
                self.updateLines();
            },
            REG_CPU_INT_DIS => {
                // Respect protected mask - don't disable protected interrupts
                const actual_disable = value & ~self.protected_mask;
                if (self.protected_mask != 0 and (value & self.protected_mask) != 0) {
                    std.debug.print("CPU_INT_DIS: disabling 0x{X:0>8} (was 0x{X:0>8}), protected=0x{X:0>8}, actual=0x{X:0>8}\n", .{ value, self.cpu_enable, self.protected_mask, actual_disable });
                } else {
                    std.debug.print("CPU_INT_DIS: disabling 0x{X:0>8} (was 0x{X:0>8})\n", .{ value, self.cpu_enable });
                }
                self.cpu_enable &= ~actual_disable;
                self.updateLines();
            },
            REG_CPU_INT_PRIORITY => {
                self.cpu_priority = value;
            },

            // COP enable/disable
            REG_COP_INT_EN => {
                self.cop_enable |= value;
                self.updateLines();
            },
            REG_COP_INT_DIS => {
                self.cop_enable &= ~value;
                self.updateLines();
            },
            REG_COP_INT_PRIORITY => {
                self.cop_priority = value;
            },

            // FIQ enables
            REG_CPU_FIQ_EN => {
                self.cpu_fiq_enable = value;
                self.updateLines();
            },
            REG_COP_FIQ_EN => {
                self.cop_fiq_enable = value;
                self.updateLines();
            },

            // High priority
            REG_CPU_HI_INT_STAT => {
                self.hi_status &= ~value;
                self.updateLines();
            },
            REG_CPU_HI_INT_EN => {
                self.hi_enable |= value;
                self.updateLines();
            },
            REG_CPU_HI_INT_CLR => {
                self.hi_enable &= ~value;
                self.updateLines();
            },

            else => {},
        }
    }

    /// Create a peripheral handler for the memory bus
    pub fn createHandler(self: *Self) bus.PeripheralHandler {
        return .{
            .context = @ptrCast(self),
            .readFn = readWrapper,
            .writeFn = writeWrapper,
        };
    }

    fn readWrapper(ctx: *anyopaque, offset: u32) u32 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.read(offset);
    }

    fn writeWrapper(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write(offset, value);
    }
};

// Tests
test "interrupt enable/disable" {
    var ctrl = InterruptController.init();

    // Enable timer1 interrupt
    ctrl.write(InterruptController.REG_CPU_INT_EN, Interrupt.timer1.mask());
    try std.testing.expectEqual(Interrupt.timer1.mask(), ctrl.cpu_enable);

    // Disable timer1 interrupt
    ctrl.write(InterruptController.REG_CPU_INT_DIS, Interrupt.timer1.mask());
    try std.testing.expectEqual(@as(u32, 0), ctrl.cpu_enable);
}

test "interrupt assertion" {
    var ctrl = InterruptController.init();

    // Enable and assert timer1
    ctrl.cpu_enable = Interrupt.timer1.mask();
    ctrl.assertInterrupt(.timer1);

    try std.testing.expect(ctrl.hasPendingIrq());
    try std.testing.expectEqual(Interrupt.timer1, ctrl.getHighestPending().?);

    // Clear the interrupt
    ctrl.clearInterrupt(.timer1);
    try std.testing.expect(!ctrl.hasPendingIrq());
}

test "interrupt priority" {
    var ctrl = InterruptController.init();

    // Enable multiple interrupts
    ctrl.cpu_enable = Interrupt.timer1.mask() | Interrupt.timer2.mask() | Interrupt.i2s.mask();

    // Assert all three
    ctrl.assertInterrupt(.timer1);
    ctrl.assertInterrupt(.timer2);
    ctrl.assertInterrupt(.i2s);

    // Lowest bit (timer1) should be highest priority
    try std.testing.expectEqual(Interrupt.timer1, ctrl.getHighestPending().?);
}

test "forced interrupt" {
    var ctrl = InterruptController.init();

    // Enable timer1 interrupt
    ctrl.cpu_enable = Interrupt.timer1.mask();

    // Force the interrupt via software
    ctrl.write(InterruptController.REG_INT_FORCED_SET, Interrupt.timer1.mask());
    try std.testing.expect(ctrl.hasPendingIrq());

    // Clear the forced interrupt
    ctrl.write(InterruptController.REG_INT_FORCED_CLR, Interrupt.timer1.mask());
    try std.testing.expect(!ctrl.hasPendingIrq());
}
