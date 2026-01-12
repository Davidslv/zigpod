//! ARM (32-bit) Instruction Decoder
//!
//! Decodes ARM instructions into their component fields.
//! All ARM instructions are 32 bits and conditionally executed.
//!
//! Reference: ARM7TDMI Technical Reference Manual (ARM DDI 0029E) Section 4

const std = @import("std");

/// Condition codes for ARM instructions
pub const Condition = enum(u4) {
    eq = 0b0000, // Equal (Z=1)
    ne = 0b0001, // Not equal (Z=0)
    cs = 0b0010, // Carry set / unsigned higher or same (C=1)
    cc = 0b0011, // Carry clear / unsigned lower (C=0)
    mi = 0b0100, // Minus / negative (N=1)
    pl = 0b0101, // Plus / positive or zero (N=0)
    vs = 0b0110, // Overflow (V=1)
    vc = 0b0111, // No overflow (V=0)
    hi = 0b1000, // Unsigned higher (C=1 and Z=0)
    ls = 0b1001, // Unsigned lower or same (C=0 or Z=1)
    ge = 0b1010, // Signed greater or equal (N=V)
    lt = 0b1011, // Signed less than (N!=V)
    gt = 0b1100, // Signed greater than (Z=0 and N=V)
    le = 0b1101, // Signed less or equal (Z=1 or N!=V)
    al = 0b1110, // Always
    nv = 0b1111, // Never (reserved, or unconditional on ARMv5+)

    /// Check if condition is satisfied given NZCV flags
    pub fn check(self: Condition, n: bool, z: bool, c: bool, v: bool) bool {
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
            .nv => false, // Never execute (or ARMv5 unconditional)
        };
    }
};

/// Data processing opcodes
pub const DPOpcode = enum(u4) {
    AND = 0b0000, // Rd = Rn AND Op2
    EOR = 0b0001, // Rd = Rn XOR Op2
    SUB = 0b0010, // Rd = Rn - Op2
    RSB = 0b0011, // Rd = Op2 - Rn
    ADD = 0b0100, // Rd = Rn + Op2
    ADC = 0b0101, // Rd = Rn + Op2 + C
    SBC = 0b0110, // Rd = Rn - Op2 - !C
    RSC = 0b0111, // Rd = Op2 - Rn - !C
    TST = 0b1000, // Rn AND Op2, set flags only
    TEQ = 0b1001, // Rn XOR Op2, set flags only
    CMP = 0b1010, // Rn - Op2, set flags only
    CMN = 0b1011, // Rn + Op2, set flags only
    ORR = 0b1100, // Rd = Rn OR Op2
    MOV = 0b1101, // Rd = Op2
    BIC = 0b1110, // Rd = Rn AND NOT Op2
    MVN = 0b1111, // Rd = NOT Op2

    /// Is this a test-only operation (doesn't write result)?
    pub fn isTest(self: DPOpcode) bool {
        return switch (self) {
            .TST, .TEQ, .CMP, .CMN => true,
            else => false,
        };
    }

    /// Is this a logical operation (for carry flag from shifter)?
    pub fn isLogical(self: DPOpcode) bool {
        return switch (self) {
            .AND, .EOR, .TST, .TEQ, .ORR, .MOV, .BIC, .MVN => true,
            else => false,
        };
    }
};

/// Shift types
pub const ShiftType = enum(u2) {
    lsl = 0b00, // Logical shift left
    lsr = 0b01, // Logical shift right
    asr = 0b10, // Arithmetic shift right
    ror = 0b11, // Rotate right
};

/// Decoded instruction types
pub const InstructionType = enum {
    // Data Processing
    data_processing,

    // Multiply
    multiply,
    multiply_long,

    // Single Data Transfer (LDR/STR)
    single_transfer,

    // Halfword/Signed Transfer (LDRH/STRH/LDRSB/LDRSH)
    halfword_transfer,

    // Block Data Transfer (LDM/STM)
    block_transfer,

    // Branch
    branch,
    branch_exchange,

    // Software Interrupt
    swi,

    // Swap
    swap,

    // Coprocessor
    coprocessor_data,
    coprocessor_transfer,
    coprocessor_register,

    // Special
    mrs,
    msr,

    // Undefined
    undefined,
};

