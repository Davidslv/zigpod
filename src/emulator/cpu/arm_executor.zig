//! ARM (32-bit) Instruction Executor
//!
//! Executes decoded ARM instructions and returns cycle count.
//!
//! Reference: ARM7TDMI Technical Reference Manual (ARM DDI 0029E)

const std = @import("std");
const registers = @import("registers.zig");
const decoder = @import("arm_decoder.zig");
const exceptions = @import("exceptions.zig");

const RegisterFile = registers.RegisterFile;
const Mode = registers.Mode;
const PSR = registers.PSR;

/// Result of a shift operation
const ShiftResult = struct {
    value: u32,
    carry: bool,
};

/// Result of an arithmetic operation with flags
const ArithResult = struct {
    result: u32,
    carry: bool,
    overflow: bool,
};

/// Memory bus interface for CPU memory access
pub const MemoryBus = struct {
    context: *anyopaque,
    read8Fn: *const fn (*anyopaque, u32) u8,
    read16Fn: *const fn (*anyopaque, u32) u16,
    read32Fn: *const fn (*anyopaque, u32) u32,
    write8Fn: *const fn (*anyopaque, u32, u8) void,
    write16Fn: *const fn (*anyopaque, u32, u16) void,
    write32Fn: *const fn (*anyopaque, u32, u32) void,

    pub fn read8(self: *const MemoryBus, addr: u32) u8 {
        return self.read8Fn(self.context, addr);
    }

    pub fn read16(self: *const MemoryBus, addr: u32) u16 {
        return self.read16Fn(self.context, addr);
    }

    pub fn read32(self: *const MemoryBus, addr: u32) u32 {
        return self.read32Fn(self.context, addr);
    }

    pub fn write8(self: *const MemoryBus, addr: u32, value: u8) void {
        self.write8Fn(self.context, addr, value);
    }

    pub fn write16(self: *const MemoryBus, addr: u32, value: u16) void {
        self.write16Fn(self.context, addr, value);
    }

    pub fn write32(self: *const MemoryBus, addr: u32, value: u32) void {
        self.write32Fn(self.context, addr, value);
    }
};

/// Execute a single ARM instruction
/// Returns the number of cycles consumed
pub fn execute(regs: *RegisterFile, bus: *const MemoryBus, instruction: u32) u32 {
    const decoded = decoder.decode(instruction);

    // Check condition
    if (!decoded.condition.check(
        regs.cpsr.negative,
        regs.cpsr.zero,
        regs.cpsr.carry,
        regs.cpsr.overflow,
    )) {
        // Condition failed, instruction not executed
        return 1;
    }

    // Execute based on instruction type
    return switch (decoded.type) {
        .data_processing => executeDataProcessing(regs, instruction),
        .multiply => executeMultiply(regs, instruction),
        .multiply_long => executeMultiplyLong(regs, instruction),
        .single_transfer => executeSingleTransfer(regs, bus, instruction),
        .halfword_transfer => executeHalfwordTransfer(regs, bus, instruction),
        .block_transfer => executeBlockTransfer(regs, bus, instruction),
        .branch => executeBranch(regs, instruction),
        .branch_exchange => executeBranchExchange(regs, instruction),
        .swi => executeSoftwareInterrupt(regs, instruction),
        .swap => executeSwap(regs, bus, instruction),
        .mrs => executeMrs(regs, instruction),
        .msr => executeMsr(regs, instruction),
        .coprocessor_data, .coprocessor_transfer, .coprocessor_register => {
            // Check for CP15 (system control coprocessor)
            // PP5021C doesn't have true CP15, but Rockbox may use these instructions
            // We emulate CP15 to allow the code to continue
            const cp_num: u4 = @truncate((instruction >> 8) & 0xF);
            if (cp_num == 15) {
                return executeCoprocessor15(regs, instruction);
            }
            // Other coprocessors - undefined on ARM7TDMI without coprocessor
            _ = exceptions.enterException(regs, .undefined);
            return 3;
        },
        .undefined => {
            _ = exceptions.enterException(regs, .undefined);
            return 3;
        },
    };
}

