/***************************************************************************************
 * Physical Memory Protection (PMP) for NEMU RISC-V target.
 *
 * Mirrors the RTL implementation in hdl/memory/rapt_pmp.sv so that the
 * NEMU reference model and the Raptor DUT produce identical access-fault
 * behaviour for difftest and RISCOF.
 *
 * Configuration:
 *   - 16 entries, granularity G=0 (4-byte grain), NA4 supported.
 *   - Backing store lives in cpu.sr[0x3a0..0x3a3] (packed pmpcfg bytes) and
 *     cpu.sr[0x3b0..0x3bf] (raw pmpaddr values).
 *   - L-bit lockdown and WARL masking of reserved cfg bits are applied via
 *     csr_write_pmp() at CSR-write time.
 *
 * Check semantics (RISC-V Privileged spec 3.7):
 *   - Data operations select the lowest-numbered entry matching any byte;
 *     that entry must cover the entire operation, including in M-mode.
 *   - Instruction fetches are decomposed into halfword parcels by vaddr.c.
 *   - No matching entry with priv<M => access-fault; priv==M => allow.
 *   - Matching entry with L=0 and priv==M => allow (M-mode bypass unlocked).
 *   - Otherwise require that the requested permission bit is set in cfg.
 ***************************************************************************************/

#include <isa.h>
#include <isa-def.h>
#include <memory/tlb.h>
#include "../local-include/reg.h"

#define PMP_N 16

/* pmpcfg byte field positions (match hdl/include/rapt.svh). */
#define PMPCFG_R_BIT 0
#define PMPCFG_W_BIT 1
#define PMPCFG_X_BIT 2
#define PMPCFG_A_LSB 3
#define PMPCFG_L_BIT 7

#define PMP_A_OFF 0
#define PMP_A_TOR 1
#define PMP_A_NA4 2
#define PMP_A_NAPOT 3

/* ------------------------------------------------------------------ */
/* Accessors for the packed cfg / raw addr storage.                   */

static inline uint8_t pmp_cfg(int i)
{
#ifdef CONFIG_RV64
  /* RV64: pmpcfg0 holds pmp0-7, pmpcfg2 holds pmp8-15 (odd regs illegal). */
  word_t w = cpu.sr[CSR_PMPCFG0 + ((i >> 3) * 2)];
  return (uint8_t)(w >> ((i & 7) * 8));
#else
  /* RV32: pmpcfgN holds entries N*4 .. N*4+3 as bytes 0..3. */
  word_t w = cpu.sr[CSR_PMPCFG0 + (i >> 2)];
  return (uint8_t)(w >> ((i & 3) * 8));
#endif
}

static inline void pmp_cfg_set(int i, uint8_t byte)
{
#ifdef CONFIG_RV64
  int off = (i & 7) * 8;
  word_t m = ((word_t)0xff) << off;
  word_t *p = &cpu.sr[CSR_PMPCFG0 + ((i >> 3) * 2)];
#else
  int off = (i & 3) * 8;
  word_t m = ((word_t)0xff) << off;
  word_t *p = &cpu.sr[CSR_PMPCFG0 + (i >> 2)];
#endif
  *p = (*p & ~m) | (((word_t)byte << off) & m);
}

static inline word_t pmp_addr(int i)
{
  return cpu.sr[CSR_PMPADDR0 + i];
}

static inline void pmp_addr_set(int i, word_t v)
{
  cpu.sr[CSR_PMPADDR0 + i] = v;
}

/* ------------------------------------------------------------------ */
/* CSR write hook: returns non-zero on success, 0 if the target was   */
/* not a PMP CSR (caller should perform the normal write).            */

static bool pmp_any_active = false;

/* Decoded PMP entries: rebuilt only when a PMP CSR changes. Avoids the
 * per-lookup shift/mask and NAPOT trailing-ones loops. */
struct pmp_decoded
{
  uint8_t cfg;
  uint8_t a;      /* PMP_A_OFF / TOR / NA4 / NAPOT */
  word_t lo_w;    /* TOR: lower bound (inclusive), in 4-byte words */
  word_t hi_w;    /* TOR: upper bound (exclusive), in 4-byte words */
  word_t base_w;  /* NA4/NAPOT: base, in 4-byte words */
  word_t mask_w;  /* NAPOT: size mask, in 4-byte words; 0 otherwise */
};

static struct pmp_decoded pmp_dec[PMP_N];

/* Per-word match cache: the lowest-numbered matching entry is a pure
 * function of (pmpcfg, pmpaddr, word address), so a generation counter
 * invalidates the whole cache on any PMP update. Direct-mapped. */
#define PMP_WCACHE_BITS 13
#define PMP_WCACHE_SIZE (1u << PMP_WCACHE_BITS)
struct pmp_wcache_entry
{
  paddr_t word;
  int entry; /* -1: no matching entry */
  uint8_t cfg;
  uint32_t gen;
};
static struct pmp_wcache_entry pmp_wcache[PMP_WCACHE_SIZE];
static uint32_t pmp_gen = 1;

