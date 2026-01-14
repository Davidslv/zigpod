//! PP5021C Timers
//!
//! Implements Timer 1, Timer 2, USEC_TIMER (microsecond counter), and RTC.
//!
//! Reference: Rockbox firmware/export/pp5020.h
//!
//! Registers (base 0x60005000):
//! - 0x00: TIMER1_CFG - Config (bits 31:30 = enable/repeat, 28:0 = count)
//! - 0x04: TIMER1_VAL - Current value / write to acknowledge interrupt
//! - 0x08: TIMER2_CFG
//! - 0x0C: TIMER2_VAL
//! - 0x10: USEC_TIMER - Free-running microsecond counter (read-only)
//! - 0x14: RTC - Seconds counter (32-bit, read-only)
//!
//! Timer Configuration:
//! - Bit 31: Timer enabled
//! - Bit 30: Auto-repeat mode (1 = repeat, 0 = one-shot)
//! - Bits 28:0: Initial count value
//!
//! Timers run at 1MHz (1 tick per microsecond).

const std = @import("std");
const bus = @import("../memory/bus.zig");
const interrupt_ctrl = @import("interrupt_ctrl.zig");

/// Single timer state
const Timer = struct {
    config: u32,
    value: u32,
    cycles_accumulated: u64,

    const ENABLE_BIT: u32 = 1 << 31;
    const REPEAT_BIT: u32 = 1 << 30;
    const COUNT_MASK: u32 = 0x1FFFFFFF;

    pub fn init() Timer {
        return .{
            .config = 0,
            .value = 0,
            .cycles_accumulated = 0,
        };
    }

    pub fn isEnabled(self: *const Timer) bool {
        return (self.config & ENABLE_BIT) != 0;
    }

    pub fn isRepeat(self: *const Timer) bool {
        return (self.config & REPEAT_BIT) != 0;
    }

    pub fn getCount(self: *const Timer) u32 {
        return self.config & COUNT_MASK;
    }

    pub fn setConfig(self: *Timer, value: u32) void {
        self.config = value;
        // When config is written, reload the value
        self.value = value & COUNT_MASK;
        self.cycles_accumulated = 0;
    }

    /// Tick the timer and return true if it fired
    /// cpu_cycles: number of CPU cycles elapsed
    /// cpu_freq_mhz: CPU frequency in MHz
    pub fn tick(self: *Timer, cpu_cycles: u32, cpu_freq_mhz: u32) bool {
        if (!self.isEnabled()) return false;

        // Convert CPU cycles to microseconds
        // us = cycles / freq_mhz (since freq is in MHz)
        self.cycles_accumulated += cpu_cycles;

        const us = self.cycles_accumulated / cpu_freq_mhz;
        if (us == 0) return false;

        self.cycles_accumulated -= us * cpu_freq_mhz;

        // Decrement timer
        const us32: u32 = @truncate(@min(us, 0xFFFFFFFF));
        if (self.value > us32) {
            self.value -= us32;
            return false;
        }

        // Timer fired
        if (self.isRepeat()) {
            // Reload and continue
            const remainder = us32 - self.value;
            self.value = self.getCount();
            if (remainder < self.value) {
                self.value -= remainder;
            }
        } else {
            // One-shot: disable timer
            self.config &= ~ENABLE_BIT;
            self.value = 0;
        }

        return true;
    }

    /// Acknowledge interrupt (write to value register)
    pub fn acknowledge(self: *Timer) void {
        // Writing to value register acknowledges the interrupt
        // and reloads the value if in repeat mode
        if (self.isRepeat()) {
            self.value = self.getCount();
        }
    }
};

