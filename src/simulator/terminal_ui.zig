//! Terminal UI for ZigPod Simulator
//!
//! Provides an enhanced terminal-based visualization using ANSI escape codes
//! for color output and interactive keyboard input mapping.

const std = @import("std");
const simulator = @import("simulator.zig");

// ============================================================
// ANSI Terminal Constants
// ============================================================

const ANSI = struct {
    // Cursor control
    pub const CLEAR_SCREEN = "\x1B[2J";
    pub const HOME = "\x1B[H";
    pub const HIDE_CURSOR = "\x1B[?25l";
    pub const SHOW_CURSOR = "\x1B[?25h";
    pub const SAVE_CURSOR = "\x1B[s";
    pub const RESTORE_CURSOR = "\x1B[u";

    // Colors
    pub const RESET = "\x1B[0m";
    pub const BOLD = "\x1B[1m";
    pub const DIM = "\x1B[2m";
    pub const UNDERLINE = "\x1B[4m";
    pub const REVERSE = "\x1B[7m";

    // Foreground colors
    pub const FG_BLACK = "\x1B[30m";
    pub const FG_RED = "\x1B[31m";
    pub const FG_GREEN = "\x1B[32m";
    pub const FG_YELLOW = "\x1B[33m";
    pub const FG_BLUE = "\x1B[34m";
    pub const FG_MAGENTA = "\x1B[35m";
    pub const FG_CYAN = "\x1B[36m";
    pub const FG_WHITE = "\x1B[37m";

    // Background colors
    pub const BG_BLACK = "\x1B[40m";
    pub const BG_WHITE = "\x1B[47m";
    pub const BG_GRAY = "\x1B[100m";

    // Position cursor at row, col
    pub fn moveTo(writer: anytype, row: u16, col: u16) !void {
        try writer.print("\x1B[{d};{d}H", .{ row, col });
    }

    // Set 256-color foreground
    pub fn setFg256(writer: anytype, color: u8) !void {
        try writer.print("\x1B[38;5;{d}m", .{color});
    }

    // Set 256-color background
    pub fn setBg256(writer: anytype, color: u8) !void {
        try writer.print("\x1B[48;5;{d}m", .{color});
    }

    // Set 24-bit true color foreground
    pub fn setFgRgb(writer: anytype, r: u8, g: u8, b: u8) !void {
        try writer.print("\x1B[38;2;{d};{d};{d}m", .{ r, g, b });
    }

    // Set 24-bit true color background
    pub fn setBgRgb(writer: anytype, r: u8, g: u8, b: u8) !void {
        try writer.print("\x1B[48;2;{d};{d};{d}m", .{ r, g, b });
    }
};

// ============================================================
// Terminal UI Configuration
// ============================================================

pub const TerminalUIConfig = struct {
    /// Use true color (24-bit) output
    true_color: bool = true,
    /// LCD display scale (1 = 1 char per 4 pixels, 2 = 1 char per 8 pixels)
    lcd_scale: u8 = 4,
    /// Show status bar
    show_status: bool = true,
    /// Show help panel
    show_help: bool = true,
    /// Refresh rate in milliseconds
    refresh_ms: u32 = 100,
};

// ============================================================
// Terminal UI
// ============================================================

