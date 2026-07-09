#include <common.h>
#include <difftest.h>
#include <readline/readline.h>
#include <readline/history.h>
#include <npc_verilog.h>

#include <unistd.h>
#include <fcntl.h>

extern NPCState npc;
extern TOP_NAME *top;

uint64_t get_time();

PMUState pmu;
word_t start_timer = 0;
word_t g_timer = 0;

void reg_display(int n);
void cpu_show_itrace();
void perf();

/**
 * @brief Save the current status to "status.log" file.
 * You can view the file in real-time using:
 * $ less -R +F status.log
 * ors
 * $ tail -f status.log
 */
static void save_status_to_file(const char *filename)
{
  if (filename == NULL)
  {
    return;
  }
  if (start_timer == 0)
  {
    start_timer = get_time();
  }
  fflush(stdout);

  int saved_stdout = dup(fileno(stdout)); // save stdout's file descriptor
  int fd = open(filename, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0)
  {
    perror("Failed to open perf.log");
    return;
  }
  dup2(fd, fileno(stdout)); // redirect stdout to the file
  close(fd);

  uint64_t current_time = get_time();
  printf(" Simulated Time: %.3f s\n", (current_time - start_timer) / 1000000.0);
  printf("Simulated Speed: %.3f MIPS\n",
         (pmu.instr_cnt / 1000000.0) / ((current_time - start_timer) / 1000000.0));
  printf("\n");

  reg_display(GPR_SIZE);
  printf("\n");

  cpu_show_itrace();
  printf("\n");

  perf();

  fflush(stdout);
  dup2(saved_stdout, fileno(stdout)); // restore stdout
  close(saved_stdout);
}

static float percentage(int a, int b)
{
  float ret = (b == 0) ? 0 : (100.0 * a / b);
  return ret == 100.0 ? 99.0 : ret;
}

