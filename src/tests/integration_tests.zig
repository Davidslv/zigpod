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
const power = @import("../drivers/power.zig");
const bootloader = @import("../kernel/bootloader.zig");
const library = @import("../library/library.zig");

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

// ============================================================
// Audio Decoder Integration Tests
// ============================================================

test "audio decoder format detection" {
    // WAV
    const wav_header = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E' };
    try std.testing.expectEqual(audio.decoders.DecoderType.wav, audio.decoders.detectFormat(&wav_header));

    // FLAC
    const flac_header = [_]u8{ 'f', 'L', 'a', 'C', 0, 0, 0, 0 };
    try std.testing.expectEqual(audio.decoders.DecoderType.flac, audio.decoders.detectFormat(&flac_header));

    // MP3 (ID3v2)
    const mp3_id3 = [_]u8{ 'I', 'D', '3', 0x04, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(audio.decoders.DecoderType.mp3, audio.decoders.detectFormat(&mp3_id3));

    // AIFF
    const aiff_header = [_]u8{ 'F', 'O', 'R', 'M', 0, 0, 0, 0, 'A', 'I', 'F', 'F' };
    try std.testing.expectEqual(audio.decoders.DecoderType.aiff, audio.decoders.detectFormat(&aiff_header));

    // Unknown
    const unknown = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(audio.decoders.DecoderType.unknown, audio.decoders.detectFormat(&unknown));
}

test "audio supported extensions" {
    try std.testing.expect(audio.decoders.isSupportedExtension(".wav"));
    try std.testing.expect(audio.decoders.isSupportedExtension(".WAV"));
    try std.testing.expect(audio.decoders.isSupportedExtension(".flac"));
    try std.testing.expect(audio.decoders.isSupportedExtension(".mp3"));
    try std.testing.expect(audio.decoders.isSupportedExtension(".MP3"));
    try std.testing.expect(audio.decoders.isSupportedExtension(".aiff"));
    try std.testing.expect(audio.decoders.isSupportedExtension(".aif"));
    try std.testing.expect(!audio.decoders.isSupportedExtension(".ogg"));
    try std.testing.expect(!audio.decoders.isSupportedExtension(".wma"));
}

// ============================================================
// DSP Integration Tests
// ============================================================

test "dsp equalizer with presets" {
    var dsp = audio.dsp.DspChain.init();

    // Apply Rock preset
    dsp.applyPreset(1);
    try std.testing.expectEqual(@as(i8, 4), dsp.equalizer.getBandGain(0));
    try std.testing.expectEqual(@as(i8, 2), dsp.equalizer.getBandGain(1));

    // Apply Flat preset
    dsp.applyPreset(0);
    for (0..audio.dsp.EQ_BANDS) |i| {
        try std.testing.expectEqual(@as(i8, 0), dsp.equalizer.getBandGain(i));
    }
}

test "dsp stereo widener" {
    var widener = audio.dsp.StereoWidener.init();
    widener.enabled = true;

    // Mono (width = 0)
    widener.setWidth(0);
    const mono_result = widener.process(1000, -1000);
    try std.testing.expectEqual(mono_result.left, mono_result.right);

    // Normal (width = 100)
    widener.setWidth(100);
    const normal_result = widener.process(1000, -1000);
    try std.testing.expect(normal_result.left != normal_result.right);
}

test "dsp chain passthrough" {
    var dsp = audio.dsp.DspChain.init();

    // With neutral settings, output should be close to input
    const result = dsp.process(1000, -1000);

    // Allow tolerance for fixed-point math
    try std.testing.expect(@abs(@as(i32, result.left) - 1000) < 100);
    try std.testing.expect(@abs(@as(i32, result.right) + 1000) < 100);
}

// ============================================================
// Power Management Integration Tests
// ============================================================

test "battery estimation curve" {
    // Full charge
    try std.testing.expectEqual(@as(u8, 100), power.BatteryInfo.estimateFromVoltage(4200));

    // Mid range
    const mid = power.BatteryInfo.estimateFromVoltage(3700);
    try std.testing.expect(mid >= 45 and mid <= 55);

    // Low
    const low = power.BatteryInfo.estimateFromVoltage(3400);
    try std.testing.expect(low >= 5 and low <= 15);

    // Empty
    try std.testing.expectEqual(@as(u8, 0), power.BatteryInfo.estimateFromVoltage(3000));
    try std.testing.expectEqual(@as(u8, 0), power.BatteryInfo.estimateFromVoltage(2500));
}

test "battery icon selection" {
    var info = power.BatteryInfo{};

    info.percentage = 90;
    try std.testing.expectEqualStrings("[####]", info.getIcon());

    info.percentage = 50;
    try std.testing.expectEqualStrings("[##  ]", info.getIcon());

    info.percentage = 10;
    try std.testing.expectEqualStrings("[!   ]", info.getIcon());

    info.charging_state = .charging;
    try std.testing.expectEqualStrings("[CHG]", info.getIcon());
}

test "power profiles" {
    const normal = power.DEFAULT_PROFILES[0];
    try std.testing.expectEqualStrings("Normal", normal.name);
    try std.testing.expectEqual(@as(u16, 30), normal.backlight_timeout_sec);

    const power_saver = power.DEFAULT_PROFILES[1];
    try std.testing.expectEqualStrings("Power Saver", power_saver.name);
    try std.testing.expectEqual(@as(u16, 10), power_saver.backlight_timeout_sec);

    const performance = power.DEFAULT_PROFILES[2];
    try std.testing.expectEqualStrings("Performance", performance.name);
    try std.testing.expectEqual(@as(u16, 0), performance.auto_sleep_minutes);
}

// ============================================================
// Bootloader Integration Tests
// ============================================================

test "boot config checksum" {
    var config = bootloader.BootConfig{};
    config.updateChecksum();
    try std.testing.expect(config.isValid());

    // Corrupt data
    config.boot_count = 12345;
    try std.testing.expect(!config.isValid());

    // Fix checksum
    config.updateChecksum();
    try std.testing.expect(config.isValid());
}

test "firmware header validation" {
    var header = bootloader.FirmwareHeader{
        .size = 65536,
        .entry_point = 0x40100100,
        .load_address = 0x40100000,
    };
    try std.testing.expect(header.isValid());

    // Invalid: zero size
    header.size = 0;
    try std.testing.expect(!header.isValid());

    // Invalid: entry before load
    header.size = 1024;
    header.entry_point = 0x40000000;
    try std.testing.expect(!header.isValid());
}

test "firmware header version string" {
    const header = bootloader.FirmwareHeader{
        .version_major = 1,
        .version_minor = 2,
        .version_patch = 3,
    };

    var buf: [16]u8 = undefined;
    const version = header.getVersion(&buf);
    try std.testing.expectEqualStrings("1.2.3", version);
}

// ============================================================
// Library Integration Tests
// ============================================================

test "playlist format detection" {
    try std.testing.expect(library.playlist_parser.isPlaylistExtension("playlist.m3u"));
    try std.testing.expect(library.playlist_parser.isPlaylistExtension("playlist.M3U8"));
    try std.testing.expect(library.playlist_parser.isPlaylistExtension("playlist.pls"));
    try std.testing.expect(!library.playlist_parser.isPlaylistExtension("song.mp3"));
}

test "m3u playlist parsing" {
    const m3u_content =
        \\#EXTM3U
        \\#PLAYLIST:Test Playlist
        \\#EXTINF:180,Artist - Song Title
        \\/music/song.mp3
        \\#EXTINF:240,Another Song
        \\/music/song2.mp3
    ;

    var parser = library.playlist_parser.M3uParser.init(m3u_content);
    const result = parser.parse();

    try std.testing.expect(result.is_extended);
    try std.testing.expectEqualStrings("Test Playlist", result.name);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("/music/song.mp3", result.entries[0].path);
    try std.testing.expectEqual(@as(u32, 180), result.entries[0].duration_secs);
}

// ============================================================
// Metadata Integration Tests
// ============================================================

test "metadata empty check" {
    const empty_data = [_]u8{0} ** 100;
    const metadata = audio.metadata.parse(&empty_data);
    try std.testing.expect(metadata.isEmpty());
}

test "metadata field storage" {
    var metadata = audio.metadata.Metadata{};

    metadata.setTitle("Test Song");
    try std.testing.expectEqualStrings("Test Song", metadata.getTitle());

    metadata.setArtist("Test Artist");
    try std.testing.expectEqualStrings("Test Artist", metadata.getArtist());

    metadata.setAlbum("Test Album");
    try std.testing.expectEqualStrings("Test Album", metadata.getAlbum());
}

// ============================================================
// Simulator Terminal UI Integration Tests
// ============================================================

test "simulator rgb565 conversion" {
    const terminal_ui = simulator.terminal_ui;

    // White
    const white = terminal_ui.rgb565ToRgb888(0xFFFF);
    try std.testing.expectEqual(@as(u8, 255), white.r);
    try std.testing.expectEqual(@as(u8, 255), white.g);
    try std.testing.expectEqual(@as(u8, 255), white.b);

    // Black
    const black = terminal_ui.rgb565ToRgb888(0x0000);
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);

    // Roundtrip red
    const red_565: u16 = 0xF800;
    const red_rgb = terminal_ui.rgb565ToRgb888(red_565);
    const red_back = terminal_ui.rgb888ToRgb565(red_rgb.r, red_rgb.g, red_rgb.b);
    try std.testing.expectEqual(red_565, red_back);
}

// ============================================================
// Complete System Integration Tests
// ============================================================

test "complete audio pipeline structure" {
    // Verify audio types are properly sized
    try std.testing.expect(@sizeOf(audio.TrackInfo) <= 64);

    // Verify decoder types are all registered
    try std.testing.expectEqual(@as(usize, 5), @typeInfo(audio.decoders.DecoderType).@"enum".fields.len);
}

test "complete ui screen dimensions" {
    try std.testing.expectEqual(@as(u16, 320), ui.SCREEN_WIDTH);
    try std.testing.expectEqual(@as(u16, 240), ui.SCREEN_HEIGHT);
    try std.testing.expect(ui.MAX_VISIBLE_ITEMS >= 8);
}

test "complete power stats structure" {
    const stats = power.PowerStats{};
    var buf: [64]u8 = undefined;
    const uptime = stats.getUptimeString(&buf);
    try std.testing.expectEqualStrings("0h 0m", uptime);
}
