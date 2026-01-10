//! Kernel Boot and Initialization
//!
//! This module handles the early boot process, including:
//! - Vector table setup
//! - Stack initialization
//! - BSS clearing
//! - Clock/PLL initialization
//! - SDRAM controller initialization
//! - Cache configuration
//! - Hardware initialization
//! - Jump to main application
//!
//! Boot Sequence (PP5021C):
//! 1. Reset vector -> _start
//! 2. Disable interrupts, set initial stack
//! 3. Clear BSS
//! 4. Initialize PLL for 80MHz operation
//! 5. Initialize SDRAM controller
//! 6. Enable caches (I-cache, D-cache)
//! 7. Copy IRAM sections
//! 8. Initialize mode-specific stacks
//! 9. Initialize HAL and peripherals
//! 10. Jump to main application

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("../hal/hal.zig");
const clock = @import("clock.zig");
const sdram = @import("sdram.zig");
const cache = @import("cache.zig");

// Hardware-specific initialization for single binary approach
const pp5021c_init = if (is_arm) @import("pp5021c_init.zig") else struct {
    pub fn disableInterrupts() void {}
    pub fn initMinimal() void {}
    pub fn delayMs(_: u32) void {}
};
const bcm = if (is_arm) @import("../drivers/display/bcm.zig") else struct {
    pub fn init() !void {}
    pub fn clear(_: u16) void {}
    pub fn isReady() bool {
        return true;
    }
};

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
    clocks_initialized,
    sdram_initialized,
    cache_initialized,
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
    // kernelInit is noreturn so we don't need anything after
    asm volatile (
        \\cpsid if
        \\ldr sp, =__stack_top
        \\b kernelInit
    );
}

fn undefinedHandler_arm() callconv(.naked) noreturn {
    // Infinite loop on undefined instruction (ARM7TDMI has no WFI)
    asm volatile ("1: b 1b");
}

fn swiHandler_arm() callconv(.naked) void {
    asm volatile ("movs pc, lr");
}

fn prefetchAbortHandler_arm() callconv(.naked) noreturn {
    // Infinite loop on prefetch abort
    asm volatile ("1: b 1b");
}

