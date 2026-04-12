/*
 * pk-user.ld — Linker script for user ELFs running under riscv-pk
 *
 * Uses standard userspace addresses (starting at 0x10000) instead of
 * picolibc's bare-metal layout (0x80000000) which conflicts with pk.
 * Passed via -T to suppress picolibc.ld injection from specs.
 */

ENTRY(_start)

SECTIONS
{
    . = 0x10000;

    .text : {
        *(.text.startup .text.startup.*)
        *(.text.init .text.init.*)
        *(.text .text.*)
        *(.gnu.linkonce.t.*)
    }

    .rodata : {
        *(.rdata)
        *(.rodata .rodata.*)
        *(.gnu.linkonce.r.*)
        *(.srodata .srodata.*)
    }

    . = ALIGN(0x1000);

    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
        *(.gnu.linkonce.d.*)
    }

    .bss : {
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(.gnu.linkonce.b.*)
        *(COMMON)
    }

    . = ALIGN(8);
    _end = .;

    /DISCARD/ : {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}
