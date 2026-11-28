.section .text.start, "ax"
.global _start
_start:
#ifdef NATIVE_SAMPLING
    # Host holds reset until sparse RAM, SRAM restore code and state are ready.
    li t0, 0x0f000000
    jr t0
#endif
    csrw mie, zero
    csrw satp, zero
#if defined(NATIVE_NHARTS) && (NATIVE_NHARTS > 1)
    csrr t0, mhartid
    bnez t0, secondary_park
#endif
    la sp, _stack_top
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la t0, trap_entry
    csrw mtvec, t0
    la t0, _bss_start
    la t1, _bss_end
1:  bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:  call boot_main
3:  wfi
    j 3b

.balign 4
trap_entry:
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    la sp, _stack_top
    call boot_trap
    j 3b

.global boot_jump
boot_jump:
    # a0 = entry, a1 = DTB; next stage sees hart ID in a0 and DTB in a1.
    mv t0, a0
#if defined(NATIVE_NHARTS) && (NATIVE_NHARTS > 1)
    la t1, _smp_mailbox
#if __riscv_xlen == 64
    sd a0, 0(t1)
    sd a1, 8(t1)
#else
    sw a0, 0(t1)
    sw a1, 4(t1)
#endif
    fence rw, rw
    li t1, 0x02000004
    li t2, NATIVE_NHARTS - 1
    li t3, 1
4:  sw t3, 0(t1)
    addi t1, t1, 4
    addi t2, t2, -1
    bnez t2, 4b
#endif
    fence rw, rw
    fence.i
    csrw mie, zero
    csrw satp, zero
#if __riscv_xlen == 64
    li t1, 0xc0000000000000f0
#else
    li t1, 0xf0
#endif
    csrw 0x30a, t1
    li a0, 0
    jr t0

#if defined(NATIVE_NHARTS) && (NATIVE_NHARTS > 1)
secondary_park:
    li t1, 8
    csrw mie, t1
5:  wfi
    csrr t1, mip
    andi t1, t1, 8
    beqz t1, 5b
    li t1, 0x02000000
    slli t2, t0, 2
    add t1, t1, t2
    sw zero, 0(t1)
    fence rw, rw
    fence.i
    csrw mie, zero
    csrw satp, zero
#if __riscv_xlen == 64
    li t1, 0xc0000000000000f0
#else
    li t1, 0xf0
#endif
    csrw 0x30a, t1
    la t1, _smp_mailbox
#if __riscv_xlen == 64
    ld t2, 0(t1)
    ld a1, 8(t1)
#else
    lw t2, 0(t1)
    lw a1, 4(t1)
#endif
    mv a0, t0
    jr t2

.section .bss
.balign 8
_smp_mailbox:
    .space 16
#endif
