//! HAL Stack Test Firmware
//!
//! Minimal firmware to test that the HAL layer works on real hardware.
//! Tests: LCD display, text rendering, clickwheel input.

const builtin = @import("builtin");
const zigpod = @import("zigpod");
const hal = zigpod.hal;
const lcd = zigpod.lcd;
const clickwheel = zigpod.clickwheel;

// ============================================================
// Entry Point (ARM only)
// ============================================================

comptime {
    if (builtin.cpu.arch == .arm and builtin.os.tag == .freestanding) {
        @export(&_start, .{ .name = "_start" });
    }
}

fn _start() callconv(.naked) noreturn {
    // Disable IRQ/FIQ (ARM7TDMI compatible)
    asm volatile ("msr cpsr_c, #0xdf");

    // Set up stack in SDRAM
    asm volatile ("ldr sp, =0x40008000");

    // Jump to Zig code
    asm volatile ("bl _hal_test_main");

    // Infinite loop (should never reach)
    asm volatile ("1: b 1b");
}

// ============================================================
// Test State
// ============================================================

var test_phase: u8 = 0;
var button_count: u32 = 0;
var last_button: u8 = 0;

// ============================================================
// Main Test Function
// ============================================================

export fn _hal_test_main() void {
    // Phase 1: Initialize HAL
    test_phase = 1;
    hal.init();

    // Phase 2: Initialize LCD through HAL
    test_phase = 2;
    lcd.init() catch {
        // If LCD init fails, we can't show anything - just halt
        showErrorPattern(0xF800); // Red
        hang();
    };

    // Phase 3: Set backlight
    test_phase = 3;
    lcd.setBacklight(true);

    // Phase 4: Clear screen and draw test
    test_phase = 4;
    lcd.clear(lcd.Colors.BLACK);

    // Draw header
    lcd.drawString(10, 10, "ZigPod HAL Test", lcd.Colors.WHITE, null);
    lcd.drawString(10, 30, "================", lcd.Colors.GRAY, null);

    // Draw test info
    lcd.drawString(10, 50, "Phase: LCD OK", lcd.Colors.GREEN, null);
    lcd.drawString(10, 70, "Press buttons to test", lcd.Colors.WHITE, null);

    // Draw button labels
    lcd.drawString(10, 100, "MENU:", lcd.Colors.WHITE, null);
    lcd.drawString(10, 120, "PLAY:", lcd.Colors.WHITE, null);
    lcd.drawString(10, 140, "LEFT:", lcd.Colors.WHITE, null);
    lcd.drawString(10, 160, "RIGHT:", lcd.Colors.WHITE, null);
    lcd.drawString(10, 180, "SELECT:", lcd.Colors.WHITE, null);

    // Update display
    lcd.update() catch {
        showErrorPattern(0xF81F); // Magenta - update failed
        hang();
    };

    // Phase 5: Initialize clickwheel
    test_phase = 5;
    clickwheel.init() catch {
        lcd.drawString(10, 200, "Wheel init FAILED", lcd.Colors.RED, null);
        lcd.update() catch {};
        hang();
    };

    lcd.drawString(10, 200, "Wheel: OK - Testing...", lcd.Colors.GREEN, null);
    lcd.update() catch {};

    // Phase 6: Main loop - test button input
    test_phase = 6;
    mainLoop();
}

fn mainLoop() void {
    while (true) {
        // Poll clickwheel
        if (clickwheel.poll()) |event| {
            // Update button display
            updateButtonDisplay(event);
            button_count += 1;
        } else |_| {
            // Poll error - ignore
        }

        // Small delay
        hal.delayMs(16); // ~60fps
    }
}

fn updateButtonDisplay(event: clickwheel.InputEvent) void {
    // Clear button status area
    lcd.fillRect(80, 100, 100, 100, lcd.Colors.BLACK);

    // Show which buttons are pressed using Button constants
    if (event.buttonPressed(clickwheel.Button.MENU)) {
        lcd.drawString(80, 100, "PRESSED", lcd.Colors.RED, null);
        last_button = 1;
    }
    if (event.buttonPressed(clickwheel.Button.PLAY)) {
        lcd.drawString(80, 120, "PRESSED", lcd.Colors.GREEN, null);
        last_button = 2;
    }
    if (event.buttonPressed(clickwheel.Button.LEFT)) {
        lcd.drawString(80, 140, "PRESSED", lcd.Colors.BLUE, null);
        last_button = 3;
    }
    if (event.buttonPressed(clickwheel.Button.RIGHT)) {
        lcd.drawString(80, 160, "PRESSED", lcd.Colors.YELLOW, null);
        last_button = 4;
    }
    if (event.buttonPressed(clickwheel.Button.SELECT)) {
        lcd.drawString(80, 180, "PRESSED", lcd.Colors.WHITE, null);
        last_button = 5;
    }

    // Show button count
    lcd.fillRect(10, 220, 200, 20, lcd.Colors.BLACK);
    lcd.drawString(10, 220, "Count:", lcd.Colors.WHITE, null);

    // Simple number display (just show last digit for now)
    var count_str: [16]u8 = undefined;
    const digit = @as(u8, @intCast(button_count % 10)) + '0';
    count_str[0] = digit;
    lcd.drawChar(70, 220, digit, lcd.Colors.CYAN, null);

    // Update display
    lcd.update() catch {};
}

fn showErrorPattern(color: u16) void {
    // Direct BCM write for error display (bypasses HAL)
    const BCM_DATA32: *volatile u32 = @ptrFromInt(0x30000000);
    const BCM_WR_ADDR32: *volatile u32 = @ptrFromInt(0x30010000);
    const BCM_CONTROL: *volatile u16 = @ptrFromInt(0x30030000);

    // Set write address
    BCM_WR_ADDR32.* = 0xE0000;
    while ((BCM_CONTROL.* & 0x2) == 0) {}

    // Fill with color
    const color32: u32 = @as(u32, color) | (@as(u32, color) << 16);
    var i: u32 = 0;
    while (i < 320 * 240 / 2) : (i += 1) {
        BCM_DATA32.* = color32;
    }

    // Trigger update
    BCM_WR_ADDR32.* = 0x1F8;
    while ((BCM_CONTROL.* & 0x2) == 0) {}
    BCM_DATA32.* = 0xFFFF0000;
    BCM_CONTROL.* = 0x31;
}

fn hang() noreturn {
    while (true) {
        asm volatile ("nop");
    }
}
