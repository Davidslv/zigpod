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

// Click wheel registers (I2C-like interface at 0x7000C100)
const WHEEL_DATA: *volatile u32 = @ptrFromInt(0x7000C100);
const WHEEL_CFG: *volatile u32 = @ptrFromInt(0x7000C104);
const WHEEL_PERIOD: *volatile u32 = @ptrFromInt(0x7000C108);
const WHEEL_STATUS: *volatile u32 = @ptrFromInt(0x7000C10C);

// Device enable registers
const DEV_EN: *volatile u32 = @ptrFromInt(0x6000D000);
const DEV_RS: *volatile u32 = @ptrFromInt(0x6000D010);
const DEV_INIT1: *volatile u32 = @ptrFromInt(0x6000D020);

// Device bits
const DEV_OPTO: u32 = 0x00800000;
const INIT_BUTTONS: u32 = 0x00000040;

// Button bits from wheel packet
const BTN_SELECT: u8 = 0x01;
const BTN_RIGHT: u8 = 0x02;
const BTN_LEFT: u8 = 0x04;
const BTN_PLAY: u8 = 0x08;
const BTN_MENU: u8 = 0x10;

// Initialize click wheel
fn initWheel() void {
    // Enable OPTO device (click wheel)
    DEV_EN.* |= DEV_OPTO;

    // Reset OPTO
    DEV_RS.* |= DEV_OPTO;
    var i: u32 = 0;
    while (i < 50000) : (i += 1) {
        asm volatile ("nop");
    }
    DEV_RS.* &= ~DEV_OPTO;

    // Initialize buttons
    DEV_INIT1.* |= INIT_BUTTONS;

    // Configure wheel interface (from Rockbox)
    WHEEL_DATA.* = 0xC00A1F00;
    WHEEL_CFG.* = 0x01000000;
}

// Read wheel data packet
fn readWheel() u32 {
    // Check if data available
    const status = WHEEL_STATUS.*;
    if ((status & 0x01) != 0) {
        return WHEEL_DATA.*;
    }
    return 0;
}

// Extract button state from wheel packet
fn getButtons(packet: u32) u8 {
    return @truncate((packet >> 16) & 0xFF);
}

// Extract wheel position from wheel packet (0-95)
fn getWheelPosition(packet: u32) u8 {
    return @truncate((packet >> 8) & 0xFF);
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
    // Initialize click wheel
    initWheel();

    // Draw initial UI
    drawUI();

    var last_buttons: u8 = 0;
    var last_wheel_pos: u8 = 0;

    // Interactive main loop
    while (true) {
        const packet = readWheel();
        if (packet != 0) {
            const buttons = getButtons(packet);
            const wheel_pos = getWheelPosition(packet);

            // Handle button presses (on release)
            if (last_buttons != 0 and buttons == 0) {
                if ((last_buttons & BTN_MENU) != 0) {
                    // Menu pressed - move up
                    if (selected_item > 0) {
                        selected_item -= 1;
                        drawMenuItems();
                    }
                } else if ((last_buttons & BTN_PLAY) != 0) {
                    // Play pressed - move down
                    if (selected_item < MENU_ITEMS - 1) {
                        selected_item += 1;
                        drawMenuItems();
                    }
                } else if ((last_buttons & BTN_SELECT) != 0) {
                    // Select pressed - flash screen to show selection
                    fillScreen(COLOR32_WHITE);
                    delay();
                    drawUI();
                    drawMenuItems();
                }
            }

            // Handle wheel rotation
            if (wheel_pos != last_wheel_pos and wheel_pos < 96) {
                // Calculate delta with wraparound handling
                var delta: i16 = @as(i16, wheel_pos) - @as(i16, last_wheel_pos);
                if (delta > 48) delta -= 96;
                if (delta < -48) delta += 96;

                // Only act on significant movement
                if (delta > 4) {
                    // Clockwise - move down
                    if (selected_item < MENU_ITEMS - 1) {
                        selected_item += 1;
                        drawMenuItems();
                    }
                } else if (delta < -4) {
                    // Counter-clockwise - move up
                    if (selected_item > 0) {
                        selected_item -= 1;
                        drawMenuItems();
                    }
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
