//! Minimal Boot Test - Simple Main Entry
//!
//! Skip all PP5021C re-initialization since Apple bootloader already did it.
//! Just initialize BCM and call a simple main loop.

const builtin = @import("builtin");

// Only compile for ARM
comptime {
    if (builtin.cpu.arch == .arm) {
        @export(&_start, .{ .name = "_start" });
    }
}

/// Minimal entry point
fn _start() callconv(.naked) noreturn {
    // Disable IRQ/FIQ at ARM core level (safe)
    asm volatile (
        \\msr cpsr_c, #0xdf
    );

    // Set up stack in SDRAM (Apple already initialized SDRAM)
    asm volatile (
        \\ldr sp, =0x40008000
    );

    // Jump to Zig code
    asm volatile (
        \\bl _zigpod_main
    );

    // Should never reach here
    asm volatile (
        \\1: b 1b
    );
}

// BCM registers
const BCM_DATA32: *volatile u32 = @ptrFromInt(0x30000000);
const BCM_WR_ADDR32: *volatile u32 = @ptrFromInt(0x30010000);
const BCM_CONTROL: *volatile u16 = @ptrFromInt(0x30030000);

const BCMA_CMDPARAM: u32 = 0xE0000;
const BCMA_COMMAND: u32 = 0x1F8;
const BCMCMD_LCD_UPDATE: u32 = 0xFFFF0000;

// Colors (RGB565 as u32 for fillScreen - two pixels packed)
const COLOR32_BLACK: u32 = 0x00000000;
const COLOR32_WHITE: u32 = 0xFFFFFFFF;
const COLOR32_RED: u32 = 0xF800F800;
const COLOR32_GREEN: u32 = 0x07E007E0;
const COLOR32_BLUE: u32 = 0x001F001F;
const COLOR32_YELLOW: u32 = 0xFFE0FFE0;
const COLOR32_CYAN: u32 = 0x07FF07FF;
const COLOR32_MAGENTA: u32 = 0xF81FF81F;

// 5.5G PWM backlight control
const PWM_BACKLIGHT: *volatile u32 = @ptrFromInt(0x6000B004);

// Click wheel registers - from Rockbox bootloader/ipod.c
const WHEEL_CTRL: *volatile u32 = @ptrFromInt(0x7000C100);   // Control register
const WHEEL_STATUS: *volatile u32 = @ptrFromInt(0x7000C104); // Status register
const WHEEL_TX: *volatile u32 = @ptrFromInt(0x7000C120);     // TX data (send command here)
const WHEEL_DATA: *volatile u32 = @ptrFromInt(0x7000C140);   // RX data (read response here)

// GPIO B registers for click wheel serial communication
const GPIOB_ENABLE: *volatile u32 = @ptrFromInt(0x6000D020);
const GPIOB_OUTPUT_EN: *volatile u32 = @ptrFromInt(0x6000D030);
const GPIOB_OUTPUT_VAL: *volatile u32 = @ptrFromInt(0x6000D034);

// Microsecond timer for timeouts
const USEC_TIMER: *volatile u32 = @ptrFromInt(0x60005010);

// Device enable registers
const DEV_RS: *volatile u32 = @ptrFromInt(0x60006004);   // Device reset
const DEV_EN: *volatile u32 = @ptrFromInt(0x6000600C);   // Device enable
const DEV_INIT1: *volatile u32 = @ptrFromInt(0x70000010); // Device init 1

// Device bits
const DEV_OPTO: u32 = 0x00010000;      // Click wheel enable
const INIT_BUTTONS: u32 = 0x00040000;  // Button detection enable

// Wheel polling command (from Rockbox bootloader)
const WHEEL_CMD: u32 = 0x8000023A;

// Status bits
const WHEEL_STATUS_DATA_READY: u32 = 0x04000000;  // Bit 26 - data available
const WHEEL_STATUS_BUSY: u32 = 0x80000000;        // Bit 31 - transfer in progress
const WHEEL_STATUS_CLEAR: u32 = 0x0C000000;       // Clear bits
const WHEEL_CTRL_START: u32 = 0x80000000;         // Start transfer
const WHEEL_CTRL_ACK: u32 = 0x60000000;           // Acknowledge bits

