`include "rapt.svh"
`include "rapt_if.svh"

// Data-capture issue queue. Dispatch slots express program order at allocation;
// execution ports have independent availability and capability masks. A uop
// has no persistent association with its original dispatch slot.
// Payload transport is opaque; only register and completion dependencies are
// interpreted here. Selection and execution remain combinational in this core.
module rapt_iq #(
    parameter rapt_pkg::core_config_t Cfg             = rapt_pkg::CoreConfig,
    parameter type                    IssueT          = rapt_pkg::issue_packet_t,
    parameter type                    SlotT           = rapt_pkg::dispatch_slot_t,
    parameter int unsigned            NumSlots        = Cfg.dispatch_width,
    parameter int unsigned            NumDependencies = Cfg.completion_dependencies,
    parameter type                    UopT            = rapt_pkg::uop_t,
    parameter int unsigned            NumCompletions  = Cfg.completion_ports,
    parameter type                    CompletionT     = rapt_pkg::completion_t,
    parameter unsigned                IQ_SIZE         = 8,
    parameter int unsigned            NumIssuePorts   = 1,
    parameter bit                     IN_ORDER_ISSUE  = 1'b0,
    parameter bit                     RebalancePorts  = Cfg.issue_rebalance,
    parameter bit                     ReclaimOnIssue  = Cfg.iq_reclaim_on_issue,
    parameter unsigned                ROB_SIZE        = Cfg.rob_entries,
    parameter unsigned                PLEN            = rapt_pkg::index_bits(Cfg.phys_regs),
    parameter unsigned                RLEN            = rapt_pkg::index_bits(Cfg.arch_regs),
    parameter unsigned                XLEN            = Cfg.xlen
) (
    input CompletionT completion[NumCompletions],
    input clock,
    input reset,
    // One-cycle, producer-validated recovery event. Ages use the ROB ring,
    // not per-slot generation ordering. No same-cycle cancel-to-free bypass.
    input logic cancel_valid,
    input logic [$clog2(ROB_SIZE)-1:0] cancel_head,
    cancel_owner,

    cmu_bcast_if.in cmu_bcast,

    // Dispatch source + arbitration (EXU router drives accepts)
    input SlotT dispatch[NumSlots],
    dpu_iq_if.rs disp,

    // Slow CDB wakeup sources (all value-producing pipes, incl. our own)

    // Fast load-use tag wakeup
    load_fast_if.sink load_fast,

    // Execution availability per attached function-unit port.
    input logic [NumIssuePorts-1:0] issue_enable,

    // Issue ports: combinational view of the oldest ready entries.
    // op1/op2 have the fast-confirm MEM-result bypass already applied.
    output IssueT issue[NumIssuePorts],

    // Occupancy (PMU aggregation) + PMU full pulse
    output logic [$clog2(IQ_SIZE):0] occ_o,
    /* verilator lint_off UNUSEDSIGNAL */
    output logic pmu_iq_full
    /* verilator lint_on UNUSEDSIGNAL */
);
  localparam unsigned IQLen = (IQ_SIZE > 1) ? $clog2(IQ_SIZE) : 1;
  localparam unsigned ROBLen = $clog2(ROB_SIZE);
  localparam unsigned GenBits = $bits(dispatch[0].generation);

  UopT iq_uop[IQ_SIZE];
