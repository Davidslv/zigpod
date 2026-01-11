//! PP5021C Interrupt Controller
//!
//! Implements the interrupt controller for the PP5021C SoC.
//!
//! Reference: Rockbox firmware/export/pp5020.h
//!
//! Registers (base 0x60004000):
//! - 0x000: CPU_INT_STAT - Interrupt status (read)
//! - 0x024: CPU_INT_EN - Enable interrupts (write 1 to enable)
//! - 0x028: CPU_INT_CLR - Disable interrupts (write 1 to disable, also called CPU_INT_DIS)
//! - 0x02C: CPU_INT_PRIORITY - Priority configuration
//!
//! High priority interrupt registers at offset 0x100:
//! - 0x100: CPU_HI_INT_STAT
//! - 0x104: CPU_HI_INT_EN
//! - 0x108: CPU_HI_INT_CLR
//!
//! COP (second core) registers at offset 0x100xx (CPU) and 0x200xx (COP)

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
    // 11-22 reserved
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
    /// Interrupt status (pending interrupts)
    status: u32,

    /// Interrupt enable mask
    enable: u32,

    /// High priority status
    hi_status: u32,

    /// High priority enable
    hi_enable: u32,

    /// Priority configuration
    priority: u32,

    /// FIQ configuration (which interrupts are FIQ vs IRQ)
    fiq_enable: u32,

    /// Callback to update CPU IRQ/FIQ lines
    irq_callback: ?*const fn (bool) void,
    fiq_callback: ?*const fn (bool) void,

    const Self = @This();

    /// Register offsets
    const REG_CPU_INT_STAT: u32 = 0x000;
    const REG_CPU_INT_EN: u32 = 0x024;
    const REG_CPU_INT_CLR: u32 = 0x028;
    const REG_CPU_INT_PRIORITY: u32 = 0x02C;
    const REG_CPU_HI_INT_STAT: u32 = 0x100;
    const REG_CPU_HI_INT_EN: u32 = 0x104;
    const REG_CPU_HI_INT_CLR: u32 = 0x108;
    const REG_CPU_FIQ_EN: u32 = 0x040;

    pub fn init() Self {
        return .{
            .status = 0,
            .enable = 0,
            .hi_status = 0,
            .hi_enable = 0,
            .priority = 0,
            .fiq_enable = 0,
            .irq_callback = null,
            .fiq_callback = null,
        };
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
        self.status |= irq.mask();
        self.updateLines();
    }

    /// Clear an interrupt (usually called by peripheral when acknowledged)
    pub fn clearInterrupt(self: *Self, irq: Interrupt) void {
        self.status &= ~irq.mask();
        self.updateLines();
    }

    /// Assert a high-priority interrupt
    pub fn assertHiInterrupt(self: *Self, bit: u5) void {
        self.hi_status |= @as(u32, 1) << bit;
        // Also set the HI_IRQ bit in main status
        self.status |= Interrupt.hi_irq.mask();
        self.updateLines();
    }

    /// Clear a high-priority interrupt
    pub fn clearHiInterrupt(self: *Self, bit: u5) void {
        self.hi_status &= ~(@as(u32, 1) << bit);
        if (self.hi_status == 0) {
            self.status &= ~Interrupt.hi_irq.mask();
        }
        self.updateLines();
    }

    /// Update CPU IRQ/FIQ lines based on current state
    fn updateLines(self: *Self) void {
        // Calculate pending interrupts
        const pending = self.status & self.enable;
        const hi_pending = self.hi_status & self.hi_enable;

        // Separate FIQ and IRQ
        const fiq_pending = pending & self.fiq_enable;
        const irq_pending = (pending & ~self.fiq_enable) | (if (hi_pending != 0) Interrupt.hi_irq.mask() else @as(u32, 0));

        // Notify CPU
        if (self.irq_callback) |callback| {
            callback(irq_pending != 0);
        }
        if (self.fiq_callback) |callback| {
            callback(fiq_pending != 0);
        }
    }

    /// Check if any interrupt is pending
    pub fn hasPendingIrq(self: *const Self) bool {
        const pending = self.status & self.enable & ~self.fiq_enable;
        return pending != 0;
    }

    /// Check if FIQ is pending
    pub fn hasPendingFiq(self: *const Self) bool {
        const pending = self.status & self.enable & self.fiq_enable;
        return pending != 0;
    }

    /// Get highest priority pending interrupt
    pub fn getHighestPending(self: *const Self) ?Interrupt {
        const pending = self.status & self.enable;
        if (pending == 0) return null;

        // Find lowest set bit (highest priority)
        const bit: u5 = @intCast(@ctz(pending));
        return @enumFromInt(bit);
    }

    /// Read register
    pub fn read(self: *const Self, offset: u32) u32 {
        return switch (offset) {
            REG_CPU_INT_STAT => self.status,
            REG_CPU_INT_EN => self.enable,
            REG_CPU_INT_CLR => 0, // Write-only
            REG_CPU_INT_PRIORITY => self.priority,
            REG_CPU_HI_INT_STAT => self.hi_status,
            REG_CPU_HI_INT_EN => self.hi_enable,
            REG_CPU_HI_INT_CLR => 0, // Write-only
            REG_CPU_FIQ_EN => self.fiq_enable,
            else => 0,
        };
    }

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        switch (offset) {
            REG_CPU_INT_STAT => {
                // Writing to status clears bits (write 1 to clear)
                self.status &= ~value;
                self.updateLines();
            },
            REG_CPU_INT_EN => {
                // Write 1 to enable
                self.enable |= value;
                self.updateLines();
            },
            REG_CPU_INT_CLR => {
                // Write 1 to disable
                self.enable &= ~value;
                self.updateLines();
            },
            REG_CPU_INT_PRIORITY => {
                self.priority = value;
            },
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
            REG_CPU_FIQ_EN => {
                self.fiq_enable = value;
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
    try std.testing.expectEqual(Interrupt.timer1.mask(), ctrl.enable);

    // Disable timer1 interrupt
    ctrl.write(InterruptController.REG_CPU_INT_CLR, Interrupt.timer1.mask());
    try std.testing.expectEqual(@as(u32, 0), ctrl.enable);
}

test "interrupt assertion" {
    var ctrl = InterruptController.init();

    // Enable and assert timer1
    ctrl.enable = Interrupt.timer1.mask();
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
    ctrl.enable = Interrupt.timer1.mask() | Interrupt.timer2.mask() | Interrupt.i2s.mask();

    // Assert all three
    ctrl.assertInterrupt(.timer1);
    ctrl.assertInterrupt(.timer2);
    ctrl.assertInterrupt(.i2s);

    // Lowest bit (timer1) should be highest priority
    try std.testing.expectEqual(Interrupt.timer1, ctrl.getHighestPending().?);
}
