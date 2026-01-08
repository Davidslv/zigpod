//! Click Wheel Input Driver
//!
//! This driver handles the iPod click wheel and button input.
//! The click wheel uses a capacitive sensor with 96 positions (0-95).

const std = @import("std");
const hal = @import("../../hal/hal.zig");

// ============================================================
// Button Definitions
// ============================================================

/// Button bit flags
pub const Button = struct {
    pub const SELECT: u8 = 0x01;
    pub const RIGHT: u8 = 0x02;
    pub const LEFT: u8 = 0x04;
    pub const PLAY: u8 = 0x08;
    pub const MENU: u8 = 0x10;
    pub const HOLD: u8 = 0x20;

    /// No buttons pressed
    pub const NONE: u8 = 0x00;
};

/// Named button for cleaner API
pub const ButtonId = enum {
    select,
    right,
    left,
    play_pause,
    menu,
    hold,
    none,
};

/// Wheel events
pub const WheelEvent = enum {
    none,
    clockwise,
    counter_clockwise,
};

/// Input event
pub const InputEvent = struct {
    buttons: u8,
    wheel_position: u8,
    wheel_delta: i8,
    timestamp: u32,

    pub fn buttonPressed(self: InputEvent, button: u8) bool {
        return (self.buttons & button) != 0;
    }

    pub fn anyButtonPressed(self: InputEvent) bool {
        return self.buttons != Button.NONE;
    }

    pub fn isHoldOn(self: InputEvent) bool {
        return (self.buttons & Button.HOLD) != 0;
    }

    pub fn wheelEvent(self: InputEvent) WheelEvent {
        if (self.wheel_delta > 0) return .clockwise;
        if (self.wheel_delta < 0) return .counter_clockwise;
        return .none;
    }
};

// ============================================================
// Click Wheel Constants
// ============================================================

pub const WHEEL_POSITIONS: u8 = 96; // 0-95
pub const WHEEL_MAX_VALUE: u8 = 95;
pub const WHEEL_SENSITIVITY: u8 = 4; // Minimum delta to register as scroll

/// Button repeat timing
pub const REPEAT_START_MS: u32 = 500;
pub const REPEAT_INTERVAL_MS: u32 = 100;

// ============================================================
// Click Wheel State
// ============================================================

var initialized: bool = false;
var last_position: u8 = 0;
var last_buttons: u8 = 0;
var button_press_time: u32 = 0;
var button_repeat_count: u32 = 0;

/// Raw input state (for HAL mock)
var raw_wheel_position: u8 = 0;
var raw_buttons: u8 = 0;

/// Initialize the click wheel driver
pub fn init() hal.HalError!void {
    try hal.current_hal.clickwheel_init();
    last_position = 0;
    last_buttons = 0;
    initialized = true;
}

/// Check if initialized
pub fn isInitialized() bool {
    return initialized;
}

// ============================================================
// Input Reading
// ============================================================

/// Poll for input events
pub fn poll() hal.HalError!InputEvent {
    if (!initialized) return hal.HalError.DeviceNotReady;

    // Read current state from HAL
    const current_buttons = hal.current_hal.clickwheel_read_buttons();
    const current_position = hal.current_hal.clickwheel_read_position();
    const timestamp = hal.current_hal.get_ticks();

    // Calculate wheel delta with wraparound handling
    var delta: i16 = @as(i16, current_position) - @as(i16, last_position);

    // Handle wraparound (wheel is circular)
    if (delta > WHEEL_POSITIONS / 2) {
        delta -= WHEEL_POSITIONS;
    } else if (delta < -@as(i16, WHEEL_POSITIONS / 2)) {
        delta += WHEEL_POSITIONS;
    }

    // Apply sensitivity threshold
    var reported_delta: i8 = 0;
    if (delta >= WHEEL_SENSITIVITY or delta <= -@as(i16, WHEEL_SENSITIVITY)) {
        reported_delta = @intCast(std.math.clamp(delta, -127, 127));
        last_position = current_position;
    }

    // Update state
    last_buttons = current_buttons;

    return InputEvent{
        .buttons = current_buttons,
        .wheel_position = current_position,
        .wheel_delta = reported_delta,
        .timestamp = timestamp,
    };
}

/// Wait for any button press (blocking)
pub fn waitForButton() hal.HalError!InputEvent {
    while (true) {
        const event = try poll();
        if (event.anyButtonPressed()) {
            return event;
        }
        hal.delayMs(10);
    }
}

