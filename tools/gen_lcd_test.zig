//! LCD Test Firmware Generator
//!
//! Generates ARM firmware that tests the LCD2 bridge interface.
//! Uses the same protocol as Rockbox to write pixels to the display.
//!
//! Usage:
//! 1. Generate boot_stub.bin with gen_boot_stub
//! 2. Generate lcd_test.bin with this tool
//! 3. Run: zigpod-emulator --firmware firmware/boot_stub.bin --load-iram firmware/lcd_test.bin

const std = @import("std");

// Memory addresses
const IRAM_BASE: u32 = 0x40000000;
const RESULT_BASE: u32 = 0x40000100;

// LCD2 Bridge registers (from Rockbox pp5020.h)
const LCD2_BASE: u32 = 0x70008A00;
const LCD2_PORT: u32 = 0x70008A0C;
const LCD2_BLOCK_CTRL: u32 = 0x70008A20;
const LCD2_BLOCK_CONFIG: u32 = 0x70008A24;
const LCD2_BLOCK_DATA: u32 = 0x70008B00;

// Block control commands and flags
const BLOCK_READY: u32 = 0x04000000;
const BLOCK_TXOK: u32 = 0x01000000;
const BLOCK_CMD_INIT: u32 = 0x10000080;
const BLOCK_CMD_START: u32 = 0x34000000;

// LCD dimensions
const LCD_WIDTH: u32 = 320;
const LCD_HEIGHT: u32 = 240;

// ARM instruction helpers

/// LDR Rd, [PC, #offset]
fn ldrPcRel(rd: u4, offset: u12) u32 {
    return 0xE59F0000 | (@as(u32, rd) << 12) | offset;
}

/// LDR Rd, [Rn, #offset]
fn ldr(rd: u4, rn: u4, offset: u12) u32 {
    return 0xE5900000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | offset;
}

/// STR Rd, [Rn, #offset]
fn str(rd: u4, rn: u4, offset: u12) u32 {
    return 0xE5800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | offset;
}

/// MOV Rd, #imm8
fn mov(rd: u4, imm: u8) u32 {
    return 0xE3A00000 | (@as(u32, rd) << 12) | imm;
}

/// MOV Rd, #imm8, ROR #rot*2 (for larger immediates)
fn movImm(rd: u4, imm: u8, rot: u4) u32 {
    return 0xE3A00000 | (@as(u32, rd) << 12) | (@as(u32, rot) << 8) | imm;
}

/// ADD Rd, Rn, #imm8
fn add(rd: u4, rn: u4, imm: u8) u32 {
    return 0xE2800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | imm;
}

/// SUBS Rd, Rn, #imm8
fn subs(rd: u4, rn: u4, imm: u8) u32 {
    return 0xE2500000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | imm;
}

/// CMP Rn, #imm8
fn cmp(rn: u4, imm: u8) u32 {
    return 0xE3500000 | (@as(u32, rn) << 16) | imm;
}

/// BNE offset
fn bne(offset: i24) u32 {
    const off: u24 = @bitCast(offset);
    return 0x1A000000 | @as(u32, off);
}

/// B offset
fn b(offset: i24) u32 {
    const off: u24 = @bitCast(offset);
    return 0xEA000000 | @as(u32, off);
}

/// TST Rn, #imm8
fn tst(rn: u4, imm: u8) u32 {
    return 0xE3100000 | (@as(u32, rn) << 16) | imm;
}

/// BEQ offset
fn beq(offset: i24) u32 {
    const off: u24 = @bitCast(offset);
    return 0x0A000000 | @as(u32, off);
}

