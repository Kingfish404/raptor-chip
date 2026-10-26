// Bare-metal port of fpga/common/tests/ubuntu_bench/memory_probe.c.
#include <am.h>
#include <klib.h>
#include <stdint.h>

struct node {
  struct node *volatile next;
  uint64_t padding;
};

#define MAX_BYTES (1 << 20)
#ifndef MEMPROBE_QUICK
#define MEMPROBE_QUICK 0
#endif
#ifndef MEMPROBE_STEPS
#define MEMPROBE_STEPS 65536
#endif
#ifndef MEMPROBE_STORE_ONLY
#define MEMPROBE_STORE_ONLY 0
#endif
#define MAX_RING_BYTES (MEMPROBE_STORE_ONLY ? 2048 : (MEMPROBE_QUICK ? 32768 : MAX_BYTES))
#ifndef MEMPROBE_MATCH_BOARD
#define MEMPROBE_MATCH_BOARD 0
#endif
_Static_assert(MEMPROBE_STEPS >= MAX_RING_BYTES / sizeof(struct node),
               "MEMPROBE_STEPS must visit the largest ring at least once");
_Static_assert(MEMPROBE_STEPS % (MAX_RING_BYTES / sizeof(struct node)) == 0,
               "MEMPROBE_STEPS must be a multiple of every ring length");
#if !MEMPROBE_STORE_ONLY
static struct node nodes[MAX_BYTES / sizeof(struct node)] __attribute__((aligned(4096)));
static uint32_t order[MAX_BYTES / sizeof(struct node)];
static uint32_t random_state = 42;

static uint32_t random_u32(void) {
  random_state ^= random_state << 13;
  random_state ^= random_state >> 17;
  random_state ^= random_state << 5;
  return random_state;
}
#endif
static volatile uint64_t stores[128];

static inline uint64_t cycles(void) {
  uint64_t c;
#if __riscv_xlen == 64
  asm volatile("csrr %0, mcycle" : "=r"(c) : : "memory");
#else
  uint32_t lo, hi, hi2;
  do {
    asm volatile("csrr %0, mcycleh" : "=r"(hi));
    asm volatile("csrr %0, mcycle" : "=r"(lo));
    asm volatile("csrr %0, mcycleh" : "=r"(hi2));
  } while (hi != hi2);
  c = ((uint64_t)hi << 32) | lo;
#endif
  return c;
}
#if !MEMPROBE_STORE_ONLY
static struct node *chase(struct node *p, size_t steps) {
#if MEMPROBE_MATCH_BOARD
#if __riscv_xlen != 64
#error Board instruction matching requires RV64
#endif
  register struct node *pointer asm("s9") = p;
  register size_t count asm("s1") = steps / 8;
  /* Match the board's 24-byte loop at byte offset 12 in a 16-byte cache line. */
  asm volatile(
      ".balign 16\n"
      ".rept 6\n"
      ".2byte 0x0001\n"
      ".endr\n"
      "1: ld a5, 0(s9)\n"
      "addi s1, s1, -1\n"
      "ld a5, 0(a5)\n"
      "ld a5, 0(a5)\n"
      "ld a5, 0(a5)\n"
      "ld a5, 0(a5)\n"
      "ld a5, 0(a5)\n"
      "ld a5, 0(a5)\n"
      "ld s9, 0(a5)\n"
      "bnez s1, 1b\n"
      : "+r"(pointer), "+r"(count)
      :
      : "a5", "memory");
  return pointer;
#else
  for (size_t i = 0; i < steps / 8; i++) {
    p = p->next; p = p->next; p = p->next; p = p->next;
    p = p->next; p = p->next; p = p->next; p = p->next;
  }
  return p;
#endif
}
#endif

static void report(const char *name, size_t bytes, uint64_t c, size_t steps) {
  uint64_t x100 = c * 100 / steps;
  printf("MEMPROBE %s %d cycles_per_access=%d.%02d\n", name, (int)bytes, (int)(x100 / 100),
         (int)(x100 % 100));
}

