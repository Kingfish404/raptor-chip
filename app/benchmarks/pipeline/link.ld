OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
  . = 0x80000000;
  .text : { KEEP(*(.text.start)) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) *(.sdata .sdata.*) }
  . = ALIGN(16);
  .bss (NOLOAD) : { __bss_start = .; *(.bss .bss.*) *(.sbss .sbss.*) . = ALIGN(16); __bss_end = .; }
  . = ALIGN(16);
  . += 16384;
  __stack_top = .;
  /DISCARD/ : { *(.eh_frame) *(.comment) }
}
