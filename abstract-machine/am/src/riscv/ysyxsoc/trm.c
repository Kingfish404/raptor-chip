#include <am.h>
#include <ysyxsoc.h>
#include <klib-macros.h>
#include <string.h>

extern char _heap_start;
int main(const char *args);

extern char _pmem_start;

extern char *_data_start;
extern char *_data_size;
extern char *_data_load_start;

extern char *_bss_start;
extern char *_bss_size;
extern char *_bss_load_start;

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
  if (_data_start != _data_load_start)
  {
    memcpy(_data_start, _data_load_start, (size_t)_data_size);
  }
    memcpy(_data_start, _data_load_start, (size_t)_data_size);

}

void _trm_init()
{
  // copy_data();
    memcpy(_data_start, _data_load_start, (size_t)_data_size);

  int ret = main(mainargs);
  halt(ret);
}
