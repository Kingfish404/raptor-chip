#ifndef __NPC_CPU_H__
#define __NPC_CPU_H__

typedef enum
{
  MNONE__ = 0,

  // Keep this order identical to `csr_t` in rapt_csr.sv. F/D CSRs occupy
  // the first three storage slots, so omitting them shifts every later CSR
  // observed by difftest.
  FFLAGS,
  FRM,
  FCSR,

  SSTATUS,
  SIE____,
  STVEC__,

  // NOTE: order MUST match `csr_t` in hdl/frontend/rapt_csr.sv exactly,
  // because difftest indexes into the DUT's csr[] storage by these values.
  SCOUNTE,
  MCOUNTE,

  SSCRATCH,
  SEPC___,
  SCAUSE_,
  STVAL__,
  SIP____,
  STIMECMP,
  STIMECMPH,
  SATP___,

  MSTATUS,
  MISA___,
  MEDELEG,
  MIDELEG,
  MIE____,
  MTVEC__,

  MSTATUSH,
  MENVCFG,

  MSCRATCH,
  MEPC___,
  MCAUSE_,
  MTVAL__,
  MIP____,

  MCYCLE_,
  MCYCLEH,
  MINSTRET,
  MINSTRETH,
  TIME___,
  TIMEH__,

  MVENDORID,
  MARCHID,
  IMPID__,
  MHARTID
} csr_t;

void cpu_exec_init();

void cpu_exec(uint64_t n);

void cpu_show_itrace();

#endif /* __NPC_CPU_H__ */