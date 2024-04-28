#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include <am.h>
#include <ysyxsoc.h>
#include <klib-macros.h>

extern char _heap_start;
int main(const char *args);
void _second_stage_bootloader();
void _trm_init();
bool ioe_init();

extern char _pmem_start;

extern char _second_boot_start[];
extern char _second_boot_end[];
extern char _second_boot_load_start[];

extern char _text_start[];
extern char _text_end[];
extern char _text_load_start[];

extern char _rodata_start[];
extern char _rodata_end[];
extern char _rodata_load_start[];

extern char _data_start[];
extern char _data_end[];
extern char _data_load_start[];

#define PMEM_SIZE (4 * 1024 * 1024)
#define PMEM_END ((uintptr_t) & _pmem_start + PMEM_SIZE)

Area heap = RANGE(&_heap_start, PMEM_END);
#ifndef MAINARGS
#define MAINARGS ""
#endif
static const char mainargs[] = MAINARGS;

void init_uart(void)
{
  outb(UART16550_LCR, 0x80);
  outb(UART16550_DL2, 0);
  outb(UART16550_DL1, 1);
  outb(UART16550_LCR, 0x03);
}

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

__attribute__((section(".first_boot"))) void _first_stage_bootloader(void)
{
  volatile uint8_t *p = (uint8_t *)0x80010000;
  for (int i = 0; i < 1024; i++)
  {
    *p = i;
    i == *p;
  }
  
  asm volatile("ebreak");
  return;

  if ((size_t)_second_boot_start != (size_t)_second_boot_load_start)
  {
    size_t text_size = _second_boot_end - _second_boot_start;
    size_t text_size_u64_fix = text_size / 8;
    for (size_t i = 0; i < text_size_u64_fix; i++)
    {
      ((uint64_t *)_second_boot_start)[i] = ((uint64_t *)_second_boot_load_start)[i];
    }
    for (size_t i = text_size_u64_fix * 8; i < text_size; i++)
    // for (size_t i = 0; i < text_size; i++)
    {
      _second_boot_start[i] = _second_boot_load_start[i];
    }
  }
  _second_stage_bootloader();
}

size_t ssb_start_time, ssb_end_time;

__attribute__((section(".second_boot"))) void _second_stage_bootloader()
{
  ssb_start_time = *((uint32_t *)RTC_ADDR);
  if ((size_t)_text_start != (size_t)_text_load_start)
  {
    size_t text_size = _text_end - _text_start;
    size_t text_size_u64_fix = text_size / 8;
    for (size_t i = 0; i < text_size_u64_fix; i++)
    {
      ((uint64_t *)_text_start)[i] = ((uint64_t *)_text_load_start)[i];
    }
    for (size_t i = text_size_u64_fix * 8; i < text_size; i++)
    // for (size_t i = 0; i < text_size; i++)
    {
      _text_start[i] = _text_load_start[i];
    }
  }
  if ((size_t)_rodata_start != (size_t)_rodata_load_start)
  {
    size_t rodata_size = _rodata_end - _rodata_start;
    memcpy(_rodata_start, _rodata_load_start, (size_t)rodata_size);
  }
  if ((size_t)_data_start != (size_t)_data_load_start)
  {
    size_t data_size = _data_end - _data_start;
    memcpy(_data_start, _data_load_start, (size_t)data_size);
  }
  ssb_end_time = *((uint32_t *)RTC_ADDR);
  _trm_init();
}

void _trm_init()
{
  init_uart();
  printf("[%d] first stage boot loader done\n", ssb_start_time);
  printf("[%d|%d] second stage boot loader done\n", ssb_end_time, ssb_end_time - ssb_start_time);
  ioe_init();
  uint32_t mvendorid, marchid;
  asm volatile(
      "csrr %0, mvendorid\n\t"
      "csrr %1, marchid\n\t"
      : "=r"(mvendorid), "=r"(marchid) :);
  size_t ready_time = *((uint32_t *)RTC_ADDR);
  printf("[%d|%d] trm init, mvendorid: 0x%lx, marchid: %ld\n", ready_time, ready_time - ssb_end_time, mvendorid, marchid);

  int ret = main(mainargs);
  halt(ret);
}
