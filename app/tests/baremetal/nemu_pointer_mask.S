.option norvc
.option norelax
.section .text
.globl _start
_start:
  csrr s0, mhartid
  la t0, trap
  csrw mtvec, t0
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 15
  csrw pmpcfg0, t0
  li s8, 0
  li s10, 0
  andi t0, s0, 1
  addi s1, t0, 2
  slli s1, s1, 32
  li s2, 3
  sub s2, s2, t0
  slli s2, s2, 32
  csrw 0x10a, s1
  csrw 0x30a, s2
  slli t0, s0, 12
  la s3, roots
  add s3, s3, t0
  la t1, middles
  add t1, t1, t0
  la s5, leaves
  add s5, s5, t0
  la s4, pages
  add s4, s4, t0
  srli t2, t1, 12
  slli t2, t2, 10
  ori t2, t2, 1
  sd t2, 8(s3)
  srli t2, s5, 12
  slli t2, t2, 10
  ori t2, t2, 1
  sd t2, 0(t1)
  srli t2, s4, 12
  slli t2, t2, 10
  ori t2, t2, 0xdf
  sd t2, 0(s5)
  addi s6, s0, 0x123
  sd s6, 0(s4)
  srli t0, s3, 12
  li t1, 0x8000000000000000
  or t0, t0, t1
  csrw satp, t0
  li s7, 0xaa00000040000000
  andi t0, s0, 1
  beqz t0, user_tag
  li s7, 0xabcd000040000000
user_tag:
  li t0, 0x20000
  csrw mstatus, t0
  li s9, 32
warm:
  ld t0, 0(s7)
  bne t0, s6, fail
  addi s9, s9, -1
  bnez s9, warm
  lr.d t0, (s7)
  bne t0, s6, fail
  addi s6, s6, 1
  li t0, 0x5400000040000000
  sc.d t1, s6, (t0)
  bnez t1, fail
  csrw 0x10a, zero
  li s10, 13
  mv s11, s7
  ld t0, 0(s7)
  csrw mstatus, zero
  csrw 0x10a, s1
  li t0, 0x20000
  csrw mstatus, t0
  ld t0, 0(s7)
  bne t0, s6, fail
  li t0, 0xa0000
  csrw mstatus, t0
  li s10, 13
  ld t0, 0(s7)
  csrw mstatus, zero
  csrw 0x10a, zero
  srli t0, s4, 12
  slli t0, t0, 10
  ori t0, t0, 0xcf
  sd t0, 0(s5)
  sfence.vma
  li s7, 0xaa00000040000000
  andi t0, s0, 1
  bnez t0, supervisor_tag
  li s7, 0xabcd000040000000
supervisor_tag:
  mv s11, s7
  li t0, 0x20800
  csrw mstatus, t0
  ld t0, 0(s7)
  bne t0, s6, fail
  csrw 0x30a, zero
  li s10, 13
  ld t0, 0(s7)
  csrw mstatus, zero
  csrw 0x30a, s2
  csrw 0x10a, s1
  csrw satp, zero
  li t0, 0xaa00000000000000
  andi t1, s0, 1
  beqz t1, bare_tag
  li t0, 0xabcd000000000000
bare_tag:
  or s7, s4, t0
  mv s11, s7
  li t0, 0x20000
  csrw mstatus, t0
  ld t0, 0(s7)
  bne t0, s6, fail
  li t0, 0xa0000
  csrw mstatus, t0
  li s10, 5
  ld t0, 0(s7)
  csrw mstatus, zero
  li s10, 5
  ld t0, 0(s7)
  li t0, 5
  bne s8, t0, fail
  la t0, finished
  li t1, 1
  amoadd.w.aqrl zero, t1, (t0)
  bnez s0, park
wait:
  lw t1, 0(t0)
  li t2, HARTS
  bne t1, t2, wait
  li t0, 0x100000
  li t1, 0x5555
  sw t1, 0(t0)
park:
  j park
trap:
  csrr t3, mcause
  bne t3, s10, fail
  csrr t3, mtval
  bne t3, s11, fail
  addi s8, s8, 1
  li s10, 0
  csrr t3, mepc
  addi t3, t3, 4
  csrw mepc, t3
  mret
fail:
  csrw mstatus, zero
  li t0, 0x100000
  li t1, 0x3333
  sw t1, 0(t0)
  j fail
.section .data
.balign 64
finished:
  .word 0
.section .bss
.balign 4096
roots:
  .skip 16384
middles:
  .skip 16384
leaves:
  .skip 16384
pages:
  .skip 16384