/// Execute data processing instruction
fn executeDataProcessing(regs: *RegisterFile, instruction: u32) u32 {
    const dp = decoder.DataProcessing.decode(instruction);

    // Get first operand
    const rn_value = if (dp.rn == 15)
        regs.getPcWithOffset()
    else
        regs.get(dp.rn);

    // Calculate second operand and shifter carry
    var op2: u32 = undefined;
    var shifter_carry = regs.cpsr.carry;

    if (dp.is_immediate) {
        const imm = dp.getImmediate();
        op2 = imm.value;
        if (dp.imm_rotate != 0) {
            shifter_carry = imm.carry;
        }
    } else {
        const shift_result = calculateShift(regs, dp.rm, dp.shift_type, dp.shift_by_register, dp.shift_amount, dp.rs);
        op2 = shift_result.value;
        shifter_carry = shift_result.carry;
    }

    // Perform operation
    var result: u32 = undefined;
    var carry_out = regs.cpsr.carry;
    var overflow = regs.cpsr.overflow;

    switch (dp.opcode) {
        .AND => result = rn_value & op2,
        .EOR => result = rn_value ^ op2,
        .SUB => {
            const sub_result = subWithCarry(rn_value, op2, true);
            result = sub_result.result;
            carry_out = sub_result.carry;
            overflow = sub_result.overflow;
        },
        .RSB => {
            const sub_result = subWithCarry(op2, rn_value, true);
            result = sub_result.result;
            carry_out = sub_result.carry;
            overflow = sub_result.overflow;
        },
        .ADD => {
            const add_result = addWithCarry(rn_value, op2, false);
            result = add_result.result;
            carry_out = add_result.carry;
            overflow = add_result.overflow;
        },
        .ADC => {
            const add_result = addWithCarry(rn_value, op2, regs.cpsr.carry);
            result = add_result.result;
            carry_out = add_result.carry;
            overflow = add_result.overflow;
        },
        .SBC => {
            const sub_result = subWithCarry(rn_value, op2, regs.cpsr.carry);
            result = sub_result.result;
            carry_out = sub_result.carry;
            overflow = sub_result.overflow;
        },
        .RSC => {
            const sub_result = subWithCarry(op2, rn_value, regs.cpsr.carry);
            result = sub_result.result;
            carry_out = sub_result.carry;
            overflow = sub_result.overflow;
        },
        .TST => {
            result = rn_value & op2;
            carry_out = shifter_carry;
        },
        .TEQ => {
            result = rn_value ^ op2;
            carry_out = shifter_carry;
        },
        .CMP => {
            const sub_result = subWithCarry(rn_value, op2, true);
            result = sub_result.result;
            carry_out = sub_result.carry;
            overflow = sub_result.overflow;
        },
        .CMN => {
            const add_result = addWithCarry(rn_value, op2, false);
            result = add_result.result;
            carry_out = add_result.carry;
            overflow = add_result.overflow;
        },
        .ORR => result = rn_value | op2,
        .MOV => result = op2,
        .BIC => result = rn_value & ~op2,
        .MVN => result = ~op2,
    }

    // For logical operations, carry comes from shifter
    if (dp.opcode.isLogical()) {
        carry_out = shifter_carry;
    }

    // Write result (not for test instructions)
    if (!dp.opcode.isTest()) {
        regs.set(dp.rd, result);

        // Writing to PC requires special handling
        if (dp.rd == 15 and dp.set_flags) {
            // MOVS PC, ... copies SPSR to CPSR
            exceptions.returnFromException(regs);
            return 3;
        }
    }

    // Update flags if S bit set
    if (dp.set_flags and dp.rd != 15) {
        regs.cpsr.negative = (result & 0x80000000) != 0;
        regs.cpsr.zero = result == 0;
        regs.cpsr.carry = carry_out;
        if (!dp.opcode.isLogical()) {
            regs.cpsr.overflow = overflow;
        }
    }

    // Cycle count: 1 for register, 2 for register-shifted register
    return if (dp.shift_by_register) 2 else 1;
}

/// Calculate shifted value and carry out
fn calculateShift(
    regs: *RegisterFile,
    rm: u4,
    shift_type: decoder.ShiftType,
    by_register: bool,
    imm_amount: u5,
    rs: u4,
) ShiftResult {
    const rm_value = if (rm == 15) regs.getPcWithOffset() else regs.get(rm);

    var amount: u8 = undefined;
    if (by_register) {
        amount = @truncate(regs.get(rs) & 0xFF);
    } else {
        amount = imm_amount;
    }

    return applyShift(rm_value, shift_type, amount, regs.cpsr.carry, !by_register and imm_amount == 0);
}

