#pragma once
#ifndef __NPC_VERILOG_H__
#define __NPC_VERILOG_H__

#include <common.h>
#include <cpu.h>

#include CONCAT_HEAD(TOP_NAME)
#include CONCAT_HEAD(CONCAT(TOP_NAME, ___024root))
#include CONCAT_HEAD(CONCAT(TOP_NAME, __Dpi))

#ifdef RAPT_SOC
// Verilator 5.x hierarchical cell access: rootp -> ysyxSoCFull -> asic -> cpu -> cpu (rapt)
#include CONCAT_HEAD(CONCAT(TOP_NAME, _ysyxSoCFull))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _ysyxSoCASIC__pi1))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _CPU))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _rapt))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _rapt_rou))
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
#include CONCAT_HEAD(CONCAT(TOP_NAME, _raptSoC))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _rapt))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _rapt_rou))
#define VERILOG_CPU(m) (top->rootp->raptSoC->cpu->m)
#define VERILOG_ROU(m) (top->rootp->raptSoC->cpu->rou->m)
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
  npc->mcounte = csr + MCOUNTE;

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

  npc->mstatush = csr + MSTATUSH;

  npc->mscratch = csr + MSCRATCH;
  npc->mepc___ = csr + MEPC___;
  npc->mcause_ = csr + MCAUSE_;
  npc->mtval__ = csr + MTVAL__;
  npc->mip____ = csr + MIP____;

  npc->mcycle_ = csr + MCYCLE_;
  npc->mcycleh = csr + MCYCLEH;
  npc->minstret = csr + MINSTRET;
  npc->minstreth = csr + MINSTRETH;
  npc->time___ = csr + TIME___;
  npc->timeh__ = csr + TIMEH__;

  npc->clint_mtime = (uint64_t *)&VERILOG_CPU(bus__DOT__clint__DOT__mtime);
  npc->clint_mtimecmp = (uint64_t *)&VERILOG_CPU(bus__DOT__clint__DOT__mtimecmp);
  npc->clint_msip = (uint8_t *)&VERILOG_CPU(bus__DOT__clint__DOT__msip_reg);

  npc->pmpcfg = (uint8_t *)&VERILOG_CPU(csrs__DOT__pmpcfg_r);
  npc->pmpaddr = (word_t *)&VERILOG_CPU(csrs__DOT__pmpaddr_r);

  /* Pipeline quiesce probes (for checkpoint save: defer until SQ/STQ/ROB are
   * empty so in-flight stores don't get truncated by host-side memory dump).
   * Use valid-bitvectors / dedicated empty signal — head==tail is ambiguous. */
  npc->rob_empty = (uint8_t *)&VERILOG_ROU(rob_empty);
  npc->sq_valid = (uint8_t *)&VERILOG_CPU(lsu__DOT__sq_valid);
  npc->stq_valid = (uint8_t *)&VERILOG_CPU(lsu__DOT__stq_valid);
}

#endif // __NPC_VERILOG_H__