// Button bits from wheel packet - 5.5G CONFIRMED mapping
// These are the bit positions in the data word (bits 8-13)
const BTN_SELECT: u32 = 0x00000100;  // Bit 8
const BTN_RIGHT: u32 = 0x00000200;   // Bit 9
const BTN_LEFT: u32 = 0x00000400;    // Bit 10
const BTN_PLAY: u32 = 0x00000800;    // Bit 11
const BTN_MENU: u32 = 0x00002000;    // Bit 13 (NOT bit 12!)

// Initialize click wheel - full sequence from Rockbox opto_i2c_init()
fn initWheel() void {
    // Step 1: Enable OPTO device
    DEV_EN.* |= DEV_OPTO;

    // Step 2: Reset the OPTO device
    DEV_RS.* |= DEV_OPTO;

    // Step 3: Wait for reset (at least 5us)
    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        asm volatile ("nop");
    }

    // Step 4: Release reset
    DEV_RS.* &= ~DEV_OPTO;

    // Step 5: Enable button detection
    DEV_INIT1.* |= INIT_BUTTONS;

    // Step 6: Configure wheel controller (from Rockbox opto_i2c_init)
    WHEEL_CTRL.* = 0xC00A1F00;
    WHEEL_STATUS.* = 0x01000000;
}

// Send configuration command to click wheel (from Rockbox bootloader)
// This is the key - we must SEND a command to GET data back!
fn wheelSendCommand(val: u32) void {
    // Disable GPIO B bit 7
    GPIOB_ENABLE.* &= ~@as(u32, 0x80);

    // Clear status
    WHEEL_STATUS.* = WHEEL_STATUS.* | WHEEL_STATUS_CLEAR;

    // Send command to TX register
    WHEEL_TX.* = val;

    // Start transfer (set bit 31)
    WHEEL_CTRL.* = WHEEL_CTRL.* | WHEEL_CTRL_START;

    // Configure GPIO B for output
    GPIOB_OUTPUT_VAL.* &= ~@as(u32, 0x10);
    GPIOB_OUTPUT_EN.* |= 0x10;

    // Wait for transfer complete (bit 31 goes low) with timeout
    var timeout: u32 = 0;
    while ((WHEEL_STATUS.* & WHEEL_STATUS_BUSY) != 0) {
        timeout += 1;
        if (timeout > 150000) break;  // ~1.5ms at 80MHz
        asm volatile ("nop");
    }

    // Clear start bit
    WHEEL_CTRL.* = WHEEL_CTRL.* & ~WHEEL_CTRL_START;

    // Restore GPIO B
    GPIOB_ENABLE.* |= 0x80;
    GPIOB_OUTPUT_VAL.* |= 0x10;
    GPIOB_OUTPUT_EN.* &= ~@as(u32, 0x10);

    // Acknowledge
    WHEEL_STATUS.* = WHEEL_STATUS.* | WHEEL_STATUS_CLEAR;
    WHEEL_CTRL.* = WHEEL_CTRL.* | WHEEL_CTRL_ACK;
}

// Poll click wheel for button/wheel data (from Rockbox bootloader)
// Returns button state (0-31) or 0 if no button pressed
fn readWheel() u8 {
    var attempts: u32 = 5;

    while (attempts > 0) {
        // Send polling command
        wheelSendCommand(WHEEL_CMD);

        // Wait for data with timeout
        var timeout: u32 = 0;
        var got_data = false;
        while (timeout < 150000) : (timeout += 1) {
            if ((WHEEL_STATUS.* & WHEEL_STATUS_DATA_READY) != 0) {
                got_data = true;
                break;
            }
            asm volatile ("nop");
        }

        if (!got_data) {
            attempts -= 1;
            continue;
        }

        // Read data
        const data = WHEEL_DATA.*;

        // Validate packet: (data & ~0x7fff0000) should equal WHEEL_CMD
        if ((data & ~@as(u32, 0x7FFF0000)) != WHEEL_CMD) {
            attempts -= 1;
            continue;
        }

        // Acknowledge
        WHEEL_CTRL.* = WHEEL_CTRL.* | WHEEL_CTRL_ACK;
        WHEEL_STATUS.* = WHEEL_STATUS.* | WHEEL_STATUS_CLEAR;

        // Extract button state: (data << 11) >> 27, then XOR with 0x1F
        const buttons = @as(u8, @truncate((data << 11) >> 27)) ^ 0x1F;
        return buttons;
    }

    return 0;  // No button pressed
}

