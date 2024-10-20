#pragma once
#ifndef __NPC_VERILOG_H__
#define __NPC_VERILOG_H__

#include <common.h>
#include <cpu.h>

#include CONCAT_HEAD(TOP_NAME)
#include CONCAT_HEAD(CONCAT(TOP_NAME, ___024root))
#include CONCAT_HEAD(CONCAT(TOP_NAME, __Dpi))

#ifdef YSYX_SOC
#define VERILOG_PREFIX top->rootp->ysyxSoCFull__DOT__asic__DOT__cpu__DOT__cpu__DOT__
#else
#define VERILOG_PREFIX top->rootp->ysyxSoC__DOT__cpu__DOT__
#endif

static inline void verilog_connect(TOP_NAME *top, NPCState *npc)
{
  // for difftest
  npc->inst = (uint32_t *)&(CONCAT(VERILOG_PREFIX, wbu__DOT__inst_wbu));

  npc->gpr = (word_t *)&CONCAT(VERILOG_PREFIX, regs__DOT__rf);
  npc->cpc = (uint32_t *)&CONCAT(VERILOG_PREFIX, wbu__DOT__pc_wbu);
  npc->pc = (uint32_t *)&CONCAT(VERILOG_PREFIX, wbu__DOT__npc_wbu);
  npc->ret = npc->gpr + reg_str2idx("a0");
  word_t *csr = (word_t *)&CONCAT(VERILOG_PREFIX, exu__DOT__csrs__DOT__csr);

  npc->state = NPC_RUNNING;
  npc->mstatus = csr + CSR_MSTATUS;
  npc->mcause = csr + CSR_MCAUSE;
  npc->mepc = csr + CSR_MEPC;
  npc->mtvec = csr + CSR_MTVEC;
}

#endif // __NPC_VERILOG_H__