/// Apply shift operation
fn applyShift(value: u32, shift_type: decoder.ShiftType, amount: u8, carry_in: bool, is_immediate_zero: bool) ShiftResult {
    if (amount == 0 and !is_immediate_zero) {
        return .{ .value = value, .carry = carry_in };
    }

    return switch (shift_type) {
        .lsl => {
            if (is_immediate_zero and amount == 0) {
                return .{ .value = value, .carry = carry_in };
            }
            if (amount == 0) {
                return .{ .value = value, .carry = carry_in };
            }
            if (amount >= 32) {
                const carry = if (amount == 32) (value & 1) != 0 else false;
                return .{ .value = 0, .carry = carry };
            }
            const carry = (value >> @intCast(32 - amount)) & 1 != 0;
            return .{ .value = value << @intCast(amount), .carry = carry };
        },
        .lsr => {
            const effective_amount: u8 = if (is_immediate_zero) 32 else amount;
            if (effective_amount == 0) {
                return .{ .value = value, .carry = carry_in };
            }
            if (effective_amount >= 32) {
                const carry = if (effective_amount == 32) (value & 0x80000000) != 0 else false;
                return .{ .value = 0, .carry = carry };
            }
            const carry = (value >> @intCast(effective_amount - 1)) & 1 != 0;
            return .{ .value = value >> @intCast(effective_amount), .carry = carry };
        },
        .asr => {
            const effective_amount: u8 = if (is_immediate_zero) 32 else amount;
            if (effective_amount == 0) {
                return .{ .value = value, .carry = carry_in };
            }
            const signed_value: i32 = @bitCast(value);
            if (effective_amount >= 32) {
                const result: u32 = if (signed_value < 0) 0xFFFFFFFF else 0;
                return .{ .value = result, .carry = (value & 0x80000000) != 0 };
            }
            const result: i32 = signed_value >> @intCast(effective_amount);
            const carry = (value >> @intCast(effective_amount - 1)) & 1 != 0;
            return .{ .value = @bitCast(result), .carry = carry };
        },
        .ror => {
            if (is_immediate_zero and amount == 0) {
                // RRX: rotate right extended (through carry)
                const carry = (value & 1) != 0;
                const result = (value >> 1) | (@as(u32, @intFromBool(carry_in)) << 31);
                return .{ .value = result, .carry = carry };
            }
            if (amount == 0) {
                return .{ .value = value, .carry = carry_in };
            }
            const effective_amount = amount & 31;
            if (effective_amount == 0) {
                return .{ .value = value, .carry = (value & 0x80000000) != 0 };
            }
            const result = std.math.rotr(u32, value, @as(u5, @intCast(effective_amount)));
            return .{ .value = result, .carry = (result & 0x80000000) != 0 };
        },
    };
}

/// Add with carry, returning result and flags
fn addWithCarry(a: u32, b: u32, carry_in: bool) ArithResult {
    const a64: u64 = a;
    const b64: u64 = b;
    const c64: u64 = @intFromBool(carry_in);
    const result64 = a64 +% b64 +% c64;
    const result: u32 = @truncate(result64);

    // Carry is bit 32
    const carry = (result64 >> 32) != 0;

    // Overflow: if both operands have same sign and result has different sign
    const overflow = ((a ^ result) & (b ^ result) & 0x80000000) != 0;

    return .{ .result = result, .carry = carry, .overflow = overflow };
}

/// Subtract with borrow
fn subWithCarry(a: u32, b: u32, carry_in: bool) ArithResult {
    // SUB: a - b = a + ~b + 1
    // SBC: a - b - !C = a + ~b + C
    return addWithCarry(a, ~b, carry_in);
}

/// Execute multiply instruction
fn executeMultiply(regs: *RegisterFile, instruction: u32) u32 {
    const mul = decoder.Multiply.decode(instruction);

    const rm_value = regs.get(mul.rm);
    const rs_value = regs.get(mul.rs);

    var result = rm_value *% rs_value;

    if (mul.accumulate) {
        result +%= regs.get(mul.rn);
    }

    regs.set(mul.rd, result);

    if (mul.set_flags) {
        regs.cpsr.negative = (result & 0x80000000) != 0;
        regs.cpsr.zero = result == 0;
        // Carry is undefined, overflow is unchanged
    }

    // Cycle count depends on multiplier value (simplified to 3)
    return 3;
}

