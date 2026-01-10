/*
 * ZigPod Single Binary Linker Script for PortalPlayer PP5021C
 *
 * Apple bootloader loads the binary to 0x10000000 (IRAM).
 * Only code/data in IRAM goes into the binary file.
 * BSS/stack/heap are in SDRAM, initialized at runtime.
 */

MEMORY
{
    /* IRAM - Where Apple loads firmware - THIS GOES IN BINARY */
    IRAM (rwx) : ORIGIN = 0x10000000, LENGTH = 96K

    /* SDRAM - Runtime memory - NOT in binary, just address reservation */
    SDRAM (rwx) : ORIGIN = 0x40000000, LENGTH = 32M

    /* Uncached SDRAM for DMA */
    SDRAM_NC (rw) : ORIGIN = 0x42000000, LENGTH = 1M
}

ENTRY(_start)

SECTIONS
{
    /* ============================================================ */
    /* Code and data in IRAM (goes into binary file) */
    /* ============================================================ */

    .vectors : {
        KEEP(*(.vectors))
        KEEP(*(.vectors.*))
    } > IRAM

    .text : {
        *(.text._start*)
        *(.text.kernelInit*)
        *(.text)
        *(.text.*)
        *(.gnu.linkonce.t.*)
    } > IRAM

    .rodata : {
        *(.rodata)
        *(.rodata.*)
        *(.gnu.linkonce.r.*)
    } > IRAM

    .ARM.extab : {
        *(.ARM.extab*)
    } > IRAM

    .ARM.exidx : {
        __exidx_start = .;
        *(.ARM.exidx*)
        __exidx_end = .;
    } > IRAM

    .data : {
        __data_start = .;
        *(.data)
        *(.data.*)
        *(.gnu.linkonce.d.*)
        __data_end = .;
    } > IRAM

    /* Mark end of IRAM content */
    __iram_content_end = .;

    /* ============================================================ */
    /* Runtime sections in SDRAM (NOT in binary file) */
    /* ============================================================ */

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.gnu.linkonce.b.*)
        *(COMMON)
        __bss_end = .;
    } > SDRAM

    .stack (NOLOAD) : {
        . = ALIGN(8);
        __stack_bottom = .;
        . += 16K;
        __stack_top = .;
    } > SDRAM

    .irq_stack (NOLOAD) : {
        . = ALIGN(8);
        __irq_stack_bottom = .;
        . += 4K;
        __irq_stack_top = .;
    } > SDRAM

    .fiq_stack (NOLOAD) : {
        . = ALIGN(8);
        __fiq_stack_bottom = .;
        . += 2K;
        __fiq_stack_top = .;
    } > SDRAM

    .iram (NOLOAD) : {
        __iram_start = .;
        *(.iram)
        *(.iram.*)
        __iram_end = .;
    } > SDRAM

    __iram_load = __iram_content_end;

    /* Heap */
    __heap_start = .;
    __heap_end = ORIGIN(SDRAM_NC);

    /* ============================================================ */
    /* DMA buffers in uncached SDRAM */
    /* ============================================================ */

    .dma_buffers (NOLOAD) : {
        . = ALIGN(32);
        __dma_start = .;
        *(.dma_buffer)
        *(.dma_buffer.*)
        __dma_end = .;
    } > SDRAM_NC

    .audio_buffer (NOLOAD) : {
        . = ALIGN(32);
        __audio_buffer_start = .;
        . += 512K;
        __audio_buffer_end = .;
    } > SDRAM_NC

    /DISCARD/ : {
        *(.comment)
        *(.note.*)
    }
}

/* Symbols for startup code */
__sdram_start = ORIGIN(SDRAM);
__sdram_end = ORIGIN(SDRAM) + LENGTH(SDRAM);
__iram_origin = ORIGIN(IRAM);
__iram_length = LENGTH(IRAM);