/// Decoded ARM instruction
pub const DecodedInstruction = struct {
    /// Raw 32-bit instruction
    raw: u32,

    /// Condition code
    condition: Condition,

    /// Instruction type
    type: InstructionType,

    /// Get condition code field [31:28]
    pub fn getCondition(raw: u32) Condition {
        return @enumFromInt(@as(u4, @truncate(raw >> 28)));
    }

    /// Check if condition is satisfied
    pub fn conditionMet(self: *const DecodedInstruction, n: bool, z: bool, c: bool, v: bool) bool {
        return self.condition.check(n, z, c, v);
    }
};

/// Data processing instruction fields
pub const DataProcessing = struct {
    opcode: DPOpcode,
    set_flags: bool, // S bit
    rn: u4, // First operand register
    rd: u4, // Destination register
    is_immediate: bool, // I bit

    // For immediate operand
    imm_value: u8,
    imm_rotate: u4,

    // For register operand
    rm: u4, // Second operand register
    shift_type: ShiftType,
    shift_by_register: bool, // 0=immediate, 1=register
    shift_amount: u5, // Immediate shift amount
    rs: u4, // Register containing shift amount

    pub fn decode(raw: u32) DataProcessing {
        return .{
            .opcode = @enumFromInt(@as(u4, @truncate((raw >> 21) & 0xF))),
            .set_flags = (raw & (1 << 20)) != 0,
            .rn = @truncate((raw >> 16) & 0xF),
            .rd = @truncate((raw >> 12) & 0xF),
            .is_immediate = (raw & (1 << 25)) != 0,

            .imm_value = @truncate(raw & 0xFF),
            .imm_rotate = @truncate((raw >> 8) & 0xF),

            .rm = @truncate(raw & 0xF),
            .shift_type = @enumFromInt(@as(u2, @truncate((raw >> 5) & 0x3))),
            .shift_by_register = (raw & (1 << 4)) != 0,
            .shift_amount = @truncate((raw >> 7) & 0x1F),
            .rs = @truncate((raw >> 8) & 0xF),
        };
    }

    /// Calculate the immediate operand (rotated)
    pub fn getImmediate(self: *const DataProcessing) struct { value: u32, carry: bool } {
        const rotate = @as(u5, self.imm_rotate) * 2;
        const value = std.math.rotr(u32, @as(u32, self.imm_value), rotate);
        // Carry out is bit 31 of result if rotate != 0
        const carry = if (rotate != 0) (value & 0x80000000) != 0 else false;
        return .{ .value = value, .carry = carry };
    }
};

/// Multiply instruction fields
pub const Multiply = struct {
    accumulate: bool, // A bit (MLA vs MUL)
    set_flags: bool, // S bit
    rd: u4, // Destination
    rn: u4, // Accumulator (for MLA)
    rs: u4, // Multiplier
    rm: u4, // Multiplicand

    pub fn decode(raw: u32) Multiply {
        return .{
            .accumulate = (raw & (1 << 21)) != 0,
            .set_flags = (raw & (1 << 20)) != 0,
            .rd = @truncate((raw >> 16) & 0xF),
            .rn = @truncate((raw >> 12) & 0xF),
            .rs = @truncate((raw >> 8) & 0xF),
            .rm = @truncate(raw & 0xF),
        };
    }
};

/// Multiply long instruction fields
pub const MultiplyLong = struct {
    is_signed: bool, // U bit (0=unsigned, 1=signed)
    accumulate: bool, // A bit
    set_flags: bool, // S bit
    rd_hi: u4, // High 32 bits of result
    rd_lo: u4, // Low 32 bits of result
    rs: u4, // Multiplier
    rm: u4, // Multiplicand

    pub fn decode(raw: u32) MultiplyLong {
        return .{
            .is_signed = (raw & (1 << 22)) != 0,
            .accumulate = (raw & (1 << 21)) != 0,
            .set_flags = (raw & (1 << 20)) != 0,
            .rd_hi = @truncate((raw >> 16) & 0xF),
            .rd_lo = @truncate((raw >> 12) & 0xF),
            .rs = @truncate((raw >> 8) & 0xF),
            .rm = @truncate(raw & 0xF),
        };
    }
};

