//! LCD Display Driver for iPod Video (BCM2722)
//!
//! This driver controls the Broadcom BCM2722 VideoCore GPU for LCD output.
//! The iPod Video has a 320x240 RGB565 color display.
//!
//! WARNING: The BCM2722 requires firmware loaded from flash ROM.
//! This implementation provides a simplified interface that works through the HAL.

const std = @import("std");
const hal = @import("../../hal/hal.zig");

// ============================================================
// LCD Constants
// ============================================================

pub const WIDTH: u16 = 320;
pub const HEIGHT: u16 = 240;
pub const BPP: u8 = 16; // 16 bits per pixel (RGB565)
pub const FRAMEBUFFER_SIZE: usize = @as(usize, WIDTH) * HEIGHT * 2; // 153600 bytes

// ============================================================
// Color Definitions (RGB565)
// ============================================================

/// RGB565 color type
pub const Color = u16;

/// Convert RGB888 to RGB565
pub fn rgb(r: u8, g: u8, b: u8) Color {
    return (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | (b >> 3);
}

/// Predefined colors
pub const Colors = struct {
    pub const BLACK: Color = rgb(0, 0, 0);
    pub const WHITE: Color = rgb(255, 255, 255);
    pub const RED: Color = rgb(255, 0, 0);
    pub const GREEN: Color = rgb(0, 255, 0);
    pub const BLUE: Color = rgb(0, 0, 255);
    pub const YELLOW: Color = rgb(255, 255, 0);
    pub const CYAN: Color = rgb(0, 255, 255);
    pub const MAGENTA: Color = rgb(255, 0, 255);
    pub const GRAY: Color = rgb(128, 128, 128);
    pub const DARK_GRAY: Color = rgb(64, 64, 64);
    pub const LIGHT_GRAY: Color = rgb(192, 192, 192);

    // iPod-style colors
    pub const IPOD_BG: Color = rgb(255, 255, 255);
    pub const IPOD_HIGHLIGHT: Color = rgb(66, 133, 244);
    pub const IPOD_TEXT: Color = rgb(0, 0, 0);
    pub const IPOD_SELECTED: Color = rgb(66, 133, 244);
};

// ============================================================
// Rectangle
// ============================================================

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn contains(self: Rect, px: u16, py: u16) bool {
        return px >= self.x and px < self.x + self.width and
            py >= self.y and py < self.y + self.height;
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.x + other.width and
            self.x + self.width > other.x and
            self.y < other.y + other.height and
            self.y + self.height > other.y;
    }

    pub fn intersection(self: Rect, other: Rect) ?Rect {
        const x1 = @max(self.x, other.x);
        const y1 = @max(self.y, other.y);
        const x2 = @min(self.x + self.width, other.x + other.width);
        const y2 = @min(self.y + self.height, other.y + other.height);

        if (x2 > x1 and y2 > y1) {
            return Rect{
                .x = x1,
                .y = y1,
                .width = x2 - x1,
                .height = y2 - y1,
            };
        }
        return null;
    }

    /// Full screen rectangle
    pub fn fullScreen() Rect {
        return Rect{ .x = 0, .y = 0, .width = WIDTH, .height = HEIGHT };
    }
};

// ============================================================
// LCD Driver State
// ============================================================

var framebuffer: [FRAMEBUFFER_SIZE]u8 = [_]u8{0} ** FRAMEBUFFER_SIZE;
var initialized: bool = false;
var backlight_on: bool = false;

/// Initialize the LCD
pub fn init() hal.HalError!void {
    try hal.current_hal.lcd_init();
    clear(Colors.BLACK);
    initialized = true;
}

/// Check if LCD is initialized
pub fn isInitialized() bool {
    return initialized;
}

/// Turn backlight on or off
pub fn setBacklight(on: bool) void {
    hal.current_hal.lcd_set_backlight(on);
    backlight_on = on;
}

