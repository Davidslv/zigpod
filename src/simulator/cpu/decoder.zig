//! ARM7TDMI Instruction Decoder
//!
//! Decodes ARM (32-bit) and Thumb (16-bit) instructions into a unified
//! instruction representation for execution.

const std = @import("std");

/// ARM condition codes (bits 31-28)
pub const Condition = enum(u4) {
    eq = 0b0000, // Equal (Z set)
    ne = 0b0001, // Not equal (Z clear)
    cs = 0b0010, // Carry set / unsigned higher or same
    cc = 0b0011, // Carry clear / unsigned lower
    mi = 0b0100, // Minus / negative (N set)
    pl = 0b0101, // Plus / positive or zero (N clear)
    vs = 0b0110, // Overflow (V set)
    vc = 0b0111, // No overflow (V clear)
    hi = 0b1000, // Unsigned higher (C set and Z clear)
    ls = 0b1001, // Unsigned lower or same (C clear or Z set)
    ge = 0b1010, // Signed greater than or equal (N == V)
    lt = 0b1011, // Signed less than (N != V)
    gt = 0b1100, // Signed greater than (Z clear and N == V)
    le = 0b1101, // Signed less than or equal (Z set or N != V)
    al = 0b1110, // Always (unconditional)
    nv = 0b1111, // Never (used for special instructions in ARMv5+)

    /// Check if condition passes given CPSR flags
    pub fn evaluate(self: Condition, n: bool, z: bool, c: bool, v: bool) bool {
        return switch (self) {
            .eq => z,
            .ne => !z,
            .cs => c,
            .cc => !c,
            .mi => n,
            .pl => !n,
            .vs => v,
            .vc => !v,
            .hi => c and !z,
            .ls => !c or z,
            .ge => n == v,
            .lt => n != v,
            .gt => !z and (n == v),
            .le => z or (n != v),
            .al => true,
            .nv => false, // Unconditional in ARMv5+, undefined in ARMv4
        };
    }
};

/// Data processing opcodes
pub const DpOpcode = enum(u4) {
    @"and" = 0b0000, // Rd = Rn AND Op2
    eor = 0b0001, // Rd = Rn XOR Op2
    sub = 0b0010, // Rd = Rn - Op2
    rsb = 0b0011, // Rd = Op2 - Rn
    add = 0b0100, // Rd = Rn + Op2
    adc = 0b0101, // Rd = Rn + Op2 + C
    sbc = 0b0110, // Rd = Rn - Op2 - !C
    rsc = 0b0111, // Rd = Op2 - Rn - !C
    tst = 0b1000, // Rn AND Op2 (flags only)
    teq = 0b1001, // Rn XOR Op2 (flags only)
    cmp = 0b1010, // Rn - Op2 (flags only)
    cmn = 0b1011, // Rn + Op2 (flags only)
    orr = 0b1100, // Rd = Rn OR Op2
    mov = 0b1101, // Rd = Op2
    bic = 0b1110, // Rd = Rn AND NOT Op2
    mvn = 0b1111, // Rd = NOT Op2

    /// Check if this is a test instruction (doesn't write Rd)
    pub fn isTest(self: DpOpcode) bool {
        return switch (self) {
            .tst, .teq, .cmp, .cmn => true,
            else => false,
        };
    }

    /// Check if this instruction uses Rn
    pub fn usesRn(self: DpOpcode) bool {
        return switch (self) {
            .mov, .mvn => false,
            else => true,
        };
    }
};

/// Shift types for operand 2
pub const ShiftType = enum(u2) {
    lsl = 0b00, // Logical shift left
    lsr = 0b01, // Logical shift right
    asr = 0b10, // Arithmetic shift right
    ror = 0b11, // Rotate right (RRX if shift amount is 0)
};

