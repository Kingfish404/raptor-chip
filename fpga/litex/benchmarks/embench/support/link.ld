/* ============================================================================
 * link.ld: Linker script for Embench-IoT on Raptor LiteX SoC
 *
 * Binary is loaded to main_ram at 0x80000000 by boot firmware.
 * Larger footprint than CoreMark (picojpeg, sglib, nettle-* need ~100-200 KB
 * .rodata/.bss), so we grant 1 MiB + a 32 KiB stack.
 * ============================================================================ */

OUTPUT_FORMAT("elf32-littleriscv")
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ram (rwx) : ORIGIN = 0x80000000, LENGTH = 1M
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

    /* 32 KiB stack reserved after BSS (some benchmarks recurse) */
    . = ALIGN(16);
    _sstack = .;
    . = . + 32K;
    _estack = .;

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
