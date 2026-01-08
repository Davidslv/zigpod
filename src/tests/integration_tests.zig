//! Integration Tests
//!
//! This module contains integration tests that verify the interaction
//! between multiple ZigPod OS components.

const std = @import("std");
const hal = @import("../hal/hal.zig");
const memory = @import("../kernel/memory.zig");
const interrupts = @import("../kernel/interrupts.zig");
const timer = @import("../kernel/timer.zig");
const lcd = @import("../drivers/display/lcd.zig");
const clickwheel = @import("../drivers/input/clickwheel.zig");
const audio = @import("../audio/audio.zig");
const ui = @import("../ui/ui.zig");
const simulator = @import("../simulator/simulator.zig");

// ============================================================
// Test Helpers
// ============================================================

fn setupTestEnvironment() !void {
    // Initialize HAL with mock
    hal.init();
    // Initialize memory
    memory.init();
}

// ============================================================
// Memory Integration Tests
// ============================================================

test "memory allocation and kernel integration" {
    setupTestEnvironment() catch {};

    // Allocate memory of different sizes
    const small = memory.alloc(32);
    const medium = memory.alloc(128);
    const large = memory.alloc(512);

    try std.testing.expect(small != null);
    try std.testing.expect(medium != null);
    try std.testing.expect(large != null);

    // Check stats
    const stats = memory.getStats();
    try std.testing.expect(stats.small_free < memory.SMALL_BLOCK_COUNT);
    try std.testing.expect(stats.medium_free < memory.MEDIUM_BLOCK_COUNT);
    try std.testing.expect(stats.large_free < memory.LARGE_BLOCK_COUNT);

    // Free memory
    if (small) |ptr| memory.free(ptr, 32);
    if (medium) |ptr| memory.free(ptr, 128);
    if (large) |ptr| memory.free(ptr, 512);

    // Verify freed
    const stats2 = memory.getStats();
    try std.testing.expectEqual(memory.SMALL_BLOCK_COUNT, stats2.small_free);
    try std.testing.expectEqual(memory.MEDIUM_BLOCK_COUNT, stats2.medium_free);
    try std.testing.expectEqual(memory.LARGE_BLOCK_COUNT, stats2.large_free);
}

// ============================================================
// Interrupt Integration Tests
// ============================================================

test "interrupt registration and critical sections" {
    setupTestEnvironment() catch {};

    const handler = struct {
        fn handle() void {
            // This would be called on interrupt
        }
    }.handle;

    // Register an interrupt handler
    interrupts.register(.timer1, handler);

    // Test critical section
    {
        const section = interrupts.CriticalSection.enter();
        defer section.leave();

        // Interrupts should be disabled
        try std.testing.expect(!interrupts.globalEnabled());
    }

    // Clean up
    interrupts.unregister(.timer1);
}

// ============================================================
// Timer Integration Tests
// ============================================================

test "timer with memory allocation" {
    setupTestEnvironment() catch {};

    // Allocate a timer callback context
    const Context = struct {
        count: u32 = 0,
        data: [64]u8 = undefined,
    };

    const ctx_ptr = memory.alloc(@sizeOf(Context));
    try std.testing.expect(ctx_ptr != null);

    if (ctx_ptr) |ptr| {
        const ctx: *Context = @ptrCast(@alignCast(ptr));
        ctx.count = 0;
        @memset(&ctx.data, 0xAA);

        // Verify data
        try std.testing.expectEqual(@as(u32, 0), ctx.count);
        try std.testing.expectEqual(@as(u8, 0xAA), ctx.data[0]);

        // Free
        memory.free(ptr, @sizeOf(Context));
    }
}

test "software timer allocation and processing" {
    setupTestEnvironment() catch {};

    var called_count: u32 = 0;

    const callback = struct {
        fn cb(data: ?*anyopaque) void {
            if (data) |ptr| {
                const count: *u32 = @ptrCast(@alignCast(ptr));
                count.* += 1;
            }
        }
    }.cb;

    // Allocate a software timer
    const sw_timer = timer.allocTimer();
    try std.testing.expect(sw_timer != null);

    if (sw_timer) |t| {
        t.start(1000, false, callback, @ptrCast(&called_count));
        try std.testing.expect(t.active);

        // Process (won't actually fire without time passing)
        timer.processSoftwareTimers();

        // Stop
        t.stop();
        try std.testing.expect(!t.active);
    }
}

