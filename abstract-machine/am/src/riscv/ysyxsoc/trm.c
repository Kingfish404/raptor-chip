#include <am.h>
#include <ysyxsoc.h>
#include <klib-macros.h>
#include <string.h>
#include <stdio.h>

extern char _heap_start;
int main(const char *args);

extern char _pmem_start;

extern char _text_start[];
extern char _text_end[];
extern char _text_load_start[];

extern char _rodata_start[];
extern char _rodata_end[];
extern char _rodata_load_start[];

extern char _data_start[];
extern char _data_end[];
extern char _data_load_start[];

#define PMEM_SIZE (128 * 1024 * 1024)
#define PMEM_END ((uintptr_t) & _pmem_start + PMEM_SIZE)

Area heap = RANGE(&_heap_start, PMEM_END);
#ifndef MAINARGS
#define MAINARGS ""
#endif
static const char mainargs[] = MAINARGS;

void putch(char ch)
{
  while ((inb(UART16550_LSR) & (0x1 << 5)) == 0x0)
    ;
  outb(UART16550_TX, ch);
}

void halt(int code)
{
  asm volatile("ebreak");
  while (1)
    ;
}

__attribute__((section(".flash_text"))) void bootloader(void)
{
  if ((size_t)_text_start != 0 && (size_t)_text_start != (size_t)_text_load_start)
  {
    size_t text_size = _text_end - _text_start;
    for (size_t i = 0; i < text_size; i++)
    {
      _text_start[i] = _text_load_start[i];
    }
  }
  if ((size_t)_rodata_start != 0 && (size_t)_rodata_start != (size_t)_rodata_load_start)
  {
    size_t rodata_size = _rodata_end - _rodata_start;
    memcpy(_rodata_start, _rodata_load_start, (size_t)rodata_size);
  }
  if ((size_t)_data_start != 0 && (size_t)_data_start != (size_t)_data_load_start)
  {
    size_t data_size = _data_end - _data_start;
    memcpy(_data_start, _data_load_start, (size_t)data_size);
  }
}

void init_uart(void)
{
  outb(UART16550_LCR, 0x80);
  outb(UART16550_DL2, 0);
  outb(UART16550_DL1, 1);
  outb(UART16550_LCR, 0x03);
}

__attribute__((section(".flash_text"))) void _trm_init()
{
  bootloader();
  init_uart();
  uint32_t mvendorid, marchid;
  asm volatile(
      "csrr %0, mvendorid\n\t"
      "csrr %1, marchid\n\t"
      : "=r"(mvendorid), "=r"(marchid) :);
  printf("mvendorid: 0x%lx, marchid: %ld\n", mvendorid, marchid);

  int ret = main(mainargs);
  halt(ret);
}
