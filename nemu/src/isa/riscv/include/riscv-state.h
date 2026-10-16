#ifndef NEMU_RISCV_STATE_H
#define NEMU_RISCV_STATE_H

#include <common.h>

typedef struct
{
  word_t sr[4096];
  word_t gpr[MUXDEF(CONFIG_RVE, 16, 32)];
  // FLEN is fixed at 64 for every future F/D-capable RV32/RV64 build.
  uint64_t fpr[32];
  uint8_t vreg[32][16];
  vaddr_t pc;
  vaddr_t cpc; // for difftest.ref
  uint32_t inst;
  uint32_t priv;
  bool virt;
  bool intr;
  word_t raise_intr;
  uint32_t last_inst_priv;
  uint16_t last_csr_wr;
  bool csr_dirty;           // mstatus/mie/mip changed outside a Zicsr write
  bool instruction_trapped; // Synchronous trap: this attempt did not retire.
  uint64_t mtimecmp;
  bool stip; // Hardware Sstc level; separate from software-writable mip.STIP.
  bool seip; // External S interrupt level, independent of software mip.SEIP.
  vaddr_t reservation;
  uint8_t reservation_bytes; // zero means no valid reservation

  vaddr_t vwaddr;
  word_t pwaddr;
  word_t wdata;
  word_t len;

  // for load diff
  vaddr_t rvaddr;
  word_t rpaddr;
  word_t rdata;
  word_t rlen;

  word_t iomm_addr; // for iomm
  word_t skip;      // for iomm
} riscv_CPU_state;

#endif
