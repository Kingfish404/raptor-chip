#pragma once
#ifndef __NPC_VERILOG_H__
#define __NPC_VERILOG_H__

#include <common.h>
#include <cpu.h>

#include CONCAT_HEAD(TOP_NAME)
#include CONCAT_HEAD(CONCAT(TOP_NAME, ___024root))
#include CONCAT_HEAD(CONCAT(TOP_NAME, __Dpi))

// The core composes frontend, backend and caches. Keep observation paths
// explicit so difftest and PMU follow the same architectural state after
// hierarchy changes; these accessors do not participate in RTL behavior.
#ifdef RAPT_SOC
// Verilator 5.x hierarchical cell access:
//   rootp -> ysyxSoCFull -> asic -> cpu -> cpu -> adapter -> cpu (rapt) -> core
// MemoryReadCredits=1 gives the generated rapt/core classes their __M1 suffix.
#include CONCAT_HEAD(CONCAT(TOP_NAME, _ysyxSoCFull))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _ysyxSoCASIC__pi1))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _CPU))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _ysyx_00000000))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _wrap_ysyxsoc))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _rapt__M1))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _rapt_core__M1))
// The symbol header includes the actual parameter-specialized backend and ROU classes.
#include CONCAT_HEAD(CONCAT(TOP_NAME, __Syms))
#define VERILOG_CPU(m) (top->rootp->ysyxSoCFull->asic->cpu->cpu->adapter->cpu->core->m)
#define VERILOG_BACKEND(m) (top->rootp->ysyxSoCFull->asic->cpu->cpu->adapter->cpu->core->backend->m)
#define VERILOG_FRONTEND(m) VERILOG_CPU(CONCAT(frontend__DOT__, m))
#define VERILOG_ROU(m) (top->rootp->ysyxSoCFull->asic->cpu->cpu->adapter->cpu->core->backend->rou->m)
// CLINT lives at the cluster level (rapt). Verilator inlines the small
// rapt_clint module, so its registers are reached via the __DOT__ name
// from the parent `rapt` cell rather than a dedicated cell pointer.
#define VERILOG_CLINT(m) CONCAT(top->rootp->ysyxSoCFull->asic->cpu->cpu->adapter->cpu->clint_inst__DOT__, m)
#define VERILOG_PLIC(m) CONCAT(top->rootp->ysyxSoCFull->asic->cpu->cpu->adapter->cpu->plic__DOT__, m)
#define VERILOG_CLUSTER(m) (top->rootp->ysyxSoCFull->asic->cpu->cpu->adapter->cpu->m)
#define VERILOG_RESET (top->reset || top->rootp->ysyxSoCFull->asic->cpu_reset_chain__DOT__output_chain__DOT__sync_0)
#else

#ifdef CONFIG_wrapBus
#define VERILOG_CPU(m) CONCAT(top->rootp->wrapSoC__DOT__chip__DOT__cpu__DOT__core__DOT__, m)
#define VERILOG_BACKEND(m) CONCAT(top->rootp->wrapSoC__DOT__chip__DOT__cpu__DOT__core__DOT__backend__DOT__, m)
#define VERILOG_FRONTEND(m) VERILOG_CPU(CONCAT(frontend__DOT__, m))
#define VERILOG_ROU(m) CONCAT(top->rootp->wrapSoC__DOT__chip__DOT__cpu__DOT__core__DOT__backend__DOT__rou__DOT__, m)
#define VERILOG_CLINT(m) CONCAT(top->rootp->wrapSoC__DOT__chip__DOT__cpu__DOT__clint_inst__DOT__, m)
#define VERILOG_PLIC(m) CONCAT(top->rootp->wrapSoC__DOT__chip__DOT__cpu__DOT__plic__DOT__, m)
#define VERILOG_CLUSTER(m) CONCAT(top->rootp->wrapSoC__DOT__chip__DOT__cpu__DOT__, m)
#define VERILOG_RESET top->reset
#else
// NPC mode: Verilator 5.x hierarchical classes -- navigate via cell pointers.
// raptSoC -> cpu (rapt) -> core (rapt_core) -> sub-cells.
// CLINT lives at the cluster level (rapt.clint_inst), shared across harts.
// rapt_clint is inlined by Verilator, so its registers are reached via the
// __DOT__ name from the parent `rapt` cell (`cpu`).
#include CONCAT_HEAD(CONCAT(TOP_NAME, _raptSoC))
#if __has_include(CONCAT_HEAD(CONCAT(TOP_NAME, _rapt)))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _rapt))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _rapt_core))
#elif __has_include(CONCAT_HEAD(CONCAT(TOP_NAME, _rapt__Lz1)))
// A write-back top parameter (including default-l2's default) specializes these classes.
#include CONCAT_HEAD(CONCAT(TOP_NAME, _rapt__Lz1))
#include CONCAT_HEAD(CONCAT(TOP_NAME, _rapt_core__Lz1))
#else
#error Unsupported Verilator rapt hierarchy
#endif
// The symbol header includes the actual parameter-specialized backend and ROU classes.
#include CONCAT_HEAD(CONCAT(TOP_NAME, __Syms))
#define VERILOG_CPU(m) (top->rootp->raptSoC->cpu->core->m)
#define VERILOG_BACKEND(m) (top->rootp->raptSoC->cpu->core->backend->m)
#define VERILOG_FRONTEND(m) VERILOG_CPU(CONCAT(frontend__DOT__, m))
#define VERILOG_ROU(m) (top->rootp->raptSoC->cpu->core->backend->rou->m)
#define VERILOG_CLINT(m) CONCAT(top->rootp->raptSoC->cpu->clint_inst__DOT__, m)
#define VERILOG_PLIC(m) CONCAT(top->rootp->raptSoC->cpu->plic__DOT__, m)
#define VERILOG_CLUSTER(m) (top->rootp->raptSoC->cpu->m)
#define VERILOG_RESET top->reset
#endif

