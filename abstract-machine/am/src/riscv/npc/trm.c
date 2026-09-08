#include <am.h>
#include <npc.h>
#include <klib-macros.h>

extern char _heap_start;
int main(const char *args);

extern char _pmem_start;
#define PMEM_SIZE (128 * 1024 * 1024)
#define PMEM_END ((uintptr_t)&_pmem_start + PMEM_SIZE)

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
  // EBREAK stops the simulator immediately. Complete pending UART/MMIO and
  // memory stores first, including beats held up by random AXI backpressure.
  asm volatile("fence iorw, iorw\n\tebreak" ::: "memory");
  while (1)
    ;
}

void _trm_init()
{
  asm volatile("fence");
  int ret = main(mainargs);
  halt(ret);
}
