//! PP5021C (PortalPlayer) Hardware Initialization for iPod Video
//!
//! The PP5021C is the main SoC in the iPod Video. It contains:
//! - Dual ARM7TDMI cores
//! - Memory controllers
//! - PLL/clock generation
//! - GPIO controllers
//! - Interrupt controllers
//! - Various peripherals (I2C, SPI, USB, etc.)
//!
//! This module initializes the PP5021C from a bare metal state.
//! Based on Rockbox firmware/target/arm/pp/system-pp502x.c
//!
//! Note: When loaded by Apple bootloader, many peripherals are already
//! initialized. We reset them to a known state anyway.

const std = @import("std");

// ============================================================
// Memory Map Constants
// ============================================================

/// DRAM start address (where Apple ROM loads firmware)
pub const DRAM_START: u32 = 0x10000000;

/// IRAM (internal SRAM) base address
pub const IRAM_BASE: u32 = 0x40000000;

/// SDRAM base address
pub const SDRAM_BASE: u32 = 0x10000000;

/// ROM base address
pub const ROM_BASE: u32 = 0x20000000;

/// PP5021C peripheral register base
pub const PP_BASE: u32 = 0x60000000;

/// PP5021C system register base
pub const SYS_BASE: u32 = 0x70000000;

// ============================================================
// Device Control Registers (0x6000D000)
// ============================================================

/// Device enable register - controls power to peripherals
const DEV_EN: *volatile u32 = @ptrFromInt(0x6000D000);
const DEV_EN2: *volatile u32 = @ptrFromInt(0x6000D004);
const DEV_EN3: *volatile u32 = @ptrFromInt(0x6000D008);

/// Device reset register - reset peripherals
const DEV_RS: *volatile u32 = @ptrFromInt(0x6000D010);
const DEV_RS2: *volatile u32 = @ptrFromInt(0x6000D014);
const DEV_RS3: *volatile u32 = @ptrFromInt(0x6000D018);

/// Device initialization registers
const DEV_INIT1: *volatile u32 = @ptrFromInt(0x6000D020);
const DEV_INIT2: *volatile u32 = @ptrFromInt(0x6000D024);

/// Cache priority register
const CACHE_PRIORITY: *volatile u32 = @ptrFromInt(0x6000D034);

// ============================================================
// Clock/PLL Registers (0x70000000)
// ============================================================

/// PLL control register
const PLL_CONTROL: *volatile u32 = @ptrFromInt(0x70000020);

/// PLL status register (bit 31 = locked)
const PLL_STATUS: *volatile u32 = @ptrFromInt(0x70000024);

/// Clock source select register
const CLOCK_SOURCE: *volatile u32 = @ptrFromInt(0x70000028);

/// Clock enable register
const CLK_EN: *volatile u32 = @ptrFromInt(0x7000002C);

// ============================================================
// GPIO Registers (0x6000D0xx)
// ============================================================

/// GPO32 (32-bit general purpose output)
pub const GPO32_VAL: *volatile u32 = @ptrFromInt(0x6000D0A0);
pub const GPO32_ENABLE: *volatile u32 = @ptrFromInt(0x6000D0B0);

/// GPIOA (8-bit GPIO port A)
const GPIOA_OUTPUT_VAL: *volatile u32 = @ptrFromInt(0x6000D000);
const GPIOA_OUTPUT_EN: *volatile u32 = @ptrFromInt(0x6000D010);
const GPIOA_INPUT_VAL: *volatile u32 = @ptrFromInt(0x6000D020);

/// GPIOB (8-bit GPIO port B)
const GPIOB_OUTPUT_VAL: *volatile u32 = @ptrFromInt(0x6000D004);
const GPIOB_OUTPUT_EN: *volatile u32 = @ptrFromInt(0x6000D014);
const GPIOB_INPUT_VAL: *volatile u32 = @ptrFromInt(0x6000D024);

/// GPIOC (8-bit GPIO port C)
const GPIOC_ENABLE: *volatile u32 = @ptrFromInt(0x6000D028);
const GPIOC_OUTPUT_EN: *volatile u32 = @ptrFromInt(0x6000D038);
const GPIOC_INPUT_VAL: *volatile u32 = @ptrFromInt(0x6000D048);

