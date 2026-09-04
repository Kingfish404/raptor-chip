/***************************************************************************************
 * Copyright (c) 2014-2022 Zihao Yu, Nanjing University
 *
 * NEMU is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *          http://license.coscl.org.cn/MulanPSL2
 *
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
 * EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
 * MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 *
 * See the Mulan PSL v2 for more details.
 ***************************************************************************************/

#ifndef __RISCV_REG_H__
#define __RISCV_REG_H__

#include <common.h>
#include <isa-def.h>

static inline int check_reg_idx(int idx)
{
  IFDEF(CONFIG_RT_CHECK, assert(idx >= 0 && idx < MUXDEF(CONFIG_RVE, 16, 32)));
  return idx;
}

static inline int check_sr_idx(int idx)
{
  idx = idx & 0xfff;
  IFDEF(CONFIG_RT_CHECK, assert(idx >= 0 && idx < 4096));
  return idx;
}

#define gpr(idx) (cpu.gpr[check_reg_idx(idx)])

static inline int check_fpr_idx(int idx)
{
  IFDEF(CONFIG_RT_CHECK, assert(idx >= 0 && idx < 32));
  return idx;
}

#define fpr(idx) (cpu.fpr[check_fpr_idx(idx)])

#define sr(idx) (cpu.sr[check_sr_idx(idx)])

// PMP (pmpcfg0..3 @ 0x3a0-0x3a3, pmpaddr0..15 @ 0x3b0-0x3bf) is now
// implemented in nemu/src/isa/riscv/system/pmp.c.  CSR reads go through
// cpu.sr[] directly; writes are routed through pmp_csr_write() which
// enforces WARL masking and L-bit lockdown.
static inline bool is_pmp_csr(uint16_t csr)
{
  csr = csr & 0xfff;
  return (csr >= 0x3a0 && csr <= 0x3a3) || (csr >= 0x3b0 && csr <= 0x3bf);
}

static inline bool is_fp_csr(uint16_t csr)
{
  csr &= 0xfff;
  return csr == CSR_FFLAGS || csr == CSR_FRM || csr == CSR_FCSR;
}

/* Raptor implements the optional Zihpm CSR banks as WARL-zero.  Keep the
 * reference model's CSR existence and read/write behaviour aligned with the
 * RTL: reads return zero and writes to the machine banks are ignored. */
static inline bool is_hpm_zero_csr(uint16_t csr)
{
  csr &= 0xfff;
  if ((csr >= 0xb03 && csr <= 0xb1f) ||  /* mhpmcounter3..31 */
      (csr >= 0x323 && csr <= 0x33f) ||  /* mhpmevent3..31 */
      (csr >= 0xc03 && csr <= 0xc1f))    /* hpmcounter3..31 */
    return true;
#ifndef CONFIG_RV64
  if ((csr >= 0xb83 && csr <= 0xb9f) ||  /* mhpmcounter3h..31h */
      (csr >= 0xc83 && csr <= 0xc9f))    /* hpmcounter3h..31h */
    return true;
#endif
  return false;
}

static inline unsigned counteren_bit(uint16_t csr)
{
  csr &= 0xfff;
  if (csr == CSR_CYCLE_ || csr == CSR_CYCLEH) return 1u << 0;
  if (csr == CSR_TIME || csr == CSR_TIMEH) return 1u << 1;
  if (csr == CSR_INSTRET || csr == CSR_INSTRETH) return 1u << 2;
  return 0;
}

static inline bool is_rv32_counter_high_csr(uint16_t csr)
{
#ifdef CONFIG_RV64
  (void)csr;
  return false;
#else
  csr &= 0xfff;
  return csr == CSR_MCYCLEH || csr == CSR_MINSTRETH ||
         csr == CSR_CYCLEH || csr == CSR_TIMEH || csr == CSR_INSTRETH;
#endif
}

static inline const char *reg_name(int idx)
{
  extern const char *regs[];
  return regs[check_reg_idx(idx)];
}

typedef enum
{
  CSR_EXIST,
  CSR_EXIST_DIFF_SKIP,
  CSR_NOT_EXIST
} CSR_status;

static inline CSR_status check_csr_exist(uint16_t csr)
{
  csr = csr & 0xfff;
  if (likely(
          csr == CSR_SSTATUS ||
          csr == CSR_FFLAGS ||
          csr == CSR_FRM ||
          csr == CSR_FCSR ||
          csr == CSR_SIE ||
          csr == CSR_STVEC ||

          csr == CSR_SCOUNTEREN ||
          csr == CSR_SENVCFG ||

          csr == CSR_SSCRATCH ||
          csr == CSR_SEPC ||
          csr == CSR_SCAUSE ||
          csr == CSR_STVAL ||
          csr == CSR_SIP ||
          csr == CSR_SATP ||

          csr == CSR_MSTATUS ||
          csr == CSR_MISA ||
          csr == CSR_MEDELEG ||
          csr == CSR_MIDELEG ||
          csr == CSR_MIE ||
          csr == CSR_MTVEC ||

          csr == CSR_MSTATUSH ||

          csr == CSR_MSCRATCH ||
          csr == CSR_MEPC ||
          csr == CSR_MCAUSE ||
          csr == CSR_MTVAL ||
          csr == CSR_MIP ||

          csr == CSR_MCYCLE ||
          csr == CSR_MINSTRET ||
          csr == CSR_CYCLE_ ||
          csr == CSR_TIME ||
          csr == CSR_INSTRET ||
          is_rv32_counter_high_csr(csr) ||

          csr == CSR_MVENDORID ||
          csr == CSR_MARCHID ||
          csr == CSR_IMPID ||
          csr == CSR_MHARTID ||

          csr == 0x14d ||  // stimecmp
          csr == 0x15d ||  // stimecmph (RV32 view; harmless in RV64 table)
          csr == CSR_MCOUNTEREN ||
          csr == 0x30a ||  // menvcfg
          is_hpm_zero_csr(csr) ||
          (csr >= 0x3a0 && csr <= 0x3a3) ||  // pmpcfg0-3
          (csr >= 0x3b0 && csr <= 0x3bf)))    // pmpaddr0-15
  {
    if ((0) //
        || csr == CSR_MISA

        || (csr == CSR_MCYCLE)    //
        || (csr == CSR_MINSTRET)  //
        || (csr == CSR_CYCLE_)    //
        || (csr == CSR_TIME)      //
        || (csr == CSR_INSTRET)   //
        || is_rv32_counter_high_csr(csr)

        || (csr == CSR_MVENDORID) //
        || (csr == CSR_MARCHID)   //
        || (csr == CSR_IMPID)     //
        || (csr == CSR_MHARTID)   //

        || csr == 0x14d   // stimecmp
        || csr == 0x15d   // stimecmph
        || csr == CSR_MCOUNTEREN
        || csr == 0x30a   // menvcfg
    )
    {
      return CSR_EXIST_DIFF_SKIP;
    }
    return CSR_EXIST;
  }
  return CSR_NOT_EXIST;
}

#endif