static inline word_t pmp_napot_mask(word_t pa)
{
  /* Trailing ones in pmpaddr define the region size (in 4-byte words). */
  word_t mask = 1;
  for (int j = 1; j < (int)sizeof(word_t) * 8; j++)
  {
    if (pa & ((word_t)1 << (j - 1)))
      mask |= ((word_t)1 << j);
    else
      break;
  }
  return mask;
}

static void pmp_rebuild_decoded(void)
{
  pmp_any_active = false;
  for (int i = 0; i < PMP_N; i++)
  {
    uint8_t cfg = pmp_cfg(i);
    int a = (cfg >> PMPCFG_A_LSB) & 0x3;
    struct pmp_decoded *d = &pmp_dec[i];
    d->cfg = cfg;
    d->a = (uint8_t)a;
    word_t pa = pmp_addr(i);
    if (a != PMP_A_OFF)
      pmp_any_active = true;
    if (a == PMP_A_TOR)
    {
      d->lo_w = (i == 0) ? 0 : pmp_addr(i - 1);
      d->hi_w = pa;
      d->base_w = 0;
      d->mask_w = 0;
    }
    else if (a == PMP_A_NA4)
    {
      d->base_w = pa;
      d->mask_w = 0;
    }
    else if (a == PMP_A_NAPOT)
    {
      d->mask_w = pmp_napot_mask(pa);
      d->base_w = pa & ~d->mask_w;
    }
    else
    {
      d->base_w = 0;
      d->mask_w = 0;
    }
  }
  if (unlikely(++pmp_gen == 0))
  {
    memset(pmp_wcache, 0, sizeof(pmp_wcache));
    pmp_gen = 1;
  }
}

void pmp_restore_checkpoint(const uint8_t *cfg, const word_t *addr)
{
  for (int i = 0; i < PMP_N; i++)
  {
    pmp_cfg_set(i, cfg[i]);
    pmp_addr_set(i, addr[i]);
  }
  pmp_rebuild_decoded();
  soft_tlb_flush();
}

int pmp_csr_write(uint16_t csr, word_t val)
{
  csr &= 0xfff;
  if (csr >= CSR_PMPCFG0 && csr <= CSR_PMPCFG3)
  {
#ifdef CONFIG_RV64
    /* Instruction legality is checked upstream; ignore reserved odd banks here. */
    if (csr & 1) return 1;
    /* Even pmpcfg holds 8 entries packed in 64 bits. */
    int base = ((csr - CSR_PMPCFG0) / 2) * 8;
    for (int pi = 0; pi < 8; pi++)
#else
    int base = (csr - CSR_PMPCFG0) * 4;
    for (int pi = 0; pi < 4; pi++)
#endif
    {
      uint8_t old = pmp_cfg(base + pi);
      if (old & (1u << PMPCFG_L_BIT))
        continue;                                        /* locked */
      uint8_t nb = (uint8_t)((val >> (pi * 8)) & 0x9Fu); /* mask [6:5] WARL 0 */
      if ((nb & 3u) == 2u) nb &= (uint8_t)~7u; /* reserved RW: clear RWX */
      pmp_cfg_set(base + pi, nb);
    }
    pmp_rebuild_decoded();
    soft_tlb_flush();
    return 1;
  }
  if (csr >= CSR_PMPADDR0 && csr <= CSR_PMPADDR0 + PMP_N - 1)
  {
    int i = csr - CSR_PMPADDR0;
    uint8_t self_cfg = pmp_cfg(i);
    if (self_cfg & (1u << PMPCFG_L_BIT))
      return 1; /* self locked */
    if (i < PMP_N - 1)
    {
      uint8_t next_cfg = pmp_cfg(i + 1);
      int next_a = (next_cfg >> PMPCFG_A_LSB) & 0x3;
      if ((next_cfg & (1u << PMPCFG_L_BIT)) && next_a == PMP_A_TOR)
      {
        return 1; /* next is locked TOR, this addr forms its lower bound */
      }
    }
    pmp_addr_set(i, val);
    pmp_rebuild_decoded();
    soft_tlb_flush();
    return 1;
  }
  return 0;
}

/* ------------------------------------------------------------------ */
/* Per-byte match + fault evaluation.                                 */

struct pmp_match
{
  bool any_match;
  int entry;
  uint8_t cfg;
};

static void pmp_byte_lookup(paddr_t addr_bytes, struct pmp_match *m)
{
  const paddr_t addr_w = addr_bytes >> 2;
  struct pmp_wcache_entry *c =
      &pmp_wcache[(addr_w ^ (addr_w >> 13)) & (PMP_WCACHE_SIZE - 1)];
  if (likely(c->gen == pmp_gen && c->word == addr_w))
  {
    m->any_match = c->entry >= 0;
    m->entry = c->entry;
    m->cfg = c->cfg;
    return;
  }

  int found = -1;
  uint8_t found_cfg = 0;
  for (int i = 0; i < PMP_N; i++)
  {
    const struct pmp_decoded *d = &pmp_dec[i];
    if (d->a == PMP_A_OFF)
      continue;
    bool match;
    if (d->a == PMP_A_TOR)
      match = (addr_w >= d->lo_w) && (addr_w < d->hi_w);
    else
      match = ((addr_w & ~d->mask_w) == d->base_w);
    if (match)
    {
      found = i;
      found_cfg = d->cfg;
      break;
    }
  }
  c->word = addr_w;
  c->entry = found;
  c->cfg = found_cfg;
  c->gen = pmp_gen;
  m->any_match = found >= 0;
  m->entry = found;
  m->cfg = found_cfg;
}

