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
#include <cpu/cpu.h>
#include <difftest-def.h>
#include <memory/paddr.h>
#include <memory/vaddr.h>

typedef struct
{
  int state;
  word_t *gpr;
  word_t *ret;
  word_t *pc;
} NPCState;

__EXPORT void difftest_memcpy(paddr_t addr, void *buf, size_t n, bool direction)
{
  if (direction == DIFFTEST_TO_REF)
  {
    memcpy(guest_to_host(addr), buf, n);
  }
  else
  {
    memcpy(buf, guest_to_host(addr), n);
  }
}

__EXPORT void difftest_regcpy(void *dut, bool direction)
{
  NPCState *npc = (NPCState *)dut;
  if (direction == DIFFTEST_TO_REF)
  {
    cpu.pc = *npc->pc;
    for (int i = 0; i < RISCV_GPR_NUM; i++)
    {
      cpu.gpr[i] = npc->gpr[i];
    }
  }
  else if (direction == DIFFTEST_TO_DUT)
  {
    npc->pc = &cpu.pc;
    npc->gpr = cpu.gpr;
  }
  // isa_reg_display();
  // vaddr_show(cpu.pc, 0x2c);
}

__EXPORT void difftest_exec(uint64_t n)
{
  cpu_exec(n);
}

__EXPORT void difftest_raise_intr(word_t NO)
{
  assert(0);
}

__EXPORT void difftest_init(int port)
{
  void init_mem();
  init_mem();
  /* Perform ISA dependent initialization. */
  init_isa();
}
