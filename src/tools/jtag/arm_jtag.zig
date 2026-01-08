//! ARM7TDMI JTAG Protocol Implementation
//!
//! Implements the ARM7TDMI debug interface via JTAG.
//! Provides low-level operations for debugging ARM cores.

const std = @import("std");

/// ARM7TDMI JTAG Instructions
pub const JtagInstruction = enum(u4) {
    /// Bypass - default instruction
    bypass = 0xF,
    /// Select scan chain
    scan_n = 0x2,
    /// Access instruction register
    intest = 0xC,
    /// Access debug register
    restart = 0x4,
    /// ID code register
    idcode = 0xE,
    /// Halt the core
    halt = 0x8,
};

/// ARM7TDMI Scan Chains
pub const ScanChain = enum(u4) {
    /// Debug control/status
    debug = 0,
    /// Debug comms channel
    dcc = 1,
    /// Embedded ICE watchpoint unit
    embedded_ice = 2,
};

/// Debug status bits
pub const DebugStatus = struct {
    /// Core is halted in debug state
    halted: bool = false,
    /// Watchpoint 0 triggered
    wp0_triggered: bool = false,
    /// Watchpoint 1 triggered
    wp1_triggered: bool = false,
    /// DBGACK signal state
    dbgack: bool = false,
    /// DBGRQ signal state
    dbgrq: bool = false,
    /// Interrupt disabled during debug
    int_dis: bool = false,
    /// SYSCOMP (system speed access complete)
    syscomp: bool = false,

    pub fn fromBits(bits: u32) DebugStatus {
        return .{
            .halted = (bits & 0x01) != 0,
            .wp0_triggered = (bits & 0x02) != 0,
            .wp1_triggered = (bits & 0x04) != 0,
            .dbgack = (bits & 0x08) != 0,
            .dbgrq = (bits & 0x10) != 0,
            .int_dis = (bits & 0x20) != 0,
            .syscomp = (bits & 0x40) != 0,
        };
    }

    pub fn toBits(self: DebugStatus) u32 {
        var bits: u32 = 0;
        if (self.halted) bits |= 0x01;
        if (self.wp0_triggered) bits |= 0x02;
        if (self.wp1_triggered) bits |= 0x04;
        if (self.dbgack) bits |= 0x08;
        if (self.dbgrq) bits |= 0x10;
        if (self.int_dis) bits |= 0x20;
        if (self.syscomp) bits |= 0x40;
        return bits;
    }
};

/// Embedded ICE registers
pub const EmbeddedIceReg = enum(u5) {
    /// Debug control register
    debug_ctrl = 0,
    /// Debug status register
    debug_status = 1,
    /// Vector catch register
    vector_catch = 2,
    /// Debug comms control register
    dcc_ctrl = 4,
    /// Debug comms data register
    dcc_data = 5,
    /// Watchpoint 0 address value
    wp0_addr_value = 8,
    /// Watchpoint 0 address mask
    wp0_addr_mask = 9,
    /// Watchpoint 0 data value
    wp0_data_value = 10,
    /// Watchpoint 0 data mask
    wp0_data_mask = 11,
    /// Watchpoint 0 control value
    wp0_ctrl_value = 12,
    /// Watchpoint 0 control mask
    wp0_ctrl_mask = 13,
    /// Watchpoint 1 address value
    wp1_addr_value = 16,
    /// Watchpoint 1 address mask
    wp1_addr_mask = 17,
    /// Watchpoint 1 data value
    wp1_data_value = 18,
    /// Watchpoint 1 data mask
    wp1_data_mask = 19,
    /// Watchpoint 1 control value
    wp1_ctrl_value = 20,
    /// Watchpoint 1 control mask
    wp1_ctrl_mask = 21,
};

