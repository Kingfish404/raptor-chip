#include <common.h>
#include <difftest.h>
#include <readline/readline.h>
#include <readline/history.h>
#include <npc_verilog.h>
#include CONCAT_HEAD(CONCAT(TOP_NAME, _rapt_pkg))
#include <algorithm>
#include <array>
#include <recovery_metrics.h>

#include <unistd.h>
#include <fcntl.h>

extern NPCState npc;
extern TOP_NAME *top;

uint64_t get_time();

PMUState pmu;
word_t start_timer = 0;
word_t g_timer = 0;

struct PMUSamplerState
{
  bool branch_recovery_active;
  bool prev_rs_full;
  bool prev_ioq_full;
  bool prev_uoq_blocked;
  bool prev_sq_full;
  uint8_t prev_l1i_state;
  uint8_t prev_l1d_state;
};

static PMUSamplerState sampler_state = {};
using RtlConfig = CONCAT(TOP_NAME, _rapt_pkg);
struct DispatchMetrics
{
  std::array<uint64_t, RtlConfig::DispatchStopCount> cycles, zero_progress_cycles, unfilled_slots;
  std::array<uint64_t, RtlConfig::ExecutionDomains> endpoint_cycles;
  std::array<uint64_t, RtlConfig::DispatchWidth + 1> histogram;
  uint64_t accepted;
};
static DispatchMetrics dispatch_metrics = {};
struct RobDispatchMetrics
{
  std::array<uint64_t, RtlConfig::ExecutionDomains> blocked_domains;
  std::array<uint64_t, RtlConfig::ExecutionDomains> pending_domain_sum, pending_domain_peak;
  std::array<uint64_t, RtlConfig::ROBEntries + 1> pending_histogram;
  uint64_t candidates, accepted, bypass, oldest_blocked_cycles, pending_sum, pending_peak;
};
static RobDispatchMetrics rob_dispatch_metrics = {};
// Mirrors rapt_pkg::DOMAIN_BRANCH and rapt_iq's simulation-only reason codes.
static constexpr unsigned BranchDomain = 1;
static std::array<uint64_t, 7> branch_capacity_reasons = {};
static std::array<uint64_t, RtlConfig::IntegerIssuePorts + 1> alq_issue_histogram = {};
using ControlRecoveryMetrics = RecoveryMetrics<RtlConfig::ROBEntries,
    RtlConfig::CfAllocate, RtlConfig::CfResolve, RtlConfig::CfMispredict,
    RtlConfig::CfRetire, RtlConfig::CfTrap>;
static ControlRecoveryMetrics recovery_metrics;
struct RecoveryHeadMetrics {
  std::array<uint64_t, RtlConfig::ExecutionDomains> waiting{};
  uint64_t ready = 0, empty = 0;
};
static RecoveryHeadMetrics recovery_head;

static void report_recovery_metrics()
{
  const auto &m = recovery_metrics;
  const auto u = [](uint64_t n) { return static_cast<unsigned long long>(n); };
  assert(m.conserved());
  Log("Control lifecycle: allocated %llu, resolved %llu, retired %llu, traps %llu, "
      "killed unresolved %llu, killed correct %llu, killed wrong %llu, reset discarded %llu, live %llu",
      u(m.allocated), u(m.resolved), u(m.retired), u(m.trap_retired), u(m.killed_unresolved),
      u(m.killed_correct), u(m.wrong_killed.count), u(m.reset_discarded), u(m.live_count()));
  const auto latency = [&](const char *name, const ControlRecoveryMetrics::Latency &v) {
    Log("Control latency %s: count %llu, cycles %llu, max %llu", name, u(v.count), u(v.cycles), u(v.maximum));
    for (unsigned bucket = 0; bucket < v.histogram.size(); ++bucket)
      Log("Control histogram %s bucket %u: count %llu", name, bucket, u(v.histogram[bucket]));
  };
  latency("correct_retire", m.correct_retire);
  latency("wrong_retire", m.wrong_retire);
  latency("wrong_killed", m.wrong_killed);
  Log("Control pending wrong: union cycles %llu, instruction cycles %llu, max concurrent %llu, live %llu",
      u(m.pending_wrong_cycles), u(m.pending_wrong_integral), u(m.pending_wrong_max), u(m.pending_wrong()));
  Log("Control pending residual: trap cycles %llu, reset cycles %llu, live cycles %llu",
      u(m.wrong_trap_cycles), u(m.wrong_reset_cycles), u(m.live_wrong_age()));
  uint64_t head_total = recovery_head.ready + recovery_head.empty;
  for (unsigned domain = 0; domain < recovery_head.waiting.size(); ++domain) {
    head_total += recovery_head.waiting[domain];
    Log("Control pending head domain %u: waiting cycles %llu", domain, u(recovery_head.waiting[domain]));
  }
  assert(head_total == m.pending_wrong_cycles);
  Log("Control pending head: ready cycles %llu, empty cycles %llu", u(recovery_head.ready), u(recovery_head.empty));
}

static const char *dispatch_reason_name(unsigned reason)
{
  switch (reason)
  {
  case RtlConfig::DispatchStopWidth: return "width";
  case RtlConfig::DispatchStopEmpty: return "empty";
  case RtlConfig::DispatchStopFlush: return "flush";
  case RtlConfig::DispatchStopHalt: return "halt";
  case RtlConfig::DispatchStopSerialBusy: return "serial_busy";
  case RtlConfig::DispatchStopSerialWait: return "serial_wait";
  case RtlConfig::DispatchStopSerialBoundary: return "serial_boundary";
  case RtlConfig::DispatchStopRob: return "rob";
  case RtlConfig::DispatchStopEndpoint: return "endpoint";
  case RtlConfig::DispatchStopReset: return "reset";
  case RtlConfig::DispatchStopRecovery: return "recovery";
  default: return "unknown";
  }
}

void perf_reset_counters()
{
  memset(&pmu, 0, sizeof(pmu));
  dispatch_metrics = {};
  rob_dispatch_metrics = {};
  branch_capacity_reasons = {};
  alq_issue_histogram = {};
  recovery_metrics = {};
  recovery_head = {};
  sampler_state = {};
}

