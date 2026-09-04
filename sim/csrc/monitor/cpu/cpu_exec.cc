#include <common.h>
#include <checkpoint.h>
#include <difftest.h>
#include <flow_check.h>
#include <lightsss.h>
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
void serial_tick();
unsigned serial_rx_pending();
const char *serial_input_source();

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

void perf_sample_per_inst(uint32_t inst);

void perf_reset_sampler_state();

void statistic();

static uint64_t tfp_cycle = UINT64_MAX;
static uint64_t tfp_inst = UINT64_MAX;

static void dump_pipeline_stall_state()
{
  Log("stall state: ROB head=%u tail=%u busy=%016llx head_valid=%u "
      "store_ready=%u fence_ready=%u UOQ valid=%02x head=%u tail=%u",
      (unsigned)VERILOG_ROU(rob_head), (unsigned)VERILOG_ROU(rob_tail_a),
      (unsigned long long)VERILOG_ROU(rob_entry_busy),
      (unsigned)VERILOG_ROU(head0_valid),
      (unsigned)VERILOG_ROU(head0_store_ready),
      (unsigned)VERILOG_ROU(head0_fence_ready),
      (unsigned)VERILOG_ROU(uoq_valid),
      (unsigned)VERILOG_ROU(uoq_head_a), (unsigned)VERILOG_ROU(uoq_tail_a));
  Log("stall state: IFU=%u L1I=%u IPTW=%u; L1D=%u DPTW=%u; "
      "AXI rd_out=%u req=%u resp=%u; bus l1d_busy=%u issued=%u "
      "mmio=%u skid=%u source=%u",
      (unsigned)VERILOG_CPU(ifu__DOT__state_ifu),
      (unsigned)VERILOG_CPU(l1i_cache__DOT__l1i_state),
      (unsigned)VERILOG_CPU(l1i_cache__DOT__u_iptw__DOT__state),
      (unsigned)VERILOG_CPU(l1d_cache__DOT__l1d_state),
      (unsigned)VERILOG_CPU(l1d_cache__DOT__u_dptw__DOT__state),
      (unsigned)VERILOG_CPU(axi_master__DOT__read_outstanding),
      (unsigned)VERILOG_CPU(axi_master__DOT__read_request_fire),
      (unsigned)VERILOG_CPU(axi_master__DOT__read_response_fire),
      (unsigned)VERILOG_CPU(bus__DOT__l1d_slot_busy),
      (unsigned)VERILOG_CPU(bus__DOT__l1d_slot_issued),
      (unsigned)VERILOG_CPU(bus__DOT__l1d_slot_mmio),
      (unsigned)VERILOG_CPU(bus__DOT__rd_skid_valid),
      (unsigned)VERILOG_CPU(bus__DOT__source_valid));
  Log("stall state: IOQ valid=%02x complete=%02x mmu=%02x head=%u tail=%u "
      "issue=%u req_valid=%u req_idx=%u at_rob_head=%u; "
      "ALQ valid=%02x ready=%02x p1busy=%02x p2busy=%02x; BRQ valid=%x",
      (unsigned)VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_valid),
      (unsigned)VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_complete),
      (unsigned)VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_mmu_en),
      (unsigned)VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_head),
      (unsigned)VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_tail_a),
      (unsigned)VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_issue_found),
      (unsigned)VERILOG_CPU(lsu__DOT__u_ioq__DOT__load_req_valid_q),
      (unsigned)VERILOG_CPU(lsu__DOT__u_ioq__DOT__load_req_idx_q),
      (unsigned)VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_at_rob_head),
      (unsigned)VERILOG_CPU(ieu__DOT__u_alq__DOT__iq_valid),
      (unsigned)VERILOG_CPU(ieu__DOT__u_alq__DOT__iq_ready_vec),
      (unsigned)VERILOG_CPU(ieu__DOT__u_alq__DOT__iq_pr1_busy),
      (unsigned)VERILOG_CPU(ieu__DOT__u_alq__DOT__iq_pr2_busy),
      (unsigned)VERILOG_CPU(ieu__DOT__u_brq__DOT__iq_valid));
  const size_t ioq_entries = sizeof(VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_pc)) /
                             sizeof(VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_pc)[0]);
  for (size_t i = 0; i < ioq_entries; i++)
  {
    if (VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_valid) & (1u << i))
      Log("stall IOQ[%zu]: pc=" FMT_WORD_NO_PREFIX " dest=%u pr1=%u pr2=%u",
          i, (word_t)VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_pc)[i],
          (unsigned)VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_dest)[i],
          (unsigned)VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_pr1)[i],
          (unsigned)VERILOG_CPU(lsu__DOT__u_ioq__DOT__ioq_pr2)[i]);
  }
  const size_t alq_entries = sizeof(VERILOG_CPU(ieu__DOT__u_alq__DOT__iq_pc)) /
                             sizeof(VERILOG_CPU(ieu__DOT__u_alq__DOT__iq_pc)[0]);
  for (size_t i = 0; i < alq_entries; i++)
  {
    if (VERILOG_CPU(ieu__DOT__u_alq__DOT__iq_valid) & (1u << i))
      Log("stall ALQ[%zu]: pc=" FMT_WORD_NO_PREFIX " dest=%u pr1=%u pr2=%u",
          i, (word_t)VERILOG_CPU(ieu__DOT__u_alq__DOT__iq_pc)[i],
          (unsigned)VERILOG_CPU(ieu__DOT__u_alq__DOT__iq_dest)[i],
          (unsigned)VERILOG_CPU(ieu__DOT__u_alq__DOT__iq_pr1)[i],
          (unsigned)VERILOG_CPU(ieu__DOT__u_alq__DOT__iq_pr2)[i]);
  }
