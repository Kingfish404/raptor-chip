OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
  . = 0x20000000;
  .text : { KEEP(*(.text.start)) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) }
  .bss : { *(.bss .bss.*) }
  ASSERT(. <= 0x20001000, "boot ROM exceeds 4 KiB")
  /DISCARD/ : { *(.comment) *(.eh_frame) }
}
