#ifndef RISCV_H__
#define RISCV_H__

#include <stdint.h>

static inline uint8_t inb(uintptr_t addr) { return *(volatile uint8_t *)addr; }
static inline uint16_t inw(uintptr_t addr) { return *(volatile uint16_t *)addr; }
static inline uint32_t inl(uintptr_t addr) { return *(volatile uint32_t *)addr; }

static inline void outb(uintptr_t addr, uint8_t data) { *(volatile uint8_t *)addr = data; }
static inline void outw(uintptr_t addr, uint16_t data) { *(volatile uint16_t *)addr = data; }
static inline void outl(uintptr_t addr, uint32_t data) { *(volatile uint32_t *)addr = data; }

#define MSTATUS_MXR (1 << 19)
#define MSTATUS_SUM (1 << 18)

#if __riscv_xlen == 64
#define MSTATUS_SXL (2ull << 34)
#define MSTATUS_UXL (2ull << 32)
#else
#define MSTATUS_SXL 0
#define MSTATUS_UXL 0
#endif

#endif
