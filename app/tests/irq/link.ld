/* app/tests/irq/link.ld: bare-metal layout for nsim IRQ tests.
 *
 * Image is loaded by nsim into MBASE = 0x80000000 via the positional
 * IMG argument. _start lives at the very beginning so the MROM jumper
 * (rom.c) lands directly on it.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  ram (rwx) : ORIGIN = 0x80000000, LENGTH = 16M
}

SECTIONS
{
  . = ORIGIN(ram);

  .text : {
    KEEP(*(.text.entry))
    *(.text*)
    *(.rodata*)
    *(.srodata*)
  } > ram

  . = ALIGN(16);
  .data : {
    *(.data*)
    *(.sdata*)
  } > ram

  . = ALIGN(16);
  .bss : {
    _bss_start = .;
    *(.bss*)
    *(.sbss*)
    *(COMMON)
    _bss_end = .;
  } > ram

  . = ALIGN(16);
  . = . + 0x4000;          /* 16 KB stack */
  _stack_top = .;
}
