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
#include <isa.h>
#include <isa-def.h>
#include <memory/vaddr.h>
#include <memory/paddr.h>

extern jmp_buf exec_jmp_buf;
extern int cause;

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
  if ((cpu.priv == PRV_M) &&
      (((cpu.sr[CSR_MSTATUS] & CSR_MSTATUS_MPRV) == 0) ||
       (type == MEM_TYPE_IFETCH)))
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
  // printf("vaddr: %x, vpn1: %x, vpn0: %x, ", vaddr, vpn[1], vpn[0]);
  for (int i = 1; i >= 0; i--)
  {
    word_t pte_addr = a + (vpn[i] * 4);
    if (pte_addr == 0)
    {
      cause = MCA_INS_PAG_FAU;
      longjmp(exec_jmp_buf, 1);
    }
    pte.val = paddr_read(pte_addr, 4);
    // printf("i: %x, pte_addr: %x, pte: %x, ", i, pte_addr, val.val);
    if (pte.pte.v == 0)
    {
      cause = MCA_INS_PAG_FAU;
      longjmp(exec_jmp_buf, 2);
    }
    if ((pte.pte.r == 1) || (pte.pte.x == 1))
    {
      if (i > 0 && ((pte.pte.ppn0 & 0x1) != 0))
      {
        cause = MCA_INS_PAG_FAU;
        longjmp(exec_jmp_buf, 3);
      }
      if (i > 0)
      {
        // If i>0, then this is a superpage translation and
        // pa.ppn[i-1:0] = va.vpn[i-1:0].
        pte.pte.ppn0 = vpn[0];
      }
      break;
    }
    if ((i - 1) < -1)
    {
      cause = MCA_INS_PAG_FAU;
      longjmp(exec_jmp_buf, 4);
    }
    a = pte.pte_ppn.ppn * 4096;
  }
  // printf("ppn: %x, paddr: %x\n", val.pte_ppn.ppn, (val.pte_ppn.ppn * 4096) | offset);
  word_t paddr = (pte.pte_ppn.ppn * 4096) | offset;
  return paddr;
}
