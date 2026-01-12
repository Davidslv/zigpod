//! BCM2722 LCD Controller and LCD2 Bridge
//!
//! Implements the LCD controller for iPod 5th/5.5th Gen.
//! The BCM2722 is the display controller IC used in these iPods.
//!
//! This module provides two interfaces:
//!
//! 1. BCM2722 Direct (base 0x30000000):
//!    - 0x00000: BCM_DATA32 - 32-bit data write
//!    - 0x10000: BCM_WR_ADDR32 - Write address
//!    - 0x30000: BCM_CONTROL - Control register
//!
//! 2. LCD2 Bridge (base 0x70008a00) - Used by Rockbox:
//!    - 0x0C: LCD2_PORT - Command/data port
//!    - 0x20: LCD2_BLOCK_CTRL - Block transfer control
//!    - 0x24: LCD2_BLOCK_CONFIG - Block transfer config
//!    - 0x100: LCD2_BLOCK_DATA - Block data FIFO
//!
//! Reference: Rockbox firmware/target/arm/ipod/lcd-color_nano.c
//!            Rockbox firmware/export/pp5020.h
//!
//! Display specifications:
//! - Resolution: 320x240 pixels
//! - Color format: RGB565 (16-bit)
//! - Framebuffer size: 320 * 240 * 2 = 153,600 bytes

const std = @import("std");
const bus = @import("../memory/bus.zig");

/// Display dimensions
pub const LCD_WIDTH: u32 = 320;
pub const LCD_HEIGHT: u32 = 240;
pub const LCD_BPP: u32 = 16; // Bits per pixel
pub const FRAMEBUFFER_SIZE: usize = LCD_WIDTH * LCD_HEIGHT * 2;

/// RGB565 color
pub const Color = packed struct(u16) {
    blue: u5,
    green: u6,
    red: u5,

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{
            .red = @truncate(r >> 3),
            .green = @truncate(g >> 2),
            .blue = @truncate(b >> 3),
        };
    }

    pub fn toRgb(self: Color) struct { r: u8, g: u8, b: u8 } {
        return .{
            .r = @as(u8, self.red) << 3 | @as(u8, self.red) >> 2,
            .g = @as(u8, self.green) << 2 | @as(u8, self.green) >> 4,
            .b = @as(u8, self.blue) << 3 | @as(u8, self.blue) >> 2,
        };
    }

    pub fn toU32(self: Color) u32 {
        const rgb = self.toRgb();
        return (@as(u32, 0xFF) << 24) | // Alpha
            (@as(u32, rgb.r) << 16) |
            (@as(u32, rgb.g) << 8) |
            @as(u32, rgb.b);
    }
};

/// BCM commands
pub const BcmCommand = enum(u32) {
    // Common commands
    nop = 0x00,
    lcd_update = 0x34,
    set_window = 0x35,
    write_data = 0x36,

    pub fn fromU32(value: u32) ?BcmCommand {
        return switch (value) {
            0x00 => .nop,
            0x34 => .lcd_update,
            0x35 => .set_window,
            0x36 => .write_data,
            else => null,
        };
    }
};

