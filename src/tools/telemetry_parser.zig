//! Telemetry Parser Tool
//!
//! Parses telemetry buffers extracted from hardware via JTAG and provides
//! analysis for debugging hardware issues.
//!
//! Usage:
//!   zigpod-telemetry parse telemetry.bin
//!   zigpod-telemetry analyze telemetry.bin
//!   zigpod-telemetry compare before.bin after.bin

const std = @import("std");
const telemetry = @import("../debug/telemetry.zig");

const Event = telemetry.Event;
const EventType = telemetry.EventType;
const BufferHeader = telemetry.BufferHeader;
const TelemetryBuffer = telemetry.TelemetryBuffer;
const MAGIC = telemetry.MAGIC;
const VERSION = telemetry.VERSION;

/// Analysis result
pub const Analysis = struct {
    total_events: u32,
    boot_count: u32,
    duration_ms: u32,
    error_count: u32,
    underrun_count: u32,
    overrun_count: u32,
    panic_count: u32,
    warnings: std.ArrayList([]const u8),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Analysis {
        return .{
            .total_events = 0,
            .boot_count = 0,
            .duration_ms = 0,
            .error_count = 0,
            .underrun_count = 0,
            .overrun_count = 0,
            .panic_count = 0,
            .warnings = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Analysis) void {
        self.warnings.deinit();
    }

    pub fn addWarning(self: *Analysis, msg: []const u8) !void {
        try self.warnings.append(msg);
    }

    pub fn print(self: *const Analysis, writer: anytype) !void {
        try writer.print("\n========================================\n", .{});
        try writer.print("       ZIGPOD TELEMETRY ANALYSIS\n", .{});
        try writer.print("========================================\n\n", .{});

        try writer.print("Session Info:\n", .{});
        try writer.print("  Boot count:     {d}\n", .{self.boot_count});
        try writer.print("  Duration:       {d}ms ({d:.1}s)\n", .{
            self.duration_ms,
            @as(f32, @floatFromInt(self.duration_ms)) / 1000.0,
        });
        try writer.print("  Total events:   {d}\n", .{self.total_events});

        try writer.print("\nHealth Summary:\n", .{});

        // Overall status
        const status = if (self.panic_count > 0)
            "CRITICAL - Panics detected"
        else if (self.error_count > 5)
            "POOR - Multiple errors"
        else if (self.underrun_count > 0)
            "WARNING - Audio underruns"
        else
            "GOOD";

        try writer.print("  Status:         {s}\n", .{status});
        try writer.print("  Errors:         {d}\n", .{self.error_count});
        try writer.print("  Panics:         {d}\n", .{self.panic_count});
        try writer.print("  Audio underruns:{d}\n", .{self.underrun_count});
        try writer.print("  Audio overruns: {d}\n", .{self.overrun_count});

        if (self.warnings.items.len > 0) {
            try writer.print("\nWarnings:\n", .{});
            for (self.warnings.items) |warning| {
                try writer.print("  ! {s}\n", .{warning});
            }
        }

        try writer.print("\n========================================\n", .{});
    }
};

/// Parse telemetry buffer from file
pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !*TelemetryBuffer {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const buffer = try allocator.create(TelemetryBuffer);
    const bytes = std.mem.asBytes(buffer);

    const read = try file.readAll(bytes);
    if (read != bytes.len) {
        return error.IncompleteRead;
    }

    // Validate magic
    if (!buffer.header.isValid()) {
        return error.InvalidMagic;
    }

    return buffer;
}

/// Analyze telemetry buffer
pub fn analyze(allocator: std.mem.Allocator, buffer: *const TelemetryBuffer) !Analysis {
    var result = Analysis.init(allocator);

    result.boot_count = buffer.header.boot_count;
    result.total_events = buffer.header.total_events;

    var first_timestamp: ?u32 = null;
    var last_timestamp: u32 = 0;
    var last_event_type: ?EventType = null;

    var iter = buffer.iterate();
    while (iter.next()) |event| {
        if (first_timestamp == null) {
            first_timestamp = event.timestamp_ms;
        }
        last_timestamp = event.timestamp_ms;

        switch (event.event_type) {
            .audio_buffer_underrun => result.underrun_count += 1,
            .audio_buffer_overrun => result.overrun_count += 1,
            .error_recorded => result.error_count += 1,
            .panic => result.panic_count += 1,
            .hard_fault => {
                result.panic_count += 1;
                try result.addWarning("Hard fault detected - check PC address");
            },
            .ata_timeout => {
                try result.addWarning("ATA timeout - disk may be slow or failing");
            },
            .low_battery => {
                try result.addWarning("Low battery event - test with full charge");
            },
            .watchdog_reset => {
                try result.addWarning("Watchdog reset - system hung");
            },
            else => {},
        }

        // Check for rapid repeated events (possible bug)
        if (last_event_type) |last| {
            if (last == event.event_type and event.event_type == .error_recorded) {
                // Rapid errors might indicate a loop
            }
        }
        last_event_type = event.event_type;
    }

    if (first_timestamp) |first| {
        result.duration_ms = last_timestamp - first;
    }

    // Add warnings based on patterns
    if (result.underrun_count > 10) {
        try result.addWarning("Frequent underruns - CPU may be overloaded");
    }

    if (result.total_events > 0 and result.error_count * 100 / result.total_events > 10) {
        try result.addWarning("High error rate (>10%) - investigate root cause");
    }

    return result;
}

/// Print events in human-readable format
pub fn printEvents(buffer: *const TelemetryBuffer, writer: anytype) !void {
    try writer.print("=== ZigPod Telemetry Events ===\n", .{});
    try writer.print("Boot #{d}, {d} events\n\n", .{
        buffer.header.boot_count,
        buffer.header.event_count,
    });

    var iter = buffer.iterate();
    var i: u32 = 0;
    while (iter.next()) |event| {
        try writer.print("[{d:>4}] {d:>8}ms  {s:<24} data=0x{X:0>4} ext=0x{X:0>8}\n", .{
            i,
            event.timestamp_ms,
            @tagName(event.event_type),
            event.data,
            event.extended,
        });
        i += 1;
    }
}

/// Print event type summary
pub fn printSummary(buffer: *const TelemetryBuffer, writer: anytype) !void {
    var counts = [_]u32{0} ** 256;

    var iter = buffer.iterate();
    while (iter.next()) |event| {
        counts[@intFromEnum(event.event_type)] += 1;
    }

    try writer.print("=== Event Type Summary ===\n", .{});
    for (counts, 0..) |count, i| {
        if (count > 0) {
            const event_type: EventType = @enumFromInt(i);
            try writer.print("  {s:<28} {d:>6}\n", .{ @tagName(event_type), count });
        }
    }
}

/// Generate troubleshooting report
pub fn generateReport(allocator: std.mem.Allocator, buffer: *const TelemetryBuffer, writer: anytype) !void {
    const analysis = try analyze(allocator, buffer);
    defer @constCast(&analysis).deinit();

    try analysis.print(writer);
    try writer.print("\n", .{});
    try printSummary(buffer, writer);
    try writer.print("\n", .{});

    // Detailed recommendations
    try writer.print("=== Troubleshooting Recommendations ===\n\n", .{});

    if (analysis.panic_count > 0) {
        try writer.print("PANIC DETECTED:\n", .{});
        try writer.print("  1. Check the PC address in panic event for crash location\n", .{});
        try writer.print("  2. Use addr2line or objdump to find source line\n", .{});
        try writer.print("  3. Common causes: null pointer, stack overflow, invalid memory\n\n", .{});
    }

    if (analysis.underrun_count > 0) {
        try writer.print("AUDIO UNDERRUNS:\n", .{});
        try writer.print("  1. CPU may be overloaded - check frame_time events\n", .{});
        try writer.print("  2. DMA may not be keeping up - check buffer sizes\n", .{});
        try writer.print("  3. Storage reads may be slow - check ata_read timings\n\n", .{});
    }

    if (analysis.error_count > 0) {
        try writer.print("ERRORS RECORDED:\n", .{});
        try writer.print("  1. Check error_recorded events for error codes\n", .{});
        try writer.print("  2. Cross-reference with src/app/app.zig ErrorState\n", .{});
        try writer.print("  3. Look for patterns in timing\n\n", .{});
    }

    try writer.print("NEXT STEPS:\n", .{});
    try writer.print("  1. Share this report for analysis\n", .{});
    try writer.print("  2. Extract full event log if needed\n", .{});
    try writer.print("  3. Compare with previous runs\n", .{});
}

// ============================================================
// CLI Entry Point
// ============================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();

    if (args.len < 2) {
        try stdout.print("ZigPod Telemetry Parser\n\n", .{});
        try stdout.print("Usage:\n", .{});
        try stdout.print("  {s} parse <telemetry.bin>     Print all events\n", .{args[0]});
        try stdout.print("  {s} analyze <telemetry.bin>   Analyze and show report\n", .{args[0]});
        try stdout.print("  {s} summary <telemetry.bin>   Show event summary\n", .{args[0]});
        return;
    }

    const command = args[1];
    if (args.len < 3) {
        try stdout.print("Error: Missing filename\n", .{});
        return;
    }
    const filename = args[2];

    const buffer = parseFile(allocator, filename) catch |err| {
        try stdout.print("Error loading {s}: {s}\n", .{ filename, @errorName(err) });
        return;
    };
    defer allocator.destroy(buffer);

    if (std.mem.eql(u8, command, "parse")) {
        try printEvents(buffer, stdout);
    } else if (std.mem.eql(u8, command, "analyze")) {
        try generateReport(allocator, buffer, stdout);
    } else if (std.mem.eql(u8, command, "summary")) {
        try printSummary(buffer, stdout);
    } else {
        try stdout.print("Unknown command: {s}\n", .{command});
    }
}

// ============================================================
// Tests
// ============================================================

test "analysis init" {
    const allocator = std.testing.allocator;
    var a = Analysis.init(allocator);
    defer a.deinit();

    try std.testing.expectEqual(@as(u32, 0), a.error_count);
}

test "buffer validation" {
    var buffer: TelemetryBuffer = undefined;
    buffer.header.magic = 0x12345678; // Wrong magic
    try std.testing.expect(!buffer.header.isValid());

    buffer.header.magic = MAGIC;
    buffer.header.version = VERSION;
    try std.testing.expect(buffer.header.isValid());
}