void perf_sample_per_cycle()
{
  bool reset = (uint8_t)(VERILOG_RESET);
  if (reset)
  {
    return;
  }
  pmu.active_cycle++;
  // BPU: use registered ben_r/jen_r/flush_pipe_r from CMU for correct timing
  // alignment with the registered 'valid' signal (all sampled at the same posedge)
  bool b = *(uint8_t *)&VERILOG_CPU(cmu__DOT__ben_r);
  bool j = *(uint8_t *)&VERILOG_CPU(cmu__DOT__jen_r);
  bool jr = *(uint8_t *)&VERILOG_CPU(cmu__DOT__jren_r);
  bool wb_valid = *(uint8_t *)&VERILOG_CPU(cmu__DOT__valid);
  if (wb_valid)
  {
    bool is_br = b || j || jr;
    bool br_predict_fail = *(uint8_t *)&VERILOG_CPU(cmu__DOT__flush_pipe_r);
    pmu.bpu_cnt += is_br ? 1 : 0;
    pmu.bpu_fail_cnt += is_br && br_predict_fail ? 1 : 0;
    pmu.bpu_b_fail += br_predict_fail && b ? 1 : 0;
    pmu.bpu_j_fail += br_predict_fail && j ? 1 : 0;
    pmu.bpu_jr_fail += br_predict_fail && jr ? 1 : 0;

    // A7: RVC branch detection
    // CMU holds the committed instruction for this cycle in cmu_inst_r
    uint32_t inst = *(uint32_t *)&VERILOG_CPU(cmu__DOT__inst);
    uint16_t inst_lo = inst & 0xFFFF; // Lower 16 bits for RVC decoding
    if ((inst_lo & 0x0003) == 0x01)
    { // C-type encoding (bits [1:0] = 01)
      uint8_t funct3 = (inst_lo >> 13) & 0x7;
      // C.BEQZ (funct3 = 3'b110), C.BNEZ (funct3 = 3'b111), C.J (funct3 = 3'b101)
      bool is_c_branch = (funct3 == 0x6) || (funct3 == 0x7) || (funct3 == 0x5);
      pmu.bpu_cnt += is_c_branch ? 1 : 0;
      pmu.bpu_fail_cnt += is_c_branch && br_predict_fail ? 1 : 0;
    }
  }
  bool ifu_hazard = *(uint8_t *)&VERILOG_CPU(ifu__DOT__ifu_hazard);
  bool ifu_fetch_fire = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_fire);
  bool ifu_stall = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_ifu_stall);

  bool rou_ready = *(uint8_t *)&VERILOG_ROU(ready_a);
  uint32_t exu_ooo_valid = *(uint8_t *)&VERILOG_CPU(exu__DOT__u_rs__DOT__rs_valid);
  bool exu_ooo_valid_found = *(uint8_t *)&VERILOG_CPU(exu__DOT__u_rs__DOT__valid_found_a);
  uint32_t exu_ioq_valid = *(uint8_t *)&VERILOG_CPU(exu__DOT__u_ioq__DOT__ioq_valid);
  bool exu_ioq_valid_found = *(uint8_t *)&VERILOG_CPU(exu__DOT__u_ioq__DOT__ioq_valid_found);
  uint8_t l1d_state = *(uint8_t *)&VERILOG_CPU(l1d_cache__DOT__l1d_state);
  bool lsu_l1d_hit = *(uint8_t *)&VERILOG_CPU(l1d_cache__DOT__tag_hit);
  bool lsu_fwd_hit = *(uint8_t *)&VERILOG_CPU(lsu__DOT__fwd_hit);
  bool lsu_load_in_sq = *(uint8_t *)&VERILOG_CPU(lsu__DOT__load_in_sq);
  bool lsu_raddr_valid = *(uint8_t *)&VERILOG_CPU(lsu__DOT__raddr_valid);
  bool wbu_valid = *(uint8_t *)&VERILOG_CPU(cmu__DOT__valid);
  bool wbu_valid_b = *(uint8_t *)&VERILOG_CPU(cmu__DOT__valid_b);
  uint8_t l1i_state = *(uint8_t *)&VERILOG_CPU(l1i_cache__DOT__l1i_state);
  if (ifu_fetch_fire)
  {
    pmu.ifu_fetch_cnt++;
  }
  // IFU stall: IDU was ready but IFU had no instruction (registered for correct timing)
  pmu.ifu_stall_cycle += ifu_stall ? 1 : 0;
  pmu.ifu_sys_hazard_cycle += ifu_hazard ? 1 : 0;
  // ROU structural hazard: RNU has a renamed uop but dispatch queue (UOQ) is full
  uint8_t rnq_valid = *(uint8_t *)&VERILOG_CPU(rnu__DOT__rnq_valid);
  uint8_t rnq_tail = *(uint8_t *)&VERILOG_CPU(rnu__DOT__rnq_tail_a);
  bool rnu_valid = (rnq_valid >> rnq_tail) & 1;
  pmu.rou_hazard_cycle += (rnu_valid && !rou_ready) ? 1 : 0;
  if (exu_ooo_valid && !exu_ooo_valid_found)
  {
    pmu.exu_ooo_stall_cycle++;
  }
  if (exu_ioq_valid && !exu_ioq_valid_found)
  {
    pmu.exu_ioq_stall_cycle++;
  }
  pmu.lsu_l1d_stall_cycle += ((l1d_state == 2) && !lsu_l1d_hit) ? 1 : 0;
  // SQ stall: only count when a ready store at ROB head is blocked by full SQ
  bool rou_sq_stall = *(uint8_t *)&VERILOG_ROU(pmu_sq_stall);
  pmu.lsu_sq_stall_cycle += rou_sq_stall ? 1 : 0;
  // IDU early resteer: BPU predicted taken on non-branch instruction
  bool early_resteer = *(uint8_t *)&VERILOG_CPU(idu__DOT__pmu_early_resteer);
  pmu.early_resteer_cnt += early_resteer ? 1 : 0;
  pmu.lsu_fwd_cnt += (lsu_raddr_valid && lsu_fwd_hit) ? 1 : 0;
  pmu.lsu_sq_conflict_cnt += (lsu_raddr_valid && lsu_load_in_sq) ? 1 : 0;
  pmu.dual_commit_cnt += (wbu_valid && wbu_valid_b) ? 1 : 0;
  if (!wbu_valid)
  {
    pmu.wbu_stall_cycle++;
  }

  // -------------------------------------------------------------------
  // Extended (gem5-aligned) PMU samples
  // -------------------------------------------------------------------
  // 1. IFU stall decomposition.  Uses L1I FSM busy + a small flush-drain timer.
  static int flush_drain_window = 0;
  bool flush_pipe_r = *(uint8_t *)&VERILOG_CPU(cmu__DOT__flush_pipe_r);
  if (flush_pipe_r)
    flush_drain_window = 5; // ~5 cycles for IF->ID bubble
  else if (flush_drain_window > 0)
    flush_drain_window--;

  if (ifu_stall)
  {
    bool l1i_busy_now = (l1i_state == 0b001) || (l1i_state == 0b010) || (l1i_state == 0b110) || (l1i_state == 0b111) || (l1i_state == 0b100);
    if (l1i_busy_now)
      pmu.ifu_icache_miss_cycle++;
    else if (flush_drain_window)
      pmu.ifu_flush_cycle++;
    else
      pmu.ifu_empty_cycle++;
  }

  // 2. Structural full cycles + rising-edge events.
  //    RS/IOQ are 8 entries each (RS_SIZE=IIQ_SIZE=8) -> full when uint8 == 0xFF.
  //    ROB-full proxy: rnu has a renamed uop but UOQ/ROB cannot accept it.
  //    SQ-full: width-stable 1-bit probe from the LSU (&sq_valid).
  bool rs_full = (exu_ooo_valid == 0xFFu);
  bool ioq_full = (exu_ioq_valid == 0xFFu);
  bool rob_full = rnu_valid && !rou_ready;
  bool sq_full = npc.sq_full && (*npc.sq_full != 0);
  static bool prev_rs_full = false, prev_ioq_full = false;
  static bool prev_rob_full = false, prev_sq_full = false;
  if (rs_full)
  {
    pmu.rs_full_cycle++;
    if (!prev_rs_full)
      pmu.rs_full_events++;
  }
  if (ioq_full)
  {
    pmu.ioq_full_cycle++;
    if (!prev_ioq_full)
      pmu.ioq_full_events++;
  }
  if (rob_full)
  {
    pmu.rob_full_cycle++;
    if (!prev_rob_full)
      pmu.rob_full_events++;
  }
  if (sq_full)
  {
    pmu.sq_full_cycle++;
    if (!prev_sq_full)
      pmu.sq_full_events++;
  }
  prev_rs_full = rs_full;
  prev_ioq_full = ioq_full;
  prev_rob_full = rob_full;
  prev_sq_full = sq_full;

  // 3. Commit-width distribution (per cycle).
  if (wbu_valid && wbu_valid_b)
    pmu.commit_2_cycle++;
  else if (wbu_valid)
    pmu.commit_1_cycle++;
  // commit_0_cycle implicitly == wbu_stall_cycle (already accumulated above).

  // 4. Rename/dispatch status mix.
  if (flush_drain_window)
    pmu.dispatch_squash_cycle++;
  else if (rnu_valid && rou_ready)
    pmu.dispatch_running_cycle++;
  else if (rnu_valid && !rou_ready)
    pmu.dispatch_blocked_cycle++;
  else
    pmu.dispatch_idle_cycle++;
  // L1I cache sample: state-transition-based tracking
  // L1I FSM states: IDLE=000, RD_A=001, RD_0=010, PTWAIT=100, TRAP=101, RD_1=110, FINA=111
  static uint8_t prev_l1i_state = 0;
  bool l1i_busy = (l1i_state == 0b001)     // RD_A
                  || (l1i_state == 0b010)  // RD_0
                  || (l1i_state == 0b110)  // RD_1
                  || (l1i_state == 0b111)  // FINA
                  || (l1i_state == 0b100); // PTWAIT

  // Miss: L1I transitions from IDLE to a busy state (cache miss or TLB miss)
  if (prev_l1i_state == 0b000 && l1i_busy)
  {
    pmu.l1i_cache_miss_cnt++;
  }
  // Miss cycles: accumulate while L1I is in any fetching/PTW state
  if (l1i_busy)
  {
    pmu.l1i_cache_miss_cycle++;
  }
  // Hit count and hit cycles are computed at report time:
  //   hit_cnt = ifu_fetch_cnt - miss_cnt,  hit_cycle ~= hit_cnt (1 SRAM cycle/hit)
  prev_l1i_state = l1i_state;
  // L1D cache sample: state-transition-based tracking (load path only)
  // L1D FSM states: IDLE=000, LD_A=001, LD_D=010, PTWAIT=100, TRAP=101
  static uint8_t prev_l1d_state = 0;
  // Hit: LD_A with tag_hit (1-cycle load hit)
  if (l1d_state == 0b001 && lsu_l1d_hit)
  {
    pmu.l1d_cache_hit_cnt++;
  }
  // Miss: transition from LD_A to LD_D (tag miss, going to memory)
  if (prev_l1d_state == 0b001 && l1d_state == 0b010)
  {
    pmu.l1d_cache_miss_cnt++;
  }
  // Miss cycles: accumulate while L1D is fetching from memory
  if (l1d_state == 0b010) // LD_D
  {
    pmu.l1d_cache_miss_cycle++;
  }
  prev_l1d_state = l1d_state;
  // tlb & page table walk sample
  char stlb_mmu = *(char *)&VERILOG_CPU(l1d_cache__DOT__stlb_mmu);
  bool i_ptw = (l1i_state == 0b100); // PTWAIT
  if (i_ptw)
  {
    pmu.itlb_ptw_cycle++;
  }
  bool dtlb_ptw = (l1d_state == 0b100); // PTWAIT
  if (dtlb_ptw)
  {
    if (stlb_mmu)
    {
      pmu.stlb_ptw_cycle++;
    }
    else
    {
      pmu.ltlb_ptw_cycle++;
    }
  }
}

