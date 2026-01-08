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
    lcd.update() catch {};

    // Simulate loading with progress
    var progress: u8 = 0;
    while (progress < 100) : (progress += 5) {
        lcd.drawProgressBar(60, 140, 200, 12, progress, theme.accent, theme.disabled);
        lcd.update() catch {};
        kernel.timer.delayMs(30);
    }

    // Brief pause on complete
    kernel.timer.delayMs(200);
}

fn showLowBatteryWarning() void {
    lcd.clear(lcd.Colors.RED);
    lcd.drawStringCentered(100, "LOW BATTERY", lcd.Colors.WHITE, lcd.Colors.RED);
    lcd.drawStringCentered(120, "Please charge", lcd.Colors.WHITE, lcd.Colors.RED);
    lcd.update() catch {};
    kernel.timer.delayMs(3000);
}

// ============================================================
// Main Loop
// ============================================================

fn mainLoop() void {
    while (system_state == .running) {
        // Update application
        app.update();

        // Check for shutdown request
        if (shouldShutdown()) {
            break;
        }

        // Yield to other tasks
        kernel.timer.delayMs(16); // ~60 FPS
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
    lcd.update() catch {};

    // Disable interrupts
    kernel.interrupts.disableGlobal();

    // Power off
    power.setState(.off) catch {};
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

    lcd.update() catch {};

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
