//! Test Firmware Generator
//!
//! Generates simple ARM machine code for testing the emulator.
//! The firmware runs in IRAM at 0x40000000 and tests peripherals.

const std = @import("std");

// Memory addresses
const SYS_CTRL_BASE: u32 = 0x60006000;
const TIMER_BASE: u32 = 0x60005000;
const CACHE_CTRL_BASE: u32 = 0x6000C000;
const RESULT_BASE: u32 = 0x40000100;

// ARM instruction encoding helpers

/// LDR Rd, [PC, #offset] - PC-relative load
fn ldrPcRel(rd: u4, offset: u12) u32 {
    // LDR Rd, [PC, #offset] - E59Fnxxx
    return 0xE59F0000 | (@as(u32, rd) << 12) | offset;
}

/// LDR Rd, [Rn, #offset]
fn ldrro(rd: u4, rn: u4, offset: u12) u32 {
    // LDR Rd, [Rn, #offset] - E59noxxx
    return 0xE5900000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | offset;
}

/// STR Rd, [Rn, #offset]
fn strro(rd: u4, rn: u4, offset: u12) u32 {
    // STR Rd, [Rn, #offset] - E58noxxx
    return 0xE5800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | offset;
}

/// MOV Rd, #imm8
fn movi(rd: u4, imm: u8) u32 {
    // MOV Rd, #imm - E3A0d0ii
    return 0xE3A00000 | (@as(u32, rd) << 12) | imm;
}

/// SUBS Rd, Rn, #imm8
fn subsi(rd: u4, rn: u4, imm: u8) u32 {
    // SUBS Rd, Rn, #imm - E25nd0ii
    return 0xE2500000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | imm;
}

/// BNE offset (offset in words from PC+8)
fn bne(offset: i24) u32 {
    // BNE offset - 1Axxxxxx
    const off: u24 = @bitCast(offset);
    return 0x1A000000 | @as(u32, off);
}

/// B offset (offset in words from PC+8)
fn b(offset: i24) u32 {
    // B offset - EAxxxxxx
    const off: u24 = @bitCast(offset);
    return 0xEA000000 | @as(u32, off);
}

