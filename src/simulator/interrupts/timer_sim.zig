//! PP5021C Timer Simulation
//!
//! Simulates the PP5021C hardware timers.
//! The PP5021C has two programmable timers plus a microsecond counter.

const std = @import("std");
const interrupt_controller = @import("interrupt_controller.zig");

const InterruptController = interrupt_controller.InterruptController;
const InterruptSource = interrupt_controller.InterruptSource;

/// Timer configuration bits
pub const TimerConfig = struct {
    pub const ENABLE: u32 = 0x80000000;
    pub const REPEAT: u32 = 0x40000000;
    pub const IRQ_ENABLE: u32 = 0x20000000;

    /// Extract count value from config register
    pub fn getCount(cfg: u32) u32 {
        return cfg & 0x0FFFFFFF;
    }
};

/// Timer callback function type
pub const TimerCallback = *const fn (timer_id: u2, context: ?*anyopaque) void;

/// Single timer state
pub const Timer = struct {
    /// Configuration register
    cfg: u32 = 0,
    /// Current counter value
    value: u32 = 0,
    /// Reload value (from cfg)
    reload: u32 = 0,
    /// User callback
    callback: ?TimerCallback = null,
    /// Callback context
    context: ?*anyopaque = null,
    /// Accumulated time since last tick (nanoseconds)
    accumulated_ns: u64 = 0,

    const Self = @This();

    /// Check if timer is enabled
    pub fn isEnabled(self: *const Self) bool {
        return (self.cfg & TimerConfig.ENABLE) != 0;
    }

    /// Check if timer repeats
    pub fn isRepeat(self: *const Self) bool {
        return (self.cfg & TimerConfig.REPEAT) != 0;
    }

    /// Check if IRQ is enabled
    pub fn irqEnabled(self: *const Self) bool {
        return (self.cfg & TimerConfig.IRQ_ENABLE) != 0;
    }

    /// Configure the timer
    pub fn configure(self: *Self, cfg: u32) void {
        self.cfg = cfg;
        self.reload = TimerConfig.getCount(cfg);
        if ((cfg & TimerConfig.ENABLE) != 0) {
            self.value = self.reload;
        }
    }

    /// Set callback
    pub fn setCallback(self: *Self, callback: TimerCallback, context: ?*anyopaque) void {
        self.callback = callback;
        self.context = context;
    }

    /// Clear callback
    pub fn clearCallback(self: *Self) void {
        self.callback = null;
        self.context = null;
    }

    /// Stop the timer
    pub fn stop(self: *Self) void {
        self.cfg &= ~TimerConfig.ENABLE;
    }

    /// Read current value
    pub fn readValue(self: *const Self) u32 {
        return self.value;
    }
};