/// Operand 2 encoding
pub const Operand2 = union(enum) {
    /// Immediate value (8-bit rotated)
    immediate: struct {
        value: u8,
        rotate: u4,
    },
    /// Register with shift
    register: struct {
        rm: u4,
        shift_type: ShiftType,
        shift_amount: ShiftAmount,
    },

    pub const ShiftAmount = union(enum) {
        immediate: u5,
        register: u4,
    };

    /// Decode operand 2 from instruction bits [11:0]
    pub fn decode(bits: u12, is_immediate: bool) Operand2 {
        if (is_immediate) {
            return .{
                .immediate = .{
                    .value = @truncate(bits & 0xFF),
                    .rotate = @truncate((bits >> 8) & 0xF),
                },
            };
        } else {
            const rm: u4 = @truncate(bits & 0xF);
            const shift_type: ShiftType = @enumFromInt((bits >> 5) & 0x3);
            const is_reg_shift = (bits & 0x10) != 0;

            return .{
                .register = .{
                    .rm = rm,
                    .shift_type = shift_type,
                    .shift_amount = if (is_reg_shift)
                        .{ .register = @truncate((bits >> 8) & 0xF) }
                    else
                        .{ .immediate = @truncate((bits >> 7) & 0x1F) },
                },
            };
        }
    }
};

/// Decoded instruction representation
pub const Instruction = union(enum) {
    /// Data processing instruction
    data_processing: struct {
        cond: Condition,
        opcode: DpOpcode,
        set_flags: bool,
        rn: u4,
        rd: u4,
        operand2: Operand2,
    },

    /// Multiply instruction
    multiply: struct {
        cond: Condition,
        accumulate: bool,
        set_flags: bool,
        rd: u4,
        rn: u4, // Used only if accumulate
        rs: u4,
        rm: u4,
    },

    /// Multiply long instruction (UMULL, UMLAL, SMULL, SMLAL)
    multiply_long: struct {
        cond: Condition,
        signed: bool,
        accumulate: bool,
        set_flags: bool,
        rd_hi: u4,
        rd_lo: u4,
        rs: u4,
        rm: u4,
    },

    /// Single data transfer (LDR, STR)
    single_transfer: struct {
        cond: Condition,
        load: bool, // true = LDR, false = STR
        write_back: bool,
        byte: bool, // true = byte transfer
        up: bool, // true = add offset, false = subtract
        pre_index: bool, // true = pre-indexed
        rn: u4,
        rd: u4,
        offset: TransferOffset,
    },

    /// Halfword/signed data transfer (LDRH, STRH, LDRSB, LDRSH)
    halfword_transfer: struct {
        cond: Condition,
        load: bool,
        write_back: bool,
        up: bool,
        pre_index: bool,
        signed: bool,
        halfword: bool, // false = byte (for signed loads)
        rn: u4,
        rd: u4,
        offset: HalfwordOffset,
    },

    /// Block data transfer (LDM, STM)
    block_transfer: struct {
        cond: Condition,
        load: bool,
        write_back: bool,
        psr_force_user: bool, // S bit
        up: bool,
        pre_index: bool,
        rn: u4,
        register_list: u16,
    },

    /// Branch instruction (B, BL)
    branch: struct {
        cond: Condition,
        link: bool,
        offset: i24,
    },

    /// Branch and exchange (BX)
    branch_exchange: struct {
        cond: Condition,
        rn: u4,
    },

    /// Software interrupt (SWI)
    software_interrupt: struct {
        cond: Condition,
        comment: u24,
    },

    /// Move to/from status register (MRS, MSR)
    status_register: struct {
        cond: Condition,
        to_status: bool, // true = MSR, false = MRS
        use_spsr: bool, // true = SPSR, false = CPSR
        flags_only: bool, // true = only flags field
        source: StatusSource,
    },

    /// Coprocessor data transfer (LDC, STC)
    coprocessor_transfer: struct {
        cond: Condition,
        load: bool,
        write_back: bool,
        transfer_length: bool, // N bit
        up: bool,
        pre_index: bool,
        coproc: u4,
        crd: u4,
        rn: u4,
        offset: u8,
    },

    /// Coprocessor register transfer (MCR, MRC)
    coprocessor_register: struct {
        cond: Condition,
        to_arm: bool, // MRC = true, MCR = false
        opcode1: u3,
        crn: u4,
        rd: u4,
        coproc: u4,
        opcode2: u3,
        crm: u4,
    },

    /// Coprocessor data operation (CDP)
    coprocessor_data: struct {
        cond: Condition,
        opcode1: u4,
        crn: u4,
        crd: u4,
        coproc: u4,
        opcode2: u3,
        crm: u4,
    },

    /// Single data swap (SWP)
    swap: struct {
        cond: Condition,
        byte: bool,
        rn: u4,
        rd: u4,
        rm: u4,
    },

    /// Undefined instruction
    undefined: struct {
        cond: Condition,
        raw: u32,
    },

    pub const TransferOffset = union(enum) {
        immediate: u12,
        register: struct {
            rm: u4,
            shift_type: ShiftType,
            shift_amount: u5,
        },
    };

    pub const HalfwordOffset = union(enum) {
        immediate: u8,
        register: u4,
    };

    pub const StatusSource = union(enum) {
        register: u4,
        immediate: struct {
            value: u8,
            rotate: u4,
        },
    };
};

