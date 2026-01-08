//! ARM7TDMI Instruction Executor
//!
//! Executes decoded ARM instructions, modifying CPU state and memory.

const std = @import("std");
const decoder = @import("decoder.zig");
const registers = @import("registers.zig");

const Instruction = decoder.Instruction;
const Condition = decoder.Condition;
const DpOpcode = decoder.DpOpcode;
const ShiftType = decoder.ShiftType;
const Operand2 = decoder.Operand2;
const RegisterFile = registers.RegisterFile;
const Psr = registers.Psr;
const Mode = registers.Mode;

/// Memory bus interface for read/write operations
pub const MemoryBus = struct {
    context: *anyopaque,
    read32Fn: *const fn (*anyopaque, u32) MemoryError!u32,
    read16Fn: *const fn (*anyopaque, u32) MemoryError!u16,
    read8Fn: *const fn (*anyopaque, u32) MemoryError!u8,
    write32Fn: *const fn (*anyopaque, u32, u32) MemoryError!void,
    write16Fn: *const fn (*anyopaque, u32, u16) MemoryError!void,
    write8Fn: *const fn (*anyopaque, u32, u8) MemoryError!void,

    pub fn read32(self: *MemoryBus, addr: u32) MemoryError!u32 {
        return self.read32Fn(self.context, addr);
    }

    pub fn read16(self: *MemoryBus, addr: u32) MemoryError!u16 {
        return self.read16Fn(self.context, addr);
    }

    pub fn read8(self: *MemoryBus, addr: u32) MemoryError!u8 {
        return self.read8Fn(self.context, addr);
    }

    pub fn write32(self: *MemoryBus, addr: u32, value: u32) MemoryError!void {
        return self.write32Fn(self.context, addr, value);
    }

    pub fn write16(self: *MemoryBus, addr: u32, value: u16) MemoryError!void {
        return self.write16Fn(self.context, addr, value);
    }

    pub fn write8(self: *MemoryBus, addr: u32, value: u8) MemoryError!void {
        return self.write8Fn(self.context, addr, value);
    }
};

pub const MemoryError = error{
    AccessFault,
    AlignmentFault,
    UnmappedAddress,
};

pub const ExecuteError = error{
    UndefinedInstruction,
    UnimplementedInstruction,
    InvalidMode,
    MemoryFault,
    CoprocessorError,
};

/// Result of instruction execution
pub const ExecuteResult = struct {
    /// Number of cycles consumed
    cycles: u32,
    /// Whether PC was modified (branch taken)
    branch_taken: bool,
    /// Exception to raise after execution (if any)
    exception: ?Exception,

    pub const Exception = enum {
        undefined_instruction,
        software_interrupt,
        prefetch_abort,
        data_abort,
    };
};

/// Shift result including carry output
const ShiftResult = struct {
    value: u32,
    carry: bool,
};

