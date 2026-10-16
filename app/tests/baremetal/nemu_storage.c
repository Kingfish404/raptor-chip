#include <stdint.h>
#include <stddef.h>

#ifndef STORAGE_MODE
#define STORAGE_MODE 0
#endif
#ifndef EXPECT_STORED
#define EXPECT_STORED 0
#endif
#ifndef NEGOTIATE_FLUSH
#define NEGOTIATE_FLUSH 1
#endif

_Alignas(4096) unsigned char nemu_test_stacks[HARTS][4096];
typedef struct { uint64_t address; uint32_t length; uint16_t flags, next; } Descriptor;
typedef struct { uint32_t type, reserved; uint64_t sector; } Request;
static _Alignas(64) volatile Descriptor descriptors[4];
static _Alignas(64) volatile Request request;
static _Alignas(64) volatile uint16_t available[4];
static _Alignas(64) volatile uint32_t used[10];
static _Alignas(64) volatile unsigned char data[512];
static volatile unsigned char status;

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

static unsigned perform(unsigned type, unsigned sector)
{
  write_reg(0x70, 0);
  for (unsigned index = 0; index < 4; index++) available[index] = 0;
  for (unsigned index = 0; index < 10; index++) used[index] = 0;
  request.type = type;
  request.sector = sector;
  status = 0xa5;
  descriptors[0] = (Descriptor){(uintptr_t)&request, 16, 1, type == 4 ? 3 : 1};
  descriptors[1] = (Descriptor){(uintptr_t)data, 256, type == 1 ? 1 : 3, 2};
  descriptors[2] = (Descriptor){(uintptr_t)data + 256, 256, type == 1 ? 1 : 3, 3};
  descriptors[3] = (Descriptor){(uintptr_t)&status, 1, 2, 0};
  available[1] = 1;
  write_reg(0x20, NEGOTIATE_FLUSH ? read_reg(0x10) : 0);
  write_reg(0x38, 4);
  write_reg(0x80, (uintptr_t)descriptors);
  write_reg(0x90, (uintptr_t)available);
  write_reg(0xa0, (uintptr_t)used);
  write_reg(0x44, 1);
  write_reg(0x70, 4);
  __asm__ volatile ("fence rw, rw" ::: "memory");
  write_reg(0x50, 0);
  __asm__ volatile ("fence rw, rw" ::: "memory");
  check(used[0] == 0x10000 && used[1] == 0);
  check(used[2] == (type == 0 && !status ? 513 : 1));
  check(read_reg(0x60) == 1);
  return status;
}

void nemu_test_main(unsigned hart)
{
  if (hart) for (;;) __asm__ volatile ("wfi");
  unsigned features = 6 | (STORAGE_MODE == 1 ? 32 : STORAGE_MODE == 2 ? 512 : 0);
  check(read_reg(8) == 2 && read_reg(0x10) == features);
  check(read_reg(0x100) == 8);
  check(perform(0, 1) == 0);
  for (unsigned index = 0; index < 512; index++) {
    check(data[index] == (EXPECT_STORED ? 0x73 : 0x2b));
    data[index] = 0x73;
  }
  check(perform(1, 1) == (STORAGE_MODE == 1 ? 1 : 0));
  check(perform(4, 0) == (STORAGE_MODE == 2 ? 0 : 1));
  check(perform(0, 1) == 0);
  for (unsigned index = 0; index < 512; index++)
    check(data[index] == (STORAGE_MODE == 1 && !EXPECT_STORED ? 0x2b : 0x73));
  check(perform(4, 1) == 1);
  *(volatile uint32_t *)(uintptr_t)0x100000 = 0x5555;
  for (;;) __asm__ volatile ("wfi");
}
