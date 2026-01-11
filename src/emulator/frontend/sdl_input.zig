//! SDL2 Input Frontend
//!
//! Maps keyboard and mouse input to iPod click wheel controls.
//!
//! Keyboard mapping:
//! - Enter/Return: Select (center button)
//! - Escape/M: Menu
//! - Space/P: Play/Pause
//! - Right Arrow/N: Next track
//! - Left Arrow/B: Previous track
//! - Up Arrow: Scroll up (wheel clockwise)
//! - Down Arrow: Scroll down (wheel counter-clockwise)
//! - H: Toggle hold switch
//!
//! Mouse:
//! - Click in center region: Select
//! - Click in cardinal regions: Menu/Play/Next/Prev
//! - Scroll wheel: Wheel rotation

const std = @import("std");
const clickwheel = @import("../peripherals/clickwheel.zig");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

/// Input event types
pub const InputEvent = union(enum) {
    button_press: clickwheel.Button,
    button_release: clickwheel.Button,
    wheel_rotate: i8, // Positive = clockwise, negative = counter-clockwise
    quit: void,
    none: void,
};

/// SDL Input Handler
pub const SdlInput = struct {
    /// Reference to click wheel controller
    wheel: *clickwheel.ClickWheel,

    /// Keys currently held
    keys_held: std.AutoHashMap(c_int, void),

    /// Allocator for hash map
    allocator: std.mem.Allocator,

    /// Wheel scroll accumulator (for smooth scrolling)
    scroll_accumulator: f32,

    const Self = @This();

    /// Wheel rotation per scroll step
    const SCROLL_SENSITIVITY: f32 = 4.0;

    /// Wheel rotation per key press (for arrow keys)
    const KEY_WHEEL_DELTA: i8 = 4;

    pub fn init(allocator: std.mem.Allocator, wheel: *clickwheel.ClickWheel) Self {
        return .{
            .wheel = wheel,
            .keys_held = std.AutoHashMap(c_int, void).init(allocator),
            .allocator = allocator,
            .scroll_accumulator = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.keys_held.deinit();
    }

    /// Process SDL events and update click wheel state
    /// Returns true if should quit
    pub fn processEvents(self: *Self) bool {
        var event: c.SDL_Event = undefined;

        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => return true,

                c.SDL_KEYDOWN => {
                    if (event.key.repeat == 0) {
                        self.handleKeyDown(event.key.keysym.sym);
                    }
                },

                c.SDL_KEYUP => {
                    self.handleKeyUp(event.key.keysym.sym);
                },

                c.SDL_MOUSEWHEEL => {
                    self.handleMouseWheel(event.wheel.y);
                },

                c.SDL_MOUSEBUTTONDOWN => {
                    self.handleMouseButton(event.button.x, event.button.y, true);
                },

                c.SDL_MOUSEBUTTONUP => {
                    self.handleMouseButton(event.button.x, event.button.y, false);
                },

                else => {},
            }
        }

        return false;
    }

    /// Handle key press
    fn handleKeyDown(self: *Self, key: c_int) void {
        // Avoid duplicate key handling
        if (self.keys_held.contains(key)) return;
        self.keys_held.put(key, {}) catch return;

        switch (key) {
            // Select button
            c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                self.wheel.pressButton(.select);
            },

            // Menu button
            c.SDLK_ESCAPE, c.SDLK_m => {
                self.wheel.pressButton(.menu);
            },

            // Play/Pause button
            c.SDLK_SPACE, c.SDLK_p => {
                self.wheel.pressButton(.play);
            },

            // Next track
            c.SDLK_RIGHT, c.SDLK_n => {
                self.wheel.pressButton(.next);
            },

            // Previous track
            c.SDLK_LEFT, c.SDLK_b => {
                self.wheel.pressButton(.prev);
            },

            // Wheel scroll up (clockwise)
            c.SDLK_UP => {
                self.wheel.rotateWheel(KEY_WHEEL_DELTA);
            },

            // Wheel scroll down (counter-clockwise)
            c.SDLK_DOWN => {
                self.wheel.rotateWheel(-KEY_WHEEL_DELTA);
            },

            // Hold switch toggle
            c.SDLK_h => {
                // Toggle hold
                if (self.wheel.buttons & clickwheel.Button.hold.mask() != 0) {
                    self.wheel.releaseButton(.hold);
                } else {
                    self.wheel.pressButton(.hold);
                }
            },

            else => {},
        }
    }

    /// Handle key release
    fn handleKeyUp(self: *Self, key: c_int) void {
        _ = self.keys_held.remove(key);

        switch (key) {
            c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                self.wheel.releaseButton(.select);
            },

            c.SDLK_ESCAPE, c.SDLK_m => {
                self.wheel.releaseButton(.menu);
            },

            c.SDLK_SPACE, c.SDLK_p => {
                self.wheel.releaseButton(.play);
            },

            c.SDLK_RIGHT, c.SDLK_n => {
                self.wheel.releaseButton(.next);
            },

            c.SDLK_LEFT, c.SDLK_b => {
                self.wheel.releaseButton(.prev);
            },

            // Hold doesn't release on key up (it's a toggle)

            else => {},
        }
    }

    /// Handle mouse wheel scroll
    fn handleMouseWheel(self: *Self, y: c_int) void {
        // Accumulate scroll
        self.scroll_accumulator += @as(f32, @floatFromInt(y)) * SCROLL_SENSITIVITY;

        // Convert to discrete wheel rotation
        const delta: i8 = @intFromFloat(self.scroll_accumulator);
        if (delta != 0) {
            self.wheel.rotateWheel(delta);
            self.scroll_accumulator -= @as(f32, @floatFromInt(delta));
        }
    }

    /// Handle mouse button click
    /// Maps click position to iPod button based on screen region
    fn handleMouseButton(self: *Self, x: c_int, y: c_int, pressed: bool) void {
        // Get window size for region calculation
        // Assuming 2x scale (640x480 window)
        const window_width: f32 = 640;
        const window_height: f32 = 480;

        // Normalize coordinates to -1..1
        const nx = (@as(f32, @floatFromInt(x)) / window_width) * 2.0 - 1.0;
        const ny = (@as(f32, @floatFromInt(y)) / window_height) * 2.0 - 1.0;

        // Determine which button based on position
        // iPod layout:
        //        MENU (top)
        //   PREV   SELECT   NEXT
        //        PLAY (bottom)

        const radius = @sqrt(nx * nx + ny * ny);

        if (radius < 0.3) {
            // Center: Select
            if (pressed) {
                self.wheel.pressButton(.select);
            } else {
                self.wheel.releaseButton(.select);
            }
        } else if (radius < 0.9) {
            // Determine quadrant
            const angle = std.math.atan2(ny, nx);
            const PI: f32 = std.math.pi;
            const PI_4: f32 = PI / 4.0;
            const PI_3_4: f32 = 3.0 * PI / 4.0;

            if (angle > -PI_4 and angle < PI_4) {
                // Right: Next
                if (pressed) {
                    self.wheel.pressButton(.next);
                } else {
                    self.wheel.releaseButton(.next);
                }
            } else if (angle >= PI_4 and angle < PI_3_4) {
                // Bottom: Play
                if (pressed) {
                    self.wheel.pressButton(.play);
                } else {
                    self.wheel.releaseButton(.play);
                }
            } else if (angle >= PI_3_4 or angle < -PI_3_4) {
                // Left: Prev
                if (pressed) {
                    self.wheel.pressButton(.prev);
                } else {
                    self.wheel.releaseButton(.prev);
                }
            } else {
                // Top: Menu
                if (pressed) {
                    self.wheel.pressButton(.menu);
                } else {
                    self.wheel.releaseButton(.menu);
                }
            }
        }
        // Outside click wheel area - ignore
    }

    /// Get key state for debugging
    pub fn isKeyHeld(self: *const Self, key: c_int) bool {
        return self.keys_held.contains(key);
    }
};