/* Last PMP fault address — reports which byte of a possibly-straddling access
 * triggered the fault. For hi-byte failures, reports the naturally-aligned
 * second segment (matching sail's mtval convention for straddle faults). */
word_t pmp_last_fault_addr = 0;

/* Main PMP check.
 * addr     : physical byte address of the first byte of the access.
 * size     : access size in bytes (1, 2, 4, 8).
 * priv     : effective privilege level (PRV_U/S/M).
 * op_r/w/x : requested permission (exactly one should be true).
 * Returns true if the access must fault. */
bool pmp_check(paddr_t addr, int size, uint32_t priv,
               bool op_r, bool op_w, bool op_x)
{
  /* See RV32 sibling for rationale. */
  if (likely(!pmp_any_active))
  {
    if (priv == PRV_M)
      return false;
    pmp_last_fault_addr = addr;
    return true;
  }
  if (size <= 0)
    size = 1;
  paddr_t addr_hi = addr + (paddr_t)(size - 1);
  const bool same_word = (addr_hi >> 2) == (addr >> 2);

  /* Fast path: the entire access lies inside one 4-byte grain. PMP region
   * boundaries are grain-aligned, so the lowest-numbered entry matching that
   * grain also covers every byte of the access. This resolves the dominant
   * fetch / word load / word store cases with a single wcache probe. */
  if (likely(same_word))
  {
    struct pmp_match one;
    pmp_byte_lookup(addr, &one);
    if (!one.any_match)
    {
      if (priv == PRV_M)
        return false;
      pmp_last_fault_addr = addr;
      return true;
    }
    const uint8_t cfg = one.cfg;
    if (priv == PRV_M && !((cfg >> PMPCFG_L_BIT) & 1))
      return false; /* M-mode bypasses unlocked entries */
    bool ok = (!op_r || ((cfg >> PMPCFG_R_BIT) & 1))
           && (!op_w || ((cfg >> PMPCFG_W_BIT) & 1))
           && (!op_x || ((cfg >> PMPCFG_X_BIT) & 1));
    if (ok)
      return false;
    pmp_last_fault_addr = addr;
    return true;
  }

  struct pmp_match lo, hi;
  pmp_byte_lookup(addr, &lo);
  pmp_byte_lookup(addr_hi, &hi);

  bool is_m = (priv == PRV_M);

  /* Covering rule (privileged spec 3.7): the lowest-numbered entry matching
   * ANY byte of the access must cover EVERY byte, else the access faults.
   * pmp_byte_lookup returns the lowest-numbered entry for a grain, so that
   * condition holds iff every touched grain resolves to the same entry.
   * This replaces an explicit per-endpoint region re-match with integer
   * compares, which matters because 8-byte RV64 accesses dominate here. */
  if (!op_x)
  {
    const int e0 = lo.entry;
    bool covered = (hi.entry == e0);
    for (int offset = 4 - (int)(addr & 3); covered && offset < size; offset += 4)
    {
      paddr_t g = addr + (paddr_t)offset;
      if ((g >> 2) == (addr_hi >> 2))
        continue; /* hi grain already known */
      struct pmp_match part;
      pmp_byte_lookup(g, &part);
      if (part.entry != e0)
        covered = false;
    }
    /* covered with e0 < 0 means no grain matched at all; leave the pass
     * loop below to apply the M-mode-vs-S/U no-match rule. */
    if ((lo.any_match || hi.any_match) && !covered)
    {
      pmp_last_fault_addr = addr;
      return true;
    }
  }

  for (int pass = 0; pass < 2; pass++)
  {
    struct pmp_match *m = (pass == 0) ? &lo : &hi;
    paddr_t fail_addr = (pass == 0) ? addr : (addr_hi & ~(paddr_t)(size - 1));
    if (!m->any_match)
    {
      if (!is_m)
      {
        pmp_last_fault_addr = fail_addr;
        return true;
      }
      continue;
    }
    bool l = (m->cfg >> PMPCFG_L_BIT) & 1;
    if (is_m && !l)
      continue; /* M-mode bypasses unlocked entries */
    bool perm_r = (m->cfg >> PMPCFG_R_BIT) & 1;
    bool perm_w = (m->cfg >> PMPCFG_W_BIT) & 1;
    bool perm_x = (m->cfg >> PMPCFG_X_BIT) & 1;
    bool ok = (!op_r || perm_r) && (!op_w || perm_w) && (!op_x || perm_x);
    if (!ok)
    {
      pmp_last_fault_addr = fail_addr;
      return true;
    }
  }
  return false;
}

