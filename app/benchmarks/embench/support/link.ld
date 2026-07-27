OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ram (rwx) : ORIGIN = 0x80000000, LENGTH = 16M
}

SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > ram

    .rodata : ALIGN(8) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > ram

    .data : ALIGN(8) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > ram

    .bss : ALIGN(8) {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        __bss_end = .;
    } > ram

    . = ALIGN(16);
    . = . + 16K;
    __stack_top = .;

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame*)
        *(.note*)
        *(.riscv.attributes)
    }
}