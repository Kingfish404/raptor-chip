/* pk userspace layout with the thread-local storage required by Picolibc. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
    . = 0x10000;
    .text : { *(.text.startup .text.startup.*) *(.text .text.*) }
    .rodata : ALIGN(16) { *(.rodata .rodata.* .srodata .srodata.*) }
    . = ALIGN(0x1000);
    .data : { *(.data .data.* .sdata .sdata.*) }
    .tdata : ALIGN(16) {
        __tls_base = .;
        *(.tdata .tdata.*)
    }
    .tbss (NOLOAD) : { *(.tbss .tbss.*) }
    .bss (ADDR(.tbss) + SIZEOF(.tbss)) (NOLOAD) : {
        *(.bss .bss.* .sbss .sbss.*) *(COMMON)
        . = ALIGN(16);
    }
    _end = .;
    /DISCARD/ : { *(.comment .eh_frame* .note*) }
}
