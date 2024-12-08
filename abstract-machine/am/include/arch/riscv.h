#ifndef ARCH_H__
#define ARCH_H__

#ifdef __riscv_e
#define NR_REGS 16
#else
#define NR_REGS 32
#endif

enum
{
  r_zero = 0,
  r_ra = 1,
  r_sp = 2,
  r_gp = 3,
  r_tp = 4,
  r_t0 = 5,
  r_t1 = 6,
  r_t2 = 7,
  r_s0 = 8,
  r_s1 = 9,
  r_a0 = 10,
  r_a1 = 11,
  r_a2 = 12,
  r_a3 = 13,
  r_a4 = 14,
  r_a5 = 15,
  r_a6 = 16,
  r_a7 = 17,
  r_s2 = 18,
  r_s3 = 19,
  r_s4 = 20,
  r_s5 = 21,
  r_s6 = 22,
  r_s7 = 23,
  r_s8 = 24,
  r_s9 = 25,
  r_s10 = 26,
  r_s11 = 27,
  r_t3 = 28,
  r_t4 = 29,
  r_t5 = 30,
  r_t6 = 31
};

struct Context
{
  // TODO: fix the order of these members to match trap.S
  uintptr_t gpr[NR_REGS], mcause, mstatus, mepc;
  void *pdir;
};

#ifdef __riscv_e
#define GPR1 gpr[15] // a5
#else
#define GPR1 gpr[17] // a7
#endif

#define GPR2 gpr[r_a0]
#define GPR3 gpr[r_a1]
#define GPR4 gpr[r_a2]
#define GPRx gpr[r_a0]

#endif
