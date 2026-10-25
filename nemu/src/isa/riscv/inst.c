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

#include <setjmp.h>
#include "local-include/reg.h"
#include "local-include/fp.h"
#include "local-include/fp-exec.h"
#include <isa-def.h>
#include <isa-extensions.h>
#include <vector-control.h>
#include <cpu/cpu.h>
#include <cpu/thread.h>
#include <cpu/ifetch.h>
#include <cpu/decode.h>
#include <cpu/difftest.h>
#include <cpu/icache.h>
#include <cpu/multidiff.h>
#include <device/mmio.h>
#include <memory/tlb.h>
#include <memory/trap.h>
#include <memory/paddr.h>
#include <memory/vaddr.h>
#include <stdlib.h>
#include <stdio.h>

#define R(i) gpr(i)
#define CSR(i) sr(i)
extern NEMU_TLS word_t g_vaddr;
bool pmp_check(paddr_t addr, int size, uint32_t priv,
               bool op_r, bool op_w, bool op_x);
static inline bool sstc_enabled(void)
{
#ifdef CONFIG_RV64
  return (CSR(CSR_MENVCFG) >> 63) != 0;
#else
  return (CSR(CSR_MENVCFGH) >> 31) != 0;
#endif
}
word_t riscv_hart_mip_value(const riscv_CPU_state *hart)
{
  word_t value = (hart->sr[CSR_MIP] & ~(word_t)riscv_virtual_irq_mask()) |
      (hart->seip ? (word_t)0x200 : 0);
  value |= hart->sr[CSR_HVIP] & (word_t)riscv_virtual_irq_mask();
#ifdef CONFIG_RAPTOR_MEMORY_MAP
  value = (value & ~((word_t)1 << 16)) | ((hart->sr[CSR_MBERR_STATUS] & 1) << 16);
#endif
#ifdef CONFIG_RV64
  bool stce = (hart->sr[CSR_MENVCFG] >> 63) != 0;
#else
  bool stce = (hart->sr[CSR_MENVCFGH] >> 31) != 0;
#endif
  if (stce)
  {
    // Standalone CLINT computes this level. A differential reference gets
    // the DUT timer input at each step, rather than using its unrelated clock.
    value = (value & ~(word_t)0x20) | (hart->stip ? 0x20 : 0);
  }
  if (riscv_virtual_timer_pending(hart)) value |= (word_t)0x40;
  return value;
}
word_t riscv_mip_value(void)
{
  return riscv_hart_mip_value(&cpu);
}
static inline uint16_t guest_csr_alias(uint16_t csr)
{
#ifdef CONFIG_RV64
  if (cpu.virt)
  {
    switch (csr)
    {
    case CSR_SSTATUS: return CSR_VSSTATUS;
    case CSR_SIE: return CSR_VSIE;
    case CSR_STVEC: return CSR_VSTVEC;
    case CSR_SSCRATCH: return CSR_VSSCRATCH;
    case CSR_SEPC: return CSR_VSEPC;
    case CSR_SCAUSE: return CSR_VSCAUSE;
    case CSR_STVAL: return CSR_VSTVAL;
    case CSR_SIP: return CSR_VSIP;
    case 0x14d: return CSR_VSTIMECMP;
    case CSR_SATP: return CSR_VSATP;
    default: break;
    }
  }
#endif
  return csr;
}

static inline bool guest_shared_supervisor_csr(uint16_t csr)
{
  return csr == CSR_SCOUNTEREN || csr == CSR_SENVCFG ||
      (csr >= CSR_SSTATEEN0 && csr <= CSR_SSTATEEN3);
}

word_t pmp_csr_read(uint16_t csr);

static inline word_t csr_read_value(uint16_t csr)
{
  csr = guest_csr_alias(csr & 0xfff);
  if (is_pmp_csr(csr)) return pmp_csr_read(csr);
#ifdef CONFIG_RV64
  if (csr == CSR_VSSTATUS && riscv_h_gstage_preview_enabled())
  {
    word_t value = (CSR(CSR_VSSTATUS) & ~((word_t)1 << 63)) | ((word_t)2 << 32);
    if (((value >> 13) & 3) == 3 || ((value >> 9) & 3) == 3)
      value |= (word_t)1 << 63;
    return value;
  }
  if (csr == CSR_HSTATUS && riscv_h_gstage_preview_enabled())
    return CSR(CSR_HSTATUS) | ((word_t)2 << 32);
  if ((csr == CSR_HGEIE || csr == CSR_HGEIP) && riscv_h_gstage_preview_enabled())
    return 0;
  if (csr == CSR_HENVCFG && riscv_h_gstage_preview_enabled())
    return CSR(CSR_HENVCFG) & (CSR(CSR_MENVCFG) | ~((word_t)3 << 62));
#endif
  if ((csr == CSR_TIME || csr == CSR_TIMEH) && multidiff_clint_active() && nemu_md_timer_update)
    nemu_md_timer_update();
  if (csr == CSR_TIME && cpu.virt && riscv_h_gstage_preview_enabled())
    return CSR(CSR_TIME) + CSR(CSR_HTIMEDELTA);
  if (csr == CSR_MIP) return riscv_mip_value();
  if (csr == CSR_SIP) return riscv_mip_value() & CSR(CSR_MIDELEG) & (word_t)riscv_supervisor_irq_mask();
  if (csr == CSR_SIE) return CSR(CSR_MIE) & CSR(CSR_MIDELEG) & (word_t)riscv_supervisor_irq_mask();
  if (riscv_h_gstage_preview_enabled())
  {
    word_t virtual_mask = (word_t)riscv_virtual_irq_mask();
    if (csr == CSR_HIP) return riscv_mip_value() & virtual_mask;
    if (csr == CSR_HIE) return CSR(CSR_MIE) & virtual_mask;
    if (csr == CSR_VSIP) return (riscv_mip_value() & CSR(CSR_HIDELEG) & virtual_mask) >> 1;
    if (csr == CSR_VSIE) return (CSR(CSR_MIE) & CSR(CSR_HIDELEG) & virtual_mask) >> 1;
  }
  if (csr == CSR_SCOUNTOVF) return 0;
  if (csr >= CSR_HSTATEEN0 && csr <= CSR_HSTATEEN3 &&
      riscv_h_gstage_preview_enabled() && riscv_smstateen_preview_enabled())
    return CSR(csr) & CSR(CSR_MSTATEEN0 + csr - CSR_HSTATEEN0);
  if (is_hpm_zero_csr(csr))
    return 0;
  if (csr == CSR_FFLAGS)
    return CSR(CSR_FCSR) & 0x1f;
  if (csr == CSR_FRM)
    return (CSR(CSR_FCSR) >> 5) & 0x7;
  if (csr == CSR_FCSR)
    return CSR(CSR_FCSR) & 0xff;

  /* Raptor implements the user-visible counters as read-only aliases of the
   * corresponding machine counters, rather than as independent storage. */
  if (csr == CSR_CYCLE_)
    return CSR(CSR_MCYCLE);
  if (csr == CSR_INSTRET)
    return CSR(CSR_MINSTRET);
#ifndef CONFIG_RV64
  if (csr == CSR_CYCLEH)
    return CSR(CSR_MCYCLEH);
  if (csr == CSR_INSTRETH)
    return CSR(CSR_MINSTRETH);
#endif
  return CSR(csr);
}
#define CSR_READ(i) csr_read_value(i)
static inline word_t csr_rmw_value(uint16_t csr)
{
  if (csr == CSR_MIP)
    return (riscv_mip_value() & ~(word_t)0x200) | (CSR(CSR_MIP) & (word_t)0x200);
  return csr_read_value(csr);
}
static inline word_t stateen_machine_mask(uint16_t csr)
{
#ifdef CONFIG_RV64
  return ((word_t)1 << 63) | (csr == CSR_MSTATEEN0 ? (word_t)1 << 62 : 0);
#else
  return ((word_t)1 << 31) | (csr == CSR_MSTATEEN0H ? (word_t)1 << 30 : 0);
#endif
}

static inline void stateen_write(uint16_t csr, word_t value)
{
  if (csr >= CSR_SSTATEEN0 && csr <= CSR_SSTATEEN3) return;
#ifdef CONFIG_RV64
  if (csr >= CSR_HSTATEEN0 && csr <= CSR_HSTATEEN3 &&
      riscv_h_gstage_preview_enabled() && riscv_smstateen_preview_enabled())
  {
    unsigned index = csr - CSR_HSTATEEN0;
    sr(csr) = value & stateen_machine_mask(CSR_MSTATEEN0 + index) &
        CSR(CSR_MSTATEEN0 + index);
    return;
  }
  if (csr >= CSR_MSTATEEN0 && csr <= CSR_MSTATEEN3)
  {
    sr(csr) = value & stateen_machine_mask(csr);
    if (riscv_h_gstage_preview_enabled())
      sr(CSR_HSTATEEN0 + csr - CSR_MSTATEEN0) &= sr(csr);
  }
#else
  if (csr >= CSR_MSTATEEN0H && csr <= CSR_MSTATEEN3H)
    sr(csr) = value & stateen_machine_mask(csr);
#endif
}

static inline bool stateen_machine_allows_supervisor(uint16_t csr)
{
  if (!riscv_smstateen_preview_enabled()) return true;
  unsigned index;
  unsigned bit;
  if (csr >= CSR_SSTATEEN0 && csr <= CSR_SSTATEEN3)
  {
    index = csr - CSR_SSTATEEN0;
    bit = 63;
  }
  else if (csr >= CSR_HSTATEEN0 && csr <= CSR_HSTATEEN3 &&
           riscv_h_gstage_preview_enabled())
  {
    index = csr - CSR_HSTATEEN0;
    bit = 63;
  }
  else if (csr == CSR_HENVCFG && riscv_h_gstage_preview_enabled())
  {
    index = 0;
    bit = 62;
  }
  else if (csr == CSR_SENVCFG)
  {
    index = 0;
    bit = 62;
  }
  else return true;
#ifdef CONFIG_RV64
  return (CSR(CSR_MSTATEEN0 + index) >> bit) & 1;
#else
  return (CSR(CSR_MSTATEEN0H + index) >> (bit - 32)) & 1;
#endif
}

static inline bool stateen_guest_access(uint16_t csr)
{
#ifdef CONFIG_RV64
  if (!cpu.virt || cpu.priv != PRV_S || !riscv_h_gstage_preview_enabled() ||
      !riscv_smstateen_preview_enabled()) return true;
  if (csr == CSR_SENVCFG) return (CSR(CSR_HSTATEEN0) >> 62) & 1;
  if (csr >= CSR_SSTATEEN0 && csr <= CSR_SSTATEEN3)
    return (CSR(CSR_HSTATEEN0 + csr - CSR_SSTATEEN0) >> 63) & 1;
#else
  (void)csr;
#endif
  return true;
}
/* CSR write with PMP hook: routes writes to pmpcfg/pmpaddr through
 * pmp_csr_write() which enforces WARL masking and L-bit lockdown.  All
 * other CSRs fall through to the raw cpu.sr[] store. */
int pmp_csr_write(uint16_t csr, word_t val);
/* WARL coercion for tvec/epc CSRs, mirroring rapt_csr.sv:
 *   - mtvec/stvec: if wdata[1]==1 (reserved MODE 10/11), mode bits -> 00.
 *   - mepc/sepc:   bit 0 always 0 (IALIGN enforcement).
 *   - satp:        if MODE field is unsupported, the entire write is dropped
 *                  (caller must check the rejection flag). */
static inline bool csrw_satp_accept(word_t v)
{
#ifdef CONFIG_RV64
  /* RV64: MODE is bits [63:60].  Accept Bare(0) or Sv39(8) only. */
  uint32_t mode = (uint32_t)((v >> 60) & 0xf);
  return (mode == 0) || (mode == 8);
#else
  /* RV32: MODE is bit [31].  Both 0 (Bare) and 1 (Sv32) are valid. */
  (void)v;
  return true;
#endif
}
static inline word_t csrw_warl(uint16_t c, word_t v)
{
  c &= 0xfff;
#ifdef CONFIG_RV_MCOUNTINHIBIT
  if (c == CSR_MCOUNTINHIBIT) return 0;
#endif
  if (c == CSR_MTVEC || c == CSR_STVEC || c == CSR_VSTVEC)
  {
    return (v & ~(word_t)0x3) | ((v & 0x2) ? 0 : (v & 0x3));
  }
  if (c == CSR_MEPC || c == CSR_SEPC || c == CSR_VSEPC)
  {
    return v & ~(word_t)0x1;
  }
  if (c == CSR_SATP || c == CSR_VSATP)
  {
#ifdef CONFIG_RV64
    /* ASID width is a platform choice: generic RV64 uses 16 bits, while
     * riscv64_ref_defconfig selects Raptor's nine-bit ASID contract. */
    const word_t asid_mask = (((word_t)1 << CONFIG_RV_ASID_BITS) - 1) << 44;
    return v & (~((word_t)0xffff << 44) | asid_mask);
#else
    return v;
#endif
  }
#ifdef CONFIG_RV64
  if (c == CSR_HEDELEG)
    return v & (word_t)0xcb1fe;
  if (c == CSR_HCOUNTEREN)
    return v & (word_t)0x7;
  if (c == CSR_HGEIE)
    return 0;
  if (c == CSR_HIDELEG || c == CSR_HVIP)
    return v & (word_t)riscv_virtual_irq_mask();
  if (c == CSR_HSTATUS)
  {
    unsigned hupmm = (v >> 48) & 3;
    if (!(riscv_isa_extensions & NEMU_ISA_EXT_SSNPM) || hupmm == 1) hupmm = 0;
    return (v & (((word_t)15 << 6) | CSR_HSTATUS_VTVM |
                 CSR_HSTATUS_VTW | CSR_HSTATUS_VTSR)) | ((word_t)2 << 32) |
        ((word_t)hupmm << 48);
  }
  if (c == CSR_HENVCFG)
  {
    word_t result = (v & (word_t)0xf0) |
        (word_t)riscv_envcfg_pmm(v, NEMU_ISA_EXT_SSNPM) |
        (v & CSR(CSR_MENVCFG) & ((word_t)3 << 62));
    return (result & (word_t)0x30) == (word_t)0x20
        ? result | (word_t)0x10 : result;
  }
  if (c == CSR_VSSTATUS)
    return (v & ((word_t)3 << 18 | (word_t)3 << 13 | (word_t)1 << 8 |
                 (word_t)1 << 5 | (word_t)1 << 1 |
                 (riscv_v128_preview_enabled() ? CSR_MSTATUS_VS_MASK : 0))) |
        ((word_t)2 << 32);
  if (c == CSR_HGATP)
  {
    word_t mode = v >> 60;
    return mode == 8 ? ((word_t)8 << 60) | (v & (((word_t)1 << 44) - 4)) : 0;
  }
#endif
  if (c == CSR_MCOUNTEREN || c == CSR_SCOUNTEREN)
  {
    return v & (word_t)0x7;
  }
#ifdef CONFIG_RAPTOR_MEMORY_MAP
  if (c == CSR_MIE) return v & ((word_t)0x10aaa | (riscv_sscofpmf_enabled() ? (word_t)0x2000 : 0) |
                                   (word_t)riscv_virtual_irq_mask());
  if (c == CSR_MBERR_STATUS) return CSR(CSR_MBERR_STATUS) & ~(v & (word_t)3);
#else
  if (c == CSR_MIE) return v & ((word_t)0xaaa | (riscv_sscofpmf_enabled() ? (word_t)0x2000 : 0) |
                                   (word_t)riscv_virtual_irq_mask());
#endif
  if (c == CSR_MENVCFGH)
    return v & (word_t)0x80000000;
  if (c == CSR_MSTATUSH)
  {
    /* Raptor is little-endian only, so MBE/SBE are WARL-zero. */
    return 0;
  }
  if (c == CSR_SENVCFG)
  {
    word_t result = (v & (word_t)0xf0) | (word_t)riscv_envcfg_pmm(v, NEMU_ISA_EXT_SSNPM);
    return (result & (word_t)0x30) == (word_t)0x20
        ? result | (word_t)0x10 : result;
  }
  if (c == CSR_MENVCFG)
  {
#ifdef CONFIG_RV64
    word_t result = (v & ((word_t)0xc000000000000000ull | (word_t)0xf0))
        | (word_t)riscv_envcfg_pmm(v, NEMU_ISA_EXT_SMNPM);
#else
    word_t result = v & (word_t)0xf0;
#endif
    return (result & (word_t)0x30) == (word_t)0x20
        ? result | (word_t)0x10 : result;
  }
  return v;
}

