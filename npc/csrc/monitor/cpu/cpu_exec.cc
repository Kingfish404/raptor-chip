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

PMUState pmu;

extern VerilatedContext *contextp;
extern TOP_NAME *top;
extern VerilatedVcdC *tfp;

word_t g_timer = 0;

#ifdef CONFIG_ITRACE
static char iringbuf[MAX_IRING_SIZE][128] = {};
static uint64_t iringhead = 0;
#endif

float percentage(int a, int b)
{
  float ret = (b == 0) ? 0 : (100.0 * a / b);
  return ret == 100.0 ? 99.0 : ret;
}

static void perf()
{
  printf("======== Instruction Analysis ========\n");
  Log(FMT_BLUE("Cycle: %llu, #Inst: %lld, IPC: %.3f"), pmu.active_cycle, pmu.instr_cnt, (1.0 * pmu.instr_cnt / pmu.active_cycle));
  printf("| %8s,  %% | %8s,  %% | %8s,  %% | %6s, %% | %6s, %% | %6s, %% | %6s, %% | %3s, %% | %5s, %% |\n",
         "IFU", "LSU", "EXU", "LD", "ST", "ALU", "BR", "CSR", "OTH");
  printf("| %8lld,%3.0f | %8lld,%3.0f | %8lld,%3.0f | %6lld,%2.0f | %6lld,%2.0f | %6lld,%2.0f | %6lld,%2.0f | %3lld,%2.0f | %5lld,%2.0f |\n",
         (long long)pmu.ifu_fetch_stall_cycle, percentage(pmu.ifu_fetch_stall_cycle, pmu.active_cycle),
         (long long)pmu.lsu_stall_cycle, percentage(pmu.lsu_stall_cycle, pmu.active_cycle),
         (long long)pmu.exu_alu_cnt, percentage(pmu.exu_alu_cnt, pmu.instr_cnt),
         (long long)pmu.ld_inst_cnt, percentage(pmu.ld_inst_cnt, pmu.instr_cnt),
         (long long)pmu.st_inst_cnt, percentage(pmu.st_inst_cnt, pmu.instr_cnt),
         (long long)pmu.alu_inst_cnt, percentage(pmu.alu_inst_cnt, pmu.instr_cnt),
         (long long)pmu.b_inst_cnt, percentage(pmu.b_inst_cnt, pmu.instr_cnt),
         (long long)pmu.csr_inst_cnt, percentage(pmu.csr_inst_cnt, pmu.instr_cnt),
         (long long)pmu.other_inst_cnt, percentage(pmu.other_inst_cnt, pmu.instr_cnt));
  printf("======== TOP DOWN Analysis ========\n");
  printf("| %8s,  %% | %8s,  %% | %8s,  %% | %8s,  %% | %8s,  %% |\n",
         "IFU", "LSU", "EXU", "LD", "ST");
  printf("| %8lld,%3.0f | %8lld,%3.0f | %8lld,%3.0f | %8lld,%3.0f | %8lld,%3.0f |\n",
         pmu.ifu_fetch_stall_cycle, percentage(pmu.ifu_fetch_stall_cycle, pmu.active_cycle),
         pmu.lsu_stall_cycle, percentage(pmu.lsu_stall_cycle, pmu.active_cycle),
         pmu.exu_alu_cnt, percentage(pmu.exu_alu_cnt, pmu.instr_cnt),
         pmu.ld_inst_cnt, percentage(pmu.ld_inst_cnt, pmu.instr_cnt),
         pmu.st_inst_cnt, percentage(pmu.st_inst_cnt, pmu.instr_cnt));
  // show average IF cycle and LS cycle
  Log(FMT_BLUE("IFU Avg Cycle: %2.1f, LSU Avg Cycle: %2.1f"),
      (1.0 * pmu.ifu_fetch_stall_cycle) / (pmu.ifu_fetch_cnt + 1),
      (1.0 * pmu.lsu_stall_cycle) / (pmu.lsu_load_cnt + 1));
  printf("ifu_stall_cycle: %lld, ifu_fetch_cnt: %lld\n", pmu.ifu_fetch_stall_cycle, pmu.ifu_fetch_cnt);
  Log(FMT_BLUE("ifu_fetch_cnt: %lld, instr_cnt: %lld"), pmu.ifu_fetch_cnt, pmu.instr_cnt);
  assert(pmu.ifu_fetch_cnt == pmu.instr_cnt);
  assert(
      pmu.instr_cnt ==
      (pmu.ld_inst_cnt + pmu.st_inst_cnt + pmu.alu_inst_cnt + pmu.b_inst_cnt +
       pmu.csr_inst_cnt + pmu.other_inst_cnt));
  printf("======== Cache Analysis ========\n");
  // AMAT: Average Memory Access Time
  printf("| %8s, %% | %8s, %% | %8s, %% | %8s, %% | %13s | %13s | %8s |\n",
         "HIT", "MISS", "HIT CYC", "MISS CYC", "HIT Cost AVG", "MISS Cost AVG", "AMAT");
  double l1i_hit_rate = percentage(pmu.l1i_cache_hit_cnt, pmu.l1i_cache_hit_cnt + pmu.l1i_cache_miss_cnt);
  double l1i_access_time = pmu.l1i_cache_hit_cycle / (pmu.l1i_cache_hit_cnt + 1);
  double l1i_miss_penalty = pmu.l1i_cache_miss_cycle / (pmu.l1i_cache_miss_cnt + 1);
  printf("| %8lld,%2.0f | %8lld,%2.0f | %8lld,%2.0f | %8lld,%2.0f | %13lld | %13lld | %8.1f |\n",
         pmu.l1i_cache_hit_cnt, l1i_hit_rate,
         pmu.l1i_cache_miss_cnt, 100 - l1i_hit_rate,
         pmu.l1i_cache_hit_cycle, percentage(pmu.l1i_cache_hit_cycle, pmu.l1i_cache_hit_cycle + pmu.l1i_cache_miss_cycle),
         pmu.l1i_cache_miss_cycle, percentage(pmu.l1i_cache_miss_cycle, pmu.l1i_cache_hit_cycle + pmu.l1i_cache_miss_cycle),
         (long long)l1i_access_time, (long long)l1i_miss_penalty,
         l1i_access_time + (100 - l1i_hit_rate) / 100.0 * l1i_miss_penalty);
  assert(
      (pmu.l1i_cache_hit_cnt + pmu.l1i_cache_miss_cnt) == pmu.ifu_fetch_cnt);
  printf("pmu.l1i_cache_hit_cnt + pmu.l1i_cache_miss_cnt = %lld\n", pmu.l1i_cache_hit_cnt + pmu.l1i_cache_miss_cnt);
  printf("pmu.ifu_fetch_cnt = %lld\n", pmu.ifu_fetch_cnt);
}

