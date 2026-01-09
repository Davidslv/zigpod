//! PP5021C Interrupt Controller
//!
//! This module provides low-level interrupt controller access for the PP5021C SoC.
//! It complements the kernel-level interrupt handling in boot.zig and kernel/interrupts.zig
//! by providing:
//! - Direct register access for interrupt control
//! - FIQ configuration for time-critical audio
//! - Priority management
//! - Interrupt statistics
//!
//! The exception vector table and IRQ entry points are handled by kernel/boot.zig.
//!
//! Interrupt sources are mapped to specific bits in CPU_INT_STAT:
//! - Bit 0: Timer 1
//! - Bit 1: Timer 2
//! - Bit 2: Mailbox (IPC)
//! - Bit 4: I2S (audio)
//! - Bit 5: USB
//! - Bit 6: IDE/ATA
//! - Bit 8: DMA
//! - Bit 9-11: GPIO groups
//! - Bit 14: I2C

const std = @import("std");
const reg = @import("registers.zig");

// ============================================================
// Interrupt Source Definitions
// ============================================================

/// Interrupt source identifiers
pub const IrqSource = enum(u5) {
    timer1 = 0,
    timer2 = 1,
    mailbox = 2,
    // Bit 3 reserved
    i2s = 4,
    usb = 5,
    ide = 6,
    firewire = 7,
    dma = 8,
    gpio0 = 9,
    gpio1 = 10,
    gpio2 = 11,
    serial0 = 12,
    serial1 = 13,
    i2c = 14,

    pub fn toBit(self: IrqSource) u32 {
        return @as(u32, 1) << @intFromEnum(self);
    }
};

// ============================================================
// Statistics
// ============================================================

/// Interrupt statistics
var irq_total_count: u32 = 0;
var fiq_total_count: u32 = 0;
var source_counts: [32]u32 = [_]u32{0} ** 32;

/// Critical section nesting counter
var critical_section_depth: u32 = 0;

/// Saved interrupt state for critical sections
var saved_irq_state: bool = false;

// ============================================================
// Interrupt Controller Access
// ============================================================

/// Initialize the interrupt controller
/// Called by HAL system_init - clears all pending and disables all sources
pub fn init() void {
    // Disable global interrupts during setup
    disableIrq();
    disableFiq();

    // Clear all pending interrupts
    reg.writeReg(u32, reg.CPU_INT_CLR, 0xFFFFFFFF);
    reg.writeReg(u32, reg.CPU_HI_INT_CLR, 0xFFFFFFFF);

    // Disable all interrupt sources
    reg.writeReg(u32, reg.CPU_INT_EN, 0);
    reg.writeReg(u32, reg.CPU_HI_INT_EN, 0);

    // Clear FIQ routing (all IRQ, no FIQ)
    reg.writeReg(u32, reg.CPU_INT_PRIO, 0);

    // Reset statistics
    irq_total_count = 0;
    fiq_total_count = 0;
    for (&source_counts) |*count| {
        count.* = 0;
    }

    critical_section_depth = 0;
}

/// Enable an interrupt source at the controller
pub fn enableSource(source: IrqSource) void {
    reg.modifyReg(reg.CPU_INT_EN, 0, source.toBit());
}

/// Disable an interrupt source at the controller
pub fn disableSource(source: IrqSource) void {
    reg.modifyReg(reg.CPU_INT_EN, source.toBit(), 0);
}

/// Clear a pending interrupt
pub fn clearPending(source: IrqSource) void {
    reg.writeReg(u32, reg.CPU_INT_CLR, source.toBit());
}

/// Check if an interrupt is pending
pub fn isPending(source: IrqSource) bool {
    const stat = reg.readReg(u32, reg.CPU_INT_STAT);
    return (stat & source.toBit()) != 0;
}

/// Get all pending interrupt bits
pub fn getPending() u32 {
    return reg.readReg(u32, reg.CPU_INT_STAT);
}

/// Clear multiple pending interrupts
pub fn clearPendingMask(mask: u32) void {
    reg.writeReg(u32, reg.CPU_INT_CLR, mask);
}

// ============================================================
// Global Interrupt Control
// ============================================================

/// Enable global IRQ
pub fn enableIrq() void {
    asm volatile ("cpsie i");
}

/// Disable global IRQ
pub fn disableIrq() void {
    asm volatile ("cpsid i");
}

/// Check if IRQ is enabled
pub fn isIrqEnabled() bool {
    var cpsr: u32 = undefined;
    asm volatile ("mrs %[cpsr], cpsr"
        : [cpsr] "=r" (cpsr),
    );
    return (cpsr & 0x80) == 0; // I bit is 0 when enabled
}

/// Enable global FIQ
pub fn enableFiq() void {
    asm volatile ("cpsie f");
}

/// Disable global FIQ
pub fn disableFiq() void {
    asm volatile ("cpsid f");
}