#define CSRW(i, v)                                                                      \
  do                                                                                    \
  {                                                                                     \
    uint16_t _c = guest_csr_alias((uint16_t)((i) & 0xfff));                             \
    word_t _v = csrw_warl(_c, (word_t)(v));                                             \
    bool _pmm_changed = (_c == CSR_SENVCFG || _c == CSR_MENVCFG ||                      \
                         _c == CSR_HENVCFG) &&                                          \
        ((CSR(_c) ^ _v) & (word_t)RISCV_ENVCFG_PMM);                                    \
    /* satp WARL: drop entire write if MODE is unsupported (Priv §10.6.1). */           \
    if ((_c == CSR_SATP || _c == CSR_VSATP) && !csrw_satp_accept(_v))                   \
    {                                                                                   \
      cpu.last_csr_wr = _c;                                                             \
      break;                                                                            \
    }                                                                                   \
    if (is_fp_csr(_c))                                                                  \
    {                                                                                   \
      if (_c == CSR_FFLAGS)                                                             \
        CSR(CSR_FCSR) = (CSR(CSR_FCSR) & ~(word_t)0x1f) | (_v & 0x1f);                  \
      else if (_c == CSR_FRM)                                                           \
        CSR(CSR_FCSR) = (CSR(CSR_FCSR) & ~(word_t)0xe0) | ((_v & 0x7) << 5);            \
      else                                                                              \
        CSR(CSR_FCSR) = _v & 0xff;                                                      \
      CSR(CSR_MSTATUS) = (CSR(CSR_MSTATUS) & ~CSR_MSTATUS_FS_MASK) | ((word_t)3 << 13); \
      if (cpu.virt) CSR(CSR_VSSTATUS) |= CSR_MSTATUS_FS_MASK;                          \
    }                                                                                   \
    else if (is_vector_csr(_c))                                                         \
      riscv_vector_csr_write(_c, _v);                                                  \
    else if (is_stateen_csr(_c))                                                        \
      stateen_write(_c, _v);                                                           \
    else if (is_hpm_zero_csr(_c))                                                       \
    {                                                                                   \
      /* Optional HPM counters/event selectors are implemented as WARL-zero. */         \
    }                                                                                   \
    else if (!pmp_csr_write(_c, _v))                                                    \
    {                                                                                   \
      if (_c == CSR_MIP)                                                                \
      {                                                                                \
        word_t mask = (word_t)riscv_supervisor_irq_mask() &                            \
            ~(sstc_enabled() ? (word_t)0x20 : 0);                                       \
        sr(_c) = (sr(_c) & ~mask) | (_v & mask);                                          \
        if (riscv_h_gstage_preview_enabled())                                           \
          CSR(CSR_HVIP) = (CSR(CSR_HVIP) & ~(word_t)0x4) | (_v & (word_t)0x4);          \
      }                      \
      else if (_c == CSR_HIE || _c == CSR_VSIE)                                         \
      {                                                                                \
        word_t mask = (word_t)riscv_virtual_irq_mask();                                 \
        if (_c == CSR_VSIE) mask &= CSR(CSR_HIDELEG);                                   \
        word_t bits = _c == CSR_VSIE ? _v << 1 : _v;                                   \
        CSR(CSR_MIE) = (CSR(CSR_MIE) & ~mask) | (bits & mask);                           \
      }                                                                                \
      else if (_c == CSR_HIP || _c == CSR_VSIP)                                         \
      {                                                                                \
        word_t mask = (word_t)0x4;                                                      \
        if (_c == CSR_VSIP) mask &= CSR(CSR_HIDELEG);                                   \
        word_t bits = _c == CSR_VSIP ? _v << 1 : _v;                                   \
        CSR(CSR_HVIP) = (CSR(CSR_HVIP) & ~mask) | (bits & mask);                         \
      }                                                                                \
      else                                                                              \
        sr(_c) = _v;                                                                    \
    }                                                                                   \
    if (_c == CSR_MENVCFG && riscv_h_gstage_preview_enabled())                          \
      CSR(CSR_HENVCFG) &= _v | ~(word_t)(UINT64_C(3) << 62);                           \
    cpu.last_csr_wr = _c;                                                               \
    /* Flush soft TLB on writes to CSRs that affect address translation */              \
    if (_c == CSR_SATP || _c == CSR_VSATP || _c == CSR_HGATP ||                         \
        _c == CSR_HSTATUS || _c == CSR_VSSTATUS ||                                      \
        _c == CSR_MSTATUS || _c == CSR_SSTATUS ||                                       \
        _c == CSR_MSTATUSH || _pmm_changed)                                              \
      soft_tlb_flush();                                                                 \
  } while (0)
#define Mr vaddr_read
#define Mw vaddr_write

#ifdef CONFIG_RV64
typedef __int128 dword_t;
typedef unsigned __int128 udword_t;
#define MULH_SHIFT 64
#else
typedef int64_t dword_t;
typedef uint64_t udword_t;
#define MULH_SHIFT 32
#endif

uint64_t get_mtimecmp();
uint64_t get_time();
word_t get_paddr(vaddr_t addr, int len);
void clint_update_mip(void);
bool clint_wfi_advance(void);
extern NEMU_TLS uint64_t g_nr_guest_inst;

void ftrace_add(word_t pc, word_t npc, word_t inst);
extern bool ftrace_enabled;

enum cbo_kind
{
  CBO_INVAL,
  CBO_CLEAN_FLUSH,
  CBO_ZERO,
};

static word_t cbo_access_exception(enum cbo_kind kind)
{
  if (cpu.priv == PRV_M)
    return 0;

  word_t menvcfg = CSR(CSR_MENVCFG);
  word_t senvcfg = CSR(CSR_SENVCFG);
  word_t henvcfg = CSR(CSR_HENVCFG);
  word_t mask;
  if (kind == CBO_INVAL)
    mask = (word_t)0x30;
  else if (kind == CBO_CLEAN_FLUSH)
    mask = (word_t)0x40;
  else
    mask = (word_t)0x80;
  if (!(menvcfg & mask) || (cpu.priv == PRV_U && !cpu.virt && !(senvcfg & mask)))
    return MCA_ILLEGAL_INS;
  if (cpu.virt && (!(henvcfg & mask) || (cpu.priv == PRV_U && !(senvcfg & mask))))
    return MCA_VIRT_INS;
  return 0;
}

static bool cbo_prepare(Decode *s, enum cbo_kind kind)
{
  word_t exception = cbo_access_exception(kind);
  if (!exception) return true;
  s->dnpc = isa_raise_intr(exception, s->pc);
  if (exception == MCA_ILLEGAL_INS) difftest_skip_ref();
  return false;
}

static void vector_memory_execute(Decode *s, bool store)
{
  word_t cause = riscv_vector_memory(s->isa.inst, store);
  if (cause) s->dnpc = isa_raise_intr(cause, s->pc);
}

#ifdef CONFIG_RV64
static word_t hypervisor_pointer_mask(word_t address, bool execute_access)
{
  if (execute_access || !(riscv_isa_extensions & NEMU_ISA_EXT_SSNPM) ||
      ((CSR(CSR_MSTATUS) | CSR(CSR_VSSTATUS)) & ((word_t)1 << 19)))
    return address;
  bool virtual_supervisor = (CSR(CSR_HSTATUS) & ((word_t)1 << 8)) != 0;
  unsigned pmm = virtual_supervisor ? (CSR(CSR_HENVCFG) >> 32) & 3 :
      cpu.priv == PRV_U ? (CSR(CSR_HSTATUS) >> 48) & 3 :
      (CSR(CSR_SENVCFG) >> 32) & 3;
  return riscv_pointer_mask_value(address, pmm, (CSR(CSR_VSATP) >> 60) != 0);
}

static void hypervisor_memory_trap(Decode *s, word_t trap)
{
  riscv_h_explicit_trap = true;
  s->dnpc = isa_raise_intr(trap, s->pc);
  riscv_h_explicit_trap = false;
}

static bool hypervisor_memory_piece(Decode *s, bool store, bool execute_access,
                                    int length, bool misaligned, int original_length,
                                    word_t address, paddr_t *piece_address)
{
  g_vaddr = address;
  riscv_h_fault_gpa = address;
  riscv_h_fault_ptw = false;
  riscv_h_fault_write = false;
  paddr_t guest_address = 0;
  paddr_t physical_address = 0;
  uint8_t vs_pbmt = 0;
  uint8_t g_pbmt = 0;
  int status = riscv_vstage_translate(address, store, execute_access,
                                      (CSR(CSR_HSTATUS) & ((word_t)1 << 8)) != 0, false,
                                      &guest_address, &riscv_h_fault_gpa,
                                      &riscv_h_fault_write, &vs_pbmt);
  if (status != RISCV_VSTAGE_OK)
  {
    word_t trap = status == RISCV_VSTAGE_PAGE_FAULT ?
        (store ? MCA_STO_PAG_FAU : MCA_LOA_PAG_FAU) :
        (status == RISCV_VSTAGE_GUEST_PAGE_FAULT ?
            (store ? MCA_STO_GUEST_PAG_FAU : MCA_LOA_GUEST_PAG_FAU) :
            (store ? MCA_STO_ACC_FAU : MCA_LOA_ACC_FAU));
    riscv_h_fault_ptw = status == RISCV_VSTAGE_GUEST_PAGE_FAULT;
    hypervisor_memory_trap(s, trap);
    return false;
  }
  riscv_h_fault_gpa = guest_address;
  status = riscv_gstage_translate(guest_address, store, execute_access, false, false,
                                  &physical_address, &g_pbmt);
  if (status != RISCV_GSTAGE_OK)
  {
    word_t trap = status == RISCV_GSTAGE_PAGE_FAULT ?
        (store ? MCA_STO_GUEST_PAG_FAU : MCA_LOA_GUEST_PAG_FAU) :
        (store ? MCA_STO_ACC_FAU : MCA_LOA_ACC_FAU);
    hypervisor_memory_trap(s, trap);
    return false;
  }
  uint8_t effective_pbmt = vs_pbmt ? vs_pbmt : g_pbmt;
  bool memory = paddr_is_memory_span(physical_address, length);
#ifdef CONFIG_DEVICE
  bool device = mmio_map_contains_span(physical_address, length);
#else
  bool device = !memory && paddr_is_mapped(physical_address) &&
      paddr_is_mapped(physical_address + length - 1);
#endif
  bool invalid_width = false;
#ifdef CONFIG_RAPTOR_MEMORY_MAP
  invalid_width = physical_address >= 0x0c000000u && physical_address < 0x0d000000u &&
      (original_length != 4 || (physical_address & 3));
#endif
  if ((!memory && !device) || (execute_access && device) || invalid_width ||
      (store && !device && paddr_is_readonly(physical_address)) ||
      pmp_check(physical_address, length, PRV_S, !store, store, execute_access))
  {
    hypervisor_memory_trap(s, store ? MCA_STO_ACC_FAU : MCA_LOA_ACC_FAU);
    return false;
  }
  if (misaligned && (effective_pbmt == 2 || device))
  {
    hypervisor_memory_trap(s, store ? MCA_STO_ACC_FAU : MCA_LOA_ACC_FAU);
    return false;
  }
  if (misaligned && effective_pbmt == 1)
  {
    hypervisor_memory_trap(s, store ? MCA_STO_ADD_MIS : MCA_LOA_ADD_MIS);
    return false;
  }
  *piece_address = physical_address;
  return true;
}

