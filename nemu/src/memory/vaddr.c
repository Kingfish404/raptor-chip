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
  /* A halfword-aligned 32-bit instruction can span independently mapped
   * pages. Read its first half before deciding whether a second is needed;
   * a compressed instruction must not fault on an unused following page. */
  if (len == 4 && (addr & 2))
  {
    const word_t first = vaddr_ifetch(addr, 2);
    if ((first & 3) != 3) return first;
    const word_t second = vaddr_ifetch(addr + 2, 2);
    g_vaddr = addr;
    return first | (second << 16);
  }
  g_vaddr = addr;
  paddr_t paddr = addr;
  bool mmu_on = false;
  uint8_t pbmt = 0;
  if (isa_mmu_check(addr, len, MEM_TYPE_IFETCH) == MMU_DIRECT)
  {
    paddr = addr;
  }
  else
  {
    mmu_on = true;
    if (soft_tlb_lookup_attrs(soft_tlb_ifetch, addr, &paddr, &pbmt))
    {
      if (!paddr_is_memory_span(paddr, len)
          || pmp_check(paddr, len, cpu.priv, false, false, true))
      {
        cause = MCA_INS_ACC_FAU;
        nemu_longjmp(exec_jmp_buf, 22);
      }
      return paddr_read(paddr, len);
    }
    paddr = isa_mmu_translate_attrs(addr, len, MEM_TYPE_IFETCH, &pbmt);
    soft_tlb_refill_attrs(soft_tlb_ifetch, addr, paddr, pbmt);
  }
  if (!paddr_is_memory_span(paddr, len))
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

/* A virtual page boundary need not be physically contiguous. Validate both
 * parts before issuing data accesses, retaining the faulting virtual page. */
static void check_data_pma(paddr_t pa, int len, bool store)
{
  /* Probe without MMIO/skip side effects before any host access. A mapped
   * first byte does not authorize an unaligned access past its backing. */
  bool allowed = len > 0;
  int fault_offset = 0;
  for (int i = 0; allowed && i < len; i++)
  {
    const paddr_t byte_addr = pa + (paddr_t)i;
    allowed = byte_addr >= pa && paddr_is_mapped(byte_addr)
        && (!store || !paddr_is_readonly(byte_addr));
    if (!allowed) fault_offset = i;
  }
  if (!allowed)
  {
    g_vaddr += (word_t)fault_offset;
    cause = store ? MCA_STO_ACC_FAU : MCA_LOA_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, store ? 24 : 23);
  }
}

/* Raptor rejects misaligned explicit IO accesses before device activity.
 * Keep the original operation's alignment when checking cross-page pieces. */
static void check_data_type(paddr_t pa, uint8_t pbmt, bool misaligned, bool store, int original_len)
{
  bool device = false;
#ifdef CONFIG_RAPTOR_MEMORY_MAP
  device = paddr_is_mapped(pa) && !paddr_is_memory_span(pa, 1);
#else
  (void)pa;
#endif
  bool width_fault = false;
#ifdef CONFIG_RAPTOR_MEMORY_MAP
  /* Physical PLIC width is not changed by page memory types or splitting. */
  width_fault = pa >= 0x0c000000u && pa < 0x0d000000u
      && (original_len != 4 || (pa & 3) != 0);
#else
  (void)original_len;
#endif
  if (width_fault || ((pbmt == 2 || device) && misaligned)) {
    cause = store ? MCA_STO_ACC_FAU : MCA_LOA_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, store ? 24 : 23);
  }
}

static paddr_t checked_data_piece(vaddr_t addr, int len, bool store, bool misaligned, int original_len)
{
  g_vaddr = addr;
  const int type = store ? MEM_TYPE_WRITE : MEM_TYPE_READ;
  const bool translated = isa_mmu_check(addr, len, type) != MMU_DIRECT;
  uint8_t pbmt = 0;
  paddr_t pa = translated ? isa_mmu_translate_attrs(addr, len, type, &pbmt) : addr;
  check_data_type(pa, pbmt, misaligned, store, original_len);
  check_data_pma(pa, len, store);
  if (pmp_check(pa, len, pmp_effective_priv_ls(), !store, store, false))
  {
    if (!translated) g_vaddr = pmp_last_fault_addr;
    cause = store ? MCA_STO_ACC_FAU : MCA_LOA_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, store ? 24 : 23);
  }
  return pa;
}

static paddr_t checked_data_address(vaddr_t addr, int len, bool store)
{
  return checked_data_piece(addr, len, store, (addr & (len - 1)) != 0, len);
}

/* A valid writable PTE also grants reads. Check write translation first so
 * AMO page faults have the store class, then check both physical permissions. */
paddr_t vaddr_check_reservation(vaddr_t addr, int len, bool store)
{
  paddr_t pa = checked_data_address(addr, len, store);
  if (!paddr_supports_atomic(pa, len))
  {
    g_vaddr = addr;
    cause = store ? MCA_STO_ACC_FAU : MCA_LOA_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, store ? 24 : 23);
  }
  return pa;
}

void vaddr_check_amo(vaddr_t addr, int len)
{
  const paddr_t pa = vaddr_check_reservation(addr, len, true);
  if (pmp_check(pa, len, pmp_effective_priv_ls(), true, true, false))
  {
    g_vaddr = addr;
    cause = MCA_STO_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, 24);
  }
}

void vaddr_check_zero(vaddr_t addr)
{
  paddr_t pa = checked_data_address(addr, 1, true);
  if (!paddr_supports_zero(pa))
  {
    g_vaddr = addr;
    cause = MCA_STO_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, 24);
  }
}

