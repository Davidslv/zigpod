//! SDL2 GUI Backend for ZigPod Simulator
//!
//! Provides SDL2-based display and input handling.
//! This module is optional and requires SDL2 to be installed.

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

/// SDL2 Backend implementation
pub const Sdl2Backend = struct {
    window: ?*c.SDL_Window = null,
    renderer: ?*c.SDL_Renderer = null,
    texture: ?*c.SDL_Texture = null,
    config: LcdConfig = .{},
    open: bool = false,
    button_states: [6]bool = [_]bool{false} ** 6,
    wheel_pos: u8 = 0,
    // Pixel buffer for upscaling
    pixel_buffer: []u32 = &[_]u32{},
    allocator: std.mem.Allocator,

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

        const window_width = config.width * config.scale;
        const window_height = config.height * config.scale;

        // Create window
        self.window = c.SDL_CreateWindow(
            config.title.ptr,
            c.SDL_WINDOWPOS_CENTERED,
            c.SDL_WINDOWPOS_CENTERED,
            @intCast(window_width),
            @intCast(window_height),
            c.SDL_WINDOW_SHOWN,
        );
        if (self.window == null) {
            return error.WindowCreationFailed;
        }
        errdefer c.SDL_DestroyWindow(self.window);

        // Create renderer
        self.renderer = c.SDL_CreateRenderer(
            self.window,
            -1,
            c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC,
        );
        if (self.renderer == null) {
            return error.RendererCreationFailed;
        }
        errdefer c.SDL_DestroyRenderer(self.renderer);

        // Create texture for LCD display
        self.texture = c.SDL_CreateTexture(
            self.renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_STREAMING,
            @intCast(config.width),
            @intCast(config.height),
        );
        if (self.texture == null) {
            return error.TextureCreationFailed;
        }

        // Allocate pixel buffer
        const buffer_size = config.width * config.height;
        self.pixel_buffer = try self.allocator.alloc(u32, buffer_size);

        self.open = true;
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (self.pixel_buffer.len > 0) {
            self.allocator.free(self.pixel_buffer);
            self.pixel_buffer = &[_]u32{};
        }

        if (self.texture) |tex| {
            c.SDL_DestroyTexture(tex);
            self.texture = null;
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
        if (self.texture == null) return;

        const pixels_to_convert = @min(framebuffer.len, self.pixel_buffer.len);

        // Convert RGB565 to ARGB8888
        for (0..pixels_to_convert) |i| {
            const rgb565 = framebuffer[i];
            const rgb = Color.rgb565ToRgb888(rgb565);
            self.pixel_buffer[i] = 0xFF000000 | // Alpha
                (@as(u32, rgb.r) << 16) |
                (@as(u32, rgb.g) << 8) |
                @as(u32, rgb.b);
        }

        // Update texture
        _ = c.SDL_UpdateTexture(
            self.texture,
            null,
            @ptrCast(self.pixel_buffer.ptr),
            @intCast(self.config.width * @sizeOf(u32)),
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
        _ = self;
        switch (sdl_event.type) {
            c.SDL_QUIT => {
                return .{ .event_type = .quit };
            },
            c.SDL_KEYDOWN => {
                const button = mapKeyToButton(sdl_event.key.keysym.sym);
                if (button) |btn| {
                    return .{ .event_type = .button_press, .button = btn };
                }
                return .{ .event_type = .key_down, .keycode = @intCast(sdl_event.key.keysym.sym) };
            },
            c.SDL_KEYUP => {
                const button = mapKeyToButton(sdl_event.key.keysym.sym);
                if (button) |btn| {
                    return .{ .event_type = .button_release, .button = btn };
                }
                return .{ .event_type = .key_up, .keycode = @intCast(sdl_event.key.keysym.sym) };
            },
            c.SDL_MOUSEWHEEL => {
                // Map mouse wheel to click wheel
                const delta: i8 = if (sdl_event.wheel.y > 0) 1 else if (sdl_event.wheel.y < 0) -1 else 0;
                if (delta != 0) {
                    return .{ .event_type = .wheel_turn, .wheel_delta = delta * 8 };
                }
            },
            else => {},
        }
        return null;
    }

    fn mapKeyToButton(keycode: c_int) ?Button {
        return switch (keycode) {
            c.SDLK_m, c.SDLK_ESCAPE => .menu,
            c.SDLK_SPACE, c.SDLK_p => .play_pause,
            c.SDLK_RIGHT, c.SDLK_n => .next,
            c.SDLK_LEFT, c.SDLK_b => .prev,
            c.SDLK_RETURN, c.SDLK_s => .select,
            c.SDLK_h => .hold,
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
        if (self.renderer == null or self.texture == null) return;

        // Clear and render
        _ = c.SDL_RenderClear(self.renderer);
        _ = c.SDL_RenderCopy(self.renderer, self.texture, null, null);

        // Draw click wheel overlay (simple circle)
        drawClickWheelOverlay(self);

        c.SDL_RenderPresent(self.renderer);
    }

    fn drawClickWheelOverlay(self: *Self) void {
        // Simple click wheel visualization in the corner
        if (self.renderer == null) return;

        const base_x: c_int = @intCast(self.config.width * self.config.scale - 80);
        const base_y: c_int = @intCast(self.config.height * self.config.scale - 80);

        // Draw outer ring
        _ = c.SDL_SetRenderDrawColor(self.renderer, 100, 100, 100, 200);

        // Draw wheel position indicator
        const angle = @as(f32, @floatFromInt(self.wheel_pos)) * std.math.pi * 2.0 / 256.0;
        const indicator_x = base_x + 30 + @as(c_int, @intFromFloat(@cos(angle) * 25.0));
        const indicator_y = base_y + 30 + @as(c_int, @intFromFloat(@sin(angle) * 25.0));

        _ = c.SDL_SetRenderDrawColor(self.renderer, 255, 255, 255, 255);
        var rect = c.SDL_Rect{
            .x = indicator_x - 3,
            .y = indicator_y - 3,
            .w = 6,
            .h = 6,
        };
        _ = c.SDL_RenderFillRect(self.renderer, &rect);

        // Draw button states
        const button_colors = [_][3]u8{
            .{ 255, 0, 0 }, // menu - red
            .{ 0, 255, 0 }, // play - green
            .{ 0, 0, 255 }, // next - blue
            .{ 255, 255, 0 }, // prev - yellow
            .{ 255, 0, 255 }, // select - magenta
            .{ 128, 128, 128 }, // hold - gray
        };

        for (0..6) |i| {
            if (self.button_states[i]) {
                _ = c.SDL_SetRenderDrawColor(
                    self.renderer,
                    button_colors[i][0],
                    button_colors[i][1],
                    button_colors[i][2],
                    255,
                );
                rect = c.SDL_Rect{
                    .x = base_x + @as(c_int, @intCast(i * 10)),
                    .y = base_y + 70,
                    .w = 8,
                    .h = 8,
                };
                _ = c.SDL_RenderFillRect(self.renderer, &rect);
            }
        }
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
    // This would check for SDL2 at runtime, but for now
    // we just return true since this module is conditionally compiled
    return true;
}

// No tests for SDL2 backend as it requires SDL2 to be installed
// Testing is done via the null backend in gui.zig
