//! Unified Logging System
//!
//! Routes log messages to the appropriate destination:
//! - USB CDC: Real-time streaming when connected to computer
//! - Disk: Persistent storage when not connected
//! - Both: Critical events always go to both
//!
//! Log levels:
//! - TRACE: Verbose debugging (CDC only, if enabled)
//! - DEBUG: Detailed debugging info
//! - INFO:  Normal operation events
//! - WARN:  Potential issues
//! - ERROR: Failures that are handled
//! - FATAL: Unrecoverable errors (triggers crash store)
//!
//! Usage:
//!   const log = @import("debug/logger.zig");
//!   log.info("Audio started at {d}Hz", .{sample_rate});
//!   log.err("Failed to open file: {s}", .{path});
//!   log.fatal("Stack overflow detected", .{});

const std = @import("std");
const usb_cdc = @import("../drivers/usb_cdc.zig");
const disk_telemetry = @import("disk_telemetry.zig");
const telemetry = @import("telemetry.zig");
const crash_store = @import("crash_store.zig");

// ============================================================
// Configuration
// ============================================================

/// Log level
pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn toColor(self: Level) []const u8 {
        return switch (self) {
            .trace => "\x1b[90m", // Gray
            .debug => "\x1b[36m", // Cyan
            .info => "\x1b[32m", // Green
            .warn => "\x1b[33m", // Yellow
            .err => "\x1b[31m", // Red
            .fatal => "\x1b[35m", // Magenta
        };
    }
};

/// Log category for filtering
pub const Category = enum(u8) {
    system = 0,
    audio = 1,
    storage = 2,
    ui = 3,
    power = 4,
    usb = 5,
    input = 6,
    network = 7, // Future
    dma_audio = 8, // DMA audio pipeline
    custom = 255,

    pub fn toString(self: Category) []const u8 {
        return switch (self) {
            .system => "SYS",
            .audio => "AUD",
            .storage => "STO",
            .ui => "UI ",
            .power => "PWR",
            .usb => "USB",
            .input => "INP",
            .network => "NET",
            .dma_audio => "DMA",
            .custom => "USR",
        };
    }
};

/// Logger configuration
pub const Config = struct {
    /// Minimum level to log
    min_level: Level = .info,

    /// Enable colored output (for terminal)
    colors: bool = true,

    /// Enable timestamps
    timestamps: bool = true,

    /// Enable category prefix
    categories: bool = true,

    /// Log to USB CDC when available
    cdc_enabled: bool = true,

    /// Log to disk
    disk_enabled: bool = true,

    /// Flush to disk after each critical log
    immediate_flush: bool = true,

    /// Category filter (null = all)
    category_filter: ?Category = null,
};

// ============================================================
// Global State
// ============================================================

var config: Config = .{};
var initialized: bool = false;
var boot_time_ms: u64 = 0;
var log_count: u64 = 0;

// Message buffer for formatting
var msg_buffer: [512]u8 = undefined;

// ============================================================
// Initialization
// ============================================================

/// Initialize the logging system
pub fn init() void {
    if (initialized) return;

    // Initialize subsystems
    telemetry.init();
    disk_telemetry.init() catch {};
    crash_store.init() catch {};

    // Get boot time for relative timestamps
    boot_time_ms = 0; // TODO: Read from timer

    initialized = true;

    // Log startup
    info(.system, "Logger initialized", .{});

    // Check for crashes from previous boot
    if (crash_store.hasPendingCrashes()) {
        warn(.system, "Crashes from previous boot detected - check /ZIGPOD/LOGS/crashes/", .{});
    }
}

/// Update logger configuration
pub fn configure(new_config: Config) void {
    config = new_config;
}

/// Get current configuration
pub fn getConfig() Config {
    return config;
}

// ============================================================
// Core Logging Functions
// ============================================================

