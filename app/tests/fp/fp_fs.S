.section .text
.globl _start
_start:
  li s0, 0
  la t0, trap_handler
  csrw mtvec, t0

  li t0, 0x3f800000
fs_off_fmv:
  fmv.w.x ft0, t0

after_fs_off:
  li t1, 1
  bne s0, t1, fail_trap_count

  li t0, 0x2000
  csrw mstatus, t0
  li t0, 0x3f800000
  fmv.w.x ft0, t0
  csrr t1, mstatus
  li t2, 0x6000
  and t1, t1, t2
  bne t1, t2, fail_fp_dirty

  li t0, 0x2000
  csrw mstatus, t0
  csrw fflags, zero
  csrr t1, mstatus
  li t2, 0x6000
  and t1, t1, t2
  bne t1, t2, fail_csr_dirty

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

trap_handler:
  csrr t0, mcause
  li t1, 2
  bne t0, t1, fail_cause
  csrr t0, mtval
  li t1, 0xf0028053
  bne t0, t1, fail_tval
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  addi s0, s0, 1
  mret

fail_trap_count:
  li t0, 0x00100000
  li t1, 0x00013333
  sw t1, 0(t0)

fail_fp_dirty:
  li t0, 0x00100000
  li t1, 0x00023333
  sw t1, 0(t0)

fail_csr_dirty:
  li t0, 0x00100000
  li t1, 0x00033333
  sw t1, 0(t0)

fail_cause:
  li t0, 0x00100000
  li t1, 0x00043333
  sw t1, 0(t0)

fail_tval:
  li t0, 0x00100000
  li t1, 0x00053333
  sw t1, 0(t0)