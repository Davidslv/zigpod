//! JTAG Bridge for ZigPod Hardware Debugging
//!
//! High-level interface for debugging iPod hardware via JTAG.
//! Supports memory reads, register access, and debug operations.

const std = @import("std");
const arm_jtag = @import("arm_jtag.zig");
const ft2232_driver = @import("ft2232_driver.zig");

const Arm7Debug = arm_jtag.Arm7Debug;
const ArmJtagInterface = arm_jtag.ArmJtagInterface;
const DebugStatus = arm_jtag.DebugStatus;
const MockJtag = arm_jtag.MockJtag;
const Ft2232Driver = ft2232_driver.Ft2232Driver;

/// JTAG bridge errors
pub const BridgeError = error{
    NotConnected,
    DeviceNotFound,
    ConnectionFailed,
    CpuNotHalted,
    MemoryReadFailed,
    RegisterReadFailed,
    Timeout,
    InvalidAddress,
    UnsupportedOperation,
};

/// ARM7TDMI register names
pub const CpuRegister = enum(u4) {
    r0 = 0,
    r1 = 1,
    r2 = 2,
    r3 = 3,
    r4 = 4,
    r5 = 5,
    r6 = 6,
    r7 = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    sp = 13, // R13
    lr = 14, // R14
    pc = 15, // R15
};

/// CPU state snapshot
pub const CpuState = struct {
    r: [16]u32 = [_]u32{0} ** 16,
    cpsr: u32 = 0,
    halted: bool = false,

    pub fn getRegister(self: *const CpuState, reg: CpuRegister) u32 {
        return self.r[@intFromEnum(reg)];
    }

    pub fn format(self: *const CpuState, writer: anytype) !void {
        try writer.print("CPU State (halted: {}):\n", .{self.halted});
        for (0..16) |i| {
            const name = switch (i) {
                13 => "SP",
                14 => "LR",
                15 => "PC",
                else => null,
            };
            if (name) |n| {
                try writer.print("  {s}: 0x{X:0>8}\n", .{ n, self.r[i] });
            } else {
                try writer.print("  R{d}: 0x{X:0>8}\n", .{ i, self.r[i] });
            }
        }
        try writer.print("  CPSR: 0x{X:0>8}\n", .{self.cpsr});
    }
};

/// Memory region for validation
pub const MemoryRegion = struct {
    name: []const u8,
    start: u32,
    end: u32,
    readable: bool = true,
    writable: bool = false,
};

/// PP5021C memory map
pub const PP5021_REGIONS = [_]MemoryRegion{
    .{ .name = "IRAM", .start = 0x40000000, .end = 0x40060000, .readable = true, .writable = true },
    .{ .name = "DRAM", .start = 0x10000000, .end = 0x12000000, .readable = true, .writable = true },
    .{ .name = "Flash", .start = 0x20000000, .end = 0x20100000, .readable = true },
    .{ .name = "Peripherals", .start = 0x60000000, .end = 0x70000000, .readable = true },
    .{ .name = "ROM", .start = 0x00000000, .end = 0x00010000, .readable = true },
};

/// JTAG Bridge backend type
pub const BackendType = enum {
    mock,
    ft2232,
};