void perf_reset_sampler_state()
{
  sampler_state = {};
  recovery_metrics.reset_epoch();
}

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
  const double elapsed_s = (current_time - start_timer) / 1000000.0;
  printf(" Simulated Time: %.3f s\n", (current_time - start_timer) / 1000000.0);
  printf("Simulated Speed: %.3f MIPS\n",
         elapsed_s > 0.0 ? (pmu.instr_cnt / 1000000.0) / elapsed_s : 0.0);
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

static double percentage(long long int a, long long int b)
{
  return (b == 0) ? 0.0 : (100.0 * static_cast<double>(a) / static_cast<double>(b));
}

static void sample_branch(bool valid, bool b, bool j, bool jr, bool mispredict)
{
  if (!valid)
    return;
  const bool is_control_flow = b || j || jr;
  pmu.bpu_cnt += is_control_flow ? 1 : 0;
  pmu.bpu_fail_cnt += is_control_flow && mispredict ? 1 : 0;
  pmu.bpu_b_fail += b && mispredict ? 1 : 0;
  // `jen` is set for both JAL and JALR; keep the failure subtypes exclusive.
  pmu.bpu_j_fail += j && !jr && mispredict ? 1 : 0;
  pmu.bpu_jr_fail += jr && mispredict ? 1 : 0;
}

