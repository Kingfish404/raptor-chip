# Checks a core built with RAPT_NO_FPU: MISA lacks F and D, mstatus.FS stays Off
# after a write, and both an FP instruction and an FP CSR access trap as illegal.
# Reports through the sifive,test finisher: 0x5555 pass, (line << 16) | 0x3333 fail.
  .section .text
  .globl _start
_start:
  la t0, trap
  csrw mtvec, t0
  li s0, 0x00100000         # finisher
  li s1, 0                  # traps seen

  csrr t0, misa
  andi t1, t0, 0x28         # F (bit 5) and D (bit 3)
  bnez t1, fail_misa

  li t0, 0x6000             # mstatus.FS = Dirty
  csrs mstatus, t0
  csrr t1, mstatus
  and t1, t1, t0
  bnez t1, fail_fs

  la s2, after_fadd
  .option push
  .option arch, +f
  fadd.s f0, f1, f2
  .option pop
  j fail_no_trap
after_fadd:
  la s2, after_fcsr
  .option push
  .option arch, +f
  frcsr t2
  .option pop
  j fail_no_trap
after_fcsr:
  li t0, 2
  bne s1, t0, fail_count
  li t0, 0x5555
  sw t0, 0(s0)
1: j 1b

# Expect illegal instruction (cause 2), resume at s2.
trap:
  csrr t0, mcause
  li t1, 2
  bne t0, t1, fail_cause
  addi s1, s1, 1
  csrw mepc, s2
  mret

fail_misa:    li a0, 1
  j fail
fail_fs:      li a0, 2
  j fail
fail_no_trap: li a0, 3
  j fail
fail_count:   li a0, 4
  j fail
fail_cause:   li a0, 5
fail:
  slli a0, a0, 16
  li t0, 0x3333
  or a0, a0, t0
  sw a0, 0(s0)
2: j 2b
