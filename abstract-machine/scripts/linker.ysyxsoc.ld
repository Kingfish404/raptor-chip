PHDRS { entry PT_LOAD; text PT_LOAD; data PT_LOAD; bss PT_LOAD; }

MEMORY {
  mrom  : ORIGIN = 0x20000000, LENGTH = 4K
  flash : ORIGIN = 0x30000000, LENGTH = 10M
  sram  : ORIGIN = 0x0f000000, LENGTH = 8K
}

SECTIONS {
  /* _pmem_start and _entry_offset are defined in LDFLAGS */
  . = _pmem_start + _entry_offset;
  . = ORIGIN(flash);
  .entry : {
     *(.entry) 
     } > flash AT > flash : entry
  .text : 
    {
      _text_start = .;
      *(.text*)
      text_end = .;
    } > sram AT> flash : text
  _text_size = SIZEOF(.text);
  etext = .;
  _etext = .;
  .rodata :
    {
      _rodata_start = .;
      *(.rodata*)
      rodata_end = .;
    } > sram AT> flash
  _rodata_size = SIZEOF(.rodata);
  .data :
    {
      _data_start = .;
      *(.data*)
      *(.sdata*)
    } > sram AT> flash : data
  _data_size = SIZEOF(.data);
  _data_end = ADDR(.bss);
  _data_load_start = LOADADDR(.data);
  edata = .;
  _data = .;
  .bss :
    {
      _bss_start = .;
      *(.bss*)
      *(.sbss*)
      *(.scommon)
    } > sram AT> flash : bss
  _stack_top = ALIGN(0x1000);
  . = _stack_top + 0x8000;
  _stack_pointer = .;
  end = .;
  _end = .;
  _heap_start = ALIGN(0x1000);
}