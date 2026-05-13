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
#include <device/map.h>
#include <device/alarm.h>
#include <utils.h>

#define MSIP_BASE 0x0
#define MTIMECMP_BASE 0x4000
#define MTIME_BASE 0xbff8

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
static uint32_t *clint_base = NULL;
static uint32_t clint_msip = 0; // MSIP register (only bit 0 used)

static uint64_t clint_get_ticks(void)
{
#if defined(CONFIG_TIMER_CYCLE)
  // 1GHz / 10MHz = 100 cycles per tick
  extern uint64_t g_nr_guest_inst;
  return g_nr_guest_inst / 100;
#else
  return get_time() * 10;
#endif
}

static uint64_t sstc_get_stimecmp(void)
{
#if defined(CONFIG_RV64)
  return cpu.sr[CSR_STIMECMP];
#else
  return ((uint64_t)(uint32_t)cpu.sr[CSR_STIMECMPH] << 32) |
         (uint32_t)cpu.sr[CSR_STIMECMP];
#endif
}

static bool sstc_enabled(void)
{
#if defined(CONFIG_RV64)
  return (cpu.sr[CSR_MENVCFG] >> 63) & 0x1;
#else
  return (cpu.sr[CSR_MENVCFGH] >> 31) & 0x1;
#endif
}

// Update MIP.MTIP and MIP.MSIP based on current CLINT state.
// Called after every instruction (from decode_exec) and on CLINT MMIO writes.
void clint_update_mip(void)
{
#if !defined(CONFIG_TARGET_SHARE)
  uint64_t ticks = clint_get_ticks();

  // MTIP: mtime >= mtimecmp (level-triggered, same as RTL CLINT)
  if (ticks >= cpu.mtimecmp)
    cpu.sr[CSR_MIP] |= MIP_MTIP_BIT;
  else
    cpu.sr[CSR_MIP] &= ~MIP_MTIP_BIT;

  if (sstc_enabled())
  {
    if (ticks >= sstc_get_stimecmp())
      cpu.sr[CSR_MIP] |= MIP_STIP_BIT;
    else
      cpu.sr[CSR_MIP] &= ~MIP_STIP_BIT;
  }

  // MSIP: software interrupt from CLINT MSIP register
  if (clint_msip & 1u)
    cpu.sr[CSR_MIP] |= MIP_MSIP_BIT;
  else
    cpu.sr[CSR_MIP] &= ~MIP_MSIP_BIT;
#endif
}

// WFI acceleration: advance time to mtimecmp so the next instruction sees MTIP.
// Returns true if time was advanced.
bool clint_wfi_advance(void)
{
#if !defined(CONFIG_TARGET_SHARE) && defined(CONFIG_TIMER_CYCLE)
  uint64_t ticks = clint_get_ticks();
  uint64_t next_cmp = cpu.mtimecmp;
  uint64_t stimecmp = sstc_get_stimecmp();
  if (stimecmp < next_cmp)
    next_cmp = stimecmp;
  // Only advance if timer interrupt is not already pending
  if (ticks < next_cmp)
  {
    // Advance g_nr_guest_inst so that ticks reaches the next timer compare.
    extern uint64_t g_nr_guest_inst;
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

static void clint_io_handler(uint32_t offset, int len, bool is_write)
{
  if (is_write)
  {
    // MSIP register (offset 0x0, only bit 0)
    if (offset >= MSIP_BASE && offset < MSIP_BASE + 4)
    {
      uint8_t *p = (uint8_t *)clint_base;
      clint_msip = *(uint32_t *)(p + MSIP_BASE) & 1u;
      clint_update_mip();
    }
    // mtimecmp register (offset 0x4000, 64-bit)
    else if (offset >= MTIMECMP_BASE && offset < MTIMECMP_BASE + 8)
    {
      uint8_t *p = (uint8_t *)clint_base;
      uint32_t lo = *(uint32_t *)(p + MTIMECMP_BASE);
      uint32_t hi = *(uint32_t *)(p + MTIMECMP_BASE + 4);
      cpu.mtimecmp = ((uint64_t)hi << 32) | lo;
      // Immediately recalculate MTIP (writing mtimecmp often clears timer interrupt)
      clint_update_mip();
    }
  }
  else
  {
    // MSIP read
    if (offset >= MSIP_BASE && offset < MSIP_BASE + 4)
    {
      uint8_t *p = (uint8_t *)clint_base;
      *(uint32_t *)(p + MSIP_BASE) = clint_msip & 1u;
    }
    // mtime read: update mtime from ticks
    else
    {
      uint64_t ticks = clint_get_ticks();
      uint8_t *p = (uint8_t *)clint_base;
      *(uint32_t *)(p + MTIME_BASE) = (uint32_t)ticks;
      *(uint32_t *)(p + MTIME_BASE + 4) = (uint32_t)(ticks >> 32);
    }
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
  uint8_t *p = (uint8_t *)clint_base;
  uint32_t lo = *(uint32_t *)(p + MTIMECMP_BASE);
  uint32_t hi = *(uint32_t *)(p + MTIMECMP_BASE + 4);
  return ((uint64_t)hi << 32) | lo;
}

void init_timer()
{
  rtc_port_base = (uint32_t *)new_space(8);
  clint_base = (uint32_t *)new_space(0x000c0000);
  clint_msip = 0;
  /* Initialize mtimecmp to max so timer doesn't fire until software programs it */
  uint8_t *p = (uint8_t *)clint_base;
  *(uint32_t *)(p + MTIMECMP_BASE) = 0xFFFFFFFF;
  *(uint32_t *)(p + MTIMECMP_BASE + 4) = 0xFFFFFFFF;
#ifdef CONFIG_HAS_PORT_IO
  add_pio_map("rtc", CONFIG_RTC_PORT, rtc_port_base, 8, rtc_io_handler);
#else
  add_mmio_map("rtc", CONFIG_RTC_MMIO, rtc_port_base, 8, rtc_io_handler);
  // https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/platform.h
  // https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/clint.cc
  add_mmio_map("clint", CONFIG_RTC_MMIO_CLINT, clint_base, 0x000c0000, clint_io_handler);
  // egos HARDWARE platform CLINT alias at 0xF0010000 (mvendorid==666 path).
  // Shares the same backing storage and handler so MSIP/MTIMECMP/MTIME
  // accesses route through identically.
  add_mmio_map("clint-litex-alias", 0xF0010000u, clint_base, 0x10000, clint_io_handler);
#endif
  IFNDEF(CONFIG_TARGET_AM, add_alarm_handle(timer_intr));
}
