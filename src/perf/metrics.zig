//! Performance Metrics
//!
//! Provides instrumentation for measuring and reporting performance:
//! - CPU usage per component (decode, resample, DSP, render)
//! - Memory high-water mark
//! - Buffer underruns/overruns
//! - Frame timing statistics
//!
//! Designed for ARM7TDMI with minimal overhead.

const std = @import("std");
const hal = @import("../hal/hal.zig");

// ============================================================
// Cycle Counter
// ============================================================

/// Simple cycle counter for profiling sections of code
pub const CycleCounter = struct {
    start_time: u64,
    total_cycles: u64,
    call_count: u64,
    min_cycles: u64,
    max_cycles: u64,

    pub fn init() CycleCounter {
        return CycleCounter{
            .start_time = 0,
            .total_cycles = 0,
            .call_count = 0,
            .min_cycles = std.math.maxInt(u64),
            .max_cycles = 0,
        };
    }

    /// Start measuring
    pub fn start(self: *CycleCounter) void {
        self.start_time = hal.getTicksUs();
    }

    /// Stop measuring and record
    pub fn stop(self: *CycleCounter) void {
        const end_time = hal.getTicksUs();
        const elapsed = end_time -% self.start_time;

        self.total_cycles += elapsed;
        self.call_count += 1;

        if (elapsed < self.min_cycles) {
            self.min_cycles = elapsed;
        }
        if (elapsed > self.max_cycles) {
            self.max_cycles = elapsed;
        }
    }

    /// Get average cycles per call
    pub fn average(self: *const CycleCounter) u64 {
        if (self.call_count == 0) return 0;
        return self.total_cycles / self.call_count;
    }

    /// Reset all counters
    pub fn reset(self: *CycleCounter) void {
        self.start_time = 0;
        self.total_cycles = 0;
        self.call_count = 0;
        self.min_cycles = std.math.maxInt(u64);
        self.max_cycles = 0;
    }
};

// ============================================================
// Performance Metrics
// ============================================================