/// Log with explicit level and category
pub fn log(level: Level, category: Category, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) < @intFromEnum(config.min_level)) return;
    if (config.category_filter) |filter| {
        if (category != filter) return;
    }

    // Format the message
    const msg = std.fmt.bufPrint(&msg_buffer, fmt, args) catch fmt;

    // Build the full log line
    var line_buf: [640]u8 = undefined;
    var line_len: usize = 0;

    // Timestamp
    if (config.timestamps) {
        const elapsed = getElapsedMs();
        const ts = std.fmt.bufPrint(line_buf[line_len..], "[{d:>8}] ", .{elapsed}) catch "";
        line_len += ts.len;
    }

    // Level (with optional color)
    if (config.colors and usb_cdc.isConnected()) {
        const color = level.toColor();
        @memcpy(line_buf[line_len .. line_len + color.len], color);
        line_len += color.len;
    }

    const level_str = level.toString();
    @memcpy(line_buf[line_len .. line_len + level_str.len], level_str);
    line_len += level_str.len;

    if (config.colors and usb_cdc.isConnected()) {
        const reset = "\x1b[0m";
        @memcpy(line_buf[line_len .. line_len + reset.len], reset);
        line_len += reset.len;
    }

    // Category
    if (config.categories) {
        const cat = std.fmt.bufPrint(line_buf[line_len..], " [{s}]", .{category.toString()}) catch "";
        line_len += cat.len;
    }

    // Space before message
    line_buf[line_len] = ' ';
    line_len += 1;

    // Message
    const msg_end = @min(line_len + msg.len, line_buf.len - 2);
    @memcpy(line_buf[line_len..msg_end], msg[0 .. msg_end - line_len]);
    line_len = msg_end;

    // Newline
    line_buf[line_len] = '\n';
    line_len += 1;

    const line = line_buf[0..line_len];

    // Route to destinations
    routeLog(level, category, line, msg);

    log_count += 1;
}

/// Route log to appropriate destinations
fn routeLog(level: Level, category: Category, line: []const u8, msg: []const u8) void {
    // Always record in telemetry for critical logs
    if (@intFromEnum(level) >= @intFromEnum(Level.warn)) {
        const event_type: telemetry.EventType = switch (level) {
            .warn => .debug_print,
            .err => .error_recorded,
            .fatal => .panic,
            else => .debug_print,
        };
        telemetry.record(event_type, @intFromEnum(category), 0);
    }

    // USB CDC - real-time
    if (config.cdc_enabled and usb_cdc.isConnected()) {
        _ = usb_cdc.write(line);
    }

    // Disk - persistent
    if (config.disk_enabled) {
        disk_telemetry.logRaw(line);

        // Immediate flush for errors
        if (config.immediate_flush and @intFromEnum(level) >= @intFromEnum(Level.err)) {
            disk_telemetry.flush();
        }
    }

    // Fatal - record in crash store
    if (level == .fatal) {
        const pc = getProgramCounter();
        crash_store.recordCrash(.panic, pc, 0, 0, 0, 0, msg);
    }
}

/// Get program counter (ARM only, returns 0 on other platforms)
fn getProgramCounter() u32 {
    const builtin = @import("builtin");
    if (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb) {
        var pc: u32 = 0;
        asm volatile ("mov %[pc], pc"
            : [pc] "=r" (pc)
        );
        return pc;
    }
    return 0; // Not available on non-ARM
}

// ============================================================
// Convenience Functions (by level)
// ============================================================

/// Trace level (verbose debugging)
pub fn trace(category: Category, comptime fmt: []const u8, args: anytype) void {
    log(.trace, category, fmt, args);
}

/// Debug level
pub fn debug(category: Category, comptime fmt: []const u8, args: anytype) void {
    log(.debug, category, fmt, args);
}

/// Info level (normal events)
pub fn info(category: Category, comptime fmt: []const u8, args: anytype) void {
    log(.info, category, fmt, args);
}

/// Warning level
pub fn warn(category: Category, comptime fmt: []const u8, args: anytype) void {
    log(.warn, category, fmt, args);
}

/// Error level
pub fn err(category: Category, comptime fmt: []const u8, args: anytype) void {
    log(.err, category, fmt, args);
}

/// Fatal level (triggers crash store)
pub fn fatal(category: Category, comptime fmt: []const u8, args: anytype) void {
    log(.fatal, category, fmt, args);
}

// ============================================================
// Scoped Loggers (for modules)
// ============================================================

/// Create a scoped logger for a specific category
pub fn scoped(comptime category: Category) type {
    return struct {
        pub fn trace(comptime fmt: []const u8, args: anytype) void {
            log(.trace, category, fmt, args);
        }

        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            log(.debug, category, fmt, args);
        }

        pub fn info(comptime fmt: []const u8, args: anytype) void {
            log(.info, category, fmt, args);
        }

        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            log(.warn, category, fmt, args);
        }

        pub fn err(comptime fmt: []const u8, args: anytype) void {
            log(.err, category, fmt, args);
        }

        pub fn fatal(comptime fmt: []const u8, args: anytype) void {
            log(.fatal, category, fmt, args);
        }
    };
}

