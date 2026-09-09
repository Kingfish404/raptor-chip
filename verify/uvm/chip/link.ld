OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
  . = 0x20000000;
  .text : { *(.text.init) *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  .bss : { *(.bss*) }
}
