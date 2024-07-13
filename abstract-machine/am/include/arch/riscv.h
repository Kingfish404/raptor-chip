#ifndef ARCH_H__
#define ARCH_H__

#ifdef __riscv_e
#define NR_REGS 16
#else
#define NR_REGS 32
#endif

enum {
    r_zero = 0, r_ra, r_sp, r_gp, r_tp, r_t0, r_t1, r_t2,
    r_s0, r_s1, r_a0, r_a1, r_a2, r_a3, r_a4, r_a5,
    r_a6, r_a7, r_s2, r_s3, r_s4, r_s5, r_s6, r_s7,
    r_s8, r_s9, r_s10, r_s11, r_t3, r_t4, r_t5, r_t6,
};

struct Context {
  // TODO: fix the order of these members to match trap.S
  uintptr_t gpr[NR_REGS], mcause, mstatus, mepc;
  void *pdir;
};

#ifdef __riscv_e
#define GPR1 gpr[15] // a5
#else
#define GPR1 gpr[17] // a7
#endif

#define GPR2 gpr[10]
#define GPR3 gpr[11]
#define GPR4 gpr[12]
#define GPRx gpr[10]

#endif
