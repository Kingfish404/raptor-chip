/***************************************************************************************
 * Physical Memory Protection (PMP) for NEMU RISC-V target.
 *
 * Mirrors the RTL implementation in rtl_sv/memory/rapt_pmp.sv so that the
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
 *   - Per-byte first-match priority encoding on both the first and last byte
 *     of the access (straddle support).
 *   - No matching entry with priv<M => access-fault; priv==M => allow.
 *   - Matching entry with L=0 and priv==M => allow (M-mode bypass unlocked).
 *   - Otherwise require that the requested permission bit is set in cfg.
 ***************************************************************************************/

#include <isa.h>
#include <isa-def.h>
#include "../local-include/reg.h"

#define PMP_N 16

/* pmpcfg byte field positions (match rtl_sv/include/rapt.svh). */
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
  /* pmpcfgN packs entries [N*4 .. N*4+3] as bytes [0..3]. */
  word_t w = cpu.sr[CSR_PMPCFG0 + (i >> 2)];
  return (uint8_t)(w >> ((i & 3) * 8));
}

static inline void pmp_cfg_set(int i, uint8_t byte)
{
  int off = (i & 3) * 8;
  word_t m = ((word_t)0xff) << off;
  word_t *p = &cpu.sr[CSR_PMPCFG0 + (i >> 2)];
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

static void pmp_rebuild_active(void)
{
  pmp_any_active = false;
  for (int i = 0; i < PMP_N; i++)
  {
    uint8_t cfg = pmp_cfg(i);
    int a = (cfg >> PMPCFG_A_LSB) & 0x3;
    if (a != PMP_A_OFF)
    {
      pmp_any_active = true;
      return;
    }
  }
}

int pmp_csr_write(uint16_t csr, word_t val)
{
  csr &= 0xfff;
  if (csr >= CSR_PMPCFG0 && csr <= CSR_PMPCFG3)
  {
    int base = (csr - CSR_PMPCFG0) * 4;
    for (int pi = 0; pi < 4; pi++)
    {
      uint8_t old = pmp_cfg(base + pi);
      if (old & (1u << PMPCFG_L_BIT))
        continue;                                        /* locked */
      uint8_t nb = (uint8_t)((val >> (pi * 8)) & 0x9Fu); /* mask [6:5] WARL 0 */
      pmp_cfg_set(base + pi, nb);
    }
    pmp_rebuild_active();
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

static void pmp_byte_lookup(word_t addr_bytes, struct pmp_match *m)
{
  word_t addr_w = addr_bytes >> 2;
  m->any_match = false;
  m->entry = -1;
  m->cfg = 0;
  for (int i = 0; i < PMP_N; i++)
  {
    uint8_t cfg = pmp_cfg(i);
    int a = (cfg >> PMPCFG_A_LSB) & 0x3;
    if (a == PMP_A_OFF)
      continue;
    word_t pa = pmp_addr(i);
    bool match = false;
    if (a == PMP_A_TOR)
    {
      word_t lo = (i == 0) ? 0 : pmp_addr(i - 1);
      match = (addr_w >= lo) && (addr_w < pa);
    }
    else if (a == PMP_A_NA4)
    {
      match = (addr_w == pa);
    }
    else
    { /* NAPOT */
      /* Compute mask: trailing ones in pa define region size (in words). */
      word_t mask = 1;
      for (int j = 1; j < (int)sizeof(word_t) * 8; j++)
      {
        if (pa & ((word_t)1 << (j - 1)))
          mask |= ((word_t)1 << j);
        else
          break;
      }
      word_t base = pa & ~mask;
      match = ((addr_w & ~mask) == base);
    }
    if (match)
    {
      m->any_match = true;
      m->entry = i;
      m->cfg = cfg;
      return;
    }
  }
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
  struct pmp_match lo, hi;
  pmp_byte_lookup((word_t)addr, &lo);
  pmp_byte_lookup((word_t)addr_hi, &hi);
  bool is_m = (priv == PRV_M);

  for (int pass = 0; pass < 2; pass++)
  {
    struct pmp_match *m = (pass == 0) ? &lo : &hi;
    paddr_t fail_addr = (pass == 0) ? addr : (((addr_hi) & ~(paddr_t)(size - 1)));
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

/* Effective privilege for loads/stores: MPRV + MPP override when in M-mode. */
uint32_t pmp_effective_priv_ls(void)
{
  word_t ms = cpu.sr[CSR_MSTATUS];
  if ((ms & CSR_MSTATUS_MPRV) && cpu.priv == PRV_M)
  {
    return (uint32_t)((ms & CSR_MSTATUS_MPP) >> 11);
  }
  return cpu.priv;
}
