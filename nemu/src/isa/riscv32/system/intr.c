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

#include <isa.h>
#include <isa-def.h>
#include <stdio.h>
#include <cpu/difftest.h>

#if defined(CONFIG_ISA64)
// for riscv64
#define IRQ_TIMER 0x8000000000000007
#else
// for riscv32
#define IRQ_TIMER 0x80000007
#endif

extern word_t g_vaddr;

word_t isa_raise_intr(word_t NO, vaddr_t epc)
{
#ifdef CONFIG_ETRACE
  printf("ETRACE | NO: %d at epc: " FMT_WORD " trap-handler base address: " FMT_WORD,
         NO, epc, cpu.sr[CSR_MTVEC]);
#endif
  word_t tval = 0;
  switch (NO)
  {
  case MCA_ILLEGAL_INS:
    tval = cpu.inst;
    break;
  case MCA_BREAK_POINT:
    tval = epc;
    break;
  case MCA_LOA_ADD_MIS:
    tval = g_vaddr;
    break;
  case MCA_LOA_ACC_FAU:
    tval = g_vaddr;
    break;
  case MCA_STO_ADD_MIS:
    tval = g_vaddr;
    break;
  case MCA_STO_ACC_FAU:
    tval = g_vaddr;
    break;
  case MCA_ENV_CAL_UMO:
  case MCA_ENV_CAL_SMO:
  case MCA_ENV_CAL_MMO:
    tval = 0;
    break;
  case MCA_INS_PAG_FAU:
    tval = epc;
    break;
  case MCA_LOA_PAG_FAU:
  case MCA_STO_PAG_FAU:
    tval = g_vaddr;
    break;
  default:
    tval = epc;
    break;
  }
  word_t ret_pc = 0;
  if (cpu.priv <= PRV_S)
  {
    if ((cpu.sr[CSR_MEDELEG] & (1 << NO)) ||
        ((NO & (1 << (XLEN - 1))) &&
         (cpu.sr[CSR_MIDELEG] & (1 << (NO & ~(1 << (XLEN - 1)))))))
    {
      // printf("NO: %x, (NO & (1 << (XLEN - 1))): %x, "
      //        "(1 << (NO & ~(1 << (XLEN - 1)))): %x\n",
      //        NO, (NO & (1 << (XLEN - 1))), (1 << (NO & ~(1 << (XLEN - 1)))));
      cpu.sr[CSR_STVAL] = tval;
      cpu.sr[CSR_SEPC] = epc;
      cpu.sr[CSR_SCAUSE] = NO;

      csr_t reg_s = {.val = cpu.sr[CSR_SSTATUS]};
      reg_s.mstatus.spp = cpu.priv;
      reg_s.mstatus.spie = reg_s.mstatus.sie;
      reg_s.mstatus.sie = 0;
      cpu.sr[CSR_SSTATUS] = reg_s.val;

      csr_t reg_m = {.val = cpu.sr[CSR_MSTATUS]};
      reg_m.mstatus.spp = cpu.priv;
      reg_m.mstatus.spie = reg_m.mstatus.sie;
      reg_m.mstatus.sie = 0;
      cpu.sr[CSR_MSTATUS] = reg_m.val;

      cpu.last_inst_priv = cpu.priv;
      cpu.priv = PRV_S;
      ret_pc = cpu.sr[CSR_STVEC];
      return ret_pc;
    }
  }
  cpu.sr[CSR_MTVAL] = tval;
  cpu.sr[CSR_MEPC] = epc;
  cpu.sr[CSR_MCAUSE] = NO;
  csr_t reg = {.val = cpu.sr[CSR_MSTATUS]};
  reg.mstatus.mpp = cpu.priv;
  reg.mstatus.mpie = reg.mstatus.mie;
  reg.mstatus.mie = 0;
  cpu.sr[CSR_MSTATUS] = reg.val;

  cpu.last_inst_priv = cpu.priv;
  cpu.raise_intr = NO;
  cpu.priv = PRV_M;
  ret_pc = cpu.sr[CSR_MTVEC];
  return ret_pc;
}

word_t isa_query_intr()
{
  csr_t reg_mstatus = {.val = cpu.sr[CSR_MSTATUS]};
  csr_t reg_mie = {.val = cpu.sr[CSR_MIE]};

  if (cpu.intr)
  {
    if (cpu.priv == PRV_M &&
        (reg_mstatus.mstatus.mie == 1 &&
         reg_mie.mie.mtie == 1))
    {
      cpu.intr = false;
      return MCA_MAC_TIM_INT;
    }
    if (cpu.priv == PRV_S &&
        (reg_mstatus.mstatus.sie == 1 &&
         reg_mie.mie.stie == 1))
    {
      cpu.intr = false;
      return MCA_SUP_TIM_INT;
    }
  }
  return INTR_EMPTY;
}
