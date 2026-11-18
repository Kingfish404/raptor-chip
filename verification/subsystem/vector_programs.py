#!/usr/bin/env python3
"""Shared RV32/RV64 vector integration payloads; all generated files live in --output."""

import argparse
import json
from pathlib import Path
import re


SOURCES = {
    "program": r"""#include <riscv_vector.h>

void _start(void) {
    __asm__ volatile ("li t3, 0x2200; csrs mstatus, t3" : : : "t3", "memory");
    size_t count = __riscv_vsetvl_e32m1(4);
    vint32m1_t a = __riscv_vmv_v_x_i32m1(3, count);
    vint32m1_t b = __riscv_vadd_vx_i32m1(a, 4, count);
    vint32m1_t c = __riscv_vadd_vv_i32m1(a, b, count);
    volatile int32_t *input = (volatile int32_t *)0x80001000UL;
    volatile int32_t *output = (volatile int32_t *)0x80001020UL;
    for (int i = 0; i < 4; ++i) input[i] = i + 10;
    vint32m1_t loaded = __riscv_vle32_v_i32m1((const int32_t *)input, count);
    vint32m1_t sum = __riscv_vadd_vv_i32m1(loaded, c, count);
    __riscv_vse32_v_i32m1((int32_t *)output, sum, count);
    volatile int32_t *segments = (volatile int32_t *)0x80001040UL;
    __asm__ volatile ("vsetivli zero, 2, e32, m1, ta, ma\n"
                      "vlseg2e32.v v8, (%0)\n"
                      "vsseg2e32.v v8, (%1)\n"
                      "vsetivli zero, 4, e32, m1, ta, ma"
                      : : "r"(output), "r"(segments) : "v8", "v9", "memory");
    volatile uint32_t *fp_input = (volatile uint32_t *)0x80001080UL;
    volatile uint32_t *fp_output = (volatile uint32_t *)0x800010a0UL;
    fp_input[0] = 0x3f800000U;
    fp_input[1] = 0x40000000U;
    fp_input[2] = 0xbf800000U;
    fp_input[3] = 0x3f000000U;
    __asm__ volatile ("" : : : "memory");
    vfloat32m1_t f = __riscv_vle32_v_f32m1((const float *)fp_input, 4);
    vfloat32m1_t doubled = __riscv_vfadd_vv_f32m1(f, f, 4);
    __riscv_vse32_v_f32m1((float *)fp_output, doubled, 4);
    volatile uint32_t *fp_scalar_out = (volatile uint32_t *)0x800010c0UL;
    float scalar = *(volatile float *)fp_input;
    vfloat32m1_t shifted = __riscv_vfadd_vf_f32m1(f, scalar, 4);
    __riscv_vse32_v_f32m1((float *)fp_scalar_out, shifted, 4);
    uint32_t extracted;
    __asm__ volatile ("vle32.v v8, (%1)\n"
                      "vfmv.f.s ft0, v8\n"
                      "fmv.x.w %0, ft0"
                      : "=r"(extracted) : "r"(fp_scalar_out)
                      : "v8", "ft0", "memory");
    __asm__ volatile ("csrw fflags, zero" : : : "memory");
    vfloat32m1_t zero = __riscv_vfsub_vv_f32m1(f, f, 4);
    vfloat32m1_t invalid = __riscv_vfdiv_vv_f32m1(zero, zero, 4);
    volatile uint32_t *fp_invalid_out = (volatile uint32_t *)0x800010e0UL;
    __riscv_vse32_v_f32m1((float *)fp_invalid_out, invalid, 4);
    unsigned long accrued_flags;
    __asm__ volatile ("csrr %0, fflags" : "=r"(accrued_flags) : : "memory");
    volatile int64_t *wide_input = (volatile int64_t *)0x80001100UL;
    volatile int64_t *wide_output = (volatile int64_t *)0x80001120UL;
    volatile uint32_t *wide_input_words = (volatile uint32_t *)wide_input;
    volatile uint32_t *wide_output_words = (volatile uint32_t *)wide_output;
    wide_input_words[0] = 0x55667788U;
    wide_input_words[1] = 0x11223344U;
    wide_input_words[2] = 0xfffffffdU;
    wide_input_words[3] = 0xffffffffU;
    vint64m1_t wide = __riscv_vle64_v_i64m1((const int64_t *)wide_input, 2);
    wide = __riscv_vadd_vx_i64m1(wide, 4, 2);
    __riscv_vse64_v_i64m1((int64_t *)wide_output, wide, 2);
    int wide_ok = wide_output_words[0] == 0x5566778cU
        && wide_output_words[1] == 0x11223344U
        && wide_output_words[2] == 1 && wide_output_words[3] == 0;
    volatile uint32_t *fp64_input = (volatile uint32_t *)0x80001160UL;
    volatile uint32_t *fp64_output = (volatile uint32_t *)0x80001180UL;
    fp64_input[0] = 0;
    fp64_input[1] = 0x3ff80000U;
    fp64_input[2] = 0;
    fp64_input[3] = 0xc0040000U;
    vfloat64m1_t doubles = __riscv_vle64_v_f64m1((const double *)fp64_input, 2);
    doubles = __riscv_vfadd_vv_f64m1(doubles, doubles, 2);
    __riscv_vse64_v_f64m1((double *)fp64_output, doubles, 2);
    int wide_fp_ok = fp64_output[0] == 0 && fp64_output[1] == 0x40080000U
        && fp64_output[2] == 0 && fp64_output[3] == 0xc0140000U;
    int uart_ready = (*(volatile uint8_t *)0x10000005UL & 0x20) != 0;
    int memory_ok = uart_ready && wide_ok && wide_fp_ok && output[0] == 20 && output[1] == 21
        && output[2] == 22 && output[3] == 23
        && segments[0] == 20 && segments[1] == 21
        && segments[2] == 22 && segments[3] == 23
        && fp_output[0] == 0x40000000U && fp_output[1] == 0x40800000U
        && fp_output[2] == 0xc0000000U && fp_output[3] == 0x3f800000U
        && fp_scalar_out[0] == 0x40000000U && fp_scalar_out[1] == 0x40400000U
        && fp_scalar_out[2] == 0 && fp_scalar_out[3] == 0x3fc00000U
        && extracted == 0x40000000U && (accrued_flags & 0x10) != 0
        && fp_invalid_out[0] == 0x7fc00000U;
    int element = __riscv_vmv_x_s_i32m1_i32(c);
    __asm__ volatile ("vsetivli zero, 4, e32, m1, ta, ma" : : "r"(element) : "memory");
    unsigned long vl, vlenb, vxrm, status, misa;
    __asm__ volatile ("csrr %0, misa" : "=r"(misa));
    __asm__ volatile ("csrr %0, vl" : "=r"(vl));
    __asm__ volatile ("csrr %0, vlenb" : "=r"(vlenb));
    __asm__ volatile ("csrwi vxrm, 2");
    __asm__ volatile ("csrr %0, vxrm" : "=r"(vxrm));
    __asm__ volatile ("csrr %0, mstatus" : "=r"(status));
    register int result __asm__("a0") = element == 10 && memory_ok && vl == 4
        && vlenb == 16 && vxrm == 2 && ((misa >> 21) & 1) == 1
        && ((status >> 9) & 3) == 3
        && ((status >> 13) & 3) == 3 ? 10 : -1;
    __asm__ volatile ("ebreak" : : "r"(result) : "memory");
    for (;;) {}
}
""",
    "trap": r""".option norvc
.section .text
.global _start
_start:
    la t0, trap_handler
    csrw mtvec, t0
    li s4, 0
    vsetivli zero, 4, e32, m1, tu, mu
    csrr t1, vl
    li t2, 0x200
    csrs mstatus, t2
    csrw vl, zero
    vsetivli t0, 4, e32, m1, tu, mu
    csrr t1, mstatus
    andi t1, t1, 0x600
    li t2, 0x600
    bne t1, t2, fail
    li t0, 3
    bne s4, t0, fail
    li a0, 10
    ebreak
fail:
    li a0, -1
    ebreak
.align 2
trap_handler:
    csrr t0, mcause
    li t1, 2
    bne t0, t1, fail
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    addi s4, s4, 1
    mret
""",
    "restart": r""".option norvc
.section .text
.global _start
_start:
    la t0, trap_handler
    csrw mtvec, t0
    li s4, 0
    li t0, 0x200
    csrs mstatus, t0
    lui ra, 0x0f001
    li t0, 99
    sw t0, 16(ra)
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v8, 5
retry_store:
    vse32.v v8, (ra)
    csrr t0, vstart
    bnez t0, fail
    lw t0, 0(ra)
    li t1, 5
    bne t0, t1, fail
    lw t0, 4(ra)
    bne t0, t1, fail
    lw t0, 8(ra)
    bne t0, t1, fail
    lw t0, 12(ra)
    bne t0, t1, fail
    lw t0, 16(ra)
    li t1, 99
    bne t0, t1, fail
    li t0, 1
    bne s4, t0, fail
    li a0, 10
    ebreak
fail:
    li a0, -1
    ebreak
.align 2
trap_handler:
    csrr t0, mcause
    li t1, 7
    bne t0, t1, fail
    csrr t0, mtval
    addi t1, ra, 8
    bne t0, t1, fail
    csrr t0, vstart
    li t1, 2
    bne t0, t1, fail
    csrr t0, mepc
    la t1, retry_store
    bne t0, t1, fail
    addi s4, s4, 1
    mret
""",
    "read-restart": r""".option norvc
.section .text
.global _start
_start:
    la t0, trap_handler
    csrw mtvec, t0
    li s4, 0
    li t0, 0x200
    csrs mstatus, t0
    lui ra, 0x80001
    li t2, 64
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v8, -1
retry_load:
    vlse32.v v8, (ra), t2
    csrr t0, vstart
    bnez t0, fail
    li t0, 1
    bne s4, t0, fail
    addi t3, ra, 512
    vse32.v v8, (t3)
    lw t0, 0(t3)
    li t1, 11
    bne t0, t1, fail
    lw t0, 4(t3)
    li t1, 22
    bne t0, t1, fail
    lw t0, 8(t3)
    li t1, 33
    bne t0, t1, fail
    lw t0, 12(t3)
    li t1, 44
    bne t0, t1, fail
    li a0, 10
    ebreak
fail:
    li a0, -1
    ebreak
.align 2
trap_handler:
    csrr t0, mcause
    li t1, 5
    bne t0, t1, fail
    csrr t0, mtval
    addi t1, ra, 128
    bne t0, t1, fail
    csrr t0, vstart
    li t1, 2
    bne t0, t1, fail
    csrr t0, mepc
    la t1, retry_load
    bne t0, t1, fail
    addi s4, s4, 1
    mret
.org 0x1000
    .word 11
.org 0x1040
    .word 22
.org 0x1080
    .word 33
.org 0x10c0
    .word 44
""",
    "read-fof": r""".option norvc
.section .text
.global _start
_start:
    la t0, trap_handler
    csrw mtvec, t0
    li s4, 0
    li t0, 0x200
    csrs mstatus, t0
    lui ra, 0x80001
    addi ra, ra, 56
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v8, -1
retry_load:
    vle32ff.v v8, (ra)
    csrr t0, vl
#ifdef FIRST_FAULT
    li t1, 4
    bne t0, t1, fail
    li t0, 1
    bne s4, t0, fail
#else
    li t1, 2
    bne t0, t1, fail
    bnez s4, fail
#endif
    vsetivli zero, 4, e32, m1, tu, mu
    addi t3, ra, 456
    vse32.v v8, (t3)
    lw t0, 0(t3)
    li t1, 11
    bne t0, t1, fail
    lw t0, 4(t3)
    li t1, 22
    bne t0, t1, fail
#ifdef FIRST_FAULT
    li t1, 33
#else
    li t1, -1
#endif
    lw t0, 8(t3)
    bne t0, t1, fail
#ifdef FIRST_FAULT
    li t1, 44
#endif
    lw t0, 12(t3)
    bne t0, t1, fail
    li a0, 10
    ebreak
fail:
    li a0, -1
    ebreak
.align 2
trap_handler:
#ifdef FIRST_FAULT
    csrr t0, mcause
    li t1, 5
    bne t0, t1, fail
    csrr t0, mtval
    bne t0, ra, fail
    csrr t0, vstart
    bnez t0, fail
    csrr t0, mepc
    la t1, retry_load
    bne t0, t1, fail
    addi s4, s4, 1
    mret
#else
    j fail
#endif
.org 0x1038
    .word 11, 22, 33, 44
""",
    "wide-restart": r""".option norvc
.section .text
.global _start
_start:
    la t0, trap_handler
    csrw mtvec, t0
    li s4, 0
    li t0, 0x200
    csrs mstatus, t0
    lui ra, 0x0f001
    li t0, 99
    sw t0, 16(ra)
    vsetivli zero, 2, e64, m1, tu, mu
    vmv.v.i v8, -1
retry_store:
    vse64.v v8, (ra)
    csrr t0, vstart
    bnez t0, fail
    lw t0, 0(ra)
    li t1, -1
    bne t0, t1, fail
    lw t0, 4(ra)
    bne t0, t1, fail
    lw t0, 8(ra)
    bne t0, t1, fail
    lw t0, 12(ra)
    bne t0, t1, fail
    lw t0, 16(ra)
    li t1, 99
    bne t0, t1, fail
    li t0, 1
    bne s4, t0, fail
    li a0, 10
    ebreak
fail:
    li a0, -1
    ebreak
.align 2
trap_handler:
    csrr t0, mcause
    li t1, 7
    bne t0, t1, fail
    csrr t0, mtval
    addi t1, ra, 12
    bne t0, t1, fail
    csrr t0, vstart
    li t1, 1
    bne t0, t1, fail
    csrr t0, mepc
    la t1, retry_store
    bne t0, t1, fail
    addi s4, s4, 1
    mret
""",
    "probe": r""".option norvc
.section .text
.global _start
_start:
    la t0, trap_handler
    csrw mtvec, t0
    li t0, 0x200
    csrs mstatus, t0
    li s4, 0
    vsetivli zero, 2, e32, m1, tu, mu
    lui a1, 0x10000
    vlseg2e32.v v8, (a1)
#if __riscv_xlen == 32
    vsetivli zero, 2, e64, m1, tu, mu
    vle64.v v8, (a1)
    vse64.v v8, (a1)
    li t0, 3
#else
    li t0, 1
#endif
    bne s4, t0, fail
    li a0, 10
    ebreak
fail:
    li a0, -1
    ebreak
.align 2
trap_handler:
    csrr t0, mcause
    li t1, 5
    li t2, 2
    bne s4, t2, check_cause
    li t1, 7
check_cause:
    bne t0, t1, fail
    csrr t0, mtval
    bne t0, a1, fail
    csrr t0, vstart
    bnez t0, fail
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    addi s4, s4, 1
    mret
""",
    "device": r""".option norvc
.section .text
.global _start
_start:
    la t0, trap_handler
    csrw mtvec, t0
    li t0, 0x200
    csrs mstatus, t0
    li s4, 0
    li a1, 0x10000040
#ifdef NATIVE_DEVICE_BOARD
    li t0, 0x10000080
#if DEVICE_CASE == 0
    li t1, (0x300 | FAULT_INDEX)
#elif DEVICE_CASE == 1
    li t1, (0x100 | FAULT_INDEX)
#elif DEVICE_CASE == 2
    li t1, 0x301
#elif DEVICE_CASE == 4
    li t1, 0x320
#else
    li t1, 0
#endif
    sw t1, 0(t0)
#endif
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v8, -1
#if DEVICE_CASE == 0
retry_load:
    vle32.v v8, (a1)
retry_store:
    vse32.v v8, (a1)
    li t0, 2
    bne s4, t0, fail
    li s3, 4
#elif DEVICE_CASE == 1
retry_load:
    vle32ff.v v8, (a1)
#if FAULT_INDEX == 0
    li t0, 1
    bne s4, t0, fail
    li s3, 4
#else
    bnez s4, fail
    li s3, FAULT_INDEX
#endif
    csrr t0, vl
    bne t0, s3, fail
#elif DEVICE_CASE == 2
    vsetivli zero, 4, e8, m1, tu, mu
    li t0, 5
    vmv.s.x v0, t0
    vsetivli zero, 4, e32, m1, tu, mu
    li t0, 1
    csrw vstart, t0
    vle32.v v8, (a1), v0.t
    li t0, 1
    csrw vstart, t0
    vse32.v v8, (a1), v0.t
    bnez s4, fail
    li s3, 4
#elif DEVICE_CASE == 4
    vmv.v.i v16, 0
retry_load:
    vloxei32.v v8, (a1), v16
retry_store:
    vsoxei32.v v8, (a1), v16
    li t0, 2
    bne s4, t0, fail
    li s3, 4
#else
retry_load:
    vlseg2e32.v v8, (a1)
retry_store:
    vsseg2e32.v v8, (a1)
    li t0, 2
    bne s4, t0, fail
    vmv.v.i v0, 0
    vlseg2e32.v v8, (a1), v0.t
    vsseg2e32.v v8, (a1), v0.t
#endif
    csrr t0, vstart
    bnez t0, fail
#if DEVICE_CASE != 3
    li t3, 0x80002000
    vse32.v v8, (t3)
    li t2, 0
check_values:
    lw t0, 0(t3)
#if DEVICE_CASE == 2
    li t1, -1
    li t4, 2
    bne t2, t4, compare_value
#endif
    li t1, 0x41410000
#if DEVICE_CASE == 4
    slli t4, t2, 8
    add t1, t1, t4
#else
    add t1, t1, t2
#endif
compare_value:
    bne t0, t1, fail
    addi t3, t3, 4
    addi t2, t2, 1
    bltu t2, s3, check_values
#endif
#ifdef NATIVE_DEVICE_BOARD
    li t0, 0x10000084
    lw t1, 0(t0)
#if DEVICE_CASE == 0
    li t2, 0x000f000f
#elif DEVICE_CASE == 1
    li t2, 0x00000003
#elif DEVICE_CASE == 2
    li t2, 0x00040004
#elif DEVICE_CASE == 4
    li t2, 0x00010001
#else
    li t2, 0
#endif
    bne t1, t2, fail
    lw t1, 4(t0)
#if DEVICE_CASE == 0
    li t2, 0x02010201
#elif DEVICE_CASE == 1
    li t2, 0x00000100
#elif DEVICE_CASE == 4
    li t2, 0x05040504
#else
    li t2, 0
#endif
    bne t1, t2, fail
    lw t1, 8(t0)
#if DEVICE_CASE == 0
    li t2, 0x41410002
#elif DEVICE_CASE == 4
    li t2, 0x41410300
#else
    li t2, 0
#endif
    bne t1, t2, fail
    lw t1, 12(t0)
#if DEVICE_CASE == 0 || DEVICE_CASE == 4
    li t2, 0x00040004
#elif DEVICE_CASE == 1
    li t2, 0x00000002
#elif DEVICE_CASE == 2
    li t2, 0x00010001
#else
    li t2, 0
#endif
    bne t1, t2, fail
    lw t1, 16(t0)
#if DEVICE_CASE == 0 || DEVICE_CASE == 4
    li t2, 0x00050005
#elif DEVICE_CASE == 1
    li t2, 0x00000003
#elif DEVICE_CASE == 2
    li t2, 0x00010001
#else
    li t2, 0
#endif
    bne t1, t2, fail
#ifdef NATIVE_DEVICE_NEGATIVE
    j fail
#endif
    la t3, board_pass
    j board_print
#else
    li a0, 10
    ebreak
#endif
fail:
#ifdef NATIVE_DEVICE_BOARD
    la t3, board_fail
    j board_print
#else
    li a0, -1
    ebreak
#endif
.align 2
trap_handler:
#if DEVICE_CASE == 2
    j fail
#else
    csrr t0, mcause
    li t1, 5
#if DEVICE_CASE == 0 || DEVICE_CASE == 3 || DEVICE_CASE == 4
    beqz s4, check_cause
    li t1, 7
check_cause:
#endif
    bne t0, t1, fail
    csrr t0, mtval
#if DEVICE_CASE == 3 || DEVICE_CASE == 4
    mv t1, a1
#else
    li t1, FAULT_INDEX
    slli t1, t1, 2
    add t1, a1, t1
#endif
    bne t0, t1, fail
    csrr t0, vstart
#if DEVICE_CASE == 3
    bnez t0, fail
#else
    li t1, FAULT_INDEX
    bne t0, t1, fail
#endif
    csrr t0, mepc
    la t1, retry_load
#if DEVICE_CASE == 0 || DEVICE_CASE == 3 || DEVICE_CASE == 4
    beqz s4, check_pc
    la t1, retry_store
check_pc:
#endif
    bne t0, t1, fail
#if DEVICE_CASE == 3
    addi t0, t0, 4
    csrw mepc, t0
#endif
    addi s4, s4, 1
    mret
#endif
#ifdef NATIVE_DEVICE_BOARD
board_print:
    li t0, 0x10000000
board_print_next:
    lbu t1, 0(t3)
    beqz t1, board_halt
board_print_wait:
    lbu t2, 5(t0)
    andi t2, t2, 0x20
    beqz t2, board_print_wait
    sb t1, 0(t0)
    addi t3, t3, 1
    j board_print_next
board_halt:
    j board_halt
board_pass:
    .asciz "NATIVE PAYLOAD PASS\r\n"
board_fail:
    .asciz "NATIVE PAYLOAD FAIL\r\n"
#endif
""",
    "wide-fault": r""".option norvc
.section .text
.global _start
_start:
    la t0, wide_handler
    csrw mtvec, t0
    li t0, 0x200
    csrs mstatus, t0
    li s4, 0
    li a1, FAULT_BASE
#if !FAULT_WRITE
    /* Partial scalar stores initialize the SRAM without allocating L1D words. */
    li t0, 0x1111
    sh t0, 0(a1)
    sh t0, 2(a1)
    li t0, 0x2222
    sh t0, 4(a1)
    sh t0, 6(a1)
    li t0, 0x3333
    sh t0, 64(a1)
    sh t0, 66(a1)
    li t0, 0x4444
    sh t0, 68(a1)
    sh t0, 70(a1)
    fence rw, rw
#endif
    li t2, 64
    vsetivli zero, 2, e64, m1, tu, mu
    vmv.v.i v8, -1
wide_access:
#if FAULT_WRITE
    vsse64.v v8, (a1), t2
#else
    vlse64.v v8, (a1), t2
#endif
    csrr t0, vstart
    bnez t0, wide_fail
    li t0, 1
    bne s4, t0, wide_fail
#if FAULT_WRITE
    lw t0, 0(a1)
    li t1, -1
    bne t0, t1, wide_fail
    lw t0, 4(a1)
    bne t0, t1, wide_fail
    lw t0, 64(a1)
    bne t0, t1, wide_fail
    lw t0, 68(a1)
    bne t0, t1, wide_fail
#else
    addi t3, a1, 512
    vse64.v v8, (t3)
    lw t0, 0(t3)
    li t1, 0x11111111
    bne t0, t1, wide_fail
    lw t0, 4(t3)
    li t1, 0x22222222
    bne t0, t1, wide_fail
    lw t0, 8(t3)
    li t1, 0x33333333
    bne t0, t1, wide_fail
    lw t0, 12(t3)
    li t1, 0x44444444
    bne t0, t1, wide_fail
#endif
    li a0, 10
    ebreak
.align 2
wide_handler:
    csrr t0, mcause
#if FAULT_WRITE
    li t1, 7
#else
    li t1, 5
#endif
    bne t0, t1, wide_bad_metadata
    csrr t0, mtval
    li t1, (FAULT_INDEX * 64 + FAULT_HALF * 4)
    add t1, a1, t1
    bne t0, t1, wide_bad_metadata
    csrr t0, vstart
    li t1, FAULT_INDEX
    bne t0, t1, wide_bad_metadata
    csrr t0, mepc
    la t1, wide_access
    bne t0, t1, wide_bad_metadata
    addi s4, s4, 1
    mret
wide_bad_metadata:
    mv a0, t0
    ebreak
wide_fail:
    mv a0, s4
    ebreak
""",
    "page": r""".option norvc
.section .text
.global _start
_start:
    la t0, page_handler
    csrw mtvec, t0
    li s4, 0
    li t0, -1
    csrw pmpaddr0, t0
    li t0, 0x1f
    csrw pmpcfg0, t0

    li t3, 0x80004ff8
    li t0, 0x111
    sw t0, 0(t3)
    li t0, 0x222
    sw t0, 4(t3)
    li t3, 0x80006000
    li t0, 0x333
    sw t0, 0(t3)
    li t0, 0x444
    sw t0, 4(t3)

    li s0, 0x80002000
    li t0, 0x200000cf
#if __riscv_xlen == 64
    sd t0, 16(s0)
    li t3, 4080
    add t3, s0, t3
    sd t0, 0(t3)
    li t0, 0x20000c01
    sd t0, 8(s0)
    li t3, 0x80003000
    li t0, 0x20001401
    sd t0, 0(t3)
    li s1, 0x80005000
    li t0, 0x200010cf
    sd t0, 0(s1)
    li t0, 0x8000000000080002
#else
    li t3, 2048
    add t3, s0, t3
    sw t0, 0(t3)
    li t0, 0x20000c01
    sw t0, 1024(s0)
    li s1, 0x80003000
    li t0, 0x200010cf
    sw t0, 0(s1)
    li t0, 0x80080002
#endif
    csrw satp, t0
#ifdef MAP_SECOND_EARLY
    li t0, 0x200018cf
#if __riscv_xlen == 64
    sd t0, 8(s1)
#else
    sw t0, 4(s1)
#endif
#endif
    sfence.vma zero, zero
    li t0, 0xa00
    csrs mstatus, t0
    la t0, supervisor_page
    csrw mepc, t0
    mret
supervisor_page:
    li a1, 0x40000ff8
#if PAGE_CASE == 3
    addi a1, a1, 4
    vsetivli zero, 1, e32, m1, tu, mu
#else
    vsetivli zero, 4, e32, m1, tu, mu
#endif
    vmv.v.i v8, -1
#if PAGE_CASE == 1
    vid.v v8
    vadd.vi v8, v8, 10
#endif
vector_page_access:
#if PAGE_CASE == 0
    vle32.v v8, (a1)
#elif PAGE_CASE == 1
    vse32.v v8, (a1)
#elif PAGE_CASE == 2
    vle32ff.v v8, (a1)
#else
    vlseg2e32.v v8, (a1)
#endif
    csrr t0, vstart
    bnez t0, page_fail
#if PAGE_CASE == 2
    bnez s4, page_fail
    csrr t0, vl
    li t1, 2
    bne t0, t1, page_fail
#else
    li t0, 1
    bne s4, t0, page_fail
#endif
#if PAGE_CASE == 1
    li t3, 0x80004ff8
    lw t0, 0(t3)
    li t1, 10
    bne t0, t1, page_fail
    lw t0, 4(t3)
    li t1, 11
    bne t0, t1, page_fail
    li t3, 0x80006000
    lw t0, 0(t3)
    li t1, 12
    bne t0, t1, page_fail
    lw t0, 4(t3)
    li t1, 13
    bne t0, t1, page_fail
#else
    li t3, 0x80007000
    vse32.v v8, (t3)
#if PAGE_CASE == 3
    addi t3, t3, 4
    vse32.v v9, (t3)
    addi t3, t3, -4
    lw t0, 0(t3)
    li t1, 0x222
    bne t0, t1, page_fail
    lw t0, 4(t3)
    li t1, 0x333
    bne t0, t1, page_fail
#else
    lw t0, 0(t3)
    li t1, 0x111
    bne t0, t1, page_fail
    lw t0, 4(t3)
    li t1, 0x222
    bne t0, t1, page_fail
#if PAGE_CASE == 0
    lw t0, 8(t3)
    li t1, 0x333
    bne t0, t1, page_fail
    lw t0, 12(t3)
    li t1, 0x444
    bne t0, t1, page_fail
#endif
#endif
#endif
    li a0, 10
    ebreak
.align 2
page_handler:
    csrr t0, mcause
#if PAGE_CASE == 1
    li t1, 15
#else
    li t1, 13
#endif
    bne t0, t1, page_fail
    csrr t0, mtval
    li t1, 0x40001000
    bne t0, t1, page_fail
    csrr t0, vstart
#if PAGE_CASE == 3
    bnez t0, page_fail
#else
    li t1, 2
    bne t0, t1, page_fail
#endif
    csrr t0, mepc
    la t1, vector_page_access
    bne t0, t1, page_fail
    li t0, 0x200018cf
#if __riscv_xlen == 64
    sd t0, 8(s1)
#else
    sw t0, 4(s1)
#endif
    sfence.vma zero, zero
    addi s4, s4, 1
    mret
page_fail:
    li a0, -1
    ebreak
""",
    "mmu": r""".option norvc
.section .text
.global _start
_start:
    la t0, page_fault_handler
    csrw mtvec, t0
    li s5, 0
    li t0, -1
    csrw pmpaddr0, t0
    li t0, 0x1f
    csrw pmpcfg0, t0
    lui s0, 0x80001
    li t0, 10
    sw t0, 0(s0)
    li t0, 11
    sw t0, 4(s0)
    lui s1, 0x80002
    li t0, 0x200000cf
#if __riscv_xlen == 64
    li t1, 4080
    add t1, s1, t1
    sd t0, 0(t1)
    sd t0, 8(s1)
    li t0, 0x8000000000080002
#else
    li t1, 2048
    add t1, s1, t1
    sw t0, 0(t1)
    sw t0, 1024(s1)
    li t0, 0x80080002
#endif
    csrw satp, t0
    sfence.vma zero, zero
    li t0, 0xa00
    csrs mstatus, t0
    la t0, supervisor
    csrw mepc, t0
    mret
supervisor:
    lui a1, 0x40001
    vsetivli zero, 2, e32, m1, tu, mu
    vle32.v v8, (a1)
    vadd.vi v8, v8, 5
    addi a2, a1, 32
    vse32.v v8, (a2)
    lw t0, 0(a2)
    li t1, 15
    bne t0, t1, fail
    lw t0, 4(a2)
    li t1, 16
    bne t0, t1, fail
#if __riscv_xlen == 64
    li t0, 0x40000000
#else
    li t0, 0x400000
#endif
    vlse32.v v10, (a1), t0
    csrr t1, vstart
    bnez t1, fail
    addi a2, a2, 32
    vse32.v v10, (a2)
    lw t1, 0(a2)
    li t2, 10
    bne t1, t2, fail
    lw t1, 4(a2)
    bne t1, t2, fail
#if __riscv_xlen == 32
    vsetivli zero, 1, e64, m1, tu, mu
    vle64.v v12, (a1)
    vadd.vi v12, v12, 5
    addi a2, a1, 96
    vse64.v v12, (a2)
    lw t1, 0(a2)
    li t2, 15
    bne t1, t2, fail
    lw t1, 4(a2)
    li t2, 11
    bne t1, t2, fail
    vsetivli zero, 2, e64, m1, tu, mu
    li t0, 0x800000
    vlse64.v v14, (a1), t0
    csrr t1, vstart
    bnez t1, fail
    addi a2, a1, 128
    vse64.v v14, (a2)
    lw t1, 0(a2)
    li t2, 10
    bne t1, t2, fail
    lw t1, 4(a2)
    li t2, 11
    bne t1, t2, fail
    lw t1, 8(a2)
    li t2, 10
    bne t1, t2, fail
    lw t1, 12(a2)
    li t2, 11
    bne t1, t2, fail
    li t2, 2
    bne s5, t2, fail
#endif
    li a0, 10
    ebreak
page_fault_handler:
    csrr s2, mcause
    li s3, 13
    bne s2, s3, fail
    csrr s2, mtval
    add s3, a1, t0
    bne s2, s3, fail
    csrr s2, vstart
    li s3, 1
    bne s2, s3, fail
    li s3, 0x200000cf
#if __riscv_xlen == 64
    sd s3, 16(s1)
#else
    beqz s5, first_fault
    sw s3, 1032(s1)
    j page_mapped
first_fault:
    sw s3, 1028(s1)
page_mapped:
    addi s5, s5, 1
#endif
    sfence.vma zero, zero
    mret
fail:
    li a0, -1
    ebreak
""",
    "indexed": r""".option norvc
.section .text
.global _start
_start:
    la t0, fail
    csrw mtvec, t0
    li t0, 0x200
    csrs mstatus, t0
    lui s0, 0x80001
    li t0, 100
    sw t0, 0(s0)
    li t0, 200
    sw t0, 4(s0)
    li t0, 300
    sw t0, 8(s0)
    li t0, 400
    sw t0, 12(s0)
    addi s1, s0, 64
    li t0, 12
    sw t0, 0(s1)
    sw zero, 4(s1)
    li t0, 8
    sw t0, 8(s1)
    li t0, 4
    sw t0, 12(s1)
    vsetivli zero, 4, e32, m1, tu, mu
    vle32.v v2, (s1)
    vluxei32.v v4, (s0), v2
    vadd.vi v4, v4, 1
    addi s2, s0, 128
    vsuxei32.v v4, (s2), v2
    lw t0, 0(s2)
    li t1, 101
    bne t0, t1, fail
    lw t0, 4(s2)
    li t1, 201
    bne t0, t1, fail
    lw t0, 8(s2)
    li t1, 301
    bne t0, t1, fail
    lw t0, 12(s2)
    li t1, 401
    bne t0, t1, fail
    vmsltu.vi v0, v2, 8
    vle32.v v4, (s0), v0.t
    vsetivli zero, 2, e32, m1, tu, mu
    vadd.vi v4, v4, 1
    li t0, 8
    vlse32.v v6, (s0), t0
    addi s3, s2, 64
    vse32.v v6, (s3)
    lw t0, 0(s3)
    li t1, 100
    bne t0, t1, fail
    lw t0, 4(s3)
    li t1, 300
    bne t0, t1, fail
    vsetivli zero, 4, e32, m1, tu, mu
    addi s3, s2, 32
    vse32.v v4, (s3)
    lw t0, 0(s3)
    li t1, 402
    bne t0, t1, fail
    lw t0, 4(s3)
    li t1, 201
    bne t0, t1, fail
    lw t0, 8(s3)
    li t1, 301
    bne t0, t1, fail
    lw t0, 12(s3)
    li t1, 400
    bne t0, t1, fail
    vsetivli zero, 4, e8, m1, tu, mu
    # Keep index EEW=16 separate from the EEW=8 data source.
    vmv2r.v v6, v2
    vrgatherei16.vv v4, v2, v6
    addi s4, s2, 224
    vse8.v v4, (s4)
    lbu t0, 0(s4)
    li t1, 4
    bne t0, t1, fail
    lbu t0, 1(s4)
    li t1, 12
    bne t0, t1, fail
    lbu t0, 2(s4)
    bne t0, t1, fail
    lbu t0, 3(s4)
    bne t0, t1, fail
    addi s4, s2, 192
    vsuxei16.v v2, (s4), v6
    lbu t0, 12(s4)
    li t1, 12
    bne t0, t1, fail
    lbu t0, 0(s4)
    bnez t0, fail
    li t0, 11
    sb t0, 0(s4)
    li t0, 3
    sb t0, 1(s4)
    li t0, 5
    sb t0, 2(s4)
    li t0, 9
    sb t0, 3(s4)
    vle8.v v2, (s4)
    # Mask EEW=1 and the widening seed EEW=16 need a distinct source.
    vmv1r.v v4, v2
    vcompress.vm v6, v2, v4
    addi s4, s4, 16
    vse8.v v6, (s4)
    lbu t0, 0(s4)
    li t1, 11
    bne t0, t1, fail
    lbu t0, 1(s4)
    li t1, 3
    bne t0, t1, fail
    lbu t0, 2(s4)
    li t1, 9
    bne t0, t1, fail
    vwredsumu.vs v8, v2, v4
    vsetivli zero, 1, e16, m1, tu, mu
    vse16.v v8, (s4)
    lhu t0, 0(s4)
    li t1, 807
    bne t0, t1, fail
#if __riscv_xlen == 32
    # Exercise 64-bit data with legal 32-bit indices on an RV32 hart.
    addi s0, s0, 512
    li t0, 0x55667788
    sw t0, 0(s0)
    li t0, 0x11223344
    sw t0, 4(s0)
    li t0, 0x76543210
    sw t0, 8(s0)
    li t0, 0x12345678
    sw t0, 12(s0)
    addi s1, s0, 64
    li t0, 8
    sw t0, 0(s1)
    sw zero, 4(s1)
    vsetivli zero, 2, e64, m1, tu, mu
    vle32.v v2, (s1)
    vloxei32.v v4, (s0), v2
    addi s2, s0, 128
    vsoxei32.v v4, (s2), v2
    lw t0, 0(s2)
    li t1, 0x55667788
    bne t0, t1, fail
    lw t0, 4(s2)
    li t1, 0x11223344
    bne t0, t1, fail
    lw t0, 8(s2)
    li t1, 0x76543210
    bne t0, t1, fail
    lw t0, 12(s2)
    li t1, 0x12345678
    bne t0, t1, fail
    vsetivli zero, 1, e64, m1, tu, mu
    vlseg2e64.v v8, (s0)
    addi s3, s0, 192
    vsseg2e64.v v8, (s3)
    lw t0, 0(s3)
    li t1, 0x55667788
    bne t0, t1, fail
    lw t0, 4(s3)
    li t1, 0x11223344
    bne t0, t1, fail
    lw t0, 8(s3)
    li t1, 0x76543210
    bne t0, t1, fail
    lw t0, 12(s3)
    li t1, 0x12345678
    bne t0, t1, fail
#endif
    li a0, 10
    ebreak
fail:
    li a0, -1
    ebreak
""",
    "context": r""".option norvc
.section .text
.global _start
_start:
    li t0, 0x2200
    csrs mstatus, t0
    vsetivli zero, 16, e8, m1, ta, ma
    vmv.v.i v0, 0
    vmv.v.i v1, 1
    vmv.v.i v2, 2
    vmv.v.i v3, 3
    vmv.v.i v4, 4
    vmv.v.i v5, 5
    vmv.v.i v6, 6
    vmv.v.i v7, 7
    vmv.v.i v8, 8
    vmv.v.i v9, 9
    vmv.v.i v10, 10
    vmv.v.i v11, 11
    vmv.v.i v12, 12
    vmv.v.i v13, 13
    vmv.v.i v14, 14
    vmv.v.i v15, 15
    vmv.v.i v16, -16
    vmv.v.i v17, -15
    vmv.v.i v18, -14
    vmv.v.i v19, -13
    vmv.v.i v20, -12
    vmv.v.i v21, -11
    vmv.v.i v22, -10
    vmv.v.i v23, -9
    vmv.v.i v24, -8
    vmv.v.i v25, -7
    vmv.v.i v26, -6
    vmv.v.i v27, -5
    vmv.v.i v28, -4
    vmv.v.i v29, -3
    vmv.v.i v30, -2
    vmv.v.i v31, -1
    csrwi vxrm, 2
    csrwi vxsat, 1
    csrwi vstart, 3
    csrr s0, vl
    csrr s1, vtype
    csrr s2, vxrm
    csrr s3, vxsat
    csrr s4, vstart
    csrr s5, vlenb
    csrwi vstart, 0
    li t0, 0x80001200
    vs8r.v v0, (t0)
    addi t0, t0, 128
    vs8r.v v8, (t0)
    addi t0, t0, 128
    vs8r.v v16, (t0)
    addi t0, t0, 128
    vs8r.v v24, (t0)
    addi t0, t0, 128
    li t0, 0x80001200
    li t1, 0
    li t2, 512
check_initial:
    lbu t3, 0(t0)
    srli t4, t1, 4
    li t5, 16
    bltu t4, t5, 1f
    addi t4, t4, 224
1:  bne t3, t4, context_fail
    addi t0, t0, 1
    addi t1, t1, 1
    bltu t1, t2, check_initial
    li t0, 128
    vsetvli zero, t0, e8, m8, ta, ma
    vmv.v.i v0, 0
    vmv.v.i v8, 0
    vmv.v.i v16, 0
    vmv.v.i v24, 0
    vsetivli zero, 4, e32, m1, tu, mu
    csrwi vxrm, 0
    csrwi vxsat, 0
    li t0, 0x600
    csrc mstatus, t0
    li t0, 0x200
    csrs mstatus, t0
    li t0, 0x80001200
    vl8re8.v v0, (t0)
    addi t0, t0, 128
    vl8re8.v v8, (t0)
    addi t0, t0, 128
    vl8re8.v v16, (t0)
    addi t0, t0, 128
    vl8re8.v v24, (t0)
    addi t0, t0, 128
    vsetvl zero, s0, s1
    csrw vxrm, s2
    csrw vxsat, s3
    csrw vstart, s4
    csrr t0, vstart
    bne t0, s4, context_fail
    csrwi vstart, 0
    csrr t0, vl
    bne t0, s0, context_fail
    csrr t0, vtype
    bne t0, s1, context_fail
    csrr t0, vxrm
    bne t0, s2, context_fail
    csrr t0, vxsat
    bne t0, s3, context_fail
    li t0, 16
    bne s5, t0, context_fail
    csrr t0, mstatus
    andi t0, t0, 0x600
    li t1, 0x600
    bne t0, t1, context_fail
    li t0, 0x80001400
    vs8r.v v0, (t0)
    addi t0, t0, 128
    vs8r.v v8, (t0)
    addi t0, t0, 128
    vs8r.v v16, (t0)
    addi t0, t0, 128
    vs8r.v v24, (t0)
    addi t0, t0, 128
    li t0, 0x80001200
    li t1, 0x80001400
    li t2, 512
check_restored:
    lbu t3, 0(t0)
    lbu t4, 0(t1)
    bne t3, t4, context_fail
    addi t0, t0, 1
    addi t1, t1, 1
    addi t2, t2, -1
    bnez t2, check_restored
    li a0, 10
    ebreak
context_fail:
    li a0, -1
    ebreak
""",
    "interrupt": r""".option norvc
.section .text
.global _start
_start:
    la t0, interrupt_handler
    csrw mtvec, t0
    li s4, 0
    li t0, 0x2200
    csrs mstatus, t0
    vsetivli zero, 2, e64, m1, ta, ma
    vmv.v.i v1, 13
    li t0, 0x0c000004
    li t1, 1
    sw t1, 0(t0)
    li t0, 0x0c002000
    li t1, 2
    sw t1, 0(t0)
    li t0, 0x0c200000
    sw zero, 0(t0)
    fence rw, rw
    li t0, 0x800
    csrs mie, t0
    li t0, 8
    csrs mstatus, t0
    li t1, 3
    vdivu.vx v2, v1, t1
    li t0, 0x80001200
    vse64.v v2, (t0)
    li t0, 10000
wait_interrupt:
    bnez s4, check_interrupt
    addi t0, t0, -1
    bnez t0, wait_interrupt
    j interrupt_fail
check_interrupt:
    li t0, 1
    bne s4, t0, interrupt_fail
    li t0, 0x80001200
    lw t1, 0(t0)
    li t2, 4
    bne t1, t2, interrupt_fail
    lw t1, 4(t0)
    bnez t1, interrupt_fail
    lw t1, 8(t0)
    bne t1, t2, interrupt_fail
    lw t1, 12(t0)
    bnez t1, interrupt_fail
    li a0, 10
    ebreak
interrupt_fail:
    li a0, -1
    ebreak
.align 2
interrupt_handler:
    csrr t0, mcause
    bgez t0, interrupt_fail
    slli t0, t0, 1
    srli t0, t0, 1
    li t1, 11
    bne t0, t1, interrupt_fail
    li t0, 0x0c200004
    lw t1, 0(t0)
    li t2, 1
    bne t1, t2, interrupt_fail
    sw t1, 0(t0)
    addi s4, s4, 1
    mret
""",
}


