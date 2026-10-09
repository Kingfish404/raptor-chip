/* Run only with SIM_MEM_PROFILE=large. Exit through the SiFive test finisher. */
#include "raptor_platform.h"
.option norvc
.section .text
.globl _start
_start:
    /* Two addresses formerly occupied by SDRAM or the high I/O aperture. */
    li t0, 0xa0000000
    li t1, 0x13579bdf
    sw t1, 0(t0)
    lw t2, 0(t0)
    bne t1, t2, fail

    li t0, 0xc0000000
    li t1, 0x2468ace0
    sw t1, 0(t0)
    lw t2, 0(t0)
    bne t1, t2, fail

    /* The former LiteX UART address is RAM in this profile. */
    li t0, 0xf0001800
    li t1, 0x00000041
    sw t1, 0(t0)
    lw t2, 0(t0)
    bne t1, t2, fail

    /* The last naturally aligned 32-bit word must not wrap the PMEM end. */
    li t0, RAPTOR_MAIN_RAM_BASE + RAPTOR_MAIN_RAM_MAX_SIZE - 4
    li t1, 0x5a69c3d2
    sw t1, 0(t0)
    lw t2, 0(t0)
    bne t1, t2, fail
    li t1, 0x7b
    sb t1, 3(t0)
    lbu t2, 3(t0)
    bne t1, t2, fail

#if __riscv_xlen == 64
    /* Both accepted RV64 encodings of the 32-bit physical address. */
    li t0, 0xc0000000
    slli t0, t0, 32
    srli t0, t0, 32
    lw t2, 0(t0)
    li t1, 0x2468ace0
    bne t1, t2, fail

    /* Arbitrary upper bits must fault instead of aliasing the RAM below. */
    la t0, invalid_upper_trap
    csrw mtvec, t0
    li t0, 0x00000002a0000000
    lw t2, 0(t0)
    j fail
invalid_upper_resume:
#endif

pass:
    li t0, RAPTOR_FINISHER_BASE
    li t1, 0x5555
    sw t1, 0(t0)
1:  j 1b

fail:
    li t0, RAPTOR_FINISHER_BASE
    li t1, 0x3333
    sw t1, 0(t0)
2:  j 2b

#if __riscv_xlen == 64
invalid_upper_trap:
    csrr t0, mcause
    li t1, 5
    bne t0, t1, fail
    la t0, invalid_upper_resume
    csrw mepc, t0
    mret
#endif