/// Debug control register bits
pub const DebugCtrl = struct {
    /// Enable debug mode
    dbgen: bool = false,
    /// Enable monitor mode (vs halt mode)
    mon_en: bool = false,
    /// Disable interrupts during single step
    int_dis: bool = false,
    /// Debug request
    dbgrq: bool = false,

    pub fn fromBits(bits: u32) DebugCtrl {
        return .{
            .dbgen = (bits & 0x01) != 0,
            .mon_en = (bits & 0x02) != 0,
            .int_dis = (bits & 0x04) != 0,
            .dbgrq = (bits & 0x08) != 0,
        };
    }

    pub fn toBits(self: DebugCtrl) u32 {
        var bits: u32 = 0;
        if (self.dbgen) bits |= 0x01;
        if (self.mon_en) bits |= 0x02;
        if (self.int_dis) bits |= 0x04;
        if (self.dbgrq) bits |= 0x08;
        return bits;
    }
};

/// TAP State Machine states
pub const TapState = enum {
    test_logic_reset,
    run_test_idle,
    select_dr_scan,
    capture_dr,
    shift_dr,
    exit1_dr,
    pause_dr,
    exit2_dr,
    update_dr,
    select_ir_scan,
    capture_ir,
    shift_ir,
    exit1_ir,
    pause_ir,
    exit2_ir,
    update_ir,
};

/// ARM JTAG Interface (abstract - to be implemented by hardware driver)
pub const ArmJtagInterface = struct {
    /// VTable for JTAG operations
    pub const VTable = struct {
        /// Send TMS/TDI sequence, return TDO
        shift: *const fn (*anyopaque, bits: []const u8, tms: []const u8, len: usize) anyerror![]u8,
        /// Reset TAP to Test-Logic-Reset
        reset: *const fn (*anyopaque) anyerror!void,
        /// Get current TAP state
        getState: *const fn (*anyopaque) TapState,
    };

    vtable: *const VTable,
    context: *anyopaque,

    const Self = @This();

    /// Shift bits through JTAG
    pub fn shift(self: *Self, bits: []const u8, tms: []const u8, len: usize) ![]u8 {
        return self.vtable.shift(self.context, bits, tms, len);
    }

    /// Reset TAP
    pub fn reset(self: *Self) !void {
        return self.vtable.reset(self.context);
    }

    /// Get TAP state
    pub fn getState(self: *Self) TapState {
        return self.vtable.getState(self.context);
    }
};

