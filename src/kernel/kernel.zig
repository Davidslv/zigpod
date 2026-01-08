//! ZigPod Kernel
//!
//! This module provides the core kernel functionality for ZigPod OS,
//! including memory management, interrupt handling, and timing services.

pub const boot = @import("boot.zig");
pub const memory = @import("memory.zig");
pub const interrupts = @import("interrupts.zig");
pub const timer = @import("timer.zig");
pub const dma = @import("dma.zig");

// Re-export commonly used types
pub const CriticalSection = interrupts.CriticalSection;
pub const MemoryStats = memory.MemoryStats;

// ============================================================
// Tests
// ============================================================

test {
    _ = boot;
    _ = memory;
    _ = interrupts;
    _ = timer;
    _ = dma;
}
