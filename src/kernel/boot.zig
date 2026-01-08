//! Kernel Boot and Initialization
//!
//! This module handles the early boot process, including:
//! - Vector table setup
//! - Stack initialization
//! - BSS clearing
//! - Hardware initialization
//! - Jump to main application

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("../hal/hal.zig");

// ============================================================
// Architecture Detection
// ============================================================

const is_arm = builtin.cpu.arch == .arm;

// ============================================================
// External Symbols from Linker (ARM only)
// ============================================================

// These symbols are only defined when linking for ARM target
const extern_symbols = if (is_arm) struct {
    extern var __bss_start: u8;
    extern var __bss_end: u8;
    extern var __stack_top: u8;
    extern var __irq_stack_top: u8;
    extern var __fiq_stack_top: u8;
    extern var __data_start: u8;
    extern var __data_end: u8;
    extern var __iram_start: u8;
    extern var __iram_end: u8;
    extern const __iram_load: u8;
} else struct {};

// ============================================================
// Boot State
// ============================================================

pub const BootState = enum {
    uninitialized,
    bss_cleared,
    stacks_initialized,
    hardware_initialized,
    running,
    shutdown,
};

var boot_state: BootState = .uninitialized;

pub fn getBootState() BootState {
    return boot_state;
}

pub fn setBootState(state: BootState) void {
    boot_state = state;
}

// ============================================================
// Vector Table (ARM7TDMI)
// ============================================================

/// ARM exception vector table
/// Must be placed at address 0x00000000 or remapped via cache controller
pub const VectorTable = extern struct {
    reset: u32, // 0x00: Reset
    undefined: u32, // 0x04: Undefined instruction
    swi: u32, // 0x08: Software interrupt
    prefetch_abort: u32, // 0x0C: Prefetch abort
    data_abort: u32, // 0x10: Data abort
    reserved: u32, // 0x14: Reserved
    irq: u32, // 0x18: IRQ
    fiq: u32, // 0x1C: FIQ
};

/// Generate ARM branch instruction to target address
pub fn armBranch(from: usize, to: usize) u32 {
    const to_i64: i64 = @intCast(to);
    const from_i64: i64 = @intCast(from);
    const offset = @as(i32, @intCast(to_i64 - from_i64 - 8)) >> 2;
    const masked_offset = @as(u32, @bitCast(offset)) & 0x00FFFFFF;
    return 0xEA000000 | masked_offset;
}

// ============================================================
// ARM Exception Handlers (only compiled for ARM target)
// ============================================================

// These are only defined for ARM targets - they contain ARM assembly
// and use naked calling convention which has strict requirements

comptime {
    if (is_arm) {
        // Export the ARM-specific entry points
        @export(&_start_arm, .{ .name = "_start" });
        @export(&undefinedHandler_arm, .{ .name = "undefinedHandler" });
        @export(&swiHandler_arm, .{ .name = "swiHandler" });
        @export(&prefetchAbortHandler_arm, .{ .name = "prefetchAbortHandler" });
        @export(&dataAbortHandler_arm, .{ .name = "dataAbortHandler" });
        @export(&irqHandler_arm, .{ .name = "irqHandler" });
        @export(&fiqHandler_arm, .{ .name = "fiqHandler" });
    }
}

fn _start_arm() callconv(.naked) noreturn {
    // Disable interrupts, set up stack, and jump to init
    asm volatile (
        \\cpsid if
        \\ldr sp, =__stack_top
        \\bl kernelInit
    );
    unreachable;
}

fn undefinedHandler_arm() callconv(.naked) noreturn {
    asm volatile (
        \\1: wfi
        \\b 1b
    );
    unreachable;
}

fn swiHandler_arm() callconv(.naked) void {
    asm volatile ("movs pc, lr");
}

fn prefetchAbortHandler_arm() callconv(.naked) noreturn {
    asm volatile (
        \\1: wfi
        \\b 1b
    );
    unreachable;
}

fn dataAbortHandler_arm() callconv(.naked) noreturn {
    asm volatile (
        \\1: wfi
        \\b 1b
    );
    unreachable;
}

