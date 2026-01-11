//! Thumb (16-bit) Instruction Decoder
//!
//! Decodes Thumb instructions (16-bit compressed ARM subset).
//! All Thumb instructions are unconditionally executed except branches.
//!
//! Reference: ARM7TDMI Technical Reference Manual (ARM DDI 0029E) Section 6

const std = @import("std");

/// Thumb instruction formats
pub const InstructionFormat = enum {
    // Format 1: Move shifted register
    move_shifted_register,

    // Format 2: Add/subtract
    add_subtract,

    // Format 3: Move/compare/add/subtract immediate
    mov_cmp_add_sub_imm,

    // Format 4: ALU operations
    alu_operations,

    // Format 5: Hi register operations / BX
    hi_register_bx,

    // Format 6: PC-relative load
    pc_relative_load,

    // Format 7: Load/store with register offset
    load_store_register,

    // Format 8: Load/store sign-extended byte/halfword
    load_store_sign_extended,

    // Format 9: Load/store with immediate offset
    load_store_immediate,

    // Format 10: Load/store halfword
    load_store_halfword,

    // Format 11: SP-relative load/store
    sp_relative_load_store,

    // Format 12: Load address
    load_address,

    // Format 13: Add offset to SP
    add_offset_sp,

    // Format 14: Push/pop registers
    push_pop,

    // Format 15: Multiple load/store
    multiple_load_store,

    // Format 16: Conditional branch
    conditional_branch,

    // Format 17: Software interrupt
    software_interrupt,

    // Format 18: Unconditional branch
    unconditional_branch,

    // Format 19: Long branch with link
    long_branch_link,

    // Undefined
    undefined,
};

/// ALU operation codes for Format 4
pub const AluOp = enum(u4) {
    AND = 0b0000,
    EOR = 0b0001,
    LSL = 0b0010,
    LSR = 0b0011,
    ASR = 0b0100,
    ADC = 0b0101,
    SBC = 0b0110,
    ROR = 0b0111,
    TST = 0b1000,
    NEG = 0b1001,
    CMP = 0b1010,
    CMN = 0b1011,
    ORR = 0b1100,
    MUL = 0b1101,
    BIC = 0b1110,
    MVN = 0b1111,
};

/// Condition codes for conditional branch
pub const Condition = enum(u4) {
    eq = 0b0000,
    ne = 0b0001,
    cs = 0b0010,
    cc = 0b0011,
    mi = 0b0100,
    pl = 0b0101,
    vs = 0b0110,
    vc = 0b0111,
    hi = 0b1000,
    ls = 0b1001,
    ge = 0b1010,
    lt = 0b1011,
    gt = 0b1100,
    le = 0b1101,

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
        };
    }
};

/// Format 1: Move shifted register
pub const MoveShiftedRegister = struct {
    op: u2, // 00=LSL, 01=LSR, 10=ASR
    offset: u5,
    rs: u3,
    rd: u3,

    pub fn decode(instruction: u16) MoveShiftedRegister {
        return .{
            .op = @truncate((instruction >> 11) & 0x3),
            .offset = @truncate((instruction >> 6) & 0x1F),
            .rs = @truncate((instruction >> 3) & 0x7),
            .rd = @truncate(instruction & 0x7),
        };
    }
};

/// Format 2: Add/subtract
pub const AddSubtract = struct {
    is_immediate: bool, // I bit
    is_subtract: bool, // Op bit
    rn_or_imm: u3, // Rn or 3-bit immediate
    rs: u3,
    rd: u3,

    pub fn decode(instruction: u16) AddSubtract {
        return .{
            .is_immediate = (instruction & (1 << 10)) != 0,
            .is_subtract = (instruction & (1 << 9)) != 0,
            .rn_or_imm = @truncate((instruction >> 6) & 0x7),
            .rs = @truncate((instruction >> 3) & 0x7),
            .rd = @truncate(instruction & 0x7),
        };
    }
};

/// Format 3: Move/compare/add/subtract immediate
pub const MovCmpAddSubImm = struct {
    op: u2, // 00=MOV, 01=CMP, 10=ADD, 11=SUB
    rd: u3,
    offset: u8,

    pub fn decode(instruction: u16) MovCmpAddSubImm {
        return .{
            .op = @truncate((instruction >> 11) & 0x3),
            .rd = @truncate((instruction >> 8) & 0x7),
            .offset = @truncate(instruction & 0xFF),
        };
    }
};

