/* ==========================================================================
 * Linker script for fuzz/sigtest programs targeting Raptor Chip NPC sim.
 *
 * Memory map must match sim expectations:
 *   - MROM at 0x20000000 (bootloader, jumps to MBASE)
 *   - User code/data loaded at MBASE = 0x80000000
 * ========================================================================== */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 0x8000000  /* 128 MiB */
}

SECTIONS
{
    . = 0x80000000;

    .text : {
        *(.text .text.*)
    } > RAM

    . = ALIGN(8);

    .rodata : {
        *(.rodata .rodata.*)
    } > RAM

    . = ALIGN(8);

    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM

    . = ALIGN(8);

    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        __bss_end = .;
    } > RAM

    . = ALIGN(8);
    _end = .;

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}