/// Check if FIQ is enabled
pub fn isFiqEnabled() bool {
    var cpsr: u32 = undefined;
    asm volatile ("mrs %[cpsr], cpsr"
        : [cpsr] "=r" (cpsr),
    );
    return (cpsr & 0x40) == 0; // F bit is 0 when enabled
}

// ============================================================
// FIQ Configuration (for Audio)
// ============================================================

/// Route an interrupt source to FIQ (for low-latency handling)
/// On PP5021C, setting a bit in CPU_INT_PRIO routes that IRQ to FIQ
pub fn routeToFiq(source: IrqSource) void {
    const current = reg.readReg(u32, reg.CPU_INT_PRIO);
    reg.writeReg(u32, reg.CPU_INT_PRIO, current | source.toBit());
}

/// Route an interrupt source back to IRQ
pub fn routeToIrq(source: IrqSource) void {
    const current = reg.readReg(u32, reg.CPU_INT_PRIO);
    reg.writeReg(u32, reg.CPU_INT_PRIO, current & ~source.toBit());
}

/// Configure FIQ for I2S audio with DMA
/// This sets up the highest priority interrupt path for audio
pub fn configureAudioFiq() void {
    // Route I2S and DMA to FIQ for lowest latency
    routeToFiq(.i2s);
    routeToFiq(.dma);

    // Enable I2S and DMA interrupts at the controller
    enableSource(.i2s);
    enableSource(.dma);
}

/// Enable audio interrupts (call after DMA is configured)
pub fn enableAudioInterrupts() void {
    enableFiq();
}

/// Disable audio interrupts
pub fn disableAudioInterrupts() void {
    disableFiq();
}

// ============================================================
// Critical Sections
// ============================================================

/// Enter critical section (disable IRQ and save state)
pub fn enterCritical() void {
    const was_enabled = isIrqEnabled();

    disableIrq();

    if (critical_section_depth == 0) {
        saved_irq_state = was_enabled;
    }
    critical_section_depth += 1;
}

/// Exit critical section (restore IRQ state)
pub fn exitCritical() void {
    if (critical_section_depth > 0) {
        critical_section_depth -= 1;

        if (critical_section_depth == 0 and saved_irq_state) {
            enableIrq();
        }
    }
}

/// Execute a function with interrupts disabled
pub fn withInterruptsDisabled(comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
    enterCritical();
    defer exitCritical();
    return @call(.auto, func, args);
}

// ============================================================
// Statistics and Debugging
// ============================================================

/// Increment IRQ count (called from IRQ handler)
pub fn recordIrq() void {
    irq_total_count += 1;
}

/// Increment FIQ count (called from FIQ handler)
pub fn recordFiq() void {
    fiq_total_count += 1;
}

/// Record a specific source was handled
pub fn recordSource(source: IrqSource) void {
    const idx = @intFromEnum(source);
    if (idx < 32) {
        source_counts[idx] += 1;
    }
}

/// Get interrupt statistics
pub fn getStats() struct {
    irq_count: u32,
    fiq_count: u32,
    source_counts: [32]u32,
} {
    return .{
        .irq_count = irq_total_count,
        .fiq_count = fiq_total_count,
        .source_counts = source_counts,
    };
}

/// Get trigger count for a specific IRQ source
pub fn getSourceCount(source: IrqSource) u32 {
    const idx = @intFromEnum(source);
    if (idx < 32) {
        return source_counts[idx];
    }
    return 0;
}

/// Reset all statistics
pub fn resetStats() void {
    irq_total_count = 0;
    fiq_total_count = 0;
    for (&source_counts) |*count| {
        count.* = 0;
    }
}

// ============================================================
// Tests (run on host, not hardware)
// ============================================================

test "IrqSource bit conversion" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 1 << 0), IrqSource.timer1.toBit());
    try testing.expectEqual(@as(u32, 1 << 4), IrqSource.i2s.toBit());
    try testing.expectEqual(@as(u32, 1 << 8), IrqSource.dma.toBit());
}

test "critical section nesting" {
    const testing = std.testing;

    // Reset state
    critical_section_depth = 0;

    // Enter nested critical sections
    enterCritical();
    try testing.expectEqual(@as(u32, 1), critical_section_depth);

    enterCritical();
    try testing.expectEqual(@as(u32, 2), critical_section_depth);

    // Exit critical sections
    exitCritical();
    try testing.expectEqual(@as(u32, 1), critical_section_depth);

    exitCritical();
    try testing.expectEqual(@as(u32, 0), critical_section_depth);
}

test "statistics recording" {
    const testing = std.testing;

    // Reset
    resetStats();

    // Record some interrupts
    recordIrq();
    recordIrq();
    recordFiq();
    recordSource(.timer1);
    recordSource(.i2s);
    recordSource(.i2s);

    const stats = getStats();
    try testing.expectEqual(@as(u32, 2), stats.irq_count);
    try testing.expectEqual(@as(u32, 1), stats.fiq_count);
    try testing.expectEqual(@as(u32, 1), getSourceCount(.timer1));
    try testing.expectEqual(@as(u32, 2), getSourceCount(.i2s));
}