/// Perform a barrel shifter operation
fn barrelShift(value: u32, shift_type: ShiftType, amount: u8, carry_in: bool) ShiftResult {
    if (amount == 0) {
        // Special cases for zero shift
        return switch (shift_type) {
            .lsl => .{ .value = value, .carry = carry_in },
            .lsr => .{ .value = 0, .carry = (value & 0x80000000) != 0 }, // LSR #32
            .asr => blk: {
                const sign_bit = (value & 0x80000000) != 0;
                break :blk .{
                    .value = if (sign_bit) 0xFFFFFFFF else 0, // ASR #32
                    .carry = sign_bit,
                };
            },
            .ror => blk: {
                // RRX (rotate right extended through carry)
                const carry_bit: u32 = if (carry_in) 0x80000000 else 0;
                break :blk .{
                    .value = (value >> 1) | carry_bit,
                    .carry = (value & 1) != 0,
                };
            },
        };
    }

    return switch (shift_type) {
        .lsl => blk: {
            if (amount >= 32) {
                break :blk .{
                    .value = 0,
                    .carry = if (amount == 32) (value & 1) != 0 else false,
                };
            }
            const shifted = value << @intCast(amount);
            const carry = (value >> @intCast(32 - amount)) & 1 != 0;
            break :blk .{ .value = shifted, .carry = carry };
        },
        .lsr => blk: {
            if (amount >= 32) {
                break :blk .{
                    .value = 0,
                    .carry = if (amount == 32) (value & 0x80000000) != 0 else false,
                };
            }
            const shifted = value >> @intCast(amount);
            const carry = (value >> @intCast(amount - 1)) & 1 != 0;
            break :blk .{ .value = shifted, .carry = carry };
        },
        .asr => blk: {
            if (amount >= 32) {
                const sign_bit = (value & 0x80000000) != 0;
                break :blk .{
                    .value = if (sign_bit) 0xFFFFFFFF else 0,
                    .carry = sign_bit,
                };
            }
            const shifted = @as(u32, @bitCast(@as(i32, @bitCast(value)) >> @intCast(amount)));
            const carry = (value >> @intCast(amount - 1)) & 1 != 0;
            break :blk .{ .value = shifted, .carry = carry };
        },
        .ror => blk: {
            const effective_amount = amount & 31;
            if (effective_amount == 0) {
                break :blk .{ .value = value, .carry = (value & 0x80000000) != 0 };
            }
            const rotated = std.math.rotr(u32, value, @as(u5, @intCast(effective_amount)));
            break :blk .{ .value = rotated, .carry = (rotated & 0x80000000) != 0 };
        },
    };
}

/// Evaluate operand 2 and return value with optional carry update
fn evaluateOperand2(regs: *RegisterFile, op2: Operand2, update_carry: bool) ShiftResult {
    switch (op2) {
        .immediate => |imm| {
            // Rotate right immediate value
            const rotate_amount: u5 = @truncate(@as(u8, imm.rotate) * 2);
            const rotated = std.math.rotr(u32, @as(u32, imm.value), rotate_amount);
            const carry = if (imm.rotate == 0)
                regs.cpsr.c
            else
                (rotated & 0x80000000) != 0;
            return .{ .value = rotated, .carry = if (update_carry) carry else regs.cpsr.c };
        },
        .register => |reg| {
            const rm_value = regs.get(reg.rm);
            const shift_amount: u8 = switch (reg.shift_amount) {
                .immediate => |amt| amt,
                .register => |rs| @truncate(regs.get(rs) & 0xFF),
            };
            return barrelShift(rm_value, reg.shift_type, shift_amount, regs.cpsr.c);
        },
    }
}

/// Execute an instruction
pub fn execute(
    inst: Instruction,
    regs: *RegisterFile,
    memory: *MemoryBus,
) ExecuteError!ExecuteResult {
    // Check condition first
    const cond = switch (inst) {
        .data_processing => |dp| dp.cond,
        .multiply => |m| m.cond,
        .multiply_long => |m| m.cond,
        .single_transfer => |st| st.cond,
        .halfword_transfer => |ht| ht.cond,
        .block_transfer => |bt| bt.cond,
        .branch => |b| b.cond,
        .branch_exchange => |bx| bx.cond,
        .software_interrupt => |swi| swi.cond,
        .status_register => |sr| sr.cond,
        .coprocessor_transfer => |cp| cp.cond,
        .coprocessor_register => |cp| cp.cond,
        .coprocessor_data => |cp| cp.cond,
        .swap => |s| s.cond,
        .undefined => |u| u.cond,
    };

    if (!cond.evaluate(regs.cpsr.n, regs.cpsr.z, regs.cpsr.c, regs.cpsr.v)) {
        // Condition failed - instruction is a NOP
        regs.advancePC();
        return .{ .cycles = 1, .branch_taken = false, .exception = null };
    }

    return switch (inst) {
        .data_processing => |dp| executeDataProcessing(dp, regs),
        .multiply => |m| executeMultiply(m, regs),
        .multiply_long => |m| executeMultiplyLong(m, regs),
        .single_transfer => |st| executeSingleTransfer(st, regs, memory),
        .halfword_transfer => |ht| executeHalfwordTransfer(ht, regs, memory),
        .block_transfer => |bt| executeBlockTransfer(bt, regs, memory),
        .branch => |b| executeBranch(b, regs),
        .branch_exchange => |bx| executeBranchExchange(bx, regs),
        .software_interrupt => |swi| executeSoftwareInterrupt(swi, regs),
        .status_register => |sr| executeStatusRegister(sr, regs),
        .coprocessor_register => |cp| executeCoprocessorRegister(cp, regs),
        .swap => |s| executeSwap(s, regs, memory),
        .coprocessor_transfer, .coprocessor_data => {
            // Coprocessor data transfer/operation - not implemented for ARM7TDMI sim
            regs.advancePC();
            return .{ .cycles = 2, .branch_taken = false, .exception = null };
        },
        .undefined => {
            return .{ .cycles = 1, .branch_taken = false, .exception = .undefined_instruction };
        },
    };
}