SOURCES["disabled"] = r""".option norvc
.section .text
.global _start
_start:
    la t0, handler
    csrw mtvec, t0
    li s4, 0
    csrr t0, misa
    li t1, 0x200000
    and t0, t0, t1
    bnez t0, fail
    li t0, 0x600
    csrs mstatus, t0
    csrr t1, mstatus
    and t1, t1, t0
    bnez t1, fail
    vsetivli zero, 4, e32, m1, tu, mu
    csrr t0, vlenb
    vadd.vv v8, v8, v8
    li t0, 0x80001000
    vle32.v v8, (t0)
    li t0, 4
    bne s4, t0, fail
    li a0, 10
    ebreak
fail:
    li a0, -1
    ebreak
.align 2
handler:
    csrr t0, mcause
    li t1, 2
    bne t0, t1, fail
    csrr t0, mepc
    csrr t1, mtval
#if __riscv_xlen == 64
    lwu t2, 0(t0)
#else
    lw t2, 0(t0)
#endif
    bne t1, t2, fail
    addi t0, t0, 4
    csrw mepc, t0
    addi s4, s4, 1
    mret
"""


def smoke(directory, xlen):
    directory.mkdir(parents=True, exist_ok=True)
    program = [
        0x00300213,  # addi x4, x0, 3
        0x000272d7,  # vsetvli x5, x4, e8, m1, tu, mu
        0x5e02b457,  # vmv.v.i v8, 5
        0x00700313,  # addi x6, x0, 7
        0x02834457,  # vadd.vx v8, v8, x6
        0x42802557,  # vmv.x.s x10, v8
        0x00150593,  # addi x11, x10, 1
    ]
    def binary(words):
        return b"".join(word.to_bytes(4, "little") for word in words)
    enable_vs = [0x20000e13, 0x300e2073]  # li t3, 0x200; csrs mstatus, t3
    trace = enable_vs + program + [0x00000013] * 120
    (directory / "trace.bin").write_bytes(binary(trace))
    # A prior scalar store exercises drain; the taken branch skips a poison vector
    # operation. A wrongly issued poison changes the checked scalar result.
    core = enable_vs + [0x00900613, 0x800013b7, 0x00c3a023] + program[:4]
    core += [0x00000463, 0x0280b457] + program[4:] + [0x00100073]
    (directory / "core.bin").write_bytes(binary(core))
    (directory / "boot.bin").write_bytes(binary([0x800002b7, 0x00028067]))
    lines = [f"{0x80000000 + 4*i:08x} {word:08x} {0x80000004 + 4*i:08x}"
             for i, word in enumerate(trace)]
    (directory / "trace.inst").write_text("\n".join(lines) + "\n")
    fault = enable_vs + [
        0x800010b7,  # lui x1, 0x80001
        0xc10272d7,  # vsetivli x5, 4, e32, m1, tu, mu
        0x5e02b457,  # vmv.v.i v8, 5
        0x0200e427,  # vse32.v v8, (x1)
    ] + [0x00000013] * 120
    (directory / "fault.bin").write_bytes(binary(fault))
    lines = [f"{0x80000000 + 4*i:08x} {word:08x} {0x80000004 + 4*i:08x}"
             for i, word in enumerate(fault)]
    (directory / "fault.inst").write_text("\n".join(lines) + "\n")
    if xlen == 64:
        memory = enable_vs + [
            0x800013b7, 0x00a00313, 0x0063b023, 0x00b00313, 0x0063b423,
            0xc18172d7, 0x0203f407, 0x0282b457, 0x02038493, 0x0204f427,
            0x0004b503, 0x0084b583,
        ]
    else:
        memory = enable_vs + [
            0x800013b7, 0x00a00313, 0x0063a023, 0x00b00313, 0x0063a223,
            0x00c00313, 0x0063a423, 0x00d00313, 0x0063a623, 0xc10272d7,
            0x0203e407, 0x0282b457, 0x02038493, 0x0204e427, 0x0004a503,
            0x00c4a583,
        ]
    memory += [0x00000013] * 120
    (directory / "memory.bin").write_bytes(binary(memory))
    lines = [f"{0x80000000 + 4*i:08x} {word:08x} {0x80000004 + 4*i:08x}"
             for i, word in enumerate(memory)]
    (directory / "memory.inst").write_text("\n".join(lines) + "\n")