/// NOP (MOV R0, R0)
fn nop() u32 {
    return 0xE1A00000;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var code = std.ArrayListUnmanaged(u32){};
    defer code.deinit(allocator);

    // We'll build the code and then append literal pool at the end
    // Each PC-relative load needs to know its offset to the literal pool

    // First, build the code with placeholder offsets, then fix them
    // Code structure:
    //   0x00: LDR R0, =SYS_CTRL_BASE     (literal 0)
    //   0x04: LDR R1, [R0, #0x00]        - Read chip ID
    //   0x08: LDR R2, =RESULT_BASE       (literal 1)
    //   0x0C: STR R1, [R2, #0x00]        - Store chip ID
    //   0x10: LDR R1, [R0, #0x3C]        - Read PLL status
    //   0x14: STR R1, [R2, #0x04]        - Store PLL status
    //   0x18: LDR R0, =TIMER_BASE        (literal 2)
    //   0x1C: LDR R1, [R0, #0x10]        - Read USEC timer
    //   0x20: STR R1, [R2, #0x08]        - Store timer low
    //   0x24: MOV R3, #100               - Delay counter
    //   0x28: SUBS R3, R3, #1            - Decrement
    //   0x2C: BNE -3                     - Loop back to SUBS
    //   0x30: LDR R1, [R0, #0x10]        - Read timer again
    //   0x34: STR R1, [R2, #0x0C]        - Store timer high
    //   0x38: LDR R0, =CACHE_CTRL_BASE   (literal 3)
    //   0x3C: LDR R1, [R0, #0x00]        - Read cache status
    //   0x40: STR R1, [R2, #0x10]        - Store cache status
    //   0x44: LDR R1, =0xDEAD1234        (literal 4)
    //   0x48: STR R1, [R2, #0x14]        - Store success marker
    //   0x4C: B .                        - Infinite loop
    //   ... (pad to align)
    //   Literal pool starts at 0x50

    const code_size = 20; // 20 instructions = 0x50 bytes
    const literal_pool_start: u32 = code_size * 4; // 0x50

    // Literals in order
    const literals = [_]u32{
        SYS_CTRL_BASE,   // index 0
        RESULT_BASE,     // index 1
        TIMER_BASE,      // index 2
        CACHE_CTRL_BASE, // index 3
        0xDEAD1234,      // index 4 (success marker)
    };

    // Helper to calculate PC-relative offset
    // At instruction N, PC reads as (N*4) + 8
    // Literal L is at literal_pool_start + L*4
    // Offset = literal_addr - pc_value
    const calcOffset = struct {
        fn calc(instr_index: u32, literal_index: u32, pool_start: u32) u12 {
            const pc = (instr_index * 4) + 8;
            const literal_addr = pool_start + (literal_index * 4);
            return @intCast(literal_addr - pc);
        }
    }.calc;

    // Build code
    // 0x00: LDR R0, =SYS_CTRL_BASE
    try code.append(allocator, ldrPcRel(0, calcOffset(0, 0, literal_pool_start)));
    // 0x04: LDR R1, [R0, #0x00] - Read chip ID
    try code.append(allocator, ldrro(1, 0, 0x00));
    // 0x08: LDR R2, =RESULT_BASE
    try code.append(allocator, ldrPcRel(2, calcOffset(2, 1, literal_pool_start)));
    // 0x0C: STR R1, [R2, #0x00] - Store chip ID at RESULT_BASE
    try code.append(allocator, strro(1, 2, 0x00));
    // 0x10: LDR R1, [R0, #0x3C] - Read PLL status
    try code.append(allocator, ldrro(1, 0, 0x3C));
    // 0x14: STR R1, [R2, #0x04] - Store PLL status
    try code.append(allocator, strro(1, 2, 0x04));
    // 0x18: LDR R0, =TIMER_BASE
    try code.append(allocator, ldrPcRel(0, calcOffset(6, 2, literal_pool_start)));
    // 0x1C: LDR R1, [R0, #0x10] - Read USEC timer
    try code.append(allocator, ldrro(1, 0, 0x10));
    // 0x20: STR R1, [R2, #0x08] - Store timer low
    try code.append(allocator, strro(1, 2, 0x08));
    // 0x24: MOV R3, #100
    try code.append(allocator, movi(3, 100));
    // 0x28: SUBS R3, R3, #1
    try code.append(allocator, subsi(3, 3, 1));
    // 0x2C: BNE -3 (back to SUBS at 0x28)
    try code.append(allocator, bne(-3));
    // 0x30: LDR R1, [R0, #0x10] - Read timer again
    try code.append(allocator, ldrro(1, 0, 0x10));
    // 0x34: STR R1, [R2, #0x0C] - Store timer high
    try code.append(allocator, strro(1, 2, 0x0C));
    // 0x38: LDR R0, =CACHE_CTRL_BASE
    try code.append(allocator, ldrPcRel(0, calcOffset(14, 3, literal_pool_start)));
    // 0x3C: LDR R1, [R0, #0x00] - Read cache status
    try code.append(allocator, ldrro(1, 0, 0x00));
    // 0x40: STR R1, [R2, #0x10] - Store cache status
    try code.append(allocator, strro(1, 2, 0x10));
    // 0x44: LDR R1, =0xDEAD1234
    try code.append(allocator, ldrPcRel(1, calcOffset(17, 4, literal_pool_start)));
    // 0x48: STR R1, [R2, #0x14] - Store success marker
    try code.append(allocator, strro(1, 2, 0x14));
    // 0x4C: B . (infinite loop)
    try code.append(allocator, b(-2));

    // Verify we have exactly code_size instructions
    std.debug.assert(code.items.len == code_size);

    // Add literal pool
    for (literals) |lit| {
        try code.append(allocator, lit);
    }

    // Write binary output to file
    const file = try std.fs.cwd().createFile("firmware/test_firmware.bin", .{});
    defer file.close();

    for (code.items) |word| {
        // Write in little-endian
        const bytes: [4]u8 = @bitCast(word);
        _ = try file.write(&bytes);
    }

    std.debug.print("Generated test firmware: {} bytes ({} code + {} literals)\n", .{
        code.items.len * 4,
        code_size * 4,
        literals.len * 4,
    });

    // Print disassembly for verification
    std.debug.print("\nDisassembly:\n", .{});
    for (code.items[0..code_size], 0..) |word, i| {
        std.debug.print("  0x{X:0>2}: 0x{X:0>8}\n", .{ i * 4, word });
    }
    std.debug.print("Literal pool at 0x{X:0>2}:\n", .{literal_pool_start});
    for (literals, 0..) |lit, i| {
        std.debug.print("  0x{X:0>2}: 0x{X:0>8}\n", .{ literal_pool_start + i * 4, lit });
    }
}