fn executeDataProcessing(dp: std.meta.TagPayload(Instruction, .data_processing), regs: *RegisterFile) ExecuteError!ExecuteResult {
    const rn_value = if (dp.opcode.usesRn()) regs.get(dp.rn) else 0;
    const op2_result = evaluateOperand2(regs, dp.operand2, dp.set_flags);
    const op2_value = op2_result.value;

    var result: u32 = 0;
    var carry = regs.cpsr.c;
    var overflow = regs.cpsr.v;

    switch (dp.opcode) {
        .@"and", .tst => {
            result = rn_value & op2_value;
            carry = op2_result.carry;
        },
        .eor, .teq => {
            result = rn_value ^ op2_value;
            carry = op2_result.carry;
        },
        .sub, .cmp => {
            result = rn_value -% op2_value;
            carry = rn_value >= op2_value;
            // Overflow for subtraction
            const a_neg = (rn_value & 0x80000000) != 0;
            const b_neg = (op2_value & 0x80000000) != 0;
            const r_neg = (result & 0x80000000) != 0;
            overflow = (a_neg != b_neg) and (a_neg != r_neg);
        },
        .rsb => {
            result = op2_value -% rn_value;
            carry = op2_value >= rn_value;
            const a_neg = (op2_value & 0x80000000) != 0;
            const b_neg = (rn_value & 0x80000000) != 0;
            const r_neg = (result & 0x80000000) != 0;
            overflow = (a_neg != b_neg) and (a_neg != r_neg);
        },
        .add, .cmn => {
            const sum: u64 = @as(u64, rn_value) + @as(u64, op2_value);
            result = @truncate(sum);
            carry = sum > 0xFFFFFFFF;
            const a_neg = (rn_value & 0x80000000) != 0;
            const b_neg = (op2_value & 0x80000000) != 0;
            const r_neg = (result & 0x80000000) != 0;
            overflow = (a_neg == b_neg) and (a_neg != r_neg);
        },
        .adc => {
            const c_in: u64 = if (regs.cpsr.c) 1 else 0;
            const sum: u64 = @as(u64, rn_value) + @as(u64, op2_value) + c_in;
            result = @truncate(sum);
            carry = sum > 0xFFFFFFFF;
            const a_neg = (rn_value & 0x80000000) != 0;
            const b_neg = (op2_value & 0x80000000) != 0;
            const r_neg = (result & 0x80000000) != 0;
            overflow = (a_neg == b_neg) and (a_neg != r_neg);
        },
        .sbc => {
            const borrow: u32 = if (regs.cpsr.c) 0 else 1;
            result = rn_value -% op2_value -% borrow;
            carry = @as(u64, rn_value) >= (@as(u64, op2_value) + @as(u64, borrow));
            const a_neg = (rn_value & 0x80000000) != 0;
            const b_neg = (op2_value & 0x80000000) != 0;
            const r_neg = (result & 0x80000000) != 0;
            overflow = (a_neg != b_neg) and (a_neg != r_neg);
        },
        .rsc => {
            const borrow: u32 = if (regs.cpsr.c) 0 else 1;
            result = op2_value -% rn_value -% borrow;
            carry = @as(u64, op2_value) >= (@as(u64, rn_value) + @as(u64, borrow));
            const a_neg = (op2_value & 0x80000000) != 0;
            const b_neg = (rn_value & 0x80000000) != 0;
            const r_neg = (result & 0x80000000) != 0;
            overflow = (a_neg != b_neg) and (a_neg != r_neg);
        },
        .orr => {
            result = rn_value | op2_value;
            carry = op2_result.carry;
        },
        .mov => {
            result = op2_value;
            carry = op2_result.carry;
        },
        .bic => {
            result = rn_value & ~op2_value;
            carry = op2_result.carry;
        },
        .mvn => {
            result = ~op2_value;
            carry = op2_result.carry;
        },
    }

    // Update flags if S bit set
    if (dp.set_flags) {
        if (dp.rd == 15) {
            // Special case: S bit with PC destination restores CPSR from SPSR
            if (regs.getSPSR()) |spsr| {
                regs.cpsr = spsr;
            }
        } else {
            regs.cpsr.n = (result & 0x80000000) != 0;
            regs.cpsr.z = result == 0;
            regs.cpsr.c = carry;
            if (!dp.opcode.isTest()) {
                // Arithmetic ops update overflow
                switch (dp.opcode) {
                    .sub, .rsb, .add, .adc, .sbc, .rsc, .cmp, .cmn => {
                        regs.cpsr.v = overflow;
                    },
                    else => {},
                }
            }
        }
    }

    // Write result (except for test instructions)
    if (!dp.opcode.isTest()) {
        regs.set(dp.rd, result);
    }

    // Advance PC unless destination was PC
    const branch_taken = dp.rd == 15 and !dp.opcode.isTest();
    if (!branch_taken) {
        regs.advancePC();
    }

    return .{ .cycles = 1, .branch_taken = branch_taken, .exception = null };
}

