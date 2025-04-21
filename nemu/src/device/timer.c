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
  // printf("clint_io_handler: offset: " FMT_WORD ", len: %d, is_write: %d\n", offset, len, is_write);
  if (!is_write)
  {
    uint64_t us = get_time();
    clint_base[offset] = (uint32_t)us;
    clint_base[offset] = us >> 32;
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
  return ((uint64_t)clint_base[MTIMECMP_BASE + 4] << 32) | clint_base[MTIMECMP_BASE];
}

void init_timer()
{
  rtc_port_base = (uint32_t *)new_space(8);
  clint_base = (uint32_t *)new_space(0x000c0000);
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