/// Execute multiply long instruction
fn executeMultiplyLong(regs: *RegisterFile, instruction: u32) u32 {
    const mul = decoder.MultiplyLong.decode(instruction);

    const rm_value = regs.get(mul.rm);
    const rs_value = regs.get(mul.rs);

    var result: u64 = undefined;

    if (mul.is_signed) {
        const a: i64 = @as(i32, @bitCast(rm_value));
        const b: i64 = @as(i32, @bitCast(rs_value));
        result = @bitCast(a * b);
    } else {
        result = @as(u64, rm_value) * @as(u64, rs_value);
    }

    if (mul.accumulate) {
        const accum: u64 = (@as(u64, regs.get(mul.rd_hi)) << 32) | regs.get(mul.rd_lo);
        result +%= accum;
    }

    regs.set(mul.rd_lo, @truncate(result));
    regs.set(mul.rd_hi, @truncate(result >> 32));

    if (mul.set_flags) {
        regs.cpsr.negative = (result & 0x8000000000000000) != 0;
        regs.cpsr.zero = result == 0;
    }

    return 4;
}

/// Execute single data transfer (LDR/STR)
fn executeSingleTransfer(regs: *RegisterFile, bus: *const MemoryBus, instruction: u32) u32 {
    const st = decoder.SingleTransfer.decode(instruction);

    const base = if (st.rn == 15) regs.getPcWithOffset() else regs.get(st.rn);

    // Calculate offset
    var offset: u32 = undefined;
    if (st.is_immediate) {
        offset = st.offset;
    } else {
        const shift_result = applyShift(regs.get(st.rm), st.shift_type, st.shift_amount, false, st.shift_amount == 0);
        offset = shift_result.value;
    }

    // Calculate address
    var address = base;
    if (st.pre_index) {
        if (st.add_offset) {
            address +%= offset;
        } else {
            address -%= offset;
        }
    }

    // Perform transfer
    if (st.is_load) {
        var value: u32 = undefined;
        if (st.byte_transfer) {
            value = bus.read8(address);
        } else {
            // Word load - handle rotation for unaligned access
            const aligned_addr = address & ~@as(u32, 3);
            value = bus.read32(aligned_addr);
            const rotation: u5 = @intCast((address & 3) * 8);
            if (rotation != 0) {
                value = std.math.rotr(u32, value, rotation);
            }
        }
        regs.set(st.rd, value);
    } else {
        var value = regs.get(st.rd);
        if (st.rd == 15) {
            value = regs.getPcWithOffset() + 4; // STR PC stores PC+12
        }
        if (st.byte_transfer) {
            bus.write8(address, @truncate(value));
        } else {
            bus.write32(address & ~@as(u32, 3), value);
        }
    }

    // Post-index or write-back
    if (!st.pre_index) {
        if (st.add_offset) {
            address = base +% offset;
        } else {
            address = base -% offset;
        }
    }

    if (st.write_back or !st.pre_index) {
        if (st.rn != 15) {
            regs.set(st.rn, address);
        }
    }

    // Cycle count: 3 for load, 2 for store
    return if (st.is_load) 3 else 2;
}

/// Execute halfword/signed transfer
fn executeHalfwordTransfer(regs: *RegisterFile, bus: *const MemoryBus, instruction: u32) u32 {
    const ht = decoder.HalfwordTransfer.decode(instruction);

    const base = if (ht.rn == 15) regs.getPcWithOffset() else regs.get(ht.rn);

    // Calculate offset
    var offset: u32 = undefined;
    if (ht.is_immediate) {
        offset = ht.getOffset();
    } else {
        offset = regs.get(ht.rm);
    }

    // Calculate address
    var address = base;
    if (ht.pre_index) {
        if (ht.add_offset) {
            address +%= offset;
        } else {
            address -%= offset;
        }
    }

    // Perform transfer
    if (ht.is_load) {
        var value: u32 = undefined;

        if (ht.is_signed) {
            if (ht.is_halfword) {
                // LDRSH
                const half = bus.read16(address & ~@as(u32, 1));
                value = @bitCast(@as(i32, @as(i16, @bitCast(half))));
            } else {
                // LDRSB
                const byte = bus.read8(address);
                value = @bitCast(@as(i32, @as(i8, @bitCast(byte))));
            }
        } else {
            // LDRH
            value = bus.read16(address & ~@as(u32, 1));
        }

        regs.set(ht.rd, value);
    } else {
        // STRH
        const value: u16 = @truncate(regs.get(ht.rd));
        bus.write16(address & ~@as(u32, 1), value);
    }

    // Post-index
    if (!ht.pre_index) {
        if (ht.add_offset) {
            address = base +% offset;
        } else {
            address = base -% offset;
        }
    }

    if (ht.write_back or !ht.pre_index) {
        if (ht.rn != 15) {
            regs.set(ht.rn, address);
        }
    }

    return if (ht.is_load) 3 else 2;
}

