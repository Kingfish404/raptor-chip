#ifndef ARCH_H__
#define ARCH_H__

#ifdef __riscv_e
#define NR_REGS 16
#else
#define NR_REGS 32
#endif

// RISC-V privilege levels
enum
{
  PRV_U = 0,
  PRV_S = 1,
  PRV_M = 3,
};

// RISC-V PTE fields
#define PTE_G 0x20

#define PTE_V 0x01
#define PTE_R 0x02
#define PTE_W 0x04
#define PTE_X 0x08
#define PTE_U 0x10
#define PTE_A 0x40
#define PTE_D 0x80

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

typedef union
{
  struct
  {
    size_t rev1 : 1;
    size_t sie : 1;
    size_t rev2 : 1;
    size_t mie : 1;
    size_t rev3 : 1;
    size_t spie : 1;
    size_t ube : 1;
    size_t mpie : 1;
    size_t spp : 1;
    size_t vs : 2;
    size_t mpp : 2;
    size_t fs : 2;
    size_t xs : 2;
    size_t mprv : 1;
    size_t sum : 1;
    size_t mxr : 1;
    size_t tvm : 1;
    size_t tw : 1;
    size_t tsr : 1;
    size_t rev4 : 8;
    size_t sd : 1;
  } mstatus;
  size_t val;
} csr_t;

struct Context
{
  uintptr_t gpr[NR_REGS];
  uintptr_t mcause, mstatus, mepc;
  void *pdir;
  uintptr_t np;
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