int main(const char *args) {
  const size_t steps = MEMPROBE_STEPS;
  (void)args;
  int ok = 1;
#if !MEMPROBE_STORE_ONLY
#if MEMPROBE_QUICK
  const size_t sizes[] = {1024, 32768};
#else
  const size_t sizes[] = {1024, 8192, 16384, 32768, 65536, 262144, 1048576};
#endif
  for (size_t s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++) {
    const size_t n = sizes[s] / sizeof(struct node);
    for (size_t i = 0; i < n; i++) order[i] = i;
    for (size_t i = n - 1; i; i--) {
      size_t j = random_u32() % (i + 1);
      uint32_t t = order[i]; order[i] = order[j]; order[j] = t;
    }
    for (size_t i = 0; i < n; i++) nodes[order[i]].next = &nodes[order[(i + 1) % n]];
    struct node *start = &nodes[0];
    struct node *p = chase(start, n * 4);
    uint64_t c0 = cycles();
    p = chase(p, steps);
    uint64_t c1 = cycles();
    report("chase", sizes[s], c1 - c0, steps);
    printf("MEMPROBE detail chase bytes=%d cycles=%llu steps=%d verify=%d\n",
           (int)sizes[s], (unsigned long long)(c1 - c0), (int)steps, p == start);
    if (p != start) ok = 0;
  }
#endif
  for (size_t i = 0; i < 128; i++) stores[i] = i;
  uint64_t c0 = cycles();
#if MEMPROBE_MATCH_BOARD
  register volatile uint64_t *base asm("s0") = stores;
  register size_t index asm("a4") = 0;
  register size_t limit asm("a1") = steps;
  /* Preserve the board compiler's address-generation sequence between stores. */
  asm volatile(
      ".balign 16\n"
      ".rept 6\n"
      ".2byte 0x0001\n"
      ".endr\n"
      "1: andi a5, a4, 127\n"
      "slli a5, a5, 3\n"
      "add a3, s0, a5\n"
      "addi a2, a5, 8\n"
      "sd a4, 0(a3)\n"
      "add a2, a2, s0\n"
      "addi a3, a5, 16\n"
      "sd a4, 0(a2)\n"
      "add a3, a3, s0\n"
      "addi a2, a5, 24\n"
      "sd a4, 0(a3)\n"
      "add a2, a2, s0\n"
      "addi a3, a5, 32\n"
      "sd a4, 0(a2)\n"
      "add a3, a3, s0\n"
      "addi a2, a5, 40\n"
      "sd a4, 0(a3)\n"
      "add a2, a2, s0\n"
      "addi a3, a5, 48\n"
      "sd a4, 0(a2)\n"
      "add a3, a3, s0\n"
      "addi a5, a5, 56\n"
      "sd a4, 0(a3)\n"
      "add a5, a5, s0\n"
      "sd a4, 0(a5)\n"
      "addi a4, a4, 8\n"
      "bne a4, a1, 1b\n"
      "fence rw,rw\n"
      : "+r"(index)
      : "r"(base), "r"(limit)
      : "a2", "a3", "a5", "memory");
#else
  for (size_t i = 0; i < steps; i += 8) {
    size_t j = i & 127;
    stores[j] = i; stores[j + 1] = i; stores[j + 2] = i; stores[j + 3] = i;
    stores[j + 4] = i; stores[j + 5] = i; stores[j + 6] = i; stores[j + 7] = i;
  }
  asm volatile("fence rw,rw" ::: "memory");
#endif
  uint64_t c1 = cycles();
  report("store", 1024, c1 - c0, steps);
  for (size_t j = 0; j < 128; j++)
    if (stores[j] != steps - 128 + (j & ~(size_t)7)) ok = 0;
  printf("MEMPROBE detail store bytes=1024 cycles=%llu steps=%d\n",
         (unsigned long long)(c1 - c0), (int)steps);
  printf("MEMPROBE verify=%d\n", ok);
  return ok ? 0 : 1;
}
