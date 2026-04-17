/* Linker script for Raptor LiteX minimal firmware */
/* ROM at 0x20000000, SRAM at 0x0f000000 */

MEMORY {
    rom  (rx)  : ORIGIN = 0x20000000, LENGTH = 128K
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
