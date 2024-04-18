PHDRS { 
  first_boot PT_LOAD;
  second_boot PT_LOAD;
  rodata PT_LOAD;
  text PT_LOAD;
  data PT_LOAD;
  bss PT_LOAD;
}

MEMORY {
  mrom  : ORIGIN = 0x20000000, LENGTH = 4K
  flash : ORIGIN = 0x30000000, LENGTH = 10M
  sram  : ORIGIN = 0x0f000000, LENGTH = 8K
  psram : ORIGIN = 0x80000000, LENGTH = 4M
  sdram : ORIGIN = 0xa0000000, LENGTH = 8M
}

SECTIONS {
  /* _pmem_start and _entry_offset are defined in LDFLAGS */
  . = ORIGIN(flash);
  .first_boot :
    {
      *(entry)
      *(.first_boot*)
    } > flash AT> flash : first_boot
  . = _pmem_start + _entry_offset;
  .second_boot :
    {
      _second_boot_start = .;
      *(.second_boot*)
    } > sdram AT> flash : second_boot
  _second_boot_end = ADDR(.text);
  _second_boot_load_start = LOADADDR(.second_boot);
  .text :
    {
      _text_start = .;
      *(.text*)
    } > sdram AT> flash : text
  _text_end = ADDR(.rodata);
  _text_load_start = LOADADDR(.text);
  etext = .;
  _etext = .;
  .rodata :
    {
      _rodata_start = .;
      *(.rodata*)
      *(.srodata*)

      rodata_end = .;
    } > sdram AT> flash : rodata
  _rodata_end = ADDR(.data);
  _rodata_load_start = LOADADDR(.rodata);
  .data :
    {
    _data_start = .;
      *(.data*)
      *(.sdata*)

    /* for rt-thread */
    /* __fsymtab_start = .;
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
    KEEP(*(UtestTcTab)) */

    . = ALIGN(8);
    __am_apps_data_start = .;
    *(__am_apps.data*)
    *(__am_apps.sdata*)
    __am_apps_data_end = .;
    . = ALIGN(8);
    __rt_utest_tc_tab_end = .;
    /* end for rt-thread */
      
    } > sdram AT> flash : data
  _data_end = ADDR(.bss);
  _data_load_start = LOADADDR(.data);
  .data.extra : {
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
  } > sdram AT> flash : data
  .bss :
    {
      _bss_start = .;
      *(.bss*)
      *(.sbss*)
      *(.scommon)
    } > sdram AT> flash : bss
   .bss.extra : {
    . = ALIGN(8);
    __am_apps_bss_start = .;
    *(__am_apps.bss*)
    *(__am_apps.sbss*)
    *(__am_apps.scommon*)
    __am_apps_bss_end = .;
    . = ALIGN(8);
  } > sdram AT> flash : bss 
  _stack_top = ALIGN(0x1000);
  . = _stack_top + 0x8000;
  _stack_pointer = .;
  end = .;
  _end = .;
  _heap_start = ALIGN(0x1000);
  _heap_end = ORIGIN(psram) + LENGTH(psram);
}