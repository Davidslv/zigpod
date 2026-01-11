//! Thumb (16-bit) Instruction Executor
//!
//! Executes decoded Thumb instructions and returns cycle count.
//!
//! Reference: ARM7TDMI Technical Reference Manual (ARM DDI 0029E) Section 6

const std = @import("std");
const registers = @import("registers.zig");
const thumb_decoder = @import("thumb_decoder.zig");
const arm_executor = @import("arm_executor.zig");
const exceptions = @import("exceptions.zig");

const RegisterFile = registers.RegisterFile;
const MemoryBus = arm_executor.MemoryBus;

/// Execute a single Thumb instruction
/// Returns the number of cycles consumed
pub fn execute(regs: *RegisterFile, bus: *const MemoryBus, instruction: u16) u32 {
    const format = thumb_decoder.decodeFormat(instruction);

    return switch (format) {
        .move_shifted_register => executeMoveShiftedRegister(regs, instruction),
        .add_subtract => executeAddSubtract(regs, instruction),
        .mov_cmp_add_sub_imm => executeMovCmpAddSubImm(regs, instruction),
        .alu_operations => executeAluOperations(regs, instruction),
        .hi_register_bx => executeHiRegisterBx(regs, instruction),
        .pc_relative_load => executePcRelativeLoad(regs, bus, instruction),
        .load_store_register => executeLoadStoreRegister(regs, bus, instruction),
        .load_store_sign_extended => executeLoadStoreSignExtended(regs, bus, instruction),
        .load_store_immediate => executeLoadStoreImmediate(regs, bus, instruction),
        .load_store_halfword => executeLoadStoreHalfword(regs, bus, instruction),
        .sp_relative_load_store => executeSpRelativeLoadStore(regs, bus, instruction),
        .load_address => executeLoadAddress(regs, instruction),
        .add_offset_sp => executeAddOffsetSp(regs, instruction),
        .push_pop => executePushPop(regs, bus, instruction),
        .multiple_load_store => executeMultipleLoadStore(regs, bus, instruction),
        .conditional_branch => executeConditionalBranch(regs, instruction),
        .software_interrupt => executeSoftwareInterrupt(regs),
        .unconditional_branch => executeUnconditionalBranch(regs, instruction),
        .long_branch_link => executeLongBranchLink(regs, instruction),
        .undefined => {
            _ = exceptions.enterException(regs, .undefined);
            return 3;
        },
    };
}

/// Format 1: Move shifted register
fn executeMoveShiftedRegister(regs: *RegisterFile, instruction: u16) u32 {
    const op = thumb_decoder.MoveShiftedRegister.decode(instruction);

    const rs_value = regs.get(op.rs);
    var result: u32 = undefined;
    var carry = regs.cpsr.carry;

    switch (op.op) {
        0b00 => { // LSL
            if (op.offset == 0) {
                result = rs_value;
            } else {
                const shift_for_carry: u5 = @intCast(32 - @as(u8, op.offset));
                carry = (rs_value >> shift_for_carry) & 1 != 0;
                result = rs_value << op.offset;
            }
        },
        0b01 => { // LSR
            if (op.offset == 0) {
                // LSR #0 is actually LSR #32
                carry = (rs_value & 0x80000000) != 0;
                result = 0;
            } else {
                const shift_for_carry: u5 = op.offset - 1;
                carry = (rs_value >> shift_for_carry) & 1 != 0;
                result = rs_value >> op.offset;
            }
        },
        0b10 => { // ASR
            const amount: u8 = if (op.offset == 0) 32 else op.offset;
            const signed: i32 = @bitCast(rs_value);
            if (amount >= 32) {
                result = if (signed < 0) 0xFFFFFFFF else 0;
                carry = (rs_value & 0x80000000) != 0;
            } else {
                carry = (rs_value >> @intCast(amount - 1)) & 1 != 0;
                result = @bitCast(signed >> @intCast(amount));
            }
        },
        else => result = rs_value,
    }

    regs.set(op.rd, result);

    // Update flags
    regs.cpsr.negative = (result & 0x80000000) != 0;
    regs.cpsr.zero = result == 0;
    regs.cpsr.carry = carry;

    return 1;
}

