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
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"};

extern uint64_t g_nr_guest_inst;

void isa_reg_display()
{
  csr_t reg_mstatus = {.val = cpu.sr[CSR_MSTATUS]};
  csr_t reg_mie = {.val = cpu.sr[CSR_MIE]};
  printf(" pc: " FMT_WORD_NO_PREFIX ", num: %llu , inst.val: " FMT_WORD "\n",
         cpu.pc, g_nr_guest_inst, cpu.inst);
  printf(" cpu.inst: %x, cpu.priv: %d, cpu.intr: %d\n",
         cpu.inst, cpu.priv, cpu.intr);
  printf(" mstatus.mie: %d, mie.mtie: %d, mstatus.sie: %d, mie.stie: %d\n",
         reg_mstatus.mstatus.mie, reg_mie.mie.mtie, reg_mstatus.mstatus.sie, reg_mie.mie.stie);

  printf(" csr.sstatus: " FMT_WORD " ", cpu.sr[CSR_SSTATUS]);
  printf("     csr.sie: " FMT_WORD " ", cpu.sr[CSR_SIE]);
  printf("   csr.stvec: " FMT_WORD "\n", cpu.sr[CSR_STVEC]);

  printf("csr.sscratch: " FMT_WORD " ", cpu.sr[CSR_SSCRATCH]);
  printf("    csr.sepc: " FMT_WORD " ", cpu.sr[CSR_SEPC]);
  printf("  csr.scause: " FMT_WORD "\n", cpu.sr[CSR_SCAUSE]);
  printf("   csr.stval: " FMT_WORD " ", cpu.sr[CSR_STVAL]);
  printf("     csr.sip: " FMT_WORD " ", cpu.sr[CSR_SIP]);
  printf("    csr.satp: " FMT_WORD "\n", cpu.sr[CSR_SATP]);

  printf("csr.mstatush: " FMT_WORD "\n", cpu.sr[CSR_MSTATUSH]);
  printf(" csr.mstatus: " FMT_WORD " ", cpu.sr[CSR_MSTATUS]);
  printf(" csr.medeleg: " FMT_WORD " ", cpu.sr[CSR_MEDELEG]);
  printf(" csr.mideleg: " FMT_WORD "\n", cpu.sr[CSR_MIDELEG]);
  printf("     csr.mie: " FMT_WORD " ", cpu.sr[CSR_MIE]);
  printf("   csr.mtvec: " FMT_WORD "\n", cpu.sr[CSR_MTVEC]);

  printf("csr.mscratch: " FMT_WORD " ", cpu.sr[CSR_MSCRATCH]);
  printf("    csr.mepc: " FMT_WORD " ", cpu.sr[CSR_MEPC]);
  printf("  csr.mcause: " FMT_WORD "\n", cpu.sr[CSR_MCAUSE]);
  printf("   csr.mtval: " FMT_WORD " ", cpu.sr[CSR_MTVAL]);
  printf("     csr.mip: " FMT_WORD "\n", cpu.sr[CSR_MIP]);

  printf("  csr.mcycle: " FMT_WORD " ", cpu.sr[CSR_MCYCLE]);
  printf("csr.mtimecmp:  %8llx ", cpu.mtimecmp);
  printf("    csr.misa: " FMT_WORD "\n", cpu.sr[CSR_MISA]);
  printf("\n");
  for (int i = 0; i < MUXDEF(CONFIG_RVE, 16, 32); i++)
  {
    if (i > 0 && i % 4 == 0)
      printf("\n");
    printf("%4s: " FMT_WORD "", regs[i], cpu.gpr[i]);
  }
  printf("\n");
}

word_t isa_reg_str2val(const char *s, bool *success)
{
  if (strcmp(s, "pc") == 0)
  {
    *success = true;
    return cpu.pc;
  }
  if (strcmp(s, "mstatus") == 0)
  {
    *success = true;
    return cpu.sr[CSR_MSTATUS];
  }
  if (strcmp(s, "mepc") == 0)
  {
    *success = true;
    return cpu.sr[CSR_MEPC];
  }
  if (strcmp(s, "mtvec") == 0)
  {
    *success = true;
    return cpu.sr[CSR_MTVEC];
  }
  if (strcmp(s, "mcause") == 0)
  {
    *success = true;
    return cpu.sr[CSR_MCAUSE];
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
