.section .text.start, "ax"
.global _start
_start:
#ifdef NATIVE_VECTOR_TEST
    # The vector build checks real integer and FP64 arithmetic through main RAM.
    li t0, 0x2200
    csrs mstatus, t0
    csrr t0, misa
    li t1, 0x200000
    and t0, t0, t1
    beqz t0, vector_fail
    csrr t0, vlenb
    li t1, 16
    bne t0, t1, vector_fail
    vsetivli t0, 2, e64, m1, ta, ma
    li t1, 2
    bne t0, t1, vector_fail
    vmv.v.i v8, 3
    vadd.vi v9, v8, 4
    li t0, 0x80001000
    vse64.v v9, (t0)
    lw t2, 0(t0)
    li t3, 7
    bne t2, t3, vector_fail
    lw t2, 4(t0)
    bnez t2, vector_fail
    lw t2, 8(t0)
    bne t2, t3, vector_fail
    lw t2, 12(t0)
    bnez t2, vector_fail
    sw zero, 0(t0)
    li t2, 0x3ff80000
    sw t2, 4(t0)
    sw zero, 8(t0)
    li t2, 0xc0040000
    sw t2, 12(t0)
    csrwi fflags, 0
    vle64.v v10, (t0)
    vfadd.vv v11, v10, v10
    addi t0, t0, 32
    vse64.v v11, (t0)
    lw t2, 0(t0)
    bnez t2, vector_fail
    lw t2, 4(t0)
    li t3, 0x40080000
    bne t2, t3, vector_fail
    lw t2, 8(t0)
    bnez t2, vector_fail
    lw t2, 12(t0)
    # LW sign-extends on RV64; use the signed value in both XLEN modes.
    li t3, -0x3fec0000
    bne t2, t3, vector_fail
    csrr t2, fflags
    bnez t2, vector_fail
    csrr t2, mstatus
    li t3, 0x6600
    and t2, t2, t3
    bne t2, t3, vector_fail
#endif
    la t1, message
    j print_message
#ifdef NATIVE_VECTOR_TEST
vector_fail:
    la t1, failure
#endif
print_message:
    li t0, 0x10000000
1:  lbu t2, 0(t1)
    beqz t2, 3f
2:  lbu t3, 5(t0)
    andi t3, t3, 0x20
    beqz t3, 2b
    sb t2, 0(t0)
    addi t1, t1, 1
    j 1b
3:  wfi
    j 3b
message:
    .asciz "NATIVE PAYLOAD PASS\r\n"

#ifdef NATIVE_VECTOR_TEST
failure:
    .asciz "NATIVE VECTOR FAIL\r\n"
#endif
