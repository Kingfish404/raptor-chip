/* ============================================================================
 * crt0.S: Minimal startup for Embench-IoT on Raptor LiteX SoC
 *
 * Boot firmware loads binary to main_ram (0x80000000) and jumps here.
 * Sets up stack, clears BSS, calls main().
 * ============================================================================ */

.section .text.start, "ax", @progbits
.global _start
.type _start, @function

_start:
    /* Stack pointer at top of reserved region (defined in link.ld) */
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
    /* main(0, NULL) */
    li      a0, 0
    li      a1, 0
    call    main

    /* Halt after main returns */
3:  j       3b

.size _start, . - _start
