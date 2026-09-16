/* Raptor implements MENVCFG but not optional MCOUNTINHIBIT. OpenSBI's
 * sequential privilege-version probe can therefore skip MENVCFG setup.
 * Enable real S-mode cache maintenance before entering either SBI variant.
 * Do not disable Zicbom or pretend that external DMA is coherent.
 */
#ifndef RAPT_UART_BASE
#define RAPT_UART_BASE 0xf0001800
#endif
.macro raptor_enable_cmo
    csrrci t5, mstatus, 8 /* keep asynchronous IRQs out of the CSR probe */
    csrr t4, mtvec
    lla t0, .Lcmo_failure\@
    csrw mtvec, t0
    li t1, 0x70 /* CBIE=invalidate, CBCFE=clean/flush; leave other bits alone */
    csrs 0x30a, t1
    csrr t2, 0x30a
    and t2, t2, t1
    bne t2, t1, .Lcmo_failure\@
    csrw mtvec, t4
    andi t5, t5, 8
    csrs mstatus, t5
    j .Lcmo_ready\@
    .balign 4, 0
.Lcmo_failure\@:
    /* CSR trap or unsupported WARL bits: stop before Linux/DMA corruption. */
    lla t0, .Lcmo_message\@
    li t1, RAPT_UART_BASE
.Lcmo_print\@:
    lbu t2, 0(t0)
    beqz t2, .Lcmo_halt\@
.Lcmo_wait\@:
    lw t3, 4(t1)
    bnez t3, .Lcmo_wait\@
    sw t2, 0(t1)
    addi t0, t0, 1
    j .Lcmo_print\@
.Lcmo_halt\@:
    j .Lcmo_halt\@
.Lcmo_message\@:
    .asciz "stage0: ERROR: MENVCFG does not enable S-mode Zicbom; check bitstream\n"
    .balign 4, 0
.Lcmo_ready\@:
.endm