/// LCD Controller
pub const LcdController = struct {
    /// Framebuffer (RGB565)
    framebuffer: [FRAMEBUFFER_SIZE]u8,

    /// Control register
    control: u32,

    /// Current write address
    write_addr: u32,

    /// Window coordinates
    x_start: u16,
    y_start: u16,
    x_end: u16,
    y_end: u16,

    /// Current position within window
    x_pos: u16,
    y_pos: u16,

    /// Display update pending
    update_pending: bool,

    /// Display update callback
    display_callback: ?*const fn (*const [FRAMEBUFFER_SIZE]u8) void,

    /// Debug: pixel write count
    debug_pixel_writes: u32,

    /// Debug: update count
    debug_update_count: u32,

    /// Debug: last unexpected offset written
    debug_last_offset: u32,

    const Self = @This();

    /// Register offsets
    const REG_DATA32: u32 = 0x00000;
    const REG_WR_ADDR32: u32 = 0x10000;
    const REG_CONTROL: u32 = 0x30000;

    pub fn init() Self {
        var lcd = Self{
            .framebuffer = [_]u8{0} ** FRAMEBUFFER_SIZE,
            .control = 0,
            .write_addr = 0,
            .x_start = 0,
            .y_start = 0,
            .x_end = LCD_WIDTH - 1,
            .y_end = LCD_HEIGHT - 1,
            .x_pos = 0,
            .y_pos = 0,
            .update_pending = false,
            .display_callback = null,
            .debug_pixel_writes = 0,
            .debug_update_count = 0,
            .debug_last_offset = 0,
        };

        // Initialize framebuffer to black
        @memset(&lcd.framebuffer, 0);

        return lcd;
    }

    /// Set display update callback
    pub fn setDisplayCallback(self: *Self, callback: *const fn (*const [FRAMEBUFFER_SIZE]u8) void) void {
        self.display_callback = callback;
    }

    /// Set window for writes
    pub fn setWindow(self: *Self, x_start: u16, y_start: u16, x_end: u16, y_end: u16) void {
        self.x_start = @min(x_start, LCD_WIDTH - 1);
        self.y_start = @min(y_start, LCD_HEIGHT - 1);
        self.x_end = @min(x_end, LCD_WIDTH - 1);
        self.y_end = @min(y_end, LCD_HEIGHT - 1);
        self.x_pos = self.x_start;
        self.y_pos = self.y_start;
    }

    /// Write pixel data to framebuffer
    pub fn writePixel(self: *Self, color: u16) void {
        const offset = (@as(usize, self.y_pos) * LCD_WIDTH + self.x_pos) * 2;
        if (offset + 1 < FRAMEBUFFER_SIZE) {
            // BCM2722 sends big-endian RGB565, swap bytes for little-endian storage
            self.framebuffer[offset] = @truncate(color >> 8);
            self.framebuffer[offset + 1] = @truncate(color);
            self.debug_pixel_writes += 1;
        }

        // Advance position
        self.x_pos += 1;
        if (self.x_pos > self.x_end) {
            self.x_pos = self.x_start;
            self.y_pos += 1;
            if (self.y_pos > self.y_end) {
                self.y_pos = self.y_start;
            }
        }
    }

    /// Trigger display update
    pub fn update(self: *Self) void {
        self.update_pending = false;
        self.debug_update_count += 1;
        if (self.display_callback) |callback| {
            callback(&self.framebuffer);
        }
    }

    /// Get debug statistics
    pub fn getDebugStats(self: *const Self) struct { pixel_writes: u32, update_count: u32, last_offset: u32 } {
        return .{
            .pixel_writes = self.debug_pixel_writes,
            .update_count = self.debug_update_count,
            .last_offset = self.debug_last_offset,
        };
    }

    /// Get pixel at coordinates
    pub fn getPixel(self: *const Self, x: u16, y: u16) Color {
        if (x >= LCD_WIDTH or y >= LCD_HEIGHT) {
            return .{ .red = 0, .green = 0, .blue = 0 };
        }
        const offset = (@as(usize, y) * LCD_WIDTH + x) * 2;
        const value = @as(u16, self.framebuffer[offset]) |
            (@as(u16, self.framebuffer[offset + 1]) << 8);
        return @bitCast(value);
    }

    /// Read register
    pub fn read(self: *const Self, offset: u32) u32 {
        return switch (offset) {
            // Control register: bit 1 = ready, always indicate ready for now
            REG_CONTROL => self.control | 0x02,
            REG_WR_ADDR32 => self.write_addr,
            else => 0,
        };
    }

    /// BCM internal address for framebuffer (BCMA_CMDPARAM)
    const BCMA_CMDPARAM: u32 = 0xE0000;

    /// Debug: count WR_ADDR writes
    pub var debug_wr_addr_count: u32 = 0;
    pub var debug_first_wr_addr: u32 = 0;
    pub var debug_last_wr_addr: u32 = 0;

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        // BCM only decodes address bits 16-18 for register selection
        // All addresses in range 0x30000000-0x3000FFFF map to DATA32
        const bcm_reg = offset & 0x70000;
        switch (bcm_reg) {
            REG_DATA32 => {
                // Write 32-bit value to BCM internal address (auto-incrementing)
                // The framebuffer starts at BCMA_CMDPARAM (0xE0000)
                if (self.write_addr >= BCMA_CMDPARAM) {
                    const fb_offset = self.write_addr - BCMA_CMDPARAM;
                    if (fb_offset + 3 < FRAMEBUFFER_SIZE) {
                        // Write 4 bytes (2 pixels) in little-endian order
                        self.framebuffer[fb_offset] = @truncate(value);
                        self.framebuffer[fb_offset + 1] = @truncate(value >> 8);
                        self.framebuffer[fb_offset + 2] = @truncate(value >> 16);
                        self.framebuffer[fb_offset + 3] = @truncate(value >> 24);
                        self.debug_pixel_writes += 2;
                    }
                }
                // Auto-increment BCM write address
                self.write_addr += 4;
            },
            REG_WR_ADDR32 => {
                self.write_addr = value;
                debug_wr_addr_count += 1;
                if (debug_wr_addr_count == 1) debug_first_wr_addr = value;
                debug_last_wr_addr = value;
            },
            REG_CONTROL => {
                self.control = value;

                // Check for commands
                const cmd = value & 0xFF;
                if (BcmCommand.fromU32(cmd)) |bcm_cmd| {
                    switch (bcm_cmd) {
                        .lcd_update => self.update(),
                        .set_window => {
                            // Window parameters are typically passed in subsequent writes
                            // For now, reset to full screen
                        },
                        .write_data => {
                            // Start data write mode
                        },
                        .nop => {},
                    }
                }
            },
            else => {
                // Debug: track unexpected offsets
                self.debug_last_offset = offset;
            },
        }
    }

    /// Clear screen to a color
    pub fn clear(self: *Self, color: Color) void {
        const color_u16: u16 = @bitCast(color);
        const lo: u8 = @truncate(color_u16);
        const hi: u8 = @truncate(color_u16 >> 8);

        var i: usize = 0;
        while (i < FRAMEBUFFER_SIZE) : (i += 2) {
            self.framebuffer[i] = lo;
            self.framebuffer[i + 1] = hi;
        }
        self.update_pending = true;
    }

    /// Draw a filled rectangle
    pub fn fillRect(self: *Self, x: u16, y: u16, w: u16, h: u16, color: Color) void {
        const color_u16: u16 = @bitCast(color);
        const lo: u8 = @truncate(color_u16);
        const hi: u8 = @truncate(color_u16 >> 8);

        const x_end = @min(x + w, LCD_WIDTH);
        const y_end = @min(y + h, LCD_HEIGHT);

        var py = y;
        while (py < y_end) : (py += 1) {
            var px = x;
            while (px < x_end) : (px += 1) {
                const offset = (@as(usize, py) * LCD_WIDTH + px) * 2;
                self.framebuffer[offset] = lo;
                self.framebuffer[offset + 1] = hi;
            }
        }
        self.update_pending = true;
    }

    /// Create a peripheral handler for the memory bus
    pub fn createHandler(self: *Self) bus.PeripheralHandler {
        return .{
            .context = @ptrCast(self),
            .readFn = readWrapper,
            .writeFn = writeWrapper,
        };
    }

    fn readWrapper(ctx: *anyopaque, offset: u32) u32 {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.read(offset);
    }

    fn writeWrapper(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write(offset, value);
    }
};

