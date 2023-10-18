#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <pthread.h>
#include "Vtop.h"
#include "Vtop__Dpi.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

VerilatedContext *contextp;

void single_cycle(Vtop *top)
{
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
}

void reset(Vtop *top, int n)
{
  top->rst = 1;
  while (n-- > 0)
  {
    single_cycle(top);
  }
  top->rst = 0;
}

uint32_t pmem_read(uint64_t addr)
{
  switch (addr)
  {
  case 0x80000000:
  case 0x80000004:
  case 0x80000008:
  case 0x8000000c:
  case 0x80000010:
  case 0x80000014:
    // addi x1, x0, 0
    //     0b0000000 00001 00001 000 00001 00100 11;
    return 0b00000000000100001000000010010011;
  default:
    // ebreak
    //     0b0000000 00001 00000 000 00000 11100 11;
    return 0b0000000000010000000000001110011;
  }
}

void npc_exu_ebreak()
{
  contextp->gotFinish(true);
  printf("npc_exu_ebreak\n");
}

void sim(int argc, char **argv)
{
  contextp = new VerilatedContext;
  contextp->commandArgs(argc, argv);
  Vtop *top = new Vtop{contextp};

  reset(top, 1);
  printf("init\n");
  while (!contextp->gotFinish())
  {
    contextp->timeInc(1);
    top->inst = pmem_read(top->pc);
    single_cycle(top);
    printf("c> pc: 0x%016llx, inst: 0x%08x\n", top->pc, top->inst);
    for (size_t i = 0; i < 8; i++)
    {
      if (i != 0 && i % 4 == 0)
        printf("\n");
      printf("c> x%2zu: 0x%016llx\t", i, top->rfout[i]);
    }
    printf("\n");
  }
  delete top;
  delete contextp;
}

int main(int argc, char **argv)
{
  sim(argc, argv);
  return 0;
}
