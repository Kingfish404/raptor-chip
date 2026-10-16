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
#include <stdlib.h>
#include <isa.h>
#include <cpu/thread.h>
#include <isa-def.h>
#include <isa-extensions.h>
#include <memory/vaddr.h>
#include <memory/trap.h>
#include <memory/paddr.h>

bool pmp_check(paddr_t addr, int size, uint32_t priv,
               bool op_r, bool op_w, bool op_x);

#define SV32_MODE 1
#define SV39_MODE 8

// Implicit page-table reads are supported by physical memory, not devices.
// Use this reference platform's backing-region map (also includes virt ROM),
// independently of the translated leaf's permissions or memory type.
static bool ptw_memory_readable(paddr_t addr, unsigned size)
{
  return (addr & (size - 1)) == 0 && paddr_is_memory_span(addr, size);
}

typedef union
{
  struct
  {
    word_t offset : 12;
    word_t vpn0 : 10;
    word_t vpn1 : 10;
  } vaddr;
  struct
  {
    word_t v : 1;
    word_t r : 1;
    word_t w : 1;
    word_t x : 1;
    word_t u : 1;
    word_t g : 1;
    word_t a : 1;
    word_t d : 1;
    word_t psw : 2;
    word_t ppn0 : 10;
    word_t ppn1 : 12;
  } pte;
  struct
  {
    word_t v : 1;
    word_t r : 1;
    word_t w : 1;
    word_t x : 1;
    word_t u : 1;
    word_t g : 1;
    word_t a : 1;
    word_t d : 1;
    word_t psw : 2;
    word_t ppn : 22;
  } pte_ppn;
  word_t val;
} addr_t;

int isa_mmu_check(vaddr_t vaddr, int len, int type)
{
#ifdef CONFIG_RV64
  if (type == MEM_TYPE_IFETCH ? cpu.virt : riscv_data_virtual_mode())
    return MMU_TRANSLATE;
#endif
  csr_t csr = {.val = cpu.sr[CSR_SATP]};
  if (csr.satp.mode == 0)
  {
    return MMU_DIRECT;
  }
  uint32_t eff_priv = (type == MEM_TYPE_IFETCH)
                          ? cpu.priv
                          : pmp_effective_priv_ls();
  if (eff_priv == PRV_M)
  {
    return MMU_DIRECT;
  }
#ifdef CONFIG_ISA64
  if (csr.satp.mode == SV39_MODE)
  {
    return MMU_TRANSLATE;
  }
#endif
  return csr.satp.mode == SV32_MODE ? MMU_TRANSLATE : MMU_DIRECT;
}

