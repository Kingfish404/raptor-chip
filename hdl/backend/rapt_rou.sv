`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

// Re-Order Unit (ROU) - dispatch queue + reorder buffer + commit.
//
// Sub-sections:
//   1. Dispatch Queue (UOQ)   - buffers renamed uops before ROB allocation
//   2. ROB Dispatch Buffer    - independently steers allocated owners to domains
//   3. Reorder Buffer (ROB)   - tracks in-flight instructions for in-order commit
//   4. Operand Bypass         - forwards results while work awaits a domain
//   5. Commit Logic           - retires ROB head when ready
//
// Rename input, dispatch allocation and retirement widths are independent.
module rapt_rou #(
    parameter rapt_pkg::core_config_t Cfg = rapt_pkg::CoreConfig,
    parameter type SlotT = rapt_pkg::dispatch_slot_t,
    parameter int unsigned NumSlots = Cfg.dispatch_width,
    parameter int unsigned ScanEntries = Cfg.steer_scan_entries,
    parameter int unsigned RenameWidth = Cfg.rename_width,
    parameter int unsigned CommitWidth = Cfg.commit_width,
    parameter type UopT = rapt_pkg::uop_t,
    parameter int unsigned NumCompletions = Cfg.completion_ports,
    parameter int unsigned NumDependencies = Cfg.completion_dependencies,
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter unsigned IIQ_SIZE = Cfg.dispatch_entries,
    parameter unsigned ROB_SIZE = Cfg.rob_entries,
    parameter unsigned OperandSpillEntries = Cfg.operand_spill_entries,
    /* verilator lint_off UNUSEDPARAM */
    parameter unsigned RNUM = Cfg.arch_regs,
    parameter unsigned RLEN = rapt_pkg::index_bits(Cfg.arch_regs),
    /* verilator lint_on UNUSEDPARAM */
    parameter unsigned PLEN = rapt_pkg::index_bits(Cfg.phys_regs),
    parameter unsigned GenerationBits = Cfg.rob_generation_bits,
    parameter unsigned CheckpointEntries = Cfg.branch_checkpoints,
    parameter unsigned CheckpointBits = rapt_pkg::index_bits(CheckpointEntries),
    parameter unsigned XLEN = Cfg.xlen,
    // The integrated core supplies the accepted completion fabric. Standalone
    // hostile-input harnesses may enable the local guard without making the
    // production datapath pay for the same ROB lookup twice.
    parameter bit ValidateCompletionInputs = 1'b0
) (
    input CompletionT completion[NumCompletions],
    rob_completion_owner_if.owner completion_owner,
    input clock,
    input logic writeback_idle = 1'b1,
    output logic writeback_drain,

    rnu_rou_if.slave rnu_rou,
    rapt_recovery_if.source recovery,
    checkpoint_release_if.source checkpoint_release,

    exu_prf_if.master exu_prf,
    output SlotT dispatch[NumSlots],
    output rapt_pkg::execution_domain_t candidate_domain[ScanEntries],
    output logic candidate_valid[ScanEntries],
    input logic candidate_ready[ScanEntries],
    input logic selected_valid[NumSlots],
    input logic [rapt_pkg::index_bits(ScanEntries)-1:0] selected_candidate[NumSlots],

    // interrupt
    csr_bcast_if.in csr_bcast,
    // Async trap inputs: timer, software, external, and S-mode delegated
    input clint_timer_trap,
    input clint_sw_trap,
    input clint_ext_trap,

    // S-mode delegated interrupt (level): cause is supplied by csr.
    input                  s_int_pending,
    input [`RAPT_XLEN-1:0] s_int_cause,

    // commit
    rou_cmu_if.out rou_cmu,
    rou_csr_if.out rou_csr,
    rou_lsu_if.out rou_lsu,

    // RISC-V Debug: external halt request from the cluster Debug Module.
    // When asserted (level), block UOQ->ROB dispatch so the in-flight ROB
    // drains naturally; once `rob_empty` we report `halted_o` to the DM.
    // Resume happens automatically when `dm_haltreq_i` is deasserted.
    input  logic            dm_haltreq_i,
    output logic            halted_o,
    // Next architectural PC at the halt boundary (= npc of the youngest
    // committed instruction, or PC_RESET on cold halt). The DM samples
    // this on the halted_o rising edge and uses it as dpc.
    output logic [XLEN-1:0] halt_pc_o,
    // Single-cycle pulse: at least one ROB entry retired this cycle
    // (commit fire). Used by the DM to count instructions while
    // dcsr.step=1 so single-step requests halt after exactly one retire.
    output logic            commit_fire_o,

    // A2: PMU: one-cycle pulse when ROB becomes full
    /* verilator lint_off UNUSEDSIGNAL */
    output logic pmu_rob_full,
    /* verilator lint_on UNUSEDSIGNAL */

    input reset
);

  localparam int RBits = rapt_pkg::index_bits(ROB_SIZE);
  localparam int QBits = rapt_pkg::index_bits(IIQ_SIZE);
  localparam int SlotBits = rapt_pkg::index_bits(NumSlots);
  localparam int SpillBits = rapt_pkg::index_bits(OperandSpillEntries);
  localparam int NumDomains = Cfg.execution_domains;
  localparam int RetireBits = rapt_pkg::index_bits(rapt_pkg::CommitWidth + 1);
  logic [RBits-1:0] rob_head, rob_tail, h0;
  logic [RBits-1:0] rob_alloc[NumSlots], dispatch_index[ScanEntries], commit_index[CommitWidth];
  logic dispatch_from_allocation[ScanEntries];
  logic [SlotBits-1:0] dispatch_source_slot[ScanEntries];
  rapt_pkg::rob_entry_t rob_entry[ROB_SIZE];
  // Project narrow, dynamically indexed state out of the packed ROB record
  // before selecting it.  Some FPGA synthesis flows otherwise build a mux
  // for the entire rob_entry_t and discard every bit except `trap` afterward.
  logic [ROB_SIZE-1:0] rob_trap;
  for (genvar entry = 0; entry < ROB_SIZE; entry++) begin : g_rob_trap_view
    assign rob_trap[entry] = rob_entry[entry].trap;
  end
`ifdef RAPT_RVFI
  // Optional per-owner trace, separate from functional retirement metadata.
  logic [XLEN-1:0] rvfi_mem_addr[ROB_SIZE], rvfi_mem_data[ROB_SIZE];
`endif
  // The complete uop lives only while its owner waits for execution dispatch
  // in the 16-entry spill. ROB retirement needs a much narrower, immutable
  // summary; storing the full execution payload in every ROB slot duplicates
  // the spill and makes the dispatch read a 32:1 wide mux.
  typedef struct packed {rapt_pkg::execution_domain_t domain;} retire_schedule_t;
  typedef struct packed {logic [5:0] alu;} retire_int_t;
  typedef struct packed {
    logic conditional;
    logic jump;
    logic indirect;
  } retire_branch_t;
  typedef struct packed {logic [5:0] op;} retire_fp_t;
  typedef struct packed {
    logic valid;
    logic ecall;
    logic ebreak;
    logic fence_i;
    logic fence;
    logic mret;
    logic sret;
  } retire_sys_t;
  typedef struct packed {
    retire_int_t int_op;
    retire_branch_t branch;
    retire_fp_t fp;
    retire_sys_t sys;
  } retire_execute_t;
  typedef struct packed {
    retire_schedule_t schedule;
    retire_execute_t execute;
    logic c;
    logic [11:0] imm;
    logic [31:0] inst;
`ifdef RAPT_RVFI
    logic [31:0] rvfi_inst;
`endif
    logic [XLEN-1:0] pc;
  } retire_uop_t;
  retire_uop_t uop_pl[ROB_SIZE];
  logic [QBits-1:0] uoq_head, uoq_tail, enq_index[RenameWidth], deq_index[NumSlots];
  logic [IIQ_SIZE-1:0] uoq_valid, uoq_pv1_valid, uoq_pv2_valid;
  UopT uoq_uops[IIQ_SIZE];
  logic [PLEN-1:0] uoq_pr1[IIQ_SIZE], uoq_pr2[IIQ_SIZE], uoq_prd[IIQ_SIZE], uoq_prs[IIQ_SIZE];
  logic uoq_checkpoint_valid[IIQ_SIZE];
  logic [CheckpointBits-1:0] uoq_checkpoint[IIQ_SIZE];
  // One value slot per source: rename supplies a zero-tag value, otherwise
  // the PRF/CDB snapshot owns it until a matching writeback wakes the source.
  logic [XLEN-1:0] uoq_op1[IIQ_SIZE], uoq_op2[IIQ_SIZE];
  logic
      enq_fire[RenameWidth],
      deq_fire[NumSlots],
      endpoint_fire[ScanEntries],
      commit_fire[CommitWidth];
  int unsigned enqueue_count, dispatch_count, endpoint_count, commit_count;
  logic admission_present[NumSlots], admission_rob_available[NumSlots], admission_serial[NumSlots];
  logic admission_eligible[NumSlots], allocation_endpoint_ready[NumSlots];
  rapt_pkg::dispatch_stop_t dispatch_stop, pmu_dispatch_reason;
  logic [31:0] pmu_dispatch_count, pmu_dispatch_stop_domain;
  logic [31:0] pmu_steer_candidates, pmu_steer_accepted, pmu_steer_bypass;
  logic [31:0] pmu_steer_pending, pmu_steer_blocked_domain;
  logic [31:0] steer_pending_domain[NumDomains];
  logic [31:0] pmu_steer_pending_domain[NumDomains] /* verilator public_flat_rd */;
  logic pmu_steer_oldest_blocked;
  int unsigned steer_candidate_count, steer_bypass_count;
  logic steer_oldest_blocked;
  logic serialize_in_flight, head0_valid, head0_flush;
  logic rob_empty  /* verilator public_flat_rd */;
  logic flush_pipe, flush_apply, recieved_trap;
  logic recieved_sw_trap /* verilator public */;
  logic [XLEN-1:0] trap_cause /* verilator public */;
  logic [XLEN-1:0] trap_pc, commit_npc_q, flush_target_r;
  // CSR/FP operations enter only an empty ROB and block younger allocation.
  // Thus at most one CSR write payload can be live; keep it once, not per ROB
  // entry. The per-entry csr_wen bit still owns commit and trap cancellation.
  logic [XLEN-1:0] csr_wdata_q;
  // Like BOOM's oldest-exception record, only the earliest live synchronous
  // trap can reach architectural commit. A trap bit remains in each entry;
  // its full-width cause has one owner-selected copy instead of ROB_SIZE copies.
  logic oldest_exception_valid, exception_next_valid;
  logic [RBits-1:0] oldest_exception_owner, exception_next_owner;
  logic [XLEN-1:0] oldest_exception_cause, exception_next_cause;
  logic [XLEN-1:0] oldest_exception_tval, exception_next_tval;
  // CBO is serializing and therefore has one live owner. Only its cache-line
  // offset is needed at retirement; it must not keep a full tval per ROB slot.
  logic [5:0] cbo_block_q;
  logic head_cbo, head_cbo_inval;
