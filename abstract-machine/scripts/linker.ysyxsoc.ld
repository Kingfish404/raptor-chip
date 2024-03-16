PHDRS { flash_text PT_LOAD; text PT_LOAD; data PT_LOAD; bss PT_LOAD; }

MEMORY {
  mrom  : ORIGIN = 0x20000000, LENGTH = 4K
  flash : ORIGIN = 0x30000000, LENGTH = 10M
  sram  : ORIGIN = 0x0f000000, LENGTH = 8K
  pmem  : ORIGIN = 0x80000000, LENGTH = 4M
}

SECTIONS {
  /* _pmem_start and _entry_offset are defined in LDFLAGS */
  . = _pmem_start + _entry_offset;
  . = ORIGIN(flash);
  .flash_text : 
    {
      _flash_text_start = .;
      *(entry)
      *(.flash_text*)
    } > flash : flash_text
  .text :
    {
      _text_start = .;
      *(.text*)
    } > flash AT> flash : text
  _text_end = ADDR(.rodata);
  _text_load_start = LOADADDR(.text);
  etext = .;
  _etext = .;
  .rodata :
    {
      _rodata_start = .;
      *(.rodata*)
      rodata_end = .;
    } > flash AT> flash
  _rodata_end = ADDR(.data);
  _rodata_load_start = LOADADDR(.rodata);
  .data :
    {
      _data_start = .;
      *(.data*)
      *(.sdata*)
    } > sram AT> flash : data
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