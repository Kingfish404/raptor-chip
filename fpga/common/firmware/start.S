.section .text.start, "ax"
.global _start
_start:
    csrw mie, zero
    csrw satp, zero
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
    fence rw, rw
    fence.i
    csrw mie, zero
    csrw satp, zero
    li a0, 0
    jr t0