`ifndef SYNTHESIS
  // Diagnostic-only copy for the SQ commit-address contract. The SQ owns the
  // functional address; this witness is not needed in synthesized hardware.
  logic [XLEN-1:0] store_addr_witness[ROB_SIZE];
`endif
  logic async_trap_pending;
  logic [XLEN-1:0] async_trap_cause;
  logic [ROB_SIZE-1:0] rob_entry_busy;
  logic [ROB_SIZE-1:0] rob_entry_executing;
  logic rob_control_flow[ROB_SIZE];
  // Compact retirement controls are decoded once at allocation, before the
  // wide ROB uop read and the commit-prefix chain.
  logic rob_serializing[ROB_SIZE];
  logic rob_drains_sq[ROB_SIZE];
  logic rob_atomic[ROB_SIZE];
  logic rob_fp_valid[ROB_SIZE];
  logic [ROB_SIZE-1:0] rob_dispatch_pending, rob_dispatch_eligible;
  logic [SpillBits-1:0] rob_dp_spill[ROB_SIZE];
  logic [GenerationBits-1:0] rob_next_generation[ROB_SIZE];
  logic [GenerationBits-1:0] rob_owner_generation[ROB_SIZE];
  logic rob_checkpoint_valid[ROB_SIZE];
  logic [CheckpointBits-1:0] rob_checkpoint[ROB_SIZE];
  // A checkpoint is live only until its control-flow instruction resolves.
  // Keep predicted targets in this small shared file instead of the UOQ and
  // execution-domain queues. The ROB entry carries only the checkpoint ID.
  logic [XLEN-1:0] predicted_npc[CheckpointEntries];
  logic predicted_taken[CheckpointEntries];
  logic completion_mispredict[NumCompletions];
  logic [PLEN-1:0] rob_owner_prd[ROB_SIZE];
  logic [RLEN-1:0] rob_owner_rd[ROB_SIZE];
  logic completion_valid[NumCompletions];
  logic completion_identity_match[NumCompletions];
  logic completion_payload_match[NumCompletions];
  logic rob_full_r;
  logic recovery_pending;
  logic [RBits-1:0] recovery_owner;
  logic [XLEN-1:0] recovery_target;
  logic [GenerationBits-1:0] recovery_generation;
  logic recovery_owner_current;
  logic recovery_announced;
  logic [RBits-1:0] recovery_announced_owner;
  logic [XLEN-1:0] recovery_announced_target;
  logic [GenerationBits-1:0] recovery_announced_generation;
  logic recovery_candidate_valid[NumCompletions];
  logic [RBits-1:0] recovery_candidate_index[NumCompletions];
  logic [XLEN-1:0] recovery_candidate_target[NumCompletions];
  logic pmu_enqueue_ready;
  assign pmu_enqueue_ready = rnu_rou.ready[0];
  logic [RBits-1:0] youngest_commit, store_commit, branch_commit;
  logic store_commit_valid, branch_commit_valid;
  localparam int NWB = NumCompletions;
  logic wb_valid_v[NWB];
  logic [PLEN-1:0] wb_prd_v[NWB];
  logic [XLEN-1:0] wb_res_v[NWB];
  logic spill_allocate_valid[NumSlots], spill_allocate_ready[NumSlots];
  logic [XLEN-1:0] spill_allocate_op1[NumSlots], spill_allocate_op2[NumSlots];
  logic [PLEN-1:0] spill_allocate_pr1[NumSlots], spill_allocate_pr2[NumSlots];
  UopT spill_allocate_uop[NumSlots], spill_read_uop[NumSlots];
  logic [SpillBits-1:0] spill_allocate_index[NumSlots];
  logic spill_release_valid[NumSlots];
  logic [SpillBits-1:0] spill_release_index[NumSlots];
  logic [SpillBits-1:0] spill_read_index[NumSlots];
  logic spill_read_valid[NumSlots];
  logic [XLEN-1:0] spill_read_op1[NumSlots], spill_read_op2[NumSlots];
  logic [PLEN-1:0] spill_read_pr1[NumSlots], spill_read_pr2[NumSlots];
  for (genvar p = 0; p < NWB; p++) begin : g_wb_capture
    assign wb_valid_v[p] = completion_valid[p] && completion[p].rd != 0;
    assign wb_prd_v[p] = completion[p].prd;
    assign wb_res_v[p] = completion[p].result;
  end
  rapt_operand_value_spill #(
      .Xlen(XLEN),
      .UopT(UopT),
      .PhysBits(PLEN),
      .SpillEntries(OperandSpillEntries),
      .AllocateWidth(NumSlots),
      .ReleaseWidth(NumSlots),
      .ReadPorts(NumSlots),
      .CompletionPorts(NWB),
      .SpillBits(SpillBits)
  ) operand_values (
      .clock,
      .reset,
      .flush(flush_pipe),
      .allocate_valid(spill_allocate_valid),
      .allocate_uop(spill_allocate_uop),
      .allocate_op1(spill_allocate_op1),
      .allocate_op2(spill_allocate_op2),
      .allocate_pr1(spill_allocate_pr1),
      .allocate_pr2(spill_allocate_pr2),
      .allocate_ready(spill_allocate_ready),
      .allocate_index(spill_allocate_index),
      .release_valid(spill_release_valid),
      .release_index(spill_release_index),
      .read_index(spill_read_index),
      .read_valid(spill_read_valid),
      .read_uop(spill_read_uop),
      .read_op1(spill_read_op1),
      .read_op2(spill_read_op2),
      .read_pr1(spill_read_pr1),
      .read_pr2(spill_read_pr2),
      .completion_valid(wb_valid_v),
      .completion_prd(wb_prd_v),
      .completion_result(wb_res_v)
  );
  assign h0 = rob_head;
  assign rob_empty = !(|rob_entry_busy);
  // UOQ entries can already contain PRF operand snapshots when admission
  // stops. Discard all speculative state at the drained boundary before a
  // debugger may modify architectural registers; resume refetches that PC.
  logic debug_halt_flushed, debug_halt_flush;
  assign debug_halt_flush = dm_haltreq_i && rob_empty && !head0_valid && !debug_halt_flushed;
  always_ff @(posedge clock) begin
    if (reset || !dm_haltreq_i) debug_halt_flushed <= 1'b0;
    else if (debug_halt_flush) debug_halt_flushed <= 1'b1;
  end
  assign halted_o = dm_haltreq_i && rob_empty && debug_halt_flushed;
  assign halt_pc_o = commit_npc_q;
  assign commit_fire_o = commit_count != 0;
  assign async_trap_pending = csr_bcast.bus_error_int || clint_sw_trap || clint_timer_trap
      || clint_ext_trap || s_int_pending;
  assign async_trap_cause = csr_bcast.bus_error_int
      ? XLEN'(`RAPT_BUS_ERROR_IRQ) | (XLEN'(1) << (XLEN-1))
      : clint_ext_trap
      ? XLEN'(`RAPT_CAUSE_MEI) | (XLEN'(1) << (XLEN-1))
      : clint_sw_trap ? XLEN'(`RAPT_CAUSE_MSI) | (XLEN'(1) << (XLEN-1))
      : clint_timer_trap ? XLEN'(`RAPT_CAUSE_MTI) | (XLEN'(1) << (XLEN-1)) : s_int_cause;
  function automatic logic serializing(input UopT u);
    return u.execute.sys.valid || u.execute.fp.valid || u.execute.sys.fence_i
        || u.execute.sys.fence;
  endfunction
  function automatic logic drains_sq_before_commit(input UopT u);
    // CBO.ZERO uses the serialization flag but owns a speculative SQ entry.
    // It must commit that entry before it can drain, just like other stores.
    // SQ order preserves older stores, and the resident blocks load forwarding
    // until the complete zero block has drained. Fences/CBOM own no SQ entry.
    return !u.execute.memory.store && (u.execute.sys.fence || u.execute.sys.fence_i
        || (u.execute.sys.valid && u.inst[6:0] == `RAPT_OP_FENCE_));
  endfunction
  function automatic logic control_flow(input UopT u);
    return u.execute.branch.conditional || u.execute.branch.jump || u.execute.branch.indirect;
  endfunction
  function automatic retire_uop_t compact_retire_uop(input UopT u);
    retire_uop_t result;
    result = '0;
    result.schedule.domain = u.schedule.domain;
    result.execute.int_op.alu = u.execute.int_op.alu;
    result.execute.branch.conditional = u.execute.branch.conditional;
    result.execute.branch.jump = u.execute.branch.jump;
    result.execute.branch.indirect = u.execute.branch.indirect;
    result.execute.fp.op = u.execute.fp.op;
    result.execute.sys.valid = u.execute.sys.valid;
    result.execute.sys.ecall = u.execute.sys.ecall;
    result.execute.sys.ebreak = u.execute.sys.ebreak;
    result.execute.sys.fence_i = u.execute.sys.fence_i;
    result.execute.sys.fence = u.execute.sys.fence;
    result.execute.sys.mret = u.execute.sys.mret;
    result.execute.sys.sret = u.execute.sys.sret;
    result.c = u.c;
    result.imm = u.imm[11:0];
    result.inst = u.inst;
`ifdef RAPT_RVFI
    result.rvfi_inst = u.rvfi_inst;
`endif
    result.pc = u.pc;
    return result;
  endfunction
  function automatic UopT without_prediction(input UopT u);
    UopT result;
    result = u;
    result.pnpc = '0;
    result.execute.branch.predicted_taken = 1'b0;
    return result;
  endfunction
  function automatic logic older_rob_owner(input logic [RBits-1:0] lhs, rhs);
    // Configured ROB sizes are powers of two; retain the generic modulo case
    // for parameterized tests. Both compare circular distance from the head.
    if ((ROB_SIZE & (ROB_SIZE - 1)) == 0) return RBits'(lhs - rob_head) < RBits'(rhs - rob_head);
    else
      return (int'(lhs) + ROB_SIZE - int'(rob_head)) % ROB_SIZE
          < (int'(rhs) + ROB_SIZE - int'(rob_head)) % ROB_SIZE;
  endfunction
  function automatic logic commit_special(input int e);
    return rob_serializing[e] || rob_entry[e].trap || rob_entry[e].mispredict ||
        rob_atomic[e] || rob_entry[e].difftest_skip;
  endfunction
  if (!(NumSlots > 0 && ScanEntries >= NumSlots && RenameWidth > 0
      && CommitWidth > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_rou configuration");
  end
  if (!(ROB_SIZE >= ScanEntries && ROB_SIZE >= CommitWidth)) begin : g_invalid_config_1
    $error("Invalid rapt_rou configuration");
  end
  if (!(OperandSpillEntries >= NumSlots && OperandSpillEntries <= ROB_SIZE)) begin : g_invalid_spill
    $error("Invalid rapt_rou operand spill configuration");
  end
  if (!(IIQ_SIZE >= RenameWidth && IIQ_SIZE >= NumSlots)) begin : g_invalid_config_2
    $error("Invalid rapt_rou configuration");
  end
  if (!(rnu_rou.Width == RenameWidth && rou_cmu.Width == CommitWidth)) begin : g_invalid_config_3
    $error("Invalid rapt_rou configuration");
  end
  if (!(checkpoint_release.Ports == NumCompletions)) begin : g_invalid_config_4
    $error("Invalid rapt_rou configuration");
  end
  if (!(NumDependencies >= 3 && $bits(
          dispatch[0].dep_valid
      ) == NumDependencies)) begin : g_invalid_config_5
    $error("Invalid rapt_rou configuration");
  end
  if (!(CheckpointEntries > 0)) begin : g_invalid_config_6
    $error("Invalid rapt_rou configuration");
  end
  if (!(rnu_rou.CheckpointBits == CheckpointBits)) begin : g_invalid_config_7
    $error("Invalid rapt_rou configuration");
  end
  if (!(recovery.CheckpointBits == CheckpointBits)) begin : g_invalid_config_8
    $error("Invalid rapt_rou configuration");
  end
  for (genvar e = 0; e < ROB_SIZE; e++) begin : g_rob_owner_view
    assign rob_entry_busy[e] = rob_entry[e].state != rapt_pkg::ROB_CM;
    assign rob_entry_executing[e] = rob_entry[e].state == rapt_pkg::ROB_EX;
    assign rob_dispatch_pending[e] = rob_entry[e].state == rapt_pkg::ROB_DP;
    assign rob_owner_generation[e] = rob_entry[e].generation;
    assign rob_owner_prd[e] = rob_entry[e].prd;
    assign rob_owner_rd[e] = rob_entry[e].rd;
    assign completion_owner.generation[e] = rob_entry[e].generation;
    assign completion_owner.prd[e] = rob_entry[e].prd;
    assign completion_owner.rd[e] = rob_entry[e].rd;
  end
  rapt_rob_age_mask #(
      .Entries(ROB_SIZE),
      .IndexBits(RBits)
  ) recovery_dispatch_mask (
      .pending(rob_dispatch_pending),
      .fence(Cfg.recovery_dispatch_fence && recovery_pending),
      .head(rob_head),
      .owner(recovery_owner),
      .eligible(rob_dispatch_eligible)
  );
  assign completion_owner.live = rob_entry_busy;
  assign completion_owner.executing = rob_entry_executing;

  logic [RBits-1:0] completion_index[NumCompletions];
  logic final_candidate_valid[NumCompletions];
  logic [GenerationBits-1:0] completion_generation[NumCompletions];
  logic [PLEN-1:0] completion_prd[NumCompletions];
  logic [RLEN-1:0] completion_rd[NumCompletions];
  for (genvar p = 0; p < NumCompletions; p++) begin : g_completion_guard_view
    assign final_candidate_valid[p] = completion[p].valid;
    assign completion_index[p] = completion[p].dest;
    assign completion_generation[p] = completion[p].generation;
    assign completion_prd[p] = completion[p].prd;
    assign completion_rd[p] = completion[p].rd;
  end
  if (ValidateCompletionInputs) begin : g_validate_completion_inputs
    for (genvar p = 0; p < NumCompletions; p++) begin : g_final_guard
      rapt_completion_guard #(
          .Entries(ROB_SIZE),
          .IndexBits(RBits),
          .GenerationBits(GenerationBits),
          .PhysBits(PLEN),
          .ArchBits(RLEN),
          .EnforcePayload(1'b1)
      ) guard (
          .candidate_valid(final_candidate_valid[p]),
          .candidate_index(completion_index[p]),
          .candidate_generation(completion_generation[p]),
          .candidate_prd(completion_prd[p]),
          .candidate_rd(completion_rd[p]),
          .live(rob_entry_busy),
          .executing(rob_entry_executing),
          .owner_generation(rob_owner_generation),
          .owner_prd(rob_owner_prd),
          .owner_rd(rob_owner_rd),
          .accept(completion_valid[p]),
          .identity_match(completion_identity_match[p]),
          .payload_match(completion_payload_match[p])
      );
    end
  end else begin : g_trusted_completion_inputs
    for (genvar p = 0; p < NumCompletions; p++) begin : g_accept
      assign completion_valid[p] = completion[p].valid;
      assign completion_identity_match[p] = completion[p].valid;
      assign completion_payload_match[p] = completion[p].valid;
      `RAPT_SVA_IMPLY(clock, reset, ROU_ACCEPTED_COMPLETION_INDEX, completion[p].valid,
                      int'(completion[p].dest) < ROB_SIZE)
      `RAPT_SVA_IMPLY(clock, reset, ROU_ACCEPTED_COMPLETION_OWNER,
                      completion[p].valid && int'(completion[p].dest) < ROB_SIZE,
                      rob_entry_busy[completion[p].dest]
          && rob_entry_executing[completion[p].dest]
          && rob_owner_generation[completion[p].dest] == completion[p].generation
          && rob_owner_prd[completion[p].dest] == completion[p].prd
          && rob_owner_rd[completion[p].dest] == completion[p].rd)
    end
  end
  for (genvar p = 0; p < NumCompletions; p++) begin : g_recovery_candidate
    always_comb begin
      recovery_candidate_valid[p] = 0;
      recovery_candidate_index[p] = completion[p].dest;
      recovery_candidate_target[p] = '0;
      if (completion_valid[p] && int'(completion[p].dest) < ROB_SIZE) begin
        recovery_candidate_valid[p] = completion[p].updates.control_flow
            && completion_mispredict[p] && !completion[p].trap
            && rob_entry_busy[completion[p].dest] && !rob_trap[completion[p].dest]
            && rob_control_flow[completion[p].dest];
        if (recovery_candidate_valid[p]) recovery_candidate_target[p] = completion[p].npc;
      end
    end
  end
  rapt_recovery_pending #(
      .Entries(ROB_SIZE),
      .Ports(NumCompletions),
      .Xlen(XLEN),
      .GenerationBits(GenerationBits)
  ) recovery_request (
      .clock(clock),
      .reset(reset),
      .flush(flush_pipe),
      .live(rob_entry_busy),
      .head(rob_head),
      .owner_generation(rob_owner_generation),
      .candidate_generation(completion_generation),
      .candidate_valid(recovery_candidate_valid),
      .candidate_index(recovery_candidate_index),
      .candidate_target(recovery_candidate_target),
      .pending(recovery_pending),
      .owner(recovery_owner),
      .target(recovery_target),
      .generation(recovery_generation)
  );
  assign recovery_owner_current = int'(recovery_owner) < ROB_SIZE
      && rob_entry_busy[recovery_owner]
      && rob_owner_generation[recovery_owner] == recovery_generation;
  assign recovery.pending = recovery_pending;
  assign recovery.redirect_valid = recovery_pending && recovery_owner_current
      && (!recovery_announced
          || recovery_owner != recovery_announced_owner
          || recovery_generation != recovery_announced_generation
          || recovery_target != recovery_announced_target);
  assign recovery.owner = recovery_owner;
  assign recovery.head = rob_head;
  assign recovery.generation = recovery_generation;
  assign recovery.target = recovery_target;
  assign recovery.checkpoint_valid = recovery_pending && recovery_owner_current
      && rob_checkpoint_valid[recovery_owner];
  assign recovery.checkpoint = rob_checkpoint[recovery_owner];
  // Host-observable pulse for quantifying how often completion-time recovery
  // can overlap target-side I-cache work with the later precise ROB cleanup.
  logic pmu_recovery_redirect  /* verilator public_flat_rd */;
  assign pmu_recovery_redirect = recovery.redirect_valid;
  always_ff @(posedge clock) begin
    if (reset || flush_pipe || !recovery_pending) begin
      recovery_announced <= 1'b0;
      // Metadata comparisons are ignored while !recovery_announced. Every
      // new announcement captures the complete identity/target together.
    end else if (recovery.redirect_valid) begin
      recovery_announced <= 1'b1;
      recovery_announced_owner <= recovery_owner;
      recovery_announced_target <= recovery_target;
      recovery_announced_generation <= recovery_generation;
    end
  end
  for (genvar p = 0; p < NumCompletions; p++) begin : g_rename_checkpoint_resolve
    assign checkpoint_release.valid[p] = completion_valid[p]
        && completion[p].updates.control_flow && !completion_mispredict[p] && !completion[p].trap
        && int'(completion[p].dest) < ROB_SIZE && rob_checkpoint_valid[completion[p].dest]
        && rob_control_flow[completion[p].dest];
    assign checkpoint_release.checkpoint[p] = checkpoint_release.valid[p]
        ? rob_checkpoint[completion[p].dest] : '0;
  end
  for (genvar p = 0; p < NumCompletions; p++) begin : g_prediction_check
    wire [RBits-1:0] owner = completion[p].dest;
    wire has_target = int'(owner) < ROB_SIZE && rob_checkpoint_valid[owner]
        && int'(rob_checkpoint[owner]) < CheckpointEntries;
    wire [CheckpointBits-1:0] checkpoint = rob_checkpoint[owner];
    // The fallback only serves standalone/hostile-input harnesses. Normal
    // rename allocates a checkpoint for every control-flow instruction.
    assign completion_mispredict[p] = has_target
        ? (completion[p].npc != predicted_npc[checkpoint]
            || (uop_pl[owner].execute.branch.conditional
                && completion[p].btaken != predicted_taken[checkpoint]))
        : completion[p].mispredict;
  end

  // UOQ -> ROB allocation remains an ordered prefix. In buffered mode this
  // boundary depends only on ROB/serialization resources; execution-domain
  // capacity is consumed by the independent ROB_DP steering boundary below.
  rapt_dispatch_admit #(
      .Width(NumSlots)
  ) admission (
      .reset(reset),
      .flush(flush_pipe),
      .halt(dm_haltreq_i),
      .serial_in_flight(serialize_in_flight),
      .rob_empty(rob_empty),
      .recovery_pending(Cfg.recovery_dispatch_fence && recovery_pending),
      .present(admission_present),
      .rob_available(admission_rob_available),
      .serial(admission_serial),
      .endpoint_ready(allocation_endpoint_ready),
      .eligible(admission_eligible),
      .accepted(deq_fire),
      .count(dispatch_count),
      .stop_reason(dispatch_stop)
  );

  if (Cfg.rob_dispatch_buffered) begin : g_buffered_dispatch
    rapt_rob_dispatch_select #(
        .Entries(ROB_SIZE),
        .Width(NumSlots),
        .ScanEntries(ScanEntries),
        .IndexBits(RBits)
    ) select (
        .pending(rob_dispatch_eligible),
        .head(rob_head),
        .incoming_valid(deq_fire),
        .incoming_index(rob_alloc),
        .endpoint_ready(candidate_ready),
        .candidate_valid(candidate_valid),
        .candidate_index(dispatch_index),
        .candidate_incoming(dispatch_from_allocation),
        .candidate_source_slot(dispatch_source_slot),
        .accepted(endpoint_fire),
        .candidate_count(steer_candidate_count),
        .accepted_count(endpoint_count),
        .bypass_count(steer_bypass_count),
        .oldest_blocked(steer_oldest_blocked)
    );
  end else begin : g_coupled_dispatch
    always_comb begin
      steer_candidate_count = 0;
      endpoint_count = 0;
      steer_bypass_count = 0;
      steer_oldest_blocked = admission_eligible[0] && !candidate_ready[0];
      for (int s = 0; s < ScanEntries; s++) begin
        candidate_valid[s] = 1'b0;
        dispatch_index[s] = '0;
        dispatch_from_allocation[s] = 1'b0;
        dispatch_source_slot[s] = '0;
        endpoint_fire[s] = 1'b0;
        if (s < NumSlots) begin
          candidate_valid[s] = admission_eligible[s];
          dispatch_index[s] = rob_alloc[s];
          dispatch_from_allocation[s] = 1'b1;
          dispatch_source_slot[s] = SlotBits'(s);
          endpoint_fire[s] = deq_fire[s];
          steer_candidate_count += int'(candidate_valid[s]);
          endpoint_count += int'(endpoint_fire[s]);
        end
      end
    end
  end

  always_ff @(posedge clock) begin
    pmu_dispatch_reason <= dispatch_stop;
    pmu_dispatch_count <= dispatch_count;
    pmu_dispatch_stop_domain <= 0;
    for (int s = 0; s < NumSlots; s++)
    if (dispatch_stop == rapt_pkg::DispatchStopEndpoint && dispatch_count == s)
      pmu_dispatch_stop_domain <= 32'(uoq_uops[deq_index[s]].schedule.domain);
    pmu_steer_candidates <= 32'(steer_candidate_count);
    pmu_steer_accepted <= 32'(endpoint_count);
    pmu_steer_bypass <= 32'(steer_bypass_count);
    pmu_steer_pending <= 32'($countones(rob_dispatch_pending));
    for (int d = 0; d < NumDomains; d++) pmu_steer_pending_domain[d] <= steer_pending_domain[d];
    pmu_steer_oldest_blocked <= steer_oldest_blocked;
    pmu_steer_blocked_domain <= candidate_valid[0] ? 32'(candidate_domain[0]) : '0;
  end
  always_comb begin
    for (int d = 0; d < NumDomains; d++) begin
      steer_pending_domain[d] = '0;
      for (int e = 0; e < ROB_SIZE; e++)
      steer_pending_domain[d] += 32'(rob_dispatch_pending[e]
            && int'(uop_pl[e].schedule.domain) == d);
    end
  end
  for (genvar c = 0; c < ScanEntries; c++) begin : g_candidate_domain
    always_comb begin
      candidate_domain[c] = rapt_pkg::execution_domain_t'(0);
      if (candidate_valid[c]) begin
        if (Cfg.rob_dispatch_buffered && !dispatch_from_allocation[c])
          candidate_domain[c] = uop_pl[dispatch_index[c]].schedule.domain;
        else candidate_domain[c] = uoq_uops[deq_index[dispatch_source_slot[c]]].schedule.domain;
      end
    end
  end
  // Compute allocation operands/dependencies once per physical allocation port.
  // Both fall-through dispatch and the selected ROB owner consume this record.
  SlotT allocation[NumSlots];
  for (genvar s = 0; s < NumSlots; s++) begin : g_allocation_payload
    wire [QBits-1:0] source_index = deq_index[s];
    always_comb begin
      allocation[s] = '0;
      allocation[s].uop = uoq_uops[source_index];
      allocation[s].op1 = uoq_pv1_valid[source_index] ? uoq_op1[source_index]
          : wb_val(uoq_pr1[source_index], '0);
      allocation[s].stable_op1 = uoq_op1[source_index];
      allocation[s].stable_op1_valid = uoq_pv1_valid[source_index];
      allocation[s].op2 = uoq_pv2_valid[source_index] ? uoq_op2[source_index]
          : wb_val(uoq_pr2[source_index], '0);
      allocation[s].pr1 = uoq_pv1_valid[source_index] || wb_hit(uoq_pr1[source_index])
          ? '0 : uoq_pr1[source_index];
      allocation[s].pr2 = uoq_pv2_valid[source_index] || wb_hit(uoq_pr2[source_index])
          ? '0 : uoq_pr2[source_index];
      allocation[s].prd = uoq_prd[source_index];
      allocation[s].prs = uoq_prs[source_index];
      allocation[s].dest = rob_alloc[s];
      allocation[s].generation = rob_next_generation[rob_alloc[s]];
      // Every FP instruction enters an empty ROB and blocks younger admission
      // until retirement. No FPR producer can remain when the next FP (or FP
      // store) allocates, so completion-tag dependencies are unreachable.
      for (int d = 0; d < NumDependencies; d++) begin
        allocation[s].dep_valid[d] = 1'b0;
        allocation[s].dep_tag[d] = '0;
        allocation[s].dep_generation[d] = '0;
      end
    end
  end
  for (genvar s = 0; s < NumSlots; s++) begin : g_spill_route
    always_comb begin
      automatic int unsigned candidate_slot;
      candidate_slot = int'(selected_candidate[s]);
      spill_read_index[s] = '0;
      spill_release_valid[s] = 1'b0;
      spill_release_index[s] = '0;
      if (selected_valid[s] && Cfg.rob_dispatch_buffered
          && !dispatch_from_allocation[candidate_slot])
        spill_read_index[s] = rob_dp_spill[dispatch_index[candidate_slot]];
      if (selected_valid[s] && Cfg.rob_dispatch_buffered && endpoint_fire[candidate_slot]) begin
        spill_release_valid[s] = 1'b1;
        spill_release_index[s] = dispatch_from_allocation[candidate_slot]
            ? spill_allocate_index[dispatch_source_slot[candidate_slot]]
            : rob_dp_spill[dispatch_index[candidate_slot]];
      end
    end
  end
  for (genvar s = 0; s < NumSlots; s++) begin : g_dispatch
    always_comb begin
      automatic int unsigned candidate_slot;
      dispatch[s] = '0;
      candidate_slot = int'(selected_candidate[s]);
      if (selected_valid[s] && Cfg.rob_dispatch_buffered
          && !dispatch_from_allocation[candidate_slot]) begin
        dispatch[s].uop = spill_read_uop[s];
        // The resident pending-state snoop updates at the clock edge.  Merge
        // the current CDB combinationally as well, otherwise a completion on
        // the same edge that the endpoint accepts this uop would be lost by
        // the destination queue (the stored tag is one cycle old there).
        dispatch[s].op1 = wb_val(spill_read_pr1[s], spill_read_op1[s]);
        dispatch[s].stable_op1 = spill_read_op1[s];
        dispatch[s].stable_op1_valid = spill_read_pr1[s] == '0;
        dispatch[s].op2 = wb_val(spill_read_pr2[s], spill_read_op2[s]);
        dispatch[s].pr1 = wb_hit(spill_read_pr1[s]) ? '0 : spill_read_pr1[s];
        dispatch[s].pr2 = wb_hit(spill_read_pr2[s]) ? '0 : spill_read_pr2[s];
        dispatch[s].prd = rob_entry[dispatch_index[candidate_slot]].prd;
        dispatch[s].prs = rob_entry[dispatch_index[candidate_slot]].prs;
        dispatch[s].dest = dispatch_index[candidate_slot];
        dispatch[s].generation = rob_entry[dispatch_index[candidate_slot]].generation;
        for (int d = 0; d < NumDependencies; d++) begin
          dispatch[s].dep_valid[d] = 1'b0;
          dispatch[s].dep_tag[d] = '0;
          dispatch[s].dep_generation[d] = '0;
        end
      end else if (selected_valid[s]) begin
        dispatch[s] = allocation[dispatch_source_slot[candidate_slot]];
      end
      // Prediction target is consumed on RNU->UOQ acceptance and kept by
      // checkpoint ID. No execution queue needs an XLEN-wide copy.
      dispatch[s].uop.pnpc = '0;
      dispatch[s].uop.execute.branch.predicted_taken = 1'b0;
    end
    `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_RESIDENT_DISPATCH_HAS_SPILL,
                    selected_valid[s] && Cfg.rob_dispatch_buffered
                        && !dispatch_from_allocation[selected_candidate[s]],
                    spill_read_valid[s])
  end
  for (genvar s = 0; s < NumSlots; s++) begin : g_allocate
    assign deq_index[s] = QBits'((int'(uoq_tail) + s) % IIQ_SIZE);
    assign rob_alloc[s] = RBits'((int'(rob_tail) + s) % ROB_SIZE);
    assign admission_present[s] = uoq_valid[deq_index[s]];
    assign admission_rob_available[s] = !rob_entry_busy[rob_alloc[s]];
    assign admission_serial[s] = serializing(uoq_uops[deq_index[s]]);
    assign spill_allocate_valid[s] = Cfg.rob_dispatch_buffered
        && admission_eligible[s] && spill_allocate_ready[s];
    always_comb begin
      spill_allocate_uop[s] = allocation[s].uop;
      spill_allocate_uop[s].pnpc = '0;
      spill_allocate_uop[s].execute.branch.predicted_taken = 1'b0;
    end
    assign spill_allocate_op1[s] = allocation[s].op1;
    assign spill_allocate_op2[s] = allocation[s].op2;
    assign spill_allocate_pr1[s] = allocation[s].pr1;
    assign spill_allocate_pr2[s] = allocation[s].pr2;
    assign allocation_endpoint_ready[s] = Cfg.rob_dispatch_buffered
        ? spill_allocate_ready[s] : candidate_ready[s];
  end
  for (genvar s = 0; s < RenameWidth; s++) begin : g_enqueue
    logic available;
    assign enq_index[s] = QBits'((int'(uoq_head) + s) % IIQ_SIZE);
    // Reclaim a dispatched UOQ entry after the edge.  Same-cycle reuse feeds
    // dispatch admission back into rename readiness and, through frontend
    // cancellation and retirement, forms a core-wide combinational loop.
    assign available = !uoq_valid[enq_index[s]];
    if (s == 0) begin : g_first_slot
      assign rnu_rou.ready[s] = available && !flush_pipe && !reset && !dm_haltreq_i;
    end else begin : g_chain_slot
      assign rnu_rou.ready[s] = available && enq_fire[s-1] && !flush_pipe && !reset
          && !dm_haltreq_i;
    end
    assign enq_fire[s] = rnu_rou.valid[s] && rnu_rou.ready[s];
    assign exu_prf.pr1[s] = rnu_rou.slot[s].pr1;
    assign exu_prf.pr2[s] = rnu_rou.slot[s].pr2;
  end
  always_comb begin
    enqueue_count = 0;
    for (int s = 0; s < RenameWidth; s++) enqueue_count += int'(enq_fire[s]);
  end
  // Any-port tag match (zero tag never matches).
  function automatic logic wb_hit(input logic [PLEN-1:0] pr);
    wb_hit = 1'b0;
    for (int p = 0; p < NWB; p++) begin
      wb_hit |= (pr != '0) && wb_valid_v[p] && (wb_prd_v[p] == pr);
    end
  endfunction

  // First-match value in port order (reverse loop: slot 0 wins).
  function automatic logic [XLEN-1:0] wb_val(input logic [PLEN-1:0] pr,
                                             input logic [XLEN-1:0] dflt);
    wb_val = dflt;
    for (int p = NWB - 1; p >= 0; p--) begin
      if ((pr != '0) && wb_valid_v[p] && (wb_prd_v[p] == pr)) wb_val = wb_res_v[p];
    end
  endfunction

  // Resolve rename-side bypass once per input port, before the UOQ write mux.
  logic [XLEN-1:0] enqueue_value1[RenameWidth], enqueue_value2[RenameWidth];
  logic enqueue_ready1[RenameWidth], enqueue_ready2[RenameWidth];
  for (genvar s = 0; s < RenameWidth; s++) begin : g_enqueue_payload
    assign enqueue_value1[s] = wb_val(rnu_rou.slot[s].pr1, exu_prf.pv1[s]);
    assign enqueue_value2[s] = wb_val(rnu_rou.slot[s].pr2, exu_prf.pv2[s]);
    assign enqueue_ready1[s] = wb_hit(rnu_rou.slot[s].pr1) || exu_prf.pv1_valid[s];
    assign enqueue_ready2[s] = wb_hit(rnu_rou.slot[s].pr2) || exu_prf.pv2_valid[s];
  end




  always_ff @(posedge clock) begin
    if (reset || flush_pipe) begin
      uoq_head <= '0;
      uoq_tail <= '0;
      serialize_in_flight <= 1'b0;
    end else begin
      uoq_head <= QBits'((int'(uoq_head) + enqueue_count) % IIQ_SIZE);
      uoq_tail <= QBits'((int'(uoq_tail) + dispatch_count) % IIQ_SIZE);
      if (serialize_in_flight && rob_empty) serialize_in_flight <= 1'b0;
      for (int s = 0; s < NumSlots; s++)
      if (deq_fire[s] && serializing(allocation[s].uop)) serialize_in_flight <= 1'b1;
    end
  end
  always_ff @(posedge clock) begin
    if (reset || flush_pipe) csr_wdata_q <= '0;
    else begin
      for (int p = 0; p < NumCompletions; p++)
      if (completion_valid[p] && completion[p].updates.system_state && completion[p].csr_wen)
        csr_wdata_q <= completion[p].csr_wdata;
    end
  end
  always_ff @(posedge clock) begin
    if (!reset && !flush_pipe) begin
      for (int s = 0; s < RenameWidth; s++) begin
        if (enq_fire[s] && rnu_rou.checkpoint_valid[s]
            && int'(rnu_rou.checkpoint[s]) < CheckpointEntries) begin
          predicted_npc[rnu_rou.checkpoint[s]] <= rnu_rou.slot[s].uop.pnpc;
          predicted_taken[rnu_rou.checkpoint[s]]
              <= rnu_rou.slot[s].uop.execute.branch.predicted_taken;
        end
      end
    end
  end
  always_comb begin
    exception_next_valid = oldest_exception_valid;
    exception_next_owner = oldest_exception_owner;
    exception_next_cause = oldest_exception_cause;
    exception_next_tval = oldest_exception_tval;
    for (int s = 0; s < NumSlots; s++) begin
      if (deq_fire[s] && allocation[s].uop.trap && (!exception_next_valid || older_rob_owner(
              rob_alloc[s], exception_next_owner
          ))) begin
        exception_next_valid = 1'b1;
        exception_next_owner = rob_alloc[s];
        exception_next_cause = allocation[s].uop.cause;
        exception_next_tval = allocation[s].uop.tval;
      end
    end
    for (int p = 0; p < NumCompletions; p++) begin
      if (completion_valid[p] && completion[p].updates.exception && completion[p].trap
          && (!exception_next_valid || completion[p].dest == exception_next_owner
              || older_rob_owner(
              completion[p].dest, exception_next_owner
          ))) begin
        exception_next_valid = 1'b1;
        exception_next_owner = completion[p].dest;
        exception_next_cause = completion[p].cause;
        exception_next_tval = completion[p].tval;
      end
    end
  end
  always_ff @(posedge clock) begin
    if (reset || flush_pipe) begin
      oldest_exception_valid <= 1'b0;
      oldest_exception_owner <= '0;
      oldest_exception_cause <= '0;
      oldest_exception_tval <= '0;
    end else begin
      oldest_exception_valid <= exception_next_valid;
      oldest_exception_owner <= exception_next_owner;
      oldest_exception_cause <= exception_next_cause;
      oldest_exception_tval <= exception_next_tval;
    end
  end
  always_ff @(posedge clock) begin
    if (reset || flush_pipe) cbo_block_q <= '0;
    else begin
      for (int p = 0; p < NumCompletions; p++)
      if (completion_valid[p] && completion[p].dest == h0 && head_cbo)
        cbo_block_q <= completion[p].tval[11:6];
    end
  end
  // The rename writer for a given UOQ entry is a combinational function so
  // the sequential UOQ block stays free of blocking assignment statements.
  function automatic int enq_writer(input int unsigned e);
    for (int s = 0; s < RenameWidth; s++) if (enq_fire[s] && int'(enq_index[s]) == e) return s;
    return -1;
  endfunction
  for (genvar e = 0; e < IIQ_SIZE; e++) begin : g_uoq_state
    always_ff @(posedge clock) begin
      if (reset || flush_pipe) begin
        uoq_valid[e] <= 1'b0;
        uoq_pv1_valid[e] <= 1'b0;
        uoq_pv2_valid[e] <= 1'b0;
      end else begin
        automatic int writer = enq_writer(e);
        if (writer >= 0) begin
          uoq_uops[e] <= without_prediction(rnu_rou.slot[writer].uop);
          uoq_pr1[e] <= rnu_rou.slot[writer].pr1;
          uoq_pr2[e] <= rnu_rou.slot[writer].pr2;
          uoq_prd[e] <= rnu_rou.slot[writer].prd;
          uoq_prs[e] <= rnu_rou.slot[writer].prs;
          uoq_op1[e] <= rnu_rou.slot[writer].pr1 == '0
              ? rnu_rou.slot[writer].op1 : enqueue_value1[writer];
          uoq_op2[e] <= rnu_rou.slot[writer].pr2 == '0
              ? rnu_rou.slot[writer].op2 : enqueue_value2[writer];
          uoq_checkpoint_valid[e] <= rnu_rou.checkpoint_valid[writer];
          uoq_checkpoint[e] <= rnu_rou.checkpoint[writer];
          uoq_valid[e] <= 1'b1;
          uoq_pv1_valid[e] <= rnu_rou.slot[writer].pr1 == '0 || enqueue_ready1[writer];
          uoq_pv2_valid[e] <= rnu_rou.slot[writer].pr2 == '0 || enqueue_ready2[writer];
        end else begin
          for (int s = 0; s < NumSlots; s++)
          if (deq_fire[s] && int'(deq_index[s]) == e) uoq_valid[e] <= 1'b0;
          if (uoq_valid[e]) begin
            if (!uoq_pv1_valid[e] && wb_hit(uoq_pr1[e])) begin
              uoq_op1[e] <= wb_val(uoq_pr1[e], '0);
              uoq_pv1_valid[e] <= 1'b1;
            end
            if (!uoq_pv2_valid[e] && wb_hit(uoq_pr2[e])) begin
              uoq_op2[e] <= wb_val(uoq_pr2[e], '0);
              uoq_pv2_valid[e] <= 1'b1;
            end
          end
        end

      end
    end
  end
  // Retirement scans a contiguous prefix with explicit scalar-effect budgets.
  assign writeback_drain = !reset && rob_entry_busy[rob_head]
      && rob_entry[rob_head].state == rapt_pkg::ROB_WB
      && rob_drains_sq[rob_head];
  // Special operations retire alone; ordinary groups may contain one store and
  // one control-flow instruction, matching the physical LSU/BPU interfaces.
  for (genvar c = 0; c < CommitWidth; c++) begin : g_commit_index
    assign commit_index[c] = RBits'((int'(rob_head) + c) % ROB_SIZE);
  end
  always_comb begin
    automatic logic prefix;
    prefix = !reset && !recieved_trap;
    commit_count = 0;
    youngest_commit = h0;
    store_commit = h0;
    branch_commit = h0;
    store_commit_valid = 1'b0;
    branch_commit_valid = 1'b0;
    for (int c = 0; c < CommitWidth; c++) begin
      commit_fire[c] = prefix && rob_entry_busy[commit_index[c]]
          && rob_entry[commit_index[c]].state == rapt_pkg::ROB_WB
          && (!rob_entry[commit_index[c]].wen || (rou_lsu.sq_ready && !store_commit_valid))
          && (!rob_control_flow[commit_index[c]] || !branch_commit_valid) &&
          (!commit_special(int'(commit_index[c])) || c == 0) &&
          (!rob_drains_sq[commit_index[c]] || (rou_lsu.sq_empty && writeback_idle));
      if (commit_fire[c]) begin
        commit_count++;
        youngest_commit = commit_index[c];
        if (rob_entry[commit_index[c]].wen) begin
          store_commit = commit_index[c];
          store_commit_valid = 1'b1;
        end
        if (rob_control_flow[commit_index[c]]) begin
          branch_commit = commit_index[c];
          branch_commit_valid = 1'b1;
        end
      end
      // The scalar store-commit endpoint terminates this retirement group.
      // This is an effect policy, independent of the store's slot number.
      prefix = prefix && commit_fire[c] && !commit_special(int'(commit_index[c])) &&
          !rob_entry[commit_index[c]].wen;
    end
  end
  assign head0_valid = recieved_trap || commit_fire[0];
  assign head0_flush = recieved_trap || (commit_fire[0] && (
      rob_serializing[h0] && !rob_fp_valid[h0]
      || rob_entry[h0].trap || rob_entry[h0].mispredict || rob_atomic[h0]));
  assign flush_pipe = head0_flush || debug_halt_flush;
  assign rou_cmu.next_pc = debug_halt_flush ? commit_npc_q :
      recieved_trap || rob_entry[youngest_commit].trap
      || uop_pl[youngest_commit].execute.sys.ecall || uop_pl[youngest_commit].execute.sys.ebreak
      ? csr_bcast.tvec : rob_entry[youngest_commit].npc;
  for (genvar entry = 0; entry < ROB_SIZE; entry++) begin : g_generation
    always_ff @(posedge clock) begin
      if (reset) rob_next_generation[entry] <= '0;
      else begin
        // Survives flush: reusing a physical slot creates a new identity.
        for (int s = 0; s < NumSlots; s++)
        if (deq_fire[s] && int'(rob_alloc[s]) == entry)
          rob_next_generation[entry] <= rob_next_generation[entry] + 1'b1;
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      flush_apply <= 1'b0;
      flush_target_r <= '0;
      commit_npc_q <= XLEN'(`RAPT_PC_INIT);
    end else begin
      flush_apply <= flush_pipe;
      if (flush_pipe) flush_target_r <= rou_cmu.next_pc;
      if (head0_valid) commit_npc_q <= rou_cmu.next_pc;
    end
  end
  always_ff @(posedge clock) begin
    if (reset || flush_pipe) begin
      rob_head <= '0;
      rob_tail <= '0;
      recieved_trap <= 1'b0;
      recieved_sw_trap <= 1'b0;
      trap_cause <= '0;
      rob_full_r <= 1'b0;
      pmu_rob_full <= 1'b0;
    end else begin
      rob_tail <= RBits'((int'(rob_tail) + dispatch_count) % ROB_SIZE);
      rob_head <= RBits'((int'(rob_head) + commit_count) % ROB_SIZE);
      pmu_rob_full <= (&rob_entry_busy) && !rob_full_r;
      rob_full_r <= &rob_entry_busy;
      if (commit_count != 0 || rob_empty) begin
        recieved_trap <= async_trap_pending;
        recieved_sw_trap <= clint_sw_trap;
        if (async_trap_pending) trap_cause <= async_trap_cause;
        trap_pc <= commit_count != 0 ? rou_cmu.next_pc : commit_npc_q;
      end
    end
  end
  // Each physical owner has one local state writer. Priority at an edge is
  // reset/flush > retire > completion > endpoint acceptance > allocation >
  // pending operand snoop. Only the small port dimensions are procedural.
  for (genvar entry = 0; entry < ROB_SIZE; entry++) begin : g_rob_state
    always_ff @(posedge clock) begin
      if (reset || flush_pipe) begin
        rob_entry[entry].state <= rapt_pkg::ROB_CM;
        rob_checkpoint_valid[entry] <= 1'b0;
      end else begin
        for (int s = 0; s < NumSlots; s++)
        if (deq_fire[s] && int'(rob_alloc[s]) == entry) begin
          // ---- ROB entry: control + WB-mutable defaults ----
          rob_entry[entry].prd        <= allocation[s].prd;
          rob_entry[entry].prs        <= allocation[s].prs;
          rob_entry[entry].generation <= allocation[s].generation;
          rob_control_flow[entry] <= control_flow(allocation[s].uop);
          rob_serializing[entry] <= serializing(allocation[s].uop);
          rob_drains_sq[entry] <= drains_sq_before_commit(allocation[s].uop);
          rob_atomic[entry] <= allocation[s].uop.execute.memory.atomic;
          rob_fp_valid[entry] <= allocation[s].uop.execute.fp.valid;
          rob_entry[entry].state      <= Cfg.rob_dispatch_buffered
              ? rapt_pkg::ROB_DP : rapt_pkg::ROB_EX;
          rob_entry[entry].rd         <= allocation[s].uop.rd;
          rob_entry[entry].mispredict <= 1'b0;
          rob_checkpoint_valid[entry] <= uoq_checkpoint_valid[deq_index[s]];
          rob_checkpoint[entry]       <= uoq_checkpoint[deq_index[s]];
          rob_entry[entry].wen        <= allocation[s].uop.execute.memory.store;
          rob_entry[entry].fp_flags_valid <= 1'b0;
          rob_entry[entry].fp_flags   <= '0;
          rob_entry[entry].trap  <= allocation[s].uop.trap;
`ifndef SYNTHESIS
          store_addr_witness[entry] <= allocation[s].uop.tval;
`endif

          // Immutable metadata belongs to the ROB, not execution-unit ports.
          uop_pl[entry] <= compact_retire_uop(allocation[s].uop);

          rob_dp_spill[entry] <= spill_allocate_index[s];
        end
        for (int s = 0; s < ScanEntries; s++)
        if (endpoint_fire[s] && int'(dispatch_index[s]) == entry)
          rob_entry[entry].state <= rapt_pkg::ROB_EX;
        for (int p = 0; p < NumCompletions; p++) begin
          if (completion_valid[p] && int'(completion[p].dest) == entry) begin
            rob_entry[entry].state <= rapt_pkg::ROB_WB;
            rob_entry[entry].npc <= completion[p].npc;
            rob_entry[entry].difftest_skip <= completion[p].difftest_skip;
            if (completion[p].updates.control_flow) begin
              rob_entry[entry].btaken <= completion[p].btaken;
              rob_entry[entry].mispredict <= completion_mispredict[p];
            end
            if (completion[p].updates.memory) begin
              rob_entry[entry].wen <= completion[p].wen && !completion[p].trap;
`ifdef RAPT_RVFI
              rvfi_mem_addr[entry] <= completion[p].sq_waddr;
              rvfi_mem_data[entry] <= completion[p].sq_wdata;
`endif
            end
            if (completion[p].updates.system_state) begin
              rob_entry[entry].csr_wen <= completion[p].csr_wen;
              rob_entry[entry].fp_flags_valid <= completion[p].fp_flags_valid;
              rob_entry[entry].fp_flags <= completion[p].fp_flags;
            end
            if (completion[p].updates.exception) begin
              // A faulting producer must not update the architectural map.
              // This includes FP-to-GPR operations, not just memory faults.
              if (completion[p].trap) rob_entry[entry].rd <= '0;
              rob_entry[entry].trap <= completion[p].trap;
`ifndef SYNTHESIS
              store_addr_witness[entry] <= completion[p].tval;
`endif
            end
          end
        end


        for (int c = 0; c < CommitWidth; c++)
        if (commit_fire[c] && int'(commit_index[c]) == entry) begin
          rob_entry[entry].state <= rapt_pkg::ROB_CM;
          rob_entry[entry].csr_wen <= 1'b0;
          rob_entry[entry].fp_flags_valid <= 1'b0;
          rob_entry[entry].trap <= 1'b0;
          rob_entry[entry].wen <= 1'b0;
          rob_checkpoint_valid[entry] <= 1'b0;
        end

      end
    end
  end
  for (genvar c = 0; c < CommitWidth; c++) begin : g_commit_event
    always_comb begin
      rou_cmu.slot[c] = '0;
      rou_cmu.slot[c].valid = commit_fire[c];
      rou_cmu.slot[c].rd = rob_entry[commit_index[c]].rd;
      rou_cmu.slot[c].prd = rob_entry[commit_index[c]].prd;
      rou_cmu.slot[c].prs = rob_entry[commit_index[c]].prs;
      rou_cmu.slot[c].pc = uop_pl[commit_index[c]].pc;
      rou_cmu.slot[c].inst = uop_pl[commit_index[c]].inst;
      rou_cmu.slot[c].c = uop_pl[commit_index[c]].c;
      rou_cmu.slot[c].trap = rob_entry[commit_index[c]].trap;
      rou_cmu.slot[c].atomic = rob_atomic[commit_index[c]];
      rou_cmu.slot[c].npc = rob_entry[commit_index[c]].trap
          || uop_pl[commit_index[c]].execute.sys.ecall || uop_pl[commit_index[c]].execute.sys.ebreak
          ? csr_bcast.tvec : rob_entry[commit_index[c]].npc;
      rou_cmu.slot[c].ebreak = uop_pl[commit_index[c]].execute.sys.ebreak;
      rou_cmu.slot[c].difftest_skip = rob_entry[commit_index[c]].difftest_skip;
      rou_cmu.slot[c].ben = uop_pl[commit_index[c]].execute.branch.conditional;
      rou_cmu.slot[c].jen = uop_pl[commit_index[c]].execute.branch.jump;
      rou_cmu.slot[c].jren = uop_pl[commit_index[c]].execute.branch.indirect;
      rou_cmu.slot[c].branch_mispredict = rob_entry[commit_index[c]].mispredict;
      rou_cmu.slot[c].btaken = rob_entry[commit_index[c]].btaken;
`ifdef RAPT_RVFI
      rou_cmu.slot[c].rvfi_trap = rob_entry[commit_index[c]].trap;
      rou_cmu.slot[c].rvfi_npc = rou_cmu.slot[c].npc;
      rou_cmu.slot[c].rvfi_sq_waddr = rvfi_mem_addr[commit_index[c]];
      rou_cmu.slot[c].rvfi_sq_wdata = rvfi_mem_data[commit_index[c]];
      rou_cmu.slot[c].rvfi_inst = uop_pl[commit_index[c]].rvfi_inst;
`endif
    end
  end
  assign rou_cmu.ben = branch_commit_valid && uop_pl[branch_commit].execute.branch.conditional;
  assign rou_cmu.jen = branch_commit_valid && uop_pl[branch_commit].execute.branch.jump;
  assign rou_cmu.jren = branch_commit_valid && uop_pl[branch_commit].execute.branch.indirect;
  assign rou_cmu.btaken = rob_entry[branch_commit].btaken;
  assign rou_cmu.atomic_sc = rob_atomic[h0]
      && uop_pl[h0].execute.int_op.alu == `RAPT_ATO_SC__;
  assign rou_cmu.fence_i = head0_valid && uop_pl[h0].execute.sys.fence_i;
  // Decoder fence flags still serialize CBO dispatch/retirement and replay
  // younger work. They must not turn CBO into a whole-cache/TLB flush.
  assign head_cbo = uop_pl[h0].inst[14:0] == 15'h200f
      && (uop_pl[h0].inst[31:20] == 12'h000
       || uop_pl[h0].inst[31:20] == 12'h001
       || uop_pl[h0].inst[31:20] == 12'h002
       || uop_pl[h0].inst[31:20] == 12'h004);
  assign head_cbo_inval = head_cbo && (uop_pl[h0].inst[31:20] == 12'h000
      || uop_pl[h0].inst[31:20] == 12'h002);
  assign rou_cmu.fence_time = head0_valid && uop_pl[h0].execute.sys.fence && !head_cbo;
  // CBOM drains the SQ and, in write-back configurations, the L1D through
  // writeback_drain. ZERO instead uses its committed SQ store descriptor.
  // A successful serializing CBO completion supplies its block offset.
  assign rou_cmu.cbo_inval = commit_fire[0] && !recieved_trap
      && !rob_entry[h0].trap && head_cbo_inval;
  assign rou_cmu.cbo_block = cbo_block_q;
  assign rou_cmu.flush_pipe = flush_pipe;
  assign rou_cmu.flush_redirect = flush_apply;
  assign rou_cmu.redirect_pc = flush_target_r;
  assign rou_cmu.sys_resume = 1'b0;
  assign rou_cmu.time_trap = recieved_trap;
  assign rou_cmu.rob_head = rob_head;
  logic fp_f2i_from_h0;
  logic fp_dirty_from_h0;
  assign fp_f2i_from_h0 = (uop_pl[h0].execute.fp.op == `RAPT_FP_OP_FCVT_W_S)
      || (uop_pl[h0].execute.fp.op == `RAPT_FP_OP_FCVT_WU_S)
      || (uop_pl[h0].execute.fp.op == `RAPT_FP_OP_FCVT_L_S)
      || (uop_pl[h0].execute.fp.op == `RAPT_FP_OP_FCVT_LU_S)
      || (uop_pl[h0].execute.fp.op == `RAPT_FP_OP_FCVT_W_D)
      || (uop_pl[h0].execute.fp.op == `RAPT_FP_OP_FCVT_WU_D)
      || (uop_pl[h0].execute.fp.op == `RAPT_FP_OP_FCVT_L_D)
      || (uop_pl[h0].execute.fp.op == `RAPT_FP_OP_FCVT_LU_D)
      || ((uop_pl[h0].execute.fp.op == `RAPT_FP_OP_ZFHMIN)
          && (uop_pl[h0].inst[31:25] == 7'b1110010));
  assign fp_dirty_from_h0 = head0_valid && rob_fp_valid[h0] && !rob_entry[h0].trap
      && ((uop_pl[h0].execute.fp.op != `RAPT_FP_OP_FSW)
        && (uop_pl[h0].execute.fp.op != `RAPT_FP_OP_FSD)
        && !((uop_pl[h0].execute.fp.op == `RAPT_FP_OP_ZFHMIN)
             && (uop_pl[h0].inst[6:0] == 7'b0100111))
        && (uop_pl[h0].execute.fp.op != `RAPT_FP_OP_FMV_X_W)
        && (uop_pl[h0].execute.fp.op != `RAPT_FP_OP_FMV_X_D)
        && (uop_pl[h0].execute.fp.op != `RAPT_FP_OP_FLE_S)
        && (uop_pl[h0].execute.fp.op != `RAPT_FP_OP_FLT_S)
        && (uop_pl[h0].execute.fp.op != `RAPT_FP_OP_FEQ_S)
        && (uop_pl[h0].execute.fp.op != `RAPT_FP_OP_FCLASS_S)
        && (uop_pl[h0].execute.fp.op != `RAPT_FP_OP_FLE_D)
        && (uop_pl[h0].execute.fp.op != `RAPT_FP_OP_FLT_D)
        && (uop_pl[h0].execute.fp.op != `RAPT_FP_OP_FEQ_D)
        && (uop_pl[h0].execute.fp.op != `RAPT_FP_OP_FCLASS_D)
        && !fp_f2i_from_h0
        || (rob_entry[h0].fp_flags_valid && |rob_entry[h0].fp_flags));


  logic commit_trap;
  assign commit_trap = rob_entry[h0].trap;
  `RAPT_SVA_IMPLY(clock, reset, ROB_TRAP_HAS_OLDEST_CAUSE, commit_fire[0] && commit_trap,
                  oldest_exception_valid && oldest_exception_owner == h0)
  assign rou_csr.pc = recieved_trap ? trap_pc : uop_pl[h0].pc;
  assign rou_csr.csr_wen = !recieved_trap && !commit_trap && uop_pl[h0].execute.sys.valid
      && rob_entry[h0].csr_wen;
  assign rou_csr.csr_wdata = csr_wdata_q;
  assign rou_csr.csr_addr = uop_pl[h0].imm[11:0];
  assign rou_csr.fp_flags_valid = !recieved_trap && !commit_trap && rob_entry[h0].fp_flags_valid;
  assign rou_csr.fp_flags = rob_entry[h0].fp_flags;
  assign rou_csr.fp_dirty = !recieved_trap && !commit_trap && fp_dirty_from_h0;
  assign rou_csr.ecall = !recieved_trap && !commit_trap && uop_pl[h0].execute.sys.ecall;
  assign rou_csr.ebreak = !recieved_trap && !commit_trap && uop_pl[h0].execute.sys.ebreak;
  assign rou_csr.mret = !recieved_trap && !commit_trap && uop_pl[h0].execute.sys.mret;
  assign rou_csr.sret = !recieved_trap && !commit_trap && uop_pl[h0].execute.sys.sret;
  assign rou_csr.trap = recieved_trap || commit_trap;
  assign rou_csr.tval = recieved_trap ? '0 : commit_trap ? oldest_exception_tval : '0;
  assign rou_csr.cause = recieved_trap ? trap_cause : oldest_exception_cause;
  assign rou_csr.valid = recieved_trap || (commit_fire[0] && (uop_pl[h0].execute.sys.valid
      || commit_trap || rob_entry[h0].fp_flags_valid || fp_dirty_from_h0));
  // Faulting instructions still leave the ROB and deliver their exception,
  // but do not retire architecturally. commit_special confines these events
  // to a single head entry; interrupts already suppress commit_count.
  assign rou_csr.retire_count = (commit_fire[0] && (commit_trap
      || uop_pl[h0].execute.sys.ecall || uop_pl[h0].execute.sys.ebreak))
      ? '0 : RetireBits'(commit_count);
  assign rou_lsu.store = store_commit_valid && !rob_entry[store_commit].trap;
  assign rou_lsu.dest = store_commit;
`ifndef SYNTHESIS
  assign rou_lsu.sq_vaddr = store_addr_witness[store_commit];
`else
  assign rou_lsu.sq_vaddr = '0;
`endif
  assign rou_lsu.pc = uop_pl[store_commit].pc;
  assign rou_lsu.valid = store_commit_valid;
  // Narrow PMU state remains independent of the wide commit record muxes.
  logic pmu_branch_flush, pmu_nonbranch_flush, pmu_sq_stall;
`ifndef SYNTHESIS
  // Observational only. Register event identity before pointers/payload change.
  // Flush suppresses ROB writes, but the retiring head still retires on that
  // edge. The host handles retire first, then cancels all remaining identities.
  logic [4:0] pmu_cf_events[ROB_SIZE];
  logic pmu_cf_head_busy, pmu_cf_head_waiting;
  logic [31:0] pmu_cf_head_domain;
  // Registered head classification aligned with CMU's registered retire
  // packet, which the simulator samples after the edge.
  logic pmu_head_busy /* verilator public_flat_rd */;
  logic [1:0] pmu_head_state /* verilator public_flat_rd */;
  logic [31:0] pmu_head_domain /* verilator public_flat_rd */;
  logic pmu_head_store_wait /* verilator public_flat_rd */;
  logic pmu_head_drain_wait /* verilator public_flat_rd */;
  // Combinational per-entry event decoder keeps the sequential PMU block
  // free of blocking assignment statements.
  function automatic logic [4:0] cf_events(input int unsigned e);
    logic [4:0] events;
    events = '0;
    if (!reset) begin
      if (!flush_pipe) begin
        for (int s = 0; s < NumSlots; s++)
        if (deq_fire[s] && int'(rob_alloc[s]) == e && control_flow(uoq_uops[deq_index[s]]))
          events |= 5'(rapt_pkg::CfAllocate);
        for (int p = 0; p < NumCompletions; p++)
        if (completion_valid[p] && int'(completion[p].dest) == e
            && completion[p].updates.control_flow && rob_control_flow[e]) begin
          events |= 5'(rapt_pkg::CfResolve);
          if (completion_mispredict[p] && !completion[p].trap) events |= 5'(rapt_pkg::CfMispredict);
        end
      end
      for (int c = 0; c < CommitWidth; c++)
      if (commit_fire[c] && int'(commit_index[c]) == e && rob_control_flow[e]) begin
        events |= 5'(rapt_pkg::CfRetire);
        if (rob_entry[e].trap) events |= 5'(rapt_pkg::CfTrap);
      end
    end
    return events;
  endfunction
  always_ff @(posedge clock) begin
    pmu_cf_head_busy <= !reset && rob_entry_busy[h0];
    pmu_cf_head_waiting <= !reset && rob_entry_busy[h0] && rob_entry[h0].state != rapt_pkg::ROB_WB;
    pmu_cf_head_domain <= reset ? '0 : 32'(uop_pl[h0].schedule.domain);
    pmu_head_busy <= !reset && rob_entry_busy[h0];
    pmu_head_state <= reset ? rapt_pkg::ROB_CM : rob_entry[h0].state;
    pmu_head_domain <= reset ? '0 : 32'(uop_pl[h0].schedule.domain);
    pmu_head_store_wait <= !reset && rob_entry_busy[h0]
        && rob_entry[h0].state == rapt_pkg::ROB_WB && rob_entry[h0].wen
        && !rou_lsu.sq_ready;
    pmu_head_drain_wait <= !reset && rob_entry_busy[h0]
        && rob_entry[h0].state == rapt_pkg::ROB_WB
        && rob_drains_sq[h0] && (!rou_lsu.sq_empty || !writeback_idle);
    for (int e = 0; e < ROB_SIZE; e++) pmu_cf_events[e] <= cf_events(e);
  end
`endif
  assign pmu_branch_flush = head0_valid && rob_entry[h0].mispredict && rob_control_flow[h0];
  assign pmu_nonbranch_flush = flush_pipe && !pmu_branch_flush;
  assign pmu_sq_stall = rob_entry_busy[h0] && rob_entry[h0].state == rapt_pkg::ROB_WB
      && rob_entry[h0].wen && !rou_lsu.sq_ready;
  `RAPT_SVA_IMPLY(clock, reset, ROB_STORE_HAS_ADDR, rou_lsu.valid && rou_lsu.store, !$isunknown
                  (rou_lsu.sq_vaddr))
  for (genvar c = 0; c < CommitWidth; c++) begin : g_retire_effect_contract
    `RAPT_SVA_IMPLY(clock, reset, ROB_TRAP_HAS_NO_GPR_DEST,
                    commit_fire[c] && rob_entry[commit_index[c]].trap,
                    rob_entry[commit_index[c]].rd == '0)
    `RAPT_SVA_IMPLY(clock, reset, ROB_COMMIT_NEEDS_BUSY, commit_fire[c],
                    rob_entry_busy[commit_index[c]])
    `RAPT_SVA_IMPLY(clock, reset, ROB_SPECIAL_RETIRES_ALONE, commit_fire[c] && commit_special(
                    int'(commit_index[c])), commit_count == 1)
    `RAPT_SVA_IMPLY(clock, reset, ROB_MEMORY_FENCE_DRAINS_MEMORY,
                    commit_fire[c] && rob_drains_sq[commit_index[c]],
                    rou_lsu.sq_empty && writeback_idle)
  end
  for (genvar s = 0; s < NumSlots; s++) begin : g_allocate_contract
    `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_DISPATCH_SYSOP_ONEHOT, deq_fire[s], $onehot0(
                    {
                      uoq_uops[deq_index[s]].execute.sys.ecall,
                      uoq_uops[deq_index[s]].execute.sys.ebreak,
                      uoq_uops[deq_index[s]].execute.sys.mret,
                      uoq_uops[deq_index[s]].execute.sys.sret
                    }
                    ))
    `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_CHECKPOINT_MATCHES_CONTROL_FLOW, deq_fire[s],
                    uoq_checkpoint_valid[deq_index[s]] == control_flow(uoq_uops[deq_index[s]]))
    for (genvar p = 0; p < NumCompletions; p++) begin : g_no_alias
      `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_DISPATCH_WB_NO_ALIAS,
                      deq_fire[s] && completion_valid[p], rob_alloc[s] != completion[p].dest)
    end
  end
  for (genvar s = 0; s < RenameWidth; s++) begin : g_prediction_enqueue_contract
    `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_PREDICTION_ENQUEUE_INDEX,
                    enq_fire[s] && rnu_rou.checkpoint_valid[s],
                    int'(rnu_rou.checkpoint[s]) < CheckpointEntries)
    for (genvar t = s + 1; t < RenameWidth; t++) begin : g_unique
      `RAPT_SVA_IMPLY(
          clock, reset || flush_pipe, ROB_PREDICTION_ENQUEUE_UNIQUE,
          enq_fire[s] && enq_fire[t] && rnu_rou.checkpoint_valid[s] && rnu_rou.checkpoint_valid[t],
          rnu_rou.checkpoint[s] != rnu_rou.checkpoint[t])
    end
  end
  for (genvar s = 0; s < ScanEntries; s++) begin : g_endpoint_dispatch_contract
    `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_ENDPOINT_ACCEPTS_PENDING,
                    Cfg.rob_dispatch_buffered && endpoint_fire[s],
                    (rob_entry_busy[dispatch_index[s]]
         && rob_entry[dispatch_index[s]].state == rapt_pkg::ROB_DP)
        || (dispatch_from_allocation[s]
            && deq_fire[dispatch_source_slot[s]]
            && dispatch_index[s] == rob_alloc[dispatch_source_slot[s]]))
    for (genvar t = s + 1; t < ScanEntries; t++) begin : g_unique
      `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_ENDPOINT_ACCEPTS_UNIQUE,
                      endpoint_fire[s] && endpoint_fire[t], dispatch_index[s] != dispatch_index[t])
    end
  end
  `RAPT_SVA_IMPLY(clock, reset, ROB_SYS_SERIALIZING_FLUSH,
                  commit_fire[0] && (uop_pl[h0].execute.sys.valid || uop_pl[h0].execute.sys.fence),
                  flush_pipe)
  `RAPT_SVA_NEXT(clock, reset, ROB_COMMIT_NPC_IS_ARCHITECTURAL, commit_count != 0,
                 commit_npc_q == $past(rou_cmu.next_pc))
  `RAPT_SVA_NEXT(clock, reset, ROB_IDLE_INTERRUPT_CAPTURE,
                 rob_empty && async_trap_pending && !head0_valid, recieved_trap && trap_pc == $past
                 (commit_npc_q))
  `RAPT_SVA_NEXT(clock, reset, ROB_ORPHAN_SERIALIZE_LOCK_CLEARS, serialize_in_flight && rob_empty,
                 !serialize_in_flight)
  `RAPT_SVA_NEXT(clock, reset, ROB_EVERY_FLUSH_REDIRECTS, flush_pipe,
                 flush_apply && flush_target_r == $past(rou_cmu.next_pc))
  `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_RECOVERY_STOPS_YOUNGER_DISPATCH,
                  Cfg.recovery_dispatch_fence && recovery_pending, dispatch_count == 0)
  `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_RECOVERY_OWNER_IS_LIVE, recovery_pending,
                  rob_entry_busy[recovery_owner] && rob_entry[recovery_owner].mispredict)
  for (genvar c = 1; c < CommitWidth; c++) begin : g_commit_contract
    `RAPT_SVA_IMPLY(clock, reset, ROB_COMMIT_PREFIX, commit_fire[c], commit_fire[c-1])
  end
  for (genvar s = 1; s < NumSlots; s++) begin : g_dispatch_contract
    `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_DISPATCH_PREFIX, deq_fire[s], deq_fire[s-1])
  end
  for (genvar s = 0; s < NumSlots; s++) begin : g_serial_fp_contract
    `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_FP_ALONE_ON_ALLOCATION,
                    deq_fire[s] && allocation[s].uop.execute.fp.valid,
                    s == 0 && rob_empty && dispatch_count == 1)
  end
  for (genvar p = 0; p < NumCompletions; p++) begin : g_completion_contract
    `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_COMPLETION_LIVE, completion_valid[p],
                    rob_entry_busy[completion[p].dest])
    for (genvar q = p + 1; q < NumCompletions; q++) begin : g_unique
      `RAPT_SVA_IMPLY(clock, reset || flush_pipe, ROB_COMPLETION_UNIQUE,
                      completion_valid[p] && completion_valid[q],
                      completion[p].dest != completion[q].dest
              || completion[p].generation != completion[q].generation)
    end
  end
endmodule


// Fixed-position rename packet register before the asynchronous PRF read.
// Unlike a ring head mux, output PR tags are driven directly by registers.
// Partial consumption compacts the remaining suffix; refill is accepted only
// when the old batch is fully consumed, preserving an ordered prefix.
module rapt_operand_stage #(
    parameter int Width = rapt_pkg::RenameWidth
) (
    input logic clock,
    reset,
    flush,
    rnu_rou_if.slave upstream,
    rnu_rou_if.master downstream
);
  localparam int CountBits = $clog2(Width + 1);
  logic [CountBits-1:0] count;
  // Use the interface's type/parameter, not a hierarchical signal in $bits.
  typedef upstream.slot_t SlotT;
  SlotT slot_q[Width];
  logic checkpoint_valid_q[Width];
  logic [upstream.CheckpointBits-1:0] checkpoint_q[Width];
  int consumed, accepted;
  assign downstream.empty = upstream.empty && count == 0;
  for (genvar s = 0; s < Width; s++) begin : g_output
    assign downstream.slot[s] = slot_q[s];
    assign downstream.checkpoint_valid[s] = checkpoint_valid_q[s];
    assign downstream.checkpoint[s] = checkpoint_q[s];
    assign downstream.valid[s] = !reset && !flush && int'(count) > s;
    assign upstream.ready[s] = !reset && !flush && consumed == int'(count);
  end
  always_comb begin
    consumed = 0;
    accepted = 0;
    for (int s = 0; s < Width; s++)
    if (s == consumed && downstream.valid[s] && downstream.ready[s]) consumed++;
    for (int s = 0; s < Width; s++)
    if (s == accepted && upstream.valid[s] && upstream.ready[s]) accepted++;
  end
  always_ff @(posedge clock) begin
    if (reset || flush) count <= '0;
    else begin
      count <= CountBits'(int'(count) - consumed + accepted);
      if (consumed == int'(count)) begin
        for (int s = 0; s < Width; s++)
        if (s < accepted) begin
          slot_q[s] <= upstream.slot[s];
          checkpoint_valid_q[s] <= upstream.checkpoint_valid[s];
          checkpoint_q[s] <= upstream.checkpoint[s];
        end
      end else if (consumed != 0) begin
        for (int s = 0; s < Width; s++)
        if (s + consumed < int'(count)) begin
          slot_q[s] <= slot_q[s + consumed];
          checkpoint_valid_q[s] <= checkpoint_valid_q[s + consumed];
          checkpoint_q[s] <= checkpoint_q[s + consumed];
        end
      end
    end
  end
  `RAPT_SVA(clock, reset, OPERAND_STAGE_CAPACITY, int'(count) <= Width)
endmodule
