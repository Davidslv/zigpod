//! FT2232 JTAG Adapter Driver
//!
//! Driver for FTDI FT2232H-based JTAG adapters.
//! Uses MPSSE mode for efficient JTAG operations.

const std = @import("std");
const arm_jtag = @import("arm_jtag.zig");

const TapState = arm_jtag.TapState;
const ArmJtagInterface = arm_jtag.ArmJtagInterface;

/// FTDI MPSSE Commands
pub const MpsseCmd = struct {
    /// Write bytes on falling clock edge (MSB first)
    pub const WRITE_BYTES_MSB_FALLING: u8 = 0x11;
    /// Read bytes on rising clock edge (MSB first)
    pub const READ_BYTES_MSB_RISING: u8 = 0x20;
    /// Write/Read bytes MSB (clock on falling write, rising read)
    pub const WRITE_READ_BYTES_MSB: u8 = 0x31;
    /// Write bits on falling clock edge (MSB first)
    pub const WRITE_BITS_MSB_FALLING: u8 = 0x13;
    /// Read bits on rising clock edge (MSB first)
    pub const READ_BITS_MSB_RISING: u8 = 0x22;
    /// Write/Read bits MSB
    pub const WRITE_READ_BITS_MSB: u8 = 0x33;
    /// Write TMS on falling clock edge
    pub const WRITE_TMS: u8 = 0x4B;
    /// Set low byte GPIO
    pub const SET_LOW_BYTE: u8 = 0x80;
    /// Set high byte GPIO
    pub const SET_HIGH_BYTE: u8 = 0x82;
    /// Read low byte GPIO
    pub const READ_LOW_BYTE: u8 = 0x81;
    /// Read high byte GPIO
    pub const READ_HIGH_BYTE: u8 = 0x83;
    /// Set clock divisor
    pub const SET_DIVISOR: u8 = 0x86;
    /// Disable clock divide by 5
    pub const DISABLE_CLK_DIV5: u8 = 0x8A;
    /// Enable clock divide by 5
    pub const ENABLE_CLK_DIV5: u8 = 0x8B;
    /// Enable 3-phase clocking
    pub const ENABLE_3PHASE: u8 = 0x8C;
    /// Disable 3-phase clocking
    pub const DISABLE_3PHASE: u8 = 0x8D;
    /// Send immediate
    pub const SEND_IMMEDIATE: u8 = 0x87;
    /// Bad command response
    pub const BAD_COMMAND: u8 = 0xFA;
};

/// JTAG signal pin assignments (typical FT2232H)
pub const JtagPins = struct {
    pub const TCK: u8 = 0x01; // ADBUS0
    pub const TDI: u8 = 0x02; // ADBUS1
    pub const TDO: u8 = 0x04; // ADBUS2
    pub const TMS: u8 = 0x08; // ADBUS3
    pub const TRST: u8 = 0x10; // ADBUS4 (active low)
    pub const SRST: u8 = 0x20; // ADBUS5 (active low)
};

/// FT2232 connection errors
pub const Ft2232Error = error{
    DeviceNotFound,
    OpenFailed,
    ConfigFailed,
    WriteFailed,
    ReadFailed,
    Timeout,
    InvalidResponse,
    NotConnected,
};

