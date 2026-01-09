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

// ============================================================
// Wheel Acceleration
// ============================================================

/// Wheel acceleration for faster scrolling through large lists
/// Uses velocity tracking and exponential curve for natural feel
pub const WheelAccelerator = struct {
    /// Configuration
    pub const Config = struct {
        /// Base scroll speed (1.0 = raw delta)
        base_multiplier: u16 = 256, // Q8 fixed-point (1.0)
        /// Maximum acceleration multiplier
        max_multiplier: u16 = 2048, // Q8 fixed-point (8.0)
        /// Velocity threshold to start accelerating (wheel positions per second)
        accel_threshold: u32 = 50,
        /// Time window to measure velocity (ms)
        velocity_window: u32 = 100,
        /// Decay rate when wheel stops (ms to return to base speed)
        decay_ms: u32 = 300,
    };

    config: Config = .{},

    // State
    last_delta_time: u32 = 0,
    last_delta: i8 = 0,
    accumulated_delta: i32 = 0,
    velocity: u32 = 0, // positions per second, Q0
    current_multiplier: u16 = 256, // Q8

    // History for velocity calculation
    history: [4]DeltaEntry = [_]DeltaEntry{.{}} ** 4,
    history_index: u8 = 0,

    const DeltaEntry = struct {
        delta: i8 = 0,
        timestamp: u32 = 0,
    };

    /// Update with new wheel delta
    pub fn update(self: *WheelAccelerator, delta: i8, timestamp: u32) i16 {
        if (delta == 0) {
            // Decay acceleration when wheel is idle
            self.decay(timestamp);
            return 0;
        }

        // Add to history
        self.history[self.history_index] = .{ .delta = delta, .timestamp = timestamp };
        self.history_index = (self.history_index + 1) % 4;

        // Calculate velocity from history
        self.velocity = self.calculateVelocity(timestamp);

        // Update multiplier based on velocity
        self.updateMultiplier();

        // Apply acceleration
        const abs_delta: i32 = if (delta < 0) -@as(i32, delta) else @as(i32, delta);
        const sign: i32 = if (delta < 0) -1 else 1;
        const accelerated = (abs_delta * self.current_multiplier) >> 8;
        const result = sign * @max(1, accelerated);

        self.last_delta = delta;
        self.last_delta_time = timestamp;

        return @intCast(std.math.clamp(result, -127, 127));
    }

    fn calculateVelocity(self: *WheelAccelerator, current_time: u32) u32 {
        var total_delta: u32 = 0;
        var oldest_time: u32 = current_time;
        var valid_entries: u32 = 0;

        for (self.history) |entry| {
            if (entry.timestamp > 0 and current_time - entry.timestamp < self.config.velocity_window) {
                const abs_delta: u32 = if (entry.delta < 0)
                    @intCast(-@as(i32, entry.delta))
                else
                    @intCast(entry.delta);
                total_delta += abs_delta;
                if (entry.timestamp < oldest_time) {
                    oldest_time = entry.timestamp;
                }
                valid_entries += 1;
            }
        }

        if (valid_entries < 2 or current_time == oldest_time) {
            return 0;
        }

        // positions per second
        const time_span = current_time - oldest_time;
        if (time_span == 0) return 0;
        return (total_delta * 1000) / time_span;
    }

    fn updateMultiplier(self: *WheelAccelerator) void {
        if (self.velocity < self.config.accel_threshold) {
            self.current_multiplier = self.config.base_multiplier;
            return;
        }

        // Exponential curve: multiplier = base * (velocity / threshold)^0.7
        // Approximated with linear interpolation for embedded
        const excess = self.velocity - self.config.accel_threshold;
        const scale = @min(excess, 200); // Cap at 200 excess velocity

        // Linear interpolation from base to max based on velocity
        // Use u32 to avoid overflow: range (1792) * scale (200) = 358400
        const range: u32 = self.config.max_multiplier - self.config.base_multiplier;
        const increase: u32 = (range * scale) / 200;
        self.current_multiplier = self.config.base_multiplier + @as(u16, @intCast(increase));
    }

    fn decay(self: *WheelAccelerator, current_time: u32) void {
        if (self.current_multiplier <= self.config.base_multiplier) return;

        const elapsed = current_time - self.last_delta_time;
        if (elapsed >= self.config.decay_ms) {
            self.current_multiplier = self.config.base_multiplier;
            self.velocity = 0;
        } else {
            // Gradual decay
            const progress = (elapsed * 256) / self.config.decay_ms;
            const range = self.current_multiplier - self.config.base_multiplier;
            const decay_amount = (range * @as(u16, @intCast(progress))) / 256;
            if (decay_amount >= range) {
                self.current_multiplier = self.config.base_multiplier;
            } else {
                self.current_multiplier -= @as(u16, @intCast(decay_amount));
            }
        }
    }

    /// Reset acceleration state
    pub fn reset(self: *WheelAccelerator) void {
        self.current_multiplier = self.config.base_multiplier;
        self.velocity = 0;
        self.history = [_]DeltaEntry{.{}} ** 4;
        self.history_index = 0;
    }

    /// Get current acceleration multiplier (Q8 fixed-point, 256 = 1.0x)
    pub fn getMultiplier(self: *const WheelAccelerator) u16 {
        return self.current_multiplier;
    }

    /// Get current velocity (positions per second)
    pub fn getVelocity(self: *const WheelAccelerator) u32 {
        return self.velocity;
    }
};