def catalog(output):
    """Exercise the baseline encoding catalogue through real CPU retirement."""
    header = Path(__file__).resolve().parents[1] / "vpu/catalog_entries.h"
    entries = re.findall(r'\{"([^"]+)",0x([0-9a-f]+)u,(true|false),(true|false)\}',
                         header.read_text())
    if len(entries) != 375:
        raise ValueError("Review the baseline V catalogue before changing its scope")
    lines = [".option norvc", ".section .text", ".global _start", "_start:",
             "    la t0, trap_handler", "    csrw mtvec, t0", "    li t0, 0x2200",
             "    csrs mstatus, t0", "    csrr t0, misa", "    li t1, 0x200000",
             "    and t0, t0, t1", "    beqz t0, fail", "    csrr t0, vlenb",
             "    li t1, 16", "    bne t0, t1, fail",
             "    li sp, 0x800f0000", "    li gp, 64",
             "    li s0, 0", "    li t0, -1", "    vsetvli zero, t0, e8, m8, tu, mu",
             "    vmv.v.i v0, -1", "    vmv.v.i v8, -1",
             "    vmv.v.i v16, 0", "    vmv.v.i v24, 0"]
    cases = []
    for name, raw, segment, mask in entries:
        for nf in range(8 if segment == "true" else 1):
            for vm in ((0, 1) if mask == "true" else (1,)):
                for sew in (8, 16, 32, 64):
                    for start in (0, 2):
                        insn = int(raw, 16) | (nf << 29)
                        if mask == "true":
                            insn = (insn & ~(1 << 25)) | (vm << 25)
                        label = f"vector_case_{len(cases)}"
                        lines += [f"    vsetivli zero, 4, e{sew}, m1, tu, mu",
                                  f"    csrwi vstart, {start}", f".global {label}",
                                  label + ":", f"    .word 0x{insn:08x}"]
                        cases.append(dict(label=label, name=name, insn=f"{insn:08x}",
                                          fields=nf+1, vm=vm, sew=sew, vstart=start))
    lines += ["    li a0, VECTOR_SUCCESS_CODE", "    ebreak", "1: j 1b",
              "trap_handler:", "    csrr t0, mcause", "    li t1, 2",
              "    bne t0, t1, fail", "    addi s0, s0, 1", "    csrr t0, mepc",
              "    addi t0, t0, 4", "    csrw mepc, t0", "    mret",
              "fail:", "    li a0, -1", "    ebreak", "    j fail"]
    output.with_suffix(".json").write_text(json.dumps(cases, indent=2) + "\n")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", choices=("smoke", "catalog", *SOURCES))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--xlen", type=int, choices=(32, 64), default=32)
    parser.add_argument("--success-code", type=int, choices=(0, 10), default=10,
                        help="NPC exits on zero; the directed RTL harness expects ten")
    args = parser.parse_args()
    if args.source == "smoke":
        smoke(args.output, args.xlen)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        source = catalog(args.output) if args.source == "catalog" else SOURCES[args.source]
        source = source.replace("li a0, 10", "li a0, VECTOR_SUCCESS_CODE")
        source = source.replace("? 10 : -1", "? VECTOR_SUCCESS_CODE : -1")
        args.output.write_text(f"#define VECTOR_SUCCESS_CODE {args.success_code}\n" + source)


if __name__ == "__main__":
    main()
