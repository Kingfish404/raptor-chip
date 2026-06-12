OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    main_ram (rwx) : ORIGIN = 0x80000000, LENGTH = 1M
}

SECTIONS {
    .text.init : {
        *(.text.init)
    } > main_ram

    .text : {
        *(.text)
        *(.text.*)
    } > main_ram

    .rodata : ALIGN(4) {
        *(.rodata)
        *(.rodata.*)
    } > main_ram

    /DISCARD/ : {
        *(.eh_frame)
        *(.comment)
        *(.riscv.attributes)
        *(.note.*)
    }
}