static bool hypervisor_memory_access(Decode *s, bool store, bool execute_access, int length,
                                     word_t address, word_t data, word_t *result)
{
  if (cpu.virt)
  {
    s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
    return false;
  }
  if (!riscv_h_gstage_preview_enabled() ||
      (cpu.priv == PRV_U && !(CSR(CSR_HSTATUS) & ((word_t)1 << 9))))
  {
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    return false;
  }
  address = hypervisor_pointer_mask(address, execute_access);
  bool misaligned = (address & (length - 1)) != 0;
  int first_length = 4096 - (int)(address & 4095);
  if (first_length > length) first_length = length;
  int second_length = length - first_length;
  paddr_t first_address = 0;
  paddr_t second_address = 0;
  if (!hypervisor_memory_piece(s, store, execute_access, first_length, misaligned,
                               length, address, &first_address)) return false;
  if (second_length &&
      !hypervisor_memory_piece(s, store, execute_access, second_length, misaligned,
                               length, address + first_length, &second_address)) return false;
  if (store)
  {
    if (second_length)
    {
      for (int index = 0; index < length; index++)
      {
        paddr_t physical_address = index < first_length ? first_address + index :
            second_address + index - first_length;
        paddr_write(physical_address, 1, (data >> (8 * index)) & 0xff);
      }
    }
    else paddr_write(first_address, length, data);
  }
  else if (second_length)
  {
    *result = 0;
    for (int index = 0; index < length; index++)
    {
      paddr_t physical_address = index < first_length ? first_address + index :
          second_address + index - first_length;
      *result |= (word_t)paddr_read(physical_address, 1) << (8 * index);
    }
  }
  else *result = paddr_read(first_address, length);
  return true;
}

static bool hypervisor_fence(Decode *s, bool guest_stage)
{
  if (cpu.virt)
  {
    s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
    return false;
  }
  csr_t status = {.val = CSR(CSR_MSTATUS)};
  if (!riscv_h_gstage_preview_enabled() || cpu.priv == PRV_U ||
      (guest_stage && cpu.priv == PRV_S && status.mstatus.tvm))
  {
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    return false;
  }
  soft_tlb_flush();
  return true;
}
#endif

bool csr_valid(Decode *s, uint16_t csr, bool is_write)
{
  csr = csr & 0xfff;
  // Privilege check: CSR addr[9:8] encodes minimum privilege level
  uint8_t csr_priv = (csr >> 8) & 0x3;
  bool guest_hs_csr = cpu.virt && (csr_priv == 2 ||
      (cpu.priv == PRV_S && csr_priv == 1 && guest_csr_alias(csr) == csr &&
       !guest_shared_supervisor_csr(csr)) ||
      (cpu.priv == PRV_U && csr_priv == 1 &&
       check_csr_exist(csr) != CSR_NOT_EXIST));
  if (guest_hs_csr)
  {
    bool hs_qualified = check_csr_exist(csr) != CSR_NOT_EXIST &&
        !(is_write && ((csr >> 10) & 0x3) == 0x3) &&
        stateen_machine_allows_supervisor(csr);
    s->dnpc = isa_raise_intr(hs_qualified ? MCA_VIRT_INS : MCA_ILLEGAL_INS, s->pc);
    return false;
  }
  if (csr_priv > cpu.priv &&
      !(csr_priv == 2 && cpu.priv == PRV_S && riscv_h_gstage_preview_enabled()))
  {
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    difftest_skip_ref();
    return false;
  }
  // Read-only check: CSR addr[11:10]==2'b11 means read-only
  if (is_write && ((csr >> 10) & 0x3) == 0x3)
  {
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    difftest_skip_ref();
    return false;
  }
  if (cpu.priv == PRV_S && !stateen_machine_allows_supervisor(csr))
  {
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    return false;
  }
  if (!stateen_guest_access(csr))
  {
    s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
    return false;
  }
  // TVM: if mstatus.TVM=1 and priv==S, access to satp traps illegal-instruction.
  if ((csr == CSR_SATP || csr == CSR_HGATP) && cpu.priv == PRV_S && !cpu.virt)
  {
    csr_t ms = {.val = cpu.sr[CSR_MSTATUS]};
    if (ms.mstatus.tvm)
    {
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
      difftest_skip_ref();
      return false;
    }
  }
  if (csr == CSR_SATP && cpu.virt && cpu.priv == PRV_S &&
      riscv_h_gstage_preview_enabled() && (CSR(CSR_HSTATUS) & CSR_HSTATUS_VTVM))
  {
    s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
    return false;
  }
  if (is_fp_csr(csr))
  {
    word_t fs = (CSR(CSR_MSTATUS) & CSR_MSTATUS_FS_MASK) >> 13;
    if (!(CSR(CSR_MISA) & CSR_MISA_EXT_F) || fs == 0 ||
        (cpu.virt && !(CSR(CSR_VSSTATUS) & CSR_MSTATUS_FS_MASK)))
    {
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
      difftest_skip_ref();
      return false;
    }
  }
  if (is_vector_csr(csr) &&
      !riscv_vector_context_enabled())
  {
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    return false;
  }
  if ((csr == 0x14d || csr == 0x15d) && cpu.priv != PRV_M &&
      (!sstc_enabled() || !(CSR(CSR_MCOUNTEREN) & 2)))
  {
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    return false;
  }
  if (csr == 0x14d && cpu.virt && riscv_h_gstage_preview_enabled() &&
      (!(CSR(CSR_HENVCFG) & (word_t)(UINT64_C(1) << 63)) ||
       !(CSR(CSR_HCOUNTEREN) & 2)))
  {
    s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
    return false;
  }
  unsigned counter_bit = counteren_bit(csr);
  if (counter_bit != 0 && cpu.priv != PRV_M)
  {
    if (!(CSR(CSR_MCOUNTEREN) & counter_bit))
    {
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
      difftest_skip_ref();
      return false;
    }
    if (cpu.virt && riscv_h_gstage_preview_enabled() &&
        !(CSR(CSR_HCOUNTEREN) & counter_bit))
    {
      s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
      return false;
    }
    if (cpu.priv == PRV_U && !(CSR(CSR_SCOUNTEREN) & counter_bit))
    {
      if (cpu.virt && riscv_h_gstage_preview_enabled())
        s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
      else
      {
        s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
        difftest_skip_ref();
      }
      return false;
    }
  }
  /* The implemented HPM banks are read-only zero and their counter-enable
   * bits are WARL-zero, so the user aliases are accessible only from M-mode. */
  if (csr >= 0xc03 && csr <= 0xc1f && cpu.priv != PRV_M)
  {
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    difftest_skip_ref();
    return false;
  }
#ifndef CONFIG_RV64
  if (csr >= 0xc83 && csr <= 0xc9f && cpu.priv != PRV_M)
  {
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    difftest_skip_ref();
    return false;
  }
#endif
  // PMP CSRs are fully implemented in system/pmp.c; no special-case needed
  // here.  Writes are routed through pmp_csr_write() below.

  CSR_status csr_status = check_csr_exist(csr);
  switch (csr_status)
  {
  case CSR_EXIST:
    return true;
    break;
  case CSR_EXIST_DIFF_SKIP:
    difftest_skip_ref();
    return true;
    break;
  case CSR_NOT_EXIST:
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    difftest_skip_ref();
    break;
  default:
    panic("Wrong csr_status");
    break;
  }
  return false;
}

static void decode_operand(Decode *s, int *rd, int *rs, word_t *src1, word_t *src2, word_t *imm, int type)
{
  uint32_t i = s->isa.inst;
  uint32_t rs1 = BITS(i, 19, 15);
  uint32_t rs2 = BITS(i, 24, 20);
  *rd = BITS(i, 11, 7);
  *rs = rs1;
  switch (type)
  {
  case TYPE_R:
    src1R();
    src2R();
    break;
  case TYPE_I:
    src1R();
    immI();
    break;
  case TYPE_I_I:
    *src1 = rs1;
    immI();
    break;
  case TYPE_S:
    src1R();
    src2R();
    immS();
    break;
  case TYPE_B:
    src1R();
    src2R();
    immB();
    break;
  case TYPE_U:
    immU();
    break;
  case TYPE_J:
    immJ();
    break;
  case TYPE_N:
    break;
  default:
    panic("unsupported type = %d", type);
  }
}

/*
    31       27   25 24     20 19     15 14  12 11     7 6      0
    |  funct7       |   rs2   |   rs1   |funct3|  rd    | opcode | R-type
    |  [11:0]                 |   rs1   |funct3|  rd    | opcode | I-type
    |  [11:5]       |   rs2   |   rs1   |funct3|   [4:0]| opcode | S-type
    |  [12|10:5]    |   rs2   |   rs1   |funct3|[4:1|11]| opcode | B-type
    |  [31:12]                                 |   rd   | opcode | U-type
    |  [20|10:1|11|19:12]                      |   rd   | opcode | J-type
 */
