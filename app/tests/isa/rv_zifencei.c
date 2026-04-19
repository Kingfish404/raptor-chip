/* rv_zifencei.c: Test Zifencei (fence.i) — instruction-fetch fence
 *
 * Zifencei provides FENCE.I (opcode MISC-MEM, funct3=001) which ensures
 * earlier stores to instruction memory are visible to subsequent fetches
 * on the same hart. Under riscv-pk / user mode we cannot reliably modify
 * .text (it's typically read-only / ICache-backed), so we focus on:
 *   1) FENCE.I executes without faulting.
 *   2) FENCE.I acts as a serialization boundary (does not corrupt state).
 *   3) Interleaved data/inst fences coexist.
 *
 * A fuller self-modifying-code test (writable RWX buffer) is out of scope
 * here because pk does not grant RWX pages by default.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define CHECK(cond, msg)                                   \
    do                                                     \
    {                                                      \
        if (!(cond))                                       \
        {                                                  \
            printf("FAIL: %s (line %d)\n", msg, __LINE__); \
            fail++;                                        \
        }                                                  \
        else                                               \
        {                                                  \
            pass++;                                        \
        }                                                  \
    } while (0)

__attribute__((noinline)) static int do_add(int a, int b)
{
    int r = a + b;
    asm volatile("fence.i" ::: "memory");
    return r;
}

int main(void)
{
    int pass = 0, fail = 0;

    /* ---- FENCE.I alone ---- */
    {
        asm volatile("fence.i" ::: "memory");
        pass++; /* reached here without trap */
    }

    /* ---- FENCE.I repeated ---- */
    {
        for (int i = 0; i < 64; i++)
            asm volatile("fence.i" ::: "memory");
        pass++;
    }

    /* ---- FENCE.I mixed with data fences ---- */
    {
        asm volatile("fence rw, rw" ::: "memory");
        asm volatile("fence.i" ::: "memory");
        asm volatile("fence r, w" ::: "memory");
        asm volatile("fence.i" ::: "memory");
        asm volatile("fence w, r" ::: "memory");
        pass++;
    }

    /* ---- FENCE.I interleaved with normal compute: result unaffected ---- */
    {
        int acc = 0;
        for (int i = 0; i < 100; i++)
        {
            acc = do_add(acc, i);
        }
        CHECK(acc == 4950, "fence.i does not corrupt compute state");
    }

    /* ---- Raw encoding check: FENCE.I = 0x0000100f ----
     * (MISC-MEM opcode=0001111, funct3=001, rd=rs1=0, imm=0) */
    {
        asm volatile(".4byte 0x0000100f"); /* FENCE.I */
        pass++;
    }

    printf("rv_zifencei: %d passed, %d failed\n", pass, fail);
    return fail ? EXIT_FAILURE : EXIT_SUCCESS;
}
