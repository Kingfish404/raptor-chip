/* Supply normal MITH command-line options without changing workload sources. */
#include <stdio.h>

#define STRINGIFY_(x) #x
#define STRINGIFY(x) STRINGIFY_(x)
extern int __real_main(int argc, char **argv);

int __wrap_main(int argc, char **argv)
{
#ifndef __GLIBC__
    /* The pk startup preserves its own tp; picolibc requires this ELF's TLS. */
    __asm__ volatile("la tp, __tls_base" ::: "memory");
#endif
    if (argc > 1)
        return __real_main(argc, argv);
    char *defaults[] = {
        "raptor", "-i" STRINGIFY(CMP_ITERATIONS), "-c1", "-w1",
        "-v" STRINGIFY(CMP_VERIFY), "-P=Raptor-RV" STRINGIFY(__riscv_xlen), 0
    };
    return __real_main(6, defaults);
}
