@ PP5021C Test Firmware
@ Runs directly in IRAM at 0x40000000
@ Tests basic peripherals without ROM dependency

.global _start
.arm

@ Memory map constants
.equ IRAM_BASE,         0x40000000
.equ SDRAM_BASE,        0x10000000

@ Peripheral base addresses
.equ SYS_CTRL_BASE,     0x60006000
.equ TIMER_BASE,        0x60005000
.equ GPIO_BASE,         0x6000D000
.equ INT_CTRL_BASE,     0x60004000
.equ CACHE_CTRL_BASE,   0x6000C000
.equ I2C_BASE,          0x7000C000
.equ LCD_BASE,          0x30000000

@ System Controller registers
.equ REG_CHIP_ID,       0x00
.equ REG_DEV_EN,        0x0C
.equ REG_PLL_STATUS,    0x3C

@ Timer registers
.equ REG_USEC_TIMER,    0x10

@ I2C registers
.equ I2C_CTRL,          0x00
.equ I2C_ADDR,          0x04
.equ I2C_DATA0,         0x0C
.equ I2C_STATUS,        0x1C

@ I2C device addresses
.equ PCF50605_ADDR,     0x08
.equ WM8758_ADDR,       0x1A

@ Result codes stored at IRAM + 0x100
.equ RESULT_BASE,       0x40000100
.equ RESULT_CHIP_ID,    0x40000100
.equ RESULT_PLL_STATUS, 0x40000104
.equ RESULT_USEC_LOW,   0x40000108
.equ RESULT_USEC_HIGH,  0x4000010C
.equ RESULT_I2C_PCF_ID, 0x40000110
.equ RESULT_CACHE_STAT, 0x40000114
.equ RESULT_STATUS,     0x40000118

_start:
    @ Set up stack pointer in IRAM
    ldr sp, =0x40017FF0

    @ === Test 1: Read Chip ID ===
    ldr r0, =SYS_CTRL_BASE
    ldr r1, [r0, #REG_CHIP_ID]
    ldr r2, =RESULT_CHIP_ID
    str r1, [r2]

    @ === Test 2: Read PLL Status ===
    ldr r1, [r0, #REG_PLL_STATUS]
    ldr r2, =RESULT_PLL_STATUS
    str r1, [r2]

    @ === Test 3: Read USEC Timer ===
    ldr r0, =TIMER_BASE
    ldr r1, [r0, #REG_USEC_TIMER]
    ldr r2, =RESULT_USEC_LOW
    str r1, [r2]

    @ Small delay
    mov r3, #1000
delay1:
    subs r3, r3, #1
    bne delay1

    @ Read timer again
    ldr r1, [r0, #REG_USEC_TIMER]
    ldr r2, =RESULT_USEC_HIGH
    str r1, [r2]

    @ === Test 4: Read Cache Status ===
    ldr r0, =CACHE_CTRL_BASE
    ldr r1, [r0]            @ Status register at offset 0
    ldr r2, =RESULT_CACHE_STAT
    str r1, [r2]

    @ === Test 5: I2C - Read PCF50605 ID ===
    @ Set up I2C to read from PCF50605
    ldr r0, =I2C_BASE

    @ Set register address to read (register 0 = ID)
    mov r1, #0
    str r1, [r0, #I2C_DATA0]

    @ Write PCF50605 address (write mode first to set register)
    mov r1, #PCF50605_ADDR
    str r1, [r0, #I2C_ADDR]

    @ Start write (1 byte)
    mov r1, #0x180          @ Start + 1 byte
    str r1, [r0, #I2C_CTRL]

    @ Wait for completion
    mov r3, #100
i2c_wait1:
    ldr r1, [r0, #I2C_STATUS]
    tst r1, #0x04           @ Check done bit
    bne i2c_done1
    subs r3, r3, #1
    bne i2c_wait1
i2c_done1:

    @ Now read the ID
    mov r1, #PCF50605_ADDR
    orr r1, r1, #0x80       @ Read mode
    str r1, [r0, #I2C_ADDR]

    @ Start read (1 byte)
    mov r1, #0x180
    str r1, [r0, #I2C_CTRL]

    @ Wait for completion
    mov r3, #100
i2c_wait2:
    ldr r1, [r0, #I2C_STATUS]
    tst r1, #0x04
    bne i2c_done2
    subs r3, r3, #1
    bne i2c_wait2
i2c_done2:

    @ Get result
    ldr r1, [r0, #I2C_DATA0]
    ldr r2, =RESULT_I2C_PCF_ID
    str r1, [r2]

    @ === Write success marker ===
    ldr r2, =RESULT_STATUS
    ldr r1, =0xDEAD1234     @ Success marker
    str r1, [r2]

    @ === Done - infinite loop ===
done_loop:
    b done_loop

.end