// Extract button state from wheel packet - CORRECTED bit positions
// Buttons are in bits 8-12 of the packet:
//   Bit 8:  SELECT (center)
//   Bit 9:  RIGHT (forward)
//   Bit 10: LEFT (back)
//   Bit 11: PLAY/PAUSE
//   Bit 12: MENU
fn getButtons(packet: u32) u8 {
    var buttons: u8 = 0;
    if (packet & 0x00000100 != 0) buttons |= BTN_SELECT;  // Bit 8
    if (packet & 0x00000200 != 0) buttons |= BTN_RIGHT;   // Bit 9
    if (packet & 0x00000400 != 0) buttons |= BTN_LEFT;    // Bit 10
    if (packet & 0x00000800 != 0) buttons |= BTN_PLAY;    // Bit 11
    if (packet & 0x00001000 != 0) buttons |= BTN_MENU;    // Bit 12
    return buttons;
}

// Extract wheel position from wheel packet (0-95)
// Wheel position is in bits 16-22, bit 30 indicates touch
fn getWheelPosition(packet: u32) u8 {
    return @truncate((packet >> 16) & 0x7F);  // 7 bits, not 8
}

// Check if wheel is being touched
fn isWheelTouched(packet: u32) bool {
    return (packet & 0x40000000) != 0;  // Bit 30
}

fn bcmWriteAddr(addr: u32) void {
    BCM_WR_ADDR32.* = addr;
    while ((BCM_CONTROL.* & 0x2) == 0) {
        asm volatile ("nop");
    }
}

fn fillScreen(color: u32) void {
    bcmWriteAddr(BCMA_CMDPARAM);
    var i: u32 = 0;
    while (i < 320 * 240 / 2) : (i += 1) {
        BCM_DATA32.* = color;
    }
    bcmWriteAddr(BCMA_COMMAND);
    BCM_DATA32.* = BCMCMD_LCD_UPDATE;
    BCM_CONTROL.* = 0x31;
}

fn delay() void {
    var i: u32 = 0;
    while (i < 3000000) : (i += 1) {
        asm volatile ("nop");
    }
}

// Draw directly to BCM - no framebuffer needed
// Draws a horizontal line of colored pixels
fn drawLine(y: u16, x_start: u16, x_end: u16, color: u16) void {
    const color32: u32 = @as(u32, color) | (@as(u32, color) << 16);
    // Calculate BCM address for this line
    const line_addr = BCMA_CMDPARAM + @as(u32, y) * 320 * 2 + @as(u32, x_start) * 2;
    bcmWriteAddr(line_addr);

    var x = x_start;
    while (x < x_end) : (x += 2) {
        BCM_DATA32.* = color32;
    }
}

fn drawUI() void {
    // Colors (u16 for drawLine)
    const white: u16 = 0xFFFF;
    const dark_gray: u16 = 0x4208;
    const menu_green: u16 = 0x07E0;
    const title_blue: u16 = 0x001F;

    // First, fill entire screen black
    fillScreen(COLOR32_BLACK);

    // Draw title bar (white, top 24 lines)
    var y: u16 = 0;
    while (y < 24) : (y += 1) {
        drawLine(y, 0, 320, white);
    }

    // Draw blue "ZigPod" indicator in title bar
    y = 4;
    while (y < 20) : (y += 1) {
        drawLine(y, 10, 70, title_blue);
    }

    // Draw green battery indicator
    y = 4;
    while (y < 20) : (y += 1) {
        drawLine(y, 280, 310, menu_green);
    }

    // Draw menu item 1 (Music) - green highlight
    y = 40;
    while (y < 60) : (y += 1) {
        drawLine(y, 10, 310, menu_green);
    }

    // Draw menu item 2 (Files) - gray
    y = 65;
    while (y < 85) : (y += 1) {
        drawLine(y, 10, 310, dark_gray);
    }

    // Draw menu item 3 (Settings) - gray
    y = 90;
    while (y < 110) : (y += 1) {
        drawLine(y, 10, 310, dark_gray);
    }

    // Draw menu item 4 (Now Playing) - gray
    y = 115;
    while (y < 135) : (y += 1) {
        drawLine(y, 10, 310, dark_gray);
    }

    // Final update command
    bcmWriteAddr(BCMA_COMMAND);
    BCM_DATA32.* = BCMCMD_LCD_UPDATE;
    BCM_CONTROL.* = 0x31;
}

