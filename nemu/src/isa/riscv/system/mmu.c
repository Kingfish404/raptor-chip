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
#include <isa-def.h>
#include <memory/vaddr.h>
#include <memory/paddr.h>

extern jmp_buf exec_jmp_buf;
extern int cause;

bool pmp_check(paddr_t addr, int size, uint32_t priv,
               bool op_r, bool op_w, bool op_x);
uint32_t pmp_effective_priv_ls(void);

#define SV32_MODE 1
#define SV39_MODE 8

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
    word_t ppn1 : 10;
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
    word_t ppn : 20;
  } pte_ppn;
  word_t val;
} addr_t;

int isa_mmu_check(vaddr_t vaddr, int len, int type)
{
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
/* Sv39 page table walk. paddr_t is 64-bit when PMEM64 is set; otherwise the
 * caller relies on guest physical addresses fitting in 32 bits (true for the
 * default 256 MiB DRAM at 0x80000000). */
static paddr_t sv39_translate(vaddr_t vaddr, int len, int type)
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
    nemu_longjmp(exec_jmp_buf, 12);
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
    if (pmp_check(pte_addr, 8, eff_priv, true, false, false))
    {
      cause = af_cause;
      nemu_longjmp(exec_jmp_buf, 25);
    }
    pte_val = paddr_read(pte_addr, 8);
    word_t v = pte_val & 1;
    word_t r = (pte_val >> 1) & 1;
    word_t w = (pte_val >> 2) & 1;
    word_t x = (pte_val >> 3) & 1;
    if (!v || (w && !r))
    {
      cause = pf_cause;
      nemu_longjmp(exec_jmp_buf, 2);
    }
    if (r || x)
    {
      break; /* leaf */
    }
    /* pointer to next level */
    if (level == 0)
    {
      cause = pf_cause;
      nemu_longjmp(exec_jmp_buf, 4);
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

  /* Misaligned superpage check */
  if (level > 0)
  {
    word_t mask = (1ULL << (9 * level)) - 1;
    if (ppn & mask)
    {
      cause = pf_cause;
      nemu_longjmp(exec_jmp_buf, 3);
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
        nemu_longjmp(exec_jmp_buf, 5);
      }
      if (mstatus_for_prm.mstatus.sum == 0)
      {
        cause = pf_cause;
        nemu_longjmp(exec_jmp_buf, 6);
      }
    }
  }
  else if (eff_priv == PRV_U)
  {
    if (!pte_u)
    {
      cause = pf_cause;
      nemu_longjmp(exec_jmp_buf, 7);
    }
  }
  if (is_fetch && !pte_x)
  {
    cause = pf_cause;
    nemu_longjmp(exec_jmp_buf, 8);
  }
  if (is_read)
  {
    bool readable = pte_r || (mstatus_for_prm.mstatus.mxr && pte_x);
    if (!readable)
    {
      cause = pf_cause;
      nemu_longjmp(exec_jmp_buf, 9);
    }
  }
  if (is_cmo)
  {
    bool readable = pte_r || (mstatus_for_prm.mstatus.mxr && pte_x);
    if (!readable && !pte_w)
    {
      cause = pf_cause;
      nemu_longjmp(exec_jmp_buf, 9);
    }
  }
  if (is_write && !pte_w)
  {
    cause = pf_cause;
    nemu_longjmp(exec_jmp_buf, 10);
  }

#ifdef CONFIG_RV_SVADE
  if (!pte_a || (is_write && !pte_d))
  {
    cause = pf_cause;
    nemu_longjmp(exec_jmp_buf, 11);
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
    paddr = ((ppn & ~0x3ffffULL) << 12) | (vpn[1] << 12) | (vpn[0] << 12) | offset;
  }
  return (paddr_t)paddr;
}
#endif