fn executeMultiply(m: std.meta.TagPayload(Instruction, .multiply), regs: *RegisterFile) ExecuteError!ExecuteResult {
    const rm = regs.get(m.rm);
    const rs = regs.get(m.rs);
    var result = rm *% rs;

    if (m.accumulate) {
        result +%= regs.get(m.rn);
    }

    regs.set(m.rd, result);

    if (m.set_flags) {
        regs.cpsr.n = (result & 0x80000000) != 0;
        regs.cpsr.z = result == 0;
        // C and V flags are undefined for MUL/MLA on ARM7TDMI
    }

    regs.advancePC();

    // Cycle count depends on rs value (simplified)
    return .{ .cycles = 4, .branch_taken = false, .exception = null };
}

fn executeMultiplyLong(m: std.meta.TagPayload(Instruction, .multiply_long), regs: *RegisterFile) ExecuteError!ExecuteResult {
    const rm = regs.get(m.rm);
    const rs = regs.get(m.rs);

    var result: u64 = if (m.signed) blk: {
        const rm_signed: i64 = @as(i32, @bitCast(rm));
        const rs_signed: i64 = @as(i32, @bitCast(rs));
        break :blk @bitCast(rm_signed * rs_signed);
    } else blk: {
        break :blk @as(u64, rm) * @as(u64, rs);
    };

    if (m.accumulate) {
        const acc: u64 = (@as(u64, regs.get(m.rd_hi)) << 32) | @as(u64, regs.get(m.rd_lo));
        result +%= acc;
    }

    regs.set(m.rd_lo, @truncate(result));
    regs.set(m.rd_hi, @truncate(result >> 32));

    if (m.set_flags) {
        regs.cpsr.n = (result & 0x8000000000000000) != 0;
        regs.cpsr.z = result == 0;
    }

    regs.advancePC();

    return .{ .cycles = 5, .branch_taken = false, .exception = null };
}