/// Timers peripheral
pub const Timers = struct {
    timer1: Timer,
    timer2: Timer,

    /// Free-running microsecond counter
    usec_timer: u32,

    /// RTC seconds counter
    rtc: u32,

    /// Debug: count of USEC_TIMER reads
    debug_usec_reads: u32,

    /// Accumulated cycles for USEC_TIMER
    usec_cycles: u64,

    /// Accumulated seconds for RTC
    rtc_usec: u64,

    /// CPU frequency in MHz
    cpu_freq_mhz: u32,

    /// Interrupt controller reference (for asserting interrupts)
    int_ctrl: ?*interrupt_ctrl.InterruptController,

    const Self = @This();

    /// Register offsets
    const REG_TIMER1_CFG: u32 = 0x00;
    const REG_TIMER1_VAL: u32 = 0x04;
    const REG_TIMER2_CFG: u32 = 0x08;
    const REG_TIMER2_VAL: u32 = 0x0C;
    const REG_USEC_TIMER: u32 = 0x10;
    const REG_RTC: u32 = 0x14;

    pub fn init(cpu_freq_mhz: u32) Self {
        return .{
            .timer1 = Timer.init(),
            .timer2 = Timer.init(),
            .usec_timer = 0,
            .rtc = 0,
            .debug_usec_reads = 0,
            .usec_cycles = 0,
            .rtc_usec = 0,
            .cpu_freq_mhz = cpu_freq_mhz,
            .int_ctrl = null,
        };
    }

    /// Set interrupt controller reference
    pub fn setInterruptController(self: *Self, ctrl: *interrupt_ctrl.InterruptController) void {
        self.int_ctrl = ctrl;
    }

    /// Tick all timers
    pub fn tick(self: *Self, cpu_cycles: u32) void {
        // Update USEC_TIMER
        self.usec_cycles += cpu_cycles;
        const us = self.usec_cycles / self.cpu_freq_mhz;
        if (us > 0) {
            self.usec_cycles -= us * self.cpu_freq_mhz;
            self.usec_timer +%= @truncate(@min(us, 0xFFFFFFFF));

            // Update RTC
            self.rtc_usec += us;
            const secs = self.rtc_usec / 1_000_000;
            if (secs > 0) {
                self.rtc_usec -= secs * 1_000_000;
                self.rtc +%= @truncate(@min(secs, 0xFFFFFFFF));
            }
        }

        // Tick Timer 1
        if (self.timer1.tick(cpu_cycles, self.cpu_freq_mhz)) {
            if (self.int_ctrl) |ctrl| {
                ctrl.assertInterrupt(.timer1);
                // Debug: print when Timer1 fires (only first 5 times)
                if (ctrl.debug_timer1_fires < 5) {
                    ctrl.debug_timer1_fires += 1;
                    std.debug.print("TIMER1_FIRE: #{} raw_status=0x{X:0>8} cpu_enable=0x{X:0>8}\n", .{
                        ctrl.debug_timer1_fires, ctrl.raw_status, ctrl.cpu_enable,
                    });
                }
            }
        }

        // Tick Timer 2
        if (self.timer2.tick(cpu_cycles, self.cpu_freq_mhz)) {
            if (self.int_ctrl) |ctrl| {
                ctrl.assertInterrupt(.timer2);
            }
        }
    }

    /// Force fire a timer1 IRQ (for RTOS kickstart debugging)
    pub fn forceTimerIrq(self: *Self) void {
        if (self.int_ctrl) |ctrl| {
            std.debug.print("TIMER: Forcing timer1 IRQ assertion\n", .{});
            ctrl.assertInterrupt(.timer1);
        } else {
            std.debug.print("TIMER: Cannot force IRQ - no interrupt controller\n", .{});
        }
    }

    /// Read register
    pub fn read(self: *const Self, offset: u32) u32 {
        const value = switch (offset) {
            REG_TIMER1_CFG => self.timer1.config,
            REG_TIMER1_VAL => self.timer1.value,
            REG_TIMER2_CFG => self.timer2.config,
            REG_TIMER2_VAL => self.timer2.value,
            REG_USEC_TIMER => self.usec_timer,
            REG_RTC => self.rtc,
            else => 0,
        };
        // Debug: trace USEC_TIMER reads
        if (offset == REG_USEC_TIMER) {
            const print = std.debug.print;
            // Only print first few and when value is high
            if (self.debug_usec_reads < 5 or value > 0x1000000) {
                print("USEC_TIMER READ: value=0x{X:0>8} usec_cycles={}\n", .{ value, self.usec_cycles });
            }
            // Increment counter using pointer cast to bypass const
            const self_mut = @constCast(self);
            self_mut.debug_usec_reads += 1;
        }
        return value;
    }

    /// Write register
    pub fn write(self: *Self, offset: u32, value: u32) void {
        switch (offset) {
            REG_TIMER1_CFG => {
                const enabled = (value & Timer.ENABLE_BIT) != 0;
                const repeat = (value & Timer.REPEAT_BIT) != 0;
                const count = value & Timer.COUNT_MASK;
                std.debug.print("TIMER1_CFG: value=0x{X:0>8} enabled={} repeat={} count={}\n", .{ value, enabled, repeat, count });
                self.timer1.setConfig(value);
            },
            REG_TIMER1_VAL => {
                self.timer1.acknowledge();
                if (self.int_ctrl) |ctrl| {
                    ctrl.clearInterrupt(.timer1);
                }
            },
            REG_TIMER2_CFG => self.timer2.setConfig(value),
            REG_TIMER2_VAL => {
                self.timer2.acknowledge();
                if (self.int_ctrl) |ctrl| {
                    ctrl.clearInterrupt(.timer2);
                }
            },
            REG_USEC_TIMER, REG_RTC => {}, // Read-only
            else => {},
        }
    }

    /// Create a peripheral handler for the memory bus
    pub fn createHandler(self: *Self) bus.PeripheralHandler {
        return .{
            .context = @ptrCast(self),
            .readFn = readWrapper,
            .writeFn = writeWrapper,
        };
    }

    fn readWrapper(ctx: *anyopaque, offset: u32) u32 {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        return self.read(offset);
    }

    fn writeWrapper(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.write(offset, value);
    }
};