/// Format 2: Add/subtract
fn executeAddSubtract(regs: *RegisterFile, instruction: u16) u32 {
    const op = thumb_decoder.AddSubtract.decode(instruction);

    const rs_value = regs.get(op.rs);
    const operand: u32 = if (op.is_immediate) op.rn_or_imm else regs.get(op.rn_or_imm);

    var result: u32 = undefined;
    var carry: bool = undefined;
    var overflow: bool = undefined;

    if (op.is_subtract) {
        // SUB
        const sub_result = subWithCarry(rs_value, operand);
        result = sub_result.result;
        carry = sub_result.carry;
        overflow = sub_result.overflow;
    } else {
        // ADD
        const add_result = addWithCarry(rs_value, operand);
        result = add_result.result;
        carry = add_result.carry;
        overflow = add_result.overflow;
    }

    regs.set(op.rd, result);

    regs.cpsr.negative = (result & 0x80000000) != 0;
    regs.cpsr.zero = result == 0;
    regs.cpsr.carry = carry;
    regs.cpsr.overflow = overflow;

    return 1;
}

/// Format 3: Move/compare/add/subtract immediate
fn executeMovCmpAddSubImm(regs: *RegisterFile, instruction: u16) u32 {
    const op = thumb_decoder.MovCmpAddSubImm.decode(instruction);

    const rd_value = regs.get(op.rd);
    const imm: u32 = op.offset;

    var result: u32 = undefined;
    var carry = regs.cpsr.carry;
    var overflow = regs.cpsr.overflow;
    var write_result = true;

    switch (op.op) {
        0b00 => { // MOV
            result = imm;
        },
        0b01 => { // CMP
            const sub_result = subWithCarry(rd_value, imm);
            result = sub_result.result;
            carry = sub_result.carry;
            overflow = sub_result.overflow;
            write_result = false;
        },
        0b10 => { // ADD
            const add_result = addWithCarry(rd_value, imm);
            result = add_result.result;
            carry = add_result.carry;
            overflow = add_result.overflow;
        },
        0b11 => { // SUB
            const sub_result = subWithCarry(rd_value, imm);
            result = sub_result.result;
            carry = sub_result.carry;
            overflow = sub_result.overflow;
        },
    }

    if (write_result) {
        regs.set(op.rd, result);
    }

    regs.cpsr.negative = (result & 0x80000000) != 0;
    regs.cpsr.zero = result == 0;
    if (op.op != 0b00) { // MOV doesn't affect C/V
        regs.cpsr.carry = carry;
        regs.cpsr.overflow = overflow;
    }

    return 1;
}

