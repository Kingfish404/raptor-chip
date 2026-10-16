#include <stdint.h>
#include <stddef.h>

_Alignas(4096) unsigned char nemu_test_stacks[HARTS][4096];
static volatile unsigned barrier_count, barrier_generation;
static volatile unsigned irq_count;
static _Alignas(64) volatile unsigned char output[HARTS][512];
static _Alignas(64) volatile struct {
  uint64_t address;
  uint32_t length;
  uint16_t flags, next;
} descriptors[8];
static _Alignas(64) volatile uint16_t available[12];
static _Alignas(64) volatile uint32_t used[20];

static void check(int condition)
{
  if (condition) return;
  *(volatile uint32_t *)(uintptr_t)0x100000 = 0x3333;
  for (;;) __asm__ volatile ("wfi");
}

static void reg_write(unsigned offset, uint32_t value)
{
  *(volatile uint32_t *)(uintptr_t)(0x10003000 + offset) = value;
}

static uint32_t reg_read(unsigned offset)
{
  return *(volatile uint32_t *)(uintptr_t)(0x10003000 + offset);
}

static void barrier(void)
{
  unsigned hart;
  __asm__ volatile ("csrr %0, mhartid" : "=r"(hart));
  volatile uint32_t *pending = (volatile uint32_t *)(uintptr_t)(0x02000000 + 4 * hart);
  *pending = 0;
  unsigned generation = __atomic_load_n(&barrier_generation, __ATOMIC_SEQ_CST);
  if (__atomic_add_fetch(&barrier_count, 1, __ATOMIC_SEQ_CST) == HARTS) {
    __atomic_store_n(&barrier_count, 0, __ATOMIC_SEQ_CST);
    __atomic_add_fetch(&barrier_generation, 1, __ATOMIC_SEQ_CST);
    for (unsigned target = 0; target < HARTS; target++)
      *(volatile uint32_t *)(uintptr_t)(0x02000000 + 4 * target) = 1;
  } else while (__atomic_load_n(&barrier_generation, __ATOMIC_SEQ_CST) == generation) {
    *pending = 0;
    if (__atomic_load_n(&barrier_generation, __ATOMIC_SEQ_CST) == generation)
      __asm__ volatile ("wfi" ::: "memory");
  }
  *pending = 0;
}

static void setup(unsigned count, unsigned length)
{
  reg_write(0x70, 0);
  for (unsigned index = 0; index < 12; index++) available[index] = 0;
  for (unsigned index = 0; index < 20; index++) used[index] = 0;
  for (unsigned index = 0; index < count; index++) {
    descriptors[index].address = (uintptr_t)output[index];
    descriptors[index].length = length;
    descriptors[index].flags = 2;
    descriptors[index].next = 0;
    available[2 + index] = index;
    for (unsigned byte = 0; byte < 512; byte++) output[index][byte] = 0xa5;
  }
  available[1] = count;
  reg_write(0x38, 8);
  reg_write(0x80, (uintptr_t)descriptors);
  reg_write(0x90, (uintptr_t)available);
  reg_write(0xa0, (uintptr_t)used);
  reg_write(0x44, 3);
  reg_write(0x70, 4);
  __asm__ volatile ("fence rw, rw" ::: "memory");
}

static unsigned reserved_load(volatile unsigned char *address)
{
  unsigned value;
  __asm__ volatile ("lr.w %0, (%1)" : "=r"(value) : "r"(address) : "memory");
  return value;
}

static unsigned conditional_store(volatile unsigned char *address, unsigned value)
{
  unsigned failed;
  __asm__ volatile ("sc.w %0, %2, (%1)" : "=&r"(failed) : "r"(address), "r"(value) : "memory");
  return failed;
}

static void register_tests(void)
{
  check(reg_read(0) == 0x74726976 && reg_read(4) == 2 && reg_read(8) == 4);
  check(reg_read(12) == 0x554d4551 && reg_read(0x34) == 8);
  reg_write(0x14, 1);
  check(reg_read(0x10) == 1);
  reg_write(0x14, 2);
  check(reg_read(0x10) == 0);
  reg_write(0x24, 3);
  reg_write(0x20, 0x12345678);
  reg_write(0x30, 1);
  check(reg_read(0x34) == 0);
  reg_write(0xffc, 0x12345678);
  check(reg_read(0xffc) == 0);
  reg_write(0x70, 0);
  reg_write(0x50, 0);
  check(reg_read(0x60) == 0);
}

