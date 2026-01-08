//! ARM7TDMI Cache Controller
//!
//! This module handles cache configuration for the PP5021C's ARM7TDMI core.
//! The ARM7TDMI has separate instruction and data caches that can be
//! configured via the CP15 coprocessor.
//!
//! PP5021C Cache Configuration:
//! - Instruction cache: 8KB (4-way set associative)
//! - Data cache: 8KB (4-way set associative)
//! - Cache line size: 32 bytes
//! - Write buffer: 8 entries
//!
//! The PP5021C also has a memory-mapped cache controller for additional
//! configuration options beyond what CP15 provides.
//!
//! References:
//! - ARM7TDMI Technical Reference Manual
//! - Rockbox firmware/target/arm/crt0-pp.S

const std = @import("std");
const reg = @import("../hal/pp5021c/registers.zig");
const builtin = @import("builtin");

// ============================================================
// Cache Controller Registers (Memory Mapped)
// ============================================================

/// PP5021C cache controller base
const CACHE_CTL: usize = 0x6000C000;
const CACHE_PRIORITY: usize = 0x6000C004;
const CACHE_FLUSH: usize = 0x6000F000;
const CACHE_INVALIDATE: usize = 0x6000F040;

/// Cache line size
pub const CACHE_LINE_SIZE: usize = 32;

/// Cache sizes
pub const ICACHE_SIZE: usize = 8 * 1024; // 8KB instruction cache
pub const DCACHE_SIZE: usize = 8 * 1024; // 8KB data cache

// ============================================================
// CP15 Register Definitions
// ============================================================

/// CP15 register numbers
const CP15 = struct {
    /// Control register (c1)
    pub const CONTROL: u4 = 1;
    /// Cache type register (c0, op2=1)
    pub const CACHE_TYPE: u4 = 0;
    /// TCM status (c9)
    pub const TCM_STATUS: u4 = 9;
    /// Cache operations (c7)
    pub const CACHE_OPS: u4 = 7;
};

/// Control register bits
const CTRL = struct {
    pub const MMU_ENABLE: u32 = 1 << 0; // MMU enable (not used on PP5021C)
    pub const ALIGN_CHECK: u32 = 1 << 1; // Alignment fault checking
    pub const DCACHE_ENABLE: u32 = 1 << 2; // Data cache enable
    pub const WRITE_BUFFER: u32 = 1 << 3; // Write buffer enable
    pub const BIG_ENDIAN: u32 = 1 << 7; // Big endian (0=little endian)
    pub const SYSTEM_PROTECT: u32 = 1 << 8; // System protection
    pub const ROM_PROTECT: u32 = 1 << 9; // ROM protection
    pub const ICACHE_ENABLE: u32 = 1 << 12; // Instruction cache enable
    pub const HIGH_VECTORS: u32 = 1 << 13; // High exception vectors (0xFFFF0000)
    pub const ROUND_ROBIN: u32 = 1 << 14; // Round-robin replacement
};

// ============================================================
// Cache State
// ============================================================

var icache_enabled: bool = false;
var dcache_enabled: bool = false;
var write_buffer_enabled: bool = false;

// ============================================================
// CP15 Access Functions (ARM only)
// ============================================================

const is_arm = builtin.cpu.arch == .arm;

/// Read CP15 control register
fn readControlReg() u32 {
    if (is_arm) {
        var value: u32 = undefined;
        asm volatile ("mrc p15, 0, %[value], c1, c0, 0"
            : [value] "=r" (value),
        );
        return value;
    }
    return 0;
}

/// Write CP15 control register
fn writeControlReg(value: u32) void {
    if (is_arm) {
        asm volatile ("mcr p15, 0, %[value], c1, c0, 0"
            :
            : [value] "r" (value),
            : .{ .memory = true }
        );
    }
}

/// Invalidate entire instruction cache
fn invalidateICache() void {
    if (is_arm) {
        asm volatile ("mcr p15, 0, %[zero], c7, c5, 0"
            :
            : [zero] "r" (@as(u32, 0)),
            : .{ .memory = true }
        );
    }
}

/// Invalidate entire data cache
fn invalidateDCache() void {
    if (is_arm) {
        asm volatile ("mcr p15, 0, %[zero], c7, c6, 0"
            :
            : [zero] "r" (@as(u32, 0)),
            : .{ .memory = true }
        );
    }
}