/// LCD2 Bridge Controller
///
/// Implements the PP5021C's LCD bridge interface used by Rockbox.
/// This bridge provides block transfer support for efficient pixel writes.
///
/// Register offsets (from 0x70008a00):
///   0x0C: LCD2_PORT - Command/data port
///   0x20: LCD2_BLOCK_CTRL - Block transfer control
///   0x24: LCD2_BLOCK_CONFIG - Block transfer configuration
///   0x100: LCD2_BLOCK_DATA - Block data FIFO
pub const Lcd2Bridge = struct {
    /// Reference to the LCD controller (for pixel writes)
    lcd_ctrl: *LcdController,

    /// LCD2_PORT register
    port: u32,

    /// Block transfer control
    block_ctrl: u32,

    /// Block transfer configuration
    block_config: u32,

    /// Pixels remaining in current block transfer
    pixels_remaining: u32,

    /// Block transfer active flag
    block_active: bool,

    const Self = @This();

    /// Register offsets (relative to 0x70008a00)
    const REG_PORT: u32 = 0x0C;
    const REG_BLOCK_CTRL: u32 = 0x20;
    const REG_BLOCK_CONFIG: u32 = 0x24;
    const REG_BLOCK_DATA: u32 = 0x100; // 0x70008b00 - 0x70008a00

    /// Block control bits
    const BLOCK_READY: u32 = 0x04000000;
    const BLOCK_TXOK: u32 = 0x01000000;

    /// Block control commands
    const BLOCK_CMD_INIT: u32 = 0x10000080;
    const BLOCK_CMD_START: u32 = 0x34000000;

    pub fn init(lcd_ctrl: ?*LcdController) Self {
        return .{
            .lcd_ctrl = lcd_ctrl orelse undefined,
            .port = 0,
            .block_ctrl = BLOCK_READY | BLOCK_TXOK, // Ready for transfers
            .block_config = 0,
            .pixels_remaining = 0,
            .block_active = false,
        };
    }

    /// Read register
    pub fn read(self: *const Self, offset: u32) u32 {
        return switch (offset) {
            REG_PORT => self.port,
            REG_BLOCK_CTRL => self.block_ctrl,
            REG_BLOCK_CONFIG => self.block_config,
            else => 0,
        };
    }

    /// Debug write count
    pub var debug_total_writes: u32 = 0;
    pub var debug_block_data_writes: u32 = 0;
    pub var debug_block_ctrl_writes: u32 = 0;
    pub var debug_block_start_count: u32 = 0;
    pub var debug_last_ctrl_value: u32 = 0;
    pub var debug_pixels_written: u32 = 0;
    pub var debug_block_active_false: u32 = 0;
    pub var debug_pixels_remaining_zero: u32 = 0;

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        debug_total_writes += 1;

        switch (offset) {
            REG_PORT => {
                self.port = value;
                // LCD2_PORT handles LCD controller commands
                // Bit 31 = command/data flag
                // We don't need to fully emulate the LCD controller protocol
                // since we're directly managing the framebuffer
            },
            REG_BLOCK_CTRL => {
                debug_block_ctrl_writes += 1;
                debug_last_ctrl_value = value;
                self.block_ctrl = value;

                // Check for block transfer commands
                if (value == BLOCK_CMD_INIT) {
                    // Initialize block transfer
                    self.block_active = false;
                    self.pixels_remaining = 0;
                    // Set ready flags
                    self.block_ctrl = BLOCK_READY | BLOCK_TXOK;
                } else if (value == BLOCK_CMD_START) {
                    debug_block_start_count += 1;
                    // Start block transfer
                    self.block_active = true;
                    // pixels_remaining is set from block_config
                    // Config format: 0xC001XXXX where XXXX is byte count - 1
                    // Use 20 bits to handle counts up to 1MB
                    self.pixels_remaining = (self.block_config & 0xFFFFF) + 1;
                    // Convert from bytes to pixels (2 bytes per pixel)
                    self.pixels_remaining /= 2;
                    // Indicate transfer in progress
                    self.block_ctrl = BLOCK_TXOK;
                }
            },
            REG_BLOCK_CONFIG => {
                self.block_config = value;
            },
            REG_BLOCK_DATA, REG_BLOCK_DATA + 4, REG_BLOCK_DATA + 8, REG_BLOCK_DATA + 12 => {
                debug_block_data_writes += 1;
                // Block data write - each 32-bit write contains 2 RGB565 pixels
                if (!self.block_active) {
                    debug_block_active_false += 1;
                } else if (self.pixels_remaining == 0) {
                    debug_pixels_remaining_zero += 1;
                } else {
                    // Write first pixel (lower 16 bits)
                    self.lcd_ctrl.writePixel(@truncate(value));
                    debug_pixels_written += 1;
                    self.pixels_remaining -= 1;

                    // Write second pixel (upper 16 bits)
                    if (self.pixels_remaining > 0) {
                        self.lcd_ctrl.writePixel(@truncate(value >> 16));
                        debug_pixels_written += 1;
                        self.pixels_remaining -= 1;
                    }

                    // Check if transfer complete
                    if (self.pixels_remaining == 0) {
                        self.block_active = false;
                        // Signal transfer complete
                        self.block_ctrl = BLOCK_READY | BLOCK_TXOK;
                        // Trigger display update
                        self.lcd_ctrl.update();
                    }
                }
            },
            else => {
                // Handle any offset in the block data range (0x100-0x1FF)
                if (offset >= REG_BLOCK_DATA and offset < REG_BLOCK_DATA + 0x100) {
                    // Same handling as above
                    if (self.block_active and self.pixels_remaining > 0) {
                        self.lcd_ctrl.writePixel(@truncate(value));
                        if (self.pixels_remaining > 0) {
                            self.pixels_remaining -= 1;
                        }
                        if (self.pixels_remaining > 0) {
                            self.lcd_ctrl.writePixel(@truncate(value >> 16));
                            self.pixels_remaining -= 1;
                        }
                        if (self.pixels_remaining == 0) {
                            self.block_active = false;
                            self.block_ctrl = BLOCK_READY | BLOCK_TXOK;
                            self.lcd_ctrl.update();
                        }
                    }
                }
            },
        }
    }

    /// Create a peripheral handler for the memory bus
    pub fn createHandler(self: *Self) bus.PeripheralHandler {
        return .{
            .context = @ptrCast(self),
            .readFn = readWrapper,
            .writeFn = writeWrapper,
        };
    }

    fn readWrapper(ctx: *anyopaque, offset: u32) u32 {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.read(offset);
    }

    fn writeWrapper(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write(offset, value);
    }
};