/// GPIOD (8-bit GPIO port D)
const GPIOD_OUTPUT_VAL: *volatile u32 = @ptrFromInt(0x6000D00C);
const GPIOD_OUTPUT_EN: *volatile u32 = @ptrFromInt(0x6000D01C);
const GPIOD_INPUT_VAL: *volatile u32 = @ptrFromInt(0x6000D02C);

// ============================================================
// Interrupt Controller Registers (0x6000F000 and 0x60004000)
// ============================================================

/// CPU interrupt controller
const CPU_INT_EN: *volatile u32 = @ptrFromInt(0x60004024);
const CPU_INT_CLR: *volatile u32 = @ptrFromInt(0x60004028);
const CPU_INT_STAT: *volatile u32 = @ptrFromInt(0x60004000);
const CPU_HI_INT_EN: *volatile u32 = @ptrFromInt(0x60004100);
const CPU_HI_INT_CLR: *volatile u32 = @ptrFromInt(0x60004104);

/// COP (coprocessor) interrupt controller
const COP_INT_EN: *volatile u32 = @ptrFromInt(0x60004034);
const COP_INT_CLR: *volatile u32 = @ptrFromInt(0x60004038);
const COP_HI_INT_EN: *volatile u32 = @ptrFromInt(0x60004110);
const COP_HI_INT_CLR: *volatile u32 = @ptrFromInt(0x60004114);

/// Timer register
const TIMER1_CFG: *volatile u32 = @ptrFromInt(0x60005000);
const TIMER1_VAL: *volatile u32 = @ptrFromInt(0x60005004);
const TIMER2_CFG: *volatile u32 = @ptrFromInt(0x60005008);
const TIMER2_VAL: *volatile u32 = @ptrFromInt(0x6000500C);
const USEC_TIMER: *volatile u32 = @ptrFromInt(0x60005010);

// ============================================================
// Cache Control Registers
// ============================================================

/// Cache control register
const CACHE_CTRL: *volatile u32 = @ptrFromInt(0xF0000000);

/// Cache operation register
const CACHE_OP: *volatile u32 = @ptrFromInt(0xF0000004);

// ============================================================
// PP5021C Device Enable Bits
// ============================================================

const DEV_EN_BITS = struct {
    // DEV_EN register bits (confirmed for iPod Video)
    const I2C: u32 = 1 << 0;
    const SERIAL0: u32 = 1 << 5;
    const ATA: u32 = 1 << 6;
    const USB: u32 = 1 << 7;
    const I2S: u32 = 1 << 11;
    const TIMER1: u32 = 1 << 13;
    const TIMER2: u32 = 1 << 14;
    const GPIO: u32 = 1 << 18;
    const DMA: u32 = 1 << 25;
    const AUDIO: u32 = 1 << 26;
};

// ============================================================
// Initialization State
// ============================================================

pub const InitState = enum {
    uninitialized,
    interrupts_disabled,
    clocks_configured,
    devices_enabled,
    gpio_configured,
    cache_initialized,
    fully_initialized,
    failed,
};

var init_state: InitState = .uninitialized;

// ============================================================
// Low-Level Functions
// ============================================================

/// Disable all interrupts (both CPU and COP)
pub fn disableInterrupts() void {
    // Clear CPU interrupt enable registers
    CPU_INT_EN.* = 0;
    CPU_HI_INT_EN.* = 0;

    // Clear COP interrupt enable registers
    COP_INT_EN.* = 0;
    COP_HI_INT_EN.* = 0;

    // Clear any pending interrupts
    CPU_INT_CLR.* = 0xFFFFFFFF;
    CPU_HI_INT_CLR.* = 0xFFFFFFFF;
    COP_INT_CLR.* = 0xFFFFFFFF;
    COP_HI_INT_CLR.* = 0xFFFFFFFF;

    // Disable interrupts at ARM core level
    asm volatile (
        \\mrs r0, cpsr
        \\orr r0, r0, #0xC0
        \\msr cpsr_c, r0
        ::: .{ .r0 = true });

    init_state = .interrupts_disabled;
}

/// Enable interrupts at ARM core level
pub fn enableInterrupts() void {
    asm volatile (
        \\mrs r0, cpsr
        \\bic r0, r0, #0xC0
        \\msr cpsr_c, r0
        ::: .{ .r0 = true });
}

