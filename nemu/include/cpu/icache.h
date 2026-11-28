/*
 * Decoded-instruction cache: PC -> (post-decompression inst word, ilen).
 *
 * Direct-mapped, ISA-agnostic, lives outside isa/ so that both riscv32 and
 * riscv64 share a single implementation. The goal is to skip the per-
 * instruction inst_fetch (vaddr translation, PMP check, paddr_read) AND
 * the C-extension decompress on PCs we've already executed.
 *
 * Cache coherence: maintained by `icache_flush()`, which is piggy-backed
 * onto `soft_tlb_flush()` so every event that invalidates address
 * translations (trap entry, satp write, sfence.vma, paddr remap) also
 * invalidates this cache. The only extra hook is on fence.i, which
 * mutates the instruction stream without touching the TLB.
 *
 * Flush is O(1) via an epoch counter (mirrors the soft-TLB design).
 */
#ifndef __CPU_ICACHE_H__
#define __CPU_ICACHE_H__

#include <common.h>

#define ICACHE_BITS 14
#define ICACHE_SIZE (1u << ICACHE_BITS)
#define ICACHE_MASK (ICACHE_SIZE - 1u)

typedef enum {
  IC_OP_FALLBACK = 0,
  IC_OP_LUI,
  IC_OP_AUIPC,
  IC_OP_JAL,
  IC_OP_JALR,
  IC_OP_BEQ,
  IC_OP_BNE,
  IC_OP_BLT,
  IC_OP_BGE,
  IC_OP_BLTU,
  IC_OP_BGEU,
  IC_OP_LB,
  IC_OP_LH,
  IC_OP_LW,
  IC_OP_LBU,
  IC_OP_LHU,
  IC_OP_LWU,
  IC_OP_LD,
  IC_OP_SB,
  IC_OP_SH,
  IC_OP_SW,
  IC_OP_SD,
  IC_OP_ADDI,
  IC_OP_SLTI,
  IC_OP_SLTIU,
  IC_OP_XORI,
  IC_OP_ORI,
  IC_OP_ANDI,
  IC_OP_SLLI,
  IC_OP_SRLI,
  IC_OP_SRAI,
  IC_OP_ADDIW,
  IC_OP_SLLIW,
  IC_OP_SRLIW,
  IC_OP_SRAIW,
  IC_OP_ADD,
  IC_OP_SUB,
  IC_OP_SLL,
  IC_OP_SLT,
  IC_OP_SLTU,
  IC_OP_XOR,
  IC_OP_SRL,
  IC_OP_SRA,
  IC_OP_OR,
  IC_OP_AND,
  IC_OP_ADDW,
  IC_OP_SUBW,
  IC_OP_SLLW,
  IC_OP_SRLW,
  IC_OP_SRAW,
  IC_OP_MUL,
  IC_OP_MULW,
  IC_OP_COUNT
} icache_op_t;

typedef struct {
  vaddr_t  pc;     /* tag                                            */
  uint32_t inst;   /* post-decompression instruction word            */
  int32_t  imm;    /* pre-decoded sign-extended immediate            */
  uint32_t epoch;  /* entry valid iff epoch == icache_epoch          */
  uint8_t  op;     /* pre-decoded icache_op_t (0 = fallback)         */
  uint8_t  rd;     /* pre-decoded rd  (0..31)                        */
  uint8_t  rs1;    /* pre-decoded rs1 (0..31)                        */
  uint8_t  rs2;    /* pre-decoded rs2 (0..31)                        */
  uint8_t  ilen;   /* original fetch length: 2 (C-ext) or 4          */
  uint8_t  _pad[3];
} icache_entry_t;

extern NEMU_TLS icache_entry_t icache[ICACHE_SIZE];
extern NEMU_TLS uint32_t       icache_epoch;

/* O(1) flush. Wrap-to-zero hard-resets all tags so a stale epoch-0
 * entry can never be mistaken as valid. */
void icache_flush(void);

static inline icache_entry_t *icache_slot(vaddr_t pc) {
  return &icache[(pc >> 1) & ICACHE_MASK];
}

static inline bool icache_hit(const icache_entry_t *e, vaddr_t pc) {
  return e->pc == pc && e->epoch == icache_epoch;
}

static inline void icache_fill(icache_entry_t *e, vaddr_t pc,
                               uint32_t inst, uint16_t ilen) {
  e->pc    = pc;
  e->inst  = inst;
  e->ilen  = (uint8_t)ilen;
  e->op    = IC_OP_FALLBACK;
  e->epoch = icache_epoch;
}

#endif
