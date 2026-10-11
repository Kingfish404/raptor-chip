OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { ram (rwx) : ORIGIN = 0x80000000, LENGTH = 128M }
SECTIONS
{
    .text : { KEEP(*(.text.start)) *(.text .text.*) } > ram
    .rodata : ALIGN(16) { *(.rodata .rodata.* .srodata .srodata.*) } > ram
    .data : ALIGN(16) {
        __global_pointer$ = . + 0x800;
        *(.data .data.* .sdata .sdata.*)
    } > ram
    .tdata : ALIGN(16) {
        __tls_base = .;
        *(.tdata .tdata.*)
    } > ram
    .tbss (NOLOAD) : {
        __bss_start = .;
        *(.tbss .tbss.*)
    } > ram
    .bss (ADDR(.tbss) + SIZEOF(.tbss)) (NOLOAD) : {
        *(.bss .bss.* .sbss .sbss.*) *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > ram
    __heap_start = ALIGN(16);
    __heap_end = ORIGIN(ram) + LENGTH(ram) - 1M;
    __stack_top = ORIGIN(ram) + LENGTH(ram);
    ASSERT(__heap_start < __heap_end, "benchmark exceeds RAM")
    /DISCARD/ : { *(.comment .eh_frame* .note*) }
}