/// Comprehensive performance metrics for the audio/UI system
pub const PerfMetrics = struct {
    /// Decode stage timing (microseconds)
    decode: CycleCounter,
    /// Resample stage timing
    resample: CycleCounter,
    /// DSP effects timing
    dsp: CycleCounter,
    /// UI render timing
    render: CycleCounter,
    /// Main loop idle time
    idle: CycleCounter,

    /// Buffer underruns (audio starved)
    underruns: u32,
    /// Buffer overruns (buffer overflow)
    overruns: u32,

    /// Memory high-water mark (bytes)
    memory_peak: usize,
    /// Current memory usage (bytes)
    memory_current: usize,

    /// Frames rendered
    frames_rendered: u64,
    /// Frame time accumulator (microseconds)
    frame_time_total: u64,
    /// Frame time min (microseconds)
    frame_time_min: u64,
    /// Frame time max (microseconds)
    frame_time_max: u64,

    /// Last frame start time
    frame_start: u64,

    /// Total uptime in microseconds
    uptime_us: u64,

    /// Initialize metrics
    pub fn init() PerfMetrics {
        return PerfMetrics{
            .decode = CycleCounter.init(),
            .resample = CycleCounter.init(),
            .dsp = CycleCounter.init(),
            .render = CycleCounter.init(),
            .idle = CycleCounter.init(),
            .underruns = 0,
            .overruns = 0,
            .memory_peak = 0,
            .memory_current = 0,
            .frames_rendered = 0,
            .frame_time_total = 0,
            .frame_time_min = std.math.maxInt(u64),
            .frame_time_max = 0,
            .frame_start = 0,
            .uptime_us = 0,
        };
    }

    /// Start frame timing
    pub fn frameStart(self: *PerfMetrics) void {
        self.frame_start = hal.getTicksUs();
    }

    /// End frame timing
    pub fn frameEnd(self: *PerfMetrics) void {
        const now = hal.getTicksUs();
        const frame_time = now -% self.frame_start;

        self.frames_rendered += 1;
        self.frame_time_total += frame_time;

        if (frame_time < self.frame_time_min) {
            self.frame_time_min = frame_time;
        }
        if (frame_time > self.frame_time_max) {
            self.frame_time_max = frame_time;
        }

        self.uptime_us = now;
    }

    /// Record a buffer underrun
    pub fn recordUnderrun(self: *PerfMetrics) void {
        self.underruns += 1;
    }

    /// Record a buffer overrun
    pub fn recordOverrun(self: *PerfMetrics) void {
        self.overruns += 1;
    }

    /// Update memory usage
    pub fn updateMemory(self: *PerfMetrics, current: usize) void {
        self.memory_current = current;
        if (current > self.memory_peak) {
            self.memory_peak = current;
        }
    }

    /// Get average frame time in microseconds
    pub fn avgFrameTimeUs(self: *const PerfMetrics) u64 {
        if (self.frames_rendered == 0) return 0;
        return self.frame_time_total / self.frames_rendered;
    }

    /// Get frames per second
    pub fn fps(self: *const PerfMetrics) u32 {
        const avg = self.avgFrameTimeUs();
        if (avg == 0) return 0;
        return @intCast(1_000_000 / avg);
    }

    /// Get CPU usage estimate (0-100%)
    /// Based on time spent in active processing vs idle
    pub fn cpuUsagePercent(self: *const PerfMetrics) u8 {
        const active = self.decode.total_cycles + self.resample.total_cycles +
            self.dsp.total_cycles + self.render.total_cycles;
        const total = active + self.idle.total_cycles;

        if (total == 0) return 0;
        return @intCast(@min(100, (active * 100) / total));
    }

    /// Get audio CPU usage (decode + resample + dsp)
    pub fn audioCpuPercent(self: *const PerfMetrics) u8 {
        const audio = self.decode.total_cycles + self.resample.total_cycles +
            self.dsp.total_cycles;
        const total = audio + self.idle.total_cycles + self.render.total_cycles;

        if (total == 0) return 0;
        return @intCast(@min(100, (audio * 100) / total));
    }

    /// Get render CPU usage
    pub fn renderCpuPercent(self: *const PerfMetrics) u8 {
        const total = self.decode.total_cycles + self.resample.total_cycles +
            self.dsp.total_cycles + self.render.total_cycles + self.idle.total_cycles;

        if (total == 0) return 0;
        return @intCast(@min(100, (self.render.total_cycles * 100) / total));
    }

    /// Reset all metrics
    pub fn reset(self: *PerfMetrics) void {
        self.decode.reset();
        self.resample.reset();
        self.dsp.reset();
        self.render.reset();
        self.idle.reset();
        self.underruns = 0;
        self.overruns = 0;
        self.frames_rendered = 0;
        self.frame_time_total = 0;
        self.frame_time_min = std.math.maxInt(u64);
        self.frame_time_max = 0;
    }

    /// Format uptime as HH:MM:SS
    pub fn formatUptime(self: *const PerfMetrics, buf: []u8) []u8 {
        const secs = self.uptime_us / 1_000_000;
        const mins = secs / 60;
        const hours = mins / 60;
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{
            hours % 100,
            mins % 60,
            secs % 60,
        }) catch buf[0..0];
    }
};

// ============================================================
// Global Metrics Instance
// ============================================================

var global_metrics: PerfMetrics = PerfMetrics.init();

/// Get global metrics instance
pub fn getGlobal() *PerfMetrics {
    return &global_metrics;
}

/// Reset global metrics
pub fn resetGlobal() void {
    global_metrics.reset();
}

// ============================================================
// Profiling Macros/Helpers
// ============================================================

/// Profile a block of code
pub fn profile(counter: *CycleCounter, comptime func: anytype) @TypeOf(func()) {
    counter.start();
    defer counter.stop();
    return func();
}

// ============================================================
// Metrics Report
// ============================================================

