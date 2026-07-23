OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    stage (rx) : ORIGIN = 0x82000000, LENGTH = 0x1000
}

SECTIONS {
    .text : {
        *(.text.init)
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > stage

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.riscv.attributes)
    }
}

ASSERT(SIZEOF(.text) <= 0x1000, "egos stage0 exceeds its 4 KiB bundle slot")