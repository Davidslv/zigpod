/* Linker script for emulator test firmware
 * Loads at address 0 (boot ROM location)
 */

ENTRY(_start)

MEMORY
{
    /* Boot ROM area - firmware loads here */
    ROM (rx) : ORIGIN = 0x00000000, LENGTH = 128K
}

SECTIONS
{
    /* Code starts at address 0 */
    .text 0x00000000 :
    {
        *(.text._start)    /* Entry point first */
        *(.text*)
        *(.rodata*)
    } > ROM

    .data :
    {
        *(.data*)
    } > ROM

    .bss :
    {
        *(.bss*)
    } > ROM

    /* Discard debug sections for smaller binary */
    /DISCARD/ :
    {
        *(.comment)
        *(.debug*)
        *(.ARM.*)
    }
}