/// Format 4: ALU operations
pub const AluOperations = struct {
    op: AluOp,
    rs: u3,
    rd: u3,

    pub fn decode(instruction: u16) AluOperations {
        return .{
            .op = @enumFromInt(@as(u4, @truncate((instruction >> 6) & 0xF))),
            .rs = @truncate((instruction >> 3) & 0x7),
            .rd = @truncate(instruction & 0x7),
        };
    }
};

/// Format 5: Hi register operations / BX
pub const HiRegisterBx = struct {
    op: u2, // 00=ADD, 01=CMP, 10=MOV, 11=BX
    h1: bool, // High bit for Rd
    h2: bool, // High bit for Rs
    rs: u3,
    rd: u3,

    pub fn decode(instruction: u16) HiRegisterBx {
        return .{
            .op = @truncate((instruction >> 8) & 0x3),
            .h1 = (instruction & (1 << 7)) != 0,
            .h2 = (instruction & (1 << 6)) != 0,
            .rs = @truncate((instruction >> 3) & 0x7),
            .rd = @truncate(instruction & 0x7),
        };
    }

    pub fn getFullRd(self: *const HiRegisterBx) u4 {
        return (@as(u4, @intFromBool(self.h1)) << 3) | self.rd;
    }

    pub fn getFullRs(self: *const HiRegisterBx) u4 {
        return (@as(u4, @intFromBool(self.h2)) << 3) | self.rs;
    }
};

/// Format 6: PC-relative load
pub const PcRelativeLoad = struct {
    rd: u3,
    word_offset: u8, // Multiplied by 4

    pub fn decode(instruction: u16) PcRelativeLoad {
        return .{
            .rd = @truncate((instruction >> 8) & 0x7),
            .word_offset = @truncate(instruction & 0xFF),
        };
    }

    pub fn getOffset(self: *const PcRelativeLoad) u32 {
        return @as(u32, self.word_offset) * 4;
    }
};

/// Format 7: Load/store with register offset
pub const LoadStoreRegister = struct {
    is_load: bool, // L bit
    is_byte: bool, // B bit
    ro: u3, // Offset register
    rb: u3, // Base register
    rd: u3,

    pub fn decode(instruction: u16) LoadStoreRegister {
        return .{
            .is_load = (instruction & (1 << 11)) != 0,
            .is_byte = (instruction & (1 << 10)) != 0,
            .ro = @truncate((instruction >> 6) & 0x7),
            .rb = @truncate((instruction >> 3) & 0x7),
            .rd = @truncate(instruction & 0x7),
        };
    }
};

/// Format 8: Load/store sign-extended byte/halfword
pub const LoadStoreSignExtended = struct {
    h_flag: bool, // H bit
    sign_extend: bool, // S bit
    ro: u3,
    rb: u3,
    rd: u3,

    pub fn decode(instruction: u16) LoadStoreSignExtended {
        return .{
            .h_flag = (instruction & (1 << 11)) != 0,
            .sign_extend = (instruction & (1 << 10)) != 0,
            .ro = @truncate((instruction >> 6) & 0x7),
            .rb = @truncate((instruction >> 3) & 0x7),
            .rd = @truncate(instruction & 0x7),
        };
    }

    /// Returns operation type: 0=STRH, 1=LDSB, 2=LDRH, 3=LDSH
    pub fn getOperation(self: *const LoadStoreSignExtended) u2 {
        return (@as(u2, @intFromBool(self.h_flag)) << 1) | @intFromBool(self.sign_extend);
    }
};

/// Format 9: Load/store with immediate offset
pub const LoadStoreImmediate = struct {
    is_byte: bool, // B bit
    is_load: bool, // L bit
    offset: u5, // Word offset for word, byte offset for byte
    rb: u3,
    rd: u3,

    pub fn decode(instruction: u16) LoadStoreImmediate {
        return .{
            .is_byte = (instruction & (1 << 12)) != 0,
            .is_load = (instruction & (1 << 11)) != 0,
            .offset = @truncate((instruction >> 6) & 0x1F),
            .rb = @truncate((instruction >> 3) & 0x7),
            .rd = @truncate(instruction & 0x7),
        };
    }

    pub fn getByteOffset(self: *const LoadStoreImmediate) u32 {
        if (self.is_byte) {
            return self.offset;
        } else {
            return @as(u32, self.offset) * 4;
        }
    }
};

/// Format 10: Load/store halfword
pub const LoadStoreHalfword = struct {
    is_load: bool, // L bit
    offset: u5, // Halfword offset (multiplied by 2)
    rb: u3,
    rd: u3,

    pub fn decode(instruction: u16) LoadStoreHalfword {
        return .{
            .is_load = (instruction & (1 << 11)) != 0,
            .offset = @truncate((instruction >> 6) & 0x1F),
            .rb = @truncate((instruction >> 3) & 0x7),
            .rd = @truncate(instruction & 0x7),
        };
    }

    pub fn getByteOffset(self: *const LoadStoreHalfword) u32 {
        return @as(u32, self.offset) * 2;
    }
};

