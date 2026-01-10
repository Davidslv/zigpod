//! BCM2722 Graphics Chip Driver for iPod Video
//!
//! The iPod Video uses a Broadcom BCM2722 chip for LCD control.
//! This is NOT a simple LCD controller - it's a separate processor that
//! handles all display operations.
//!
//! The BCM requires:
//! 1. Power-on via GPIO
//! 2. A 3-stage bootstrap sequence
//! 3. Firmware upload from iPod ROM
//! 4. Command protocol for display updates
//!
//! Based on Rockbox lcd-video.c by Bernard Leach and Dave Chapman.

const std = @import("std");
const builtin = @import("builtin");

// ============================================================
// BCM Register Addresses (Memory-mapped at 0x30000000)
// ============================================================

/// BCM data register - write pixel data here
const BCM_DATA: *volatile u16 = @ptrFromInt(0x30000000);
const BCM_DATA32: *volatile u32 = @ptrFromInt(0x30000000);

/// BCM write address register - set destination address
const BCM_WR_ADDR: *volatile u16 = @ptrFromInt(0x30010000);
const BCM_WR_ADDR32: *volatile u32 = @ptrFromInt(0x30010000);

/// BCM read address register - set source address
const BCM_RD_ADDR: *volatile u16 = @ptrFromInt(0x30020000);
const BCM_RD_ADDR32: *volatile u32 = @ptrFromInt(0x30020000);

/// BCM control register
const BCM_CONTROL: *volatile u16 = @ptrFromInt(0x30030000);

/// BCM alternate registers (used during bootstrap)
const BCM_ALT_DATA: *volatile u16 = @ptrFromInt(0x30040000);
const BCM_ALT_DATA32: *volatile u32 = @ptrFromInt(0x30040000);
const BCM_ALT_WR_ADDR: *volatile u16 = @ptrFromInt(0x30050000);
const BCM_ALT_WR_ADDR32: *volatile u32 = @ptrFromInt(0x30050000);
const BCM_ALT_RD_ADDR: *volatile u16 = @ptrFromInt(0x30060000);
const BCM_ALT_RD_ADDR32: *volatile u32 = @ptrFromInt(0x30060000);
const BCM_ALT_CONTROL: *volatile u16 = @ptrFromInt(0x30070000);

// ============================================================
// BCM Internal Addresses
// ============================================================

/// BCM SRAM base - firmware is uploaded here
const BCMA_SRAM_BASE: u32 = 0x0;

/// BCM command register address
const BCMA_COMMAND: u32 = 0x1F8;

/// BCM status register address
const BCMA_STATUS: u32 = 0x1FC;

/// BCM command parameter area - framebuffer data goes here
const BCMA_CMDPARAM: u32 = 0xE0000;

/// BCM SDRAM base (for TV out, not used for LCD)
const BCMA_SDRAM_BASE: u32 = 0xC0000000;

// ============================================================
// BCM Commands
// ============================================================

/// Encode a BCM command (inverted in upper 16 bits, normal in lower 16)
fn bcmCmd(x: u16) u32 {
    return (~@as(u32, x) << 16) | @as(u32, x);
}

/// LCD update command - tells BCM to refresh display
const BCMCMD_LCD_UPDATE: u32 = bcmCmd(0);

/// LCD sleep command - puts LCD in low power mode
const BCMCMD_LCD_SLEEP: u32 = bcmCmd(8);

/// LCD partial update command
const BCMCMD_LCD_UPDATERECT: u32 = bcmCmd(5);

// ============================================================
// PP5021C GPIO Registers (for BCM power control)
// ============================================================

/// GPO32 value register - bit 14 controls BCM power
const GPO32_VAL: *volatile u32 = @ptrFromInt(0x6000D0A0);
const GPO32_ENABLE: *volatile u32 = @ptrFromInt(0x6000D0B0);

/// GPIOC registers (BCM interrupt pin)
const GPIOC_ENABLE: *volatile u32 = @ptrFromInt(0x6000D020);
const GPIOC_OUTPUT_EN: *volatile u32 = @ptrFromInt(0x6000D030);

/// STRAP_OPT_A register
const STRAP_OPT_A: *volatile u32 = @ptrFromInt(0x70000080);

// ============================================================
// ROM Constants
// ============================================================

/// ROM base address where iPod firmware is stored
const ROM_BASE: u32 = 0x20000000;

/// ROM image ID for BCM firmware ("vmcs")
const ROM_ID_VMCS: u32 = 0x766D6373; // "vmcs" in little-endian

// ============================================================
// Display Constants
// ============================================================

pub const LCD_WIDTH: u16 = 320;
pub const LCD_HEIGHT: u16 = 240;
pub const LCD_BPP: u8 = 16; // RGB565

