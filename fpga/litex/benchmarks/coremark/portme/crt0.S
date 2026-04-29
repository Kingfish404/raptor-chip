/* ============================================================================
 * crt0.S: Minimal startup for CoreMark on Raptor LiteX SoC
 *
 * Boot firmware loads binary to main_ram (0x80000000) and jumps here.
 * Sets up stack, clears BSS, calls main().
 * ============================================================================ */

.section .text.start, "ax", @progbits
.global _start
.type _start, @function

_start:
    /* Set up stack pointer at top of a 16 KB region after BSS */
    la      sp, _estack

    /* Clear BSS */
    la      t0, _fbss
    la      t1, _ebss
1:
    bge     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    /* Call main(0, NULL) */
    li      a0, 0
    li      a1, 0
    call    main

    /* main() returned. We deliberately do NOT trigger a SoC reset here:
     * litex_term --kernel re-uploads the binary on every SFL magic, so a
     * reset would loop. Halt cleanly; user can re-flash or press the
     * board reset button to return to the BIOS `litex>` prompt. */
3:  wfi
    j       3b

.size _start, . - _start