static void perf_sample_per_cycle()
{
  if (top->reset)
  {
    return;
  }
  pmu.active_cycle++;
  bool ifu_valid = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, ifu_valid));
  bool ifu_stall = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, ifu__DOT__ifu_stall));
  bool idu_ready = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, idu_ready));
  bool idu_valid = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, idu_valid));
  bool exu_ready = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, exu_ready));
  bool exu_valid = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, exu_valid));
  bool wbu_ready = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, wbu_ready));
  bool wbu_valid = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, wbu_valid));
  uint8_t l1i_state = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, ifu__DOT__l1i_state));
  bool l1i_cache_hit = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, ifu__DOT__l1i_cache_hit));
  bool lsu_valid = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, exu__DOT__lsu_valid));
  uint32_t pc_ifu = *(uint32_t *)&(CONCAT(VERILOG_PREFIX, ifu__DOT__pc_ifu));
  uint32_t pc_idu = *(uint32_t *)&(CONCAT(VERILOG_PREFIX, idu__DOT__pc_idu));
  uint32_t pc_exu = *(uint32_t *)&(CONCAT(VERILOG_PREFIX, exu__DOT__pc_exu));
  uint32_t pc_wbu = *(uint32_t *)&(CONCAT(VERILOG_PREFIX, wbu__DOT__pc_wbu));
  static uint32_t ifu_pc = 0;
  if (ifu_valid && idu_ready)
  {
    pmu.ifu_fetch_cnt++;
  }
  if (!ifu_valid && (l1i_state == 0b000 || l1i_state == 0b001 ||
                     l1i_state == 0b010 || l1i_state == 0b011))
  {
    pmu.ifu_fetch_stall_cycle++;
  }
  if (ifu_stall)
  {
    pmu.ifu_stall_cycle++;
  }
  if (lsu_valid)
  {
    pmu.lsu_load_cnt++;
  }
  if (!lsu_valid && *(uint8_t *)&(CONCAT(VERILOG_PREFIX, exu__DOT__lsu_avalid)))
  {
    pmu.lsu_stall_cycle++;
  }
  if (exu_valid)
  {
    pmu.exu_alu_cnt++;
  }
  // cache sample
  static bool i_fetching = false;
  if (i_fetching == false)
  {
    if (!(ifu_valid && idu_ready) && l1i_state == 0b000)
    {
      i_fetching = true;
      pmu.l1i_cache_miss_cnt++;
      pmu.l1i_cache_miss_cycle++;
      pmu.l1i_cache_hit_cnt = pmu.ifu_fetch_cnt - pmu.l1i_cache_miss_cnt;
      pmu.l1i_cache_hit_cycle = pmu.l1i_cache_hit_cnt;
    }
  }
  else
  {
    if (ifu_valid && l1i_state == 0b011)
    {
      i_fetching = false;
    }
    else
    {
      pmu.l1i_cache_miss_cycle++;
    }
  }
}

