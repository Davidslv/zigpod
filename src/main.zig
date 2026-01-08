//! ZigPod OS Main Entry Point
//!
//! This is the main entry point for ZigPod OS after low-level boot initialization.
//! It initializes all subsystems and enters the main application loop.

const std = @import("std");
const kernel = @import("kernel/kernel.zig");
const hal = @import("hal/hal.zig");
const audio = @import("audio/audio.zig");
const ui = @import("ui/ui.zig");
const lcd = @import("drivers/display/lcd.zig");
const clickwheel = @import("drivers/input/clickwheel.zig");
const storage = @import("drivers/storage/ata.zig");
const fat32 = @import("drivers/storage/fat32.zig");

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

    // Show boot screen
    showBootScreen();

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
    lcd.clear(lcd.Colors.BLACK);

    // Draw ZigPod logo (centered text)
    const title = "ZigPod OS";
    const subtitle = "v0.1.0";

    // Center the title
    const title_x = (lcd.WIDTH - @as(u16, @intCast(title.len * 8))) / 2;
    const subtitle_x = (lcd.WIDTH - @as(u16, @intCast(subtitle.len * 8))) / 2;

    lcd.drawString(title_x, 100, title, lcd.Colors.WHITE, lcd.Colors.BLACK);
    lcd.drawString(subtitle_x, 120, subtitle, lcd.Colors.GRAY, lcd.Colors.BLACK);

    lcd.update() catch {};

    // Brief delay for splash screen
    kernel.timer.delayMs(1000);
}

// ============================================================
// Main Loop
// ============================================================

fn mainLoop() void {
    const ui_state = ui.getState();

    while (true) {
        // Poll input
        const event = clickwheel.poll() catch {
            kernel.timer.delayMs(10);
            continue;
        };

        // Handle button presses
        if (event.anyButtonPressed()) {
            if (event.buttonPressed(clickwheel.Button.PLAY)) {
                audio.togglePause();
            }
            // Pass input to current menu if active
            if (ui_state.current_menu) |menu| {
                _ = ui.handleMenuInput(menu, event);
            }
        }

        // Process audio
        audio.process() catch {};

        // Draw UI (basic refresh)
        if (ui_state.current_menu) |menu| {
            ui.drawMenu(menu);
        }
        lcd.update() catch {};

        // Yield to other tasks
        kernel.timer.delayMs(10);
    }
}

// ============================================================
// Shutdown
// ============================================================

fn shutdown() void {
    // Stop audio
    audio.shutdown();

    // Turn off backlight
    lcd.setBacklight(false);

    // Clear screen
    lcd.clear(lcd.Colors.BLACK);
    lcd.update() catch {};

    // Disable interrupts
    kernel.interrupts.disableGlobal();
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

    lcd.update() catch {};

    // Halt
    while (true) {
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
