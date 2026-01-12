//! SDL2 Display Frontend
//!
//! Renders the emulated iPod LCD to an SDL2 window.
//! Supports window scaling for better visibility.

const std = @import("std");
const lcd = @import("../peripherals/lcd.zig");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

/// Display scale factor (2x = 640x480 window)
pub const SCALE: u32 = 2;

/// Window dimensions
pub const WINDOW_WIDTH: u32 = lcd.LCD_WIDTH * SCALE;
pub const WINDOW_HEIGHT: u32 = lcd.LCD_HEIGHT * SCALE;

/// SDL Display
pub const SdlDisplay = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,

    /// ARGB8888 pixel buffer for SDL texture
    pixel_buffer: [lcd.LCD_WIDTH * lcd.LCD_HEIGHT]u32,

    const Self = @This();

    /// Initialize SDL display
    pub fn init() !Self {
        // Initialize SDL video
        if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
            return error.SdlInitFailed;
        }
        errdefer c.SDL_Quit();

        // Create window
        const window = c.SDL_CreateWindow(
            "ZigPod Emulator - iPod 5th Gen",
            c.SDL_WINDOWPOS_CENTERED,
            c.SDL_WINDOWPOS_CENTERED,
            @intCast(WINDOW_WIDTH),
            @intCast(WINDOW_HEIGHT),
            c.SDL_WINDOW_SHOWN,
        ) orelse return error.WindowCreationFailed;
        errdefer c.SDL_DestroyWindow(window);

        // Create renderer
        const renderer = c.SDL_CreateRenderer(
            window,
            -1,
            c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC,
        ) orelse return error.RendererCreationFailed;
        errdefer c.SDL_DestroyRenderer(renderer);

        // Create texture for framebuffer
        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_STREAMING,
            @intCast(lcd.LCD_WIDTH),
            @intCast(lcd.LCD_HEIGHT),
        ) orelse return error.TextureCreationFailed;

        return Self{
            .window = window,
            .renderer = renderer,
            .texture = texture,
            .pixel_buffer = [_]u32{0xFF000000} ** (lcd.LCD_WIDTH * lcd.LCD_HEIGHT),
        };
    }

    /// Deinitialize SDL display
    pub fn deinit(self: *Self) void {
        c.SDL_DestroyTexture(self.texture);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    /// Update display from LCD framebuffer (RGB565)
    pub fn update(self: *Self, framebuffer: *const [lcd.FRAMEBUFFER_SIZE]u8) void {
        // Convert RGB565 to ARGB8888
        var i: usize = 0;
        var pixel_idx: usize = 0;
        while (i < lcd.FRAMEBUFFER_SIZE) : (i += 2) {
            const rgb565 = @as(u16, framebuffer[i]) | (@as(u16, framebuffer[i + 1]) << 8);
            const color: lcd.Color = @bitCast(rgb565);
            self.pixel_buffer[pixel_idx] = color.toU32();
            pixel_idx += 1;
        }

        // Update texture
        _ = c.SDL_UpdateTexture(
            self.texture,
            null,
            @ptrCast(&self.pixel_buffer),
            @intCast(lcd.LCD_WIDTH * @sizeOf(u32)),
        );

        // Render
        _ = c.SDL_RenderClear(self.renderer);
        _ = c.SDL_RenderCopy(self.renderer, self.texture, null, null);
        c.SDL_RenderPresent(self.renderer);
    }

    /// Set window title
    pub fn setTitle(self: *Self, title: [*:0]const u8) void {
        c.SDL_SetWindowTitle(self.window, title);
    }
};

/// Convert LCD framebuffer callback for use with emulator
pub fn createFramebufferCallback(display: *SdlDisplay) *const fn (*const [lcd.FRAMEBUFFER_SIZE]u8) void {
    const Wrapper = struct {
        var display_ptr: *SdlDisplay = undefined;

        fn callback(fb: *const [lcd.FRAMEBUFFER_SIZE]u8) void {
            display_ptr.update(fb);
        }
    };

    Wrapper.display_ptr = display;
    return &Wrapper.callback;
}
