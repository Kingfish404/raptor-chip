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

word_t isa_raise_intr(word_t NO, vaddr_t epc) {
#ifdef CONFIG_ETRACE
  printf("ETRACE | NO: %d at epc: " FMT_WORD " trap-handler base address: " FMT_WORD,
   NO, epc, cpu.sr[CSR_MTVEC]);
#endif
  cpu.sr[CSR_MEPC] = epc;
  cpu.sr[CSR_MCAUSE] = NO;

  // csr.mstatus.m.MPIE = csr.mstatus.m.MIE;
  CSR_BIT_COND_SET(CSR_MSTATUS, CSR_MSTATUS_MIE, CSR_MSTATUS_MPIE) 
  CSR_CLEAR(CSR_MSTATUS, CSR_MSTATUS_MIE) // csr.mstatus.m.MIE  = 0;

  return cpu.sr[CSR_MTVEC];
}

word_t isa_query_intr() {
  return INTR_EMPTY;
}
