//! PP5021C Interrupt Controller Simulation
//!
//! Simulates the PP5021C dual-core interrupt controller.
//! Each CPU (main CPU and COP) has its own interrupt registers.

const std = @import("std");

/// Interrupt source identifiers (matches PP5021C hardware)
pub const InterruptSource = enum(u5) {
    timer1 = 0,
    timer2 = 1,
    mailbox = 2,
    // 3 reserved
    i2s = 4,
    usb = 5,
    ide = 6,
    firewire = 7,
    dma = 8,
    gpio0 = 9,
    gpio1 = 10,
    gpio2 = 11,
    ser0 = 12,
    ser1 = 13,
    i2c = 14,
    // Higher interrupts (15-31)
    lcd = 15,
    clickwheel = 16,

    /// Get the bit mask for this interrupt
    pub fn mask(self: InterruptSource) u32 {
        return @as(u32, 1) << @intFromEnum(self);
    }
};

/// Interrupt priority levels
pub const InterruptPriority = enum(u2) {
    low = 0,
    medium = 1,
    high = 2,
    critical = 3,
};

/// Per-CPU interrupt state
pub const CpuInterruptState = struct {
    /// Interrupt status (pending interrupts)
    status: u32 = 0,
    /// Interrupt enable mask
    enable: u32 = 0,
    /// High-priority interrupt status
    hi_status: u32 = 0,
    /// High-priority interrupt enable
    hi_enable: u32 = 0,
    /// Interrupt priority settings
    priority: u32 = 0,

    const Self = @This();

    /// Check if any enabled interrupt is pending
    pub fn hasPending(self: *const Self) bool {
        return (self.status & self.enable) != 0 or (self.hi_status & self.hi_enable) != 0;
    }

    /// Get highest priority pending interrupt
    pub fn getHighestPending(self: *const Self) ?InterruptSource {
        // Check high-priority interrupts first
        const hi_pending = self.hi_status & self.hi_enable;
        if (hi_pending != 0) {
            const bit = @ctz(hi_pending);
            if (bit < 32) {
                return @enumFromInt(bit);
            }
        }

        // Check normal interrupts
        const pending = self.status & self.enable;
        if (pending != 0) {
            const bit = @ctz(pending);
            if (bit < 32) {
                return @enumFromInt(bit);
            }
        }

        return null;
    }

    /// Raise an interrupt
    pub fn raise(self: *Self, src: InterruptSource) void {
        self.status |= src.mask();
    }

    /// Clear an interrupt
    pub fn clear(self: *Self, src: InterruptSource) void {
        self.status &= ~src.mask();
    }

    /// Enable an interrupt
    pub fn enableInt(self: *Self, src: InterruptSource) void {
        self.enable |= src.mask();
    }

    /// Disable an interrupt
    pub fn disableInt(self: *Self, src: InterruptSource) void {
        self.enable &= ~src.mask();
    }

    /// Check if specific interrupt is pending and enabled
    pub fn isPending(self: *const Self, src: InterruptSource) bool {
        const m = src.mask();
        return (self.status & self.enable & m) != 0;
    }
};

/// Interrupt callback function type
pub const InterruptHandler = *const fn (source: InterruptSource, context: ?*anyopaque) void;

/// Registered interrupt handler
const RegisteredHandler = struct {
    handler: InterruptHandler,
    context: ?*anyopaque,
};

