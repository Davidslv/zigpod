//! ZigPod OS Main Entry Point
//!
//! This is the main entry point for ZigPod OS after low-level boot initialization.
//! It initializes all subsystems and enters the main application loop.

const std = @import("std");
const builtin = @import("builtin");
const kernel = @import("kernel/kernel.zig");
const hal = @import("hal/hal.zig");

// Ensure boot code is included for ARM freestanding target
comptime {
    if (builtin.cpu.arch == .arm and builtin.os.tag == .freestanding) {
        _ = kernel.boot;
    }
}
const audio = @import("audio/audio.zig");
const ui = @import("ui/ui.zig");
const lcd = @import("drivers/display/lcd.zig");
const clickwheel = @import("drivers/input/clickwheel.zig");
const storage = @import("drivers/storage/ata.zig");
const power = @import("drivers/power.zig");
const app = @import("app/app.zig");

// ============================================================
// System State
// ============================================================

pub const SystemState = enum {
    booting,
    initializing,
    running,
    shutting_down,
    error_state,
};

var system_state: SystemState = .booting;

// ============================================================
// Main Entry Point
// ============================================================

/// Main entry point called from boot.zig after low-level initialization
pub fn main() void {
    system_state = .initializing;

    // Initialize kernel subsystems
    initKernel() catch |err| {
        handleFatalError("Kernel init failed", err);
        return;
    };

    // Initialize hardware drivers
    initDrivers() catch |err| {
        handleFatalError("Driver init failed", err);
        return;
    };

    // Initialize audio subsystem
    audio.init() catch |err| {
        handleFatalError("Audio init failed", err);
        return;
    };

    // Initialize UI
    ui.init() catch |err| {
        handleFatalError("UI init failed", err);
        return;
    };

    // Initialize power management
    power.init() catch |err| {
        handleFatalError("Power init failed", err);
        return;
    };

    // Initialize application controller
    app.init();

    // Show boot screen
    showBootScreen();

    // Check battery level before continuing
    const battery = power.getBatteryInfo();
    if (battery.is_critical) {
        showLowBatteryWarning();
        shutdown();
        return;
    }

    // Enter main loop
    system_state = .running;
    mainLoop();

    // Shutdown
    system_state = .shutting_down;
    shutdown();
}

// ============================================================
// Initialization
// ============================================================

fn initKernel() !void {
    // Initialize memory allocator
    kernel.memory.init();

    // Initialize interrupt system (global interrupts disabled initially)
    kernel.interrupts.disableGlobal();

    // Timer uses HAL directly, no init needed

    // Enable global interrupts
    kernel.interrupts.enableGlobal();
}

fn initDrivers() !void {
    // Initialize LCD
    try lcd.init();
    lcd.setBacklight(true);
    lcd.clear(lcd.Colors.BLACK);

    // Initialize click wheel
    try clickwheel.init();

    // Initialize storage (optional - may not have disk)
    storage.init() catch {
        // Storage init failure is not fatal - we can run without disk
    };
}

fn showBootScreen() void {
    const theme = ui.getTheme();
    lcd.clear(theme.background);

    // Draw ZigPod logo (centered text)
    lcd.drawStringCentered(80, "ZigPod OS", theme.foreground, null);
    lcd.drawStringCentered(100, "v0.1.0 \"Genesis\"", theme.disabled, null);

    // Draw loading bar
    lcd.drawProgressBar(60, 140, 200, 12, 0, theme.accent, theme.disabled);
    // Boot display errors are non-fatal - continue boot sequence
    lcd.update() catch {};

    // Simulate loading with progress
    var progress: u8 = 0;
    while (progress < 100) : (progress += 5) {
        lcd.drawProgressBar(60, 140, 200, 12, progress, theme.accent, theme.disabled);
        lcd.update() catch {}; // Continue boot even if display fails
        kernel.timer.delayMs(30);
    }

    // Brief pause on complete
    kernel.timer.delayMs(200);
}