fn executeSingleTransfer(st: std.meta.TagPayload(Instruction, .single_transfer), regs: *RegisterFile, memory: *MemoryBus) ExecuteError!ExecuteResult {
    const base = regs.get(st.rn);

    // Calculate offset
    const offset: u32 = switch (st.offset) {
        .immediate => |imm| imm,
        .register => |reg| blk: {
            const rm_val = regs.get(reg.rm);
            const shifted = barrelShift(rm_val, reg.shift_type, reg.shift_amount, regs.cpsr.c);
            break :blk shifted.value;
        },
    };

    // Calculate address
    const addr_offset = if (st.up) base +% offset else base -% offset;
    const addr = if (st.pre_index) addr_offset else base;

    // Perform transfer
    if (st.load) {
        const value = if (st.byte)
            @as(u32, memory.read8(addr) catch return error.MemoryFault)
        else
            memory.read32(addr & ~@as(u32, 3)) catch return error.MemoryFault;

        regs.set(st.rd, value);
    } else {
        const value = regs.get(st.rd);
        if (st.byte) {
            memory.write8(addr, @truncate(value)) catch return error.MemoryFault;
        } else {
            memory.write32(addr & ~@as(u32, 3), value) catch return error.MemoryFault;
        }
    }

    // Write-back
    if (st.write_back or !st.pre_index) {
        regs.set(st.rn, addr_offset);
    }

    // Advance PC unless destination was PC in load
    const branch_taken = st.load and st.rd == 15;
    if (!branch_taken) {
        regs.advancePC();
    }

    return .{ .cycles = if (st.load) 3 else 2, .branch_taken = branch_taken, .exception = null };
}

fn executeHalfwordTransfer(ht: std.meta.TagPayload(Instruction, .halfword_transfer), regs: *RegisterFile, memory: *MemoryBus) ExecuteError!ExecuteResult {
    const base = regs.get(ht.rn);

    // Calculate offset
    const offset: u32 = switch (ht.offset) {
        .immediate => |imm| imm,
        .register => |rm| regs.get(rm),
    };

    const addr_offset = if (ht.up) base +% offset else base -% offset;
    const addr = if (ht.pre_index) addr_offset else base;

    if (ht.load) {
        var value: u32 = undefined;
        if (ht.halfword) {
            // Halfword load
            const hw = memory.read16(addr & ~@as(u32, 1)) catch return error.MemoryFault;
            if (ht.signed) {
                // Sign-extend from 16 to 32 bits
                value = @bitCast(@as(i32, @as(i16, @bitCast(hw))));
            } else {
                value = hw;
            }
        } else {
            // Signed byte load
            const b = memory.read8(addr) catch return error.MemoryFault;
            value = @bitCast(@as(i32, @as(i8, @bitCast(b))));
        }
        regs.set(ht.rd, value);
    } else {
        // Store halfword
        const value: u16 = @truncate(regs.get(ht.rd));
        memory.write16(addr & ~@as(u32, 1), value) catch return error.MemoryFault;
    }

    // Write-back
    if (ht.write_back or !ht.pre_index) {
        regs.set(ht.rn, addr_offset);
    }

    const branch_taken = ht.load and ht.rd == 15;
    if (!branch_taken) {
        regs.advancePC();
    }

    return .{ .cycles = if (ht.load) 3 else 2, .branch_taken = branch_taken, .exception = null };
}

fn executeBlockTransfer(bt: std.meta.TagPayload(Instruction, .block_transfer), regs: *RegisterFile, memory: *MemoryBus) ExecuteError!ExecuteResult {
    const base = regs.get(bt.rn);
    const reg_count = @popCount(bt.register_list);
    var cycles: u32 = 2;

    // Calculate start address based on addressing mode
    var addr: u32 = undefined;
    if (bt.up) {
        if (bt.pre_index) {
            addr = base + 4;
        } else {
            addr = base;
        }
    } else {
        if (bt.pre_index) {
            addr = base - (reg_count * 4);
        } else {
            addr = base - (reg_count * 4) + 4;
        }
    }

    // Transfer registers
    var reg_list = bt.register_list;
    var branch_taken = false;

    for (0..16) |i| {
        if ((reg_list & 1) != 0) {
            const reg: u4 = @intCast(i);
            if (bt.load) {
                const value = memory.read32(addr) catch return error.MemoryFault;
                // If S bit set and loading PC, restore CPSR from SPSR
                if (bt.psr_force_user and reg == 15) {
                    if (regs.getSPSR()) |spsr| {
                        regs.cpsr = spsr;
                    }
                }
                regs.set(reg, value);
                if (reg == 15) branch_taken = true;
            } else {
                const value = regs.get(reg);
                memory.write32(addr, value) catch return error.MemoryFault;
            }
            addr += 4;
            cycles += 1;
        }
        reg_list >>= 1;
    }

    // Write-back base register
    if (bt.write_back) {
        const final_base = if (bt.up)
            base + (reg_count * 4)
        else
            base - (reg_count * 4);
        regs.set(bt.rn, final_base);
    }

    if (!branch_taken) {
        regs.advancePC();
    }

    return .{ .cycles = cycles, .branch_taken = branch_taken, .exception = null };
}

