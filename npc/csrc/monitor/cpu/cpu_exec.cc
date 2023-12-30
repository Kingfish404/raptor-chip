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

word_t prev_pc = 0;
uint64_t g_timer = 0;
uint64_t g_nr_guest_inst = 0;

#ifdef CONFIG_ITRACE
static char iringbuf[MAX_IRING_SIZE][128] = {};
static uint64_t iringhead = 0;
#endif

static void statistic()
{
  double time_s = g_timer / 1e6;
  double frequency = contextp->time() / 2 / time_s;
  Log(FMT_BLUE("nr_inst = %llu, time = %llu (ns)"), g_nr_guest_inst, g_timer);
  Log(FMT_BLUE("Freq = %.3f Hz"), frequency);
  Log(FMT_BLUE("Inst = %.3f inst/s"), g_nr_guest_inst / time_s);
  Log("%s at pc = " FMT_WORD_NO_PREFIX ", inst: " FMT_WORD_NO_PREFIX,
      ((*npc.ret) == 0 && npc.state != NPC_ABORT
           ? FMT_GREEN("HIT GOOD TRAP")
           : FMT_RED("HIT BAD TRAP")),
      (*npc.pc), top->inst);
}

static void cpu_exec_one_cycle()
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
    tfp->flush();
  }
  contextp->timeInc(1);
}

void cpu_show_itrace()
{
#ifdef CONFIG_ITRACE
  for (int i = iringhead + 1 % MAX_IRING_SIZE; i != iringhead; i = (i + 1) % MAX_IRING_SIZE)
  {
    if (iringbuf[i][0] == '\0')
    {
      continue;
    }
    if ((i + 1) % MAX_IRING_SIZE == iringhead)
    {
      printf(" => %s\n", iringbuf[i]);
    }
    else
    {
      printf("    %s\n", iringbuf[i]);
    }
  }
#else
  printf("itrace is not enabled\n");
#endif
}

void disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);

void cpu_exec(uint64_t n)
{
  switch (npc.state)
  {
  case NPC_END:
  case NPC_ABORT:
    printf("Program execution has ended. To restart the program, exit NEMU and run again.\n");
    return;
  default:
    npc.state = NPC_RUNNING;
    break;
  }

  uint64_t now = get_time();
  while (!contextp->gotFinish() && npc.state == NPC_RUNNING && n-- > 0)
  {
    prev_pc = *(npc.pc);
    cpu_exec_one_cycle();
    g_nr_guest_inst++;
    fflush(stdout);

#ifdef CONFIG_ITRACE
    snprintf(
        iringbuf[iringhead], sizeof(iringbuf[0]),
        FMT_WORD_NO_PREFIX ": " FMT_WORD_NO_PREFIX "\t",
        prev_pc, top->inst);
    int len = strlen(iringbuf[iringhead]);
    disassemble(
        iringbuf[iringhead] + len, sizeof(iringbuf[0]), *npc.pc, (uint8_t *)&top->inst, 4);
    iringhead = (iringhead + 1) % MAX_IRING_SIZE;
#endif

#ifdef CONFIG_DIFFTEST
    difftest_step(*npc.pc);
#endif
  }
  g_timer += get_time() - now;

  switch (npc.state)
  {
  case NPC_RUNNING:
    npc.state = NPC_STOP;
    break;
  case NPC_END:
    if (*npc.ret != 0)
    {
      Log("a0 = " FMT_RED(FMT_WORD), *npc.ret);
    }
  case NPC_ABORT:
    if (npc.state == NPC_ABORT)
    {
      Log("Program execution has aborted.");
      cpu_show_itrace();
      reg_display(GPR_SIZE);
    }
  case NPC_QUIT:
    statistic();
    break;
  default:
    assert(0);
    break;
  }
}
