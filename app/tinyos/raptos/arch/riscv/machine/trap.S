.equ TF_MEPC, 128
.equ TF_MSTATUS, 132

#if __riscv_xlen == 64
.macro load_word rd, offset
    lwu \rd, \offset(sp)
.endm
#else
.macro load_word rd, offset
    lw \rd, \offset(sp)
.endm
#endif

.section .text, "ax"
.align 2
.globl trap_entry
trap_entry:
    csrrw sp, mscratch, sp
    sw t0, 20(sp)
    csrr t0, mscratch
    sw t0, 8(sp)
    sw ra, 4(sp)
    sw gp, 12(sp)
    sw tp, 16(sp)
    sw t1, 24(sp)
    sw t2, 28(sp)
    sw s0, 32(sp)
    sw s1, 36(sp)
    sw a0, 40(sp)
    sw a1, 44(sp)
    sw a2, 48(sp)
    sw a3, 52(sp)
    sw a4, 56(sp)
    sw a5, 60(sp)
    sw a6, 64(sp)
    sw a7, 68(sp)
    sw s2, 72(sp)
    sw s3, 76(sp)
    sw s4, 80(sp)
    sw s5, 84(sp)
    sw s6, 88(sp)
    sw s7, 92(sp)
    sw s8, 96(sp)
    sw s9, 100(sp)
    sw s10, 104(sp)
    sw s11, 108(sp)
    sw t3, 112(sp)
    sw t4, 116(sp)
    sw t5, 120(sp)
    sw t6, 124(sp)
    csrr t0, mepc
    sw t0, TF_MEPC(sp)
    csrr t0, mstatus
    sw t0, TF_MSTATUS(sp)
    mv a0, sp
    call trap_handler
    mv sp, a0
    j .Lrestore

.globl trap_return
trap_return:
    mv sp, a0
.Lrestore:
    load_word t0, TF_MEPC
    csrw mepc, t0
    load_word t0, TF_MSTATUS
    csrw mstatus, t0
    load_word t0, 8
    csrw mscratch, t0
    load_word ra, 4
    load_word gp, 12
    load_word tp, 16
    load_word t1, 24
    load_word t2, 28
    load_word s0, 32
    load_word s1, 36
    load_word a0, 40
    load_word a1, 44
    load_word a2, 48
    load_word a3, 52
    load_word a4, 56
    load_word a5, 60
    load_word a6, 64
    load_word a7, 68
    load_word s2, 72
    load_word s3, 76
    load_word s4, 80
    load_word s5, 84
    load_word s6, 88
    load_word s7, 92
    load_word s8, 96
    load_word s9, 100
    load_word s10, 104
    load_word s11, 108
    load_word t3, 112
    load_word t4, 116
    load_word t5, 120
    load_word t6, 124
    load_word t0, 20
    csrrw sp, mscratch, sp
    mret