fn executeBranch(b: std.meta.TagPayload(Instruction, .branch), regs: *RegisterFile) ExecuteError!ExecuteResult {
    if (b.link) {
        // Save return address in LR (address of instruction after branch)
        regs.setLR(regs.getPC() + 4);
    }

    // Calculate target: PC + 8 + (offset << 2)
    // PC reads as current instruction address + 8 in ARM mode
    const offset: i32 = @as(i32, b.offset) << 2;
    const pc_plus_8 = regs.getPC() + 8;
    const target: u32 = @bitCast(@as(i32, @bitCast(pc_plus_8)) +% offset);

    regs.setPC(target);

    return .{ .cycles = 3, .branch_taken = true, .exception = null };
}

fn executeBranchExchange(bx: std.meta.TagPayload(Instruction, .branch_exchange), regs: *RegisterFile) ExecuteError!ExecuteResult {
    const target = regs.get(bx.rn);

    // Set Thumb state based on bit 0
    regs.cpsr.thumb = (target & 1) != 0;

    // Branch to target (clear bit 0 for alignment)
    regs.setPC(target & ~@as(u32, 1));

    return .{ .cycles = 3, .branch_taken = true, .exception = null };
}

fn executeSoftwareInterrupt(_: std.meta.TagPayload(Instruction, .software_interrupt), regs: *RegisterFile) ExecuteError!ExecuteResult {
    _ = regs;
    // SWI triggers an exception - return to let CPU handle it
    return .{ .cycles = 3, .branch_taken = false, .exception = .software_interrupt };
}

fn executeStatusRegister(sr: std.meta.TagPayload(Instruction, .status_register), regs: *RegisterFile) ExecuteError!ExecuteResult {
    if (sr.to_status) {
        // MSR - write to status register
        const value: u32 = switch (sr.source) {
            .register => |rm| regs.get(rm),
            .immediate => |imm| blk: {
                const rotate_amount: u5 = @truncate(@as(u8, imm.rotate) * 2);
                break :blk std.math.rotr(u32, @as(u32, imm.value), rotate_amount);
            },
        };

        if (sr.use_spsr) {
            if (sr.flags_only) {
                var spsr = regs.getSPSR() orelse return error.InvalidMode;
                // Only update flags (bits 31-28)
                const flags: u32 = value & 0xF0000000;
                var spsr_u32 = spsr.toU32();
                spsr_u32 = (spsr_u32 & 0x0FFFFFFF) | flags;
                regs.setSPSR(Psr.fromU32(spsr_u32));
            } else {
                regs.setSPSR(Psr.fromU32(value));
            }
        } else {
            if (sr.flags_only) {
                const flags: u32 = value & 0xF0000000;
                var cpsr_u32 = regs.cpsr.toU32();
                cpsr_u32 = (cpsr_u32 & 0x0FFFFFFF) | flags;
                regs.cpsr = Psr.fromU32(cpsr_u32);
            } else {
                // Full CPSR write - may trigger mode switch
                const old_mode = regs.getMode();
                regs.cpsr = Psr.fromU32(value);
                const new_mode = regs.cpsr.getMode() orelse return error.InvalidMode;
                if (old_mode != new_mode) {
                    // This is a simplified version - proper impl needs register banking
                    regs.switchMode(new_mode);
                }
            }
        }
    } else {
        // MRS - read from status register
        const rd: u4 = switch (sr.source) {
            .register => |r| r,
            .immediate => return error.UndefinedInstruction,
        };

        const value = if (sr.use_spsr)
            (regs.getSPSR() orelse Psr.fromU32(0)).toU32()
        else
            regs.cpsr.toU32();

        regs.set(rd, value);
    }

    regs.advancePC();
    return .{ .cycles = 1, .branch_taken = false, .exception = null };
}

