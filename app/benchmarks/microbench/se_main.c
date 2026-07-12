#include <am.h>

#include <stdint.h>
#include <stdlib.h>

#define MICROBENCH_HEAP_BYTES (2 * 1024 * 1024)

static unsigned char microbench_heap[MICROBENCH_HEAP_BYTES]
    __attribute__((aligned(8)));

Area heap = {
  .start = microbench_heap,
  .end = microbench_heap + sizeof(microbench_heap),
};

extern int microbench_am_main(const char *args);

uint64_t microbench_se_uptime(void)
{
#if __riscv_xlen == 32
  uint32_t high_before;
  uint32_t low;
  uint32_t high_after;

  do {
    __asm__ volatile("rdcycleh %0" : "=r"(high_before));
    __asm__ volatile("rdcycle %0" : "=r"(low));
    __asm__ volatile("rdcycleh %0" : "=r"(high_after));
  } while (high_before != high_after);

  return (((uint64_t)high_before << 32) | low) / 1000;
#else
  uint64_t cycles;
  __asm__ volatile("rdcycle %0" : "=r"(cycles));
  return cycles / 1000;
#endif
}

void halt(int code)
{
  exit(code);
}

int main(int argc, char **argv)
{
  return microbench_am_main(argc > 1 ? argv[1] : "test");
}
