//! GUI Interface for ZigPod Simulator
//!
//! Provides an abstract interface for GUI backends.
//! Supports LCD display, click wheel, and button visualization.

const std = @import("std");

/// Input event types
pub const EventType = enum {
    quit,
    key_down,
    key_up,
    button_press,
    button_release,
    wheel_turn,
};

/// Button identifiers
pub const Button = enum(u8) {
    menu = 0,
    play_pause = 1,
    next = 2,
    prev = 3,
    select = 4,
    hold = 5,
};

/// Input event
pub const Event = struct {
    event_type: EventType,
    /// For button events
    button: ?Button = null,
    /// For wheel events: positive = clockwise, negative = counter-clockwise
    wheel_delta: i8 = 0,
    /// For key events
    keycode: u32 = 0,
};

/// LCD display configuration
pub const LcdConfig = struct {
    width: u32 = 320,
    height: u32 = 240,
    scale: u32 = 2,
    title: []const u8 = "ZigPod Simulator",
};

/// GUI Backend VTable
pub const GuiVTable = struct {
    /// Initialize the GUI with given LCD dimensions
    init: *const fn (*anyopaque, LcdConfig) anyerror!void,
    /// Cleanup
    deinit: *const fn (*anyopaque) void,
    /// Update LCD display with framebuffer (RGB565)
    updateLcd: *const fn (*anyopaque, []const u16) void,
    /// Poll for input events (returns null if no events)
    pollEvent: *const fn (*anyopaque) ?Event,
    /// Set button state for visualization
    setButtonState: *const fn (*anyopaque, Button, bool) void,
    /// Set wheel position (0-255)
    setWheelPosition: *const fn (*anyopaque, u8) void,
    /// Check if window is still open
    isOpen: *const fn (*anyopaque) bool,
    /// Present/swap buffers
    present: *const fn (*anyopaque) void,
};

/// GUI Backend interface
pub const GuiBackend = struct {
    vtable: *const GuiVTable,
    context: *anyopaque,

    const Self = @This();

    /// Initialize the GUI
    pub fn init(self: *Self, config: LcdConfig) !void {
        return self.vtable.init(self.context, config);
    }

    /// Cleanup
    pub fn deinit(self: *Self) void {
        self.vtable.deinit(self.context);
    }

    /// Update LCD display
    pub fn updateLcd(self: *Self, framebuffer: []const u16) void {
        self.vtable.updateLcd(self.context, framebuffer);
    }

    /// Poll for events
    pub fn pollEvent(self: *Self) ?Event {
        return self.vtable.pollEvent(self.context);
    }

    /// Set button state
    pub fn setButtonState(self: *Self, button: Button, pressed: bool) void {
        self.vtable.setButtonState(self.context, button, pressed);
    }

    /// Set wheel position
    pub fn setWheelPosition(self: *Self, position: u8) void {
        self.vtable.setWheelPosition(self.context, position);
    }

    /// Check if still open
    pub fn isOpen(self: *Self) bool {
        return self.vtable.isOpen(self.context);
    }

    /// Present frame
    pub fn present(self: *Self) void {
        self.vtable.present(self.context);
    }
};

/// Null backend (headless mode)
pub const NullBackend = struct {
    open: bool = true,
    button_states: [6]bool = [_]bool{false} ** 6,
    wheel_pos: u8 = 0,
    event_queue: std.ArrayList(Event) = undefined,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .event_queue = std.ArrayList(Event){},
        };
    }

    pub fn getBackend(self: *Self) GuiBackend {
        return .{
            .vtable = &vtable,
            .context = self,
        };
    }

    fn initImpl(ctx: *anyopaque, _: LcdConfig) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.open = true;
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.event_queue.deinit(self.allocator);
    }

    fn updateLcdImpl(_: *anyopaque, _: []const u16) void {
        // No-op for null backend
    }

    fn pollEventImpl(ctx: *anyopaque) ?Event {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.event_queue.items.len > 0) {
            return self.event_queue.orderedRemove(0);
        }
        return null;
    }

    fn setButtonStateImpl(ctx: *anyopaque, button: Button, pressed: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.button_states[@intFromEnum(button)] = pressed;
    }

    fn setWheelPositionImpl(ctx: *anyopaque, pos: u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.wheel_pos = pos;
    }

    fn isOpenImpl(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.open;
    }

    fn presentImpl(_: *anyopaque) void {
        // No-op for null backend
    }

    /// Inject an event for testing
    pub fn injectEvent(self: *Self, event: Event) !void {
        try self.event_queue.append(self.allocator, event);
    }

    /// Close the window
    pub fn close(self: *Self) void {
        self.open = false;
    }

    const vtable = GuiVTable{
        .init = initImpl,
        .deinit = deinitImpl,
        .updateLcd = updateLcdImpl,
        .pollEvent = pollEventImpl,
        .setButtonState = setButtonStateImpl,
        .setWheelPosition = setWheelPositionImpl,
        .isOpen = isOpenImpl,
        .present = presentImpl,
    };
};

