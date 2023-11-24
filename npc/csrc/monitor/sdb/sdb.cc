#include <common.h>
#include "Vtop.h"
#include "Vtop___024root.h"
#include "Vtop__Dpi.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

uint8_t pmem[MSIZE];
struct CPU
{
  word_t *gpr;
  uint32_t *pc;
} cpu;

const char *regs[] = {
    "$0", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"};

void sdb_set_batch_mode()
{
}

VerilatedContext *contextp = NULL;
Vtop *top = NULL;
VerilatedVcdC *tfp = NULL;

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

static inline word_t host_read(void *addr, int len)
{
  switch (len)
  {
  case 1:
    return *(uint8_t *)addr;
  case 2:
    return *(uint16_t *)addr;
  case 4:
    return *(uint32_t *)addr;
  case 8:
    return *(uint64_t *)addr;
  default:
    assert(0);
  }
}

uint32_t pmem_read(uint64_t addr)
{
  if (addr >= MBASE && addr < MBASE + MSIZE)
  {
    return host_read(pmem + addr - MBASE, 4);
  }
  return 0;
}

void npc_exu_ebreak()
{
  contextp->gotFinish(true);
  printf("npc_exu_ebreak\n");
}

void reg_show(Vtop *top, int n = 4)
{
  printf(" pc: " FMT_GREEN(FMT_WORD) " inst: " FMT_GREEN(FMT_WORD) "\n",
         *(cpu.pc), top->inst);
  for (size_t i = 0; i < n; i++)
  {
    if (i != 0 && i % 4 == 0)
      printf("\n");
    printf("%3s: " FMT_WORD " ", regs[i], cpu.gpr[i]);
  }
  printf("\n");
}

int reg_str2idx(const char *reg)
{
  for (size_t i = 0; i < GPR_SIZE; i++)
  {
    if (strcmp(reg, regs[i]) == 0)
      return i;
  }
  return -1;
}

void sim(int argc, char **argv)
{
  contextp = new VerilatedContext;
  contextp->commandArgs(argc, argv);
  top = new Vtop{contextp};
  Verilated::traceEverOn(true);
  tfp = new VerilatedVcdC;
  top->trace(tfp, 99);
  tfp->open("npc.vcd");

  cpu.gpr = (word_t *)&(top->rootp->top__DOT__regs__DOT__rf);
  cpu.pc = (uint32_t *)&(top->rootp->top__DOT__pc);

  reset(top, 1);
  while (!contextp->gotFinish())
  {
    top->clk = 0;
    top->inst = pmem_read(*(cpu.pc));
    top->eval();
    tfp->dump(contextp->time());
    contextp->timeInc(1);

    top->clk = 1;
    top->eval();
    tfp->dump(contextp->time());
    contextp->timeInc(1);
    reg_show(top, 8);
    tfp->flush();
  }
  printf("Simulation ends\n");
  reg_show(top, GPR_SIZE);
  tfp->close();
  delete tfp;
  delete top;
  delete contextp;
}