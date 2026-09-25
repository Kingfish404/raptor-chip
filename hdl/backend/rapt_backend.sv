`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"
`include "rapt_dpi_c.svh"

// Backend composition: rename/checkpoints, ROB, dispatch, operand storage,
// issue/execute, completion ownership, LSU/SQ and precise retirement remain
// in one synthesis block. Only decoded uops and memory/control contracts cross.
module rapt_backend #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clock,
    input logic writeback_idle = 1'b1,
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
  dpu_iq_if #(.RS_SIZE(8)) disp_brq ();
  dpu_iq_if #(.RS_SIZE(4)) disp_mdq ();
  dpu_iq_if #(.RS_SIZE(1)) disp_fpq ();
  dpu_ioq_if disp_ioq ();

  // Unified completion topology: a parameterized integer-port array followed
  // by branch, memory and MUL/DIV. Composition selects which integer port owns
  // CSR/system capability and shares its endpoint with FP; ordered stage width
  // and dispatch-slot identity do not determine any physical port identity.
  localparam int IntegerIssuePorts = rapt_pkg::CoreConfig.integer_issue_ports;
  localparam int IntegerSystemPort = rapt_pkg::CoreConfig.integer_system_port;
  rapt_pkg::completion_t wb_integer_shared;
  rapt_pkg::completion_t wb_integer_raw[IntegerIssuePorts];
  rapt_pkg::completion_t wb_fpu;
  rapt_pkg::completion_t wb_branch;
  rapt_pkg::completion_t exu_ioq_bcast;
  rapt_pkg::completion_t exu_wb_mul;
  rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts];
  rapt_pkg::completion_t completion_accepted[rapt_pkg::CompletionPorts];
  // Validate every physical producer before endpoint arbitration. There are
  // two more candidates than broadcast ports: FPU shares the selected system
  // port, and independent early-load wake is not a CDB port. A stale FP result
  // cannot suppress an independently valid integer/system result.
  localparam int CandidateIntegerBase = 0;
  localparam int CandidateFpu = IntegerIssuePorts;
  localparam int CandidateBranch = IntegerIssuePorts + 1;
  localparam int CandidateMemory = IntegerIssuePorts + 2;
  localparam int CandidateMul = IntegerIssuePorts + 3;
  localparam int CandidateFastLoad = IntegerIssuePorts + 4;
  // Physical producers are a composition registry, not derived from the
  // number of downstream broadcast ports (one integer endpoint is shared and
  // fast-load is not a CDB port at all).
  localparam int CompletionCandidates = CandidateFastLoad + 1;
  rapt_pkg::completion_t completion_candidate[CompletionCandidates];
  logic completion_candidate_accept[CompletionCandidates];
  logic completion_candidate_identity_match[CompletionCandidates];
  logic completion_candidate_payload_match[CompletionCandidates];
  rob_completion_owner_if completion_owner ();
  for (genvar p = 0; p < IntegerIssuePorts; p++) begin : g_integer_candidate
    assign completion_candidate[CandidateIntegerBase+p] = wb_integer_raw[p];
  end
  assign completion_candidate[CandidateFpu] = wb_fpu;
  assign completion_candidate[CandidateBranch] = wb_branch;
  assign completion_candidate[CandidateMemory] = exu_ioq_bcast;
  assign completion_candidate[CandidateMul] = exu_wb_mul;
  rapt_pkg::completion_t fast_load_candidate;
  // Keep each physical CDB slot on its own combinational writer so a
  // branch-queue CDB wake cannot see the branch packet it is producing.
  for (
      genvar integer_port = 0; integer_port < IntegerIssuePorts; integer_port++
  ) begin : g_integer_accept
    if (integer_port == IntegerSystemPort) begin : g_shared
      assign completion_accepted[integer_port] = wb_integer_shared;
    end else begin : g_simple
      always_comb begin
        completion_accepted[integer_port] = wb_integer_raw[integer_port];
        completion_accepted[integer_port].valid = wb_integer_raw[integer_port].valid
            && completion_candidate_accept[CandidateIntegerBase+integer_port];
      end
    end
  end
  always_comb begin
    completion_accepted[IntegerIssuePorts] = wb_branch;
    completion_accepted[IntegerIssuePorts].valid = wb_branch.valid
        && completion_candidate_accept[CandidateBranch];
  end
  always_comb begin
    completion_accepted[IntegerIssuePorts+1] = exu_ioq_bcast;
    completion_accepted[IntegerIssuePorts+1].valid = exu_ioq_bcast.valid
        && completion_candidate_accept[CandidateMemory];
  end
  always_comb begin
    completion_accepted[IntegerIssuePorts+2] = exu_wb_mul;
    completion_accepted[IntegerIssuePorts+2].valid = exu_wb_mul.valid
        && completion_candidate_accept[CandidateMul];
  end

  load_fast_if load_fast_raw ();
  load_fast_if load_fast_accepted ();
  load_fast_if load_fast ();
  logic fast_load_confirm_reject;
  always_comb begin
    fast_load_candidate = '0;
    fast_load_candidate.valid = load_fast_raw.valid && !load_fast_raw.rebusy;
    fast_load_candidate.dest = load_fast_raw.dest;
    fast_load_candidate.generation = load_fast_raw.generation;
    fast_load_candidate.prd = load_fast_raw.prd;
    fast_load_candidate.rd = load_fast_raw.rd;

    fast_load_confirm_reject = load_fast_raw.confirmed
        && !completion_candidate_accept[CandidateMemory];
    load_fast_accepted.valid = (load_fast_raw.valid
        && (load_fast_raw.rebusy || completion_candidate_accept[CandidateFastLoad]))
        || fast_load_confirm_reject;
    load_fast_accepted.rebusy = load_fast_raw.rebusy || fast_load_confirm_reject;
    load_fast_accepted.prd = fast_load_confirm_reject ? load_fast_raw.confirmed_prd
        : load_fast_raw.prd;
    load_fast_accepted.dest = fast_load_confirm_reject ? load_fast_raw.confirmed_dest
        : load_fast_raw.dest;
    load_fast_accepted.generation = fast_load_confirm_reject
        ? load_fast_raw.confirmed_generation : load_fast_raw.generation;
    load_fast_accepted.rd = fast_load_confirm_reject ? load_fast_raw.confirmed_rd
        : load_fast_raw.rd;
    load_fast_accepted.confirmed = load_fast_raw.confirmed
        && completion_candidate_accept[CandidateMemory];
    load_fast_accepted.confirmed_prd = load_fast_raw.confirmed_prd;
    load_fast_accepted.confirmed_dest = load_fast_raw.confirmed_dest;
    load_fast_accepted.confirmed_generation = load_fast_raw.confirmed_generation;
    load_fast_accepted.confirmed_rd = load_fast_raw.confirmed_rd;
    load_fast_accepted.result = load_fast_raw.result;
  end
  // Integer execute already registers the issue packet. Memory completion is
  // the IOQ broadcast the cycle after L1D `rready`. Branch compare is
  // combinational from the already-registered BRQ issue packet; a fabric
  // register here delayed recovery and ROB complete by a cycle. Mul/div stay
  // registered because that FU is already pipelined.
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_completion_stage
    if (p != IntegerIssuePorts + 2) begin : g_same_cycle
      assign completion[p] = completion_accepted[p];
    end else begin : g_registered
      rapt_completion_stage stage (
          .clock(clock),
          .reset(reset),
          .flush(cmu_bcast.flush_pipe),
          .accepted(completion_accepted[p]),
          .completion(completion[p])
      );
    end
  end
  // Fast-load wake is combinational with IOQ `rready`; confirm is the
  // registered IOQ broadcast the next cycle. Do not re-register the pair.
  always_comb begin
    load_fast.valid = load_fast_accepted.valid && !reset && !cmu_bcast.flush_pipe;
    load_fast.confirmed = load_fast_accepted.confirmed && !reset
        && !cmu_bcast.flush_pipe;
    load_fast.rebusy = load_fast_accepted.rebusy;
    load_fast.prd = load_fast_accepted.prd;
    load_fast.dest = load_fast_accepted.dest;
    load_fast.generation = load_fast_accepted.generation;
    load_fast.rd = load_fast_accepted.rd;
    load_fast.confirmed_prd = load_fast_accepted.confirmed_prd;
    load_fast.confirmed_dest = load_fast_accepted.confirmed_dest;
    load_fast.confirmed_generation = load_fast_accepted.confirmed_generation;
    load_fast.confirmed_rd = load_fast_accepted.confirmed_rd;
    load_fast.result = load_fast_accepted.result;
  end
  `RAPT_SVA_IMPLY(clock, reset, MEMORY_COMPLETION_SAME_CYCLE,
                  completion_accepted[IntegerIssuePorts+1].valid,
                  completion[IntegerIssuePorts+1] == completion_accepted[IntegerIssuePorts+1])
  `RAPT_SVA_IMPLY(clock, reset, BRANCH_COMPLETION_SAME_CYCLE,
                  completion_accepted[IntegerIssuePorts].valid,
                  completion[IntegerIssuePorts] == completion_accepted[IntegerIssuePorts])
  `RAPT_SVA_IMPLY(clock, reset, FAST_LOAD_WAKE_SAME_CYCLE,
                  load_fast_accepted.valid && !cmu_bcast.flush_pipe, load_fast.valid)
  `RAPT_SVA_NEXT(clock, reset, FAST_LOAD_STAGE_FLUSH, cmu_bcast.flush_pipe,
                 !load_fast.valid && !load_fast.confirmed)
  // Consequent extracted so the SVA macro argument stays short and the
  // formatter cannot rejoin it past the column limit.
  logic fast_load_stage_confirm;
  assign fast_load_stage_confirm = completion[IntegerIssuePorts+1].valid
      && completion[IntegerIssuePorts+1].dest == load_fast.confirmed_dest
      && completion[IntegerIssuePorts+1].generation == load_fast.confirmed_generation
      && completion[IntegerIssuePorts+1].prd == load_fast.confirmed_prd
      && completion[IntegerIssuePorts+1].result == load_fast.result;
  `RAPT_SVA_IMPLY(clock, reset, FAST_LOAD_STAGE_CONFIRM, load_fast.confirmed,
                  fast_load_stage_confirm)
  assign completion_candidate[CandidateFastLoad] = fast_load_candidate;
  if (!(IntegerIssuePorts > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_core configuration");
  end
  if (!(IntegerSystemPort < IntegerIssuePorts)) begin : g_invalid_config_1
    $error("Invalid rapt_core configuration");
  end
  if (!(rapt_pkg::CompletionPorts == IntegerIssuePorts + 3)) begin : g_invalid_config_2
    $error("Invalid rapt_core configuration");
  end
  for (genvar p = 0; p < CompletionCandidates; p++) begin : g_completion_guard
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
        .accept(completion_candidate_accept[p]),
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
  logic integer_system_issue_enable;
  logic fpu_completion_ready;
  logic fpu_issue_enable;

  exu_prf_if exu_prf ();
  fpr_if fpr ();
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
  rapt_operand_stage operand_read_stage (
      .clock,
      .reset,
      .flush(cmu_bcast.flush_pipe || recovery.pending),
      .upstream(rnu_rou),
      .downstream(rnu_operand)
  );

  rapt_rou rou (
      .writeback_idle(writeback_idle),
      .writeback_drain(writeback_drain),
      .completion(completion),
      .completion_owner(completion_owner),
      .clock(clock),

      .rnu_rou(rnu_operand),
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
      .completion(completion),
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

  rapt_fpr fpr_bank (
      .clock(clock),
      .reset(reset),
      .fpr(fpr)
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

  rapt_ieu ieu (
      .cancel_valid(recovery.redirect_valid),
      .cancel_head(recovery.head),
      .cancel_owner(recovery.owner),
      .completion(completion),
      .clock(clock),
      .reset(reset),
      .cmu_bcast(cmu_bcast),
      .csr_bcast(csr_bcast),
      .dispatch(dispatch),
      .disp_alq(disp_alq),
      .disp_brq(disp_brq),
      .disp_mdq(disp_mdq),

      .load_fast(load_fast),
      .integer_system_issue_enable(integer_system_issue_enable),
      .exu_csr(exu_csr),
      .wb_integer_raw(wb_integer_raw),
      .wb_branch(wb_branch),
      .exu_wb_mul(exu_wb_mul),
      .pmu_ooo_valid(pmu_ooo_valid_unused),
      .pmu_ooo_valid_found(pmu_ooo_valid_found_unused),
      .pmu_ooo_full(pmu_ooo_full_unused)
  );

  rapt_feu feu (
      .cancel_valid(recovery.redirect_valid),
      .cancel_head(recovery.head),
      .cancel_owner(recovery.owner),
      .completion(completion),
      .clock(clock),
      .reset(reset),
      .cmu_bcast(cmu_bcast),
      .csr_bcast(csr_bcast),
      .dispatch(dispatch),
      .disp_fpq(disp_fpq),

      .load_fast(load_fast),
      .fpr(fpr),
      .wb_fpu(wb_fpu),
      .wb_accept(completion_candidate_accept[CandidateFpu]),
      .completion_ready(fpu_completion_ready),
      .issue_enable(fpu_issue_enable)
  );

  rapt_cdb_arb cdb_arb (
      .flush(cmu_bcast.flush_pipe),
      .cancel_valid(recovery.redirect_valid),
      .cancel_head(recovery.head),
      .cancel_owner(recovery.owner),
      .fpu_completion_ready(fpu_completion_ready),
      .clock(clock),
      .reset(reset),
      .integer_system_pipe_enable(1'b1),
      .fpu_issue_enable(fpu_issue_enable),
      .wb_integer_system_raw(wb_integer_raw[IntegerSystemPort]),
      .wb_fpu(wb_fpu),
      .wb_integer_system_accept(completion_candidate_accept[CandidateIntegerBase
          +IntegerSystemPort]),
      .wb_fpu_accept(completion_candidate_accept[CandidateFpu]),
      .wb_shared(wb_integer_shared),
      .integer_system_issue_enable(integer_system_issue_enable)
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
      .completion(completion),
      .clock(clock),
      .reset(reset),
      .cmu_bcast(cmu_bcast),
      .lsu_l1d(lsu_l1d),
      .exu_l1d(exu_l1d),
      .dispatch(dispatch),
      .disp_ioq(disp_ioq),

      .exu_ioq_bcast(exu_ioq_bcast),
      .wb_accept(completion_candidate_accept[CandidateMemory]),
      .rou_lsu(rou_lsu),
      .csr_bcast(csr_bcast),
      .pmp_update(pmp_update),
      .fpr(fpr),
      .load_fast(load_fast_raw),
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

  assign empty_o = !(|completion_owner.live) && rnu_operand.empty;
  assign sq_empty_o = rou_lsu.sq_empty;
endmodule
