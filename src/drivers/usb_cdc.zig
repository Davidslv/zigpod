//! USB CDC (Communication Device Class) Driver
//!
//! Implements a virtual serial port over USB for real-time log streaming.
//! When the iPod is connected to a computer, it appears as a serial device
//! (like /dev/tty.usbmodem* on macOS or COM port on Windows).
//!
//! Usage on computer:
//!   macOS:   screen /dev/tty.usbmodem* 115200
//!   Linux:   screen /dev/ttyACM0 115200
//!   Windows: PuTTY on COM port
//!
//! Or use the ZigPod log viewer:
//!   zigpod-serial --port /dev/tty.usbmodem*

const std = @import("std");
const hal = @import("../hal/hal.zig");

// ============================================================
// USB CDC Constants
// ============================================================

/// USB CDC Class codes
const CDC_CLASS = struct {
    pub const COMM: u8 = 0x02; // Communication Interface Class
    pub const DATA: u8 = 0x0A; // Data Interface Class
};

/// CDC Subclass codes
const CDC_SUBCLASS = struct {
    pub const ACM: u8 = 0x02; // Abstract Control Model
};

/// CDC Protocol codes
const CDC_PROTOCOL = struct {
    pub const NONE: u8 = 0x00;
    pub const AT: u8 = 0x01; // AT Commands (V.250)
};

/// CDC Request codes
const CDC_REQUEST = struct {
    pub const SET_LINE_CODING: u8 = 0x20;
    pub const GET_LINE_CODING: u8 = 0x21;
    pub const SET_CONTROL_LINE_STATE: u8 = 0x22;
    pub const SEND_BREAK: u8 = 0x23;
};

/// Line coding structure (for SET/GET_LINE_CODING)
pub const LineCoding = packed struct {
    baud_rate: u32 = 115200,
    stop_bits: u8 = 0, // 0=1 stop, 1=1.5 stop, 2=2 stop
    parity: u8 = 0, // 0=none, 1=odd, 2=even
    data_bits: u8 = 8,
};

// ============================================================
// Endpoint Configuration
// ============================================================

/// CDC uses 3 endpoints:
/// - EP0: Control (standard USB)
/// - EP1 IN: Notification (interrupt, optional)
/// - EP2 IN: Data TX (bulk)
/// - EP2 OUT: Data RX (bulk)
const ENDPOINT = struct {
    pub const NOTIFY: u8 = 0x81; // EP1 IN
    pub const DATA_IN: u8 = 0x82; // EP2 IN
    pub const DATA_OUT: u8 = 0x02; // EP2 OUT
};

/// Buffer sizes
const TX_BUFFER_SIZE: usize = 2048;
const RX_BUFFER_SIZE: usize = 256;

// ============================================================
// CDC State
// ============================================================

pub const CdcState = enum {
    disconnected,
    initializing,
    ready,
    transmitting,
    error_state,
};

/// CDC driver state
var state: CdcState = .disconnected;
var line_coding: LineCoding = .{};
var dtr_active: bool = false; // Data Terminal Ready
var rts_active: bool = false; // Request To Send

/// Transmit buffer (ring buffer)
var tx_buffer: [TX_BUFFER_SIZE]u8 = undefined;
var tx_read_pos: usize = 0;
var tx_write_pos: usize = 0;
var tx_count: usize = 0;

/// Receive buffer
var rx_buffer: [RX_BUFFER_SIZE]u8 = undefined;
var rx_read_pos: usize = 0;
var rx_write_pos: usize = 0;
var rx_count: usize = 0;

/// Statistics
var bytes_sent: u64 = 0;
var bytes_received: u64 = 0;
var tx_overflows: u32 = 0;

// ============================================================
// Initialization
// ============================================================

/// Initialize USB CDC
pub fn init() !void {
    if (state != .disconnected) return;

    state = .initializing;

    // Reset buffers
    tx_read_pos = 0;
    tx_write_pos = 0;
    tx_count = 0;
    rx_read_pos = 0;
    rx_write_pos = 0;
    rx_count = 0;

    // Initialize USB controller for CDC mode
    // This would configure the USB peripheral for CDC descriptors
    try initUsbController();

    state = .ready;
}

/// Initialize USB controller for CDC
fn initUsbController() !void {
    // TODO: Configure USB controller with CDC descriptors
    // This involves:
    // 1. Set up device descriptor (VID/PID for CDC)
    // 2. Set up configuration descriptor
    // 3. Set up CDC-specific descriptors (header, ACM, union)
    // 4. Set up interface descriptors
    // 5. Set up endpoint descriptors
    // 6. Enable endpoints

    // For now, we prepare the descriptor data
    // Actual USB init happens in usb.zig
}