/// Create a wheel accelerator
pub fn createWheelAccelerator() WheelAccelerator {
    return WheelAccelerator{};
}

// ============================================================
// Gesture Detection
// ============================================================

/// Comprehensive gesture detector for buttons and wheel
pub const GestureDetector = struct {
    /// Gesture types
    pub const GestureType = enum {
        none,
        tap, // Quick press and release
        long_press, // Held for threshold time
        double_tap, // Two quick taps
        hold, // Currently being held (continuous)
        scrub_cw, // Fast clockwise wheel movement
        scrub_ccw, // Fast counter-clockwise wheel movement
    };

    /// Configuration
    pub const Config = struct {
        tap_max_ms: u32 = 200, // Max time for a tap
        long_press_ms: u32 = 800, // Time to trigger long press
        double_tap_window_ms: u32 = 400, // Window for double tap
        scrub_threshold: u32 = 48, // Wheel positions to trigger scrub
    };

    config: Config = .{},

    // Button state
    button_down_time: u32 = 0,
    button_up_time: u32 = 0,
    button_down: bool = false,
    last_button: u8 = 0,
    tap_count: u8 = 0,
    long_press_fired: bool = false,

    // Wheel state
    wheel_accumulator: i32 = 0,
    wheel_direction: i8 = 0,
    wheel_last_time: u32 = 0,

    /// Update with new input event, returns detected gesture
    pub fn update(self: *GestureDetector, event: InputEvent) GestureType {
        var gesture: GestureType = .none;

        // Check for wheel gestures
        if (event.wheel_delta != 0) {
            gesture = self.updateWheel(event.wheel_delta, event.timestamp);
            if (gesture != .none) return gesture;
        } else {
            // Wheel idle - decay accumulator
            if (event.timestamp - self.wheel_last_time > 200) {
                self.wheel_accumulator = 0;
            }
        }

        // Check for button gestures
        const any_pressed = event.anyButtonPressed();

        if (any_pressed and !self.button_down) {
            // Button just pressed
            self.button_down = true;
            self.button_down_time = event.timestamp;
            self.last_button = event.buttons;
            self.long_press_fired = false;
        } else if (!any_pressed and self.button_down) {
            // Button just released
            self.button_down = false;
            self.button_up_time = event.timestamp;

            const press_duration = event.timestamp - self.button_down_time;

            if (!self.long_press_fired and press_duration < self.config.tap_max_ms) {
                // This was a tap
                if (self.tap_count == 1 and event.timestamp - self.button_up_time < self.config.double_tap_window_ms) {
                    self.tap_count = 0;
                    return .double_tap;
                } else {
                    self.tap_count = 1;
                    return .tap;
                }
            }
        } else if (self.button_down) {
            // Button being held
            const press_duration = event.timestamp - self.button_down_time;

            if (!self.long_press_fired and press_duration >= self.config.long_press_ms) {
                self.long_press_fired = true;
                return .long_press;
            }

            if (self.long_press_fired) {
                return .hold;
            }
        }

        // Reset tap count if window expired
        if (self.tap_count > 0 and event.timestamp - self.button_up_time > self.config.double_tap_window_ms) {
            self.tap_count = 0;
        }

        return gesture;
    }

    fn updateWheel(self: *GestureDetector, delta: i8, timestamp: u32) GestureType {
        const direction: i8 = if (delta > 0) 1 else -1;

        if (direction != self.wheel_direction) {
            // Direction changed - reset
            self.wheel_accumulator = 0;
            self.wheel_direction = direction;
        }

        self.wheel_accumulator += delta;
        self.wheel_last_time = timestamp;

        const abs_accum: u32 = @intCast(@abs(self.wheel_accumulator));

        if (abs_accum >= self.config.scrub_threshold) {
            // Scrub detected - reset and return
            self.wheel_accumulator = 0;
            return if (direction > 0) .scrub_cw else .scrub_ccw;
        }

        return .none;
    }

    /// Reset all gesture state
    pub fn reset(self: *GestureDetector) void {
        self.button_down = false;
        self.tap_count = 0;
        self.long_press_fired = false;
        self.wheel_accumulator = 0;
        self.wheel_direction = 0;
    }

    /// Get the button that triggered the last gesture
    pub fn getLastButton(self: *const GestureDetector) u8 {
        return self.last_button;
    }
};