/// FT2232 JTAG adapter driver
pub const Ft2232Driver = struct {
    /// Device handle (platform-specific)
    handle: ?*anyopaque = null,
    /// TAP state machine
    tap_state: TapState = .test_logic_reset,
    /// Current GPIO output state
    gpio_low: u8 = 0,
    /// GPIO direction (1 = output)
    gpio_low_dir: u8 = JtagPins.TCK | JtagPins.TDI | JtagPins.TMS | JtagPins.TRST | JtagPins.SRST,
    /// JTAG clock frequency in Hz
    frequency: u32 = 1_000_000, // 1 MHz default
    /// Allocator for buffers
    allocator: std.mem.Allocator,
    /// Command buffer
    cmd_buffer: std.ArrayList(u8),
    /// Connected flag
    connected: bool = false,

    const Self = @This();

    /// Create a new FT2232 driver instance
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .cmd_buffer = std.ArrayList(u8){},
        };
    }

    /// Cleanup
    pub fn deinit(self: *Self) void {
        self.disconnect();
        self.cmd_buffer.deinit(self.allocator);
    }

    /// Connect to device by index
    pub fn connect(self: *Self, device_index: u32) Ft2232Error!void {
        _ = device_index;

        // Platform-specific USB/FTDI initialization would go here
        // For now, this is a stub that simulates connection

        // Initialize GPIO state
        self.gpio_low = JtagPins.TRST | JtagPins.SRST; // TRST/SRST high (inactive)

        // Reset TAP to known state
        self.tap_state = .test_logic_reset;
        self.connected = true;
    }

    /// Disconnect from device
    pub fn disconnect(self: *Self) void {
        if (self.handle) |_| {
            // Close device
            self.handle = null;
        }
        self.connected = false;
    }

    /// Set JTAG clock frequency
    pub fn setFrequency(self: *Self, hz: u32) Ft2232Error!void {
        if (!self.connected) return Ft2232Error.NotConnected;

        self.frequency = hz;

        // Calculate divisor: frequency = 60MHz / ((1 + divisor) * 2)
        // divisor = (60MHz / (frequency * 2)) - 1
        const divisor: u16 = @intCast(@max(0, @as(i32, @intCast(30_000_000 / hz)) - 1));

        self.cmd_buffer.clearRetainingCapacity();
        self.cmd_buffer.append(self.allocator, MpsseCmd.SET_DIVISOR) catch return Ft2232Error.WriteFailed;
        self.cmd_buffer.append(self.allocator, @truncate(divisor & 0xFF)) catch return Ft2232Error.WriteFailed;
        self.cmd_buffer.append(self.allocator, @truncate(divisor >> 8)) catch return Ft2232Error.WriteFailed;

        try self.flushCommands();
    }

    /// Reset TRST line (toggle low then high)
    pub fn resetTrst(self: *Self) Ft2232Error!void {
        if (!self.connected) return Ft2232Error.NotConnected;

        // Assert TRST (active low)
        self.gpio_low &= ~JtagPins.TRST;
        try self.setGpioLow();

        // Small delay
        std.time.sleep(10_000_000); // 10ms

        // Deassert TRST
        self.gpio_low |= JtagPins.TRST;
        try self.setGpioLow();

        self.tap_state = .test_logic_reset;
    }

    /// Reset SRST line
    pub fn resetSrst(self: *Self) Ft2232Error!void {
        if (!self.connected) return Ft2232Error.NotConnected;

        // Assert SRST (active low)
        self.gpio_low &= ~JtagPins.SRST;
        try self.setGpioLow();

        // Hold for 100ms
        std.time.sleep(100_000_000);

        // Deassert SRST
        self.gpio_low |= JtagPins.SRST;
        try self.setGpioLow();
    }

    /// Set low byte GPIO
    fn setGpioLow(self: *Self) Ft2232Error!void {
        self.cmd_buffer.clearRetainingCapacity();
        self.cmd_buffer.append(self.allocator, MpsseCmd.SET_LOW_BYTE) catch return Ft2232Error.WriteFailed;
        self.cmd_buffer.append(self.allocator, self.gpio_low) catch return Ft2232Error.WriteFailed;
        self.cmd_buffer.append(self.allocator, self.gpio_low_dir) catch return Ft2232Error.WriteFailed;

        try self.flushCommands();
    }

    /// Navigate TAP state machine via TMS
    pub fn gotoState(self: *Self, target: TapState) Ft2232Error!void {
        if (!self.connected) return Ft2232Error.NotConnected;

        const tms_seq = getTmsSequence(self.tap_state, target);
        if (tms_seq.len == 0) return; // Already at target

        self.cmd_buffer.clearRetainingCapacity();
        self.cmd_buffer.append(self.allocator, MpsseCmd.WRITE_TMS) catch return Ft2232Error.WriteFailed;
        self.cmd_buffer.append(self.allocator, @intCast(tms_seq.len - 1)) catch return Ft2232Error.WriteFailed; // Length - 1
        self.cmd_buffer.append(self.allocator, tms_seq.bits) catch return Ft2232Error.WriteFailed;

        try self.flushCommands();
        self.tap_state = target;
    }

    /// Shift data through TDI/TDO
    pub fn shiftData(self: *Self, tdi: []const u8, bit_count: usize, capture: bool) Ft2232Error!?[]u8 {
        if (!self.connected) return Ft2232Error.NotConnected;

        const byte_count = bit_count / 8;
        const remaining_bits = bit_count % 8;

        self.cmd_buffer.clearRetainingCapacity();

        // Shift complete bytes
        if (byte_count > 0) {
            const cmd = if (capture) MpsseCmd.WRITE_READ_BYTES_MSB else MpsseCmd.WRITE_BYTES_MSB_FALLING;
            self.cmd_buffer.append(self.allocator, cmd) catch return Ft2232Error.WriteFailed;
            self.cmd_buffer.append(self.allocator, @intCast((byte_count - 1) & 0xFF)) catch return Ft2232Error.WriteFailed;
            self.cmd_buffer.append(self.allocator, @intCast((byte_count - 1) >> 8)) catch return Ft2232Error.WriteFailed;
            self.cmd_buffer.appendSlice(self.allocator, tdi[0..byte_count]) catch return Ft2232Error.WriteFailed;
        }

        // Shift remaining bits
        if (remaining_bits > 0) {
            const cmd = if (capture) MpsseCmd.WRITE_READ_BITS_MSB else MpsseCmd.WRITE_BITS_MSB_FALLING;
            self.cmd_buffer.append(self.allocator, cmd) catch return Ft2232Error.WriteFailed;
            self.cmd_buffer.append(self.allocator, @intCast(remaining_bits - 1)) catch return Ft2232Error.WriteFailed;
            self.cmd_buffer.append(self.allocator, if (byte_count < tdi.len) tdi[byte_count] else 0) catch return Ft2232Error.WriteFailed;
        }

        try self.flushCommands();

        if (capture) {
            // Read response
            const result_len = byte_count + (if (remaining_bits > 0) @as(usize, 1) else 0);
            const result = self.allocator.alloc(u8, result_len) catch return Ft2232Error.ReadFailed;
            // Actual read would happen here
            @memset(result, 0);
            return result;
        }

        return null;
    }

    /// Flush command buffer to device
    fn flushCommands(self: *Self) Ft2232Error!void {
        if (self.cmd_buffer.items.len == 0) return;

        // Add SEND_IMMEDIATE to force data out
        self.cmd_buffer.append(self.allocator, MpsseCmd.SEND_IMMEDIATE) catch return Ft2232Error.WriteFailed;

        // Platform-specific USB write would go here
        // For now, just clear the buffer

        self.cmd_buffer.clearRetainingCapacity();
    }

    /// Get JTAG interface
    pub fn getInterface(self: *Self) ArmJtagInterface {
        return .{
            .vtable = &vtable,
            .context = self,
        };
    }

    fn shiftImpl(ctx: *anyopaque, bits: []const u8, _: []const u8, len: usize) anyerror![]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (try self.shiftData(bits, len, true)) |data| {
            return data;
        }
        return error.ShiftFailed;
    }

    fn resetImpl(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.gotoState(.test_logic_reset);
    }

    fn getStateImpl(ctx: *anyopaque) TapState {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.tap_state;
    }

    const vtable = ArmJtagInterface.VTable{
        .shift = shiftImpl,
        .reset = resetImpl,
        .getState = getStateImpl,
    };
};

