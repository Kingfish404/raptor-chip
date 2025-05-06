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

extern jmp_buf exec_jmp_buf;
extern int cause;

extern FILE *mem_trace;

word_t g_vaddr = 0;

word_t get_paddr(vaddr_t addr, int len)
{
  paddr_t paddr = addr;
  if (paddr == 0)
  {
    cause = MCA_INS_ACC_FAU;
    longjmp(exec_jmp_buf, 20);
  }
  if (isa_mmu_check(addr, len, MEM_TYPE_IFETCH) == MMU_DIRECT)
  {
    paddr = addr;
  }
  else
  {
    // printf("ir = " FMT_WORD "\n", addr);
    paddr = isa_mmu_translate(addr, len, MEM_TYPE_IFETCH);
  }
  return paddr;
}

word_t vaddr_ifetch(vaddr_t addr, int len)
{
  g_vaddr = addr;
  paddr_t paddr = addr;
  if (paddr == 0)
  {
    cause = MCA_INS_ACC_FAU;
    longjmp(exec_jmp_buf, 20);
  }
  if (isa_mmu_check(addr, len, MEM_TYPE_IFETCH) == MMU_DIRECT)
  {
    paddr = addr;
  }
  else
  {
    // printf("ir = " FMT_WORD "\n", addr);
    paddr = isa_mmu_translate(addr, len, MEM_TYPE_IFETCH);
  }
  return paddr_read(paddr, len);
}

word_t vaddr_read(vaddr_t addr, int len)
{
  g_vaddr = addr;
  if ((addr % len) != 0)
  {
    cause = MCA_LOA_ADD_MIS;
    longjmp(exec_jmp_buf, 21);
  }
  if (mem_trace != NULL)
  {
    fprintf(mem_trace, FMT_WORD_NO_PREFIX "-%c\n", addr, 'r');
  }
  paddr_t paddr = addr;
  if (isa_mmu_check(addr, len, MEM_TYPE_READ) == MMU_DIRECT)
  {
    paddr = addr;
  }
  else
  {
    // printf("dr: addr = " FMT_WORD "\n", addr);
    paddr = isa_mmu_translate(addr, len, MEM_TYPE_READ);
  }
  return paddr_read(paddr, len);
}

void vaddr_write(vaddr_t addr, int len, word_t data)
{
  g_vaddr = addr;
  cpu.vwaddr = addr;
  cpu.wdata = data;
  cpu.len = len;
  if ((addr % len) != 0)
  {
    cause = MCA_STO_ADD_MIS;
    longjmp(exec_jmp_buf, 21);
  }
  if (mem_trace != NULL)
  {
    fprintf(mem_trace, FMT_WORD_NO_PREFIX "-%c\n", addr, 'w');
  }
  paddr_t paddr = 0;
  if (isa_mmu_check(addr, len, MEM_TYPE_WRITE) == MMU_DIRECT)
  {
    paddr = addr;
  }
  else
  {
    // printf("dw:  addr = " FMT_WORD "\n", addr);
    paddr = isa_mmu_translate(addr, len, MEM_TYPE_WRITE);
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