/// Decode a 32-bit ARM instruction
pub fn decode(raw: u32) Instruction {
    const cond: Condition = @enumFromInt(@as(u4, @truncate(raw >> 28)));

    // Bits 27-25 determine instruction class
    const class: u3 = @truncate((raw >> 25) & 0x7);

    // Special case: Multiply and swap instructions (bits 27-24 = 0000, bits 7-4 = 1001)
    if ((raw & 0x0FC000F0) == 0x00000090) {
        return decodeMultiply(raw, cond);
    }

    // Special case: Single data swap (bits 27-23 = 00010, bits 11-4 = 00001001)
    if ((raw & 0x0FB00FF0) == 0x01000090) {
        return decodeSwap(raw, cond);
    }

    // Special case: Branch and exchange (bits 27-4 = 0001_0010_1111_1111_1111_0001)
    if ((raw & 0x0FFFFFF0) == 0x012FFF10) {
        return .{
            .branch_exchange = .{
                .cond = cond,
                .rn = @truncate(raw & 0xF),
            },
        };
    }

    // Special case: Halfword and signed data transfer
    if ((raw & 0x0E000090) == 0x00000090 and (raw & 0x00000060) != 0) {
        return decodeHalfwordTransfer(raw, cond);
    }

    // Special case: MSR/MRS
    if ((raw & 0x0FBF0FFF) == 0x010F0000) {
        // MRS
        return .{
            .status_register = .{
                .cond = cond,
                .to_status = false,
                .use_spsr = (raw & 0x00400000) != 0,
                .flags_only = false,
                .source = .{ .register = @truncate((raw >> 12) & 0xF) },
            },
        };
    }
    if ((raw & 0x0DB0F000) == 0x0120F000) {
        // MSR
        const is_immediate = (raw & 0x02000000) != 0;
        return .{
            .status_register = .{
                .cond = cond,
                .to_status = true,
                .use_spsr = (raw & 0x00400000) != 0,
                .flags_only = (raw & 0x00010000) == 0,
                .source = if (is_immediate)
                    .{ .immediate = .{
                        .value = @truncate(raw & 0xFF),
                        .rotate = @truncate((raw >> 8) & 0xF),
                    } }
                else
                    .{ .register = @truncate(raw & 0xF) },
            },
        };
    }

    return switch (class) {
        0b000, 0b001 => decodeDataProcessing(raw, cond),
        0b010, 0b011 => decodeSingleTransfer(raw, cond),
        0b100 => decodeBlockTransfer(raw, cond),
        0b101 => decodeBranch(raw, cond),
        0b110 => decodeCoprocessorTransfer(raw, cond),
        0b111 => decodeCoprocessorOrSwi(raw, cond),
    };
}

fn decodeDataProcessing(raw: u32, cond: Condition) Instruction {
    const is_immediate = (raw & 0x02000000) != 0;
    const opcode: DpOpcode = @enumFromInt(@as(u4, @truncate((raw >> 21) & 0xF)));
    const set_flags = (raw & 0x00100000) != 0;
    const rn: u4 = @truncate((raw >> 16) & 0xF);
    const rd: u4 = @truncate((raw >> 12) & 0xF);

    return .{
        .data_processing = .{
            .cond = cond,
            .opcode = opcode,
            .set_flags = set_flags,
            .rn = rn,
            .rd = rd,
            .operand2 = Operand2.decode(@truncate(raw & 0xFFF), is_immediate),
        },
    };
}

