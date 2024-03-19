#ifndef __YSYXSOC_H__
#define __YSYXSOC_H__

#include <klib-macros.h>
#include <riscv/riscv.h>

#define UART16550_BASE 0x10000000

#define UART16550_TX UART16550_BASE + 0x00
#define UART16550_LCR UART16550_BASE + 0x03
#define UART16550_DL1 UART16550_BASE + 0x00
#define UART16550_DL2 UART16550_BASE + 0x01
#define UART16550_LSR UART16550_BASE + 0x05

#define RTC_ADDR 0xa0000048

typedef uintptr_t PTE;

#define PGSIZE 4096

#endif // __YSYXSOC_H__
