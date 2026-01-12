@ LFN Character Iteration Test
@ Tests the longent_char_next() pattern used in Rockbox FAT driver
@
@ This is the exact C code we're testing:
@   static inline unsigned int longent_char_next(unsigned int i) {
@       switch (i += 2) {
@       case 26: i -= 1; /* Fall-Through */
@       case 11: i += 3;
@       }
@       return i < 31 ? i : 0;
@   }

.global _start
.arm

@ Result addresses at IRAM + 0x200 (away from code/literal pool)
.equ RESULT_BASE,       0x40000200
.equ RESULT_MARKER,     0x40000200  @ "LFN\0" marker
.equ RESULT_INPUT_9,    0x40000204  @ longent_char_next(9) -> expected 14
.equ RESULT_INPUT_22,   0x40000208  @ longent_char_next(22) -> expected 24
.equ RESULT_INPUT_24,   0x4000020C  @ longent_char_next(24) -> expected 28
.equ RESULT_INPUT_28,   0x40000210  @ longent_char_next(28) -> expected 30
.equ RESULT_INPUT_30,   0x40000214  @ longent_char_next(30) -> expected 0 (end)
.equ RESULT_PASS_FAIL,  0x40000218  @ 0xPASSED or 0xFAILED

_start:
    @ Set up stack pointer in IRAM
    ldr sp, =0x40017FF0

    @ Write marker "LFN\0" (0x004E464C in little-endian)
    ldr r0, =RESULT_BASE
    ldr r1, =0x004E464C     @ "LFN\0"
    str r1, [r0]

    @ Test 1: longent_char_next(9) -> expected 14
    @ This tests the case 11 branch (9+2=11, then +3=14)
    mov r0, #9
    bl longent_char_next
    ldr r1, =RESULT_INPUT_9
    str r0, [r1]

    @ Test 2: longent_char_next(22) -> expected 24
    @ This tests normal case (22+2=24, no special case)
    mov r0, #22
    bl longent_char_next
    ldr r1, =RESULT_INPUT_22
    str r0, [r1]

    @ Test 3: longent_char_next(24) -> expected 28
    @ This tests the CRITICAL case 26 with fall-through (24+2=26, -1=25, +3=28)
    mov r0, #24
    bl longent_char_next
    ldr r1, =RESULT_INPUT_24
    str r0, [r1]

    @ Test 4: longent_char_next(28) -> expected 30
    @ This tests normal case after name3 starts (28+2=30)
    mov r0, #28
    bl longent_char_next
    ldr r1, =RESULT_INPUT_28
    str r0, [r1]

    @ Test 5: longent_char_next(30) -> expected 0
    @ This tests end of entry (30+2=32 >= 31, return 0)
    mov r0, #30
    bl longent_char_next
    ldr r1, =RESULT_INPUT_30
    str r0, [r1]

    @ Verify all results and set PASS/FAIL marker
    mov r7, #0              @ r7 = pass flag (0 = all pass)

    @ Check test 1: should be 14
    ldr r0, =RESULT_INPUT_9
    ldr r0, [r0]
    cmp r0, #14
    bne test_failed

    @ Check test 2: should be 24
    ldr r0, =RESULT_INPUT_22
    ldr r0, [r0]
    cmp r0, #24
    bne test_failed

    @ Check test 3 (CRITICAL): should be 28
    ldr r0, =RESULT_INPUT_24
    ldr r0, [r0]
    cmp r0, #28
    bne test_failed

    @ Check test 4: should be 30
    ldr r0, =RESULT_INPUT_28
    ldr r0, [r0]
    cmp r0, #30
    bne test_failed

    @ Check test 5: should be 0
    ldr r0, =RESULT_INPUT_30
    ldr r0, [r0]
    cmp r0, #0
    bne test_failed

    @ All tests passed!
    ldr r0, =RESULT_PASS_FAIL
    ldr r1, =0x50415353     @ "PASS" in little-endian
    str r1, [r0]
    b done

test_failed:
    ldr r0, =RESULT_PASS_FAIL
    ldr r1, =0x4641494C     @ "FAIL" in little-endian
    str r1, [r0]

done:
    @ Infinite loop
    b done

@ ============================================================
@ longent_char_next - Get next byte offset for LFN character
@ Input: r0 = current offset
@ Output: r0 = next offset (or 0 if past end)
@ Preserves: r1-r12, lr
@ ============================================================
longent_char_next:
    @ i += 2
    add r0, r0, #2

    @ switch (i):
    @ case 26: fall through after decrement
    cmp r0, #26
    bne check_case_11
    sub r0, r0, #1          @ case 26: i -= 1
    @ Fall through to case 11

check_case_11:
    cmp r0, #11             @ Note: after case 26, r0=25, not 11
    beq do_case_11
    cmp r0, #25             @ After fall-through from case 26, check if 25
    bne end_switch

do_case_11:
    add r0, r0, #3          @ case 11: i += 3 (also case 26 fall-through)

end_switch:
    @ return i < 31 ? i : 0
    cmp r0, #31
    movge r0, #0
    bx lr

.end