fn decodeMultiply(raw: u32, cond: Condition) Instruction {
    const is_long = (raw & 0x00800000) != 0;

    if (is_long) {
        return .{
            .multiply_long = .{
                .cond = cond,
                .signed = (raw & 0x00400000) != 0,
                .accumulate = (raw & 0x00200000) != 0,
                .set_flags = (raw & 0x00100000) != 0,
                .rd_hi = @truncate((raw >> 16) & 0xF),
                .rd_lo = @truncate((raw >> 12) & 0xF),
                .rs = @truncate((raw >> 8) & 0xF),
                .rm = @truncate(raw & 0xF),
            },
        };
    } else {
        return .{
            .multiply = .{
                .cond = cond,
                .accumulate = (raw & 0x00200000) != 0,
                .set_flags = (raw & 0x00100000) != 0,
                .rd = @truncate((raw >> 16) & 0xF),
                .rn = @truncate((raw >> 12) & 0xF),
                .rs = @truncate((raw >> 8) & 0xF),
                .rm = @truncate(raw & 0xF),
            },
        };
    }
}

fn decodeSwap(raw: u32, cond: Condition) Instruction {
    return .{
        .swap = .{
            .cond = cond,
            .byte = (raw & 0x00400000) != 0,
            .rn = @truncate((raw >> 16) & 0xF),
            .rd = @truncate((raw >> 12) & 0xF),
            .rm = @truncate(raw & 0xF),
        },
    };
}

fn decodeHalfwordTransfer(raw: u32, cond: Condition) Instruction {
    const is_immediate = (raw & 0x00400000) != 0;
    const sh = (raw >> 5) & 0x3;

    return .{
        .halfword_transfer = .{
            .cond = cond,
            .load = (raw & 0x00100000) != 0,
            .write_back = (raw & 0x00200000) != 0,
            .up = (raw & 0x00800000) != 0,
            .pre_index = (raw & 0x01000000) != 0,
            .signed = (sh & 0x2) != 0,
            .halfword = (sh & 0x1) != 0,
            .rn = @truncate((raw >> 16) & 0xF),
            .rd = @truncate((raw >> 12) & 0xF),
            .offset = if (is_immediate)
                .{ .immediate = @truncate(((raw >> 4) & 0xF0) | (raw & 0xF)) }
            else
                .{ .register = @truncate(raw & 0xF) },
        },
    };
}

fn decodeSingleTransfer(raw: u32, cond: Condition) Instruction {
    const is_register = (raw & 0x02000000) != 0;

    return .{
        .single_transfer = .{
            .cond = cond,
            .load = (raw & 0x00100000) != 0,
            .write_back = (raw & 0x00200000) != 0,
            .byte = (raw & 0x00400000) != 0,
            .up = (raw & 0x00800000) != 0,
            .pre_index = (raw & 0x01000000) != 0,
            .rn = @truncate((raw >> 16) & 0xF),
            .rd = @truncate((raw >> 12) & 0xF),
            .offset = if (is_register)
                .{ .register = .{
                    .rm = @truncate(raw & 0xF),
                    .shift_type = @enumFromInt((raw >> 5) & 0x3),
                    .shift_amount = @truncate((raw >> 7) & 0x1F),
                } }
            else
                .{ .immediate = @truncate(raw & 0xFFF) },
        },
    };
}

fn decodeBlockTransfer(raw: u32, cond: Condition) Instruction {
    return .{
        .block_transfer = .{
            .cond = cond,
            .load = (raw & 0x00100000) != 0,
            .write_back = (raw & 0x00200000) != 0,
            .psr_force_user = (raw & 0x00400000) != 0,
            .up = (raw & 0x00800000) != 0,
            .pre_index = (raw & 0x01000000) != 0,
            .rn = @truncate((raw >> 16) & 0xF),
            .register_list = @truncate(raw & 0xFFFF),
        },
    };
}

fn decodeBranch(raw: u32, cond: Condition) Instruction {
    // Sign-extend the 24-bit offset
    const offset_raw: u24 = @truncate(raw & 0x00FFFFFF);
    const offset: i24 = @bitCast(offset_raw);

    return .{
        .branch = .{
            .cond = cond,
            .link = (raw & 0x01000000) != 0,
            .offset = offset,
        },
    };
}

