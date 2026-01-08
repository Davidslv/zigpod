//! Timer and Delay Utilities
//!
//! This module provides timing functions for ZigPod OS.

const std = @import("std");
const hal = @import("../hal/hal.zig");

// ============================================================
// Delay Functions
// ============================================================

/// Delay for specified microseconds
pub inline fn delayUs(us: u32) void {
    hal.current_hal.delay_us(us);
}

/// Delay for specified milliseconds
pub inline fn delayMs(ms: u32) void {
    hal.current_hal.delay_ms(ms);
}

/// Delay for specified seconds
pub fn delaySec(sec: u32) void {
    var i: u32 = 0;
    while (i < sec) : (i += 1) {
        delayMs(1000);
    }
}

// ============================================================
// Time Measurement
// ============================================================

/// Get current time in microseconds
pub inline fn getTimeUs() u64 {
    return hal.current_hal.get_ticks_us();
}

/// Get current time in milliseconds
pub fn getTimeMs() u64 {
    return getTimeUs() / 1000;
}

/// Measure elapsed time since a start point
pub fn elapsedUs(start: u64) u64 {
    return getTimeUs() -% start;
}

pub fn elapsedMs(start: u64) u64 {
    return getTimeMs() -% start;
}

// ============================================================
// Timeout Handling
// ============================================================

/// Timeout helper for polling operations
pub const Timeout = struct {
    deadline: u64,

    /// Create a timeout with duration in microseconds
    pub fn initUs(duration_us: u64) Timeout {
        return .{ .deadline = getTimeUs() + duration_us };
    }

    /// Create a timeout with duration in milliseconds
    pub fn initMs(duration_ms: u64) Timeout {
        return initUs(duration_ms * 1000);
    }

    /// Check if timeout has expired
    pub fn expired(self: Timeout) bool {
        return getTimeUs() >= self.deadline;
    }

    /// Remaining time in microseconds (0 if expired)
    pub fn remainingUs(self: Timeout) u64 {
        const now = getTimeUs();
        if (now >= self.deadline) return 0;
        return self.deadline - now;
    }
};

// ============================================================
// Software Timers
// ============================================================

pub const TimerCallback = *const fn (user_data: ?*anyopaque) void;

pub const SoftwareTimer = struct {
    callback: ?TimerCallback = null,
    user_data: ?*anyopaque = null,
    period_us: u64 = 0,
    next_fire: u64 = 0,
    active: bool = false,
    one_shot: bool = false,

    /// Start the timer
    pub fn start(self: *SoftwareTimer, period_us: u64, one_shot: bool, callback: TimerCallback, user_data: ?*anyopaque) void {
        self.callback = callback;
        self.user_data = user_data;
        self.period_us = period_us;
        self.next_fire = getTimeUs() + period_us;
        self.one_shot = one_shot;
        self.active = true;
    }

    /// Stop the timer
    pub fn stop(self: *SoftwareTimer) void {
        self.active = false;
    }

    /// Check and fire if due (call this periodically)
    pub fn tick(self: *SoftwareTimer) void {
        if (!self.active) return;

        if (getTimeUs() >= self.next_fire) {
            if (self.callback) |cb| {
                cb(self.user_data);
            }

            if (self.one_shot) {
                self.active = false;
            } else {
                self.next_fire += self.period_us;
            }
        }
    }
};

// Global software timer pool
const MAX_SOFTWARE_TIMERS = 8;
var software_timers: [MAX_SOFTWARE_TIMERS]SoftwareTimer = [_]SoftwareTimer{.{}} ** MAX_SOFTWARE_TIMERS;

/// Allocate a software timer
pub fn allocTimer() ?*SoftwareTimer {
    for (&software_timers) |*timer| {
        if (!timer.active and timer.callback == null) {
            return timer;
        }
    }
    return null;
}

/// Process all software timers (call periodically from main loop)
pub fn processSoftwareTimers() void {
    for (&software_timers) |*timer| {
        timer.tick();
    }
}

// ============================================================
// Tests
// ============================================================

test "timeout" {
    const timeout = Timeout.initUs(1000);
    try std.testing.expect(!timeout.expired());
    try std.testing.expect(timeout.remainingUs() > 0);
}

test "software timer" {
    var timer = SoftwareTimer{};
    var called_count: u32 = 0;

    const callback = struct {
        fn cb(data: ?*anyopaque) void {
            if (data) |ptr| {
                const count: *u32 = @ptrCast(@alignCast(ptr));
                count.* += 1;
            }
        }
    }.cb;

    timer.start(1000, false, callback, @ptrCast(&called_count));
    try std.testing.expect(timer.active);
}
