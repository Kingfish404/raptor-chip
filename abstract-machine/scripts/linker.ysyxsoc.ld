PHDRS { 
  first_boot PT_LOAD;
  second_boot PT_LOAD;
  text PT_LOAD;
  data PT_LOAD;
  bss PT_LOAD;
}

MEMORY {
  mrom  : ORIGIN = 0x20000000, LENGTH = 4K
  flash : ORIGIN = 0x30000000, LENGTH = 10M
  sram  : ORIGIN = 0x0f000000, LENGTH = 8K
  psram  : ORIGIN = 0x80000000, LENGTH = 4M
}

SECTIONS {
  /* _pmem_start and _entry_offset are defined in LDFLAGS */
  . = _pmem_start + _entry_offset;
  . = ORIGIN(flash);
  .first_boot_text :
    {
      *(entry)
      *(.first_boot*)
    } > flash AT> flash : first_boot
  .second_boot_text : 
    {
      _second_boot_text_start = .;
      *(.second_boot*)
    } > psram AT> flash : second_boot
  _second_boot_text_end = ADDR(.text);
  _second_boot_text_load_start = LOADADDR(.second_boot_text);
  .text :
    {
      _text_start = .;
      *(.text*)
    } > psram AT> flash : text
  _text_end = ADDR(.rodata);
  _text_load_start = LOADADDR(.text);
  etext = .;
  _etext = .;
  .rodata :
    {
      _rodata_start = .;
      *(.rodata*)
      rodata_end = .;
    } > psram AT> flash
  _rodata_end = ADDR(.data);
  _rodata_load_start = LOADADDR(.rodata);
  .data :
    {
    _data_start = .;
      *(.data*)
      *(.sdata*)

    __fsymtab_start = .;
    KEEP(*(FSymTab))
    __fsymtab_end = .;
    . = ALIGN(8);
    __vsymtab_start = .;
    KEEP(*(VSymTab))
    __vsymtab_end = .;
    . = ALIGN(8);

    . = ALIGN(8);
    __rt_init_start = .;
    KEEP(*(SORT(.rti_fn*)))
    __rt_init_end = .;
    . = ALIGN(8);

    __rt_utest_tc_tab_start = .;
    KEEP(*(UtestTcTab))
    __rt_utest_tc_tab_end = .;
      
    } > psram AT> flash : data
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
    } > psram AT> flash : bss
  _stack_top = ALIGN(0x1000);
  . = _stack_top + 0x8000;
  _stack_pointer = .;
  end = .;
  _end = .;
  _heap_start = ALIGN(0x1000);
  _heap_end = ORIGIN(psram) + LENGTH(psram);
}