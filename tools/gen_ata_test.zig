//! ATA Test Firmware Generator
//!
//! Generates ARM firmware that tests the ATA controller by reading
//! the MBR (first sector) and checking for the 0x55AA boot signature.
//!
//! Usage:
//! 1. Create a test disk image: dd if=/dev/zero of=test.img bs=512 count=2048
//! 2. Add MBR signature: echo -ne '\x55\xaa' | dd of=test.img bs=1 seek=510 conv=notrunc
//! 3. Generate firmware: gen-ata-test
//! 4. Run: zigpod-emulator --load-iram firmware/ata_test.bin test.img

const std = @import("std");

// Memory addresses
const IRAM_BASE: u32 = 0x40000000;
const RESULT_BASE: u32 = 0x40000100;

// ATA registers (PP5021C 4-byte aligned!)
const ATA_BASE: u32 = 0xC3000000;
const ATA_DATA: u32 = ATA_BASE + 0x1E0;
const ATA_ERROR: u32 = ATA_BASE + 0x1E4;
const ATA_NSECTOR: u32 = ATA_BASE + 0x1E8;
const ATA_SECTOR: u32 = ATA_BASE + 0x1EC;
const ATA_LCYL: u32 = ATA_BASE + 0x1F0;
const ATA_HCYL: u32 = ATA_BASE + 0x1F4;
const ATA_SELECT: u32 = ATA_BASE + 0x1F8;
const ATA_COMMAND: u32 = ATA_BASE + 0x1FC;
const ATA_STATUS: u32 = ATA_BASE + 0x1FC; // Same as command (read vs write)
const ATA_CONTROL: u32 = ATA_BASE + 0x3F8;

// ATA commands
const CMD_READ_SECTORS: u8 = 0x20;

// ATA status bits
const STATUS_BSY: u8 = 0x80;
const STATUS_DRQ: u8 = 0x08;
const STATUS_ERR: u8 = 0x01;

// LCD2 Bridge for showing result
const LCD2_BLOCK_CTRL: u32 = 0x70008A20;
const LCD2_BLOCK_CONFIG: u32 = 0x70008A24;
const LCD2_BLOCK_DATA: u32 = 0x70008B00;
const BLOCK_CMD_INIT: u32 = 0x10000080;
const BLOCK_CMD_START: u32 = 0x34000000;

// ARM instruction helpers

/// LDR Rd, [PC, #offset]
fn ldrPcRel(rd: u4, offset: u12) u32 {
    return 0xE59F0000 | (@as(u32, rd) << 12) | offset;
}

/// LDR Rd, [Rn]
fn ldr(rd: u4, rn: u4) u32 {
    return 0xE5900000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12);
}

/// LDRB Rd, [Rn]
fn ldrb(rd: u4, rn: u4) u32 {
    return 0xE5D00000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12);
}

/// LDRH Rd, [Rn, #0] - unsigned halfword load with zero offset
fn ldrh(rd: u4, rn: u4) u32 {
    // Encoding: cond 000P UIWL Rn Rd offset_h 1011 offset_l
    // P=1 (pre-index), U=1 (add), I=1 (immediate), W=0 (no writeback), L=1 (load)
    // offset_h=0, offset_l=0 for zero offset
    return 0xE1F000B0 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12);
}

/// STR Rd, [Rn]
fn str(rd: u4, rn: u4) u32 {
    return 0xE5800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12);
}

/// STRH Rd, [Rn, #0] - unsigned halfword store with zero offset
fn strh(rd: u4, rn: u4) u32 {
    // Encoding: cond 000P UIWL Rn Rd offset_h 1011 offset_l
    // P=1 (pre-index), U=1 (add), I=1 (immediate), W=0 (no writeback), L=0 (store)
    return 0xE1C000B0 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12);
}

/// STRB Rd, [Rn]
fn strb(rd: u4, rn: u4) u32 {
    return 0xE5C00000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12);
}

/// MOV Rd, #imm8
fn movImm(rd: u4, imm: u8) u32 {
    return 0xE3A00000 | (@as(u32, rd) << 12) | imm;
}

/// CMP Rn, #imm8
fn cmpImm(rn: u4, imm: u8) u32 {
    return 0xE3500000 | (@as(u32, rn) << 16) | imm;
}