/// PP5021C Timer System
pub const TimerSystem = struct {
    /// Timer 1
    timer1: Timer = .{},
    /// Timer 2
    timer2: Timer = .{},
    /// Microsecond timer (free-running)
    usec_timer: u64 = 0,
    /// RTC seconds counter
    rtc: u32 = 0,
    /// Timer frequency (1 MHz)
    timer_freq: u32 = 1_000_000,
    /// Reference to interrupt controller
    interrupt_controller: ?*InterruptController = null,
    /// Accumulated nanoseconds for microsecond timer
    usec_accum_ns: u64 = 0,
    /// Accumulated microseconds for RTC
    rtc_accum_us: u64 = 0,

    const Self = @This();

    /// Create timer system
    pub fn init() Self {
        return .{};
    }

    /// Connect to interrupt controller
    pub fn connectInterruptController(self: *Self, ic: *InterruptController) void {
        self.interrupt_controller = ic;
    }

    /// Reset all timers
    pub fn reset(self: *Self) void {
        self.timer1 = .{};
        self.timer2 = .{};
        self.usec_timer = 0;
        self.rtc = 0;
        self.usec_accum_ns = 0;
        self.rtc_accum_us = 0;
    }

    /// Tick the timer system (advance by elapsed nanoseconds)
    pub fn tick(self: *Self, elapsed_ns: u64) void {
        // Update microsecond timer
        self.usec_accum_ns += elapsed_ns;
        const us_ticks = self.usec_accum_ns / 1000;
        self.usec_accum_ns %= 1000;
        self.usec_timer += us_ticks;

        // Update RTC (seconds)
        self.rtc_accum_us += us_ticks;
        const sec_ticks = self.rtc_accum_us / 1_000_000;
        self.rtc_accum_us %= 1_000_000;
        self.rtc +%= @intCast(sec_ticks);

        // Update timer 1
        self.updateTimer(&self.timer1, us_ticks, 0);

        // Update timer 2
        self.updateTimer(&self.timer2, us_ticks, 1);
    }

    /// Update a single timer
    fn updateTimer(self: *Self, timer: *Timer, us_ticks: u64, timer_id: u2) void {
        if (!timer.isEnabled()) return;

        timer.accumulated_ns += us_ticks * 1000;

        // Each timer tick is 1us (at 1MHz)
        const timer_ticks = timer.accumulated_ns / 1000;
        timer.accumulated_ns %= 1000;

        if (timer_ticks == 0) return;

        // Decrement counter
        const ticks_u32: u32 = @intCast(@min(timer_ticks, 0xFFFFFFFF));
        if (timer.value <= ticks_u32) {
            // Timer expired
            timer.value = 0;

            // Invoke callback
            if (timer.callback) |cb| {
                cb(timer_id, timer.context);
            }

            // Raise interrupt if enabled
            if (timer.irqEnabled()) {
                if (self.interrupt_controller) |ic| {
                    const src: InterruptSource = if (timer_id == 0) .timer1 else .timer2;
                    ic.raiseInterrupt(src);
                }
            }

            // Reload if repeat mode
            if (timer.isRepeat()) {
                timer.value = timer.reload;
            } else {
                timer.stop();
            }
        } else {
            timer.value -= ticks_u32;
        }
    }

    /// Configure timer 1
    pub fn configureTimer1(self: *Self, cfg: u32) void {
        self.timer1.configure(cfg);
    }

    /// Configure timer 2
    pub fn configureTimer2(self: *Self, cfg: u32) void {
        self.timer2.configure(cfg);
    }

    /// Read timer 1 value
    pub fn readTimer1(self: *const Self) u32 {
        return self.timer1.readValue();
    }

    /// Read timer 2 value
    pub fn readTimer2(self: *const Self) u32 {
        return self.timer2.readValue();
    }

    /// Read microsecond timer
    pub fn readUsecTimer(self: *const Self) u64 {
        return self.usec_timer;
    }

    /// Read RTC
    pub fn readRtc(self: *const Self) u32 {
        return self.rtc;
    }

    /// Set RTC (for initialization)
    pub fn setRtc(self: *Self, value: u32) void {
        self.rtc = value;
    }

    /// Stop timer 1
    pub fn stopTimer1(self: *Self) void {
        self.timer1.stop();
    }

    /// Stop timer 2
    pub fn stopTimer2(self: *Self) void {
        self.timer2.stop();
    }

    /// Set timer 1 callback
    pub fn setTimer1Callback(self: *Self, callback: TimerCallback, context: ?*anyopaque) void {
        self.timer1.setCallback(callback, context);
    }

    /// Set timer 2 callback
    pub fn setTimer2Callback(self: *Self, callback: TimerCallback, context: ?*anyopaque) void {
        self.timer2.setCallback(callback, context);
    }

    // --------------------------------------------------------
    // Memory-mapped register access
    // --------------------------------------------------------

    /// Read timer 1 config
    pub fn readTimer1Cfg(self: *const Self) u32 {
        return self.timer1.cfg;
    }

    /// Write timer 1 config
    pub fn writeTimer1Cfg(self: *Self, value: u32) void {
        self.configureTimer1(value);
    }

    /// Read timer 2 config
    pub fn readTimer2Cfg(self: *const Self) u32 {
        return self.timer2.cfg;
    }

    /// Write timer 2 config
    pub fn writeTimer2Cfg(self: *Self, value: u32) void {
        self.configureTimer2(value);
    }
};