/// Simple delay loop (approximately microseconds at 80MHz)
fn delayUs(us: u32) void {
    var i: u32 = 0;
    const cycles = us * 20; // Rough approximation
    while (i < cycles) : (i += 1) {
        asm volatile ("nop");
    }
}

/// Delay in milliseconds
pub fn delayMs(ms: u32) void {
    delayUs(ms * 1000);
}

/// Get microsecond timer value
pub fn getMicroseconds() u32 {
    return USEC_TIMER.*;
}

// ============================================================
// Clock Configuration
// ============================================================

/// Configure PLL for 80MHz operation
pub fn configurePll() void {
    // PP5022/PP5021C PLL configuration for 80MHz:
    // Formula: (mult/div * 24MHz) / 2 = 80MHz
    // So mult=20, div=3: (20/3 * 24) / 2 = 80

    // Set PLL control register
    // Value 0x8a121403 = 80MHz on PP5022
    PLL_CONTROL.* = 0x8a121403;

    // Wait for PLL to lock (bit 31 of status register)
    while ((PLL_STATUS.* & 0x80000000) == 0) {
        // Spin wait - add timeout in production
    }

    // Switch all clocks to PLL source
    // 0x20007777 = CPU, COP, DRAM, AHB all from PLL
    CLOCK_SOURCE.* = 0x20007777;

    init_state = .clocks_configured;
}

/// Get current CPU frequency in Hz (approximate)
pub fn getCpuFrequency() u32 {
    // When PLL is configured as above, CPU runs at ~80MHz
    // This is a rough estimate
    return 80_000_000;
}

// ============================================================
// Device Enable/Reset
// ============================================================

/// Enable and reset all necessary devices
pub fn enableDevices() void {
    // iPod Video specific device enable values (from Rockbox)
    DEV_EN.* = 0xc2000124;
    DEV_EN2.* = 0x00000000;

    // Set cache priority
    CACHE_PRIORITY.* = 0x0000003f;

    // Clear some GPO32 bits
    GPO32_VAL.* &= 0x00004000; // Preserve BCM power bit

    // Device init registers
    DEV_INIT1.* = 0x00000000;
    DEV_INIT2.* = 0x40000000;

    // Reset all devices
    DEV_RS.* = 0x3dfffef8;
    DEV_RS2.* = 0xffffffff;

    // Short delay for reset to take effect
    delayUs(100);

    // Clear reset
    DEV_RS.* = 0x00000000;
    DEV_RS2.* = 0x00000000;

    init_state = .devices_enabled;
}

/// Enable a specific device
pub fn enableDevice(device_bit: u32) void {
    DEV_EN.* |= device_bit;
}

/// Disable a specific device
pub fn disableDevice(device_bit: u32) void {
    DEV_EN.* &= ~device_bit;
}

// ============================================================
// GPIO Configuration
// ============================================================

/// Configure GPIO pins for iPod Video
pub fn configureGpio() void {
    // Configure GPO32 for BCM power control
    GPO32_ENABLE.* |= 0xC000; // Enable bits 14 and 15

    // Configure GPIOC for BCM
    GPIOC_ENABLE.* &= ~@as(u32, 0x80); // Disable bit 7
    GPIOC_ENABLE.* |= 0x40; // Enable bit 6 (BCM interrupt)
    GPIOC_OUTPUT_EN.* &= ~@as(u32, 0x40); // Bit 6 as input

    // Disable GPO32 bit 0
    GPO32_ENABLE.* &= ~@as(u32, 1);

    init_state = .gpio_configured;
}

/// Set GPIO pin high
pub fn gpioSetHigh(port: u8, pin: u8) void {
    const mask = @as(u32, 1) << pin;
    switch (port) {
        0 => GPIOA_OUTPUT_VAL.* |= mask,
        1 => GPIOB_OUTPUT_VAL.* |= mask,
        2 => {}, // GPIOC is special
        3 => GPIOD_OUTPUT_VAL.* |= mask,
        else => {},
    }
}

/// Set GPIO pin low
pub fn gpioSetLow(port: u8, pin: u8) void {
    const mask = @as(u32, 1) << pin;
    switch (port) {
        0 => GPIOA_OUTPUT_VAL.* &= ~mask,
        1 => GPIOB_OUTPUT_VAL.* &= ~mask,
        2 => {}, // GPIOC is special
        3 => GPIOD_OUTPUT_VAL.* &= ~mask,
        else => {},
    }
}