/// TMS sequence for state transitions
const TmsSequence = struct {
    bits: u8,
    len: u4,
};

/// Get TMS sequence to navigate between states
fn getTmsSequence(from: TapState, to: TapState) TmsSequence {
    // Common transitions - this is a simplified implementation
    // A full implementation would have a complete state transition table

    if (from == to) return .{ .bits = 0, .len = 0 };

    // Reset from any state (5 TMS=1)
    if (to == .test_logic_reset) {
        return .{ .bits = 0x1F, .len = 5 };
    }

    // From Reset to Run-Test-Idle
    if (from == .test_logic_reset and to == .run_test_idle) {
        return .{ .bits = 0, .len = 1 }; // TMS=0
    }

    // From Run-Test-Idle to Shift-DR
    if (from == .run_test_idle and to == .shift_dr) {
        return .{ .bits = 0x01, .len = 3 }; // TMS=1,0,0
    }

    // From Run-Test-Idle to Shift-IR
    if (from == .run_test_idle and to == .shift_ir) {
        return .{ .bits = 0x03, .len = 4 }; // TMS=1,1,0,0
    }

    // From Shift-DR to Run-Test-Idle
    if (from == .shift_dr and to == .run_test_idle) {
        return .{ .bits = 0x03, .len = 3 }; // TMS=1,1,0
    }

    // From Shift-IR to Run-Test-Idle
    if (from == .shift_ir and to == .run_test_idle) {
        return .{ .bits = 0x03, .len = 3 }; // TMS=1,1,0
    }

    // Default: go through reset
    return .{ .bits = 0x1F, .len = 5 };
}

