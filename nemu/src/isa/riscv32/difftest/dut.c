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

// DUT: Device Under Test

#include <isa.h>
#include <cpu/difftest.h>
#include "../local-include/reg.h"

#define CHECK_CSR(name)                                                                \
  if (cpu.sr[name] != ref_r->sr[name])                                                 \
  {                                                                                    \
    printf(ANSI_FMT("Difftest: %12s: " FMT_WORD ", ref: " FMT_WORD "\n", ANSI_FG_RED), \
           #name, cpu.sr[name], ref_r->sr[name]);                                      \
    is_same = false;                                                                   \
  }

bool isa_difftest_checkregs(CPU_state *ref_r, vaddr_t pc)
{
  bool is_same = true;
  if (cpu.pc != ref_r->pc)
  {
    printf(ANSI_FMT("Difftest:           pc: " FMT_WORD ", ref: " FMT_WORD "\n", ANSI_FG_RED),
           cpu.pc, ref_r->pc);
    is_same = false;
  }
  for (int i = 0; i < MUXDEF(CONFIG_RVE, 16, 32); i++)
  {
    if (gpr(i) != ref_r->gpr[i])
    {
      printf(ANSI_FMT("Difftest:      reg[%s]: " FMT_WORD ", ref: " FMT_WORD "\n", ANSI_FG_RED),
             reg_name(i), gpr(i), ref_r->gpr[i]);
      is_same = false;
    }
  }
  CHECK_CSR(CSR_SSTATUS);
  CHECK_CSR(CSR_SIE);
  CHECK_CSR(CSR_STVEC);

  CHECK_CSR(CSR_SSCRATCH);
  CHECK_CSR(CSR_SEPC);
  CHECK_CSR(CSR_SCAUSE);
  CHECK_CSR(CSR_STVAL);
  // SIP: mask out hardware-controlled bits (STIP=5, SEIP=9) that may differ
  // due to different timer/PLIC implementations between DUT and ref
  {
    word_t sip_mask = ~((word_t)((1u << 5) | (1u << 9)));
    word_t dut_sip = cpu.sr[CSR_SIP] & sip_mask;
    word_t ref_sip = ref_r->sr[CSR_SIP] & sip_mask;
    if (dut_sip != ref_sip)
    {
      printf(ANSI_FMT("Difftest: %12s: " FMT_WORD ", ref: " FMT_WORD "\n", ANSI_FG_RED),
             "CSR_SIP", cpu.sr[CSR_SIP], ref_r->sr[CSR_SIP]);
      is_same = false;
    }
  }
  CHECK_CSR(CSR_SATP);

  CHECK_CSR(CSR_MSTATUSH);
  CHECK_CSR(CSR_MSTATUS);
  CHECK_CSR(CSR_MEDELEG);
  CHECK_CSR(CSR_MIDELEG);
  CHECK_CSR(CSR_MIE);
  CHECK_CSR(CSR_MTVEC);

  CHECK_CSR(CSR_MSCRATCH);
  CHECK_CSR(CSR_MEPC);
  CHECK_CSR(CSR_MCAUSE);
  CHECK_CSR(CSR_MTVAL);
  // MIP: mask out hardware-controlled bits (MSIP=3, MTIP=7, MEIP=11) that are
  // set by CLINT/PLIC hardware and may differ between DUT and ref timers
  {
    word_t mip_hw_mask = ~((word_t)((1u << 3) | (1u << 7) | (1u << 11)));
    word_t dut_mip = cpu.sr[CSR_MIP] & mip_hw_mask;
    word_t ref_mip = ref_r->sr[CSR_MIP] & mip_hw_mask;
    if (dut_mip != ref_mip)
    {
      printf(ANSI_FMT("Difftest: %12s: " FMT_WORD ", ref: " FMT_WORD "\n", ANSI_FG_RED),
             "CSR_MIP", cpu.sr[CSR_MIP], ref_r->sr[CSR_MIP]);
      is_same = false;
    }
  }

  if (cpu.priv != ref_r->priv)
  {
    printf("Difftest: priv = %d, ref = %d\n", cpu.priv, ref_r->priv);
    is_same = false;
  }
  return is_same;
}

void isa_difftest_attach()
{
}