// ============================================================
// BCM State
// ============================================================

const BcmState = enum {
    uninitialized,
    powered_off,
    initializing,
    ready,
    updating,
    failed,
};

var bcm_state: BcmState = .uninitialized;
var vmcs_offset: u32 = 0;
var vmcs_length: u32 = 0;

// ============================================================
// Bootstrap Data
// ============================================================

/// Data written to BCM_CONTROL and BCM_ALT_CONTROL during bootstrap
const bootstrap_data = [_]u8{ 0xA1, 0x81, 0x91, 0x02, 0x12, 0x22, 0x72, 0x62 };

// ============================================================
// Low-Level BCM Functions
// ============================================================

/// Write a destination address to BCM
fn bcmWriteAddr(address: u32) void {
    BCM_WR_ADDR32.* = address;

    // Wait for BCM to be ready for write
    while ((BCM_CONTROL.* & 0x2) == 0) {
        // Spin wait
    }
}

/// Write a 32-bit value to a BCM address
fn bcmWrite32(address: u32, value: u32) void {
    bcmWriteAddr(address);
    BCM_DATA32.* = value;
}

/// Read a 32-bit value from a BCM address
fn bcmRead32(address: u32) u32 {
    // Wait for read address register to be ready
    while ((BCM_RD_ADDR.* & 1) == 0) {
        // Spin wait
    }

    BCM_RD_ADDR32.* = address;

    // Wait for data to be ready
    while ((BCM_CONTROL.* & 0x10) == 0) {
        // Spin wait
    }

    return BCM_DATA32.*;
}

/// Write pixel data to BCM
fn bcmWriteData(data: []const u16) void {
    for (data) |pixel| {
        BCM_DATA.* = pixel;
    }
}

/// Write pixel data as 32-bit words (faster)
fn bcmWriteData32(data: []const u32) void {
    for (data) |word| {
        BCM_DATA32.* = word;
    }
}

// ============================================================
// Delay Function
// ============================================================

/// Simple delay loop (approximately microseconds on PP5021C at 80MHz)
fn delayUs(us: u32) void {
    // At 80MHz, ~80 cycles per microsecond
    // This is a rough approximation
    var i: u32 = 0;
    const cycles = us * 20; // Reduced for loop overhead
    while (i < cycles) : (i += 1) {
        asm volatile ("nop");
    }
}

/// Delay in milliseconds
pub fn delayMs(ms: u32) void {
    delayUs(ms * 1000);
}

// ============================================================
// ROM Flash Functions
// ============================================================

/// Find a section in iPod ROM flash by image ID
fn flashGetSection(image_id: u32) ?struct { offset: u32, length: u32 } {
    // ROM directory is at ROM_BASE + 0xffe00
    var p: [*]const u32 = @ptrFromInt(ROM_BASE + 0xffe00);

    // Search for the image in the directory
    while (true) {
        // Check for "flsh" magic
        if (p[0] != 0x666C7368) { // "flsh" in little-endian
            return null;
        }

        if (p[1] == image_id) {
            // Found it - get offset and length
            const offset = p[3];
            const length = p[4];

            // Verify checksum (optional but good practice)
            var checksum: u32 = 0;
            const data: [*]const u8 = @ptrFromInt(ROM_BASE + offset);
            for (0..length) |i| {
                checksum +%= data[i];
            }

            if (checksum == p[7]) {
                return .{
                    .offset = ROM_BASE + offset,
                    .length = length,
                };
            }
            return null;
        }

        // Move to next directory entry (10 words per entry)
        p += 10;
    }
}

// ============================================================
// BCM Initialization
// ============================================================

/// Initialize BCM GPIO pins
fn bcmInitGpio() void {
    // Enable GPO32 bits for BCM control
    GPO32_ENABLE.* |= 0xC000;

    // Disable GPIOC bit 7
    GPIOC_ENABLE.* &= ~@as(u32, 0x80);

    // Enable GPIOC bit 6 for BCM interrupts (input)
    GPIOC_ENABLE.* |= 0x40;
    GPIOC_OUTPUT_EN.* &= ~@as(u32, 0x40);

    // Disable GPO32 bit 0
    GPO32_ENABLE.* &= ~@as(u32, 1);
}

/// Power on the BCM chip
fn bcmPowerOn() void {
    GPO32_VAL.* |= 0x4000;
    delayMs(50); // BCM needs time to power up
}

/// Power off the BCM chip
pub fn bcmPowerOff() void {
    GPO32_VAL.* &= ~@as(u32, 0x4000);
    bcm_state = .powered_off;
}

