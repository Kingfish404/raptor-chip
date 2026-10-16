.option norvc
.section .text
.globl _start
_start:
  csrr s0, mhartid
  la t0, fail
  csrw mtvec, t0
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 15
  csrw pmpcfg0, t0
  slli t0, s0, 12
  la s1, roots
  add s1, s1, t0
  la s2, middles
  add s2, s2, t0
  la s3, leaves
  add s3, s3, t0
  srli t1, s2, 12
  slli t1, t1, 10
  ori t1, t1, 1
  sd t1, 8(s1)
  srli t1, s3, 12
  slli t1, t1, 10
  ori t1, t1, 1
  sd t1, 0(s2)
  slli t0, s0, 16
  la s4, pages
  add s4, s4, t0
  srli s5, s4, 12
  ori s5, s5, 8
  slli s5, s5, 10
  ori s5, s5, 0xcf
  li t0, 0x8000000000000000
  or s5, s5, t0
  srli t1, s1, 12
  or t1, t1, t0
  csrw satp, t1
  li s6, 0x40000000
  li s7, 16
  li s8, 0x20800
page:
  sd s5, 0(s3)
  addi s9, s7, 0x123
  sd s9, 0(s4)
  sfence.vma s6, zero
  li s10, 4
warm:
  csrw mstatus, s8
  ld t0, 0(s6)
  addi t1, t0, 1
  sd t1, 8(s6)
  csrw mstatus, zero
  bne t0, s9, fail
  ld t2, 8(s4)
  bne t1, t2, fail
  addi s10, s10, -1
  bnez s10, warm
  ld t0, 0(s3)
  bne t0, s5, fail
  li t0, 0x40000
  add s11, s4, t0
  addi s9, s9, 17
  sd s9, 0(s11)
  srli t0, s11, 12
  slli t0, t0, 10
  ori t0, t0, 0xcf
  sd t0, 0(s3)
  sfence.vma s6, zero
  csrw mstatus, s8
  ld t0, 0(s6)
  csrw mstatus, zero
  bne t0, s9, fail
  addi s3, s3, 8
  li t0, 4096
  add s4, s4, t0
  add s6, s6, t0
  addi s7, s7, -1
  bnez s7, page
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
.balign 65536
pages:
  .skip 524288
