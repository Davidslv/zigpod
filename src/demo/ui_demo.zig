//! ZigPod UI Demo
//!
//! Native executable that demonstrates the ZigPod user interface
//! using SDL2 for display. This allows viewing and testing the UI
//! without actual hardware.
//!
//! Run: zig build demo -Dsdl2=true

const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

// Import ZigPod modules via the zigpod package
const zigpod = @import("zigpod");
const ui = zigpod.ui;
const lcd = zigpod.lcd;
const hal = zigpod.hal;

const WIDTH = 320;
const HEIGHT = 240;
const SCALE = 2;

pub fn main() !void {
    // Initialize SDL2
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    // Create window
    const window = c.SDL_CreateWindow(
        "ZigPod UI Demo",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        WIDTH * SCALE,
        HEIGHT * SCALE,
        c.SDL_WINDOW_SHOWN,
    ) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLWindowFailed;
    };
    defer c.SDL_DestroyWindow(window);

    // Create renderer
    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLRendererFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    // Create texture for framebuffer
    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_RGB565,
        c.SDL_TEXTUREACCESS_STREAMING,
        WIDTH,
        HEIGHT,
    ) orelse {
        std.debug.print("SDL_CreateTexture failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLTextureFailed;
    };
    defer c.SDL_DestroyTexture(texture);

    // Initialize HAL (uses mock on native)
    hal.init();

    // Initialize LCD driver
    lcd.init() catch |err| {
        std.debug.print("LCD init failed: {}\n", .{err});
    };

    // Initialize UI framework
    ui.init() catch |err| {
        std.debug.print("UI init failed: {}\n", .{err});
    };

    // App controller not needed for demo

    // Draw initial UI
    drawMainMenu();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════╗\n", .{});
    std.debug.print("║         ZigPod UI Demo               ║\n", .{});
    std.debug.print("╠══════════════════════════════════════╣\n", .{});
    std.debug.print("║  Arrow Up/Down  : Navigate           ║\n", .{});
    std.debug.print("║  Enter          : Select             ║\n", .{});
    std.debug.print("║  Escape/Backsp  : Back               ║\n", .{});
    std.debug.print("║  Q              : Quit               ║\n", .{});
    std.debug.print("╚══════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    var selected_index: usize = 0;
    const menu_items = [_][]const u8{
        "Music",
        "Playlists",
        "Artists",
        "Albums",
        "Songs",
        "Settings",
        "Now Playing",
        "About",
    };

    // Main loop
    var running = true;
    while (running) {
        // Handle events
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => {
                    running = false;
                },
                c.SDL_KEYDOWN => {
                    switch (event.key.keysym.sym) {
                        c.SDLK_q, c.SDLK_ESCAPE => {
                            if (event.key.keysym.sym == c.SDLK_q) {
                                running = false;
                            }
                        },
                        c.SDLK_UP => {
                            if (selected_index > 0) {
                                selected_index -= 1;
                            }
                        },
                        c.SDLK_DOWN => {
                            if (selected_index < menu_items.len - 1) {
                                selected_index += 1;
                            }
                        },
                        c.SDLK_RETURN => {
                            std.debug.print("Selected: {s}\n", .{menu_items[selected_index]});
                        },
                        else => {},
                    }
                    // Redraw UI
                    drawUI(menu_items[0..], selected_index);
                },
                else => {},
            }
        }

        // Get framebuffer from mock HAL
        const framebuffer = hal.mock.getFramebuffer();

        // Update texture with framebuffer
        _ = c.SDL_UpdateTexture(texture, null, framebuffer.ptr, WIDTH * 2);

        // Render
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderCopy(renderer, texture, null, null);
        c.SDL_RenderPresent(renderer);

        // Small delay
        c.SDL_Delay(16);
    }
}

fn drawMainMenu() void {
    const theme = ui.getTheme();

    // Clear screen with background
    lcd.clear(theme.background);

    // Draw header
    lcd.fillRect(0, 0, lcd.WIDTH, ui.HEADER_HEIGHT, theme.header_bg);
    lcd.drawStringCentered(4, "ZigPod", theme.header_fg, theme.header_bg);

    // Draw menu items
    const menu_items = [_][]const u8{
        "Music",
        "Playlists",
        "Artists",
        "Albums",
        "Songs",
        "Settings",
        "Now Playing",
        "About",
    };

    drawUI(menu_items[0..], 0);
}

fn drawUI(items: []const []const u8, selected: usize) void {
    const theme = ui.getTheme();

    // Clear content area
    lcd.fillRect(0, ui.HEADER_HEIGHT, lcd.WIDTH, ui.CONTENT_HEIGHT, theme.background);

    // Draw menu items
    var y: u16 = ui.CONTENT_START_Y + 2;
    for (items, 0..) |item, i| {
        const is_selected = i == selected;
        const bg = if (is_selected) theme.selected_bg else theme.background;
        const fg = if (is_selected) theme.selected_fg else theme.foreground;

        // Draw item background
        lcd.fillRect(0, y, lcd.WIDTH, ui.MENU_ITEM_HEIGHT, bg);

        // Draw item text
        lcd.drawString(10, y + 4, item, fg, bg);

        // Draw arrow for selected item
        if (is_selected) {
            lcd.drawString(lcd.WIDTH - 20, y + 4, ">", fg, bg);
        }

        y += ui.MENU_ITEM_HEIGHT;
    }

    // Draw footer
    lcd.fillRect(0, lcd.HEIGHT - ui.FOOTER_HEIGHT, lcd.WIDTH, ui.FOOTER_HEIGHT, theme.footer_bg);
    lcd.drawStringCentered(lcd.HEIGHT - ui.FOOTER_HEIGHT + 4, "Select to enter", theme.footer_fg, theme.footer_bg);

    // Update display
    lcd.update() catch {};
}