/// PP5021C Interrupt Controller
pub const InterruptController = struct {
    /// CPU interrupt state
    cpu: CpuInterruptState = .{},
    /// COP interrupt state
    cop: CpuInterruptState = .{},

    /// Registered handlers
    handlers: [32]?RegisteredHandler = [_]?RegisteredHandler{null} ** 32,

    /// Global interrupt enable (master switch)
    global_enable: bool = false,

    /// FIQ enable
    fiq_enable: bool = false,

    /// Pending FIQ sources
    fiq_pending: u32 = 0,

    /// FIQ enable mask
    fiq_mask: u32 = 0,

    const Self = @This();

    /// Create a new interrupt controller
    pub fn init() Self {
        return .{};
    }

    /// Reset the controller to initial state
    pub fn reset(self: *Self) void {
        self.cpu = .{};
        self.cop = .{};
        self.global_enable = false;
        self.fiq_enable = false;
        self.fiq_pending = 0;
        self.fiq_mask = 0;
    }

    /// Register an interrupt handler
    pub fn registerHandler(self: *Self, src: InterruptSource, handler: InterruptHandler, context: ?*anyopaque) void {
        const idx = @intFromEnum(src);
        if (idx < 32) {
            self.handlers[idx] = .{
                .handler = handler,
                .context = context,
            };
        }
    }

    /// Unregister an interrupt handler
    pub fn unregisterHandler(self: *Self, src: InterruptSource) void {
        const idx = @intFromEnum(src);
        if (idx < 32) {
            self.handlers[idx] = null;
        }
    }

    /// Raise an interrupt (CPU)
    pub fn raiseInterrupt(self: *Self, src: InterruptSource) void {
        self.cpu.raise(src);
    }

    /// Raise an interrupt for COP
    pub fn raiseInterruptCop(self: *Self, src: InterruptSource) void {
        self.cop.raise(src);
    }

    /// Raise a FIQ interrupt
    pub fn raiseFiq(self: *Self, src: InterruptSource) void {
        self.fiq_pending |= src.mask();
    }

    /// Clear an interrupt
    pub fn clearInterrupt(self: *Self, src: InterruptSource) void {
        self.cpu.clear(src);
        self.cop.clear(src);
    }

    /// Clear FIQ
    pub fn clearFiq(self: *Self, src: InterruptSource) void {
        self.fiq_pending &= ~src.mask();
    }

    /// Acknowledge and get pending CPU IRQ
    pub fn acknowledgeIrq(self: *Self) ?InterruptSource {
        return self.cpu.getHighestPending();
    }

    /// Acknowledge and get pending FIQ
    pub fn acknowledgeFiq(self: *Self) ?InterruptSource {
        const pending = self.fiq_pending & self.fiq_mask;
        if (pending != 0) {
            const bit = @ctz(pending);
            if (bit < 32) {
                return @enumFromInt(bit);
            }
        }
        return null;
    }

    /// Check if CPU has pending IRQ
    pub fn hasPendingIrq(self: *const Self) bool {
        return self.global_enable and self.cpu.hasPending();
    }

    /// Check if FIQ is pending
    pub fn hasPendingFiq(self: *const Self) bool {
        return self.fiq_enable and (self.fiq_pending & self.fiq_mask) != 0;
    }

    /// Enable global interrupts
    pub fn enableGlobal(self: *Self) void {
        self.global_enable = true;
    }

    /// Disable global interrupts
    pub fn disableGlobal(self: *Self) void {
        self.global_enable = false;
    }

    /// Enable FIQ
    pub fn enableFiq(self: *Self) void {
        self.fiq_enable = true;
    }

    /// Disable FIQ
    pub fn disableFiq(self: *Self) void {
        self.fiq_enable = false;
    }

    /// Process pending interrupts (call handlers)
    pub fn processPending(self: *Self) u32 {
        var count: u32 = 0;

        // Process CPU IRQs - iterate through known interrupt sources
        const pending = self.cpu.status & self.cpu.enable;

        inline for (@typeInfo(InterruptSource).@"enum".fields) |field| {
            const idx = field.value;
            const m = @as(u32, 1) << idx;
            if ((pending & m) != 0) {
                if (self.handlers[idx]) |h| {
                    h.handler(@enumFromInt(idx), h.context);
                    count += 1;
                }
            }
        }

        return count;
    }

    // --------------------------------------------------------
    // Memory-mapped register access (for simulator integration)
    // --------------------------------------------------------

    /// Read CPU interrupt status
    pub fn readCpuIntStat(self: *const Self) u32 {
        return self.cpu.status;
    }

    /// Write CPU interrupt status (clear bits)
    pub fn writeCpuIntClr(self: *Self, value: u32) void {
        self.cpu.status &= ~value;
    }

    /// Read CPU interrupt enable
    pub fn readCpuIntEn(self: *const Self) u32 {
        return self.cpu.enable;
    }

    /// Write CPU interrupt enable
    pub fn writeCpuIntEn(self: *Self, value: u32) void {
        self.cpu.enable = value;
    }

    /// Read COP interrupt status
    pub fn readCopIntStat(self: *const Self) u32 {
        return self.cop.status;
    }

    /// Write COP interrupt clear
    pub fn writeCopIntClr(self: *Self, value: u32) void {
        self.cop.status &= ~value;
    }

    /// Read COP interrupt enable
    pub fn readCopIntEn(self: *const Self) u32 {
        return self.cop.enable;
    }

    /// Write COP interrupt enable
    pub fn writeCopIntEn(self: *Self, value: u32) void {
        self.cop.enable = value;
    }
};

// ============================================================
// Tests
// ============================================================