/// ORR Rd, Rn, Rm, LSL #shift
fn orrShift(rd: u4, rn: u4, rm: u4, shift: u5) u32 {
    return 0xE1800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | (@as(u32, shift) << 7) | @as(u32, rm);
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

    // Literal fixup info
    const LitFixup = struct { instr_idx: usize, lit_idx: usize, rd: u4 };

    // Track instruction indices for literal pool fixups
    var lit_indices = std.ArrayListUnmanaged(LitFixup){};
    defer lit_indices.deinit(allocator);

    // Literal pool values
    var literals = std.ArrayListUnmanaged(u32){};
    defer literals.deinit(allocator);

    // Helper to add PC-relative load with fixup
    const addLdrLitHelper = struct {
        fn add(c: *std.ArrayListUnmanaged(u32), li: *std.ArrayListUnmanaged(LitFixup), lits: *std.ArrayListUnmanaged(u32), a: std.mem.Allocator, rd: u4, value: u32) !void {
            const instr_idx = c.items.len;
            try c.append(a, ldrPcRel(rd, 0)); // Placeholder offset

            // Find or add literal
            var lit_idx: usize = 0;
            var found = false;
            for (lits.items, 0..) |lit, i| {
                if (lit == value) {
                    lit_idx = i;
                    found = true;
                    break;
                }
            }
            if (!found) {
                lit_idx = lits.items.len;
                try lits.append(a, value);
            }

            try li.append(a, .{ .instr_idx = instr_idx, .lit_idx = lit_idx, .rd = rd });
        }
    };

    const addLdrLit = addLdrLitHelper.add;

    // =====================================================
    // Main code at 0x40000000
    // =====================================================

    // === Initialize LCD2 block transfer ===
    // Load LCD2_BLOCK_CTRL address
    try addLdrLit(&code, &lit_indices, &literals, allocator, 4, LCD2_BLOCK_CTRL);

    // Load LCD2_BLOCK_CONFIG address
    try addLdrLit(&code, &lit_indices, &literals, allocator, 5, LCD2_BLOCK_CONFIG);

    // Load LCD2_BLOCK_DATA address
    try addLdrLit(&code, &lit_indices, &literals, allocator, 6, LCD2_BLOCK_DATA);

    // === Fill screen with red ===
    // Red in RGB565 = 0xF800

    // Initialize block transfer
    // Write BLOCK_CMD_INIT to LCD2_BLOCK_CTRL
    try addLdrLit(&code, &lit_indices, &literals, allocator, 0, BLOCK_CMD_INIT);
    try code.append(allocator, str(0, 4, 0x00)); // STR R0, [R4]

    // Configure transfer size: full screen = 320*240*2 bytes = 153600 bytes
    // But block transfers are limited to 0x10000 bytes, so we'll do multiple blocks
    // For simplicity, do 160*240*2 = 76800 bytes per block (two blocks for full screen)

    // First half of screen (153600 / 2 = 76800 bytes)
    // BLOCK_CONFIG = 0xC0010000 | (bytes - 1)
    // = 0xC0010000 | 0x12BFF = 0xC00132BFF? That doesn't fit in imm8
    // Actually Rockbox does: 0xc0010000 | (pixels_to_write - 1)
    // where pixels_to_write is in bytes (2 per pixel)
    // So for 38400 pixels = 76800 bytes: 0xc0010000 | (76800 - 1) = 0xC0012BFF

    try addLdrLit(&code, &lit_indices, &literals, allocator, 0, 0xC0012BFF);
    try code.append(allocator, str(0, 5, 0x00)); // STR R0, [R5] - configure

    // Start transfer
    try addLdrLit(&code, &lit_indices, &literals, allocator, 0, BLOCK_CMD_START);
    try code.append(allocator, str(0, 4, 0x00)); // STR R0, [R4] - start

    // Load red color (RGB565: red = 0xF800, two pixels = 0xF800F800)
    try addLdrLit(&code, &lit_indices, &literals, allocator, 7, 0xF800F800);

    // Write 38400 pixels (19200 32-bit words, 2 pixels per word)
    // Use R8 as counter
    try addLdrLit(&code, &lit_indices, &literals, allocator, 8, 19200);

    const loop1_start = code.items.len;
    // Write pixel data
    try code.append(allocator, str(7, 6, 0x00)); // STR R7, [R6] - write 2 pixels
    // Decrement counter
    try code.append(allocator, subs(8, 8, 1));
    // Loop if not zero
    const loop1_offset: i24 = @intCast(@as(i32, @intCast(loop1_start)) - @as(i32, @intCast(code.items.len)) - 2);
    try code.append(allocator, bne(loop1_offset));

    // Note: In a real implementation, we'd wait for transfer complete by polling
    // BLOCK_CTRL for BLOCK_READY bit. Since the emulator processes instantly,
    // we skip the wait loop for simplicity.

    // === Second half with green ===
    // Green in RGB565 = 0x07E0 (two pixels = 0x07E007E0)

    // Re-init block transfer
    try addLdrLit(&code, &lit_indices, &literals, allocator, 0, BLOCK_CMD_INIT);
    try code.append(allocator, str(0, 4, 0x00));

    // Same size
    try addLdrLit(&code, &lit_indices, &literals, allocator, 0, 0xC0012BFF);
    try code.append(allocator, str(0, 5, 0x00));

    // Start
    try addLdrLit(&code, &lit_indices, &literals, allocator, 0, BLOCK_CMD_START);
    try code.append(allocator, str(0, 4, 0x00));

    // Load green color
    try addLdrLit(&code, &lit_indices, &literals, allocator, 7, 0x07E007E0);

    // Counter
    try addLdrLit(&code, &lit_indices, &literals, allocator, 8, 19200);

    const loop2_start = code.items.len;
    try code.append(allocator, str(7, 6, 0x00));
    try code.append(allocator, subs(8, 8, 1));
    const loop2_offset: i24 = @intCast(@as(i32, @intCast(loop2_start)) - @as(i32, @intCast(code.items.len)) - 2);
    try code.append(allocator, bne(loop2_offset));

    // Store success marker
    try addLdrLit(&code, &lit_indices, &literals, allocator, 2, RESULT_BASE);
    try addLdrLit(&code, &lit_indices, &literals, allocator, 0, 0xDEADBEEF);
    try code.append(allocator, str(0, 2, 0x00));

    // Infinite loop
    try code.append(allocator, b(-2));

    // Pad to align literal pool (4-byte aligned is fine, but let's add some space)
    while (code.items.len % 4 != 0) {
        try code.append(allocator, nop());
    }

    // =====================================================
    // Literal pool
    // =====================================================
    const literal_pool_start = code.items.len;

    for (literals.items) |lit| {
        try code.append(allocator, lit);
    }

    // Fix up all PC-relative loads
    for (lit_indices.items) |fixup| {
        const instr_addr = fixup.instr_idx * 4;
        const pc = instr_addr + 8; // ARM PC = instruction address + 8
        const literal_addr = (literal_pool_start + fixup.lit_idx) * 4;
        if (literal_addr >= pc) {
            const offset: u12 = @intCast(literal_addr - pc);
            code.items[fixup.instr_idx] = ldrPcRel(fixup.rd, offset);
        } else {
            std.debug.print("Error: literal pool before instruction at 0x{X}\n", .{instr_addr});
        }
    }

    // Write binary output
    const file = try std.fs.cwd().createFile("firmware/lcd_test.bin", .{});
    defer file.close();

    for (code.items) |word| {
        const bytes: [4]u8 = @bitCast(word);
        _ = try file.write(&bytes);
    }

    std.debug.print("Generated LCD test firmware: {} bytes\n", .{code.items.len * 4});
    std.debug.print("  Code: {} instructions\n", .{literal_pool_start});
    std.debug.print("  Literals: {} words\n", .{literals.items.len});

    // Print disassembly summary
    std.debug.print("\nTest will:\n", .{});
    std.debug.print("  1. Fill top half of screen with red (RGB565: 0xF800)\n", .{});
    std.debug.print("  2. Fill bottom half with green (RGB565: 0x07E0)\n", .{});
    std.debug.print("  3. Write 0xDEADBEEF to 0x{X:0>8} on success\n", .{RESULT_BASE});
}