fn showLowBatteryWarning() void {
    lcd.clear(lcd.Colors.RED);
    lcd.drawStringCentered(100, "LOW BATTERY", lcd.Colors.WHITE, lcd.Colors.RED);
    lcd.drawStringCentered(120, "Please charge", lcd.Colors.WHITE, lcd.Colors.RED);
    lcd.update() catch {}; // Display warning even if update fails
    kernel.timer.delayMs(3000);
}

// ============================================================
// Frame Rate Limiting
// ============================================================

/// Frame rate limiter with idle detection for power efficiency
const FrameLimiter = struct {
    const TARGET_FPS: u32 = 60;
    const FRAME_TIME_US: u64 = 1_000_000 / TARGET_FPS; // ~16,667us per frame
    const IDLE_FRAME_TIME_US: u64 = 50_000; // 50ms when idle (20fps)
    const IDLE_THRESHOLD_FRAMES: u8 = 30; // Frames without activity before entering idle

    frame_start_us: u64 = 0,
    idle_frame_count: u8 = 0,
    is_idle: bool = false,
    last_needs_redraw: bool = true,

    /// Start frame timing
    pub fn startFrame(self: *FrameLimiter) void {
        self.frame_start_us = kernel.timer.getTimeUs();
    }

    /// End frame and sleep for remaining time
    /// Returns true if frame was processed in time
    pub fn endFrame(self: *FrameLimiter, had_input: bool, needs_redraw: bool, is_playing: bool) bool {
        // Update idle state
        const has_activity = had_input or needs_redraw or is_playing or self.last_needs_redraw;
        self.last_needs_redraw = needs_redraw;

        if (has_activity) {
            self.idle_frame_count = 0;
            if (self.is_idle) {
                self.is_idle = false;
                // Wake from idle - could notify power management
            }
        } else {
            if (self.idle_frame_count < IDLE_THRESHOLD_FRAMES) {
                self.idle_frame_count += 1;
            } else if (!self.is_idle) {
                self.is_idle = true;
                // Enter idle - could notify power management
            }
        }

        // Calculate elapsed time
        const elapsed_us = kernel.timer.elapsedUs(self.frame_start_us);

        // Determine target frame time based on idle state
        const target_us = if (self.is_idle) IDLE_FRAME_TIME_US else FRAME_TIME_US;

        // Sleep for remaining time
        if (elapsed_us < target_us) {
            const sleep_us = target_us - elapsed_us;
            // Use delayUs for sub-millisecond precision, delayMs for longer sleeps
            if (sleep_us >= 1000) {
                kernel.timer.delayMs(@intCast(sleep_us / 1000));
                // Sleep remaining sub-millisecond portion
                const remaining_us = sleep_us % 1000;
                if (remaining_us > 100) {
                    kernel.timer.delayUs(@intCast(remaining_us));
                }
            } else if (sleep_us > 100) {
                kernel.timer.delayUs(@intCast(sleep_us));
            }
            return true; // Frame completed in time
        }

        return false; // Frame took longer than target
    }

    /// Check if currently in idle state
    pub fn isIdle(self: *const FrameLimiter) bool {
        return self.is_idle;
    }
};

var frame_limiter = FrameLimiter{};

// ============================================================
// Main Loop
// ============================================================

fn mainLoop() void {
    while (system_state == .running) {
        // Start frame timing
        frame_limiter.startFrame();

        // Update application
        app.update();

        // Check for shutdown request
        if (shouldShutdown()) {
            break;
        }

        // Get state for frame limiter
        const app_state = app.getState();
        const had_input = false; // Input is handled in app.update(), could track this
        const needs_redraw = app_state.needs_redraw;
        const is_playing = audio.isPlaying();

        // End frame with proper sleep timing
        _ = frame_limiter.endFrame(had_input, needs_redraw, is_playing);
    }
}

fn shouldShutdown() bool {
    // Check for hold switch + menu for shutdown
    // Or critical battery
    const battery = power.getBatteryInfo();
    return battery.is_critical;
}

// ============================================================
// Shutdown
// ============================================================