/// Format 11: SP-relative load/store
pub const SpRelativeLoadStore = struct {
    is_load: bool, // L bit
    rd: u3,
    word_offset: u8,

    pub fn decode(instruction: u16) SpRelativeLoadStore {
        return .{
            .is_load = (instruction & (1 << 11)) != 0,
            .rd = @truncate((instruction >> 8) & 0x7),
            .word_offset = @truncate(instruction & 0xFF),
        };
    }

    pub fn getByteOffset(self: *const SpRelativeLoadStore) u32 {
        return @as(u32, self.word_offset) * 4;
    }
};

/// Format 12: Load address (ADD Rd, PC/SP, #imm)
pub const LoadAddress = struct {
    is_sp: bool, // SP bit (0=PC, 1=SP)
    rd: u3,
    word_offset: u8,

    pub fn decode(instruction: u16) LoadAddress {
        return .{
            .is_sp = (instruction & (1 << 11)) != 0,
            .rd = @truncate((instruction >> 8) & 0x7),
            .word_offset = @truncate(instruction & 0xFF),
        };
    }

    pub fn getByteOffset(self: *const LoadAddress) u32 {
        return @as(u32, self.word_offset) * 4;
    }
};

/// Format 13: Add offset to stack pointer
pub const AddOffsetSp = struct {
    is_negative: bool, // S bit
    word_offset: u7,

    pub fn decode(instruction: u16) AddOffsetSp {
        return .{
            .is_negative = (instruction & (1 << 7)) != 0,
            .word_offset = @truncate(instruction & 0x7F),
        };
    }

    pub fn getByteOffset(self: *const AddOffsetSp) i32 {
        const offset: i32 = @as(i32, self.word_offset) * 4;
        return if (self.is_negative) -offset else offset;
    }
};

/// Format 14: Push/pop registers
pub const PushPop = struct {
    is_load: bool, // L bit (0=PUSH/STMDB, 1=POP/LDMIA)
    store_lr: bool, // R bit (store LR for PUSH, load PC for POP)
    register_list: u8,

    pub fn decode(instruction: u16) PushPop {
        return .{
            .is_load = (instruction & (1 << 11)) != 0,
            .store_lr = (instruction & (1 << 8)) != 0,
            .register_list = @truncate(instruction & 0xFF),
        };
    }
};

/// Format 15: Multiple load/store
pub const MultipleLoadStore = struct {
    is_load: bool, // L bit
    rb: u3,
    register_list: u8,

    pub fn decode(instruction: u16) MultipleLoadStore {
        return .{
            .is_load = (instruction & (1 << 11)) != 0,
            .rb = @truncate((instruction >> 8) & 0x7),
            .register_list = @truncate(instruction & 0xFF),
        };
    }
};

/// Format 16: Conditional branch
pub const ConditionalBranch = struct {
    condition: Condition,
    offset: i8,

    pub fn decode(instruction: u16) ConditionalBranch {
        return .{
            .condition = @enumFromInt(@as(u4, @truncate((instruction >> 8) & 0xF))),
            .offset = @bitCast(@as(u8, @truncate(instruction & 0xFF))),
        };
    }

    pub fn getByteOffset(self: *const ConditionalBranch) i32 {
        return @as(i32, self.offset) * 2;
    }
};

/// Format 17: Software interrupt
pub const SoftwareInterrupt = struct {
    value: u8,

    pub fn decode(instruction: u16) SoftwareInterrupt {
        return .{
            .value = @truncate(instruction & 0xFF),
        };
    }
};

/// Format 18: Unconditional branch
pub const UnconditionalBranch = struct {
    offset: i11,

    pub fn decode(instruction: u16) UnconditionalBranch {
        const raw: u11 = @truncate(instruction & 0x7FF);
        return .{
            .offset = @bitCast(raw),
        };
    }

    pub fn getByteOffset(self: *const UnconditionalBranch) i32 {
        return @as(i32, self.offset) * 2;
    }
};

/// Format 19: Long branch with link
pub const LongBranchLink = struct {
    is_low: bool, // H bit (0=high offset, 1=low offset + branch)
    offset: u11,

    pub fn decode(instruction: u16) LongBranchLink {
        return .{
            .is_low = (instruction & (1 << 11)) != 0,
            .offset = @truncate(instruction & 0x7FF),
        };
    }
};

