#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include "Vexample.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

int main(int argc, char **argv)
{
  VerilatedContext *contextp = new VerilatedContext;
  contextp->commandArgs(argc, argv);
  Vexample *top = new Vexample{contextp};
  Verilated::traceEverOn(true);
  VerilatedVcdC *tfp = new VerilatedVcdC;
  top->trace(tfp, 99);
  tfp->open("main.vcd");
  int count = 0;
  while (!contextp->gotFinish())
  {
    int a = rand() & 1;
    int b = rand() & 1;
    top->a = a;
    top->b = b;
    contextp->timeInc(1);
    top->eval();
    tfp->dump(contextp->time());
    printf("a = %d, b = %d, f = %d\n", a, b, top->f);
    assert(top->f == (a ^ b));
    if (count++ > 100)
    {
      break;
    }
  }
  tfp->close();
  delete tfp;
  delete top;
  delete contextp;
  return 0;
}