/// Single data transfer (LDR/STR) fields
pub const SingleTransfer = struct {
    is_immediate: bool, // I bit (0=immediate offset, 1=register offset)
    pre_index: bool, // P bit
    add_offset: bool, // U bit
    byte_transfer: bool, // B bit
    write_back: bool, // W bit
    is_load: bool, // L bit
    rn: u4, // Base register
    rd: u4, // Source/destination register

    // Immediate offset
    offset: u12,

    // Register offset
    rm: u4,
    shift_type: ShiftType,
    shift_amount: u5,

    pub fn decode(raw: u32) SingleTransfer {
        return .{
            .is_immediate = (raw & (1 << 25)) == 0, // Note: inverted from encoding
            .pre_index = (raw & (1 << 24)) != 0,
            .add_offset = (raw & (1 << 23)) != 0,
            .byte_transfer = (raw & (1 << 22)) != 0,
            .write_back = (raw & (1 << 21)) != 0,
            .is_load = (raw & (1 << 20)) != 0,
            .rn = @truncate((raw >> 16) & 0xF),
            .rd = @truncate((raw >> 12) & 0xF),
            .offset = @truncate(raw & 0xFFF),
            .rm = @truncate(raw & 0xF),
            .shift_type = @enumFromInt(@as(u2, @truncate((raw >> 5) & 0x3))),
            .shift_amount = @truncate((raw >> 7) & 0x1F),
        };
    }
};

/// Halfword/signed transfer fields
pub const HalfwordTransfer = struct {
    pre_index: bool,
    add_offset: bool,
    is_immediate: bool,
    write_back: bool,
    is_load: bool,
    rn: u4,
    rd: u4,
    is_signed: bool, // S bit
    is_halfword: bool, // H bit
    offset_high: u4,
    rm: u4, // Also used as offset_low for immediate

    pub fn decode(raw: u32) HalfwordTransfer {
        return .{
            .pre_index = (raw & (1 << 24)) != 0,
            .add_offset = (raw & (1 << 23)) != 0,
            .is_immediate = (raw & (1 << 22)) != 0,
            .write_back = (raw & (1 << 21)) != 0,
            .is_load = (raw & (1 << 20)) != 0,
            .rn = @truncate((raw >> 16) & 0xF),
            .rd = @truncate((raw >> 12) & 0xF),
            .is_signed = (raw & (1 << 6)) != 0,
            .is_halfword = (raw & (1 << 5)) != 0,
            .offset_high = @truncate((raw >> 8) & 0xF),
            .rm = @truncate(raw & 0xF),
        };
    }

    pub fn getOffset(self: *const HalfwordTransfer) u8 {
        if (self.is_immediate) {
            return (@as(u8, self.offset_high) << 4) | self.rm;
        }
        return 0; // Register offset - caller handles rm
    }
};

/// Block data transfer (LDM/STM) fields
pub const BlockTransfer = struct {
    pre_index: bool, // P bit
    add_offset: bool, // U bit
    load_psr: bool, // S bit (load PSR or force user mode)
    write_back: bool, // W bit
    is_load: bool, // L bit
    rn: u4, // Base register
    register_list: u16, // Bit mask of registers

    pub fn decode(raw: u32) BlockTransfer {
        return .{
            .pre_index = (raw & (1 << 24)) != 0,
            .add_offset = (raw & (1 << 23)) != 0,
            .load_psr = (raw & (1 << 22)) != 0,
            .write_back = (raw & (1 << 21)) != 0,
            .is_load = (raw & (1 << 20)) != 0,
            .rn = @truncate((raw >> 16) & 0xF),
            .register_list = @truncate(raw & 0xFFFF),
        };
    }

    /// Count number of registers in list
    pub fn registerCount(self: *const BlockTransfer) u5 {
        return @popCount(self.register_list);
    }
};