/// Color conversion utilities
pub const Color = struct {
    /// Convert RGB888 to RGB565
    pub fn rgb888ToRgb565(r: u8, g: u8, b: u8) u16 {
        const r5: u16 = @as(u16, r >> 3);
        const g6: u16 = @as(u16, g >> 2);
        const b5: u16 = @as(u16, b >> 3);
        return (r5 << 11) | (g6 << 5) | b5;
    }

    /// Convert RGB565 to RGB888
    pub fn rgb565ToRgb888(color: u16) struct { r: u8, g: u8, b: u8 } {
        const r5 = (color >> 11) & 0x1F;
        const g6 = (color >> 5) & 0x3F;
        const b5 = color & 0x1F;
        return .{
            .r = @as(u8, @intCast(r5)) << 3 | @as(u8, @intCast(r5 >> 2)),
            .g = @as(u8, @intCast(g6)) << 2 | @as(u8, @intCast(g6 >> 4)),
            .b = @as(u8, @intCast(b5)) << 3 | @as(u8, @intCast(b5 >> 2)),
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "null backend init" {
    const allocator = std.testing.allocator;
    var backend = NullBackend.create(allocator);
    var gui = backend.getBackend();

    try gui.init(.{});
    defer gui.deinit();

    try std.testing.expect(gui.isOpen());
}

test "null backend button state" {
    const allocator = std.testing.allocator;
    var backend = NullBackend.create(allocator);
    var gui = backend.getBackend();

    try gui.init(.{});
    defer gui.deinit();

    gui.setButtonState(.menu, true);
    try std.testing.expect(backend.button_states[0]);

    gui.setButtonState(.menu, false);
    try std.testing.expect(!backend.button_states[0]);
}

test "null backend event injection" {
    const allocator = std.testing.allocator;
    var backend = NullBackend.create(allocator);
    var gui = backend.getBackend();

    try gui.init(.{});
    defer gui.deinit();

    // No events initially
    try std.testing.expect(gui.pollEvent() == null);

    // Inject an event
    try backend.injectEvent(.{ .event_type = .button_press, .button = .play_pause });

    // Should receive the event
    const event = gui.pollEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(EventType.button_press, event.?.event_type);
    try std.testing.expectEqual(Button.play_pause, event.?.button.?);

    // Queue should be empty again
    try std.testing.expect(gui.pollEvent() == null);
}

test "null backend close" {
    const allocator = std.testing.allocator;
    var backend = NullBackend.create(allocator);
    var gui = backend.getBackend();

    try gui.init(.{});
    defer gui.deinit();

    try std.testing.expect(gui.isOpen());
    backend.close();
    try std.testing.expect(!gui.isOpen());
}

test "rgb565 color conversion" {
    // Pure red
    const red = Color.rgb888ToRgb565(255, 0, 0);
    try std.testing.expectEqual(@as(u16, 0xF800), red);

    // Pure green
    const green = Color.rgb888ToRgb565(0, 255, 0);
    try std.testing.expectEqual(@as(u16, 0x07E0), green);

    // Pure blue
    const blue = Color.rgb888ToRgb565(0, 0, 255);
    try std.testing.expectEqual(@as(u16, 0x001F), blue);

    // White
    const white = Color.rgb888ToRgb565(255, 255, 255);
    try std.testing.expectEqual(@as(u16, 0xFFFF), white);

    // Black
    const black = Color.rgb888ToRgb565(0, 0, 0);
    try std.testing.expectEqual(@as(u16, 0x0000), black);
}

test "rgb565 roundtrip" {
    const original = Color.rgb888ToRgb565(128, 64, 192);
    const converted = Color.rgb565ToRgb888(original);

    // Due to precision loss, check approximate values
    try std.testing.expect(converted.r >= 120 and converted.r <= 136);
    try std.testing.expect(converted.g >= 60 and converted.g <= 68);
    try std.testing.expect(converted.b >= 184 and converted.b <= 200);
}

test "wheel position" {
    const allocator = std.testing.allocator;
    var backend = NullBackend.create(allocator);
    var gui = backend.getBackend();

    try gui.init(.{});
    defer gui.deinit();

    gui.setWheelPosition(128);
    try std.testing.expectEqual(@as(u8, 128), backend.wheel_pos);
}