/// Deinitialize CDC
pub fn deinit() void {
    state = .disconnected;
}

// ============================================================
// Connection Status
// ============================================================

/// Check if CDC is connected and ready
pub fn isConnected() bool {
    return state == .ready and dtr_active;
}

/// Check if host terminal is ready (DTR active)
pub fn isTerminalReady() bool {
    return dtr_active;
}

/// Get current state
pub fn getState() CdcState {
    return state;
}

// ============================================================
// Transmit (iPod → Computer)
// ============================================================

/// Write a single byte to TX buffer
pub fn writeByte(byte: u8) bool {
    if (tx_count >= TX_BUFFER_SIZE) {
        tx_overflows += 1;
        return false;
    }

    tx_buffer[tx_write_pos] = byte;
    tx_write_pos = (tx_write_pos + 1) % TX_BUFFER_SIZE;
    tx_count += 1;
    return true;
}

/// Write bytes to TX buffer
pub fn write(data: []const u8) usize {
    var written: usize = 0;
    for (data) |byte| {
        if (writeByte(byte)) {
            written += 1;
        } else {
            break;
        }
    }
    return written;
}

/// Write a formatted string
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(str);
}

/// Write a line (with newline)
pub fn println(comptime fmt: []const u8, args: anytype) void {
    print(fmt ++ "\r\n", args);
}

/// Write raw string
pub fn writeString(str: []const u8) void {
    _ = write(str);
}

/// Flush TX buffer to USB
pub fn flush() !void {
    if (tx_count == 0) return;
    if (state != .ready) return;

    // Send data via USB bulk endpoint
    while (tx_count > 0) {
        const byte = tx_buffer[tx_read_pos];
        tx_read_pos = (tx_read_pos + 1) % TX_BUFFER_SIZE;
        tx_count -= 1;
        bytes_sent += 1;

        // TODO: Actually send via USB endpoint
        // usb.sendBulk(ENDPOINT.DATA_IN, &[_]u8{byte});
        _ = byte;
    }
}

/// Get available TX buffer space
pub fn txAvailable() usize {
    return TX_BUFFER_SIZE - tx_count;
}

// ============================================================
// Receive (Computer → iPod)
// ============================================================

/// Read a single byte from RX buffer
pub fn readByte() ?u8 {
    if (rx_count == 0) return null;

    const byte = rx_buffer[rx_read_pos];
    rx_read_pos = (rx_read_pos + 1) % RX_BUFFER_SIZE;
    rx_count -= 1;
    return byte;
}

