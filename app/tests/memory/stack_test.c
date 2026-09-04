/* stack_test.c: Test stack operations, deep recursion, and large stack frames */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); fail++; } \
    else { pass++; } \
} while (0)

static int pass = 0, fail = 0;

/* Deep recursion to stress stack growth */
__attribute__((noinline))
int fibonacci(int n) {
    if (n <= 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
}

/* Large local array to stress stack frame */
__attribute__((noinline))
int large_frame(void) {
    volatile int arr[256];
    for (int i = 0; i < 256; i++)
        arr[i] = i * i;
    int sum = 0;
    for (int i = 0; i < 256; i++)
        sum += arr[i];
    return sum;
}

/* Touch a 64 KiB frame sparsely so PK must fault in multiple stack pages.
 * Distinct markers catch aliasing or corruption while later pages fault in.
 */
__attribute__((noinline))
int paged_frame(void) {
    enum { PAGE_WORDS = 4096 / sizeof(uint32_t), PAGES = 16 };
    volatile uint32_t arr[PAGES * PAGE_WORDS];
    for (int page = 0; page < PAGES; page++) {
        arr[page * PAGE_WORDS] = 0x12340000u + page;
        arr[(page + 1) * PAGE_WORDS - 1] = 0xabcd0000u + page;
    }
    for (int page = PAGES - 1; page >= 0; page--) {
        if (arr[page * PAGE_WORDS] != 0x12340000u + page ||
            arr[(page + 1) * PAGE_WORDS - 1] != 0xabcd0000u + page)
            return 0;
    }
    return 1;
}

/* Function with many saved registers */
__attribute__((noinline))
long many_regs(long a, long b, long c, long d,
               long e, long f, long g, long h) {
    volatile long v1 = a + b;
    volatile long v2 = c + d;
    volatile long v3 = e + f;
    volatile long v4 = g + h;
    volatile long v5 = v1 * v2;
    volatile long v6 = v3 * v4;
    return v5 + v6;
}

/* Nested calls to verify return address save/restore */
__attribute__((noinline))
int nest3(int x) { return x + 3; }
__attribute__((noinline))
int nest2(int x) { return nest3(x + 2); }
__attribute__((noinline))
int nest1(int x) { return nest2(x + 1); }

int main(void) {
    /* fibonacci recursion */
    CHECK(fibonacci(0) == 0, "fib(0) = 0");
    CHECK(fibonacci(1) == 1, "fib(1) = 1");
    CHECK(fibonacci(10) == 55, "fib(10) = 55");
    CHECK(fibonacci(20) == 6765, "fib(20) = 6765");

    /* large stack frame */
    {
        /* sum of i^2 for i=0..255 = 255*256*511/6 = 5559680 */
        int result = large_frame();
        CHECK(result == 5559680, "large stack frame: sum of squares");
    }

    CHECK(paged_frame(), "demand-paged stack: distinct markers across 64 KiB");

    /* many registers */
    {
        long result = many_regs(1, 2, 3, 4, 5, 6, 7, 8);
        /* v1=3, v2=7, v3=11, v4=15 -> v5=21, v6=165 -> 186 */
        CHECK(result == 186, "many saved registers");
    }

    /* nested calls */
    CHECK(nest1(0) == 6, "nested calls: 0+1+2+3 = 6");
    CHECK(nest1(10) == 16, "nested calls: 10+1+2+3 = 16");

    /* verify stack pointer alignment (RISC-V ABI: 16-byte aligned) */
    {
        long sp;
        asm volatile("mv %0, sp" : "=r"(sp));
        CHECK((sp & 0xF) == 0, "stack pointer is 16-byte aligned");
    }

    printf("stack_test: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
