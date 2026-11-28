/* hello.c: Simple hello world test for RISC-V on NPC (via pk) */

#include <stdio.h>

int main(void)
{
#ifdef __GLIBC__
    printf("Hello from Raptor Linux!\n");
#elif defined(__FreeBSD__)
    printf("Hello from Raptor FreeBSD!\n");
#elif defined(__NetBSD__)
    printf("Hello from Raptor NetBSD!\n");
#else
    printf("Hello from pk!\n");
#endif
    return 0;
}