/// Wait for specific button (blocking)
pub fn waitForSpecificButton(button: u8) hal.HalError!InputEvent {
    while (true) {
        const event = try poll();
        if (event.buttonPressed(button)) {
            return event;
        }
        hal.delayMs(10);
    }
}

/// Check if hold switch is on
pub fn isHoldOn() bool {
    if (!initialized) return false;
    return (hal.current_hal.clickwheel_read_buttons() & Button.HOLD) != 0;
}

/// Get current wheel position (0-95)
pub fn getWheelPosition() u8 {
    if (!initialized) return 0;
    return hal.current_hal.clickwheel_read_position();
}

/// Get current button state
pub fn getButtons() u8 {
    if (!initialized) return 0;
    return hal.current_hal.clickwheel_read_buttons();
}

// ============================================================
// Button Detection Helpers
// ============================================================

/// Debounced button check
pub const DebouncedButton = struct {
    button: u8,
    pressed: bool = false,
    press_time: u32 = 0,
    release_time: u32 = 0,
    debounce_ms: u32 = 50,

    pub fn update(self: *DebouncedButton, current_state: u8, timestamp: u32) bool {
        const is_pressed = (current_state & self.button) != 0;

        if (is_pressed and !self.pressed) {
            // Button just pressed
            if (timestamp - self.release_time >= self.debounce_ms) {
                self.pressed = true;
                self.press_time = timestamp;
                return true; // Valid press
            }
        } else if (!is_pressed and self.pressed) {
            // Button just released
            self.pressed = false;
            self.release_time = timestamp;
        }

        return false;
    }

    pub fn isPressed(self: DebouncedButton) bool {
        return self.pressed;
    }

    pub fn pressDuration(self: DebouncedButton, current_time: u32) u32 {
        if (!self.pressed) return 0;
        return current_time - self.press_time;
    }
};

/// Create a debounced button tracker
pub fn createDebouncedButton(button: u8) DebouncedButton {
    return DebouncedButton{
        .button = button,
    };
}

// ============================================================
// Wheel Gesture Detection
// ============================================================

/// Gesture state for detecting wheel patterns
pub const WheelGesture = struct {
    accumulated_delta: i32 = 0,
    last_direction: i8 = 0,
    gesture_start_time: u32 = 0,
    is_active: bool = false,

    pub const SCRUB_THRESHOLD: i32 = 24; // 1/4 wheel turn
    pub const FULL_TURN: i32 = 96;
    pub const GESTURE_TIMEOUT_MS: u32 = 200;

    pub fn update(self: *WheelGesture, delta: i8, timestamp: u32) void {
        if (delta == 0) {
            // Check for gesture timeout
            if (self.is_active and (timestamp - self.gesture_start_time > GESTURE_TIMEOUT_MS)) {
                self.reset();
            }
            return;
        }

        const direction: i8 = if (delta > 0) 1 else -1;

        if (!self.is_active) {
            // Start new gesture
            self.is_active = true;
            self.gesture_start_time = timestamp;
            self.last_direction = direction;
            self.accumulated_delta = delta;
        } else if (direction == self.last_direction) {
            // Continue gesture in same direction
            self.accumulated_delta += delta;
        } else {
            // Direction changed - reset
            self.reset();
            self.is_active = true;
            self.gesture_start_time = timestamp;
            self.last_direction = direction;
            self.accumulated_delta = delta;
        }
    }

    pub fn reset(self: *WheelGesture) void {
        self.accumulated_delta = 0;
        self.last_direction = 0;
        self.is_active = false;
    }

    /// Get the number of "scrub units" (1 scrub unit = 24 wheel positions)
    pub fn getScrubUnits(self: WheelGesture) i32 {
        return @divTrunc(self.accumulated_delta, SCRUB_THRESHOLD);
    }

    /// Get the wheel rotation (in fractions of full turn, 0-100)
    pub fn getRotationPercent(self: WheelGesture) u8 {
        const abs_delta: u32 = @intCast(@abs(self.accumulated_delta));
        return @intCast(@min(100, (abs_delta * 100) / FULL_TURN));
    }
};

/// Create a wheel gesture tracker
pub fn createWheelGesture() WheelGesture {
    return WheelGesture{};
}

// ============================================================
// Convenience Functions
// ============================================================

