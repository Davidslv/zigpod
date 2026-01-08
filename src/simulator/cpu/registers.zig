//! ARM7TDMI Register File
//!
//! Implements the complete ARM7TDMI register set including:
//! - 16 general purpose registers (R0-R15)
//! - Current Program Status Register (CPSR)
//! - Saved Program Status Registers (SPSR) for each mode
//! - Banked registers for FIQ, IRQ, SVC, ABT, UND modes

const std = @import("std");

/// ARM7TDMI processor modes
pub const Mode = enum(u5) {
    user = 0b10000,
    fiq = 0b10001,
    irq = 0b10010,
    supervisor = 0b10011,
    abort = 0b10111,
    undefined = 0b11011,
    system = 0b11111,

    /// Convert mode bits to array index for banked registers
    pub fn bankIndex(self: Mode) usize {
        return switch (self) {
            .user, .system => 0,
            .fiq => 1,
            .irq => 2,
            .supervisor => 3,
            .abort => 4,
            .undefined => 5,
        };
    }

    /// Check if mode is privileged
    pub fn isPrivileged(self: Mode) bool {
        return self != .user;
    }

    /// Get mode from CPSR bits
    pub fn fromBits(bits: u5) ?Mode {
        return switch (bits) {
            0b10000 => .user,
            0b10001 => .fiq,
            0b10010 => .irq,
            0b10011 => .supervisor,
            0b10111 => .abort,
            0b11011 => .undefined,
            0b11111 => .system,
            else => null,
        };
    }
};

/// Program Status Register (PSR) bit layout
pub const Psr = packed struct(u32) {
    /// Processor mode bits [4:0]
    mode: u5,
    /// Thumb state bit [5]
    thumb: bool,
    /// FIQ disable bit [6]
    fiq_disable: bool,
    /// IRQ disable bit [7]
    irq_disable: bool,
    /// Reserved bits [27:8]
    reserved: u20 = 0,
    /// Overflow flag [28]
    v: bool,
    /// Carry flag [29]
    c: bool,
    /// Zero flag [30]
    z: bool,
    /// Negative flag [31]
    n: bool,

    /// Create PSR from raw u32 value
    pub fn fromU32(value: u32) Psr {
        return @bitCast(value);
    }

    /// Convert PSR to raw u32 value
    pub fn toU32(self: Psr) u32 {
        return @bitCast(self);
    }

    /// Get the processor mode
    pub fn getMode(self: Psr) ?Mode {
        return Mode.fromBits(self.mode);
    }

    /// Set the processor mode
    pub fn setMode(self: *Psr, mode: Mode) void {
        self.mode = @intFromEnum(mode);
    }

    /// Set condition flags from ALU result
    pub fn setNZ(self: *Psr, result: u32) void {
        self.n = (result & 0x80000000) != 0;
        self.z = result == 0;
    }

    /// Set carry flag for addition
    pub fn setCarryAdd(self: *Psr, a: u32, b: u32, result: u64) void {
        _ = a;
        _ = b;
        self.c = result > 0xFFFFFFFF;
    }

    /// Set overflow flag for addition
    pub fn setOverflowAdd(self: *Psr, a: u32, b: u32, result: u32) void {
        // Overflow if both operands same sign and result different sign
        const a_neg = (a & 0x80000000) != 0;
        const b_neg = (b & 0x80000000) != 0;
        const r_neg = (result & 0x80000000) != 0;
        self.v = (a_neg == b_neg) and (a_neg != r_neg);
    }

    /// Set carry flag for subtraction (a - b)
    pub fn setCarrySub(self: *Psr, a: u32, b: u32) void {
        self.c = a >= b;
    }

    /// Set overflow flag for subtraction (a - b)
    pub fn setOverflowSub(self: *Psr, a: u32, b: u32, result: u32) void {
        // Overflow if operands different sign and result sign differs from first operand
        const a_neg = (a & 0x80000000) != 0;
        const b_neg = (b & 0x80000000) != 0;
        const r_neg = (result & 0x80000000) != 0;
        self.v = (a_neg != b_neg) and (a_neg != r_neg);
    }
};

