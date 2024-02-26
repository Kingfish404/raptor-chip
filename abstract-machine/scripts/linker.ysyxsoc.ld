PHDRS { text PT_LOAD; data PT_LOAD; }

MEMORY {
  mrom : ORIGIN = 0x20000000, LENGTH = 4K
  sram : ORIGIN = 0x0f000000, LENGTH = 8K
}

SECTIONS {
  /* _pmem_start and _entry_offset are defined in LDFLAGS */
  . = _pmem_start + _entry_offset;
  . = ORIGIN(mrom);
  .text : 
    {
      *(entry)
      *(.text*)
      text_end = .;
    } > mrom AT> mrom : text
  etext = .;
  _etext = .;
  .rodata : 
    {
      *(.rodata*)
      rodata_end = .;
    } > mrom AT> mrom
  .data : ALIGN(0x1000)
    {
      _data_start = .;
      *(.data)
      _data_end = .;
    } > sram AT> mrom : data
  _data_load_start = LOADADDR(.data);
  edata = .;
  _data = .;
  .bss : ALIGN(0x1000)
    {
      _bss_start = .;
      *(.bss*)
      *(.sbss*)
      *(.scommon)
    } > sram AT> mrom : data
  _stack_top = ALIGN(0x1000);
  . = _stack_top + 0x8000;
  _stack_pointer = .;
  end = .;
  _end = .;
  _heap_start = ALIGN(0x1000);
}