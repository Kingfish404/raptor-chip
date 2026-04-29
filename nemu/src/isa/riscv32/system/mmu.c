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

/* PMP check (implemented in system/pmp.c).  PTE reads always use M-mode
 * privilege since they are performed by the hart for its own translation.
 * The faulting cause is access-fault of the access type being translated. */
bool pmp_check(paddr_t addr, int size, uint32_t priv,
               bool op_r, bool op_w, bool op_x);
uint32_t pmp_effective_priv_ls(void);

// !important: only Little-Endian is supported
typedef union // 32-bit vaddr for page table walk
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
  // Effective privilege for translation decision:
  //   fetches always use cpu.priv;
  //   loads/stores in M-mode with MPRV=1 use MPP instead.
  uint32_t eff_priv = (type == MEM_TYPE_IFETCH)
                          ? cpu.priv
                          : pmp_effective_priv_ls();
  if (eff_priv == PRV_M)
  {
    return MMU_DIRECT;
  }
  return MMU_TRANSLATE;
}

// a.k.a. Page Table Walk
paddr_t isa_mmu_translate(vaddr_t vaddr, int len, int type)
{
  csr_t reg = {.val = cpu.sr[CSR_SATP]};
  addr_t addr = {.val = vaddr};
  if ((reg.satp.mode) == 0)
  {
    return addr.val;
  }
  // sv32
  word_t offset = addr.vaddr.offset;

  word_t vpn[2] = {addr.vaddr.vpn0, addr.vaddr.vpn1};
  word_t a = reg.satp.ppn * 4096;
  addr_t pte = {.val = 0};
  // Effective privilege for permission checks: fetches always use cpu.priv;
  // explicit loads/stores use MPRV/MPP override if in M with MPRV=1.
  csr_t mstatus_for_prm = {.val = cpu.sr[CSR_MSTATUS]};
  uint32_t eff_priv = (type == MEM_TYPE_IFETCH)
                          ? cpu.priv
                          : pmp_effective_priv_ls();
  int pf_cause = type == MEM_TYPE_IFETCH
                     ? MCA_INS_PAG_FAU
                     : (type == MEM_TYPE_READ ? MCA_LOA_PAG_FAU : MCA_STO_PAG_FAU);
  int i;
  word_t pte_addr = 0;
  for (i = 1; i >= 0; i--)
  {
    pte_addr = a + (vpn[i] * 4);
    if (pte_addr == 0)
    {
      cause = pf_cause;
      longjmp(exec_jmp_buf, 1);
    }
    pte.val = paddr_read(pte_addr, 4);
    {
      uint32_t ptw_priv = (type == MEM_TYPE_IFETCH) ? cpu.priv : pmp_effective_priv_ls();
      if (pmp_check(pte_addr, 4, ptw_priv, true, false, false))
      {
        cause = type == MEM_TYPE_IFETCH
                    ? MCA_INS_ACC_FAU
                    : (type == MEM_TYPE_READ ? MCA_LOA_ACC_FAU : MCA_STO_ACC_FAU);
        longjmp(exec_jmp_buf, 25);
      }
    }
    // Invalid PTE: v=0, or (w=1 && r=0) reserved encoding.
    if (pte.pte.v == 0 || (pte.pte.w == 1 && pte.pte.r == 0))
    {
      cause = pf_cause;
      longjmp(exec_jmp_buf, 2);
    }
    if ((pte.pte.r == 1) || (pte.pte.x == 1))
    {
      if (i > 0 && ((pte.pte.ppn0 & 0x3ff) != 0))
      {
        // Misaligned superpage: pte.ppn[i-1:0] != 0 must fault.
        cause = pf_cause;
        longjmp(exec_jmp_buf, 3);
      }
      if (i > 0)
      {
        // Superpage translation: pa.ppn[i-1:0] = va.vpn[i-1:0].
        pte.pte.ppn0 = vpn[0];
      }
      break;
    }
    // Non-leaf PTE: must not set u/a/d/g per spec.
    if (pte.pte.u == 1 || pte.pte.a == 1 || pte.pte.d == 1)
    {
      cause = pf_cause;
      longjmp(exec_jmp_buf, 2);
    }
    if (i == 0)
    {
      // No leaf found at lowest level.
      cause = pf_cause;
      longjmp(exec_jmp_buf, 4);
    }
    a = pte.pte_ppn.ppn * 4096;
  }

  // Permission checks (leaf pte).
  // - U-bit vs. effective privilege:
  //     fetch: S-mode cannot execute U-pages (regardless of SUM).
  //     load/store from S-mode: if pte.u=1, require SUM=1.
  //     U-mode: pte.u must be 1.
  bool is_fetch = (type == MEM_TYPE_IFETCH);
  bool is_write = (type == MEM_TYPE_WRITE);
  bool is_read  = (type == MEM_TYPE_READ);
  if (eff_priv == PRV_S)
  {
    if (pte.pte.u == 1)
    {
      if (is_fetch)
      {
        cause = pf_cause;
        longjmp(exec_jmp_buf, 5);
      }
      if (mstatus_for_prm.mstatus.sum == 0)
      {
        cause = pf_cause;
        longjmp(exec_jmp_buf, 6);
      }
    }
  }
  else if (eff_priv == PRV_U)
  {
    if (pte.pte.u == 0)
    {
      cause = pf_cause;
      longjmp(exec_jmp_buf, 7);
    }
  }

  // R/W/X permission check (with MXR: X implies R on loads when MXR=1).
  if (is_fetch && pte.pte.x == 0)
  {
    cause = pf_cause;
    longjmp(exec_jmp_buf, 8);
  }
  if (is_read)
  {
    bool readable = (pte.pte.r == 1) ||
                    (mstatus_for_prm.mstatus.mxr == 1 && pte.pte.x == 1);
    if (!readable)
    {
      cause = pf_cause;
      longjmp(exec_jmp_buf, 9);
    }
  }
  if (is_write && pte.pte.w == 0)
  {
    cause = pf_cause;
    longjmp(exec_jmp_buf, 10);
  }

  // A/D-bit handling.
  //   CONFIG_RV_SVADE  : Svade-style hardware faults on A=0 or write+D=0
  //                      (matches sail / riscv-arch-test vm_sv32 suite).
  //   default (Svadu)  : hardware atomically sets A (and D for stores)
  //                      and writes the PTE back, never raising a fault.
  //                      Required for Linux 6.x boot (kernel never sets A/D
  //                      explicitly, relies on hw update).
#ifdef CONFIG_RV_SVADE
  if (pte.pte.a == 0 || (is_write && pte.pte.d == 0))
  {
    cause = pf_cause;
    longjmp(exec_jmp_buf, 11);
  }
#else
  {
    bool need_update = false;
    if (pte.pte.a == 0) { pte.pte.a = 1; need_update = true; }
    if (is_write && pte.pte.d == 0) { pte.pte.d = 1; need_update = true; }
    if (need_update && pte_addr != 0)
    {
      paddr_write(pte_addr, 4, pte.val);
    }
  }
#endif

  word_t paddr = (pte.pte_ppn.ppn * 4096) | offset;
  return paddr;
}