pub const TerminalUI = struct {
    config: TerminalUIConfig,
    writer: std.fs.File.Writer,
    last_render_time: i128,
    frame_count: u64,

    /// Initialize terminal UI with a writer
    pub fn init(config: TerminalUIConfig, writer: std.fs.File.Writer) TerminalUI {
        return TerminalUI{
            .config = config,
            .writer = writer,
            .last_render_time = std.time.nanoTimestamp(),
            .frame_count = 0,
        };
    }

    /// Setup terminal for UI (hide cursor, clear screen)
    pub fn setup(self: *TerminalUI) !void {
        try self.writer.writeAll(ANSI.HIDE_CURSOR);
        try self.writer.writeAll(ANSI.CLEAR_SCREEN);
        try self.writer.writeAll(ANSI.HOME);
    }

    /// Cleanup terminal (show cursor, reset colors)
    pub fn cleanup(self: *TerminalUI) void {
        self.writer.writeAll(ANSI.SHOW_CURSOR) catch {};
        self.writer.writeAll(ANSI.RESET) catch {};
        self.writer.writeAll(ANSI.CLEAR_SCREEN) catch {};
        self.writer.writeAll(ANSI.HOME) catch {};
    }

    /// Render the full UI
    pub fn render(self: *TerminalUI, state: *simulator.SimulatorState) !void {
        // Rate limiting
        const now = std.time.nanoTimestamp();
        const elapsed_ms = @divTrunc(now - self.last_render_time, 1_000_000);
        if (elapsed_ms < self.config.refresh_ms) return;
        self.last_render_time = now;
        self.frame_count += 1;

        // Start rendering
        try self.writer.writeAll(ANSI.HOME);

        // Draw LCD frame
        try self.drawLcdFrame(state);

        // Draw status bar
        if (self.config.show_status) {
            try self.drawStatusBar(state);
        }

        // Draw help panel
        if (self.config.show_help) {
            try self.drawHelpPanel();
        }
    }

    /// Draw the LCD display with colors
    fn drawLcdFrame(self: *TerminalUI, state: *simulator.SimulatorState) !void {
        const scale = self.config.lcd_scale;
        const display_width: usize = 320 / scale;

        // Top border
        try self.writer.writeAll(ANSI.FG_CYAN);
        try self.writer.writeAll("╔");
        for (0..display_width) |_| {
            try self.writer.writeAll("═");
        }
        try self.writer.writeAll("╗\n");

        // LCD content
        var y: usize = 0;
        while (y < 240) : (y += scale * 2) {
            try self.writer.writeAll(ANSI.FG_CYAN);
            try self.writer.writeAll("║");

            var x: usize = 0;
            while (x < 320) : (x += scale) {
                // Sample the pixel at this position
                const pixel = state.lcd_framebuffer[y * 320 + x];
                try self.writeColoredPixel(pixel);
            }

            try self.writer.writeAll(ANSI.RESET);
            try self.writer.writeAll(ANSI.FG_CYAN);
            try self.writer.writeAll("║\n");
        }

        // Bottom border
        try self.writer.writeAll("╚");
        for (0..display_width) |_| {
            try self.writer.writeAll("═");
        }
        try self.writer.writeAll("╝");
        try self.writer.writeAll(ANSI.RESET);
        try self.writer.writeAll("\n");
    }

    /// Write a colored pixel character using terminal colors
    fn writeColoredPixel(self: *TerminalUI, rgb565: u16) !void {
        // Extract RGB components from RGB565
        const r5: u8 = @intCast((rgb565 >> 11) & 0x1F);
        const g6: u8 = @intCast((rgb565 >> 5) & 0x3F);
        const b5: u8 = @intCast(rgb565 & 0x1F);

        // Convert to 8-bit RGB
        const r8: u8 = @intCast((@as(u16, r5) * 255) / 31);
        const g8: u8 = @intCast((@as(u16, g6) * 255) / 63);
        const b8: u8 = @intCast((@as(u16, b5) * 255) / 31);

        if (self.config.true_color) {
            // True color mode - use actual RGB values
            try ANSI.setBgRgb(self.writer, r8, g8, b8);
        } else {
            // 256 color mode - quantize to palette
            const color = rgb888To256(r8, g8, b8);
            try ANSI.setBg256(self.writer, color);
        }

        // Use space character with background color
        try self.writer.writeAll(" ");
        try self.writer.writeAll(ANSI.RESET);
    }

    /// Draw the status bar
    fn drawStatusBar(self: *TerminalUI, state: *simulator.SimulatorState) !void {
        try self.writer.writeAll("\n");
        try self.writer.writeAll(ANSI.BOLD);
        try self.writer.writeAll("┌─ Status ");
        try self.writer.writeAll("─" ** 60);
        try self.writer.writeAll("┐\n");
        try self.writer.writeAll(ANSI.RESET);

        // First row: Backlight, Wheel, Buttons
        try self.writer.print("│ Backlight: {s}{s}{s}  ", .{
            if (state.lcd_backlight) ANSI.FG_GREEN else ANSI.FG_RED,
            if (state.lcd_backlight) "ON " else "OFF",
            ANSI.RESET,
        });

        try self.writer.print("│ Wheel: {s}{d:0>2}{s}  ", .{
            ANSI.FG_YELLOW,
            state.wheel_position,
            ANSI.RESET,
        });

        try self.writer.print("│ Buttons: {s}0x{X:0>2}{s}  ", .{
            ANSI.FG_CYAN,
            state.button_state,
            ANSI.RESET,
        });

        // Decode button state
        try self.writer.writeAll("│ ");
        try self.drawButtonIndicators(state.button_state);
        try self.writer.writeAll("\n");

        // Second row: Time, Audio, FPS
        const sim_time_us = state.getTimeUs();
        const sim_time_s = sim_time_us / 1_000_000;
        const sim_time_ms = (sim_time_us / 1000) % 1000;

        try self.writer.print("│ Time: {s}{d}.{d:0>3}s{s}  ", .{
            ANSI.FG_MAGENTA,
            sim_time_s,
            sim_time_ms,
            ANSI.RESET,
        });

        try self.writer.print("│ Audio: {s}{s}{s}  ", .{
            if (state.audio_enabled) ANSI.FG_GREEN else ANSI.FG_RED,
            if (state.audio_enabled) "ENABLED " else "DISABLED",
            ANSI.RESET,
        });

        try self.writer.print("│ Frame: {s}{d}{s}  ", .{
            ANSI.FG_BLUE,
            self.frame_count,
            ANSI.RESET,
        });

        try self.writer.writeAll("│\n");

        try self.writer.writeAll("└");
        try self.writer.writeAll("─" ** 70);
        try self.writer.writeAll("┘\n");
    }

    /// Draw button indicators
    fn drawButtonIndicators(self: *TerminalUI, buttons: u8) !void {
        const indicators = [_]struct { bit: u3, name: []const u8 }{
            .{ .bit = 0, .name = "Menu" },
            .{ .bit = 1, .name = "Play" },
            .{ .bit = 2, .name = "Next" },
            .{ .bit = 3, .name = "Prev" },
            .{ .bit = 4, .name = "Select" },
        };

        for (indicators) |ind| {
            const pressed = (buttons & (@as(u8, 1) << ind.bit)) != 0;
            if (pressed) {
                try self.writer.writeAll(ANSI.REVERSE);
            }
            try self.writer.writeAll("[");
            try self.writer.writeAll(ind.name);
            try self.writer.writeAll("]");
            if (pressed) {
                try self.writer.writeAll(ANSI.RESET);
            }
            try self.writer.writeAll(" ");
        }
    }

    /// Draw help panel
    fn drawHelpPanel(self: *TerminalUI) !void {
        try self.writer.writeAll("\n");
        try self.writer.writeAll(ANSI.DIM);
        try self.writer.writeAll("┌─ Controls ");
        try self.writer.writeAll("─" ** 58);
        try self.writer.writeAll("┐\n");

        try self.writer.writeAll("│ M: Menu    P: Play/Pause    N: Next    B: Prev    Enter: Select │\n");
        try self.writer.writeAll("│ ←/→: Scroll Wheel    Q: Quit                                    │\n");

        try self.writer.writeAll("└");
        try self.writer.writeAll("─" ** 70);
        try self.writer.writeAll("┘");
        try self.writer.writeAll(ANSI.RESET);
        try self.writer.writeAll("\n");
    }
};