/// Format 4: ALU operations
fn executeAluOperations(regs: *RegisterFile, instruction: u16) u32 {
    const op = thumb_decoder.AluOperations.decode(instruction);

    const rd_value = regs.get(op.rd);
    const rs_value = regs.get(op.rs);

    var result: u32 = undefined;
    var carry = regs.cpsr.carry;
    var overflow = regs.cpsr.overflow;
    var write_result = true;
    var cycles: u32 = 1;

    switch (op.op) {
        .AND => result = rd_value & rs_value,
        .EOR => result = rd_value ^ rs_value,
        .LSL => {
            const amount = rs_value & 0xFF;
            if (amount == 0) {
                result = rd_value;
            } else if (amount < 32) {
                carry = (rd_value >> @intCast(32 - @as(u8, @truncate(amount)))) & 1 != 0;
                result = rd_value << @intCast(amount);
            } else if (amount == 32) {
                carry = (rd_value & 1) != 0;
                result = 0;
            } else {
                carry = false;
                result = 0;
            }
            cycles = 2;
        },
        .LSR => {
            const amount = rs_value & 0xFF;
            if (amount == 0) {
                result = rd_value;
            } else if (amount < 32) {
                carry = (rd_value >> @intCast(amount - 1)) & 1 != 0;
                result = rd_value >> @intCast(amount);
            } else if (amount == 32) {
                carry = (rd_value & 0x80000000) != 0;
                result = 0;
            } else {
                carry = false;
                result = 0;
            }
            cycles = 2;
        },
        .ASR => {
            const amount = rs_value & 0xFF;
            const signed: i32 = @bitCast(rd_value);
            if (amount == 0) {
                result = rd_value;
            } else if (amount < 32) {
                carry = (rd_value >> @intCast(amount - 1)) & 1 != 0;
                result = @bitCast(signed >> @intCast(amount));
            } else {
                carry = (rd_value & 0x80000000) != 0;
                result = if (signed < 0) 0xFFFFFFFF else 0;
            }
            cycles = 2;
        },
        .ADC => {
            const add_result = addWithCarryIn(rd_value, rs_value, regs.cpsr.carry);
            result = add_result.result;
            carry = add_result.carry;
            overflow = add_result.overflow;
        },
        .SBC => {
            const sub_result = subWithBorrow(rd_value, rs_value, regs.cpsr.carry);
            result = sub_result.result;
            carry = sub_result.carry;
            overflow = sub_result.overflow;
        },
        .ROR => {
            const amount = rs_value & 0xFF;
            if (amount == 0) {
                result = rd_value;
            } else {
                const effective: u5 = @intCast(amount & 31);
                if (effective == 0) {
                    carry = (rd_value & 0x80000000) != 0;
                    result = rd_value;
                } else {
                    result = std.math.rotr(u32, rd_value, effective);
                    carry = (result & 0x80000000) != 0;
                }
            }
            cycles = 2;
        },
        .TST => {
            result = rd_value & rs_value;
            write_result = false;
        },
        .NEG => {
            const sub_result = subWithCarry(0, rs_value);
            result = sub_result.result;
            carry = sub_result.carry;
            overflow = sub_result.overflow;
        },
        .CMP => {
            const sub_result = subWithCarry(rd_value, rs_value);
            result = sub_result.result;
            carry = sub_result.carry;
            overflow = sub_result.overflow;
            write_result = false;
        },
        .CMN => {
            const add_result = addWithCarry(rd_value, rs_value);
            result = add_result.result;
            carry = add_result.carry;
            overflow = add_result.overflow;
            write_result = false;
        },
        .ORR => result = rd_value | rs_value,
        .MUL => {
            result = rd_value *% rs_value;
            cycles = 3; // Simplified
        },
        .BIC => result = rd_value & ~rs_value,
        .MVN => result = ~rs_value,
    }

    if (write_result) {
        regs.set(op.rd, result);
    }

    regs.cpsr.negative = (result & 0x80000000) != 0;
    regs.cpsr.zero = result == 0;
    regs.cpsr.carry = carry;
    switch (op.op) {
        .ADC, .SBC, .NEG, .CMP, .CMN => regs.cpsr.overflow = overflow,
        else => {},
    }

    return cycles;
}

/// Format 5: Hi register operations / BX
fn executeHiRegisterBx(regs: *RegisterFile, instruction: u16) u32 {
    const op = thumb_decoder.HiRegisterBx.decode(instruction);

    const rd = op.getFullRd();
    const rs = op.getFullRs();
    const rs_value = if (rs == 15) regs.getPcWithOffset() else regs.get(rs);

    switch (op.op) {
        0b00 => { // ADD
            const rd_value = if (rd == 15) regs.getPcWithOffset() else regs.get(rd);
            regs.set(rd, rd_value +% rs_value);
        },
        0b01 => { // CMP
            const rd_value = regs.get(rd);
            const sub_result = subWithCarry(rd_value, rs_value);
            regs.cpsr.negative = (sub_result.result & 0x80000000) != 0;
            regs.cpsr.zero = sub_result.result == 0;
            regs.cpsr.carry = sub_result.carry;
            regs.cpsr.overflow = sub_result.overflow;
        },
        0b10 => { // MOV
            regs.set(rd, rs_value);
        },
        0b11 => { // BX
            regs.cpsr.thumb = (rs_value & 1) != 0;
            if (regs.cpsr.thumb) {
                regs.r[15] = rs_value & ~@as(u32, 1);
            } else {
                regs.r[15] = rs_value & ~@as(u32, 3);
            }
            return 3;
        },
    }

    return 1;
}

