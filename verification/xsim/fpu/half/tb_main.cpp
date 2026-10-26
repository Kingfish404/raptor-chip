#include "Vrapt_fpu_half_tb.h"
#include "verilated.h"

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vrapt_fpu_half_tb top;
  top.clock = 0;
  top.reset = 1;
  for (int cycle = 0; cycle < 2000 && !Verilated::gotFinish(); ++cycle) {
    if (cycle == 4) top.reset = 0;
    top.clock = 0;
    top.eval();
    Verilated::timeInc(1);
    top.clock = 1;
    top.eval();
    Verilated::timeInc(1);
  }
  top.final();
  return Verilated::gotFinish() ? 0 : 1;
}
