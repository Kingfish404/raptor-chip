/***************************************************************************************
 * Software TLB for NEMU: caches vaddr->paddr translations to skip page table walks.
 *
 * Direct-mapped, separate arrays for ifetch / load / store.
 * Flushed on sfence.vma and satp writes.
 ***************************************************************************************/

#ifndef __MEMORY_TLB_H__
#define __MEMORY_TLB_H__

#include <common.h>
#include <memory/vaddr.h>

/* 256 entries per TLB: power-of-two, direct-mapped by VPN */
#define SOFT_TLB_BITS 8
#define SOFT_TLB_ENTRIES (1u << SOFT_TLB_BITS)
#define SOFT_TLB_MASK (SOFT_TLB_ENTRIES - 1)

/* An invalid tag that can never match a real VPN (VPN is at most 20 bits for Sv32) */
#define SOFT_TLB_INVALID_TAG ((vaddr_t) - 1)

typedef struct
{
  vaddr_t vpn;    /* virtual page number (vaddr >> PAGE_SHIFT), acts as tag */
  paddr_t ppn;    /* physical page base  (paddr with offset=0)              */
  uint32_t epoch; /* version stamp; entry valid iff epoch == soft_tlb_epoch */
} soft_tlb_entry_t;

/* Three separate TLBs: mirrors Spike's design for permission separation */
extern soft_tlb_entry_t soft_tlb_ifetch[SOFT_TLB_ENTRIES];
extern soft_tlb_entry_t soft_tlb_load[SOFT_TLB_ENTRIES];
extern soft_tlb_entry_t soft_tlb_store[SOFT_TLB_ENTRIES];

/* Global epoch counter: incremented on every full flush. An entry whose
 * `epoch` field doesn't match the current global counter is treated as
 * invalid, turning the previously-O(SOFT_TLB_ENTRIES * 3) memset flush
 * into an O(1) increment. */
extern uint32_t soft_tlb_epoch;

/* Flush all TLBs (called from sfence.vma / satp write).
 * Now O(1): just bumps soft_tlb_epoch. Stale entries from earlier epochs
 * are filtered by the lookup's `epoch == cur_epoch` check. */
void soft_tlb_flush(void);

/* ----- inline fast-path lookup ----- */

static inline bool soft_tlb_lookup(
    const soft_tlb_entry_t *tlb, vaddr_t vaddr, paddr_t *out_paddr)
{
  vaddr_t vpn = vaddr >> PAGE_SHIFT;
  unsigned idx = vpn & SOFT_TLB_MASK;
  const soft_tlb_entry_t *e = &tlb[idx];
  if (e->vpn == vpn && e->epoch == soft_tlb_epoch)
  {
    *out_paddr = e->ppn | (vaddr & PAGE_MASK);
    return true;
  }
  return false;
}

static inline void soft_tlb_refill(
    soft_tlb_entry_t *tlb, vaddr_t vaddr, paddr_t paddr)
{
  vaddr_t vpn = vaddr >> PAGE_SHIFT;
  unsigned idx = vpn & SOFT_TLB_MASK;
  tlb[idx].vpn = vpn;
  tlb[idx].ppn = paddr & ~((paddr_t)PAGE_MASK);
  tlb[idx].epoch = soft_tlb_epoch;
}

#endif /* __MEMORY_TLB_H__ */
