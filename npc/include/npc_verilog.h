#pragma once
#ifndef __NPC_VERILOG_H__
#define __NPC_VERILOG_H__

#include <common.h>
#include <cpu.h>

#include CONCAT_HEAD(TOP_NAME)
#include CONCAT_HEAD(CONCAT(TOP_NAME, ___024root))
#include CONCAT_HEAD(CONCAT(TOP_NAME, __Dpi))

#ifdef YSYX_SOC
#define VERILOG_PREFIX top->rootp->ysyxSoCFull__DOT__asic__DOT__cpu__DOT__cpu
#else
#define VERILOG_PREFIX top->rootp->ysyx
#endif

static inline void verilog_connect(TOP_NAME *top, NPCState *npc)
{
  // for difftest
  npc->inst = (uint32_t *)&(CONCAT(VERILOG_PREFIX, __DOT__ifu__DOT__inst_idu));

  npc->gpr = (word_t *)&CONCAT(VERILOG_PREFIX, __DOT__regs__DOT__rf);
  npc->pc = (uint32_t *)&CONCAT(VERILOG_PREFIX, __DOT__pc);
  npc->ret = npc->gpr + reg_str2idx("a0");
  word_t *csr = (word_t *)&CONCAT(VERILOG_PREFIX, __DOT__exu__DOT__csr__DOT__csr);

  npc->state = NPC_RUNNING;
  npc->mstatus = csr + CSR_MSTATUS;
  npc->mcause = csr + CSR_MCAUSE;
  npc->mepc = csr + CSR_MEPC;
  npc->mtvec = csr + CSR_MTVEC;
}

#endif // __NPC_VERILOG_H__