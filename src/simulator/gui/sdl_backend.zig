//! SDL2 GUI Backend for ZigPod Simulator
//!
//! Provides a high-fidelity iPod Classic visual representation using SDL2.
//! Shows the LCD screen, click wheel, and button layout.

const std = @import("std");
const gui = @import("gui.zig");

const GuiVTable = gui.GuiVTable;
const GuiBackend = gui.GuiBackend;
const LcdConfig = gui.LcdConfig;
const Event = gui.Event;
const EventType = gui.EventType;
const Button = gui.Button;
const Color = gui.Color;

/// SDL2 C bindings
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

// ============================================================
// iPod Visual Layout Constants
// ============================================================

/// iPod Classic dimensions (scaled)
const IPOD_WIDTH: c_int = 400;
const IPOD_HEIGHT: c_int = 700;

/// LCD position within iPod body
const LCD_X: c_int = 40;
const LCD_Y: c_int = 60;
const LCD_WIDTH: c_int = 320;
const LCD_HEIGHT: c_int = 240;

/// Click wheel position and size
const WHEEL_CENTER_X: c_int = IPOD_WIDTH / 2;
const WHEEL_CENTER_Y: c_int = 500;
const WHEEL_OUTER_RADIUS: c_int = 130;
const WHEEL_INNER_RADIUS: c_int = 50;

/// Button positions on the wheel (relative to center)
const MENU_BUTTON_Y: c_int = -95;
const PREV_BUTTON_X: c_int = -95;
const NEXT_BUTTON_X: c_int = 95;
const PLAY_BUTTON_Y: c_int = 95;

// ============================================================
// Colors
// ============================================================

const COLOR_IPOD_BODY: [3]u8 = .{ 220, 220, 225 }; // Silver
const COLOR_IPOD_BEZEL: [3]u8 = .{ 40, 40, 45 }; // Dark gray
const COLOR_LCD_OFF: [3]u8 = .{ 30, 35, 30 }; // Dark greenish
const COLOR_WHEEL: [3]u8 = .{ 240, 240, 245 }; // Light silver
const COLOR_WHEEL_BUTTON: [3]u8 = .{ 180, 180, 185 }; // Darker silver
const COLOR_CENTER_BUTTON: [3]u8 = .{ 200, 200, 205 }; // Medium silver
const COLOR_BUTTON_PRESSED: [3]u8 = .{ 100, 150, 255 }; // Blue highlight
const COLOR_WHEEL_INDICATOR: [3]u8 = .{ 50, 120, 255 }; // Blue dot