// Pre-defined scoped loggers
pub const system = scoped(.system);
pub const audio = scoped(.audio);
pub const storage = scoped(.storage);
pub const ui = scoped(.ui);
pub const power = scoped(.power);
pub const usb = scoped(.usb);
pub const input = scoped(.input);

// ============================================================
// Special Logging Functions
// ============================================================

/// Log a hexdump
pub fn hexdump(category: Category, data: []const u8, label: []const u8) void {
    if (@intFromEnum(Level.debug) < @intFromEnum(config.min_level)) return;

    debug(category, "Hexdump: {s} ({d} bytes)", .{ label, data.len });

    var offset: usize = 0;
    while (offset < data.len) {
        var line: [80]u8 = undefined;
        var pos: usize = 0;

        // Offset
        const off_str = std.fmt.bufPrint(line[pos..], "{X:0>4}: ", .{offset}) catch "";
        pos += off_str.len;

        // Hex bytes
        var i: usize = 0;
        while (i < 16 and offset + i < data.len) : (i += 1) {
            const hex = std.fmt.bufPrint(line[pos..], "{X:0>2} ", .{data[offset + i]}) catch "";
            pos += hex.len;
        }

        // Padding
        while (i < 16) : (i += 1) {
            @memcpy(line[pos .. pos + 3], "   ");
            pos += 3;
        }

        // ASCII
        line[pos] = '|';
        pos += 1;
        i = 0;
        while (i < 16 and offset + i < data.len) : (i += 1) {
            const c = data[offset + i];
            line[pos] = if (c >= 0x20 and c < 0x7F) c else '.';
            pos += 1;
        }
        line[pos] = '|';
        pos += 1;

        debug(category, "{s}", .{line[0..pos]});
        offset += 16;
    }
}

/// Log a performance measurement
pub fn perfMark(category: Category, comptime name: []const u8, duration_us: u32) void {
    debug(category, "PERF {s}: {d}us", .{ name, duration_us });
    telemetry.record(.perf_mark_end, 0, duration_us);
}

/// Log with assertion (fatal if condition false)
pub fn assert(condition: bool, category: Category, comptime fmt: []const u8, args: anytype) void {
    if (!condition) {
        fatal(category, "ASSERTION FAILED: " ++ fmt, args);
    }
}

// ============================================================
// Control Functions
// ============================================================

/// Flush all logs to disk
pub fn flush() void {
    disk_telemetry.flush();
    usb_cdc.flush() catch {};
}

/// Shutdown logging (call before power off)
pub fn shutdown() void {
    info(.system, "Logger shutting down (logged {d} messages)", .{log_count});
    flush();
    disk_telemetry.shutdown();
}

/// Get elapsed time since boot
fn getElapsedMs() u64 {
    // TODO: Read from hardware timer
    return 0;
}

/// Get total log count
pub fn getLogCount() u64 {
    return log_count;
}

// ============================================================
// Tests
// ============================================================

test "log level ordering" {
    try std.testing.expect(@intFromEnum(Level.trace) < @intFromEnum(Level.debug));
    try std.testing.expect(@intFromEnum(Level.debug) < @intFromEnum(Level.info));
    try std.testing.expect(@intFromEnum(Level.info) < @intFromEnum(Level.warn));
    try std.testing.expect(@intFromEnum(Level.warn) < @intFromEnum(Level.err));
    try std.testing.expect(@intFromEnum(Level.err) < @intFromEnum(Level.fatal));
}

test "level to string" {
    try std.testing.expectEqualStrings("INFO ", Level.info.toString());
    try std.testing.expectEqualStrings("ERROR", Level.err.toString());
}

test "category to string" {
    try std.testing.expectEqualStrings("AUD", Category.audio.toString());
    try std.testing.expectEqualStrings("STO", Category.storage.toString());
}

test "scoped logger" {
    // Just verify it compiles
    const my_log = scoped(.audio);
    _ = my_log;
}

test "config defaults" {
    const c = Config{};
    try std.testing.expectEqual(Level.info, c.min_level);
    try std.testing.expect(c.cdc_enabled);
    try std.testing.expect(c.disk_enabled);
}
