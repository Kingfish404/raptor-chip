/* ============================================================================
 * link.ld: Linker script for CoreMark on Raptor LiteX SoC
 *
 * Binary is loaded to main_ram at 0x80000000 by boot firmware.
 * ============================================================================ */

OUTPUT_FORMAT("elf32-littleriscv")
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ram (rwx) : ORIGIN = 0x80000000, LENGTH = 256K
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text .text.*)
    } > ram

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > ram

    .data : ALIGN(4) {
        _fdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        _edata = .;
    } > ram

    .bss : ALIGN(4) {
        _fbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _ebss = .;
    } > ram

    /* Stack: 16 KB after BSS */
    . = ALIGN(16);
    _sstack = .;
    . = . + 16K;
    _estack = .;

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