/// Bootstrap stage 1 - initial setup
fn bcmBootstrapStage1() void {
    STRAP_OPT_A.* &= ~@as(u32, 0xF00);

    // Write to mystery register
    const reg: *volatile u32 = @ptrFromInt(0x70000040);
    reg.* = 0x1313;
}

/// Bootstrap stage 2 - handshake with BCM
fn bcmBootstrapStage2() void {
    // Wait for BCM_ALT_CONTROL bit 7 to clear
    while ((BCM_ALT_CONTROL.* & 0x80) != 0) {
        // Spin wait
    }

    // Wait for BCM_ALT_CONTROL bit 6 to set
    while ((BCM_ALT_CONTROL.* & 0x40) == 0) {
        // Spin wait
    }

    // Write bootstrap data to BCM_CONTROL
    for (bootstrap_data) |byte| {
        BCM_CONTROL.* = byte;
    }

    // Write bootstrap data (starting from index 3) to BCM_ALT_CONTROL
    for (bootstrap_data[3..]) |byte| {
        BCM_ALT_CONTROL.* = byte;
    }

    // Wait for both read address registers to be ready
    while ((BCM_RD_ADDR.* & 1) == 0 or (BCM_ALT_RD_ADDR.* & 1) == 0) {
        // Spin wait
    }

    // Read from write address registers (clears them)
    _ = BCM_WR_ADDR.*;
    _ = BCM_ALT_WR_ADDR.*;
}

/// Bootstrap stage 3 - upload firmware
fn bcmBootstrapStage3() !void {
    // Wait for BCM_ALT_CONTROL ready
    while ((BCM_ALT_CONTROL.* & 0x80) != 0) {
        // Spin wait
    }
    while ((BCM_ALT_CONTROL.* & 0x40) == 0) {
        // Spin wait
    }

    // Get vmcs firmware from ROM
    const vmcs = flashGetSection(ROM_ID_VMCS) orelse {
        bcm_state = .failed;
        return error.VmcsFirmwareNotFound;
    };

    vmcs_offset = vmcs.offset;
    vmcs_length = vmcs.length;

    // Round up to even number of 16-bit words
    const upload_length = ((vmcs.length + 3) >> 1) & ~@as(u32, 1);

    // Upload firmware to BCM SRAM
    bcmWriteAddr(BCMA_SRAM_BASE);

    // Write firmware data
    const fw_data: [*]const u16 = @ptrFromInt(vmcs.offset);
    for (0..upload_length) |i| {
        BCM_DATA.* = fw_data[i];
    }

    // Initialize BCM
    bcmWrite32(BCMA_COMMAND, 0);
    bcmWrite32(0x10000C00, 0xC0000000);

    // Wait for BCM to start
    while ((bcmRead32(0x10000C00) & 1) == 0) {
        // Spin wait - but add timeout in real implementation
    }

    bcmWrite32(0x10000C00, 0);
    bcmWrite32(0x10000400, 0xA5A50002);

    // Wait for BCM command to be non-zero (firmware running)
    var timeout: u32 = 0;
    while (bcmRead32(BCMA_COMMAND) == 0) {
        delayMs(1);
        timeout += 1;
        if (timeout > 500) {
            bcm_state = .failed;
            return error.BcmFirmwareTimeout;
        }
    }
}

/// Full BCM initialization
pub fn init() !void {
    if (bcm_state == .ready) {
        return; // Already initialized
    }

    bcm_state = .initializing;

    // Initialize GPIO pins for BCM
    bcmInitGpio();

    // Power on BCM
    bcmPowerOn();

    // Bootstrap stage 1
    bcmBootstrapStage1();

    // Bootstrap stage 2
    bcmBootstrapStage2();

    // Bootstrap stage 3 - upload firmware
    try bcmBootstrapStage3();

    bcm_state = .ready;
}

// ============================================================
// LCD Update Functions
// ============================================================

/// Check if BCM is busy with an update
fn bcmIsBusy() bool {
    const cmd = bcmRead32(BCMA_COMMAND);
    return cmd == BCMCMD_LCD_UPDATE or cmd == 0xFFFF;
}

/// Wait for BCM to finish current operation
fn bcmWaitReady() void {
    while (bcmIsBusy()) {
        // Could add timeout here
    }
}

/// Update the entire LCD with new framebuffer data
pub fn updateFull(framebuffer: []const u16) void {
    if (bcm_state != .ready) {
        return;
    }

    bcmWaitReady();

    // Set destination address to command parameter area
    bcmWriteAddr(BCMA_CMDPARAM);

    // Write framebuffer data
    for (framebuffer) |pixel| {
        BCM_DATA.* = pixel;
    }

    // Trigger LCD update
    bcmWrite32(BCMA_COMMAND, BCMCMD_LCD_UPDATE);
    BCM_CONTROL.* = 0x31;
}

