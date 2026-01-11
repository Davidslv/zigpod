//! LCD Test Firmware for PP5021C Emulator
//!
//! This test firmware draws colored rectangles to verify the LCD pipeline.
//! Runs at boot (address 0x00000000).
//!
//! LCD Controller (BCM2722):
//! - BCM_DATA32 at 0x30000000: Write two 16-bit RGB565 pixels per 32-bit write
//! - BCM_CONTROL at 0x30030000: Write 0x34 to trigger LCD update
//!
//! Display: 320x240 RGB565

const LCD_WIDTH: u32 = 320;
const LCD_HEIGHT: u32 = 240;

// BCM2722 LCD registers
const BCM_DATA32: *volatile u32 = @ptrFromInt(0x30000000);
const BCM_CONTROL: *volatile u32 = @ptrFromInt(0x30030000);

// LCD commands
const LCD_UPDATE: u32 = 0x34;

/// RGB565 color from RGB components
fn rgb565(r: u8, g: u8, b: u8) u16 {
    return (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | @as(u16, b >> 3);
}

/// Write two pixels at once (32-bit write)
fn writePixels(color1: u16, color2: u16) void {
    BCM_DATA32.* = @as(u32, color1) | (@as(u32, color2) << 16);
}

/// Fill entire screen with a color
fn fillScreen(color: u16) void {
    const total_pixels = LCD_WIDTH * LCD_HEIGHT;
    var i: u32 = 0;
    while (i < total_pixels) : (i += 2) {
        writePixels(color, color);
    }
}

/// Trigger LCD update
fn updateLcd() void {
    BCM_CONTROL.* = LCD_UPDATE;
}

/// Draw test pattern - colored stripes
fn drawTestPattern() void {
    // Define colors
    const red = rgb565(255, 0, 0);
    const green = rgb565(0, 255, 0);
    const blue = rgb565(0, 0, 255);
    const yellow = rgb565(255, 255, 0);
    const cyan = rgb565(0, 255, 255);
    const magenta = rgb565(255, 0, 255);
    const white = rgb565(255, 255, 255);
    const black = rgb565(0, 0, 0);

    // Draw horizontal stripes (30 pixels each = 8 stripes)
    const stripe_height: u32 = 30;
    const colors = [_]u16{ red, green, blue, yellow, cyan, magenta, white, black };

    var y: u32 = 0;
    var stripe_idx: usize = 0;
    while (y < LCD_HEIGHT) : (y += 1) {
        stripe_idx = @min(y / stripe_height, colors.len - 1);
        const color = colors[stripe_idx];

        // Write one row
        var x: u32 = 0;
        while (x < LCD_WIDTH) : (x += 2) {
            writePixels(color, color);
        }
    }
}

/// Draw a more interesting test pattern with rectangles
fn drawRectanglePattern() void {
    const black = rgb565(0, 0, 0);
    const red = rgb565(255, 0, 0);
    const green = rgb565(0, 255, 0);
    const blue = rgb565(0, 0, 255);
    const white = rgb565(255, 255, 255);
    const yellow = rgb565(255, 255, 0);

    // Fill screen with pattern - we draw row by row
    var y: u32 = 0;
    while (y < LCD_HEIGHT) : (y += 1) {
        var x: u32 = 0;
        while (x < LCD_WIDTH) : (x += 2) {
            var color1: u16 = black;
            var color2: u16 = black;

            // Top-left quadrant: Red
            if (x < 160 and y < 120) {
                color1 = red;
                if (x + 1 < 160) color2 = red;
            }
            // Top-right quadrant: Green
            else if (x >= 160 and y < 120) {
                color1 = green;
                color2 = green;
            }
            // Bottom-left quadrant: Blue
            else if (x < 160 and y >= 120) {
                color1 = blue;
                if (x + 1 < 160) color2 = blue;
            }
            // Bottom-right quadrant: White
            else {
                color1 = white;
                color2 = white;
            }

            // Draw center box in yellow
            if (x >= 110 and x < 210 and y >= 70 and y < 170) {
                color1 = yellow;
                if (x + 1 < 210 and x + 1 >= 110) color2 = yellow;
            }

            writePixels(color1, color2);
        }
    }
}

/// Entry point - called at boot (address 0)
export fn _start() callconv(.c) noreturn {
    // Draw test pattern
    drawRectanglePattern();

    // Trigger LCD update
    updateLcd();

    // Infinite loop - done
    while (true) {
        // Could add animation here
        asm volatile ("nop");
    }
}