// ============================================================
// Tests
// ============================================================

test "timer config parsing" {
    try std.testing.expectEqual(@as(u32, 0x01234567), TimerConfig.getCount(0x81234567));
    try std.testing.expect((TimerConfig.ENABLE & 0x80000000) != 0);
}

test "timer enable and tick" {
    var ts = TimerSystem.init();

    // Configure timer1 for 1000us with repeat
    ts.configureTimer1(TimerConfig.ENABLE | TimerConfig.REPEAT | 1000);

    try std.testing.expect(ts.timer1.isEnabled());
    try std.testing.expect(ts.timer1.isRepeat());
    try std.testing.expectEqual(@as(u32, 1000), ts.timer1.value);

    // Tick 500us (500,000 ns)
    ts.tick(500_000);
    try std.testing.expectEqual(@as(u32, 500), ts.timer1.value);

    // Tick another 600us - should wrap
    ts.tick(600_000);
    // Timer should have reloaded
    try std.testing.expect(ts.timer1.value <= 1000);
}

test "timer one-shot" {
    var ts = TimerSystem.init();

    // Configure timer1 for 100us one-shot
    ts.configureTimer1(TimerConfig.ENABLE | 100);

    try std.testing.expect(!ts.timer1.isRepeat());

    // Tick past expiry
    ts.tick(150_000); // 150us

    // Timer should be disabled
    try std.testing.expect(!ts.timer1.isEnabled());
}

test "timer callback" {
    var ts = TimerSystem.init();

    const Context = struct {
        count: u32 = 0,
    };
    var ctx = Context{};

    const callback = struct {
        fn cb(_: u2, opaque_ctx: ?*anyopaque) void {
            if (opaque_ctx) |c| {
                const context: *Context = @ptrCast(@alignCast(c));
                context.count += 1;
            }
        }
    }.cb;

    ts.timer1.setCallback(callback, &ctx);
    ts.configureTimer1(TimerConfig.ENABLE | TimerConfig.REPEAT | 100);

    // Tick 250us - should expire twice
    ts.tick(250_000);

    try std.testing.expect(ctx.count >= 2);
}

test "timer interrupt" {
    var ts = TimerSystem.init();
    var ic = InterruptController.init();
    ts.connectInterruptController(&ic);

    // Configure timer1 with IRQ enabled
    ts.configureTimer1(TimerConfig.ENABLE | TimerConfig.IRQ_ENABLE | 50);

    // Tick past expiry
    ts.tick(100_000);

    // Should have raised timer1 interrupt
    try std.testing.expect((ic.cpu.status & InterruptSource.timer1.mask()) != 0);
}

test "microsecond timer" {
    var ts = TimerSystem.init();

    ts.tick(5_000_000); // 5ms

    try std.testing.expectEqual(@as(u64, 5000), ts.readUsecTimer());
}

test "rtc counter" {
    var ts = TimerSystem.init();

    // Set initial RTC
    ts.setRtc(1000);

    // Tick 2.5 seconds
    ts.tick(2_500_000_000); // 2.5s in ns

    try std.testing.expectEqual(@as(u32, 1002), ts.readRtc());
}

test "stop timer" {
    var ts = TimerSystem.init();

    ts.configureTimer1(TimerConfig.ENABLE | TimerConfig.REPEAT | 1000);
    try std.testing.expect(ts.timer1.isEnabled());

    ts.stopTimer1();
    try std.testing.expect(!ts.timer1.isEnabled());
}

test "memory mapped access" {
    var ts = TimerSystem.init();

    ts.writeTimer1Cfg(TimerConfig.ENABLE | 500);
    try std.testing.expectEqual(@as(u32, 500), ts.readTimer1());

    ts.writeTimer2Cfg(TimerConfig.ENABLE | 300);
    try std.testing.expectEqual(@as(u32, 300), ts.readTimer2());
}
