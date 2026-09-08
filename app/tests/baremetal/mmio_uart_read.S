/* Exercise actual NS16550 byte lanes and read-to-clear IIR behavior. */
.option norvc
.section .text
.globl _start
_start:
  csrw mie, zero
  li t0, 0x10000000
  li t1, 3
  sb t1, 3(t0)             /* LCR: DLAB clear */
  sb zero, 2(t0)           /* FIFO disabled */
  li t1, 2
  sb t1, 1(t0)             /* TX interrupt enabled, RX disabled */
  li t1, 0xa5
  sb t1, 7(t0)             /* Highest byte lane in RV64 */
  li t1, 0x52
  sb t1, 0(t0)             /* One host output and pending TX interrupt */
  fence iorw, iorw
  lbu t2, 7(t0)
  li t1, 0xa5
  bne t2, t1, fail
  lbu t2, 3(t0)
  li t1, 3
  bne t2, t1, fail
  lbu t2, 1(t0)
  li t1, 2
  bne t2, t1, fail
  lbu t2, 5(t0)             /* LSR must not clear the pending IIR */
  andi t2, t2, 0x60
  li t1, 0x60
  bne t2, t1, fail
  lbu t2, 2(t0)             /* First IIR read consumes TX interrupt */
  li t1, 2
  bne t2, t1, fail
  fence iorw, iorw
  lbu t2, 2(t0)             /* Second read must observe no interrupt */
  li t1, 1
  bne t2, t1, fail
  lbu t2, 7(t0)
  li t1, 0xa5
  bne t2, t1, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
