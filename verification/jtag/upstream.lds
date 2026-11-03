OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.entry) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) }
  .sdata : {
    __global_pointer$ = . + 0x800;
    *(.srodata .srodata.* .sdata .sdata.*)
  }
  __bss_start = .;
  .sbss : { *(.sbss .sbss.* .scommon) }
  .bss : { *(.bss .bss.* COMMON) }
  __bss_end = .;
  __malloc_start = .;
  . += 4096;
  _end = .;
}
