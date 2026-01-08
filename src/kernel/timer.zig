//! Timer and Delay Utilities
//!
//! This module provides timing functions for ZigPod OS.
//! Includes both software timers and hardware timer configuration
//! for interrupt-driven timing on PP5021C.

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("../hal/hal.zig");
const interrupts = @import("interrupts.zig");

// Hardware register access (only for ARM target)
const is_arm = builtin.cpu.arch == .arm;
const reg = if (is_arm) @import("../hal/pp5021c/registers.zig") else struct {
    pub const TIMER1_CFG: usize = 0;
    pub const TIMER1_VAL: usize = 0;
    pub const TIMER2_CFG: usize = 0;
    pub const TIMER2_VAL: usize = 0;
    pub const CPU_INT_EN: usize = 0;
    pub const TIMER1_IRQ: u32 = 1;
    pub const TIMER2_IRQ: u32 = 2;
    pub const TIMER_FREQ: u32 = 1_000_000;
    pub fn readReg(comptime T: type, addr: usize) T {
        _ = addr;
        return 0;
    }
    pub fn writeReg(comptime T: type, addr: usize, value: T) void {
        _ = addr;
        _ = value;
    }
};

// ============================================================
// Hardware Timer Configuration (PP5021C)
// ============================================================

/// Timer configuration bits
const TIMER_EN: u32 = 0x80000000; // Timer enable
const TIMER_IRQ_EN: u32 = 0x40000000; // Interrupt enable
const TIMER_PERIODIC: u32 = 0x20000000; // Periodic mode (auto-reload)
const TIMER_CNT_MODE: u32 = 0x10000000; // Count mode

/// System tick counter (incremented by timer interrupt)
var system_ticks: u64 = 0;

/// Tick rate in Hz (default 1000 = 1ms ticks)
var tick_rate_hz: u32 = 1000;

/// Hardware timer callback
var hw_timer_callback: ?*const fn () void = null;

/// Initialize hardware timer 1 for system ticks
/// tick_hz: Number of ticks per second (e.g., 1000 for 1ms ticks)
pub fn initHardwareTimer(tick_hz: u32) void {
    if (!is_arm) return;

    tick_rate_hz = tick_hz;

    // Calculate reload value
    // Timer runs at TIMER_FREQ (1 MHz)
    // Reload = TIMER_FREQ / tick_hz
    const reload_value = reg.TIMER_FREQ / tick_hz;

    // Disable timer during configuration
    reg.writeReg(u32, reg.TIMER1_CFG, 0);

    // Set reload value
    reg.writeReg(u32, reg.TIMER1_VAL, reload_value);

    // Register our interrupt handler
    interrupts.register(.timer1, timer1IrqHandler);

    // Enable timer interrupt in interrupt controller
    const int_en = reg.readReg(u32, reg.CPU_INT_EN);
    reg.writeReg(u32, reg.CPU_INT_EN, int_en | reg.TIMER1_IRQ);

    // Enable timer with interrupt and periodic mode
    reg.writeReg(u32, reg.TIMER1_CFG, TIMER_EN | TIMER_IRQ_EN | TIMER_PERIODIC);
}

/// Stop hardware timer 1
pub fn stopHardwareTimer() void {
    if (!is_arm) return;

    // Disable timer
    reg.writeReg(u32, reg.TIMER1_CFG, 0);

    // Disable interrupt
    const int_en = reg.readReg(u32, reg.CPU_INT_EN);
    reg.writeReg(u32, reg.CPU_INT_EN, int_en & ~reg.TIMER1_IRQ);

    // Unregister handler
    interrupts.unregister(.timer1);
}

/// Set callback for hardware timer (called on each tick)
pub fn setTimerCallback(callback: ?*const fn () void) void {
    hw_timer_callback = callback;
}

/// Timer 1 interrupt handler
fn timer1IrqHandler() void {
    // Increment system tick counter
    system_ticks += 1;

    // Call user callback if registered
    if (hw_timer_callback) |cb| {
        cb();
    }

    // Process software timers
    processSoftwareTimers();
}

/// Get system tick count
pub fn getSystemTicks() u64 {
    return system_ticks;
}

/// Get tick rate in Hz
pub fn getTickRate() u32 {
    return tick_rate_hz;
}

/// Convert ticks to milliseconds
pub fn ticksToMs(ticks: u64) u64 {
    return (ticks * 1000) / tick_rate_hz;
}

/// Convert milliseconds to ticks
pub fn msToTicks(ms: u64) u64 {
    return (ms * tick_rate_hz) / 1000;
}

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
