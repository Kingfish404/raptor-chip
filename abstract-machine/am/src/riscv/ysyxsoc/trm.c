#include <am.h>
#include <ysyxsoc.h>
#include <klib-macros.h>

extern char _heap_start;
int main(const char *args);

extern char _pmem_start;
#define PMEM_SIZE (128 * 1024 * 1024)
#define PMEM_END ((uintptr_t) & _pmem_start + PMEM_SIZE)

Area heap = RANGE(&_heap_start, PMEM_END);
#ifndef MAINARGS
#define MAINARGS ""
#endif
static const char mainargs[] = MAINARGS;

void putch(char ch)
{
    outb(UART16550_ADDR, ch);
}

void halt(int code)
{
    asm volatile("ebreak");
    while (1)
        ;
}

void _trm_init()
{
    // int ret = main(mainargs);
    int ret;
    // asm volatile(
    //     "li a0, 0\n\t"
    //     "mv a0, %1\n\t"
    //     "jal main\n\t"
    //     "mv %0, a0\n\t"
    //     : "=r"(ret)
    //     : "r"(mainargs));
    halt(ret);
}
