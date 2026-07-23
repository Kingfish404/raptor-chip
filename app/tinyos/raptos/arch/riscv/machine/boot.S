.section .text.init, "ax"
.globl _start
_start:
    csrw mie, zero
    li t0, 8
    csrc mstatus, t0
    la sp, boot_stack_top

    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:
    la t0, trap_entry
    csrw mtvec, t0
    call kmain
3:
    wfi
    j 3b

.section .bss.boot_stack, "aw", @nobits
.align 4
boot_stack:
    .space 2048
boot_stack_top: