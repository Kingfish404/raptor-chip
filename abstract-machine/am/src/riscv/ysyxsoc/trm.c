#include <am.h>
#include <ysyxsoc.h>
#include <klib-macros.h>
#include <string.h>

extern char _heap_start;
int main(const char *args);

extern char _pmem_start;

extern char _data_start[];
extern char _data_end[];
extern char _data_size[];
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
  while ((inb(UART16550_LSR) & 0x6) == 0x0)
    ;
  outb(UART16550_TX, ch);
}

void halt(int code)
{
  asm volatile("ebreak");
  while (1)
    ;
}

void copy_data(void)
{
  if (_data_start != _data_load_start)
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

void _trm_init()
{
  init_uart();
  copy_data();
  int ret = main(mainargs);
  halt(ret);
}
