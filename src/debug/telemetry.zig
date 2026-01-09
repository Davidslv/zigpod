//! Hardware Debug Telemetry
//!
//! Captures runtime data for hardware debugging. Data is stored in a reserved
//! memory region and can be extracted via JTAG for analysis.
//!
//! Usage:
//! 1. Enable telemetry at boot
//! 2. Run tests on hardware
//! 3. Extract telemetry buffer via JTAG
//! 4. Parse with zigpod-telemetry tool for analysis

const std = @import("std");

// ============================================================
// Configuration
// ============================================================

/// Telemetry buffer size (16KB default, fits in IRAM)
pub const BUFFER_SIZE: usize = 16 * 1024;

/// Magic number to identify valid telemetry buffer
pub const MAGIC: u32 = 0x5A504454; // "ZPDT" - ZigPod Debug Telemetry

/// Telemetry version for format compatibility
pub const VERSION: u16 = 1;

// ============================================================
// Event Types
// ============================================================

pub const EventType = enum(u8) {
    // System events
    boot_start = 0x01,
    boot_complete = 0x02,
    shutdown = 0x03,
    hard_fault = 0x04,
    watchdog_reset = 0x05,

    // Audio events
    audio_init = 0x10,
    audio_start = 0x11,
    audio_stop = 0x12,
    audio_buffer_underrun = 0x13,
    audio_buffer_overrun = 0x14,
    audio_decode_error = 0x15,
    audio_dma_complete = 0x16,
    audio_sample_rate_change = 0x17,

    // Storage events
    ata_init = 0x20,
    ata_read = 0x21,
    ata_write = 0x22,
    ata_error = 0x23,
    ata_timeout = 0x24,
    fat32_mount = 0x25,
    fat32_error = 0x26,

    // Display events
    lcd_init = 0x30,
    lcd_refresh = 0x31,
    lcd_error = 0x32,

    // Input events
    button_press = 0x40,
    button_release = 0x41,
    wheel_move = 0x42,

    // Power events
    battery_read = 0x50,
    power_state_change = 0x51,
    charging_start = 0x52,
    charging_stop = 0x53,
    low_battery = 0x54,

    // Error events
    error_recorded = 0x60,
    panic = 0x61,
    assertion_failed = 0x62,

    // Performance markers
    perf_mark_start = 0x70,
    perf_mark_end = 0x71,
    frame_time = 0x72,
    cpu_load = 0x73,

    // Custom/debug
    debug_print = 0xF0,
    memory_snapshot = 0xF1,
    register_snapshot = 0xF2,
};

// ============================================================
// Event Structure
// ============================================================

/// Single telemetry event (12 bytes fixed size for easy parsing)
pub const Event = packed struct {
    /// Timestamp in milliseconds since boot
    timestamp_ms: u32,
    /// Event type
    event_type: EventType,
    /// Event-specific flags
    flags: u8,
    /// Event-specific data (interpretation depends on event_type)
    data: u16,
    /// Extended data (32-bit value for larger payloads)
    extended: u32,

    pub fn init(event_type: EventType, data: u16, extended: u32) Event {
        return .{
            .timestamp_ms = getTimestamp(),
            .event_type = event_type,
            .flags = 0,
            .data = data,
            .extended = extended,
        };
    }

    pub fn format(self: *const Event, writer: anytype) !void {
        try writer.print("[{d:>8}ms] {s}: data=0x{X:0>4} ext=0x{X:0>8}\n", .{
            self.timestamp_ms,
            @tagName(self.event_type),
            self.data,
            self.extended,
        });
    }
};

// ============================================================
// Telemetry Buffer Header
// ============================================================

/// Buffer header (32 bytes)
pub const BufferHeader = packed struct {
    magic: u32 = MAGIC,
    version: u16 = VERSION,
    flags: u16 = 0,
    /// Total events written (may wrap)
    total_events: u32 = 0,
    /// Current write index in ring buffer
    write_index: u32 = 0,
    /// Number of events currently in buffer
    event_count: u32 = 0,
    /// Boot count (incremented each boot)
    boot_count: u32 = 0,
    /// Checksum of buffer contents
    checksum: u32 = 0,
    /// Reserved for future use
    reserved: u32 = 0,

    pub fn isValid(self: *const BufferHeader) bool {
        return self.magic == MAGIC and self.version == VERSION;
    }
};

// ============================================================
// Telemetry Buffer
// ============================================================

