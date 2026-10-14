#include <stdint.h>
#include <stddef.h>

_Alignas(4096) unsigned char nemu_block_stacks[HARTS][4096];
static volatile unsigned barrier_count, barrier_generation, irq_count;
typedef struct { uint64_t address; uint32_t length; uint16_t flags, next; } Descriptor;
typedef struct { uint32_t type, reserved; uint64_t sector; } Request;
typedef uint32_t BlockWord __attribute__((may_alias));
#ifdef BIG_REQUEST
#define DATA_SIZE 65568
#else
#define DATA_SIZE 512
#endif
static _Alignas(64) volatile Descriptor descriptors[16];
static _Alignas(64) volatile Request requests[HARTS];
static _Alignas(64) volatile uint16_t available[20];
static _Alignas(64) volatile uint32_t used[36];
static _Alignas(64) volatile unsigned char data[HARTS][DATA_SIZE];
static volatile unsigned char status[HARTS];

static void check(int condition)
{
  if (condition) return;
  *(volatile uint32_t *)(uintptr_t)0x100000 = 0x3333;
  for (;;) __asm__ volatile ("wfi");
}

static void write_reg(unsigned offset, uint32_t value)
{
  *(volatile uint32_t *)(uintptr_t)(0x10001000 + offset) = value;
}