/// Format 6: PC-relative load
fn executePcRelativeLoad(regs: *RegisterFile, bus: *const MemoryBus, instruction: u16) u32 {
    const op = thumb_decoder.PcRelativeLoad.decode(instruction);

    // PC is aligned down to word boundary, then add offset
    const pc = regs.r[15] & ~@as(u32, 3);
    const address = pc +% op.getOffset();

    regs.set(op.rd, bus.read32(address));

    return 3;
}

/// Format 7: Load/store with register offset
fn executeLoadStoreRegister(regs: *RegisterFile, bus: *const MemoryBus, instruction: u16) u32 {
    const op = thumb_decoder.LoadStoreRegister.decode(instruction);

    const address = regs.get(op.rb) +% regs.get(op.ro);

    if (op.is_load) {
        if (op.is_byte) {
            regs.set(op.rd, bus.read8(address));
        } else {
            // Word load with rotation for unaligned
            const aligned = address & ~@as(u32, 3);
            var value = bus.read32(aligned);
            const rotation: u5 = @intCast((address & 3) * 8);
            if (rotation != 0) {
                value = std.math.rotr(u32, value, rotation);
            }
            regs.set(op.rd, value);
        }
        return 3;
    } else {
        if (op.is_byte) {
            bus.write8(address, @truncate(regs.get(op.rd)));
        } else {
            bus.write32(address & ~@as(u32, 3), regs.get(op.rd));
        }
        return 2;
    }
}

/// Format 8: Load/store sign-extended byte/halfword
fn executeLoadStoreSignExtended(regs: *RegisterFile, bus: *const MemoryBus, instruction: u16) u32 {
    const op = thumb_decoder.LoadStoreSignExtended.decode(instruction);

    const address = regs.get(op.rb) +% regs.get(op.ro);

    switch (op.getOperation()) {
        0 => { // STRH
            bus.write16(address & ~@as(u32, 1), @truncate(regs.get(op.rd)));
            return 2;
        },
        1 => { // LDSB
            const byte = bus.read8(address);
            regs.set(op.rd, @bitCast(@as(i32, @as(i8, @bitCast(byte)))));
            return 3;
        },
        2 => { // LDRH
            regs.set(op.rd, bus.read16(address & ~@as(u32, 1)));
            return 3;
        },
        3 => { // LDSH
            const half = bus.read16(address & ~@as(u32, 1));
            regs.set(op.rd, @bitCast(@as(i32, @as(i16, @bitCast(half)))));
            return 3;
        },
    }
}

/// Format 9: Load/store with immediate offset
fn executeLoadStoreImmediate(regs: *RegisterFile, bus: *const MemoryBus, instruction: u16) u32 {
    const op = thumb_decoder.LoadStoreImmediate.decode(instruction);

    const address = regs.get(op.rb) +% op.getByteOffset();

    if (op.is_load) {
        if (op.is_byte) {
            regs.set(op.rd, bus.read8(address));
        } else {
            regs.set(op.rd, bus.read32(address & ~@as(u32, 3)));
        }
        return 3;
    } else {
        if (op.is_byte) {
            bus.write8(address, @truncate(regs.get(op.rd)));
        } else {
            bus.write32(address & ~@as(u32, 3), regs.get(op.rd));
        }
        return 2;
    }
}

