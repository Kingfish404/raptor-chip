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

word_t isa_raise_intr(word_t NO, vaddr_t epc)
{
#ifdef CONFIG_ETRACE
  printf("ETRACE | NO: %d at epc: " FMT_WORD " trap-handler base address: " FMT_WORD,
         NO, epc, cpu.sr[CSR_MTVEC]);
#endif
  // printf("ecall: priv: %d, mstatus: " FMT_WORD ", NO: %d\n",
  //        cpu.priv, cpu.sr[CSR_MSTATUS], NO);
  cpu.sr[CSR_MEPC] = epc;
  cpu.sr[CSR_MCAUSE] = NO;
  csr_t reg = {.val = cpu.sr[CSR_MSTATUS]};
  reg.mstatus.mpp = cpu.priv;
  reg.mstatus.mpie = reg.mstatus.mie;
  reg.mstatus.mie = 0;
  cpu.sr[CSR_MSTATUS] = reg.val;
  cpu.priv = PRV_M;

  return cpu.sr[CSR_MTVEC];
}

word_t isa_query_intr()
{
  return INTR_EMPTY;
}
