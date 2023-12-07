#include <common.h>
#include <difftest.h>
#include <mem.h>
#include <readline/readline.h>
#include <readline/history.h>
#include "Vtop.h"
#include "verilated_vcd_c.h"

#define MAX_INST_TO_PRINT 10
#define MAX_IRING_SIZE 16

extern NPCState npc;

extern VerilatedContext *contextp;
extern Vtop *top;
extern VerilatedVcdC *tfp;

uint64_t g_timer = 0;
uint64_t g_nr_guest_inst = 0;

static char iringbuf[MAX_IRING_SIZE][128] = {};
static uint64_t iringhead = 0;

void cpu_exec_one_cycle()
{
  pmem_read(*(npc.pc), (word_t *)&(top->inst));

  top->clk = (top->clk == 0) ? 1 : 0;
  top->eval();
  if (tfp)
  {
    tfp->dump(contextp->time());
  }
  contextp->timeInc(1);

  top->clk = (top->clk == 0) ? 1 : 0;
  top->eval();
  if (tfp)
  {
    tfp->dump(contextp->time());
  }
  contextp->timeInc(1);
  if (tfp)
  {
    tfp->flush();
  }
}

void disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);

void cpu_exec(uint64_t n)
{
  while (!contextp->gotFinish() && npc.state == NPC_RUNNING && n-- > 0)
  {
    uint64_t now = get_time();
    cpu_exec_one_cycle();
    g_timer += get_time() - now;
    g_nr_guest_inst++;
    snprintf(
        iringbuf[iringhead], sizeof(iringbuf[0]),
        FMT_WORD_NO_PREFIX ": " FMT_WORD_NO_PREFIX "\t",
        *(npc.pc), top->inst);
    int len = strlen(iringbuf[iringhead]);
    disassemble(
        iringbuf[iringhead] + len, sizeof(iringbuf[0]), *npc.pc, (uint8_t *)&top->inst, 4);
    iringhead = (iringhead + 1) % MAX_IRING_SIZE;
    difftest_step(*npc.pc);
  }
}

void cpu_show_itrace()
{
  for (int i = iringhead + 1 % MAX_IRING_SIZE; i != iringhead; i = (i + 1) % MAX_IRING_SIZE)
  {
    if (iringbuf[i][0] == '\0')
    {
      continue;
    }
    printf("%s\n", iringbuf[i]);
  }
}