.option norvc
#if __riscv_xlen == 64
#define PTE_STORE sd
#else
#define PTE_STORE sw
#endif
.section .text
.globl _start
_start:
  csrr s0, mhartid
  la t0, trap
  csrw mtvec, t0
#ifdef NEMU_TLB_UNSUPPORTED
  li t0, 0x10002000
  lw t1, 0(t0)
#endif
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0xf
  csrw pmpcfg0, t0
  slli t0, s0, 12
  la s3, roots
  add s3, s3, t0
  la s2, leaves
  add s2, s2, t0
  la s4, pages_a
  add s4, s4, t0
  la s5, pages_b
  add s5, s5, t0
  addi s6, s0, 0x111
  sw s6, 0(s4)
  addi t1, s0, 0x222
  sw t1, 0(s5)
  li t1, 0x01100593
  sw t1, 32(s4)
  li t1, 0x02200593
  sw t1, 32(s5)
  li t1, 0x00008067
  sw t1, 36(s4)
  sw t1, 36(s5)
  fence.i
  srli t1, s2, 12
  slli t1, t1, 10
  ori t1, t1, 1
#if __riscv_xlen == 64
  la t2, middles
  add t2, t2, t0
  sd t1, 0(t2)
  srli t1, t2, 12
  slli t1, t1, 10
  ori t1, t1, 1
  sd t1, 8(s3)
  li t1, 0x200000cf
  sd t1, 16(s3)
#else
  sw t1, 1024(s3)
  li t1, 0x200000cf
  li t2, 2048
  add t2, s3, t2
  sw t1, 0(t2)
#endif
  srli t1, s4, 12
  slli t1, t1, 10
  ori t1, t1, 0xcf
  PTE_STORE t1, 0(s2)
  srli t1, s3, 12
#if __riscv_xlen == 64
  li t2, 0x8000000000000000
#else
  li t2, 0x80000000
#endif
  or s3, t1, t2
  csrw satp, s3
  sfence.vma
  la t0, supervisor
  csrw mepc, t0
  li t0, 0x800
  csrw mstatus, t0
  li s7, 0
  li s8, 0
  li s1, 0x40000000
  mv s10, s1
  mret
supervisor:
  li s9, 128
warm:
  lw t0, 0(s1)
  bne t0, s6, fail
  addi t1, s0, 0x333
  sw t1, 8(s1)
  lw t2, 8(s4)
  bne t1, t2, fail
  addi s9, s9, -1
  bnez s9, warm
  jalr ra, s1, 32
  li t0, 17
  bne a1, t0, fail
  srli t0, s5, 12
  slli t0, t0, 10
  ori t0, t0, 0xcf
  PTE_STORE t0, 0(s2)
  sfence.vma s1, zero
  lw t0, 0(s1)
  addi t1, s0, 0x222
  bne t0, t1, fail
  addi t1, s0, 0x444
  sw t1, 8(s1)
  lw t2, 8(s5)
  bne t1, t2, fail
  jalr ra, s1, 32
  li t0, 34
  bne a1, t0, fail
  srli t0, s4, 12
  slli t0, t0, 10
  ori t0, t0, 0xcf
  PTE_STORE t0, 0(s2)
  csrw satp, s3
  lw t0, 0(s1)
  bne t0, s6, fail
  jalr ra, s1, 32
  li t0, 17
  bne a1, t0, fail
  srli t0, s4, 12
  slli t0, t0, 10
  ori t0, t0, 0xc7
  PTE_STORE t0, 0(s2)
  sfence.vma
  li s7, 12
  addi s10, s1, 32
  jalr ra, s1, 32
  li t0, 17
  bne a1, t0, fail
  mv s10, s1
  srli t0, s4, 12
  slli t0, t0, 10
  ori t0, t0, 7
  PTE_STORE t0, 0(s2)
  sfence.vma
  li s7, 13
  lw t0, 0(s1)
  bne t0, s6, fail
  srli t0, s4, 12
  slli t0, t0, 10
  ori t0, t0, 0xc3
  PTE_STORE t0, 0(s2)
  sfence.vma
  li s7, 15
  addi t1, s0, 0x555
  sw t1, 0(s1)
  lw t0, 0(s4)
  bne t0, t1, fail
  li t0, 3
  bne s8, t0, fail
  li a0, 1
  ecall
  li s7, 5
  lw t0, 0(s1)
  bne t0, t1, fail
  li t0, 4
  bne s8, t0, fail
  srli t0, s4, 12
  slli t0, t0, 10
  ori t0, t0, 0xdf
  PTE_STORE t0, 0(s2)
  sfence.vma
  li t0, 0x40000
  csrs sstatus, t0
  lw t2, 0(s1)
  bne t2, t1, fail
  csrc sstatus, t0
  li s7, 13
  lw t2, 0(s1)
  bne t2, t1, fail
  srli t0, s4, 12
  slli t0, t0, 10
  ori t0, t0, 0xdf
  PTE_STORE t0, 0(s2)
  sfence.vma
  li t0, 0x40000
  csrs sstatus, t0
  sw t1, 0(s1)
  csrc sstatus, t0
  li s7, 15
  sw t1, 0(s1)
  srli t0, s4, 12
  slli t0, t0, 10
  ori t0, t0, 0xc9
  PTE_STORE t0, 0(s2)
  sfence.vma
  li t0, 0x80000
  csrs sstatus, t0
  lw t2, 0(s1)
  bne t2, t1, fail
  csrc sstatus, t0
  li s7, 13
  lw t2, 0(s1)
  bne t2, t1, fail
  li t0, 7
  bne s8, t0, fail
  li a0, 9
  ecall
fail:
  li a0, 99
  ecall
  j fail
trap:
  csrr t3, mcause
  li t4, 9
  beq t3, t4, supervisor_call
  bne t3, s7, machine_fail
  csrr t3, mtval
  bne t3, s10, machine_fail
  li t3, 5
  beq s7, t3, allow_pmp
  srli t3, s4, 12
  slli t3, t3, 10
  ori t3, t3, 0xcf
  PTE_STORE t3, 0(s2)
  j return_fault
allow_pmp:
  li t3, -1
  csrw pmpaddr0, t3
  li t3, 0xf
  csrw pmpcfg0, t3
return_fault:
  addi s8, s8, 1
  li s7, 0
  mret
supervisor_call:
  li t3, 1
  beq a0, t3, deny_pmp
  li t3, 9
  bne a0, t3, machine_fail
  la t3, finished
  li t4, 1
  amoadd.w.aqrl zero, t4, (t3)
  bnez s0, park
wait_harts:
  lw t4, 0(t3)
  li t5, HARTS
  bne t4, t5, wait_harts
  li t3, 0x100000
  li t4, 0x5555
  sw t4, 0(t3)
park:
  wfi
  j park
deny_pmp:
  li t3, -1
  csrw pmpaddr1, t3
  srli t3, s4, 2
  csrw pmpaddr0, t3
  li t3, 0x1f18
  csrw pmpcfg0, t3
  csrr t3, mepc
  addi t3, t3, 4
  csrw mepc, t3
  mret
machine_fail:
  li t3, 0x100000
  li t4, 0x3333
  sw t4, 0(t3)
  j machine_fail
.section .data
.balign 64
finished:
  .word 0
.section .bss
.balign 4096
.globl roots, leaves, tables_end
roots:
  .skip 16384
middles:
  .skip 16384
leaves:
  .skip 16384
tables_end:
pages_a:
  .skip 16384
pages_b:
  .skip 16384
