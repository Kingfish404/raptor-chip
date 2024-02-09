#ifndef NPC_H__
#define NPC_H__

#include <klib-macros.h>
#include <riscv/riscv.h>

#define UART16550_ADDR 0x10000000

// #define KBD_ADDR (DEVICE_BASE + 0x0011000)
// #define RTC_ADDR (DEVICE_BASE + 0x0000048)
// #define VGACTL_ADDR (DEVICE_BASE + 0x0000100)
// #define AUDIO_ADDR (DEVICE_BASE + 0x0000200)
// #define DISK_ADDR (DEVICE_BASE + 0x0000300)
// #define FB_ADDR (MMIO_BASE + 0x1000000)
// #define AUDIO_SBUF_ADDR (MMIO_BASE + 0x1200000)

typedef uintptr_t PTE;

#define PGSIZE 4096

#endif // NPC_H__