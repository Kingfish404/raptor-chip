#include <common.h>
#include <difftest.h>
#include <readline/readline.h>
#include <readline/history.h>
#include <npc_verilog.h>
#include <verilated_vcd_c.h>
#ifdef CONFIG_NVBoard
#include <nvboard.h>
#endif

#define MAX_INST_TO_PRINT 10
#define MAX_IRING_SIZE 16

extern NPCState npc;
extern PMUState pmu;

extern VerilatedContext *contextp;
extern TOP_NAME *top;
extern VerilatedVcdC *tfp;

word_t prev_pc = 0;
word_t g_timer = 0;

#ifdef CONFIG_ITRACE
static char iringbuf[MAX_IRING_SIZE][128] = {};
static uint64_t iringhead = 0;
#endif

float percentage(int a, int b)
{
  return (b == 0) ? 0 : (100.0 * a / b);
}

static void perf()
{
  Log(FMT_BLUE("#Inst: %lld, Cycle: %llu, IPC: %.3f"), pmu.instr_cnt, pmu.active_cycle, (1.0 * pmu.instr_cnt / pmu.active_cycle));

  Log(FMT_BLUE("IFU Fetch: %lld, LSU Load: %lld, EXU ALU: %lld"),
      pmu.ifu_fetch_cnt, pmu.lsu_load_cnt, pmu.exu_alu_cnt);
  Log(FMT_BLUE("LD  Inst: %lld (%2.1f%%), ST Inst: %lld, (%2.1f%%)"),
      pmu.ld_inst_cnt, percentage(pmu.ld_inst_cnt, pmu.instr_cnt),
      pmu.st_inst_cnt, percentage(pmu.st_inst_cnt, pmu.instr_cnt));
  Log(FMT_BLUE("ALU Inst: %lld (%2.1f%%), BR Inst: %lld, (%2.1f%%)"),
      pmu.alu_inst_cnt, percentage(pmu.alu_inst_cnt, pmu.instr_cnt),
      pmu.b_inst_cnt, percentage(pmu.b_inst_cnt, pmu.instr_cnt));
  Log(FMT_BLUE("CSR Inst: %lld (%2.1f%%)"),
      pmu.csr_inst_cnt, percentage(pmu.csr_inst_cnt, pmu.instr_cnt));
  Log(FMT_BLUE("Other Inst: %lld (%2.1f%%)"),
      pmu.other_inst_cnt, percentage(pmu.other_inst_cnt, pmu.instr_cnt));
  assert(
      pmu.ifu_fetch_cnt == pmu.instr_cnt);
  assert(
      pmu.instr_cnt ==
      (pmu.ld_inst_cnt + pmu.st_inst_cnt +
       pmu.alu_inst_cnt + pmu.b_inst_cnt +
       pmu.csr_inst_cnt +
       pmu.other_inst_cnt));
}

static void perf_sample_per_cycle()
{
  pmu.active_cycle++;
  if (*(uint8_t *)&(CONCAT(VERILOG_PREFIX, __DOT__ifu_valid)))
  {
    pmu.ifu_fetch_cnt++;
  }
  if (*(uint8_t *)&(CONCAT(VERILOG_PREFIX, __DOT__exu__DOT__lsu_valid)))
  {
    pmu.lsu_load_cnt++;
  }
  if (*(uint8_t *)&(CONCAT(VERILOG_PREFIX, __DOT__exu_valid)))
  {
    pmu.exu_alu_cnt++;
  }
}

static void perf_sample_per_inst()
{
  pmu.instr_cnt++;
  switch (*(uint8_t *)&(CONCAT(VERILOG_PREFIX, __DOT__exu__DOT__opcode_exu)))
  {
  case 0b0000011:
    pmu.ld_inst_cnt++;
    break;
  case 0b0100011:
    pmu.st_inst_cnt++;
    break;
  case 0b0110011:
  case 0b0010011:
    pmu.alu_inst_cnt++;
    break;
  case 0b1100011:
    pmu.b_inst_cnt++;
    break;
  case 0b1110011:
    pmu.csr_inst_cnt++;
    break;
  default:
    pmu.other_inst_cnt++;
    break;
  }
}

static void statistic()
{
  perf();
  double time_s = g_timer / 1e6;
  double frequency = pmu.active_cycle / time_s;
  Log(FMT_BLUE(
          "time: %d (ns), %d (ms)"),
      g_timer, (int)(g_timer / 1e3));
  Log(FMT_BLUE("Simulate Freq: %.3f Hz, %.3d MHz"), frequency, (int)(frequency / 1e3));
  Log(FMT_BLUE("Inst: %.3f Inst/s, %.1f KInst/s"),
      pmu.instr_cnt / time_s, pmu.instr_cnt / time_s / 1e3);
  Log("%s at pc: " FMT_WORD_NO_PREFIX ", inst: " FMT_WORD_NO_PREFIX,
      ((*npc.ret) == 0 && npc.state != NPC_ABORT
           ? FMT_GREEN("HIT GOOD TRAP")
           : FMT_RED("HIT BAD TRAP")),
      (*npc.pc), *(npc.inst));
}

static void cpu_exec_one_cycle()
{
#ifdef CONFIG_NVBoard
  nvboard_update();
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

  prev_pc = *(npc.pc);
  uint64_t now = get_time();
  uint64_t cur_inst_cycle = 0;
  while (!contextp->gotFinish() && npc.state == NPC_RUNNING && n-- > 0)
  {
    cpu_exec_one_cycle();
    // Simulate the performance monitor unit
    perf_sample_per_cycle();
    cur_inst_cycle++;
    if (cur_inst_cycle > 0x2fff)
    {
      Log("Too many cycles for one instruction, maybe a bug.");
      npc.state = NPC_ABORT;
      break;
    }
    if (prev_pc != *(npc.pc))
    {
      perf_sample_per_inst();
      cur_inst_cycle = 0;
      fflush(stdout);
#ifdef CONFIG_ITRACE
      snprintf(
          iringbuf[iringhead], sizeof(iringbuf[0]),
          FMT_WORD_NO_PREFIX ": " FMT_WORD_NO_PREFIX "\t",
          prev_pc, *(npc.inst));
      int len = strlen(iringbuf[iringhead]);
      disassemble(
          iringbuf[iringhead] + len, sizeof(iringbuf[0]), prev_pc, (uint8_t *)(npc.inst), 4);
      iringhead = (iringhead + 1) % MAX_IRING_SIZE;
#endif

#ifdef CONFIG_DIFFTEST
      difftest_step(*npc.pc);
#endif
      prev_pc = *(npc.pc);
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