// Menu state
var selected_item: u8 = 0;
const MENU_ITEMS: u8 = 4;

fn drawMenuItem(index: u8, selected: bool) void {
    const y_start: u16 = 40 + @as(u16, index) * 25;
    const y_end: u16 = y_start + 20;

    // Colors
    const highlight: u16 = 0x07E0; // Green
    const normal: u16 = 0x4208;    // Dark gray
    const color = if (selected) highlight else normal;

    var y = y_start;
    while (y < y_end) : (y += 1) {
        drawLine(y, 10, 310, color);
    }
}

fn drawMenuItems() void {
    var i: u8 = 0;
    while (i < MENU_ITEMS) : (i += 1) {
        drawMenuItem(i, i == selected_item);
    }

    // Update display
    bcmWriteAddr(BCMA_COMMAND);
    BCM_DATA32.* = BCMCMD_LCD_UPDATE;
    BCM_CONTROL.* = 0x31;
}

export fn _zigpod_main() void {
    // Set backlight to maximum (5.5G enhancement)
    PWM_BACKLIGHT.* = 0x0000FFFF;

    // Show startup sequence
    fillScreen(COLOR32_RED);
    delay();
    fillScreen(COLOR32_GREEN);
    delay();
    fillScreen(COLOR32_BLUE);
    delay();

    // Initialize click wheel
    DEV_EN.* |= DEV_OPTO;
    DEV_RS.* |= DEV_OPTO;
    var i: u32 = 0;
    while (i < 5000) : (i += 1) asm volatile ("nop");
    DEV_RS.* &= ~DEV_OPTO;
    DEV_INIT1.* |= INIT_BUTTONS;
    WHEEL_CTRL.* = 0xC00A1F00;
    WHEEL_STATUS.* = 0x01000000;

    // Show CYAN = init complete
    fillScreen(COLOR32_CYAN);
    delay();

    // Main loop - poll wheel and show button colors
    fillScreen(COLOR32_BLACK);

    while (true) {
        const status = WHEEL_STATUS.*;

        // Check data ready bit (bit 26)
        if ((status & 0x04000000) != 0) {
            const data = WHEEL_DATA.*;

            // Acknowledge the read
            WHEEL_STATUS.* = WHEEL_STATUS.* | 0x0C000000;
            WHEEL_CTRL.* = WHEEL_CTRL.* | 0x60000000;

            // Validate packet: lower byte must be 0x1A
            // NOTE: MENU packets don't have bit 31 set, so only check lower byte!
            if ((data & 0xFF) == 0x1A) {
                // 5.5G Button mapping (CONFIRMED WORKING January 2026):
                // Bit 8  (0x0100) = SELECT
                // Bit 9  (0x0200) = RIGHT
                // Bit 10 (0x0400) = LEFT
                // Bit 11 (0x0800) = PLAY
                // Bit 12 (0x1000) = MENU (alternative)
                // Bit 13 (0x2000) = MENU (primary)

                if ((data & 0x00002000) != 0 or (data & 0x00001000) != 0) {
                    fillScreen(COLOR32_RED);     // MENU = Red
                } else if ((data & 0x00000100) != 0) {
                    fillScreen(COLOR32_WHITE);   // SELECT = White
                } else if ((data & 0x00000800) != 0) {
                    fillScreen(COLOR32_GREEN);   // PLAY = Green
                } else if ((data & 0x00000400) != 0) {
                    fillScreen(COLOR32_BLUE);    // LEFT = Blue
                } else if ((data & 0x00000200) != 0) {
                    fillScreen(COLOR32_YELLOW);  // RIGHT = Yellow
                } else {
                    fillScreen(COLOR32_BLACK);   // No button
                }
            }
        }

        // Small delay
        var j: u32 = 0;
        while (j < 5000) : (j += 1) asm volatile ("nop");
    }
}