/// Check backlight state
pub fn getBacklight() bool {
    return backlight_on;
}

// ============================================================
// Framebuffer Operations
// ============================================================

/// Get direct access to framebuffer
pub fn getFramebuffer() []u8 {
    return &framebuffer;
}

/// Get framebuffer as color array
pub fn getPixels() []Color {
    const ptr: [*]Color = @ptrCast(@alignCast(&framebuffer));
    return ptr[0 .. @as(usize, WIDTH) * HEIGHT];
}

/// Set a single pixel
pub fn setPixel(x: u16, y: u16, color: Color) void {
    if (x >= WIDTH or y >= HEIGHT) return;

    const offset = (@as(usize, y) * WIDTH + x) * 2;
    const color_bytes: [2]u8 = @bitCast(color);
    framebuffer[offset] = color_bytes[0];
    framebuffer[offset + 1] = color_bytes[1];
}

/// Get a single pixel
pub fn getPixel(x: u16, y: u16) Color {
    if (x >= WIDTH or y >= HEIGHT) return 0;

    const offset = (@as(usize, y) * WIDTH + x) * 2;
    return @bitCast([2]u8{ framebuffer[offset], framebuffer[offset + 1] });
}

/// Clear screen with color
pub fn clear(color: Color) void {
    fillRect(0, 0, WIDTH, HEIGHT, color);
}

/// Fill rectangle with color
pub fn fillRect(x: u16, y: u16, w: u16, h: u16, color: Color) void {
    const x_end = @min(x + w, WIDTH);
    const y_end = @min(y + h, HEIGHT);

    var py: u16 = y;
    while (py < y_end) : (py += 1) {
        var px: u16 = x;
        while (px < x_end) : (px += 1) {
            setPixel(px, py, color);
        }
    }
}

/// Draw rectangle outline
pub fn drawRect(x: u16, y: u16, w: u16, h: u16, color: Color) void {
    // Top and bottom lines
    drawHLine(x, y, w, color);
    if (h > 1) {
        drawHLine(x, y + h - 1, w, color);
    }

    // Left and right lines
    drawVLine(x, y, h, color);
    if (w > 1) {
        drawVLine(x + w - 1, y, h, color);
    }
}

/// Draw horizontal line
pub fn drawHLine(x: u16, y: u16, w: u16, color: Color) void {
    if (y >= HEIGHT) return;
    const x_end = @min(x + w, WIDTH);
    var px: u16 = x;
    while (px < x_end) : (px += 1) {
        setPixel(px, y, color);
    }
}

/// Draw vertical line
pub fn drawVLine(x: u16, y: u16, h: u16, color: Color) void {
    if (x >= WIDTH) return;
    const y_end = @min(y + h, HEIGHT);
    var py: u16 = y;
    while (py < y_end) : (py += 1) {
        setPixel(x, py, color);
    }
}

/// Draw line using Bresenham's algorithm
pub fn drawLine(x0: u16, y0: u16, x1: u16, y1: u16, color: Color) void {
    var x0_var: i32 = x0;
    var y0_var: i32 = y0;
    const x1_i: i32 = x1;
    const y1_i: i32 = y1;

    const dx = @abs(x1_i - x0_var);
    const dy = -@abs(y1_i - y0_var);
    const sx: i32 = if (x0_var < x1_i) 1 else -1;
    const sy: i32 = if (y0_var < y1_i) 1 else -1;
    var err = dx + dy;

    while (true) {
        if (x0_var >= 0 and x0_var < WIDTH and y0_var >= 0 and y0_var < HEIGHT) {
            setPixel(@intCast(x0_var), @intCast(y0_var), color);
        }

        if (x0_var == x1_i and y0_var == y1_i) break;

        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x0_var += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0_var += sy;
        }
    }
}

// ============================================================
// Text Rendering (8x8 bitmap font)
// ============================================================