/// SDL2 Backend implementation
pub const Sdl2Backend = struct {
    window: ?*c.SDL_Window = null,
    renderer: ?*c.SDL_Renderer = null,
    lcd_texture: ?*c.SDL_Texture = null,
    config: LcdConfig = .{},
    open: bool = false,
    button_states: [7]bool = [_]bool{false} ** 7,
    wheel_pos: u8 = 0,
    backlight_on: bool = true,
    // Pixel buffer for LCD
    pixel_buffer: []u32 = &[_]u32{},
    allocator: std.mem.Allocator,
    // Mouse state for wheel interaction
    mouse_in_wheel: bool = false,
    last_wheel_angle: f32 = 0,

    const Self = @This();

    /// Create a new SDL2 backend
    pub fn create(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Get the GUI backend interface
    pub fn getBackend(self: *Self) GuiBackend {
        return .{
            .vtable = &vtable,
            .context = self,
        };
    }

    fn initImpl(ctx: *anyopaque, config: LcdConfig) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.config = config;

        // Initialize SDL
        if (c.SDL_Init(c.SDL_INIT_VIDEO) < 0) {
            return error.SdlInitFailed;
        }
        errdefer c.SDL_Quit();

        // Create window sized for iPod visual
        self.window = c.SDL_CreateWindow(
            "ZigPod Simulator - iPod Classic",
            c.SDL_WINDOWPOS_CENTERED,
            c.SDL_WINDOWPOS_CENTERED,
            IPOD_WIDTH,
            IPOD_HEIGHT,
            c.SDL_WINDOW_SHOWN,
        );
        if (self.window == null) {
            return error.WindowCreationFailed;
        }
        errdefer c.SDL_DestroyWindow(self.window);

        // Create renderer with vsync
        self.renderer = c.SDL_CreateRenderer(
            self.window,
            -1,
            c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC,
        );
        if (self.renderer == null) {
            return error.RendererCreationFailed;
        }
        errdefer c.SDL_DestroyRenderer(self.renderer);

        // Enable alpha blending
        _ = c.SDL_SetRenderDrawBlendMode(self.renderer, c.SDL_BLENDMODE_BLEND);

        // Create texture for LCD display (320x240)
        self.lcd_texture = c.SDL_CreateTexture(
            self.renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_STREAMING,
            LCD_WIDTH,
            LCD_HEIGHT,
        );
        if (self.lcd_texture == null) {
            return error.TextureCreationFailed;
        }

        // Allocate pixel buffer for LCD
        const buffer_size: usize = @intCast(LCD_WIDTH * LCD_HEIGHT);
        self.pixel_buffer = try self.allocator.alloc(u32, buffer_size);

        self.open = true;
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (self.pixel_buffer.len > 0) {
            self.allocator.free(self.pixel_buffer);
            self.pixel_buffer = &[_]u32{};
        }

        if (self.lcd_texture) |tex| {
            c.SDL_DestroyTexture(tex);
            self.lcd_texture = null;
        }
        if (self.renderer) |ren| {
            c.SDL_DestroyRenderer(ren);
            self.renderer = null;
        }
        if (self.window) |win| {
            c.SDL_DestroyWindow(win);
            self.window = null;
        }
        c.SDL_Quit();
        self.open = false;
    }

    fn updateLcdImpl(ctx: *anyopaque, framebuffer: []const u16) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.lcd_texture == null) return;

        const pixels_to_convert = @min(framebuffer.len, self.pixel_buffer.len);

        // Convert RGB565 to ARGB8888
        for (0..pixels_to_convert) |i| {
            const rgb565 = framebuffer[i];
            const rgb = Color.rgb565ToRgb888(rgb565);

            // Apply backlight effect
            if (self.backlight_on) {
                self.pixel_buffer[i] = 0xFF000000 |
                    (@as(u32, rgb.r) << 16) |
                    (@as(u32, rgb.g) << 8) |
                    @as(u32, rgb.b);
            } else {
                // Dim display when backlight is off
                self.pixel_buffer[i] = 0xFF000000 |
                    (@as(u32, rgb.r / 4) << 16) |
                    (@as(u32, rgb.g / 4) << 8) |
                    @as(u32, rgb.b / 4);
            }
        }

        // Update texture
        _ = c.SDL_UpdateTexture(
            self.lcd_texture,
            null,
            @ptrCast(self.pixel_buffer.ptr),
            LCD_WIDTH * @sizeOf(u32),
        );
    }

    fn pollEventImpl(ctx: *anyopaque) ?Event {
        const self: *Self = @ptrCast(@alignCast(ctx));

        var sdl_event: c.SDL_Event = undefined;
        if (c.SDL_PollEvent(&sdl_event) != 0) {
            return self.translateEvent(&sdl_event);
        }
        return null;
    }

    fn translateEvent(self: *Self, sdl_event: *c.SDL_Event) ?Event {
        switch (sdl_event.type) {
            c.SDL_QUIT => {
                self.open = false;
                return .{ .event_type = .quit };
            },
            c.SDL_KEYDOWN => {
                if (sdl_event.key.repeat != 0) return null; // Ignore key repeat
                const button = mapKeyToButton(sdl_event.key.keysym.sym);
                if (button) |btn| {
                    self.button_states[@intFromEnum(btn)] = true;
                    return .{ .event_type = .button_press, .button = btn };
                }
                return .{ .event_type = .key_down, .keycode = @intCast(sdl_event.key.keysym.sym) };
            },
            c.SDL_KEYUP => {
                const button = mapKeyToButton(sdl_event.key.keysym.sym);
                if (button) |btn| {
                    self.button_states[@intFromEnum(btn)] = false;
                    return .{ .event_type = .button_release, .button = btn };
                }
                return .{ .event_type = .key_up, .keycode = @intCast(sdl_event.key.keysym.sym) };
            },
            c.SDL_MOUSEBUTTONDOWN => {
                return self.handleMouseDown(sdl_event.button.x, sdl_event.button.y);
            },
            c.SDL_MOUSEBUTTONUP => {
                return self.handleMouseUp(sdl_event.button.x, sdl_event.button.y);
            },
            c.SDL_MOUSEMOTION => {
                if (sdl_event.motion.state != 0) { // Button held
                    return self.handleMouseDrag(sdl_event.motion.x, sdl_event.motion.y);
                }
            },
            c.SDL_MOUSEWHEEL => {
                // Scroll wheel simulates click wheel rotation
                const delta: i8 = if (sdl_event.wheel.y > 0) 8 else if (sdl_event.wheel.y < 0) -8 else 0;
                if (delta != 0) {
                    return .{ .event_type = .wheel_turn, .wheel_delta = delta };
                }
            },
            else => {},
        }
        return null;
    }

    fn handleMouseDown(self: *Self, x: c_int, y: c_int) ?Event {
        // Check center button
        const center_dist = distance(x, y, WHEEL_CENTER_X, WHEEL_CENTER_Y);
        if (center_dist <= WHEEL_INNER_RADIUS) {
            self.button_states[@intFromEnum(Button.select)] = true;
            return .{ .event_type = .button_press, .button = .select };
        }

        // Check if in wheel ring
        if (center_dist <= WHEEL_OUTER_RADIUS and center_dist > WHEEL_INNER_RADIUS) {
            self.mouse_in_wheel = true;
            self.last_wheel_angle = std.math.atan2(
                @as(f32, @floatFromInt(y - WHEEL_CENTER_Y)),
                @as(f32, @floatFromInt(x - WHEEL_CENTER_X)),
            );

            // Check which button zone
            const button = self.getWheelButton(x, y);
            if (button) |btn| {
                self.button_states[@intFromEnum(btn)] = true;
                return .{ .event_type = .button_press, .button = btn };
            }
        }

        return null;
    }

    fn handleMouseUp(self: *Self, x: c_int, y: c_int) ?Event {
        _ = x;
        _ = y;
        self.mouse_in_wheel = false;

        // Release all buttons
        for (0..5) |i| {
            if (self.button_states[i]) {
                self.button_states[i] = false;
                return .{ .event_type = .button_release, .button = @enumFromInt(i) };
            }
        }
        return null;
    }

    fn handleMouseDrag(self: *Self, x: c_int, y: c_int) ?Event {
        if (!self.mouse_in_wheel) return null;

        const center_dist = distance(x, y, WHEEL_CENTER_X, WHEEL_CENTER_Y);
        if (center_dist <= WHEEL_OUTER_RADIUS and center_dist > WHEEL_INNER_RADIUS) {
            const new_angle = std.math.atan2(
                @as(f32, @floatFromInt(y - WHEEL_CENTER_Y)),
                @as(f32, @floatFromInt(x - WHEEL_CENTER_X)),
            );

            var angle_diff = new_angle - self.last_wheel_angle;

            // Handle wrap-around
            if (angle_diff > std.math.pi) {
                angle_diff -= 2.0 * std.math.pi;
            } else if (angle_diff < -std.math.pi) {
                angle_diff += 2.0 * std.math.pi;
            }

            // Convert to wheel delta (scale appropriately)
            const delta: i8 = @intFromFloat(angle_diff * 20.0);
            if (delta != 0) {
                self.last_wheel_angle = new_angle;
                // Update wheel position
                const new_pos = @as(i16, self.wheel_pos) + delta;
                self.wheel_pos = @truncate(@as(u16, @bitCast(@as(i16, @truncate(new_pos)))));
                return .{ .event_type = .wheel_turn, .wheel_delta = delta };
            }
        }
        return null;
    }

    fn getWheelButton(self: *Self, x: c_int, y: c_int) ?Button {
        _ = self;
        const dx = x - WHEEL_CENTER_X;
        const dy = y - WHEEL_CENTER_Y;

        // Determine which quadrant/button zone
        if (@abs(dx) > @abs(dy)) {
            // Left or right
            if (dx < 0) return .prev else return .next;
        } else {
            // Top or bottom
            if (dy < 0) return .menu else return .play_pause;
        }
    }

    fn mapKeyToButton(keycode: c_int) ?Button {
        return switch (keycode) {
            c.SDLK_m, c.SDLK_ESCAPE => .menu,
            c.SDLK_SPACE, c.SDLK_p => .play_pause,
            c.SDLK_RIGHT, c.SDLK_n => .next,
            c.SDLK_LEFT, c.SDLK_b => .prev,
            c.SDLK_RETURN, c.SDLK_s => .select,
            c.SDLK_h => .hold,
            c.SDLK_r => .repeat, // R key toggles repeat mode
            // Note: UP/DOWN arrows are handled separately for menu navigation
            else => null,
        };
    }

    fn setButtonStateImpl(ctx: *anyopaque, button: Button, pressed: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.button_states[@intFromEnum(button)] = pressed;
    }

    fn setWheelPositionImpl(ctx: *anyopaque, pos: u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.wheel_pos = pos;
    }

    fn isOpenImpl(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.open;
    }

    fn presentImpl(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.renderer == null) return;

        // Clear with background color
        _ = c.SDL_SetRenderDrawColor(self.renderer, 50, 50, 55, 255);
        _ = c.SDL_RenderClear(self.renderer);

        // Draw iPod body
        self.drawIpodBody();

        // Draw LCD screen
        self.drawLcdScreen();

        // Draw click wheel
        self.drawClickWheel();

        // Draw status bar
        self.drawStatusBar();

        c.SDL_RenderPresent(self.renderer);
    }

    fn drawIpodBody(self: *Self) void {
        const renderer = self.renderer orelse return;

        // Main body (rounded rectangle approximation)
        _ = c.SDL_SetRenderDrawColor(renderer, COLOR_IPOD_BODY[0], COLOR_IPOD_BODY[1], COLOR_IPOD_BODY[2], 255);

        var body_rect = c.SDL_Rect{
            .x = 10,
            .y = 10,
            .w = IPOD_WIDTH - 20,
            .h = IPOD_HEIGHT - 20,
        };
        _ = c.SDL_RenderFillRect(renderer, &body_rect);

        // Edge highlight (top)
        _ = c.SDL_SetRenderDrawColor(renderer, 250, 250, 255, 255);
        var highlight_rect = c.SDL_Rect{
            .x = 12,
            .y = 12,
            .w = IPOD_WIDTH - 24,
            .h = 3,
        };
        _ = c.SDL_RenderFillRect(renderer, &highlight_rect);

        // Edge shadow (bottom)
        _ = c.SDL_SetRenderDrawColor(renderer, 150, 150, 155, 255);
        var shadow_rect = c.SDL_Rect{
            .x = 12,
            .y = IPOD_HEIGHT - 15,
            .w = IPOD_WIDTH - 24,
            .h = 3,
        };
        _ = c.SDL_RenderFillRect(renderer, &shadow_rect);
    }

    fn drawLcdScreen(self: *Self) void {
        const renderer = self.renderer orelse return;

        // LCD bezel (dark frame around screen)
        _ = c.SDL_SetRenderDrawColor(renderer, COLOR_IPOD_BEZEL[0], COLOR_IPOD_BEZEL[1], COLOR_IPOD_BEZEL[2], 255);
        var bezel_rect = c.SDL_Rect{
            .x = LCD_X - 5,
            .y = LCD_Y - 5,
            .w = LCD_WIDTH + 10,
            .h = LCD_HEIGHT + 10,
        };
        _ = c.SDL_RenderFillRect(renderer, &bezel_rect);

        // LCD screen area
        if (self.lcd_texture) |texture| {
            var lcd_rect = c.SDL_Rect{
                .x = LCD_X,
                .y = LCD_Y,
                .w = LCD_WIDTH,
                .h = LCD_HEIGHT,
            };
            _ = c.SDL_RenderCopy(renderer, texture, null, &lcd_rect);
        } else {
            // Show "off" state
            _ = c.SDL_SetRenderDrawColor(renderer, COLOR_LCD_OFF[0], COLOR_LCD_OFF[1], COLOR_LCD_OFF[2], 255);
            var lcd_rect = c.SDL_Rect{
                .x = LCD_X,
                .y = LCD_Y,
                .w = LCD_WIDTH,
                .h = LCD_HEIGHT,
            };
            _ = c.SDL_RenderFillRect(renderer, &lcd_rect);
        }
    }

    fn drawClickWheel(self: *Self) void {
        if (self.renderer == null) return;

        // Draw outer wheel ring
        self.drawFilledCircle(WHEEL_CENTER_X, WHEEL_CENTER_Y, WHEEL_OUTER_RADIUS, COLOR_WHEEL);

        // Draw button zones (subtle highlights when pressed)
        self.drawWheelButtons();

        // Draw center button
        const center_color = if (self.button_states[@intFromEnum(Button.select)])
            COLOR_BUTTON_PRESSED
        else
            COLOR_CENTER_BUTTON;
        self.drawFilledCircle(WHEEL_CENTER_X, WHEEL_CENTER_Y, WHEEL_INNER_RADIUS, center_color);

        // Draw wheel position indicator (blue dot on outer ring)
        const angle = @as(f32, @floatFromInt(self.wheel_pos)) * std.math.pi * 2.0 / 256.0 - std.math.pi / 2.0;
        const indicator_radius: f32 = @floatFromInt((WHEEL_OUTER_RADIUS + WHEEL_INNER_RADIUS) / 2);
        const indicator_x: c_int = WHEEL_CENTER_X + @as(c_int, @intFromFloat(@cos(angle) * indicator_radius));
        const indicator_y: c_int = WHEEL_CENTER_Y + @as(c_int, @intFromFloat(@sin(angle) * indicator_radius));
        self.drawFilledCircle(indicator_x, indicator_y, 8, COLOR_WHEEL_INDICATOR);

        // Draw button labels
        self.drawButtonLabels();
    }

    fn drawWheelButtons(self: *Self) void {
        const renderer = self.renderer orelse return;

        // Menu button (top)
        if (self.button_states[@intFromEnum(Button.menu)]) {
            _ = c.SDL_SetRenderDrawColor(renderer, COLOR_BUTTON_PRESSED[0], COLOR_BUTTON_PRESSED[1], COLOR_BUTTON_PRESSED[2], 150);
            self.drawWheelSegment(0);
        }

        // Prev button (left)
        if (self.button_states[@intFromEnum(Button.prev)]) {
            _ = c.SDL_SetRenderDrawColor(renderer, COLOR_BUTTON_PRESSED[0], COLOR_BUTTON_PRESSED[1], COLOR_BUTTON_PRESSED[2], 150);
            self.drawWheelSegment(1);
        }

        // Next button (right)
        if (self.button_states[@intFromEnum(Button.next)]) {
            _ = c.SDL_SetRenderDrawColor(renderer, COLOR_BUTTON_PRESSED[0], COLOR_BUTTON_PRESSED[1], COLOR_BUTTON_PRESSED[2], 150);
            self.drawWheelSegment(2);
        }

        // Play/Pause button (bottom)
        if (self.button_states[@intFromEnum(Button.play_pause)]) {
            _ = c.SDL_SetRenderDrawColor(renderer, COLOR_BUTTON_PRESSED[0], COLOR_BUTTON_PRESSED[1], COLOR_BUTTON_PRESSED[2], 150);
            self.drawWheelSegment(3);
        }
    }

    fn drawWheelSegment(self: *Self, segment: u8) void {
        const renderer = self.renderer orelse return;

        // Draw a pie-shaped segment of the wheel
        const start_angle: f32 = switch (segment) {
            0 => -std.math.pi * 0.75, // Top (Menu)
            1 => std.math.pi * 0.75, // Left (Prev)
            2 => -std.math.pi * 0.25, // Right (Next)
            3 => std.math.pi * 0.25, // Bottom (Play)
            else => 0,
        };
        const end_angle = start_angle + std.math.pi * 0.5;

        // Draw filled arc using triangles
        const steps: usize = 20;
        const inner: f32 = @floatFromInt(WHEEL_INNER_RADIUS);
        const outer: f32 = @floatFromInt(WHEEL_OUTER_RADIUS);

        var i: usize = 0;
        while (i < steps) : (i += 1) {
            const t1 = start_angle + (end_angle - start_angle) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const t2 = start_angle + (end_angle - start_angle) * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(steps));

            const x1 = WHEEL_CENTER_X + @as(c_int, @intFromFloat(@cos(t1) * inner));
            const y1 = WHEEL_CENTER_Y + @as(c_int, @intFromFloat(@sin(t1) * inner));
            const x2 = WHEEL_CENTER_X + @as(c_int, @intFromFloat(@cos(t1) * outer));
            const y2 = WHEEL_CENTER_Y + @as(c_int, @intFromFloat(@sin(t1) * outer));
            const x3 = WHEEL_CENTER_X + @as(c_int, @intFromFloat(@cos(t2) * outer));
            const y3 = WHEEL_CENTER_Y + @as(c_int, @intFromFloat(@sin(t2) * outer));
            const x4 = WHEEL_CENTER_X + @as(c_int, @intFromFloat(@cos(t2) * inner));
            const y4 = WHEEL_CENTER_Y + @as(c_int, @intFromFloat(@sin(t2) * inner));

            _ = c.SDL_RenderDrawLine(renderer, x1, y1, x2, y2);
            _ = c.SDL_RenderDrawLine(renderer, x2, y2, x3, y3);
            _ = c.SDL_RenderDrawLine(renderer, x3, y3, x4, y4);
            _ = c.SDL_RenderDrawLine(renderer, x4, y4, x1, y1);
        }
    }

    fn drawButtonLabels(self: *Self) void {
        const renderer = self.renderer orelse return;

        // Draw simple button indicators (symbols)
        _ = c.SDL_SetRenderDrawColor(renderer, 80, 80, 85, 255);

        // Menu (top) - horizontal line
        var rect = c.SDL_Rect{ .x = WHEEL_CENTER_X - 15, .y = WHEEL_CENTER_Y + MENU_BUTTON_Y - 2, .w = 30, .h = 4 };
        _ = c.SDL_RenderFillRect(renderer, &rect);

        // Prev (left) - two left arrows (<<)
        _ = c.SDL_RenderDrawLine(renderer, WHEEL_CENTER_X + PREV_BUTTON_X + 10, WHEEL_CENTER_Y - 8, WHEEL_CENTER_X + PREV_BUTTON_X, WHEEL_CENTER_Y);
        _ = c.SDL_RenderDrawLine(renderer, WHEEL_CENTER_X + PREV_BUTTON_X, WHEEL_CENTER_Y, WHEEL_CENTER_X + PREV_BUTTON_X + 10, WHEEL_CENTER_Y + 8);
        _ = c.SDL_RenderDrawLine(renderer, WHEEL_CENTER_X + PREV_BUTTON_X + 20, WHEEL_CENTER_Y - 8, WHEEL_CENTER_X + PREV_BUTTON_X + 10, WHEEL_CENTER_Y);
        _ = c.SDL_RenderDrawLine(renderer, WHEEL_CENTER_X + PREV_BUTTON_X + 10, WHEEL_CENTER_Y, WHEEL_CENTER_X + PREV_BUTTON_X + 20, WHEEL_CENTER_Y + 8);

        // Next (right) - two right arrows (>>)
        _ = c.SDL_RenderDrawLine(renderer, WHEEL_CENTER_X + NEXT_BUTTON_X - 10, WHEEL_CENTER_Y - 8, WHEEL_CENTER_X + NEXT_BUTTON_X, WHEEL_CENTER_Y);
        _ = c.SDL_RenderDrawLine(renderer, WHEEL_CENTER_X + NEXT_BUTTON_X, WHEEL_CENTER_Y, WHEEL_CENTER_X + NEXT_BUTTON_X - 10, WHEEL_CENTER_Y + 8);
        _ = c.SDL_RenderDrawLine(renderer, WHEEL_CENTER_X + NEXT_BUTTON_X - 20, WHEEL_CENTER_Y - 8, WHEEL_CENTER_X + NEXT_BUTTON_X - 10, WHEEL_CENTER_Y);
        _ = c.SDL_RenderDrawLine(renderer, WHEEL_CENTER_X + NEXT_BUTTON_X - 10, WHEEL_CENTER_Y, WHEEL_CENTER_X + NEXT_BUTTON_X - 20, WHEEL_CENTER_Y + 8);

        // Play/Pause (bottom) - play triangle and pause bars
        // Play triangle
        _ = c.SDL_RenderDrawLine(renderer, WHEEL_CENTER_X - 12, WHEEL_CENTER_Y + PLAY_BUTTON_Y - 8, WHEEL_CENTER_X - 12, WHEEL_CENTER_Y + PLAY_BUTTON_Y + 8);
        _ = c.SDL_RenderDrawLine(renderer, WHEEL_CENTER_X - 12, WHEEL_CENTER_Y + PLAY_BUTTON_Y - 8, WHEEL_CENTER_X - 2, WHEEL_CENTER_Y + PLAY_BUTTON_Y);
        _ = c.SDL_RenderDrawLine(renderer, WHEEL_CENTER_X - 2, WHEEL_CENTER_Y + PLAY_BUTTON_Y, WHEEL_CENTER_X - 12, WHEEL_CENTER_Y + PLAY_BUTTON_Y + 8);
        // Pause bars
        rect = c.SDL_Rect{ .x = WHEEL_CENTER_X + 4, .y = WHEEL_CENTER_Y + PLAY_BUTTON_Y - 8, .w = 4, .h = 16 };
        _ = c.SDL_RenderFillRect(renderer, &rect);
        rect = c.SDL_Rect{ .x = WHEEL_CENTER_X + 12, .y = WHEEL_CENTER_Y + PLAY_BUTTON_Y - 8, .w = 4, .h = 16 };
        _ = c.SDL_RenderFillRect(renderer, &rect);
    }

    fn drawFilledCircle(self: *Self, cx: c_int, cy: c_int, radius: c_int, color: [3]u8) void {
        const renderer = self.renderer orelse return;
        _ = c.SDL_SetRenderDrawColor(renderer, color[0], color[1], color[2], 255);

        // Draw filled circle using horizontal lines
        var y: c_int = -radius;
        while (y <= radius) : (y += 1) {
            const width: c_int = @intFromFloat(@sqrt(@as(f32, @floatFromInt(radius * radius - y * y))));
            _ = c.SDL_RenderDrawLine(renderer, cx - width, cy + y, cx + width, cy + y);
        }
    }

    fn drawStatusBar(self: *Self) void {
        const renderer = self.renderer orelse return;

        // Status bar at bottom
        _ = c.SDL_SetRenderDrawColor(renderer, 30, 30, 35, 255);
        var bar_rect = c.SDL_Rect{
            .x = 0,
            .y = IPOD_HEIGHT - 25,
            .w = IPOD_WIDTH,
            .h = 25,
        };
        _ = c.SDL_RenderFillRect(renderer, &bar_rect);

        // Draw key hints
        _ = c.SDL_SetRenderDrawColor(renderer, 150, 150, 155, 255);
        // Would draw text here, but SDL2 text requires SDL_ttf
        // For now, the controls are intuitive (arrows, space, enter, m, esc)
    }

    fn distance(x1: c_int, y1: c_int, x2: c_int, y2: c_int) f32 {
        const dx: f32 = @floatFromInt(x1 - x2);
        const dy: f32 = @floatFromInt(y1 - y2);
        return @sqrt(dx * dx + dy * dy);
    }

    const vtable = GuiVTable{
        .init = initImpl,
        .deinit = deinitImpl,
        .updateLcd = updateLcdImpl,
        .pollEvent = pollEventImpl,
        .setButtonState = setButtonStateImpl,
        .setWheelPosition = setWheelPositionImpl,
        .isOpen = isOpenImpl,
        .present = presentImpl,
    };
};

/// Check if SDL2 is available at runtime
pub fn isSdl2Available() bool {
    return true;
}
