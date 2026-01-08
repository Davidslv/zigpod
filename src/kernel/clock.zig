//! PP5021C Clock and PLL Initialization
//!
//! This module handles clock tree initialization for the PortalPlayer PP5021C SoC.
//! The PP5021C has multiple clock domains that need proper configuration:
//! - CPU core clock (target: 80MHz)
//! - COP (coprocessor) clock
//! - SDRAM controller clock
//! - Peripheral clocks (I2C, I2S, ATA, LCD, USB)
//!
//! Clock sources:
//! - 32.768 kHz low-power oscillator
//! - 24 MHz main crystal oscillator
//! - PLL (generates 80MHz from 24MHz)
//!
//! References:
//! - Rockbox firmware/target/arm/system-pp502x.c
//! - iPod Linux project documentation

const std = @import("std");
const reg = @import("../hal/pp5021c/registers.zig");

// ============================================================
// Clock Configuration Constants
// ============================================================

/// Target CPU frequency in Hz
pub const CPU_FREQ_HZ: u32 = 80_000_000; // 80 MHz

/// Main crystal oscillator frequency
pub const XTAL_FREQ_HZ: u32 = 24_000_000; // 24 MHz

/// Low-power oscillator frequency
pub const LP_OSC_FREQ_HZ: u32 = 32_768; // 32.768 kHz

/// PLL output frequency
pub const PLL_FREQ_HZ: u32 = 80_000_000; // 80 MHz

// ============================================================
// Additional Register Definitions
// ============================================================

/// PLL configuration register
const PLL_CONTROL: usize = 0x60006034;
const PLL_STATUS: usize = 0x6000603C;

/// Clock source selection register
const CLOCK_SOURCE: usize = 0x60006020;

/// Device clock dividers
const CPU_CLOCK_DIV: usize = 0x60006024;
const COP_CLOCK_DIV: usize = 0x60006028;

/// Additional clock registers
const IDE_CONFIG: usize = 0x600060B4;
const MLCD_SCLK_DIV: usize = 0x6000602C;

// PLL control values (derived from Rockbox)
// PLL formula: Fout = (Fin * (P+1)) / ((Q+1) * (2^S))
// For 80MHz from 24MHz: P=9, Q=2, S=0 -> 24 * 10 / 3 = 80MHz
const PLL_80MHZ: u32 = 0x8002_2902; // Enable + P=9, Q=2, S=0

// Clock source configurations
// Each nibble controls a different clock domain
// 0 = 32kHz, 1 = 24MHz, 2 = 24MHz, 7 = PLL
const CLOCK_SRC_32K: u32 = 0x2000_2222; // All domains on 32kHz/24MHz
const CLOCK_SRC_PLL: u32 = 0x2000_7777; // All domains on PLL

// ============================================================
// Clock State
// ============================================================

var pll_enabled: bool = false;
var current_cpu_freq: u32 = LP_OSC_FREQ_HZ;

// ============================================================
// Clock Initialization Functions
// ============================================================

/// Initialize the clock system
/// This must be called early in boot, before any peripherals are used
pub fn init() void {
    // Step 1: Ensure we start from a known state
    // Switch to safe low-speed clocks first
    switchToLowSpeed();

    // Step 2: Configure and enable PLL
    configurePll();

    // Step 3: Wait for PLL to lock
    waitForPllLock();

    // Step 4: Switch clock domains to PLL
    switchToPll();

    // Step 5: Configure peripheral clock dividers
    configurePeripheralClocks();

    pll_enabled = true;
    current_cpu_freq = CPU_FREQ_HZ;
}

/// Switch all clock domains to low-speed (32kHz/24MHz) mode
/// Used during initialization and before sleep
fn switchToLowSpeed() void {
    reg.writeReg(u32, CLOCK_SOURCE, CLOCK_SRC_32K);

    // Small delay for clock switch to complete
    // At 32kHz, we need only a few cycles
    spinDelay(100);
}

/// Configure the PLL for 80MHz output
fn configurePll() void {
    // Disable PLL first (clear enable bit)
    reg.writeReg(u32, PLL_CONTROL, 0x0002_2902);

    // Small delay
    spinDelay(100);

    // Enable PLL with 80MHz configuration
    reg.writeReg(u32, PLL_CONTROL, PLL_80MHZ);
}

/// Wait for PLL to achieve lock
fn waitForPllLock() void {
    // PLL lock bit is in PLL_STATUS register
    // Typically takes a few hundred microseconds
    var timeout: u32 = 10000;
    while (timeout > 0) : (timeout -= 1) {
        const status = reg.readReg(u32, PLL_STATUS);
        if ((status & 0x8000_0000) != 0) {
            // PLL is locked
            return;
        }
        spinDelay(10);
    }
    // If we get here, PLL failed to lock
    // Continue anyway - hardware may still work at lower speed
}

