/* Supply normal MITH command-line options without changing workload sources. */
#include <stdio.h>

#define STRINGIFY_(x) #x
#define STRINGIFY(x) STRINGIFY_(x)
extern int __real_main(int argc, char **argv);

int __wrap_main(int argc, char **argv)
{
    /* The pk startup preserves its own tp; libc requires this ELF's TLS. */
    __asm__ volatile("la tp, __tls_base" ::: "memory");
    char *defaults[] = {
        "raptor", "-i" STRINGIFY(CMP_ITERATIONS), "-c1", "-w1",
        "-v" STRINGIFY(CMP_VERIFY), "-P=Raptor-RV" STRINGIFY(__riscv_xlen), 0
    };
    (void)argc;
    (void)argv;
    return __real_main(6, defaults);
}