void perf_sample_per_cycle()
{
  bool reset = (uint8_t)(VERILOG_RESET);
  if (reset)
  {
    perf_reset_sampler_state();
    return;
  }
  pmu.active_cycle++;
  if (recovery_metrics.pending_wrong()) {
    if (!VERILOG_ROU(pmu_cf_head_busy)) ++recovery_head.empty;
    else if (!VERILOG_ROU(pmu_cf_head_waiting)) ++recovery_head.ready;
    else {
      const unsigned domain = VERILOG_ROU(pmu_cf_head_domain);
      assert(domain < recovery_head.waiting.size());
      ++recovery_head.waiting[domain];
    }
  }
  recovery_metrics.sample(VERILOG_ROU(pmu_cf_events), VERILOG_CPU(cmu__DOT__flush_pipe_r));
  const unsigned dispatch_count = VERILOG_ROU(pmu_dispatch_count);
  const unsigned dispatch_reason = VERILOG_ROU(pmu_dispatch_reason);
  assert(dispatch_count <= RtlConfig::DispatchWidth && dispatch_reason < RtlConfig::DispatchStopCount);
  dispatch_metrics.cycles[dispatch_reason]++;
  dispatch_metrics.zero_progress_cycles[dispatch_reason] += dispatch_count == 0;
  dispatch_metrics.unfilled_slots[dispatch_reason] += RtlConfig::DispatchWidth - dispatch_count;
  dispatch_metrics.histogram[dispatch_count]++;
  dispatch_metrics.accepted += dispatch_count;
  if (dispatch_reason == RtlConfig::DispatchStopEndpoint)
  {
    const unsigned domain = VERILOG_ROU(pmu_dispatch_stop_domain);
    assert(domain < RtlConfig::ExecutionDomains);
    dispatch_metrics.endpoint_cycles[domain]++;
  }
  const unsigned steer_candidates = VERILOG_ROU(pmu_steer_candidates);
  const unsigned steer_accepted = VERILOG_ROU(pmu_steer_accepted);
  const unsigned steer_bypass = VERILOG_ROU(pmu_steer_bypass);
  const unsigned steer_pending = VERILOG_ROU(pmu_steer_pending);
  const bool steer_oldest_blocked = VERILOG_ROU(pmu_steer_oldest_blocked);
  assert(steer_accepted <= steer_candidates && steer_accepted <= RtlConfig::DispatchWidth
         && steer_candidates <= RtlConfig::SteerScanEntries);
  assert(steer_bypass <= steer_accepted && steer_pending <= RtlConfig::ROBEntries);
  rob_dispatch_metrics.candidates += steer_candidates;
  rob_dispatch_metrics.accepted += steer_accepted;
  rob_dispatch_metrics.bypass += steer_bypass;
  rob_dispatch_metrics.oldest_blocked_cycles += steer_oldest_blocked;
  rob_dispatch_metrics.pending_sum += steer_pending;
  rob_dispatch_metrics.pending_histogram[steer_pending]++;
  rob_dispatch_metrics.pending_peak = std::max(rob_dispatch_metrics.pending_peak,
                                               static_cast<uint64_t>(steer_pending));
  unsigned steer_pending_domain_total = 0;
  for (unsigned domain = 0; domain < RtlConfig::ExecutionDomains; ++domain)
  {
    const unsigned count = VERILOG_ROU(pmu_steer_pending_domain)[domain];
    steer_pending_domain_total += count;
    rob_dispatch_metrics.pending_domain_sum[domain] += count;
    rob_dispatch_metrics.pending_domain_peak[domain] = std::max(
        rob_dispatch_metrics.pending_domain_peak[domain], static_cast<uint64_t>(count));
  }
  assert(steer_pending_domain_total == steer_pending);
  if (steer_oldest_blocked)
  {
    const unsigned domain = VERILOG_ROU(pmu_steer_blocked_domain);
    assert(domain < RtlConfig::ExecutionDomains);
    rob_dispatch_metrics.blocked_domains[domain]++;
    if (domain == BranchDomain)
    {
      // Both observations capture the same pre-edge queue/candidate state.
      const unsigned reason = VERILOG_CPU(ieu__DOT__u_brq__DOT__pmu_capacity_reason);
      assert(reason > 0 && reason < branch_capacity_reasons.size());
      branch_capacity_reasons[reason]++;
    }
  }
  pmu.alq_ready_entry_cycles += VERILOG_CPU(ieu__DOT__u_alq__DOT__pmu_select_ready);
  const unsigned alq_issue_count = VERILOG_CPU(ieu__DOT__u_alq__DOT__pmu_select_issued);
  assert(alq_issue_count <= RtlConfig::IntegerIssuePorts);
  pmu.alq_issued += alq_issue_count;
  alq_issue_histogram[alq_issue_count]++;
  pmu.alq_rebalance_gain += VERILOG_CPU(ieu__DOT__u_alq__DOT__pmu_select_gain);
  pmu.alq_reclaim_allocations += VERILOG_CPU(ieu__DOT__u_alq__DOT__pmu_reclaim_allocations);
  pmu.alq_extra_port_issues += VERILOG_CPU(ieu__DOT__pmu_alq_extra_port_count);
  // Sample every registered retirement, independently of physical issue ports.
  bool wb_valid = *(uint8_t *)&VERILOG_CPU(cmu__DOT__valid);
  const uint32_t retire_count = VERILOG_CPU(cmu__DOT__retire_count);
  for (uint32_t slot = 0; slot < retire_count; ++slot)
    sample_branch(true, VERILOG_CPU(cmu__DOT__ben_slots)[slot],
                  VERILOG_CPU(cmu__DOT__jen_slots)[slot],
                  VERILOG_CPU(cmu__DOT__jren_slots)[slot],
                  VERILOG_CPU(cmu__DOT__mispredict_slots)[slot]);
  bool ifu_hazard = *(uint8_t *)&VERILOG_CPU(ifu__DOT__ifu_hazard);
  bool ifu_fetch_fire = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_fire);
  uint32_t ifu_fetch_slots = VERILOG_CPU(ifu__DOT__pmu_fetch_slots);
  bool ifu_fetch_response_consume = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_response_consume);
  bool ifu_fetch_multi = ifu_fetch_slots > 1;
  bool ifu_fetch_bpu_taken = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_bpu_taken);
  bool ifu_fetch_first_control = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_first_control);
  bool ifu_fetch_aux_conditional = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_aux_conditional);
  bool ifu_fetch_nonfirst_jal_pack = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_nonfirst_jal_pack);
  bool ifu_fetch_nonfirst_cond_pack = *(uint8_t *)&VERILOG_CPU(ifu__DOT__pmu_fetch_nonfirst_cond_pack);
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

  bool rou_ready = VERILOG_ROU(pmu_enqueue_ready);
  // OoO scheduler stall: any ALU-class IQ holds pending work but no IEU pipe
  // issued this cycle. The IOQ is owned by the LSU.
  bool exu_ooo_valid = *(uint8_t *)&VERILOG_CPU(ieu__DOT__pmu_ooo_valid);
  bool exu_ooo_valid_found = *(uint8_t *)&VERILOG_CPU(ieu__DOT__pmu_ooo_valid_found);
  bool exu_ioq_valid = *(uint8_t *)&VERILOG_CPU(lsu__DOT__u_ioq__DOT__pmu_ioq_any_valid);
  bool exu_ioq_full = *(uint8_t *)&VERILOG_CPU(lsu__DOT__u_ioq__DOT__pmu_ioq_all_full);
  bool exu_ioq_valid_found = *(uint8_t *)&VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_valid_found);
  uint8_t l1d_state = *(uint8_t *)&VERILOG_CPU(l1d_cache__DOT__l1d_state);
  bool lsu_l1d_hit = *(uint8_t *)&VERILOG_CPU(l1d_cache__DOT__tag_hit);
  bool lsu_fwd_hit = *(uint8_t *)&VERILOG_CPU(lsu__DOT__u_sq__DOT__fwd_hit);
  bool lsu_load_in_sq = *(uint8_t *)&VERILOG_CPU(lsu__DOT__u_sq__DOT__load_in_sq);
  bool lsu_raddr_valid = *(uint8_t *)&VERILOG_CPU(lsu__DOT__u_sq__DOT__raddr_valid);
  bool wbu_valid = *(uint8_t *)&VERILOG_CPU(cmu__DOT__valid);
  uint8_t l1i_state = *(uint8_t *)&VERILOG_CPU(l1i_cache__DOT__l1i_state);
  if (ifu_fetch_fire)
  {
    pmu.ifu_fetch_cnt++;
  }
  pmu.ifu_fetch_inst_cnt += ifu_fetch_slots;
  pmu.ifu_fetch_response_cnt += ifu_fetch_response_consume ? 1 : 0;
  pmu.ifu_multi_fetch_cnt += ifu_fetch_multi ? 1 : 0;
  pmu.ifu_fetch_bpu_taken_cnt += ifu_fetch_bpu_taken ? 1 : 0;
  pmu.ifu_fetch_first_control_cnt += ifu_fetch_first_control ? 1 : 0;
  pmu.ifu_fetch_aux_conditional_cnt += ifu_fetch_aux_conditional ? 1 : 0;
  pmu.ifu_fetch_nonfirst_jal_pack_cnt += ifu_fetch_nonfirst_jal_pack ? 1 : 0;
  pmu.ifu_fetch_nonfirst_cond_pack_cnt += ifu_fetch_nonfirst_cond_pack ? 1 : 0;
  pmu.ifu_fetch_n1_unavailable_cnt += ifu_fetch_n1_unavailable ? 1 : 0;
  pmu.ifu_fetch_n1_unavailable_unaligned_cnt += ifu_fetch_n1_unavailable_unaligned ? 1 : 0;
  pmu.ifu_fetch_n1_unavailable_l1i_cnt += ifu_fetch_n1_unavailable_l1i ? 1 : 0;
  pmu.ifu_fetch_downstream_blocked_cycle += ifu_fetch_downstream_blocked ? 1 : 0;
  pmu.ifu_fetch_target_steer_cnt += ifu_fetch_target_steer ? 1 : 0;
  // IFU stall: IDU was ready but IFU had no instruction (registered for correct timing)
  pmu.ifu_stall_cycle += ifu_stall ? 1 : 0;
  pmu.ifu_sys_hazard_cycle += ifu_hazard ? 1 : 0;
  // ROU structural hazard: RNU has renamed work but the dispatch path cannot
  // accept it. Ordered UOQ readiness is space based, so this is not a
  // ROB-full probe.
  bool rnu_valid = VERILOG_CPU(rnu__DOT__pmu_pending);
  pmu.rou_hazard_cycle += (rnu_valid && !rou_ready) ? 1 : 0;
  const bool checkpoint_full = VERILOG_CPU(rnu__DOT__pmu_checkpoint_full);
  const bool checkpoint_stall = VERILOG_CPU(rnu__DOT__pmu_checkpoint_stall);
  const bool rename_recovery_fence = VERILOG_CPU(rnu__DOT__pmu_recovery_fence);
  const bool recovery_early_redirect = VERILOG_ROU(pmu_recovery_redirect);
  const uint32_t checkpoint_occupancy = VERILOG_CPU(rnu__DOT__pmu_checkpoint_occupancy);
  assert(checkpoint_occupancy <= RtlConfig::BranchCheckpoints);
  pmu.rename_checkpoint_full_cycle += checkpoint_full;
  pmu.rename_checkpoint_stall_cycle += checkpoint_stall;
  pmu.rename_checkpoint_occupancy_sum += checkpoint_occupancy;
  if (pmu.rename_checkpoint_peak < static_cast<long long>(checkpoint_occupancy))
    pmu.rename_checkpoint_peak = checkpoint_occupancy;
  pmu.rename_recovery_fence_cycle += rename_recovery_fence;
  pmu.recovery_early_redirect_events += recovery_early_redirect;
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
  // IDU early resteer: static decode or speculative RAS target correction.
  bool early_resteer = *(uint8_t *)&VERILOG_CPU(idu__DOT__pmu_early_resteer);
  pmu.early_resteer_cnt += early_resteer ? 1 : 0;

  // Measure the end-to-end frontend recovery after an exact branch-caused
  // commit flush. This intentionally includes any downstream backpressure
  // encountered before the corrected path can supply its first packet.
  // The ROU head/flush classification is combinational and has advanced by
  // the time the C++ sampler runs after the clock edge.  Use CMU's registered
  // flush and per-slot commit snapshots, which are aligned with `wb_valid`.
  bool flush_pipe_r = *(uint8_t *)&VERILOG_CPU(cmu__DOT__flush_pipe_r);
  bool branch_flush = flush_pipe_r && wb_valid
      && VERILOG_CPU(cmu__DOT__mispredict_slots)[0]
      && (VERILOG_CPU(cmu__DOT__ben_slots)[0]
          || VERILOG_CPU(cmu__DOT__jen_slots)[0]
          || VERILOG_CPU(cmu__DOT__jren_slots)[0]);
  bool nonbranch_flush = flush_pipe_r && !branch_flush;
  if (branch_flush)
  {
    pmu.branch_flush_events++;
    pmu.branch_recovery_overlap_events += sampler_state.branch_recovery_active ? 1 : 0;
    sampler_state.branch_recovery_active = true;
  }
  else if (sampler_state.branch_recovery_active)
  {
    pmu.branch_recovery_wait_cycles++;
    if (ifu_fetch_fire)
    {
      pmu.branch_recovery_completed++;
      sampler_state.branch_recovery_active = false;
    }
  }
  pmu.nonbranch_flush_events += nonbranch_flush ? 1 : 0;
  pmu.lsu_fwd_cnt += (lsu_raddr_valid && lsu_fwd_hit) ? 1 : 0;
  pmu.lsu_sq_conflict_cnt += (lsu_raddr_valid && lsu_load_in_sq) ? 1 : 0;
  pmu.dual_commit_cnt += retire_count == 2 ? 1 : 0;
  pmu.commit_multi_inst += retire_count > 1 ? retire_count : 0;
  if (!wbu_valid)
  {
    pmu.wbu_stall_cycle++;
  }

  // -------------------------------------------------------------------
  // Extended PMU samples. These are Raptor-local event definitions; some are
  // useful for comparison with similarly named gem5 statistics, but they are
  // not assumed to have identical sampling boundaries.
  // -------------------------------------------------------------------
  // 1. IFU stall decomposition. The IFU publishes registered, mutually
  // exclusive root causes; do not approximate flush cost with a fixed timer.
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
  //    ALQ-full proxy: the integer ALU reservation station is full.
  //    IOQ probes are one-bit reductions and work for every configured depth.
  //    UOQ-blocked: rnu has a renamed uop but the dispatch path cannot accept it.
  //    True ROB-full is the rapt_rou all-entry-busy event pulse.
  //    SQ-full: width-stable 1-bit probe from the LSU (&sq_valid).
  bool rs_full = *(uint8_t *)&VERILOG_CPU(ieu__DOT__pmu_ooo_full);
  bool ioq_full = exu_ioq_full;
  bool uoq_blocked = rnu_valid && !rou_ready;
  bool rob_full_event = *(uint8_t *)&VERILOG_ROU(pmu_rob_full);
  bool sq_full = npc.sq_full && (*npc.sq_full != 0);
  if (rs_full)
  {
    pmu.rs_full_cycle++;
    if (!sampler_state.prev_rs_full)
      pmu.rs_full_events++;
  }
  if (ioq_full)
  {
    pmu.ioq_full_cycle++;
    if (!sampler_state.prev_ioq_full)
      pmu.ioq_full_events++;
  }
  if (uoq_blocked)
  {
    pmu.uoq_blocked_cycle++;
    if (!sampler_state.prev_uoq_blocked)
      pmu.uoq_blocked_events++;
  }
  pmu.rob_full_events += rob_full_event ? 1 : 0;
  if (sq_full)
  {
    pmu.sq_full_cycle++;
    if (!sampler_state.prev_sq_full)
      pmu.sq_full_events++;
  }
  sampler_state.prev_rs_full = rs_full;
  sampler_state.prev_ioq_full = ioq_full;
  sampler_state.prev_uoq_blocked = uoq_blocked;
  sampler_state.prev_sq_full = sq_full;

  // 3. Commit-width distribution (per cycle).
  if (retire_count > 2)
    pmu.commit_wide_cycle++;
  else if (retire_count == 2)
    pmu.commit_2_cycle++;
  else if (wbu_valid)
    pmu.commit_1_cycle++;
  // commit_0_cycle implicitly == wbu_stall_cycle (already accumulated above).

  // 4. Rename/dispatch status mix.
  // Raptor clears rename/dispatch queues in one edge; this registered pulse is
  // the exact squash interval. A fixed five-cycle estimate overstated it.
  if (flush_pipe_r)
    pmu.dispatch_squash_cycle++;
  else if (rnu_valid && rou_ready)
    pmu.dispatch_running_cycle++;
  else if (rnu_valid && !rou_ready)
    pmu.dispatch_blocked_cycle++;
  else
    pmu.dispatch_idle_cycle++;
  // L1I cache sample: explicit refill starts and service states.
  // L1I FSM states: IDLE=000, RD_A=001, RD_0=010, PTWAIT=100, TRAP=101, RD_1=110, FINA=111
  bool entering_i_ptw = (sampler_state.prev_l1i_state != 0b100) && (l1i_state == 0b100);
  // Count a cache miss only when the RTL starts a refill. IDLE->PTWAIT is an
  // ITLB miss and RD_A can be only a translated-address/SRAM recheck.
  if (l1i_refill_start_line_miss || l1i_refill_start_current_hole ||
      l1i_refill_start_next_line_miss || l1i_refill_start_next_hole)
    pmu.l1i_cache_miss_cnt++;
  // Only the cache-refill FSM contributes cache miss service cycles; page-table
  // walk time remains in the dedicated ITLB counters below.
  if (l1i_state == 0b010 || l1i_state == 0b110 || l1i_state == 0b111)
    pmu.l1i_cache_miss_cycle++;
  sampler_state.prev_l1i_state = l1i_state;
  // L1D cache sample: state-transition-based tracking (load path only)
  // L1D FSM states: IDLE=000, LD_A=001, LD_D=010, PTWAIT=100, TRAP=101
  bool entering_d_ptw = (sampler_state.prev_l1d_state != 0b100) && (l1d_state == 0b100);
  // Hit: LD_A with tag_hit (1-cycle load hit)
  if (l1d_state == 0b001 && lsu_l1d_hit)
  {
    pmu.l1d_cache_hit_cnt++;
  }
  // Miss: transition from LD_A to LD_D (tag miss, going to memory)
  if (sampler_state.prev_l1d_state == 0b001 && l1d_state == 0b010)
  {
    pmu.l1d_cache_miss_cnt++;
  }
  // Miss cycles: accumulate while L1D is fetching from memory
  if (l1d_state == 0b010) // LD_D
  {
    pmu.l1d_cache_miss_cycle++;
  }
  sampler_state.prev_l1d_state = l1d_state;
  // tlb & page table walk sample
  char stlb_mmu = *(char *)&VERILOG_CPU(l1d_cache__DOT__stlb_mmu);
  bool i_ptw = (l1i_state == 0b100); // PTWAIT
  pmu.itlb_ptw_count += entering_i_ptw ? 1 : 0;
  if (i_ptw)
  {
    pmu.itlb_ptw_cycle++;
  }
  bool dtlb_ptw = (l1d_state == 0b100); // PTWAIT
  if (entering_d_ptw)
  {
    if (stlb_mmu)
      pmu.stlb_ptw_count++;
    else
      pmu.ltlb_ptw_count++;
  }
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
  OP_JAL_ = 0b1101111,
  OP_JALR = 0b1100111,
} rv_opcode_t;

