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
#include <memory/paddr.h>
#include <memory/tlb.h>
#include <cpu/icache.h>

extern jmp_buf exec_jmp_buf;
extern int cause;

extern FILE *mem_trace;

/* PMP check (implemented in src/isa/<isa>/system/pmp.c) */
bool pmp_check(paddr_t addr, int size, uint32_t priv,
               bool op_r, bool op_w, bool op_x);
uint32_t pmp_effective_priv_ls(void);
extern word_t pmp_last_fault_addr;

word_t g_vaddr = 0;

/* Software TLB arrays: direct-mapped, separate per access type */
soft_tlb_entry_t soft_tlb_ifetch[SOFT_TLB_ENTRIES];
soft_tlb_entry_t soft_tlb_load[SOFT_TLB_ENTRIES];
soft_tlb_entry_t soft_tlb_store[SOFT_TLB_ENTRIES];

/* Start at 1 so the zero-initialized `epoch` field of a fresh entry never
 * appears "valid" before the first explicit refill. */
uint32_t soft_tlb_epoch = 1;

void soft_tlb_flush(void)
{
  /* Every event that invalidates an address translation (trap entry,
   * satp write, sfence.vma, paddr/pmp remap) also invalidates the
   * decoded-instruction cache: a stale entry would let us execute an
   * inst that the new mapping might not even fetchable, or worse,
   * skip a permission fault. Flush them together. */
  icache_flush();
  /* O(1) epoch bump. All previously-cached entries are filtered out by
   * the `epoch == soft_tlb_epoch` check inside soft_tlb_lookup. On the
   * (very rare) wrap to 0 we hard-reset all VPN tags to SOFT_TLB_INVALID_TAG
   * to make sure no stale entry from epoch 0 is mistaken as valid. */
  if (++soft_tlb_epoch == 0)
  {
    for (unsigned i = 0; i < SOFT_TLB_ENTRIES; i++)
    {
      soft_tlb_ifetch[i].vpn = SOFT_TLB_INVALID_TAG;
      soft_tlb_load[i].vpn = SOFT_TLB_INVALID_TAG;
      soft_tlb_store[i].vpn = SOFT_TLB_INVALID_TAG;
    }
    soft_tlb_epoch = 1;
  }
}

word_t get_paddr(vaddr_t addr, int len)
{
  paddr_t paddr = addr;
  if (paddr == 0)
  {
    cause = MCA_INS_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, 20);
  }
  // Used by LR/SC to compute the reservation address. These are loads/stores,
  // not instruction fetches, so use MEM_TYPE_READ semantics (R=1 needed). Using
  // MEM_TYPE_IFETCH here incorrectly required X=1 and faulted on every LR/SC
  // targeting a data page (kernel heap/stack/spinlocks), causing difftest
  // divergence vs the RTL which correctly classifies LR/SC as data ops.
  if (isa_mmu_check(addr, len, MEM_TYPE_READ) == MMU_DIRECT)
  {
    paddr = addr;
  }
  else
  {
    paddr = isa_mmu_translate(addr, len, MEM_TYPE_READ);
  }
  return paddr;
}

word_t vaddr_ifetch(vaddr_t addr, int len)
{
  g_vaddr = addr;
  paddr_t paddr = addr;
  bool mmu_on = false;
  if (isa_mmu_check(addr, len, MEM_TYPE_IFETCH) == MMU_DIRECT)
  {
    paddr = addr;
  }
  else
  {
    mmu_on = true;
    if (soft_tlb_lookup(soft_tlb_ifetch, addr, &paddr))
    {
      if (pmp_check(paddr, len, cpu.priv, false, false, true))
      {
        cause = MCA_INS_ACC_FAU;
        nemu_longjmp(exec_jmp_buf, 22);
      }
      return paddr_read(paddr, len);
    }
    paddr = isa_mmu_translate(addr, len, MEM_TYPE_IFETCH);
    soft_tlb_refill(soft_tlb_ifetch, addr, paddr);
  }
  if (!mmu_on && paddr == 0)
  {
    cause = MCA_INS_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, 20);
  }
  if (pmp_check(paddr, len, cpu.priv, false, false, true))
  {
    if (!mmu_on)
    {
      g_vaddr = pmp_last_fault_addr;
    }
    cause = MCA_INS_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, 22);
  }
  return paddr_read(paddr, len);
}

