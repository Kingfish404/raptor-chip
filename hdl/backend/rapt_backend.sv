`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"
`include "rapt_dpi_c.svh"

// Backend composition: rename/checkpoints, ROB, dispatch, operand storage,
// issue/execute, completion ownership, LSU/SQ and precise retirement remain
// in one synthesis block. Only decoded uops and memory/control contracts cross.
module rapt_backend #(
    parameter int XLEN = `RAPT_XLEN,
    // Standalone users may supply live idle; the core supplies held completion.
    parameter bit RegisteredDrainCompletion = 1'b0,
    parameter bit CompactFpOperands = 1'b0,
    parameter bit RegisteredDispatchPayload = 1'b0,
    // Rename slots carry rapt_pkg::derive_op* selectors, not constant values.
    parameter bit DerivedConstants = 1'b0,
    parameter bit LocalIntegerWake = 1'b0,
    parameter bit LocalMemoryWake = 1'b0,
    // Keep FP-to-FP queue capture live when the FP broadcast is registered.
    parameter bit LocalFpWake = 1'b0,
    // Reuse the ownership-checked completion register for selected wake ports.
    parameter logic [rapt_pkg::CompletionPorts-1:0] RegisteredOperandWakePorts = '0
) (
    input logic clock,
    input logic writeback_done = 1'b1,
    output logic writeback_drain,
    idu_rnu_if.slave idu_rnu,
    cmu_bcast_if cmu_bcast,
    csr_bcast_if csr_bcast,
    rapt_recovery_if recovery,
    pmp_update_if pmp_update,
    lsu_l1d_if.master lsu_l1d,
    lsu_l1d_mmu_if.master exu_l1d,
    output logic empty_o,
    output logic sq_empty_o,
    input logic clint_timer_int_i,
    input logic clint_sw_int_i,
    input logic [63:0] mtime_i,
    input logic io_interrupt,
    input logic s_ext_irq_i,
    input logic [XLEN-1:0] hart_id_i,
    input logic dm_haltreq_i,
    output logic halted_o,
    output logic [XLEN-1:0] halt_pc_o,
    output logic commit_fire_o,
    output logic [XLEN-1:0] dbg_gpr_rdata_o,
    input logic dbg_gpr_we_i,
    input logic [4:0] dbg_gpr_addr_i,
    input logic [XLEN-1:0] dbg_gpr_wdata_i,
    input logic [63:0] snapshot_ghr = '0,
    input logic [7:0] snapshot_phr = '0,
    output logic history_restore,
    output logic [63:0] restore_ghr,
    output logic [7:0] restore_phr,
`ifdef RAPT_RVFI
    // RISC-V Formal Interface (RVFI) outputs -- NRET=CommitWidth channels
    output [rapt_pkg::CommitWidth-1:0] rvfi_valid,
    output [rapt_pkg::CommitWidth*64-1:0] rvfi_order,
    output [rapt_pkg::CommitWidth*32-1:0] rvfi_insn,
    output [rapt_pkg::CommitWidth-1:0] rvfi_trap,
    output [rapt_pkg::CommitWidth-1:0] rvfi_halt,
    output [rapt_pkg::CommitWidth-1:0] rvfi_intr,
    output [rapt_pkg::CommitWidth*2-1:0] rvfi_mode,
    output [rapt_pkg::CommitWidth*2-1:0] rvfi_ixl,
    output [rapt_pkg::CommitWidth*5-1:0] rvfi_rs1_addr,
    output [rapt_pkg::CommitWidth*5-1:0] rvfi_rs2_addr,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_rs1_rdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_rs2_rdata,
    output [rapt_pkg::CommitWidth*5-1:0] rvfi_rd_addr,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_rd_wdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_pc_rdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_pc_wdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_mem_addr,
    output [rapt_pkg::CommitWidth*(XLEN/8)-1:0] rvfi_mem_rmask,
    output [rapt_pkg::CommitWidth*(XLEN/8)-1:0] rvfi_mem_wmask,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_mem_rdata,
    output [rapt_pkg::CommitWidth*XLEN-1:0] rvfi_mem_wdata,