fn executeCoprocessorRegister(cp: std.meta.TagPayload(Instruction, .coprocessor_register), regs: *RegisterFile) ExecuteError!ExecuteResult {
    // Only handle CP15 (system control coprocessor) for cache operations
    if (cp.coproc != 15) {
        regs.advancePC();
        return .{ .cycles = 2, .branch_taken = false, .exception = null };
    }

    if (cp.to_arm) {
        // MRC - read from coprocessor
        // Return 0 for all CP15 reads (simplified)
        regs.set(cp.rd, 0);
    }
    // MCR - write to coprocessor
    // Ignore writes (cache operations simulated elsewhere)

    regs.advancePC();
    return .{ .cycles = 2, .branch_taken = false, .exception = null };
}

fn executeSwap(s: std.meta.TagPayload(Instruction, .swap), regs: *RegisterFile, memory: *MemoryBus) ExecuteError!ExecuteResult {
    const addr = regs.get(s.rn);
    const new_value = regs.get(s.rm);

    if (s.byte) {
        const old_value = memory.read8(addr) catch return error.MemoryFault;
        memory.write8(addr, @truncate(new_value)) catch return error.MemoryFault;
        regs.set(s.rd, old_value);
    } else {
        const old_value = memory.read32(addr & ~@as(u32, 3)) catch return error.MemoryFault;
        memory.write32(addr & ~@as(u32, 3), new_value) catch return error.MemoryFault;
        regs.set(s.rd, old_value);
    }

    regs.advancePC();
    return .{ .cycles = 4, .branch_taken = false, .exception = null };
}

// ============================================================
// Tests
// ============================================================

// Simple memory implementation for testing
const TestMemory = struct {
    data: [1024]u8,

    fn read32(ctx: *anyopaque, addr: u32) MemoryError!u32 {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (addr >= self.data.len - 3) return error.UnmappedAddress;
        return std.mem.readInt(u32, self.data[addr..][0..4], .little);
    }

    fn read16(ctx: *anyopaque, addr: u32) MemoryError!u16 {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (addr >= self.data.len - 1) return error.UnmappedAddress;
        return std.mem.readInt(u16, self.data[addr..][0..2], .little);
    }

    fn read8(ctx: *anyopaque, addr: u32) MemoryError!u8 {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (addr >= self.data.len) return error.UnmappedAddress;
        return self.data[addr];
    }

    fn write32(ctx: *anyopaque, addr: u32, value: u32) MemoryError!void {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (addr >= self.data.len - 3) return error.UnmappedAddress;
        std.mem.writeInt(u32, self.data[addr..][0..4], value, .little);
    }

    fn write16(ctx: *anyopaque, addr: u32, value: u16) MemoryError!void {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (addr >= self.data.len - 1) return error.UnmappedAddress;
        std.mem.writeInt(u16, self.data[addr..][0..2], value, .little);
    }

    fn write8(ctx: *anyopaque, addr: u32, value: u8) MemoryError!void {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (addr >= self.data.len) return error.UnmappedAddress;
        self.data[addr] = value;
    }

    fn bus(self: *TestMemory) MemoryBus {
        return .{
            .context = self,
            .read32Fn = read32,
            .read16Fn = read16,
            .read8Fn = read8,
            .write32Fn = write32,
            .write16Fn = write16,
            .write8Fn = write8,
        };
    }
};

test "execute MOV R0, #42" {
    var regs = RegisterFile.init();
    var mem = TestMemory{ .data = undefined };
    var bus = mem.bus();

    const inst = decoder.decode(0xE3A0002A); // MOV R0, #42
    const result = try execute(inst, &regs, &bus);

    try std.testing.expectEqual(@as(u32, 42), regs.r[0]);
    try std.testing.expect(!result.branch_taken);
}

