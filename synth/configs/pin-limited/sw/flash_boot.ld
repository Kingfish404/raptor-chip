/* Raw Flash offset zero maps to XIP after the reset ROM. Keep this image below 64 KiB.
 * Initialized SRAM code/data is stored immediately after the ROM text.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
  rom (rx) : ORIGIN = 0x30000000, LENGTH = 64K
  ram (rwx) : ORIGIN = 0x0f000000, LENGTH = 8K
}
SECTIONS {
  .text : { KEEP(*(.text.start)) *(.text .text.*) *(.rodata .rodata.*) } >rom
  .ramtext : ALIGN(4) {
    _sram_start = .;
    *(.ramtext .ramtext.*)
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(4);
    _sram_end = .;
  } >ram AT>rom
  _sram_load = LOADADDR(.ramtext);
  .bss (NOLOAD) : ALIGN(4) {
    _bss_start = .;
    *(.bss .bss.* .sbss .sbss.*) *(COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } >ram
  _stack_top = ORIGIN(ram) + LENGTH(ram);
  ASSERT(_bss_end <= _stack_top - 2048, "Reserve 2 KiB for the stack")
  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame*) }
}
