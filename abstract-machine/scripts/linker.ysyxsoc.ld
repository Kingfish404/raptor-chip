
MEMORY {
  mrom : ORIGIN = 0x20000000, LENGTH = 4K
  sram : ORIGIN = 0x0f000000, LENGTH = 8K
}

REGION_ALIAS("REGION_TEXT", mrom);
REGION_ALIAS("REGION_RODATA", mrom);
REGION_ALIAS("REGION_DATA", sram);
REGION_ALIAS("REGION_BSS", sram);

SECTIONS {
  /* _pmem_start and _entry_offset are defined in LDFLAGS */
  . = _pmem_start + _entry_offset;
  . = ORIGIN(mrom);
.text :
    {
    *(.text)
    } > REGION_TEXT
.rodata :
    {
    *(.rodata)
    rodata_end = .;
    } > REGION_RODATA
.data : AT (rodata_end)
    {
    data_start = .;
    *(.data)
    } > REGION_DATA
data_size = SIZEOF(.data);
data_load_start = LOADADDR(.data);
.bss :
    {
    *(.bss)
    } > REGION_BSS
  etext = .;
  _etext = .;
  data_size = SIZEOF(.data);
  data_load_start = LOADADDR(.data);
  edata = .;
  _data = .;
  _stack_top = ALIGN(0x1000);
  . = _stack_top + 0x8000;
  _stack_pointer = .;
  end = .;
  _end = .;
  _heap_start = ALIGN(0x1000);
}