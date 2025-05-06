#include <common.h>
#include <difftest.h>
#include <readline/readline.h>
#include <readline/history.h>
#include <npc_verilog.h>
#include "verilated_fst_c.h"
#ifdef CONFIG_NVBoard
#include <nvboard.h>
#endif

#define MAX_INST_TO_PRINT 10
#define MAX_IRING_SIZE 16

extern NPCState npc;
extern PMUState pmu;
extern word_t g_timer;

extern VerilatedContext *contextp;
extern TOP_NAME *top;
extern VerilatedFstC *tfp;

#ifdef CONFIG_ITRACE
static char iringbuf[MAX_IRING_SIZE][128] = {};
static uint64_t iringhead = 0;
#endif

void perf();

void perf_sample_per_cycle();

void perf_sample_per_inst();

void statistic();

static void cpu_exec_one_cycle()
{
#ifdef CONFIG_NVBoard
  if (!top->reset)
  {
    nvboard_update();
  }
#endif

  top->clock = (top->clock == 0) ? 1 : 0;
  top->eval();
  if (tfp)
  {
    tfp->dump(contextp->time());
  }
  contextp->timeInc(1);

  top->clock = (top->clock == 0) ? 1 : 0;
  top->eval();
  if (tfp)
  {
    tfp->dump(contextp->time());
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
      printf("-> %s\n", iringbuf[i]);
    }
    else
    {
      printf("   %s\n", iringbuf[i]);
    }
  }
#else
  printf("itrace is not enabled\n");
#endif
}

void cpu_exec_init()
{
  memset(&pmu, 0, sizeof(pmu));
}

void cpu_exec(uint64_t n)
{
  switch (npc.state)
  {
  case NPC_END:
  case NPC_ABORT:
    printf("Program execution has ended. To restart the program, exit NEMU and run again.\n");
    return;
  case NPC_QUIT:
    printf("Program execution has been quitted.\n");
    break;
  default:
    npc.state = NPC_RUNNING;
    break;
  }

  uint64_t now = get_time();
  uint64_t cur_inst_cycle = 0;
  while (!contextp->gotFinish() && npc.state == NPC_RUNNING && n-- > 0)
  {
    cpu_exec_one_cycle();
    if (npc.state == NPC_END) // for ebreak
    {
      pmu.instr_cnt++;
      pmu.csr_inst_cnt++;
      break;
    }
    // Simulate the performance monitor unit
    perf_sample_per_cycle();
    cur_inst_cycle++;
    if (cur_inst_cycle > 0x1ffff)
    {
      Log(FMT_RED("Too many cycles (0x%llx) stalled at pc: %x."), cur_inst_cycle, *npc.pc);
      npc.state = NPC_ABORT;
      break;
    }
    if (*(uint8_t *)&(CONCAT(VERILOG_PREFIX, wbu__DOT__valid)))
    {
      perf_sample_per_inst();
      cur_inst_cycle = 0;
#ifdef CONFIG_ITRACE
      snprintf(
          iringbuf[iringhead], sizeof(iringbuf[0]),
          FMT_WORD_NO_PREFIX ": " FMT_WORD_NO_PREFIX "\t",
          *npc.cpc, *(npc.inst));
      int len = strlen(iringbuf[iringhead]);
      void disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);
      disassemble(
          iringbuf[iringhead] + len, sizeof(iringbuf[0]), *npc.cpc, (uint8_t *)(npc.inst), 4);
      iringhead = (iringhead + 1) % MAX_IRING_SIZE;
#endif

#ifdef CONFIG_DIFFTEST
      difftest_step(*npc.cpc);
#endif
      npc.last_inst = *(npc.inst);
    }
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
    if (npc.state == NPC_ABORT || *npc.ret != 0)
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
