#ifndef __NPC_COMMON_H__
#define __NPC_COMMON_H__

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <pthread.h>

#define MBASE 0x80000000
#define MSIZE 0x4096

#define GPR_SIZE 32

#define FMT_WORD "0x%08x"
#define FMT_GREEN(x) "\033[1;32m" x "\033[0m"
#define FMT_RED(x) "\033[1;31m" x "\033[0m"

typedef uint32_t word_t;

#define Log(format, ...)                                    \
    _Log(ANSI_FMT("[%s:%d %s] " format, ANSI_FG_BLUE) "\n", \
         __FILE__, __LINE__, __func__, ##__VA_ARGS__)

#define panic(format, ...) Assert(0, format, ##__VA_ARGS__)

#define TODO() panic("please implement me")

#endif /* __NPC_COMMON_H__ */