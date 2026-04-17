/* ============================================================================
 * core_portme.h: CoreMark port header for Raptor LiteX SoC
 *
 * Fully freestanding — no newlib/picolibc/glibc required.
 * Timing: RISC-V rdtime (Zicntr), 1 MHz timebase (CLINT default).
 * Output: minimal printf via LiteX UART CSR.
 * ============================================================================ */

#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stdint.h>  /* GCC freestanding: stdint-gcc.h via -ffreestanding */
#include <stddef.h>  /* GCC freestanding: size_t, NULL */

/* ---- CoreMark Configuration ---- */
#ifndef HAS_FLOAT
#define HAS_FLOAT 0
#endif

#ifndef HAS_TIME_H
#define HAS_TIME_H 0
#endif

#ifndef USE_CLOCK
#define USE_CLOCK 0
#endif

/* Disable libc stdio — we provide our own ee_printf */
#ifndef HAS_STDIO
#define HAS_STDIO 0
#endif

#ifndef HAS_PRINTF
#define HAS_PRINTF 0
#endif

#ifndef ITERATIONS
#define ITERATIONS 40
#endif

#define MEM_METHOD MEM_STATIC

/* ---- Timing: rdtime (RISC-V Zicntr) ---- */
typedef unsigned long long CORE_TICKS;

static inline unsigned long long _rdtime(void)
{
#if __riscv_xlen == 64
    unsigned long long v;
    __asm__ volatile("rdtime %0" : "=r"(v));
    return v;
#else
    unsigned int lo, hi, hi2;
    do {
        __asm__ volatile("rdtimeh %0" : "=r"(hi));
        __asm__ volatile("rdtime  %0" : "=r"(lo));
        __asm__ volatile("rdtimeh %0" : "=r"(hi2));
    } while (hi != hi2);
    return ((unsigned long long)hi << 32) | lo;
#endif
}

/* CLINT timebase: 1 MHz */
#define CORETIMETYPE        unsigned long long
#define GETMYTIME(_t)       (*(_t) = _rdtime())
#define MYTIMEDIFF(fin,ini) ((fin) - (ini))
#define TIMER_RES_DIVIDER   1
#define SAMPLE_TIME_IMPLEMENTATION 1
#define EE_TICKS_PER_SEC    1000000ULL

/* ---- Data types ---- */
typedef int16_t   ee_s16;
typedef uint16_t  ee_u16;
typedef int32_t   ee_s32;
typedef uint32_t  ee_u32;
typedef double    ee_f32;
typedef uint8_t   ee_u8;
typedef uintptr_t ee_ptr_int;
typedef size_t    ee_size_t;

/* Align to 4-byte boundary */
#define align_mem(x) (void *)(4 + ((((uintptr_t)(x) - 1) >> 2) << 2))

/* Configuration: SEED_METHOD */
#define SEED_METHOD SEED_VOLATILE

/* Configuration: MAIN_HAS_NORETURN */
#define MAIN_HAS_NORETURN 0

/* Compiler identification */
#ifndef COMPILER_VERSION
#define COMPILER_VERSION "GCC " __VERSION__
#endif

#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS "See Makefile"
#endif

#ifndef MEM_LOCATION
#define MEM_LOCATION "STATIC"
#endif

/* ---- printf: our own minimal implementation ---- */
int ee_printf(const char *fmt, ...);

/* Multithread: single core */
#ifndef MULTITHREAD
#define MULTITHREAD 1
#endif
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0

extern ee_u32 default_num_contexts;

/* Portable data struct */
typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#endif /* CORE_PORTME_H */
