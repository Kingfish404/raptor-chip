#include <common.h>
#include <difftest.h>
#include <readline/readline.h>
#include <readline/history.h>
#include <npc_verilog.h>

extern NPCState npc;
extern TOP_NAME *top;

PMUState pmu;
word_t g_timer = 0;
word_t main_cycle_cnt = 0;
word_t main_inst_cnt = 0;

float percentage(int a, int b)
{
  float ret = (b == 0) ? 0 : (100.0 * a / b);
  return ret == 100.0 ? 99.0 : ret;
}

void perf_sample_per_cycle()
{
  if (top->reset)
  {
    return;
  }
  pmu.active_cycle++;
  bool speculation = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, ifu__DOT__speculation));
  bool pc_retire = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, wbu__DOT__retire));
  bool flush_pipeline = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, flush_pipeline));
  pmu.bpu_success_cnt += speculation && pc_retire ? 1 : 0;
  pmu.bpu_fail_cnt += speculation && flush_pipeline ? 1 : 0;
  bool ifu_valid = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, ifu_arvalid));
  bool ifu_sys_hazard = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, ifu__DOT__ifu_sys_hazard));
  bool ifu_lsu_hazard = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, ifu__DOT__ifu_lsu_hazard));

  bool idu_ready = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, idu__DOT__ready));

  bool iqu_ready = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, iqu_ready));
  uint8_t l1i_state = *(uint8_t *)&(CONCAT(VERILOG_PREFIX, ifu__DOT__l1i_cache__DOT__l1i_state));
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
  pmu.ifu_sys_hazard_cycle += ifu_sys_hazard ? 1 : 0;
  pmu.ifu_lsu_hazard_cycle += ifu_lsu_hazard ? 1 : 0;
  pmu.iqu_hazard_cycle += !iqu_ready ? 1 : 0;
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

void perf_sample_per_inst()
{
  if (top->reset)
  {
    return;
  }
  pmu.instr_cnt++;
  uint32_t inst = *(uint32_t *)&(CONCAT(VERILOG_PREFIX, wbu__DOT__inst_wbu));
  if (inst == 0x0ff0000f) // fence
  {
    main_cycle_cnt = pmu.active_cycle;
    main_inst_cnt = pmu.instr_cnt;
  }
  uint32_t opcode = inst & 0x7f;
  switch (opcode)
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
  case 0b1101111: // J type: jal
    pmu.jal_inst_cnt++;
    break;
  case 0b1100111: // I type: jalr
    pmu.jalr_inst_cnt++;
    break;
  case 0b1110011: // N type: ecall, ebreak, csrrw, csrrs, csrrc, csrrwi, csrrsi, csrrci, mert
    pmu.csr_inst_cnt++;
    break;
  default:
    pmu.other_inst_cnt++;
    break;
  }
}