// Tests
test "LCD dimensions" {
    try std.testing.expectEqual(@as(u32, 320), LCD_WIDTH);
    try std.testing.expectEqual(@as(u32, 240), LCD_HEIGHT);
    try std.testing.expectEqual(@as(usize, 153600), FRAMEBUFFER_SIZE);
}

test "RGB565 conversion" {
    const white = Color.fromRgb(255, 255, 255);
    try std.testing.expectEqual(@as(u5, 31), white.red);
    try std.testing.expectEqual(@as(u6, 63), white.green);
    try std.testing.expectEqual(@as(u5, 31), white.blue);

    const black = Color.fromRgb(0, 0, 0);
    try std.testing.expectEqual(@as(u5, 0), black.red);
    try std.testing.expectEqual(@as(u6, 0), black.green);
    try std.testing.expectEqual(@as(u5, 0), black.blue);

    const red = Color.fromRgb(255, 0, 0);
    try std.testing.expectEqual(@as(u5, 31), red.red);
    try std.testing.expectEqual(@as(u6, 0), red.green);
    try std.testing.expectEqual(@as(u5, 0), red.blue);
}

test "LCD pixel write" {
    var lcd = LcdController.init();

    // Set window to full screen
    lcd.setWindow(0, 0, LCD_WIDTH - 1, LCD_HEIGHT - 1);

    // Write a red pixel at (0, 0)
    const red = Color.fromRgb(255, 0, 0);
    lcd.writePixel(@bitCast(red));

    // Read it back
    const pixel = lcd.getPixel(0, 0);
    try std.testing.expectEqual(red.red, pixel.red);
    try std.testing.expectEqual(red.green, pixel.green);
    try std.testing.expectEqual(red.blue, pixel.blue);
}

test "LCD fill rect" {
    var lcd = LcdController.init();

    const blue = Color.fromRgb(0, 0, 255);
    lcd.fillRect(10, 10, 20, 20, blue);

    // Check a pixel inside the rectangle
    const pixel = lcd.getPixel(15, 15);
    try std.testing.expectEqual(blue.red, pixel.red);
    try std.testing.expectEqual(blue.green, pixel.green);
    try std.testing.expectEqual(blue.blue, pixel.blue);

    // Check a pixel outside the rectangle
    const outside = lcd.getPixel(5, 5);
    try std.testing.expectEqual(@as(u5, 0), outside.red);
    try std.testing.expectEqual(@as(u6, 0), outside.green);
    try std.testing.expectEqual(@as(u5, 0), outside.blue);
}