#ifdef CONFIG_ISA64
int riscv_gstage_translate(paddr_t guest_address, bool store, bool execute_access,
                           bool cmo, bool implicit, paddr_t *physical_address, uint8_t *pbmt_out)
{
  if (pbmt_out) *pbmt_out = 0;
  uint64_t hgatp = cpu.sr[CSR_HGATP];
  unsigned mode = hgatp >> 60;
  if (mode == 0)
  {
    *physical_address = guest_address;
    return RISCV_GSTAGE_OK;
  }
  if (mode != SV39_MODE || guest_address >> 41)
    return RISCV_GSTAGE_PAGE_FAULT;

  uint64_t vpn[3] = {
      (guest_address >> 12) & 0x1ff,
      (guest_address >> 21) & 0x1ff,
      (guest_address >> 30) & 0x7ff,
  };
  paddr_t table = (hgatp & ((UINT64_C(1) << 44) - 1)) << 12;
  for (int level = 2; level >= 0; level--)
  {
    paddr_t pte_address = table + vpn[level] * 8;
    if (!ptw_memory_readable(pte_address, 8) ||
        pmp_check(pte_address, 8, PRV_S, true, false, false))
      return RISCV_GSTAGE_ACCESS_FAULT;
    uint64_t pte = paddr_read(pte_address, 8);
    bool valid = pte & 1;
    bool read = pte & 2;
    bool write = pte & 4;
    bool execute = pte & 8;
    bool user = pte & 16;
    bool accessed = pte & 64;
    bool dirty = pte & 128;
    unsigned pbmt = (pte >> 61) & 3;
    bool napot = pte >> 63;
    uint64_t ppn = (pte >> 10) & ((UINT64_C(1) << 44) - 1);
    bool pbmte = (cpu.sr[CSR_MENVCFG] >> 62) & 1;
    if (!valid || (write && !read) || (pte & (UINT64_C(0x7f) << 54)) ||
        pbmt == 3 || (pbmt && !pbmte) ||
        (napot && (!(riscv_isa_extensions & NEMU_ISA_EXT_SVNAPOT) || level != 0 ||
                   !(read || execute) || (ppn & 15) != 8)))
      return RISCV_GSTAGE_PAGE_FAULT;
    if (!read && !execute)
    {
      if (level == 0 || (pte & (UINT64_C(3) << 61)) || napot || (pte & 0xd0))
        return RISCV_GSTAGE_PAGE_FAULT;
      table = ppn << 12;
      continue;
    }
    bool permitted = cmo ? (write || read || (execute &&
        (cpu.sr[CSR_MSTATUS] & ((word_t)1 << 19)))) : store ? write : (execute_access ? execute :
        (read || (execute && !implicit &&
            (cpu.sr[CSR_MSTATUS] & ((word_t)1 << 19)))));
    if (!user || !permitted)
      return RISCV_GSTAGE_PAGE_FAULT;
    if (napot) ppn = (ppn & ~UINT64_C(15)) | (vpn[0] & 15);
    uint64_t low_mask = (UINT64_C(1) << (9 * level)) - 1;
    if (ppn & low_mask) return RISCV_GSTAGE_PAGE_FAULT;
#ifdef CONFIG_RV_SVADE
    if (!accessed || (store && !dirty)) return RISCV_GSTAGE_PAGE_FAULT;
#else
    if (!accessed || (store && !dirty))
    {
      if (pmp_check(pte_address, 8, PRV_S, false, true, false))
        return RISCV_GSTAGE_ACCESS_FAULT;
      paddr_write(pte_address, 8, pte | 64 | (store ? 128 : 0));
    }
#endif
    ppn = (ppn & ~low_mask) | ((guest_address >> 12) & low_mask);
    *physical_address = (ppn << 12) | (guest_address & 0xfff);
    if (pbmt_out) *pbmt_out = pbmt;
    return RISCV_GSTAGE_OK;
  }
  return RISCV_GSTAGE_PAGE_FAULT;
}

