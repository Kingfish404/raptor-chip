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
#include <memory/paddr.h>

word_t vaddr_ifetch(vaddr_t addr, int len)
{
  return paddr_read(addr, len);
}

word_t vaddr_read(vaddr_t addr, int len)
{
  return paddr_read(addr, len);
}

void vaddr_write(vaddr_t addr, int len, word_t data)
{
  paddr_write(addr, len, data);
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