static uint32_t read_reg(unsigned offset)
{
  return *(volatile uint32_t *)(uintptr_t)(0x10001000 + offset);
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

static void setup(unsigned count, unsigned type, unsigned sector)
{
  write_reg(0x70, 0);
  for (unsigned index = 0; index < 20; index++) available[index] = 0;
  for (unsigned index = 0; index < 36; index++) used[index] = 0;
  for (unsigned hart = 0; hart < count; hart++) {
    unsigned head = hart * 4;
    requests[hart].type = type;
    requests[hart].sector = sector + hart;
    status[hart] = 0xa5;
    descriptors[head] = (Descriptor){(uintptr_t)&requests[hart], 16, 1, head + 1};
#ifdef BIG_REQUEST
    descriptors[head + 1] = (Descriptor){(uintptr_t)data[hart], DATA_SIZE, type == 1 ? 1 : 3, head + 3};
#else
    descriptors[head + 1] = (Descriptor){(uintptr_t)data[hart], 256, type == 1 ? 1 : 3, head + 2};
    descriptors[head + 2] = (Descriptor){(uintptr_t)data[hart] + 256, 256, type == 1 ? 1 : 3, head + 3};
#endif
    descriptors[head + 3] = (Descriptor){(uintptr_t)&status[hart], 1, 2, 0};
    available[2 + hart] = head;
  }
  available[1] = count;
  write_reg(0x38, 16);
  write_reg(0x80, (uintptr_t)descriptors);
  write_reg(0x90, (uintptr_t)available);
  write_reg(0xa0, (uintptr_t)used);
  write_reg(0x44, 3);
  write_reg(0x70, 4);
}

#ifndef EMPTY_DISK
static void block_interrupt(void) __attribute__((interrupt("machine"), aligned(4)));
static void block_interrupt(void)
{
  uintptr_t cause;
  __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
  check(cause == ((uintptr_t)1 << (__riscv_xlen - 1) | 11));
  check(*(volatile uint32_t *)(uintptr_t)0x0c200004 == 1);
  write_reg(0x64, 1);
  *(volatile uint32_t *)(uintptr_t)0x0c200004 = 1;
  irq_count++;
}
#endif

#if !defined(EMPTY_DISK) && !defined(BIG_REQUEST)
static void failures(void)
{
  setup(1, 8, 0);
  descriptors[1].length = 20;
  descriptors[1].next = 3;
  write_reg(0x50, 0);
  check(status[0] == 0 && used[2] == 21);
  check(data[0][0] == 'N' && data[0][14] == 'K' && data[0][19] == 0);
  setup(1, 0, 0);
  requests[0].sector = UINT64_C(1) << 55;
  data[0][0] = 0xa5;
  write_reg(0x50, 0);
  check(status[0] == 1 && used[2] == 1 && data[0][0] == 0xa5);
  setup(1, 0, 4096);
  write_reg(0x50, 0);
  check(status[0] == 1 && used[2] == 1);
  setup(1, 0, 0);
  descriptors[1].address |= UINT64_C(1) << 32;
  write_reg(0x50, 0);
  check(status[0] == 1 && used[2] == 1);
  setup(1, 1, 0);
  descriptors[1].address |= UINT64_C(1) << 32;
  write_reg(0x50, 0);
  check(status[0] == 1 && used[2] == 1);
  setup(1, 0, 0);
  descriptors[2].address |= UINT64_C(1) << 32;
  data[0][256] = 0xa5;
  write_reg(0x50, 0);
  check(status[0] == 1 && used[2] == 257 && data[0][0] == 3 && data[0][256] == 0xa5);
  setup(1, 0, 0);
  descriptors[3].flags = 0;
  write_reg(0x50, 0);
  check(status[0] == 0xa5 && used[2] == 512);
  setup(1, 0, 0);
  descriptors[1].next = 1;
  write_reg(0x50, 0);
  check(status[0] == 0xa5 && used[2] == 15 * 256);
  setup(1, 99, 0);
  write_reg(0x50, 0);
  check(status[0] == 1 && used[2] == 1);
  setup(1, 0, 0);
  descriptors[1].flags = 1;
  write_reg(0x50, 0);
  check(status[0] == 1 && used[2] == 1);
  setup(1, 0, 0);
  write_reg(0x84, 1);
  write_reg(0x50, 0);
  check(status[0] == 0xa5 && used[2] == 0);
  setup(1, 0, 0);
  write_reg(0x94, 1);
  write_reg(0x50, 0);
  check(used[0] == 0);
  setup(1, 0, 0);
  write_reg(0xa0, 0xbffffffc);
  *(volatile uint16_t *)(uintptr_t)0xbffffffe = 0;
  write_reg(0x50, 0);
  check(status[0] == 0 && read_reg(0x60) == 0);
  setup(1, 0, 0);
  used[0] = 0xffff0000;
  write_reg(0x50, 0);
  check(used[0] == 0 && used[31] == 0 && used[32] == 513);
  setup(1, 0, 0);
  descriptors[1].length = 0x100001;
  write_reg(0x50, 0);
  check(status[0] == 1 && used[2] == 1);
}
#endif

void nemu_block_main(unsigned hart)
{
  __asm__ volatile ("csrw mstatus, zero\ncsrw mie, %0" :: "r"(8) : "memory");
#ifdef BAD_WIDTH
  if (!hart) (void)*(volatile uint8_t *)(uintptr_t)0x10001000;
#endif
  if (!hart) {
    check(read_reg(0) == 0x74726976 && read_reg(4) == 2 && read_reg(12) == 0x554d4551);
#ifdef EMPTY_DISK
    check(read_reg(8) == 0 && read_reg(0x34) == 0 && read_reg(0x100) == 0);
    setup(HARTS, 0, 0);
    write_reg(0x50, 0);
    check(used[0] == 0);
#else
    check(read_reg(8) == 2 && read_reg(0x34) == 256 && read_reg(0x100) == 2048);
    check(read_reg(0x108) == 0x100000 && read_reg(0x10c) == 128);
    check(read_reg(0x10) == 6);
    write_reg(0x14, 1);
    check(read_reg(0x10) == 1);
    write_reg(0x30, 1);
    check(read_reg(0x34) == 0);
    setup(HARTS, 0, 0);
    *(volatile uint32_t *)(uintptr_t)0x0c000004 = 1;
    *(volatile uint32_t *)(uintptr_t)0x0c002000 = 2;
#endif
  }
  barrier();
#ifndef EMPTY_DISK
  unsigned original, failed;
  __asm__ volatile ("lr.w %0, (%1)" : "=r"(original) : "r"(data[hart]) : "memory");
  barrier();
  write_reg(0x50, 0);
  barrier();
  __asm__ volatile ("sc.w %0, %2, (%1)" : "=&r"(failed) : "r"(data[hart]), "r"(original) : "memory");
  check(failed == 1 && status[hart] == 0 && used[0] == HARTS * 0x10000 && used[2 + 2 * hart] == DATA_SIZE + 1);
#ifdef BIG_REQUEST
  for (unsigned index = 0; index < DATA_SIZE / 4; index++) {
    unsigned byte = (index * 28 + 3) & 255;
    uint32_t expected = byte | ((byte + 7) & 255) << 8 | ((byte + 14) & 255) << 16 | ((byte + 21) & 255) << 24;
    check(((volatile BlockWord *)data[hart])[index] == expected);
  }
#else
  for (unsigned index = 0; index < DATA_SIZE; index++) {
    check(data[hart][index] == (unsigned char)(7 * index + 3));
    data[hart][index] = (unsigned char)(index + 37 * hart);
  }
  barrier();
  if (!hart) setup(HARTS, 1, 8);
  barrier();
  __asm__ volatile ("lr.w %0, (%1)" : "=r"(original) : "r"(data[hart]) : "memory");
  barrier();
  write_reg(0x50, 0);
  barrier();
  __asm__ volatile ("sc.w %0, %2, (%1)" : "=&r"(failed) : "r"(data[hart]), "r"(original) : "memory");
  check(failed == 0 && status[hart] == 0 && used[2 + 2 * hart] == 1);
  for (unsigned index = 0; index < DATA_SIZE; index++) data[hart][index] = 0;
  barrier();
  if (!hart) setup(HARTS, 0, 8);
  barrier();
  write_reg(0x50, 0);
  barrier();
  check(status[hart] == 0 && used[2 + 2 * hart] == 513);
  for (unsigned index = 0; index < DATA_SIZE; index++) check(data[hart][index] == (unsigned char)(index + 37 * hart));
#endif
  barrier();
  if (!hart) {
    __asm__ volatile ("csrw mtvec, %0\ncsrw mie, %1\ncsrs mstatus, %2"
                      :: "r"((uintptr_t)block_interrupt), "r"(0x800), "r"(8) : "memory");
    while (!irq_count) __asm__ volatile ("wfi");
    __asm__ volatile ("csrc mstatus, %0\ncsrw mie, %0" :: "r"(8) : "memory");
#ifndef BIG_REQUEST
    failures();
#endif
    write_reg(0x70, 0);
    check(read_reg(0x60) == 0 && read_reg(0x44) == 0);
  }
#endif
  *(volatile uint8_t *)(uintptr_t)0x10000000 = 'B';
  check(*(volatile uint32_t *)(uintptr_t)0x100000 == 0);
  barrier();
  if (!hart) {
    uint32_t value = *(volatile uint32_t *)(uintptr_t)0x100000;
    *(volatile uint32_t *)(uintptr_t)0x100000 = (value & 0xffff0000u) | 0x5555;
  }
  for (;;) __asm__ volatile ("wfi");
}
