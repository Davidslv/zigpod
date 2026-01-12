//! SDL2 Frontend Integration
//!
//! Main module that integrates SDL2 display, audio, and input handling
//! for the PP5021C emulator.

const std = @import("std");
const core = @import("../core.zig");
const lcd = @import("../peripherals/lcd.zig");
const i2s = @import("../peripherals/i2s.zig");
const clickwheel = @import("../peripherals/clickwheel.zig");

pub const SdlDisplay = @import("sdl_display.zig").SdlDisplay;
pub const SdlAudio = @import("sdl_audio.zig").SdlAudio;
pub const SdlInput = @import("sdl_input.zig").SdlInput;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

/// SDL Frontend
pub const SdlFrontend = struct {
    display: SdlDisplay,
    audio: SdlAudio,
    input: SdlInput,

    /// Emulator reference
    emulator: *core.Emulator,

    /// Frame timing
    last_frame_time: u64,
    frame_count: u64,

    /// Target FPS
    target_fps: u32,
    frame_time_ns: u64,

    /// Performance stats
    fps: f32,
    cpu_usage: f32,

    const Self = @This();

    /// Initialize SDL frontend
    pub fn init(allocator: std.mem.Allocator, emulator: *core.Emulator) !Self {
        // Initialize display
        var display = try SdlDisplay.init();
        errdefer display.deinit();

        // Initialize audio
        var audio = try SdlAudio.init();
        errdefer audio.deinit();

        // Initialize input
        const input = SdlInput.init(allocator, &emulator.wheel);

        // Set up callbacks
        emulator.lcd_ctrl.setDisplayCallback(
            @import("sdl_display.zig").createFramebufferCallback(&display),
        );
        emulator.i2s_ctrl.setAudioCallback(
            @import("sdl_audio.zig").createAudioCallback(&audio),
        );

        return Self{
            .display = display,
            .audio = audio,
            .input = input,
            .emulator = emulator,
            .last_frame_time = @intCast(c.SDL_GetPerformanceCounter()),
            .frame_count = 0,
            .target_fps = 60,
            .frame_time_ns = 1_000_000_000 / 60,
            .fps = 0,
            .cpu_usage = 0,
        };
    }

    /// Deinitialize SDL frontend
    pub fn deinit(self: *Self) void {
        self.input.deinit();
        self.audio.deinit();
        self.display.deinit();
    }

    /// Run one frame
    /// Returns false if should quit
    pub fn runFrame(self: *Self) bool {
        const frame_start = c.SDL_GetPerformanceCounter();

        // Process input
        if (self.input.processEvents()) {
            return false; // Quit requested
        }

        // Run emulator for one frame worth of cycles
        self.emulator.runFrame();

        // Update display (in case LCD didn't trigger callback)
        self.display.update(&self.emulator.lcd_ctrl.framebuffer);

        // Calculate timing
        const frame_end = c.SDL_GetPerformanceCounter();
        const freq: f64 = @floatFromInt(c.SDL_GetPerformanceFrequency());
        const frame_time: f64 = @as(f64, @floatFromInt(frame_end - frame_start)) / freq;

        // Frame rate limiting
        const target_frame_time: f64 = 1.0 / @as(f64, @floatFromInt(self.target_fps));
        if (frame_time < target_frame_time) {
            const delay_ms: u32 = @intFromFloat((target_frame_time - frame_time) * 1000.0);
            c.SDL_Delay(delay_ms);
        }

        // Update FPS counter
        self.frame_count += 1;
        if (self.frame_count % 60 == 0) {
            const now = c.SDL_GetPerformanceCounter();
            const elapsed: f64 = @as(f64, @floatFromInt(now - self.last_frame_time)) / freq;
            self.fps = @floatCast(60.0 / elapsed);
            self.cpu_usage = @floatCast(frame_time / target_frame_time * 100.0);
            self.last_frame_time = now;

            // Update window title with stats
            self.updateTitle();
        }

        return true;
    }

    /// Main run loop
    pub fn run(self: *Self) void {
        while (self.runFrame()) {}
    }

    /// Update window title with performance stats
    fn updateTitle(self: *Self) void {
        var title_buf: [128]u8 = undefined;
        const title = std.fmt.bufPrint(
            &title_buf,
            "ZigPod Emulator | {d:.1} FPS | PC: 0x{X:0>8}\x00",
            .{ self.fps, self.emulator.getPc() },
        ) catch return;

        self.display.setTitle(@ptrCast(title.ptr));
    }

    /// Set target FPS
    pub fn setTargetFps(self: *Self, fps: u32) void {
        self.target_fps = fps;
        self.frame_time_ns = 1_000_000_000 / fps;
    }

    /// Set audio volume (0-128)
    pub fn setVolume(self: *Self, volume: u8) void {
        self.audio.setVolume(volume);
    }

    /// Mute/unmute audio
    pub fn setMuted(self: *Self, muted: bool) void {
        self.audio.setMuted(muted);
    }
};

// Re-export display constants
pub const WINDOW_WIDTH = @import("sdl_display.zig").WINDOW_WIDTH;
pub const WINDOW_HEIGHT = @import("sdl_display.zig").WINDOW_HEIGHT;
pub const SCALE = @import("sdl_display.zig").SCALE;
