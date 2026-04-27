/* Linker script for Raptor Chip RISCOF DUT tests.
 * Maps the whole image at the reset vector (0x80000000, main RAM) and keeps
 * the signature region word-aligned so that the --sig dump reads valid data.
 */
OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .text : { *(.text) *(.text.*) }
  . = ALIGN(0x1000);
  .data : { *(.data) *(.data.*) }
  .data.string : { *(.data.string) }
  . = ALIGN(0x10);
  .bss : { *(.bss) *(.sbss) }
  . = ALIGN(0x10);
  _end = .;
}
