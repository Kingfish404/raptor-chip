#include <stdint.h>

static volatile unsigned seen;
static volatile uint8_t *const uart0 = (void *)0x10000000;
static volatile uint32_t *const claim = (void *)0x0c200004;

static void __attribute__((interrupt("machine"), aligned(4))) trap(void) {
  uint32_t cause;
  asm volatile("csrr %0, mcause" : "=r"(cause));
  unsigned source = *claim;
  uart0[1] = 0;
  if (cause == 0x8000000b && source == 2)
    seen = 1;
  else
    seen = 2;
  *claim = source;
  asm volatile("csrc mstatus, %0" ::"r"(0x80));
}

int main(void) {
  *(volatile uint32_t *)0x0c000008 = 1;
  *(volatile uint32_t *)0x0c002000 = 4;
  *(volatile uint32_t *)0x0c200000 = 0;
  asm volatile("csrw mtvec, %0" ::"r"(trap));
  uart0[3] = 3;
  uart0[1] = 2; /* Real UART0 THRE interrupt, PLIC source 2. */
  asm volatile("fence iorw, iorw" ::: "memory");
  asm volatile("csrw mie, %0; csrsi mstatus, 8" ::"r"(0x800));
  for (volatile unsigned wait = 0; wait < 100000 && !seen; ++wait) {
  }
  asm volatile("csrci mstatus, 8; csrw mie, zero");
  uart0[1] = 0;
  return seen != 1;
}