// Tests
test "timer one-shot" {
    var timers = Timers.init(80); // 80 MHz

    // Set Timer 1 to fire after 1000 us (one-shot)
    timers.timer1.setConfig(1000 | Timer.ENABLE_BIT);

    // Tick 800 cycles at 80MHz = 10us
    var fired = timers.timer1.tick(800, 80);
    try std.testing.expect(!fired);
    try std.testing.expect(timers.timer1.value < 1000);

    // Tick enough to fire
    for (0..100) |_| {
        fired = timers.timer1.tick(800, 80);
        if (fired) break;
    }
    try std.testing.expect(fired);
    try std.testing.expect(!timers.timer1.isEnabled());
}

test "timer repeat" {
    var timers = Timers.init(80);

    // Set Timer 1 to fire after 100 us (repeat)
    timers.timer1.setConfig(100 | Timer.ENABLE_BIT | Timer.REPEAT_BIT);

    // Tick until fired
    var fired_count: u32 = 0;
    for (0..200) |_| {
        if (timers.timer1.tick(80, 80)) { // 1us per tick
            fired_count += 1;
        }
    }

    // Should have fired twice (200us / 100us = 2)
    try std.testing.expect(fired_count >= 2);
    try std.testing.expect(timers.timer1.isEnabled()); // Still enabled
}

test "usec timer" {
    var timers = Timers.init(80);

    const initial = timers.usec_timer;

    // Tick 800 cycles = 10us at 80MHz
    timers.tick(800);

    try std.testing.expectEqual(initial + 10, timers.usec_timer);
}

test "rtc update" {
    var timers = Timers.init(1); // 1 MHz for easy math

    const initial_rtc = timers.rtc;

    // Tick 2 million cycles = 2 seconds at 1MHz
    timers.tick(1_000_000);
    timers.tick(1_000_000);

    try std.testing.expectEqual(initial_rtc + 2, timers.rtc);
}
