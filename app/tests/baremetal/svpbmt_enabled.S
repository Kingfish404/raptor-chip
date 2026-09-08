/* Real software PBMTE enablement, S-mode NC/IO data and instruction mappings. */
#if __riscv_xlen != 64
#error Svpbmt requires an RV64 page-table format
#endif
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, machine_trap
  csrw mtvec, t0
  csrw medeleg, zero
  csrw mideleg, zero
  csrw mie, zero
  csrw mstatus, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li t0, 0x40000000000000f0
  csrw menvcfg, t0
  csrr t1, menvcfg
  bne t0, t1, fail
  la s0, root
  li t0, 0x200000cf
  sd t0, 16(s0)
  la t0, level1
  srli t0, t0, 2
  ori t0, t0, 1
  sd t0, 8(s0)
  la t0, level0
  srli t0, t0, 2
  ori t0, t0, 1
  la t1, level1
  sd t0, 0(t1)
  la t1, level0
  la t0, payload
  srli t0, t0, 2
  ori t0, t0, 0xcf
  sd t0, 16(t1) // PMA alias
  li t2, 0x2000000000000000
  or t3, t0, t2
  sd t3, 0(t1) // NC alias
  slli t2, t2, 1
  or t3, t0, t2
  sd t3, 8(t1) // IO alias
  li t2, 0x6000000000000000
  or t3, t0, t2
  sd t3, 24(t1) // reserved PBMT=3
  la t0, typed_code
  srli t0, t0, 2
  ori t0, t0, 0xcb
  li t2, 0x2000000000000000
  or t3, t0, t2
  sd t3, 32(t1)
  slli t2, t2, 1
  or t3, t0, t2
  sd t3, 40(t1)
  srli t0, s0, 12
  li t1, 0x8000000000000000
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  li s7, 0
  la t0, supervisor
  csrw mepc, t0
  li t0, 0x800
  csrw mstatus, t0
  mret
supervisor:
  li a1, 0x40000000 // NC
  li a2, 0x40001000 // IO
  li a3, 0x40002000 // PMA
  li s1, 0x1122334455667788
  sd s1, 0(a1)
  fence rw,rw
  ld t0, 0(a1)
  bne t0, s1, fail
  ld t0, 0(a2)
  bne t0, s1, fail
  ld t0, 0(a3) // warm cacheable alias
  bne t0, s1, fail
  cbo.flush (a3)
  fence iorw,iorw
  li s1, 0x123456789abcdef
  sd s1, 0(a2)
  fence iorw,iorw
  cbo.inval (a3)
  fence iorw,iorw
  ld t0, 0(a3)
  bne t0, s1, fail
  // Device-width accesses must preserve their original AXI size and lanes.
  li t1, 0x5a
  sb t1, 16(a2)
  fence iorw,iorw
  lbu t0, 16(a2)
  bne t0, t1, fail
  li t1, 0x1234
  sh t1, 18(a2)
  fence iorw,iorw
  lhu t0, 18(a2)
  bne t0, t1, fail
  li t1, 0x12345678
  sw t1, 20(a2)
  fence iorw,iorw
  lwu t0, 20(a2)
  bne t0, t1, fail
  // NC misalignment is supported; IO misalignment is a platform access fault.
  sd s1, 1(a1)
  fence rw,rw
  ld t0, 1(a1)
  bne t0, s1, fail
  li s9, 0x40001001
  li s10, 5
  la s8, 1f
  la s11, 2f
1:ld t0, 0(s9)
2:li s10, 7
  la s8, 3f
  la s11, 4f
3:sd zero, 0(s9)
4:li s9, 0x40003000
  li s10, 13
  la s8, 5f
  la s11, 6f
5:ld t0, 0(s9)
6:li t0, 0x40004000
  jalr ra, t0, 0
  li t1, 0x123
  bne a4, t1, fail
  li t0, 0x40005000
  jalr ra, t0, 0
  li t1, 0x123
  bne a4, t1, fail
  li t0, 3
  bne s7, t0, fail
  // Both typed TLB entries are warm. M-mode changes PBMTE and fences before
  // returning; stale entries must not permit these mappings while disabled.
  li a5, 1
  ecall
  li s9, 0x40000000
  li s10, 13
  la s8, 7f
  la s11, 8f
7:ld t0, 0(s9)
8:li s9, 0x40001000
  la s8, 9f
  la s11, 10f
9:ld t0, 0(s9)
10:li a5, 2
  ecall
  ld t0, 1(a1)
  bne t0, s1, fail
  li t0, 0x40005000
  jalr ra, t0, 0
  li t1, 0x123
  bne a4, t1, fail
  li a5, 0
  ecall
  j fail
machine_trap:
  csrr t0, mcause
  li t1, 9
  beq t0, t1, service
  bne t0, s10, fail
  csrr t0, mepc
  bne t0, s8, fail
  csrr t0, mtval
  bne t0, s9, fail
  addi s7, s7, 1
  csrw mepc, s11
  mret
service:
  beqz a5, finish
  li t0, 0x4000000000000000
  li t1, 1
  beq a5, t1, disable_pbmt
  li t1, 2
  bne a5, t1, fail
  csrs menvcfg, t0
  j resume_service
disable_pbmt:
  csrc menvcfg, t0
resume_service:
  sfence.vma
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret
finish:
  li t0, 5
  bne s7, t0, fail
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak
.balign 4096
typed_code:
  li a4, 0x123
  ret
.section .data
.balign 4096
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
payload: .zero 4096
