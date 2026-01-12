//! Timer Interrupt Test Firmware
//!
//! Tests timer interrupts with the emulator.
//! To use:
//! 1. Generate boot_stub.bin with gen_boot_stub
//! 2. Generate irq_test.bin with this tool
//! 3. Run: zigpod-emulator --firmware firmware/boot_stub.bin --load-iram firmware/irq_test.bin --trace N
//!
//! The firmware:
//! - Sets up IRQ handler at 0x40000200
//! - Configures Timer1 to fire every 1000 microseconds
//! - Enables Timer1 interrupt in interrupt controller
//! - Enables IRQ in CPU (clears I bit in CPSR)
//! - Loops waiting for interrupts
//! - IRQ handler increments a counter and acknowledges the timer
//!
//! Results stored at 0x40000100:
//! - 0x100: IRQ counter (number of interrupts received)
//! - 0x104: Timer1 config register value (for debugging)
//! - 0x108: Success marker (0xDEADBEEF when complete)

const std = @import("std");

// Memory addresses
const IRAM_BASE: u32 = 0x40000000;
const RESULT_BASE: u32 = 0x40000100;
const IRQ_HANDLER_ADDR: u32 = 0x40000200;

// Peripheral addresses
const INT_CTRL_BASE: u32 = 0x60004000;
const INT_CTRL_STAT: u32 = 0x60004000;
const INT_CTRL_EN: u32 = 0x60004024;
const INT_CTRL_CLR: u32 = 0x60004028;

const TIMER_BASE: u32 = 0x60005000;
const TIMER1_CFG: u32 = 0x60005000;
const TIMER1_VAL: u32 = 0x60005004;

// Timer config bits
const TIMER_ENABLE: u32 = 1 << 31;
const TIMER_REPEAT: u32 = 1 << 30;

// Interrupt bits
const INT_TIMER1: u32 = 1 << 0;

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

/// ADD Rd, Rn, #imm8
fn add(rd: u4, rn: u4, imm: u8) u32 {
    return 0xE2800000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | imm;
}

/// CMP Rn, #imm8
fn cmp(rn: u4, imm: u8) u32 {
    return 0xE3500000 | (@as(u32, rn) << 16) | imm;
}

/// BLT offset
fn blt(offset: i24) u32 {
    const off: u24 = @bitCast(offset);
    return 0xBA000000 | @as(u32, off);
}

/// B offset
fn b(offset: i24) u32 {
    const off: u24 = @bitCast(offset);
    return 0xEA000000 | @as(u32, off);
}

/// MRS Rd, CPSR
fn mrsCpsr(rd: u4) u32 {
    return 0xE10F0000 | (@as(u32, rd) << 12);
}

/// MSR CPSR_c, Rn (write control bits only)
fn msrCpsrC(rn: u4) u32 {
    return 0xE121F000 | @as(u32, rn);
}

/// BIC Rd, Rn, #imm8
fn bic(rd: u4, rn: u4, imm: u8) u32 {
    return 0xE3C00000 | (@as(u32, rn) << 16) | (@as(u32, rd) << 12) | imm;
}

