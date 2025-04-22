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

#include "mmu.h"
#include "sim.h"
#include "../../include/common.h"
#include <difftest-def.h>

#define NR_GPR MUXDEF(CONFIG_RVE, 16, 32)

static std::vector<std::pair<reg_t, abstract_device_t*>> difftest_plugin_devices;
static std::vector<std::string> difftest_htif_args;
static std::vector<std::pair<reg_t, mem_t*>> difftest_mem(
    1, std::make_pair(reg_t(DRAM_BASE), new mem_t(CONFIG_MSIZE)));
static debug_module_config_t difftest_dm_config = {
  .progbufsize = 2,
  .max_sba_data_width = 0,
  .require_authentication = false,
  .abstract_rti = 0,
  .support_hasel = true,
  .support_abstract_csr_access = true,
  .support_abstract_fpr_access = true,
  .support_haltgroups = true,
  .support_impebreak = true
};

struct diff_context_t {
  word_t sr[4096];
  word_t gpr[MUXDEF(CONFIG_RVE, 16, 32)];
  word_t pc;
  word_t cpc;
  uint32_t inst;
  uint32_t priv;
  bool intr;
  uint32_t last_inst_priv;
  uint64_t mtimecmp;
  vaddr_t reservation;
};

static sim_t* s = NULL;
static processor_t *p = NULL;
static state_t *state = NULL;

void sim_t::diff_init(int port) {
  p = get_core("0");
  state = p->get_state();
}

void sim_t::diff_step(uint64_t n) {
  step(n);
}

void sim_t::diff_get_regs(void* diff_context) {
  struct diff_context_t* ctx = (struct diff_context_t*)diff_context;
  ctx->pc = state->pc;
  for (int i = 0; i < NR_GPR; i++) {
    ctx->gpr[i] = state->XPR[i];
  }
  ctx->sr[CSR_SSTATUS] = state->sstatus->read();
  ctx->sr[CSR_SIE] = state->csrmap[CSR_SIE]->read();
  ctx->sr[CSR_STVEC] = state->stvec->read();

  ctx->sr[CSR_SSCRATCH] = state->csrmap[CSR_SSCRATCH]->read();
  ctx->sr[CSR_SEPC] = state->sepc->read();
  ctx->sr[CSR_SCAUSE] = state->scause->read();
  ctx->sr[CSR_STVAL] = state->stval->read();
  ctx->sr[CSR_SIP] = state->csrmap[CSR_SIP]->read();
  ctx->sr[CSR_SATP] = state->satp->read();

  ctx->sr[CSR_MSTATUSH] = state->mstatush->read();
  ctx->sr[CSR_MSTATUS] = state->mstatus->read();
  ctx->sr[CSR_MEDELEG] = state->medeleg->read();
  ctx->sr[CSR_MIDELEG] = state->mideleg->read();
  ctx->sr[CSR_MIE] = state->mie->read();
  ctx->sr[CSR_MTVEC] = state->mtvec->read();

  ctx->sr[CSR_MSCRATCH] = state->csrmap[CSR_MSCRATCH]->read();
  ctx->sr[CSR_MEPC] = state->mepc->read();
  ctx->sr[CSR_MCAUSE] = state->mcause->read();
  ctx->sr[CSR_MTVAL] = state->mtval->read();
  ctx->sr[CSR_MIP] = state->csrmap[CSR_MIP]->read();

  ctx->priv = state->prv;
}

void sim_t::diff_set_regs(void* diff_context) {
  struct diff_context_t* ctx = (struct diff_context_t*)diff_context;
  state->pc = ctx->pc;
  for (int i = 0; i < NR_GPR; i++) {
    state->XPR.write(i, (sword_t)ctx->gpr[i]);
  }
  state->sstatus->write(ctx->sr[CSR_SSTATUS]);
  state->csrmap[CSR_SIE]->write(ctx->sr[CSR_SIE]);
  state->stvec->write(ctx->sr[CSR_STVEC]);

  state->csrmap[CSR_SSCRATCH]->write(ctx->sr[CSR_SSCRATCH]);
  state->sepc->write(ctx->sr[CSR_SEPC]);
  state->scause->write(ctx->sr[CSR_SCAUSE]);
  state->stval->write(ctx->sr[CSR_STVAL]);
  state->csrmap[CSR_SIP]->write(ctx->sr[CSR_SIP]);
  state->satp->write(ctx->sr[CSR_SATP]);

  state->mstatush->write(ctx->sr[CSR_MSTATUSH]);
  state->mstatus->write(ctx->sr[CSR_MSTATUS]);
  state->medeleg->write(ctx->sr[CSR_MEDELEG]);
  state->mideleg->write(ctx->sr[CSR_MIDELEG]);
  state->mie->write(ctx->sr[CSR_MIE]);
  state->mtvec->write(ctx->sr[CSR_MTVEC]);

  state->csrmap[CSR_MSCRATCH]->write(ctx->sr[CSR_MSCRATCH]);
  state->mepc->write(ctx->sr[CSR_MEPC]);
  state->mcause->write(ctx->sr[CSR_MCAUSE]);
  state->mtval->write(ctx->sr[CSR_MTVAL]);
  state->csrmap[CSR_MIP]->write(ctx->sr[CSR_MIP]);

  state->misa->write(ctx->sr[CSR_MISA]);
  
  state->prv = ctx->priv;
}

void sim_t::diff_memcpy(reg_t dest, void* src, size_t n) {
  mmu_t* mmu = p->get_mmu();
  for (size_t i = 0; i < n; i++) {
    mmu->store<uint8_t>(dest+i, *((uint8_t*)src+i));
  }
}

extern "C" {

__EXPORT void difftest_memcpy(paddr_t addr, void *buf, size_t n, bool direction) {
  if (direction == DIFFTEST_TO_REF) {
    s->diff_memcpy(addr, buf, n);
  } else {
    assert(0);
  }
}

__EXPORT void difftest_regcpy(void* dut, bool direction) {
  if (direction == DIFFTEST_TO_REF) {
    s->diff_set_regs(dut);
  } else {
    s->diff_get_regs(dut);
  }
}

__EXPORT void difftest_exec(uint64_t n) {
  s->diff_step(n);
}

__EXPORT void difftest_init(int port) {
  difftest_htif_args.push_back("");
  const char *isa = "RV" MUXDEF(CONFIG_RV64, "64", "32") MUXDEF(CONFIG_RVE, "E", "I") "MAFDC";
  cfg_t *cfg = new cfg_t(/*default_initrd_bounds=*/std::make_pair((reg_t)0, (reg_t)0),
            /*default_bootargs=*/nullptr,
            /*default_isa=*/isa,
            /*default_priv=*/DEFAULT_PRIV,
            /*default_varch=*/DEFAULT_VARCH,
            /*default_misaligned=*/false,
            /*default_endianness*/endianness_little,
            /*default_pmpregions=*/16,
            /*default_mem_layout=*/std::vector<mem_cfg_t>(),
            /*default_hartids=*/std::vector<size_t>(1),
            /*default_real_time_clint=*/false,
            /*default_trigger_count=*/4);
  s = new sim_t(cfg, false,
      difftest_mem, difftest_plugin_devices, difftest_htif_args,
      difftest_dm_config, nullptr, false, NULL,
      false,
      NULL,
      true);
  s->diff_init(port);
}

__EXPORT void difftest_raise_intr(uint64_t NO) {
  trap_t t(NO);
  p->take_trap_public(t, state->pc);
}

}