/// Read GPIO pin value
pub fn gpioRead(port: u8, pin: u8) bool {
    const mask = @as(u32, 1) << pin;
    const val = switch (port) {
        0 => GPIOA_INPUT_VAL.*,
        1 => GPIOB_INPUT_VAL.*,
        2 => GPIOC_INPUT_VAL.*,
        3 => GPIOD_INPUT_VAL.*,
        else => return false,
    };
    return (val & mask) != 0;
}

// ============================================================
// Cache Control
// ============================================================

/// Enable instruction and data caches
pub fn enableCache() void {
    // Invalidate caches first
    CACHE_OP.* = 2; // Invalidate I-cache
    CACHE_OP.* = 0; // Invalidate D-cache

    // Enable both caches
    // Bit 0 = D-cache enable
    // Bit 1 = I-cache enable
    CACHE_CTRL.* = 3;

    init_state = .cache_initialized;
}

/// Disable caches
pub fn disableCache() void {
    CACHE_CTRL.* = 0;
}

/// Flush data cache
pub fn flushDataCache() void {
    CACHE_OP.* = 1; // Flush D-cache
}

/// Invalidate instruction cache
pub fn invalidateICache() void {
    CACHE_OP.* = 2;
}

// ============================================================
// Full System Initialization
// ============================================================

/// Full PP5021C initialization sequence
pub fn init() !void {
    // Step 1: Disable all interrupts
    disableInterrupts();

    // Step 2: Configure PLL for 80MHz operation
    configurePll();

    // Step 3: Enable and reset devices
    enableDevices();

    // Step 4: Configure GPIO pins
    configureGpio();

    // Step 5: Enable caches (optional, can be done later)
    // Note: Leave caches disabled for now during debugging
    // enableCache();

    init_state = .fully_initialized;
}

/// Minimal bootloader initialization (just enough to get display working)
pub fn initMinimal() void {
    // Just disable interrupts and enable devices
    // Don't reconfigure PLL (Apple bootloader already set it up)

    disableInterrupts();
    configureGpio();

    init_state = .gpio_configured;
}

/// Get initialization state
pub fn getState() InitState {
    return init_state;
}

/// Check if system is fully initialized
pub fn isInitialized() bool {
    return init_state == .fully_initialized or init_state == .gpio_configured;
}

// ============================================================
// Watchdog Timer (if available)
// ============================================================

/// Watchdog timer registers (PP5022)
const WATCHDOG_COUNT: *volatile u32 = @ptrFromInt(0x60005030);
const WATCHDOG_CTRL: *volatile u32 = @ptrFromInt(0x60005034);

/// Enable watchdog timer
pub fn enableWatchdog(timeout_ms: u32) void {
    // Watchdog uses USEC_TIMER
    // timeout_ms * 1000 = microseconds before reset
    WATCHDOG_COUNT.* = timeout_ms * 1000;
    WATCHDOG_CTRL.* = 1; // Enable
}

/// Kick/reset watchdog timer
pub fn kickWatchdog() void {
    // Reset the count
    WATCHDOG_COUNT.* = WATCHDOG_COUNT.*;
}

/// Disable watchdog timer
pub fn disableWatchdog() void {
    WATCHDOG_CTRL.* = 0;
}

// ============================================================
// Sleep/Power Management
// ============================================================

/// Enter CPU sleep mode (wait for interrupt)
pub fn sleep() void {
    asm volatile (
        \\mov r0, #0
        \\mcr p15, 0, r0, c7, c0, 4
        ::: .{ .r0 = true });
}

/// System reset via watchdog
pub fn systemReset() noreturn {
    // Trigger immediate watchdog reset
    WATCHDOG_COUNT.* = 1;
    WATCHDOG_CTRL.* = 1;

    // Wait for reset
    while (true) {
        asm volatile ("nop");
    }
}

// ============================================================
// Tests (for host/simulator only)
// ============================================================

test "init state transitions" {
    // These tests only verify the enum values, not hardware access
    try std.testing.expectEqual(InitState.uninitialized, init_state);
}
