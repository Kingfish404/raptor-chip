#pragma once
#ifndef __NPC_UTILS_H__
#define __NPC_UTILS_H__

#include <stdint.h>

#define STR2(x) #x
#define STR(x) STR2(x)

#ifdef __APPLE__
#define USTR(x) "_" STR(x)
#else
#define USTR(x) STR(x)
#endif

#ifdef _WIN32
#define INCBIN_SECTION ".rdata, \"dr\""
#elif defined __APPLE__
#define INCBIN_SECTION "__TEXT,__const"
#else
#define INCBIN_SECTION ".rodata"
#endif

#define INCBIN(prefix, name, file)                                            \
    asm(".section " INCBIN_SECTION "\n");                                     \
    asm(".global " USTR(prefix) "_" STR(name) "_start\n");                    \
    asm(".balign 16\n" USTR(prefix) "_" STR(name) "_start:\n");               \
    asm(".incbin \"" file "\"\n");                                            \
    asm(".global " STR(prefix) "_" STR(name) "_end\n");                       \
    asm(".balign 1\n" USTR(prefix) "_" STR(name) "_end:\n");                  \
    asm(".byte 0\n");                                                         \
    extern __attribute__((aligned(16))) const char prefix##_##name##_start[]; \
    extern const uint8_t prefix##_##name##_end[];

#endif // __NPC_UTILS_H__