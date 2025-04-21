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

static uint8_t *plic_base = NULL;

void dev_raise_intr()
{
    if (!cpu.intr)
    {
        cpu.intr = true;
    }
}

static void plic_io_handler(uint32_t offset, int len, bool is_write)
{
    // printf("plic_io_handler: offset: " FMT_WORD ", len: %d, is_write: %d\n", offset, len, is_write);
    assert(len == 4);
    if (is_write)
    {
        plic_base[offset] = 0;
    }
    else
    {
        // Log("PLIC: do not support read");
    }
}

void init_intr()
{
    plic_base = new_space(0x01000000);
    // https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/platform.h
    // https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/plic.cc
    add_mmio_map("plic", CONFIG_PLIC_MMIO, plic_base, 0x01000000, plic_io_handler);
}