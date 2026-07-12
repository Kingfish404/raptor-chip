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
  uint8_t ifu_fetch_slots = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_slots);
  bool ifu_fetch_response_consume = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_response_consume);
  bool ifu_fetch_dual = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_dual_fire);
  bool ifu_fetch_bpu_taken = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_bpu_taken);
  bool ifu_fetch_slot_a_control = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_slot_a_control);
  bool ifu_fetch_slot_b_control = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_slot_b_control);
  bool ifu_fetch_slot_b_jal_pack = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_slot_b_jal_pack);
  bool ifu_fetch_slot_b_cond_pack = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_slot_b_cond_pack);
  bool ifu_fetch_n1_unavailable = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_n1_unavailable);
  bool ifu_fetch_n1_unavailable_unaligned = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_n1_unavailable_unaligned);
  bool ifu_fetch_n1_unavailable_l1i = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_n1_unavailable_l1i);
  bool ifu_fetch_downstream_blocked = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_downstream_blocked);
  bool ifu_fetch_target_steer = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_target_steer);
  bool ifu_stall = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_ifu_stall);
  bool ifu_icache_stall = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_ifu_icache_stall);
  bool ifu_flush_stall = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_ifu_flush_stall);
  bool ifu_empty_stall = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_ifu_empty_stall);
  bool ifu_response_after_redirect = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_ifu_response_after_redirect);
  bool ifu_response_after_l1i_gap = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_ifu_response_after_l1i_gap);
  bool ifu_response_bypass_candidate = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_ifu_response_bypass_candidate);
  bool l1i_refill_active = *(uint8_t *)&VERILOG_CPU(l1i_cache__DOT__pmu_l1i_refill_active);
  bool l1i_sram_warmup = *(uint8_t *)&VERILOG_CPU(l1i_cache__DOT__pmu_l1i_sram_warmup);
  bool l1i_tag_miss = *(uint8_t *)&VERILOG_CPU(l1i_cache__DOT__pmu_l1i_tag_miss);
  bool l1i_nextword_miss = *(uint8_t *)&VERILOG_CPU(l1i_cache__DOT__pmu_l1i_nextword_miss);
  bool l1i_refill_start_line_miss = *(uint8_t *)&VERILOG_CPU(l1i_cache__DOT__pmu_l1i_refill_start_line_miss);
  bool l1i_refill_start_current_hole = *(uint8_t *)&VERILOG_CPU(l1i_cache__DOT__pmu_l1i_refill_start_current_hole);
  bool l1i_refill_start_next_line_miss = *(uint8_t *)&VERILOG_CPU(l1i_cache__DOT__pmu_l1i_refill_start_next_line_miss);
  bool l1i_refill_start_next_hole = *(uint8_t *)&VERILOG_CPU(l1i_cache__DOT__pmu_l1i_refill_start_next_hole);
  bool fqu_full = *(uint8_t *)&VERILOG_CPU(fqu__DOT__pmu_full);
  uint8_t fqu_count = *(uint8_t *)&VERILOG_CPU(fqu__DOT__pmu_count);

  bool rou_ready = *(uint8_t *)&VERILOG_ROU(ready_a);
  // OoO scheduler stall: any ALU-class IQ (IQ-A / IQ-B / BRQ) holds pending
  // work but no ALU-class pipe issued this cycle. Aggregated in rapt_exu
  // (the former unified RS was split into per-pipe issue queues).
  bool exu_ooo_valid = *(uint8_t *)&VERILOG_CPU(exu__DOT__pmu_ooo_valid);
  bool exu_ooo_valid_found = *(uint8_t *)&VERILOG_CPU(exu__DOT__pmu_ooo_valid_found);
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
  pmu.ifu_fetch_inst_cnt += ifu_fetch_slots;
  pmu.ifu_fetch_response_cnt += ifu_fetch_response_consume ? 1 : 0;
  pmu.ifu_dual_fetch_cnt += ifu_fetch_dual ? 1 : 0;
  pmu.ifu_fetch_bpu_taken_cnt += ifu_fetch_bpu_taken ? 1 : 0;
  pmu.ifu_fetch_slot_a_control_cnt += ifu_fetch_slot_a_control ? 1 : 0;
  pmu.ifu_fetch_slot_b_control_cnt += ifu_fetch_slot_b_control ? 1 : 0;
  pmu.ifu_fetch_slot_b_jal_pack_cnt += ifu_fetch_slot_b_jal_pack ? 1 : 0;
  pmu.ifu_fetch_slot_b_cond_pack_cnt += ifu_fetch_slot_b_cond_pack ? 1 : 0;
  pmu.ifu_fetch_n1_unavailable_cnt += ifu_fetch_n1_unavailable ? 1 : 0;
  pmu.ifu_fetch_n1_unavailable_unaligned_cnt += ifu_fetch_n1_unavailable_unaligned ? 1 : 0;
  pmu.ifu_fetch_n1_unavailable_l1i_cnt += ifu_fetch_n1_unavailable_l1i ? 1 : 0;
  pmu.ifu_fetch_downstream_blocked_cycle += ifu_fetch_downstream_blocked ? 1 : 0;
  pmu.ifu_fetch_target_steer_cnt += ifu_fetch_target_steer ? 1 : 0;
  // IFU stall: IDU was ready but IFU had no instruction (registered for correct timing)
  pmu.ifu_stall_cycle += ifu_stall ? 1 : 0;
  pmu.ifu_sys_hazard_cycle += ifu_hazard ? 1 : 0;
  // ROU structural hazard: RNU has renamed work but the dispatch path cannot
  // accept it. `ready_a` is UOQ-space based, so this is not a ROB-full probe.
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
  // IDU early resteer: statically resolvable IFU correction.
  bool early_resteer = *(uint8_t *)&VERILOG_CPU(idu__DOT__pmu_early_resteer);
  pmu.early_resteer_cnt += early_resteer ? 1 : 0;

  // Measure the end-to-end frontend recovery after an exact branch-caused
  // commit flush. This intentionally includes any downstream backpressure
  // encountered before the corrected path can supply its first packet.
  bool branch_flush = *(uint8_t *)&VERILOG_ROU(pmu_branch_flush);
  bool nonbranch_flush = *(uint8_t *)&VERILOG_ROU(pmu_nonbranch_flush);
  static bool branch_recovery_active = false;
  if (branch_flush)
  {
    pmu.branch_flush_events++;
    pmu.branch_recovery_overlap_events += branch_recovery_active ? 1 : 0;
    branch_recovery_active = true;
  }
  else if (branch_recovery_active)
  {
    pmu.branch_recovery_wait_cycles++;
    if (ifu_fetch_fire)
    {
      pmu.branch_recovery_completed++;
      branch_recovery_active = false;
    }
  }
  pmu.nonbranch_flush_events += nonbranch_flush ? 1 : 0;
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
  // 1. IFU stall decomposition. The IFU publishes registered, mutually
  // exclusive root causes; do not approximate flush cost with a fixed timer.
  static int flush_drain_window = 0;
  bool flush_pipe_r = *(uint8_t *)&VERILOG_CPU(cmu__DOT__flush_pipe_r);
  if (flush_pipe_r)
    flush_drain_window = 5; // ~5 cycles for IF->ID bubble
  else if (flush_drain_window > 0)
    flush_drain_window--;

  pmu.ifu_icache_miss_cycle += ifu_icache_stall ? 1 : 0;
  pmu.ifu_flush_cycle += ifu_flush_stall ? 1 : 0;
  pmu.ifu_empty_cycle += ifu_empty_stall ? 1 : 0;
  pmu.ifu_response_after_redirect_cycle += ifu_response_after_redirect ? 1 : 0;
  pmu.ifu_response_after_l1i_gap_cycle += ifu_response_after_l1i_gap ? 1 : 0;
  pmu.ifu_response_bypass_candidate_cycle += ifu_response_bypass_candidate ? 1 : 0;
  if (ifu_icache_stall)
  {
    pmu.ifu_no_response_refill_cycle += l1i_refill_active ? 1 : 0;
    pmu.ifu_no_response_sram_warmup_cycle += l1i_sram_warmup ? 1 : 0;
    pmu.ifu_no_response_tag_miss_cycle += l1i_tag_miss ? 1 : 0;
    pmu.ifu_no_response_nextword_miss_cycle += l1i_nextword_miss ? 1 : 0;
  }
  pmu.l1i_refill_start_line_miss += l1i_refill_start_line_miss ? 1 : 0;
  pmu.l1i_refill_start_current_hole += l1i_refill_start_current_hole ? 1 : 0;
  pmu.l1i_refill_start_next_line_miss += l1i_refill_start_next_line_miss ? 1 : 0;
  pmu.l1i_refill_start_next_hole += l1i_refill_start_next_hole ? 1 : 0;
  pmu.fqu_full_cycle += fqu_full ? 1 : 0;
  pmu.fqu_buffered_cycle += fqu_count != 0 ? 1 : 0;
  pmu.fqu_occupancy_sum += fqu_count;

  // 2. Structural full cycles + rising-edge events.
  //    RS-full proxy: both distributed ALU IQs full (aggregated in rapt_exu);
  //    IOQ is 8 entries (IIQ_SIZE=8) -> full when uint8 == 0xFF.
  //    UOQ-blocked: rnu has a renamed uop but the dispatch path cannot accept it.
  //    True ROB-full is the rapt_rou all-entry-busy event pulse.
  //    SQ-full: width-stable 1-bit probe from the LSU (&sq_valid).
  bool rs_full = *(uint8_t *)&VERILOG_CPU(exu__DOT__pmu_ooo_full);
  bool ioq_full = (exu_ioq_valid == 0xFFu);
  bool uoq_blocked = rnu_valid && !rou_ready;
  bool rob_full_event = *(uint8_t *)&VERILOG_ROU(pmu_rob_full);
  bool sq_full = npc.sq_full && (*npc.sq_full != 0);
  static bool prev_rs_full = false, prev_ioq_full = false;
  static bool prev_uoq_blocked = false, prev_sq_full = false;
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
  if (uoq_blocked)
  {
    pmu.uoq_blocked_cycle++;
    if (!prev_uoq_blocked)
      pmu.uoq_blocked_events++;
  }
  pmu.rob_full_events += rob_full_event ? 1 : 0;
  if (sq_full)
  {
    pmu.sq_full_cycle++;
    if (!prev_sq_full)
      pmu.sq_full_events++;
  }
  prev_rs_full = rs_full;
  prev_ioq_full = ioq_full;
  prev_uoq_blocked = uoq_blocked;
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
  Log("Early resteer: %lld events (statically resolvable IFU corrections)",
      pmu.early_resteer_cnt);
  Log("Commit flush: branch %lld, non-branch %lld; branch recovery: %lld completed, "
      "%lld wait cycles (%4.2f cycles/completed), %lld overlaps",
      pmu.branch_flush_events, pmu.nonbranch_flush_events,
      pmu.branch_recovery_completed, pmu.branch_recovery_wait_cycles,
      pmu.branch_recovery_completed
          ? (double)pmu.branch_recovery_wait_cycles / pmu.branch_recovery_completed
          : 0.0,
      pmu.branch_recovery_overlap_events);

  // -------------------------------------------------------------------
  // IFU stall decomposition  (gem5: fetch.icacheStallCycles / squashCycles)
  // -------------------------------------------------------------------
  Log("======== IFU Stall Decomposition ========");
  Log("|%10s, %%|%10s, %%|%10s, %%|%10s, %%|",
      "IFU TOTAL", "L1I/PTW", "RESP STAGE", "SERIAL");
  Log("|%10.0e,%3.0f|%10.0e,%3.0f|%10.0e,%3.0f|%10.0e,%3.0f|",
      (double)pmu.ifu_stall_cycle, percentage(pmu.ifu_stall_cycle, pmu.active_cycle),
      (double)pmu.ifu_icache_miss_cycle, percentage(pmu.ifu_icache_miss_cycle, pmu.ifu_stall_cycle),
      (double)pmu.ifu_flush_cycle, percentage(pmu.ifu_flush_cycle, pmu.ifu_stall_cycle),
      (double)pmu.ifu_empty_cycle, percentage(pmu.ifu_empty_cycle, pmu.ifu_stall_cycle));
  Log("IFU roots exact: total %lld, no-response %lld, response-stage %lld, serializing %lld",
      pmu.ifu_stall_cycle, pmu.ifu_icache_miss_cycle,
      pmu.ifu_flush_cycle, pmu.ifu_empty_cycle);
  Log("response-stage origin: redirect %lld, prior-L1I-gap %lld, other %lld",
      pmu.ifu_response_after_redirect_cycle, pmu.ifu_response_after_l1i_gap_cycle,
      pmu.ifu_flush_cycle - pmu.ifu_response_after_redirect_cycle - pmu.ifu_response_after_l1i_gap_cycle);
  Log("response-stage direct-bypass candidates: %lld", pmu.ifu_response_bypass_candidate_cycle);
  Log("no-response roots: refill/PTW %lld, SRAM warmup %lld, tag miss %lld, next-word miss %lld, other %lld",
      pmu.ifu_no_response_refill_cycle, pmu.ifu_no_response_sram_warmup_cycle,
      pmu.ifu_no_response_tag_miss_cycle, pmu.ifu_no_response_nextword_miss_cycle,
      pmu.ifu_icache_miss_cycle - pmu.ifu_no_response_refill_cycle - pmu.ifu_no_response_sram_warmup_cycle - pmu.ifu_no_response_tag_miss_cycle - pmu.ifu_no_response_nextword_miss_cycle);
  Log("L1I refill starts: line miss %lld, current-word hole %lld, next-line miss %lld, next-word hole %lld",
      pmu.l1i_refill_start_line_miss, pmu.l1i_refill_start_current_hole,
      pmu.l1i_refill_start_next_line_miss, pmu.l1i_refill_start_next_hole);
    Log("FQU: full %lld cycles, buffered %lld cycles, avg occupancy %4.2f / 2",
      pmu.fqu_full_cycle, pmu.fqu_buffered_cycle,
      pmu.active_cycle ? (double)pmu.fqu_occupancy_sum / pmu.active_cycle : 0.0);

  Log("======== Fetch Delivery ========");
  Log("packets: %lld, instructions: %lld, avg/packet: %4.2f, dual packets: %lld (%2.1f%%)",
      pmu.ifu_fetch_cnt, pmu.ifu_fetch_inst_cnt,
      pmu.ifu_fetch_cnt ? (double)pmu.ifu_fetch_inst_cnt / pmu.ifu_fetch_cnt : 0.0,
      pmu.ifu_dual_fetch_cnt, percentage(pmu.ifu_dual_fetch_cnt, pmu.ifu_fetch_cnt));
  Log("L1I response consumes: %lld; gem5-aligned B-CFI deferrals: %lld (%2.1f%% consumes, %4.1f / 1K active cycles)",
      pmu.ifu_fetch_response_cnt, pmu.ifu_fetch_slot_b_control_cnt,
      percentage(pmu.ifu_fetch_slot_b_control_cnt, pmu.ifu_fetch_response_cnt),
      pmu.active_cycle
          ? 1000.0 * (double)pmu.ifu_fetch_slot_b_control_cnt / pmu.active_cycle
          : 0.0);
  Log("slot-B direct-JAL packs: %lld (%2.1f%% response consumes)",
      pmu.ifu_fetch_slot_b_jal_pack_cnt,
      percentage(pmu.ifu_fetch_slot_b_jal_pack_cnt, pmu.ifu_fetch_response_cnt));
  Log("slot-B conditional packs: %lld (%2.1f%% response consumes)",
      pmu.ifu_fetch_slot_b_cond_pack_cnt,
      percentage(pmu.ifu_fetch_slot_b_cond_pack_cnt, pmu.ifu_fetch_response_cnt));
  Log("predicted target-steered packets: %lld (%2.1f%% response consumes)",
      pmu.ifu_fetch_target_steer_cnt,
      percentage(pmu.ifu_fetch_target_steer_cnt, pmu.ifu_fetch_response_cnt));
  Log("next-word unavailable roots: unaligned R32+R32 %lld (%2.1f%%), L1I/PMP %lld (%2.1f%%)",
      pmu.ifu_fetch_n1_unavailable_unaligned_cnt,
      percentage(pmu.ifu_fetch_n1_unavailable_unaligned_cnt, pmu.ifu_fetch_response_cnt),
      pmu.ifu_fetch_n1_unavailable_l1i_cnt,
      percentage(pmu.ifu_fetch_n1_unavailable_l1i_cnt, pmu.ifu_fetch_response_cnt));
  Log("slot-B loss (%% packets): BPU-taken %lld (%2.1f%%), A-control %lld (%2.1f%%), "
      "B-control %lld (%2.1f%%), next-word unavailable %lld (%2.1f%%), IDU blocked %lld (%2.1f%%)",
      pmu.ifu_fetch_bpu_taken_cnt, percentage(pmu.ifu_fetch_bpu_taken_cnt, pmu.ifu_fetch_cnt),
      pmu.ifu_fetch_slot_a_control_cnt, percentage(pmu.ifu_fetch_slot_a_control_cnt, pmu.ifu_fetch_cnt),
      pmu.ifu_fetch_slot_b_control_cnt, percentage(pmu.ifu_fetch_slot_b_control_cnt, pmu.ifu_fetch_cnt),
      pmu.ifu_fetch_n1_unavailable_cnt, percentage(pmu.ifu_fetch_n1_unavailable_cnt, pmu.ifu_fetch_cnt),
      pmu.ifu_fetch_downstream_blocked_cycle,
      percentage(pmu.ifu_fetch_downstream_blocked_cycle, pmu.active_cycle));

  // -------------------------------------------------------------------
  // Structural-full events  (gem5: iqFullEvents / robFullEvents / sqFullEvents)
  // -------------------------------------------------------------------
  Log("======== Structural Full (events / cycles, %% of total) ========");
  Log("|%10s|%14s|%10s|%13s|%10s|%13s|%10s|%10s|",
      "RS EVT", "RS CYC, %", "IOQ EVT", "IOQ CYC, %",
      "UOQ EVT", "UOQ CYC, %", "ROB EVT", "SQ EVT/CYC");
  Log("|%10lld|%9.0e,%4.1f|%10lld|%8.0e,%4.1f|%10lld|%8.0e,%4.1f|%10lld|%5lld/%4.1f|",
      pmu.rs_full_events, (double)pmu.rs_full_cycle, percentage(pmu.rs_full_cycle, pmu.active_cycle),
      pmu.ioq_full_events, (double)pmu.ioq_full_cycle, percentage(pmu.ioq_full_cycle, pmu.active_cycle),
      pmu.uoq_blocked_events, (double)pmu.uoq_blocked_cycle, percentage(pmu.uoq_blocked_cycle, pmu.active_cycle),
      pmu.rob_full_events, pmu.sq_full_events, percentage(pmu.sq_full_cycle, pmu.active_cycle));

  // -------------------------------------------------------------------
  // Commit-width distribution  (gem5: commit.committed_per_cycle)
  // -------------------------------------------------------------------
  Log("======== Commit Width Distribution ========");
  Log("|%13s, %%|%13s, %%|%13s, %%|  avg/cycle: %5.3f",
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
  Log("|%13s, %%|%13s, %%|%13s, %%|%13s, %%|",
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