/// Switch clock domains to use PLL
fn switchToPll() void {
    // Gradually switch domains to PLL to avoid glitches
    // First enable PLL for CPU
    var src = reg.readReg(u32, CLOCK_SOURCE);

    // Switch CPU to PLL (nibble 0)
    src = (src & 0xFFFF_FFF0) | 0x7;
    reg.writeReg(u32, CLOCK_SOURCE, src);
    spinDelay(100);

    // Switch other domains
    reg.writeReg(u32, CLOCK_SOURCE, CLOCK_SRC_PLL);
    spinDelay(100);
}

/// Configure peripheral clock dividers for 80MHz base
fn configurePeripheralClocks() void {
    // CPU clock divider (1:1 at 80MHz)
    reg.writeReg(u32, CPU_CLOCK_DIV, 0x0000_0000);

    // COP clock divider (same as CPU)
    reg.writeReg(u32, COP_CLOCK_DIV, 0x0000_0000);

    // IDE/ATA timing for 80MHz
    // These values are from Rockbox for PIO mode
    reg.writeReg(u32, IDE_CONFIG, 0x0000_0191);
}

/// Simple spin delay (not accurate, just wastes cycles)
fn spinDelay(count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        asm volatile ("nop");
    }
}

// ============================================================
// Runtime Clock Control
// ============================================================

/// Get current CPU frequency
pub fn getCpuFrequency() u32 {
    return current_cpu_freq;
}

/// Check if PLL is enabled
pub fn isPllEnabled() bool {
    return pll_enabled;
}

/// Enter low-power clock mode (for sleep)
pub fn enterLowPowerMode() void {
    switchToLowSpeed();
    current_cpu_freq = LP_OSC_FREQ_HZ;
}

/// Exit low-power clock mode (wake from sleep)
pub fn exitLowPowerMode() void {
    if (pll_enabled) {
        waitForPllLock();
        switchToPll();
        current_cpu_freq = CPU_FREQ_HZ;
    }
}

/// Set CPU frequency (basic scaling)
/// Only supports full speed (80MHz) or low speed (24MHz) currently
pub fn setCpuFrequency(target_hz: u32) void {
    if (target_hz >= CPU_FREQ_HZ) {
        // Full speed - use PLL
        if (!pll_enabled) {
            init();
        } else {
            switchToPll();
            current_cpu_freq = CPU_FREQ_HZ;
        }
    } else {
        // Low speed - bypass PLL
        switchToLowSpeed();
        current_cpu_freq = XTAL_FREQ_HZ; // Actually ~24MHz in this mode
    }
}

// ============================================================
// Peripheral Clock Configuration
// ============================================================

/// Enable clock for a specific peripheral
pub fn enablePeripheralClock(device: u32) void {
    const current = reg.readReg(u32, reg.DEV_EN);
    reg.writeReg(u32, reg.DEV_EN, current | device);
}

/// Disable clock for a specific peripheral
pub fn disablePeripheralClock(device: u32) void {
    const current = reg.readReg(u32, reg.DEV_EN);
    reg.writeReg(u32, reg.DEV_EN, current & ~device);
}

/// Configure I2S clock for audio
/// MCLK should be 256 * sample_rate for WM8758
pub fn configureI2sClock(sample_rate: u32) void {
    // I2S clock is derived from PLL
    // For 44100Hz: MCLK = 11.2896 MHz (256 * 44100)
    // For 48000Hz: MCLK = 12.288 MHz (256 * 48000)

    // Calculate divider from 80MHz
    // Divider = 80MHz / (256 * sample_rate)
    const mclk_target = sample_rate * 256;
    const divider = (CPU_FREQ_HZ + mclk_target / 2) / mclk_target;

    // I2S clock divider register
    const IISCLKDIV: usize = 0x7000_2804;
    reg.writeReg(u32, IISCLKDIV, divider - 1);
}

/// Configure LCD pixel clock
pub fn configureLcdClock(pixel_clock_hz: u32) void {
    // Calculate divider from PLL
    const divider = (CPU_FREQ_HZ + pixel_clock_hz / 2) / pixel_clock_hz;

    // LCD clock divider
    reg.writeReg(u32, MLCD_SCLK_DIV, divider - 1);
}

// ============================================================
// Tests
// ============================================================

test "clock constants" {
    // Verify PLL can generate 80MHz from 24MHz
    // Formula: Fout = Fin * (P+1) / ((Q+1) * 2^S)
    // P=9, Q=2, S=0: 24 * 10 / 3 = 80
    const p: u32 = 9;
    const q: u32 = 2;
    const s: u32 = 0;
    const fout = (XTAL_FREQ_HZ * (p + 1)) / ((q + 1) * (@as(u32, 1) << @intCast(s)));
    try std.testing.expectEqual(CPU_FREQ_HZ, fout);
}

test "i2s clock divider" {
    // For 44100Hz: MCLK = 11.2896 MHz
    // Divider from 80MHz = 80 / 11.2896 ≈ 7
    const sample_rate: u32 = 44100;
    const mclk_target = sample_rate * 256;
    const divider = (CPU_FREQ_HZ + mclk_target / 2) / mclk_target;
    try std.testing.expect(divider >= 6 and divider <= 8);
}