/// Branch instruction fields
pub const Branch = struct {
    link: bool, // L bit (BL vs B)
    offset: i24, // Signed offset (will be multiplied by 4)

    pub fn decode(raw: u32) Branch {
        // Sign-extend the 24-bit offset
        const raw_offset: u24 = @truncate(raw & 0xFFFFFF);

        return .{
            .link = (raw & (1 << 24)) != 0,
            .offset = @as(i24, @bitCast(raw_offset)),
        };
    }

    /// Calculate target address (PC + 8 + offset*4)
    pub fn getTargetOffset(self: *const Branch) i32 {
        return @as(i32, self.offset) * 4;
    }
};

/// Branch and Exchange (BX) fields
pub const BranchExchange = struct {
    rm: u4, // Register containing target address

    pub fn decode(raw: u32) BranchExchange {
        return .{
            .rm = @truncate(raw & 0xF),
        };
    }
};

/// SWI instruction fields
pub const SoftwareInterrupt = struct {
    comment: u24, // Comment field (ignored by processor)

    pub fn decode(raw: u32) SoftwareInterrupt {
        return .{
            .comment = @truncate(raw & 0xFFFFFF),
        };
    }
};

/// Swap instruction fields
pub const Swap = struct {
    byte_swap: bool, // B bit
    rn: u4, // Base register (memory address)
    rd: u4, // Destination register
    rm: u4, // Source register

    pub fn decode(raw: u32) Swap {
        return .{
            .byte_swap = (raw & (1 << 22)) != 0,
            .rn = @truncate((raw >> 16) & 0xF),
            .rd = @truncate((raw >> 12) & 0xF),
            .rm = @truncate(raw & 0xF),
        };
    }
};

/// MRS instruction fields
pub const Mrs = struct {
    use_spsr: bool, // R bit (0=CPSR, 1=SPSR)
    rd: u4, // Destination register

    pub fn decode(raw: u32) Mrs {
        return .{
            .use_spsr = (raw & (1 << 22)) != 0,
            .rd = @truncate((raw >> 12) & 0xF),
        };
    }
};

/// MSR instruction fields
pub const Msr = struct {
    use_spsr: bool, // R bit
    is_immediate: bool, // I bit
    field_mask: u4, // Field mask (c, x, s, f)

    // Immediate operand
    imm_value: u8,
    imm_rotate: u4,

    // Register operand
    rm: u4,

    pub fn decode(raw: u32) Msr {
        return .{
            .use_spsr = (raw & (1 << 22)) != 0,
            .is_immediate = (raw & (1 << 25)) != 0,
            .field_mask = @truncate((raw >> 16) & 0xF),
            .imm_value = @truncate(raw & 0xFF),
            .imm_rotate = @truncate((raw >> 8) & 0xF),
            .rm = @truncate(raw & 0xF),
        };
    }
};

/// Decode a 32-bit ARM instruction
pub fn decode(raw: u32) DecodedInstruction {
    const condition = DecodedInstruction.getCondition(raw);

    // Decode instruction type based on bit patterns
    const inst_type = decodeType(raw);

    return .{
        .raw = raw,
        .condition = condition,
        .type = inst_type,
    };
}