word_t vaddr_read(vaddr_t addr, int len)
{
  g_vaddr = addr;
  cpu.rvaddr = addr;
  cpu.rlen = len;
  /* Misaligned ordinary loads are allowed (Zicclsm). The rapt RTL LSU
   * splits misaligned beats via the MA_HI / LS_S_HI_V FSM, and the
   * spike-diff reference is configured with `zicclsm` so it permits
   * misaligned silently as well. Do NOT trap here. */
  if (mem_trace != NULL)
  {
    fprintf(mem_trace, FMT_WORD_NO_PREFIX "-%c\n", addr, 'r');
  }
  paddr_t paddr = addr;
  bool mmu_on = false;
  if (isa_mmu_check(addr, len, MEM_TYPE_READ) == MMU_DIRECT)
  {
    paddr = addr;
  }
  else
  {
    mmu_on = true;
    if (soft_tlb_lookup(soft_tlb_load, addr, &paddr))
    {
      if (pmp_check(paddr, len, pmp_effective_priv_ls(), true, false, false))
      {
        if (!mmu_on)
        {
          g_vaddr = pmp_last_fault_addr;
        }
        cause = MCA_LOA_ACC_FAU;
        nemu_longjmp(exec_jmp_buf, 23);
      }
      cpu.rpaddr = paddr;
      cpu.rdata = paddr_read(paddr, len);
      return cpu.rdata;
    }
    paddr = isa_mmu_translate(addr, len, MEM_TYPE_READ);
    soft_tlb_refill(soft_tlb_load, addr, paddr);
  }
  if (pmp_check(paddr, len, pmp_effective_priv_ls(), true, false, false))
  {
    if (!mmu_on)
    {
      g_vaddr = pmp_last_fault_addr;
    }
    cause = MCA_LOA_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, 23);
  }
  cpu.rpaddr = paddr;
  cpu.rdata = paddr_read(paddr, len);
  return cpu.rdata;
}

void vaddr_write(vaddr_t addr, int len, word_t data)
{
  g_vaddr = addr;
  cpu.vwaddr = addr;
  cpu.wdata = data;
  cpu.len = len;
  /* Misaligned ordinary stores are allowed (Zicclsm); see vaddr_read note. */
  if (mem_trace != NULL)
  {
    fprintf(mem_trace, FMT_WORD_NO_PREFIX "-%c\n", addr, 'w');
  }
  paddr_t paddr = 0;
  bool mmu_on = false;
  if (isa_mmu_check(addr, len, MEM_TYPE_WRITE) == MMU_DIRECT)
  {
    paddr = addr;
  }
  else
  {
    mmu_on = true;
    if (soft_tlb_lookup(soft_tlb_store, addr, &paddr))
    {
      if (pmp_check(paddr, len, pmp_effective_priv_ls(), false, true, false))
      {
        if (!mmu_on)
        {
          g_vaddr = pmp_last_fault_addr;
        }
        cause = MCA_STO_ACC_FAU;
        nemu_longjmp(exec_jmp_buf, 24);
      }
      cpu.pwaddr = paddr;
      paddr_write(paddr, len, data);
      if ((cpu.reservation & ~0x3) == (paddr & ~0x3))
      {
        cpu.reservation = 0;
      }
      return;
    }
    paddr = isa_mmu_translate(addr, len, MEM_TYPE_WRITE);
    soft_tlb_refill(soft_tlb_store, addr, paddr);
  }
  if (pmp_check(paddr, len, pmp_effective_priv_ls(), false, true, false))
  {
    if (!mmu_on)
    {
      g_vaddr = pmp_last_fault_addr;
    }
    cause = MCA_STO_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, 24);
  }
  cpu.pwaddr = paddr;
  paddr_write(paddr, len, data);
  if ((cpu.reservation & ~0x3) == (paddr & ~0x3))
  {
    cpu.reservation = 0;
  }
}

void vaddr_show(vaddr_t addr, int n)
{
  word_t data;
  word_t wsize = 4;
  for (int i = 0; i < (n / 4 + 1); i++)
  {
    if (i % 4 == 0)
    {
      if (i != 0)
      {
        printf("| ");
        for (size_t j = 0; j < wsize; j++)
        {
          data = vaddr_read(addr + (i - (3 - j) - 1) * wsize, 4);
          for (size_t k = 0; k < wsize; k++)
          {
            uint8_t c = (data >> (((wsize)-1 - k) * 8)) & 0xff;
            printf("%02x ", c);
          }
          printf(" ");
        }
        printf("\n");
      }
      printf("" FMT_WORD ": ", addr + i * wsize);
    }
    data = vaddr_read(addr + i * wsize, 4);
    printf("" FMT_WORD " ", data);
  }
  printf("\n");
}