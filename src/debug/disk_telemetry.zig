//! Disk-Based Telemetry for USB-Only Debugging
//!
//! Since JTAG is not accessible on iPod Classic 5.5G, this module stores
//! telemetry to the hard drive. After testing, connect via USB Disk Mode
//! and copy the log files for analysis.
//!
//! Log location: /ZIGPOD/LOGS/
//! Files:
//!   - telemetry.bin   (binary event buffer)
//!   - crash.log       (last crash info, human-readable)
//!   - boot.log        (boot sequence log)
//!
//! Workflow:
//!   1. Run ZigPod on hardware
//!   2. Test features, trigger issues
//!   3. Shut down cleanly (or let it crash)
//!   4. Hold Menu+Select to reboot into Apple firmware
//!   5. Connect USB, mount as Disk Mode
//!   6. Copy /ZIGPOD/LOGS/* to computer
//!   7. Run: zigpod-telemetry analyze telemetry.bin

const std = @import("std");
const telemetry = @import("telemetry.zig");

// ============================================================
// Configuration
// ============================================================

/// Base path for ZigPod data on the disk
pub const ZIGPOD_PATH = "/ZIGPOD";
pub const LOGS_PATH = "/ZIGPOD/LOGS";

/// Log file names
pub const TELEMETRY_FILE = "/ZIGPOD/LOGS/telemetry.bin";
pub const CRASH_LOG_FILE = "/ZIGPOD/LOGS/crash.log";
pub const BOOT_LOG_FILE = "/ZIGPOD/LOGS/boot.log";
pub const SESSION_LOG_FILE = "/ZIGPOD/LOGS/session.txt";

/// Maximum session log size (text log)
pub const MAX_SESSION_LOG_SIZE: usize = 64 * 1024; // 64KB

// ============================================================
// Disk Logger
// ============================================================

pub const DiskLogger = struct {
    /// File system reference (will be wired to FAT32)
    fs: ?*anyopaque = null,

    /// Session log buffer (written periodically to disk)
    session_buffer: [MAX_SESSION_LOG_SIZE]u8 = undefined,
    session_pos: usize = 0,

    /// Boot count (read from disk on init)
    boot_count: u32 = 0,

    /// Initialization status
    initialized: bool = false,

    /// Write pending flag
    dirty: bool = false,

    const Self = @This();

    /// Initialize disk logger
    pub fn init(self: *Self) !void {
        if (self.initialized) return;

        // TODO: Wire to actual FAT32 filesystem
        // For now, just initialize memory buffer

        // Try to read previous boot count
        self.boot_count = self.readBootCount() catch 0;
        self.boot_count += 1;

        // Clear session buffer
        self.session_pos = 0;

        // Write boot marker
        try self.logLine("=== ZigPod Boot #{d} ===", .{self.boot_count});
        try self.logLine("Build: " ++ @import("builtin").zig_version_string, .{});

        self.initialized = true;

        // Record boot in telemetry
        telemetry.record(.boot_start, @truncate(self.boot_count), 0);
    }

    /// Log a formatted line to session log
    pub fn logLine(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.session_pos >= MAX_SESSION_LOG_SIZE - 256) {
            // Buffer full, need to flush
            try self.flush();
        }

        const remaining = self.session_buffer[self.session_pos..];
        const written = std.fmt.bufPrint(remaining, fmt ++ "\n", args) catch {
            return error.BufferFull;
        };
        self.session_pos += written.len;
        self.dirty = true;
    }

    /// Log raw string
    pub fn log(self: *Self, msg: []const u8) void {
        if (self.session_pos + msg.len + 1 >= MAX_SESSION_LOG_SIZE) {
            self.flush() catch {};
        }

        const end = @min(self.session_pos + msg.len, MAX_SESSION_LOG_SIZE - 1);
        @memcpy(self.session_buffer[self.session_pos..end], msg[0 .. end - self.session_pos]);
        self.session_pos = end;

        if (self.session_pos < MAX_SESSION_LOG_SIZE) {
            self.session_buffer[self.session_pos] = '\n';
            self.session_pos += 1;
        }
        self.dirty = true;
    }

    /// Flush session log to disk
    pub fn flush(self: *Self) !void {
        if (!self.dirty or self.session_pos == 0) return;

        // TODO: Write to FAT32 filesystem
        // For now, this is a stub that would write:
        // fat32.writeFile(SESSION_LOG_FILE, self.session_buffer[0..self.session_pos]);

        self.dirty = false;
    }

    /// Save telemetry buffer to disk
    pub fn saveTelemetry(self: *Self) !void {
        _ = self;
        const buffer = telemetry.exportBuffer();
        _ = buffer;
        // TODO: Write to FAT32
        // fat32.writeFile(TELEMETRY_FILE, buffer);
    }

    /// Write crash log (called from panic handler)
    pub fn writeCrashLog(self: *Self, pc: u32, lr: u32, sp: u32, cpsr: u32, message: []const u8) !void {
        var crash_buf: [2048]u8 = undefined;
        var pos: usize = 0;

        const header = "=== ZIGPOD CRASH LOG ===\n\n";
        @memcpy(crash_buf[pos .. pos + header.len], header);
        pos += header.len;

        // Format crash info
        const info = std.fmt.bufPrint(crash_buf[pos..],
            \\Boot: #{d}
            \\
            \\Registers:
            \\  PC:   0x{X:0>8}
            \\  LR:   0x{X:0>8}
            \\  SP:   0x{X:0>8}
            \\  CPSR: 0x{X:0>8}
            \\
            \\Message: {s}
            \\
            \\To debug:
            \\  1. Note the PC address above
            \\  2. Run: arm-none-eabi-addr2line -e zigpod.elf 0x{X:0>8}
            \\  3. This shows the source file and line
            \\
            \\Telemetry saved to: {s}
            \\
        , .{
            self.boot_count,
            pc, lr, sp, cpsr,
            message,
            pc,
            TELEMETRY_FILE,
        }) catch return error.FormatFailed;
        pos += info.len;

        _ = crash_buf[0..pos];
        // TODO: Write to FAT32
        // fat32.writeFile(CRASH_LOG_FILE, crash_buf[0..pos]);

        // Also save telemetry
        try self.saveTelemetry();
    }

    /// Read boot count from disk
    fn readBootCount(self: *Self) !u32 {
        _ = self;
        // TODO: Read from FAT32 boot.log or dedicated file
        return 0;
    }

    /// Shutdown cleanly (save all logs)
    pub fn shutdown(self: *Self) void {
        self.logLine("=== Shutdown ===", .{}) catch {};
        telemetry.record(.shutdown, 0, 0);
        self.flush() catch {};
        self.saveTelemetry() catch {};
    }
};

