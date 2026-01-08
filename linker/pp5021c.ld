/*
 * ZigPod Linker Script for PortalPlayer PP5021C (iPod Video 5th Gen)
 *
 * Memory Map (from Rockbox documentation):
 *   0x00000000 - 0x0001FFFF : Flash/Boot ROM (128KB)
 *   0x10000000 - 0x10001FFF : Internal SRAM (8KB, fast memory)
 *   0x40000000 - 0x43FFFFFF : SDRAM (32MB or 64MB)
 *
 * For firmware loaded by bootloader, we start at DRAM_START (0x40000000)
 */

MEMORY
{
    /* Internal SRAM - fast memory for critical code/data */
    IRAM (rwx) : ORIGIN = 0x10000000, LENGTH = 8K

    /* Main SDRAM - assume 32MB minimum (30GB model) */
    /* Leave first 4KB for bootloader communication */
    DRAM (rwx) : ORIGIN = 0x40001000, LENGTH = 32M - 4K

    /* Uncached DRAM region for DMA buffers */
    DRAM_NC (rw) : ORIGIN = 0x42000000, LENGTH = 1M
}

/* Entry point */
ENTRY(_start)

SECTIONS
{
    /* ============================================================ */
    /* Vector Table - must be at start of DRAM or remapped */
    /* ============================================================ */
    .vectors : {
        KEEP(*(.vectors))
        KEEP(*(.vectors.*))
    } > DRAM

    /* ============================================================ */
    /* Code Section */
    /* ============================================================ */
    .text : {
        *(.text)
        *(.text.*)
        *(.gnu.linkonce.t.*)
    } > DRAM

    /* Read-only data */
    .rodata : {
        *(.rodata)
        *(.rodata.*)
        *(.gnu.linkonce.r.*)
    } > DRAM

    /* ARM exception handling tables */
    .ARM.extab : {
        *(.ARM.extab*)
    } > DRAM

    .ARM.exidx : {
        __exidx_start = .;
        *(.ARM.exidx*)
        __exidx_end = .;
    } > DRAM

    /* ============================================================ */
    /* Initialized Data */
    /* ============================================================ */
    .data : {
        __data_start = .;
        *(.data)
        *(.data.*)
        *(.gnu.linkonce.d.*)
        __data_end = .;
    } > DRAM

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
    } > DRAM

    /* ============================================================ */
    /* Stack (grows down from end of main DRAM) */
    /* ============================================================ */
    .stack (NOLOAD) : {
        . = ALIGN(8);
        __stack_bottom = .;
        . += 16K;  /* 16KB main stack */
        __stack_top = .;
    } > DRAM

    /* IRQ Stack */
    .irq_stack (NOLOAD) : {
        . = ALIGN(8);
        __irq_stack_bottom = .;
        . += 4K;
        __irq_stack_top = .;
    } > DRAM

    /* FIQ Stack */
    .fiq_stack (NOLOAD) : {
        . = ALIGN(8);
        __fiq_stack_bottom = .;
        . += 2K;
        __fiq_stack_top = .;
    } > DRAM

    /* ============================================================ */
    /* IRAM Sections (fast memory) */
    /* ============================================================ */
    .iram : {
        __iram_start = .;
        *(.iram)
        *(.iram.*)
        __iram_end = .;
    } > IRAM AT > DRAM

    __iram_load = LOADADDR(.iram);

    /* IRAM BSS */
    .iram_bss (NOLOAD) : {
        __iram_bss_start = .;
        *(.iram_bss)
        *(.iram_bss.*)
        __iram_bss_end = .;
    } > IRAM

    /* ============================================================ */
    /* DMA Buffers (uncached) */
    /* ============================================================ */
    .dma_buffers (NOLOAD) : {
        . = ALIGN(32);  /* Cache line alignment */
        __dma_start = .;
        *(.dma_buffer)
        *(.dma_buffer.*)
        __dma_end = .;
    } > DRAM_NC

    /* Audio buffer - large, uncached for DMA */
    .audio_buffer (NOLOAD) : {
        . = ALIGN(32);
        __audio_buffer_start = .;
        . += 512K;  /* 512KB audio buffer */
        __audio_buffer_end = .;
    } > DRAM_NC

    /* ============================================================ */
    /* Heap (remaining DRAM) */
    /* ============================================================ */
    .heap (NOLOAD) : {
        . = ALIGN(8);
        __heap_start = .;
        /* Heap extends to end of DRAM */
    } > DRAM

    __heap_end = ORIGIN(DRAM) + LENGTH(DRAM);

    /* ============================================================ */
    /* Debug Sections (discarded in release) */
    /* ============================================================ */
    /DISCARD/ : {
        *(.comment)
        *(.note.*)
    }
}

/* Useful symbols for startup code */
__dram_start = ORIGIN(DRAM);
__dram_end = ORIGIN(DRAM) + LENGTH(DRAM);
__iram_origin = ORIGIN(IRAM);
__iram_length = LENGTH(IRAM);