static int decode_exec(Decode *s)
{
  if ((s->isa.inst & 0x3) != 3)
  {
    s->isa.inst &= 0xffff;
    s->snpc = s->pc + 2;
    // uint32_t inst = s->isa.inst;
    uint32_t decompress_c(uint32_t inst);
    s->isa.inst = decompress_c(s->isa.inst);

    // char p[512];
    // void disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);
    // disassemble(p, 512, s->pc, (uint8_t *)(&s->isa.inst), 4);
    // printf("[C2I] %08x: %04x -> %08x, %s\n", s->pc, inst, s->isa.inst, p);
  }
  else if (s->snpc <= s->pc)
  {
    /* Cache-miss path: inst_fetch advanced snpc to pc+4 already. On a
     * decode-cache hit the caller has pre-set snpc to pc+ilen, so we
     * must not clobber it here. */
    s->snpc = s->pc + 4;
  }
  s->dnpc = s->snpc;

#define INSTPAT_INST(s) ((s)->isa.inst)
#define INSTPAT_MATCH(s, name, type, ... /* execute body */)               \
  {                                                                        \
    int rd = 0, rs1 = 0;                                                   \
    word_t src1 = 0, src2 = 0, imm = 0;                                    \
    decode_operand(s, &rd, &rs1, &src1, &src2, &imm, concat(TYPE_, type)); \
    __VA_ARGS__;                                                           \
  }

  INSTPAT_SWITCH();
  //      |31      24rs2 19rs1 14  11 rd 6      0|
  INSTPAT_CASE(0b01101, grp_lui) // LUI
  INSTPAT("??????? ????? ????? ??? ????? 01101 11", lui, U, R(rd) = imm);
  INSTPAT_CASE_END(grp_lui)

  INSTPAT_CASE(0b00101, grp_auipc) // AUIPC
  INSTPAT("??????? ????? ????? ??? ????? 00101 11", auipc, U, R(rd) = s->pc + imm);
  INSTPAT_CASE_END(grp_auipc)

  INSTPAT_CASE(0b11011, grp_jal) // JAL
  INSTPAT("??????? ????? ????? ??? ????? 11011 11", jal, J, R(rd) = s->snpc; s->dnpc = (s->pc + imm) & ~1);
  INSTPAT_CASE_END(grp_jal)

  INSTPAT_CASE(0b11001, grp_jalr) // JALR
  INSTPAT("??????? ????? ????? 000 ????? 11001 11", jalr, I, R(rd) = s->snpc; s->dnpc = (src1 + imm) & ~1);
  INSTPAT_CASE_END(grp_jalr)

  INSTPAT_CASE(0b11000, grp_branch) // Branch
  INSTPAT("??????? ????? ????? 000 ????? 11000 11", beq, B, if (src1 == src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 001 ????? 11000 11", bne, B, if (src1 != src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 100 ????? 11000 11", blt, B, if ((sword_t)src1 < (sword_t)src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 101 ????? 11000 11", bge, B, if ((sword_t)src1 >= (sword_t)src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 110 ????? 11000 11", bltu, B, if ((word_t)src1 < (word_t)src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 111 ????? 11000 11", bgeu, B, if ((word_t)src1 >= (word_t)src2) s->dnpc = s->pc + imm);
  INSTPAT_CASE_END(grp_branch)

  INSTPAT_CASE(0b00000, grp_load) // Load
  INSTPAT("??????? ????? ????? 000 ????? 00000 11", lb, I, R(rd) = SEXT(Mr(src1 + imm, 1), 8));
  INSTPAT("??????? ????? ????? 001 ????? 00000 11", lh, I, R(rd) = SEXT(Mr(src1 + imm, 2), 16));
  INSTPAT("??????? ????? ????? 010 ????? 00000 11", lw, I, R(rd) = SEXT(Mr(src1 + imm, 4), 32));
  INSTPAT("??????? ????? ????? 100 ????? 00000 11", lbu, I, { R(rd) = Mr(src1 + imm, 1); });
  INSTPAT("??????? ????? ????? 101 ????? 00000 11", lhu, I, { R(rd) = Mr(src1 + imm, 2); });
#ifdef CONFIG_RV64
  // RV64I loads (RV32 leaves these encodings reserved → illegal-instruction)
  INSTPAT("??????? ????? ????? 110 ????? 00000 11", lwu, I, R(rd) = Mr(src1 + imm, 4));
  INSTPAT("??????? ????? ????? 011 ????? 00000 11", ld, I, R(rd) = Mr(src1 + imm, 8));
#endif
  INSTPAT_CASE_END(grp_load)

  INSTPAT_CASE(0b00001, grp_fp_load)
  INSTPAT("??????? ????? ????? 001 ????? 00001 11", flh, I, fp_load_h(s, rd, src1 + imm));
  INSTPAT("??????? ????? ????? 010 ????? 00001 11", flw, I, fp_load_s(s, rd, src1 + imm));
  INSTPAT("??????? ????? ????? 011 ????? 00001 11", fld, I, fp_load_d(s, rd, src1 + imm));
  INSTPAT("??????? ????? ????? 000 ????? 00001 11", vle8, N, {
    vector_memory_execute(s, false);
  });
  INSTPAT("??????? ????? ????? 101 ????? 00001 11", vle16, N, {
    vector_memory_execute(s, false);
  });
  INSTPAT("??????? ????? ????? 110 ????? 00001 11", vle32, N, {
    vector_memory_execute(s, false);
  });
  INSTPAT("??????? ????? ????? 111 ????? 00001 11", vle64, N, {
    vector_memory_execute(s, false);
  });
  INSTPAT_CASE_END(grp_fp_load)

  INSTPAT_CASE(0b01000, grp_store) // Store
  INSTPAT("??????? ????? ????? 000 ????? 01000 11", sb, S, Mw(src1 + imm, 1, src2));
  INSTPAT("??????? ????? ????? 001 ????? 01000 11", sh, S, Mw(src1 + imm, 2, src2));
  INSTPAT("??????? ????? ????? 010 ????? 01000 11", sw, S, Mw(src1 + imm, 4, src2));
#ifdef CONFIG_RV64
  // RV64I store (RV32 reserved → illegal-instruction)
  INSTPAT("??????? ????? ????? 011 ????? 01000 11", sd, S, Mw(src1 + imm, 8, src2));
#endif
  INSTPAT_CASE_END(grp_store)

  INSTPAT_CASE(0b01001, grp_fp_store)
  INSTPAT("??????? ????? ????? 001 ????? 01001 11", fsh, S, fp_store_h(s, src1 + imm, fp_rs2(s)));
  INSTPAT("??????? ????? ????? 010 ????? 01001 11", fsw, S, fp_store_s(s, src1 + imm, fp_rs2(s)));
  INSTPAT("??????? ????? ????? 011 ????? 01001 11", fsd, S, fp_store_d(s, src1 + imm, fp_rs2(s)));
  INSTPAT("??????? ????? ????? 000 ????? 01001 11", vse8, N, {
    vector_memory_execute(s, true);
  });
  INSTPAT("??????? ????? ????? 101 ????? 01001 11", vse16, N, {
    vector_memory_execute(s, true);
  });
  INSTPAT("??????? ????? ????? 110 ????? 01001 11", vse32, N, {
    vector_memory_execute(s, true);
  });
  INSTPAT("??????? ????? ????? 111 ????? 01001 11", vse64, N, {
    vector_memory_execute(s, true);
  });
  INSTPAT_CASE_END(grp_fp_store)

  INSTPAT_CASE(0b10000, grp_fmadd)
  INSTPAT("????? 00 ????? ????? ??? ????? 10000 11", fmadd.s, R, fp_exec_fma_s(s, rd, fp_rs1(s), fp_rs2(s), fp_rs3(s), false, false));
  INSTPAT("????? 01 ????? ????? ??? ????? 10000 11", fmadd.d, R, fp_exec_fma_d(s, rd, fp_rs1(s), fp_rs2(s), fp_rs3(s), false, false));
  INSTPAT_CASE_END(grp_fmadd)

  INSTPAT_CASE(0b10001, grp_fmsub)
  INSTPAT("????? 00 ????? ????? ??? ????? 10001 11", fmsub.s, R, fp_exec_fma_s(s, rd, fp_rs1(s), fp_rs2(s), fp_rs3(s), false, true));
  INSTPAT("????? 01 ????? ????? ??? ????? 10001 11", fmsub.d, R, fp_exec_fma_d(s, rd, fp_rs1(s), fp_rs2(s), fp_rs3(s), false, true));
  INSTPAT_CASE_END(grp_fmsub)

  INSTPAT_CASE(0b10010, grp_fnmsub)
  INSTPAT("????? 00 ????? ????? ??? ????? 10010 11", fnmsub.s, R, fp_exec_fma_s(s, rd, fp_rs1(s), fp_rs2(s), fp_rs3(s), true, false));
  INSTPAT("????? 01 ????? ????? ??? ????? 10010 11", fnmsub.d, R, fp_exec_fma_d(s, rd, fp_rs1(s), fp_rs2(s), fp_rs3(s), true, false));
  INSTPAT_CASE_END(grp_fnmsub)

  INSTPAT_CASE(0b10011, grp_fnmadd)
  INSTPAT("????? 00 ????? ????? ??? ????? 10011 11", fnmadd.s, R, fp_exec_fma_s(s, rd, fp_rs1(s), fp_rs2(s), fp_rs3(s), true, true));
  INSTPAT("????? 01 ????? ????? ??? ????? 10011 11", fnmadd.d, R, fp_exec_fma_d(s, rd, fp_rs1(s), fp_rs2(s), fp_rs3(s), true, true));
  INSTPAT_CASE_END(grp_fnmadd)

  INSTPAT_CASE(0b10100, grp_fp_op)
  INSTPAT("111100? 00001 ????? 000 ????? 10100 11", fli, N, fp_exec_zfa(s, FP_ZFA_LI));
  INSTPAT("001010? ????? ????? 01? ????? 10100 11", fminmaxm, N, fp_exec_zfa(s, FP_ZFA_MINMAX));
  INSTPAT("010000? 0010? ????? ??? ????? 10100 11", fround, N, fp_exec_zfa(s, FP_ZFA_ROUND));
  INSTPAT("101000? ????? ????? 10? ????? 10100 11", fquiet, N, fp_exec_zfa(s, FP_ZFA_QUIET));
  INSTPAT("1100001 01000 ????? 001 ????? 10100 11", fcvtmod.w.d, N, fp_exec_zfa(s, FP_ZFA_MOD));
  INSTPAT("1110001 00001 ????? 000 ????? 10100 11", fmvh.x.d, N, fp_exec_zfa(s, FP_ZFA_MOVE_HIGH));
  INSTPAT("1011001 ????? ????? 000 ????? 10100 11", fmvp.d.x, N, fp_exec_zfa(s, FP_ZFA_MOVE_PAIR));
  INSTPAT("1111010 00000 ????? 000 ????? 10100 11", fmv.h.x, R, fp_move_to_h(s, rd, src1));
  INSTPAT("1110010 00000 ????? 000 ????? 10100 11", fmv.x.h, R, fp_move_from_h(s, rd, fp_rs1(s)));
  INSTPAT("1111000 00000 ????? 000 ????? 10100 11", fmv.w.x, R, fp_move_to_s(s, rd, src1));
  INSTPAT("1110000 00000 ????? 000 ????? 10100 11", fmv.x.w, R, fp_move_from_s(s, rd, fp_rs1(s)));
  INSTPAT("0010000 ????? ????? 000 ????? 10100 11", fsgnj.s, R, fp_sign_inject_s(s, rd, fp_rs1(s), fp_rs2(s), 0));
  INSTPAT("0010000 ????? ????? 001 ????? 10100 11", fsgnjn.s, R, fp_sign_inject_s(s, rd, fp_rs1(s), fp_rs2(s), 1));
  INSTPAT("0010000 ????? ????? 010 ????? 10100 11", fsgnjx.s, R, fp_sign_inject_s(s, rd, fp_rs1(s), fp_rs2(s), 2));
  INSTPAT("0000000 ????? ????? ??? ????? 10100 11", fadd.s, R, fp_exec_binary_s(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_add_s));
  INSTPAT("0000100 ????? ????? ??? ????? 10100 11", fsub.s, R, fp_exec_binary_s(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_sub_s));
  INSTPAT("0001000 ????? ????? ??? ????? 10100 11", fmul.s, R, fp_exec_binary_s(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_mul_s));
  INSTPAT("0001100 ????? ????? ??? ????? 10100 11", fdiv.s, R, fp_exec_binary_s(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_div_s));
  INSTPAT("0101100 00000 ????? ??? ????? 10100 11", fsqrt.s, R, fp_exec_unary_s(s, rd, fp_rs1(s), riscv_fp_sqrt_s));
  INSTPAT("0010100 ????? ????? 000 ????? 10100 11", fmin.s, R, fp_exec_minmax_s(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_min_s));
  INSTPAT("0010100 ????? ????? 001 ????? 10100 11", fmax.s, R, fp_exec_minmax_s(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_max_s));
  INSTPAT("1010000 ????? ????? 000 ????? 10100 11", fle.s, R, fp_exec_compare_s(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_le_s));
  INSTPAT("1010000 ????? ????? 001 ????? 10100 11", flt.s, R, fp_exec_compare_s(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_lt_s));
  INSTPAT("1010000 ????? ????? 010 ????? 10100 11", feq.s, R, fp_exec_compare_s(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_eq_s));
  INSTPAT("1110000 00000 ????? 001 ????? 10100 11", fclass.s, R, fp_exec_class_s(s, rd, fp_rs1(s)));
  INSTPAT("1100000 00000 ????? ??? ????? 10100 11", fcvt.w.s, R, fp_exec_to_int_s(s, rd, fp_rs1(s), false, false));
  INSTPAT("1100000 00001 ????? ??? ????? 10100 11", fcvt.wu.s, R, fp_exec_to_int_s(s, rd, fp_rs1(s), true, false));
#ifdef CONFIG_RV64
  INSTPAT("1100000 00010 ????? ??? ????? 10100 11", fcvt.l.s, R, fp_exec_to_int_s(s, rd, fp_rs1(s), false, true));
  INSTPAT("1100000 00011 ????? ??? ????? 10100 11", fcvt.lu.s, R, fp_exec_to_int_s(s, rd, fp_rs1(s), true, true));
#endif
  INSTPAT("1101000 00000 ????? ??? ????? 10100 11", fcvt.s.w, R, fp_exec_from_int_s(s, rd, src1, false, false));
  INSTPAT("1101000 00001 ????? ??? ????? 10100 11", fcvt.s.wu, R, fp_exec_from_int_s(s, rd, src1, true, false));
#ifdef CONFIG_RV64
  INSTPAT("1101000 00010 ????? ??? ????? 10100 11", fcvt.s.l, R, fp_exec_from_int_s(s, rd, src1, false, true));
  INSTPAT("1101000 00011 ????? ??? ????? 10100 11", fcvt.s.lu, R, fp_exec_from_int_s(s, rd, src1, true, true));
#endif
  INSTPAT("1111001 00000 ????? 000 ????? 10100 11", fmv.d.x, R, fp_move_to_d(s, rd, src1));
  INSTPAT("1110001 00000 ????? 000 ????? 10100 11", fmv.x.d, R, fp_move_from_d(s, rd, fp_rs1(s)));
  INSTPAT("0010001 ????? ????? 000 ????? 10100 11", fsgnj.d, R, fp_sign_inject_d(s, rd, fp_rs1(s), fp_rs2(s), 0));
  INSTPAT("0010001 ????? ????? 001 ????? 10100 11", fsgnjn.d, R, fp_sign_inject_d(s, rd, fp_rs1(s), fp_rs2(s), 1));
  INSTPAT("0010001 ????? ????? 010 ????? 10100 11", fsgnjx.d, R, fp_sign_inject_d(s, rd, fp_rs1(s), fp_rs2(s), 2));
  INSTPAT("0000001 ????? ????? ??? ????? 10100 11", fadd.d, R, fp_exec_binary_d(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_add_d));
  INSTPAT("0000101 ????? ????? ??? ????? 10100 11", fsub.d, R, fp_exec_binary_d(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_sub_d));
  INSTPAT("0001001 ????? ????? ??? ????? 10100 11", fmul.d, R, fp_exec_binary_d(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_mul_d));
  INSTPAT("0001101 ????? ????? ??? ????? 10100 11", fdiv.d, R, fp_exec_binary_d(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_div_d));
  INSTPAT("0101101 00000 ????? ??? ????? 10100 11", fsqrt.d, R, fp_exec_unary_d(s, rd, fp_rs1(s), riscv_fp_sqrt_d));
  INSTPAT("0010101 ????? ????? 000 ????? 10100 11", fmin.d, R, fp_exec_minmax_d(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_min_d));
  INSTPAT("0010101 ????? ????? 001 ????? 10100 11", fmax.d, R, fp_exec_minmax_d(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_max_d));
  INSTPAT("1010001 ????? ????? 000 ????? 10100 11", fle.d, R, fp_exec_compare_d(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_le_d));
  INSTPAT("1010001 ????? ????? 001 ????? 10100 11", flt.d, R, fp_exec_compare_d(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_lt_d));
  INSTPAT("1010001 ????? ????? 010 ????? 10100 11", feq.d, R, fp_exec_compare_d(s, rd, fp_rs1(s), fp_rs2(s), riscv_fp_eq_d));
  INSTPAT("1110001 00000 ????? 001 ????? 10100 11", fclass.d, R, fp_exec_class_d(s, rd, fp_rs1(s)));
  INSTPAT("1100001 00000 ????? ??? ????? 10100 11", fcvt.w.d, R, fp_exec_to_int_d(s, rd, fp_rs1(s), false, false));
  INSTPAT("1100001 00001 ????? ??? ????? 10100 11", fcvt.wu.d, R, fp_exec_to_int_d(s, rd, fp_rs1(s), true, false));
#ifdef CONFIG_RV64
  INSTPAT("1100001 00010 ????? ??? ????? 10100 11", fcvt.l.d, R, fp_exec_to_int_d(s, rd, fp_rs1(s), false, true));
  INSTPAT("1100001 00011 ????? ??? ????? 10100 11", fcvt.lu.d, R, fp_exec_to_int_d(s, rd, fp_rs1(s), true, true));
#endif
  INSTPAT("1101001 00000 ????? ??? ????? 10100 11", fcvt.d.w, R, fp_exec_from_int_d(s, rd, src1, false, false));
  INSTPAT("1101001 00001 ????? ??? ????? 10100 11", fcvt.d.wu, R, fp_exec_from_int_d(s, rd, src1, true, false));
#ifdef CONFIG_RV64
  INSTPAT("1101001 00010 ????? ??? ????? 10100 11", fcvt.d.l, R, fp_exec_from_int_d(s, rd, src1, false, true));
  INSTPAT("1101001 00011 ????? ??? ????? 10100 11", fcvt.d.lu, R, fp_exec_from_int_d(s, rd, src1, true, true));
#endif
  INSTPAT("0100000 00001 ????? ??? ????? 10100 11", fcvt.s.d, R, fp_exec_convert_d_to_s(s, rd, fp_rs1(s)));
  INSTPAT("0100001 00000 ????? ??? ????? 10100 11", fcvt.d.s, R, fp_exec_convert_s_to_d(s, rd, fp_rs1(s)));
  INSTPAT("0100000 00010 ????? ??? ????? 10100 11", fcvt.s.h, R, fp_exec_convert_h_to_s(s, rd, fp_rs1(s)));
  INSTPAT("0100001 00010 ????? ??? ????? 10100 11", fcvt.d.h, R, fp_exec_convert_h_to_d(s, rd, fp_rs1(s)));
  INSTPAT("0100010 00000 ????? ??? ????? 10100 11", fcvt.h.s, R, fp_exec_convert_s_to_h(s, rd, fp_rs1(s)));
  INSTPAT("0100010 00001 ????? ??? ????? 10100 11", fcvt.h.d, R, fp_exec_convert_d_to_h(s, rd, fp_rs1(s)));
  INSTPAT_CASE_END(grp_fp_op)

  INSTPAT_CASE(0b00100, grp_opimm) // OP-IMM
  // Zicbop HINTs are explicit so the advertised profile is visible in the
  // decoder. The generic OP-IMM encodings also leave no architectural
  // effect with rd=x0, but naming these avoids accidental future rejection.
  INSTPAT("??????? 00000 ????? 110 00000 00100 11", prefetch.i, N, {});
  INSTPAT("??????? 00000 ????? 100 00000 00100 11", prefetch.r, N, {});
  INSTPAT("??????? 00011 ????? 110 00000 00100 11", prefetch.w, N, {});
  INSTPAT("??????? ????? ????? 000 ????? 00100 11", addi, I, R(rd) = (sword_t)src1 + imm);
  INSTPAT("??????? ????? ????? 010 ????? 00100 11", slti, I, R(rd) = ((sword_t)src1 < (sword_t)imm) ? 1 : 0);
  INSTPAT("??????? ????? ????? 011 ????? 00100 11", sltiu, I, R(rd) = ((word_t)src1 < (word_t)imm) ? 1 : 0);
  INSTPAT("??????? ????? ????? 100 ????? 00100 11", xori, I, R(rd) = src1 ^ imm);
  INSTPAT("??????? ????? ????? 110 ????? 00100 11", ori, I, R(rd) = src1 | imm);
  INSTPAT("??????? ????? ????? 111 ????? 00100 11", andi, I, R(rd) = src1 & imm);
#ifndef CONFIG_RV64
  INSTPAT("0000000 ????? ????? 001 ????? 00100 11", slli, I, R(rd) = src1 << (imm & 0x1f));
  INSTPAT("0000000 ????? ????? 101 ????? 00100 11", srli, I, R(rd) = ((word_t)src1) >> (imm & 0x1f));
  INSTPAT("0100000 ????? ????? 101 ????? 00100 11", srai, I, R(rd) = ((sword_t)src1) >> (imm & 0x1f));
#else
  // RV64I shift-immediate permits shamt[5]; RV32 must reject that bit.
  INSTPAT("000000? ????? ????? 001 ????? 00100 11", slli, I, R(rd) = src1 << (imm & 0x3f));
  INSTPAT("000000? ????? ????? 101 ????? 00100 11", srli, I, R(rd) = (word_t)src1 >> (imm & 0x3f));
  INSTPAT("010000? ????? ????? 101 ????? 00100 11", srai, I, R(rd) = (sword_t)src1 >> (imm & 0x3f));

#endif

  // Zbb Extension (OP-IMM encoded)
  INSTPAT("0110000 00000 ????? 001 ????? 00100 11", clz, I, {
    word_t x = src1; unsigned count = sizeof(word_t) * 8;
    for (int i = sizeof(word_t) * 8 - 1; i >= 0; i--) { if ((x >> i) & 1) { count = sizeof(word_t) * 8 - 1 - i; break; } }
    R(rd) = count; });
  INSTPAT("0110000 00001 ????? 001 ????? 00100 11", ctz, I, {
    word_t x = src1; unsigned count = sizeof(word_t) * 8;
    for (unsigned i = 0; i < sizeof(word_t) * 8; i++) { if ((x >> i) & 1) { count = i; break; } }
    R(rd) = count; });
  INSTPAT("0110000 00010 ????? 001 ????? 00100 11", cpop, I, {
    word_t x = src1; unsigned count = 0;
    for (unsigned i = 0; i < sizeof(word_t) * 8; i++) { if ((x >> i) & 1) count++; }
    R(rd) = count; });
  INSTPAT("0110000 00100 ????? 001 ????? 00100 11", sext.b, I, R(rd) = SEXT(src1 & 0xff, 8));
  INSTPAT("0110000 00101 ????? 001 ????? 00100 11", sext.h, I, R(rd) = SEXT(src1 & 0xffff, 16));
#ifndef CONFIG_RV64
  INSTPAT("0110100 11000 ????? 101 ????? 00100 11", rev8, I, {
    word_t x = src1, result = 0;
    result |= (x & 0xff) << 24; result |= ((x >> 8) & 0xff) << 16;
    result |= ((x >> 16) & 0xff) << 8; result |= ((x >> 24) & 0xff);
    R(rd) = result; });
  INSTPAT("0110000 ????? ????? 101 ????? 00100 11", rori, I, {
    unsigned shamt = imm & 0x1f;
    R(rd) = ((word_t)src1 >> shamt) | (src1 << ((32 - shamt) & 31)); });

  // Zbs Extension (OP-IMM encoded, RV32)
  INSTPAT("0100100 ????? ????? 001 ????? 00100 11", bclri, I, R(rd) = src1 & ~((word_t)1 << (imm & 0x1f)));
  INSTPAT("0100100 ????? ????? 101 ????? 00100 11", bexti, I, R(rd) = ((word_t)src1 >> (imm & 0x1f)) & 1);
  INSTPAT("0110100 ????? ????? 001 ????? 00100 11", binvi, I, R(rd) = src1 ^ ((word_t)1 << (imm & 0x1f)));
  INSTPAT("0010100 ????? ????? 001 ????? 00100 11", bseti, I, R(rd) = src1 | ((word_t)1 << (imm & 0x1f)));
#else
  INSTPAT("0110101 11000 ????? 101 ????? 00100 11", rev8, I, {
    word_t x = src1, result = 0;
    for (int i = 0; i < 8; i++) result |= ((x >> (i * 8)) & 0xff) << ((7 - i) * 8);
    R(rd) = result; });
  INSTPAT("011000? ????? ????? 101 ????? 00100 11", rori, I, {
    unsigned shamt = imm & 0x3f;
    R(rd) = ((word_t)src1 >> shamt) | (src1 << ((64 - shamt) & 63)); });
  // Zbs Extension (OP-IMM encoded, RV64)
  INSTPAT("010010? ????? ????? 001 ????? 00100 11", bclri, I, R(rd) = src1 & ~((word_t)1 << (imm & 0x3f)));
  INSTPAT("010010? ????? ????? 101 ????? 00100 11", bexti, I, R(rd) = ((word_t)src1 >> (imm & 0x3f)) & 1);
  INSTPAT("011010? ????? ????? 001 ????? 00100 11", binvi, I, R(rd) = src1 ^ ((word_t)1 << (imm & 0x3f)));
  INSTPAT("001010? ????? ????? 001 ????? 00100 11", bseti, I, R(rd) = src1 | ((word_t)1 << (imm & 0x3f)));
#endif
  INSTPAT("0010100 00111 ????? 101 ????? 00100 11", orc.b, I, {
    word_t x = src1, result = 0;
    for (unsigned i = 0; i < sizeof(word_t); i++) {
      if ((x >> (i * 8)) & 0xff) result |= (word_t)0xff << (i * 8);
    }
    R(rd) = result; });
  INSTPAT_CASE_END(grp_opimm)

  INSTPAT_CASE(0b01100, grp_op) // OP + RV32M
  INSTPAT("0000000 ????? ????? 000 ????? 01100 11", add, R, R(rd) = src1 + src2);
  INSTPAT("0100000 ????? ????? 000 ????? 01100 11", sub, R, R(rd) = src1 - src2);
  INSTPAT("0000000 ????? ????? 001 ????? 01100 11", sll, R, R(rd) = src1 << (src2 & (sizeof(word_t) * 8 - 1)));
  INSTPAT("0000000 ????? ????? 010 ????? 01100 11", slt, R, R(rd) = (sword_t)src1 < (sword_t)src2);
  INSTPAT("0000000 ????? ????? 011 ????? 01100 11", sltu, R, R(rd) = ((word_t)src1 < (word_t)src2) ? 1 : 0);
  INSTPAT("0000000 ????? ????? 100 ????? 01100 11", xor, R, R(rd) = src1 ^ src2);
  INSTPAT("0000000 ????? ????? 101 ????? 01100 11", srl, R, R(rd) = src1 >> (src2 & (sizeof(word_t) * 8 - 1)));
  // SRA: arithmetic right shift requires signed operand so `>>` is arithmetic, not logical
  INSTPAT("0100000 ????? ????? 101 ????? 01100 11", sra, R, R(rd) = (sword_t)src1 >> (src2 & (sizeof(word_t) * 8 - 1)));
  INSTPAT("0000000 ????? ????? 110 ????? 01100 11", or, R, R(rd) = src1 | src2);
  INSTPAT("0000000 ????? ????? 111 ????? 01100 11", and, R, R(rd) = src1 & src2);
  // RV32M Extension
  INSTPAT("0000001 ????? ????? 000 ????? 01100 11", mul, R, R(rd) = src1 * src2);
  INSTPAT("0000001 ????? ????? 001 ????? 01100 11", mulh, R, R(rd) = ((dword_t)(sword_t)src1 * (dword_t)(sword_t)src2) >> MULH_SHIFT);
  INSTPAT("0000001 ????? ????? 010 ????? 01100 11", mulhsu, R, R(rd) = ((dword_t)(sword_t)src1 * (dword_t)(word_t)src2) >> MULH_SHIFT);
  INSTPAT("0000001 ????? ????? 011 ????? 01100 11", mulhu, R, R(rd) = ((udword_t)(word_t)src1 * (udword_t)(word_t)src2) >> MULH_SHIFT);
  // RISC-V spec: div-by-zero and signed overflow (INT_MIN/-1) have defined results
  INSTPAT("0000001 ????? ????? 100 ????? 01100 11", div, R,
          R(rd) = ((sword_t)src2 == 0)                                  ? (word_t)~0
                  : (src1 == ((word_t)1 << (sizeof(word_t) * 8 - 1))
                     && (sword_t)src2 == -1)                            ? src1
                                                                        : (word_t)((sword_t)src1 / (sword_t)src2));
  INSTPAT("0000001 ????? ????? 101 ????? 01100 11", divu, R,
          R(rd) = ((word_t)src2 == 0) ? (word_t)~0 : (word_t)src1 / (word_t)src2);
  INSTPAT("0000001 ????? ????? 110 ????? 01100 11", rem, R,
          R(rd) = ((sword_t)src2 == 0)                                  ? src1
                  : (src1 == ((word_t)1 << (sizeof(word_t) * 8 - 1))
                     && (sword_t)src2 == -1)                            ? 0
                                                                        : (word_t)((sword_t)src1 % (sword_t)src2));
  INSTPAT("0000001 ????? ????? 111 ????? 01100 11", remu, R, R(rd) = ((word_t)src2 == 0) ? src1 : (word_t)src1 % (word_t)src2);

  // Zba Extension
  INSTPAT("0010000 ????? ????? 010 ????? 01100 11", sh1add, R, R(rd) = (src1 << 1) + src2);
  INSTPAT("0010000 ????? ????? 100 ????? 01100 11", sh2add, R, R(rd) = (src1 << 2) + src2);
  INSTPAT("0010000 ????? ????? 110 ????? 01100 11", sh3add, R, R(rd) = (src1 << 3) + src2);

  // Zbb Extension
  INSTPAT("0100000 ????? ????? 111 ????? 01100 11", andn, R, R(rd) = src1 & ~src2);
  INSTPAT("0100000 ????? ????? 110 ????? 01100 11", orn, R, R(rd) = src1 | ~src2);
  INSTPAT("0100000 ????? ????? 100 ????? 01100 11", xnor, R, R(rd) = src1 ^ ~src2);
  INSTPAT("0000101 ????? ????? 110 ????? 01100 11", max, R, R(rd) = ((sword_t)src1 > (sword_t)src2) ? src1 : src2);
  INSTPAT("0000101 ????? ????? 111 ????? 01100 11", maxu, R, R(rd) = ((word_t)src1 > (word_t)src2) ? src1 : src2);
  INSTPAT("0000101 ????? ????? 100 ????? 01100 11", min, R, R(rd) = ((sword_t)src1 < (sword_t)src2) ? src1 : src2);
  INSTPAT("0000101 ????? ????? 101 ????? 01100 11", minu, R, R(rd) = ((word_t)src1 < (word_t)src2) ? src1 : src2);
  INSTPAT("0110000 ????? ????? 001 ????? 01100 11", rol, R, {
    unsigned shamt = src2 & (sizeof(word_t) * 8 - 1);
    R(rd) = (src1 << shamt) | ((word_t)src1 >> ((sizeof(word_t) * 8 - shamt) & (sizeof(word_t) * 8 - 1))); });
  INSTPAT("0110000 ????? ????? 101 ????? 01100 11", ror, R, {
    unsigned shamt = src2 & (sizeof(word_t) * 8 - 1);
    R(rd) = ((word_t)src1 >> shamt) | (src1 << ((sizeof(word_t) * 8 - shamt) & (sizeof(word_t) * 8 - 1))); });
#ifndef CONFIG_RV64
  INSTPAT("0000100 00000 ????? 100 ????? 01100 11", zext.h, R, R(rd) = (word_t)(uint16_t)src1);
#endif

  // Zbs Extension
  INSTPAT("0100100 ????? ????? 001 ????? 01100 11", bclr, R, R(rd) = src1 & ~((word_t)1 << (src2 & (sizeof(word_t) * 8 - 1))));
  INSTPAT("0100100 ????? ????? 101 ????? 01100 11", bext, R, R(rd) = ((word_t)src1 >> (src2 & (sizeof(word_t) * 8 - 1))) & 1);
  INSTPAT("0110100 ????? ????? 001 ????? 01100 11", binv, R, R(rd) = src1 ^ ((word_t)1 << (src2 & (sizeof(word_t) * 8 - 1))));
  INSTPAT("0010100 ????? ????? 001 ????? 01100 11", bset, R, R(rd) = src1 | ((word_t)1 << (src2 & (sizeof(word_t) * 8 - 1))));

  // Zbc Extension (Carry-less Multiplication)
  INSTPAT("0000101 ????? ????? 001 ????? 01100 11", clmul, R, {
    word_t a = src1, b = src2, result = 0;
    for (unsigned i = 0; i < sizeof(word_t) * 8; i++)
      if ((b >> i) & 1) result ^= a << i;
    R(rd) = result; });
  INSTPAT("0000101 ????? ????? 011 ????? 01100 11", clmulh, R, {
    word_t a = src1, b = src2;
    word_t result = 0;
    for (unsigned i = 1; i < sizeof(word_t) * 8; i++)
      if ((b >> i) & 1) result ^= a >> (sizeof(word_t) * 8 - i);
    R(rd) = result; });
  INSTPAT("0000101 ????? ????? 010 ????? 01100 11", clmulr, R, {
    word_t a = src1, b = src2, result = 0;
    for (unsigned i = 0; i < sizeof(word_t) * 8; i++)
      if ((b >> i) & 1) result ^= a >> (sizeof(word_t) * 8 - 1 - i);
    R(rd) = result; });

  // Zicond (Conditional Operations)
  INSTPAT("0000111 ????? ????? 101 ????? 01100 11", czero.eqz, R, R(rd) = (src2 == 0) ? 0 : src1);
  INSTPAT("0000111 ????? ????? 111 ????? 01100 11", czero.nez, R, R(rd) = (src2 != 0) ? 0 : src1);
  INSTPAT_CASE_END(grp_op)

  INSTPAT_CASE(0b10101, grp_vector)
  INSTPAT("??????? ????? ????? 111 ????? 10101 11", vset, N, {
    if (!riscv_vector_configure(s->isa.inst))
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
  });
  INSTPAT("??????? ????? ????? ??? ????? 10101 11", vector, N, {
    if (!riscv_vector_execute(s->isa.inst))
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
  });
  INSTPAT_CASE_END(grp_vector)

#ifdef CONFIG_RV64
  // RV64I OP-IMM-32 and OP-32 (RV64-only opcode groups; in RV32 these encodings
  // are reserved and must trap illegal-instruction, so the cases are omitted.)
  INSTPAT_CASE(0b00110, grp_opimm32) // OP-IMM-32 (RV64 only)
  INSTPAT("??????? ????? ????? 000 ????? 00110 11", addiw, I, R(rd) = SEXT((uint32_t)src1 + imm, 32));
  INSTPAT("0000000 ????? ????? 001 ????? 00110 11", slliw, I, R(rd) = SEXT((uint32_t)src1 << (imm & 0x1f), 32));
  INSTPAT("0000000 ????? ????? 101 ????? 00110 11", srliw, I, R(rd) = SEXT((uint32_t)src1 >> (imm & 0x1f), 32));
  INSTPAT("0100000 ????? ????? 101 ????? 00110 11", sraiw, I, R(rd) = SEXT((int32_t)src1 >> (imm & 0x1f), 32));
  // Zba Extension (RV64 only)
  INSTPAT("000010? ????? ????? 001 ????? 00110 11", slli.uw, I, R(rd) = (word_t)(uint32_t)src1 << (imm & 0x3f));
  // Zbb Extension (RV64 only)
  INSTPAT("0110000 00000 ????? 001 ????? 00110 11", clzw, I, {
    uint32_t x = (uint32_t)src1; unsigned count = 32;
    for (int i = 31; i >= 0; i--) { if ((x >> i) & 1) { count = 31 - i; break; } }
    R(rd) = count; });
  INSTPAT("0110000 00001 ????? 001 ????? 00110 11", ctzw, I, {
    uint32_t x = (uint32_t)src1; unsigned count = 32;
    for (unsigned i = 0; i < 32; i++) { if ((x >> i) & 1) { count = i; break; } }
    R(rd) = count; });
  INSTPAT("0110000 00010 ????? 001 ????? 00110 11", cpopw, I, {
    uint32_t x = (uint32_t)src1; unsigned count = 0;
    for (unsigned i = 0; i < 32; i++) { if ((x >> i) & 1) count++; }
    R(rd) = count; });
  INSTPAT("0110000 ????? ????? 101 ????? 00110 11", roriw, I, {
    uint32_t x = (uint32_t)src1; unsigned shamt = imm & 0x1f;
    R(rd) = SEXT((x >> shamt) | (x << ((32 - shamt) & 31)), 32); });
  INSTPAT_CASE_END(grp_opimm32)

  INSTPAT_CASE(0b01110, grp_op32) // OP-32 + RV64M (RV64 only)
  INSTPAT("0000000 ????? ????? 000 ????? 01110 11", addw, R, R(rd) = SEXT((uint32_t)src1 + (uint32_t)src2, 32));
  INSTPAT("0100000 ????? ????? 000 ????? 01110 11", subw, R, R(rd) = SEXT((uint32_t)src1 - (uint32_t)src2, 32));
  INSTPAT("0000000 ????? ????? 001 ????? 01110 11", sllw, R, R(rd) = SEXT((uint32_t)src1 << ((uint32_t)src2 & 31), 32));
  INSTPAT("0000000 ????? ????? 101 ????? 01110 11", srlw, R, R(rd) = SEXT((uint32_t)src1 >> ((uint32_t)src2 & 31), 32));
  INSTPAT("0100000 ????? ????? 101 ????? 01110 11", sraw, R, R(rd) = SEXT((int32_t)src1 >> ((uint32_t)src2 & 31), 32));
  // RV64M Extension
  INSTPAT("0000001 ????? ????? 000 ????? 01110 11", mulw, R, R(rd) = SEXT((uint32_t)src1 * (uint32_t)src2, 32));
  INSTPAT("0000001 ????? ????? 100 ????? 01110 11", divw, R,
          R(rd) = ((int32_t)src2 == 0) ? SEXT(UINT32_MAX, 32)
                  : ((int32_t)src1 == INT32_MIN && (int32_t)src2 == -1)
                    ? SEXT((uint32_t)INT32_MIN, 32)
                    : SEXT((int32_t)src1 / (int32_t)src2, 32));
  INSTPAT("0000001 ????? ????? 101 ????? 01110 11", divuw, R,
          R(rd) = ((uint32_t)src2 == 0) ? SEXT(UINT32_MAX, 32)
                                         : SEXT((uint32_t)src1 / (uint32_t)src2, 32));
  INSTPAT("0000001 ????? ????? 110 ????? 01110 11", remw, R,
          R(rd) = ((int32_t)src2 == 0) ? SEXT((uint32_t)src1, 32)
                  : ((int32_t)src1 == INT32_MIN && (int32_t)src2 == -1)
                    ? 0 : SEXT((int32_t)src1 % (int32_t)src2, 32));
  INSTPAT("0000001 ????? ????? 111 ????? 01110 11", remuw, R,
          R(rd) = ((uint32_t)src2 == 0) ? SEXT((uint32_t)src1, 32)
                                         : SEXT((uint32_t)src1 % (uint32_t)src2, 32));
  // Zba Extension (RV64 only)
  INSTPAT("0010000 ????? ????? 010 ????? 01110 11", sh1add.uw, R, R(rd) = ((word_t)(uint32_t)src1 << 1) + src2);
  INSTPAT("0010000 ????? ????? 100 ????? 01110 11", sh2add.uw, R, R(rd) = ((word_t)(uint32_t)src1 << 2) + src2);
  INSTPAT("0010000 ????? ????? 110 ????? 01110 11", sh3add.uw, R, R(rd) = ((word_t)(uint32_t)src1 << 3) + src2);
  INSTPAT("0000100 ????? ????? 000 ????? 01110 11", add.uw, R, R(rd) = (word_t)(uint32_t)src1 + src2);
  // Zbb Extension (RV64 only)
  INSTPAT("0000100 00000 ????? 100 ????? 01110 11", zext.h, R, R(rd) = (word_t)(uint16_t)src1);
  INSTPAT("0110000 ????? ????? 001 ????? 01110 11", rolw, R, {
    uint32_t x = (uint32_t)src1; unsigned shamt = src2 & 31;
    R(rd) = SEXT((x << shamt) | (x >> ((32 - shamt) & 31)), 32); });
  INSTPAT("0110000 ????? ????? 101 ????? 01110 11", rorw, R, {
    uint32_t x = (uint32_t)src1; unsigned shamt = src2 & 31;
    R(rd) = SEXT((x >> shamt) | (x << ((32 - shamt) & 31)), 32); });
  INSTPAT_CASE_END(grp_op32)
#endif // CONFIG_RV64

  INSTPAT_CASE(0b00011, grp_miscmem)                                   // MISC-MEM (fence, fence.i, Zicbom, fence.tso, pause)
  INSTPAT("0000000 10000 00000 000 00000 00011 11", pause, N, {});     // hint instruction (include in fence)
  INSTPAT("1000001 10011 00000 000 00000 00011 11", fence_tso, N, { cpu_bus_lock(); cpu_bus_unlock(); });
  INSTPAT("??????? ????? ????? 000 ????? 00011 11", fence, N, { cpu_bus_lock(); cpu_bus_unlock(); });
  INSTPAT("??????? ????? ????? 001 ????? 00011 11", fence_i, I, icache_flush());
  INSTPAT("0000000 00000 ????? 010 00000 00011 11", cbo.inval, I, {
    if (cbo_prepare(s, CBO_INVAL)) vaddr_check_cmo(src1);
  });
  INSTPAT("0000000 00001 ????? 010 00000 00011 11", cbo.clean, I, {
    if (cbo_prepare(s, CBO_CLEAN_FLUSH)) vaddr_check_cmo(src1);
  });
  INSTPAT("0000000 00010 ????? 010 00000 00011 11", cbo.flush, I, {
    if (cbo_prepare(s, CBO_CLEAN_FLUSH)) vaddr_check_cmo(src1);
  });
  INSTPAT("0000000 00100 ????? 010 00000 00011 11", cbo.zero, I, {
    if (cbo_prepare(s, CBO_ZERO)) {
      // Check the original operand before expanding the block so a PMA
      // denial reports that VA and produces no partial zeroing side effect.
      vaddr_check_zero(src1);
      word_t block = src1 & ~(word_t)0x3f;
      for (int off = 0; off < 64; off += sizeof(word_t))
        vaddr_write(block + off, sizeof(word_t), 0);
    }
  });
  INSTPAT_CASE_END(grp_miscmem)

  INSTPAT_CASE(0b11100, grp_system) // SYSTEM (ecall, ebreak, sfence.vma, mret, sret, wfi, CSRs)
  INSTPAT("0000000 00000 00000 000 00000 11100 11", ecall, N,
          if (cpu.priv == PRV_U && getenv("NEMU_SYSCALL_DEBUG") != NULL)
          {
              long t6 = (long)R(31);
              if (t6 == 5 || t6 == 33 || t6 == 56 || t6 == 59)
              {
                  char pbuf[80];
                  int i;
                  for (i = 0; i < 79; i++)
                  {
                      word_t ch = vaddr_read(R(10) + i, 1);
                      if (ch == 0)
                          break;
                      pbuf[i] = (char)ch;
                  }
                  pbuf[i] = '\0';
                  fprintf(stderr, "[sys] ecall t6=%ld path='%s'\n", t6, pbuf);
              }
              else
                  fprintf(stderr, "[sys] ecall pc=" FMT_WORD " t6=%ld a0=%ld a1=%ld a2=%ld\n",
                          s->pc, t6, (long)R(10), (long)R(11), (long)R(12));
          }
          s->dnpc = isa_raise_intr(
              ((cpu.priv == PRV_U) ? MCA_ENV_CAL_UMO :
               (cpu.priv == PRV_S ? (cpu.virt ? MCA_ENV_CAL_VSMO : MCA_ENV_CAL_SMO) :
                MCA_ENV_CAL_MMO)),
              s->pc));
#ifdef CONFIG_RV_EBREAK_HOST_EXIT
  INSTPAT("0000000 00001 00000 000 00000 11100 11", ebreak, N, {
    extern int sig_is_enabled(void);
    if (sig_is_enabled())
    {
      s->dnpc = isa_raise_intr(MCA_BREAK_POINT, s->pc);
    }
    else
    {
      NEMUTRAP(s->pc, R(10));
    }
  }); // R(10) is $a0
#else
  INSTPAT("0000000 00001 00000 000 00000 11100 11", ebreak, N, { s->dnpc = isa_raise_intr(MCA_BREAK_POINT, s->pc); });
#endif
  INSTPAT("0001001 ????? ????? 000 00000 11100 11", sfence.vma, N, {
    csr_t ms = {.val = CSR(CSR_MSTATUS)};
    if (cpu.virt && riscv_h_gstage_preview_enabled() &&
        (cpu.priv == PRV_U || (CSR(CSR_HSTATUS) & CSR_HSTATUS_VTVM)))
      s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
    else if (cpu.priv == PRV_U || (cpu.priv == PRV_S && ms.mstatus.tvm && !cpu.virt))
    {
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
      difftest_skip_ref();
    }
    else
    {
      soft_tlb_flush();
    }
  });
#ifdef CONFIG_RV64
  INSTPAT("0010001 ????? ????? 000 00000 11100 11", hfence.vvma, N, {
    hypervisor_fence(s, false);
  });
  INSTPAT("0010011 ????? ????? 000 00000 11100 11", hinval.vvma, N, {
    hypervisor_fence(s, false);
  });
  INSTPAT("0110001 ????? ????? 000 00000 11100 11", hfence.gvma, N, {
    hypervisor_fence(s, true);
  });
  INSTPAT("0110011 ????? ????? 000 00000 11100 11", hinval.gvma, N, {
    hypervisor_fence(s, true);
  });
  INSTPAT("011000000000 ????? 100 ????? 11100 11", hlv.b, R, {
    word_t value;
    if (hypervisor_memory_access(s, false, false, 1, src1, 0, &value)) R(rd) = SEXT(value, 8);
  });
  INSTPAT("011000000001 ????? 100 ????? 11100 11", hlv.bu, R, {
    word_t value;
    if (hypervisor_memory_access(s, false, false, 1, src1, 0, &value)) R(rd) = value;
  });
  INSTPAT("011001000000 ????? 100 ????? 11100 11", hlv.h, R, {
    word_t value;
    if (hypervisor_memory_access(s, false, false, 2, src1, 0, &value)) R(rd) = SEXT(value, 16);
  });
  INSTPAT("011001000001 ????? 100 ????? 11100 11", hlv.hu, R, {
    word_t value;
    if (hypervisor_memory_access(s, false, false, 2, src1, 0, &value)) R(rd) = value;
  });
  INSTPAT("011010000000 ????? 100 ????? 11100 11", hlv.w, R, {
    word_t value;
    if (hypervisor_memory_access(s, false, false, 4, src1, 0, &value)) R(rd) = SEXT(value, 32);
  });
  INSTPAT("011010000001 ????? 100 ????? 11100 11", hlv.wu, R, {
    word_t value;
    if (hypervisor_memory_access(s, false, false, 4, src1, 0, &value)) R(rd) = value;
  });
  INSTPAT("011011000000 ????? 100 ????? 11100 11", hlv.d, R, {
    word_t value;
    if (hypervisor_memory_access(s, false, false, 8, src1, 0, &value)) R(rd) = value;
  });
  INSTPAT("011001000011 ????? 100 ????? 11100 11", hlvx.hu, R, {
    word_t value;
    if (hypervisor_memory_access(s, false, true, 2, src1, 0, &value)) R(rd) = value;
  });
  INSTPAT("011010000011 ????? 100 ????? 11100 11", hlvx.wu, R, {
    word_t value;
    if (hypervisor_memory_access(s, false, true, 4, src1, 0, &value)) R(rd) = value;
  });
  INSTPAT("0110001 ????? ????? 100 00000 11100 11", hsv.b, R, {
    hypervisor_memory_access(s, true, false, 1, src1, src2, NULL);
  });
  INSTPAT("0110011 ????? ????? 100 00000 11100 11", hsv.h, R, {
    hypervisor_memory_access(s, true, false, 2, src1, src2, NULL);
  });
  INSTPAT("0110101 ????? ????? 100 00000 11100 11", hsv.w, R, {
    hypervisor_memory_access(s, true, false, 4, src1, src2, NULL);
  });
  INSTPAT("0110111 ????? ????? 100 00000 11100 11", hsv.d, R, {
    hypervisor_memory_access(s, true, false, 8, src1, src2, NULL);
  });
#endif
  INSTPAT("0001011 ????? ????? 000 00000 11100 11", sinval.vma, N, {
    csr_t ms = {.val = CSR(CSR_MSTATUS)};
    if (cpu.virt && riscv_h_gstage_preview_enabled() &&
        (cpu.priv == PRV_U || (CSR(CSR_HSTATUS) & CSR_HSTATUS_VTVM)))
      s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
    else if (cpu.priv == PRV_U || (cpu.priv == PRV_S && ms.mstatus.tvm && !cpu.virt))
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    else
      soft_tlb_flush();
  });
  INSTPAT("0001100 0000? 00000 000 00000 11100 11", sfence.inval, N, {
    if (cpu.priv == PRV_U && cpu.virt && riscv_h_gstage_preview_enabled())
      s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
    else if (cpu.priv == PRV_U)
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
  });
  // RV32/RV64 Zicsr Extension
  INSTPAT("??????? ????? ????? 001 ????? 11100 11", csrrw, I, { if (csr_valid(s, imm, true)) {R(rd) = CSR_READ(imm); CSRW(imm, src1); } });
  INSTPAT("??????? ????? ????? 010 ????? 11100 11", csrrs, I, { if (csr_valid(s, imm, rs1 != 0)) {R(rd) = CSR_READ(imm); if (rs1 != 0) { CSRW(imm, csr_rmw_value(imm) | src1);}; } });
  INSTPAT("??????? ????? ????? 011 ????? 11100 11", csrrc, I, { if (csr_valid(s, imm, rs1 != 0)) {R(rd) = CSR_READ(imm); if (rs1 != 0) { CSRW(imm, csr_rmw_value(imm) & ~src1);}; } });
  INSTPAT("??????? ????? ????? 101 ????? 11100 11", csrrwi, I_I, { if (csr_valid(s, imm, true)) { R(rd) = CSR_READ(imm); CSRW(imm, src1);} });
  INSTPAT("??????? ????? ????? 110 ????? 11100 11", csrrsi, I_I, { if (csr_valid(s, imm, rs1 != 0)) {R(rd) = CSR_READ(imm); if (rs1 != 0) { CSRW(imm, csr_rmw_value(imm) | src1); };} });
  INSTPAT("??????? ????? ????? 111 ????? 11100 11", csrrci, I_I, { if (csr_valid(s, imm, rs1 != 0)) {R(rd) = CSR_READ(imm); if (rs1 != 0) { CSRW(imm, csr_rmw_value(imm) & ~src1); };} });
  // Trap-Return Instructions
  INSTPAT("0011000 00010 00000 000 00000 11100 11", mret, N, {
    if (cpu.priv != PRV_M) {
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    } else {
      s->dnpc = CSR(CSR_MEPC);
      csr_t reg = {.val = CSR(CSR_MSTATUS)};
      cpu.last_inst_priv = cpu.priv;
      cpu.priv = reg.mstatus.mpp;
      cpu.virt = riscv_h_gstage_preview_enabled() && cpu.priv != PRV_M &&
          (((uint64_t)reg.val >> 39) & 1);
      reg.val &= ~(word_t)(UINT64_C(1) << 39);
      if (cpu.priv != PRV_M) reg.mstatus.mprv = 0;
      reg.mstatus.mie = reg.mstatus.mpie;
      reg.mstatus.mpie = 1;
      reg.mstatus.mpp = PRV_U;
      CSR(CSR_MSTATUS) = reg.val;
      cpu.csr_dirty = true;
      soft_tlb_flush();
    }
  });
  INSTPAT("0001000 00010 00000 000 00000 11100 11", sret, N, {
    csr_t reg = {.val = CSR(CSR_MSTATUS)};
    if (cpu.virt && riscv_h_gstage_preview_enabled() &&
        (cpu.priv == PRV_U || (CSR(CSR_HSTATUS) & CSR_HSTATUS_VTSR))) {
      s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
    } else if (cpu.priv == PRV_U ||
               (cpu.priv == PRV_S && !cpu.virt && reg.mstatus.tsr)) {
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
      difftest_skip_ref();
    } else if (cpu.virt) {
      word_t vsstatus = CSR(CSR_VSSTATUS);
      s->dnpc = CSR(CSR_VSEPC);
      cpu.last_inst_priv = cpu.priv;
      cpu.priv = (vsstatus >> 8) & 1;
      vsstatus = (vsstatus & ~((word_t)0x122)) |
          (((vsstatus >> 5) & 1) << 1) | ((word_t)1 << 5);
      CSR(CSR_VSSTATUS) = vsstatus;
      cpu.csr_dirty = true;
      soft_tlb_flush();
    } else {
      s->dnpc = CSR(CSR_SEPC);
      cpu.last_inst_priv = cpu.priv;
      word_t hstatus = CSR(CSR_HSTATUS);
      cpu.virt = riscv_h_gstage_preview_enabled() && ((hstatus >> 7) & 1);
      cpu.priv = reg.mstatus.spp;
      if (riscv_h_gstage_preview_enabled())
        CSR(CSR_HSTATUS) = hstatus & ~((word_t)1 << 7);
      reg.mstatus.sie = reg.mstatus.spie;
      reg.mstatus.spie = 1;
      reg.mstatus.spp = 0;
      /* sret returning to priv != M clears MPRV (spec). */
      if (cpu.priv != PRV_M) reg.mstatus.mprv = 0;
      CSR(CSR_MSTATUS) = reg.val;
      cpu.csr_dirty = true;
      /* SSTATUS view will be re-derived by post-instruction code. */
      soft_tlb_flush();
    }
  });
  INSTPAT("0000000 01101 00000 000 00000 11100 11", wrs.nto, N, {
    csr_t reg = {.val = CSR(CSR_MSTATUS)};
    if (!(riscv_isa_extensions & NEMU_ISA_EXT_ZAWRS) ||
        (cpu.priv != PRV_M && reg.mstatus.tw))
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
    else if (cpu.virt && riscv_h_gstage_preview_enabled() &&
             (CSR(CSR_HSTATUS) & CSR_HSTATUS_VTW))
      s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
  });
  INSTPAT("0000000 11101 00000 000 00000 11100 11", wrs.sto, N, {
    if (!(riscv_isa_extensions & NEMU_ISA_EXT_ZAWRS))
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
  });
  // Interrupt-Management Instructions
  INSTPAT("0001000 00101 00000 000 00000 11100 11", wfi, N, {
    csr_t reg = {.val = CSR(CSR_MSTATUS)};
    if (cpu.virt && riscv_h_gstage_preview_enabled() && !reg.mstatus.tw &&
        (cpu.priv == PRV_U || (CSR(CSR_HSTATUS) & CSR_HSTATUS_VTW))) {
      s->dnpc = isa_raise_intr(MCA_VIRT_INS, s->pc);
    } else if (cpu.priv == PRV_U || (cpu.priv == PRV_S && reg.mstatus.tw)) {
      s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
      difftest_skip_ref();
    } else {
#if !defined(CONFIG_TARGET_SHARE)
      // WFI acceleration: if no interrupt pending, advance time to mtimecmp
      word_t pending = riscv_mip_value() & cpu.sr[CSR_MIE];
#ifdef NEMU_HAS_SMP
      if (nemu_nr_harts > 1 || nemu_threaded || multidiff_clint_active())
        nemu_hart_waiting[nemu_hartid] = pending == 0;
      else
#endif
      if (pending == 0)
        clint_wfi_advance();
#endif
      difftest_skip_ref();
    }
  });
  // Zimop: May-Be-Operations. Architecturally write 0 to rd; semantics
  // reserved for future repurposing. Currently decode as NOP + rd<-0.
  // MOP.r.n  : 1-00--0111-- sssss 100 ddddd 1110011  (32 MOPs)
  INSTPAT("1?00??0111?? ????? 100 ????? 11100 11", mop.r, I, R(rd) = 0);
  // MOP.rr.n : 1-00--1 rs2 rs1 100 rd 1110011  (8 MOPs)
  INSTPAT("1?00??1 ????? ????? 100 ????? 11100 11", mop.rr, R, R(rd) = 0);
  INSTPAT_CASE_END(grp_system)

  INSTPAT_CASE(0b01011, grp_amo) // AMO (RV32A + RV64A)
  /* Translate with store permissions before reading; PMP checks use PA and
   * require both R/W. Unreadable or unwritable PTEs report store page fault. */
#define AMO_PRECHECK(addr, len) vaddr_check_amo((addr), (len))
  // RV32A Extension
  INSTPAT("00010?? 00000 ????? 010 ????? 01011 11", lr.w, R, { paddr_t pa = vaddr_check_reservation(src1, 4, false); R(rd) = SEXT(Mr(src1, 4), 32); cpu.reservation = pa; cpu.reservation_bytes = 4; });
  INSTPAT("00011?? ????? ????? 010 ????? 01011 11", sc.w, R, {
    paddr_t pa = vaddr_check_reservation(src1, 4, true);
    if (cpu.reservation_bytes >= 4 && pa >= cpu.reservation
        && pa - cpu.reservation <= cpu.reservation_bytes - 4) { R(rd) = 0; Mw(src1, 4, src2); } else { R(rd) = 1; }; cpu.reservation = 0; cpu.reservation_bytes = 0; });
  INSTPAT("00001?? ????? ????? 010 ????? 01011 11", amoswap.w, R, {AMO_PRECHECK(src1, 4); sword_t tmp = Mr(src1, 4); Mw(src1, 4, src2); R(rd) = SEXT(tmp, 32); });
  INSTPAT("00000?? ????? ????? 010 ????? 01011 11", amoadd.w, R, {AMO_PRECHECK(src1, 4); sword_t  tmp = Mr(src1, 4); Mw(src1, 4, src2 + tmp); R(rd) = SEXT(tmp, 32); });
  INSTPAT("00100?? ????? ????? 010 ????? 01011 11", amoxor.w, R, { AMO_PRECHECK(src1, 4); sword_t tmp = Mr(src1, 4); Mw(src1, 4, src2 ^ tmp); R(rd) = SEXT(tmp, 32); });
  INSTPAT("01100?? ????? ????? 010 ????? 01011 11", amoand.w, R, { AMO_PRECHECK(src1, 4); sword_t tmp = Mr(src1, 4); Mw(src1, 4, src2 & tmp); R(rd) = SEXT(tmp, 32); });
  INSTPAT("01000?? ????? ????? 010 ????? 01011 11", amoor.w, R, { AMO_PRECHECK(src1, 4); sword_t  tmp = Mr(src1, 4); Mw(src1, 4, src2 | tmp); R(rd) = SEXT(tmp, 32); });
  INSTPAT("10000?? ????? ????? 010 ????? 01011 11", amomin.w, R, {AMO_PRECHECK(src1, 4); int32_t tmp = (int32_t)Mr(src1, 4); Mw(src1, 4, (tmp < (int32_t)src2) ? tmp : src2);R(rd) = SEXT(tmp, 32); });
  INSTPAT("10100?? ????? ????? 010 ????? 01011 11", amomax.w, R, {AMO_PRECHECK(src1, 4); int32_t tmp = (int32_t)Mr(src1, 4); Mw(src1, 4, (tmp > (int32_t)src2) ? tmp : src2);R(rd) = SEXT(tmp, 32); });
  INSTPAT("11000?? ????? ????? 010 ????? 01011 11", amominu.w, R, {AMO_PRECHECK(src1, 4); word_t tmp = Mr(src1, 4); Mw(src1, 4, (tmp < (uint32_t)src2) ? tmp : src2);R(rd) = SEXT(tmp, 32); });
  INSTPAT("11100?? ????? ????? 010 ????? 01011 11", amomaxu.w, R, {AMO_PRECHECK(src1, 4); word_t tmp = Mr(src1, 4); Mw(src1, 4, (tmp > (uint32_t)src2) ? tmp : src2);R(rd) = SEXT(tmp, 32); });
  // RV64A Extension
#ifdef CONFIG_RV64
  INSTPAT("00010?? 00000 ????? 011 ????? 01011 11", lr.d, R, {
    paddr_t pa = vaddr_check_reservation(src1, 8, false); R(rd) = Mr(src1, 8); cpu.reservation = pa; cpu.reservation_bytes = 8; });
  INSTPAT("00011?? ????? ????? 011 ????? 01011 11", sc.d, R, {
    paddr_t pa = vaddr_check_reservation(src1, 8, true);
    if (cpu.reservation_bytes >= 8 && pa >= cpu.reservation
        && pa - cpu.reservation <= cpu.reservation_bytes - 8) { R(rd) = 0; Mw(src1, 8, src2); } else { R(rd) = 1; }; cpu.reservation = 0; cpu.reservation_bytes = 0; });
  INSTPAT("00001?? ????? ????? 011 ????? 01011 11", amoswap.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2);R(rd) = tmp; });
  INSTPAT("00000?? ????? ????? 011 ????? 01011 11", amoadd.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2 + tmp);R(rd) = tmp; });
  INSTPAT("00100?? ????? ????? 011 ????? 01011 11", amoxor.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2 ^ tmp);R(rd) = tmp; });
  INSTPAT("01100?? ????? ????? 011 ????? 01011 11", amoand.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2 & tmp);R(rd) = tmp; });
  INSTPAT("01000?? ????? ????? 011 ????? 01011 11", amoor.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, src2 | tmp);R(rd) = tmp; });
  INSTPAT("10000?? ????? ????? 011 ????? 01011 11", amomin.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, (tmp < (sword_t)src2) ? tmp : src2);R(rd) = tmp; });
  INSTPAT("10100?? ????? ????? 011 ????? 01011 11", amomax.d, R, {AMO_PRECHECK(src1, 8); sword_t tmp = Mr(src1, 8);Mw(src1, 8, (tmp > (sword_t)src2) ? tmp : src2);R(rd) = tmp; });
  INSTPAT("11000?? ????? ????? 011 ????? 01011 11", amominu.d, R, {AMO_PRECHECK(src1, 8); word_t tmp = Mr(src1, 8);Mw(src1, 8, (tmp < src2) ? tmp : src2);R(rd) = tmp; });
  INSTPAT("11100?? ????? ????? 011 ????? 01011 11", amomaxu.d, R, {AMO_PRECHECK(src1, 8); word_t tmp = Mr(src1, 8);Mw(src1, 8, (tmp > src2) ? tmp : src2);R(rd) = tmp; });