// ============================================================
// Tests
// ============================================================

test "ft2232 init and deinit" {
    const allocator = std.testing.allocator;
    var driver = Ft2232Driver.init(allocator);
    defer driver.deinit();

    try std.testing.expect(!driver.connected);
}

test "ft2232 connect" {
    const allocator = std.testing.allocator;
    var driver = Ft2232Driver.init(allocator);
    defer driver.deinit();

    try driver.connect(0);
    try std.testing.expect(driver.connected);

    driver.disconnect();
    try std.testing.expect(!driver.connected);
}

test "tms sequence to reset" {
    const seq = getTmsSequence(.run_test_idle, .test_logic_reset);

    try std.testing.expectEqual(@as(u4, 5), seq.len);
    try std.testing.expectEqual(@as(u8, 0x1F), seq.bits);
}

test "tms sequence run to shift dr" {
    const seq = getTmsSequence(.run_test_idle, .shift_dr);

    try std.testing.expectEqual(@as(u4, 3), seq.len);
    try std.testing.expectEqual(@as(u8, 0x01), seq.bits);
}

test "tms sequence same state" {
    const seq = getTmsSequence(.shift_dr, .shift_dr);

    try std.testing.expectEqual(@as(u4, 0), seq.len);
}

test "mpsse commands" {
    // Verify command bytes
    try std.testing.expectEqual(@as(u8, 0x11), MpsseCmd.WRITE_BYTES_MSB_FALLING);
    try std.testing.expectEqual(@as(u8, 0x31), MpsseCmd.WRITE_READ_BYTES_MSB);
    try std.testing.expectEqual(@as(u8, 0x86), MpsseCmd.SET_DIVISOR);
    try std.testing.expectEqual(@as(u8, 0x87), MpsseCmd.SEND_IMMEDIATE);
}

test "jtag pin assignments" {
    // Verify pin bits don't overlap
    const all_pins = JtagPins.TCK | JtagPins.TDI | JtagPins.TDO | JtagPins.TMS | JtagPins.TRST | JtagPins.SRST;
    try std.testing.expectEqual(@as(u8, 0x3F), all_pins);
}

test "ft2232 gpio initial state" {
    const allocator = std.testing.allocator;
    var driver = Ft2232Driver.init(allocator);
    defer driver.deinit();

    try driver.connect(0);

    // TRST and SRST should be high (inactive)
    try std.testing.expect((driver.gpio_low & JtagPins.TRST) != 0);
    try std.testing.expect((driver.gpio_low & JtagPins.SRST) != 0);
}
