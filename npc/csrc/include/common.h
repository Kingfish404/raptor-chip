#ifndef __NPC_COMMON_H__
#define __NPC_COMMON_H__

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <pthread.h>
#include <string.h>

typedef uint32_t word_t;
typedef word_t paddr_t;
typedef word_t vaddr_t;

#define MBASE 0x80000000
#define MSIZE 0x8000000

#define GPR_SIZE 16

#define FMT_WORD "0x%08x"
#define FMT_WORD_NO_PREFIX "%08x"
#define FMT_GREEN(x) "\033[1;32m" x "\033[0m"
#define FMT_RED(x) "\033[1;31m" x "\033[0m"
#define FMT_BLUE(x) "\033[1;34m" x "\033[0m"

#define ARRLEN(arr) (int)(sizeof(arr) / sizeof(arr[0]))

#define _Log(...)        \
  do                     \
  {                      \
    printf(__VA_ARGS__); \
  } while (0)

#define __FILENAME__ (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)

#define Log(format, ...)                        \
  _Log(FMT_BLUE("[npc %s:%d %s] ") format "\n", \
       __FILENAME__, __LINE__, __func__, ##__VA_ARGS__)

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
} NPCState;

extern NPCState npc;

#define panic(format, ...) Assert(0, format, ##__VA_ARGS__)

#define TODO() panic("please implement me")

int reg_str2idx(const char *reg);

void reg_display(int n = GPR_SIZE);

uint64_t get_time();

#endif /* __NPC_COMMON_H__ */