int riscv_vstage_translate(vaddr_t guest_address, bool store, bool execute_access,
                           bool virtual_supervisor, bool cmo,
                           paddr_t *guest_physical_address, paddr_t *fault_address,
                           bool *page_table_write, uint8_t *pbmt_out)
{
  if (pbmt_out) *pbmt_out = 0;
  uint64_t vsatp = cpu.sr[CSR_VSATP];
  unsigned mode = vsatp >> 60;
  if (mode == 0)
  {
    *guest_physical_address = guest_address;
    return RISCV_VSTAGE_OK;
  }
  uint64_t high = guest_address >> 38;
  if (mode != SV39_MODE || (high != 0 && high != (UINT64_MAX >> 38)))
    return RISCV_VSTAGE_PAGE_FAULT;

  uint64_t vpn[3] = {
      (guest_address >> 12) & 0x1ff,
      (guest_address >> 21) & 0x1ff,
      (guest_address >> 30) & 0x1ff,
  };
  paddr_t table = (vsatp & ((UINT64_C(1) << 44) - 1)) << 12;
  for (int level = 2; level >= 0; level--)
  {
    paddr_t guest_pte_address = table + vpn[level] * 8;
    paddr_t pte_address = 0;
    int status = riscv_gstage_translate(guest_pte_address, false, false, false, true,
                                        &pte_address, NULL);
    if (status != RISCV_GSTAGE_OK)
    {
      *fault_address = guest_pte_address;
      *page_table_write = false;
      return status == RISCV_GSTAGE_PAGE_FAULT ? RISCV_VSTAGE_GUEST_PAGE_FAULT :
          RISCV_VSTAGE_ACCESS_FAULT;
    }
    if (!ptw_memory_readable(pte_address, 8) ||
        pmp_check(pte_address, 8, PRV_S, true, false, false))
      return RISCV_VSTAGE_ACCESS_FAULT;

    uint64_t pte = paddr_read(pte_address, 8);
    bool read = pte & 2;
    bool write = pte & 4;
    bool execute = pte & 8;
    bool user = pte & 16;
    bool napot = pte >> 63;
    uint64_t ppn = (pte >> 10) & ((UINT64_C(1) << 44) - 1);
    unsigned pbmt = (pte >> 61) & 3;
    bool pbmte = (cpu.sr[CSR_HENVCFG] >> 62) & (cpu.sr[CSR_MENVCFG] >> 62) & 1;
    if (!(pte & 1) || (write && !read) || (pte & (UINT64_C(0x7f) << 54)) ||
        pbmt == 3 || (pbmt && !pbmte) ||
        (napot && (!(riscv_isa_extensions & NEMU_ISA_EXT_SVNAPOT) ||
                          level != 0 || !(read || execute) || (ppn & 15) != 8)))
      return RISCV_VSTAGE_PAGE_FAULT;
    if (!read && !execute)
    {
      if (level == 0 || pbmt || napot || (pte & 0xd0)) return RISCV_VSTAGE_PAGE_FAULT;
      table = ppn << 12;
      continue;
    }

    bool sum = (cpu.sr[CSR_VSSTATUS] >> 18) & 1;
    bool mxr = ((cpu.sr[CSR_VSSTATUS] | cpu.sr[CSR_MSTATUS]) >> 19) & 1;
    bool permitted = cmo ? (write || read || (execute && mxr)) :
        store ? write : (execute_access ? execute : (read || (execute && mxr)));
    if (!permitted || (virtual_supervisor ? (user && (!sum || execute_access)) : !user))
      return RISCV_VSTAGE_PAGE_FAULT;
    if (napot) ppn = (ppn & ~UINT64_C(15)) | (vpn[0] & 15);
    uint64_t low_mask = (UINT64_C(1) << (9 * level)) - 1;
    if (ppn & low_mask) return RISCV_VSTAGE_PAGE_FAULT;
#ifdef CONFIG_RV_SVADE
    if (!(pte & 64) || (store && !(pte & 128))) return RISCV_VSTAGE_PAGE_FAULT;
#else
    if (!(pte & 64) || (store && !(pte & 128)))
    {
      paddr_t pte_write_address = 0;
      status = riscv_gstage_translate(guest_pte_address, true, false, false, true,
                                      &pte_write_address, NULL);
      if (status != RISCV_GSTAGE_OK)
      {
        *fault_address = guest_pte_address;
        *page_table_write = true;
        return status == RISCV_GSTAGE_PAGE_FAULT ? RISCV_VSTAGE_GUEST_PAGE_FAULT :
            RISCV_VSTAGE_ACCESS_FAULT;
      }
      if (!ptw_memory_readable(pte_write_address, 8) ||
          pmp_check(pte_write_address, 8, PRV_S, false, true, false))
        return RISCV_VSTAGE_ACCESS_FAULT;
      paddr_write(pte_write_address, 8, pte | 64 | (store ? 128 : 0));
    }
#endif
    ppn = (ppn & ~low_mask) | ((guest_address >> 12) & low_mask);
    *guest_physical_address = (ppn << 12) | (guest_address & 0xfff);
    if (pbmt_out) *pbmt_out = pbmt;
    return RISCV_VSTAGE_OK;
  }
  return RISCV_VSTAGE_PAGE_FAULT;
}

