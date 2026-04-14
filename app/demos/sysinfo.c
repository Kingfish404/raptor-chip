/* sysinfo.c: Print RISC-V system information — ISA, CSRs, build config */
#include <stdio.h>
#include <stdint.h>

#if __riscv_xlen == 32
#define XLEN 32
#else
#define XLEN 64
#endif

static inline unsigned long read_cycle(void)
{
#if __riscv_xlen == 32
    unsigned long lo, hi, hi2;
    do
    {
        asm volatile("rdcycleh %0" : "=r"(hi));
        asm volatile("rdcycle  %0" : "=r"(lo));
        asm volatile("rdcycleh %0" : "=r"(hi2));
    } while (hi != hi2);
    return lo; /* return low word for simplicity */
#else
    unsigned long c;
    asm volatile("rdcycle %0" : "=r"(c));
    return c;
#endif
}

static inline unsigned long read_time(void)
{
#if __riscv_xlen == 32
    unsigned long lo;
    asm volatile("rdtime %0" : "=r"(lo));
    return lo;
#else
    unsigned long t;
    asm volatile("rdtime %0" : "=r"(t));
    return t;
#endif
}

static inline unsigned long read_instret(void)
{
#if __riscv_xlen == 32
    unsigned long lo;
    asm volatile("rdinstret %0" : "=r"(lo));
    return lo;
#else
    unsigned long i;
    asm volatile("rdinstret %0" : "=r"(i));
    return i;
#endif
}

int main(void)
{
    printf("=== RISC-V System Information ===\n\n");

    printf("Architecture:  RV%d\n", XLEN);

    /* Supported extensions (compile-time) */
    printf("Extensions:   ");
#ifdef __riscv_mul
    printf(" M");
#endif
#ifdef __riscv_atomic
    printf(" A");
#endif
#ifdef __riscv_compressed
    printf(" C");
#endif
#ifdef __riscv_zba
    printf(" Zba");
#endif
#ifdef __riscv_zbb
    printf(" Zbb");
#endif
#ifdef __riscv_zbs
    printf(" Zbs");
#endif
    printf("\n");

    printf("ABI:           %s\n",
#if __riscv_xlen == 32
           "ilp32"
#else
           "lp64"
#endif
    );

    printf("Compiler:      %s\n", __VERSION__);
    printf("Build date:    %s %s\n", __DATE__, __TIME__);

    /* Performance counters */
    printf("\n--- Performance Counters ---\n");
    unsigned long c1 = read_cycle();
    unsigned long t1 = read_time();
    unsigned long i1 = read_instret();

    /* Do a small workload */
    volatile int sum = 0;
    for (int i = 0; i < 1000; i++)
        sum += i;

    unsigned long c2 = read_cycle();
    unsigned long t2 = read_time();
    unsigned long i2 = read_instret();

    printf("Workload:      sum(0..999) = %d\n", sum);
    printf("Cycles:        %lu\n", c2 - c1);
    printf("Instructions:  %lu\n", i2 - i1);
    printf("Timer ticks:   %lu\n", t2 - t1);
    if (i2 > i1 && c2 > c1)
    {
        unsigned long cpi_x100 = (c2 - c1) * 100 / (i2 - i1);
        printf("CPI (x100):   %lu.%02lu\n", cpi_x100 / 100, cpi_x100 % 100);
    }

    printf("\n--- Pointer Sizes ---\n");
    printf("sizeof(int):       %lu\n", (unsigned long)sizeof(int));
    printf("sizeof(long):      %lu\n", (unsigned long)sizeof(long));
    printf("sizeof(void*):     %lu\n", (unsigned long)sizeof(void *));
    printf("sizeof(size_t):    %lu\n", (unsigned long)sizeof(size_t));

    printf("\n[sysinfo: done]\n");
    return 0;
}
