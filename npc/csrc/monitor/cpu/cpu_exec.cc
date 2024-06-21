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

PMUState pmu = {
    .active_cycle = 0,
    .instr_cnt = 0,
    .ifu_fetch_cnt = 0,
    .lsu_load_cnt = 0,
    .exu_alu_cnt = 0,
};

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
  printf("======== Instruction Analysis ========\n");
  Log(FMT_BLUE("Cycle: %llu, #Inst: %lld, IPC: %.3f"), pmu.active_cycle, pmu.instr_cnt, (1.0 * pmu.instr_cnt / pmu.active_cycle));
  printf("| %8s | %8s | %8s | %8s | %8s | %8s | %8s | %8s | %8s |\n",
         "IFU", "LSU", "EXU", "LD", "ST", "ALU", "BR", "CSR", "OTH");
  printf("| %8lld | %8lld | %8lld | %8lld | %8lld | %8lld | %8lld | %8lld | %8lld |\n",
         pmu.ifu_fetch_cnt, pmu.lsu_load_cnt, pmu.exu_alu_cnt,
         pmu.ld_inst_cnt, pmu.st_inst_cnt, pmu.alu_inst_cnt,
         pmu.b_inst_cnt, pmu.csr_inst_cnt, pmu.other_inst_cnt);
  printf("| %7lld, %4.1f%% |  %7lld, %4.1f%% |  %7lld, %4.1f%% |  %7lld, %4.1f%% |  %7lld, %4.1f%% |  %7lld, %4.1f%% |  %7lld, %4.1f%% |  %7lld, %4.1f%% |  %7lld, %4.1f%% |",
         pmu.ifu_stall_cycle, percentage(pmu.ifu_stall_cycle, pmu.active_cycle),
         pmu.lsu_stall_cycle, percentage(pmu.lsu_stall_cycle, pmu.active_cycle),
         (pmu.ifu_stall_cycle + 1) * 1.0 / pmu.ifu_fetch_cnt,
         (pmu.lsu_stall_cycle + 1) * 1.0 / pmu.lsu_load_cnt,
         pmu.ld_inst_cnt, percentage(pmu.ld_inst_cnt, pmu.instr_cnt),
         pmu.st_inst_cnt, percentage(pmu.st_inst_cnt, pmu.instr_cnt),
         pmu.alu_inst_cnt, percentage(pmu.alu_inst_cnt, pmu.instr_cnt),
         pmu.b_inst_cnt, percentage(pmu.b_inst_cnt, pmu.instr_cnt),
         pmu.csr_inst_cnt, percentage(pmu.csr_inst_cnt, pmu.instr_cnt),
         pmu.other_inst_cnt, percentage(pmu.other_inst_cnt, pmu.instr_cnt));

  Log("IFU Fetch: %8lld, LSU Load: %8lld, EXU ALU: %lld",
      pmu.ifu_fetch_cnt, pmu.lsu_load_cnt, pmu.exu_alu_cnt);
  Log("LD  Inst: %8lld (%4.1f%%), ST Inst: %8lld, (%4.1f%%)",
      pmu.ld_inst_cnt, percentage(pmu.ld_inst_cnt, pmu.instr_cnt),
      pmu.st_inst_cnt, percentage(pmu.st_inst_cnt, pmu.instr_cnt));
  Log("ALU Inst: %8lld (%4.1f%%), BR Inst: %8lld, (%4.1f%%)",
      pmu.alu_inst_cnt, percentage(pmu.alu_inst_cnt, pmu.instr_cnt),
      pmu.b_inst_cnt, percentage(pmu.b_inst_cnt, pmu.instr_cnt));
  Log("CSR Inst: %8lld (%4.1f%%)",
      pmu.csr_inst_cnt, percentage(pmu.csr_inst_cnt, pmu.instr_cnt));
  Log("Oth Inst: %8lld (%4.1f%%)",
      pmu.other_inst_cnt, percentage(pmu.other_inst_cnt, pmu.instr_cnt));
  printf("======== TOP DOWN Analysis ========\n");
  Log(FMT_BLUE("IFU Stall: %8lld (%4.1f%%), LSU Stall: %8lld (%4.1f%%)"),
      pmu.ifu_stall_cycle, percentage(pmu.ifu_stall_cycle, pmu.active_cycle),
      pmu.lsu_stall_cycle, percentage(pmu.lsu_stall_cycle, pmu.active_cycle));
  // show average IF cycle and LS cycle
  Log(FMT_BLUE("IFU Avg Cycle: %2.1f, LSU Avg Cycle: %2.1f"),
      (1.0 * pmu.ifu_stall_cycle + 1) / pmu.ifu_fetch_cnt,
      (1.0 * pmu.lsu_stall_cycle + 1) / pmu.lsu_load_cnt);
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
  bool ifu_valid = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, __DOT__ifu_valid));
  bool lsu_valid = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, __DOT__exu__DOT__lsu_valid));
  if (ifu_valid)
  {
    pmu.ifu_fetch_cnt++;
  }
  if (!ifu_valid &&
      *(uint8_t *)&(CONCAT(VERILOG_PREFIX, __DOT__ifu__DOT__pvalid)))
  {
    pmu.ifu_stall_cycle++;
  }
  if (lsu_valid)
  {
    pmu.lsu_load_cnt++;
  }
  if (!lsu_valid &&
      *(uint8_t *)&(CONCAT(VERILOG_PREFIX, __DOT__exu__DOT__lsu_avalid)))
  {
    pmu.lsu_stall_cycle++;
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
  Log("time: %d (ns), %d (ms)", g_timer, (int)(g_timer / 1e3));
  Log(FMT_BLUE("Simulate Freq: %9.1f Hz, %4d MHz"), frequency, (int)(frequency / 1e3));
  Log(FMT_BLUE("Simulate Inst: %9.1f I/s, %3.0f KInst/s"),
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
    if (cur_inst_cycle > 0xfffff)
    {
      Log("Too many cycles for one instruction (0x%llx), maybe a bug.", cur_inst_cycle);
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