/// JTAG Bridge
pub const JtagBridge = struct {
    /// Backend driver
    backend: union(BackendType) {
        mock: MockJtag,
        ft2232: Ft2232Driver,
    },
    /// JTAG interface
    jtag_iface: ArmJtagInterface,
    /// ARM debug interface
    arm_debug: Arm7Debug,
    /// Connection state
    connected: bool = false,
    /// Last known CPU state
    cpu_state: CpuState = .{},
    /// Allocator
    allocator: std.mem.Allocator,
    /// Read buffer for memory operations
    read_buffer: []u8,

    const Self = @This();

    /// Create a new JTAG bridge with mock backend (for testing)
    pub fn initMock(allocator: std.mem.Allocator) !Self {
        var self: Self = undefined;
        self.allocator = allocator;
        self.backend = .{ .mock = MockJtag.create(allocator) };
        self.jtag_iface = self.backend.mock.getInterface();
        self.arm_debug = Arm7Debug.init(allocator, &self.jtag_iface);
        self.connected = false;
        self.cpu_state = .{};
        self.read_buffer = try allocator.alloc(u8, 4096);
        return self;
    }

    /// Create a new JTAG bridge with FT2232 backend
    pub fn initFt2232(allocator: std.mem.Allocator) !Self {
        var self: Self = undefined;
        self.allocator = allocator;
        self.backend = .{ .ft2232 = Ft2232Driver.init(allocator) };
        self.jtag_iface = self.backend.ft2232.getInterface();
        self.arm_debug = Arm7Debug.init(allocator, &self.jtag_iface);
        self.connected = false;
        self.cpu_state = .{};
        self.read_buffer = try allocator.alloc(u8, 4096);
        return self;
    }

    /// Cleanup
    pub fn deinit(self: *Self) void {
        self.disconnect();
        self.allocator.free(self.read_buffer);
        switch (self.backend) {
            .mock => {},
            .ft2232 => self.backend.ft2232.deinit(),
        }
    }

    /// Connect to target device
    pub fn connect(self: *Self) BridgeError!void {
        switch (self.backend) {
            .mock => {
                self.connected = true;
            },
            .ft2232 => {
                self.backend.ft2232.connect(0) catch return BridgeError.ConnectionFailed;
                self.backend.ft2232.setFrequency(1_000_000) catch return BridgeError.ConnectionFailed;
                self.connected = true;
            },
        }

        // Reset TAP
        self.jtag_iface.reset() catch return BridgeError.ConnectionFailed;
    }

    /// Disconnect from target
    pub fn disconnect(self: *Self) void {
        switch (self.backend) {
            .mock => {},
            .ft2232 => self.backend.ft2232.disconnect(),
        }
        self.connected = false;
    }

    /// Halt the CPU
    pub fn halt(self: *Self) BridgeError!void {
        if (!self.connected) return BridgeError.NotConnected;

        self.arm_debug.halt() catch return BridgeError.Timeout;
        self.cpu_state.halted = true;
    }

    /// Resume CPU execution
    pub fn resumeCpu(self: *Self) BridgeError!void {
        if (!self.connected) return BridgeError.NotConnected;

        self.arm_debug.resumeCpu() catch return BridgeError.UnsupportedOperation;
        self.cpu_state.halted = false;
    }

    /// Check if CPU is halted
    pub fn isHalted(self: *Self) BridgeError!bool {
        if (!self.connected) return BridgeError.NotConnected;

        const status = self.arm_debug.readDebugStatus() catch return BridgeError.UnsupportedOperation;
        return status.halted;
    }

    /// Read CPU registers (requires halted CPU)
    pub fn readRegisters(self: *Self) BridgeError!CpuState {
        if (!self.connected) return BridgeError.NotConnected;

        if (!try self.isHalted()) {
            return BridgeError.CpuNotHalted;
        }

        // Reading registers via JTAG requires instruction insertion
        // This is a simplified implementation
        return self.cpu_state;
    }

    /// Read a single register
    pub fn readRegister(self: *Self, reg: CpuRegister) BridgeError!u32 {
        if (!self.connected) return BridgeError.NotConnected;

        if (!try self.isHalted()) {
            return BridgeError.CpuNotHalted;
        }

        return self.cpu_state.r[@intFromEnum(reg)];
    }

    /// Read memory
    pub fn readMemory(self: *Self, address: u32, length: usize) BridgeError![]const u8 {
        if (!self.connected) return BridgeError.NotConnected;

        // Validate address range
        if (!self.isAddressReadable(address)) {
            return BridgeError.InvalidAddress;
        }

        if (length > self.read_buffer.len) {
            return BridgeError.MemoryReadFailed;
        }

        // Memory read via JTAG would use DCC or instruction insertion
        // For now, return zeroed data
        @memset(self.read_buffer[0..length], 0);
        return self.read_buffer[0..length];
    }

    /// Read a 32-bit word from memory
    pub fn readWord(self: *Self, address: u32) BridgeError!u32 {
        const data = try self.readMemory(address, 4);
        return std.mem.readInt(u32, data[0..4], .little);
    }

    /// Check if address is in a readable region
    pub fn isAddressReadable(self: *Self, address: u32) bool {
        _ = self;
        for (PP5021_REGIONS) |region| {
            if (address >= region.start and address < region.end and region.readable) {
                return true;
            }
        }
        return false;
    }

    /// Check if address is in a writable region
    pub fn isAddressWritable(self: *Self, address: u32) bool {
        _ = self;
        for (PP5021_REGIONS) |region| {
            if (address >= region.start and address < region.end and region.writable) {
                return true;
            }
        }
        return false;
    }

    /// Get region name for address
    pub fn getRegionName(self: *Self, address: u32) ?[]const u8 {
        _ = self;
        for (PP5021_REGIONS) |region| {
            if (address >= region.start and address < region.end) {
                return region.name;
            }
        }
        return null;
    }

    /// Dump memory to a file
    pub fn dumpMemoryToFile(self: *Self, address: u32, length: usize, path: []const u8) BridgeError!void {
        if (!self.connected) return BridgeError.NotConnected;

        const file = std.fs.cwd().createFile(path, .{}) catch return BridgeError.MemoryReadFailed;
        defer file.close();

        var offset: usize = 0;
        while (offset < length) {
            const chunk_size = @min(self.read_buffer.len, length - offset);
            const data = try self.readMemory(address + @as(u32, @intCast(offset)), chunk_size);
            file.writeAll(data) catch return BridgeError.MemoryReadFailed;
            offset += chunk_size;
        }
    }

    /// Print CPU state to writer
    pub fn printCpuState(self: *Self, writer: anytype) !void {
        try self.cpu_state.format(writer);
    }

    /// Print memory map
    pub fn printMemoryMap(writer: anytype) !void {
        try writer.print("PP5021C Memory Map:\n", .{});
        try writer.print("{s:<15} {s:<12} {s:<12} {s}\n", .{ "Region", "Start", "End", "Access" });
        try writer.print("{s}\n", .{"-" ** 50});
        for (PP5021_REGIONS) |region| {
            const access = if (region.readable and region.writable) "R/W" else if (region.readable) "R" else "W";
            try writer.print("{s:<15} 0x{X:0>8}   0x{X:0>8}   {s}\n", .{
                region.name,
                region.start,
                region.end,
                access,
            });
        }
    }
};