/* Sv39 page table walk. paddr_t is 64-bit when PMEM64 is set; otherwise the
 * caller relies on guest physical addresses fitting in 32 bits (true for the
 * default 256 MiB DRAM at 0x80000000). */
static paddr_t sv39_translate(vaddr_t vaddr, int len, int type, uint8_t *out_pbmt)
{
  csr_t reg = {.val = cpu.sr[CSR_SATP]};
  csr_t mstatus_for_prm = {.val = cpu.sr[CSR_MSTATUS]};
  uint32_t eff_priv = (type == MEM_TYPE_IFETCH)
                          ? cpu.priv
                          : pmp_effective_priv_ls();
  int pf_cause = type == MEM_TYPE_IFETCH
                     ? MCA_INS_PAG_FAU
                     : (type == MEM_TYPE_READ ? MCA_LOA_PAG_FAU : MCA_STO_PAG_FAU);
  int af_cause = type == MEM_TYPE_IFETCH
                     ? MCA_INS_ACC_FAU
                     : (type == MEM_TYPE_READ ? MCA_LOA_ACC_FAU : MCA_STO_ACC_FAU);

  /* Canonical address check: bits [63:39] must equal bit 38. */
  word_t high = vaddr >> 38;
  if (high != 0 && high != ((word_t)-1 >> 38))
  {
    cause = pf_cause;
    nemu_memory_longjmp(12);
  }

  word_t offset = vaddr & 0xfff;
  word_t vpn[3];
  vpn[0] = (vaddr >> 12) & 0x1ff;
  vpn[1] = (vaddr >> 21) & 0x1ff;
  vpn[2] = (vaddr >> 30) & 0x1ff;

  word_t a = ((word_t)reg.satp.ppn) << 12;
  word_t pte_val = 0;
  word_t pte_addr = 0;
  int level = 2;
  for (level = 2; level >= 0; level--)
  {
    pte_addr = a + vpn[level] * 8;
    if (!ptw_memory_readable(pte_addr, 8)
        || pmp_check(pte_addr, 8, PRV_S, true, false, false))
    {
      cause = af_cause;
      nemu_memory_longjmp(25);
    }
    pte_val = paddr_read(pte_addr, 8);
    word_t v = pte_val & 1;
    word_t r = (pte_val >> 1) & 1;
    word_t w = (pte_val >> 2) & 1;
    word_t x = (pte_val >> 3) & 1;
    const unsigned pbmt = (unsigned)((pte_val >> 61) & 3);
    const bool napot = (pte_val >> 63) != 0;
    const bool pbmte = ((cpu.sr[CSR_MENVCFG] >> 62) & 1) != 0;
    const bool reserved = (pte_val & (0x7full << 54)) != 0
        || (napot && (!(riscv_isa_extensions & NEMU_ISA_EXT_SVNAPOT) || level != 0
                      || !(r || x) || ((pte_val >> 10) & 15) != 8))
        || pbmt == 3 || (pbmt != 0 && (!pbmte || !(r || x)));
    if (!v || (w && !r) || reserved)
    {
      cause = pf_cause;
      nemu_memory_longjmp(2);
    }
    if (r || x)
    {
      break; /* leaf */
    }
    /* Non-leaf G is legal; D/A/U are reserved. This reference flushes
     * its whole software TLB and does not need to retain global tags. */
    if (pte_val & (word_t)0xd0)
    {
      cause = pf_cause;
      nemu_memory_longjmp(2);
    }
    /* pointer to next level */
    if (level == 0)
    {
      cause = pf_cause;
      nemu_memory_longjmp(4);
    }
    word_t ppn_next = (pte_val >> 10) & ((1ULL << 44) - 1);
    a = ppn_next << 12;
  }

  word_t pte_r = (pte_val >> 1) & 1;
  word_t pte_w = (pte_val >> 2) & 1;
  word_t pte_x = (pte_val >> 3) & 1;
  word_t pte_u = (pte_val >> 4) & 1;
  word_t pte_a = (pte_val >> 6) & 1;
  word_t pte_d = (pte_val >> 7) & 1;
  word_t ppn = (pte_val >> 10) & ((1ULL << 44) - 1);
  if (pte_val >> 63) ppn = (ppn & ~15ULL) | (vpn[0] & 15);

  /* Misaligned superpage check */
  if (level > 0)
  {
    word_t mask = (1ULL << (9 * level)) - 1;
    if (ppn & mask)
    {
      cause = pf_cause;
      nemu_memory_longjmp(3);
    }
  }

  bool is_fetch = (type == MEM_TYPE_IFETCH);
  bool is_write = (type == MEM_TYPE_WRITE);
  bool is_read = (type == MEM_TYPE_READ);
  bool is_cmo = (type == MEM_TYPE_CMO);
  if (eff_priv == PRV_S)
  {
    if (pte_u)
    {
      if (is_fetch)
      {
        cause = pf_cause;
        nemu_memory_longjmp(5);
      }
      if (mstatus_for_prm.mstatus.sum == 0)
      {
        cause = pf_cause;
        nemu_memory_longjmp(6);
      }
    }
  }
  else if (eff_priv == PRV_U)
  {
    if (!pte_u)
    {
      cause = pf_cause;
      nemu_memory_longjmp(7);
    }
  }
  if (is_fetch && !pte_x)
  {
    cause = pf_cause;
    nemu_memory_longjmp(8);
  }
  if (is_read)
  {
    bool readable = pte_r || (mstatus_for_prm.mstatus.mxr && pte_x);
    if (!readable)
    {
      cause = pf_cause;
      nemu_memory_longjmp(9);
    }
  }
  if (is_cmo)
  {
    bool readable = pte_r || (mstatus_for_prm.mstatus.mxr && pte_x);
    if (!readable && !pte_w)
    {
      cause = pf_cause;
      nemu_memory_longjmp(9);
    }
  }
  if (is_write && !pte_w)
  {
    cause = pf_cause;
    nemu_memory_longjmp(10);
  }

#ifdef CONFIG_RV_SVADE
  if (!pte_a || (is_write && !pte_d))
  {
    cause = pf_cause;
    nemu_memory_longjmp(11);
  }
#else
  {
    bool need_update = false;
    word_t new_pte = pte_val;
    if (!pte_a)
    {
      new_pte |= (1ULL << 6);
      need_update = true;
    }
    if (is_write && !pte_d)
    {
      new_pte |= (1ULL << 7);
      need_update = true;
    }
    if (need_update)
    {
      paddr_write(pte_addr, 8, new_pte);
    }
  }
#endif

  /* Form physical address, handling superpages. */
  word_t paddr;
  if (level == 0)
  {
    paddr = (ppn << 12) | offset;
  }
  else if (level == 1)
  {
    paddr = ((ppn & ~0x1ffULL) << 12) | (vpn[0] << 12) | offset;
  }
  else /* level == 2 */
  {
    paddr = ((ppn & ~0x3ffffULL) << 12) | (vpn[1] << 21) | (vpn[0] << 12) | offset;
  }
  if (out_pbmt != NULL) *out_pbmt = (uint8_t)((pte_val >> 61) & 3);
  return (paddr_t)paddr;
}
#endif

