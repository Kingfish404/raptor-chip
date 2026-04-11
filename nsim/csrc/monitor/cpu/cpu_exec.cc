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

extern void (*ref_difftest_exec)(uint64_t n);
extern long long int max_timeout;

#ifdef CONFIG_ITRACE
static char iringbuf[MAX_IRING_SIZE][128] = {};
static word_t iringbuf_rpc[MAX_IRING_SIZE] = {};
static word_t iringbuf_inst[MAX_IRING_SIZE] = {};
static uint64_t iringhead = 1; // set to 0 will cause format issue
#endif

void perf();

void perf_sample_per_cycle();

void perf_sample_per_inst();

void statistic();

static uint64_t wave_cycle_thres = (0x10000);
static uint64_t wave_inst_thres = (0x1000);

static int tfp_threshold_break = 0;
static uint64_t tfp_cycle = 0;
static uint64_t tfp_inst = 0;

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
  if ((tfp)                                                                                   //
      &&                                                                                      //
      ((pmu.active_cycle > (tfp_cycle > wave_cycle_thres ? tfp_cycle - wave_cycle_thres : 0)) //
       | (pmu.instr_cnt > (tfp_inst > wave_inst_thres ? tfp_inst - wave_inst_thres : 0))))
  {
    tfp->dump(contextp->time());
  }
  contextp->timeInc(1);

  top->clock = (top->clock == 0) ? 1 : 0;
  top->eval();
  if ((tfp)                                                                                   //
      &&                                                                                      //
      ((pmu.active_cycle > (tfp_cycle > wave_cycle_thres ? tfp_cycle - wave_cycle_thres : 0)) //
       | (pmu.instr_cnt > (tfp_inst > wave_inst_thres ? tfp_inst - wave_inst_thres : 0))))
  {
    tfp->dump(contextp->time());
  }
  contextp->timeInc(1);
}

void cpu_show_itrace()
{
#ifdef CONFIG_ITRACE
  void disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);
  for (int i = (iringhead + 1) % MAX_IRING_SIZE; i != iringhead; i = (i + 1) % MAX_IRING_SIZE)
  {
    if (iringbuf_rpc[i] == 0)
    {
      continue;
    }
    int len = snprintf(
        iringbuf[i], sizeof(iringbuf[0]),
        FMT_WORD_NO_PREFIX ": " FMT_WORD_NO_PREFIX "\t",
        iringbuf_rpc[i], iringbuf_inst[i]);
    if (len >= 0 && len < (int)sizeof(iringbuf[0]))
    {
      disassemble(
          iringbuf[i] + len, sizeof(iringbuf[0]) - len,
          iringbuf_rpc[i], (uint8_t *)&iringbuf_inst[i], 4);
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

void cpu_exec_set_threshold(uint64_t cycle, uint64_t inst)
{
  tfp_threshold_break = 1;
  tfp_cycle = cycle;
  tfp_inst = inst;
}

void cpu_exec_init()
{
#if defined(CONFIG_ITRACE)
  for (int i = 0; i < MAX_IRING_SIZE; i++)
  {
    iringbuf_rpc[i] = 0;
  }
#endif
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
  uint64_t progress_cycle = 0;
  uint64_t timeout_us = (max_timeout > 0) ? (uint64_t)max_timeout * 1000000 : 0;
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
    progress_cycle++;
    if (progress_cycle % 10000000 == 0)
    {
      Log("progress: %016llu cycles, %016llu insts, pc=" FMT_WORD_NO_PREFIX,
          (unsigned long long)progress_cycle, (unsigned long long)pmu.instr_cnt,
          (word_t)(*npc.pc));
    }
    if (timeout_us && (progress_cycle % 1000000 == 0))
    {
      uint64_t elapsed = get_time() - now;
      if (elapsed > timeout_us)
      {
        Log(FMT_RED("Wall-clock timeout (%llds) exceeded at pc: " FMT_WORD_NO_PREFIX ", %llu cycles, %llu insts."),
            max_timeout, (word_t)(*npc.pc),
            (unsigned long long)progress_cycle, (unsigned long long)pmu.instr_cnt);
        npc.state = NPC_ABORT;
        break;
      }
    }
    if (cur_inst_cycle > 0x4ffff)
    {
      Log(FMT_RED("Too many cycles (0x%llx) stalled at pc: " FMT_WORD_NO_PREFIX ", rpc: " FMT_WORD_NO_PREFIX ", inst: %08x."),
          (long long int)cur_inst_cycle, (word_t)(*npc.pc), (word_t)(*npc.rpc), (uint32_t)(*(npc.inst)));
      npc.state = NPC_ABORT;
      break;
    }
    if (*(uint8_t *)&(CONCAT(VERILOG_PREFIX, cmu__DOT__valid)))
    {
      perf_sample_per_inst();
      cur_inst_cycle = 0;
      uint8_t cmu_valid_b = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, cmu__DOT__valid_b));
#ifdef CONFIG_ITRACE
      iringbuf_rpc[iringhead] = *npc.rpc;
      iringbuf_inst[iringhead] = *(word_t *)(npc.inst);
      iringhead = (iringhead + 1) % MAX_IRING_SIZE;
#endif

#ifdef CONFIG_DIFFTEST
      if (cmu_valid_b)
      {
        // Dual commit: step NEMU for slot 0 (no comparison).
        // difftest_skip is guaranteed absent during dual commit,
        // so just execute NEMU once for the intermediate instruction.
        ref_difftest_exec(1);
      }
      if (((*(npc.inst) & 0xfff0707f) == 0xc0102073))
      {
        // rdtime instruction skipped in difftest
        npc_difftest_skip_ref();
      }
      // Skip difftest for Zicntr counter CSR accesses (instret, cycle, etc.)
      {
        uint32_t inst = *(uint32_t *)(npc.inst);
        if ((inst & 0x7f) == 0x73 && ((inst >> 12) & 0x7) != 0)
        {
          uint16_t csr = (inst >> 20) & 0xfff;
          if (csr == 0xC00 || csr == 0xC02 ||
              csr == 0xC80 || csr == 0xC81 || csr == 0xC82 ||
              csr == 0xB00 || csr == 0xB02 || csr == 0xB80 || csr == 0xB82)
          {
            npc_difftest_skip_ref();
          }
        }
      }
      difftest_step(*npc.rpc);
      char interrupt = *(char *)&(CONCAT(VERILOG_PREFIX, rou__DOT__recieved_trap));
      if (interrupt)
      {
        // Determine actual timer interrupt cause based on privilege level
        // before trap (CSR module hasn't updated priv_mode yet at this point)
        uint8_t priv = *(uint8_t *)npc.priv;
        word_t cause = ((priv == 3) ? 0x7u : 0x5u) | ((word_t)1 << (sizeof(word_t) * 8 - 1));
        difftest_raise_intr(cause);
      }
#endif
      if (cmu_valid_b)
      {
        perf_sample_per_inst();
      }
      npc.last_inst = *(npc.inst);
    }
    if (tfp_threshold_break & ((pmu.active_cycle >= tfp_cycle) | (pmu.instr_cnt >= tfp_inst)))
    {
      void npc_exu_ebreak();
      npc_exu_ebreak();
      npc.state = NPC_END;
      Log("Reached the stop point at pc: " FMT_WORD_NO_PREFIX ".", *npc.pc);
      break;
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
