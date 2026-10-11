.section .text.start, "ax", @progbits
.global _start
.type _start, @function

_start:
    la      sp, __stack_top
#ifdef __riscv_flen
    /* M-mode payloads must enable the FP state before entering hard-float C. */
    li      t0, 0x6000
    csrs    mstatus, t0
    csrw    fcsr, zero
#endif

    la      t0, __bss_start
    la      t1, __bss_end
1:
    bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    li      a0, 0
    li      a1, 0
    call    main
    call    _litex_halt
3:
    wfi
    j       3b

.size _start, . - _start