/// AND Rd, Rn, #imm8
fn andImm(rd: u4, rn: u4, imm: u8) u32 {
    return 0xE2000000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | imm;
}

/// TST Rn, #imm8
fn tstImm(rn: u4, imm: u8) u32 {
    return 0xE3100000 | (@as(u32, rn) << 16) | imm;
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

/// BEQ offset (branch if equal)
fn beq(offset: i24) u32 {
    const off: u32 = @as(u24, @bitCast(offset));
    return 0x0A000000 | off;
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
    // ATA Test Code
    // =====================================================

    // Load register addresses
    // R4 = ATA_SELECT
    // R5 = ATA_COMMAND
    // R6 = ATA_STATUS
    // R7 = ATA_DATA
    // R8 = ATA_NSECTOR
    // R9 = ATA_SECTOR/LCYL/HCYL
    // R10 = RESULT_BASE

    try addLdrLit(&code, &lit_indices, &literals, allocator, 4, ATA_SELECT);
    try addLdrLit(&code, &lit_indices, &literals, allocator, 5, ATA_COMMAND);
    try addLdrLit(&code, &lit_indices, &literals, allocator, 6, ATA_STATUS);
    try addLdrLit(&code, &lit_indices, &literals, allocator, 7, ATA_DATA);
    try addLdrLit(&code, &lit_indices, &literals, allocator, 8, ATA_NSECTOR);
    try addLdrLit(&code, &lit_indices, &literals, allocator, 9, ATA_SECTOR);
    try addLdrLit(&code, &lit_indices, &literals, allocator, 10, RESULT_BASE);

    // Select drive 0, LBA mode
    // WRITE 0xE0 to ATA_SELECT
    try code.append(allocator, movImm(0, 0xE0));
    try code.append(allocator, strb(0, 4));

    // Wait for drive ready (poll status for not BSY)
    const wait_ready = code.items.len;
    try code.append(allocator, ldrb(0, 6)); // Read status
    try code.append(allocator, tstImm(0, STATUS_BSY)); // Test BSY bit
    const wait_offset: i24 = @intCast(@as(i32, @intCast(wait_ready)) - @as(i32, @intCast(code.items.len)) - 2);
    try code.append(allocator, bne(wait_offset)); // Loop if BSY set

    // Set LBA = 0 (sector 0 - MBR)
    try code.append(allocator, movImm(0, 0));
    try code.append(allocator, strb(0, 9)); // SECTOR
    try addLdrLit(&code, &lit_indices, &literals, allocator, 11, ATA_LCYL);
    try code.append(allocator, strb(0, 11)); // LCYL
    try addLdrLit(&code, &lit_indices, &literals, allocator, 11, ATA_HCYL);
    try code.append(allocator, strb(0, 11)); // HCYL

    // Set sector count = 1
    try code.append(allocator, movImm(0, 1));
    try code.append(allocator, strb(0, 8));

    // Issue READ SECTORS command
    try code.append(allocator, movImm(0, CMD_READ_SECTORS));
    try code.append(allocator, strb(0, 5));

    // Wait for DRQ (data ready)
    const wait_drq = code.items.len;
    try code.append(allocator, ldrb(0, 6)); // Read status
    try code.append(allocator, tstImm(0, STATUS_DRQ)); // Test DRQ bit
    const drq_offset: i24 = @intCast(@as(i32, @intCast(wait_drq)) - @as(i32, @intCast(code.items.len)) - 2);
    try code.append(allocator, beq(drq_offset)); // Loop if DRQ not set

    // Read 256 words (512 bytes) into memory
    // R11 = word counter
    // R12 = read buffer pointer
    try addLdrLit(&code, &lit_indices, &literals, allocator, 11, 256);
    try addLdrLit(&code, &lit_indices, &literals, allocator, 12, RESULT_BASE + 0x100); // Buffer at RESULT_BASE + 256

    const read_loop = code.items.len;
    try code.append(allocator, ldrh(0, 7)); // Read 16-bit word from ATA_DATA
    try code.append(allocator, strh(0, 12)); // Store halfword to buffer
    // Advance pointer by 2
    try code.append(allocator, 0xE2800002); // ADD R0, R0, #2 -> we need ADD R12, R12, #2
    // Actually: ADD R12, R12, #2 = 0xE28CC002
    // Remove last instruction and add correct one
    _ = code.pop();
    try code.append(allocator, 0xE28CC002); // ADD R12, R12, #2
    // Decrement counter
    try code.append(allocator, subsImm(11, 11, 1));
    const loop_offset: i24 = @intCast(@as(i32, @intCast(read_loop)) - @as(i32, @intCast(code.items.len)) - 2);
    try code.append(allocator, bne(loop_offset));

    // Check MBR signature at offset 510-511 (0x55, 0xAA)
    // Load word at buffer+508 (contains bytes 508-511)
    try addLdrLit(&code, &lit_indices, &literals, allocator, 12, RESULT_BASE + 0x100 + 508);
    try code.append(allocator, ldr(0, 12));
    // Extract bytes 510-511 (upper 16 bits of word at 508)
    // Actually bytes 510-511 are at offset 510 = buffer + 510
    // Let's load halfword at buffer + 510
    _ = code.pop();
    _ = code.pop();
    try addLdrLit(&code, &lit_indices, &literals, allocator, 12, RESULT_BASE + 0x100 + 510);
    try code.append(allocator, ldrh(0, 12));

    // Compare with 0xAA55 (little-endian: 0x55 at 510, 0xAA at 511)
    try addLdrLit(&code, &lit_indices, &literals, allocator, 1, 0xAA55);
    try code.append(allocator, 0xE1500001); // CMP R0, R1

    // If equal, store success marker
    // STREQ R2, [R10]: cond=0 (EQ), P=1, U=1, B=0, W=0, L=0, Rn=10, Rd=2, offset=0
    // = 0000 0101 1000 1010 0010 0000 0000 0000 = 0x058A2000
    try addLdrLit(&code, &lit_indices, &literals, allocator, 2, 0xCAFEBABE);
    try code.append(allocator, 0x058A2000); // STREQ R2, [R10] - store if equal

    // If not equal, store failure marker
    // STRNE R2, [R10]: cond=1 (NE), same encoding otherwise = 0x158A2000
    try addLdrLit(&code, &lit_indices, &literals, allocator, 2, 0xDEADDEAD);
    try code.append(allocator, 0x158A2000); // STRNE R2, [R10] - store if not equal

    // Store the actual signature we read for debugging
    try code.append(allocator, 0xE58A0004); // STR R0, [R10, #4]

    // Infinite loop
    try code.append(allocator, b(-2));

    // Pad to align
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
        const pc = instr_addr + 8;
        const literal_addr = (literal_pool_start + fixup.lit_idx) * 4;
        if (literal_addr >= pc) {
            const offset: u12 = @intCast(literal_addr - pc);
            code.items[fixup.instr_idx] = ldrPcRel(fixup.rd, offset);
        }
    }

    // Write binary output
    const file = try std.fs.cwd().createFile("firmware/ata_test.bin", .{});
    defer file.close();

    for (code.items) |word| {
        const bytes: [4]u8 = @bitCast(word);
        _ = try file.write(&bytes);
    }

    std.debug.print("Generated ATA test firmware: {} bytes\n", .{code.items.len * 4});
    std.debug.print("  Code: {} instructions\n", .{literal_pool_start});
    std.debug.print("  Literals: {} words\n", .{literals.items.len});

    std.debug.print("\nTest will:\n", .{});
    std.debug.print("  1. Wait for drive ready\n", .{});
    std.debug.print("  2. Read sector 0 (MBR)\n", .{});
    std.debug.print("  3. Check for boot signature 0x55AA at offset 510-511\n", .{});
    std.debug.print("  4. Store 0xCAFEBABE at 0x{X:0>8} on success\n", .{RESULT_BASE});
    std.debug.print("     Store 0xDEADDEAD at 0x{X:0>8} on failure\n", .{RESULT_BASE});
    std.debug.print("\nUsage:\n", .{});
    std.debug.print("  1. Create test disk: dd if=/dev/zero of=test.img bs=512 count=2048\n", .{});
    std.debug.print("  2. Add MBR sig: echo -ne '\\x55\\xaa' | dd of=test.img bs=1 seek=510 conv=notrunc\n", .{});
    std.debug.print("  3. Run: zigpod-emulator --load-iram firmware/ata_test.bin test.img\n", .{});
}
