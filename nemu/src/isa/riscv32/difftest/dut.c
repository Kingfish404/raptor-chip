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
#include <cpu/difftest.h>
#include "../local-include/reg.h"

#define CHECK_CSR(name)                                              \
  if (cpu.sr[name] != ref_r->sr[name])                               \
  {                                                                  \
    printf("Difftest: csr[%s] = " FMT_WORD ", ref = " FMT_WORD "\n", \
           #name, cpu.sr[name], ref_r->sr[name]);                    \
    is_same = false;                                                 \
  }

bool isa_difftest_checkregs(CPU_state *ref_r, vaddr_t pc)
{
  bool is_same = true;
  if (cpu.pc != ref_r->pc)
  {
    printf("Difftest: pc = " FMT_WORD ", ref = " FMT_WORD "\n", cpu.pc, ref_r->pc);
    is_same = false;
  }
  for (int i = 0; i < MUXDEF(CONFIG_RVE, 16, 32); i++)
  {
    if (gpr(i) != ref_r->gpr[i])
    {
      printf("Difftest: reg[%s] = " FMT_WORD ", ref = " FMT_WORD "\n", reg_name(i), gpr(i), ref_r->gpr[i]);
      is_same = false;
    }
  }
  CHECK_CSR(CSR_MSTATUS);
  if (cpu.sr[CSR_MSTATUS] != ref_r->sr[CSR_MSTATUS])
  {
    printf("Difftest: csr[%s] = " FMT_WORD ", ref = " FMT_WORD "\n",
           "CSR_MSTATUS", cpu.sr[CSR_MSTATUS], ref_r->sr[CSR_MSTATUS]);
  }
  CHECK_CSR(CSR_MEPC);
  CHECK_CSR(CSR_MTVEC);
  CHECK_CSR(CSR_MCAUSE);
  CHECK_CSR(CSR_SATP);
  return is_same;
}

void isa_difftest_attach()
{
}
