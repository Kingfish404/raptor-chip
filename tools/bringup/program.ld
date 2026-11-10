ENTRY(_start)
SECTIONS {
  . = 0x80000000;
  .text : { *(entry) *(.text*) }
  .rodata : { *(.rodata*) *(.srodata*) }
  .data : { *(.data*) *(.sdata*) }
  . = ALIGN(4);
  _bss_start = .;
  .bss : { *(.bss*) *(.sbss*) *(COMMON) }
  . = ALIGN(4);
  _bss_end = .;
  _heap_start = ALIGN(4096);
  _stack_pointer = 0x80080000;
  ASSERT(_bss_end < 0x80070000, "program exceeds bring-up RAM")
}