fn dataAbortHandler_arm() callconv(.naked) noreturn {
    // Infinite loop on data abort
    asm volatile ("1: b 1b");
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

const interrupts = @import("interrupts.zig");

// Import register definitions for interrupt controller
const reg = @import("../hal/pp5021c/registers.zig");

// Import DMA audio pipeline for FIQ handling
const dma_pipeline = @import("../audio/dma_pipeline.zig");

export fn handleIrq() void {
    // Read interrupt status register
    const status = reg.readReg(u32, reg.CPU_INT_STAT);

    // Dispatch to registered handlers based on active interrupts
    // Check each interrupt source and call handler if registered

    // Timer 1 interrupt (main tick)
    if ((status & reg.TIMER1_IRQ) != 0) {
        if (interrupts.handlers[@intFromEnum(interrupts.Interrupt.timer1)]) |handler| {
            handler();
        }
        // Clear the interrupt
        reg.writeReg(u32, reg.CPU_INT_CLR, reg.TIMER1_IRQ);
    }

    // Timer 2 interrupt
    if ((status & reg.TIMER2_IRQ) != 0) {
        if (interrupts.handlers[@intFromEnum(interrupts.Interrupt.timer2)]) |handler| {
            handler();
        }
        reg.writeReg(u32, reg.CPU_INT_CLR, reg.TIMER2_IRQ);
    }

    // I2S audio interrupt (FIFO needs data)
    if ((status & reg.IIS_IRQ) != 0) {
        if (interrupts.handlers[@intFromEnum(interrupts.Interrupt.i2s)]) |handler| {
            handler();
        }
        reg.writeReg(u32, reg.CPU_INT_CLR, reg.IIS_IRQ);
    }

    // DMA interrupt (transfer complete)
    if ((status & reg.DMA_IRQ) != 0) {
        if (interrupts.handlers[@intFromEnum(interrupts.Interrupt.dma)]) |handler| {
            handler();
        }
        reg.writeReg(u32, reg.CPU_INT_CLR, reg.DMA_IRQ);
    }

    // IDE/ATA interrupt
    if ((status & reg.IDE_IRQ) != 0) {
        if (interrupts.handlers[@intFromEnum(interrupts.Interrupt.ide)]) |handler| {
            handler();
        }
        reg.writeReg(u32, reg.CPU_INT_CLR, reg.IDE_IRQ);
    }

    // GPIO interrupts (click wheel, buttons)
    if ((status & reg.GPIO0_IRQ) != 0) {
        if (interrupts.handlers[@intFromEnum(interrupts.Interrupt.gpio0)]) |handler| {
            handler();
        }
        reg.writeReg(u32, reg.CPU_INT_CLR, reg.GPIO0_IRQ);
    }

    if ((status & reg.GPIO1_IRQ) != 0) {
        if (interrupts.handlers[@intFromEnum(interrupts.Interrupt.gpio1)]) |handler| {
            handler();
        }
        reg.writeReg(u32, reg.CPU_INT_CLR, reg.GPIO1_IRQ);
    }

    // USB interrupt
    if ((status & reg.USB_IRQ) != 0) {
        if (interrupts.handlers[@intFromEnum(interrupts.Interrupt.usb)]) |handler| {
            handler();
        }
        reg.writeReg(u32, reg.CPU_INT_CLR, reg.USB_IRQ);
    }

    // I2C interrupt
    if ((status & reg.I2C_IRQ) != 0) {
        if (interrupts.handlers[@intFromEnum(interrupts.Interrupt.i2c)]) |handler| {
            handler();
        }
        reg.writeReg(u32, reg.CPU_INT_CLR, reg.I2C_IRQ);
    }
}

export fn handleFiq() void {
    // Fast interrupt handling - used for time-critical audio DMA
    // FIQ is routed for I2S and DMA by dma_pipeline.zig

    const status = reg.readReg(u32, reg.CPU_INT_STAT);

    // Check if this is an audio-related interrupt (DMA or I2S)
    const audio_mask = reg.DMA_IRQ | reg.IIS_IRQ;
    if ((status & audio_mask) != 0) {
        // Handle audio FIQ - this swaps buffers and sets refill flag
        dma_pipeline.handleAudioFiq();
        return;
    }

    // Handle any other FIQ sources (shouldn't happen normally)
    // Clear any unexpected FIQ sources to prevent infinite loop
    if (is_arm) {
        const fiq_sources = reg.readReg(u32, reg.CPU_INT_PRIO);
        const pending_fiq = status & fiq_sources;
        if (pending_fiq != 0) {
            reg.writeReg(u32, reg.CPU_INT_CLR, pending_fiq);
        }
    }
}

// ============================================================
// Initialization Functions
// ============================================================

/// Kernel initialization - called from _start after stack setup
export fn kernelInit() noreturn {
    // ================================================================
    // SINGLE BINARY APPROACH: Initialize hardware directly first
    // This ensures LCD works before any HAL abstraction kicks in
    // ================================================================

    // Step 0: Disable interrupts immediately (critical for bare metal)
    if (is_arm) {
        pp5021c_init.disableInterrupts();
    }

    // Step 1: Clear BSS section
    if (is_arm) {
        clearBss();
    }
    boot_state = .bss_cleared;

    // Step 2: Initialize clock system (PLL for 80MHz)
    // This must happen early because all timing depends on it
    if (is_arm) {
        clock.init();
    }
    boot_state = .clocks_initialized;

    // Step 3: Initialize SDRAM controller
    // Required before any DRAM access
    if (is_arm) {
        sdram.init();
    }
    boot_state = .sdram_initialized;

    // Step 4: Initialize cache controller
    // Enables I-cache and D-cache for performance
    if (is_arm) {
        cache.init();
    }
    boot_state = .cache_initialized;

    // Step 5: Initialize PP5021C GPIO and devices
    // This sets up GPIO for BCM control
    if (is_arm) {
        pp5021c_init.initMinimal();
    }

    // Step 6: Initialize BCM2722 LCD controller
    // This is the critical step that was missing before!
    if (is_arm) {
        bcm.init() catch {
            // BCM init failed - we can't display anything
            // Just halt here - at least we tried
            haltLoop();
        };

        // Clear screen to black to show we're alive
        bcm.clear(0x0000);
    }

    // Step 7: Copy IRAM sections (if any)
    if (is_arm) {
        copyIram();
    }

    // Step 8: Initialize mode-specific stacks (IRQ, FIQ)
    if (is_arm) {
        initStacks();
    }
    boot_state = .stacks_initialized;

    // Step 9: Initialize HAL (for higher-level abstractions)
    hal.init();

    // Step 10: Initialize remaining hardware through HAL
    // Note: LCD is already initialized via BCM, so this should skip LCD init
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
        // Get stack addresses from linker symbols
        const irq_stack = @intFromPtr(&extern_symbols.__irq_stack_top);
        const fiq_stack = @intFromPtr(&extern_symbols.__fiq_stack_top);

        // Switch to IRQ mode and set stack
        asm volatile (
            \\msr cpsr_c, #0xD2
            \\mov sp, %[irq_sp]
            :
            : [irq_sp] "r" (irq_stack),
        );

        // Switch to FIQ mode and set stack
        asm volatile (
            \\msr cpsr_c, #0xD1
            \\mov sp, %[fiq_sp]
            :
            : [fiq_sp] "r" (fiq_stack),
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
        // ARM7TDMI has no WFI, just spin
        // On host, use spin loop hint
        if (!is_arm) {
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