// ============================================================
// Global Instance
// ============================================================

var disk_logger: DiskLogger = .{};

/// Initialize disk logging
pub fn init() !void {
    telemetry.init();
    try disk_logger.init();
}

/// Log a message
pub fn log(comptime fmt: []const u8, args: anytype) void {
    disk_logger.logLine(fmt, args) catch {};
}

/// Log raw string
pub fn logRaw(msg: []const u8) void {
    disk_logger.log(msg);
}

/// Flush logs to disk (call periodically)
pub fn flush() void {
    disk_logger.flush() catch {};
}

/// Save all data and shutdown
pub fn shutdown() void {
    disk_logger.shutdown();
}

/// Record crash (called from panic handler)
pub fn recordCrash(pc: u32, lr: u32, sp: u32, cpsr: u32, message: []const u8) void {
    telemetry.recordPanic(pc);
    disk_logger.writeCrashLog(pc, lr, sp, cpsr, message) catch {};
}

/// Get logger instance for advanced use
pub fn getLogger() *DiskLogger {
    return &disk_logger;
}

// ============================================================
// Convenience Logging Functions
// ============================================================

/// Log audio event
pub fn logAudio(comptime event: []const u8, value: u32) void {
    log("[AUDIO] " ++ event ++ ": {d}", .{value});
}

/// Log storage event
pub fn logStorage(comptime event: []const u8, sector: u64) void {
    log("[STORAGE] " ++ event ++ ": sector {d}", .{sector});
}

/// Log UI event
pub fn logUI(comptime event: []const u8) void {
    log("[UI] " ++ event, .{});
}

/// Log error
pub fn logError(comptime source: []const u8, code: u32) void {
    log("[ERROR] {s}: code 0x{X:0>8}", .{ source, code });
    telemetry.recordError(@truncate(code), code);
}

/// Log performance marker
pub fn logPerf(comptime name: []const u8, duration_us: u32) void {
    log("[PERF] {s}: {d}us", .{ name, duration_us });
}

// ============================================================
// Tests
// ============================================================

test "disk logger init" {
    var logger = DiskLogger{};
    try logger.init();
    try std.testing.expect(logger.initialized);
    try std.testing.expect(logger.boot_count >= 1);
}

test "log line" {
    var logger = DiskLogger{};
    try logger.init();

    try logger.logLine("Test message: {d}", .{42});
    try std.testing.expect(logger.session_pos > 0);
    try std.testing.expect(logger.dirty);
}

test "log raw" {
    var logger = DiskLogger{};
    try logger.init();

    const initial_pos = logger.session_pos;
    logger.log("Raw message");
    try std.testing.expect(logger.session_pos > initial_pos);
}

test "global functions" {
    try init();
    log("Test from global", .{});
    logAudio("buffer_level", 1024);
    logStorage("read", 12345);
    logError("test", 0xDEAD);
}