/// Get human-readable button name
pub fn buttonName(button: u8) []const u8 {
    if (button == Button.SELECT) return "Select";
    if (button == Button.RIGHT) return "Right";
    if (button == Button.LEFT) return "Left";
    if (button == Button.PLAY) return "Play/Pause";
    if (button == Button.MENU) return "Menu";
    if (button == Button.HOLD) return "Hold";
    return "Unknown";
}

/// Convert button ID to bit flag
pub fn buttonIdToFlag(id: ButtonId) u8 {
    return switch (id) {
        .select => Button.SELECT,
        .right => Button.RIGHT,
        .left => Button.LEFT,
        .play_pause => Button.PLAY,
        .menu => Button.MENU,
        .hold => Button.HOLD,
        .none => Button.NONE,
    };
}

/// Get the "primary" pressed button (highest priority)
pub fn getPrimaryButton(buttons: u8) ButtonId {
    // Priority order: Select > Menu > Play > Left > Right
    if ((buttons & Button.SELECT) != 0) return .select;
    if ((buttons & Button.MENU) != 0) return .menu;
    if ((buttons & Button.PLAY) != 0) return .play_pause;
    if ((buttons & Button.LEFT) != 0) return .left;
    if ((buttons & Button.RIGHT) != 0) return .right;
    if ((buttons & Button.HOLD) != 0) return .hold;
    return .none;
}

// ============================================================
// Tests
// ============================================================

test "button flags" {
    try std.testing.expectEqual(@as(u8, 0x01), Button.SELECT);
    try std.testing.expectEqual(@as(u8, 0x10), Button.MENU);
}

test "wheel delta calculation" {
    // Normal forward movement
    var delta: i16 = 10 - 5;
    try std.testing.expectEqual(@as(i16, 5), delta);

    // Forward wraparound (95 -> 5)
    delta = 5 - 95;
    if (delta < -@as(i16, WHEEL_POSITIONS / 2)) {
        delta += WHEEL_POSITIONS;
    }
    try std.testing.expectEqual(@as(i16, 6), delta);

    // Backward wraparound (5 -> 95)
    delta = 95 - 5;
    if (delta > WHEEL_POSITIONS / 2) {
        delta -= WHEEL_POSITIONS;
    }
    try std.testing.expectEqual(@as(i16, -6), delta);
}

test "input event" {
    const event = InputEvent{
        .buttons = Button.SELECT | Button.MENU,
        .wheel_position = 50,
        .wheel_delta = 5,
        .timestamp = 1000,
    };

    try std.testing.expect(event.buttonPressed(Button.SELECT));
    try std.testing.expect(event.buttonPressed(Button.MENU));
    try std.testing.expect(!event.buttonPressed(Button.PLAY));
    try std.testing.expect(event.anyButtonPressed());
    try std.testing.expectEqual(WheelEvent.clockwise, event.wheelEvent());
}

test "debounced button" {
    var btn = createDebouncedButton(Button.SELECT);

    // Initial press (timestamp must be >= debounce_ms for first press)
    try std.testing.expect(btn.update(Button.SELECT, 100));
    try std.testing.expect(btn.isPressed());

    // Held press - no new event
    try std.testing.expect(!btn.update(Button.SELECT, 110));

    // Release
    try std.testing.expect(!btn.update(0, 200));
    try std.testing.expect(!btn.isPressed());

    // Quick bounce (should be ignored, within 50ms)
    try std.testing.expect(!btn.update(Button.SELECT, 210));

    // Valid new press after debounce time (>= 50ms after release)
    try std.testing.expect(btn.update(Button.SELECT, 260));
}

test "wheel gesture" {
    var gesture = createWheelGesture();

    // Accumulate clockwise movement
    gesture.update(10, 0);
    gesture.update(10, 50);
    gesture.update(10, 100);

    try std.testing.expect(gesture.is_active);
    try std.testing.expectEqual(@as(i32, 30), gesture.accumulated_delta);
    try std.testing.expectEqual(@as(i32, 1), gesture.getScrubUnits()); // 30 / 24 = 1

    // Direction change resets
    gesture.update(-5, 150);
    try std.testing.expectEqual(@as(i32, -5), gesture.accumulated_delta);
}

test "button names" {
    try std.testing.expectEqualStrings("Select", buttonName(Button.SELECT));
    try std.testing.expectEqualStrings("Menu", buttonName(Button.MENU));
    try std.testing.expectEqualStrings("Play/Pause", buttonName(Button.PLAY));
}