/// Clean entire data cache (write back dirty lines)
fn cleanDCache() void {
    if (is_arm) {
        // Clean all data cache entries by iterating through sets/ways
        // PP5021C: 256 sets, 4 ways, 32-byte lines
        var way: u32 = 0;
        while (way < 4) : (way += 1) {
            var set: u32 = 0;
            while (set < 256) : (set += 1) {
                const value = (way << 30) | (set << 5);
                asm volatile ("mcr p15, 0, %[value], c7, c10, 2"
                    :
                    : [value] "r" (value),
                    : .{ .memory = true }
                );
            }
        }
    }
}

/// Drain write buffer
fn drainWriteBuffer() void {
    if (is_arm) {
        asm volatile ("mcr p15, 0, %[zero], c7, c10, 4"
            :
            : [zero] "r" (@as(u32, 0)),
            : .{ .memory = true }
        );
    }
}

/// Data synchronization barrier
fn dsb() void {
    if (is_arm) {
        // ARM7 doesn't have DSB, use drain write buffer
        drainWriteBuffer();
    }
}

/// Instruction synchronization barrier
fn isb() void {
    if (is_arm) {
        // ARM7 doesn't have ISB, but we can use a prefetch flush
        asm volatile ("mcr p15, 0, %[zero], c7, c5, 4"
            :
            : [zero] "r" (@as(u32, 0)),
            : .{ .memory = true }
        );
    }
}

// ============================================================
// Cache Initialization
// ============================================================

/// Initialize cache system
pub fn init() void {
    // Step 1: Disable caches first (safe state)
    disableAll();

    // Step 2: Invalidate all caches
    invalidateAll();

    // Step 3: Enable caches and write buffer
    enableAll();
}

/// Disable all caches
fn disableAll() void {
    var ctrl = readControlReg();
    ctrl &= ~(CTRL.ICACHE_ENABLE | CTRL.DCACHE_ENABLE | CTRL.WRITE_BUFFER);
    writeControlReg(ctrl);
    dsb();
    isb();

    icache_enabled = false;
    dcache_enabled = false;
    write_buffer_enabled = false;
}

/// Enable all caches and write buffer
fn enableAll() void {
    var ctrl = readControlReg();

    // Enable instruction cache
    ctrl |= CTRL.ICACHE_ENABLE;

    // Enable data cache
    ctrl |= CTRL.DCACHE_ENABLE;

    // Enable write buffer
    ctrl |= CTRL.WRITE_BUFFER;

    writeControlReg(ctrl);
    dsb();
    isb();

    icache_enabled = true;
    dcache_enabled = true;
    write_buffer_enabled = true;
}

// ============================================================
// Public Cache Operations
// ============================================================

/// Invalidate all caches
pub fn invalidateAll() void {
    invalidateICache();
    invalidateDCache();
    dsb();
}

/// Invalidate instruction cache only
pub fn invalidateInstructionCache() void {
    invalidateICache();
    isb();
}

/// Invalidate data cache only
pub fn invalidateDataCache() void {
    invalidateDCache();
    dsb();
}

/// Clean (flush) data cache
pub fn cleanDataCache() void {
    cleanDCache();
    dsb();
}

/// Clean and invalidate data cache
pub fn cleanInvalidateDataCache() void {
    cleanDCache();
    invalidateDCache();
    dsb();
}

/// Invalidate cache line by address
pub fn invalidateLine(addr: usize) void {
    if (is_arm) {
        const aligned_addr = addr & ~@as(usize, CACHE_LINE_SIZE - 1);
        asm volatile ("mcr p15, 0, %[addr], c7, c6, 1"
            :
            : [addr] "r" (aligned_addr),
            : .{ .memory = true }
        );
    }
}

/// Clean cache line by address
pub fn cleanLine(addr: usize) void {
    if (is_arm) {
        const aligned_addr = addr & ~@as(usize, CACHE_LINE_SIZE - 1);
        asm volatile ("mcr p15, 0, %[addr], c7, c10, 1"
            :
            : [addr] "r" (aligned_addr),
            : .{ .memory = true }
        );
    }
}

/// Clean and invalidate cache line by address
pub fn cleanInvalidateLine(addr: usize) void {
    if (is_arm) {
        const aligned_addr = addr & ~@as(usize, CACHE_LINE_SIZE - 1);
        asm volatile ("mcr p15, 0, %[addr], c7, c14, 1"
            :
            : [addr] "r" (aligned_addr),
            : .{ .memory = true }
        );
    }
}

