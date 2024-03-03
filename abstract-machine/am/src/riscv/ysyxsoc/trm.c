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

#define COM1 UART16550_BASE

void init_uart(void)
{

  outb(COM1 + 3, 0x80); // Unlock divisor
  outb(COM1 + 0, 115200 / 9600);
  outb(COM1 + 1, 0);
  outb(COM1 + 3, 0x03); // Lock divisor, 8 data bits.
  // outb(0x0f001fec, 0x0);
  // asm volatile("ebreak");

  // outb(COM1 + 4, 0);
  // outb(COM1 + 1, 0x01); // Enable receive interrupts.

  // uint8_t lcr = inb(UART16550_LCR);
  // lcr |= 0x80;
  // outb(UART16550_LCR, lcr);
  // outb(UART16550_DL2, 0x0);
  // outb(UART16550_DL1, 0x1);
  // lcr &= 0x7f;
  // outb(UART16550_LCR, lcr);
}

void _trm_init()
{
  copy_data();
  init_uart();
  int ret = main(mainargs);
  halt(ret);
}
