#include <common.h>
#include <cpu.h>
#include <flow_check.h>
#include <npc_verilog.h>

extern NPCState npc;
extern PMUState pmu;
extern TOP_NAME *top;

static int flow_check_enabled = 0;
static int flow_check_expected_valid = 0;
static word_t flow_check_expected_pc = 0;
static word_t flow_check_prev_pc = 0;
static word_t flow_check_prev_npc = 0;
static char flow_check_prev_slot = '?';

void flow_check_init()
{
  flow_check_enabled = (getenv("RAPT_FLOW_CHECK") != NULL);
  flow_check_expected_valid = 0;
  flow_check_expected_pc = 0;
  flow_check_prev_pc = 0;
  flow_check_prev_npc = 0;
  flow_check_prev_slot = '?';
  if (flow_check_enabled)
    Log("commit flow checker enabled");
}

void flow_check_commit(word_t pc, word_t next_pc, char slot)
{
  if (!flow_check_enabled)
    return;

  if (flow_check_expected_valid && pc != flow_check_expected_pc)
  {
    printf("FLOWCHECK FAIL cyc=%llu inst=%llu slot=%c pc=" FMT_WORD_NO_PREFIX
           " expected=" FMT_WORD_NO_PREFIX " prev_slot=%c prev_pc=" FMT_WORD_NO_PREFIX
           " prev_npc=" FMT_WORD_NO_PREFIX " next=" FMT_WORD_NO_PREFIX "\n",
           (unsigned long long)pmu.active_cycle,
           (unsigned long long)pmu.instr_cnt,
           slot, pc, flow_check_expected_pc,
           flow_check_prev_slot, flow_check_prev_pc, flow_check_prev_npc,
           next_pc);
    npc.state = NPC_ABORT;
    return;
  }

  flow_check_expected_valid = 1;
  flow_check_expected_pc = next_pc;
  flow_check_prev_pc = pc;
  flow_check_prev_npc = next_pc;
  flow_check_prev_slot = slot;
}

void flow_check_redirect_gap()
{
  if (!flow_check_enabled)
    return;
  if (*(uint8_t *)&VERILOG_ROU(recieved_trap))
  {
    flow_check_expected_valid = 0;
    return;
  }
  if (*(uint8_t *)&VERILOG_CPU(cmu__DOT__valid))
    return;
  if (*(uint8_t *)&VERILOG_CPU(cmu__DOT__flush_pipe_r))
    flow_check_expected_valid = 0;
}

void flow_check_async_redirect_after_sample()
{
  if (!flow_check_enabled)
    return;
  if (*(uint8_t *)&VERILOG_ROU(recieved_trap))
    flow_check_expected_valid = 0;
}