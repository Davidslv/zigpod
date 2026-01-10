/*
 * ZigPod Bootloader Linker Script for PortalPlayer PP5021C
 *
 * The bootloader is loaded by the Boot ROM into IRAM and executes from there.
 * It then loads the main ZigPod firmware into DRAM.
 *
 * Memory Map:
 *   0x10000000 - 0x10017FFF : IRAM (96KB) - Bootloader runs here
 *   0x40000000 - 0x43FFFFFF : DRAM (32MB) - Main firmware loaded here
 */

MEMORY
{
    /* Internal SRAM - bootloader code and data */
    IRAM (rwx) : ORIGIN = 0x10000000, LENGTH = 96K

    /* Small DRAM region for bootloader to use temporarily */
    DRAM (rwx) : ORIGIN = 0x40000000, LENGTH = 64K
}

/* Entry point - Boot ROM jumps here */
ENTRY(_start)

SECTIONS
{
    /* ============================================================ */
    /* Vector Table - at start of IRAM */
    /* ============================================================ */
    .vectors : {
        KEEP(*(.vectors))
        KEEP(*(.vectors.*))
    } > IRAM

    /* ============================================================ */
    /* Code Section */
    /* ============================================================ */
    .text : {
        *(.text)
        *(.text.*)
        *(.gnu.linkonce.t.*)
    } > IRAM

    /* Read-only data */
    .rodata : {
        *(.rodata)
        *(.rodata.*)
        *(.gnu.linkonce.r.*)
    } > IRAM

    /* ARM exception handling tables */
    .ARM.extab : {
        *(.ARM.extab*)
    } > IRAM

    .ARM.exidx : {
        __exidx_start = .;
        *(.ARM.exidx*)
        __exidx_end = .;
    } > IRAM

    /* ============================================================ */
    /* Initialized Data */
    /* ============================================================ */
    .data : {
        __data_start = .;
        *(.data)
        *(.data.*)
        *(.gnu.linkonce.d.*)
        __data_end = .;
    } > IRAM

    /* ============================================================ */
    /* Uninitialized Data (BSS) */
    /* ============================================================ */
    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.gnu.linkonce.b.*)
        *(COMMON)
        __bss_end = .;
    } > IRAM

    /* ============================================================ */
    /* Stack (at end of IRAM, grows down) */
    /* ============================================================ */
    .stack (NOLOAD) : {
        . = ALIGN(8);
        __stack_bottom = .;
        . += 8K;  /* 8KB bootloader stack */
        __stack_top = .;
    } > IRAM

    /* ============================================================ */
    /* Boot Configuration Area */
    /* ============================================================ */
    .boot_config (NOLOAD) : {
        . = ALIGN(4);
        __boot_config_start = .;
        *(.boot_config)
        __boot_config_end = .;
    } > IRAM

    /* ============================================================ */
    /* Temporary DRAM buffer for loading firmware */
    /* ============================================================ */
    .dram_buffer (NOLOAD) : {
        __dram_buffer_start = .;
        *(.dram_buffer)
        __dram_buffer_end = .;
    } > DRAM

    /* ============================================================ */
    /* Debug Sections (discarded in release) */
    /* ============================================================ */
    /DISCARD/ : {
        *(.comment)
        *(.note.*)
    }
}

/* Useful symbols */
__iram_start = ORIGIN(IRAM);
__iram_end = ORIGIN(IRAM) + LENGTH(IRAM);
__dram_start = ORIGIN(DRAM);
