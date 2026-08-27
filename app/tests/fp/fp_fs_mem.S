.section .text
.globl _start
_start:
  li s0, 0
  la t0, trap_handler
  csrw mtvec, t0

  li t0, 0x6000
  csrs mstatus, t0
  la t0, initial_s
  flw ft0, 0(t0)
  la t0, initial_d
  fld ft1, 0(t0)

  li t0, 0x6000
  csrc mstatus, t0

  la t0, alternate_s
fs_off_flw:
  flw ft0, 0(t0)

  la t0, alternate_d
fs_off_fld:
  fld ft1, 0(t0)

  la t0, store_s
fs_off_fsw:
  fsw ft0, 0(t0)

  la t0, store_d
fs_off_fsd:
  fsd ft1, 0(t0)

after_fs_off:
  li t1, 4
  bne s0, t1, fail_trap_count

  li t0, 0x6000
  csrs mstatus, t0

  fmv.x.w t1, ft0
  li t2, 0x3f800000
  bne t1, t2, fail_flw_side_effect

  la t0, result_d
  fsd ft1, 0(t0)
  lw t1, 0(t0)
  bnez t1, fail_fld_side_effect
  lw t1, 4(t0)
  li t2, 0x3ff00000
  bne t1, t2, fail_fld_side_effect

  la t0, store_s
  lw t1, 0(t0)
  li t2, 0x11223344
  bne t1, t2, fail_fsw_side_effect

  la t0, store_d
  lw t1, 0(t0)
  li t2, 0x55667788
  bne t1, t2, fail_fsd_side_effect
  lw t1, 4(t0)
  li t2, 0x11223344
  bne t1, t2, fail_fsd_side_effect

  li t0, 0x00100000
  li t1, 0x5555
  sw t1, 0(t0)

trap_handler:
  csrr t0, mcause
  li t1, 2
  bne t0, t1, fail_cause
  csrr t0, mepc
  csrr t1, mtval
  lw t2, 0(t0)
  bne t1, t2, fail_tval
  addi t0, t0, 4
  csrw mepc, t0
  addi s0, s0, 1
  mret

fail_trap_count:
  li t0, 0x00100000
  li t1, 0x00013333
  sw t1, 0(t0)

fail_flw_side_effect:
  li t0, 0x00100000
  li t1, 0x00023333
  sw t1, 0(t0)

fail_fld_side_effect:
  li t0, 0x00100000
  li t1, 0x00033333
  sw t1, 0(t0)

fail_fsw_side_effect:
  li t0, 0x00100000
  li t1, 0x00043333
  sw t1, 0(t0)

fail_fsd_side_effect:
  li t0, 0x00100000
  li t1, 0x00053333
  sw t1, 0(t0)

fail_cause:
  li t0, 0x00100000
  li t1, 0x00063333
  sw t1, 0(t0)

fail_tval:
  li t0, 0x00100000
  li t1, 0x00073333
  sw t1, 0(t0)

.section .data
.align 3
initial_s:
  .word 0x3f800000
alternate_s:
  .word 0x40000000
.align 3
initial_d:
  .dword 0x3ff0000000000000
alternate_d:
  .dword 0x4000000000000000
store_s:
  .word 0x11223344
.align 3
store_d:
  .dword 0x1122334455667788
result_d:
  .dword 0
