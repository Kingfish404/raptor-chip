.section .text.start, "ax", @progbits
.global _start
.type _start, @function
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    la      sp, __stack_top
    la      tp, __tls_base
    .option pop
    li      t0, 0x6000
    csrs    mstatus, t0
    csrw    fcsr, zero
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
    call    exit
3:
    wfi
    j       3b
.size _start, . - _start