/// Format 10: Load/store halfword
fn executeLoadStoreHalfword(regs: *RegisterFile, bus: *const MemoryBus, instruction: u16) u32 {
    const op = thumb_decoder.LoadStoreHalfword.decode(instruction);

    const address = regs.get(op.rb) +% op.getByteOffset();

    if (op.is_load) {
        regs.set(op.rd, bus.read16(address & ~@as(u32, 1)));
        return 3;
    } else {
        bus.write16(address & ~@as(u32, 1), @truncate(regs.get(op.rd)));
        return 2;
    }
}

/// Format 11: SP-relative load/store
fn executeSpRelativeLoadStore(regs: *RegisterFile, bus: *const MemoryBus, instruction: u16) u32 {
    const op = thumb_decoder.SpRelativeLoadStore.decode(instruction);

    const address = regs.get(13) +% op.getByteOffset();

    if (op.is_load) {
        regs.set(op.rd, bus.read32(address & ~@as(u32, 3)));
        return 3;
    } else {
        bus.write32(address & ~@as(u32, 3), regs.get(op.rd));
        return 2;
    }
}

/// Format 12: Load address
fn executeLoadAddress(regs: *RegisterFile, instruction: u16) u32 {
    const op = thumb_decoder.LoadAddress.decode(instruction);

    const base: u32 = if (op.is_sp)
        regs.get(13)
    else
        regs.r[15] & ~@as(u32, 3); // PC aligned

    regs.set(op.rd, base +% op.getByteOffset());

    return 1;
}

/// Format 13: Add offset to SP
fn executeAddOffsetSp(regs: *RegisterFile, instruction: u16) u32 {
    const op = thumb_decoder.AddOffsetSp.decode(instruction);

    const sp = regs.get(13);
    const offset = op.getByteOffset();

    regs.set(13, @bitCast(@as(i32, @bitCast(sp)) +% offset));

    return 1;
}

/// Format 14: Push/pop registers
fn executePushPop(regs: *RegisterFile, bus: *const MemoryBus, instruction: u16) u32 {
    const op = thumb_decoder.PushPop.decode(instruction);

    var sp = regs.get(13);
    var count: u32 = @popCount(op.register_list);
    if (op.store_lr) count += 1;

    if (op.is_load) {
        // POP (LDMIA SP!)
        var reg_list = op.register_list;
        var i: u4 = 0;
        while (reg_list != 0) : (i += 1) {
            if ((reg_list & 1) != 0) {
                regs.set(i, bus.read32(sp));
                sp += 4;
            }
            reg_list >>= 1;
        }
        if (op.store_lr) {
            // Pop PC
            const value = bus.read32(sp);
            sp += 4;
            // BX-like behavior
            regs.cpsr.thumb = (value & 1) != 0;
            regs.r[15] = value & ~@as(u32, 1);
        }
        regs.set(13, sp);
        return count + 2;
    } else {
        // PUSH (STMDB SP!)
        sp -= count * 4;
        regs.set(13, sp);

        var address = sp;
        var reg_list = op.register_list;
        var i: u4 = 0;
        while (reg_list != 0) : (i += 1) {
            if ((reg_list & 1) != 0) {
                bus.write32(address, regs.get(i));
                address += 4;
            }
            reg_list >>= 1;
        }
        if (op.store_lr) {
            bus.write32(address, regs.get(14));
        }
        return count + 1;
    }
}

/// Format 15: Multiple load/store
fn executeMultipleLoadStore(regs: *RegisterFile, bus: *const MemoryBus, instruction: u16) u32 {
    const op = thumb_decoder.MultipleLoadStore.decode(instruction);

    var address = regs.get(op.rb);
    const count: u32 = @popCount(op.register_list);

    var reg_list = op.register_list;
    var i: u4 = 0;
    while (reg_list != 0) : (i += 1) {
        if ((reg_list & 1) != 0) {
            if (op.is_load) {
                regs.set(i, bus.read32(address));
            } else {
                bus.write32(address, regs.get(i));
            }
            address += 4;
        }
        reg_list >>= 1;
    }

    // Write back base register
    regs.set(op.rb, address);

    return if (op.is_load) count + 2 else count + 1;
}