/// Determine instruction type from bit pattern
fn decodeType(raw: u32) InstructionType {
    // Extract key bits for classification
    const bits27_25 = (raw >> 25) & 0x7;
    const bits7_4 = (raw >> 4) & 0xF;
    const bit4 = (raw >> 4) & 0x1;

    // Software Interrupt: 1111 xxxx xxxx xxxx xxxx xxxx xxxx xxxx
    if ((raw >> 24) & 0xF == 0xF) {
        return .swi;
    }

    // Branch: 101x xxxx xxxx xxxx xxxx xxxx xxxx xxxx
    if (bits27_25 == 0b101) {
        return .branch;
    }

    // Block Data Transfer: 100x xxxx xxxx xxxx xxxx xxxx xxxx xxxx
    if (bits27_25 == 0b100) {
        return .block_transfer;
    }

    // Single Data Transfer: 01xx xxxx xxxx xxxx xxxx xxxx xxxx xxxx
    if ((bits27_25 & 0b110) == 0b010) {
        return .single_transfer;
    }

    // Coprocessor instructions: 110x or 1110
    if (bits27_25 == 0b110) {
        return .coprocessor_transfer;
    }
    if (bits27_25 == 0b111 and bit4 == 0) {
        return .coprocessor_data;
    }
    if (bits27_25 == 0b111 and bit4 == 1) {
        return .coprocessor_register;
    }

    // Now check data processing / multiply / other patterns
    if (bits27_25 == 0b000) {
        // Multiply patterns
        if (bits7_4 == 0b1001) {
            // Check for multiply long vs regular multiply
            if ((raw >> 23) & 0x1 == 1) {
                return .multiply_long;
            } else {
                return .multiply;
            }
        }

        // Swap: xxxx 0001 0x00 xxxx xxxx 0000 1001 xxxx
        if ((raw & 0x0FB00FF0) == 0x01000090) {
            return .swap;
        }

        // Branch Exchange: xxxx 0001 0010 1111 1111 1111 0001 xxxx
        if ((raw & 0x0FFFFFF0) == 0x012FFF10) {
            return .branch_exchange;
        }

        // Halfword transfer: xxxx 000x xxxx xxxx xxxx xxxx 1xx1 xxxx
        if ((bits7_4 & 0x9) == 0x9 and bits7_4 != 0x9) {
            return .halfword_transfer;
        }

        // MRS: xxxx 0001 0x00 1111 xxxx 0000 0000 0000
        if ((raw & 0x0FBF0FFF) == 0x010F0000) {
            return .mrs;
        }

        // MSR: xxxx 0001 0x10 xxxx 1111 xxxx xxxx xxxx (register)
        //      xxxx 0011 0x10 xxxx 1111 xxxx xxxx xxxx (immediate)
        if ((raw & 0x0FB0F000) == 0x0120F000 or (raw & 0x0FB0F000) == 0x0320F000) {
            return .msr;
        }

        // Otherwise data processing
        return .data_processing;
    }

    // Data processing with immediate: 001x xxxx xxxx xxxx xxxx xxxx xxxx xxxx
    if (bits27_25 == 0b001) {
        // Check for MSR immediate
        if ((raw & 0x0FB0F000) == 0x0320F000) {
            return .msr;
        }
        return .data_processing;
    }

    return .undefined;
}

// Tests
test "condition check" {
    // EQ: Z=1
    try std.testing.expect(Condition.eq.check(false, true, false, false));
    try std.testing.expect(!Condition.eq.check(false, false, false, false));

    // NE: Z=0
    try std.testing.expect(Condition.ne.check(false, false, false, false));
    try std.testing.expect(!Condition.ne.check(false, true, false, false));

    // CS: C=1
    try std.testing.expect(Condition.cs.check(false, false, true, false));

    // GE: N=V
    try std.testing.expect(Condition.ge.check(true, false, false, true));
    try std.testing.expect(Condition.ge.check(false, false, false, false));
    try std.testing.expect(!Condition.ge.check(true, false, false, false));

    // AL: always
    try std.testing.expect(Condition.al.check(false, false, false, false));
}

test "data processing decode" {
    // MOV R0, #0x12
    const mov_instr: u32 = 0xE3A00012;
    const decoded = decode(mov_instr);
    try std.testing.expectEqual(InstructionType.data_processing, decoded.type);
    try std.testing.expectEqual(Condition.al, decoded.condition);

    const dp = DataProcessing.decode(mov_instr);
    try std.testing.expectEqual(DPOpcode.MOV, dp.opcode);
    try std.testing.expectEqual(@as(u4, 0), dp.rd);
    try std.testing.expect(dp.is_immediate);
    try std.testing.expectEqual(@as(u8, 0x12), dp.imm_value);
}

test "branch decode" {
    // B +0x100
    const branch_instr: u32 = 0xEA000040;
    const decoded = decode(branch_instr);
    try std.testing.expectEqual(InstructionType.branch, decoded.type);

    const br = Branch.decode(branch_instr);
    try std.testing.expect(!br.link);
}

test "ldr decode" {
    // LDR R0, [R1]
    const ldr_instr: u32 = 0xE5910000;
    const decoded = decode(ldr_instr);
    try std.testing.expectEqual(InstructionType.single_transfer, decoded.type);

    const st = SingleTransfer.decode(ldr_instr);
    try std.testing.expect(st.is_load);
    try std.testing.expectEqual(@as(u4, 0), st.rd);
    try std.testing.expectEqual(@as(u4, 1), st.rn);
}