// Basic 8x8 font for ASCII 32-126 (space through tilde)
// Each character is 8 bytes, one byte per row
const font_8x8 = [_][8]u8{
    // Space (32)
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // ! (33)
    .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00 },
    // " (34)
    .{ 0x6C, 0x6C, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // # (35)
    .{ 0x6C, 0x6C, 0xFE, 0x6C, 0xFE, 0x6C, 0x6C, 0x00 },
    // $ (36)
    .{ 0x18, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x18, 0x00 },
    // % (37)
    .{ 0x00, 0x66, 0xAC, 0xD8, 0x36, 0x6A, 0xCC, 0x00 },
    // & (38)
    .{ 0x38, 0x6C, 0x68, 0x76, 0xDC, 0xCC, 0x76, 0x00 },
    // ' (39)
    .{ 0x18, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // ( (40)
    .{ 0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00 },
    // ) (41)
    .{ 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00 },
    // * (42)
    .{ 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00 },
    // + (43)
    .{ 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00 },
    // , (44)
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30 },
    // - (45)
    .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 },
    // . (46)
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 },
    // / (47)
    .{ 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00 },
    // 0 (48)
    .{ 0x3C, 0x66, 0x6E, 0x7E, 0x76, 0x66, 0x3C, 0x00 },
    // 1 (49)
    .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 },
    // 2 (50)
    .{ 0x3C, 0x66, 0x06, 0x1C, 0x30, 0x66, 0x7E, 0x00 },
    // 3 (51)
    .{ 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00 },
    // 4 (52)
    .{ 0x1C, 0x3C, 0x6C, 0xCC, 0xFE, 0x0C, 0x0C, 0x00 },
    // 5 (53)
    .{ 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00 },
    // 6 (54)
    .{ 0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00 },
    // 7 (55)
    .{ 0x7E, 0x66, 0x06, 0x0C, 0x18, 0x18, 0x18, 0x00 },
    // 8 (56)
    .{ 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00 },
    // 9 (57)
    .{ 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00 },
    // : (58)
    .{ 0x00, 0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00 },
    // ; (59)
    .{ 0x00, 0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x30 },
    // < (60)
    .{ 0x0C, 0x18, 0x30, 0x60, 0x30, 0x18, 0x0C, 0x00 },
    // = (61)
    .{ 0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00 },
    // > (62)
    .{ 0x30, 0x18, 0x0C, 0x06, 0x0C, 0x18, 0x30, 0x00 },
    // ? (63)
    .{ 0x3C, 0x66, 0x0C, 0x18, 0x18, 0x00, 0x18, 0x00 },
    // @ (64)
    .{ 0x3C, 0x66, 0x6E, 0x6A, 0x6E, 0x60, 0x3C, 0x00 },
    // A (65)
    .{ 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 },
    // B (66)
    .{ 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00 },
    // C (67)
    .{ 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00 },
    // D (68)
    .{ 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00 },
    // E (69)
    .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00 },
    // F (70)
    .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00 },
    // G (71)
    .{ 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3E, 0x00 },
    // H (72)
    .{ 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 },
    // I (73)
    .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 },
    // J (74)
    .{ 0x3E, 0x0C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38, 0x00 },
    // K (75)
    .{ 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00 },
    // L (76)
    .{ 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00 },
    // M (77)
    .{ 0xC6, 0xEE, 0xFE, 0xD6, 0xC6, 0xC6, 0xC6, 0x00 },
    // N (78)
    .{ 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00 },
    // O (79)
    .{ 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 },
    // P (80)
    .{ 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00 },
    // Q (81)
    .{ 0x3C, 0x66, 0x66, 0x66, 0x6A, 0x6C, 0x36, 0x00 },
    // R (82)
    .{ 0x7C, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x00 },
    // S (83)
    .{ 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00 },
    // T (84)
    .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 },
    // U (85)
    .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 },
    // V (86)
    .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 },
    // W (87)
    .{ 0xC6, 0xC6, 0xC6, 0xD6, 0xFE, 0xEE, 0xC6, 0x00 },
    // X (88)
    .{ 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00 },
    // Y (89)
    .{ 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00 },
    // Z (90)
    .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00 },
    // [ (91)
    .{ 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00 },
    // \ (92)
    .{ 0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00 },
    // ] (93)
    .{ 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00 },
    // ^ (94)
    .{ 0x18, 0x3C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // _ (95)
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00 },
    // ` (96)
    .{ 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // a (97)
    .{ 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x3E, 0x00 },
    // b (98)
    .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x00 },
    // c (99)
    .{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x66, 0x3C, 0x00 },
    // d (100)
    .{ 0x06, 0x06, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x00 },
    // e (101)
    .{ 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x3C, 0x00 },
    // f (102)
    .{ 0x1C, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x30, 0x00 },
    // g (103)
    .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x3C },
    // h (104)
    .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 },
    // i (105)
    .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 },
    // j (106)
    .{ 0x0C, 0x00, 0x1C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38 },
    // k (107)
    .{ 0x60, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0x00 },
    // l (108)
    .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 },
    // m (109)
    .{ 0x00, 0x00, 0xEC, 0xFE, 0xD6, 0xC6, 0xC6, 0x00 },
    // n (110)
    .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 },
    // o (111)
    .{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x00 },
    // p (112)
    .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60 },
    // q (113)
    .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x06 },
    // r (114)
    .{ 0x00, 0x00, 0x7C, 0x66, 0x60, 0x60, 0x60, 0x00 },
    // s (115)
    .{ 0x00, 0x00, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x00 },
    // t (116)
    .{ 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x1C, 0x00 },
    // u (117)
    .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00 },
    // v (118)
    .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 },
    // w (119)
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xD6, 0xFE, 0x6C, 0x00 },
    // x (120)
    .{ 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x00 },
    // y (121)
    .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x3C },
    // z (122)
    .{ 0x00, 0x00, 0x7E, 0x0C, 0x18, 0x30, 0x7E, 0x00 },
    // { (123)
    .{ 0x0E, 0x18, 0x18, 0x70, 0x18, 0x18, 0x0E, 0x00 },
    // | (124)
    .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 },
    // } (125)
    .{ 0x70, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x70, 0x00 },
    // ~ (126)
    .{ 0x76, 0xDC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
};

