//! LCD Test Firmware for PP5021C Emulator
//!
//! Simple test: fill screen with red, trigger update, then halt.
//! Written entirely in inline assembly to ensure correct code generation.

/// Entry point
export fn _start() callconv(.c) noreturn {
    // All in one assembly block with explicit control flow
    // Phase 1: Fill screen with red pixels
    // Phase 2: Trigger LCD update
    // Phase 3: Infinite halt loop
    asm volatile (
        // Setup for pixel fill
        // R0 = BCM_DATA32 (0x30000000)
        // R1 = red color 0xF800F800 (two RGB565 red pixels)
        //      0xF800 = RGB565 red (R=31, G=0, B=0)
        \\mov r0, #0x30000000
        \\mov r1, #0xF800
        \\orr r1, r1, #0xF8000000
        \\mov r2, #0
        \\mov r3, #0x9000
        \\orr r3, r3, #0x600
        // Pixel write loop
        \\pixel_loop:
        \\str r1, [r0]
        \\add r2, r2, #1
        \\cmp r2, r3
        \\blt pixel_loop
        // Trigger LCD update (write 0x34 to 0x30030000)
        \\mov r0, #0x30000000
        \\orr r0, r0, #0x30000
        \\mov r1, #0x34
        \\str r1, [r0]
        // Infinite halt loop
        \\halt_loop:
        \\mov r0, r0
        \\b halt_loop
    );
    unreachable;
}