/// Determine instruction format from 16-bit instruction
pub fn decodeFormat(instruction: u16) InstructionFormat {
    // Check high bits to determine format
    const high5 = (instruction >> 11) & 0x1F;
    const high6 = (instruction >> 10) & 0x3F;
    const high8 = (instruction >> 8) & 0xFF;

    // Format 1: Move shifted register [000xx]
    if ((high5 & 0x1C) == 0x00 and (high5 & 0x03) != 0x03) {
        return .move_shifted_register;
    }

    // Format 2: Add/subtract [00011x]
    if ((high6 & 0x3E) == 0x06) {
        return .add_subtract;
    }

    // Format 3: Move/compare/add/subtract immediate [001xx]
    if ((high5 & 0x1C) == 0x04) {
        return .mov_cmp_add_sub_imm;
    }

    // Format 4: ALU operations [010000]
    if (high6 == 0x10) {
        return .alu_operations;
    }

    // Format 5: Hi register operations / BX [010001]
    if (high6 == 0x11) {
        return .hi_register_bx;
    }

    // Format 6: PC-relative load [01001]
    if (high5 == 0x09) {
        return .pc_relative_load;
    }

    // Format 7 & 8: Load/store with register offset [0101xx]
    if ((high6 & 0x3C) == 0x14) {
        if ((instruction & (1 << 9)) != 0) {
            return .load_store_sign_extended;
        } else {
            return .load_store_register;
        }
    }

    // Format 9: Load/store with immediate offset [011xx]
    if ((high5 & 0x1C) == 0x0C) {
        return .load_store_immediate;
    }

    // Format 10: Load/store halfword [1000x]
    if ((high5 & 0x1E) == 0x10) {
        return .load_store_halfword;
    }

    // Format 11: SP-relative load/store [1001x]
    if ((high5 & 0x1E) == 0x12) {
        return .sp_relative_load_store;
    }

    // Format 12: Load address [1010x]
    if ((high5 & 0x1E) == 0x14) {
        return .load_address;
    }

    // Format 13: Add offset to SP [10110000]
    if (high8 == 0xB0) {
        return .add_offset_sp;
    }

    // Format 14: Push/pop [1011x10x]
    if ((high8 & 0xF6) == 0xB4) {
        return .push_pop;
    }

    // Format 15: Multiple load/store [1100x]
    if ((high5 & 0x1E) == 0x18) {
        return .multiple_load_store;
    }

    // Format 16: Conditional branch [1101xxxx] (not 1101 1111)
    if ((high8 & 0xF0) == 0xD0 and (high8 & 0x0F) != 0x0F) {
        return .conditional_branch;
    }

    // Format 17: Software interrupt [11011111]
    if (high8 == 0xDF) {
        return .software_interrupt;
    }

    // Format 18: Unconditional branch [11100]
    if (high5 == 0x1C) {
        return .unconditional_branch;
    }

    // Format 19: Long branch with link [1111x]
    if ((high5 & 0x1E) == 0x1E) {
        return .long_branch_link;
    }

    return .undefined;
}

// Tests
test "format detection" {
    // LSL Rd, Rs, #offset (Format 1)
    try std.testing.expectEqual(InstructionFormat.move_shifted_register, decodeFormat(0x0000));

    // ADD Rd, Rs, Rn (Format 2)
    try std.testing.expectEqual(InstructionFormat.add_subtract, decodeFormat(0x1800));

    // MOV Rd, #imm (Format 3)
    try std.testing.expectEqual(InstructionFormat.mov_cmp_add_sub_imm, decodeFormat(0x2000));

    // AND Rd, Rs (Format 4)
    try std.testing.expectEqual(InstructionFormat.alu_operations, decodeFormat(0x4000));

    // BX Rs (Format 5)
    try std.testing.expectEqual(InstructionFormat.hi_register_bx, decodeFormat(0x4700));

    // LDR Rd, [PC, #imm] (Format 6)
    try std.testing.expectEqual(InstructionFormat.pc_relative_load, decodeFormat(0x4800));

    // B offset (Format 18)
    try std.testing.expectEqual(InstructionFormat.unconditional_branch, decodeFormat(0xE000));

    // BL (Format 19)
    try std.testing.expectEqual(InstructionFormat.long_branch_link, decodeFormat(0xF000));
}

test "conditional branch decode" {
    // BEQ +4
    const beq: u16 = 0xD002;
    const cb = ConditionalBranch.decode(beq);
    try std.testing.expectEqual(Condition.eq, cb.condition);
    try std.testing.expectEqual(@as(i8, 2), cb.offset);
    try std.testing.expectEqual(@as(i32, 4), cb.getByteOffset());
}
