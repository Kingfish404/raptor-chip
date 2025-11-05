#ifndef NPC_H__
#define NPC_H__

#include <klib-macros.h>
#include <riscv/riscv.h>

#define DEVICE_BASE 0xa0000000

#define MMIO_BASE 0xa0000000

#define KBD_ADDR_ (DEVICE_BASE + 0x0000060)
#define VGACTL_ADDR (DEVICE_BASE + 0x0000100)
#define AUDIO_ADDR (DEVICE_BASE + 0x0000200)
#define DISK_ADDR (DEVICE_BASE + 0x0000300)
#define FB_ADDR__ (MMIO_BASE + 0x1000000)
#define AUDIO_SBUF_ADDR (MMIO_BASE + 0x1200000)

#define SERIAL_PORT (0x10000000)
#define RTC_ADDR_ (0x02000048)

extern char _pmem_start;
#define PMEM_SIZE (128 * 1024 * 1024)
#define PMEM_END ((uintptr_t)&_pmem_start + PMEM_SIZE)
#define NPC_PADDR_SPACE                                              \
    RANGE(&_pmem_start, PMEM_END),                                   \
        RANGE(FB_ADDR__, FB_ADDR__ + 0x200000),                      \
        RANGE(MMIO_BASE, MMIO_BASE + 0x1000), /* screen, keyboard */ \
        RANGE(SERIAL_PORT, SERIAL_PORT + 0x100),                     \
        RANGE(RTC_ADDR_, RTC_ADDR_ + 0x1000)

typedef uintptr_t PTE;

#define PGSIZE 4096

#endif // NPC_H__