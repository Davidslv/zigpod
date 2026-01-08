//! PP5021C SDRAM Controller Initialization
//!
//! This module handles SDRAM controller configuration for the PP5021C SoC.
//! The iPod Classic uses 32MB or 64MB of SDRAM at address 0x40000000.
//!
//! SDRAM Configuration:
//! - Base address: 0x40000000
//! - Size: 32MB (30GB model) or 64MB (80GB/160GB models)
//! - Type: 16-bit SDRAM
//! - Organization: 4 banks
//!
//! The SDRAM controller must be initialized before any DRAM access.
//! This includes setting up:
//! - Timing parameters (CAS latency, RAS-to-CAS delay, etc.)
//! - Refresh rate
//! - Mode register
//!
//! References:
//! - Rockbox firmware/target/arm/system-pp502x.c
//! - PP5020 reverse engineering documentation

const std = @import("std");
const reg = @import("../hal/pp5021c/registers.zig");
const clock = @import("clock.zig");

// ============================================================
// SDRAM Controller Registers
// ============================================================

/// SDRAM controller base address
const SDRAM_BASE: usize = 0x60006100;

/// SDRAM configuration registers
const SDRAM_CONFIG: usize = SDRAM_BASE + 0x00;
const SDRAM_TIMING1: usize = SDRAM_BASE + 0x04;
const SDRAM_TIMING2: usize = SDRAM_BASE + 0x08;
const SDRAM_REFRESH: usize = SDRAM_BASE + 0x0C;
const SDRAM_MODE: usize = SDRAM_BASE + 0x10;
const SDRAM_STATUS: usize = SDRAM_BASE + 0x14;

/// Memory controller registers
const MEM_CONTROL: usize = 0x6000C000;
const MEM_PRIORITY: usize = 0x6000C004;

// ============================================================
// SDRAM Timing Constants
// ============================================================

/// SDRAM timing parameters for 80MHz operation
/// These values are derived from Rockbox and standard SDRAM specifications
const Timing = struct {
    // All times in nanoseconds, converted to clock cycles at 80MHz
    // 1 cycle = 12.5ns at 80MHz

    /// CAS Latency (2 or 3 cycles)
    pub const CAS_LATENCY: u32 = 3;

    /// RAS-to-CAS delay (tRCD) - typically 15-20ns = 2 cycles
    pub const TRCD: u32 = 2;

    /// Row precharge time (tRP) - typically 15-20ns = 2 cycles
    pub const TRP: u32 = 2;

    /// Active-to-precharge time (tRAS) - typically 40-50ns = 4 cycles
    pub const TRAS: u32 = 4;

    /// Row cycle time (tRC) - typically 55-70ns = 5-6 cycles
    pub const TRC: u32 = 6;

    /// Write recovery time (tWR) - typically 2 cycles
    pub const TWR: u32 = 2;

    /// Refresh period (tREF) - typically 64ms for 4096 rows
    /// At 80MHz: 64ms/4096 = 15.6us ≈ 1248 cycles
    pub const REFRESH_CYCLES: u32 = 1248;
};

// ============================================================
// SDRAM Configuration Values
// ============================================================

/// SDRAM size detection result
pub const SdramSize = enum {
    mb_32, // 32MB (0x2000000)
    mb_64, // 64MB (0x4000000)
    unknown,
};

var detected_size: SdramSize = .unknown;

// ============================================================
// SDRAM Initialization
// ============================================================

/// Initialize SDRAM controller
/// Must be called after clock initialization but before any DRAM access
pub fn init() void {
    // Step 1: Configure memory controller
    configureMemoryController();

    // Step 2: Set SDRAM timing parameters
    configureTimings();

    // Step 3: Initialize SDRAM (mode register set)
    initializeMemory();

    // Step 4: Enable refresh
    enableRefresh();

    // Step 5: Detect memory size
    detected_size = detectSize();
}

/// Configure memory controller for SDRAM access
fn configureMemoryController() void {
    // Set memory controller to SDRAM mode
    // Enable SDRAM interface, configure bus width
    const config: u32 = 0x0000_0001; // Enable SDRAM controller
    reg.writeReg(u32, MEM_CONTROL, config);

    // Set memory access priority (CPU > COP > DMA)
    reg.writeReg(u32, MEM_PRIORITY, 0x0000_0321);

    // Small delay for controller to stabilize
    delay(100);
}

/// Configure SDRAM timing parameters
fn configureTimings() void {
    // Timing register 1: CAS latency, RCD, RP
    // Format: [31:24]=reserved, [23:16]=CAS, [15:8]=tRCD, [7:0]=tRP
    const timing1: u32 = (Timing.CAS_LATENCY << 16) |
        (Timing.TRCD << 8) |
        (Timing.TRP);
    reg.writeReg(u32, SDRAM_TIMING1, timing1);

    // Timing register 2: RAS, RC, WR
    // Format: [23:16]=tRAS, [15:8]=tRC, [7:0]=tWR
    const timing2: u32 = (Timing.TRAS << 16) |
        (Timing.TRC << 8) |
        (Timing.TWR);
    reg.writeReg(u32, SDRAM_TIMING2, timing2);
}