void vaddr_check_store(vaddr_t addr, int len)
{
  const int first = 4096 - (int)(addr & 4095);
  if (len > first && isa_mmu_check(addr, len, MEM_TYPE_WRITE) != MMU_DIRECT)
  {
    checked_data_piece(addr, first, true, true, len);
    checked_data_piece(addr + first, len - first, true, true, len);
  }
  else checked_data_address(addr, len, true);
}

/* Keep original width/alignment across RV32 FLD pieces without widening
 * each piece's PMP footprint or reading a device during validation. */
word_t vaddr_read_piece(vaddr_t addr, int len, int original_len, bool original_misaligned)
{
  g_vaddr = addr;
  cpu.rvaddr = addr;
  cpu.rlen = len;
  const int first = 4096 - (int)(addr & 4095);
  if (len > first && isa_mmu_check(addr, len, MEM_TYPE_READ) != MMU_DIRECT)
  {
    paddr_t lo = checked_data_piece(addr, first, false, original_misaligned, original_len);
    paddr_t hi = checked_data_piece(addr + first, len - first, false, original_misaligned, original_len);
    word_t value = 0;
    for (int i = 0; i < len; i++)
      value |= (word_t)paddr_read(i < first ? lo + i : hi + i - first, 1) << (8*i);
    g_vaddr = addr;
    cpu.rpaddr = lo;
    cpu.rdata = value;
    return value;
  }
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
  uint8_t pbmt = 0;
  if (isa_mmu_check(addr, len, MEM_TYPE_READ) == MMU_DIRECT)
  {
    paddr = addr;
  }
  else
  {
    mmu_on = true;
    if (soft_tlb_lookup_attrs(soft_tlb_load, addr, &paddr, &pbmt))
    {
      check_data_type(paddr, pbmt, original_misaligned, false, original_len);
      check_data_pma(paddr, len, false);
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
    paddr = isa_mmu_translate_attrs(addr, len, MEM_TYPE_READ, &pbmt);
    soft_tlb_refill_attrs(soft_tlb_load, addr, paddr, pbmt);
  }
  check_data_type(paddr, pbmt, original_misaligned, false, original_len);
  check_data_pma(paddr, len, false);
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

word_t vaddr_read(vaddr_t addr, int len)
{
  return vaddr_read_piece(addr, len, len, (addr & (len - 1)) != 0);
}

void vaddr_write(vaddr_t addr, int len, word_t data)
{
  g_vaddr = addr;
  cpu.vwaddr = addr;
  cpu.wdata = data;
  cpu.len = len;
  const int first = 4096 - (int)(addr & 4095);
  if (len > first && isa_mmu_check(addr, len, MEM_TYPE_WRITE) != MMU_DIRECT)
  {
    paddr_t lo = checked_data_piece(addr, first, true, true, len);
    paddr_t hi = checked_data_piece(addr + first, len - first, true, true, len);
    for (int i = 0; i < len; i++)
    {
      paddr_t pa = i < first ? lo + i : hi + i - first;
      paddr_write(pa, 1, (data >> (8*i)) & 0xff);
      if ((cpu.reservation & ~(word_t)3) == (pa & ~(paddr_t)3)) { cpu.reservation = 0; cpu.reservation_bytes = 0; }
    }
    g_vaddr = addr;
    cpu.pwaddr = lo;
    return;
  }
  /* Misaligned ordinary stores are allowed (Zicclsm); see vaddr_read note. */
  if (mem_trace != NULL)
  {
    fprintf(mem_trace, FMT_WORD_NO_PREFIX "-%c\n", addr, 'w');
  }
  paddr_t paddr = 0;
  bool mmu_on = false;
  uint8_t pbmt = 0;
  if (isa_mmu_check(addr, len, MEM_TYPE_WRITE) == MMU_DIRECT)
  {
    paddr = addr;
  }
  else
  {
    mmu_on = true;
    if (soft_tlb_lookup_attrs(soft_tlb_store, addr, &paddr, &pbmt))
    {
      check_data_type(paddr, pbmt, (addr & (len - 1)) != 0, true, len);
      check_data_pma(paddr, len, true);
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
        cpu.reservation_bytes = 0;
      }
      return;
    }
    paddr = isa_mmu_translate_attrs(addr, len, MEM_TYPE_WRITE, &pbmt);
    soft_tlb_refill_attrs(soft_tlb_store, addr, paddr, pbmt);
  }
  check_data_type(paddr, pbmt, (addr & (len - 1)) != 0, true, len);
  check_data_pma(paddr, len, true);
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
    cpu.reservation_bytes = 0;
  }
}

/* Zicbom management operations check the addressed byte as a data access with
 * load-or-store permission.  They use the store/AMO exception class, require
 * PTE.A under Svade, do not require PTE.D, and have no memory side effect. */
void vaddr_check_cmo(vaddr_t addr)
{
  g_vaddr = addr;
  paddr_t paddr = addr;
  const bool translated = isa_mmu_check(addr, 1, MEM_TYPE_CMO) != MMU_DIRECT;
  if (translated)
  {
    uint8_t pbmt;
    paddr = isa_mmu_translate_attrs(addr, 1, MEM_TYPE_CMO, &pbmt);
  }

  if (!paddr_is_mapped(paddr))
  {
    cause = MCA_STO_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, 24);
  }
  uint32_t priv = pmp_effective_priv_ls();
  bool read_fault = pmp_check(paddr, 1, priv, true, false, false);
  bool write_fault = pmp_check(paddr, 1, priv, false, true, false);
  if (read_fault && write_fault)
  {
    // PMP checks physical addresses; tval must retain the virtual operand.
    if (!translated) g_vaddr = pmp_last_fault_addr;
    cause = MCA_STO_ACC_FAU;
    nemu_longjmp(exec_jmp_buf, 24);
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
