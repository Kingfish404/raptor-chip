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
#include <cpu/thread.h>
#include <cpu/multidiff.h>
#include <cpu/diffjournal.h>
#include <difftest-journal.h>
#include <device/map.h>
#include <device/alarm.h>
#include <utils.h>

#define MSIP_BASE 0x0
#define MTIMECMP_BASE 0x4000
#define MTIME_BASE 0xbff8
#define GOLDFISH_RTC_BASE 0x00101000u
#define GOLDFISH_RTC_SIZE 0x1000u

// MIP bit positions for CLINT-controlled interrupts
#define MIP_MSIP_BIT (1u << 3)  // Machine Software Interrupt Pending
#define MIP_STIP_BIT (1u << 5)  // Supervisor Timer Interrupt Pending
#define MIP_MTIP_BIT (1u << 7)  // Machine Timer Interrupt Pending
#define CSR_STIMECMP 0x14d
#define CSR_STIMECMPH 0x15d
#define CSR_MENVCFG  0x30a
#define CSR_MENVCFGH 0x31a
// menvcfg.STCE: bit 63. Enables Sstc-driven hardware MIP.STIP.
// When STCE=0, MIP.STIP is software-writable (via M-mode); the CLINT
// must NOT override it from stimecmp.

static uint32_t *rtc_port_base = NULL;
static uint8_t *goldfish_rtc_base = NULL;
static uint32_t *clint_base = NULL;
static uint32_t clint_msip[NEMU_MAX_HARTS];

static uint64_t clint_get_ticks(void)
{
  if (nemu_threaded) return get_time() * 10;
#if defined(CONFIG_TIMER_CYCLE)
  // 1GHz / 10MHz = 100 cycles per tick
  extern NEMU_TLS uint64_t g_nr_guest_inst;
  return g_nr_guest_inst / 100;
#else
  return get_time() * 10;
#endif
}

static uint64_t sstc_get_stimecmp(const CPU_state *hart)
{
#if defined(CONFIG_RV64)
  return hart->sr[CSR_STIMECMP];
#else
  return ((uint64_t)(uint32_t)hart->sr[CSR_STIMECMPH] << 32) |
         (uint32_t)hart->sr[CSR_STIMECMP];
#endif
}

#if !defined(CONFIG_TARGET_SHARE) && defined(CONFIG_TIMER_CYCLE)
// Only the instruction-count timer's WFI fast-forward path needs STCE here.
// The live STIP level is kept separately and gated when CSR MIP is read.
static bool sstc_enabled(const CPU_state *hart)
{
#if defined(CONFIG_RV64)
  return (hart->sr[CSR_MENVCFG] >> 63) & 0x1;
#else
  return (hart->sr[CSR_MENVCFGH] >> 31) & 0x1;
#endif
}
#endif

// Update MIP.MTIP and MIP.MSIP based on current CLINT state.
// Called after every instruction (from decode_exec) and on CLINT MMIO writes.
void clint_update_mip(void)
{
  if (multidiff_active() && !multidiff_clint_active()) return;
#if !defined(CONFIG_TARGET_SHARE)
  if (nemu_threaded && !nemu_worker) return;
  cpu_bus_lock();
  uint64_t ticks = clint_get_ticks();

  if (multidiff_clint_active() && nemu_journal_clock)
    nemu_journal_clock(ticks, NEMU_JOURNAL_CLOCK_UPDATE);

  for (unsigned hartid = 0; hartid < nemu_nr_harts; hartid++)
  {
    if (nemu_threaded && hartid != nemu_hartid) continue;
    CPU_state *hart = riscv_hart(hartid);
    if (ticks >= hart->mtimecmp)
      hart->sr[CSR_MIP] |= MIP_MTIP_BIT;
    else
      hart->sr[CSR_MIP] &= ~MIP_MTIP_BIT;
    hart->stip = ticks >= sstc_get_stimecmp(hart);
    if (clint_msip[hartid] & 1u)
      hart->sr[CSR_MIP] |= MIP_MSIP_BIT;
    else
      hart->sr[CSR_MIP] &= ~MIP_MSIP_BIT;
    hart->sr[CSR_SIP] = riscv_hart_mip_value(hart) & hart->sr[CSR_MIDELEG] & (word_t)0x222;
    hart->sr[CSR_TIME] = (word_t)ticks;
#ifndef CONFIG_RV64
    hart->sr[CSR_TIMEH] = (uint32_t)(ticks >> 32);
#endif
  }
#ifdef NEMU_HAS_THREADS
  if (nemu_threaded)
  {
    extern void plic_sync_hart(void);
    plic_sync_hart();
  }
#endif
  if (multidiff_plic_active() && nemu_journal_inputs) nemu_journal_inputs(ticks);
  cpu_bus_unlock();
#endif
}

void clint_restore_checkpoint(uint64_t mtime, uint64_t mtimecmp, uint8_t msip)
{
  (void)mtime;
  cpu.mtimecmp = mtimecmp;
  clint_msip[nemu_hartid] = msip & 1u;
  if (clint_base != NULL)
  {
    uint8_t *p = (uint8_t *)clint_base;
    *(uint32_t *)(p + MSIP_BASE + 4 * nemu_hartid) = clint_msip[nemu_hartid];
    *(uint32_t *)(p + MTIMECMP_BASE + 8 * nemu_hartid) = (uint32_t)mtimecmp;
    *(uint32_t *)(p + MTIMECMP_BASE + 8 * nemu_hartid + 4) = (uint32_t)(mtimecmp >> 32);
  }
  clint_update_mip();
}