`endif

    input logic reset
);
  // Optional PMU outputs from submodules are not consumed at core level.
  logic pmu_rob_full_unused;
  logic pmu_sq_full_unused;
  logic pmu_ooo_valid_unused;
  logic pmu_ooo_valid_found_unused;
  logic pmu_ooo_full_unused;
  // RNU stage
  rnu_rou_if rnu_operand ();
  logic rou_rename_empty;
  rnu_rou_if rnu_rou ();  // Re-naming => Issue
  checkpoint_release_if checkpoint_release ();  // accepted correct resolutions

  // ROU stage
  rapt_pkg::execution_domain_t dispatch_candidate_domain[rapt_pkg::SteerScanEntries];
  logic dispatch_candidate_valid[rapt_pkg::SteerScanEntries];
  logic dispatch_candidate_ready[rapt_pkg::SteerScanEntries];
  logic [rapt_pkg::index_bits(rapt_pkg::SteerScanEntries)-1:0]
      dispatch_selected_candidate[rapt_pkg::DispatchWidth];
  rapt_pkg::dispatch_slot_t dispatch[rapt_pkg::DispatchWidth];
  logic dispatch_valid[rapt_pkg::DispatchWidth];
  rou_lsu_if rou_lsu ();  // Commit
  rou_cmu_if rou_cmu ();  // Commit

  rou_csr_if rou_csr ();

  dpu_iq_if disp_alq ();
  dpu_iq_if #(.RS_SIZE(rapt_pkg::BranchQueueEntries)) disp_brq ();
  dpu_iq_if #(.RS_SIZE(4)) disp_mdq ();
  dpu_iq_if #(.RS_SIZE(rapt_pkg::CoreConfig.iq_entries)) disp_fpq ();
  dpu_ioq_if disp_ioq ();

  // Integer, branch, memory, MUL/DIV and floating-point producers share the
  // same ownership guard, operand wake and registered ROB completion contract.
  // FP has an independent endpoint so a divide cannot stop an integer port.
  localparam int IntegerIssuePorts = rapt_pkg::CoreConfig.integer_issue_ports;
  // Candidates and accepted packets use the same completion-port layout.
  localparam int BranchPort = rapt_pkg::completion_branch_port(rapt_pkg::CoreConfig);
  localparam int MemoryPort = rapt_pkg::completion_memory_port(rapt_pkg::CoreConfig);
  localparam int MulPort = rapt_pkg::completion_mul_port(rapt_pkg::CoreConfig);
  localparam int FpuPort = rapt_pkg::completion_fpu_port(rapt_pkg::CoreConfig);
  localparam int IntegerSystemPort = rapt_pkg::CoreConfig.integer_system_port;
  rapt_pkg::completion_t wb_integer_raw[IntegerIssuePorts];
  rapt_pkg::completion_t wb_fpu;
  rapt_pkg::completion_t wb_branch;
  rapt_pkg::completion_t exu_ioq_bcast;
  rapt_pkg::completion_t exu_wb_mul;
  rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts];
  rapt_pkg::completion_t completion_accepted[rapt_pkg::CompletionPorts];
  if (!rapt_pkg::PmaRegionsValid) begin : g_invalid_pma_regions
    $error("Invalid PMA regions: bounds, alignment, overlap or mapped attributes");
  end
  // Guards are independent per producer; candidate order carries no priority.
  // Validate each physical producer before publishing data or ROB control.
  rapt_pkg::completion_t completion_candidate[rapt_pkg::CompletionPorts];
  logic completion_candidate_identity_match[rapt_pkg::CompletionPorts];
  logic completion_candidate_payload_match[rapt_pkg::CompletionPorts];
  rob_completion_owner_if completion_owner ();
  for (genvar p = 0; p < IntegerIssuePorts; p++) begin : g_integer_candidate
    assign completion_candidate[p] = wb_integer_raw[p];
  end
  assign completion_candidate[FpuPort] = wb_fpu;
  assign completion_candidate[BranchPort] = wb_branch;
  assign completion_candidate[MemoryPort] = exu_ioq_bcast;
  assign completion_candidate[MulPort] = exu_wb_mul;
  // Keep each physical CDB slot on its own combinational writer so a
  // branch-queue CDB wake cannot see the branch packet it is producing.
  for (
      genvar integer_port = 0; integer_port < IntegerIssuePorts; integer_port++
  ) begin : g_integer_accept
    always_comb begin
      completion_accepted[integer_port] = wb_integer_raw[integer_port];
      completion_accepted[integer_port].valid = wb_integer_raw[integer_port].valid
          && g_completion_guard[integer_port].accepted;
    end
  end
  always_comb begin
    completion_accepted[BranchPort] = wb_branch;
    completion_accepted[BranchPort].valid = wb_branch.valid
        && g_completion_guard[BranchPort].accepted;
  end
  always_comb begin
    completion_accepted[MemoryPort] = exu_ioq_bcast;
    completion_accepted[MemoryPort].valid = exu_ioq_bcast.valid
        && g_completion_guard[MemoryPort].accepted;
  end
  always_comb begin
    completion_accepted[MulPort] = exu_wb_mul;
    completion_accepted[MulPort].valid = exu_wb_mul.valid
        && g_completion_guard[MulPort].accepted;
  end

  always_comb begin
    completion_accepted[FpuPort] = wb_fpu;
    completion_accepted[FpuPort].valid = wb_fpu.valid
        && g_completion_guard[FpuPort].accepted;
  end

  // Dedicated external wake view: no branch producer is on this input.
  rapt_pkg::completion_t branch_wake[rapt_pkg::CompletionPorts];
  rapt_pkg::completion_t memory_wake;
  // Keep the memory-only wake writer independent of the other CDB slots.
  // Match the main operand bus even at the dedicated IEU wake inputs.
  if (RegisteredOperandWakePorts[MemoryPort]) begin : g_registered_memory_wake
    assign memory_wake = completion[MemoryPort];
  end else begin : g_live_memory_wake
    always_comb begin
      memory_wake = exu_ioq_bcast;
      memory_wake.valid = exu_ioq_bcast.valid && g_completion_guard[MemoryPort].accepted;
    end
  end
  for (genvar p = 0; p < IntegerIssuePorts; p++) begin : g_branch_wake
    if (RegisteredOperandWakePorts[p]) begin : g_registered
      assign branch_wake[p] = completion[p];
    end else begin : g_live
      always_comb begin
        branch_wake[p] = wb_integer_raw[p];
        branch_wake[p].valid = wb_integer_raw[p].valid
              && g_completion_guard[p].accepted;
      end
    end
  end
  assign branch_wake[BranchPort] = '0;
  assign branch_wake[MemoryPort] = memory_wake;
  assign branch_wake[MulPort] = '0;
  assign branch_wake[FpuPort] = RegisteredOperandWakePorts[FpuPort]
      ? completion[FpuPort] : completion_accepted[FpuPort];

  // Register every accepted completion before ROB recovery and retirement.
  // Selected operand ports reuse this boundary; other producer ports retain
  // their accepted same-cycle wake latency.
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_completion_stage
    rapt_completion_stage stage (
        .clock(clock),
        .reset(reset),
        .flush(cmu_bcast.flush_pipe),
        .accepted(completion_accepted[p]),
        .completion(completion[p])
    );
  end
  // The global wake edge is shared by operand storage and queue allocations.
  // Optional local capture only wakes residents; the registered copy covers
  // owner transfer when an allocation coincides with an early local result.
  rapt_pkg::completion_t operand_wake[rapt_pkg::CompletionPorts];
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_operand_wake
    assign operand_wake[p] = RegisteredOperandWakePorts[p] ? completion[p] : completion_accepted[p];
  end
  if (!(IntegerIssuePorts > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_core configuration");
  end
  if (!(IntegerSystemPort < IntegerIssuePorts)) begin : g_invalid_config_1
    $error("Invalid rapt_core configuration");
  end
  if (!(rapt_pkg::CompletionPorts == IntegerIssuePorts + rapt_pkg::CompletionFixedPorts)) begin : g_invalid_config_2
    $error("Invalid rapt_core configuration");
  end
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_completion_guard
    logic accepted, guard_accept;
    // The IOQ only loses owners to a precise flush, which also kills its
    // completion. Each owner completes once. The memory port therefore keeps
    // the ROB owner lookup off the load-to-wake path and checks the same
    // identity contract in verification.
    if (p == MemoryPort) begin : g_trusted
      assign accepted = completion_candidate[p].valid;
      `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, MEMORY_COMPLETION_OWNER_LIVE,
                      completion_candidate[p].valid, guard_accept)
    end else begin : g_guarded
      assign accepted = guard_accept;
    end
    rapt_completion_guard #(
        .Entries(rapt_pkg::CoreConfig.rob_entries),
        .IndexBits(rapt_pkg::ROBIndexBits),
        .GenerationBits(rapt_pkg::CoreConfig.rob_generation_bits),
        .PhysBits(rapt_pkg::PLENPkg),
        .ArchBits(rapt_pkg::RLENPkg),
        .EnforcePayload(1'b0)
    ) guard (
        .candidate_valid(completion_candidate[p].valid),
        .candidate_index(completion_candidate[p].dest),
        .candidate_generation(completion_candidate[p].generation),
        .candidate_prd(completion_candidate[p].prd),
        .candidate_rd(completion_candidate[p].rd),
        .live(completion_owner.live),
        .executing(completion_owner.executing),
        .owner_generation(completion_owner.generation),
        .owner_prd(completion_owner.prd),
        .owner_rd(completion_owner.rd),
        .accept(guard_accept),
        .identity_match(completion_candidate_identity_match[p]),
        .payload_match(completion_candidate_payload_match[p])
    );
    // prd/rd are immutable typed-packet payload, not a second allocation
    // identity. Keep their end-to-end check in verification without placing
    // two wide owner-table muxes on every production completion endpoint.
    `RAPT_SVA_IMPLY(clock, reset, COMPLETION_PAYLOAD_CONSISTENT,
                    completion_candidate[p].valid && completion_candidate_identity_match[p],
                    completion_candidate_payload_match[p])
  end

  // Operand reads happen on the dispatch lanes, after ROB/spill residency.
  exu_prf_if #(.Width(rapt_pkg::DispatchWidth)) exu_prf ();
  exu_csr_if exu_csr ();

`ifndef SYNTHESIS
`ifdef VERILATOR
  typedef enum logic [1:0] {
    P_EMPTY,
    P_VALID,
    P_STALL,
    P_SQUASH
  } pipe_state_e;
  pipe_state_e pipe_decode_state[rapt_pkg::DecodeWidth];
  pipe_state_e pipe_rename_state[rapt_pkg::RenameWidth];
  pipe_state_e pipe_dispatch_state[rapt_pkg::DispatchWidth];
  pipe_state_e pipe_commit_state[rapt_pkg::CommitWidth];
  logic [rapt_pkg::CompletionPorts-1:0] pipe_cdb_valid_mask, pipe_result_wb_valid_mask;
  logic [$clog2(rapt_pkg::CompletionPorts+1)-1:0] pipe_cdb_valid_count;
  logic pipe_cdb_multi_valid, pipe_result_wb_multi_valid;
  for (genvar s = 0; s < rapt_pkg::DecodeWidth; s++) begin : g_pipe_decode_state
    assign pipe_decode_state[s] = cmu_bcast.flush_pipe ? P_SQUASH : !idu_rnu.valid[s] ? P_EMPTY
        : idu_rnu.ready[s] ? P_VALID : P_STALL;
  end
  for (genvar s = 0; s < rapt_pkg::RenameWidth; s++) begin : g_pipe_rename_state
    assign pipe_rename_state[s] = cmu_bcast.flush_pipe ? P_SQUASH : !rnu_rou.valid[s] ? P_EMPTY
        : rnu_rou.ready[s] ? P_VALID : P_STALL;
  end
  for (genvar s = 0; s < rapt_pkg::DispatchWidth; s++) begin : g_pipe_dispatch_state
    assign pipe_dispatch_state[s] = cmu_bcast.flush_pipe ? P_SQUASH : !dispatch_valid[s] ? P_EMPTY
        : P_VALID;
  end
  for (genvar s = 0; s < rapt_pkg::CommitWidth; s++) begin : g_pipe_commit_state
    assign pipe_commit_state[s] = rou_cmu.slot[s].valid ? P_VALID : P_EMPTY;
  end
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_pipe_cdb_state
    assign pipe_cdb_valid_mask[p] = completion[p].valid;
    assign pipe_result_wb_valid_mask[p] = completion[p].valid && completion[p].rd != 0;
  end
  assign pipe_cdb_valid_count
      = $clog2(rapt_pkg::CompletionPorts+1)'($countones(pipe_cdb_valid_mask));
  assign pipe_cdb_multi_valid = $countones(pipe_cdb_valid_mask) > 1;
  assign pipe_result_wb_multi_valid = $countones(pipe_result_wb_valid_mask) > 1;
`endif
`endif

  logic clint_timer_trap;
  logic clint_sw_trap;
  logic clint_ext_trap;
  logic s_int_pending;
  logic [`RAPT_XLEN-1:0] s_int_cause;

  // Per-hart interrupt gating. The cluster CLINT supplies raw
  // timer/software interrupt levels; AND them with the per-hart CSR
  // enables (mie / mstatus) before they reach the trap-decision logic in
  // ROU. The external (PLIC) line is gated identically.
  assign clint_timer_trap = clint_timer_int_i && csr_bcast.timer_int_en;
  assign clint_sw_trap    = clint_sw_int_i && csr_bcast.sw_int_en;
  assign clint_ext_trap   = io_interrupt && csr_bcast.ext_int_en;

  // RNU (Re-naming Unit): pure rename: RNQ + freelist + maptable
  logic [`RAPT_PHY_LEN-1:0] rnu_map_snapshot[`RAPT_REG_SIZE];
  logic [`RAPT_PHY_LEN-1:0] rnu_rat_snapshot[`RAPT_REG_SIZE];

  rapt_rnu rnu (
      .clock(clock),

      .rou_cmu  (rou_cmu),
      .cmu_bcast(cmu_bcast),

      .idu_rnu(idu_rnu),
      .rnu_rou(rnu_rou),
      .recovery(recovery),
      .checkpoint_release(checkpoint_release),
      .snapshot_ghr(snapshot_ghr),
      .snapshot_phr(snapshot_phr),
      .history_restore(history_restore),
      .restore_ghr(restore_ghr),
      .restore_phr(restore_phr),

      .map_snapshot(rnu_map_snapshot),
      .rat_snapshot(rnu_rat_snapshot),

      .reset(reset)
  );

  // ROU (Re-Order Unit)
  // The ROU owns the merged registered skid and allocation handshake.
  for (genvar s = 0; s < rapt_pkg::RenameWidth; s++) begin : g_rename_allocation
    assign rnu_operand.slot[s] = rnu_rou.slot[s];
    assign rnu_operand.valid[s] = rnu_rou.valid[s];
    assign rnu_operand.checkpoint_valid[s] = rnu_rou.checkpoint_valid[s];
    assign rnu_operand.checkpoint[s] = rnu_rou.checkpoint[s];
    assign rnu_rou.ready[s] = rnu_operand.ready[s];
  end
  assign rnu_operand.empty = rnu_rou.empty;

  logic drain_completion;
  if (RegisteredDrainCompletion) begin : g_registered_drain
    // The integrated memory drain already registers the complete ordering point.
    assign drain_completion = writeback_done;
  end else begin : g_live_drain
    // Standalone clients may provide live cache status. Capture that status and
    // SQ quiescence together, and discard it when its serialized owner leaves.
    always_ff @(posedge clock) begin
      drain_completion <= writeback_drain && writeback_done && rou_lsu.sq_empty;
      if (reset || cmu_bcast.flush_pipe) drain_completion <= 1'b0;
    end
  end

  rapt_rou #(
      // Only memory (FP loads) and FEU completions write an FPR.
      .FpWritePorts((32'(1) << MemoryPort) | (32'(1) << FpuPort)),
      .SeparateOperandWake(1'b1),
      .RegisteredDrainCompletion(1'b1),
      .CompactFpOperands(CompactFpOperands),
      .RegisteredDispatchPayload(RegisteredDispatchPayload),
      .DerivedConstants(DerivedConstants)
  ) rou (
      .operand_wake(operand_wake),
      .writeback_done(drain_completion),
      .writeback_drain(writeback_drain),
      .completion(completion),
      .completion_owner(completion_owner),
      .clock(clock),

      .rnu_rou(rnu_operand),
      .rename_buffer_empty_o(rou_rename_empty),
      .recovery(recovery),
      .checkpoint_release(checkpoint_release),

      // issue
      .exu_prf(exu_prf),
      .dispatch(dispatch),
      .candidate_domain(dispatch_candidate_domain),
      .candidate_valid(dispatch_candidate_valid),
      .candidate_ready(dispatch_candidate_ready),
      .selected_valid(dispatch_valid),
      .selected_candidate(dispatch_selected_candidate),

      .csr_bcast(csr_bcast),
      .clint_timer_trap(clint_timer_trap),
      .clint_sw_trap(clint_sw_trap),
      .clint_ext_trap(clint_ext_trap),
      .s_int_pending(s_int_pending),
      .s_int_cause(s_int_cause),

      .rou_cmu(rou_cmu),
      .rou_csr(rou_csr),
      .rou_lsu(rou_lsu),

      .dm_haltreq_i (dm_haltreq_i),
      .halted_o     (halted_o),
      .halt_pc_o    (halt_pc_o),
      .commit_fire_o(commit_fire_o),

      .pmu_rob_full(pmu_rob_full_unused),

      .reset(reset)
  );

  // PRF (Physical Register File): top-level shared resource
  // Debug: architectural register view (committed + speculative)
  /* verilator lint_off UNUSEDSIGNAL */
  logic [XLEN-1:0] rf    [`RAPT_REG_SIZE];
  logic [XLEN-1:0] rf_map[`RAPT_REG_SIZE];
  /* verilator lint_on UNUSEDSIGNAL */

`ifdef RAPT_RVFI
  logic [XLEN-1:0] rvfi_rd_data[rapt_pkg::CommitWidth];
`endif

  rapt_prf prf (
      .completion(operand_wake),
      .clock(clock),
      .reset(reset),

      .prf_rd(exu_prf),

      .rou_cmu      (rou_cmu),
      .cmu_bcast    (cmu_bcast),

      .map_snapshot(rnu_map_snapshot),
      .rat_snapshot(rnu_rat_snapshot),

      .rf    (rf),
      .rf_map(rf_map),

      .dbg_we_i   (dbg_gpr_we_i),
      .dbg_addr_i (dbg_gpr_addr_i),
      .dbg_wdata_i(dbg_gpr_wdata_i),
      .dbg_rdata_o(dbg_gpr_rdata_o)

`ifdef RAPT_RVFI,
      .rvfi_rd_data(rvfi_rd_data)
`endif
  );

  rapt_pkg::dispatch_capacity_t dispatch_capacity[rapt_pkg::ExecutionDomains];
  rapt_pkg::dispatch_grant_t dispatch_grant[rapt_pkg::ExecutionDomains];
  rapt_dpu #(
      .NumCandidates(rapt_pkg::SteerScanEntries)
  ) dpu (
      .clock(clock),
      .reset(reset),
      .candidate_domain(dispatch_candidate_domain),
      .candidate_valid(dispatch_candidate_valid),
      .candidate_ready(dispatch_candidate_ready),
      .selected_valid(dispatch_valid),
      .selected_candidate(dispatch_selected_candidate),
      .capacity(dispatch_capacity),
      .grant(dispatch_grant)
  );

  rapt_dispatch_iq_adapter dispatch_alq (
      .queue(disp_alq),
      .capacity(dispatch_capacity[rapt_pkg::DOMAIN_INTEGER]),
      .grant(dispatch_grant[rapt_pkg::DOMAIN_INTEGER])
  );
  rapt_dispatch_iq_adapter dispatch_brq (
      .queue(disp_brq),
      .capacity(dispatch_capacity[rapt_pkg::DOMAIN_BRANCH]),
      .grant(dispatch_grant[rapt_pkg::DOMAIN_BRANCH])
  );
  rapt_dispatch_iq_adapter dispatch_mdq (
      .queue(disp_mdq),
      .capacity(dispatch_capacity[rapt_pkg::DOMAIN_MULDIV]),
      .grant(dispatch_grant[rapt_pkg::DOMAIN_MULDIV])
  );
  rapt_dispatch_iq_adapter dispatch_fpq (
      .queue(disp_fpq),
      .capacity(dispatch_capacity[rapt_pkg::DOMAIN_FLOAT]),
      .grant(dispatch_grant[rapt_pkg::DOMAIN_FLOAT])
  );
  rapt_dispatch_ioq_adapter dispatch_ioq (
      .queue(disp_ioq),
      .capacity(dispatch_capacity[rapt_pkg::DOMAIN_MEMORY]),
      .grant(dispatch_grant[rapt_pkg::DOMAIN_MEMORY])
  );

  // Only ALQ/BRQ resident data registers receive these local integer/load/
  // branch-link/MUL copies. ROU, PRF, MUL/DIV, FP and memory consumers keep
  // the global edge. Local capture cannot feed same-cycle selection or
  // dispatch readiness, so a BRQ may capture its own registered link result.
  rapt_pkg::completion_t local_integer_wake[rapt_pkg::CompletionPorts];
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_local_integer_wake
    localparam bit RegisteredLinkOrMul = RegisteredOperandWakePorts[p]
        && (p == BranchPort || p == MulPort);
    localparam bit LocalPort = p < IntegerIssuePorts
        || (LocalMemoryWake && p == MemoryPort) || RegisteredLinkOrMul;
    if (LocalIntegerWake && LocalPort) begin : g_live
      assign local_integer_wake[p] = completion_accepted[p];
    end else begin : g_none
      assign local_integer_wake[p] = '0;
    end
  end
  // FPQ residents capture the live FP result; integer, memory and spill
  // consumers see it on the registered edge, off the FP arbiter path.
  rapt_pkg::completion_t local_fp_wake[rapt_pkg::CompletionPorts];
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_local_fp_wake
    if (LocalFpWake && RegisteredOperandWakePorts[p] && p == FpuPort) begin : g_live
      assign local_fp_wake[p] = completion_accepted[p];
    end else begin : g_none
      assign local_fp_wake[p] = '0;
    end
  end
  rapt_ieu #(
      .LocalIntegerWake(LocalIntegerWake)
  ) ieu (
      .local_integer_wake(local_integer_wake),
      .branch_wake(branch_wake),
      .memory_wake(memory_wake),
      .cancel_valid(recovery.redirect_valid),
      .cancel_head(recovery.head),
      .cancel_owner(recovery.owner),
      .completion(operand_wake),
      .clock(clock),
      .reset(reset),
      .cmu_bcast(cmu_bcast),
      .csr_bcast(csr_bcast),
      .dispatch(dispatch),
      .disp_alq(disp_alq),
      .disp_brq(disp_brq),
      .disp_mdq(disp_mdq),

      .integer_system_issue_enable(1'b1),
      .exu_csr(exu_csr),
      .wb_integer_raw(wb_integer_raw),
      .wb_branch(wb_branch),
      .exu_wb_mul(exu_wb_mul),
      .pmu_ooo_valid(pmu_ooo_valid_unused),
      .pmu_ooo_valid_found(pmu_ooo_valid_found_unused),
      .pmu_ooo_full(pmu_ooo_full_unused)
  );

  logic fp_issue_enable_unused;
  rapt_feu #(
      .LocalFpWake(LocalFpWake)
  ) feu (
      .local_fp_wake(local_fp_wake),
      .cancel_valid(recovery.redirect_valid),
      .cancel_head(recovery.head),
      .cancel_owner(recovery.owner),
      .completion(operand_wake),
      .clock(clock),
      .reset(reset),
      .cmu_bcast(cmu_bcast),
      .csr_bcast(csr_bcast),
      .dispatch(dispatch),
      .disp_fpq(disp_fpq),

      .wb_fpu(wb_fpu),
      .wb_accept(g_completion_guard[FpuPort].accepted),
      .completion_ready(1'b1),
      .issue_enable(fp_issue_enable_unused)
  );

  // CMU (ComMit Unit)
  rapt_cmu cmu (
      .clock(clock),

      .rou_cmu  (rou_cmu),
      .cmu_bcast(cmu_bcast),

      .reset(reset)
  );

  rapt_csr csrs (
      .clock(clock),
      .mtime_i(mtime_i),

      .hart_id_i(hart_id_i),

      .rou_csr(rou_csr),
      .exu_csr(exu_csr),

      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),

      .s_int_pending(s_int_pending),
      .s_int_cause  (s_int_cause),

      .timer_irq_i(clint_timer_int_i),
      .sw_irq_i   (clint_sw_int_i),
      .m_ext_irq_i(io_interrupt),
      .s_ext_irq_i(s_ext_irq_i),
      .store_error_i(lsu_l1d.wvalid && lsu_l1d.werr),
      .store_error_addr_i(lsu_l1d.waddr),
      .store_error_strb_i(lsu_l1d.walu),

      .reset(reset)
  );

  // LSU (Load/Store Unit)
  rapt_lsu lsu (
      .completion(operand_wake),
      .local_fp_wake(local_fp_wake),
      .clock(clock),
      .reset(reset),
      .cmu_bcast(cmu_bcast),
      .lsu_l1d(lsu_l1d),
      .exu_l1d(exu_l1d),
      .dispatch(dispatch),
      .disp_ioq(disp_ioq),

      .exu_ioq_bcast(exu_ioq_bcast),
      .wb_accept(g_completion_guard[MemoryPort].accepted),
      .rou_lsu(rou_lsu),
      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),
      .pmu_sq_full(pmu_sq_full_unused)
  );