fn irqHandler_arm() callconv(.naked) void {
    asm volatile (
        \\sub lr, lr, #4
        \\stmfd sp!, {r0-r12, lr}
        \\bl handleIrq
        \\ldmfd sp!, {r0-r12, pc}^
    );
}

fn fiqHandler_arm() callconv(.naked) void {
    asm volatile (
        \\sub lr, lr, #4
        \\stmfd sp!, {r0-r7, lr}
        \\bl handleFiq
        \\ldmfd sp!, {r0-r7, pc}^
    );
}

// ============================================================
// Interrupt Handling (callable from assembly)
// ============================================================

export fn handleIrq() void {
    // Read interrupt status and dispatch
    // This would check CPU_INT_STAT and call registered handlers
}

export fn handleFiq() void {
    // Fast interrupt handling
}

// ============================================================
// Initialization Functions
// ============================================================

/// Kernel initialization - called from _start after stack setup
export fn kernelInit() noreturn {
    // Clear BSS
    if (is_arm) {
        clearBss();
    }
    boot_state = .bss_cleared;

    // Initialize HAL
    hal.init();

    // Initialize hardware through HAL
    hal.current_hal.system_init() catch {
        // Hardware init failed - halt
        haltLoop();
    };

    boot_state = .hardware_initialized;
    boot_state = .running;

    // Enter main application
    @import("../main.zig").main();

    // Should not return
    shutdown();
}

/// Clear BSS section to zero (ARM only)
fn clearBss() void {
    if (is_arm) {
        const bss_start = @intFromPtr(&extern_symbols.__bss_start);
        const bss_end = @intFromPtr(&extern_symbols.__bss_end);
        const bss_len = bss_end - bss_start;

        const bss_ptr: [*]u8 = @ptrFromInt(bss_start);
        @memset(bss_ptr[0..bss_len], 0);
    }
}

/// Copy IRAM sections from load address (ARM only)
pub fn copyIram() void {
    if (is_arm) {
        const iram_start = @intFromPtr(&extern_symbols.__iram_start);
        const iram_end = @intFromPtr(&extern_symbols.__iram_end);
        const iram_len = iram_end - iram_start;

        if (iram_len > 0) {
            const iram_load = @intFromPtr(&extern_symbols.__iram_load);
            const src: [*]const u8 = @ptrFromInt(iram_load);
            const dst: [*]u8 = @ptrFromInt(iram_start);
            @memcpy(dst[0..iram_len], src[0..iram_len]);
        }
    }
}

/// Initialize all stacks for different CPU modes (ARM only)
pub fn initStacks() void {
    if (is_arm) {
        // Switch to IRQ mode and set stack
        asm volatile (
            \\msr cpsr_c, #0xD2
            \\ldr sp, =__irq_stack_top
        );

        // Switch to FIQ mode and set stack
        asm volatile (
            \\msr cpsr_c, #0xD1
            \\ldr sp, =__fiq_stack_top
        );

        // Return to supervisor mode
        asm volatile (
            \\msr cpsr_c, #0xD3
        );
    }
    boot_state = .stacks_initialized;
}

// ============================================================
// Utility Functions
// ============================================================

/// Infinite halt loop
fn haltLoop() noreturn {
    while (true) {
        if (is_arm) {
            asm volatile ("wfi");
        } else {
            // On host, just spin
            std.atomic.spinLoopHint();
        }
    }
}

/// System shutdown
pub fn shutdown() noreturn {
    boot_state = .shutdown;

    // Disable interrupts
    hal.current_hal.irq_disable();

    // Enter low-power state
    while (true) {
        hal.current_hal.sleep();
    }
}

// ============================================================
// Tests (Host only)
// ============================================================

test "boot state transitions" {
    try std.testing.expectEqual(BootState.uninitialized, boot_state);

    setBootState(.bss_cleared);
    try std.testing.expectEqual(BootState.bss_cleared, getBootState());

    setBootState(.uninitialized);
}

test "arm branch instruction" {
    // Test generating a branch instruction
    const branch = armBranch(0x00000000, 0x00000020);
    // Branch to offset +0x20 from 0x0 = offset of 0x20 - 8 (pipeline) = 0x18
    // 0x18 >> 2 = 6
    try std.testing.expectEqual(@as(u32, 0xEA000006), branch);
}