#endif
  INSTPAT_CASE_END(grp_amo)

  INSTPAT_DEFAULT()
  INSTPAT("??????? ????? ????? ??? ????? ????? ??", inv, N, {
    // A zero trap vector is legal; it does not turn a guest exception into
    // a host abort. The next fetch at address zero may itself fault.
    s->dnpc = isa_raise_intr(MCA_ILLEGAL_INS, s->pc);
  });
  INSTPAT_SWITCH_END();

  /* Fast path: normalizing mstatus/misa/medeleg/mideleg WARL fields and
   * re-deriving the sstatus/sie/sip architectural views is only necessary
   * when this instruction changed them: any Zicsr write (cpu.last_csr_wr),
   * a trap or xRET (isa_raise_intr), or an FP-dirty mark. Everything else
   * leaves those registers already coherent, so skip the whole block. */
#if defined(CONFIG_TARGET_SHARE)
  const bool csr_commit = true;
#else
  const bool csr_commit = (cpu.last_csr_wr != 0) || cpu.csr_dirty;
#endif
  const uint16_t last_csr_wr = cpu.last_csr_wr;
  cpu.last_csr_wr = 0;
  cpu.csr_dirty = false;

  if (csr_commit)
  {
  // mstatus write mask: clear non-writable bits.
  // SD (bit 31/63) is read-only (computed below); VS is writable in V128 preview mode.
  // RV64: SXL[35:34] and UXL[33:32] are WARL fields that hold XLEN==2 and are
  // enforced below regardless of writes.
#ifdef CONFIG_RV64
#define MSTATUS_WMASK (0x007E79AAULL | (riscv_v128_preview_enabled() ? CSR_MSTATUS_VS_MASK : 0) | \
    (riscv_h_gstage_preview_enabled() ? (UINT64_C(3) << 38) : 0))
