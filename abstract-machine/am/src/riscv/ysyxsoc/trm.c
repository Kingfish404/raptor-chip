#include <am.h>
#include <ysyxsoc.h>
#include <klib-macros.h>
#include <string.h>

extern char _heap_start;
int main(const char *args);

extern char _pmem_start;

extern char data_start[];
extern char data_size[];
extern char data_load_start[];

extern char _bss_start[];
extern char _bss_size[];
extern char _bss_load_start[];

#define PMEM_SIZE (128 * 1024 * 1024)
#define PMEM_END ((uintptr_t) & _pmem_start + PMEM_SIZE)

Area heap = RANGE(&_heap_start, PMEM_END);
#ifndef MAINARGS
#define MAINARGS ""
#endif
static const char mainargs[] = MAINARGS;

void putch(char ch)
{
  outb(SERIAL_PORT, ch);
}

void halt(int code)
{
  asm volatile("ebreak");
  while (1)
    ;
}

void copy_data(void)
{
  if (data_start != data_load_start)
  {
    putch('D');
    putch('\n');
    memcpy(data_start, data_load_start, (size_t)data_size);
  }
  if (_bss_start != _bss_load_start)
  {
    putch('B');
    putch('\n');
    memcpy(_bss_start, _bss_load_start, (size_t)_bss_size);
  }
}

void _trm_init()
{
  copy_data();
  int ret = main(mainargs);
  halt(ret);
}
