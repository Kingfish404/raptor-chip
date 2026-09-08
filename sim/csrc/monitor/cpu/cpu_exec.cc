#include <common.h>
#include <checkpoint.h>
#include <difftest.h>
#include <flow_check.h>
#include <lightsss.h>
#include <readline/readline.h>
#include <readline/history.h>
#include <npc_verilog.h>
#include <npc_eval.h>
#include "verilated_fst_c.h"

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

extern long long int max_timeout;

bool cpu_read_sq_snapshot_control(uint32_t *valid, uint32_t *committed,
                                  uint8_t *capacity, uint8_t *head)
{
  *valid = uint32_t(VERILOG_CPU(lsu__DOT__u_sq__DOT__sq_valid));
  *committed = uint32_t(VERILOG_CPU(lsu__DOT__u_sq__DOT__sq_committed));
  *capacity = uint8_t(VERILOG_CPU(lsu__DOT__u_sq__DOT__sq_paddr).size());
  *head = uint8_t(VERILOG_CPU(lsu__DOT__u_sq__DOT__sq_head));
  if (*capacity == 0 || *capacity > 32)
    return false;
  for (uint8_t entry = 0; entry < *capacity; ++entry)
  {
    if ((*valid & (1u << entry)) == 0)
      continue;
    uint8_t alu = VERILOG_CPU(lsu__DOT__u_sq__DOT__sq_alu)[entry];
    unsigned size = alu == 0x01 ? 1 : alu == 0x03 ? 2 :
                    alu == 0x0f ? 4 : alu == 0x1f ? 8 : 0;
    // The overlay holds one native word at a contiguous physical address.
    // Let RTL finish FP64/split/CBO stores, including separately translated
    // high beats, instead of inventing their remaining data or addresses.
    if (size == 0 || size > sizeof(word_t)
        || VERILOG_CPU(lsu__DOT__u_sq__DOT__sq_fp64)[entry]
        || (VERILOG_CPU(lsu__DOT__u_sq__DOT__sq_paddr)[entry] & (size - 1)))
      return false;
  }
  return true;
}

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
      "UOQ valid=%02x head=%u tail=%u",
      (unsigned)VERILOG_ROU(rob_head), (unsigned)VERILOG_ROU(rob_tail),
      (unsigned long long)VERILOG_ROU(rob_entry_busy),
      (unsigned)VERILOG_ROU(head0_valid),
      (unsigned)VERILOG_ROU(uoq_valid),
      (unsigned)VERILOG_ROU(uoq_head), (unsigned)VERILOG_ROU(uoq_tail));
  Log("stall state: IFU buffered=%u L1I=%u IPTW=%u; L1D=%u DPTW=%u; "
      "AXI rd_out=%u req=%u resp=%u; bus l1d_busy=%u issued=%u "
      "mmio=%u skid=%u source=%u",
      (unsigned)VERILOG_CPU(ifu__DOT__held_count),
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

  top->clock = (top->clock == 0) ? 1 : 0;
  npc_eval(top);
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
  npc_eval(top);
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
  perf_reset_counters();
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
    // in any position of a multi-instruction commit.
    perf_sample_per_cycle();
    uint8_t cmu_valid = *(uint8_t *)&VERILOG_CPU(cmu__DOT__valid);
    uint32_t cmu_retire_count = VERILOG_CPU(cmu__DOT__retire_count);
    if (cmu_valid)
    {
      for (uint32_t slot = 0; slot < cmu_retire_count; ++slot)
        perf_sample_per_inst(VERILOG_CPU(cmu__DOT__inst_slots)[slot]);
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
      bool checkpoint_resumed = false;
      for (uint32_t slot = 0; slot < cmu_retire_count; ++slot)
      {
        word_t slot_pc = VERILOG_CPU(cmu__DOT__rpc_slots)[slot];
        word_t slot_next = VERILOG_CPU(cmu__DOT__npc_slots)[slot];
        checkpoint_resumed |= checkpoint_load_post_trampoline_tick(slot_pc);
        checkpoint_note_commit(slot_pc);
        flow_check_commit(slot_pc, slot_next, char('0' + slot));
        if (npc.state != NPC_RUNNING) break;
      }
      if (npc.state != NPC_RUNNING) break;
      flow_check_async_redirect_after_sample();
#ifdef CONFIG_ITRACE
      for (uint32_t slot = 0; slot < cmu_retire_count; ++slot)
      {
        iringbuf_rpc[iringhead] = VERILOG_CPU(cmu__DOT__rpc_slots)[slot];
        iringbuf_inst[iringhead] = VERILOG_CPU(cmu__DOT__inst_slots)[slot];
        iringhead = (iringhead + 1) % MAX_IRING_SIZE;
      }
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
          extern void (*ref_difftest_set_seip)(uint8_t);
          // Preserve the distinction between the controller level E and the
          // software SEIP bit B. CSRRS/CSRRC read B|E but only update B.
          // Observe the driving PLIC flop for hart 0. Verilator can retain an
          // unused public core input shadow without updating it after reset.
          if (ref_difftest_set_seip)
            ref_difftest_set_seip(VERILOG_PLIC(seip_q) & 1u);
#ifdef CONFIG_ISA64
          bool stce = npc.menvcfg != NULL && (((uint64_t)*npc.menvcfg >> 63) & 1u);
#else
          bool stce = (VERILOG_CPU(csrs__DOT__csr)[MENVCFGH] >> 31) & 1u;
#endif
          if (ref_difftest_set_stip && stce)
          {
            uint8_t dut_stip = (*npc.mip____ >> 5) & 1u;
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
      // Intermediate retirements advance REF; compare the final group state.
      // Skip/CSR/trap instructions retire alone by the ROB's explicit policy.
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
      difftest_step(*npc.rpc, cmu_retire_count);
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
    // Apply external write failures after this cycle's retired CSR writes:
    // a same-cycle hardware event wins a W1C acknowledgement.
    difftest_apply_store_error();
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