// a.k.a. Page Table Walk
paddr_t isa_mmu_translate(vaddr_t vaddr, int len, int type)
{
  csr_t reg = {.val = cpu.sr[CSR_SATP]};
  addr_t addr = {.val = vaddr};
#ifdef CONFIG_ISA64
  if (reg.satp.mode == SV39_MODE)
  {
    return sv39_translate(vaddr, len, type);
  }
#endif
  if (reg.satp.mode == 0 || reg.satp.mode != SV32_MODE)
  {
    return addr.val;
  }

  word_t offset = addr.vaddr.offset;
  word_t vpn[2] = {addr.vaddr.vpn0, addr.vaddr.vpn1};
  word_t a = reg.satp.ppn * 4096;
  addr_t pte = {.val = 0};
  csr_t mstatus_for_prm = {.val = cpu.sr[CSR_MSTATUS]};
  uint32_t eff_priv = (type == MEM_TYPE_IFETCH)
                          ? cpu.priv
                          : pmp_effective_priv_ls();
  int pf_cause = type == MEM_TYPE_IFETCH
                     ? MCA_INS_PAG_FAU
                     : (type == MEM_TYPE_READ ? MCA_LOA_PAG_FAU : MCA_STO_PAG_FAU);
  word_t pte_addr = 0;
  for (int i = 1; i >= 0; i--)
  {
    pte_addr = a + (vpn[i] * 4);
    if (pte_addr == 0)
    {
      cause = pf_cause;
      nemu_longjmp(exec_jmp_buf, 1);
    }
    {
      uint32_t ptw_priv = (type == MEM_TYPE_IFETCH) ? cpu.priv : pmp_effective_priv_ls();
      if (pmp_check(pte_addr, 4, ptw_priv, true, false, false))
      {
        cause = type == MEM_TYPE_IFETCH
                    ? MCA_INS_ACC_FAU
                    : (type == MEM_TYPE_READ ? MCA_LOA_ACC_FAU : MCA_STO_ACC_FAU);
        nemu_longjmp(exec_jmp_buf, 25);
      }
    }
    pte.val = paddr_read(pte_addr, 4);
    if (pte.pte.v == 0 || (pte.pte.w == 1 && pte.pte.r == 0))
    {
      cause = pf_cause;
      nemu_longjmp(exec_jmp_buf, 2);
    }
    if (pte.pte.r == 1 || pte.pte.x == 1)
    {
      if (i > 0 && (pte.pte.ppn0 & 0x3ff) != 0)
      {
        cause = pf_cause;
        nemu_longjmp(exec_jmp_buf, 3);
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
      nemu_longjmp(exec_jmp_buf, 2);
    }
    if (i == 0)
    {
      cause = pf_cause;
      nemu_longjmp(exec_jmp_buf, 4);
    }
    a = pte.pte_ppn.ppn * 4096;
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
        nemu_longjmp(exec_jmp_buf, 5);
      }
      if (mstatus_for_prm.mstatus.sum == 0)
      {
        cause = pf_cause;
        nemu_longjmp(exec_jmp_buf, 6);
      }
    }
  }
  else if (eff_priv == PRV_U)
  {
    if (pte.pte.u == 0)
    {
      cause = pf_cause;
      nemu_longjmp(exec_jmp_buf, 7);
    }
  }

  if (is_fetch && pte.pte.x == 0)
  {
    cause = pf_cause;
    nemu_longjmp(exec_jmp_buf, 8);
  }
  if (is_read)
  {
    bool readable = (pte.pte.r == 1) ||
                    (mstatus_for_prm.mstatus.mxr == 1 && pte.pte.x == 1);
    if (!readable)
    {
      cause = pf_cause;
      nemu_longjmp(exec_jmp_buf, 9);
    }
  }
  if (is_cmo)
  {
    bool readable = (pte.pte.r == 1) ||
                    (mstatus_for_prm.mstatus.mxr == 1 && pte.pte.x == 1);
    if (!readable && pte.pte.w == 0)
    {
      cause = pf_cause;
      nemu_longjmp(exec_jmp_buf, 9);
    }
  }
  if (is_write && pte.pte.w == 0)
  {
    cause = pf_cause;
    nemu_longjmp(exec_jmp_buf, 10);
  }

#ifdef CONFIG_RV_SVADE
  if (pte.pte.a == 0 || (is_write && pte.pte.d == 0))
  {
    cause = pf_cause;
    nemu_longjmp(exec_jmp_buf, 11);
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

  return (pte.pte_ppn.ppn * 4096) | offset;
}