#if !defined(RAPT_SOC) && !defined(CONFIG_wrapBus)
  Log("stall AXI model: AR v/r=%u/%u addr=%08x; R busy=%u v/r=%u/%u "
      "id=%u delay=%u beats=%u timeout=%u",
      (unsigned)top->rootp->raptSoC->perip__DOT__arvalid,
      (unsigned)top->rootp->raptSoC->perip__DOT__out_arready,
      (unsigned)top->rootp->raptSoC->perip__DOT__araddr,
      (unsigned)top->rootp->raptSoC->perip__DOT__r_busy,
      (unsigned)top->rootp->raptSoC->perip__DOT__out_rvalid,
      (unsigned)top->rootp->raptSoC->perip__DOT__rready,
      (unsigned)top->rootp->raptSoC->perip__DOT__r_id_q,
      (unsigned)top->rootp->raptSoC->perip__DOT__r_delay_q,
      (unsigned)top->rootp->raptSoC->perip__DOT__r_beats_left,
      (unsigned)top->rootp->raptSoC->perip__DOT__r_timeout_cnt);
#endif
}

void cpu_exec_set_threshold(uint64_t cycle, uint64_t inst)
{
  // size_t(-1) sentinel from the CLI parser comes through as UINT64_MAX;
  // preserve it so the unset axis never triggers the start-of-dump condition.
  tfp_cycle = cycle;
  tfp_inst = inst;
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
  // Dump-gating semantics: -c/-i specify the START point of waveform capture.
  // Once either threshold is reached, dumping continues for the rest of the
  // run.  An unset threshold is sentinel'd to UINT64_MAX so it never fires on
  // its own; the surviving threshold drives the start trigger.
  if ((tfp) && ((pmu.active_cycle >= tfp_cycle) | (pmu.instr_cnt >= tfp_inst)))
  {
    tfp->dump(contextp->time());
  }
  contextp->timeInc(1);

  top->clock = (top->clock == 0) ? 1 : 0;
  top->eval();
  if ((tfp) && ((pmu.active_cycle >= tfp_cycle) | (pmu.instr_cnt >= tfp_inst)))
  {
    tfp->dump(contextp->time());
  }
  contextp->timeInc(1);
}

/* LightSSS hook: runs inside the throwaway snapshot child (a COW fork frozen
 * at the last progress point). Drains the pipeline so committed stores have
 * reached the host memory buffer, then writes a self-consistent checkpoint.
 * The child diverging from the parent here is harmless -- it exits afterward. */