/// Maximum events that fit in buffer
const MAX_EVENTS = (BUFFER_SIZE - @sizeOf(BufferHeader)) / @sizeOf(Event);

/// Telemetry ring buffer
pub const TelemetryBuffer = struct {
    header: BufferHeader,
    events: [MAX_EVENTS]Event,

    const Self = @This();

    pub fn init() Self {
        var self: Self = undefined;
        self.header = BufferHeader{};
        self.header.boot_count = readBootCount() + 1;
        @memset(std.mem.asBytes(&self.events), 0);
        return self;
    }

    /// Record an event
    pub fn record(self: *Self, event_type: EventType, data: u16, extended: u32) void {
        const event = Event.init(event_type, data, extended);
        self.events[self.header.write_index] = event;

        self.header.write_index = (self.header.write_index + 1) % MAX_EVENTS;
        self.header.total_events += 1;
        if (self.header.event_count < MAX_EVENTS) {
            self.header.event_count += 1;
        }
    }

    /// Record with flags
    pub fn recordWithFlags(self: *Self, event_type: EventType, flags: u8, data: u16, extended: u32) void {
        var event = Event.init(event_type, data, extended);
        event.flags = flags;
        self.events[self.header.write_index] = event;

        self.header.write_index = (self.header.write_index + 1) % MAX_EVENTS;
        self.header.total_events += 1;
        if (self.header.event_count < MAX_EVENTS) {
            self.header.event_count += 1;
        }
    }

    /// Get event count
    pub fn count(self: *const Self) u32 {
        return self.header.event_count;
    }

    /// Iterate events in chronological order
    pub fn iterate(self: *const Self) EventIterator {
        return EventIterator.init(self);
    }

    /// Clear buffer
    pub fn clear(self: *Self) void {
        self.header.write_index = 0;
        self.header.event_count = 0;
        self.header.total_events = 0;
    }

    /// Calculate checksum
    pub fn updateChecksum(self: *Self) void {
        var sum: u32 = 0;
        const bytes = std.mem.asBytes(&self.events);
        for (bytes) |b| {
            sum = sum +% b;
        }
        self.header.checksum = sum;
    }
};

/// Event iterator
pub const EventIterator = struct {
    buffer: *const TelemetryBuffer,
    index: u32,
    remaining: u32,

    pub fn init(buffer: *const TelemetryBuffer) EventIterator {
        const start = if (buffer.header.event_count >= MAX_EVENTS)
            buffer.header.write_index
        else
            0;
        return .{
            .buffer = buffer,
            .index = start,
            .remaining = buffer.header.event_count,
        };
    }

    pub fn next(self: *EventIterator) ?*const Event {
        if (self.remaining == 0) return null;
        const event = &self.buffer.events[self.index];
        self.index = (self.index + 1) % MAX_EVENTS;
        self.remaining -= 1;
        return event;
    }
};

// ============================================================
// Global Instance
// ============================================================

/// Global telemetry buffer (placed in known memory location)
/// On hardware: 0x40050000 (end of IRAM)
/// In simulator: regular static memory
var telemetry_buffer: TelemetryBuffer = undefined;
var initialized: bool = false;

/// Initialize telemetry system
pub fn init() void {
    if (initialized) return;
    telemetry_buffer = TelemetryBuffer.init();
    initialized = true;
    record(.boot_start, 0, telemetry_buffer.header.boot_count);
}

/// Record an event (global function)
pub fn record(event_type: EventType, data: u16, extended: u32) void {
    if (!initialized) return;
    telemetry_buffer.record(event_type, data, extended);
}

/// Record with flags
pub fn recordWithFlags(event_type: EventType, flags: u8, data: u16, extended: u32) void {
    if (!initialized) return;
    telemetry_buffer.recordWithFlags(event_type, flags, data, extended);
}

/// Record a performance marker
pub fn perfStart(marker_id: u16) void {
    record(.perf_mark_start, marker_id, getTimestamp());
}

pub fn perfEnd(marker_id: u16) void {
    record(.perf_mark_end, marker_id, getTimestamp());
}

/// Record an error
pub fn recordError(error_code: u16, context: u32) void {
    record(.error_recorded, error_code, context);
}

/// Record a panic (called from panic handler)
pub fn recordPanic(address: u32) void {
    record(.panic, 0, address);
    telemetry_buffer.updateChecksum();
}

