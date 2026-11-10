ENTRY(_start)
MEMORY {
  code (rx) : ORIGIN = CODE_BASE, LENGTH = CODE_SIZE
  ram (rw) : ORIGIN = DATA_BASE, LENGTH = DATA_SIZE
}
SECTIONS {
  .text : { *(entry) *(.text*) } > code
  .rodata : { *(.rodata*) *(.srodata*) } > code
  .data : ALIGN(4) {
    _data_start = .;
    *(.data*) *(.sdata*)
    . = ALIGN(4);
    _data_end = .;
  } > ram AT> code
  _data_load = LOADADDR(.data);
  .bss (NOLOAD) : ALIGN(4) {
    _bss_start = .;
    *(.bss*) *(.sbss*) *(COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > ram
  _heap_start = _bss_end;
  _stack_pointer = 0x0f001e00;
  ASSERT(_bss_end <= 0x0f001600, "leave 2 KiB for stack and result storage")
  /DISCARD/ : { *(.comment) *(.eh_frame*) }
}
