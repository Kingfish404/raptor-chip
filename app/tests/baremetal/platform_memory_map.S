/* Check Raptor backing boundaries independently from the reference map. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  la t0, machine_trap
  csrw mtvec, t0
  csrw medeleg, zero
  csrw mie, zero
  li t0, -1
  csrw pmpaddr0, t0
  li t0, 0x1f
  csrw pmpcfg0, t0
  li s7, 0
  /* The final real SDRAM word remains writable. */
  li s9, 0xa1fffffc
  li t2, 0x12345678
  sw t2, 0(s9)
  lw t3, 0(s9)
  bne t2, t3, fail
  /* The final flash word is backed, despite the following page being a hole. */
  li s9, 0x3ffffffc
  lw t3, 0(s9)
  li s9, 0xa2000000
  jal ra, bad_load
  li s6, 7
  la s8, bad_store
  la s11, store_resume
bad_store:
  sw t2, 0(s9)
store_resume:
  li s9, 0x40000000
  jal ra, bad_load
  jal ra, bad_fetch
  /* QEMU virt's low boot ROM is not a Raptor memory target. */
  li s9, 0x1000
  jal ra, bad_load
  jal ra, bad_fetch
  li t0, 6
  bne s7, t0, fail
  li a0, 0
  ebreak
bad_load:
  li s4, 0x55
  li s6, 5
  la s8, load_fault
  la s11, load_resume
load_fault:
  lw s4, 0(s9)
load_resume:
  li t0, 0x55
  bne s4, t0, fail
  ret
bad_fetch:
  li s6, 1
  mv s8, s9
  la s11, fetch_resume
  jalr zero, s9, 0
fetch_resume:
  ret
machine_trap:
  csrr t0, mcause
  bne t0, s6, fail
  csrr t0, mepc
  bne t0, s8, fail
  csrr t0, mtval
  bne t0, s9, fail
  addi s7, s7, 1
  csrw mepc, s11
  mret
fail:
  li a0, 1
  ebreak