/// Get buffer for JTAG extraction
pub fn getBuffer() *TelemetryBuffer {
    return &telemetry_buffer;
}

/// Get buffer address (for JTAG tools)
pub fn getBufferAddress() usize {
    return @intFromPtr(&telemetry_buffer);
}

/// Get buffer size
pub fn getBufferSize() usize {
    return @sizeOf(TelemetryBuffer);
}

/// Export buffer to byte slice
pub fn exportBuffer() []const u8 {
    telemetry_buffer.updateChecksum();
    return std.mem.asBytes(&telemetry_buffer);
}

// ============================================================
// Platform-specific helpers
// ============================================================

/// Get current timestamp (milliseconds since boot)
fn getTimestamp() u32 {
    // In real hardware, read from timer
    // For now, return 0 (will be wired to actual timer)
    return 0;
}

/// Read boot count from persistent storage
fn readBootCount() u32 {
    // In real hardware, read from RTC backup register or flash
    return 0;
}

// ============================================================
// Debug Output
// ============================================================

/// Print all events to writer
pub fn dumpEvents(writer: anytype) !void {
    if (!initialized) {
        try writer.print("Telemetry not initialized\n", .{});
        return;
    }

    try writer.print("=== ZigPod Telemetry Dump ===\n", .{});
    try writer.print("Boot count: {d}\n", .{telemetry_buffer.header.boot_count});
    try writer.print("Total events: {d}\n", .{telemetry_buffer.header.total_events});
    try writer.print("Events in buffer: {d}/{d}\n", .{ telemetry_buffer.header.event_count, MAX_EVENTS });
    try writer.print("Checksum: 0x{X:0>8}\n", .{telemetry_buffer.header.checksum});
    try writer.print("\nEvents:\n", .{});

    var iter = telemetry_buffer.iterate();
    var count: u32 = 0;
    while (iter.next()) |event| {
        try writer.print("  [{d:>4}] ", .{count});
        try event.format(writer);
        count += 1;
    }
}

/// Print summary statistics
pub fn dumpSummary(writer: anytype) !void {
    if (!initialized) return;

    // Count events by type
    var counts = [_]u32{0} ** 256;
    var iter = telemetry_buffer.iterate();
    while (iter.next()) |event| {
        counts[@intFromEnum(event.event_type)] += 1;
    }

    try writer.print("=== Event Summary ===\n", .{});
    for (counts, 0..) |count, i| {
        if (count > 0) {
            const event_type: EventType = @enumFromInt(i);
            try writer.print("  {s}: {d}\n", .{ @tagName(event_type), count });
        }
    }
}

// ============================================================
// Tests
// ============================================================

test "telemetry buffer init" {
    var buf = TelemetryBuffer.init();
    try std.testing.expect(buf.header.isValid());
    try std.testing.expectEqual(@as(u32, 0), buf.count());
}

test "record events" {
    var buf = TelemetryBuffer.init();

    buf.record(.boot_start, 0, 0);
    buf.record(.audio_init, 44100, 0);
    buf.record(.lcd_init, 320, 240);

    try std.testing.expectEqual(@as(u32, 3), buf.count());
}

test "ring buffer wraps" {
    var buf = TelemetryBuffer.init();

    // Fill buffer
    for (0..MAX_EVENTS + 10) |i| {
        buf.record(.debug_print, @intCast(i), 0);
    }

    try std.testing.expectEqual(@as(u32, MAX_EVENTS), buf.count());
    try std.testing.expectEqual(@as(u32, MAX_EVENTS + 10), buf.header.total_events);
}

test "event iterator" {
    var buf = TelemetryBuffer.init();

    buf.record(.boot_start, 1, 0);
    buf.record(.boot_complete, 2, 0);
    buf.record(.audio_init, 3, 0);

    var iter = buf.iterate();
    var count: u32 = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), count);
}

test "event format" {
    const event = Event{
        .timestamp_ms = 1234,
        .event_type = .audio_buffer_underrun,
        .flags = 0,
        .data = 0x1234,
        .extended = 0xDEADBEEF,
    };

    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try event.format(stream.writer());

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "audio_buffer_underrun") != null);
}

test "global functions" {
    init();
    record(.boot_complete, 0, 0);
    perfStart(1);
    perfEnd(1);
    recordError(0x0001, 0x12345678);

    try std.testing.expect(telemetry_buffer.count() >= 4);
}