/// Execute block data transfer (LDM/STM)
fn executeBlockTransfer(regs: *RegisterFile, bus: *const MemoryBus, instruction: u32) u32 {
    const bt = decoder.BlockTransfer.decode(instruction);

    if (bt.register_list == 0) {
        // Empty register list - undefined behavior, skip
        return 1;
    }

    const base = regs.get(bt.rn);
    const count = bt.registerCount();

    // Calculate start address (use wrapping arithmetic as ARM does)
    var address: u32 = undefined;
    if (bt.add_offset) {
        address = if (bt.pre_index) base +% 4 else base;
    } else {
        address = if (bt.pre_index) base -% (@as(u32, count) * 4) else base -% (@as(u32, count) * 4) +% 4;
    }

    // Transfer registers
    var reg_list = bt.register_list;
    var i: u5 = 0; // Use u5 to avoid overflow when iterating through 16 registers
    while (reg_list != 0 and i < 16) : (i += 1) {
        if ((reg_list & 1) != 0) {
            const reg_num: u4 = @truncate(i);
            if (bt.is_load) {
                const value = bus.read32(address);
                regs.set(reg_num, value);
            } else {
                var value = regs.get(reg_num);
                if (reg_num == 15) {
                    value = regs.getPcWithOffset() + 4;
                }
                bus.write32(address, value);
            }
            address +%= 4;
        }
        reg_list >>= 1;
    }

    // Write-back
    if (bt.write_back) {
        var new_base: u32 = undefined;
        if (bt.add_offset) {
            new_base = base +% (@as(u32, count) * 4);
        } else {
            new_base = base -% (@as(u32, count) * 4);
        }
        regs.set(bt.rn, new_base);
    }

    // Load PSR if S bit set and PC in list (LDM with ^ and PC)
    // Use returnFromExceptionLdm since PC was already loaded from memory
    if (bt.is_load and bt.load_psr and (bt.register_list & 0x8000) != 0) {
        exceptions.returnFromExceptionLdm(regs);
    }

    // Cycles: n + 2 for load, n + 1 for store
    return if (bt.is_load) @as(u32, count) + 2 else @as(u32, count) + 1;
}

/// Execute branch instruction
fn executeBranch(regs: *RegisterFile, instruction: u32) u32 {
    const br = decoder.Branch.decode(instruction);

    if (br.link) {
        // Save return address in LR
        // r[15] is already PC+4 (next instruction), which is the correct return address
        regs.r[14] = regs.r[15];
    }

    // Calculate target: PC + 8 + offset*4
    // Since r[15] is already PC+4, we need to add another 4 to get PC+8 behavior
    const pc = regs.r[15] +% 4; // Add 4 to simulate PC+8
    const offset = br.getTargetOffset();
    regs.r[15] = @bitCast(@as(i32, @bitCast(pc)) +% offset);

    return 3;
}

/// Execute branch and exchange
fn executeBranchExchange(regs: *RegisterFile, instruction: u32) u32 {
    const bx = decoder.BranchExchange.decode(instruction);

    const target = regs.get(bx.rm);
    const was_thumb = regs.cpsr.thumb;

    // Bit 0 determines ARM/Thumb state
    regs.cpsr.thumb = (target & 1) != 0;

    // Set PC (aligned appropriately)
    if (regs.cpsr.thumb) {
        regs.r[15] = target & ~@as(u32, 1);
    } else {
        regs.r[15] = target & ~@as(u32, 3);
    }

    // Debug: Log mode switches
    if (regs.cpsr.thumb != was_thumb) {
        std.debug.print("BX: Mode switch to {s} at PC=0x{X:0>8}, target=0x{X:0>8}\n", .{
            if (regs.cpsr.thumb) "THUMB" else "ARM",
            regs.r[15],
            target,
        });
    }

    return 3;
}