/// ARM7TDMI Register File
pub const RegisterFile = struct {
    /// General purpose registers R0-R15
    /// R13 = SP (Stack Pointer)
    /// R14 = LR (Link Register)
    /// R15 = PC (Program Counter)
    r: [16]u32,

    /// Current Program Status Register
    cpsr: Psr,

    /// Banked R13 (SP) for each mode: User/Sys, FIQ, IRQ, SVC, ABT, UND
    banked_r13: [6]u32,

    /// Banked R14 (LR) for each mode: User/Sys, FIQ, IRQ, SVC, ABT, UND
    banked_r14: [6]u32,

    /// Banked R8-R12 for FIQ mode (index 0 = User/Sys, index 1 = FIQ)
    banked_r8_12: [2][5]u32,

    /// Saved Program Status Registers for each mode (no SPSR for User/System)
    /// Index: 0=unused, 1=FIQ, 2=IRQ, 3=SVC, 4=ABT, 5=UND
    spsr: [6]Psr,

    /// Previous mode before last mode switch (for debugging)
    previous_mode: ?Mode,

    const Self = @This();

    /// Initialize register file with reset values
    pub fn init() Self {
        const regs = Self{
            .r = [_]u32{0} ** 16,
            .cpsr = Psr{
                .mode = @intFromEnum(Mode.supervisor),
                .thumb = false,
                .fiq_disable = true,
                .irq_disable = true,
                .reserved = 0,
                .v = false,
                .c = false,
                .z = false,
                .n = false,
            },
            .banked_r13 = [_]u32{0} ** 6,
            .banked_r14 = [_]u32{0} ** 6,
            .banked_r8_12 = [_][5]u32{[_]u32{0} ** 5} ** 2,
            .spsr = [_]Psr{@bitCast(@as(u32, 0))} ** 6,
            .previous_mode = null,
        };
        return regs;
    }

    /// Get a register value (handles banked registers based on current mode)
    pub fn get(self: *const Self, reg: u4) u32 {
        if (reg == 15) {
            // PC is current instruction + 8 in ARM mode, + 4 in Thumb
            const offset: u32 = if (self.cpsr.thumb) 4 else 8;
            return self.r[15] +% offset;
        }
        return self.r[reg];
    }

    /// Set a register value (handles banked registers based on current mode)
    pub fn set(self: *Self, reg: u4, value: u32) void {
        if (reg == 15) {
            // Writing to PC - clear thumb bit alignment
            if (self.cpsr.thumb) {
                self.r[15] = value & ~@as(u32, 1);
            } else {
                self.r[15] = value & ~@as(u32, 3);
            }
        } else {
            self.r[reg] = value;
        }
    }

    /// Get the current Program Counter
    pub fn getPC(self: *const Self) u32 {
        return self.r[15];
    }

    /// Set the Program Counter
    pub fn setPC(self: *Self, value: u32) void {
        if (self.cpsr.thumb) {
            self.r[15] = value & ~@as(u32, 1);
        } else {
            self.r[15] = value & ~@as(u32, 3);
        }
    }

    /// Get the Stack Pointer
    pub fn getSP(self: *const Self) u32 {
        return self.r[13];
    }

    /// Set the Stack Pointer
    pub fn setSP(self: *Self, value: u32) void {
        self.r[13] = value;
    }

    /// Get the Link Register
    pub fn getLR(self: *const Self) u32 {
        return self.r[14];
    }

    /// Set the Link Register
    pub fn setLR(self: *Self, value: u32) void {
        self.r[14] = value;
    }

    /// Get the current processor mode
    pub fn getMode(self: *const Self) Mode {
        return self.cpsr.getMode() orelse .user;
    }

    /// Switch processor mode, banking registers as needed
    pub fn switchMode(self: *Self, new_mode: Mode) void {
        const old_mode = self.getMode();
        if (old_mode == new_mode) return;

        self.previous_mode = old_mode;

        // Save current R13, R14 to old mode's bank
        const old_bank = old_mode.bankIndex();
        self.banked_r13[old_bank] = self.r[13];
        self.banked_r14[old_bank] = self.r[14];

        // Handle FIQ banked R8-R12
        if (old_mode == .fiq) {
            // Save FIQ R8-R12 to FIQ bank, restore User R8-R12
            for (0..5) |i| {
                self.banked_r8_12[1][i] = self.r[8 + i];
                self.r[8 + i] = self.banked_r8_12[0][i];
            }
        } else if (new_mode == .fiq) {
            // Save User R8-R12, restore FIQ R8-R12
            for (0..5) |i| {
                self.banked_r8_12[0][i] = self.r[8 + i];
                self.r[8 + i] = self.banked_r8_12[1][i];
            }
        }

        // Restore R13, R14 from new mode's bank
        const new_bank = new_mode.bankIndex();
        self.r[13] = self.banked_r13[new_bank];
        self.r[14] = self.banked_r14[new_bank];

        // Update CPSR mode bits
        self.cpsr.setMode(new_mode);
    }

    /// Get SPSR for current mode (returns null for User/System modes)
    pub fn getSPSR(self: *const Self) ?Psr {
        const mode = self.getMode();
        if (mode == .user or mode == .system) return null;
        return self.spsr[mode.bankIndex()];
    }

    /// Set SPSR for current mode (no-op for User/System modes)
    pub fn setSPSR(self: *Self, value: Psr) void {
        const mode = self.getMode();
        if (mode == .user or mode == .system) return;
        self.spsr[mode.bankIndex()] = value;
    }

    /// Check if IRQs are enabled
    pub fn irqEnabled(self: *const Self) bool {
        return !self.cpsr.irq_disable;
    }

    /// Check if FIQs are enabled
    pub fn fiqEnabled(self: *const Self) bool {
        return !self.cpsr.fiq_disable;
    }

    /// Check if in Thumb state
    pub fn isThumb(self: *const Self) bool {
        return self.cpsr.thumb;
    }

    /// Advance PC by instruction size
    pub fn advancePC(self: *Self) void {
        if (self.cpsr.thumb) {
            self.r[15] +%= 2;
        } else {
            self.r[15] +%= 4;
        }
    }

    /// Format registers for debug output
    pub fn format(
        self: *const Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("ARM7TDMI Registers:\n", .{});
        for (0..16) |i| {
            const name = switch (i) {
                13 => "SP",
                14 => "LR",
                15 => "PC",
                else => "",
            };
            if (name.len > 0) {
                try writer.print("  R{d:2} ({s}): 0x{X:0>8}\n", .{ i, name, self.r[i] });
            } else {
                try writer.print("  R{d:2}:      0x{X:0>8}\n", .{ i, self.r[i] });
            }
        }

        const mode = self.getMode();
        try writer.print("  CPSR: 0x{X:0>8} (Mode: {s}, T:{d} F:{d} I:{d} N:{d} Z:{d} C:{d} V:{d})\n", .{
            self.cpsr.toU32(),
            @tagName(mode),
            @intFromBool(self.cpsr.thumb),
            @intFromBool(self.cpsr.fiq_disable),
            @intFromBool(self.cpsr.irq_disable),
            @intFromBool(self.cpsr.n),
            @intFromBool(self.cpsr.z),
            @intFromBool(self.cpsr.c),
            @intFromBool(self.cpsr.v),
        });
    }
};

