//! Audio Test Firmware Generator
//!
//! Generates ARM firmware that tests the I2S audio output by writing
//! a sine wave pattern to the I2S FIFO.
//!
//! Usage:
//! 1. Generate firmware: gen-audio-test
//! 2. Run: zigpod-emulator --load-iram firmware/audio_test.bin disk.img

const std = @import("std");

// Memory addresses
const IRAM_BASE: u32 = 0x40000000;
const RESULT_BASE: u32 = 0x40000100;

// I2S registers (base 0x70002800)
const I2S_BASE: u32 = 0x70002800;
const I2S_CONFIG: u32 = I2S_BASE + 0x00;
const I2S_FIFO_CFG: u32 = I2S_BASE + 0x04;
const I2S_CLOCK: u32 = I2S_BASE + 0x08;
const I2S_FIFO_WR: u32 = I2S_BASE + 0x40;

// I2S config bits
const CFG_ENABLE: u32 = 0x01;
const CFG_TX_ENABLE: u32 = 0x02;
const CFG_TX_FIFO_ENABLE: u32 = 0x08;
const CFG_ALL_ENABLE: u32 = CFG_ENABLE | CFG_TX_ENABLE | CFG_TX_FIFO_ENABLE;

// I2C registers (base 0x7000C000) - for WM8758 codec
const I2C_BASE: u32 = 0x7000C000;
const I2C_CTRL: u32 = I2C_BASE + 0x00;
const I2C_ADDR: u32 = I2C_BASE + 0x04;
const I2C_DATA0: u32 = I2C_BASE + 0x0C;
const I2C_STATUS: u32 = I2C_BASE + 0x1C;

// WM8758 codec address
const WM8758_ADDR: u8 = 0x1A;

// Sine wave lookup table (8 samples per cycle, scaled to 16-bit signed)
// Values: 0, 0.707, 1, 0.707, 0, -0.707, -1, -0.707
const SINE_TABLE = [8]i16{
    0,
    23170, // 0.707 * 32767
    32767, // 1.0 * 32767
    23170,
    0,
    -23170,
    -32767,
    -23170,
};

// ARM instruction helpers

/// LDR Rd, [PC, #offset]
fn ldrPcRel(rd: u4, offset: u12) u32 {
    return 0xE59F0000 | (@as(u32, rd) << 12) | offset;
}

/// LDR Rd, [Rn]
fn ldr(rd: u4, rn: u4) u32 {
    return 0xE5900000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12);
}

/// LDR Rd, [Rn, #imm]
fn ldrImm(rd: u4, rn: u4, imm: u12) u32 {
    return 0xE5900000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | imm;
}

/// STR Rd, [Rn]
fn str(rd: u4, rn: u4) u32 {
    return 0xE5800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12);
}

/// STR Rd, [Rn, #imm]
fn strImm(rd: u4, rn: u4, imm: u12) u32 {
    return 0xE5800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | imm;
}

/// MOV Rd, #imm8
fn movImm(rd: u4, imm: u8) u32 {
    return 0xE3A00000 | (@as(u32, rd) << 12) | imm;
}

/// MOV Rd, #imm8, ROR #rot (rot is in units of 2 bits, so 0-15)
fn movImmRot(rd: u4, imm: u8, rot: u4) u32 {
    return 0xE3A00000 | (@as(u32, rd) << 12) | (@as(u32, rot) << 8) | imm;
}

/// ADD Rd, Rn, #imm8
fn addImm(rd: u4, rn: u4, imm: u8) u32 {
    return 0xE2800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | imm;
}

/// AND Rd, Rn, #imm8
fn andImm(rd: u4, rn: u4, imm: u8) u32 {
    return 0xE2000000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | imm;
}

/// ORR Rd, Rn, Rm, LSL #shift
fn orrLsl(rd: u4, rn: u4, rm: u4, shift: u5) u32 {
    return 0xE1800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | (@as(u32, shift) << 7) | rm;
}

/// CMP Rn, #imm8
fn cmpImm(rn: u4, imm: u8) u32 {
    return 0xE3500000 | (@as(u32, rn) << 16) | imm;
}

/// SUBS Rd, Rn, #imm8
fn subsImm(rd: u4, rn: u4, imm: u8) u32 {
    return 0xE2500000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | imm;
}

/// BNE offset (branch if not equal)
fn bne(offset: i24) u32 {
    const off: u32 = @as(u24, @bitCast(offset));
    return 0x1A000000 | off;
}

