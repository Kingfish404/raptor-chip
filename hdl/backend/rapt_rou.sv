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
  localparam int NumDomains = Cfg.execution_domains;
  localparam int RetireBits = rapt_pkg::index_bits(rapt_pkg::CommitWidth + 1);
  logic [RBits-1:0] rob_head, rob_tail, h0;
  logic [RBits-1:0] rob_alloc[NumSlots], dispatch_index[ScanEntries], commit_index[CommitWidth];
  logic dispatch_from_allocation[ScanEntries];
  logic [SlotBits-1:0] dispatch_source_slot[ScanEntries];
  rapt_pkg::rob_entry_t rob_entry[ROB_SIZE];
`ifdef RAPT_RVFI
  // Optional per-owner trace, separate from functional retirement metadata.
  logic [XLEN-1:0] rvfi_mem_addr[ROB_SIZE], rvfi_mem_data[ROB_SIZE];
`endif
  UopT uop_pl[ROB_SIZE];
  logic [QBits-1:0] uoq_head, uoq_tail, enq_index[RenameWidth], deq_index[NumSlots];
  logic [IIQ_SIZE-1:0] uoq_valid, uoq_pv1_valid, uoq_pv2_valid;
  UopT uoq_uops[IIQ_SIZE];
  logic [PLEN-1:0] uoq_pr1[IIQ_SIZE], uoq_pr2[IIQ_SIZE], uoq_prd[IIQ_SIZE], uoq_prs[IIQ_SIZE];
  logic uoq_checkpoint_valid[IIQ_SIZE];
  logic [CheckpointBits-1:0] uoq_checkpoint[IIQ_SIZE];
  logic [XLEN-1:0] uoq_op1[IIQ_SIZE], uoq_op2[IIQ_SIZE], uoq_pv1[IIQ_SIZE], uoq_pv2[IIQ_SIZE];
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
  logic rob_empty /* verilator public_flat_rd */;
  logic [31:0] fp_map_valid;
  logic [RBits-1:0] fp_map[32];
  logic [GenerationBits-1:0] fp_map_generation[32];
  logic flush_pipe, flush_apply, recieved_trap;
  logic recieved_sw_trap /* verilator public */;
  logic [XLEN-1:0] trap_cause /* verilator public */;
  logic [XLEN-1:0] trap_pc, commit_npc_q, flush_target_r;
  logic async_trap_pending;
  logic [XLEN-1:0] async_trap_cause;
  logic [ROB_SIZE-1:0] rob_entry_busy;
  logic [ROB_SIZE-1:0] rob_entry_executing;
  logic [ROB_SIZE-1:0] rob_dispatch_pending, rob_dispatch_eligible;
  logic [PLEN-1:0] rob_dp_pr1[ROB_SIZE], rob_dp_pr2[ROB_SIZE];
  logic [XLEN-1:0] rob_dp_op1[ROB_SIZE], rob_dp_op2[ROB_SIZE];
  logic rob_dp_dep_valid[ROB_SIZE][NumDependencies];
  logic [RBits-1:0] rob_dp_dep_tag[ROB_SIZE][NumDependencies];
  logic [GenerationBits-1:0] rob_dp_dep_generation[ROB_SIZE][NumDependencies];
  logic [GenerationBits-1:0] rob_next_generation[ROB_SIZE];
  logic [GenerationBits-1:0] rob_owner_generation[ROB_SIZE];
  logic rob_checkpoint_valid[ROB_SIZE];
  logic [CheckpointBits-1:0] rob_checkpoint[ROB_SIZE];
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
  for (genvar p = 0; p < NWB; p++) begin
    assign wb_valid_v[p] = completion_valid[p] && completion[p].rd != 0;
    assign wb_prd_v[p] = completion[p].prd;
    assign wb_res_v[p] = completion[p].result;
  end
  assign h0 = rob_head;
  assign rob_empty = !(|rob_entry_busy);
  // UOQ entries can already contain PRF operand snapshots when admission
  // stops. Discard all speculative state at the drained boundary before a
  // debugger may modify architectural registers; resume refetches that PC.
  logic debug_halt_flushed, debug_halt_flush;
  assign debug_halt_flush = dm_haltreq_i && rob_empty && !head0_valid
      && !debug_halt_flushed;
  always_ff @(posedge clock) begin
    if (reset || !dm_haltreq_i) debug_halt_flushed <= 1'b0;
    else if (debug_halt_flush) debug_halt_flushed <= 1'b1;
  end
  assign halted_o = dm_haltreq_i && rob_empty && debug_halt_flushed;
  assign halt_pc_o = commit_npc_q;
  assign commit_fire_o = commit_count != 0;
  assign async_trap_pending = csr_bcast.bus_error_int || clint_sw_trap || clint_timer_trap || clint_ext_trap || s_int_pending;
  assign async_trap_cause = csr_bcast.bus_error_int
      ? XLEN'(`RAPT_BUS_ERROR_IRQ) | (XLEN'(1) << (XLEN-1))
      : clint_ext_trap
      ? XLEN'(`RAPT_CAUSE_MEI) | (XLEN'(1) << (XLEN-1))
      : clint_sw_trap ? XLEN'(`RAPT_CAUSE_MSI) | (XLEN'(1) << (XLEN-1))
      : clint_timer_trap ? XLEN'(`RAPT_CAUSE_MTI) | (XLEN'(1) << (XLEN-1)) : s_int_cause;
  function automatic logic serializing(input UopT u);
    return u.execute.sys.valid || u.execute.fp.valid || u.execute.sys.fence_i || u.execute.sys.fence;
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
  function automatic logic commit_special(input int e);
    return serializing(uop_pl[e]) || rob_entry[e].trap || rob_entry[e].mispredict ||
        uop_pl[e].execute.memory.atomic || rob_entry[e].difftest_skip;
  endfunction
  if (!(NumSlots > 0 && ScanEntries >= NumSlots && RenameWidth > 0 && CommitWidth > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_rou configuration");
  end
  if (!(ROB_SIZE >= ScanEntries && ROB_SIZE >= CommitWidth)) begin : g_invalid_config_1
    $error("Invalid rapt_rou configuration");
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
    assign rob_entry_busy[e] = rob_entry[e].busy;
    assign rob_entry_executing[e] = rob_entry[e].state == rapt_pkg::ROB_EX;
    assign rob_dispatch_pending[e] = rob_entry[e].busy && rob_entry[e].state == rapt_pkg::ROB_DP;
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
      recovery_candidate_target[p] = completion[p].npc;
      if (completion_valid[p] && int'(completion[p].dest) < ROB_SIZE)
        recovery_candidate_valid[p] = completion[p].updates.control_flow
            && completion[p].mispredict && !completion[p].trap
            && rob_entry_busy[completion[p].dest] && !rob_entry[completion[p].dest].trap
            && control_flow(
          uop_pl[completion[p].dest]
        );
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
  assign recovery.redirect_valid = recovery_pending && recovery_owner_current && (!recovery_announced
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
      recovery_announced_owner <= '0;
      recovery_announced_target <= '0;
      recovery_announced_generation <= '0;
    end else if (recovery.redirect_valid) begin
      recovery_announced <= 1'b1;
      recovery_announced_owner <= recovery_owner;
      recovery_announced_target <= recovery_target;
      recovery_announced_generation <= recovery_generation;
    end
  end
  for (genvar p = 0; p < NumCompletions; p++) begin : g_rename_checkpoint_resolve
    assign checkpoint_release.valid[p] = completion_valid[p]
        && completion[p].updates.control_flow && !completion[p].mispredict && !completion[p].trap
        && int'(completion[p].dest) < ROB_SIZE && rob_checkpoint_valid[completion[p].dest]
        && control_flow(uop_pl[completion[p].dest]);
    assign checkpoint_release.checkpoint[p] = rob_checkpoint[completion[p].dest];
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
      allocation[s].op1 = uoq_pr1[source_index] == 0 ? uoq_op1[source_index]
          : uoq_pv1_valid[source_index] ? uoq_pv1[source_index] : wb_val(uoq_pr1[source_index], '0);
      allocation[s].op2 = uoq_pr2[source_index] == 0 ? uoq_op2[source_index]
          : uoq_pv2_valid[source_index] ? uoq_pv2[source_index] : wb_val(uoq_pr2[source_index], '0);
      allocation[s].pr1 = uoq_pv1_valid[source_index] || wb_hit(uoq_pr1[source_index]) ? '0 : uoq_pr1[source_index];
      allocation[s].pr2 = uoq_pv2_valid[source_index] || wb_hit(uoq_pr2[source_index]) ? '0 : uoq_pr2[source_index];
      allocation[s].prd = uoq_prd[source_index];
      allocation[s].prs = uoq_prs[source_index];
      allocation[s].dest = rob_alloc[s];
      allocation[s].generation = rob_next_generation[rob_alloc[s]];
      allocation[s].dep_valid[0] = fp_uses_rs1(uoq_uops[source_index])
          && fp_map_valid[uoq_uops[source_index].execute.fp.rs1]
          && !fp_wb_done(fp_map[uoq_uops[source_index].execute.fp.rs1],
                         fp_map_generation[uoq_uops[source_index].execute.fp.rs1]);
      allocation[s].dep_valid[1] = fp_uses_rs2(uoq_uops[source_index])
          && fp_map_valid[uoq_uops[source_index].execute.fp.rs2]
          && !fp_wb_done(fp_map[uoq_uops[source_index].execute.fp.rs2],
                         fp_map_generation[uoq_uops[source_index].execute.fp.rs2]);
      allocation[s].dep_valid[2] = fp_uses_rs3(uoq_uops[source_index])
          && fp_map_valid[uoq_uops[source_index].execute.fp.rs3]
          && !fp_wb_done(fp_map[uoq_uops[source_index].execute.fp.rs3],
                         fp_map_generation[uoq_uops[source_index].execute.fp.rs3]);
      allocation[s].dep_tag[0] = fp_map[uoq_uops[source_index].execute.fp.rs1];
      allocation[s].dep_tag[1] = fp_map[uoq_uops[source_index].execute.fp.rs2];
      allocation[s].dep_tag[2] = fp_map[uoq_uops[source_index].execute.fp.rs3];
      allocation[s].dep_generation[0] = fp_map_generation[uoq_uops[source_index].execute.fp.rs1];
      allocation[s].dep_generation[1] = fp_map_generation[uoq_uops[source_index].execute.fp.rs2];
      allocation[s].dep_generation[2] = fp_map_generation[uoq_uops[source_index].execute.fp.rs3];
    end
  end
  for (genvar s = 0; s < NumSlots; s++) begin : g_dispatch
    always_comb begin
      automatic int unsigned candidate_slot;
      dispatch[s] = '0;
      candidate_slot = int'(selected_candidate[s]);
      if (selected_valid[s] && Cfg.rob_dispatch_buffered
          && !dispatch_from_allocation[candidate_slot]) begin
        dispatch[s].uop = uop_pl[dispatch_index[candidate_slot]];
        // The resident pending-state snoop updates at the clock edge.  Merge
        // the current CDB combinationally as well, otherwise a completion on
        // the same edge that the endpoint accepts this uop would be lost by
        // the destination queue (the stored tag is one cycle old there).
        dispatch[s].op1 = wb_val(rob_dp_pr1[dispatch_index[candidate_slot]],
                                 rob_dp_op1[dispatch_index[candidate_slot]]);
        dispatch[s].op2 = wb_val(rob_dp_pr2[dispatch_index[candidate_slot]],
                                 rob_dp_op2[dispatch_index[candidate_slot]]);
        dispatch[s].pr1 = wb_hit(rob_dp_pr1[dispatch_index[candidate_slot]])
            ? '0 : rob_dp_pr1[dispatch_index[candidate_slot]];
        dispatch[s].pr2 = wb_hit(rob_dp_pr2[dispatch_index[candidate_slot]])
            ? '0 : rob_dp_pr2[dispatch_index[candidate_slot]];
        dispatch[s].prd = rob_entry[dispatch_index[candidate_slot]].prd;
        dispatch[s].prs = rob_entry[dispatch_index[candidate_slot]].prs;
        dispatch[s].dest = dispatch_index[candidate_slot];
        dispatch[s].generation = rob_entry[dispatch_index[candidate_slot]].generation;
        for (int d = 0; d < NumDependencies; d++) begin
          dispatch[s].dep_valid[d] = rob_dp_dep_valid[dispatch_index[candidate_slot]][d]
              && !fp_wb_done(rob_dp_dep_tag[dispatch_index[candidate_slot]][d],
                             rob_dp_dep_generation[dispatch_index[candidate_slot]][d]);
          dispatch[s].dep_tag[d] = rob_dp_dep_tag[dispatch_index[candidate_slot]][d];
          dispatch[s].dep_generation[d] = rob_dp_dep_generation[dispatch_index[candidate_slot]][d];
        end
      end else if (selected_valid[s]) begin
        dispatch[s] = allocation[dispatch_source_slot[candidate_slot]];
      end
    end
  end
  for (genvar s = 0; s < NumSlots; s++) begin : g_allocate
    assign deq_index[s] = QBits'((int'(uoq_tail) + s) % IIQ_SIZE);
    assign rob_alloc[s] = RBits'((int'(rob_tail) + s) % ROB_SIZE);
    assign admission_present[s] = uoq_valid[deq_index[s]];
    assign admission_rob_available[s] = !rob_entry_busy[rob_alloc[s]];
    assign admission_serial[s] = serializing(uoq_uops[deq_index[s]]);
    assign allocation_endpoint_ready[s] = Cfg.rob_dispatch_buffered ? 1'b1 : candidate_ready[s];
  end
  for (genvar s = 0; s < RenameWidth; s++) begin : g_enqueue
    logic available;
    assign enq_index[s] = QBits'((int'(uoq_head) + s) % IIQ_SIZE);
    always_comb begin
      available = !uoq_valid[enq_index[s]];
      for (int d = 0; d < NumSlots; d++) available |= deq_fire[d] && deq_index[d] == enq_index[s];
    end
    if (s == 0) assign rnu_rou.ready[s] = available && !flush_pipe && !reset && !dm_haltreq_i;
    else assign rnu_rou.ready[s] = available && enq_fire[s-1] && !flush_pipe && !reset && !dm_haltreq_i;
    assign enq_fire[s] = rnu_rou.valid[s] && rnu_rou.ready[s];
    assign exu_prf.pr1[s] = rnu_rou.slot[s].pr1;
    assign exu_prf.pr2[s] = rnu_rou.slot[s].pr2;
  end
  always_comb begin
    enqueue_count = 0;
    for (int s = 0; s < RenameWidth; s++) enqueue_count += int'(enq_fire[s]);
  end
  function automatic logic fp_writes_fpr(input UopT u);
    if (!u.execute.fp.valid || u.trap) return 1'b0;
    if (u.execute.fp.op == `RAPT_FP_OP_ZFHMIN)
      return !((u.inst[6:0] == 7'b0100111)  // FSH
      || (u.inst[31:25] == 7'b1110010));  // FMV.X.H
    case (u.execute.fp.op)
      `RAPT_FP_OP_FMV_X_W, `RAPT_FP_OP_FMV_X_D,
      `RAPT_FP_OP_FLE_S, `RAPT_FP_OP_FLT_S, `RAPT_FP_OP_FEQ_S,
      `RAPT_FP_OP_FLE_D, `RAPT_FP_OP_FLT_D, `RAPT_FP_OP_FEQ_D,
      `RAPT_FP_OP_FCLASS_S, `RAPT_FP_OP_FCLASS_D,
      `RAPT_FP_OP_FCVT_W_S, `RAPT_FP_OP_FCVT_WU_S,
      `RAPT_FP_OP_FCVT_L_S, `RAPT_FP_OP_FCVT_LU_S,
      `RAPT_FP_OP_FCVT_W_D, `RAPT_FP_OP_FCVT_WU_D,
      `RAPT_FP_OP_FCVT_L_D, `RAPT_FP_OP_FCVT_LU_D,
      `RAPT_FP_OP_FSW, `RAPT_FP_OP_FSD: return 1'b0;
      default: return 1'b1;
    endcase
  endfunction

  function automatic logic fp_uses_rs1(input UopT u);
    if (!u.execute.fp.valid) return 1'b0;
    if (u.execute.fp.op == `RAPT_FP_OP_ZFHMIN)
      return !((u.inst[6:0] == 7'b0000111)  // FLH
      || (u.inst[6:0] == 7'b0100111)  // FSH uses fs2
      || (u.inst[31:25] == 7'b1111010));  // FMV.H.X
    case (u.execute.fp.op)
      `RAPT_FP_OP_FLW, `RAPT_FP_OP_FLD, `RAPT_FP_OP_FSW, `RAPT_FP_OP_FSD,
      `RAPT_FP_OP_FMV_W_X, `RAPT_FP_OP_FMV_D_X,
      `RAPT_FP_OP_FCVT_S_W, `RAPT_FP_OP_FCVT_S_WU,
      `RAPT_FP_OP_FCVT_S_L, `RAPT_FP_OP_FCVT_S_LU,
      `RAPT_FP_OP_FCVT_D_W, `RAPT_FP_OP_FCVT_D_WU,
      `RAPT_FP_OP_FCVT_D_L, `RAPT_FP_OP_FCVT_D_LU: return 1'b0;
      default: return 1'b1;
    endcase
  endfunction

  function automatic logic fp_uses_rs2(input UopT u);
    if (!u.execute.fp.valid) return 1'b0;
    if (u.execute.fp.op == `RAPT_FP_OP_ZFHMIN) return u.inst[6:0] == 7'b0100111;  // FSH
    case (u.execute.fp.op)
      `RAPT_FP_OP_FSW, `RAPT_FP_OP_FSD,
      `RAPT_FP_OP_FSGNJ_S, `RAPT_FP_OP_FSGNJN_S, `RAPT_FP_OP_FSGNJX_S,
      `RAPT_FP_OP_FSGNJ_D, `RAPT_FP_OP_FSGNJN_D, `RAPT_FP_OP_FSGNJX_D,
      `RAPT_FP_OP_FADD_S, `RAPT_FP_OP_FSUB_S, `RAPT_FP_OP_FMUL_S, `RAPT_FP_OP_FDIV_S,
      `RAPT_FP_OP_FADD_D, `RAPT_FP_OP_FSUB_D, `RAPT_FP_OP_FMUL_D, `RAPT_FP_OP_FDIV_D,
      `RAPT_FP_OP_FMIN_S, `RAPT_FP_OP_FMAX_S, `RAPT_FP_OP_FMIN_D, `RAPT_FP_OP_FMAX_D,
      `RAPT_FP_OP_FLE_S, `RAPT_FP_OP_FLT_S, `RAPT_FP_OP_FEQ_S,
      `RAPT_FP_OP_FLE_D, `RAPT_FP_OP_FLT_D, `RAPT_FP_OP_FEQ_D,
      `RAPT_FP_OP_FMADD_S, `RAPT_FP_OP_FMSUB_S, `RAPT_FP_OP_FNMSUB_S, `RAPT_FP_OP_FNMADD_S,
      `RAPT_FP_OP_FMADD_D, `RAPT_FP_OP_FMSUB_D, `RAPT_FP_OP_FNMSUB_D, `RAPT_FP_OP_FNMADD_D:
        return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic fp_uses_rs3(input UopT u);
    return u.execute.fp.valid && (u.execute.fp.op == `RAPT_FP_OP_FMADD_S || u.execute.fp.op ==
    `RAPT_FP_OP_FMSUB_S
    || u.execute.fp.op == `RAPT_FP_OP_FNMSUB_S || u.execute.fp.op ==
    `RAPT_FP_OP_FNMADD_S
    || u.execute.fp.op == `RAPT_FP_OP_FMADD_D || u.execute.fp.op ==
    `RAPT_FP_OP_FMSUB_D
    || u.execute.fp.op == `RAPT_FP_OP_FNMSUB_D || u.execute.fp.op == `RAPT_FP_OP_FNMADD_D);
  endfunction

  function automatic logic fp_wb_done(input logic [$clog2(ROB_SIZE)-1:0] dest,
                                      input logic [GenerationBits-1:0] generation);
    fp_wb_done = 1'b0;
    for (int p = 0; p < NumCompletions; p++)
    fp_wb_done |= completion_valid[p] && completion[p].dest == dest
        && completion[p].generation == generation;
  endfunction

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
  for (genvar r = 0; r < 32; r++) begin : g_fp_map_state
    always_ff @(posedge clock) begin
      if (reset || flush_pipe) fp_map_valid[r] <= 1'b0;
      else begin
        if (fp_map_valid[r] && fp_wb_done(fp_map[r], fp_map_generation[r])) fp_map_valid[r] <= 1'b0;
        // Younger allocation wins a same-edge map update, after completion.
        for (int s = 0; s < NumSlots; s++) begin
          if (deq_fire[s] && fp_writes_fpr(
                  allocation[s].uop
              ) && int'(allocation[s].uop.execute.fp.rd) == r) begin
            fp_map_valid[r] <= 1'b1;
            fp_map[r] <= allocation[s].dest;
            fp_map_generation[r] <= allocation[s].generation;
          end
        end
      end
    end
  end
  for (genvar e = 0; e < IIQ_SIZE; e++) begin : g_uoq_state
    always_ff @(posedge clock) begin
      if (reset || flush_pipe) begin
        uoq_valid[e] <= 1'b0;
        uoq_pv1_valid[e] <= 1'b0;
        uoq_pv2_valid[e] <= 1'b0;
      end else begin
        automatic int writer = -1;
        for (int s = 0; s < RenameWidth; s++)
        if (enq_fire[s] && int'(enq_index[s]) == e) writer = s;
        if (writer >= 0) begin
          uoq_uops[e] <= rnu_rou.slot[writer].uop;
          uoq_pr1[e] <= rnu_rou.slot[writer].pr1;
          uoq_pr2[e] <= rnu_rou.slot[writer].pr2;
          uoq_prd[e] <= rnu_rou.slot[writer].prd;
          uoq_prs[e] <= rnu_rou.slot[writer].prs;
          uoq_op1[e] <= rnu_rou.slot[writer].op1;
          uoq_op2[e] <= rnu_rou.slot[writer].op2;
          uoq_pv1[e] <= enqueue_value1[writer];
          uoq_pv2[e] <= enqueue_value2[writer];
          uoq_checkpoint_valid[e] <= rnu_rou.checkpoint_valid[writer];
          uoq_checkpoint[e] <= rnu_rou.checkpoint[writer];
          uoq_valid[e] <= 1'b1;
          uoq_pv1_valid[e] <= enqueue_ready1[writer];
          uoq_pv2_valid[e] <= enqueue_ready2[writer];
        end else begin
          for (int s = 0; s < NumSlots; s++)
          if (deq_fire[s] && int'(deq_index[s]) == e) uoq_valid[e] <= 1'b0;
          if (uoq_valid[e]) begin
            if (!uoq_pv1_valid[e] && wb_hit(uoq_pr1[e])) begin
              uoq_pv1[e] <= wb_val(uoq_pr1[e], '0);
              uoq_pv1_valid[e] <= 1'b1;
            end
            if (!uoq_pv2_valid[e] && wb_hit(uoq_pr2[e])) begin
              uoq_pv2[e] <= wb_val(uoq_pr2[e], '0);
              uoq_pv2_valid[e] <= 1'b1;
            end
          end
        end

      end
    end
  end
  // Retirement scans a contiguous prefix with explicit scalar-effect budgets.
  // Special operations retire alone; ordinary groups may contain one store and
  // one control-flow instruction, matching the physical LSU/BPU interfaces.
  for (genvar c = 0; c < CommitWidth; c++)
    assign commit_index[c] = RBits'((int'(rob_head) + c) % ROB_SIZE);
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
      commit_fire[c] = prefix && rob_entry[commit_index[c]].busy
          && rob_entry[commit_index[c]].state == rapt_pkg::ROB_WB
          && (!rob_entry[commit_index[c]].wen || (rou_lsu.sq_ready && !store_commit_valid))
          && (!control_flow(uop_pl[commit_index[c]]) || !branch_commit_valid) &&
          (!commit_special(int'(commit_index[c])) || c == 0) &&
          (!drains_sq_before_commit(uop_pl[commit_index[c]]) || rou_lsu.sq_empty);
      if (commit_fire[c]) begin
        commit_count++;
        youngest_commit = commit_index[c];
        if (rob_entry[commit_index[c]].wen) begin
          store_commit = commit_index[c];
          store_commit_valid = 1'b1;
        end
        if (control_flow(uop_pl[commit_index[c]])) begin
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
      serializing(uop_pl[h0]) && !uop_pl[h0].execute.fp.valid
      || rob_entry[h0].trap || rob_entry[h0].mispredict || uop_pl[h0].execute.memory.atomic));
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
        rob_entry[entry].busy <= 1'b0;
        rob_entry[entry].state <= rapt_pkg::ROB_CM;
        rob_checkpoint_valid[entry] <= 1'b0;
      end else begin
        if (rob_dispatch_pending[entry]) begin
          if (rob_dp_pr1[entry] != 0 && wb_hit(rob_dp_pr1[entry])) begin
            rob_dp_op1[entry] <= wb_val(rob_dp_pr1[entry], rob_dp_op1[entry]);
            rob_dp_pr1[entry] <= '0;
          end
          if (rob_dp_pr2[entry] != 0 && wb_hit(rob_dp_pr2[entry])) begin
            rob_dp_op2[entry] <= wb_val(rob_dp_pr2[entry], rob_dp_op2[entry]);
            rob_dp_pr2[entry] <= '0;
          end
          for (int d = 0; d < NumDependencies; d++)
          if (rob_dp_dep_valid[entry][d] && fp_wb_done(
                  rob_dp_dep_tag[entry][d], rob_dp_dep_generation[entry][d]
              ))
            rob_dp_dep_valid[entry][d] <= 1'b0;
        end
        for (int s = 0; s < NumSlots; s++)
        if (deq_fire[s] && int'(rob_alloc[s]) == entry) begin
          // ---- ROB entry: control + WB-mutable defaults ----
          rob_entry[entry].prd        <= allocation[s].prd;
          rob_entry[entry].prs        <= allocation[s].prs;
          rob_entry[entry].busy       <= 1'b1;
          rob_entry[entry].generation <= allocation[s].generation;
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
          rob_entry[entry].tval  <= allocation[s].uop.tval;
          rob_entry[entry].cause <= allocation[s].uop.cause;

          // Immutable metadata belongs to the ROB, not execution-unit ports.
          uop_pl[entry] <= allocation[s].uop;

          rob_dp_op1[entry] <= allocation[s].op1;
          rob_dp_op2[entry] <= allocation[s].op2;
          rob_dp_pr1[entry] <= allocation[s].pr1;
          rob_dp_pr2[entry] <= allocation[s].pr2;
          for (int d = 0; d < NumDependencies; d++) begin
            rob_dp_dep_valid[entry][d] <= allocation[s].dep_valid[d];
            rob_dp_dep_tag[entry][d] <= allocation[s].dep_tag[d];
            rob_dp_dep_generation[entry][d] <= allocation[s].dep_generation[d];
          end
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
              rob_entry[entry].mispredict <= completion[p].mispredict;
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
              rob_entry[entry].csr_wdata <= completion[p].csr_wdata;
              rob_entry[entry].fp_flags_valid <= completion[p].fp_flags_valid;
              rob_entry[entry].fp_flags <= completion[p].fp_flags;
            end
            if (completion[p].updates.exception) begin
              // A faulting producer must not update the architectural map.
              // This includes FP-to-GPR operations, not just memory faults.
              if (completion[p].trap) rob_entry[entry].rd <= '0;
              rob_entry[entry].trap <= completion[p].trap;
              rob_entry[entry].tval <= completion[p].tval;
              rob_entry[entry].cause <= completion[p].cause;
            end
          end
        end


        for (int c = 0; c < CommitWidth; c++)
        if (commit_fire[c] && int'(commit_index[c]) == entry) begin
          rob_entry[entry].busy <= 1'b0;
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
      rou_cmu.slot[c].atomic = uop_pl[commit_index[c]].execute.memory.atomic;
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
  assign rou_cmu.atomic_sc = uop_pl[h0].execute.memory.atomic && uop_pl[h0].execute.int_op.alu == `RAPT_ATO_SC__;
  assign rou_cmu.fence_i = head0_valid && uop_pl[h0].execute.sys.fence_i;
  assign rou_cmu.fence_time = head0_valid && uop_pl[h0].execute.sys.fence;
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
  assign fp_dirty_from_h0 = head0_valid && uop_pl[h0].execute.fp.valid && !rob_entry[h0].trap
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
  assign rou_csr.pc = recieved_trap ? trap_pc : uop_pl[h0].pc;
  assign rou_csr.csr_wen = !recieved_trap && !commit_trap && uop_pl[h0].execute.sys.valid && rob_entry[h0].csr_wen;
  assign rou_csr.csr_wdata = rob_entry[h0].csr_wdata;
  assign rou_csr.csr_addr = uop_pl[h0].imm[11:0];
  assign rou_csr.fp_flags_valid = !recieved_trap && !commit_trap && rob_entry[h0].fp_flags_valid;
  assign rou_csr.fp_flags = rob_entry[h0].fp_flags;
  assign rou_csr.fp_dirty = !recieved_trap && !commit_trap && fp_dirty_from_h0;
  assign rou_csr.ecall = !recieved_trap && !commit_trap && uop_pl[h0].execute.sys.ecall;
  assign rou_csr.ebreak = !recieved_trap && !commit_trap && uop_pl[h0].execute.sys.ebreak;
  assign rou_csr.mret = !recieved_trap && !commit_trap && uop_pl[h0].execute.sys.mret;
  assign rou_csr.sret = !recieved_trap && !commit_trap && uop_pl[h0].execute.sys.sret;
  assign rou_csr.trap = recieved_trap || commit_trap;
  assign rou_csr.tval = recieved_trap ? '0 : rob_entry[h0].tval;
  assign rou_csr.cause = recieved_trap ? trap_cause : rob_entry[h0].cause;
  assign rou_csr.valid = recieved_trap || (commit_fire[0] &&
      (uop_pl[h0].execute.sys.valid || commit_trap || rob_entry[h0].fp_flags_valid || fp_dirty_from_h0));
  // Faulting instructions still leave the ROB and deliver their exception,
  // but do not retire architecturally. commit_special confines these events
  // to a single head entry; interrupts already suppress commit_count.
  assign rou_csr.retire_count = (commit_fire[0] && (commit_trap
      || uop_pl[h0].execute.sys.ecall || uop_pl[h0].execute.sys.ebreak))
      ? '0 : RetireBits'(commit_count);
  assign rou_lsu.store = store_commit_valid && !rob_entry[store_commit].trap;
  assign rou_lsu.dest = store_commit;
  assign rou_lsu.sq_vaddr = rob_entry[store_commit].tval;
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
  always_ff @(posedge clock) begin
    pmu_cf_head_busy <= !reset && rob_entry[h0].busy;
    pmu_cf_head_waiting <= !reset && rob_entry[h0].busy && rob_entry[h0].state != rapt_pkg::ROB_WB;
    pmu_cf_head_domain <= reset ? '0 : 32'(uop_pl[h0].schedule.domain);
    for (int e = 0; e < ROB_SIZE; e++) begin
      automatic logic [4:0] events;
      events = '0;
      if (!reset) begin
        if (!flush_pipe) begin
          for (int s = 0; s < NumSlots; s++)
          if (deq_fire[s] && int'(rob_alloc[s]) == e && control_flow(uoq_uops[deq_index[s]]))
            events |= 5'(rapt_pkg::CfAllocate);
          for (int p = 0; p < NumCompletions; p++)
          if (completion_valid[p] && int'(completion[p].dest) == e
              && completion[p].updates.control_flow && control_flow(
                  uop_pl[e]
              )) begin
            events |= 5'(rapt_pkg::CfResolve);
            if (completion[p].mispredict && !completion[p].trap)
              events |= 5'(rapt_pkg::CfMispredict);
          end
        end
        for (int c = 0; c < CommitWidth; c++)
        if (commit_fire[c] && int'(commit_index[c]) == e && control_flow(uop_pl[e])) begin
          events |= 5'(rapt_pkg::CfRetire);
          if (rob_entry[e].trap) events |= 5'(rapt_pkg::CfTrap);
        end
      end
      pmu_cf_events[e] <= events;
    end
  end
`endif
  assign pmu_branch_flush = head0_valid && rob_entry[h0].mispredict && control_flow(uop_pl[h0]);
  assign pmu_nonbranch_flush = flush_pipe && !pmu_branch_flush;
  assign pmu_sq_stall = rob_entry[h0].busy && rob_entry[h0].state == rapt_pkg::ROB_WB
      && rob_entry[h0].wen && !rou_lsu.sq_ready;
`ifdef RAPT_DBG_ILA
  // Preserve the existing FPGA hang-capture probes across the width refactor.
  (* mark_debug = "true" *) logic dbg_hang;
  (* mark_debug = "true" *) logic dbg_commit_fire;
  (* mark_debug = "true" *) logic [XLEN-1:0] dbg_commit_pc;
  assign dbg_commit_fire = commit_fire_o;
  assign dbg_commit_pc = uop_pl[h0].pc;
  always_ff @(posedge clock) begin
    if (reset) dbg_hang <= 1'b0;
    else
      for (int c = 0; c < CommitWidth; c++)
      if (commit_fire[c] && uop_pl[commit_index[c]].pc == XLEN'(64'hffffffff80c321c8))
        dbg_hang <= 1'b1;
  end
`endif
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
    `RAPT_SVA_IMPLY(clock, reset, ROB_MEMORY_FENCE_DRAINS_SQ,
                    commit_fire[c] && drains_sq_before_commit(uop_pl[commit_index[c]]),
                    rou_lsu.sq_empty)
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