static void perf_sample_per_inst()
{
  if (top->reset)
  {
    return;
  }
  pmu.instr_cnt++;
  switch (*(uint8_t *)&(CONCAT(VERILOG_PREFIX, exu__DOT__opcode_exu)))
  {
  case 0b0000011: // I type: lb, lh, lw, lbu, lhu
    pmu.ld_inst_cnt++;
    break;
  case 0b0100011: // S type: sb, sh, sw
    pmu.st_inst_cnt++;
    break;
  case 0b0110011: // R type: add, sub, sll, slt, sltu, xor, srl, sra, or, and
  case 0b0010011: // I type: addi, slti, sltiu, xori, ori, andi, slli, srli, srai
    pmu.alu_inst_cnt++;
    break;
  case 0b1100011: // B type: beq, bne, blt, bge, bltu, bgeu
    pmu.b_inst_cnt++;
    break;
  case 0b1110011: // N type: ecall, ebreak, csrrw, csrrs, csrrc, csrrwi, csrrsi, csrrci, mert
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
  uint64_t time_clint = *(uint64_t *)&(CONCAT(VERILOG_PREFIX, bus__DOT__clint__DOT__mtime));
  uint64_t time_clint_us = time_clint / 2;
  Log("CLINT time: %lld (us), %2.3f MIPS", (time_clint_us), (double)((pmu.instr_cnt / 1e6) / (time_clint_us / 1e6)));
  double frequency = pmu.active_cycle / time_s;
  Log(FMT_BLUE("Simulate time: %d (ns), %d (ms)"), g_timer, (int)(g_timer / 1e3));
  Log(FMT_BLUE("Simulate Freq: %9.1f Hz, %6.3f MHz"), frequency, (double)(frequency * 1.0 / 1e6));
  Log(FMT_BLUE("Simulate Inst: %9.1f I/s, %5.3f MIPS"),
      pmu.instr_cnt / time_s, pmu.instr_cnt / time_s / 1e6);
  Log("%s at pc: " FMT_WORD_NO_PREFIX ", inst: " FMT_WORD_NO_PREFIX,
      ((*npc.ret) == 0 && npc.state != NPC_ABORT
           ? FMT_GREEN("HIT GOOD TRAP")
           : FMT_RED("HIT BAD TRAP")),
      *(npc.pc), *(npc.inst));
}

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
      Log(FMT_RED("Too many cycles (0x%llx cycle) at pc %x, maybe a bug."), cur_inst_cycle, *npc.pc);
      npc.state = NPC_ABORT;
      break;
    }
    if (*(uint8_t *)&(CONCAT(VERILOG_PREFIX, wbu_valid)))
    {
      perf_sample_per_inst();
      cur_inst_cycle = 0;
      fflush(stdout);
#ifdef CONFIG_ITRACE
      snprintf(
          iringbuf[iringhead], sizeof(iringbuf[0]),
          FMT_WORD_NO_PREFIX ": " FMT_WORD_NO_PREFIX "\t",
          *npc.cpc, *(npc.inst));
      int len = strlen(iringbuf[iringhead]);
      disassemble(
          iringbuf[iringhead] + len, sizeof(iringbuf[0]), *npc.cpc, (uint8_t *)(npc.inst), 4);
      iringhead = (iringhead + 1) % MAX_IRING_SIZE;
#endif

#ifdef CONFIG_DIFFTEST
      difftest_step(*npc.pc);
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
