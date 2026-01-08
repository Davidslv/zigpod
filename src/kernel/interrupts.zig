//! Interrupt Handling
//!
//! This module manages interrupt registration and dispatch for ZigPod OS.

const std = @import("std");
const hal = @import("../hal/hal.zig");

// ============================================================
// Interrupt Sources
// ============================================================

pub const Interrupt = enum(u8) {
    timer1 = 0,
    timer2 = 1,
    mailbox = 2,
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
};

// ============================================================
// Interrupt Handler Registration
// ============================================================

pub const Handler = *const fn () void;

/// Interrupt handler table - accessible for dispatch from boot.zig
pub var handlers: [32]?Handler = [_]?Handler{null} ** 32;
var enabled_mask: u32 = 0;

/// Register an interrupt handler
pub fn register(irq: Interrupt, handler: Handler) void {
    handlers[@intFromEnum(irq)] = handler;
    hal.current_hal.irq_register(@intFromEnum(irq), handler);
}

/// Unregister an interrupt handler
pub fn unregister(irq: Interrupt) void {
    handlers[@intFromEnum(irq)] = null;
}

/// Enable a specific interrupt
pub fn enable(irq: Interrupt) void {
    enabled_mask |= @as(u32, 1) << @as(u5, @truncate(@intFromEnum(irq)));
}

/// Disable a specific interrupt
pub fn disable(irq: Interrupt) void {
    enabled_mask &= ~(@as(u32, 1) << @as(u5, @truncate(@intFromEnum(irq))));
}

/// Enable global interrupts
pub fn enableGlobal() void {
    hal.current_hal.irq_enable();
}

/// Disable global interrupts
pub fn disableGlobal() void {
    hal.current_hal.irq_disable();
}

/// Check if global interrupts are enabled
pub fn globalEnabled() bool {
    return hal.current_hal.irq_enabled();
}

// ============================================================
// Critical Sections
// ============================================================

/// RAII guard for disabling interrupts
pub const CriticalSection = struct {
    was_enabled: bool,

    pub fn enter() CriticalSection {
        const was = globalEnabled();
        disableGlobal();
        return .{ .was_enabled = was };
    }

    pub fn leave(self: CriticalSection) void {
        if (self.was_enabled) {
            enableGlobal();
        }
    }
};

/// Execute a function with interrupts disabled
pub fn withInterruptsDisabled(comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
    const section = CriticalSection.enter();
    defer section.leave();
    return @call(.auto, func, args);
}

// ============================================================
// Tests
// ============================================================

test "interrupt registration" {
    const handler = struct {
        fn handle() void {
            // Test handler does nothing
        }
    }.handle;

    register(.timer1, handler);
    try std.testing.expect(handlers[0] != null);

    unregister(.timer1);
    try std.testing.expect(handlers[0] == null);
}

test "interrupt enable/disable" {
    enable(.timer1);
    try std.testing.expect((enabled_mask & 1) != 0);

    disable(.timer1);
    try std.testing.expect((enabled_mask & 1) == 0);
}