/// Execute software interrupt
fn executeSoftwareInterrupt(regs: *RegisterFile, instruction: u32) u32 {
    _ = instruction; // Comment field ignored
    return exceptions.enterException(regs, .swi);
}

/// Execute swap instruction
fn executeSwap(regs: *RegisterFile, bus: *const MemoryBus, instruction: u32) u32 {
    const swap = decoder.Swap.decode(instruction);

    const address = regs.get(swap.rn);

    if (swap.byte_swap) {
        const old_value = bus.read8(address);
        bus.write8(address, @truncate(regs.get(swap.rm)));
        regs.set(swap.rd, old_value);
    } else {
        const old_value = bus.read32(address & ~@as(u32, 3));
        bus.write32(address & ~@as(u32, 3), regs.get(swap.rm));
        regs.set(swap.rd, old_value);
    }

    return 4;
}

/// Execute MRS (move PSR to register)
fn executeMrs(regs: *RegisterFile, instruction: u32) u32 {
    const mrs = decoder.Mrs.decode(instruction);

    if (mrs.use_spsr) {
        if (regs.getSpsr()) |spsr| {
            regs.set(mrs.rd, spsr);
        }
    } else {
        regs.set(mrs.rd, @bitCast(regs.cpsr));
    }

    return 1;
}

/// Execute MSR (move register to PSR)
fn executeMsr(regs: *RegisterFile, instruction: u32) u32 {
    const msr = decoder.Msr.decode(instruction);

    // Calculate value to write
    var value: u32 = undefined;
    if (msr.is_immediate) {
        const rotate = @as(u5, msr.imm_rotate) * 2;
        value = std.math.rotr(u32, @as(u32, msr.imm_value), rotate);
    } else {
        value = regs.get(msr.rm);
    }

    // Build mask from field bits
    var mask: u32 = 0;
    if (msr.field_mask & 0x1 != 0) mask |= 0x000000FF; // c - control
    if (msr.field_mask & 0x2 != 0) mask |= 0x0000FF00; // x - extension
    if (msr.field_mask & 0x4 != 0) mask |= 0x00FF0000; // s - status
    if (msr.field_mask & 0x8 != 0) mask |= 0xFF000000; // f - flags

    // In user mode, can only write flags
    const current_mode = regs.cpsr.getMode();
    if (current_mode == .user) {
        mask &= 0xF0000000;
    }

    if (msr.use_spsr) {
        if (regs.getSpsr()) |spsr| {
            const new_spsr = (spsr & ~mask) | (value & mask);
            regs.setSpsr(new_spsr);
        }
    } else {
        const old_cpsr: u32 = @bitCast(regs.cpsr);
        const new_cpsr = (old_cpsr & ~mask) | (value & mask);
        const new_psr: PSR = @bitCast(new_cpsr);

        // Mode change requires register banking
        if (new_psr.getMode()) |new_mode| {
            if (current_mode != new_mode) {
                regs.switchMode(new_mode);
            }
        }

        regs.cpsr = @bitCast(new_cpsr);
    }

    return 1;
}

