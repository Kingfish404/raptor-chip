#include <stdint.h>
#include <stddef.h>

#ifdef SLIRP_ARP
#define PACKET_LENGTH 42
#elif defined(BIG_PACKET)
#define PACKET_LENGTH 65524
#else
#define PACKET_LENGTH 60
#endif
#define FRAME_LENGTH (PACKET_LENGTH + 12)
#ifdef SLIRP_ARP
#define RECEIVE_FRAME_LENGTH 76
#else
#define RECEIVE_FRAME_LENGTH FRAME_LENGTH
#endif

_Alignas(4096) unsigned char nemu_test_stacks[HARTS][4096];
static volatile unsigned barrier_count, barrier_generation, irq_count;
typedef struct {
  uint64_t address;
  uint32_t length;
  uint16_t flags, next;
} Descriptor;
static _Alignas(64) volatile Descriptor descriptors[2][8];
static _Alignas(64) volatile uint16_t available[2][12];
static _Alignas(64) volatile uint32_t used[2][20];
static _Alignas(64) volatile unsigned char receive[HARTS][RECEIVE_FRAME_LENGTH + 16];
static _Alignas(64) volatile unsigned char transmit[HARTS][FRAME_LENGTH];
typedef uint32_t NetWord __attribute__((may_alias));

static void check(int condition)
{
  if (condition) return;
  *(volatile uint32_t *)(uintptr_t)0x100000 = 0x3333;
  for (;;) __asm__ volatile ("wfi");
}

static void write_reg(unsigned offset, uint32_t value)
{
  *(volatile uint32_t *)(uintptr_t)(0x10002000 + offset) = value;
}

