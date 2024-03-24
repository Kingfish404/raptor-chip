#ifndef __NPC_COMMON_H__
#define __NPC_COMMON_H__

#include <generated/autoconf.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <pthread.h>
#include <string.h>

typedef uint32_t word_t;
typedef word_t paddr_t;
typedef word_t vaddr_t;

#define GPR_SIZE 16

#define MBASE 0x80000000
#define MSIZE 0x08000000

#define PSRAM_BASE 0x80000000
#define PSRAM_SIZE 0x00400000

#define SDRAM_BASE 0xa0000000
#define SDRAM_SIZE 0x20000000

#define SRAM_BASE 0x0f000000
#define SRAM_SIZE 0x00002000

#define MROM_BASE 0x20000000
#define MROM_SIZE 0x00001000

#define FLASH_BASE 0x30000000
#define FLASH_SIZE 0x10000000

#ifdef CONFIG_SOFT_MMIO
#define DEVICE_BASE 0xa0000000

#define MMIO_BASE 0xa0000000

#define SERIAL_PORT (DEVICE_BASE + 0x00003f8)
#define KBD_ADDR (DEVICE_BASE + 0x0000060)
#define RTC_ADDR (DEVICE_BASE + 0x0000048)
#define VGACTL_ADDR (DEVICE_BASE + 0x0000100)
#define AUDIO_ADDR (DEVICE_BASE + 0x0000200)
#define DISK_ADDR (DEVICE_BASE + 0x0000300)
#define FB_ADDR (MMIO_BASE + 0x1000000)
#define AUDIO_SBUF_ADDR (MMIO_BASE + 0x1200000)
#endif

#define FMT_WORD "0x%08x"
#define FMT_WORD_NO_PREFIX "%08x"
#define FMT_RED(x) "\33[1;31m" x "\33[0m"
#define FMT_GREEN(x) "\33[1;32m" x "\33[0m"
#define FMT_BLUE(x) "\33[1;34m" x "\33[0m"

#define ARRLEN(arr) (int)(sizeof(arr) / sizeof(arr[0]))

#define _CONCAT(x, y) x##y
#define CONCAT(x, y) _CONCAT(x, y)
#define CONCAT_HEAD(x) <x.h>

#define STRINGIZE_NX(A) #A
#define STRINGIZE(A) STRINGIZE_NX(A)

#define _Log(...)        \
  do                     \
  {                      \
    printf(__VA_ARGS__); \
  } while (0)

#define __FILENAME__ (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)

#define Log(format, ...)                        \
  _Log(FMT_BLUE("[npc %s:%d %s] ") format "\n", \
       __FILENAME__, __LINE__, __func__, ##__VA_ARGS__)

#define Error(format, ...)                     \
  _Log(FMT_RED("[npc %s:%d %s] ") format "\n", \
       __FILENAME__, __LINE__, __func__, ##__VA_ARGS__)

#define Assert(cond, format, ...) \
  Error(format, ##__VA_ARGS__);   \
  assert(cond)

enum
{
  DIFFTEST_TO_DUT,
  DIFFTEST_TO_REF
};

typedef enum
{
  NPC_RUNNING,
  NPC_STOP,
  NPC_END,
  NPC_ABORT,
  NPC_QUIT
} NPC_STATE_CODE;

typedef struct
{
  NPC_STATE_CODE state;
  word_t *gpr;
  word_t *ret;
  uint32_t *pc;

  // csr
  word_t *mcause;
  word_t *mtvec;
  word_t *mepc;
  word_t *mstatus;

  // for itrace
  uint32_t *inst;

  // for soc
  uint8_t *soc_sram;
} NPCState;

extern NPCState npc;

#define panic(format, ...) Assert(0, format, ##__VA_ARGS__)

#define TODO() panic("please implement me")

int reg_str2idx(const char *reg);

void reg_display(int n = GPR_SIZE);

uint64_t get_time();

#endif /* __NPC_COMMON_H__ */