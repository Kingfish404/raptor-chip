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

bool isa_difftest_checkregs(CPU_state *ref_r, vaddr_t pc)
{
  bool is_same = true;
  if (cpu.pc != ref_r->pc)
  {
    printf("Difftest: pc = " FMT_WORD ", ref = " FMT_WORD "\n", cpu.pc, ref_r->pc);
    is_same = false;
  }
  for (int i = 0; i < 32; i++)
  {
    if (gpr(i) != ref_r->gpr[i])
    {
      printf("Difftest: reg[%02d|%s] = " FMT_WORD ", ref = " FMT_WORD "\n", i, reg_name(i), gpr(i), ref_r->gpr[i]);
      is_same = false;
    }
  }
  return is_same;
}

void isa_difftest_attach()
{
}