// Tests
test "RegisterFile initialization" {
    const regs = RegisterFile.init();

    // All GPRs should be zero
    for (0..16) |i| {
        try std.testing.expectEqual(@as(u32, 0), regs.r[i]);
    }

    // Should start in Supervisor mode with IRQ/FIQ disabled
    try std.testing.expectEqual(Mode.supervisor, regs.getMode());
    try std.testing.expect(regs.cpsr.irq_disable);
    try std.testing.expect(regs.cpsr.fiq_disable);
    try std.testing.expect(!regs.cpsr.thumb);
}

test "RegisterFile mode switching" {
    var regs = RegisterFile.init();

    // Set up SP in Supervisor mode
    regs.r[13] = 0x1000;
    regs.r[14] = 0x2000;

    // Switch to IRQ mode
    regs.switchMode(.irq);
    try std.testing.expectEqual(Mode.irq, regs.getMode());

    // IRQ SP/LR should be zero (not initialized)
    try std.testing.expectEqual(@as(u32, 0), regs.r[13]);
    try std.testing.expectEqual(@as(u32, 0), regs.r[14]);

    // Set IRQ SP/LR
    regs.r[13] = 0x3000;
    regs.r[14] = 0x4000;

    // Switch back to Supervisor
    regs.switchMode(.supervisor);
    try std.testing.expectEqual(Mode.supervisor, regs.getMode());

    // Should have original SVC SP/LR
    try std.testing.expectEqual(@as(u32, 0x1000), regs.r[13]);
    try std.testing.expectEqual(@as(u32, 0x2000), regs.r[14]);
}