void perf()
{
  Log("======== Instruction Analysis ========");
  uint64_t time_clint = *(uint64_t *)&(CONCAT(VERILOG_PREFIX, bus__DOT__clint__DOT__mtime));
  uint64_t time_clint_us = time_clint / 2;
  float IPC = (1.0 * pmu.instr_cnt / pmu.active_cycle);
  float MAIN_IPC = (1.0 * (pmu.instr_cnt - main_inst_cnt) / (pmu.active_cycle - main_cycle_cnt));
  float MIPS = (double)((pmu.instr_cnt / 1e6) / (time_clint_us / 1e6));
  Log("#Inst: %lld, cycle: %llu, "
      "" FMT_BLUE("IPC: %2.3f, %2.3f (main)") ", CLINT: %lld (us), " FMT_BLUE(" %2.3f MIPS"),
      pmu.instr_cnt, pmu.active_cycle, IPC,
      (main_cycle_cnt != 0) ? MAIN_IPC : 0,
      (time_clint_us), MIPS);
  Log("| %8s,  %% | %8s,  %% | %8s,  %% |",
      "IFU", "LSU", "EXU");
  Log("| %8lld,%3.0f | %8lld,%3.0f | %8lld,%3.0f |",
      pmu.ifu_fetch_stall_cycle, percentage(pmu.ifu_fetch_stall_cycle, pmu.active_cycle),
      pmu.lsu_stall_cycle, percentage(pmu.lsu_stall_cycle, pmu.active_cycle),
      pmu.exu_alu_cnt, percentage(pmu.exu_alu_cnt, pmu.instr_cnt));
  Log("| %6s, %% | %6s, %% | %6s, %% | %6s, %% | %3s, %% | %5s, %% | %6s,  %% | %6s,  %% |",
      "LD", "ST", "ALU", "BR", "CSR", "OTH", "JAL", "JALR");
  Log("| %6lld,%2.0f | %6lld,%2.0f | %6lld,%2.0f "
      "| %6lld,%2.0f | %3lld,%2.0f | %5lld,%2.0f "
      "| %6lld,%3.0f | %6lld,%3.0f |",
      pmu.ld_inst_cnt, percentage(pmu.ld_inst_cnt, pmu.instr_cnt),
      pmu.st_inst_cnt, percentage(pmu.st_inst_cnt, pmu.instr_cnt),
      pmu.alu_inst_cnt, percentage(pmu.alu_inst_cnt, pmu.instr_cnt),

      pmu.b_inst_cnt, percentage(pmu.b_inst_cnt, pmu.instr_cnt),
      pmu.csr_inst_cnt, percentage(pmu.csr_inst_cnt, pmu.instr_cnt),
      pmu.other_inst_cnt, percentage(pmu.other_inst_cnt, pmu.instr_cnt),

      pmu.jal_inst_cnt, percentage(pmu.jal_inst_cnt, pmu.instr_cnt),
      pmu.jalr_inst_cnt, percentage(pmu.jalr_inst_cnt, pmu.instr_cnt));
  Log("======== TOP DOWN Analysis ========");
  Log("| %8s,  %% | %8s,  %% | %8s,  %% | %8s,  %% | %8s,  %% |",
      "IFU", "LSU", "EXU", "LD", "ST");
  Log("| %8lld,%3.0f | %8lld,%3.0f | %8lld,%3.0f | %8lld,%3.0f | %8lld,%3.0f |",
      pmu.ifu_fetch_stall_cycle, percentage(pmu.ifu_fetch_stall_cycle, pmu.active_cycle),
      pmu.lsu_stall_cycle, percentage(pmu.lsu_stall_cycle, pmu.active_cycle),
      pmu.exu_alu_cnt, percentage(pmu.exu_alu_cnt, pmu.instr_cnt),
      pmu.ld_inst_cnt, percentage(pmu.ld_inst_cnt, pmu.instr_cnt),
      pmu.st_inst_cnt, percentage(pmu.st_inst_cnt, pmu.instr_cnt));
  // show average IF cycle and LS cycle
  Log(FMT_BLUE("IFU Avg Cycle: %2.1f, LSU Avg Cycle: %2.1f"),
      (1.0 * pmu.ifu_fetch_stall_cycle) / (pmu.ifu_fetch_cnt + 1),
      (1.0 * pmu.lsu_stall_cycle) / (pmu.lsu_load_cnt + 1));
  Log("BPU Success: %lld, Fail: %lld, Rate: %2.1f%%",
      pmu.bpu_success_cnt, pmu.bpu_fail_cnt,
      percentage(pmu.bpu_success_cnt, pmu.bpu_success_cnt + pmu.bpu_fail_cnt));
  Log("ifu_sys_hazard_cycle: %8lld,%3.0f%%, ifu_lsu_hazard_cycle: %8lld,%3.0f%%",
      pmu.ifu_sys_hazard_cycle, percentage(pmu.ifu_sys_hazard_cycle, pmu.active_cycle),
      pmu.ifu_lsu_hazard_cycle, percentage(pmu.ifu_lsu_hazard_cycle, pmu.active_cycle));
  Log("iqu_hazard_cycle: %8lld,%3.0f%% (structure hazard)",
      pmu.iqu_hazard_cycle, percentage(pmu.iqu_hazard_cycle, pmu.active_cycle));
  Log(FMT_BLUE("ifu_fetch_cnt: %lld, instr_cnt: %lld"), pmu.ifu_fetch_cnt, pmu.instr_cnt);
  // assert(pmu.ifu_fetch_cnt == pmu.instr_cnt);
  assert(
      pmu.instr_cnt ==
      (pmu.ld_inst_cnt + pmu.st_inst_cnt + pmu.alu_inst_cnt +
       pmu.b_inst_cnt + pmu.csr_inst_cnt + pmu.other_inst_cnt +
       pmu.jal_inst_cnt + pmu.jalr_inst_cnt));
  Log("======== Cache Analysis ========");
  // AMAT: Average Memory Access Time
  Log("| %8s, %% | %8s, %% | %8s, %% | %8s, %% | %13s | %13s | %8s |",
      "HIT", "MISS", "HIT CYC", "MISS CYC", "HIT Cost AVG", "MISS Cost AVG", "AMAT");
  double l1i_hit_rate = percentage(pmu.l1i_cache_hit_cnt, pmu.l1i_cache_hit_cnt + pmu.l1i_cache_miss_cnt);
  double l1i_access_time = pmu.l1i_cache_hit_cycle / (pmu.l1i_cache_hit_cnt + 1);
  double l1i_miss_penalty = pmu.l1i_cache_miss_cycle / (pmu.l1i_cache_miss_cnt + 1);
  Log("| %8lld,%2.0f | %8lld,%2.0f | %8lld,%2.0f | %8lld,%2.0f | %13lld | %13lld | %8.1f |",
      pmu.l1i_cache_hit_cnt, l1i_hit_rate,
      pmu.l1i_cache_miss_cnt, 100 - l1i_hit_rate,
      pmu.l1i_cache_hit_cycle,
      percentage(pmu.l1i_cache_hit_cycle, pmu.l1i_cache_hit_cycle + pmu.l1i_cache_miss_cycle),
      pmu.l1i_cache_miss_cycle,
      percentage(pmu.l1i_cache_miss_cycle, pmu.l1i_cache_hit_cycle + pmu.l1i_cache_miss_cycle),
      (long long)l1i_access_time, (long long)l1i_miss_penalty,
      l1i_access_time + (100 - l1i_hit_rate) / 100.0 * l1i_miss_penalty);
  // assert((pmu.l1i_cache_hit_cnt + pmu.l1i_cache_miss_cnt) == pmu.ifu_fetch_cnt);
}

void statistic()
{
  perf();
  double time_s = g_timer / 1e6;
  double frequency = pmu.active_cycle / time_s;
  Log("Simulate time:"
      " %d us, %d ms, Freq: %5.3f MHz, Inst: %6.0f I/s, %5.3f MIPS",
      g_timer, (int)(g_timer / 1e3),
      (double)(frequency * 1.0 / 1e6),
      pmu.instr_cnt / time_s, pmu.instr_cnt / time_s / 1e6);
  Log("%s at pc: " FMT_WORD_NO_PREFIX ", inst: " FMT_WORD_NO_PREFIX,
      (*npc.ret == 0 && npc.state != NPC_ABORT ? FMT_GREEN("HIT GOOD TRAP")
       : (npc.state == NPC_QUIT)               ? FMT_BLUE("NPC QUIT")
                                               : FMT_RED("HIT BAD TRAP")),
      *(npc.pc), *(npc.inst));
}