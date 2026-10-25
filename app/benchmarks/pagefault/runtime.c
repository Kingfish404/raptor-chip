#define UART_BASE 0x10000000UL
#define RAPT_RUNTIME_HALT_PRINT_STATUS 1
#define RAPT_RUNTIME_FINISHER_BASE 0x100000UL
#include "../../lib/runtime/runtime.c"

void report(unsigned long cold, unsigned long pages, unsigned long hot,
            unsigned long faults) {
  printf("PAGEFAULT demand pages=64 cycles=%lu faults=%lu\n", cold, faults);
  printf("PAGEFAULT resident pages=64 accesses=4096 cycles=%lu\n", pages);
  printf("PAGEFAULT hot pages=8 accesses=4096 cycles=%lu\n", hot);
  _litex_halt(0);
}

void test_failed(void) {
  printf("PAGEFAULT validation failed\n");
  _litex_halt(1);
}