/// Execute CP15 (System Control Coprocessor) instruction
/// PP5021C doesn't have true CP15, but Rockbox uses these instructions.
/// We emulate basic CP15 functionality to allow the code to continue.
///
/// CP15 Register Layout:
/// - c0: ID registers (read-only)
/// - c1: Control register (cache/MMU enable bits)
/// - c7: Cache operations
/// - c9: Cache lockdown
///
/// Instruction formats:
/// MRC p15, op1, Rd, CRn, CRm, op2  - Read from CP15
/// MCR p15, op1, Rd, CRn, CRm, op2  - Write to CP15
fn executeCoprocessor15(regs: *RegisterFile, instruction: u32) u32 {
    // Decode coprocessor instruction fields
    const is_mrc = (instruction >> 20) & 0x1 == 1; // L bit: 1=MRC (read), 0=MCR (write)
    const crn: u4 = @truncate((instruction >> 16) & 0xF); // CRn field
    const rd: u4 = @truncate((instruction >> 12) & 0xF); // Destination/source register
    const op2: u3 = @truncate((instruction >> 5) & 0x7); // Opcode 2
    const crm: u4 = @truncate(instruction & 0xF); // CRm field

    // CP15 register values (emulated)
    // These are typical values for an ARM processor with caches disabled
    const cp15_regs = struct {
        // c0,c0,0 - Main ID Register: ARM7TDMI-like ID
        const main_id: u32 = 0x41007000;
        // c0,c0,1 - Cache Type Register: No caches
        const cache_type: u32 = 0x00000000;
        // c1,c0,0 - Control Register: Everything disabled
        const control: u32 = 0x00000000;
    };

    if (is_mrc) {
        // MRC - Read from CP15
        var value: u32 = 0;

        switch (crn) {
            0 => {
                // ID registers
                switch (crm) {
                    0 => {
                        switch (op2) {
                            0 => value = cp15_regs.main_id, // Main ID
                            1 => value = cp15_regs.cache_type, // Cache Type
                            else => value = 0,
                        }
                    },
                    else => value = 0,
                }
            },
            1 => {
                // Control register
                if (crm == 0 and op2 == 0) {
                    value = cp15_regs.control;
                }
            },
            else => {
                // Other registers return 0
                value = 0;
            },
        }

        // Write result to destination register
        if (rd == 15) {
            // When Rd=PC, the result sets condition flags instead of writing to PC
            // This is used for test/wait operations (e.g., cache clean test)
            // Set NZCV flags based on result:
            // - N = bit 31, Z = (result == 0), C = bit 30, V = bit 29
            regs.cpsr.negative = (value >> 31) != 0;
            regs.cpsr.zero = (value == 0);
            regs.cpsr.carry = ((value >> 30) & 1) != 0;
            regs.cpsr.overflow = ((value >> 29) & 1) != 0;
        } else {
            regs.set(rd, value);
        }

        // Debug trace for first few accesses
        const count = struct {
            var c: u32 = 0;
        };
        if (count.c < 10) {
            count.c += 1;
            if (rd == 15) {
                std.debug.print("CP15 MRC: CRn={}, CRm={}, op2={}, Rd=PC (flags: N={} Z={} C={} V={})\n", .{ crn, crm, op2, @intFromBool(regs.cpsr.negative), @intFromBool(regs.cpsr.zero), @intFromBool(regs.cpsr.carry), @intFromBool(regs.cpsr.overflow) });
            } else {
                std.debug.print("CP15 MRC: CRn={}, CRm={}, op2={}, Rd=r{} -> 0x{X:0>8}\n", .{ crn, crm, op2, rd, value });
            }
        }
    } else {
        // MCR - Write to CP15 (ignored, but logged)
        const value = regs.get(rd);

        const count = struct {
            var c: u32 = 0;
        };
        if (count.c < 10) {
            count.c += 1;
            std.debug.print("CP15 MCR: CRn={}, CRm={}, op2={}, value=0x{X:0>8} (ignored)\n", .{ crn, crm, op2, value });
        }
    }

    return 1; // 1 cycle for coprocessor operations
}

// Tests
test "ADD instruction" {
    var regs = RegisterFile.init();

    // Simple mock memory bus
    const MockBus = struct {
        fn read8(_: *anyopaque, _: u32) u8 {
            return 0;
        }
        fn read16(_: *anyopaque, _: u32) u16 {
            return 0;
        }
        fn read32(_: *anyopaque, _: u32) u32 {
            return 0;
        }
        fn write8(_: *anyopaque, _: u32, _: u8) void {}
        fn write16(_: *anyopaque, _: u32, _: u16) void {}
        fn write32(_: *anyopaque, _: u32, _: u32) void {}
    };

    var ctx: u8 = 0;
    const bus = MemoryBus{
        .context = @ptrCast(&ctx),
        .read8Fn = MockBus.read8,
        .read16Fn = MockBus.read16,
        .read32Fn = MockBus.read32,
        .write8Fn = MockBus.write8,
        .write16Fn = MockBus.write16,
        .write32Fn = MockBus.write32,
    };

    // ADD R0, R1, #5
    regs.set(1, 10);
    const add_instr: u32 = 0xE2810005; // ADD R0, R1, #5
    const cycles = execute(&regs, &bus, add_instr);

    try std.testing.expectEqual(@as(u32, 1), cycles);
    try std.testing.expectEqual(@as(u32, 15), regs.get(0));
}