/// ARM7TDMI Debug Interface
pub const Arm7Debug = struct {
    jtag: *ArmJtagInterface,
    current_chain: ?ScanChain = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create ARM debug interface
    pub fn init(allocator: std.mem.Allocator, jtag: *ArmJtagInterface) Self {
        return .{
            .jtag = jtag,
            .allocator = allocator,
        };
    }

    /// Select a scan chain
    pub fn selectScanChain(self: *Self, chain: ScanChain) !void {
        // Write SCAN_N instruction
        try self.writeIR(@intFromEnum(JtagInstruction.scan_n));

        // Write chain number to DR
        var chain_bits = [_]u8{@intFromEnum(chain)};
        const result = try self.shiftDR(&chain_bits, 4);
        self.allocator.free(result);

        self.current_chain = chain;
    }

    /// Read Embedded ICE register
    pub fn readEmbeddedIce(self: *Self, reg: EmbeddedIceReg) !u32 {
        if (self.current_chain != .embedded_ice) {
            try self.selectScanChain(.embedded_ice);
        }

        // Embedded ICE scan chain is 38 bits:
        // [37:6] = data (32 bits)
        // [5:1] = register address (5 bits)
        // [0] = R/W (0 = read, 1 = write)

        // First shift: set address, R/W = 0 (read)
        var scan_data = [_]u8{ @intFromEnum(reg) << 1, 0, 0, 0, 0 }; // 38 bits
        const addr_result = try self.shiftDR(&scan_data, 38);
        self.allocator.free(addr_result);

        // Second shift: clock out the data
        @memset(&scan_data, 0);
        const result = try self.shiftDR(&scan_data, 38);
        defer self.allocator.free(result);

        // Extract 32-bit value from bits [37:6]
        const data = std.mem.readInt(u32, result[0..4], .little) >> 6;
        return data;
    }

    /// Write Embedded ICE register
    pub fn writeEmbeddedIce(self: *Self, reg: EmbeddedIceReg, value: u32) !void {
        if (self.current_chain != .embedded_ice) {
            try self.selectScanChain(.embedded_ice);
        }

        // Format: [data:32][addr:5][r/w:1] = 38 bits
        var scan_data: [5]u8 = undefined;

        // Pack the data: R/W = 1 (write), address, data
        const packed_val = (@as(u64, value) << 6) | (@as(u64, @intFromEnum(reg)) << 1) | 1;
        std.mem.writeInt(u40, &scan_data, @truncate(packed_val), .little);

        const write_result = try self.shiftDR(&scan_data, 38);
        self.allocator.free(write_result);
    }

    /// Read debug status
    pub fn readDebugStatus(self: *Self) !DebugStatus {
        const bits = try self.readEmbeddedIce(.debug_status);
        return DebugStatus.fromBits(bits);
    }

    /// Write debug control
    pub fn writeDebugControl(self: *Self, ctrl: DebugCtrl) !void {
        try self.writeEmbeddedIce(.debug_ctrl, ctrl.toBits());
    }

    /// Halt the CPU
    pub fn halt(self: *Self) !void {
        var ctrl = DebugCtrl{};
        ctrl.dbgen = true;
        ctrl.dbgrq = true;
        try self.writeDebugControl(ctrl);

        // Wait for halt
        var attempts: u32 = 0;
        while (attempts < 1000) : (attempts += 1) {
            const status = try self.readDebugStatus();
            if (status.halted) return;
            std.Thread.sleep(1_000_000); // 1ms
        }
        return error.HaltTimeout;
    }

    /// Resume execution
    pub fn resumeCpu(self: *Self) !void {
        // Clear DBGRQ
        var ctrl = DebugCtrl{};
        ctrl.dbgen = true;
        ctrl.dbgrq = false;
        try self.writeDebugControl(ctrl);

        // Issue RESTART instruction
        try self.writeIR(@intFromEnum(JtagInstruction.restart));
    }

    /// Read a CPU register (requires halted CPU)
    pub fn readRegister(_: *Self, _: u4) !u32 {
        // This requires executing ARM instructions in debug state
        // The typical approach is:
        // 1. Execute STR Rn, [R0] with R0 pointing to scan chain
        // 2. Clock out the data via INTEST

        // Simplified: use debug comms channel if available
        return error.NotImplemented;
    }

    /// Read memory (requires halted CPU)
    pub fn readMemory(_: *Self, _: u32, _: usize) ![]u8 {
        // Memory reads via JTAG require:
        // 1. Setting up the DCC or using instruction insertion
        // 2. Executing LDR/STR sequences
        return error.NotImplemented;
    }

    /// Write IR (instruction register)
    fn writeIR(self: *Self, instruction: u4) !void {
        // Navigate to Shift-IR and shift instruction
        var instr_bits = [_]u8{instruction};
        var tms_bits = [_]u8{0}; // Stay in Shift-IR until last bit
        const result = try self.jtag.shift(&instr_bits, &tms_bits, 4);
        self.allocator.free(result);
    }

    /// Shift data register
    fn shiftDR(self: *Self, data: []u8, bits: usize) ![]u8 {
        // Navigate to Shift-DR and shift data
        const tms = try self.allocator.alloc(u8, (bits + 7) / 8);
        defer self.allocator.free(tms);
        @memset(tms, 0);
        return try self.jtag.shift(data, tms, bits);
    }
};