static uint32_t read_reg(unsigned offset)
{
  return *(volatile uint32_t *)(uintptr_t)(0x10002000 + offset);
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

static void setup(unsigned count)
{
  write_reg(0x70, 0);
  for (unsigned queue = 0; queue < 2; queue++) {
    for (unsigned index = 0; index < 12; index++) available[queue][index] = 0;
    for (unsigned index = 0; index < 20; index++) used[queue][index] = 0;
    for (unsigned index = 0; index < count; index++) {
      unsigned head = queue ? index : 2 * index;
      available[queue][2 + index] = head;
      descriptors[queue][head].address = (uintptr_t)(queue ? transmit[index] : receive[index]);
#ifdef BIG_PACKET
      descriptors[queue][head].length = FRAME_LENGTH;
      descriptors[queue][head].flags = queue ? 0 : 2;
#else
      descriptors[queue][head].length = queue ? FRAME_LENGTH : 9;
      descriptors[queue][head].flags = queue ? 0 : 3;
#endif
      descriptors[queue][head].next = head + 1;
      if (!queue) {
        descriptors[queue][head + 1].address = (uintptr_t)receive[index] + 9;
        descriptors[queue][head + 1].length = RECEIVE_FRAME_LENGTH - 9;
        descriptors[queue][head + 1].flags = 2;
        descriptors[queue][head + 1].next = 0;
        for (unsigned byte = 0; byte < 16; byte++) {
          receive[index][byte] = 0xa5;
          receive[index][RECEIVE_FRAME_LENGTH + byte] = 0xa5;
        }
      }
    }
    available[queue][1] = count;
    write_reg(0x30, queue);
    write_reg(0x38, 8);
    write_reg(0x80, (uintptr_t)descriptors[queue]);
    write_reg(0x90, (uintptr_t)available[queue]);
    write_reg(0xa0, (uintptr_t)used[queue]);
    write_reg(0x44, 3);
  }
  write_reg(0x70, 4);
  __asm__ volatile ("fence rw, rw" ::: "memory");
}

static void net_interrupt(void) __attribute__((interrupt("machine"), aligned(4)));

static void net_interrupt(void)
{
  uintptr_t cause;
  __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
  check(cause == ((uintptr_t)1 << (__riscv_xlen - 1) | 11));
  check(*(volatile uint32_t *)(uintptr_t)0x0c200004 == 2);
  write_reg(0x64, 1);
  *(volatile uint32_t *)(uintptr_t)0x0c200004 = 2;
  irq_count++;
}

static void wait_interrupt(unsigned received)
{
  __asm__ volatile ("csrw mtvec, %0\ncsrw mie, %1\ncsrs mstatus, %2"
                    :: "r"((uintptr_t)net_interrupt), "r"(0x800), "r"(8) : "memory");
  while ((used[0][0] >> 16) != received || !irq_count)
    __asm__ volatile ("wfi" ::: "memory");
  __asm__ volatile ("csrc mstatus, %0\ncsrw mie, %0" :: "r"(8) : "memory");
}

#if !defined(SLIRP_ARP) && !defined(BIG_PACKET)
static void failure_tests(void)
{
  setup(1);
  descriptors[0][0].flags = 0;
  write_reg(0x50, 1);
  check(used[0][0] == 0x10000 && used[0][2] == 0 && receive[0][0] == 0xa5);
  setup(1);
  descriptors[0][0].flags = 2;
  descriptors[0][0].length = 8;
  write_reg(0x50, 1);
  check(used[0][0] == 0x10000 && used[0][2] == 0 && receive[0][0] == 0 && receive[0][8] == 0xa5);
  setup(1);
  write_reg(0x30, 0);
  write_reg(0xa4, 1);
  write_reg(0x50, 1);
  check(used[0][0] == 0 && receive[0][12] == 0x77);
  setup(1);
  write_reg(0x30, 0);
  write_reg(0x94, 1);
  write_reg(0x50, 1);
  check(used[0][0] == 0 && receive[0][0] == 0xa5);
  setup(1);
  descriptors[1][0].address |= UINT64_C(1) << 32;
  write_reg(0x50, 1);
  check(used[1][0] == 0x10000 && used[1][2] == 0);
  setup(1);
  descriptors[1][0].flags = 2;
  write_reg(0x50, 1);
  check(used[1][2] == 0);
  setup(1);
  descriptors[1][0].flags = 1;
  descriptors[1][0].next = 0;
  write_reg(0x50, 1);
  check(used[1][2] == 0);
  setup(1);
  descriptors[1][0].length = 65537;
  write_reg(0x50, 1);
  check(used[1][2] == 0);
  setup(1);
  write_reg(0x84, 1);
  write_reg(0x50, 1);
  check(used[1][0] == 0x10000 && used[1][2] == 0);
  setup(1);
  write_reg(0x94, 1);
  write_reg(0x50, 1);
  check(used[1][0] == 0);
  setup(1);
  write_reg(0xa0, 0xbffffffc);
  *(volatile uint16_t *)(uintptr_t)0xbffffffe = 0;
  write_reg(0x50, 1);
  check(*(volatile uint16_t *)(uintptr_t)0xbffffffe == 0 && read_reg(0x60) == 0);
  setup(1);
  used[1][0] = 0xffff0000;
  write_reg(0x50, 1);
  check(used[1][0] == 0 && used[1][15] == 0 && used[1][16] == FRAME_LENGTH);
  setup(1);
  descriptors[1][0].length = 12;
  write_reg(0x50, 1);
  check(used[0][0] == 0x10000 && used[0][2] == 12);
  check(used[1][0] == 0x10000 && used[1][2] == 12);
  setup(1);
  descriptors[1][0].length = 11;
  write_reg(0x50, 1);
  check(used[0][0] == 0 && used[1][0] == 0x10000 && used[1][2] == 11);
}
#endif

void nemu_test_main(unsigned hart)
{
  __asm__ volatile ("csrw mstatus, zero\ncsrw mie, %0" :: "r"(8) : "memory");
#ifdef BAD_WIDTH
  if (!hart) (void)*(volatile uint8_t *)(uintptr_t)0x10002000;
#endif
  if (!hart) {
    check(read_reg(0) == 0x74726976 && read_reg(4) == 2 && read_reg(8) == 1);
    check(read_reg(12) == 0x554d4551 && read_reg(0x34) == 256);
    check(*(volatile uint8_t *)(uintptr_t)0x10002101 == 0x54);
    check(*(volatile uint16_t *)(uintptr_t)0x10002104 == 0x5634);
    check(read_reg(0x100) == 0x12005452 && read_reg(0x104) == 0x5634);
    write_reg(0x14, 0);
    check(read_reg(0x10) == 32);
    write_reg(0x14, 1);
    check(read_reg(0x10) == 1);
    write_reg(0x30, 2);
    check(read_reg(0x34) == 0 && read_reg(0x44) == 0);
    write_reg(0x38, 999);
    write_reg(0x50, 0);
    setup(HARTS);
    *(volatile uint32_t *)(uintptr_t)0x0c000008 = 1;
    *(volatile uint32_t *)(uintptr_t)0x0c002000 = 4;
  }
#ifdef BIG_PACKET
  for (unsigned index = 0; index < FRAME_LENGTH / 4; index++)
    ((volatile NetWord *)transmit[hart])[index] = index < 3 ? 0 : 0x5a5a5a5a;
#else
  for (unsigned index = 0; index < FRAME_LENGTH; index++)
    transmit[hart][index] = index < 12 ? 0 : (unsigned char)(index - 12 + 37 * hart);
#endif
#ifdef SLIRP_ARP
  const unsigned char request[42] = {
    255,255,255,255,255,255, 0x52,0x54,0,0x12,0x34,0x56, 8,6,
    0,1,8,0,6,4,0,1, 0x52,0x54,0,0x12,0x34,0x56, 10,0,2,15,
    0,0,0,0,0,0, 10,0,2,2
  };
  for (unsigned index = 0; index < 42; index++) transmit[hart][12 + index] = request[index];
#endif
  barrier();
  unsigned original, failed;
  __asm__ volatile ("lr.w %0, (%1)" : "=r"(original) : "r"(receive[hart]) : "memory");
  barrier();
  write_reg(0x50, 1);
  barrier();
  __asm__ volatile ("sc.w %0, %2, (%1)" : "=&r"(failed) : "r"(receive[hart]), "r"(original) : "memory");
  check(failed == 1 && used[0][0] == HARTS * 0x10000 && used[1][0] == HARTS * 0x10000);
  check(used[0][1 + 2 * hart] == 2 * hart);
#ifdef SLIRP_ARP
  check(used[0][2 + 2 * hart] >= FRAME_LENGTH && used[0][2 + 2 * hart] <= RECEIVE_FRAME_LENGTH);
#else
  check(used[0][2 + 2 * hart] == RECEIVE_FRAME_LENGTH);
#endif
  check(used[1][1 + 2 * hart] == hart && used[1][2 + 2 * hart] == FRAME_LENGTH);
  for (unsigned index = 0; index < 12; index++) check(receive[hart][index] == 0);
#ifdef SLIRP_ARP
  check(receive[hart][12 + 12] == 8 && receive[hart][12 + 13] == 6 && receive[hart][12 + 21] == 2);
  check(receive[hart][12 + 28] == 10 && receive[hart][12 + 31] == 2);
#elif defined(BIG_PACKET)
  for (unsigned index = 3; index < FRAME_LENGTH / 4; index++)
    check(((volatile NetWord *)receive[hart])[index] == 0x5a5a5a5a);
#else
  for (unsigned index = 0; index < PACKET_LENGTH; index++)
    check(receive[hart][12 + index] == (unsigned char)(17 * hart + index));
#endif
  for (unsigned index = 0; index < 16; index++) check(receive[hart][RECEIVE_FRAME_LENGTH + index] == 0xa5);
  __asm__ volatile ("lr.w %0, (%1)" : "=r"(original) : "r"(receive[hart]) : "memory");
  write_reg(0x50, 1);
  __asm__ volatile ("sc.w %0, %2, (%1)" : "=&r"(failed) : "r"(receive[hart]), "r"(original) : "memory");
  check(failed == 0);
  barrier();
  if (!hart) {
#if !defined(SLIRP_ARP) && !defined(BIG_PACKET)
    while (*(volatile uint32_t *)(uintptr_t)0x0c200004) *(volatile uint32_t *)(uintptr_t)0x0c200004 = 2;
    setup(1);
    write_reg(0x50, 1);
    wait_interrupt(1);
    check(receive[0][12] == 0x55);
    failure_tests();
#else
    wait_interrupt(HARTS);
#endif
#ifdef HOSTFWD_TCP
    setup(1);
    irq_count = 0;
    const char *ready = "NEMU_HOSTFWD_READY\n";
    while (*ready) *(volatile uint8_t *)(uintptr_t)0x10000000 = *ready++;
    wait_interrupt(1);
    check(used[0][2] >= 66 && used[0][2] <= RECEIVE_FRAME_LENGTH);
    check(receive[0][24] == 8 && receive[0][25] == 0 && receive[0][26] == 0x45);
    check(receive[0][35] == 6 && receive[0][48] == 0x4a && receive[0][49] == 0x38);
    check((receive[0][59] & 0x12) == 2);
#endif
    write_reg(0x70, 0);
    check(read_reg(0x44) == 0 && read_reg(0x60) == 0);
    check(*(volatile uint32_t *)(uintptr_t)0x10003000 == 0x74726976);
  }
  *(volatile uint8_t *)(uintptr_t)0x10000000 = 'N';
  barrier();
  if (!hart) *(volatile uint32_t *)(uintptr_t)0x100000 = 0x5555;
  for (;;) __asm__ volatile ("wfi");
}
