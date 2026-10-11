#include <errno.h>
#include <stddef.h>
#include <stdint.h>

/* The embedded-ELF loader reserves no brk growth range. Reserve an anonymous
 * arena once, then expose the usual sbrk interface to Picolibc's allocator. */
#define HEAP_BYTES (64UL * 1024 * 1024)

static uintptr_t pk_heap_map(void)
{
    register uintptr_t a0 __asm__("a0") = 0;
    register uintptr_t a1 __asm__("a1") = HEAP_BYTES;
    register uintptr_t a2 __asm__("a2") = 3;    /* PROT_READ | PROT_WRITE */
    register uintptr_t a3 __asm__("a3") = 0x22; /* MAP_PRIVATE | MAP_ANONYMOUS */
    register uintptr_t a4 __asm__("a4") = (uintptr_t)-1;
    register uintptr_t a5 __asm__("a5") = 0;
    register uintptr_t a7 __asm__("a7") = 222;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a3), "r"(a4), "r"(a5), "r"(a7) : "memory");
    return a0;
}

void *sbrk(ptrdiff_t increment)
{
    static uintptr_t base, used;
    if (!base) {
        uintptr_t mapped = pk_heap_map();
        if (!mapped || mapped >= (uintptr_t)-4095) {
            errno = ENOMEM;
            return (void *)-1;
        }
        base = mapped;
    }
    if ((increment >= 0 && (uintptr_t)increment > HEAP_BYTES - used) ||
        (increment < 0 && (uintptr_t)(-(increment + 1)) + 1 > used)) {
        errno = ENOMEM;
        return (void *)-1;
    }
    void *old = (void *)(base + used);
    used += increment;
    return old;
}