#else
#define MSTATUS_WMASK (0x007E79AA | (riscv_v128_preview_enabled() ? CSR_MSTATUS_VS_MASK : 0))
#endif
  CSR(CSR_MSTATUS) = CSR(CSR_MSTATUS) & MSTATUS_WMASK;
  CSR(CSR_MISA) = CSR_MISA_VALUE;
  // medeleg is WARL: only delegable synchronous exceptions are writable,
  // matching the Spike reference for this extension set (RV32IMAC+S, Zicntr,
  // no Zicfiss/Zicfilp/H): bits 1-9, 12/13/15 (page faults), 19 (hw error).
  // Hardwired 0: bit 0 (misaligned fetch; C ext), bit 11 (ecall-M, per spec),
  // bit 18 (software check; needs Zicfiss/Zicfilp), reserved bits.
  CSR(CSR_MEDELEG) &= 0x8b3fe | (riscv_h_gstage_preview_enabled() ? (word_t)0xf00400 : 0);
  CSR(CSR_MIDELEG) = (CSR(CSR_MIDELEG) & (word_t)riscv_supervisor_irq_mask()) |
      (word_t)riscv_virtual_irq_mask();
  // sstatus/sie are architecturally views of mstatus/mie (not separate regs).
  // Propagate direct writes back to mstatus/mie at any privilege level.
  // sstatus read mask: includes SD (computed) and preview VS when enabled.
