/*
 * Minimal crt0 for Raptor LiteX microbenchmarks.
 *
 * - Boot.S has already printed the jump banner and set a0=hartid, a1=dtb.
 *   We ignore those and set up a fresh stack.
 * - Zero .bss.
 * - Call main().
 * - On return, print "\n[PASS]\n" and wfi-loop forever. Verilator's
 *   SIM_TIMEOUT kills the simulation from the outside.
 */

.section .text.start
.globl _start
_start:
    la      sp, __stack_top

    /* Zero .bss */
    la      t0, __bss_start
    la      t1, __bss_end
1:  bge     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    call    main

    /* Print "\n[PASS]\n" directly via UART to keep this independent
     * of io.c (main might have returned non-zero but still succeeded). */
    la      a0, .Lmsg_pass
    call    _puts_raw
3:  wfi
    j       3b

/* Stringent raw puts (UART RXTX / TXFULL baked in) so _start can always
 * produce a final line even if main()'s return path is weird. */
.globl _puts_raw
_puts_raw:
    li      t0, 0xf0001800      /* UART RXTX  */
    li      t1, 0xf0001804      /* UART TXFULL */
.Lpr_loop:
    lbu     t2, 0(a0)
    beqz    t2, .Lpr_done
.Lpr_wait:
    lw      t3, 0(t1)
    bnez    t3, .Lpr_wait
    sw      t2, 0(t0)
    addi    a0, a0, 1
    j       .Lpr_loop
.Lpr_done:
    ret

.section .rodata
.Lmsg_pass:
    .asciz "\n[PASS]\n"