/// Mock JTAG interface for testing
pub const MockJtag = struct {
    state: TapState = .test_logic_reset,
    shift_count: u32 = 0,
    last_ir: u4 = 0xF,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn getInterface(self: *Self) ArmJtagInterface {
        return .{
            .vtable = &vtable,
            .context = self,
        };
    }

    fn shiftImpl(ctx: *anyopaque, bits: []const u8, _: []const u8, len: usize) anyerror![]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.shift_count += 1;

        // Return zeroed data for now
        const byte_len = (len + 7) / 8;
        const result = try self.allocator.alloc(u8, byte_len);
        @memset(result, 0);

        // Echo back input for some cases
        if (len <= bits.len * 8) {
            @memcpy(result[0..@min(byte_len, bits.len)], bits[0..@min(byte_len, bits.len)]);
        }

        return result;
    }

    fn resetImpl(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.state = .test_logic_reset;
        self.last_ir = 0xF;
    }

    fn getStateImpl(ctx: *anyopaque) TapState {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.state;
    }

    const vtable = ArmJtagInterface.VTable{
        .shift = shiftImpl,
        .reset = resetImpl,
        .getState = getStateImpl,
    };
};

// ============================================================
// Tests
// ============================================================

test "debug status from bits" {
    const status = DebugStatus.fromBits(0x4B);

    try std.testing.expect(status.halted);
    try std.testing.expect(status.wp0_triggered);
    try std.testing.expect(!status.wp1_triggered);
    try std.testing.expect(status.dbgack);
    try std.testing.expect(!status.dbgrq);
    try std.testing.expect(!status.int_dis);
    try std.testing.expect(status.syscomp);
}

test "debug status to bits" {
    var status = DebugStatus{};
    status.halted = true;
    status.dbgack = true;

    try std.testing.expectEqual(@as(u32, 0x09), status.toBits());
}

test "debug control from bits" {
    const ctrl = DebugCtrl.fromBits(0x0D);

    try std.testing.expect(ctrl.dbgen);
    try std.testing.expect(!ctrl.mon_en);
    try std.testing.expect(ctrl.int_dis);
    try std.testing.expect(ctrl.dbgrq);
}

test "debug control to bits" {
    var ctrl = DebugCtrl{};
    ctrl.dbgen = true;
    ctrl.dbgrq = true;

    try std.testing.expectEqual(@as(u32, 0x09), ctrl.toBits());
}

test "mock jtag reset" {
    const allocator = std.testing.allocator;
    var mock = MockJtag.create(allocator);
    var iface = mock.getInterface();

    mock.state = .run_test_idle;
    try iface.reset();

    try std.testing.expectEqual(TapState.test_logic_reset, mock.state);
}

test "mock jtag shift" {
    const allocator = std.testing.allocator;
    var mock = MockJtag.create(allocator);
    var iface = mock.getInterface();

    var data = [_]u8{ 0xAB, 0xCD };
    var tms = [_]u8{ 0, 0 };

    const result = try iface.shift(&data, &tms, 16);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(u32, 1), mock.shift_count);
    try std.testing.expectEqual(@as(u8, 0xAB), result[0]);
}

test "arm7 debug select chain" {
    const allocator = std.testing.allocator;
    var mock = MockJtag.create(allocator);
    var iface = mock.getInterface();

    var debug = Arm7Debug.init(allocator, &iface);

    try debug.selectScanChain(.embedded_ice);

    try std.testing.expectEqual(ScanChain.embedded_ice, debug.current_chain.?);
}

test "embedded ice register addresses" {
    // Verify register enumeration values
    try std.testing.expectEqual(@as(u5, 0), @intFromEnum(EmbeddedIceReg.debug_ctrl));
    try std.testing.expectEqual(@as(u5, 1), @intFromEnum(EmbeddedIceReg.debug_status));
    try std.testing.expectEqual(@as(u5, 8), @intFromEnum(EmbeddedIceReg.wp0_addr_value));
    try std.testing.expectEqual(@as(u5, 16), @intFromEnum(EmbeddedIceReg.wp1_addr_value));
}

test "jtag instruction values" {
    try std.testing.expectEqual(@as(u4, 0xF), @intFromEnum(JtagInstruction.bypass));
    try std.testing.expectEqual(@as(u4, 0x2), @intFromEnum(JtagInstruction.scan_n));
    try std.testing.expectEqual(@as(u4, 0xE), @intFromEnum(JtagInstruction.idcode));
}