/// Format 16: Conditional branch
fn executeConditionalBranch(regs: *RegisterFile, instruction: u16) u32 {
    const op = thumb_decoder.ConditionalBranch.decode(instruction);

    if (op.condition.check(regs.cpsr.negative, regs.cpsr.zero, regs.cpsr.carry, regs.cpsr.overflow)) {
        const pc: i32 = @bitCast(regs.r[15]);
        regs.r[15] = @bitCast(pc +% op.getByteOffset());
        return 3;
    }

    return 1;
}

/// Format 17: Software interrupt
fn executeSoftwareInterrupt(regs: *RegisterFile) u32 {
    return exceptions.enterException(regs, .swi);
}

/// Format 18: Unconditional branch
fn executeUnconditionalBranch(regs: *RegisterFile, instruction: u16) u32 {
    const op = thumb_decoder.UnconditionalBranch.decode(instruction);

    const pc: i32 = @bitCast(regs.r[15]);
    regs.r[15] = @bitCast(pc +% op.getByteOffset());

    return 3;
}

/// Format 19: Long branch with link (two-instruction sequence)
fn executeLongBranchLink(regs: *RegisterFile, instruction: u16) u32 {
    const op = thumb_decoder.LongBranchLink.decode(instruction);

    if (!op.is_low) {
        // First instruction: LR = PC + (offset << 12)
        const pc = regs.r[15];
        const offset: i32 = @as(i32, @as(i11, @bitCast(@as(u11, @truncate(op.offset))))) << 12;
        regs.r[14] = @bitCast(@as(i32, @bitCast(pc)) +% offset);
        return 1;
    } else {
        // Second instruction: temp = next instruction address
        //                     PC = LR + (offset << 1)
        //                     LR = temp | 1
        const next_addr = regs.r[15] - 2;
        const lr = regs.r[14];
        const offset: u32 = @as(u32, op.offset) << 1;
        regs.r[15] = (lr +% offset) & ~@as(u32, 1);
        regs.r[14] = next_addr | 1;
        return 3;
    }
}

// Helper functions

fn addWithCarry(a: u32, b: u32) struct { result: u32, carry: bool, overflow: bool } {
    const result = a +% b;
    const carry = result < a;
    const overflow = ((a ^ result) & (b ^ result) & 0x80000000) != 0;
    return .{ .result = result, .carry = carry, .overflow = overflow };
}

fn addWithCarryIn(a: u32, b: u32, carry_in: bool) struct { result: u32, carry: bool, overflow: bool } {
    const c: u32 = @intFromBool(carry_in);
    const ab = a +% b;
    const result = ab +% c;
    const carry = (result < a) or (result < b) or (ab < a);
    const overflow = ((a ^ result) & (b ^ result) & 0x80000000) != 0;
    return .{ .result = result, .carry = carry, .overflow = overflow };
}

fn subWithCarry(a: u32, b: u32) struct { result: u32, carry: bool, overflow: bool } {
    const result = a -% b;
    const carry = a >= b; // No borrow
    const overflow = ((a ^ b) & (a ^ result) & 0x80000000) != 0;
    return .{ .result = result, .carry = carry, .overflow = overflow };
}

fn subWithBorrow(a: u32, b: u32, carry_in: bool) struct { result: u32, carry: bool, overflow: bool } {
    // SBC: a - b - !C = a - b - 1 + C
    const c: u32 = @intFromBool(carry_in);
    const result = a -% b -% 1 +% c;
    const carry = if (carry_in) a >= b else a > b;
    const overflow = ((a ^ b) & (a ^ result) & 0x80000000) != 0;
    return .{ .result = result, .carry = carry, .overflow = overflow };
}
