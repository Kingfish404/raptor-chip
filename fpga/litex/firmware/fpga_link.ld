/* Linker script for the Tang Mega 138K bring-up ROM */

MEMORY {
    rom  (rx)  : ORIGIN = 0x20000000, LENGTH = 64K
    sram (rwx) : ORIGIN = 0x0f000000, LENGTH = 8K
}

SECTIONS {
    .text : {
        *(.text)
        *(.text.*)
    } > rom

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    } > rom

    .data : {
        *(.data)
        *(.data.*)
    } > sram AT > rom

    .bss : {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    } > sram

    /DISCARD/ : {
        *(.eh_frame)
        *(.comment)
        *(.riscv.attributes)
    }
}

ENTRY(_start)