#ifdef CONFIG_RV64
#define SSTATUS_RMASK (0x80000003000C6122ULL | (riscv_v128_preview_enabled() ? CSR_MSTATUS_VS_MASK : 0))
#else
#define SSTATUS_RMASK (0x800c6122 | (riscv_v128_preview_enabled() ? CSR_MSTATUS_VS_MASK : 0))
#endif
#define SIE_RMASK ((word_t)riscv_supervisor_irq_mask())
#define SIP_RMASK ((word_t)riscv_supervisor_irq_mask())
#define SIP_WMASK ((word_t)0x2 | (riscv_sscofpmf_enabled() ? (word_t)0x2000 : 0))
  /* SSTATUS/SIE are architectural views of MSTATUS/MIE.  If the last CSR
   * write targeted SSTATUS/SIE, propagate the (masked) value into the real
   * MSTATUS/MIE.  Otherwise, SSTATUS/SIE are always re-derived below from
   * MSTATUS/MIE, so there is nothing else to sync. */
  if (last_csr_wr == CSR_SSTATUS)
  {
    word_t ms_bits = CSR(CSR_SSTATUS) & SSTATUS_RMASK;
    CSR(CSR_MSTATUS) = (CSR(CSR_MSTATUS) & ~SSTATUS_RMASK) | ms_bits;
    CSR(CSR_MSTATUS) &= MSTATUS_WMASK;
  }
  if (last_csr_wr == CSR_SIE)
  {
    word_t mask = CSR(CSR_MIDELEG) & SIE_RMASK;
    word_t mie_bits = CSR(CSR_SIE) & mask;
    CSR(CSR_MIE) = (CSR(CSR_MIE) & ~mask) | mie_bits;
  }
  if (last_csr_wr == CSR_SIP)
  {
    word_t mask = CSR(CSR_MIDELEG) & SIP_WMASK;
    word_t mip_bits = CSR(CSR_SIP) & mask;
    CSR(CSR_MIP) = (CSR(CSR_MIP) & ~mask) | mip_bits;
  }
  if (last_csr_wr == 0x14d || last_csr_wr == 0x15d ||
      last_csr_wr == CSR_MENVCFG || last_csr_wr == CSR_MENVCFGH) {
    if (multidiff_clint_active() && nemu_md_timer_update) nemu_md_timer_update();
#if !defined(CONFIG_TARGET_SHARE) && defined(CONFIG_DEVICE)
    else clint_update_mip();
#endif
  }
  if (((CSR(CSR_MSTATUS) >> 11) & 3) == 2)
    CSR(CSR_MSTATUS) &= ~((word_t)3 << 11);