static void failure_tests(void)
{
  setup(1, 0);
  reg_write(0x94, 1);
  reg_write(0x50, 0);
  check(used[0] == 0 && reg_read(0x60) == 0);
  setup(1, 0);
  reg_write(0x90, 0xbffffffc);
  *(volatile uint16_t *)(uintptr_t)0xbffffffe = 1;
  reg_write(0x50, 0);
  check(used[0] == 0 && reg_read(0x60) == 0);
  setup(1, 0);
  reg_write(0x84, 1);
  reg_write(0x50, 0);
  check(used[0] == 0x10000 && used[2] == 0 && reg_read(0x60) == 1);
  setup(1, 0);
  reg_write(0xa4, 1);
  reg_write(0x50, 0);
  check(used[0] == 0 && reg_read(0x60) == 0);
  setup(1, 0);
  reg_write(0xa0, 0xbffffffc);
  *(volatile uint16_t *)(uintptr_t)0xbffffffe = 0;
  reg_write(0x50, 0);
  check(*(volatile uint16_t *)(uintptr_t)0xbffffffe == 0 && reg_read(0x60) == 0);
  setup(1, 0);
  available[2] = 8;
  reg_write(0x50, 0);
  check(used[0] == 0 && reg_read(0x60) == 0);
  setup(1, 0);
  descriptors[0].flags = 0;
  reg_write(0x50, 0);
  check(used[0] == 0x10000 && used[2] == 0);
}

static void rng_interrupt(void) __attribute__((interrupt("machine"), aligned(4)));

static void rng_interrupt(void)
{
  uintptr_t cause;
  __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
  check(cause == ((uintptr_t)1 << (__riscv_xlen - 1) | 11));
  check(*(volatile uint32_t *)(uintptr_t)0x0c200004 == 3);
  reg_write(0x64, 1);
  *(volatile uint32_t *)(uintptr_t)0x0c200004 = 3;
  irq_count++;
  __asm__ volatile ("csrw mie, zero" ::: "memory");
}

static void interrupt_test(void)
{
  setup(1, 0);
  reg_write(0x50, 0);
  __asm__ volatile ("csrw mtvec, %0\ncsrw mie, %1\ncsrs mstatus, %2"
                    :: "r"((uintptr_t)rng_interrupt), "r"(0x800), "r"(8) : "memory");
  while (!irq_count) __asm__ volatile ("wfi" ::: "memory");
  __asm__ volatile ("csrc mstatus, %0\ncsrw mie, %0" :: "r"(8) : "memory");
  check(irq_count == 1 && reg_read(0x60) == 0);
}

void nemu_test_main(unsigned hart)
{
  __asm__ volatile ("csrw mstatus, zero\ncsrw mie, %0" :: "r"(8) : "memory");
#ifdef BAD_WIDTH
  if (!hart) (void)*(volatile uint8_t *)(uintptr_t)0x10003000;
#endif
  if (!hart) {
    register_tests();
    setup(HARTS, 300);
    *(volatile uint32_t *)(uintptr_t)0x0c00000c = 1;
    *(volatile uint32_t *)(uintptr_t)0x0c002000 = 8;
  }
  barrier();
  unsigned original = reserved_load(output[hart]);
  barrier();
  reg_write(0x50, 0);
  barrier();
#ifdef RNG_EOF
  unsigned length = hart ? 0 : 256;
#else
  unsigned length = 300;
#endif
  check(conditional_store(output[hart], original) == (length != 0));
  check(used[0] == HARTS * 0x10000 && used[1 + 2 * hart] == hart && used[2 + 2 * hart] == length);
  for (unsigned index = 0; index < 512; index++)
    check(output[hart][index] == (index < length ? (unsigned char)(300 * hart + index) : 0xa5));
  original = reserved_load(output[hart]);
  reg_write(0x50, 0);
  check(conditional_store(output[hart], original) == 0);
  barrier();
  if (!hart) {
    check(reg_read(0x60) == 1);
    check(*(volatile uint32_t *)(uintptr_t)0x0c200004 == 3);
    *(volatile uint32_t *)(uintptr_t)0x0c200004 = 3;
    reg_write(0x64, 1);
    check(reg_read(0x60) == 0);
    failure_tests();
#ifndef RNG_EOF
    setup(1, 7);
    descriptors[0].flags = 3;
    descriptors[0].next = 1;
    descriptors[1].address = (uintptr_t)output[0] + 7;
    descriptors[1].length = 9;
    descriptors[1].flags = 2;
    descriptors[1].next = 0;
    reg_write(0x50, 0);
    check(used[2] == 16);
    for (unsigned index = 0; index < 16; index++)
      check(output[0][index] == (unsigned char)(HARTS * 300 + index));
    setup(1, 7);
    descriptors[0].flags = 3;
    descriptors[0].next = 0;
    reg_write(0x38, 9);
    reg_write(0x50, 0);
    check(used[2] == 56);
    setup(1, 0);
    used[0] = 0xffff0000;
    reg_write(0x50, 0);
    check(used[0] == 0 && used[15] == 0 && used[16] == 0);
    setup(1, 8);
    descriptors[0].address |= UINT64_C(1) << 32;
    reg_write(0x50, 0);
    check(used[0] == 0x10000 && used[2] == 0);
    for (unsigned index = 0; index < 8; index++) check(output[0][index] == 0xa5);
#endif
    interrupt_test();
    reg_write(0x70, 0);
    check(reg_read(0x44) == 0 && reg_read(0x60) == 0);
  }
  *(volatile uint8_t *)(uintptr_t)0x10000000 = '0' + hart;
  barrier();
  if (!hart) *(volatile uint32_t *)(uintptr_t)0x100000 = 0x5555;
  for (;;) __asm__ volatile ("wfi");
}
