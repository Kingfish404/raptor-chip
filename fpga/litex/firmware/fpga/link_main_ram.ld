/*
 * Linker script for Raptor firmware uploaded into main_ram via LiteX BIOS
 * `serialboot`. All sections live at 0x80000000 (single contiguous BSRAM
 * region, no ROM/RAM split — everything is writable).
 *
 * Pair with `make fpga-upload BIN=...`. Build with the same boot.S/main*.c
 * sources as the ROM image; only the linker script differs:
 *
 *   make firmware-fpga FW_FPGA_TARGET=irqtest FW_FPGA_LOAD=main_ram
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    main_ram (rwx) : ORIGIN = 0x80000000, LENGTH = 512K
}

SECTIONS {
    .text.init : { *(.text.init) } > main_ram

    .text : {
        *(.text)
        *(.text.*)
    } > main_ram

    .rodata : ALIGN(4) {
        *(.rodata)
        *(.rodata.*)
    } > main_ram

    .data : ALIGN(4) {
        _sdata = .;
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
        . = ALIGN(4);
        _edata = .;
    } > main_ram

    /* No need for a separate load-address ROM — boot.S still does the
     * .data copy loop, but here load == run, so make _sidata == _sdata. */
    _sidata = ADDR(.data);

    .bss (NOLOAD) : ALIGN(4) {
        _sbss = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > main_ram

    /* Stack at the top of main_ram, with 256 B reserved at the very top
     * for the trap handler so the dumper has its own private stack. */
    _stack_top      = ORIGIN(main_ram) + LENGTH(main_ram) - 0x100;
    _trap_stack_top = ORIGIN(main_ram) + LENGTH(main_ram);

    /* ROM CRC range — for the rom-crc shell command. With load==run this
     * is a degenerate self-CRC of the loaded image. */
    _srom = ORIGIN(main_ram);
    _erom = ADDR(.data) + (_edata - _sdata);

    /DISCARD/ : {
        *(.eh_frame)
        *(.comment)
        *(.note.gnu.build-id)
    }
}