/// B offset (unconditional branch)
fn b(offset: i24) u32 {
    const off: u32 = @as(u24, @bitCast(offset));
    return 0xEA000000 | off;
}

/// NOP
fn nop() u32 {
    return 0xE1A00000;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var code = std.ArrayListUnmanaged(u32){};
    defer code.deinit(allocator);

    var literals = std.ArrayListUnmanaged(u32){};
    defer literals.deinit(allocator);

    // Track literal fixups
    const LitFixup = struct {
        instr_idx: usize,
        lit_idx: usize,
        rd: u4,
    };

    var lit_indices = std.ArrayListUnmanaged(LitFixup){};
    defer lit_indices.deinit(allocator);

    // Helper to add LDR with literal
    const addLdrLitHelper = struct {
        fn add(
            cd: *std.ArrayListUnmanaged(u32),
            li: *std.ArrayListUnmanaged(LitFixup),
            lits: *std.ArrayListUnmanaged(u32),
            alloc: std.mem.Allocator,
            rd: u4,
            value: u32,
        ) !void {
            // Check if literal already exists
            for (lits.items, 0..) |lit, idx| {
                if (lit == value) {
                    try li.append(alloc, .{ .instr_idx = cd.items.len, .lit_idx = idx, .rd = rd });
                    try cd.append(alloc, 0); // Placeholder
                    return;
                }
            }
            // Add new literal
            try li.append(alloc, .{ .instr_idx = cd.items.len, .lit_idx = lits.items.len, .rd = rd });
            try cd.append(alloc, 0); // Placeholder
            try lits.append(alloc, value);
        }
    };

    const addLdrLit = addLdrLitHelper.add;

    // =====================================================
    // Audio Test Code
    // =====================================================

    // Register allocation:
    // R4 = I2S_CONFIG register address
    // R5 = I2S_FIFO_WR register address
    // R6 = Sine table base address (will be set after literal pool)
    // R7 = Sample index (0-7)
    // R8 = Sample count for duration
    // R9 = Current sample value
    // R10 = RESULT_BASE for status

    // Load I2S register addresses
    try addLdrLit(&code, &lit_indices, &literals, allocator, 4, I2S_CONFIG);
    try addLdrLit(&code, &lit_indices, &literals, allocator, 5, I2S_FIFO_WR);
    try addLdrLit(&code, &lit_indices, &literals, allocator, 10, RESULT_BASE);

    // Store "starting" marker
    try addLdrLit(&code, &lit_indices, &literals, allocator, 0, 0xA0D10001);
    try code.append(allocator, str(0, 10));

    // Enable I2S: write CFG_ALL_ENABLE to I2S_CONFIG
    try addLdrLit(&code, &lit_indices, &literals, allocator, 0, CFG_ALL_ENABLE);
    try code.append(allocator, str(0, 4));

    // Store "I2S enabled" marker
    try addLdrLit(&code, &lit_indices, &literals, allocator, 0, 0xA0D10002);
    try code.append(allocator, strImm(0, 10, 4));

    // Initialize sample index
    try code.append(allocator, movImm(7, 0)); // R7 = 0

    // Set sample count (number of samples to play: ~1 second at 44100Hz = 44100 samples)
    // We'll do 44100 / 8 = 5512 cycles of 8 samples each
    try addLdrLit(&code, &lit_indices, &literals, allocator, 8, 44100);

    // Main audio loop - write samples to I2S FIFO
    const audio_loop = code.items.len;

    // Load sine table entry: sine_table_base + (R7 * 4)
    // First load the sine table base (will be fixed up later)
    const sine_table_load_idx = code.items.len;
    try code.append(allocator, 0); // Placeholder for LDR R6, [PC, #offset]

    // Calculate offset into table: R7 * 4
    // LSL R0, R7, #2 (R0 = R7 << 2)
    try code.append(allocator, 0xE1A00107); // MOV R0, R7, LSL #2

    // Add base: R0 = R6 + R0
    try code.append(allocator, 0xE0860000); // ADD R0, R6, R0

    // Load sample from table: R9 = [R0]
    try code.append(allocator, ldr(9, 0));

    // Create stereo sample: R0 = (R9 << 16) | (R9 & 0xFFFF)
    // This puts the same sample in both left and right channels
    // First, mask to 16 bits: R0 = R9 & 0xFFFF
    // MOV R0, R9, LSL #16; MOV R0, R0, LSR #16 (clear upper bits)
    try code.append(allocator, 0xE1A00809); // MOV R0, R9, LSL #16
    try code.append(allocator, 0xE1A00820); // MOV R0, R0, LSR #16

    // R1 = R9 << 16 (right channel in upper 16 bits)
    try code.append(allocator, 0xE1A01809); // MOV R1, R9, LSL #16

    // R0 = R0 | R1 (combine left and right)
    try code.append(allocator, 0xE1800001); // ORR R0, R0, R1

    // Write sample to I2S FIFO
    try code.append(allocator, str(0, 5));

    // Increment sample index, wrap at 8
    try code.append(allocator, addImm(7, 7, 1)); // R7 = R7 + 1
    try code.append(allocator, andImm(7, 7, 7)); // R7 = R7 & 7 (wrap 0-7)

    // Decrement sample count
    try code.append(allocator, subsImm(8, 8, 1)); // R8 = R8 - 1

    // Loop if more samples
    const loop_offset: i24 = @intCast(@as(i32, @intCast(audio_loop)) - @as(i32, @intCast(code.items.len)) - 2);
    try code.append(allocator, bne(loop_offset));

    // Audio complete - store success marker
    try addLdrLit(&code, &lit_indices, &literals, allocator, 0, 0xA0D100CE);
    try code.append(allocator, strImm(0, 10, 8));

    // Store sample count written
    try addLdrLit(&code, &lit_indices, &literals, allocator, 0, 44100);
    try code.append(allocator, strImm(0, 10, 12));

    // Infinite loop
    try code.append(allocator, b(-2));

    // Pad to align
    while (code.items.len % 4 != 0) {
        try code.append(allocator, nop());
    }

    // =====================================================
    // Literal pool (before sine table)
    // =====================================================
    const literal_pool_start = code.items.len;

    for (literals.items) |lit| {
        try code.append(allocator, lit);
    }

    // =====================================================
    // Sine table
    // =====================================================
    const sine_table_start = code.items.len;

    for (SINE_TABLE) |sample| {
        // Sign-extend i16 to i32, then cast to u32 for storage
        const sample_i32: i32 = sample;
        try code.append(allocator, @bitCast(sample_i32));
    }

    // Fix up all PC-relative loads for literals
    for (lit_indices.items) |fixup| {
        const instr_addr = fixup.instr_idx * 4;
        const pc = instr_addr + 8;
        const literal_addr = (literal_pool_start + fixup.lit_idx) * 4;
        if (literal_addr >= pc) {
            const offset: u12 = @intCast(literal_addr - pc);
            code.items[fixup.instr_idx] = ldrPcRel(fixup.rd, offset);
        }
    }

    // Fix up sine table load
    {
        const instr_addr = sine_table_load_idx * 4;
        const pc = instr_addr + 8;
        const table_addr = sine_table_start * 4;
        if (table_addr >= pc) {
            const offset: u12 = @intCast(table_addr - pc);
            code.items[sine_table_load_idx] = ldrPcRel(6, offset);
        }
    }

    // Write binary output
    std.fs.cwd().makePath("firmware") catch {};
    const file = try std.fs.cwd().createFile("firmware/audio_test.bin", .{});
    defer file.close();

    for (code.items) |word| {
        const bytes: [4]u8 = @bitCast(word);
        _ = try file.write(&bytes);
    }

    std.debug.print("Generated audio test firmware: {} bytes\n", .{code.items.len * 4});
    std.debug.print("  Code: {} instructions\n", .{literal_pool_start});
    std.debug.print("  Literals: {} words\n", .{literals.items.len});
    std.debug.print("  Sine table: {} samples\n", .{SINE_TABLE.len});

    std.debug.print("\nTest will:\n", .{});
    std.debug.print("  1. Enable I2S controller\n", .{});
    std.debug.print("  2. Write 44100 samples (~1 second of audio)\n", .{});
    std.debug.print("  3. Generate a sine wave tone\n", .{});
    std.debug.print("  4. Store markers at 0x{X:0>8}:\n", .{RESULT_BASE});
    std.debug.print("     +0: 0xA0D10001 = starting\n", .{});
    std.debug.print("     +4: 0xA0D10002 = I2S enabled\n", .{});
    std.debug.print("     +8: 0xA0D100CE = audio complete\n", .{});
    std.debug.print("\nUsage:\n", .{});
    std.debug.print("  zigpod-emulator --load-iram firmware/audio_test.bin disk.img\n", .{});
}