// WFI acceleration: advance time to mtimecmp so the next instruction sees MTIP.
// Returns true if time was advanced.
bool clint_wfi_advance(void)
{
  if (nemu_threaded) return false;
#if !defined(CONFIG_TARGET_SHARE) && defined(CONFIG_TIMER_CYCLE)
  uint64_t ticks = clint_get_ticks();
  uint64_t next_cmp = UINT64_MAX;
  for (unsigned hartid = 0; hartid < nemu_nr_harts; hartid++)
  {
    const CPU_state *hart = riscv_hart(hartid);
    if ((nemu_nr_harts == 1 || (hart->sr[CSR_MIE] & MIP_MTIP_BIT)) &&
        hart->mtimecmp > ticks && hart->mtimecmp < next_cmp)
      next_cmp = hart->mtimecmp;
    uint64_t stimecmp = sstc_get_stimecmp(hart);
    if (sstc_enabled(hart) &&
        (nemu_nr_harts == 1 || (hart->sr[CSR_MIE] & MIP_STIP_BIT)) &&
        stimecmp > ticks && stimecmp < next_cmp)
      next_cmp = stimecmp;
  }
  // Only advance if timer interrupt is not already pending
  if (ticks < next_cmp && next_cmp <= UINT64_MAX / 100)
  {
    // Advance g_nr_guest_inst so that ticks reaches the next timer compare.
    extern NEMU_TLS uint64_t g_nr_guest_inst;
    g_nr_guest_inst = next_cmp * 100;
    clint_update_mip();
    return true;
  }
#endif
  return false;
}

static void rtc_io_handler(uint32_t offset, int len, bool is_write)
{
  assert(offset == 0 || offset == 4);
  if (!is_write && offset == 4)
  {
    uint64_t us = get_time();
    rtc_port_base[0] = (uint32_t)us;
    rtc_port_base[1] = us >> 32;
  }
}

static void goldfish_rtc_io_handler(uint32_t offset, int len, bool is_write)
{
  if (!is_write && (offset == 0 || offset == 4))
  {
    uint64_t us = get_time();
    *(uint32_t *)(goldfish_rtc_base + 0) = (uint32_t)us;
    *(uint32_t *)(goldfish_rtc_base + 4) = (uint32_t)(us >> 32);
  }
}

static void clint_io_handler(uint32_t offset, int len, bool is_write)
{
  uint8_t *base = (uint8_t *)clint_base;
  for (unsigned hartid = 0; hartid < nemu_nr_harts; hartid++)
  {
    unsigned msip_offset = MSIP_BASE + 4 * hartid;
    unsigned cmp_offset = MTIMECMP_BASE + 8 * hartid;
    if (offset < msip_offset + 4 && offset + len > msip_offset)
    {
      if (is_write)
        clint_msip[hartid] = *(uint32_t *)(base + msip_offset) & 1u;
      *(uint32_t *)(base + msip_offset) = clint_msip[hartid];
    }
    if (offset < cmp_offset + 8 && offset + len > cmp_offset)
    {
      CPU_state *hart = riscv_hart(hartid);
      if (is_write)
        memcpy(&hart->mtimecmp, base + cmp_offset, 8);
      else
        memcpy(base + cmp_offset, &hart->mtimecmp, 8);
    }
  }
  if (is_write)
  {
    clint_update_mip();
    cpu_thread_wake();
  }
  else
  {
    uint64_t ticks = clint_get_ticks();
    if (multidiff_clint_active() && nemu_journal_clock)
      nemu_journal_clock(ticks, NEMU_JOURNAL_CLOCK_READ);
    memcpy(base + MTIME_BASE, &ticks, 8);
  }
}

#ifndef CONFIG_TARGET_AM
static void timer_intr()
{
  if (nemu_state.state == NEMU_RUNNING)
  {
    // Legacy alarm path: update MIP from CLINT state
    clint_update_mip();
  }
}
#endif

uint64_t get_mtimecmp()
{
  cpu_bus_lock();
  uint64_t value = cpu.mtimecmp;
  cpu_bus_unlock();
  return value;
}

void init_timer()
{
  rtc_port_base = (uint32_t *)new_space(8);
  goldfish_rtc_base = new_space(GOLDFISH_RTC_SIZE);
  clint_base = (uint32_t *)new_space(0x000c0000);
  memset(clint_msip, 0, sizeof(clint_msip));
  /* Initialize mtimecmp to max so timer doesn't fire until software programs it */
  uint8_t *p = (uint8_t *)clint_base;
  memset(p + MTIMECMP_BASE, 0xff, 8 * nemu_nr_harts);
#ifdef CONFIG_HAS_PORT_IO
  add_pio_map("rtc", CONFIG_RTC_PORT, rtc_port_base, 8, rtc_io_handler);
#else
  add_mmio_map("rtc", CONFIG_RTC_MMIO, rtc_port_base, 8, rtc_io_handler);
  add_mmio_map("goldfish-rtc", GOLDFISH_RTC_BASE, goldfish_rtc_base,
               GOLDFISH_RTC_SIZE, goldfish_rtc_io_handler);
  // https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/platform.h
  // https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/clint.cc
  add_mmio_map("clint", CONFIG_RTC_MMIO_CLINT, clint_base, 0x000c0000, clint_io_handler);
#endif
  IFNDEF(CONFIG_TARGET_AM, add_alarm_handle(timer_intr));
}