/// Invalidate range of addresses
pub fn invalidateRange(start: usize, length: usize) void {
    var addr = start & ~@as(usize, CACHE_LINE_SIZE - 1);
    const end = start + length;

    while (addr < end) {
        invalidateLine(addr);
        addr += CACHE_LINE_SIZE;
    }
    dsb();
}

/// Clean range of addresses
pub fn cleanRange(start: usize, length: usize) void {
    var addr = start & ~@as(usize, CACHE_LINE_SIZE - 1);
    const end = start + length;

    while (addr < end) {
        cleanLine(addr);
        addr += CACHE_LINE_SIZE;
    }
    dsb();
}

/// Clean and invalidate range of addresses
pub fn cleanInvalidateRange(start: usize, length: usize) void {
    var addr = start & ~@as(usize, CACHE_LINE_SIZE - 1);
    const end = start + length;

    while (addr < end) {
        cleanInvalidateLine(addr);
        addr += CACHE_LINE_SIZE;
    }
    dsb();
}

// ============================================================
// Cache Control
// ============================================================

/// Enable instruction cache
pub fn enableICache() void {
    var ctrl = readControlReg();
    ctrl |= CTRL.ICACHE_ENABLE;
    writeControlReg(ctrl);
    isb();
    icache_enabled = true;
}

/// Disable instruction cache
pub fn disableICache() void {
    var ctrl = readControlReg();
    ctrl &= ~CTRL.ICACHE_ENABLE;
    writeControlReg(ctrl);
    isb();
    icache_enabled = false;
}

/// Enable data cache
pub fn enableDCache() void {
    var ctrl = readControlReg();
    ctrl |= CTRL.DCACHE_ENABLE;
    writeControlReg(ctrl);
    dsb();
    dcache_enabled = true;
}

/// Disable data cache (clean first)
pub fn disableDCache() void {
    cleanDCache();
    var ctrl = readControlReg();
    ctrl &= ~CTRL.DCACHE_ENABLE;
    writeControlReg(ctrl);
    dsb();
    dcache_enabled = false;
}

/// Enable write buffer
pub fn enableWriteBuffer() void {
    var ctrl = readControlReg();
    ctrl |= CTRL.WRITE_BUFFER;
    writeControlReg(ctrl);
    write_buffer_enabled = true;
}

/// Disable write buffer
pub fn disableWriteBuffer() void {
    drainWriteBuffer();
    var ctrl = readControlReg();
    ctrl &= ~CTRL.WRITE_BUFFER;
    writeControlReg(ctrl);
    write_buffer_enabled = false;
}

// ============================================================
// Status Functions
// ============================================================

/// Check if instruction cache is enabled
pub fn isICacheEnabled() bool {
    return icache_enabled;
}

/// Check if data cache is enabled
pub fn isDCacheEnabled() bool {
    return dcache_enabled;
}

/// Check if write buffer is enabled
pub fn isWriteBufferEnabled() bool {
    return write_buffer_enabled;
}

// ============================================================
// DMA Support
// ============================================================

/// Prepare memory region for DMA read (device will read from memory)
/// Clean cache to ensure data is in memory
pub fn prepareDmaRead(addr: usize, length: usize) void {
    cleanRange(addr, length);
}

/// Prepare memory region for DMA write (device will write to memory)
/// Invalidate cache so CPU will read fresh data
pub fn prepareDmaWrite(addr: usize, length: usize) void {
    invalidateRange(addr, length);
}

/// Complete DMA write (device has written to memory)
/// Invalidate cache to see the new data
pub fn completeDmaWrite(addr: usize, length: usize) void {
    invalidateRange(addr, length);
}

// ============================================================
// Tests
// ============================================================

test "cache line alignment" {
    // Test that addresses are properly aligned
    const addr: usize = 0x40001234;
    const aligned = addr & ~@as(usize, CACHE_LINE_SIZE - 1);
    try std.testing.expectEqual(@as(usize, 0x40001220), aligned);
}

test "cache constants" {
    try std.testing.expectEqual(@as(usize, 32), CACHE_LINE_SIZE);
    try std.testing.expectEqual(@as(usize, 8192), ICACHE_SIZE);
    try std.testing.expectEqual(@as(usize, 8192), DCACHE_SIZE);
}
