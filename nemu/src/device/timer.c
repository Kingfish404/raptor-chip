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

static uint32_t *rtc_port_base = NULL;
static uint32_t *clint_base = NULL;

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
    // When kernel writes to mtimecmp, update the cached value
    if (offset >= MTIMECMP_BASE && offset < MTIMECMP_BASE + 8)
    {
      uint8_t *p = (uint8_t *)clint_base;
      uint32_t lo = *(uint32_t *)(p + MTIMECMP_BASE);
      uint32_t hi = *(uint32_t *)(p + MTIMECMP_BASE + 4);
      cpu.mtimecmp = ((uint64_t)hi << 32) | lo;
    }
  }
  else
  {
    // Update mtime when any read hits the CLINT region
    // Scale to 10MHz (matching DTS timebase-frequency)
    uint64_t ticks = get_time() * 10;
    uint8_t *p = (uint8_t *)clint_base;
    *(uint32_t *)(p + MTIME_BASE) = (uint32_t)ticks;
    *(uint32_t *)(p + MTIME_BASE + 4) = (uint32_t)(ticks >> 32);
  }
}

#ifndef CONFIG_TARGET_AM
static void timer_intr()
{
  if (nemu_state.state == NEMU_RUNNING)
  {
    extern void dev_raise_intr();
    dev_raise_intr();
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
#endif
  IFNDEF(CONFIG_TARGET_AM, add_alarm_handle(timer_intr));
}