// ============================================================
// LCD Integration Tests
// ============================================================

test "LCD drawing with UI components" {
    setupTestEnvironment() catch {};

    // Initialize LCD
    try lcd.init();

    // Clear screen
    lcd.clear(lcd.Colors.BLACK);

    // Draw some primitives
    lcd.drawRect(10, 10, 100, 50, lcd.Colors.WHITE);
    lcd.fillRect(15, 15, 90, 40, lcd.Colors.BLUE);

    // Draw text
    lcd.drawString(20, 25, "Test", lcd.Colors.WHITE, lcd.Colors.BLUE);

    // Check a pixel was set
    try std.testing.expect(lcd.getPixel(10, 10) == lcd.Colors.WHITE);
    try std.testing.expect(lcd.getPixel(20, 20) == lcd.Colors.BLUE);
}

test "LCD with menu rendering" {
    setupTestEnvironment() catch {};

    try lcd.init();
    lcd.clear(lcd.Colors.BLACK);

    // Create menu items
    var items = [_]ui.MenuItem{
        .{ .label = "Item 1" },
        .{ .label = "Item 2" },
        .{ .label = "Item 3" },
    };

    // Create a menu
    var menu = ui.Menu{
        .title = "Test Menu",
        .items = &items,
    };

    // Draw menu
    ui.drawMenu(&menu);

    // Verify something was drawn (framebuffer not all black)
    var has_content = false;
    for (0..100) |i| {
        if (lcd.getPixel(@intCast(i), 10) != lcd.Colors.BLACK) {
            has_content = true;
            break;
        }
    }
    try std.testing.expect(has_content);
}

// ============================================================
// Click Wheel Integration Tests
// ============================================================

test "click wheel with UI navigation" {
    setupTestEnvironment() catch {};

    // Create menu items
    var items = [_]ui.MenuItem{
        .{ .label = "First" },
        .{ .label = "Second" },
        .{ .label = "Third" },
    };

    // Create a menu
    var menu = ui.Menu{
        .title = "Navigation Test",
        .items = &items,
    };

    try std.testing.expectEqual(@as(u8, 0), menu.selected_index);

    // Simulate navigation down
    menu.selectNext();
    try std.testing.expectEqual(@as(u8, 1), menu.selected_index);

    menu.selectNext();
    try std.testing.expectEqual(@as(u8, 2), menu.selected_index);

    // Navigate up
    menu.selectPrevious();
    try std.testing.expectEqual(@as(u8, 1), menu.selected_index);
}

test "click wheel debouncing integration" {
    // Create debounced buttons
    var play_btn = clickwheel.createDebouncedButton(clickwheel.Button.PLAY);
    var menu_btn = clickwheel.createDebouncedButton(clickwheel.Button.MENU);

    // Simulate button press sequence
    const timestamp: u32 = 1000;

    // Press PLAY
    const play_pressed = play_btn.update(clickwheel.Button.PLAY, timestamp);
    try std.testing.expect(play_pressed);
    try std.testing.expect(play_btn.isPressed());

    // Simultaneously try MENU (should work - different button)
    const menu_pressed = menu_btn.update(clickwheel.Button.MENU, timestamp + 10);
    try std.testing.expect(menu_pressed);

    // Release PLAY
    _ = play_btn.update(0, timestamp + 100);
    try std.testing.expect(!play_btn.isPressed());

    // Quick re-press (should be ignored - debounce)
    const quick_press = play_btn.update(clickwheel.Button.PLAY, timestamp + 110);
    try std.testing.expect(!quick_press);

    // Valid re-press after debounce period
    const valid_press = play_btn.update(clickwheel.Button.PLAY, timestamp + 200);
    try std.testing.expect(valid_press);
}

// ============================================================
// Audio Integration Tests
// ============================================================

