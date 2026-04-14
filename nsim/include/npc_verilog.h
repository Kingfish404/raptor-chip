#pragma once
#ifndef __NPC_VERILOG_H__
#define __NPC_VERILOG_H__

#include <common.h>
#include <cpu.h>

#include CONCAT_HEAD(TOP_NAME)
#include CONCAT_HEAD(CONCAT(TOP_NAME, ___024root))
#include CONCAT_HEAD(CONCAT(TOP_NAME, __Dpi))

#ifdef YSYX_SOC
// Verilator 5.x hierarchical cell access: rootp -> ysyxSoCFull -> asic -> cpu -> cpu (ysyx)
#include CONCAT_HEAD(CONCAT(TOP_NAME, _ysyxSoCFull))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _ysyxSoCASIC))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _CPU))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _ysyx))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _ysyx_rou))
#define VERILOG_CPU(m) (top->rootp->ysyxSoCFull->asic->cpu->cpu->m)
#define VERILOG_ROU(m) (top->rootp->ysyxSoCFull->asic->cpu->cpu->rou->m)
#define VERILOG_RESET (top->rootp->ysyxSoCFull->asic->cpu_reset_chain__DOT__output_chain__DOT__sync_0)
#else

#ifdef CONFIG_wrapBus
#define VERILOG_CPU(m) CONCAT(top->rootp->wrapSoC__DOT__chip__DOT__cpu__DOT__, m)
#define VERILOG_ROU(m) CONCAT(top->rootp->wrapSoC__DOT__chip__DOT__cpu__DOT__rou__DOT__, m)
#define VERILOG_RESET top->reset
#else
// NPC mode: Verilator 5.x hierarchical classes — navigate via cell pointers
#include CONCAT_HEAD(CONCAT(TOP_NAME, _ysyxSoC))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _ysyx))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _ysyx_rou))
#define VERILOG_CPU(m) (top->rootp->ysyxSoC->cpu->m)
#define VERILOG_ROU(m) (top->rootp->ysyxSoC->cpu->rou->m)
#define VERILOG_RESET top->reset
#endif

#endif

static inline void verilog_connect(TOP_NAME *top, NPCState *npc)
{
  // for difftest
  npc->inst = (uint32_t *)&VERILOG_CPU(cmu__DOT__inst);

  npc->gpr = (word_t *)&VERILOG_CPU(rf);
  npc->rpc = (word_t *)&VERILOG_CPU(cmu__DOT__rpc);
  npc->ret = npc->gpr + reg_str2idx("a0");
  npc->pc = (word_t *)&VERILOG_CPU(cmu__DOT__npc);
  npc->priv = (char *)&VERILOG_CPU(csrs__DOT__priv_mode);
  word_t *csr = (word_t *)&VERILOG_CPU(csrs__DOT__csr);

  npc->state = NPC_RUNNING;

  npc->sstatus = csr + SSTATUS;
  npc->sie____ = csr + SIE____;
  npc->stvec__ = csr + STVEC__;

  npc->scounte = csr + SCOUNTE;

  npc->sscratch = csr + SSCRATCH;
  npc->sepc___ = csr + SEPC___;
  npc->scause_ = csr + SCAUSE_;
  npc->stval__ = csr + STVAL__;
  npc->sip____ = csr + SIP____;
  npc->satp___ = csr + SATP___;

  npc->mstatus = csr + MSTATUS;
  npc->medeleg = csr + MEDELEG;
  npc->mideleg = csr + MIDELEG;
  npc->mie____ = csr + MIE____;
  npc->mtvec__ = csr + MTVEC__;

  npc->mscratch = csr + MSCRATCH;
  npc->mepc___ = csr + MEPC___;
  npc->mcause_ = csr + MCAUSE_;
  npc->mtval__ = csr + MTVAL__;
  npc->mip____ = csr + MIP____;
}

#endif // __NPC_VERILOG_H__