/// Draw a character at position
pub fn drawChar(x: u16, y: u16, char: u8, fg: Color, bg: ?Color) void {
    const glyph_index: usize = if (char >= 32 and char <= 126)
        char - 32
    else
        0; // Use space for out-of-range

    const glyph = font_8x8[glyph_index];

    var row: u16 = 0;
    while (row < 8) : (row += 1) {
        const row_data = glyph[row];
        var col: u16 = 0;
        while (col < 8) : (col += 1) {
            const bit = (row_data >> @intCast(7 - col)) & 1;
            if (bit == 1) {
                setPixel(x + col, y + row, fg);
            } else if (bg) |bg_color| {
                setPixel(x + col, y + row, bg_color);
            }
        }
    }
}

/// Draw a string at position
pub fn drawString(x: u16, y: u16, str: []const u8, fg: Color, bg: ?Color) void {
    var px = x;
    for (str) |char| {
        if (char == '\n') {
            // Newlines not supported in this simple implementation
            continue;
        }
        drawChar(px, y, char, fg, bg);
        px += 8;
        if (px >= WIDTH - 8) break;
    }
}

/// Draw string centered on X axis
pub fn drawStringCentered(y: u16, str: []const u8, fg: Color, bg: ?Color) void {
    const str_width = @as(u16, @intCast(str.len * 8));
    const x = if (str_width < WIDTH) (WIDTH - str_width) / 2 else 0;
    drawString(x, y, str, fg, bg);
}

// ============================================================
// Display Update
// ============================================================