test "audio track info formatting" {
    const info = audio.TrackInfo{
        .sample_rate = 44100,
        .channels = 2,
        .bits_per_sample = 16,
        .total_samples = 44100 * 180, // 3 minutes
        .duration_ms = 180000,
        .format = .s16_le,
    };

    // Test duration calculation
    try std.testing.expectEqual(@as(u32, 180), info.durationSeconds());

    // Test formatting
    var buf: [16]u8 = undefined;
    const formatted = info.formatDuration(&buf);
    try std.testing.expectEqualStrings("03:00", formatted);
}

test "audio position formatting" {
    var buf: [16]u8 = undefined;

    // Test various positions
    const pos1 = audio.formatPosition(0, &buf);
    try std.testing.expectEqualStrings("00:00", pos1);

    const pos2 = audio.formatPosition(65000, &buf);
    try std.testing.expectEqualStrings("01:05", pos2);

    const pos3 = audio.formatPosition(3661000, &buf);
    try std.testing.expectEqualStrings("61:01", pos3);
}

// ============================================================
// Simulator Integration Tests
// ============================================================

test "simulator with LCD visualization" {
    const allocator = std.testing.allocator;

    try simulator.initSimulator(allocator, .{
        .lcd_visualization = false, // Don't actually render to terminal in tests
    });
    defer simulator.shutdownSimulator();

    const state = simulator.getSimulatorState();
    try std.testing.expect(state != null);

    if (state) |s| {
        // Write some pixels
        s.lcdWritePixel(100, 100, 0xFFFF);
        s.lcdWritePixel(101, 100, 0xF800);

        // Verify
        try std.testing.expectEqual(@as(u16, 0xFFFF), s.lcd_framebuffer[100 * 320 + 100]);
        try std.testing.expectEqual(@as(u16, 0xF800), s.lcd_framebuffer[100 * 320 + 101]);
    }
}

test "simulator with input simulation" {
    const allocator = std.testing.allocator;

    try simulator.initSimulator(allocator, .{});
    defer simulator.shutdownSimulator();

    const state = simulator.getSimulatorState();
    try std.testing.expect(state != null);

    if (state) |s| {
        // Simulate button press
        s.setButtonState(clickwheel.Button.SELECT);
        try std.testing.expectEqual(clickwheel.Button.SELECT, s.button_state);

        // Simulate wheel movement
        s.setWheelPosition(48);
        try std.testing.expectEqual(@as(u8, 48), s.wheel_position);

        // Test wraparound
        s.setWheelPosition(100);
        try std.testing.expectEqual(@as(u8, 4), s.wheel_position); // 100 % 96 = 4
    }
}

// ============================================================
// Full System Integration Tests
// ============================================================

test "full initialization sequence" {
    setupTestEnvironment() catch {};

    // 1. Memory should be initialized
    const stats = memory.getStats();
    try std.testing.expect(stats.totalBytes() > 0);

    // 2. LCD should initialize
    try lcd.init();

    // 3. UI should initialize
    try ui.init();

    // 4. All systems operational
    try std.testing.expect(true);
}

test "menu navigation with wheel simulation" {
    setupTestEnvironment() catch {};

    // Initialize display
    try lcd.init();

    // Create menu items
    var items = [_]ui.MenuItem{
        .{ .label = "Music" },
        .{ .label = "Playlists" },
        .{ .label = "Settings" },
        .{ .label = "Now Playing" },
    };

    // Create main menu
    var main_menu = ui.Menu{
        .title = "ZigPod",
        .items = &items,
    };

    // Initial state
    try std.testing.expectEqual(@as(u8, 0), main_menu.selected_index);

    // Simulate wheel scrolling down
    for (0..3) |_| {
        main_menu.selectNext();
    }
    try std.testing.expectEqual(@as(u8, 3), main_menu.selected_index);

    // Try to scroll past end
    main_menu.selectNext();
    try std.testing.expectEqual(@as(u8, 3), main_menu.selected_index); // Should stay at end

    // Scroll back up
    main_menu.selectPrevious();
    main_menu.selectPrevious();
    try std.testing.expectEqual(@as(u8, 1), main_menu.selected_index);

    // Draw the menu
    ui.drawMenu(&main_menu);
}
