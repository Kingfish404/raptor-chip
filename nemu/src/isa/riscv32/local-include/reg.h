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

#define sr(idx) (cpu.sr[check_sr_idx(idx)])

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
          csr == CSR_SIE ||
          csr == CSR_STVEC ||

          csr == CSR_SCOUNTEREN ||

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
          csr == CSR_TIME ||
          csr == CSR_TIMEH ||

          csr == CSR_MVENDORID ||
          csr == CSR_MARCHID ||
          csr == CSR_IMPID ||
          csr == CSR_MHARTID))
  {
    if (
        csr == CSR_MISA ||
        csr == CSR_TIME ||
        csr == CSR_TIMEH ||
        csr == CSR_MVENDORID ||
        csr == CSR_MARCHID)
    {
      return CSR_EXIST_DIFF_SKIP;
    }
    return CSR_EXIST;
  }
  return CSR_NOT_EXIST;
}

#endif