// a.k.a. Page Table Walk
static paddr_t mmu_translate_unlocked(vaddr_t vaddr, int len, int type, uint8_t *pbmt)
{
  if (pbmt != NULL) *pbmt = 0;
#ifdef CONFIG_RV64
  if (type == MEM_TYPE_IFETCH ? cpu.virt : riscv_data_virtual_mode())
  {
    const bool store = type == MEM_TYPE_WRITE;
    const bool execute_access = type == MEM_TYPE_IFETCH;
    const bool cmo = type == MEM_TYPE_CMO;
    const int page_fault = execute_access ? MCA_INS_PAG_FAU :
        (store || cmo ? MCA_STO_PAG_FAU : MCA_LOA_PAG_FAU);
    const int guest_fault = execute_access ? MCA_INS_GUEST_PAG_FAU :
        (store || cmo ? MCA_STO_GUEST_PAG_FAU : MCA_LOA_GUEST_PAG_FAU);
    const int access_fault = execute_access ? MCA_INS_ACC_FAU :
        (store || cmo ? MCA_STO_ACC_FAU : MCA_LOA_ACC_FAU);
    paddr_t guest_address = 0;
    paddr_t physical_address = 0;
    uint8_t vs_pbmt = 0;
    uint8_t g_pbmt = 0;
    riscv_h_fault_gpa = 0;
    riscv_h_fault_ptw = false;
    riscv_h_fault_write = false;
    int status = riscv_vstage_translate(vaddr, store, execute_access,
                                        pmp_effective_priv_ls() == PRV_S, cmo,
                                        &guest_address, &riscv_h_fault_gpa,
                                        &riscv_h_fault_write, &vs_pbmt);
    if (status != RISCV_VSTAGE_OK)
    {
      riscv_h_fault_ptw = status == RISCV_VSTAGE_GUEST_PAGE_FAULT;
      cause = status == RISCV_VSTAGE_PAGE_FAULT ? page_fault :
          (riscv_h_fault_ptw ? guest_fault : access_fault);
      nemu_memory_longjmp(12);
    }
    riscv_h_fault_gpa = guest_address;
    status = riscv_gstage_translate(guest_address, store, execute_access, cmo, false,
                                    &physical_address, &g_pbmt);
    if (status != RISCV_GSTAGE_OK)
    {
      cause = status == RISCV_GSTAGE_PAGE_FAULT ? guest_fault : access_fault;
      nemu_memory_longjmp(12);
    }
    if (pbmt != NULL) *pbmt = vs_pbmt ? vs_pbmt : g_pbmt;
    return physical_address;
  }
#endif
  csr_t reg = {.val = cpu.sr[CSR_SATP]};
  addr_t addr = {.val = vaddr};
#ifdef CONFIG_ISA64
  if (reg.satp.mode == SV39_MODE)
  {
    return sv39_translate(vaddr, len, type, pbmt);
  }
#endif
  if (reg.satp.mode == 0 || reg.satp.mode != SV32_MODE)
  {
    return addr.val;
  }

  word_t offset = addr.vaddr.offset;
  word_t vpn[2] = {addr.vaddr.vpn0, addr.vaddr.vpn1};
  // Unsigned 22-bit fields promote to signed int. Cast before shifting so
  // physical addresses above 2 GiB never invoke signed-overflow UB.
  paddr_t a = (paddr_t)reg.satp.ppn << 12;
  addr_t pte = {.val = 0};
  csr_t mstatus_for_prm = {.val = cpu.sr[CSR_MSTATUS]};
  uint32_t eff_priv = (type == MEM_TYPE_IFETCH)
                          ? cpu.priv
                          : pmp_effective_priv_ls();
  int pf_cause = type == MEM_TYPE_IFETCH
                     ? MCA_INS_PAG_FAU
                     : (type == MEM_TYPE_READ ? MCA_LOA_PAG_FAU : MCA_STO_PAG_FAU);
  paddr_t pte_addr = 0;
  for (int i = 1; i >= 0; i--)
  {
    pte_addr = a + (vpn[i] * 4);
    {
      if (!ptw_memory_readable(pte_addr, 4)
          || pmp_check(pte_addr, 4, PRV_S, true, false, false))
      {
        cause = type == MEM_TYPE_IFETCH
                    ? MCA_INS_ACC_FAU
                    : (type == MEM_TYPE_READ ? MCA_LOA_ACC_FAU : MCA_STO_ACC_FAU);
        nemu_memory_longjmp(25);
      }
    }
    pte.val = paddr_read(pte_addr, 4);
    if (pte.pte.v == 0 || (pte.pte.w == 1 && pte.pte.r == 0))
    {
      cause = pf_cause;
      nemu_memory_longjmp(2);
    }
    if (pte.pte.r == 1 || pte.pte.x == 1)
    {
      if (i > 0 && (pte.pte.ppn0 & 0x3ff) != 0)
      {
        cause = pf_cause;
        nemu_memory_longjmp(3);
      }
      if (i > 0)
      {
        pte.pte.ppn0 = vpn[0];
      }
      break;
    }
    if (pte.pte.u == 1 || pte.pte.a == 1 || pte.pte.d == 1)
    {
      cause = pf_cause;
      nemu_memory_longjmp(2);
    }
    if (i == 0)
    {
      cause = pf_cause;
      nemu_memory_longjmp(4);
    }
    a = (paddr_t)pte.pte_ppn.ppn << 12;
  }

  bool is_fetch = (type == MEM_TYPE_IFETCH);
  bool is_write = (type == MEM_TYPE_WRITE);
  bool is_read = (type == MEM_TYPE_READ);
  bool is_cmo = (type == MEM_TYPE_CMO);
  if (eff_priv == PRV_S)
  {
    if (pte.pte.u == 1)
    {
      if (is_fetch)
      {
        cause = pf_cause;
        nemu_memory_longjmp(5);
      }
      if (mstatus_for_prm.mstatus.sum == 0)
      {
        cause = pf_cause;
        nemu_memory_longjmp(6);
      }
    }
  }
  else if (eff_priv == PRV_U)
  {
    if (pte.pte.u == 0)
    {
      cause = pf_cause;
      nemu_memory_longjmp(7);
    }
  }

  if (is_fetch && pte.pte.x == 0)
  {
    cause = pf_cause;
    nemu_memory_longjmp(8);
  }
  if (is_read)
  {
    bool readable = (pte.pte.r == 1) ||
                    (mstatus_for_prm.mstatus.mxr == 1 && pte.pte.x == 1);
    if (!readable)
    {
      cause = pf_cause;
      nemu_memory_longjmp(9);
    }
  }
  if (is_cmo)
  {
    bool readable = (pte.pte.r == 1) ||
                    (mstatus_for_prm.mstatus.mxr == 1 && pte.pte.x == 1);
    if (!readable && pte.pte.w == 0)
    {
      cause = pf_cause;
      nemu_memory_longjmp(9);
    }
  }
  if (is_write && pte.pte.w == 0)
  {
    cause = pf_cause;
    nemu_memory_longjmp(10);
  }

#ifdef CONFIG_RV_SVADE
  if (pte.pte.a == 0 || (is_write && pte.pte.d == 0))
  {
    cause = pf_cause;
    nemu_memory_longjmp(11);
  }
#else
  {
    bool need_update = false;
    if (pte.pte.a == 0)
    {
      pte.pte.a = 1;
      need_update = true;
    }
    if (is_write && pte.pte.d == 0)
    {
      pte.pte.d = 1;
      need_update = true;
    }
    if (need_update && pte_addr != 0)
    {
      paddr_write(pte_addr, 4, pte.val);
    }
  }
#endif

  return ((paddr_t)pte.pte_ppn.ppn << 12) | offset;
}

paddr_t isa_mmu_translate_attrs(vaddr_t vaddr, int len, int type, uint8_t *pbmt)
{
  cpu_bus_lock();
  paddr_t physical = mmu_translate_unlocked(vaddr, len, type, pbmt);
  cpu_bus_unlock();
  return physical;
}

/* Preserve the existing PA-only API while access and software-TLB clients
 * migrate to carrying the attribute explicitly. */
paddr_t isa_mmu_translate(vaddr_t vaddr, int len, int type)
{
  return isa_mmu_translate_attrs(vaddr, len, type, NULL);
}