/// Create a gesture detector
pub fn createGestureDetector() GestureDetector {
    return GestureDetector{};
}

// ============================================================
// Wheel Pattern Detection
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

test "wheel accelerator base speed" {
    var accel = createWheelAccelerator();

    // At slow speeds, should return approximately the input delta
    const result = accel.update(5, 0);
    // Base multiplier is 256 (1.0x), so result should be ~5
    try std.testing.expectEqual(@as(i16, 5), result);
}

test "wheel accelerator velocity buildup" {
    var accel = createWheelAccelerator();

    // Simulate fast spinning (many deltas in quick succession)
    _ = accel.update(10, 0);
    _ = accel.update(10, 20);
    _ = accel.update(10, 40);
    const result = accel.update(10, 60);

    // After velocity builds up, multiplier should increase
    // Velocity should be around 500 positions/second (10 delta per 20ms)
    try std.testing.expect(accel.getVelocity() > 0);

    // Result should be >= 10 due to acceleration
    try std.testing.expect(result >= 10);
}

test "wheel accelerator decay" {
    var accel = createWheelAccelerator();

    // Build up velocity
    _ = accel.update(10, 0);
    _ = accel.update(10, 20);
    _ = accel.update(10, 40);
    _ = accel.update(10, 60);

    const before = accel.getMultiplier();

    // Wait for decay (simulate idle time > decay_ms)
    _ = accel.update(0, 500);

    // Multiplier should decay back toward base
    try std.testing.expect(accel.getMultiplier() <= before);
}

test "wheel accelerator reset" {
    var accel = createWheelAccelerator();

    // Build up velocity
    _ = accel.update(10, 0);
    _ = accel.update(10, 20);

    accel.reset();

    try std.testing.expectEqual(@as(u16, 256), accel.getMultiplier());
    try std.testing.expectEqual(@as(u32, 0), accel.getVelocity());
}

test "gesture detector tap" {
    var detector = createGestureDetector();

    // Press button
    var event = InputEvent{
        .buttons = Button.SELECT,
        .wheel_position = 0,
        .wheel_delta = 0,
        .timestamp = 0,
    };
    var gesture = detector.update(event);
    try std.testing.expectEqual(GestureDetector.GestureType.none, gesture);

    // Release within tap window
    event.buttons = 0;
    event.timestamp = 100;
    gesture = detector.update(event);
    try std.testing.expectEqual(GestureDetector.GestureType.tap, gesture);
}

test "gesture detector long press" {
    var detector = createGestureDetector();

    // Press button
    var event = InputEvent{
        .buttons = Button.MENU,
        .wheel_position = 0,
        .wheel_delta = 0,
        .timestamp = 0,
    };
    _ = detector.update(event);

    // Hold past long press threshold
    event.timestamp = 900;
    const gesture = detector.update(event);
    try std.testing.expectEqual(GestureDetector.GestureType.long_press, gesture);
}

test "gesture detector scrub" {
    var detector = createGestureDetector();

    // Accumulate wheel movement
    var event = InputEvent{
        .buttons = 0,
        .wheel_position = 0,
        .wheel_delta = 20,
        .timestamp = 0,
    };
    _ = detector.update(event);

    event.wheel_delta = 20;
    event.timestamp = 50;
    _ = detector.update(event);

    event.wheel_delta = 20;
    event.timestamp = 100;
    const gesture = detector.update(event);

    // 60 total delta should trigger scrub (threshold is 48)
    try std.testing.expectEqual(GestureDetector.GestureType.scrub_cw, gesture);
}

test "gesture detector reset" {
    var detector = createGestureDetector();

    // Press a button
    const event = InputEvent{
        .buttons = Button.SELECT,
        .wheel_position = 0,
        .wheel_delta = 0,
        .timestamp = 0,
    };
    _ = detector.update(event);

    detector.reset();
    try std.testing.expect(!detector.button_down);
    try std.testing.expectEqual(@as(i32, 0), detector.wheel_accumulator);
}