fn decodeCoprocessorTransfer(raw: u32, cond: Condition) Instruction {
    return .{
        .coprocessor_transfer = .{
            .cond = cond,
            .load = (raw & 0x00100000) != 0,
            .write_back = (raw & 0x00200000) != 0,
            .transfer_length = (raw & 0x00400000) != 0,
            .up = (raw & 0x00800000) != 0,
            .pre_index = (raw & 0x01000000) != 0,
            .coproc = @truncate((raw >> 8) & 0xF),
            .crd = @truncate((raw >> 12) & 0xF),
            .rn = @truncate((raw >> 16) & 0xF),
            .offset = @truncate(raw & 0xFF),
        },
    };
}

fn decodeCoprocessorOrSwi(raw: u32, cond: Condition) Instruction {
    // Bit 24 distinguishes SWI from coprocessor
    if ((raw & 0x01000000) != 0) {
        return .{
            .software_interrupt = .{
                .cond = cond,
                .comment = @truncate(raw & 0x00FFFFFF),
            },
        };
    }

    // Coprocessor register transfer vs data operation
    if ((raw & 0x00000010) != 0) {
        return .{
            .coprocessor_register = .{
                .cond = cond,
                .to_arm = (raw & 0x00100000) != 0,
                .opcode1 = @truncate((raw >> 21) & 0x7),
                .crn = @truncate((raw >> 16) & 0xF),
                .rd = @truncate((raw >> 12) & 0xF),
                .coproc = @truncate((raw >> 8) & 0xF),
                .opcode2 = @truncate((raw >> 5) & 0x7),
                .crm = @truncate(raw & 0xF),
            },
        };
    } else {
        return .{
            .coprocessor_data = .{
                .cond = cond,
                .opcode1 = @truncate((raw >> 20) & 0xF),
                .crn = @truncate((raw >> 16) & 0xF),
                .crd = @truncate((raw >> 12) & 0xF),
                .coproc = @truncate((raw >> 8) & 0xF),
                .opcode2 = @truncate((raw >> 5) & 0x7),
                .crm = @truncate(raw & 0xF),
            },
        };
    }
}

// ============================================================
// Tests
// ============================================================

test "decode MOV R0, #0" {
    // E3A00000: MOV R0, #0
    const inst = decode(0xE3A00000);

    try std.testing.expect(inst == .data_processing);
    const dp = inst.data_processing;
    try std.testing.expectEqual(Condition.al, dp.cond);
    try std.testing.expectEqual(DpOpcode.mov, dp.opcode);
    try std.testing.expect(!dp.set_flags);
    try std.testing.expectEqual(@as(u4, 0), dp.rd);
    try std.testing.expect(dp.operand2 == .immediate);
    try std.testing.expectEqual(@as(u8, 0), dp.operand2.immediate.value);
}

test "decode ADD R1, R2, R3" {
    // E0821003: ADD R1, R2, R3
    const inst = decode(0xE0821003);

    try std.testing.expect(inst == .data_processing);
    const dp = inst.data_processing;
    try std.testing.expectEqual(DpOpcode.add, dp.opcode);
    try std.testing.expectEqual(@as(u4, 1), dp.rd);
    try std.testing.expectEqual(@as(u4, 2), dp.rn);
    try std.testing.expect(dp.operand2 == .register);
    try std.testing.expectEqual(@as(u4, 3), dp.operand2.register.rm);
}

test "decode ADDS (set flags)" {
    // E0910002: ADDS R0, R1, R2
    const inst = decode(0xE0910002);

    try std.testing.expect(inst == .data_processing);
    try std.testing.expect(inst.data_processing.set_flags);
}

test "decode CMP R0, #5" {
    // E3500005: CMP R0, #5
    const inst = decode(0xE3500005);

    try std.testing.expect(inst == .data_processing);
    const dp = inst.data_processing;
    try std.testing.expectEqual(DpOpcode.cmp, dp.opcode);
    try std.testing.expect(dp.set_flags);
    try std.testing.expectEqual(@as(u4, 0), dp.rn);
}

test "decode LDR R0, [R1]" {
    // E5910000: LDR R0, [R1]
    const inst = decode(0xE5910000);

    try std.testing.expect(inst == .single_transfer);
    const st = inst.single_transfer;
    try std.testing.expect(st.load);
    try std.testing.expect(st.pre_index);
    try std.testing.expectEqual(@as(u4, 0), st.rd);
    try std.testing.expectEqual(@as(u4, 1), st.rn);
}