/// Read bytes from RX buffer
pub fn read(buffer: []u8) usize {
    var count: usize = 0;
    for (buffer) |*b| {
        if (readByte()) |byte| {
            b.* = byte;
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

/// Check if data available to read
pub fn rxAvailable() usize {
    return rx_count;
}

/// Called by USB interrupt when data received
pub fn onDataReceived(data: []const u8) void {
    for (data) |byte| {
        if (rx_count < RX_BUFFER_SIZE) {
            rx_buffer[rx_write_pos] = byte;
            rx_write_pos = (rx_write_pos + 1) % RX_BUFFER_SIZE;
            rx_count += 1;
            bytes_received += 1;
        }
    }
}

// ============================================================
// CDC Control Requests
// ============================================================

/// Handle SET_LINE_CODING request
pub fn setLineCoding(coding: LineCoding) void {
    line_coding = coding;
}

/// Handle GET_LINE_CODING request
pub fn getLineCoding() LineCoding {
    return line_coding;
}

/// Handle SET_CONTROL_LINE_STATE request
pub fn setControlLineState(dtr: bool, rts: bool) void {
    dtr_active = dtr;
    rts_active = rts;

    // DTR going active typically means terminal opened
    if (dtr and state == .ready) {
        // Send welcome message
        println("=== ZigPod Debug Console ===", .{});
        println("Boot #{d} | Build: " ++ @import("builtin").zig_version_string, .{getBootCount()});
        println("Type 'help' for commands", .{});
        println("", .{});
    }
}

// ============================================================
// Statistics
// ============================================================

pub const Stats = struct {
    bytes_sent: u64,
    bytes_received: u64,
    tx_overflows: u32,
    tx_buffer_used: usize,
    rx_buffer_used: usize,
};

pub fn getStats() Stats {
    return .{
        .bytes_sent = bytes_sent,
        .bytes_received = bytes_received,
        .tx_overflows = tx_overflows,
        .tx_buffer_used = tx_count,
        .rx_buffer_used = rx_count,
    };
}

// ============================================================
// Debug Console Commands
// ============================================================

/// Process received commands (called from main loop)
pub fn processCommands() void {
    var cmd_buf: [64]u8 = undefined;
    var cmd_len: usize = 0;

    // Read until newline
    while (readByte()) |byte| {
        if (byte == '\r' or byte == '\n') {
            if (cmd_len > 0) {
                executeCommand(cmd_buf[0..cmd_len]);
                cmd_len = 0;
            }
        } else if (cmd_len < cmd_buf.len - 1) {
            cmd_buf[cmd_len] = byte;
            cmd_len += 1;
        }
    }
}

fn executeCommand(cmd: []const u8) void {
    if (std.mem.eql(u8, cmd, "help")) {
        println("Commands:", .{});
        println("  status  - Show system status", .{});
        println("  battery - Show battery info", .{});
        println("  audio   - Show audio status", .{});
        println("  errors  - Show error log", .{});
        println("  clear   - Clear error state", .{});
        println("  reboot  - Reboot device", .{});
    } else if (std.mem.eql(u8, cmd, "status")) {
        println("State: ready", .{});
        println("Uptime: TODO", .{});
        println("TX sent: {d} bytes", .{bytes_sent});
    } else if (std.mem.eql(u8, cmd, "battery")) {
        println("Battery: TODO - read from PMU", .{});
    } else if (std.mem.eql(u8, cmd, "audio")) {
        println("Audio: TODO - read from audio engine", .{});
    } else if (std.mem.eql(u8, cmd, "errors")) {
        println("Errors: TODO - read from error state", .{});
    } else if (std.mem.eql(u8, cmd, "clear")) {
        println("Errors cleared", .{});
    } else if (std.mem.eql(u8, cmd, "reboot")) {
        println("Rebooting...", .{});
        // TODO: trigger reboot
    } else {
        println("Unknown command: {s}", .{cmd});
        println("Type 'help' for commands", .{});
    }
}

// ============================================================
// Helpers
// ============================================================

fn getBootCount() u32 {
    // TODO: Read from telemetry or RTC backup
    return 1;
}

// ============================================================
// USB Descriptors for CDC ACM
// ============================================================

/// Device descriptor for CDC device
pub const device_descriptor = [18]u8{
    18, // bLength
    0x01, // bDescriptorType (Device)
    0x00, 0x02, // bcdUSB (2.0)
    0xEF, // bDeviceClass (Misc)
    0x02, // bDeviceSubClass
    0x01, // bDeviceProtocol (IAD)
    64, // bMaxPacketSize0
    0x66, 0x66, // idVendor (placeholder)
    0x01, 0x00, // idProduct (placeholder)
    0x00, 0x01, // bcdDevice
    1, // iManufacturer
    2, // iProduct
    3, // iSerialNumber
    1, // bNumConfigurations
};

/// String descriptors
pub const string_manufacturer = "ZigPod";
pub const string_product = "ZigPod Debug Console";
pub const string_serial = "001";

// ============================================================
// Tests
// ============================================================

test "cdc write byte" {
    // Reset state
    tx_read_pos = 0;
    tx_write_pos = 0;
    tx_count = 0;

    try std.testing.expect(writeByte(0x41));
    try std.testing.expectEqual(@as(usize, 1), tx_count);
    try std.testing.expectEqual(@as(u8, 0x41), tx_buffer[0]);
}

test "cdc write string" {
    tx_read_pos = 0;
    tx_write_pos = 0;
    tx_count = 0;

    const written = write("Hello");
    try std.testing.expectEqual(@as(usize, 5), written);
    try std.testing.expectEqual(@as(usize, 5), tx_count);
}

test "cdc buffer overflow" {
    tx_read_pos = 0;
    tx_write_pos = 0;
    tx_count = TX_BUFFER_SIZE; // Buffer full
    tx_overflows = 0;

    try std.testing.expect(!writeByte(0x00));
    try std.testing.expectEqual(@as(u32, 1), tx_overflows);
}

test "cdc line coding" {
    const coding = LineCoding{
        .baud_rate = 9600,
        .stop_bits = 0,
        .parity = 0,
        .data_bits = 8,
    };
    setLineCoding(coding);
    try std.testing.expectEqual(@as(u32, 9600), line_coding.baud_rate);
}

test "cdc control line state" {
    state = .ready;
    tx_read_pos = 0;
    tx_write_pos = 0;
    tx_count = 0;

    setControlLineState(true, false);
    try std.testing.expect(dtr_active);
    try std.testing.expect(!rts_active);
}
