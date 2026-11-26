// Self-contained chip smoke test for both RV32 and RV64 over the octal link.
// Verifies local control registers (0x00100800/0x00100804/0x00100808),
// 64-bit memory access on RV64, and SiFive finisher exit.
.section .text
.globl _start
_start:
  // Check xSPI control register (reset half period = 4).
  li t0, 0x00100800
  lw t1, 0(t0)
  li t2, 4
  bne t1, t2, fail

  // Check SRAM control register (chip reset value = 0x0608).
  li t0, 0x00100804
  lw t1, 0(t0)
  li t2, 0x0608
  bne t1, t2, fail

  // Check boot control register (bridge mode = 0 after JTAG switch).
  li t0, 0x00100808
  lw t1, 0(t0)
  bnez t1, fail

#if __riscv_xlen == 64
  // Verify 64-bit store/load over the octal link and cache line refill.
  li t0, 0x80001000
  li t1, 0x01234567
  slli t1, t1, 32
  li t2, 0x89abcdef
  slli t2, t2, 32
  srli t2, t2, 32
  or t1, t1, t2
  sd t1, 0(t0)
  fence
  ld t3, 0(t0)
  bne t1, t3, fail
#endif

  // Signal GOOD TRAP via SiFive test finisher.
  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)
1:
  j 1b

fail:
  li t0, 0x00100000
  li t1, 0x13333
  sw t1, 0(t0)
2:
  j 2b
