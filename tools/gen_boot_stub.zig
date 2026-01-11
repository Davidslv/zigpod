//! Boot Stub Generator
//!
//! Generates a minimal boot ROM that:
//! - Contains exception vector table
//! - Branches to IRAM at 0x40000000 for main code
//! - Has an IRQ handler that jumps to the handler address in IRAM
//!
//! This allows testing interrupt-driven firmware loaded in IRAM.

const std = @import("std");

// Memory addresses
const IRAM_START: u32 = 0x40000000;
const IRQ_HANDLER_ADDR: u32 = 0x40000200; // Where IRQ handler should be in IRAM

/// B offset (unconditional branch, offset in words from PC+8)
fn b(offset: i24) u32 {
    // B offset = EAxxxxxx
    const off: u24 = @bitCast(offset);
    return 0xEA000000 | @as(u32, off);
}

/// LDR PC, [PC, #offset] - Load PC from literal pool
fn ldrPcFromPool(offset: u12) u32 {
    // LDR PC, [PC, #offset] = E59FF0xx
    return 0xE59FF000 | @as(u32, offset);
}

/// SUBS PC, LR, #4 - Return from IRQ exception
fn subsReturnFromIrq() u32 {
    // SUBS PC, LR, #4 = E25EF004
    return 0xE25EF004;
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

    // Exception Vector Table (at address 0x00)
    // Each vector is 4 bytes, and they can be either:
    // - B <handler> : Branch to handler (limited range)
    // - LDR PC, [PC, #offset] : Load handler address from literal pool

    // 0x00: Reset vector - LDR PC from literal pool at 0x20
    // LDR PC, [PC, #0x18] loads from 0x00 + 8 + 0x18 = 0x20
    try code.append(allocator, ldrPcFromPool(0x18));

    // 0x04: Undefined instruction - infinite loop
    try code.append(allocator, b(-2)); // B .

    // 0x08: SWI - infinite loop
    try code.append(allocator, b(-2)); // B .

    // 0x0C: Prefetch abort - infinite loop
    try code.append(allocator, b(-2)); // B .

    // 0x10: Data abort - infinite loop
    try code.append(allocator, b(-2)); // B .

    // 0x14: Reserved
    try code.append(allocator, nop());

    // 0x18: IRQ - LDR PC from literal pool at 0x38
    // LDR PC, [PC, #0x18] loads from 0x18 + 8 + 0x18 = 0x38
    try code.append(allocator, ldrPcFromPool(0x18));

    // 0x1C: FIQ - infinite loop
    try code.append(allocator, b(-2)); // B .

    // 0x20: Literal pool entry - Reset handler address (IRAM_START)
    try code.append(allocator, IRAM_START);

    // Padding 0x24-0x34 (5 words)
    for (0..5) |_| {
        try code.append(allocator, nop());
    }

    // 0x38: IRQ handler address (literal pool entry for IRQ vector)
    // IRQ at 0x18: LDR PC, [PC, #0x18] -> loads from 0x18 + 8 + 0x18 = 0x38
    try code.append(allocator, IRQ_HANDLER_ADDR);

    // 0x3C: More padding
    try code.append(allocator, nop());

    // Write binary output
    const file = try std.fs.cwd().createFile("firmware/boot_stub.bin", .{});
    defer file.close();

    for (code.items) |word| {
        const bytes: [4]u8 = @bitCast(word);
        _ = try file.write(&bytes);
    }

    std.debug.print("Generated boot stub: {} bytes\n", .{code.items.len * 4});

    // Print disassembly
    std.debug.print("\nVector Table:\n", .{});
    for (code.items, 0..) |word, i| {
        const addr = i * 4;
        const label: []const u8 = switch (addr) {
            0x00 => "Reset",
            0x04 => "Undef",
            0x08 => "SWI",
            0x0C => "PAbort",
            0x10 => "DAbort",
            0x14 => "Reserved",
            0x18 => "IRQ",
            0x1C => "FIQ",
            0x38 => "IRQ_ADDR",
            else => "",
        };
        std.debug.print("  0x{X:0>2}: 0x{X:0>8}  {s}\n", .{ addr, word, label });
    }
}