void cpu_exec_lightsss_snapshot(const char *dir)
{
  /* Never dump waveform from the child: it would corrupt the parent's FST. */
  tfp = NULL;
  /* Drain until ROB/SQ/STQ are empty (bounded so we never hang). Difftest is
   * intentionally not stepped during the drain -- we only advance the RTL. */
  for (int i = 0; i < 200000; i++)
  {
    bool rob_q = (npc.rob_empty != NULL) ? (*npc.rob_empty != 0) : true;
    bool sq_q = (npc.sq_empty != NULL) ? (*npc.sq_empty != 0) : true;
    if (rob_q && sq_q)
      break;
    cpu_exec_one_cycle();
  }
  checkpoint_emergency_save(dir);
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

void cpu_exec_init()
{
#if defined(CONFIG_ITRACE)
  for (int i = 0; i < MAX_IRING_SIZE; i++)
  {
    iringbuf_rpc[i] = 0;
  }
#endif
  memset(&pmu, 0, sizeof(pmu));
  perf_reset_sampler_state();
  flow_check_init();
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
  // Progress/LightSSS-fork interval. Defaults to 40M cycles; overridable via
  // NSIM_PROGRESS_CYCLES (mainly to validate LightSSS without billion-cycle
  // workloads).
  uint64_t progress_interval = 40000000;
  {
    const char *iv = getenv("NSIM_PROGRESS_CYCLES");
    if (iv != NULL)
    {
      uint64_t v = strtoull(iv, NULL, 0);
      if (v != 0)
        progress_interval = v;
    }
  }
  while (!contextp->gotFinish() && npc.state == NPC_RUNNING && n-- > 0)
  {
    cpu_exec_one_cycle();
    // Sample the cycle and every committed slot before handling an ebreak or
    // another simulator-side stop.  The old special case counted only one CSR
    // instruction and dropped both the final cycle and slot A when ebreak was
    // in slot B of a dual commit.
    perf_sample_per_cycle();
    uint8_t cmu_valid = *(uint8_t *)&VERILOG_CPU(cmu__DOT__valid);
    uint8_t cmu_valid_b = *(uint8_t *)&VERILOG_CPU(cmu__DOT__valid_b);
    if (cmu_valid)
    {
      const uint32_t pmu_inst_a = *(uint32_t *)&VERILOG_CPU(cmu__DOT__pmu_inst_a);
      const uint32_t pmu_inst_b = *(uint32_t *)&VERILOG_CPU(cmu__DOT__pmu_inst_b);
      perf_sample_per_inst(pmu_inst_a);
      if (cmu_valid_b)
        perf_sample_per_inst(pmu_inst_b);
      cur_inst_cycle = 0;
    }
    else
    {
      cur_inst_cycle++;
    }
    if (npc.state == NPC_END) // ebreak has now been sampled like any other commit
      break;

    flow_check_redirect_gap();
    // Checkpoint save: trigger on configured cycle/instr/PC, then wait for
    // quiesce before dumping. If --ckpt-save-exit was passed, terminate cleanly.
    if (checkpoint_save_tick())
    {
      Log("checkpoint: --ckpt-save-exit set, ending simulation.");
      npc.state = NPC_QUIT;
      break;
    }
    progress_cycle++;
    if ((progress_cycle & 0x3ffu) == 0)
    {
        serial_tick();
    }
    if (progress_cycle % progress_interval == 0)
    {
        Log("progress: %016llu cycles, %016llu insts, pc=" FMT_WORD_NO_PREFIX
          ", uart_rx=%u, input=%s",
          (unsigned long long)progress_cycle, (unsigned long long)pmu.instr_cnt,
          (word_t)(*npc.pc), serial_rx_pending(), serial_input_source());
      // LightSSS: fork a COW snapshot at this rewind point. The previous
      // snapshot (window was clean) is reaped here.
      lightsss_fork_at_progress();
    }
    if (timeout_us && (progress_cycle % 800000 == 0))
    {
      uint64_t elapsed = get_time() - now;
      if (elapsed > timeout_us)
      {
        Log(FMT_RED("Wall-clock timeout (%llds) exceeded at pc: " FMT_WORD_NO_PREFIX ", %llu cycles, %llu insts."),
            max_timeout, (word_t)(*npc.pc),
            (unsigned long long)progress_cycle, (unsigned long long)pmu.instr_cnt);
        npc.state = NPC_ABORT;
        lightsss_trigger_save();
        break;
      }
    }
    if (cur_inst_cycle > 0x4ffff)
    {
      Log(FMT_RED("Too many cycles (0x%llx) stalled at pc: " FMT_WORD_NO_PREFIX ", rpc: " FMT_WORD_NO_PREFIX ", inst: %08x."),
          (long long int)cur_inst_cycle, (word_t)(*npc.pc), (word_t)(*npc.rpc), (uint32_t)(*(npc.inst)));
      dump_pipeline_stall_state();
      npc.state = NPC_ABORT;
      // A no-commit hang is just as valuable to rewind as a register
      // divergence.  Preserve the most recent LightSSS progress snapshot so
      // the failing window can be replayed with waveform tracing.
      lightsss_trigger_save();
      break;
    }
    if (cmu_valid)
    {
      word_t cmu_rpc_a = *(word_t *)&VERILOG_CPU(cmu__DOT__rpc_a);
      word_t cmu_rpc_b = *(word_t *)&VERILOG_CPU(cmu__DOT__rpc_b);
      word_t cmu_npc_a = *(word_t *)&VERILOG_CPU(cmu__DOT__npc_a);
      word_t cmu_npc_b = *(word_t *)&VERILOG_CPU(cmu__DOT__npc_b);
      word_t flow_next_a = cmu_valid_b ? cmu_rpc_b : cmu_npc_a;
      /* Checkpoint load/PC trigger hooks use registered per-slot commit PCs
       * so dual-commit slot 0 is visible to the simulator. */
      bool checkpoint_resumed = checkpoint_load_post_trampoline_tick(cmu_rpc_a);
      checkpoint_note_commit(cmu_rpc_a);
      flow_check_commit(cmu_rpc_a, flow_next_a, 'A');
      if (npc.state != NPC_RUNNING)
        break;
      if (cmu_valid_b)
      {
        checkpoint_resumed |= checkpoint_load_post_trampoline_tick(cmu_rpc_b);
        checkpoint_note_commit(cmu_rpc_b);
        flow_check_commit(cmu_rpc_b, cmu_npc_b, 'B');
        if (npc.state != NPC_RUNNING)
          break;
      }
      flow_check_async_redirect_after_sample();
#ifdef CONFIG_ITRACE
      iringbuf_rpc[iringhead] = *npc.rpc;
      iringbuf_inst[iringhead] = *(word_t *)(npc.inst);
      iringhead = (iringhead + 1) % MAX_IRING_SIZE;
#endif

#ifdef CONFIG_DIFFTEST
      // When `-d <ref.so>` was not provided, init_difftest() left REF
      // function pointers NULL. Skip all REF interactions in that case so the
      // simulator can still run pk-based / coverage workloads against REFs
      // that don't model paging or delegation identically.
      if (!difftest_is_enabled())
      {
        // Still need to clear any pending memdiff bookkeeping below.
        goto skip_difftest_block;
      }
      if (checkpoint_resumed)
      {
        difftest_checkpoint_resync();
        goto skip_difftest_block;
      }
      if (checkpoint_load_pending())
      {
        goto skip_difftest_block;
      }
      // Mirror the DUT's effective hardware-owned mip bits into REF before
      // stepping, so CSR reads stay consistent across DUT/REF.
      {
        extern void (*ref_difftest_set_meip)(uint8_t);
        extern void (*ref_difftest_set_msip)(uint8_t);
        extern void (*ref_difftest_set_mtip)(uint8_t);
        // NEMU's shared-library configuration has no self-driven CLINT.
        // Keep its hardware-owned pending bits aligned with mip_eff.  This is
        // also needed on the commit immediately after a CLINT write: the RTL
        // device register changes at the clock edge, after the MMIO operation
        // itself was marked as a skipped reference access.
        if (npc.mip____ != NULL)
        {
          word_t dut_mip = *npc.mip____;
          if (ref_difftest_set_msip)
            ref_difftest_set_msip((dut_mip >> 3) & 1u);
          if (ref_difftest_set_mtip)
            ref_difftest_set_mtip((dut_mip >> 7) & 1u);
          if (ref_difftest_set_meip)
            ref_difftest_set_meip((dut_mip >> 11) & 1u);
        }
        // Mirror the DUT's Sstc-driven supervisor timer pending bit (sip.STIP,
        // bit 5) into REF's mip when Sstc is enabled (menvcfg.STCE=1). In that
        // mode STIP is hardware-controlled in the DUT from the stimecmp
        // comparator (read-only to software), but the REF build defines
        // CONFIG_TARGET_SHARE so its CLINT never self-drives STIP -- it would
        // otherwise stay 0 and diverge from the DUT during the pending window
        // before the interrupt is taken (e.g. while sstatus.SIE=0 in early
        // boot). With STCE=0, STIP is software-managed and replayed normally,
        // so we leave it to the regular CSR comparison.
        {
          extern void (*ref_difftest_set_stip)(uint8_t);
          if (ref_difftest_set_stip && npc.menvcfg != NULL &&
              (((uint64_t)*npc.menvcfg >> 63) & 1u))
          {
            uint8_t dut_stip = (*npc.sip____ >> 5) & 1u;
            ref_difftest_set_stip(dut_stip);
          }
        }
        // Mirror rising edges of the cluster-level external IRQ line into
        // NEMU's PLIC source 1 so both PLICs see identical source events.
        // (DUT routes the cluster `io_interrupt` port into PLIC source 1
        //  internally; we mirror the same edge here.)
        extern void (*ref_difftest_plic_raise)(uint32_t);
        static uint8_t s_prev_ext_irq = 0;
#ifdef VERILOG_CLUSTER
        uint8_t cur_ext_irq = *(uint8_t *)&VERILOG_CLUSTER(io_interrupt);
#else
        uint8_t cur_ext_irq = *(uint8_t *)&VERILOG_CPU(io_interrupt);
#endif
        if (ref_difftest_plic_raise && cur_ext_irq && !s_prev_ext_irq)
          ref_difftest_plic_raise(1u);
        s_prev_ext_irq = cur_ext_irq;
      }
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
      // Asynchronous CLINT interrupts: when recieved_trap and cmu.valid both
      // fire on the same cycle, the committing instruction triggered the trap.
      // REF must first step for that instruction, then take the interrupt so
      // that sepc correctly points at the following PC (= stvec target on next
      // commit). Order: difftest_step() -> difftest_raise_intr().
      difftest_step(*npc.rpc);
      {
        uint8_t cur_recieved_trap = *(uint8_t *)&VERILOG_ROU(recieved_trap);
        if (cur_recieved_trap)
        {
          // Use the registered trap_cause from RTL: it carries the proper
          // interrupt cause (MSI/MTI for M-mode CLINT, or SSI/STI/SEI for
          // S-mode delegated interrupts). Forwarding it directly avoids the
          // ambiguity of reconstructing cause from priv (priv==S does NOT
          // imply S-level cause when mideleg leaves the bit at M-level).
          word_t cause = *(word_t *)&VERILOG_ROU(trap_cause);
          difftest_raise_intr(cause);
        }
      }
    skip_difftest_block:;
#endif
      npc.last_inst = *(npc.inst);
    }
#ifdef CONFIG_DIFFTEST
    // An interrupt captured while the ROB is empty has no commit pulse on
    // which to synchronize REF. Inject it directly before the first handler
    // instruction commits; commit-associated interrupts are handled above.
    if (!cmu_valid && difftest_is_enabled() &&
        *(uint8_t *)&VERILOG_ROU(recieved_trap))
    {
      word_t cause = *(word_t *)&VERILOG_ROU(trap_cause);
      difftest_raise_intr(cause);
    }
#endif
    if (checkpoint_save_tick())
    {
      Log("checkpoint: --ckpt-save-exit set, ending simulation.");
      npc.state = NPC_QUIT;
      break;
    }
    // LightSSS: a difftest divergence sets NPC_ABORT here without `break`ing
    // (unlike timeout/stall aborts, which break earlier). Wake the snapshot
    // child to dump a checkpoint a window behind the failure before unwinding.
    if (npc.state == NPC_ABORT)
    {
      lightsss_trigger_save();
    }
    // -c/-i thresholds only START waveform dumping; they no longer halt the
    // simulator.  Use -m / --maximum to bound execution length explicitly.
  }
  g_timer += get_time() - now;

  switch (npc.state)
  {
  case NPC_RUNNING:
    npc.state = NPC_STOP;
    break;
  case NPC_END:
    if (!npc.host_exit_ok && *npc.ret != 0)
    {
      Log("a0 = " FMT_RED(FMT_WORD), *npc.ret);
    }
  case NPC_ABORT:
    if (npc.state == NPC_ABORT || (!npc.host_exit_ok && *npc.ret != 0))
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
  // Reap any lingering LightSSS snapshot child once cpu_exec returns.
  lightsss_finish();
}
