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
#include "local-include/reg.h"

/*
    | Register | ABI Name | Description                      | Saver  |
    |----------|----------|----------------------------------|--------|
    | x0       | zero     | Hard-wired zero                  | --     |
    | x1       | ra       | Return address                   | Caller |
    | x2       | sp       | Stack pointer                    | Callee |
    | x3       | gp       | Global pointer                   | --     |
    | x4       | tp       | Thread pointer                   | --     |
    | x5       | t0       | Temporaries/alternate link reg   | Caller |
    | x6-7     | t1-2     | Temporaries                      | Caller |
    | x8       | s0/fp    | Saved register/frame pointer     | Callee |
    | x9       | s1       | Saved register                   | Callee |
    | x10-11   | a0-1     | Function arguments/return values | Caller |
    | x12-17   | a2-7     | Function arguments               | Caller |
    | x18-27   | s2-11    | Saved registers                  | Callee |
    | x28-31   | t3-6     | Temporaries                      | Caller |
    |----------|----------|----------------------------------|--------|
    | f0-7     | ft0-7    | FP temporaries                   | Caller |
    | f8-9     | fs0-1    | FP saved registers               | Callee |
    | f10-11   | fa0-1    | FP arguments/return values       | Caller |
    | f12-17   | fa2-7    | FP arguments                     | Caller |
    | f18-27   | fs2-11   | FP saved registers               | Callee |
    | f28-31   | ft8-11   | FP temporaries                   | Caller |
 */
const char *regs[] = {
    "$0", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"};

void isa_reg_display()
{
  printf(" pc: " FMT_WORD_NO_PREFIX "\n", cpu.pc);
  for (int i = 0; i < MUXDEF(CONFIG_RVE, 16, 32); i++)
  {
    if (i > 0 && i % 4 == 0)
      printf("\n");
    printf("%3s: " FMT_WORD_NO_PREFIX "\t", regs[i], cpu.gpr[i]);
  }
  printf("\n");
  printf("msr.mstatus: " FMT_WORD_NO_PREFIX "\n", cpu.sr[CSR_MSTATUS]);
  printf("   msr.mepc: " FMT_WORD_NO_PREFIX "\n", cpu.sr[CSR_MEPC]);
  printf(" msr.mcause: " FMT_WORD_NO_PREFIX "\n", cpu.sr[CSR_MCAUSE]);
  printf("  msr.mtvec: " FMT_WORD_NO_PREFIX "\n", cpu.sr[CSR_MTVEC]);
}

word_t isa_reg_str2val(const char *s, bool *success)
{
  if (strcmp(s, "pc") == 0)
  {
    *success = true;
    return cpu.pc;
  }
  for (int i = 0; i < MUXDEF(CONFIG_RVE, 16, 32); i++)
  {
    if (strcmp(s, regs[i]) == 0)
    {
      *success = true;
      return cpu.gpr[i];
    }
  }
  *success = false;
  return 0;
}