`ifdef RAPT_RVFI
  // RVFI (RISC-V Formal Interface) output generation
  rapt_rvfi rvfi_inst (
      .clock(clock),
      .reset(reset),

      .rou_cmu  (rou_cmu),
      .csr_bcast(csr_bcast),
      .rf       (rf),

      .rd_wdata(rvfi_rd_data),

      .rvfi_valid(rvfi_valid),
      .rvfi_order(rvfi_order),
      .rvfi_insn (rvfi_insn),
      .rvfi_trap (rvfi_trap),
      .rvfi_halt (rvfi_halt),
      .rvfi_intr (rvfi_intr),
      .rvfi_mode (rvfi_mode),
      .rvfi_ixl  (rvfi_ixl),

      .rvfi_rs1_addr (rvfi_rs1_addr),
      .rvfi_rs2_addr (rvfi_rs2_addr),
      .rvfi_rs1_rdata(rvfi_rs1_rdata),
      .rvfi_rs2_rdata(rvfi_rs2_rdata),
      .rvfi_rd_addr  (rvfi_rd_addr),
      .rvfi_rd_wdata (rvfi_rd_wdata),

      .rvfi_pc_rdata(rvfi_pc_rdata),
      .rvfi_pc_wdata(rvfi_pc_wdata),

      .rvfi_mem_addr (rvfi_mem_addr),
      .rvfi_mem_rmask(rvfi_mem_rmask),
      .rvfi_mem_wmask(rvfi_mem_wmask),
      .rvfi_mem_rdata(rvfi_mem_rdata),
      .rvfi_mem_wdata(rvfi_mem_wdata)
  );
`endif

  // A draining group can accept refill while still occupied; use explicit
  // registered emptiness for I/O-fetch authorization.
  assign empty_o = !(|completion_owner.live) && rnu_operand.empty && rou_rename_empty;
  assign sq_empty_o = rou_lsu.sq_empty;
endmodule
