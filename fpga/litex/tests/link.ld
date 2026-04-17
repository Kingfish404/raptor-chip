/*
 * Linker script for Raptor LiteX microbenchmark payloads.
 *
 * Payload is loaded by boot.S via --ram-init=<bin> into main_ram at
 * 0x80000000. We place everything there. BSS is zeroed by start.S.
 */

MEMORY {
    ram (rwx) : ORIGIN = 0x80000000, LENGTH = 0x00400000  /* 4 MiB */
}

SECTIONS {
    .text : {
        KEEP(*(.text.start))   /* _start must be first word */
        *(.text)
        *(.text.*)
    } > ram

    .rodata : {
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
    } > ram

    .data : {
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    } > ram

    .bss : {
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        __bss_end = .;
    } > ram

    . = ALIGN(16);
    __stack_bottom = .;
    . += 0x4000;                /* 16 KiB stack */
    __stack_top = .;

    /DISCARD/ : {
        *(.eh_frame)
        *(.comment)
        *(.riscv.attributes)
    }
}

ENTRY(_start)
