/* The Sv39 setup and precise retry follow the existing fp_page_retry test.
 * Time demand paging separately from resident translation and hot-page reads.
 * Supervisor identity mappings keep trap code, page tables and UART accessible.
 */
.option norelax
.section .text.start, "ax", @progbits
.globl _start
_start:
  la sp, __stack_top
  la t0, machine_fail
  csrw mtvec, t0
  csrw mie, zero
  csrw mideleg, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li t0, 1
  csrw mcounteren, t0
  li t0, 0x2000
  csrw medeleg, t0
  la t0, page_fault
  csrw stvec, t0

  /* Only PTE storage requires clearing; data words are initialized below. */
  la t0, table_start
  la t1, table_end
1:
  bgeu t0, t1, 2f
  sd zero, 0(t0)
  addi t0, t0, 8
  j 1b
2:
  la t0, root
  li t1, 0xc7
  sd t1, 0(t0) /* Identity MMIO gigapage, supervisor RW. */
  li t1, 0x200000cf
  sd t1, 16(t0) /* Identity code/data gigapage, supervisor RWX. */
  la t1, level1
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 8(t0)
  la t0, level1
  la t1, level0
  srli t1, t1, 2
  ori t1, t1, 1
  sd t1, 0(t0)

  /* Different line offsets avoid making every page collide in one L1D set. */
  la t0, data_pages
  li t1, 0
  li t2, 64
3:
  slli t3, t1, 12
  slli t4, t1, 4
  add t3, t3, t4
  add t3, t3, t0
  addi t4, t1, 1
  sd t4, 0(t3)
  addi t1, t1, 1
  bltu t1, t2, 3b

  la t0, root
  srli t0, t0, 12
  li t1, (8 << 60)
  or t0, t0, t1
  csrw satp, t0
  sfence.vma
  la t0, supervisor
  csrw mepc, t0
  li t0, 0x6800 /* S-mode entry, with FP enabled for the shared printf runtime. */
  csrw mstatus, t0
  mret

supervisor:
  li s11, 0 /* Only the trap handler modifies the demand-fault count. */
  li s0, 64
  li s1, 0
  li s2, 0x40000000
  li s3, 0
  rdcycle s4
cold_loop:
  slli t0, s1, 12
  slli t1, s1, 4
  add t0, t0, t1
  add t0, t0, s2
  ld t1, 0(t0)
  add s3, s3, t1
  /* Full-period 6-bit permutation: x' = 13*x + 7 modulo 64. */
  li t0, 13
  mul s1, s1, t0
  addi s1, s1, 7
  andi s1, s1, 63
  addi s0, s0, -1
  bnez s0, cold_loop
  rdcycle s5
  sub s5, s5, s4
  li t0, 2080
  bne s3, t0, machine_fail
  li t0, 64
  bne s11, t0, machine_fail

  li s0, 4096
  li s1, 0
  li s3, 0
  rdcycle s4
resident_loop:
  slli t0, s1, 12
  slli t1, s1, 4
  add t0, t0, t1
  add t0, t0, s2
  ld t1, 0(t0)
  add s3, s3, t1
  li t0, 13
  mul s1, s1, t0
  addi s1, s1, 7
  andi s1, s1, 63
  addi s0, s0, -1
  bnez s0, resident_loop
  rdcycle s6
  sub s6, s6, s4
  li t0, 133120
  bne s3, t0, machine_fail

  /* Warm the eight-page subset before measuring its steady working set. */
  li s0, 8
  li s1, 0
warm_loop:
  slli t0, s1, 12
  slli t1, s1, 4
  add t0, t0, t1
  add t0, t0, s2
  ld t1, 0(t0)
  addi s1, s1, 1
  addi s0, s0, -1
  bnez s0, warm_loop
  li s0, 4096
  li s1, 0
  li s3, 0
  rdcycle s4
hot_loop:
  slli t0, s1, 12
  slli t1, s1, 4
  add t0, t0, t1
  add t0, t0, s2
  ld t1, 0(t0)
  add s3, s3, t1
  li t0, 13
  mul s1, s1, t0
  addi s1, s1, 7
  andi s1, s1, 7
  addi s0, s0, -1
  bnez s0, hot_loop
  rdcycle s7
  sub s7, s7, s4
  li t0, 18432
  bne s3, t0, machine_fail
  li t0, 64
  bne s11, t0, machine_fail
  mv a0, s5
  mv a1, s6
  mv a2, s7
  mv a3, s11
  tail report

.balign 4
page_fault:
  /* Preserve all temporaries used by this handler; retry the same sepc. */
  addi sp, sp, -48
  sd t0, 0(sp)
  sd t1, 8(sp)
  sd t2, 16(sp)
  sd t3, 24(sp)
  sd t4, 32(sp)
  csrr t0, scause
  li t1, 13
  bne t0, t1, machine_fail
  csrr t0, stval
  li t1, 0x40000000
  sub t1, t0, t1
  srli t2, t1, 12
  li t3, 64
  bgeu t2, t3, machine_fail
  la t3, level0
  slli t4, t2, 3
  add t3, t3, t4
  ld t4, 0(t3)
  bnez t4, machine_fail
  la t4, data_pages
  slli t2, t2, 12
  add t4, t4, t2
  srli t4, t4, 2
  ori t4, t4, 0xc7
  sd t4, 0(t3)
  sfence.vma t0, zero
  addi s11, s11, 1
  ld t0, 0(sp)
  ld t1, 8(sp)
  ld t2, 16(sp)
  ld t3, 24(sp)
  ld t4, 32(sp)
  addi sp, sp, 48
  sret

.balign 4
machine_fail:
  tail test_failed

.section .bss
.balign 4096
table_start:
root: .zero 4096
level1: .zero 4096
level0: .zero 4096
table_end:
data_pages: .zero (64 * 4096)
