OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
  . = 0x80000000;
  .text : { KEEP(*(.text.start)) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) }
  .bss : { *(.bss .bss.*) }
  ASSERT(. <= 0x80004000, "payload overlaps March test region")
  /DISCARD/ : { *(.comment) *(.eh_frame) }
}