/// Generate a text report of current metrics
pub const MetricsReport = struct {
    buffer: [512]u8,
    len: usize,

    pub fn generate(metrics: *const PerfMetrics) MetricsReport {
        var report = MetricsReport{
            .buffer = undefined,
            .len = 0,
        };

        var uptime_buf: [16]u8 = undefined;
        const uptime_str = metrics.formatUptime(&uptime_buf);

        report.len = (std.fmt.bufPrint(&report.buffer,
            \\Performance Report
            \\------------------
            \\Uptime: {s}
            \\Frames: {d}
            \\FPS: {d}
            \\
            \\CPU Usage:
            \\  Total: {d}%
            \\  Audio: {d}%
            \\  Render: {d}%
            \\
            \\Audio Timing (us):
            \\  Decode: {d} avg
            \\  Resample: {d} avg
            \\  DSP: {d} avg
            \\
            \\Buffer Health:
            \\  Underruns: {d}
            \\  Overruns: {d}
            \\
            \\Memory:
            \\  Current: {d} KB
            \\  Peak: {d} KB
        , .{
            uptime_str,
            metrics.frames_rendered,
            metrics.fps(),
            metrics.cpuUsagePercent(),
            metrics.audioCpuPercent(),
            metrics.renderCpuPercent(),
            metrics.decode.average(),
            metrics.resample.average(),
            metrics.dsp.average(),
            metrics.underruns,
            metrics.overruns,
            metrics.memory_current / 1024,
            metrics.memory_peak / 1024,
        }) catch &report.buffer).len;

        return report;
    }

    pub fn asSlice(self: *const MetricsReport) []const u8 {
        return self.buffer[0..self.len];
    }
};

// ============================================================
// Tests
// ============================================================

test "cycle counter" {
    var counter = CycleCounter.init();

    counter.start();
    // Simulate some work
    var sum: u32 = 0;
    for (0..1000) |i| {
        sum +%= @intCast(i);
    }
    std.mem.doNotOptimizeAway(&sum);
    counter.stop();

    try std.testing.expect(counter.call_count == 1);
    try std.testing.expect(counter.total_cycles > 0);
}

test "perf metrics initialization" {
    const metrics = PerfMetrics.init();

    try std.testing.expectEqual(@as(u32, 0), metrics.underruns);
    try std.testing.expectEqual(@as(u32, 0), metrics.overruns);
    try std.testing.expectEqual(@as(u64, 0), metrics.frames_rendered);
}

test "perf metrics frame timing" {
    var metrics = PerfMetrics.init();

    metrics.frameStart();
    // Simulate frame work
    var sum: u32 = 0;
    for (0..100) |i| {
        sum +%= @intCast(i);
    }
    std.mem.doNotOptimizeAway(&sum);
    metrics.frameEnd();

    try std.testing.expectEqual(@as(u64, 1), metrics.frames_rendered);
    // Note: frame_time_total may be 0 on fast systems, so we just verify the counter incremented
}

test "perf metrics underrun tracking" {
    var metrics = PerfMetrics.init();

    metrics.recordUnderrun();
    metrics.recordUnderrun();
    metrics.recordUnderrun();

    try std.testing.expectEqual(@as(u32, 3), metrics.underruns);
}

test "perf metrics memory tracking" {
    var metrics = PerfMetrics.init();

    metrics.updateMemory(1024);
    try std.testing.expectEqual(@as(usize, 1024), metrics.memory_current);
    try std.testing.expectEqual(@as(usize, 1024), metrics.memory_peak);

    metrics.updateMemory(2048);
    try std.testing.expectEqual(@as(usize, 2048), metrics.memory_peak);

    metrics.updateMemory(512);
    try std.testing.expectEqual(@as(usize, 512), metrics.memory_current);
    try std.testing.expectEqual(@as(usize, 2048), metrics.memory_peak);
}

test "perf metrics reset" {
    var metrics = PerfMetrics.init();

    metrics.recordUnderrun();
    metrics.recordOverrun();
    metrics.frameStart();
    metrics.frameEnd();

    metrics.reset();

    try std.testing.expectEqual(@as(u32, 0), metrics.underruns);
    try std.testing.expectEqual(@as(u32, 0), metrics.overruns);
    try std.testing.expectEqual(@as(u64, 0), metrics.frames_rendered);
}

test "global metrics" {
    resetGlobal();
    const metrics = getGlobal();

    metrics.recordUnderrun();
    try std.testing.expectEqual(@as(u32, 1), metrics.underruns);

    resetGlobal();
    try std.testing.expectEqual(@as(u32, 0), metrics.underruns);
}

test "metrics report generation" {
    var metrics = PerfMetrics.init();
    metrics.frames_rendered = 100;

    const report = MetricsReport.generate(&metrics);
    const text = report.asSlice();

    try std.testing.expect(text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "Performance Report") != null);
}

test "uptime formatting" {
    var metrics = PerfMetrics.init();
    metrics.uptime_us = 3661_000_000; // 1 hour, 1 minute, 1 second

    var buf: [16]u8 = undefined;
    const uptime = metrics.formatUptime(&buf);

    try std.testing.expectEqualStrings("01:01:01", uptime);
}
