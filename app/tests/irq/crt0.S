/* app/tests/irq/crt0.S: minimal M-mode startup for bare-metal IRQ tests. */

  .section .text.entry, "ax"
  .globl _start
  .type  _start, @function
_start:
  /* Set up sp. */
  la    sp, _stack_top

  /* Clear .bss. */
  la    t0, _bss_start
  la    t1, _bss_end
1:
  bgeu  t0, t1, 2f
  sw    zero, 0(t0)
  addi  t0, t0, 4
  j     1b
2:

  /* Install trap vector (direct mode). */
  la    t0, _trap_entry
  csrw  mtvec, t0

  /* Call C main. */
  call  main

  /* main returns: signal sifive,test PASS (0x5555 -> finisher @0x100000). */
  li    t0, 0x100000
  li    t1, 0x5555
  sw    t1, 0(t0)
3:
  j     3b

/* ---- Trap entry: save caller-saved regs, call C handler, restore, mret. */
  .balign 4
  .globl _trap_entry
  .type  _trap_entry, @function
_trap_entry:
  addi  sp, sp, -64
  sw    ra,  0(sp)
  sw    t0,  4(sp)
  sw    t1,  8(sp)
  sw    t2, 12(sp)
  sw    a0, 16(sp)
  sw    a1, 20(sp)
  sw    a2, 24(sp)
  sw    a3, 28(sp)
  sw    a4, 32(sp)
  sw    a5, 36(sp)
  sw    a6, 40(sp)
  sw    a7, 44(sp)
  sw    t3, 48(sp)
  sw    t4, 52(sp)
  sw    t5, 56(sp)
  sw    t6, 60(sp)

  call  trap_handler

  lw    ra,  0(sp)
  lw    t0,  4(sp)
  lw    t1,  8(sp)
  lw    t2, 12(sp)
  lw    a0, 16(sp)
  lw    a1, 20(sp)
  lw    a2, 24(sp)
  lw    a3, 28(sp)
  lw    a4, 32(sp)
  lw    a5, 36(sp)
  lw    a6, 40(sp)
  lw    a7, 44(sp)
  lw    t3, 48(sp)
  lw    t4, 52(sp)
  lw    t5, 56(sp)
  lw    t6, 60(sp)
  addi  sp, sp, 64
  mret
