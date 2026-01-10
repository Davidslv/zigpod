/*
 * Minimal linker script for testing
 * Code in IRAM (where Apple loads), data/bss in SDRAM
 */

MEMORY
{
    IRAM (rwx) : ORIGIN = 0x10000000, LENGTH = 96K
    SDRAM (rwx) : ORIGIN = 0x40000000, LENGTH = 32M
}

ENTRY(_start)

SECTIONS
{
    .text : {
        *(.text)
        *(.text.*)
    } > IRAM

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    } > IRAM

    .data : {
        *(.data)
        *(.data.*)
    } > SDRAM

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        __bss_end = .;
    } > SDRAM

    /DISCARD/ : {
        *(.comment)
        *(.note.*)
        *(.ARM.*)
    }
}
