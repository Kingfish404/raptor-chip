#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <pthread.h>
#include <nvboard.h>
#include "Vtop.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

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

void light(int argc, char **argv)
{
  VerilatedContext *contextp = new VerilatedContext;
  contextp->commandArgs(argc, argv);
  Vtop *top = new Vtop{contextp};
  Verilated::traceEverOn(true);
  VerilatedVcdC *tfp = new VerilatedVcdC;
  top->trace(tfp, 99);
  tfp->open("main.vcd");

  nvboard_init();
  nvboard_bind_pin(&top->led, BIND_RATE_RT, BIND_DIR_OUT, 16, LD0, LD1, LD2, LD3, LD4, LD5, LD6, LD7, LD8, LD9, LD10, LD11, LD12, LD13, LD14, LD15);
  reset(top, 10);
  while (!contextp->gotFinish())
  {
    contextp->timeInc(1);
    single_cycle(top);
    nvboard_update();
    if (contextp->time() > 100)
    {
      // break;
    }
  }
  nvboard_quit();
  tfp->close();
  delete tfp;
  delete top;
  delete contextp;
}

#ifdef DUAL_CONTROL
int dual_control(int argc, char **argv)
{
  VerilatedContext *contextp = new VerilatedContext;
  contextp->commandArgs(argc, argv);
  Vtop *top = new Vtop{contextp};
  Verilated::traceEverOn(true);
  VerilatedVcdC *tfp = new VerilatedVcdC;
  top->trace(tfp, 99);
  tfp->open("main.vcd");

  nvboard_init();
  nvboard_bind_pin(&top->a, BIND_RATE_RT, BIND_DIR_OUT, 1, LD0);
  nvboard_bind_pin(&top->b, BIND_RATE_RT, BIND_DIR_OUT, 1, LD1);
  nvboard_bind_pin(&top->f, BIND_RATE_RT, BIND_DIR_OUT, 1, LD2);
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
    nvboard_update();
    if (contextp->time() > 100)
    {
      // break;
    }
  }
  nvboard_quit();
  tfp->close();
  delete tfp;
  delete top;
  delete contextp;
}
#endif

int main(int argc, char **argv)
{
  light(argc, argv);
  return 0;
}
