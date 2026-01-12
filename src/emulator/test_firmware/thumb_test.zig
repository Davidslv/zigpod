//! Thumb Mode Test Firmware for PP5021C Emulator
//!
//! Tests ARM to Thumb mode switching:
//! 1. Start in ARM mode
//! 2. Switch to Thumb mode using BX
//! 3. Fill screen with green using Thumb instructions
//! 4. Trigger LCD update
//!
//! If you see GREEN, Thumb mode works!
//! If you see nothing or crash, there's a bug.
//!
//! This uses raw machine code because Zig's inline assembler
//! doesn't support mixed ARM/Thumb in a single asm block.

/// Raw machine code for the test
/// Assembled manually for ARM7TDMI
const firmware = [_]u32{
    // === ARM MODE (32-bit instructions) ===
    // 0x00: adr r0, thumb_code (PC-relative load: thumb_code is at 0x0C, so offset = 0x0C - 0x08 = 0x04)
    //       Actually for ADR with forward reference: add r0, pc, #offset
    //       At PC=0x00, reading PC gives 0x08 (ARM pipeline), we want 0x0C
    //       So: add r0, pc, #4 -> E28F0004
    0xE28F0004,

    // 0x04: add r0, r0, #1 (set bit 0 to indicate Thumb mode)
    //       add r0, r0, #1 -> E2800001
    0xE2800001,

    // 0x08: bx r0 (branch to Thumb code)
    //       bx r0 -> E12FFF10
    0xE12FFF10,

    // === THUMB MODE (16-bit instructions, packed into 32-bit words) ===
    // 0x0C: thumb_code starts here
    // We need to pack two 16-bit Thumb instructions per 32-bit word
    // Little-endian: lower half-word first

    // Thumb code to fill screen with green (0x07E0) and trigger update:
    //
    // Build 0x30000000 in r0:
    //   mov r0, #0x30      ; 2030 (mov r0, #48)
    //   lsl r0, r0, #24    ; 0600 (lsl r0, r0, #24)
    //
    // Build 0x07E007E0 in r1 (green):
    //   mov r1, #0xE0      ; 21E0 (mov r1, #224)
    //   mov r2, #0x07      ; 2207 (mov r2, #7)
    //   lsl r2, r2, #8     ; 0212 (lsl r2, r2, #8)
    //   orr r1, r2         ; 4311 (orr r1, r2)
    //   mov r2, r1         ; 1C0A (mov r2, r1 = add r2, r1, #0)
    //   lsl r2, r2, #16    ; 0412 (lsl r2, r2, #16)
    //   orr r1, r2         ; 4311 (orr r1, r2)
    //
    // Counter r2 = 0:
    //   mov r2, #0         ; 2200 (mov r2, #0)
    //
    // Count r3 = 0x9600 (38400):
    //   mov r3, #0x96      ; 2396 (mov r3, #150)
    //   lsl r3, r3, #8     ; 021B (lsl r3, r3, #8)
    //
    // Loop:
    //   str r1, [r0]       ; 6001 (str r1, [r0, #0])
    //   add r2, #1         ; 3201 (add r2, #1)
    //   cmp r2, r3         ; 429A (cmp r2, r3)
    //   blt loop           ; D3FB (blt -5*2 = -10 -> offset -5)
    //
    // Trigger update - write 0x34 to 0x30030000:
    //   mov r4, #0x30      ; 2430 (mov r4, #48)
    //   lsl r4, r4, #24    ; 0624 (lsl r4, r4, #24)
    //   mov r5, #0x03      ; 2503 (mov r5, #3)
    //   lsl r5, r5, #16    ; 042D (lsl r5, r5, #16)
    //   orr r4, r5         ; 432C (orr r4, r5)
    //   mov r5, #0x34      ; 2534 (mov r5, #52)
    //   str r5, [r4]       ; 6025 (str r5, [r4, #0])
    //
    // Halt loop:
    //   b halt             ; E7FE (b -2 -> infinite loop)

    // 0x0C: mov r0, #0x30 | lsl r0, r0, #24
    0x06002030,
    // 0x10: mov r1, #0xE0 | mov r2, #0x07
    0x220721E0,
    // 0x14: lsl r2, r2, #8 | orr r1, r2
    0x43110212,
    // 0x18: mov r2, r1 (add r2, r1, #0) | lsl r2, r2, #16
    0x04121C0A,
    // 0x1C: orr r1, r2 | mov r2, #0
    0x22004311,
    // 0x20: mov r3, #0x96 | lsl r3, r3, #8
    0x021B2396,
    // 0x24: str r1, [r0] | add r2, #1  (loop start at 0x24)
    0x32016001,
    // 0x28: cmp r2, r3 | blt loop (offset = (0x24 - 0x2C) / 2 = -4, encoded as 0xFC = -4 in signed 8-bit)
    0xD3FC429A,
    // 0x2C: mov r4, #0x30 | lsl r4, r4, #24
    0x06242430,
    // 0x30: mov r5, #0x03 | lsl r5, r5, #16
    0x042D2503,
    // 0x34: orr r4, r5 | mov r5, #0x34
    0x2534432C,
    // 0x38: str r5, [r4] | b halt (halt is next instruction)
    0xE7FE6025,
    // 0x3C: Additional halt in case we need alignment
    0xE7FEE7FE,
};

/// Entry point - exports the raw firmware
export fn _start() callconv(.c) noreturn {
    // This function exists just to satisfy the linker.
    // The actual code is in the 'firmware' array above.
    // We use inline assembly to reference it so it's not optimized out.
    asm volatile (
        \\.globl firmware_data
        \\firmware_data:
    );
    unreachable;
}

/// Comptime function to get firmware as bytes
pub fn getFirmwareBytes() []const u8 {
    return @as([*]const u8, @ptrCast(&firmware))[0 .. firmware.len * 4];
}

comptime {
    // Ensure firmware is at the start
    @export(&firmware, .{ .name = "_firmware_start", .linkage = .strong });
}