// ============================================================
// Tests
// ============================================================

test "jtag bridge mock init" {
    const allocator = std.testing.allocator;
    var bridge = try JtagBridge.initMock(allocator);
    defer bridge.deinit();

    try std.testing.expect(!bridge.connected);
}

test "jtag bridge connect" {
    const allocator = std.testing.allocator;
    var bridge = try JtagBridge.initMock(allocator);
    defer bridge.deinit();

    try bridge.connect();
    try std.testing.expect(bridge.connected);

    bridge.disconnect();
    try std.testing.expect(!bridge.connected);
}

test "cpu state format" {
    var state = CpuState{};
    state.r[15] = 0x40000100;
    state.r[13] = 0x40050000;
    state.halted = true;

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try state.format(stream.writer());

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "halted: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC: 0x40000100") != null);
}

test "memory region readable" {
    const allocator = std.testing.allocator;
    var bridge = try JtagBridge.initMock(allocator);
    defer bridge.deinit();

    // IRAM should be readable
    try std.testing.expect(bridge.isAddressReadable(0x40000000));
    try std.testing.expect(bridge.isAddressReadable(0x40001000));

    // Invalid address should not be readable
    try std.testing.expect(!bridge.isAddressReadable(0x80000000));
}

test "memory region writable" {
    const allocator = std.testing.allocator;
    var bridge = try JtagBridge.initMock(allocator);
    defer bridge.deinit();

    // IRAM should be writable
    try std.testing.expect(bridge.isAddressWritable(0x40000000));

    // ROM should not be writable
    try std.testing.expect(!bridge.isAddressWritable(0x00000000));

    // Flash should not be writable
    try std.testing.expect(!bridge.isAddressWritable(0x20000000));
}

test "region name lookup" {
    const allocator = std.testing.allocator;
    var bridge = try JtagBridge.initMock(allocator);
    defer bridge.deinit();

    try std.testing.expectEqualStrings("IRAM", bridge.getRegionName(0x40000000).?);
    try std.testing.expectEqualStrings("DRAM", bridge.getRegionName(0x10000000).?);
    try std.testing.expectEqualStrings("ROM", bridge.getRegionName(0x00000100).?);
    try std.testing.expect(bridge.getRegionName(0x80000000) == null);
}

test "cpu register enum" {
    try std.testing.expectEqual(@as(u4, 13), @intFromEnum(CpuRegister.sp));
    try std.testing.expectEqual(@as(u4, 14), @intFromEnum(CpuRegister.lr));
    try std.testing.expectEqual(@as(u4, 15), @intFromEnum(CpuRegister.pc));
}

test "not connected errors" {
    const allocator = std.testing.allocator;
    var bridge = try JtagBridge.initMock(allocator);
    defer bridge.deinit();

    // Should fail when not connected
    try std.testing.expectError(BridgeError.NotConnected, bridge.halt());
    try std.testing.expectError(BridgeError.NotConnected, bridge.resumeCpu());
    try std.testing.expectError(BridgeError.NotConnected, bridge.readMemory(0x40000000, 256));
}

test "memory map print" {
    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try JtagBridge.printMemoryMap(stream.writer());

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "IRAM") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "DRAM") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ROM") != null);
}
