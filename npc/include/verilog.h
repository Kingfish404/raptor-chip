#pragma once
#ifndef __NPC_VERILOG_H__
#define __NPC_VERILOG_H__

#include <common.h>
#include <cpu.h>

// #include "Vysyx.h"
// #include "Vysyx___024root.h"
// #include "Vysyx__Dpi.h"

#include CONCAT_HEAD(TOP_NAME)
#include CONCAT_HEAD(CONCAT(TOP_NAME, ___024root))
#include CONCAT_HEAD(CONCAT(TOP_NAME, __Dpi))

static inline void verilog_connect(TOP_NAME *top, NPCState *npc)
{
  // for difftest
  npc->inst = (uint32_t *)&(top->rootp->ysyx__DOT__ifu__DOT__inst_ifu);

  npc->gpr = (word_t *)&(top->rootp->ysyx__DOT__regs__DOT__rf);
  npc->pc = (uint32_t *)&(top->rootp->ysyx__DOT__pc);
  npc->ret = npc->gpr + reg_str2idx("a0");
  word_t *csr = (word_t *)&(top->rootp->ysyx__DOT__exu__DOT__csr__DOT__csr);

  npc->state = NPC_RUNNING;
  npc->mstatus = csr + CSR_MSTATUS;
  npc->mcause = csr + CSR_MCAUSE;
  npc->mepc = csr + CSR_MEPC;
  npc->mtvec = csr + CSR_MTVEC;
}

#endif // __NPC_VERILOG_H__