`ifdef VERILATOR
  // Stable, unpacked debug view for the simulator's hang diagnostics. This
  // is a read-only projection, not separately stored execution payload.
  logic [XLEN-1:0] iq_pc[IQ_SIZE];
  for (genvar i = 0; i < IQ_SIZE; i++) assign iq_pc[i] = iq_uop[i].pc;
`endif

  // Reject inconsistent type/value configurations rather than truncating tags
  // or execution payloads silently at a specialization boundary.
  if (!(IQ_SIZE > 0 && IQ_SIZE == disp.RS_SIZE)) begin : g_invalid_capacity
    $error(
        "Invalid rapt_iq configuration: capacity must be positive and match allocation interface"
    );
  end
  if (!(NumSlots > 0 && NumSlots == disp.Width)) begin : g_invalid_config_0
    $error("IQ allocation width must match the selected frontend profile");
  end
  if (!(NumIssuePorts > 0 && NumIssuePorts <= $bits(
          iq_uop[0].schedule.issue_ports
      ))) begin : g_invalid_config_1
    $error("IQ execution-port mask is too narrow");
  end
  if (!($bits(
          dispatch[0].uop
      ) == $bits(
          UopT
      ) && $bits(
          issue[0].uop
      ) == $bits(
          UopT
      ))) begin : g_invalid_config_2
    $error("IQ uop types do not agree");
  end
  if (!($bits(
          completion[0].result
      ) == XLEN && $bits(
          dispatch[0].op1
      ) == XLEN)) begin : g_invalid_config_3
    $error("IQ operand width does not agree with configuration");
  end
  if (!($bits(
          completion[0].prd
      ) == PLEN && $bits(
          dispatch[0].prd
      ) == PLEN && $bits(
          completion[0].dest
      ) == ROBLen)) begin : g_invalid_config_4
    $error("IQ tag widths do not agree with configuration");
  end
  if (!($bits(dispatch[0].dep_valid) == NumDependencies)) begin : g_invalid_config_5
    $error("IQ completion-dependency count mismatch");
  end

  // === IQ state ===
  logic [IQ_SIZE-1:0]              iq_valid;
  logic [   XLEN-1:0]              iq_vj                  [        IQ_SIZE];
  logic [   XLEN-1:0]              iq_vk                  [        IQ_SIZE];
  logic [ ROBLen-1:0]              iq_dest                [        IQ_SIZE];
  logic [GenBits-1:0]              iq_generation          [        IQ_SIZE];
  logic [IQ_SIZE-1:0] cancelled;
  function automatic logic younger_than_cancel(input logic [ROBLen-1:0] dest);
    logic older;
    older = ((dest < cancel_head) == (cancel_owner < cancel_head))
        ? dest < cancel_owner : dest >= cancel_head;
    return cancel_valid && dest != cancel_owner && !older;
  endfunction
  for (genvar e = 0; e < IQ_SIZE; e++) begin : g_cancel
    assign cancelled[e] = iq_valid[e] && younger_than_cancel(iq_dest[e]);
  end
  logic [   PLEN-1:0]              iq_pr1                 [        IQ_SIZE];
  logic [   PLEN-1:0]              iq_pr2                 [        IQ_SIZE];
  logic [IQ_SIZE-1:0]              iq_pr1_busy;
  logic [IQ_SIZE-1:0]              iq_pr2_busy;
  logic [IQ_SIZE-1:0]              iq_pr1_fast;
  logic [IQ_SIZE-1:0]              iq_pr2_fast;
  // A fast-wake identity is small per-entry control state with concurrent
  // reads from all selector lanes, not an inferred single-port data memory.
  logic [IQ_SIZE-1:0][ ROBLen-1:0] iq_pr1_fast_dest;
  logic [IQ_SIZE-1:0][ ROBLen-1:0] iq_pr2_fast_dest;
  logic [IQ_SIZE-1:0][GenBits-1:0] iq_pr1_fast_generation;
  logic [IQ_SIZE-1:0][GenBits-1:0] iq_pr2_fast_generation;
  logic [   PLEN-1:0]              iq_prd                 [        IQ_SIZE];
  logic [IQ_SIZE-1:0]              iq_dep_busy            [NumDependencies];
  logic [ ROBLen-1:0]              iq_dep_tag             [NumDependencies] [IQ_SIZE];
  logic [GenBits-1:0]              iq_dep_generation      [NumDependencies] [IQ_SIZE];
  // === Unified CDB view for operand wakeup ===
  // All sources use one typed completion array.
  localparam int unsigned NWB = NumCompletions;
  logic            wb_valid [NWB];
  logic [PLEN-1:0] wb_prd   [NWB];
  logic [XLEN-1:0] wb_result[NWB];
  for (genvar p = 0; p < NWB; p++) begin : g_completion_view
    assign wb_valid[p] = completion[p].valid;
    assign wb_prd[p] = completion[p].prd;
    assign wb_result[p] = completion[p].result;
  end

  function automatic logic wb_hit(input logic [PLEN-1:0] pr);
    wb_hit = 1'b0;
    for (int p = 0; p < NWB; p++) begin
      wb_hit |= (pr != '0) && wb_valid[p] && (wb_prd[p] == pr);
    end
  endfunction

  function automatic logic completion_hit(input logic [ROBLen-1:0] dep,
                                          input logic [GenBits-1:0] generation);
    completion_hit = 1'b0;
    for (int p = 0; p < NumCompletions; p++)
    completion_hit |= completion[p].valid && completion[p].dest == dep
        && completion[p].generation == generation;
  endfunction

  function automatic logic [XLEN-1:0] wb_val(input logic [PLEN-1:0] pr,
                                             input logic [XLEN-1:0] dflt);
    wb_val = dflt;
    for (int p = NWB - 1; p >= 0; p--) begin
      if ((pr != '0) && wb_valid[p] && (wb_prd[p] == pr)) wb_val = wb_result[p];
    end
  endfunction

  // === Fast load-use helpers (same protocol as the former RS) ===
  function automatic logic fast_wake_match(input logic [PLEN-1:0] pr);
    return (pr != '0) && load_fast.valid && !load_fast.rebusy && (load_fast.prd == pr);
  endfunction

  function automatic logic fast_confirm_match(input logic is_fast, input logic [PLEN-1:0] pr,
                                              input logic [ROBLen-1:0] dest,
                                              input logic [GenBits-1:0] generation);
    return is_fast && load_fast.confirmed && load_fast.confirmed_prd == pr
        && load_fast.confirmed_dest == dest
        && load_fast.confirmed_generation == generation;
  endfunction

  function automatic logic [XLEN-1:0] fast_confirm_value(input logic [PLEN-1:0] pr,
                                                         input logic [ROBLen-1:0] dest,
                                                         input logic [GenBits-1:0] generation);
    return load_fast.confirmed_prd == pr && load_fast.confirmed_dest == dest
        && load_fast.confirmed_generation == generation ? load_fast.result : '0;
  endfunction

  function automatic logic fast_rebusy_match(input logic is_fast, input logic [PLEN-1:0] pr,
                                             input logic [ROBLen-1:0] dest,
                                             input logic [GenBits-1:0] generation);
    return is_fast && load_fast.valid && load_fast.rebusy && load_fast.prd == pr
        && load_fast.dest == dest && load_fast.generation == generation;
  endfunction

  function automatic logic dependencies_busy(input int entry);
    dependencies_busy = 1'b0;
    for (int d = 0; d < NumDependencies; d++) dependencies_busy |= iq_dep_busy[d][entry];
  endfunction

  // === Per-entry wakeup / eligibility vectors ===
  logic [IQ_SIZE-1:0] pr1_fast_confirm, pr2_fast_confirm;
  logic [IQ_SIZE-1:0] pr1_fast_rebusy, pr2_fast_rebusy;
  logic [IQ_SIZE-1:0] pr1_fast_wake, pr2_fast_wake;
  logic [IQ_SIZE-1:0] pr1_slow_hit, pr2_slow_hit;
  logic [XLEN-1:0] pr1_slow_val[IQ_SIZE];
  logic [XLEN-1:0] pr2_slow_val[IQ_SIZE];
  logic [IQ_SIZE-1:0] pr_ready;
  logic [IQ_SIZE-1:0] iq_free_vec, iq_ready_vec;

  always_comb begin
    for (int i = 0; i < IQ_SIZE; i++) begin
      pr1_fast_confirm[i] = fast_confirm_match(iq_pr1_fast[i], iq_pr1[i], iq_pr1_fast_dest[i],
                                               iq_pr1_fast_generation[i]);
      pr2_fast_confirm[i] = fast_confirm_match(iq_pr2_fast[i], iq_pr2[i], iq_pr2_fast_dest[i],
                                               iq_pr2_fast_generation[i]);
      pr1_fast_rebusy[i] = fast_rebusy_match(iq_pr1_fast[i], iq_pr1[i], iq_pr1_fast_dest[i],
                                             iq_pr1_fast_generation[i]);
      pr2_fast_rebusy[i] = fast_rebusy_match(iq_pr2_fast[i], iq_pr2[i], iq_pr2_fast_dest[i],
                                             iq_pr2_fast_generation[i]);
      pr1_fast_wake[i] = iq_pr1_busy[i] && fast_wake_match(iq_pr1[i]);
      pr2_fast_wake[i] = iq_pr2_busy[i] && fast_wake_match(iq_pr2[i]);
      pr1_slow_hit[i] = iq_pr1_busy[i] && wb_hit(iq_pr1[i]);
      pr2_slow_hit[i] = iq_pr2_busy[i] && wb_hit(iq_pr2[i]);
      pr1_slow_val[i] = wb_val(iq_pr1[i], iq_vj[i]);
      pr2_slow_val[i] = wb_val(iq_pr2[i], iq_vk[i]);
      pr_ready[i] = ~(iq_pr1_busy[i] | iq_pr2_busy[i]) && !dependencies_busy(i) &&
          (!iq_pr1_fast[i] || pr1_fast_confirm[i]) && (!iq_pr2_fast[i] || pr2_fast_confirm[i]);
      iq_free_vec[i] = !iq_valid[i];
      iq_ready_vec[i] = iq_valid[i] && pr_ready[i];
    end
  end

  int alloc_slot[IQ_SIZE];
  logic [IQ_SIZE-1:0] claimed, baseline_claimed, select_valid;
  always_comb begin
    automatic logic [IQ_SIZE-1:0] remaining;
    automatic logic [IQ_SIZE-1:0] reclaimed;
    remaining = ~iq_valid;
    reclaimed = ReclaimOnIssue ? claimed & iq_valid : '0;
    for (int s = 0; s < NumSlots; s++) begin
      disp.free_found[s] = 1'b0;
      disp.free_idx[s]   = '0;
      for (int e = 0; e < IQ_SIZE; e++)
      if (!disp.free_found[s] && remaining[e]) begin
        disp.free_found[s] = 1'b1;
        disp.free_idx[s] = IQLen'(e);
        remaining[e] = 1'b0;
      end
      // Prefer already-free entries, preserving old allocation identities
      // unless an issuing entry is actually needed. The old payload is read
      // before the edge; allocation has priority over issue-clear at the edge.
      for (int e = 0; e < IQ_SIZE; e++)
      if (!disp.free_found[s] && reclaimed[e]) begin
        disp.free_found[s] = 1'b1;
        disp.free_idx[s] = IQLen'(e);
        reclaimed[e] = 1'b0;
      end
    end
  end
  for (genvar s = 0; s < NumSlots; s++) begin : g_alloc_contract
    `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, QUEUE_ALLOC_FREE, disp.accept[s],
                    !iq_valid[disp.rs_idx[s]] || (ReclaimOnIssue && claimed[disp.rs_idx[s]]))
    for (genvar t = s + 1; t < NumSlots; t++) begin : g_unique
      `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, QUEUE_ALLOC_UNIQUE,
                      disp.accept[s] && disp.accept[t], disp.rs_idx[s] != disp.rs_idx[t])
    end
  end
  always_comb begin
    for (int e = 0; e < IQ_SIZE; e++) begin
      alloc_slot[e] = -1;
      for (int s = 0; s < NumSlots; s++)
      if (disp.accept[s] && int'(disp.rs_idx[s]) == e) alloc_slot[e] = s;
    end
  end
  // === Age matrix (strict partial order; same pattern as MULDIV/former RS) ===
  logic [IQ_SIZE-1:0] age_mat[IQ_SIZE];

  function automatic logic [IQLen-1:0] oh2bin(input logic [IQ_SIZE-1:0] oh);
    logic [IQLen-1:0] bin;
    bin = '0;
    for (int i = 0; i < IQ_SIZE; i++) begin
      if (oh[i]) bin = bin | i[IQLen-1:0];
    end
    return bin;
  endfunction

  // Selection owns only identities. Data capture, wakeup and payload muxing
  // remain local to IQ, so arbitration policy can evolve independently.
  logic [IQ_SIZE-1:0] selected[NumIssuePorts];
  logic [NumIssuePorts-1:0] port_mask[IQ_SIZE];
  for (genvar e = 0; e < IQ_SIZE; e++)
    assign port_mask[e] = NumIssuePorts'(iq_uop[e].schedule.issue_ports);
  assign select_valid = iq_valid & ~cancelled & {IQ_SIZE{!reset && !cmu_bcast.flush_pipe}};
  rapt_issue_select #(
      .Entries(IQ_SIZE),
      .Ports(NumIssuePorts),
      .InOrder(IN_ORDER_ISSUE),
      .Rebalance(RebalancePorts)
  ) selector (
      .valid(select_valid),
      .ready(pr_ready),
      .older(age_mat),
      .compatible(port_mask),
      .enabled(issue_enable),
      .selected(selected),
      .claimed(claimed),
      .baseline_claimed(baseline_claimed)
  );
  // Registered observations share the issue edge, never the next-cycle view.
`ifndef SYNTHESIS
  // Mutually exclusive observation of the FIRST allocation token only.
  // 0 available; 1 reset/flush; 2 all residents cancelled; 3 no ready survivor;
  // 4 no ready survivor on an enabled compatible port; 5 selection policy;
  // 6 issued but same-cycle reclaim disabled. These are not lost-IPC estimates.
  logic [2:0] pmu_capacity_reason, capacity_reason;
  logic capacity_ready_compatible;
  always_comb begin
    capacity_ready_compatible = 1'b0;
    for (int e = 0; e < IQ_SIZE; e++)
    capacity_ready_compatible |= select_valid[e] && pr_ready[e] && (|(port_mask[e] & issue_enable));
    capacity_reason = 0;
    if (!disp.free_found[0]) begin
      if (reset || cmu_bcast.flush_pipe) capacity_reason = 1;
      else if (!(|select_valid)) capacity_reason = 2;
      else if (!(|(select_valid & pr_ready))) capacity_reason = 3;
      else if (!capacity_ready_compatible) capacity_reason = 4;
      else if (|claimed) capacity_reason = 6;
      else capacity_reason = 5;
    end
  end
  always_ff @(posedge clock) pmu_capacity_reason <= capacity_reason;
`endif
  logic [31:0] pmu_select_ready, pmu_select_issued, pmu_select_gain, pmu_reclaim_allocations;
  int unsigned reclaim_allocations;
  always_comb begin
    reclaim_allocations = 0;
    for (int s = 0; s < NumSlots; s++)
    reclaim_allocations += int'(disp.accept[s] && iq_valid[disp.rs_idx[s]]);
  end
  always_ff @(posedge clock) begin
    pmu_select_ready <= 32'($countones(select_valid & pr_ready));
    pmu_select_issued <= 32'($countones(claimed));
    pmu_select_gain <= 32'($countones(claimed) - $countones(baseline_claimed));
    pmu_reclaim_allocations <= reset || cmu_bcast.flush_pipe ? 0 : reclaim_allocations;
  end
  // Keep stored payload selection separate from fast-confirm bypass. The
  // latter still checks the selected physical/ROB/generation identity below.
  localparam int StoredPayloadBits = $bits(UopT) + 2 * XLEN + ROBLen + GenBits + PLEN;
  logic [StoredPayloadBits-1:0] stored_payload[IQ_SIZE];
  for (genvar e = 0; e < IQ_SIZE; e++) begin : g_stored_payload
    assign stored_payload[e] = {
      iq_uop[e], iq_vj[e], iq_vk[e], iq_dest[e], iq_generation[e], iq_prd[e]
    };
  end
  for (genvar p = 0; p < NumIssuePorts; p++) begin : g_issue
    logic [IQLen-1:0] index;
    logic [IQ_SIZE-1:0] data_select;
    logic [StoredPayloadBits-1:0] payload;
    logic [XLEN-1:0] stored_op1, stored_op2;
    if (IN_ORDER_ISSUE && NumIssuePorts == 1) begin : g_ordered_head_data
      // A single ordered port can only issue the oldest surviving resident.
      // Preselect its payload independently of wakeup/port readiness. Otherwise
      // a late load confirmation selects the entire uop, including FPR read
      // addresses, before the floating-point first-stage arithmetic can start.
      // Validity still comes from the unchanged issue selector. Idle data is
      // the waiting head (or slot zero when empty), never an accepted transfer.
      // Reset/flush suppress transfers, not this unqualified data view. Their
      // combinational fanout must not select FPR addresses ahead of arithmetic.
      logic [IQ_SIZE-1:0] head, resident;
      assign resident = iq_valid & ~cancelled;
      for (genvar e = 0; e < IQ_SIZE; e++) begin : g_head
        logic [IQ_SIZE-1:0] predecessors;
        for (genvar o = 0; o < IQ_SIZE; o++)
          assign predecessors[o] = o != e && age_mat[o][e] && resident[o];
        assign head[e] = resident[e] && !(|predecessors);
      end
      assign data_select = (|head) ? head : IQ_SIZE'(1);
      `RAPT_SVA_IMPLY(clock, reset, IQ_ORDERED_HEAD_PAYLOAD, issue[p].valid,
                      data_select == selected[p])
    end else begin : g_selected_data
      // Unordered/multiport selection still owns the payload identity.
      assign data_select = (|selected[p]) ? selected[p] : IQ_SIZE'(1);
    end
    assign index = oh2bin(data_select);
    for (genvar b = 0; b < StoredPayloadBits; b++) begin : g_payload_bit
      logic [IQ_SIZE-1:0] column;
      for (genvar e = 0; e < IQ_SIZE; e++) assign column[e] = stored_payload[e][b];
      assign payload[b] = |(data_select & column);
    end
    assign {issue[p].uop, stored_op1, stored_op2, issue[p].dest,
        issue[p].generation, issue[p].prd} = payload;
    assign issue[p].valid = |selected[p];
    assign issue[p].op1 = pr1_fast_confirm[index] ? fast_confirm_value(
        iq_pr1[index], iq_pr1_fast_dest[index], iq_pr1_fast_generation[index]
    ) : stored_op1;
    assign issue[p].op2 = pr2_fast_confirm[index] ? fast_confirm_value(
        iq_pr2[index], iq_pr2_fast_dest[index], iq_pr2_fast_generation[index]
    ) : stored_op2;
    `RAPT_SVA_IMPLY(clock, reset, IQ_SELECT_ONEHOT, issue[p].valid, $onehot(selected[p]))
    for (genvar q = p + 1; q < NumIssuePorts; q++) begin : g_disjoint
      `RAPT_SVA(clock, reset, IQ_SELECT_DISJOINT, (selected[p] & selected[q]) == '0)
    end
  end

  // === Occupancy for router load balancing ===
  always_comb begin
    occ_o = '0;
    for (int i = 0; i < IQ_SIZE; i++) occ_o += ($clog2(IQ_SIZE) + 1)'(iq_valid[i]);
  end

  // === Sequential: alloc / wakeup / issue-clear ===
  logic iq_full_r;

  // Keep the wide operand data arrays on a data-only write cone.  In
  // particular, fast rebusy/wake and issue-clear do not change operand data;
  // folding those state-only events into this block makes FPGA synthesis put
  // the LSU arbitration path on every iq_vj/iq_vk clock-enable pin.
  for (genvar i = 0; i < IQ_SIZE; i++) begin : g_operand_state
    always_ff @(posedge clock) begin
      if (!(reset || cmu_bcast.flush_pipe)) begin
        if (alloc_slot[i] >= 0) begin
          iq_vj[i] <= dispatch[alloc_slot[i]].op1;
          iq_vk[i] <= dispatch[alloc_slot[i]].op2;
        end else if (iq_valid[i]) begin
          // A confirmed speculative wake has priority over an ordinary CDB
          // hit, matching the operand-state machine below.  Rename guarantees
          // that both cannot name different producers for the same operand.
          if (pr1_fast_confirm[i])
            iq_vj[i] <= fast_confirm_value(
                iq_pr1[i], iq_pr1_fast_dest[i], iq_pr1_fast_generation[i]
            );
          else if (pr1_slow_hit[i]) iq_vj[i] <= pr1_slow_val[i];
          if (pr2_fast_confirm[i])
            iq_vk[i] <= fast_confirm_value(
                iq_pr2[i], iq_pr2_fast_dest[i], iq_pr2_fast_generation[i]
            );
          else if (pr2_slow_hit[i]) iq_vk[i] <= pr2_slow_val[i];
        end
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) iq_full_r <= 1'b0;
    else iq_full_r <= &iq_valid;
  end

  // One writer per scheduler entry. Payload stays unreset and is observable
  // only while the owner's valid bit is set.
  for (genvar i = 0; i < IQ_SIZE; i++) begin : g_entry_state
    always_ff @(posedge clock) begin
      if (reset || cmu_bcast.flush_pipe) iq_valid[i] <= 1'b0;
      else begin
        if (alloc_slot[i] >= 0) begin
          // Allocation owns the new identity, even when the former resident
          // is cancelled. A younger incoming is accepted-and-discarded.
          iq_valid[i] <= !younger_than_cancel(dispatch[alloc_slot[i]].dest);
          iq_uop[i] <= dispatch[alloc_slot[i]].uop;

          iq_dest[i] <= dispatch[alloc_slot[i]].dest;
          iq_generation[i] <= dispatch[alloc_slot[i]].generation;
          iq_pr1[i] <= dispatch[alloc_slot[i]].pr1;
          iq_pr2[i] <= dispatch[alloc_slot[i]].pr2;
          iq_pr1_busy[i] <= (|dispatch[alloc_slot[i]].pr1) && !fast_wake_match(
              dispatch[alloc_slot[i]].pr1
          );
          iq_pr2_busy[i] <= (|dispatch[alloc_slot[i]].pr2) && !fast_wake_match(
              dispatch[alloc_slot[i]].pr2
          );
          iq_pr1_fast[i] <= fast_wake_match(dispatch[alloc_slot[i]].pr1);
          iq_pr2_fast[i] <= fast_wake_match(dispatch[alloc_slot[i]].pr2);
          iq_pr1_fast_dest[i] <= load_fast.dest;
          iq_pr2_fast_dest[i] <= load_fast.dest;
          iq_pr1_fast_generation[i] <= load_fast.generation;
          iq_pr2_fast_generation[i] <= load_fast.generation;
          iq_prd[i] <= dispatch[alloc_slot[i]].prd;

          for (int d = 0; d < NumDependencies; d++) begin
            iq_dep_busy[d][i] <= dispatch[alloc_slot[i]].dep_valid[d] && !completion_hit(
                dispatch[alloc_slot[i]].dep_tag[d], dispatch[alloc_slot[i]].dep_generation[d]
            );
            iq_dep_tag[d][i] <= dispatch[alloc_slot[i]].dep_tag[d];
            iq_dep_generation[d][i] <= dispatch[alloc_slot[i]].dep_generation[d];
          end

        end else if (cancelled[i]) begin
          // Payload/wakeup metadata remain don't-care while invalid. Neither
          // a late completion nor a fast confirmation can recreate validity.
          iq_valid[i] <= 1'b0;
        end else if (iq_valid[i] && pr_ready[i]) begin
          // Fast-confirm data capture for an entry that became fully ready
          // this cycle (woken between ready computation and the clock edge).
          if (pr1_fast_confirm[i]) begin
            iq_pr1_fast[i] <= 1'b0;
          end
          if (pr2_fast_confirm[i]) begin
            iq_pr2_fast[i] <= 1'b0;
          end
          // Issue clear: entries selected on either port free this cycle
          // (dedicated WB ports, never back-pressured).  Only the valid bit
          // and the operand-tracking bits are cleared; payload arrays keep
          // their old values (don't-care once invalid).
          if (claimed[i]) begin
            iq_valid[i]    <= 1'b0;
            iq_pr1_busy[i] <= 1'b0;
            iq_pr2_busy[i] <= 1'b0;
            iq_pr1_fast[i] <= 1'b0;
            iq_pr2_fast[i] <= 1'b0;

            for (int d = 0; d < NumDependencies; d++) iq_dep_busy[d][i] <= 1'b0;

          end
        end else if (iq_valid[i]) begin
          // Operand wakeup. Per tag, fast-wake and slow-hit are mutually
          // exclusive (unique producer), so arm order beyond the fast
          // confirm/rebusy pair is don't-care.
          if (pr1_fast_confirm[i]) begin
            iq_pr1_busy[i] <= 1'b0;
            iq_pr1_fast[i] <= 1'b0;
          end else if (pr1_fast_rebusy[i]) begin
            iq_pr1_busy[i] <= 1'b1;
            iq_pr1_fast[i] <= 1'b0;
          end else if (pr1_slow_hit[i]) begin
            iq_pr1_busy[i] <= 1'b0;
            iq_pr1_fast[i] <= 1'b0;
          end else if (pr1_fast_wake[i]) begin
            iq_pr1_busy[i] <= 1'b0;
            iq_pr1_fast[i] <= 1'b1;
            iq_pr1_fast_dest[i] <= load_fast.dest;
            iq_pr1_fast_generation[i] <= load_fast.generation;
          end
          for (int d = 0; d < NumDependencies; d++)
          if (iq_dep_busy[d][i] && completion_hit(iq_dep_tag[d][i], iq_dep_generation[d][i]))
            iq_dep_busy[d][i] <= 1'b0;
          if (pr2_fast_confirm[i]) begin
            iq_pr2_busy[i] <= 1'b0;
            iq_pr2_fast[i] <= 1'b0;
          end else if (pr2_fast_rebusy[i]) begin
            iq_pr2_busy[i] <= 1'b1;
            iq_pr2_fast[i] <= 1'b0;
          end else if (pr2_slow_hit[i]) begin
            iq_pr2_busy[i] <= 1'b0;
            iq_pr2_fast[i] <= 1'b0;
          end else if (pr2_fast_wake[i]) begin
            iq_pr2_busy[i] <= 1'b0;
            iq_pr2_fast[i] <= 1'b1;
            iq_pr2_fast_dest[i] <= load_fast.dest;
            iq_pr2_fast_generation[i] <= load_fast.generation;
          end
        end

      end
    end
    // An age row is independent of other rows at the clock edge.
    always_ff @(posedge clock) begin
      if (!(reset || cmu_bcast.flush_pipe)) begin
        // New entries are younger than residents and ordered by dispatch slot.
        for (int j = 0; j < IQ_SIZE; j++) begin
          if (alloc_slot[i] >= 0 && alloc_slot[j] >= 0)
            age_mat[i][j] <= alloc_slot[i] < alloc_slot[j];
          else if (alloc_slot[i] >= 0) age_mat[i][j] <= 1'b0;
          else if (alloc_slot[j] >= 0) age_mat[i][j] <= iq_valid[i];
        end

      end
    end
  end

  // PMU: one-cycle pulse on IQ full rising edge
  assign pmu_iq_full = (&iq_valid) && !iq_full_r;

  // ==========================================================================
  //  Assertions (enable with +define+RAPT_ASSERT_EN)
  // ==========================================================================

  // HANDSHAKE: the router must never allocate into an occupied slot.

endmodule