test "decode STR R0, [R1, #4]!" {
    // E5A10004: STR R0, [R1, #4]!
    const inst = decode(0xE5A10004);

    try std.testing.expect(inst == .single_transfer);
    const st = inst.single_transfer;
    try std.testing.expect(!st.load);
    try std.testing.expect(st.write_back);
    try std.testing.expect(st.pre_index);
    try std.testing.expect(st.offset == .immediate);
    try std.testing.expectEqual(@as(u12, 4), st.offset.immediate);
}

test "decode STMFD SP!, {R0-R3, LR}" {
    // E92D401F: STMFD SP!, {R0-R3, LR}
    const inst = decode(0xE92D401F);

    try std.testing.expect(inst == .block_transfer);
    const bt = inst.block_transfer;
    try std.testing.expect(!bt.load);
    try std.testing.expect(bt.write_back);
    try std.testing.expect(!bt.up);
    try std.testing.expect(bt.pre_index);
    try std.testing.expectEqual(@as(u4, 13), bt.rn); // SP
    try std.testing.expectEqual(@as(u16, 0x401F), bt.register_list);
}

test "decode B label" {
    // EA000010: B PC+0x44
    const inst = decode(0xEA000010);

    try std.testing.expect(inst == .branch);
    const br = inst.branch;
    try std.testing.expect(!br.link);
    try std.testing.expectEqual(@as(i24, 0x10), br.offset);
}

test "decode BL label" {
    // EB000010: BL PC+0x44
    const inst = decode(0xEB000010);

    try std.testing.expect(inst == .branch);
    try std.testing.expect(inst.branch.link);
}

test "decode BX R0" {
    // E12FFF10: BX R0
    const inst = decode(0xE12FFF10);

    try std.testing.expect(inst == .branch_exchange);
    try std.testing.expectEqual(@as(u4, 0), inst.branch_exchange.rn);
}

test "decode SWI" {
    // EF000000: SWI 0
    const inst = decode(0xEF000000);

    try std.testing.expect(inst == .software_interrupt);
    try std.testing.expectEqual(@as(u24, 0), inst.software_interrupt.comment);
}

test "decode MUL" {
    // E0010392: MUL R1, R2, R3
    const inst = decode(0xE0010392);

    try std.testing.expect(inst == .multiply);
    const mul = inst.multiply;
    try std.testing.expect(!mul.accumulate);
    try std.testing.expectEqual(@as(u4, 1), mul.rd);
    try std.testing.expectEqual(@as(u4, 2), mul.rm);
    try std.testing.expectEqual(@as(u4, 3), mul.rs);
}

test "decode MLA" {
    // E0214392: MLA R1, R2, R3, R4
    const inst = decode(0xE0214392);

    try std.testing.expect(inst == .multiply);
    const mul = inst.multiply;
    try std.testing.expect(mul.accumulate);
    try std.testing.expectEqual(@as(u4, 1), mul.rd);
    try std.testing.expectEqual(@as(u4, 4), mul.rn);
}

test "decode MCR (coprocessor register)" {
    // EE010F10: MCR p15, 0, R0, c1, c0, 0
    const inst = decode(0xEE010F10);

    try std.testing.expect(inst == .coprocessor_register);
    const cp = inst.coprocessor_register;
    try std.testing.expect(!cp.to_arm); // MCR writes to coprocessor
    try std.testing.expectEqual(@as(u4, 15), cp.coproc);
    try std.testing.expectEqual(@as(u4, 0), cp.rd);
    try std.testing.expectEqual(@as(u4, 1), cp.crn);
}

test "condition evaluation" {
    // Test EQ condition (Z set)
    try std.testing.expect(Condition.eq.evaluate(false, true, false, false));
    try std.testing.expect(!Condition.eq.evaluate(false, false, false, false));

    // Test NE condition (Z clear)
    try std.testing.expect(Condition.ne.evaluate(false, false, false, false));
    try std.testing.expect(!Condition.ne.evaluate(false, true, false, false));

    // Test AL (always)
    try std.testing.expect(Condition.al.evaluate(false, false, false, false));
    try std.testing.expect(Condition.al.evaluate(true, true, true, true));

    // Test GE (N == V)
    try std.testing.expect(Condition.ge.evaluate(true, false, false, true));
    try std.testing.expect(Condition.ge.evaluate(false, false, false, false));
    try std.testing.expect(!Condition.ge.evaluate(true, false, false, false));
}
