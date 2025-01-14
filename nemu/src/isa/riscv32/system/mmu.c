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

#include <isa.h>
#include <isa-def.h>
#include <memory/vaddr.h>
#include <memory/paddr.h>

// !important: only Little-Endian is supported
typedef union // 32-bit vaddr for page table walk
{
  struct
  {
    word_t offset : 12;
    word_t vpn0 : 10;
    word_t vpn1 : 10;
  } vaddr;
  word_t val;
} addr_t;

int isa_mmu_check(vaddr_t vaddr, int len, int type)
{
  csr_t csr = {.val = cpu.sr[CSR_SATP]};
  if ((csr.satp.mode) == 0)
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
  word_t ppn = reg.satp.ppn;
  word_t vpn1 = addr.vaddr.vpn1;
  word_t vpn0 = addr.vaddr.vpn0;
  word_t offset = addr.vaddr.offset;
  word_t l1_pg = (ppn << 12) + (vpn1 << 2);
  // printf("ppn: %x, vpn1: %x, vpn0: %x, offset: %x, l0_pg: %x, ", ppn, vpn1, vpn0, offset, l1_pg);
  word_t l0_pn = paddr_read(l1_pg, 4);
  word_t l0_pg = ((l0_pn << 2) & ~0xfff) + (vpn0 << 2);
  // printf("l0_pn: %x, l0_pg: %x, ", l0_pn, l0_pg);
  word_t pn = paddr_read(l0_pg, 4);
  word_t paddr = ((pn << 2) & ~0xfff) | offset;
  // printf("pn: %x, paddr: %x, vaddr: %x\n", pn, paddr, vaddr);
  return paddr;
}