#ifdef CONFIG_RV64
  /* SXL/UXL are WARL: pin to XLEN=64 (encoding 2) after all MSTATUS writes.
   * Must come after SSTATUS propagation which applies MSTATUS_WMASK again. */
  CSR(CSR_MSTATUS) = (CSR(CSR_MSTATUS) & ~0xF00000000ULL) | 0xA00000000ULL;
#endif
  // Compute SD (read-only): set when FS, VS, or XS is Dirty (== 3)
  {
    word_t fs = (CSR(CSR_MSTATUS) >> 13) & 3;
    word_t vs = (CSR(CSR_MSTATUS) >> 9) & 3;
    word_t xs = (CSR(CSR_MSTATUS) >> 15) & 3;
#ifdef CONFIG_RV64
    if (fs == 3 || vs == 3 || xs == 3)
      CSR(CSR_MSTATUS) |= (1ULL << 63);
#else
    if (fs == 3 || vs == 3 || xs == 3)
      CSR(CSR_MSTATUS) |= 0x80000000u;
#endif
  }
  // Derive sstatus/sie/sip from mstatus/mie/mip
  CSR(CSR_SSTATUS) = CSR(CSR_MSTATUS) & SSTATUS_RMASK;
  CSR(CSR_SIE) = CSR(CSR_MIE) & CSR(CSR_MIDELEG) & SIE_RMASK;
  // sip is a restricted view of mip per the privileged spec. mip changes
  // outside a CSR write (clint_update_mip, external SEIP) refresh the stored
  // sip themselves, so it is sufficient to mirror here on csr_commit.
  CSR(CSR_SIP) = riscv_mip_value() & CSR(CSR_MIDELEG) & SIP_RMASK;
  } // csr_commit

  /* Explicit writes to either half override this instruction's increment
   * of the underlying 64-bit counter, including non-x0 zero-mask RMWs. */
  const bool wrote_mcycle = last_csr_wr == CSR_MCYCLE
#ifndef CONFIG_RV64
      || last_csr_wr == CSR_MCYCLEH
#endif
      ;
  const bool wrote_minstret = last_csr_wr == CSR_MINSTRET
#ifndef CONFIG_RV64
      || last_csr_wr == CSR_MINSTRETH
#endif
      ;
  word_t inst_advance = 1;
#ifndef CONFIG_RV64
  word_t old_mcycle = CSR(CSR_MCYCLE);
  word_t old_minstret = CSR(CSR_MINSTRET);
#endif
  if (!wrote_mcycle) CSR(CSR_MCYCLE) += inst_advance;
  if (!wrote_minstret && !cpu.instruction_trapped) CSR(CSR_MINSTRET) += inst_advance;
#ifndef CONFIG_RV64
  if (CSR(CSR_MCYCLE) < old_mcycle) CSR(CSR_MCYCLEH)++;
  if (CSR(CSR_MINSTRET) < old_minstret) CSR(CSR_MINSTRETH)++;
#endif
  /* See RV32 sibling for the deadlock-safety rationale of this gate. */
#define TIMER_TICK_INTERVAL 1024u
  if ((CSR(CSR_MCYCLE) & (TIMER_TICK_INTERVAL - 1)) == 0 && multidiff_clint_active() && nemu_md_timer_update)
    nemu_md_timer_update();
  if (!multidiff_active() && (g_nr_guest_inst & (TIMER_TICK_INTERVAL - 1)) == 0)
  {
#if defined(CONFIG_TIMER_CYCLE)
    uint64_t ticks = (g_nr_guest_inst + inst_advance) / 100;
#else
    uint64_t ticks = get_time() * 10;
#endif
    CSR(CSR_TIME) = (word_t)ticks;
#ifndef CONFIG_RV64
    CSR(CSR_TIMEH) = (uint32_t)(ticks >> 32);
#endif
#if !defined(CONFIG_TARGET_SHARE)
    clint_update_mip();
#endif
  }
#undef TIMER_TICK_INTERVAL

  R(0) = 0; // reset $zero to 0

#if !defined(CONFIG_TARGET_SHARE)
  /* Skip the per-instruction call/return bookkeeping unless an ELF is loaded
   * or an interrupt entry still needs classifying. */
  if (!nemu_threaded && (ftrace_enabled || cpu.raise_intr != INTR_EMPTY))
    ftrace_add(s->pc, s->dnpc, s->isa.inst);
#endif
  s->pc = riscv_legalize_pc(s->dnpc);
  return 0;
}

NEMU_TLS jmp_buf exec_jmp_buf;
NEMU_TLS jmp_buf *exec_jmp_override;
NEMU_TLS int cause;

void nemu_memory_longjmp(int value)
{
  nemu_longjmp(exec_jmp_override ? *exec_jmp_override : exec_jmp_buf, value);
}

int isa_exec_once(Decode *s)
{
  cpu.instruction_trapped = false;
  cpu.last_csr_wr = 0;
  /* One longjmp target per instruction: fetch and decode faults share the
   * same trap entry, so a second _setjmp() only adds hot-path overhead. */
  int jmp_value = nemu_setjmp(exec_jmp_buf);
  if (jmp_value)
  {
    cpu_bus_unwind();
    s->pc = isa_raise_intr(cause, s->pc);
    s->isa.inst = 0x13; // addi x0, x0, 0; a.k.a. NOP
    return 0;
  }
  /* Conservatively bypass decoded-instruction caching while PBMT can be
   * active. A cached decode must not elide reads from an NC/IO mapping.
   * This also covers mixed-type pages within one fetched instruction. */
#ifdef CONFIG_ISA64
  const bool cache_decode = (cpu.sr[CSR_MENVCFG] & (1ull << 62)) == 0;
#else
  const bool cache_decode = true;
#endif
  icache_entry_t *e = icache_slot(s->pc);
  if (cache_decode && icache_hit(e, s->pc))
  {
    s->isa.inst = e->inst;
    s->snpc = s->pc + e->ilen;
  }
  else
  {
    s->isa.inst = inst_fetch(&s->snpc, 4); // advances snpc to pc+4
  }
  cpu.inst = s->isa.inst;
  if (nemu_md_instruction && !nemu_md_instruction(s->isa.inst)) return 0;

  vaddr_t fill_pc = s->pc; // decode_exec will clobber s->pc <- dnpc
  const uint32_t fetch_epoch = icache_epoch;
  const bool atomic_instruction = (s->isa.inst & 0x7f) == 0x2f;
  if (atomic_instruction) cpu_bus_lock();
  int ret = decode_exec(s);
  if (atomic_instruction) cpu_bus_unlock();
  // A CSR write, xRET, trap or fence can invalidate the context that
  // authorized this fetch. Never resurrect its decode in the new epoch.
  if (cache_decode && fetch_epoch == icache_epoch && !icache_hit(e, fill_pc))
  {
    icache_fill(e, fill_pc, s->isa.inst, (uint16_t)(s->snpc - fill_pc));
  }
  return ret;
}