// ============================================================
// Color Conversion Utilities
// ============================================================

/// Convert RGB888 to closest 256-color palette index
fn rgb888To256(r: u8, g: u8, b: u8) u8 {
    // Grayscale check
    if (r == g and g == b) {
        if (r < 8) return 16; // Black
        if (r > 248) return 231; // White
        return @as(u8, @intCast(@divTrunc(@as(u16, r) - 8, 10) + 232));
    }

    // Color cube (6x6x6)
    const r6: u8 = @intCast(@min(5, @divTrunc(@as(u16, r) * 6, 256)));
    const g6: u8 = @intCast(@min(5, @divTrunc(@as(u16, g) * 6, 256)));
    const b6: u8 = @intCast(@min(5, @divTrunc(@as(u16, b) * 6, 256)));

    return 16 + 36 * r6 + 6 * g6 + b6;
}

/// Convert RGB565 to RGB888
pub fn rgb565ToRgb888(rgb565: u16) struct { r: u8, g: u8, b: u8 } {
    const r5: u8 = @intCast((rgb565 >> 11) & 0x1F);
    const g6: u8 = @intCast((rgb565 >> 5) & 0x3F);
    const b5: u8 = @intCast(rgb565 & 0x1F);

    return .{
        .r = @intCast((@as(u16, r5) * 255) / 31),
        .g = @intCast((@as(u16, g6) * 255) / 63),
        .b = @intCast((@as(u16, b5) * 255) / 31),
    };
}

/// Convert RGB888 to RGB565
pub fn rgb888ToRgb565(r: u8, g: u8, b: u8) u16 {
    const r5: u16 = @as(u16, r >> 3);
    const g6: u16 = @as(u16, g >> 2);
    const b5: u16 = @as(u16, b >> 3);
    return @intCast((r5 << 11) | (g6 << 5) | b5);
}

// ============================================================
// Interactive Runner
// ============================================================