#endif

#define VERILOG_AXI_MASTER(m) VERILOG_CPU(CONCAT(memory_subsystem__DOT__axi_master__DOT__, m))

static inline void verilog_connect(TOP_NAME *top, NPCState *npc)
{
  // for difftest
  npc->inst = (uint32_t *)&VERILOG_BACKEND(cmu__DOT__inst);

  npc->gpr = (word_t *)&VERILOG_BACKEND(rf);
  npc->rpc = (word_t *)&VERILOG_BACKEND(cmu__DOT__rpc);
  npc->ret = npc->gpr + reg_str2idx("a0");
  npc->pc = (word_t *)&VERILOG_BACKEND(cmu__DOT__npc);
  npc->priv = (char *)&VERILOG_BACKEND(csrs__DOT__priv_mode);
  word_t *csr = (word_t *)&VERILOG_BACKEND(csrs__DOT__csr);

  npc->state = NPC_RUNNING;

  npc->sstatus = csr + SSTATUS;
  npc->sie____ = csr + SIE____;
  npc->stvec__ = csr + STVEC__;

  npc->scounte = csr + SCOUNTE;
  npc->mcounte = csr + MCOUNTE;

  npc->sscratch = csr + SSCRATCH;
  npc->sepc___ = (word_t *)&VERILOG_BACKEND(csrs__DOT__sepc_value);
  npc->sepc_half_q = (word_t *)&VERILOG_BACKEND(csrs__DOT__sepc_half_q);
  npc->scause_ = csr + SCAUSE_;
  npc->stval__ = csr + STVAL__;
  npc->sip____ = csr + SIP____;
  npc->satp___ = csr + SATP___;

  npc->mstatus = csr + MSTATUS;
  // sie/sip and mip have architectural combinational views in RTL; difftest
  // reads them from dedicated shadows kept in sync within the same eval
  // (csr[SIE____]/csr[SIP____] storage slots are not maintained per-cycle).
  npc->sie____ = (word_t *)&VERILOG_BACKEND(csrs__DOT__csr_sie_shadow);
  npc->sip____ = (word_t *)&VERILOG_BACKEND(csrs__DOT__csr_sip_shadow);
  npc->misa___ = csr + MISA___;
  npc->medeleg = csr + MEDELEG;
  npc->mideleg = csr + MIDELEG;
  npc->mie____ = csr + MIE____;
  npc->mtvec__ = csr + MTVEC__;
  npc->menvcfg = csr + MENVCFG;
  npc->menvcfgh = csr + MENVCFGH;
  npc->stimecmp = (uint64_t *)&VERILOG_BACKEND(csrs__DOT__stimecmp);
  npc->bus_error_pending = (uint8_t *)&VERILOG_BACKEND(csrs__DOT__bus_error_pending);
  npc->bus_error_overflow = (uint8_t *)&VERILOG_BACKEND(csrs__DOT__bus_error_overflow);
  npc->bus_error_strb = (uint8_t *)&VERILOG_BACKEND(csrs__DOT__bus_error_strb);
  npc->bus_error_addr = (word_t *)&VERILOG_BACKEND(csrs__DOT__bus_error_addr);

  npc->mstatush = csr + MSTATUSH;
  npc->mscratch = csr + MSCRATCH;
  // EPC storage is halfword-packed in RTL; observe the architectural value.
  // Keep the state pointer for checkpoint restore, which must write storage.
  npc->mepc___ = (word_t *)&VERILOG_BACKEND(csrs__DOT__mepc_value);
  npc->mepc_half_q = (word_t *)&VERILOG_BACKEND(csrs__DOT__mepc_half_q);
  npc->mcause_ = csr + MCAUSE_;
  npc->mtval__ = csr + MTVAL__;
  npc->mip____ = (word_t *)&VERILOG_BACKEND(csrs__DOT__csr_mip_shadow);

  npc->mcycle_ = csr + MCYCLE_;
  npc->mcycleh = csr + MCYCLEH;
  npc->minstret = csr + MINSTRET;
  npc->minstreth = csr + MINSTRETH;

  npc->fpr = (uint64_t *)&VERILOG_ROU(fp_registers__DOT__architectural);
  npc->fcsr = (uint32_t *)(csr + FCSR);

  npc->clint_mtime = (uint64_t *)&VERILOG_CLINT(mtime);
  npc->clint_mtimecmp = (uint64_t *)&VERILOG_CLINT(mtimecmp);
  npc->clint_msip = (uint8_t *)&VERILOG_CLINT(msip_reg);

  npc->plic_priority = (uint8_t *)&VERILOG_PLIC(priority_q)[0];
  npc->plic_pending = (uint32_t *)&VERILOG_PLIC(pending_q);
  npc->plic_gateway_busy = (uint32_t *)&VERILOG_PLIC(gateway_busy_q);
  npc->plic_enable = (uint32_t *)&VERILOG_PLIC(enable_q)[0];
  npc->plic_threshold = (uint8_t *)&VERILOG_PLIC(threshold_q)[0];
  npc->plic_ext_irq = (uint32_t *)&VERILOG_PLIC(ext_irq_q);

  npc->pmpcfg = (uint8_t *)&VERILOG_BACKEND(csrs__DOT__pmpcfg_r);
  npc->pmpaddr = (word_t *)&VERILOG_BACKEND(csrs__DOT__pmpaddr_r);

  /* Pipeline quiesce probes (for checkpoint save: defer until SQ/ROB are
   * empty so in-flight stores don't get truncated by host-side memory dump).
   * Phase A unified SQ: 1-bit sq_all_empty/sq_all_full probes are width-
   * stable -- host code never depends on SQ_SIZE's bit width. */
  npc->rob_empty = (uint8_t *)&VERILOG_ROU(rob_empty);
  npc->sq_empty = (uint8_t *)&VERILOG_BACKEND(lsu__DOT__u_sq__DOT__sq_all_empty);
  npc->sq_full = (uint8_t *)&VERILOG_BACKEND(lsu__DOT__u_sq__DOT__sq_all_full);
  npc->sq_snapshot_capacity = (uint8_t *)&VERILOG_BACKEND(lsu__DOT__u_sq__DOT__sq_snapshot_capacity);
  npc->sq_snapshot_head = (uint8_t *)&VERILOG_BACKEND(lsu__DOT__u_sq__DOT__sq_snapshot_head);
  npc->sq_snapshot_valid = (uint32_t *)&VERILOG_BACKEND(lsu__DOT__u_sq__DOT__sq_snapshot_valid);
  npc->sq_snapshot_committed = (uint32_t *)&VERILOG_BACKEND(lsu__DOT__u_sq__DOT__sq_snapshot_committed);
  npc->sq_snapshot_alu = (uint8_t *)&VERILOG_BACKEND(lsu__DOT__u_sq__DOT__sq_alu)[0];
  npc->sq_snapshot_paddr = (word_t *)&VERILOG_BACKEND(lsu__DOT__u_sq__DOT__sq_paddr)[0];
  npc->sq_snapshot_wdata = (word_t *)&VERILOG_BACKEND(lsu__DOT__u_sq__DOT__sq_wdata)[0];
}

#endif // __NPC_VERILOG_H__