test "interrupt source masks" {
    try std.testing.expectEqual(@as(u32, 0x01), InterruptSource.timer1.mask());
    try std.testing.expectEqual(@as(u32, 0x02), InterruptSource.timer2.mask());
    try std.testing.expectEqual(@as(u32, 0x40), InterruptSource.ide.mask());
    try std.testing.expectEqual(@as(u32, 0x4000), InterruptSource.i2c.mask());
}

test "cpu interrupt state" {
    var state = CpuInterruptState{};

    // Initially no pending
    try std.testing.expect(!state.hasPending());

    // Raise without enable - still no pending
    state.raise(.timer1);
    try std.testing.expect(!state.hasPending());

    // Enable - now pending
    state.enableInt(.timer1);
    try std.testing.expect(state.hasPending());
    try std.testing.expect(state.isPending(.timer1));

    // Get highest pending
    const pending = state.getHighestPending();
    try std.testing.expect(pending != null);
    try std.testing.expectEqual(InterruptSource.timer1, pending.?);

    // Clear
    state.clear(.timer1);
    try std.testing.expect(!state.hasPending());
}

test "interrupt controller basic" {
    var ic = InterruptController.init();

    // Enable global interrupts
    ic.enableGlobal();

    // Raise timer1 interrupt
    ic.raiseInterrupt(.timer1);

    // Not pending until enabled
    try std.testing.expect(!ic.hasPendingIrq());

    // Enable timer1
    ic.cpu.enableInt(.timer1);
    try std.testing.expect(ic.hasPendingIrq());

    // Acknowledge
    const ack = ic.acknowledgeIrq();
    try std.testing.expect(ack != null);
    try std.testing.expectEqual(InterruptSource.timer1, ack.?);

    // Clear
    ic.clearInterrupt(.timer1);
    try std.testing.expect(!ic.hasPendingIrq());
}

test "multiple interrupts priority" {
    var ic = InterruptController.init();
    ic.enableGlobal();

    // Enable multiple interrupts
    ic.cpu.enableInt(.timer1);
    ic.cpu.enableInt(.ide);
    ic.cpu.enableInt(.i2c);

    // Raise them in reverse order
    ic.raiseInterrupt(.i2c); // bit 14
    ic.raiseInterrupt(.ide); // bit 6
    ic.raiseInterrupt(.timer1); // bit 0

    // Should get lowest bit first (timer1)
    const first = ic.acknowledgeIrq();
    try std.testing.expectEqual(InterruptSource.timer1, first.?);
}

test "fiq handling" {
    var ic = InterruptController.init();
    ic.enableFiq();
    ic.fiq_mask = InterruptSource.timer2.mask();

    // Raise FIQ
    ic.raiseFiq(.timer2);
    try std.testing.expect(ic.hasPendingFiq());

    const fiq = ic.acknowledgeFiq();
    try std.testing.expectEqual(InterruptSource.timer2, fiq.?);

    // Clear
    ic.clearFiq(.timer2);
    try std.testing.expect(!ic.hasPendingFiq());
}

test "handler registration" {
    var ic = InterruptController.init();

    const Context = struct {
        called: bool = false,
    };

    var ctx = Context{};

    const handler = struct {
        fn callback(_: InterruptSource, opaque_ctx: ?*anyopaque) void {
            if (opaque_ctx) |c| {
                const context: *Context = @ptrCast(@alignCast(c));
                context.called = true;
            }
        }
    }.callback;

    ic.registerHandler(.timer1, handler, &ctx);
    ic.raiseInterrupt(.timer1);
    ic.cpu.enableInt(.timer1);

    const count = ic.processPending();
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expect(ctx.called);
}

test "memory mapped register access" {
    var ic = InterruptController.init();

    // Write enable
    ic.writeCpuIntEn(0xFF);
    try std.testing.expectEqual(@as(u32, 0xFF), ic.readCpuIntEn());

    // Raise interrupt
    ic.raiseInterrupt(.ide);
    try std.testing.expectEqual(@as(u32, 0x40), ic.readCpuIntStat() & 0x40);

    // Clear
    ic.writeCpuIntClr(0x40);
    try std.testing.expectEqual(@as(u32, 0), ic.readCpuIntStat() & 0x40);
}

test "reset controller" {
    var ic = InterruptController.init();

    ic.enableGlobal();
    ic.cpu.enableInt(.timer1);
    ic.raiseInterrupt(.timer1);

    ic.reset();

    try std.testing.expect(!ic.global_enable);
    try std.testing.expectEqual(@as(u32, 0), ic.cpu.status);
    try std.testing.expectEqual(@as(u32, 0), ic.cpu.enable);
}