/// Update a rectangular region of the LCD
pub fn updateRect(x: u16, y: u16, width: u16, height: u16, data: []const u16) void {
    if (bcm_state != .ready) {
        return;
    }

    // Ensure x and width are even (BCM requirement)
    const adj_x = x & ~@as(u16, 1);
    const adj_width = (width + (x & 1) + 1) & ~@as(u16, 1);

    bcmWaitReady();

    var bcmaddr = BCMA_CMDPARAM + @as(u32, LCD_WIDTH) * 2 * @as(u32, y) + @as(u32, adj_x) * 2;
    var data_offset: usize = 0;

    if (adj_width == LCD_WIDTH) {
        // Full width - can write all at once
        bcmWriteAddr(bcmaddr);
        for (data) |pixel| {
            BCM_DATA.* = pixel;
        }
    } else {
        // Partial width - write line by line
        var row: u16 = 0;
        while (row < height) : (row += 1) {
            bcmWriteAddr(bcmaddr);
            bcmaddr += LCD_WIDTH * 2;

            for (0..adj_width) |_| {
                if (data_offset < data.len) {
                    BCM_DATA.* = data[data_offset];
                    data_offset += 1;
                }
            }
        }
    }

    // Trigger LCD update
    bcmWrite32(BCMA_COMMAND, BCMCMD_LCD_UPDATE);
    BCM_CONTROL.* = 0x31;
}

/// Clear the LCD to a single color
pub fn clear(color: u16) void {
    if (bcm_state != .ready) {
        return;
    }

    bcmWaitReady();

    bcmWriteAddr(BCMA_CMDPARAM);

    // Fill framebuffer with color
    const total_pixels = @as(u32, LCD_WIDTH) * @as(u32, LCD_HEIGHT);
    for (0..total_pixels) |_| {
        BCM_DATA.* = color;
    }

    // Trigger LCD update
    bcmWrite32(BCMA_COMMAND, BCMCMD_LCD_UPDATE);
    BCM_CONTROL.* = 0x31;
}

/// Put LCD into sleep mode
pub fn sleep() void {
    if (bcm_state != .ready) {
        return;
    }

    bcmWaitReady();

    // Not sure what this does - from Rockbox
    bcmWrite32(0x10001400, bcmRead32(0x10001400) & ~@as(u32, 0xF0));

    // Send sleep command
    bcmWrite32(BCMA_COMMAND, BCMCMD_LCD_SLEEP);
    BCM_CONTROL.* = 0x31;
    bcmWaitReady();

    // Additional shutdown command
    bcmWrite32(BCMA_COMMAND, bcmCmd(0xC));
    BCM_CONTROL.* = 0x31;
    bcmWaitReady();

    // Power off BCM
    bcmPowerOff();
}

// ============================================================
// Color Conversion
// ============================================================

/// Convert RGB888 to RGB565
pub fn rgb565(r: u8, g: u8, b: u8) u16 {
    return (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | @as(u16, b >> 3);
}

/// Common colors in RGB565 format
pub const Color = struct {
    pub const BLACK: u16 = 0x0000;
    pub const WHITE: u16 = 0xFFFF;
    pub const RED: u16 = 0xF800;
    pub const GREEN: u16 = 0x07E0;
    pub const BLUE: u16 = 0x001F;
    pub const YELLOW: u16 = 0xFFE0;
    pub const CYAN: u16 = 0x07FF;
    pub const MAGENTA: u16 = 0xF81F;
    pub const GRAY: u16 = 0x8410;
    pub const DARK_GRAY: u16 = 0x4208;
};

// ============================================================
// Status Functions
// ============================================================

/// Check if BCM is initialized and ready
pub fn isReady() bool {
    return bcm_state == .ready;
}

/// Get current BCM state
pub fn getState() BcmState {
    return bcm_state;
}

// ============================================================
// Tests (for simulator/host)
// ============================================================

test "rgb565 conversion" {
    const white = rgb565(255, 255, 255);
    try std.testing.expectEqual(@as(u16, 0xFFFF), white);

    const black = rgb565(0, 0, 0);
    try std.testing.expectEqual(@as(u16, 0x0000), black);

    const red = rgb565(255, 0, 0);
    try std.testing.expectEqual(@as(u16, 0xF800), red);

    const green = rgb565(0, 255, 0);
    try std.testing.expectEqual(@as(u16, 0x07E0), green);

    const blue = rgb565(0, 0, 255);
    try std.testing.expectEqual(@as(u16, 0x001F), blue);
}

test "bcm command encoding" {
    const cmd0 = bcmCmd(0);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), cmd0);

    const cmd8 = bcmCmd(8);
    try std.testing.expectEqual(@as(u32, 0xFFF70008), cmd8);
}