void perf_sample_per_inst(uint32_t inst)
{
  if ((uint8_t)(VERILOG_RESET))
  {
    return;
  }
  pmu.instr_cnt++;
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
  case 0b0111011: // RV64 OP-32: addw/subw/shifts and M-extension word ops
  case 0b0011011: // RV64 OP-IMM-32
  case 0b0110111: // LUI
  case 0b0010111: // AUIPC
    pmu.alu_inst_cnt++;
    break;
  case 0b1100011: // B type: beq, bne, blt, bge, bltu, bgeu
    pmu.b_inst_cnt++;
    break;
  case OP_JAL_: // J type: jal
    pmu.jal_inst_cnt++;
    pmu.call_inst_cnt += ((((inst >> 7) & 0x1f) == 1 || ((inst >> 7) & 0x1f) == 5) ? 1 : 0);
    break;
  case OP_JALR: // I type: jalr
    pmu.jalr_inst_cnt++;
    pmu.call_inst_cnt += ((((inst >> 7) & 0x1f) == 1 || ((inst >> 7) & 0x1f) == 5) ? 1 : 0);
    break;
  case 0b1110011: // N type: ecall, ebreak, csrrw, csrrs, csrrc, csrrwi, csrrsi, csrrci, mert
    pmu.csr_inst_cnt++;
    break;
  default:
    pmu.other_inst_cnt++;
    break;
  }
  const uint32_t rd = (inst >> 7) & 0x1f;
  const uint32_t rs1 = (inst >> 15) & 0x1f;
  const int32_t jalr_imm = static_cast<int32_t>(inst) >> 20;
  const bool is_return = opcode == OP_JALR && rd == 0 && jalr_imm == 0 && (rs1 == 1 || rs1 == 5);
  pmu.ret_inst_cnt += is_return ? 1 : 0;

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
  double IPC = pmu.active_cycle
      ? static_cast<double>(pmu.instr_cnt) / pmu.active_cycle
      : 0.0;
  double MIPS = time_clint_us
      ? static_cast<double>(pmu.instr_cnt) / time_clint_us
      : 0.0;
  Log("#inst: %lld, cycle: %lld, "
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
  Log("======== Stall Probes (categories may overlap) ========");
  Log("|%6s, %%|%6s, %%|%6s, %%|%6s, %%|%6s, %%|%6s, %%|",
      "IFU", "EX|RS", "EX|IoQ", "L1D", "SQ", "NO COMMIT");
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
  Log("Rename checkpoints: pool full %lld cycles, allocation stalls %lld cycles, occupancy avg %.3f, peak %lld; recovery fence %lld cycles",
      pmu.rename_checkpoint_full_cycle, pmu.rename_checkpoint_stall_cycle,
      pmu.active_cycle ? (double)pmu.rename_checkpoint_occupancy_sum / pmu.active_cycle : 0.0,
      pmu.rename_checkpoint_peak, pmu.rename_recovery_fence_cycle);
  Log("Early recovery: redirects %lld, pending-fence window %lld cycles",
      pmu.recovery_early_redirect_events, pmu.rename_recovery_fence_cycle);
  Log("LSU fwd: %lld, sq_conflict: %lld", pmu.lsu_fwd_cnt, pmu.lsu_sq_conflict_cnt);
  // Multi-commit shares use exact retired-instruction counts, not 2*cycles.
  long long int multi_cycles = pmu.commit_2_cycle + pmu.commit_wide_cycle;
  long long int commit_cycles = pmu.commit_1_cycle + multi_cycles;
  Log("Multi commit: %lld cycles, %2.1f%% of commit cycles, %2.1f%% of insts",
      multi_cycles, percentage(multi_cycles, commit_cycles),
      percentage(pmu.commit_multi_inst, pmu.instr_cnt));
  Log("Early resteer: %lld events (decode-stage IFU corrections)",
      pmu.early_resteer_cnt);
  Log("Commit flush: branch %lld, non-branch %lld; branch recovery: %lld completed, "
      "%lld wait cycles (%4.2f cycles/completed), %lld overlaps",
      pmu.branch_flush_events, pmu.nonbranch_flush_events,
      pmu.branch_recovery_completed, pmu.branch_recovery_wait_cycles,
      pmu.branch_recovery_completed
          ? (double)pmu.branch_recovery_wait_cycles / pmu.branch_recovery_completed
          : 0.0,
      pmu.branch_recovery_overlap_events);
  report_recovery_metrics();

  // -------------------------------------------------------------------
  // IFU stall decomposition (Raptor-local, mutually exclusive roots).
  // -------------------------------------------------------------------
  Log("======== IFU Stall Decomposition ========");
  Log("|%10s, %%|%10s, %%|%10s, %%|%10s, %%|",
      "IFU TOTAL", "L1I/PTW", "RESP STAGE", "SERIAL");
  Log("|%10.0e,%3.0f|%10.0e,%3.0f|%10.0e,%3.0f|%10.0e,%3.0f|",
      (double)pmu.ifu_stall_cycle, percentage(pmu.ifu_stall_cycle, pmu.active_cycle),
      (double)pmu.ifu_icache_miss_cycle, percentage(pmu.ifu_icache_miss_cycle, pmu.ifu_stall_cycle),
      (double)pmu.ifu_flush_cycle, percentage(pmu.ifu_flush_cycle, pmu.ifu_stall_cycle),
      (double)pmu.ifu_empty_cycle, percentage(pmu.ifu_empty_cycle, pmu.ifu_stall_cycle));
  Log("IFU probes (overlapping): total %lld, no-response %lld, redirect %lld, serializing %lld",
      pmu.ifu_stall_cycle, pmu.ifu_icache_miss_cycle,
      pmu.ifu_flush_cycle, pmu.ifu_empty_cycle);
  Log("response activity probes: redirect %lld, empty-buffer arrival %lld",
      pmu.ifu_response_after_redirect_cycle, pmu.ifu_response_after_l1i_gap_cycle);
  Log("response-stage direct-bypass candidates: %lld", pmu.ifu_response_bypass_candidate_cycle);
  Log("no-response roots: refill/PTW %lld, SRAM warmup %lld, tag miss %lld, next-word miss %lld, other %lld",
      pmu.ifu_no_response_refill_cycle, pmu.ifu_no_response_sram_warmup_cycle,
      pmu.ifu_no_response_tag_miss_cycle, pmu.ifu_no_response_nextword_miss_cycle,
      pmu.ifu_icache_miss_cycle - pmu.ifu_no_response_refill_cycle - pmu.ifu_no_response_sram_warmup_cycle - pmu.ifu_no_response_tag_miss_cycle - pmu.ifu_no_response_nextword_miss_cycle);
  Log("L1I refill starts: line miss %lld, current-word hole %lld, next-line miss %lld, next-word hole %lld",
      pmu.l1i_refill_start_line_miss, pmu.l1i_refill_start_current_hole,
      pmu.l1i_refill_start_next_line_miss, pmu.l1i_refill_start_next_hole);
  Log("FQU: full %lld cycles, buffered %lld cycles, avg occupancy %4.2f instructions",
      pmu.fqu_full_cycle, pmu.fqu_buffered_cycle,
      pmu.active_cycle ? (double)pmu.fqu_occupancy_sum / pmu.active_cycle : 0.0);

  Log("======== Fetch Delivery ========");
  Log("deliveries: %lld, instructions: %lld, avg/delivery: %4.2f, multi-slot deliveries: %lld (%2.1f%%)",
      pmu.ifu_fetch_cnt, pmu.ifu_fetch_inst_cnt,
      pmu.ifu_fetch_cnt ? (double)pmu.ifu_fetch_inst_cnt / pmu.ifu_fetch_cnt : 0.0,
      pmu.ifu_multi_fetch_cnt, percentage(pmu.ifu_multi_fetch_cnt, pmu.ifu_fetch_cnt));
  Log("L1I response consumes: %lld; auxiliary conditional queries: %lld (%2.1f%% consumes, %4.1f / 1K active cycles)",
      pmu.ifu_fetch_response_cnt, pmu.ifu_fetch_aux_conditional_cnt,
      percentage(pmu.ifu_fetch_aux_conditional_cnt, pmu.ifu_fetch_response_cnt),
      pmu.active_cycle
          ? 1000.0 * (double)pmu.ifu_fetch_aux_conditional_cnt / pmu.active_cycle
          : 0.0);
  Log("Non-first direct-JAL packs: %lld (%2.1f%% response consumes)",
      pmu.ifu_fetch_nonfirst_jal_pack_cnt,
      percentage(pmu.ifu_fetch_nonfirst_jal_pack_cnt, pmu.ifu_fetch_response_cnt));
  Log("Non-first conditional packs: %lld (%2.1f%% response consumes)",
      pmu.ifu_fetch_nonfirst_cond_pack_cnt,
      percentage(pmu.ifu_fetch_nonfirst_cond_pack_cnt, pmu.ifu_fetch_response_cnt));
  Log("predicted target-steered packets: %lld (%2.1f%% response consumes)",
      pmu.ifu_fetch_target_steer_cnt,
      percentage(pmu.ifu_fetch_target_steer_cnt, pmu.ifu_fetch_response_cnt));
  Log("next-word unavailable roots: unaligned R32+R32 %lld (%2.1f%%), L1I/PMP %lld (%2.1f%%)",
      pmu.ifu_fetch_n1_unavailable_unaligned_cnt,
      percentage(pmu.ifu_fetch_n1_unavailable_unaligned_cnt, pmu.ifu_fetch_response_cnt),
      pmu.ifu_fetch_n1_unavailable_l1i_cnt,
      percentage(pmu.ifu_fetch_n1_unavailable_l1i_cnt, pmu.ifu_fetch_response_cnt));
  Log("Fetch probes (overlapping): BPU-taken %lld (%2.1f%%), first-control %lld (%2.1f%%), "
      "aux-conditional %lld (%2.1f%%), next-word unavailable %lld (%2.1f%%), downstream blocked %lld (%2.1f%%)",
      pmu.ifu_fetch_bpu_taken_cnt, percentage(pmu.ifu_fetch_bpu_taken_cnt, pmu.ifu_fetch_cnt),
      pmu.ifu_fetch_first_control_cnt, percentage(pmu.ifu_fetch_first_control_cnt, pmu.ifu_fetch_cnt),
      pmu.ifu_fetch_aux_conditional_cnt, percentage(pmu.ifu_fetch_aux_conditional_cnt, pmu.ifu_fetch_cnt),
      pmu.ifu_fetch_n1_unavailable_cnt, percentage(pmu.ifu_fetch_n1_unavailable_cnt, pmu.ifu_fetch_cnt),
      pmu.ifu_fetch_downstream_blocked_cycle,
      percentage(pmu.ifu_fetch_downstream_blocked_cycle, pmu.active_cycle));

  // -------------------------------------------------------------------
  // Structural-full events. ALQ is the integer ALU reservation station;
  // it must not be presented as an aggregate of every reservation station.
  // -------------------------------------------------------------------
  Log("======== Structural Full (events / cycles, %% of total) ========");
  Log("|%10s|%14s|%10s|%13s|%10s|%13s|%10s|%10s|",
      "ALQ EVT", "ALQ CYC, %", "IOQ EVT", "IOQ CYC, %",
      "UOQ EVT", "UOQ CYC, %", "ROB EVT", "SQ EVT/CYC");
  Log("|%10lld|%9.0e,%4.1f|%10lld|%8.0e,%4.1f|%10lld|%8.0e,%4.1f|%10lld|%5lld/%4.1f|",
      pmu.rs_full_events, (double)pmu.rs_full_cycle, percentage(pmu.rs_full_cycle, pmu.active_cycle),
      pmu.ioq_full_events, (double)pmu.ioq_full_cycle, percentage(pmu.ioq_full_cycle, pmu.active_cycle),
      pmu.uoq_blocked_events, (double)pmu.uoq_blocked_cycle, percentage(pmu.uoq_blocked_cycle, pmu.active_cycle),
      pmu.rob_full_events, pmu.sq_full_events, percentage(pmu.sq_full_cycle, pmu.active_cycle));

  // -------------------------------------------------------------------
  // Commit-width distribution.
  // -------------------------------------------------------------------
  Log("======== Commit Width Distribution ========");
  Log("|%13s, %%|%13s, %%|%13s, %%|  avg/cycle: %5.3f",
      "0 (stall)", "1 (single)", "2 (dual)",
      pmu.active_cycle ? (double)pmu.instr_cnt / pmu.active_cycle : 0.0);
  Log("|%12.0e,%3.0f|%12.0e,%3.0f|%12.0e,%3.0f|",
      (double)pmu.wbu_stall_cycle, percentage(pmu.wbu_stall_cycle, pmu.active_cycle),
      (double)pmu.commit_1_cycle, percentage(pmu.commit_1_cycle, pmu.active_cycle),
      (double)pmu.commit_2_cycle, percentage(pmu.commit_2_cycle, pmu.active_cycle));
  Log("3+ commits: %lld cycles (%2.1f%%)", pmu.commit_wide_cycle,
      percentage(pmu.commit_wide_cycle, pmu.active_cycle));

  // -------------------------------------------------------------------
  // Rename / dispatch status mix.
  // -------------------------------------------------------------------
  Log("======== Rename/Dispatch Status ========");
  Log("ALQ selection: ready-entry cycles %lld, issued %lld, rebalance extra issues %lld",
      pmu.alq_ready_entry_cycles, pmu.alq_issued, pmu.alq_rebalance_gain);
  Log("ALQ issue-slot reclaim: allocations %lld", pmu.alq_reclaim_allocations);
  for (unsigned n = 0; n <= RtlConfig::IntegerIssuePorts; ++n)
    Log("ALQ issue histogram %u: cycles %llu", n,
        static_cast<unsigned long long>(alq_issue_histogram[n]));
  Log("ALQ extra physical ports (index >= 2): issues %lld", pmu.alq_extra_port_issues);
  uint64_t dispatch_cycles = 0, unfilled_slots = 0, zero_progress_cycles = 0;
  uint64_t histogram_cycles = 0, histogram_instructions = 0, endpoint_cycles = 0;
  for (unsigned r = 0; r < RtlConfig::DispatchStopCount; r++)
  {
    dispatch_cycles += dispatch_metrics.cycles[r];
    unfilled_slots += dispatch_metrics.unfilled_slots[r];
    zero_progress_cycles += dispatch_metrics.zero_progress_cycles[r];
    Log("Dispatch stop %s: cycles %" PRIu64 ", unfilled slots %" PRIu64 ", zero-progress cycles %" PRIu64,
        dispatch_reason_name(r), dispatch_metrics.cycles[r], dispatch_metrics.unfilled_slots[r],
        dispatch_metrics.zero_progress_cycles[r]);
  }
  for (unsigned n = 0; n <= RtlConfig::DispatchWidth; n++)
  {
    histogram_cycles += dispatch_metrics.histogram[n];
    histogram_instructions += n * dispatch_metrics.histogram[n];
    Log("Dispatch histogram %u: cycles %" PRIu64, n, dispatch_metrics.histogram[n]);
  }
  for (unsigned d = 0; d < RtlConfig::ExecutionDomains; d++)
  {
    endpoint_cycles += dispatch_metrics.endpoint_cycles[d];
    Log("Dispatch endpoint domain %u: cycles %" PRIu64, d, dispatch_metrics.endpoint_cycles[d]);
  }
  assert(dispatch_cycles == (uint64_t)pmu.active_cycle && histogram_cycles == dispatch_cycles);
  assert(histogram_instructions == dispatch_metrics.accepted);
  assert(zero_progress_cycles == dispatch_metrics.histogram[0]);
  assert(endpoint_cycles == dispatch_metrics.cycles[RtlConfig::DispatchStopEndpoint]);
  assert(unfilled_slots + dispatch_metrics.accepted == RtlConfig::DispatchWidth * dispatch_cycles);
  Log("Dispatch accounting: cycles %" PRIu64 ", width %u, accepted %" PRIu64 ", unfilled %" PRIu64,
      dispatch_cycles, RtlConfig::DispatchWidth, dispatch_metrics.accepted, unfilled_slots);
  Log("ROB dispatch steering: candidates %" PRIu64 ", accepted %" PRIu64
      ", bypass %" PRIu64 ", oldest blocked %" PRIu64
      ", pending avg %.3f, peak %" PRIu64,
      rob_dispatch_metrics.candidates, rob_dispatch_metrics.accepted,
      rob_dispatch_metrics.bypass, rob_dispatch_metrics.oldest_blocked_cycles,
      pmu.active_cycle
          ? static_cast<double>(rob_dispatch_metrics.pending_sum) / pmu.active_cycle : 0.0,
      rob_dispatch_metrics.pending_peak);
  uint64_t steer_blocked_cycles = 0;
  for (unsigned d = 0; d < RtlConfig::ExecutionDomains; d++)
  {
    steer_blocked_cycles += rob_dispatch_metrics.blocked_domains[d];
    Log("ROB dispatch blocked domain %u: cycles %" PRIu64,
        d, rob_dispatch_metrics.blocked_domains[d]);
  }
  assert(steer_blocked_cycles == rob_dispatch_metrics.oldest_blocked_cycles);
  uint64_t branch_classified = 0;
  for (unsigned reason = 0; reason < branch_capacity_reasons.size(); ++reason)
  {
    branch_classified += branch_capacity_reasons[reason];
    Log("ROB branch capacity reason %u: cycles %" PRIu64,
        reason, branch_capacity_reasons[reason]);
  }
  assert(branch_classified == rob_dispatch_metrics.blocked_domains[BranchDomain]);
  uint64_t steer_histogram_cycles = 0, steer_histogram_pending = 0;
  uint64_t steer_histogram_peak = 0;
  for (unsigned n = 0; n <= RtlConfig::ROBEntries; n++)
  {
    const uint64_t cycles = rob_dispatch_metrics.pending_histogram[n];
    steer_histogram_cycles += cycles;
    steer_histogram_pending += n * cycles;
    if (cycles) steer_histogram_peak = n;
    Log("ROB dispatch pending histogram %u: cycles %" PRIu64, n, cycles);
  }
  assert(steer_histogram_cycles == static_cast<uint64_t>(pmu.active_cycle));
  assert(steer_histogram_pending == rob_dispatch_metrics.pending_sum);
  assert(steer_histogram_peak == rob_dispatch_metrics.pending_peak);
  uint64_t steer_pending_domain_sum = 0;
  for (unsigned d = 0; d < RtlConfig::ExecutionDomains; d++)
  {
    steer_pending_domain_sum += rob_dispatch_metrics.pending_domain_sum[d];
    Log("ROB dispatch pending domain %u: instruction-cycles %" PRIu64 ", peak %" PRIu64,
        d, rob_dispatch_metrics.pending_domain_sum[d], rob_dispatch_metrics.pending_domain_peak[d]);
  }
  assert(steer_pending_domain_sum == rob_dispatch_metrics.pending_sum);
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
  Log("======== Cache/Translation Analysis ========");
  // A fetch packet can cause more than one sector/line refill and can be
  // redirected before it completes.  Therefore `fetch packets - refills` is
  // not a cache-hit count and must not be used to manufacture a hit rate or
  // AMAT.  Report only directly observed L1I refill events/service cycles.
  Log("L1I: %lld refill starts, %lld refill-FSM service cycles, %4.2f cycles/start; "
      "%lld response consumes, %lld delivered packets",
      pmu.l1i_cache_miss_cnt, pmu.l1i_cache_miss_cycle,
      pmu.l1i_cache_miss_cnt
          ? (double)pmu.l1i_cache_miss_cycle / pmu.l1i_cache_miss_cnt
          : 0.0,
      pmu.ifu_fetch_response_cnt, pmu.ifu_fetch_cnt);
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
  Log("|%9s|%9s|%9s|%8s, %%|%8s, %%|%8s, %%|",
      "ITLB miss", "STLB miss", "LTLB miss", "ITLB PTW", "STLB PTW", "LTLB PTW");
  Log("|%9lld|%9lld|%9lld|%8lld,%4.1f|%8lld,%4.1f|%8lld,%4.1f|",
      pmu.itlb_ptw_count,
      pmu.stlb_ptw_count,
      pmu.ltlb_ptw_count,
      pmu.itlb_ptw_cycle,
      percentage(pmu.itlb_ptw_cycle, pmu.active_cycle),
      pmu.stlb_ptw_cycle,
      percentage(pmu.stlb_ptw_cycle, pmu.active_cycle),
      pmu.ltlb_ptw_cycle,
      percentage(pmu.ltlb_ptw_cycle, pmu.active_cycle));
}

void statistic()
{
  perf();
  double time_s = g_timer / 1e6;
  double frequency = time_s > 0.0 ? pmu.active_cycle / time_s : 0.0;
  double ips = time_s > 0.0 ? pmu.instr_cnt / time_s : 0.0;
  Log("Simulate time:"
      " " FMT_WORD_NO_PREFIX " us, " FMT_WORD_NO_PREFIX " ms, Freq: %5.3f MHz, Inst: %6.0f I/s, %5.3f MIPS",
      (word_t)g_timer, (word_t)(g_timer / 1000),
      (double)(frequency * 1.0 / 1e6),
      ips, ips / 1e6);
  Log("%s at pc: " FMT_WORD_NO_PREFIX ", inst: " FMT_WORD_NO_PREFIX,
      ((npc.state == NPC_QUIT) ? FMT_BLUE("NPC QUIT")
                               : ((npc.host_exit_ok || *npc.ret == 0) && npc.state != NPC_ABORT
                                      ? FMT_GREEN("HIT GOOD TRAP")
                                      : FMT_RED("HIT BAD TRAP"))),
      (word_t)(*(npc.pc)), (word_t)(*(npc.inst)));
}