/// Update the LCD with current framebuffer contents
pub fn update() hal.HalError!void {
    try hal.current_hal.lcd_update(&framebuffer);
}

/// Update a rectangular region of the LCD
pub fn updateRect(rect: Rect) hal.HalError!void {
    try hal.current_hal.lcd_update_rect(rect.x, rect.y, rect.width, rect.height, &framebuffer);
}

// ============================================================
// Special Effects
// ============================================================

/// Invert colors in a region
pub fn invertRect(x: u16, y: u16, w: u16, h: u16) void {
    const x_end = @min(x + w, WIDTH);
    const y_end = @min(y + h, HEIGHT);

    var py: u16 = y;
    while (py < y_end) : (py += 1) {
        var px: u16 = x;
        while (px < x_end) : (px += 1) {
            setPixel(px, py, ~getPixel(px, py));
        }
    }
}

/// Dim the screen (reduce brightness by averaging with black)
pub fn dim() void {
    var i: usize = 0;
    const pixels = getPixels();
    while (i < pixels.len) : (i += 1) {
        const pixel = pixels[i];
        const r = (pixel >> 11) & 0x1F;
        const g = (pixel >> 5) & 0x3F;
        const b = pixel & 0x1F;
        pixels[i] = ((r >> 1) << 11) | ((g >> 1) << 5) | (b >> 1);
    }
}

// ============================================================
// Progress Bar
// ============================================================

/// Draw a progress bar
pub fn drawProgressBar(x: u16, y: u16, w: u16, h: u16, progress: u8, fg: Color, bg: Color) void {
    // Background
    fillRect(x, y, w, h, bg);

    // Progress fill
    const fill_w: u16 = @intCast((@as(u32, w) * @min(progress, 100)) / 100);
    if (fill_w > 2) {
        fillRect(x + 1, y + 1, fill_w - 2, h - 2, fg);
    }

    // Border
    drawRect(x, y, w, h, fg);
}

// ============================================================
// Tests
// ============================================================

test "RGB565 conversion" {
    // Black
    try std.testing.expectEqual(@as(Color, 0x0000), rgb(0, 0, 0));

    // White
    try std.testing.expectEqual(@as(Color, 0xFFFF), rgb(255, 255, 255));

    // Pure red
    try std.testing.expectEqual(@as(Color, 0xF800), rgb(255, 0, 0));

    // Pure green
    try std.testing.expectEqual(@as(Color, 0x07E0), rgb(0, 255, 0));

    // Pure blue
    try std.testing.expectEqual(@as(Color, 0x001F), rgb(0, 0, 255));
}

test "rectangle operations" {
    const r1 = Rect{ .x = 10, .y = 10, .width = 20, .height = 20 };

    // Contains
    try std.testing.expect(r1.contains(15, 15));
    try std.testing.expect(!r1.contains(5, 5));
    try std.testing.expect(!r1.contains(35, 35));

    // Intersection
    const r2 = Rect{ .x = 20, .y = 20, .width = 20, .height = 20 };
    try std.testing.expect(r1.intersects(r2));

    const intersect = r1.intersection(r2);
    try std.testing.expect(intersect != null);
    try std.testing.expectEqual(@as(u16, 20), intersect.?.x);
    try std.testing.expectEqual(@as(u16, 20), intersect.?.y);
    try std.testing.expectEqual(@as(u16, 10), intersect.?.width);
    try std.testing.expectEqual(@as(u16, 10), intersect.?.height);
}

test "framebuffer pixel operations" {
    // Set and get pixel
    setPixel(10, 10, Colors.RED);
    try std.testing.expectEqual(Colors.RED, getPixel(10, 10));

    // Out of bounds should not crash
    setPixel(WIDTH + 10, HEIGHT + 10, Colors.BLUE);
    try std.testing.expectEqual(@as(Color, 0), getPixel(WIDTH + 10, HEIGHT + 10));
}
