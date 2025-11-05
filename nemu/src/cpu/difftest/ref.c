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
#include <cpu/cpu.h>
#include <difftest-def.h>
#include <memory/paddr.h>
#include <memory/vaddr.h>

extern CPU_state cpu;

typedef struct
{
  int state;
  word_t *gpr;
  word_t *ret;
  word_t *pc;
  char *priv;

  // csr
  word_t *sstatus;
  word_t *sie____;
  word_t *stvec__;

  word_t *scounte;

  word_t *sscratch;
  word_t *sepc___;
  word_t *scause_;
  word_t *stval__;
  word_t *sip____;
  word_t *satp___;

  word_t *mstatus;
  word_t *misa___;
  word_t *medeleg;
  word_t *mideleg;
  word_t *mie____;
  word_t *mtvec__;

  word_t *mstatush;

  word_t *mscratch;
  word_t *mepc___;
  word_t *mcause_;
  word_t *mtval__;
  word_t *mip____;

  word_t *mcycle_;
  word_t *time___;
  word_t *timeh__;

  // for mem diff
  word_t vwaddr;
  word_t pwaddr;
  word_t wdata;
  word_t wstrb;
  word_t len;

  // for iomm
  word_t iomm_addr;
  word_t skip;

  // for itrace
  uint32_t *inst;
  word_t *cpc;
  uint32_t last_inst;

  // for soc
  uint8_t *soc_sram;
} NPCState;

__EXPORT void difftest_memcpy(paddr_t addr, void *buf, size_t n, bool direction)
{
  if (direction == DIFFTEST_TO_REF)
  {
    if (in_pmem(addr) || in_sram(addr) || in_mrom(addr) || in_flash(addr))
    {
      memcpy(guest_to_host(addr), buf, n);
      return;
    }
    Assert(0, "DIFFTEST_TO_REF invalid address: " FMT_PADDR, addr);
  }
  else
  {
    if (in_pmem(addr) || in_sram(addr) || in_mrom(addr) || in_flash(addr))
    {
      memcpy(buf, guest_to_host(addr), n);
      return;
    }
    Assert(0, "DIFFTEST_TO_DUT invalid address: " FMT_PADDR, addr);
  }
}

__EXPORT void difftest_regcpy(void *dut, bool direction)
{
  NPCState *npc = (NPCState *)dut;
  if (direction == DIFFTEST_TO_REF)
  {
    cpu.pc = *npc->pc;
    for (int i = 0; i < RISCV_GPR_NUM; i++)
    {
      cpu.gpr[i] = npc->gpr[i];
    }
    cpu.sr[CSR_SSTATUS] = *npc->sstatus;
    cpu.sr[CSR_SIE] = *npc->sie____;
    cpu.sr[CSR_STVEC] = *npc->stvec__;

    cpu.sr[CSR_SSCRATCH] = *npc->sscratch;
    cpu.sr[CSR_SEPC] = *npc->sepc___;
    cpu.sr[CSR_SCAUSE] = *npc->scause_;
    cpu.sr[CSR_STVAL] = *npc->stval__;
    cpu.sr[CSR_SIP] = *npc->sip____;
    cpu.sr[CSR_SATP] = *npc->satp___;

    cpu.sr[CSR_MSTATUS] = *npc->mstatus;
    cpu.sr[CSR_MEDELEG] = *npc->medeleg;
    cpu.sr[CSR_MIDELEG] = *npc->mideleg;
    cpu.sr[CSR_MIE] = *npc->mie____;
    cpu.sr[CSR_MTVEC] = *npc->mtvec__;

    cpu.sr[CSR_MSCRATCH] = *npc->mscratch;
    cpu.sr[CSR_MEPC] = *npc->mepc___;
    cpu.sr[CSR_MCAUSE] = *npc->mcause_;
    cpu.sr[CSR_MTVAL] = *npc->mtval__;
    cpu.sr[CSR_MIP] = *npc->mip____;
    cpu.skip = 0; // reset skip flag
  }
  else if (direction == DIFFTEST_TO_DUT)
  {
    npc->cpc = &cpu.cpc;
    npc->inst = &cpu.inst;
    npc->gpr = cpu.gpr;
    npc->pc = &cpu.pc;
    npc->priv = (char *)&cpu.priv;

    npc->sstatus = &cpu.sr[CSR_SSTATUS];
    npc->sie____ = &cpu.sr[CSR_SIE];
    npc->stvec__ = &cpu.sr[CSR_STVEC];

    npc->sscratch = &cpu.sr[CSR_SSCRATCH];
    npc->sepc___ = &cpu.sr[CSR_SEPC];
    npc->scause_ = &cpu.sr[CSR_SCAUSE];
    npc->stval__ = &cpu.sr[CSR_STVAL];
    npc->sip____ = &cpu.sr[CSR_SIP];
    npc->satp___ = &cpu.sr[CSR_SATP];

    npc->mstatus = &cpu.sr[CSR_MSTATUS];
    npc->medeleg = &cpu.sr[CSR_MEDELEG];
    npc->mideleg = &cpu.sr[CSR_MIDELEG];
    npc->mie____ = &cpu.sr[CSR_MIE];
    npc->mtvec__ = &cpu.sr[CSR_MTVEC];

    npc->mscratch = &cpu.sr[CSR_MSCRATCH];
    npc->mepc___ = &cpu.sr[CSR_MEPC];
    npc->mcause_ = &cpu.sr[CSR_MCAUSE];
    npc->mtval__ = &cpu.sr[CSR_MTVAL];
    npc->mip____ = &cpu.sr[CSR_MIP];

    npc->vwaddr = cpu.vwaddr;
    npc->pwaddr = cpu.pwaddr;
    npc->wdata = cpu.wdata;
    npc->len = cpu.len;
    npc->skip = cpu.skip;
  }
  // isa_reg_display();
  // vaddr_show(cpu.pc, 0x2c);
}

__EXPORT void difftest_exec(uint64_t n)
{
  cpu_exec(n);
}

__EXPORT void difftest_raise_intr(word_t NO)
{
  cpu.intr = true;
}

__EXPORT void difftest_init(int port)
{
  void init_mem();
  init_mem();
  /* Perform ISA dependent initialization. */
  init_isa();
}
