/* Bare M-mode harness, effective U/S data privilege through MPRV.
 * TOR [area,area+12), R/RW/X-only; half accesses include a bus-beat split.
 * No locked-PMP, translated-access, PMA/MMIO or external atomicity claim. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  csrw mie, zero
  csrw mstatus, zero
  li t0, 0x6000
  csrs mstatus, t0
  la s0, area
  la s1, saved
  la t0, source_bits
  fld f0, 0(t0)
  li s2, 0                 /* effective privilege: U, S */
  li s10, 0               /* observed faults */
  li s11, 0               /* expected faults */
mode_loop:
  li s3, 0               /* permission: R, RW, X-only */
perm_loop:
  li s4, 0               /* offset: 0..15 */
offset_loop:
  /* Initial memory and FPR sentinel are restored in unrestricted M mode. */
  li t0, 0
init_mem:
  add t1, s0, t0
  addi t2, t0, 0x40
  sb t2, 0(t1)
  addi t0, t0, 1
  li t1, 24
  blt t0, t1, init_mem
  la t0, dest_bits
  fld f2, 0(t0)
  li t0, 0x43
  csrw fcsr, t0
  srli t0, s0, 2
  csrw pmpaddr0, t0
  addi t0, s0, 12
  srli t0, t0, 2
  csrw pmpaddr1, t0
  li t0, 0x0900
  beqz s3, config_done
  li t0, 0x0b00
  li t1, 1
  beq s3, t1, config_done
  li t0, 0x0c00
config_done:
  csrw pmpcfg0, t0
  sfence.vma
  add s5, s0, s4
  /* FSH is allowed only by RW and a complete two-byte match. */
  li s6, 7
  la s7, store_probe
  li s8, 1
  li t0, 1
  bne s3, t0, store_expect
  li t0, 11
  bge s4, t0, store_expect
  li s8, 0
store_expect:
  add s11, s11, s8
  jal ra, effective_mode
store_probe:
  fsh f0, 0(s5)
  li t0, 0x20000
  csrc mstatus, t0
  jal ra, check_common
  /* Compare all24 bytes, including guards outside the permission region. */
  li t0, 0
check_mem:
  add t1, s0, t0
  lbu t2, 0(t1)
  addi t3, t0, 0x40
  bnez s8, compare_byte
  bne t0, s4, second_byte
  li t3, 0xef
second_byte:
  addi t4, s4, 1
  bne t0, t4, compare_byte
  li t3, 0xbe
compare_byte:
  bne t2, t3, fail
  addi t0, t0, 1
  li t1, 24
  blt t0, t1, check_mem
  /* FLH allowed by R/RW and the same complete two-byte footprint. */
  li s6, 5
  la s7, load_probe
  li s8, 1
  li t0, 2
  beq s3, t0, load_expect
  li t0, 11
  bge s4, t0, load_expect
  li s8, 0
load_expect:
  add s11, s11, s8
  jal ra, effective_mode
load_probe:
  flh f2, 0(s5)
  li t0, 0x20000
  csrc mstatus, t0
  jal ra, check_common
  fsd f2, 0(s1)
  bnez s8, check_dest_sentinel
  lhu t0, 0(s5)
  lw t1, 0(s1)
  li t2, 0xffff0000
  or t0, t0, t2
  /* Compare low32 using identical XLEN sign extension. */
#if __riscv_xlen == 64
  sext.w t0, t0
#endif
  bne t0, t1, fail
  lw t0, 4(s1)
  li t1, -1
  bne t0, t1, fail
  j next_offset
check_dest_sentinel:
  la t0, dest_bits
  lw t1, 0(t0)
  lw t2, 0(s1)
  bne t1, t2, fail
  lw t1, 4(t0)
  lw t2, 4(s1)
  bne t1, t2, fail
next_offset:
  addi s4, s4, 1
  li t0, 16
  blt s4, t0, offset_loop
  addi s3, s3, 1
  li t0, 3
  blt s3, t0, perm_loop
  addi s2, s2, 1
  li t0, 2
  blt s2, t0, mode_loop
  bne s10, s11, fail
  li t0, 126             /* 192 probes - 66 allowed */
  bne s10, t0, fail
  li a0, 0
  ebreak

effective_mode:
  li t0, 0x26000
  beqz s2, set_mode
  li t0, 0x26800
set_mode:
  csrw mstatus, t0
  ret
check_common:
  bne s10, s11, fail
  csrr t0, fcsr
  li t1, 0x43
  bne t0, t1, fail
  fsd f0, 8(s1)
  la t0, source_bits
  lw t1, 0(t0)
  lw t2, 8(s1)
  bne t1, t2, fail
  lw t1, 4(t0)
  lw t2, 12(s1)
  bne t1, t2, fail
  ret
trap:
  li t0, 0x20000
  csrc mstatus, t0
  beqz s8, fail
  csrr t0, mcause
  bne t0, s6, fail
  csrr t0, mepc
  bne t0, s7, fail
  csrr t0, mtval
  bne t0, s5, fail
  /* Both rejected operations must preserve f2 and full FCSR. */
  fsd f2, 0(s1)
  la t0, dest_bits
  lw t1, 0(t0)
  lw t2, 0(s1)
  bne t1, t2, fail
  lw t1, 4(t0)
  lw t2, 4(s1)
  bne t1, t2, fail
  csrr t0, fcsr
  li t1, 0x43
  bne t0, t1, fail
  addi s10, s10, 1
  addi t0, s7, 4
  csrw mepc, t0
  mret
fail:
  li t0, 0x20000
  csrc mstatus, t0
  li a0, 1
  ebreak
  j fail
.section .data
.balign 8
source_bits: .dword 0xffffffffffffbeef
dest_bits: .dword 0x0123456789abcdef
saved: .zero 16
.balign 32
area: .zero 24