test "RegisterFile FIQ banking" {
    var regs = RegisterFile.init();

    // Set R8-R12 in User mode
    for (8..13) |i| {
        regs.r[i] = @intCast(i * 0x100);
    }

    // Switch to FIQ mode
    regs.switchMode(.fiq);

    // FIQ R8-R12 should be zero (banked)
    for (8..13) |i| {
        try std.testing.expectEqual(@as(u32, 0), regs.r[i]);
    }

    // Set FIQ R8-R12
    for (8..13) |i| {
        regs.r[i] = @intCast(i * 0x1000);
    }

    // Switch back to Supervisor (shares R8-R12 with User)
    regs.switchMode(.supervisor);

    // Should have original R8-R12
    for (8..13) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i * 0x100)), regs.r[i]);
    }
}

test "PSR flag operations" {
    var psr = Psr{
        .mode = @intFromEnum(Mode.user),
        .thumb = false,
        .fiq_disable = false,
        .irq_disable = false,
        .reserved = 0,
        .v = false,
        .c = false,
        .z = false,
        .n = false,
    };

    // Test setNZ
    psr.setNZ(0);
    try std.testing.expect(psr.z);
    try std.testing.expect(!psr.n);

    psr.setNZ(0x80000000);
    try std.testing.expect(!psr.z);
    try std.testing.expect(psr.n);

    psr.setNZ(0x12345678);
    try std.testing.expect(!psr.z);
    try std.testing.expect(!psr.n);
}

test "PSR carry and overflow for addition" {
    var psr = Psr{
        .mode = @intFromEnum(Mode.user),
        .thumb = false,
        .fiq_disable = false,
        .irq_disable = false,
        .reserved = 0,
        .v = false,
        .c = false,
        .z = false,
        .n = false,
    };

    // Test carry: 0xFFFFFFFF + 1 = overflow
    const a: u32 = 0xFFFFFFFF;
    const b: u32 = 1;
    const result: u64 = @as(u64, a) + @as(u64, b);
    psr.setCarryAdd(a, b, result);
    try std.testing.expect(psr.c);

    // Test overflow: 0x7FFFFFFF + 1 = signed overflow
    const a2: u32 = 0x7FFFFFFF;
    const b2: u32 = 1;
    const result2: u32 = a2 +% b2;
    psr.setOverflowAdd(a2, b2, result2);
    try std.testing.expect(psr.v);
}

test "PSR subtraction flags" {
    var psr = Psr{
        .mode = @intFromEnum(Mode.user),
        .thumb = false,
        .fiq_disable = false,
        .irq_disable = false,
        .reserved = 0,
        .v = false,
        .c = false,
        .z = false,
        .n = false,
    };

    // Test carry (borrow): 5 - 3 = no borrow, carry set
    psr.setCarrySub(5, 3);
    try std.testing.expect(psr.c);

    // Test carry (borrow): 3 - 5 = borrow, carry clear
    psr.setCarrySub(3, 5);
    try std.testing.expect(!psr.c);
}

test "Mode privileged check" {
    try std.testing.expect(!Mode.user.isPrivileged());
    try std.testing.expect(Mode.supervisor.isPrivileged());
    try std.testing.expect(Mode.irq.isPrivileged());
    try std.testing.expect(Mode.fiq.isPrivileged());
    try std.testing.expect(Mode.system.isPrivileged());
}
