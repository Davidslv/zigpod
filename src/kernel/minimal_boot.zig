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

// Click wheel registers - CORRECTED from Rockbox research
// See docs/ROCKBOX_REFERENCE.md for details
const WHEEL_CTRL: *volatile u32 = @ptrFromInt(0x7000C100);   // Control register
const WHEEL_STATUS: *volatile u32 = @ptrFromInt(0x7000C104); // Status register
const WHEEL_TX: *volatile u32 = @ptrFromInt(0x7000C120);     // TX data
const WHEEL_DATA: *volatile u32 = @ptrFromInt(0x7000C140);   // RX data (button/wheel)

// Device enable registers - CORRECTED addresses from Rockbox
const DEV_RS: *volatile u32 = @ptrFromInt(0x60006004);   // Device reset
const DEV_EN: *volatile u32 = @ptrFromInt(0x6000600C);   // Device enable
const DEV_INIT1: *volatile u32 = @ptrFromInt(0x70000010); // Device init 1

// Device bits - CORRECTED from Rockbox
const DEV_OPTO: u32 = 0x00010000;      // Click wheel enable (was 0x00800000 - WRONG!)
const INIT_BUTTONS: u32 = 0x00040000;  // Button detection enable (was 0x00000040 - WRONG!)

// Wheel controller magic values from Rockbox
const WHEEL_CTRL_INIT: u32 = 0xC00A1F00;
const WHEEL_STATUS_INIT: u32 = 0x01000000;
const WHEEL_STATUS_DATA_READY: u32 = 0x04000000;  // Bit 26
const WHEEL_PACKET_MASK: u32 = 0x800000FF;
const WHEEL_PACKET_VALID: u32 = 0x8000001A;

// Button bits from wheel packet
const BTN_SELECT: u8 = 0x01;
const BTN_RIGHT: u8 = 0x02;
const BTN_LEFT: u8 = 0x04;
const BTN_PLAY: u8 = 0x08;
const BTN_MENU: u8 = 0x10;

// Initialize click wheel - CORRECTED from Rockbox research
// See docs/ROCKBOX_REFERENCE.md Section 1 for details
fn initWheel() void {
    // Step 1: Enable OPTO device (click wheel optical sensor)
    DEV_EN.* |= DEV_OPTO;

    // Step 2: Reset sequence (minimum 5 microseconds)
    DEV_RS.* |= DEV_OPTO;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {  // ~5us at 80MHz
        asm volatile ("nop");
    }
    DEV_RS.* &= ~DEV_OPTO;

    // Step 3: Enable button detection
    DEV_INIT1.* |= INIT_BUTTONS;

    // Step 4: Configure wheel controller with magic values from Rockbox
    // CRITICAL: These were written to wrong registers before!
    WHEEL_CTRL.* = WHEEL_CTRL_INIT;      // 0xC00A1F00
    WHEEL_STATUS.* = WHEEL_STATUS_INIT;  // 0x01000000
}

// Read wheel data packet - CORRECTED with proper validation
fn readWheel() u32 {
    // Check if data available (bit 26 of status register)
    if ((WHEEL_STATUS.* & WHEEL_STATUS_DATA_READY) == 0) {
        return 0;
    }

    // Read data from correct register (0x7000C140, not 0x7000C100!)
    const data = WHEEL_DATA.*;

    // Validate packet format: (data & 0x800000FF) must equal 0x8000001A
    if ((data & WHEEL_PACKET_MASK) != WHEEL_PACKET_VALID) {
        return 0;  // Invalid packet
    }

    return data;
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

    // Initialize click wheel with CORRECTED sequence
    initWheel();

    // Show startup sequence to confirm boot
    fillScreen(COLOR32_RED);
    delay();
    fillScreen(COLOR32_GREEN);
    delay();
    fillScreen(COLOR32_BLUE);
    delay();

    // Draw initial UI
    drawUI();

    var last_buttons: u8 = 0;
    var last_wheel_pos: u8 = 0;
    var wheel_accumulated: i16 = 0;

    // Interactive main loop
    while (true) {
        const packet = readWheel();
        if (packet != 0) {
            const buttons = getButtons(packet);
            const wheel_pos = getWheelPosition(packet);
            const wheel_touched = isWheelTouched(packet);

            // Visual feedback for button presses (immediate, not on release)
            // This helps debug whether buttons are being read correctly
            if (buttons != last_buttons) {
                if ((buttons & BTN_SELECT) != 0) {
                    // SELECT = White flash
                    fillScreen(COLOR32_WHITE);
                } else if ((buttons & BTN_MENU) != 0) {
                    // MENU = Red
                    fillScreen(COLOR32_RED);
                } else if ((buttons & BTN_PLAY) != 0) {
                    // PLAY = Green
                    fillScreen(COLOR32_GREEN);
                } else if ((buttons & BTN_LEFT) != 0) {
                    // LEFT = Blue
                    fillScreen(COLOR32_BLUE);
                } else if ((buttons & BTN_RIGHT) != 0) {
                    // RIGHT = Yellow
                    fillScreen(COLOR32_YELLOW);
                } else if (buttons == 0 and last_buttons != 0) {
                    // Button released - back to UI
                    drawUI();
                    drawMenuItems();
                }
            }

            // Handle wheel rotation for menu navigation
            if (wheel_touched and wheel_pos != last_wheel_pos and wheel_pos < 96) {
                // Calculate delta with wraparound handling
                var delta: i16 = @as(i16, wheel_pos) - @as(i16, last_wheel_pos);
                if (delta > 48) delta -= 96;
                if (delta < -48) delta += 96;

                // Accumulate small movements
                wheel_accumulated += delta;

                // Only act on significant accumulated movement
                if (wheel_accumulated > 6) {
                    // Clockwise - move down
                    if (selected_item < MENU_ITEMS - 1) {
                        selected_item += 1;
                        drawMenuItems();
                    }
                    wheel_accumulated = 0;
                } else if (wheel_accumulated < -6) {
                    // Counter-clockwise - move up
                    if (selected_item > 0) {
                        selected_item -= 1;
                        drawMenuItems();
                    }
                    wheel_accumulated = 0;
                }

                last_wheel_pos = wheel_pos;
            }

            last_buttons = buttons;
        }

        // Small delay to prevent busy-looping
        var i: u32 = 0;
        while (i < 10000) : (i += 1) {
            asm volatile ("nop");
        }
    }
}