typedef enum
{
  INST_ECALL = 0x00000073,
  INST_MRET = 0x30200073,
  INST_SRET = 0x10200073,
  INST_RET_ = 0x00008067,
  INST_EBREAK = 0x00100073,
} rv_inst_t;

typedef enum
{
  OP_JAL_ = 0b1101111,
  OP_JALR = 0b1100111,
} rv_opcode_t;

void perf_sample_per_inst()
{
  if (top->reset)
  {
    return;
  }
  pmu.instr_cnt++;
  uint32_t inst = *(npc.inst);
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
  case OP_JAL_: // J type: jal
    pmu.jal_inst_cnt++;
    pmu.call_inst_cnt += ((inst & 0xfff) != 0x0000006f ? 1 : 0);
    break;
  case OP_JALR: // I type: jalr
    pmu.jalr_inst_cnt++;
    pmu.call_inst_cnt += ((inst & 0xfff) != 0x00000067 ? 1 : 0);
    break;
  case 0b1110011: // N type: ecall, ebreak, csrrw, csrrs, csrrc, csrrwi, csrrsi, csrrci, mert
    pmu.csr_inst_cnt++;
    break;
  default:
    pmu.other_inst_cnt++;
    break;
  }
  switch (inst)
  {
  case INST_MRET:
  case INST_SRET:
  case INST_RET_:
    pmu.ret_inst_cnt++;
    break;
  default:
    break;
  }

  if ((pmu.instr_cnt % 1000000) == 0) // every million instructions
  {
    save_status_to_file("data/status.log");

    int ret = 0;
    int isa_save_uarch_state(const char *);
    ret = isa_save_uarch_state("data/uarch_state.json");
    if (ret != 0)
    {
      printf("Failed to save uarch state to data/uarch_state.json\n");
    }

    if (0)
    {
      int isa_load_uarch_state(const char *filename);
      ret = isa_load_uarch_state("data/uarch_state.json");
      if (ret != 0)
      {
        printf("Failed to load uarch state from data/uarch_state.json\n");
      }
    }
  }
}