/// SUBS PC, LR, #4 (return from IRQ)
fn subsReturnFromIrq() u32 {
    return 0xE25EF004;
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

    // =====================================================
    // Main code starts at 0x40000000
    // =====================================================

    const main_code_start = 0;

    // === Initialize result area ===
    // 0x00: LDR R2, =RESULT_BASE
    try code.append(allocator, ldrPcRel(2, 0)); // placeholder, will fix
    const lit_result_base_idx = code.items.len - 1;

    // 0x04: MOV R0, #0
    try code.append(allocator, mov(0, 0));

    // 0x08: STR R0, [R2, #0x00] - Clear IRQ counter
    try code.append(allocator, str(0, 2, 0x00));

    // 0x0C: STR R0, [R2, #0x04] - Clear timer config storage
    try code.append(allocator, str(0, 2, 0x04));

    // 0x10: STR R0, [R2, #0x08] - Clear success marker
    try code.append(allocator, str(0, 2, 0x08));

    // === Configure Timer1 ===
    // 0x14: LDR R3, =TIMER_BASE
    try code.append(allocator, ldrPcRel(3, 0)); // placeholder
    const lit_timer_base_idx = code.items.len - 1;

    // 0x18: LDR R0, =TIMER_CONFIG (enable | repeat | 1000us)
    try code.append(allocator, ldrPcRel(0, 0)); // placeholder
    const lit_timer_cfg_idx = code.items.len - 1;

    // 0x1C: STR R0, [R3, #0x00] - Write Timer1 config
    try code.append(allocator, str(0, 3, 0x00));

    // 0x20: STR R0, [R2, #0x04] - Store config for debugging
    try code.append(allocator, str(0, 2, 0x04));

    // === Enable Timer1 interrupt in interrupt controller ===
    // 0x24: LDR R4, =INT_CTRL_EN
    try code.append(allocator, ldrPcRel(4, 0)); // placeholder
    const lit_int_en_idx = code.items.len - 1;

    // 0x28: MOV R0, #1 (INT_TIMER1 bit)
    try code.append(allocator, mov(0, 1));

    // 0x2C: STR R0, [R4] - Enable Timer1 interrupt
    try code.append(allocator, str(0, 4, 0x00));

    // === Enable IRQ in CPSR ===
    // 0x30: MRS R0, CPSR
    try code.append(allocator, mrsCpsr(0));

    // 0x34: BIC R0, R0, #0x80 (clear IRQ disable bit)
    try code.append(allocator, bic(0, 0, 0x80));

    // 0x38: MSR CPSR_c, R0
    try code.append(allocator, msrCpsrC(0));

    // === Main loop: wait for 5 interrupts then exit ===
    const loop_start = code.items.len;

    // 0x3C: LDR R0, [R2, #0x00] - Read IRQ counter
    try code.append(allocator, ldr(0, 2, 0x00));

    // 0x40: CMP R0, #5
    try code.append(allocator, cmp(0, 5));

    // 0x44: BLT loop_start (wait for more interrupts)
    const blt_offset: i24 = @intCast(@as(i32, @intCast(loop_start)) - @as(i32, @intCast(code.items.len)) - 2);
    try code.append(allocator, blt(blt_offset));

    // 0x48: LDR R0, =SUCCESS_MARKER
    try code.append(allocator, ldrPcRel(0, 0)); // placeholder
    const lit_success_idx = code.items.len - 1;

    // 0x4C: STR R0, [R2, #0x08] - Write success marker
    try code.append(allocator, str(0, 2, 0x08));

    // 0x50: B . (infinite loop - done)
    try code.append(allocator, b(-2));

    // Pad to align IRQ handler at 0x200 (instruction 0x80)
    while (code.items.len < 0x80) {
        try code.append(allocator, nop());
    }

    // =====================================================
    // IRQ Handler at 0x40000200 (offset 0x200 from IRAM base)
    // =====================================================
    const irq_handler_start = code.items.len;

    // Save registers we'll use (minimal - just R0, R1, R2, R3)
    // We're already in IRQ mode with separate LR and SPSR

    // 0x200: LDR R2, =RESULT_BASE
    try code.append(allocator, ldrPcRel(2, 0)); // placeholder
    const lit_result_base_irq_idx = code.items.len - 1;

    // 0x204: LDR R0, [R2, #0x00] - Load counter
    try code.append(allocator, ldr(0, 2, 0x00));

    // 0x208: ADD R0, R0, #1 - Increment counter
    try code.append(allocator, add(0, 0, 1));

    // 0x20C: STR R0, [R2, #0x00] - Store counter
    try code.append(allocator, str(0, 2, 0x00));

    // Acknowledge timer interrupt by writing to TIMER1_VAL
    // 0x210: LDR R1, =TIMER1_VAL
    try code.append(allocator, ldrPcRel(1, 0)); // placeholder
    const lit_timer_val_idx = code.items.len - 1;

    // 0x214: STR R0, [R1] - Acknowledge timer (value doesn't matter)
    try code.append(allocator, str(0, 1, 0x00));

    // Clear interrupt in interrupt controller
    // 0x218: LDR R1, =INT_CTRL_STAT
    try code.append(allocator, ldrPcRel(1, 0)); // placeholder
    const lit_int_stat_idx = code.items.len - 1;

    // 0x21C: MOV R0, #1
    try code.append(allocator, mov(0, 1));

    // 0x220: STR R0, [R1] - Clear Timer1 interrupt status
    try code.append(allocator, str(0, 1, 0x00));

    // 0x224: SUBS PC, LR, #4 - Return from IRQ
    try code.append(allocator, subsReturnFromIrq());

    // Pad and add literal pool
    while ((code.items.len - irq_handler_start) < 20) {
        try code.append(allocator, nop());
    }

    // =====================================================
    // Literal pools
    // =====================================================

    // Calculate literal pool start
    const main_literal_pool_start = code.items.len;

    // Fix up main code literals
    const main_pool_base = main_literal_pool_start * 4;

    // Helper to calculate PC-relative offset
    const calcOffset = struct {
        fn calc(instr_idx: usize, literal_idx: usize) u12 {
            const instr_addr = instr_idx * 4;
            const pc = instr_addr + 8;
            const literal_addr = literal_idx * 4;
            if (literal_addr >= pc) {
                return @intCast(literal_addr - pc);
            }
            return 0; // Error case
        }
    }.calc;

    // Add main code literals
    try code.append(allocator, RESULT_BASE);
    const lit_result_base_addr = code.items.len - 1;

    try code.append(allocator, TIMER_BASE);
    const lit_timer_base_addr = code.items.len - 1;

    try code.append(allocator, TIMER_ENABLE | TIMER_REPEAT | 1000);
    const lit_timer_cfg_addr = code.items.len - 1;

    try code.append(allocator, INT_CTRL_EN);
    const lit_int_en_addr = code.items.len - 1;

    try code.append(allocator, 0xDEADBEEF);
    const lit_success_addr = code.items.len - 1;

    // Add IRQ handler literals
    try code.append(allocator, RESULT_BASE);
    const lit_result_base_irq_addr = code.items.len - 1;

    try code.append(allocator, TIMER1_VAL);
    const lit_timer_val_addr = code.items.len - 1;

    try code.append(allocator, INT_CTRL_STAT);
    const lit_int_stat_addr = code.items.len - 1;

    // Update instructions with correct offsets
    code.items[lit_result_base_idx] = ldrPcRel(2, calcOffset(lit_result_base_idx, lit_result_base_addr));
    code.items[lit_timer_base_idx] = ldrPcRel(3, calcOffset(lit_timer_base_idx, lit_timer_base_addr));
    code.items[lit_timer_cfg_idx] = ldrPcRel(0, calcOffset(lit_timer_cfg_idx, lit_timer_cfg_addr));
    code.items[lit_int_en_idx] = ldrPcRel(4, calcOffset(lit_int_en_idx, lit_int_en_addr));
    code.items[lit_success_idx] = ldrPcRel(0, calcOffset(lit_success_idx, lit_success_addr));
    code.items[lit_result_base_irq_idx] = ldrPcRel(2, calcOffset(lit_result_base_irq_idx, lit_result_base_irq_addr));
    code.items[lit_timer_val_idx] = ldrPcRel(1, calcOffset(lit_timer_val_idx, lit_timer_val_addr));
    code.items[lit_int_stat_idx] = ldrPcRel(1, calcOffset(lit_int_stat_idx, lit_int_stat_addr));

    // Write binary output
    const file = try std.fs.cwd().createFile("firmware/irq_test.bin", .{});
    defer file.close();

    for (code.items) |word| {
        const bytes: [4]u8 = @bitCast(word);
        _ = try file.write(&bytes);
    }

    std.debug.print("Generated IRQ test firmware: {} bytes\n", .{code.items.len * 4});
    std.debug.print("  Main code: 0x{X:0>8} - 0x{X:0>8}\n", .{ IRAM_BASE, IRAM_BASE + main_code_start * 4 + 0x54 });
    std.debug.print("  IRQ handler: 0x{X:0>8}\n", .{IRQ_HANDLER_ADDR});
    std.debug.print("  Literal pool: 0x{X:0>8}\n", .{IRAM_BASE + main_pool_base});

    // Print key instructions for debugging
    std.debug.print("\nKey instructions:\n", .{});
    std.debug.print("  0x{X:0>8}: 0x{X:0>8}  ; LDR R2, =RESULT_BASE\n", .{ IRAM_BASE + lit_result_base_idx * 4, code.items[lit_result_base_idx] });
    std.debug.print("  0x{X:0>8}: 0x{X:0>8}  ; Timer config\n", .{ IRAM_BASE + lit_timer_cfg_idx * 4, code.items[lit_timer_cfg_idx] });
}