test "execute ADD R2, R0, R1" {
    var regs = RegisterFile.init();
    var mem = TestMemory{ .data = undefined };
    var bus = mem.bus();

    regs.r[0] = 10;
    regs.r[1] = 20;

    const inst = decoder.decode(0xE0802001); // ADD R2, R0, R1
    _ = try execute(inst, &regs, &bus);

    try std.testing.expectEqual(@as(u32, 30), regs.r[2]);
}

test "execute SUBS sets flags" {
    var regs = RegisterFile.init();
    var mem = TestMemory{ .data = undefined };
    var bus = mem.bus();

    regs.r[0] = 5;
    regs.r[1] = 5;

    const inst = decoder.decode(0xE0510001); // SUBS R0, R1, R1
    _ = try execute(inst, &regs, &bus);

    try std.testing.expectEqual(@as(u32, 0), regs.r[0]);
    try std.testing.expect(regs.cpsr.z); // Zero flag set
    try std.testing.expect(regs.cpsr.c); // Carry set (no borrow)
}

test "execute B (branch)" {
    var regs = RegisterFile.init();
    var mem = TestMemory{ .data = undefined };
    var bus = mem.bus();

    regs.r[15] = 0x100; // PC at 0x100

    const inst = decoder.decode(0xEA000004); // B +0x14 (offset = 4 words)
    const result = try execute(inst, &regs, &bus);

    // Target = PC + 8 + (4 << 2) = 0x100 + 8 + 16 = 0x118
    try std.testing.expectEqual(@as(u32, 0x118), regs.r[15]);
    try std.testing.expect(result.branch_taken);
}

test "execute LDR R0, [R1]" {
    var regs = RegisterFile.init();
    var mem = TestMemory{ .data = [_]u8{0} ** 1024 };
    var bus = mem.bus();

    // Store test value at address 0x100
    std.mem.writeInt(u32, mem.data[0x100..][0..4], 0xDEADBEEF, .little);
    regs.r[1] = 0x100;

    const inst = decoder.decode(0xE5910000); // LDR R0, [R1]
    _ = try execute(inst, &regs, &bus);

    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), regs.r[0]);
}

test "execute STR R0, [R1]" {
    var regs = RegisterFile.init();
    var mem = TestMemory{ .data = [_]u8{0} ** 1024 };
    var bus = mem.bus();

    regs.r[0] = 0x12345678;
    regs.r[1] = 0x200;

    const inst = decoder.decode(0xE5810000); // STR R0, [R1]
    _ = try execute(inst, &regs, &bus);

    const stored = std.mem.readInt(u32, mem.data[0x200..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 0x12345678), stored);
}

test "execute conditional (condition fails)" {
    var regs = RegisterFile.init();
    var mem = TestMemory{ .data = undefined };
    var bus = mem.bus();

    regs.cpsr.z = false; // Z flag clear
    regs.r[0] = 100;
    const pc_before = regs.r[15];

    const inst = decoder.decode(0x03A00000); // MOVEQ R0, #0 (only if Z set)
    _ = try execute(inst, &regs, &bus);

    try std.testing.expectEqual(@as(u32, 100), regs.r[0]); // Unchanged
    try std.testing.expectEqual(pc_before + 4, regs.r[15]); // PC advanced
}

test "barrel shift LSL" {
    // LSL by 4: carry gets bit (32-4)=28 of original value
    // 0xF0000001 has bit 28 set, so carry should be true
    const result = barrelShift(0xF0000001, .lsl, 4, false);
    try std.testing.expectEqual(@as(u32, 0x00000010), result.value);
    try std.testing.expect(result.carry); // Bit 28 shifted into carry
}

test "barrel shift ASR (arithmetic)" {
    const result = barrelShift(0x80000000, .asr, 4, false);
    try std.testing.expectEqual(@as(u32, 0xF8000000), result.value); // Sign extended
}

test "barrel shift ROR" {
    const result = barrelShift(0x0000000F, .ror, 4, false);
    try std.testing.expectEqual(@as(u32, 0xF0000000), result.value);
}
