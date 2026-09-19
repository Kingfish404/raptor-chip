/* Feed one 'K' on stdin. Verify real M-mode delivery and PLIC source 10. */
.option norvc
.section .text
.globl _start
_start:
  csrw mie, zero
  la t0, trap
  csrw mtvec, t0
  li s0, 0x10000000
  li s1, 0x0c200004
  li t0, 0x0c000028
  li t1, 1
  sw t1, 0(t0)
  li t0, 0x0c002000
  li t1, 1024
  sw t1, 0(t0)
  sw zero, -4(s1)
  li t1, 1
  sb t1, 1(s0)
  fence iorw, iorw
  li t0, 0x800
  csrw mie, t0
  csrsi mstatus, 8
1:
  j 1b
.balign 4
trap:
  csrr t0, mcause
  li t1, 1
  slli t1, t1, (__riscv_xlen - 1)
  ori t1, t1, 11
  bne t0, t1, fail
  lw t0, 0(s1)
  li t1, 10
  bne t0, t1, fail
  lbu t2, 0(s0)
  li t3, 'K'
  bne t2, t3, fail
  sb zero, 1(s0)
  fence iorw, iorw
  sw t0, 0(s1)
  la t3, message
2:
  lbu t2, 0(t3)
  beqz t2, pass
3:
  lbu t1, 5(s0)
  andi t1, t1, 0x20
  beqz t1, 3b
  sb t2, 0(s0)
  addi t3, t3, 1
  j 2b
pass:
  li t1, 0x5555
  j finish
fail:
  li t1, 0x13333
finish:
  fence iorw, iorw
  li t0, 0x100000
  sw t1, 0(t0)
4:
  j 4b
.section .rodata
message:
  .asciz "UART_IRQ_PASS\n"