void perf()
{
  Log("======== Instruction Analysis ========");
  uint64_t time_clint = *(uint64_t *)&VERILOG_CLINT(mtime);
  // Convert mtime (ticking at RAPT_MTIME_FREQ_MHZ) to microseconds.
  long long int time_clint_us = (long long int)(time_clint / RAPT_MTIME_FREQ_MHZ);
  float IPC = (1.0 * pmu.instr_cnt / pmu.active_cycle);
  float MIPS = (double)((pmu.instr_cnt / 1e6) / (time_clint_us / 1e6));
  Log("#inst: %lld, cycle: %llu, "
      "IPC: %2.3f, CLINT: %lld (us), %2.3f MIPS",
      pmu.instr_cnt, pmu.active_cycle, IPC,
      (time_clint_us), MIPS);
  Log("|%6s, %%|%6s, %%|%6s, %%|%6s, %%|%6s, %%|%6s, %%|%6s,  %%|%6s,  %%|",
      "LD", "ST", "ALU", "BR", "CSR", "OTH", "JAL", "JALR");
  Log("|%6.0e,%2.0f|%6.0e,%2.0f|%6.0e,%2.0f"
      "|%6.0e,%2.0f|%6.0e,%2.0f|%6.0e,%2.0f"
      "|%6.0e,%3.0f|%6.0e,%3.0f|",
      (double)pmu.ld_inst_cnt, percentage(pmu.ld_inst_cnt, pmu.instr_cnt),
      (double)pmu.st_inst_cnt, percentage(pmu.st_inst_cnt, pmu.instr_cnt),
      (double)pmu.alu_inst_cnt, percentage(pmu.alu_inst_cnt, pmu.instr_cnt),

      (double)pmu.b_inst_cnt, percentage(pmu.b_inst_cnt, pmu.instr_cnt),
      (double)pmu.csr_inst_cnt, percentage(pmu.csr_inst_cnt, pmu.instr_cnt),
      (double)pmu.other_inst_cnt, percentage(pmu.other_inst_cnt, pmu.instr_cnt),

      (double)pmu.jal_inst_cnt, percentage(pmu.jal_inst_cnt, pmu.instr_cnt),
      (double)pmu.jalr_inst_cnt, percentage(pmu.jalr_inst_cnt, pmu.instr_cnt));
  Log("======== TOP DOWN Stall Analysis ========");
  Log("|%6s, %%|%6s, %%|%6s, %%|%6s, %%|%6s, %%|%6s, %%|",
      "IFU", "EX|RS", "EX|IoQ", "L1D", "SQ", "Bubble");
  Log("|%6.0e,%2.0f|%6.0e,%2.0f|%6.0e,%2.0f|%6.0e,%2.0f|%6.0e,%2.0f|%6.0e,%2.0f|",
      (double)pmu.ifu_stall_cycle, percentage(pmu.ifu_stall_cycle, pmu.active_cycle),
      (double)pmu.exu_ooo_stall_cycle, percentage(pmu.exu_ooo_stall_cycle, pmu.active_cycle),
      (double)pmu.exu_ioq_stall_cycle, percentage(pmu.exu_ioq_stall_cycle, pmu.active_cycle),
      (double)pmu.lsu_l1d_stall_cycle, percentage(pmu.lsu_l1d_stall_cycle, pmu.active_cycle),
      (double)pmu.lsu_sq_stall_cycle, percentage(pmu.lsu_sq_stall_cycle, pmu.active_cycle),
      (double)pmu.wbu_stall_cycle, percentage(pmu.wbu_stall_cycle, pmu.active_cycle));
  Log("BPU Success: %lld, Fail: %lld, Rate: %2.1f%% (b: %lld, j: %lld, jr: %lld), call: %lld, ret: %lld",
      pmu.bpu_cnt - pmu.bpu_fail_cnt, pmu.bpu_fail_cnt,
      percentage(pmu.bpu_cnt - pmu.bpu_fail_cnt, pmu.bpu_cnt),
      pmu.bpu_b_fail, pmu.bpu_j_fail, pmu.bpu_jr_fail,
      pmu.call_inst_cnt, pmu.ret_inst_cnt);
  Log("hazard cycle of ifu_sys: %6lld,%2.0f%%, rou_cycle: %6lld,%2.0f%% (structural)",
      pmu.ifu_sys_hazard_cycle, percentage(pmu.ifu_sys_hazard_cycle, pmu.active_cycle),
      pmu.rou_hazard_cycle, percentage(pmu.rou_hazard_cycle, pmu.active_cycle));
  Log("LSU fwd: %lld, sq_conflict: %lld", pmu.lsu_fwd_cnt, pmu.lsu_sq_conflict_cnt);
  // Dual-commit: report two perspectives consistent with gem5:
  //   * fraction of commit cycles (i.e. cycles where >=1 inst committed)
  //   * fraction of total instructions committed in dual mode (2*dual / instr)
  long long int commit_cycles = pmu.commit_1_cycle + pmu.commit_2_cycle;
  Log("Dual commit: %lld cycles, %2.1f%% of commit cycles, %2.1f%% of insts",
      pmu.commit_2_cycle,
      percentage(pmu.commit_2_cycle, commit_cycles),
      percentage(2 * pmu.commit_2_cycle, pmu.instr_cnt));
  Log("Early resteer: %lld events (BPU taken on non-branch, IDU-detected)",
      pmu.early_resteer_cnt);

  // -------------------------------------------------------------------
  // IFU stall decomposition  (gem5: fetch.icacheStallCycles / squashCycles)
  // -------------------------------------------------------------------
  Log("======== IFU Stall Decomposition ========");
  Log("|%10s, %%|%10s, %%|%10s, %%|%10s, %%|",
      "IFU TOTAL", "L1I/PTW", "FLUSH", "EMPTY");
  Log("|%10.0e,%3.0f|%10.0e,%3.0f|%10.0e,%3.0f|%10.0e,%3.0f|",
      (double)pmu.ifu_stall_cycle, percentage(pmu.ifu_stall_cycle, pmu.active_cycle),
      (double)pmu.ifu_icache_miss_cycle, percentage(pmu.ifu_icache_miss_cycle, pmu.ifu_stall_cycle),
      (double)pmu.ifu_flush_cycle, percentage(pmu.ifu_flush_cycle, pmu.ifu_stall_cycle),
      (double)pmu.ifu_empty_cycle, percentage(pmu.ifu_empty_cycle, pmu.ifu_stall_cycle));

  // -------------------------------------------------------------------
  // Structural-full events  (gem5: iqFullEvents / robFullEvents / sqFullEvents)
  // -------------------------------------------------------------------
  Log("======== Structural Full (events / cycles, %% of total) ========");
  Log("|%10s|%14s|%10s|%14s|%10s|%14s|%10s|%14s|",
      "RS EVT", "RS CYC, %", "IOQ EVT", "IOQ CYC, %",
      "ROB EVT", "ROB CYC, %", "SQ EVT", "SQ CYC, %");
  Log("|%10lld|%8.0e,%4.1f|%10lld|%8.0e,%4.1f|%10lld|%8.0e,%4.1f|%10lld|%8.0e,%4.1f|",
      pmu.rs_full_events, (double)pmu.rs_full_cycle, percentage(pmu.rs_full_cycle, pmu.active_cycle),
      pmu.ioq_full_events, (double)pmu.ioq_full_cycle, percentage(pmu.ioq_full_cycle, pmu.active_cycle),
      pmu.rob_full_events, (double)pmu.rob_full_cycle, percentage(pmu.rob_full_cycle, pmu.active_cycle),
      pmu.sq_full_events, (double)pmu.sq_full_cycle, percentage(pmu.sq_full_cycle, pmu.active_cycle));

  // -------------------------------------------------------------------
  // Commit-width distribution  (gem5: commit.committed_per_cycle)
  // -------------------------------------------------------------------
  Log("======== Commit Width Distribution ========");
  Log("|%12s, %%|%12s, %%|%12s, %%|  avg/cycle: %5.3f",
      "0 (stall)", "1 (single)", "2 (dual)",
      pmu.active_cycle ? (double)pmu.instr_cnt / pmu.active_cycle : 0.0);
  Log("|%12.0e,%3.0f|%12.0e,%3.0f|%12.0e,%3.0f|",
      (double)pmu.wbu_stall_cycle, percentage(pmu.wbu_stall_cycle, pmu.active_cycle),
      (double)pmu.commit_1_cycle, percentage(pmu.commit_1_cycle, pmu.active_cycle),
      (double)pmu.commit_2_cycle, percentage(pmu.commit_2_cycle, pmu.active_cycle));

  // -------------------------------------------------------------------
  // Rename / Dispatch status mix  (gem5: rename.status)
  // -------------------------------------------------------------------
  Log("======== Rename/Dispatch Status ========");
  Log("|%12s, %%|%12s, %%|%12s, %%|%12s, %%|",
      "Running", "Blocked", "Idle", "Squashing");
  Log("|%12.0e,%3.0f|%12.0e,%3.0f|%12.0e,%3.0f|%12.0e,%3.0f|",
      (double)pmu.dispatch_running_cycle, percentage(pmu.dispatch_running_cycle, pmu.active_cycle),
      (double)pmu.dispatch_blocked_cycle, percentage(pmu.dispatch_blocked_cycle, pmu.active_cycle),
      (double)pmu.dispatch_idle_cycle, percentage(pmu.dispatch_idle_cycle, pmu.active_cycle),
      (double)pmu.dispatch_squash_cycle, percentage(pmu.dispatch_squash_cycle, pmu.active_cycle));
  assert(
      pmu.instr_cnt ==
      (pmu.ld_inst_cnt + pmu.st_inst_cnt + pmu.alu_inst_cnt +
       pmu.b_inst_cnt + pmu.csr_inst_cnt + pmu.other_inst_cnt +
       pmu.jal_inst_cnt + pmu.jalr_inst_cnt));
  Log("======== Cache Analysis ========");
  // AMAT: Average Memory Access Time
  // Compute hit count at report time: hits = total fetches - misses
  long long int l1i_hit_cnt = pmu.ifu_fetch_cnt - pmu.l1i_cache_miss_cnt;
  if (l1i_hit_cnt < 0)
    l1i_hit_cnt = 0;
  long long int l1i_hit_cycle = l1i_hit_cnt; // ~1 SRAM cycle per hit
  Log("|%6s, %%|%8s, %%|%8s, %%|%8s,  %%|%13s|%13s|%13s|",
      "L1I HIT", "L1I MISS", "HIT CYC", "MISS CYC", "HIT Cost AVG", "MISS Cost AVG", "AMAT");
  double l1i_hit_rate = percentage(l1i_hit_cnt, l1i_hit_cnt + pmu.l1i_cache_miss_cnt);
  double l1i_access_time = l1i_hit_cnt > 0 ? (double)l1i_hit_cycle / l1i_hit_cnt : 0;
  double l1i_miss_penalty = pmu.l1i_cache_miss_cnt > 0 ? (double)pmu.l1i_cache_miss_cycle / pmu.l1i_cache_miss_cnt : 0;
  Log("|%6.0e,%3.0f|%8.0e,%2.0f|%8.0e,%2.0f|%8.0e,%3.0f|%13lld|%13lld|%13.1f|",
      (double)l1i_hit_cnt, l1i_hit_rate,
      (double)pmu.l1i_cache_miss_cnt, 100 - l1i_hit_rate,
      (double)l1i_hit_cycle,
      percentage(l1i_hit_cycle, l1i_hit_cycle + pmu.l1i_cache_miss_cycle),
      (double)pmu.l1i_cache_miss_cycle,
      percentage(pmu.l1i_cache_miss_cycle, l1i_hit_cycle + pmu.l1i_cache_miss_cycle),
      (long long)l1i_access_time, (long long)l1i_miss_penalty,
      l1i_access_time + (100 - l1i_hit_rate) / 100.0 * l1i_miss_penalty);
  // L1D cache (load path only; stores are write-through and don't stall)
  long long int l1d_total = pmu.l1d_cache_hit_cnt + pmu.l1d_cache_miss_cnt;
  long long int l1d_hit_cycle = pmu.l1d_cache_hit_cnt; // ~1 SRAM cycle per hit
  Log("|%6s, %%|%8s, %%|%8s, %%|%8s,  %%|%13s|%13s|%13s|",
      "L1D HIT", "L1D MISS", "HIT CYC", "MISS CYC", "HIT Cost AVG", "MISS Cost AVG", "AMAT");
  double l1d_hit_rate = percentage(pmu.l1d_cache_hit_cnt, l1d_total);
  double l1d_access_time = pmu.l1d_cache_hit_cnt > 0 ? (double)l1d_hit_cycle / pmu.l1d_cache_hit_cnt : 0;
  double l1d_miss_penalty = pmu.l1d_cache_miss_cnt > 0 ? (double)pmu.l1d_cache_miss_cycle / pmu.l1d_cache_miss_cnt : 0;
  Log("|%6.0e,%3.0f|%8.0e,%2.0f|%8.0e,%2.0f|%8.0e,%3.0f|%13lld|%13lld|%13.1f|",
      (double)pmu.l1d_cache_hit_cnt, l1d_hit_rate,
      (double)pmu.l1d_cache_miss_cnt, 100 - l1d_hit_rate,
      (double)l1d_hit_cycle,
      percentage(l1d_hit_cycle, l1d_hit_cycle + pmu.l1d_cache_miss_cycle),
      (double)pmu.l1d_cache_miss_cycle,
      percentage(pmu.l1d_cache_miss_cycle, l1d_hit_cycle + pmu.l1d_cache_miss_cycle),
      (long long)l1d_access_time, (long long)l1d_miss_penalty,
      l1d_access_time + (100 - l1d_hit_rate) / 100.0 * l1d_miss_penalty);
  // tlb & page table walk
  Log("|======= TLB & Page Table Walk Analysis ========");
  Log("|%8s, %%|%8s, %%|%8s, %%|",
      "ITLB PTW", "STLB PTW", "LTLB PTW");
  Log("|%8.0e,%2.0f|%8.0e,%2.0f|%8.0e,%2.0f|",
      (double)pmu.itlb_ptw_cycle,
      percentage(pmu.itlb_ptw_cycle, pmu.active_cycle),
      (double)pmu.stlb_ptw_cycle,
      percentage(pmu.stlb_ptw_cycle, pmu.active_cycle),
      (double)pmu.ltlb_ptw_cycle,
      percentage(pmu.ltlb_ptw_cycle, pmu.active_cycle));
}

void statistic()
{
  perf();
  double time_s = g_timer / 1e6;
  double frequency = pmu.active_cycle / time_s;
  Log("Simulate time:"
      " " FMT_WORD_NO_PREFIX " us, " FMT_WORD_NO_PREFIX " ms, Freq: %5.3f MHz, Inst: %6.0f I/s, %5.3f MIPS",
      (word_t)g_timer, (word_t)(g_timer / 1000),
      (double)(frequency * 1.0 / 1e6),
      pmu.instr_cnt / time_s, pmu.instr_cnt / time_s / 1e6);
  Log("%s at pc: " FMT_WORD_NO_PREFIX ", inst: " FMT_WORD_NO_PREFIX,
      ((npc.state == NPC_QUIT) ? FMT_BLUE("NPC QUIT")
                               : ((npc.host_exit_ok || *npc.ret == 0) && npc.state != NPC_ABORT
                                      ? FMT_GREEN("HIT GOOD TRAP")
                                      : FMT_RED("HIT BAD TRAP"))),
      (word_t)(*(npc.pc)), (word_t)(*(npc.inst)));
}