fn shutdown() void {
    // Stop audio
    audio.shutdown();

    // Save settings
    // TODO: Persist settings to storage

    // Turn off backlight
    lcd.setBacklight(false);

    // Clear screen
    lcd.clear(lcd.Colors.BLACK);
    lcd.update() catch {}; // Best effort - shutting down anyway

    // Disable interrupts
    kernel.interrupts.disableGlobal();

    // Power off - this is the final operation, no recovery possible
    power.setState(.off) catch {
        // If power off fails, halt the CPU
        while (true) {
            asm volatile ("wfi");
        }
    };
}

// ============================================================
// Error Handling
// ============================================================

fn handleFatalError(message: []const u8, err: anyerror) void {
    system_state = .error_state;

    // Try to display error on screen
    lcd.init() catch return;
    lcd.setBacklight(true);
    lcd.clear(lcd.Colors.RED);

    lcd.drawString(10, 10, "FATAL ERROR", lcd.Colors.WHITE, lcd.Colors.RED);
    lcd.drawString(10, 30, message, lcd.Colors.WHITE, lcd.Colors.RED);

    // Format error name
    const error_name = @errorName(err);
    lcd.drawString(10, 50, error_name, lcd.Colors.YELLOW, lcd.Colors.RED);

    lcd.drawString(10, 80, "Press any button to reboot", lcd.Colors.WHITE, lcd.Colors.RED);

    lcd.update() catch {}; // Best effort for error display

    // Wait for button press
    while (true) {
        if (clickwheel.poll()) |event| {
            if (event.anyButtonPressed()) {
                // Reboot (would require watchdog or reset vector)
                break;
            }
        } else |_| {}

        hal.current_hal.sleep();
    }
}

// ============================================================
// Public API
// ============================================================

/// Get current system state
pub fn getSystemState() SystemState {
    return system_state;
}

/// Request system shutdown
pub fn requestShutdown() void {
    system_state = .shutting_down;
}

// ============================================================
// Tests
// ============================================================

test "system state transitions" {
    // Initial state should be booting
    try std.testing.expectEqual(SystemState.booting, system_state);
}

test "frame limiter idle detection" {
    var limiter = FrameLimiter{};
    // Clear initial last_needs_redraw state for clean test
    limiter.last_needs_redraw = false;

    // Initially not idle
    try std.testing.expect(!limiter.isIdle());

    // Simulate frames without activity
    var i: u8 = 0;
    while (i < FrameLimiter.IDLE_THRESHOLD_FRAMES + 5) : (i += 1) {
        limiter.frame_start_us = 0;
        _ = limiter.endFrame(false, false, false);
    }

    // Should now be idle
    try std.testing.expect(limiter.isIdle());

    // Activity should wake from idle
    limiter.frame_start_us = 0;
    _ = limiter.endFrame(true, false, false);
    try std.testing.expect(!limiter.isIdle());
    try std.testing.expectEqual(@as(u8, 0), limiter.idle_frame_count);
}

test "frame limiter activity resets idle count" {
    var limiter = FrameLimiter{};
    // Clear initial last_needs_redraw state
    limiter.last_needs_redraw = false;

    // Build up some idle frames
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        limiter.frame_start_us = 0;
        _ = limiter.endFrame(false, false, false);
    }
    try std.testing.expectEqual(@as(u8, 10), limiter.idle_frame_count);

    // Input resets
    limiter.frame_start_us = 0;
    _ = limiter.endFrame(true, false, false);
    try std.testing.expectEqual(@as(u8, 0), limiter.idle_frame_count);

    // Redraw resets
    i = 0;
    while (i < 5) : (i += 1) {
        limiter.frame_start_us = 0;
        _ = limiter.endFrame(false, false, false);
    }
    limiter.frame_start_us = 0;
    _ = limiter.endFrame(false, true, false);
    try std.testing.expectEqual(@as(u8, 0), limiter.idle_frame_count);

    // Playing audio resets
    i = 0;
    while (i < 5) : (i += 1) {
        limiter.frame_start_us = 0;
        _ = limiter.endFrame(false, false, false);
    }
    limiter.frame_start_us = 0;
    _ = limiter.endFrame(false, false, true);
    try std.testing.expectEqual(@as(u8, 0), limiter.idle_frame_count);
}