pub const SimulatorRunner = struct {
    sim_state: *simulator.SimulatorState,
    ui: TerminalUI,
    running: bool,
    allocator: std.mem.Allocator,

    /// Initialize the runner
    pub fn init(allocator: std.mem.Allocator, ui_config: TerminalUIConfig, sim_config: simulator.SimulatorConfig) !SimulatorRunner {
        const sim_state = try simulator.SimulatorState.init(allocator, sim_config);
        return SimulatorRunner{
            .sim_state = sim_state,
            .ui = TerminalUI.init(ui_config),
            .running = false,
            .allocator = allocator,
        };
    }

    /// Cleanup
    pub fn deinit(self: *SimulatorRunner) void {
        self.ui.cleanup();
        self.sim_state.deinit();
    }

    /// Run the simulator interactively
    pub fn run(self: *SimulatorRunner) !void {
        try self.ui.setup();
        self.running = true;

        while (self.running) {
            // Render UI
            try self.ui.render(self.sim_state);

            // Small delay to prevent CPU spinning
            std.Thread.sleep(10_000_000); // 10ms
        }

        self.ui.cleanup();
    }

    /// Stop the runner
    pub fn stop(self: *SimulatorRunner) void {
        self.running = false;
    }

    /// Handle keyboard input (called from external input handler)
    pub fn handleKey(self: *SimulatorRunner, key: u8) void {
        switch (key) {
            'q', 'Q' => self.running = false,
            'm', 'M' => self.sim_state.button_state ^= 0x01, // Menu toggle
            'p', 'P' => self.sim_state.button_state ^= 0x02, // Play toggle
            'n', 'N' => self.sim_state.button_state ^= 0x04, // Next toggle
            'b', 'B' => self.sim_state.button_state ^= 0x08, // Prev toggle
            '\r', '\n' => self.sim_state.button_state ^= 0x10, // Select toggle
            // Arrow keys would need special handling for wheel position
            else => {},
        }
    }

    /// Simulate button press (auto-release after delay)
    pub fn pressButton(self: *SimulatorRunner, button_mask: u8) void {
        self.sim_state.button_state |= button_mask;
    }

    /// Release button
    pub fn releaseButton(self: *SimulatorRunner, button_mask: u8) void {
        self.sim_state.button_state &= ~button_mask;
    }

    /// Rotate wheel
    pub fn rotateWheel(self: *SimulatorRunner, delta: i8) void {
        const current = @as(i16, self.sim_state.wheel_position);
        const new_pos = @mod(current + delta, 96);
        self.sim_state.wheel_position = @intCast(new_pos);
    }
};

// ============================================================
// Tests
// ============================================================

test "rgb565 to rgb888 conversion" {
    // Pure white
    const white = rgb565ToRgb888(0xFFFF);
    try std.testing.expectEqual(@as(u8, 255), white.r);
    try std.testing.expectEqual(@as(u8, 255), white.g);
    try std.testing.expectEqual(@as(u8, 255), white.b);

    // Pure black
    const black = rgb565ToRgb888(0x0000);
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);

    // Pure red
    const red = rgb565ToRgb888(0xF800);
    try std.testing.expectEqual(@as(u8, 255), red.r);
    try std.testing.expectEqual(@as(u8, 0), red.g);
    try std.testing.expectEqual(@as(u8, 0), red.b);
}

test "rgb888 to rgb565 conversion" {
    // Pure white
    const white = rgb888ToRgb565(255, 255, 255);
    try std.testing.expectEqual(@as(u16, 0xFFFF), white);

    // Pure black
    const black = rgb888ToRgb565(0, 0, 0);
    try std.testing.expectEqual(@as(u16, 0x0000), black);

    // Pure red
    const red = rgb888ToRgb565(255, 0, 0);
    try std.testing.expectEqual(@as(u16, 0xF800), red);
}

test "rgb888 to 256 color" {
    // Black
    try std.testing.expectEqual(@as(u8, 16), rgb888To256(0, 0, 0));

    // White
    try std.testing.expectEqual(@as(u8, 231), rgb888To256(255, 255, 255));

    // Gray
    const gray = rgb888To256(128, 128, 128);
    try std.testing.expect(gray >= 232 and gray <= 255);
}

test "terminal ui config defaults" {
    const config = TerminalUIConfig{};
    try std.testing.expect(config.true_color);
    try std.testing.expectEqual(@as(u8, 4), config.lcd_scale);
    try std.testing.expect(config.show_status);
    try std.testing.expect(config.show_help);
    try std.testing.expectEqual(@as(u32, 100), config.refresh_ms);
}
