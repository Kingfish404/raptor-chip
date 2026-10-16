.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrr s0, mhartid
  la t0, fail
  csrw mtvec, t0
  li t0, 0x200
  csrs mstatus, t0
  la s1, command
  la s2, acknowledged
  la s3, lines
  bnez s0, worker
  li s4, 1
next_hart:
  slli s5, s4, 6
  add s5, s3, s5
  addi s7, s5, 8
  li s6, 1
next_operation:
  mv t0, s5
  li t1, 8
  li t2, 0x5a5a
initialize_line:
  sd t2, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -1
  bnez t1, initialize_line
  slli s8, s4, 2
  add s8, s8, s6
  slli s9, s4, 4
  add s9, s9, s6
  li t0, 0x1000
  add s9, s9, t0
  lr.d.aq t4, (s7)
  bne t4, t2, fail
  fence rw, rw
  sw s8, 0(s1)
wait_writer:
  lw t0, 0(s2)
  bne t0, s8, wait_writer
  fence rw, rw
  sc.d.rl t0, zero, (s7)
  beqz t0, fail
  li t0, 0
  mv t1, s5
check_line:
  li t3, 0x5a5a
  li t2, 2
  beq s6, t2, expect_zero
  li t2, 1
  bne t0, t2, compare_word
  mv t3, s9
  j compare_word
expect_zero:
  li t3, 0
compare_word:
  ld t2, 0(t1)
  bne t2, t3, fail
  addi t0, t0, 1
  addi t1, t1, 8
  li t2, 8
  bne t0, t2, check_line
  addi s6, s6, 1
  li t0, 4
  bne s6, t0, next_operation
  addi s4, s4, 1
  li t0, HARTS
  bne s4, t0, next_hart
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
park:
  j park

worker:
  slli s5, s0, 6
  add s5, s3, s5
  addi s7, s5, 8
  li s6, 1
worker_next:
  slli s8, s0, 2
  add s8, s8, s6
worker_wait:
  lw t0, 0(s1)
  bne t0, s8, worker_wait
  fence rw, rw
  slli s9, s0, 4
  add s9, s9, s6
  li t0, 0x1000
  add s9, s9, t0
  li t0, 2
  beq s6, t0, worker_zero
  li t0, 3
  beq s6, t0, worker_atomic
  vsetivli zero, 1, e64, m1, tu, mu
  vmv.v.x v8, s9
#ifndef NEMU_TEST_SKIP_VECTOR_STORE
  vse64.v v8, (s7)
#endif
  j worker_ack
worker_zero:
  addi t0, s5, 63
  .insn i 0x0f, 2, x0, t0, 4
  j worker_ack
worker_atomic:
  amoswap.d.aqrl zero, s9, (s7)
worker_ack:
  fence rw, rw
  sw s8, 0(s2)
  addi s6, s6, 1
  li t0, 4
  bne s6, t0, worker_next
  j park

fail:
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j fail

.section .data
.balign 64
command: .word 0
acknowledged: .word 0
.balign 64
lines: .zero 64 * (HARTS + 1)
