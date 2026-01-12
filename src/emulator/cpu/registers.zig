//! ARM7TDMI Register File
//!
//! Implements the complete ARM7TDMI register set with:
//! - 16 general-purpose registers (R0-R15)
//! - CPSR (Current Program Status Register)
//! - SPSR (Saved Program Status Register) for each privileged mode
//! - Banked registers for each processor mode
//!
//! Reference: ARM7TDMI Technical Reference Manual (ARM DDI 0029E)

const std = @import("std");

/// Processor modes as defined by ARM7TDMI
pub const Mode = enum(u5) {
    user = 0b10000,
    fiq = 0b10001,
    irq = 0b10010,
    supervisor = 0b10011,
    abort = 0b10111,
    undefined = 0b11011,
    system = 0b11111,

    pub fn isPrivileged(self: Mode) bool {
        return self != .user;
    }

    pub fn hasSpsr(self: Mode) bool {
        return switch (self) {
            .user, .system => false,
            else => true,
        };
    }

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

/// Program Status Register (CPSR/SPSR)
pub const PSR = packed struct(u32) {
    /// Processor mode (M[4:0])
    mode: u5,

    /// Thumb state (T) - 0=ARM, 1=Thumb
    thumb: bool,

    /// FIQ disable (F) - 1=disabled
    fiq_disable: bool,

    /// IRQ disable (I) - 1=disabled
    irq_disable: bool,

    /// Reserved bits [27:8]
    _reserved: u20 = 0,

    /// Overflow flag (V)
    overflow: bool,

    /// Carry flag (C)
    carry: bool,

    /// Zero flag (Z)
    zero: bool,

    /// Negative flag (N)
    negative: bool,

    pub fn getMode(self: PSR) ?Mode {
        return Mode.fromBits(self.mode);
    }

    pub fn setMode(self: *PSR, mode: Mode) void {
        self.mode = @intFromEnum(mode);
    }

    /// Get condition flags as 4-bit value (NZCV)
    pub fn getConditionFlags(self: PSR) u4 {
        return (@as(u4, @intFromBool(self.negative)) << 3) |
            (@as(u4, @intFromBool(self.zero)) << 2) |
            (@as(u4, @intFromBool(self.carry)) << 1) |
            @as(u4, @intFromBool(self.overflow));
    }

    /// Set condition flags from 4-bit value (NZCV)
    pub fn setConditionFlags(self: *PSR, flags: u4) void {
        self.negative = (flags & 0x8) != 0;
        self.zero = (flags & 0x4) != 0;
        self.carry = (flags & 0x2) != 0;
        self.overflow = (flags & 0x1) != 0;
    }

    /// Initialize with a default mode
    pub fn init(mode: Mode) PSR {
        return .{
            .mode = @intFromEnum(mode),
            .thumb = false,
            .fiq_disable = true,
            .irq_disable = true,
            ._reserved = 0,
            .overflow = false,
            .carry = false,
            .zero = false,
            .negative = false,
        };
    }
};

/// Complete ARM7TDMI register file with banking
pub const RegisterFile = struct {
    /// Current visible registers R0-R15
    /// R13 = SP, R14 = LR, R15 = PC
    r: [16]u32,

    /// Current Program Status Register
    cpsr: PSR,

    /// User/System mode R8-R12 (banked for FIQ)
    r8_usr: [5]u32,
    /// User/System mode R13 (SP)
    r13_usr: u32,
    /// User/System mode R14 (LR)
    r14_usr: u32,

    /// FIQ mode banked registers R8-R12
    r8_fiq: [5]u32,
    /// FIQ mode R13 (SP)
    r13_fiq: u32,
    /// FIQ mode R14 (LR)
    r14_fiq: u32,
    /// FIQ mode SPSR
    spsr_fiq: u32,

    /// IRQ mode R13 (SP)
    r13_irq: u32,
    /// IRQ mode R14 (LR)
    r14_irq: u32,
    /// IRQ mode SPSR
    spsr_irq: u32,

    /// Supervisor mode R13 (SP)
    r13_svc: u32,
    /// Supervisor mode R14 (LR)
    r14_svc: u32,
    /// Supervisor mode SPSR
    spsr_svc: u32,

    /// Abort mode R13 (SP)
    r13_abt: u32,
    /// Abort mode R14 (LR)
    r14_abt: u32,
    /// Abort mode SPSR
    spsr_abt: u32,

    /// Undefined mode R13 (SP)
    r13_und: u32,
    /// Undefined mode R14 (LR)
    r14_und: u32,
    /// Undefined mode SPSR
    spsr_und: u32,

    const Self = @This();

    /// Initialize register file in Supervisor mode (typical after reset)
    pub fn init() Self {
        // Initialize SPSRs to valid supervisor mode CPSR (0xD3 = supervisor + I=1 + F=1)
        // This prevents crashes if code does exception return without proper SPSR setup
        const default_spsr: u32 = 0xD3;

        var regs = Self{
            .r = [_]u32{0} ** 16,
            .cpsr = PSR.init(.supervisor),
            .r8_usr = [_]u32{0} ** 5,
            .r13_usr = 0,
            .r14_usr = 0,
            .r8_fiq = [_]u32{0} ** 5,
            .r13_fiq = 0,
            .r14_fiq = 0,
            .spsr_fiq = default_spsr,
            .r13_irq = 0,
            .r14_irq = 0,
            .spsr_irq = default_spsr,
            .r13_svc = 0,
            .r14_svc = 0,
            .spsr_svc = default_spsr,
            .r13_abt = 0,
            .r14_abt = 0,
            .spsr_abt = default_spsr,
            .r13_und = 0,
            .r14_und = 0,
            .spsr_und = default_spsr,
        };

        // Set PC to reset vector
        regs.r[15] = 0x00000000;

        return regs;
    }

    /// Get register value (handles PC special case)
    pub fn get(self: *const Self, reg: u4) u32 {
        if (reg == 15) {
            // PC reads as current instruction + 8 (ARM) or + 4 (Thumb)
            // The caller should handle the pipeline offset
            return self.r[15];
        }
        return self.r[reg];
    }

    /// Set register value (handles PC special case)
    pub fn set(self: *Self, reg: u4, value: u32) void {
        if (reg == 15) {
            // PC writes: ARM aligns to 4 bytes, Thumb aligns to 2 bytes
            if (self.cpsr.thumb) {
                self.r[15] = value & ~@as(u32, 1);
            } else {
                self.r[15] = value & ~@as(u32, 3);
            }
        } else {
            self.r[reg] = value;
        }
    }

    /// Get current SPSR (only valid in privileged modes)
    pub fn getSpsr(self: *const Self) ?u32 {
        const mode = self.cpsr.getMode() orelse return null;
        return switch (mode) {
            .fiq => self.spsr_fiq,
            .irq => self.spsr_irq,
            .supervisor => self.spsr_svc,
            .abort => self.spsr_abt,
            .undefined => self.spsr_und,
            .user, .system => null,
        };
    }

    /// Set current SPSR (only valid in privileged modes)
    pub fn setSpsr(self: *Self, value: u32) void {
        const mode = self.cpsr.getMode() orelse return;
        switch (mode) {
            .fiq => self.spsr_fiq = value,
            .irq => self.spsr_irq = value,
            .supervisor => self.spsr_svc = value,
            .abort => self.spsr_abt = value,
            .undefined => self.spsr_und = value,
            .user, .system => {},
        }
    }

    /// Switch processor mode with register banking
    pub fn switchMode(self: *Self, new_mode: Mode) void {
        const old_mode = self.cpsr.getMode() orelse return;
        if (old_mode == new_mode) return;

        // Save current registers to old mode's bank
        self.saveToBank(old_mode);

        // Change mode
        self.cpsr.setMode(new_mode);

        // Restore registers from new mode's bank
        self.restoreFromBank(new_mode);
    }

    /// Save current visible registers to the specified mode's bank
    fn saveToBank(self: *Self, mode: Mode) void {
        switch (mode) {
            .user, .system => {
                // User and System share the same registers
                for (0..5) |i| {
                    self.r8_usr[i] = self.r[8 + i];
                }
                self.r13_usr = self.r[13];
                self.r14_usr = self.r[14];
            },
            .fiq => {
                for (0..5) |i| {
                    self.r8_fiq[i] = self.r[8 + i];
                }
                self.r13_fiq = self.r[13];
                self.r14_fiq = self.r[14];
            },
            .irq => {
                // IRQ shares R8-R12 with User, save them too
                for (0..5) |i| {
                    self.r8_usr[i] = self.r[8 + i];
                }
                self.r13_irq = self.r[13];
                self.r14_irq = self.r[14];
            },
            .supervisor => {
                // SVC shares R8-R12 with User, save them too
                for (0..5) |i| {
                    self.r8_usr[i] = self.r[8 + i];
                }
                self.r13_svc = self.r[13];
                self.r14_svc = self.r[14];
            },
            .abort => {
                // ABT shares R8-R12 with User, save them too
                for (0..5) |i| {
                    self.r8_usr[i] = self.r[8 + i];
                }
                self.r13_abt = self.r[13];
                self.r14_abt = self.r[14];
            },
            .undefined => {
                // UND shares R8-R12 with User, save them too
                for (0..5) |i| {
                    self.r8_usr[i] = self.r[8 + i];
                }
                self.r13_und = self.r[13];
                self.r14_und = self.r[14];
            },
        }
    }

    /// Restore visible registers from the specified mode's bank
    fn restoreFromBank(self: *Self, mode: Mode) void {
        switch (mode) {
            .user, .system => {
                for (0..5) |i| {
                    self.r[8 + i] = self.r8_usr[i];
                }
                self.r[13] = self.r13_usr;
                self.r[14] = self.r14_usr;
            },
            .fiq => {
                for (0..5) |i| {
                    self.r[8 + i] = self.r8_fiq[i];
                }
                self.r[13] = self.r13_fiq;
                self.r[14] = self.r14_fiq;
            },
            .irq => {
                // IRQ only banks R13, R14; R8-R12 come from User
                for (0..5) |i| {
                    self.r[8 + i] = self.r8_usr[i];
                }
                self.r[13] = self.r13_irq;
                self.r[14] = self.r14_irq;
            },
            .supervisor => {
                for (0..5) |i| {
                    self.r[8 + i] = self.r8_usr[i];
                }
                self.r[13] = self.r13_svc;
                self.r[14] = self.r14_svc;
            },
            .abort => {
                for (0..5) |i| {
                    self.r[8 + i] = self.r8_usr[i];
                }
                self.r[13] = self.r13_abt;
                self.r[14] = self.r14_abt;
            },
            .undefined => {
                for (0..5) |i| {
                    self.r[8 + i] = self.r8_usr[i];
                }
                self.r[13] = self.r13_und;
                self.r[14] = self.r14_und;
            },
        }
    }

    /// Get PC value with pipeline offset for instruction fetch
    /// Note: PC is already advanced by 4 (ARM) or 2 (Thumb) before execution,
    /// so we only add the remaining offset to simulate the 3-stage pipeline.
    /// ARM: instruction at X reads PC as X+8, but r[15] is X+4, so add 4
    /// Thumb: instruction at X reads PC as X+4, but r[15] is X+2, so add 2
    pub fn getPcWithOffset(self: *const Self) u32 {
        const offset: u32 = if (self.cpsr.thumb) 2 else 4;
        return self.r[15] +% offset;
    }

    /// Increment PC after instruction fetch
    pub fn incrementPc(self: *Self) void {
        // ARM mode: +4, Thumb mode: +2
        const increment: u32 = if (self.cpsr.thumb) 2 else 4;
        self.r[15] +%= increment;
    }

    /// Check if interrupts are enabled
    pub fn irqEnabled(self: *const Self) bool {
        return !self.cpsr.irq_disable;
    }

    /// Check if FIQ is enabled
    pub fn fiqEnabled(self: *const Self) bool {
        return !self.cpsr.fiq_disable;
    }
};

// Tests
test "PSR initialization" {
    const psr = PSR.init(.supervisor);
    try std.testing.expectEqual(Mode.supervisor, psr.getMode().?);
    try std.testing.expect(!psr.thumb);
    try std.testing.expect(psr.irq_disable);
    try std.testing.expect(psr.fiq_disable);
}

test "RegisterFile mode switching" {
    var regs = RegisterFile.init();

    // Set some values in supervisor mode
    regs.r[13] = 0x1000;
    regs.r[14] = 0x2000;

    // Switch to IRQ mode
    regs.switchMode(.irq);
    try std.testing.expectEqual(Mode.irq, regs.cpsr.getMode().?);

    // IRQ mode should have its own SP/LR
    try std.testing.expectEqual(@as(u32, 0), regs.r[13]);
    try std.testing.expectEqual(@as(u32, 0), regs.r[14]);

    // Set IRQ mode values
    regs.r[13] = 0x3000;
    regs.r[14] = 0x4000;

    // Switch back to supervisor
    regs.switchMode(.supervisor);
    try std.testing.expectEqual(@as(u32, 0x1000), regs.r[13]);
    try std.testing.expectEqual(@as(u32, 0x2000), regs.r[14]);
}

test "RegisterFile FIQ banking" {
    var regs = RegisterFile.init();

    // Set user mode R8-R12
    for (0..5) |i| {
        regs.r[8 + i] = @as(u32, @intCast(0x100 + i));
    }

    // Switch to FIQ mode
    regs.switchMode(.fiq);

    // FIQ mode should have its own R8-R12
    for (0..5) |i| {
        try std.testing.expectEqual(@as(u32, 0), regs.r[8 + i]);
    }

    // Set FIQ values
    for (0..5) |i| {
        regs.r[8 + i] = @as(u32, @intCast(0x200 + i));
    }

    // Switch back to supervisor (uses user bank for R8-R12)
    regs.switchMode(.supervisor);
    for (0..5) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(0x100 + i)), regs.r[8 + i]);
    }
}

test "PC alignment" {
    var regs = RegisterFile.init();

    // ARM mode: align to 4 bytes
    regs.cpsr.thumb = false;
    regs.set(15, 0x1003);
    try std.testing.expectEqual(@as(u32, 0x1000), regs.get(15));

    // Thumb mode: align to 2 bytes
    regs.cpsr.thumb = true;
    regs.set(15, 0x1003);
    try std.testing.expectEqual(@as(u32, 0x1002), regs.get(15));
}
