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
    parameter int unsigned            LastIssuePort   = NumIssuePorts - 1,
    parameter bit                     IN_ORDER_ISSUE  = 1'b0,
    parameter bit                     RebalancePorts  = 1'b0,
    parameter bit                     UniformSimplePorts = 1'b0,
    parameter bit                     ReclaimOnIssue  = 1'b0,
    parameter bit                     ThirdOperand   = 1'b0,
    parameter bit                     FilterResources = 1'b0,
    parameter int unsigned            NumResources = 1,
    // Same-cycle CDB operand wake. Mask must exclude any completion port
    // this queue produces combinationally (BRQ skips the branch port).
    parameter bit                     ComboCdbWake    = 1'b0,
    parameter bit                     ComboThirdWake  = 1'b0,
    // The consumer registers selection before reading/executing operands.
    parameter bit                     ReadAfterSelect = 1'b0,
    // IssueT supplies entry_index when the consumer owns per-entry metadata.
    parameter bit                     ExposeEntryIndex = 1'b0,
    // A local producer may capture resident operands before its global packet
    // reaches the registered broadcast. Allocation still uses the global view.
    parameter bit                     LocalOperandWake = 1'b0,
    parameter logic [31:0]            ComboWakePorts  = 32'hFFFF_FFFF,
    parameter unsigned                ROB_SIZE        = Cfg.rob_entries,
    parameter unsigned                PLEN            = rapt_pkg::index_bits(Cfg.phys_regs),
    parameter unsigned                RLEN            = rapt_pkg::index_bits(Cfg.arch_regs),
    parameter unsigned                XLEN            = Cfg.xlen
) (
    input CompletionT completion[NumCompletions],
    input CompletionT local_operand_wake[NumCompletions],
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

    // Same-cycle wake producers. Must not include a packet this queue
    // combinationally generates. Tied off when ComboCdbWake is 0.
    input CompletionT combo_source[NumCompletions],

    // Execution availability per attached function-unit port.
    input logic [NumIssuePorts-1:0] issue_enable,
    input logic [NumResources-1:0] resource_ready,

    // Issue ports: combinational view of the oldest registered-ready entries.
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
  // The uop, generation and physical destination are immutable after allocation.
  // FPGA LUTRAM uses one write bank per dispatch lane and one copy per issue port.
  localparam bit BankUop = `RAPT_FPGA_LUTRAM;
  localparam int BankBits = $bits(UopT) + GenBits + PLEN;
  localparam int LaneBits = NumSlots > 1 ? $clog2(NumSlots) : 1;
  logic alloc_hit[IQ_SIZE];
  logic [LaneBits-1:0] alloc_lane[IQ_SIZE];

  // Non-LUTRAM builds retain one FF copy of these fields per entry.
  UopT iq_uop[IQ_SIZE];
  logic [GenBits-1:0] iq_generation[IQ_SIZE];
  logic [PLEN-1:0] iq_prd[IQ_SIZE];
  // These signals are consumed only by the LUTRAM generate branch.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [NumIssuePorts-1:0] iq_issue_ports[IQ_SIZE];
  logic [IQLen-1:0] issue_data_index[NumIssuePorts];
  logic [BankBits-1:0] issue_payload[NumIssuePorts];
  /* verilator lint_on UNUSEDSIGNAL */
  if (BankUop) begin : g_banked_uop
`ifdef SYNTHESIS
    localparam int PhysIqSize = IQ_SIZE < 32 ? 32 : IQ_SIZE;
`else
    localparam int PhysIqSize = IQ_SIZE;
`endif
    localparam int PhysIqLen = $clog2(PhysIqSize);
    logic [LaneBits-1:0] lane_q[IQ_SIZE];
    logic [BankBits-1:0] bank_read[NumIssuePorts][NumSlots];
    for (genvar e = 0; e < IQ_SIZE; e++) begin : g_lane
      always_ff @(posedge clock) if (alloc_hit[e]) lane_q[e] <= alloc_lane[e];
    end
    for (genvar a = 0; a < NumSlots; a++) begin : g_write_lane
      wire [PhysIqLen-1:0] phys_rs_idx = PhysIqLen'(disp.rs_idx[a]);
      for (genvar p = 0; p < NumIssuePorts; p++) begin : g_read_copy
        logic [BankBits-1:0] words[PhysIqSize];
        wire [PhysIqLen-1:0] phys_issue_idx = PhysIqLen'(issue_data_index[p]);
        always_ff @(posedge clock)
          if (disp.accept[a])
            words[phys_rs_idx] <= {dispatch[a].uop, dispatch[a].generation, dispatch[a].prd};
        assign bank_read[p][a] = words[phys_issue_idx];
      end
    end
    for (genvar p = 0; p < NumIssuePorts; p++) begin : g_select
      assign issue_payload[p] = bank_read[p][lane_q[issue_data_index[p]]];
    end
  end
`ifndef SYNTHESIS
`ifdef VERILATOR
  // Stable, unpacked debug view for the simulator's hang diagnostics. This
  // is a read-only projection, not separately stored execution payload.
  logic [XLEN-1:0] iq_pc[IQ_SIZE];
  for (genvar i = 0; i < IQ_SIZE; i++) begin : g_iq_pc_probe
    always_ff @(posedge clock)
      if (alloc_hit[i])
        iq_pc[i] <= XLEN'($signed(dispatch[alloc_lane[i]].uop.pc));
  end
`endif
`endif

  // Reject inconsistent type/value configurations rather than truncating tags
  // or execution payloads silently at a specialization boundary.
`ifndef SYNTHESIS
  if (!(IQ_SIZE > 0 && IQ_SIZE == disp.RS_SIZE)) begin : g_invalid_capacity
    $error(
        "Invalid rapt_iq configuration: capacity must be positive and match allocation interface"
    );
  end
  if (!(NumSlots > 0 && NumSlots == disp.Width)) begin : g_invalid_config_0
    $error("IQ allocation width must match the selected frontend profile");
  end
`endif
  if (!(NumIssuePorts > 0 && NumIssuePorts <= $bits(
          dispatch[0].uop.schedule.issue_ports
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
  logic [IQ_SIZE-1:0] cancelled;
  function automatic logic younger_than_cancel(input logic [ROBLen-1:0] dest);
    return cancel_valid && `RAPT_ROB_YOUNGER(dest, cancel_owner, cancel_head);
  endfunction
  for (genvar e = 0; e < IQ_SIZE; e++) begin : g_cancel
    assign cancelled[e] = iq_valid[e] && younger_than_cancel(iq_dest[e]);
  end
  logic [   PLEN-1:0]              iq_pr1                 [        IQ_SIZE];
  logic [   PLEN-1:0]              iq_pr2                 [        IQ_SIZE];
  logic [IQ_SIZE-1:0]              iq_pr1_busy;
  logic [IQ_SIZE-1:0]              iq_pr2_busy;
  logic [IQ_SIZE-1:0] pr3_ready, resources_ready;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0]                 iq_vl[IQ_SIZE];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [XLEN-1:0] third_issue_value[IQ_SIZE];
  logic [IQ_SIZE-1:0]              iq_dep_busy            [NumDependencies];
  logic [ ROBLen-1:0]              iq_dep_tag             [NumDependencies] [IQ_SIZE];
  logic [GenBits-1:0]              iq_dep_generation      [NumDependencies] [IQ_SIZE];
  // === Unified CDB view for operand wakeup ===
  // The global array also carries dependency completion. The optional local
  // array only captures resident operand data and busy state at the next edge.
  localparam int unsigned NWB = NumCompletions;
  logic            wb_valid [NWB];
  logic [PLEN-1:0] wb_prd   [NWB];
  logic [XLEN-1:0] wb_result[NWB];
  for (genvar p = 0; p < NWB; p++) begin : g_completion_view
    assign wb_valid[p] = completion[p].valid;
    assign wb_prd[p] = completion[p].prd;
    assign wb_result[p] = completion[p].result;
  end

  // Global and local wake views form one source list with pre-decoded nonzero
  // validity so each operand shares a single tag-match vector across hit and
  // value capture without redundant (pr != 0) or default-value muxing.
  localparam int WakeSources = LocalOperandWake ? 2 * NWB : NWB;
  logic wake_nz_valid[WakeSources];
  logic [PLEN-1:0] wake_source_prd[WakeSources];
  logic [XLEN-1:0] wake_source_result[WakeSources];
  logic combo_nz_valid[NWB];
  for (genvar p = 0; p < NWB; p++) begin : g_wake_source
    assign wake_source_prd[p] = wb_prd[p];
    assign wake_source_result[p] = wb_result[p];
    assign wake_nz_valid[p] = wb_valid[p] && (wb_prd[p] != '0);
    assign combo_nz_valid[p] =
        ComboWakePorts[p] && combo_source[p].valid && (combo_source[p].prd != '0);
    if (LocalOperandWake) begin : g_local
      assign wake_source_prd[NWB+p] = local_operand_wake[p].prd;
      assign wake_source_result[NWB+p] = local_operand_wake[p].result;
      assign wake_nz_valid[NWB+p] =
          local_operand_wake[p].valid && (local_operand_wake[p].prd != '0);
    end
  end

  function automatic logic [WakeSources-1:0] wake_match(input logic [PLEN-1:0] pr);
    for (int s = 0; s < WakeSources; s++)
    wake_match[s] = wake_nz_valid[s] && (wake_source_prd[s] == pr);
  endfunction

  function automatic logic [XLEN-1:0] wake_or_val(input logic [WakeSources-1:0] match);
    wake_or_val = '0;
    for (int s = 0; s < WakeSources; s++) if (match[s]) wake_or_val |= wake_source_result[s];
  endfunction

  function automatic logic [NWB-1:0] combo_match(input logic [PLEN-1:0] pr);
    for (int p = 0; p < NWB; p++) combo_match[p] = combo_nz_valid[p] && (combo_source[p].prd == pr);
  endfunction

  function automatic logic [XLEN-1:0] combo_or_val(input logic [NWB-1:0] match);
    combo_or_val = '0;
    for (int p = 0; p < NWB; p++) if (match[p]) combo_or_val |= combo_source[p].result;
  endfunction

  function automatic logic completion_hit(input logic [ROBLen-1:0] dep,
                                          input logic [GenBits-1:0] generation);
    completion_hit = 1'b0;
    for (int p = 0; p < NumCompletions; p++)
    completion_hit |= completion[p].valid && completion[p].dest == dep
          && completion[p].generation == generation;
  endfunction

  // Allocation checks depend on the dispatch lane, before entry selection.
  if (ThirdOperand) begin : g_lane_third
    logic lane_pr3_busy[NumSlots];
    logic [XLEN-1:0] lane_vl[NumSlots];
    for (genvar s = 0; s < NumSlots; s++) begin : g_lane
      wire [WakeSources-1:0] pr3_match = wake_match(dispatch[s].pr3);
      wire pr3_hit = |pr3_match;
      assign lane_pr3_busy[s] = dispatch[s].pr3 != '0 && !pr3_hit;
      assign lane_vl[s] = pr3_hit ? wake_or_val(pr3_match) : dispatch[s].op3;
    end
  end
  logic lane_dep_busy[NumDependencies][NumSlots];
  logic lane_cancelled[NumSlots];
  for (genvar s = 0; s < NumSlots; s++) begin : g_lane_checks
    assign lane_cancelled[s] = younger_than_cancel(dispatch[s].dest);
    for (genvar d = 0; d < NumDependencies; d++) begin : g_dependency
      assign lane_dep_busy[d][s] = dispatch[s].dep_valid[d] && !completion_hit(
          dispatch[s].dep_tag[d], dispatch[s].dep_generation[d]
      );
    end
  end

  // Rename keeps one live producer per tag, so at most one completion source
  // carries a given nonzero tag; the value selects below rely on it.
  for (genvar a = 0; a < WakeSources; a++) begin : g_tag_unique
    for (genvar b = a + 1; b < WakeSources; b++) begin : g_pair
`ifdef RAPT_SVA_ACTIVE
      wire wake_tag_unique =
          !(wake_nz_valid[a] && wake_nz_valid[b] && wake_source_prd[a] == wake_source_prd[b]);
`endif
      `RAPT_SVA(clock, reset, IQ_WAKE_TAG_UNIQUE, wake_tag_unique)
    end
  end

  if (LocalOperandWake && ComboCdbWake && !ReadAfterSelect) begin : g_invalid_local_wake
    $error("Local operand wake requires registered-only issue readiness");
  end

  function automatic logic dependencies_busy(input int entry);
    dependencies_busy = 1'b0;
    for (int d = 0; d < NumDependencies; d++) dependencies_busy |= iq_dep_busy[d][entry];
  endfunction

  // === Per-entry wakeup / eligibility vectors ===
  logic [IQ_SIZE-1:0] pr1_slow_hit, pr2_slow_hit;
  logic [IQ_SIZE-1:0] pr1_combo_hit, pr2_combo_hit;
  logic [XLEN-1:0] pr1_slow_val[IQ_SIZE];
  logic [XLEN-1:0] pr2_slow_val[IQ_SIZE];
  logic [XLEN-1:0] pr1_combo_val[IQ_SIZE];
  logic [XLEN-1:0] pr2_combo_val[IQ_SIZE];
  logic [IQ_SIZE-1:0] pr_ready;
  logic [IQ_SIZE-1:0] iq_ready_vec;

  for (genvar i = 0; i < IQ_SIZE; i++) begin : g_wake_view
    wire [WakeSources-1:0] pr1_match = wake_match(iq_pr1[i]);
    wire [WakeSources-1:0] pr2_match = wake_match(iq_pr2[i]);
    assign pr1_slow_hit[i] = iq_pr1_busy[i] && (|pr1_match);
    assign pr2_slow_hit[i] = iq_pr2_busy[i] && (|pr2_match);
    assign pr1_slow_val[i] = wake_or_val(pr1_match);
    assign pr2_slow_val[i] = wake_or_val(pr2_match);
    if (ComboCdbWake) begin : g_combo_wake_view
      wire [NWB-1:0] c1_match = combo_match(iq_pr1[i]);
      wire [NWB-1:0] c2_match = combo_match(iq_pr2[i]);
      assign pr1_combo_hit[i] = iq_pr1_busy[i] && (|c1_match);
      assign pr2_combo_hit[i] = iq_pr2_busy[i] && (|c2_match);
      assign pr1_combo_val[i] = combo_or_val(c1_match);
      assign pr2_combo_val[i] = combo_or_val(c2_match);
    end else begin : g_no_combo_wake_view
      assign pr1_combo_hit[i] = 1'b0;
      assign pr2_combo_hit[i] = 1'b0;
      assign pr1_combo_val[i] = '0;
      assign pr2_combo_val[i] = '0;
    end
  end
  // Keep selector eligibility separate from CDB value capture. A simulator
  // schedules all outputs of an always_comb together; mixing readiness with
  // our own completion data creates an apparent issue -> execute -> CDB ->
  // ready loop even when ComboCdbWake is disabled.
  for (genvar i = 0; i < IQ_SIZE; i++) begin : g_operand_ready
    logic registers_ready;
    if (ComboCdbWake) begin : g_combo_wake
      assign registers_ready = (!iq_pr1_busy[i] || pr1_combo_hit[i])
          && (!iq_pr2_busy[i] || pr2_combo_hit[i]);
    end else begin : g_registered_wake
      assign registers_ready = !iq_pr1_busy[i] && !iq_pr2_busy[i];
    end
    assign pr_ready[i] = !dependencies_busy(i) && registers_ready
        && pr3_ready[i] && resources_ready[i];
    assign iq_ready_vec[i] = iq_valid[i] && pr_ready[i];
  end

  // Optional third source and unit availability use the same age/selection
  // machinery as the integer queues. Readiness changes only select identities;
  // accepted completions independently capture waiting operand values.
  for (genvar e = 0; e < IQ_SIZE; e++) begin : g_optional_operands
    if (ThirdOperand) begin : g_third
      logic [PLEN-1:0] tag;
      logic busy;
      wire [WakeSources-1:0] pr3_slow_match = wake_match(tag);
      wire pr3_slow_hit = |pr3_slow_match;
      wire [NWB-1:0] pr3_combo_match = combo_match(tag);
      wire pr3_combo_hit = ComboThirdWake && (|pr3_combo_match);
      assign pr3_ready[e] = !busy || pr3_combo_hit;
      assign third_issue_value[e] = (busy && pr3_combo_hit)
          ? combo_or_val(pr3_combo_match) : iq_vl[e];
      always_ff @(posedge clock) begin
        if (reset || cmu_bcast.flush_pipe) busy <= 1'b0;
        else if (alloc_hit[e]) begin
          tag <= dispatch[alloc_lane[e]].pr3;
          busy <= g_lane_third.lane_pr3_busy[alloc_lane[e]];
        end else if (iq_valid[e] && pr3_slow_hit) busy <= 1'b0;
      end
      always_ff @(posedge clock) begin
        if (alloc_hit[e]) iq_vl[e] <= g_lane_third.lane_vl[alloc_lane[e]];
        else if (iq_valid[e] && busy && pr3_slow_hit) iq_vl[e] <= wake_or_val(pr3_slow_match);
      end
    end else begin : g_two
      assign pr3_ready[e] = 1'b1;
      assign iq_vl[e] = '0;
      assign third_issue_value[e] = '0;
    end
    if (FilterResources) begin : g_resources
      logic [NumResources-1:0] mask_q;
      always_ff @(posedge clock)
        if (alloc_hit[e])
          mask_q <= NumResources'(dispatch[alloc_lane[e]].resources);
      assign resources_ready[e] = |(mask_q & resource_ready);
    end else begin : g_unfiltered
      assign resources_ready[e] = 1'b1;
    end
  end

  logic [IQ_SIZE-1:0] claimed;
  // Allocation ranks every free entry before any reclaimed (issuing) one,
  // each in index order, so old identities are reused only when needed. The
  // old payload is read before the edge; allocation beats issue-clear there.
  // Reclaimed entries sit at a power-of-two offset so the low bits name them.
  localparam int AllocOffset = 1 << IQLen;
  logic [2*AllocOffset-1:0] alloc_pool;
  logic alloc_found[NumSlots];
  logic [IQLen:0] alloc_index[NumSlots];
  always_comb begin
    alloc_pool = '0;
    alloc_pool[IQ_SIZE-1:0] = ~iq_valid;
    if (ReclaimOnIssue) alloc_pool[AllocOffset+:IQ_SIZE] = claimed & iq_valid;
  end
  rapt_rank_select #(
      .Entries(2 * AllocOffset),
      .NumSelect(NumSlots)
  ) alloc_rank (
      .available(alloc_pool),
      .found(alloc_found),
      .index(alloc_index)
  );
  for (genvar s = 0; s < NumSlots; s++) begin : g_alloc
    assign disp.free_found[s] = alloc_found[s];
    assign disp.free_idx[s] = alloc_index[s][IQLen-1:0];
  end
  for (genvar s = 0; s < NumSlots; s++) begin : g_alloc_contract
`ifdef RAPT_SVA_ACTIVE
    wire alloc_slot_free = !iq_valid[disp.rs_idx[s]] || (ReclaimOnIssue && claimed[disp.rs_idx[s]]);
`endif
    `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, QUEUE_ALLOC_FREE, disp.accept[s],
                    alloc_slot_free)
    for (genvar t = s + 1; t < NumSlots; t++) begin : g_unique
      `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, QUEUE_ALLOC_UNIQUE,
                      disp.accept[s] && disp.accept[t], disp.rs_idx[s] != disp.rs_idx[t])
    end
  end
  always_comb begin
    for (int e = 0; e < IQ_SIZE; e++) begin
      alloc_hit[e] = 1'b0;
      alloc_lane[e] = '0;
      for (int s = 0; s < NumSlots; s++) begin
        if (disp.accept[s] && int'(disp.rs_idx[s]) == e) begin
          alloc_hit[e] = 1'b1;
          alloc_lane[e] = LaneBits'(s);
        end
      end
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
  logic [IQ_SIZE-1:0] selected_data[NumIssuePorts];
  logic [IQ_SIZE-1:0] claimed_data;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [IQ_SIZE-1:0] baseline_claimed_data;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [NumIssuePorts-1:0] port_mask[IQ_SIZE];
  for (genvar e = 0; e < IQ_SIZE; e++) begin : g_port_mask
    if (BankUop) begin : g_banked
      assign port_mask[e] = iq_issue_ports[e];
    end else begin : g_flops
      assign port_mask[e] = NumIssuePorts'(iq_uop[e].schedule.issue_ports);
    end
  end
  // The selector sees architectural validity only: the recovery transaction
  // must not fan into the wide payload mux through the selected identity.
  // Cancellation is applied by the one-bit issue-valid gate below, so an
  // entry younger than the redirect owner is suppressed for the event cycle
  // and cleared at the edge instead of steering the payload. select_valid
  // keeps the cancel-aware view used by the PMU/capacity observations.
  wire [IQ_SIZE-1:0] transfer_enable = {IQ_SIZE{!reset && !cmu_bcast.flush_pipe}};
  assign claimed = claimed_data & transfer_enable;
  for (genvar port_index = 0; port_index < NumIssuePorts; port_index++) begin : g_transfer_gate
    assign selected[port_index] = selected_data[port_index] & transfer_enable;
  end
  rapt_issue_select #(
      .Entries(IQ_SIZE),
      .Ports(NumIssuePorts),
      .LastPort(LastIssuePort),
      .UniformSimplePorts(UniformSimplePorts),
      .InOrder(IN_ORDER_ISSUE),
      .Rebalance(RebalancePorts)
  ) selector (
      .valid(iq_valid),
      .ready(pr_ready),
      .older(age_mat),
      .compatible(port_mask),
      .enabled(issue_enable),
      .selected(selected_data),
      .claimed(claimed_data),
      .baseline_claimed(baseline_claimed_data)
  );
  localparam bit CheckUniformPorts =
      UniformSimplePorts && NumIssuePorts > 1 && !IN_ORDER_ISSUE && !RebalancePorts;
  if (CheckUniformPorts) begin : g_uniform_ports
    localparam int FirstSimplePort = LastIssuePort == 0 ? 1 : 0;
    for (genvar e = 0; e < IQ_SIZE; e++) begin : g_entry
      wire [NumIssuePorts-1:0] first_port_rep = {NumIssuePorts{port_mask[e][FirstSimplePort]}};
      wire uniform_mask =
          ((port_mask[e] ^ first_port_rep) & ~(NumIssuePorts'(1) << LastIssuePort)) == '0;
      `RAPT_SVA_IMPLY(clock, reset, UNIFORM_SIMPLE_PORTS, iq_valid[e], uniform_mask)
    end
  end
  // Registered observations share the issue edge, never the next-cycle view.
`ifndef SYNTHESIS
  logic [IQ_SIZE-1:0] baseline_claimed, select_valid, select_valid_nc;
  assign select_valid_nc = iq_valid & transfer_enable;
  assign select_valid = select_valid_nc & ~cancelled;
  assign baseline_claimed = baseline_claimed_data & transfer_enable;
  // Mutually exclusive observation of the FIRST allocation token only.
  // 0 available; 1 reset/flush; 2 all residents cancelled; 3 no ready survivor;
  // 4 no ready survivor on an enabled compatible port; 5 selection policy;
  // 6 issued but same-cycle reclaim disabled. These are not lost-IPC estimates.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [2:0] pmu_capacity_reason;
  logic [31:0] pmu_select_ready, pmu_select_issued, pmu_select_gain, pmu_reclaim_allocations;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [2:0] capacity_reason;
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
  int unsigned reclaim_allocations;
  always_comb begin
    reclaim_allocations = 0;
    for (int s = 0; s < NumSlots; s++)
    reclaim_allocations += int'(disp.accept[s] && iq_valid[disp.rs_idx[s]]);
  end
  always_ff @(posedge clock) begin
    pmu_select_ready <= 32'($countones(select_valid & pr_ready));
    // Selected-but-cancelled entries are suppressed by the issue valid
    // gate, so they do not count as issued.
    pmu_select_issued <= 32'($countones(claimed & ~cancelled));
    pmu_select_gain <= 32'($countones(claimed & ~cancelled) - $countones(
        baseline_claimed & ~cancelled));
    pmu_reclaim_allocations <= reset || cmu_bcast.flush_pipe ? 0 : reclaim_allocations;
  end
`endif
  localparam int StoredPayloadBits = (BankUop ? 0 : BankBits) + 2 * XLEN + ROBLen;
  logic [StoredPayloadBits-1:0] stored_payload[IQ_SIZE];
  logic [XLEN-1:0] entry_op1[IQ_SIZE], entry_op2[IQ_SIZE];
  for (genvar e = 0; e < IQ_SIZE; e++) begin : g_entry_operand
    assign entry_op1[e] = (ComboCdbWake && pr1_combo_hit[e]) ? pr1_combo_val[e] : iq_vj[e];
    assign entry_op2[e] = (ComboCdbWake && pr2_combo_hit[e]) ? pr2_combo_val[e] : iq_vk[e];
  end
  for (genvar e = 0; e < IQ_SIZE; e++) begin : g_stored_payload
    if (BankUop) begin : g_banked
      assign stored_payload[e] = {iq_vj[e], iq_vk[e], iq_dest[e]};
    end else begin : g_flops
      assign stored_payload[e] = {
        iq_uop[e], iq_vj[e], iq_vk[e], iq_dest[e], iq_generation[e], iq_prd[e]
      };
    end
  end
  for (genvar p = 0; p < NumIssuePorts; p++) begin : g_issue
    logic [IQLen-1:0] index;
    logic [IQ_SIZE-1:0] data_select;
    logic [StoredPayloadBits-1:0] payload;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [XLEN-1:0] stored_op1, stored_op2;
    /* verilator lint_on UNUSEDSIGNAL */
    if (IN_ORDER_ISSUE && NumIssuePorts == 1) begin : g_ordered_head_data
      // A single ordered port can only issue the oldest resident. The
      // payload view below is deliberately independent of readiness, port
      // enable and the recovery transaction: cancellation is applied at the
      // issue-valid gate, so a cancelled head can steer the mux for at most
      // the event cycle without ever being issued. Because the redirect is
      // oldest-wins, a cancelled head implies every younger resident is also
      // cancelled; suppressing the cycle therefore loses no legal issue.
      // Validity still comes from the unchanged issue selector.
      // Reset/flush suppress transfers, not this unqualified data view. Their
      // combinational fanout must not select FPR addresses ahead of arithmetic.
      logic [IQ_SIZE-1:0] head, resident;
      assign resident = iq_valid;
      for (genvar e = 0; e < IQ_SIZE; e++) begin : g_head
        logic [IQ_SIZE-1:0] predecessors;
        for (genvar o = 0; o < IQ_SIZE; o++) begin : g_predecessor
          assign predecessors[o] = o != e && age_mat[o][e] && resident[o];
        end
        assign head[e] = resident[e] && !(|predecessors);
      end
      assign data_select = (|head) ? head : IQ_SIZE'(1);
      `RAPT_SVA_IMPLY(clock, reset, IQ_ORDERED_HEAD_PAYLOAD, issue[p].valid,
                      data_select == selected[p])
    end else begin : g_selected_data
      // Unordered/multiport selection still owns the payload identity.
      assign data_select = (|selected_data[p]) ? selected_data[p] : IQ_SIZE'(1);
    end
    assign index = oh2bin(data_select);
    assign issue_data_index[p] = index;
    if (ExposeEntryIndex) begin : g_entry_index
      assign issue[p].entry_index = index;
    end
    // Share the encoded selector across the wide payload bus.
    assign payload = stored_payload[index];
    if (BankUop) begin : g_banked_payload
      assign {stored_op1, stored_op2, issue[p].dest} = payload;
      assign {issue[p].uop, issue[p].generation, issue[p].prd} = issue_payload[p];
    end else begin : g_flop_payload
      assign {issue[p].uop, stored_op1, stored_op2, issue[p].dest,
          issue[p].generation, issue[p].prd} = payload;
    end
    // Cancellation gates only this valid bit; the selected identity and
    // payload above do not depend on the recovery transaction.
    assign issue[p].valid = |selected[p] && !cancelled[index];
    assign issue[p].op3 = third_issue_value[index];
    // Resolve every entry's operand (same-cycle wake or
    // stored value) in parallel, then reduce with the one-hot selection. The
    // late select drives only the final AND-OR instead of an encoded index
    // that steers further per-entry muxes.
    if (ComboCdbWake) begin : g_wake_operands
      always_comb begin
        issue[p].op1 = '0;
        issue[p].op2 = '0;
        for (int e = 0; e < IQ_SIZE; e++) begin
          issue[p].op1 |= {XLEN{data_select[e]}} & entry_op1[e];
          issue[p].op2 |= {XLEN{data_select[e]}} & entry_op2[e];
        end
      end
    end else begin : g_stored_operands
      assign issue[p].op1 = stored_op1;
      assign issue[p].op2 = stored_op2;
    end
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
  // particular, issue-clear does not change operand data;
  // folding those state-only events into this block makes FPGA synthesis put
  // the LSU arbitration path on every iq_vj/iq_vk clock-enable pin.
  for (genvar i = 0; i < IQ_SIZE; i++) begin : g_operand_state
    always_ff @(posedge clock) begin
      begin
        if (alloc_hit[i]) begin
          iq_vj[i] <= dispatch[alloc_lane[i]].op1;
          iq_vk[i] <= dispatch[alloc_lane[i]].op2;
        end else if (iq_valid[i]) begin
          if (pr1_slow_hit[i]) iq_vj[i] <= pr1_slow_val[i];
          if (pr2_slow_hit[i]) iq_vk[i] <= pr2_slow_val[i];
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
      if (ReadAfterSelect) begin
        // Invalid entries retain readiness. Selection must not feed back into
        // these bits; allocation overwrites them before the next owner is live.
        if (alloc_hit[i]) begin
          iq_pr1_busy[i] <= |dispatch[alloc_lane[i]].pr1;
          iq_pr2_busy[i] <= |dispatch[alloc_lane[i]].pr2;
        end else begin
          if (pr1_slow_hit[i]) iq_pr1_busy[i] <= 1'b0;
          if (pr2_slow_hit[i]) iq_pr2_busy[i] <= 1'b0;
        end
      end
      begin
        if (alloc_hit[i]) begin
          // Allocation owns the new identity, even when the former resident
          // is cancelled. A younger incoming is accepted-and-discarded.
          iq_valid[i] <= !lane_cancelled[alloc_lane[i]];
          if (BankUop)
            iq_issue_ports[i] <= NumIssuePorts'(dispatch[alloc_lane[i]].uop.schedule.issue_ports);
          else begin
            iq_uop[i] <= dispatch[alloc_lane[i]].uop;
            iq_generation[i] <= dispatch[alloc_lane[i]].generation;
            iq_prd[i] <= dispatch[alloc_lane[i]].prd;
          end

          iq_dest[i] <= dispatch[alloc_lane[i]].dest;
          iq_pr1[i] <= dispatch[alloc_lane[i]].pr1;
          iq_pr2[i] <= dispatch[alloc_lane[i]].pr2;
          if (!ReadAfterSelect) begin
            iq_pr1_busy[i] <= |dispatch[alloc_lane[i]].pr1;
            iq_pr2_busy[i] <= |dispatch[alloc_lane[i]].pr2;
          end

          for (int d = 0; d < NumDependencies; d++) begin
            iq_dep_busy[d][i] <= lane_dep_busy[d][alloc_lane[i]];
            iq_dep_tag[d][i] <= dispatch[alloc_lane[i]].dep_tag[d];
            iq_dep_generation[d][i] <= dispatch[alloc_lane[i]].dep_generation[d];
          end

        end else if (cancelled[i]) begin
          // Payload/wakeup metadata remain don't-care while invalid. A late
          // completion cannot recreate validity.
          iq_valid[i] <= 1'b0;
        end else if (iq_valid[i] && claimed[i]) begin
          // A ready entry that loses port arbitration still captures wakeup.
          // Only an accepted issue may suppress the operand state update.
          iq_valid[i] <= 1'b0;
          if (!ReadAfterSelect) begin
            iq_pr1_busy[i] <= 1'b0;
            iq_pr2_busy[i] <= 1'b0;
          end
          for (int d = 0; d < NumDependencies; d++) iq_dep_busy[d][i] <= 1'b0;
        end else if (iq_valid[i]) begin
          // Capture readiness only on an accepted data wake.
          if (!ReadAfterSelect && pr1_slow_hit[i]) iq_pr1_busy[i] <= 1'b0;
          for (int d = 0; d < NumDependencies; d++)
          if (iq_dep_busy[d][i] && completion_hit(iq_dep_tag[d][i], iq_dep_generation[d][i]))
            iq_dep_busy[d][i] <= 1'b0;
          if (!ReadAfterSelect && pr2_slow_hit[i]) iq_pr2_busy[i] <= 1'b0;
        end

      end
      if (reset || cmu_bcast.flush_pipe) iq_valid[i] <= 1'b0;
    end
    // An age row is independent of other rows at the clock edge.
    always_ff @(posedge clock) begin
      begin
        // New entries are younger than residents and ordered by dispatch slot.
        for (int j = 0; j < IQ_SIZE; j++) begin
          if (alloc_hit[i] && alloc_hit[j]) age_mat[i][j] <= alloc_lane[i] < alloc_lane[j];
          else if (alloc_hit[i]) age_mat[i][j] <= 1'b0;
          else if (alloc_hit[j]) age_mat[i][j] <= iq_valid[i];
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


// One-cycle execution boundary. The queue has transferred ownership on
// capture; selective recovery must also kill a resident execution packet.
module rapt_execute_stage #(
    parameter type IssueT = rapt_pkg::issue_packet_t,
    parameter int ROB_SIZE = rapt_pkg::CoreConfig.rob_entries
) (
    input logic clock,
    reset,
    flush,
    input logic cancel_valid,
    input logic [$clog2(ROB_SIZE)-1:0] cancel_head,
    cancel_owner,
    input IssueT selected,
    output IssueT execute,
    output logic occupied
);
  IssueT packet_q;
  logic younger;
  assign younger = `RAPT_ROB_YOUNGER(packet_q.dest, cancel_owner, cancel_head);
  assign occupied = packet_q.valid;
  always_comb begin
    execute = packet_q;
    execute.valid = packet_q.valid && !reset && !flush && !(cancel_valid && younger);
  end
  always_ff @(posedge clock) begin
    packet_q <= selected;
    if (reset || flush) packet_q.valid <= 1'b0;
  end
endmodule