/// Initialize SDRAM with mode register set sequence
fn initializeMemory() void {
    // SDRAM initialization sequence:
    // 1. Apply power and clock (done by clock init)
    // 2. Wait 100us for power stabilization
    // 3. Issue PRECHARGE ALL command
    // 4. Issue 2 AUTO REFRESH commands
    // 5. Issue MODE REGISTER SET command

    // Wait for power stabilization (at least 100us)
    delay(10000);

    // Issue PRECHARGE ALL
    reg.writeReg(u32, SDRAM_MODE, 0x0000_0002); // Precharge all banks
    delay(100);

    // Issue AUTO REFRESH (twice)
    reg.writeReg(u32, SDRAM_MODE, 0x0000_0004); // Auto refresh
    delay(100);
    reg.writeReg(u32, SDRAM_MODE, 0x0000_0004); // Auto refresh again
    delay(100);

    // Issue MODE REGISTER SET
    // Mode: CAS=3, Burst Length=1 (single), Sequential
    // Value = (CAS << 4) | (burst_type << 3) | burst_length
    const mode_value: u32 = (Timing.CAS_LATENCY << 4) | 0x00; // CAS=3, BL=1
    reg.writeReg(u32, SDRAM_MODE, 0x0000_0001 | (mode_value << 8));
    delay(100);

    // Return to normal operation
    reg.writeReg(u32, SDRAM_MODE, 0x0000_0000);
}

/// Enable auto-refresh
fn enableRefresh() void {
    // Set refresh counter
    // Refresh rate = SDRAM_clock / refresh_cycles
    reg.writeReg(u32, SDRAM_REFRESH, Timing.REFRESH_CYCLES);

    // Enable refresh in config register
    var config = reg.readReg(u32, SDRAM_CONFIG);
    config |= 0x0000_0002; // Enable refresh
    reg.writeReg(u32, SDRAM_CONFIG, config);
}

/// Detect SDRAM size by writing and reading patterns
fn detectSize() SdramSize {
    // We detect size by writing patterns at specific addresses
    // and checking if they alias (wrap around)

    const test_addr_32mb: usize = reg.DRAM_START + 0x1FF_FFFC; // Last word of 32MB
    const test_addr_64mb: usize = reg.DRAM_START + 0x3FF_FFFC; // Last word of 64MB
    const base_addr: usize = reg.DRAM_START;

    const pattern1: u32 = 0xDEAD_BEEF;
    const pattern2: u32 = 0xCAFE_BABE;

    // Write pattern to base
    writeMemory(base_addr, pattern1);

    // Write different pattern to 64MB boundary
    writeMemory(test_addr_64mb, pattern2);

    // Check if base was overwritten (64MB aliases to 0 means <64MB)
    if (readMemory(base_addr) == pattern2) {
        // Memory is 64MB (no alias)
        return .mb_64;
    }

    // Write pattern to 32MB boundary
    writeMemory(base_addr, pattern1);
    writeMemory(test_addr_32mb, pattern2);

    // Check if base was overwritten
    if (readMemory(base_addr) != pattern1) {
        // Something wrong with memory
        return .unknown;
    }

    // Check 32MB location
    if (readMemory(test_addr_32mb) == pattern2) {
        return .mb_32;
    }

    return .unknown;
}

/// Simple delay loop
fn delay(count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        asm volatile ("nop");
    }
}

/// Write to memory (volatile)
fn writeMemory(addr: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Read from memory (volatile)
fn readMemory(addr: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

// ============================================================
// Public API
// ============================================================

/// Get detected SDRAM size
pub fn getSize() SdramSize {
    return detected_size;
}

/// Get SDRAM size in bytes
pub fn getSizeBytes() usize {
    return switch (detected_size) {
        .mb_32 => 32 * 1024 * 1024,
        .mb_64 => 64 * 1024 * 1024,
        .unknown => 32 * 1024 * 1024, // Assume minimum
    };
}

/// Get SDRAM base address
pub fn getBaseAddress() usize {
    return reg.DRAM_START;
}

/// Get SDRAM end address
pub fn getEndAddress() usize {
    return reg.DRAM_START + getSizeBytes();
}

/// Check if SDRAM is initialized
pub fn isInitialized() bool {
    return detected_size != .unknown;
}

/// Self-test SDRAM (basic pattern test)
pub fn selfTest() bool {
    const test_addr = reg.DRAM_START + 0x1000; // Test at offset 4KB

    // Write pattern
    const patterns = [_]u32{ 0xAAAA_AAAA, 0x5555_5555, 0x0000_0000, 0xFFFF_FFFF };

    for (patterns) |pattern| {
        writeMemory(test_addr, pattern);
        if (readMemory(test_addr) != pattern) {
            return false;
        }
    }

    // Walking ones test
    var bit: u5 = 0;
    while (bit < 32) : (bit += 1) {
        const pattern: u32 = @as(u32, 1) << bit;
        writeMemory(test_addr, pattern);
        if (readMemory(test_addr) != pattern) {
            return false;
        }
    }

    return true;
}

// ============================================================
// Tests
// ============================================================

test "timing calculations" {
    // At 80MHz, 1 cycle = 12.5ns
    // tRCD = 20ns typical = 2 cycles (ceil(20/12.5))
    try std.testing.expect(Timing.TRCD >= 2);

    // Refresh: 64ms / 4096 rows = 15.6us per row
    // At 80MHz: 15.6us * 80MHz = 1248 cycles
    try std.testing.expectEqual(@as(u32, 1248), Timing.REFRESH_CYCLES);
}

test "size detection values" {
    // Verify size constants
    const size_32mb: usize = 32 * 1024 * 1024;
    const size_64mb: usize = 64 * 1024 * 1024;

    try std.testing.expectEqual(@as(usize, 0x0200_0000), size_32mb);
    try std.testing.expectEqual(@as(usize, 0x0400_0000), size_64mb);
}
