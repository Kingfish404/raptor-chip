`include "rapt.svh"
`include "rapt_if.svh"

// Generic Issue Queue (IQ) -- per-pipeline out-of-order scheduler.
//
// One parameterized IQ instance sits in front of every ALU-class execution
// pipe. Dispatch routing (rapt_exu) decides which IQ a uop enters, so the
// IQ itself needs no per-port class predicates beyond the optional port-B
// block bit: the oldest entry with ready operands issues, and the entry is
// freed the same cycle (the pipe's writeback port is dedicated and never
// back-pressures).
//
// Issue ports:
//   * `iss`   -- always present: oldest ready entry (any class).
//   * `iss_b` -- when HAS_ISS_B=1: the oldest ready entry that is not
//     port-B-blocked (CSR/system/trap class, flagged at dispatch via
//     `disp.iss_b_block_*`) and distinct from `iss`'s pick. This lets one
//     shared entry pool feed two ALU pipes: the two oldest ready uops
//     issue together regardless of how dispatch interleaved them.
//
// Responsibilities:
//   * Hold dispatched uops with captured operands (data-capture scheduler)
//   * Wake operands from the slow CDB ports (ALU-CSR / ALU / MEM / MULDIV)
//   * Fast load-use: tag-only early wakeup from `load_fast`, confirmed (or
//     re-busied) by the MEM broadcast one cycle later; issue-time data
//     bypass from `exu_ioq_bcast.result`
//   * Age-matrix oldest-first select; expose the winning entries' payload
//     combinationally on the issue ports
//   * 2-wide allocation (slot A at free_idx_a, slot B at disp.b_rs_idx)
module rapt_exu_iq #(
    parameter unsigned IQ_SIZE  = 8,
    parameter bit      HAS_ISS_B = 1'b0,
    parameter bit      IN_ORDER_ISSUE = 1'b0,
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned PLEN     = `RAPT_PHY_LEN,
    parameter unsigned RLEN     = `RAPT_REG_LEN,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    input clock,
    input reset,

    cmu_bcast_if.in cmu_bcast,

    // Dispatch source + arbitration (EXU router drives accepts)
    rou_exu_if.monitor rou_exu,
    exu_disp_rs_if.rs  disp,

    // Slow CDB wakeup sources (all value-producing pipes, incl. our own)
    exu_wb_if.in exu_rou,
    exu_wb_if.in exu_rou_b,
    exu_wb_if.in exu_ioq_bcast,
    exu_wb_if.in exu_wb_mul,

    // Fast load-use tag wakeup
    exu_load_fast_if.sink load_fast,

    // Port-A execution availability from the attached function unit.
    input logic issue_enable,

    // Issue ports: combinational view of the oldest ready entries.
    // op1/op2 have the fast-confirm MEM-result bypass already applied.
    exu_iq_iss_if.iq iss,
    exu_iq_iss_if.iq iss_b,

    // Occupancy (PMU aggregation) + PMU full pulse
    output logic [$clog2(IQ_SIZE):0] occ_o,
    /* verilator lint_off UNUSEDSIGNAL */
    output logic pmu_iq_full
    /* verilator lint_on UNUSEDSIGNAL */
);
  localparam unsigned IQLen  = (IQ_SIZE > 1) ? $clog2(IQ_SIZE) : 1;
  localparam unsigned ROBLen = $clog2(ROB_SIZE);

  // === IQ state ===
  logic [IQ_SIZE-1:0] iq_valid;
  logic [   XLEN-1:0] iq_pc      [IQ_SIZE];
  logic [IQ_SIZE-1:0] iq_c;
  logic [IQ_SIZE-1:0] iq_word;
  logic [        5:0] iq_alu     [IQ_SIZE];
  logic [   XLEN-1:0] iq_vj      [IQ_SIZE];
  logic [   XLEN-1:0] iq_vk      [IQ_SIZE];
  logic [ ROBLen-1:0] iq_dest    [IQ_SIZE];
  logic [   PLEN-1:0] iq_pr1     [IQ_SIZE];
  logic [   PLEN-1:0] iq_pr2     [IQ_SIZE];
  logic [IQ_SIZE-1:0] iq_pr1_busy;
  logic [IQ_SIZE-1:0] iq_pr2_busy;
  logic [IQ_SIZE-1:0] iq_pr1_fast;
  logic [IQ_SIZE-1:0] iq_pr2_fast;
  logic [   PLEN-1:0] iq_prd     [IQ_SIZE];
  logic [   RLEN-1:0] iq_rd      [IQ_SIZE];
  logic [IQ_SIZE-1:0] iq_fp_valid;
  logic [        5:0] iq_fp_op   [IQ_SIZE];
  logic [        2:0] iq_fp_rm   [IQ_SIZE];
  logic [        4:0] iq_fp_rs1  [IQ_SIZE];
  logic [        4:0] iq_fp_rs2  [IQ_SIZE];
  logic [        4:0] iq_fp_rs3  [IQ_SIZE];
  logic [        4:0] iq_fp_rd   [IQ_SIZE];
  logic [IQ_SIZE-1:0] iq_fp_dep1_busy, iq_fp_dep2_busy, iq_fp_dep3_busy;
  logic [ ROBLen-1:0] iq_fp_dep1 [IQ_SIZE];
  logic [ ROBLen-1:0] iq_fp_dep2 [IQ_SIZE];
  logic [ ROBLen-1:0] iq_fp_dep3 [IQ_SIZE];
  logic [IQ_SIZE-1:0] iq_jen;
  logic [IQ_SIZE-1:0] iq_jren;
  // Ineligible for port B (dispatch sideband); only read when HAS_ISS_B=1.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [IQ_SIZE-1:0] iq_b_block;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [   XLEN-1:0] iq_imm     [IQ_SIZE];
  logic [   XLEN-1:0] iq_pnpc    [IQ_SIZE];
  logic [IQ_SIZE-1:0] iq_trap;
  logic [   XLEN-1:0] iq_tval    [IQ_SIZE];
  logic [   XLEN-1:0] iq_cause   [IQ_SIZE];

  // === Unified CDB view for operand wakeup ===
  // [0]=MEM [1]=ALU-CSR [2]=ALU [3]=MULDIV. Rename guarantees a unique
  // producer per physical register, so port order is don't-care; the fast
  // load-use tag path is layered on top (mutually exclusive per tag).
  localparam int unsigned NWB = 4;
  logic            wb_valid [NWB];
  logic [PLEN-1:0] wb_prd   [NWB];
  logic [XLEN-1:0] wb_result[NWB];
  logic [ROBLen-1:0] wb_dest[NWB];
  assign wb_valid[0]  = exu_ioq_bcast.valid;
  assign wb_prd[0]    = exu_ioq_bcast.prd;
  assign wb_result[0] = exu_ioq_bcast.result;
  assign wb_dest[0]   = exu_ioq_bcast.dest;
  assign wb_valid[1]  = exu_rou.valid;
  assign wb_prd[1]    = exu_rou.prd;
  assign wb_result[1] = exu_rou.result;
  assign wb_dest[1]   = exu_rou.dest;
  assign wb_valid[2]  = exu_rou_b.valid;
  assign wb_prd[2]    = exu_rou_b.prd;
  assign wb_result[2] = exu_rou_b.result;
  assign wb_dest[2]   = exu_rou_b.dest;
  assign wb_valid[3]  = exu_wb_mul.valid;
  assign wb_prd[3]    = exu_wb_mul.prd;
  assign wb_result[3] = exu_wb_mul.result;
  assign wb_dest[3]   = exu_wb_mul.dest;

  function automatic logic wb_hit(input logic [PLEN-1:0] pr);
    wb_hit = 1'b0;
    for (int p = 0; p < NWB; p++) begin
      wb_hit |= (pr != '0) && wb_valid[p] && (wb_prd[p] == pr);
    end
  endfunction

  function automatic logic fp_wb_hit(input logic [ROBLen-1:0] dep);
    fp_wb_hit = 1'b0;
    for (int p = 0; p < NWB; p++) begin
      fp_wb_hit |= wb_valid[p] && (wb_dest[p] == dep);
    end
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

  function automatic logic fast_confirm_match(input logic is_fast, input logic [PLEN-1:0] pr);
    return is_fast && exu_ioq_bcast.valid && (exu_ioq_bcast.prd == pr);
  endfunction

  function automatic logic fast_rebusy_match(input logic is_fast, input logic [PLEN-1:0] pr);
    return is_fast && load_fast.valid && load_fast.rebusy && (load_fast.prd == pr);
  endfunction

  function automatic logic disp_b_selects_entry(input int entry);
`ifdef RAPT_DUAL_ISSUE
    return disp.accept_b && entry == int'(disp.b_rs_idx);
`else
    return 1'b0;
`endif
  endfunction

  logic disp_a_pr1_fast_wake, disp_a_pr2_fast_wake;
  assign disp_a_pr1_fast_wake = fast_wake_match(rou_exu.pr1);
  assign disp_a_pr2_fast_wake = fast_wake_match(rou_exu.pr2);
`ifdef RAPT_DUAL_ISSUE
  logic disp_b_pr1_fast_wake, disp_b_pr2_fast_wake;
  assign disp_b_pr1_fast_wake = fast_wake_match(rou_exu.pr1_b);
  assign disp_b_pr2_fast_wake = fast_wake_match(rou_exu.pr2_b);
`endif

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
      pr1_fast_confirm[i] = fast_confirm_match(iq_pr1_fast[i], iq_pr1[i]);
      pr2_fast_confirm[i] = fast_confirm_match(iq_pr2_fast[i], iq_pr2[i]);
      pr1_fast_rebusy[i]  = fast_rebusy_match(iq_pr1_fast[i], iq_pr1[i]);
      pr2_fast_rebusy[i]  = fast_rebusy_match(iq_pr2_fast[i], iq_pr2[i]);
      pr1_fast_wake[i]    = iq_pr1_busy[i] && fast_wake_match(iq_pr1[i]);
      pr2_fast_wake[i]    = iq_pr2_busy[i] && fast_wake_match(iq_pr2[i]);
      pr1_slow_hit[i]     = iq_pr1_busy[i] && wb_hit(iq_pr1[i]);
      pr2_slow_hit[i]     = iq_pr2_busy[i] && wb_hit(iq_pr2[i]);
      pr1_slow_val[i]     = wb_val(iq_pr1[i], iq_vj[i]);
      pr2_slow_val[i]     = wb_val(iq_pr2[i], iq_vk[i]);
      pr_ready[i] = ~(iq_pr1_busy[i] | iq_pr2_busy[i])
                    && ~(iq_fp_dep1_busy[i] | iq_fp_dep2_busy[i] | iq_fp_dep3_busy[i])
                    && (!iq_pr1_fast[i] || pr1_fast_confirm[i])
                    && (!iq_pr2_fast[i] || pr2_fast_confirm[i]);
      iq_free_vec[i]  = !iq_valid[i];
      iq_ready_vec[i] = iq_valid[i] && pr_ready[i];
    end
  end

  // === Free-slot PEs (exposed via disp) ===
  logic [IQLen-1:0] free_idx_a, free_idx_b;
  logic free_found_a, free_found_b;
  always_comb begin
    free_idx_a   = '0;
    free_found_a = 1'b0;
    for (int i = 0; i < IQ_SIZE; i++) begin
      if (!free_found_a && iq_free_vec[i]) begin
        free_idx_a   = i[IQLen-1:0];
        free_found_a = 1'b1;
      end
    end
  end
`ifdef RAPT_DUAL_ISSUE
  always_comb begin
    free_idx_b   = '0;
    free_found_b = 1'b0;
    for (int i = 0; i < IQ_SIZE; i++) begin
      if (!free_found_b && iq_free_vec[i] && !(free_found_a && i[IQLen-1:0] == free_idx_a)) begin
        free_idx_b   = i[IQLen-1:0];
        free_found_b = 1'b1;
      end
    end
  end
`else
  assign free_idx_b   = '0;
  assign free_found_b = 1'b0;
`endif

  assign disp.free_found_a = free_found_a;
  assign disp.free_found_b = free_found_b;
  assign disp.free_idx_a   = free_idx_a;
  assign disp.free_idx_b   = free_idx_b;

  // === Age matrix (strict partial order; same pattern as MULDIV/former RS) ===
  logic [IQ_SIZE-1:0] age_mat[IQ_SIZE];
  logic [IQ_SIZE-1:0] age_col[IQ_SIZE];
  always_comb begin
    for (int j = 0; j < IQ_SIZE; j++) begin
      for (int i = 0; i < IQ_SIZE; i++) begin
        age_col[j][i] = (i == j) ? 1'b0 : age_mat[i][j];
      end
    end
  end

  function automatic logic [IQ_SIZE-1:0] age_oldest_oh(input logic [IQ_SIZE-1:0] vec);
    logic [IQ_SIZE-1:0] oh;
    for (int i = 0; i < IQ_SIZE; i++) oh[i] = vec[i] && ((age_col[i] & vec) == '0);
    return oh;
  endfunction

  function automatic logic [IQLen-1:0] oh2bin(input logic [IQ_SIZE-1:0] oh);
    logic [IQLen-1:0] bin;
    bin = '0;
    for (int i = 0; i < IQ_SIZE; i++) begin
      if (oh[i]) bin = bin | i[IQLen-1:0];
    end
    return bin;
  endfunction

  // === Issue selection ===
  // Port A: oldest ready entry (any class).
  logic [IQ_SIZE-1:0] sel_onehot;
  logic [IQ_SIZE-1:0] oldest_valid_onehot;
  logic [IQLen-1:0] sel_idx;
  assign oldest_valid_onehot = age_oldest_oh(iq_valid);
  assign sel_onehot = issue_enable
    ? (IN_ORDER_ISSUE ? (oldest_valid_onehot & iq_ready_vec) : age_oldest_oh(iq_ready_vec))
    : '0;
  assign iss.valid  = |sel_onehot;
  assign sel_idx    = oh2bin(sel_onehot);

  // Port B (HAS_ISS_B only): oldest ready entry that is not port-B-blocked
  // and distinct from port A's pick. The age-matrix strict partial order
  // guarantees both picks are one-hot and disjoint.
  logic [IQ_SIZE-1:0] sel_b_onehot;
  logic [IQLen-1:0] sel_b_idx;
  generate
    if (HAS_ISS_B) begin : gen_iss_b_sel
      logic [IQ_SIZE-1:0] sel_b_msk;
      assign sel_b_msk   = iq_ready_vec & ~iq_b_block & ~sel_onehot;
      assign sel_b_onehot = age_oldest_oh(sel_b_msk);
    end else begin : gen_no_iss_b_sel
      assign sel_b_onehot = '0;
    end
  endgenerate
  assign sel_b_idx   = oh2bin(sel_b_onehot);
  assign iss_b.valid = |sel_b_onehot;

  // === Issue payloads (fast-confirm bypass on operands) ===
  assign iss.op1   = pr1_fast_confirm[sel_idx] ? exu_ioq_bcast.result : iq_vj[sel_idx];
  assign iss.op2   = pr2_fast_confirm[sel_idx] ? exu_ioq_bcast.result : iq_vk[sel_idx];
  assign iss.alu   = iq_alu[sel_idx];
  assign iss.pc    = iq_pc[sel_idx];
  assign iss.c     = iq_c[sel_idx];
  assign iss.word  = iq_word[sel_idx];
  assign iss.imm   = iq_imm[sel_idx];
  assign iss.pnpc  = iq_pnpc[sel_idx];
  assign iss.jen   = iq_jen[sel_idx];
  assign iss.jren  = iq_jren[sel_idx];
  assign iss.trap  = iq_trap[sel_idx];
  assign iss.tval  = iq_tval[sel_idx];
  assign iss.cause = iq_cause[sel_idx];
  assign iss.dest  = iq_dest[sel_idx];
  assign iss.prd   = iq_prd[sel_idx];
  assign iss.rd    = iq_rd[sel_idx];
  assign iss.fp_valid = iq_fp_valid[sel_idx];
  assign iss.fp_op    = iq_fp_op[sel_idx];
  assign iss.fp_rm    = iq_fp_rm[sel_idx];
  assign iss.fp_rs1   = iq_fp_rs1[sel_idx];
  assign iss.fp_rs2   = iq_fp_rs2[sel_idx];
  assign iss.fp_rs3   = iq_fp_rs3[sel_idx];
  assign iss.fp_rd    = iq_fp_rd[sel_idx];
  assign iss.fp_dep1_valid = iq_fp_dep1_busy[sel_idx];
  assign iss.fp_dep2_valid = iq_fp_dep2_busy[sel_idx];
  assign iss.fp_dep3_valid = iq_fp_dep3_busy[sel_idx];
  assign iss.fp_dep1 = iq_fp_dep1[sel_idx];
  assign iss.fp_dep2 = iq_fp_dep2[sel_idx];
  assign iss.fp_dep3 = iq_fp_dep3[sel_idx];

  assign iss_b.op1   = pr1_fast_confirm[sel_b_idx] ? exu_ioq_bcast.result : iq_vj[sel_b_idx];
  assign iss_b.op2   = pr2_fast_confirm[sel_b_idx] ? exu_ioq_bcast.result : iq_vk[sel_b_idx];
  assign iss_b.alu   = iq_alu[sel_b_idx];
  assign iss_b.pc    = iq_pc[sel_b_idx];
  assign iss_b.c     = iq_c[sel_b_idx];
  assign iss_b.word  = iq_word[sel_b_idx];
  assign iss_b.imm   = iq_imm[sel_b_idx];
  assign iss_b.pnpc  = iq_pnpc[sel_b_idx];
  assign iss_b.jen   = iq_jen[sel_b_idx];
  assign iss_b.jren  = iq_jren[sel_b_idx];
  assign iss_b.trap  = iq_trap[sel_b_idx];
  assign iss_b.tval  = iq_tval[sel_b_idx];
  assign iss_b.cause = iq_cause[sel_b_idx];
  assign iss_b.dest  = iq_dest[sel_b_idx];
  assign iss_b.prd   = iq_prd[sel_b_idx];
  assign iss_b.rd    = iq_rd[sel_b_idx];
  assign iss_b.fp_valid = iq_fp_valid[sel_b_idx];
  assign iss_b.fp_op    = iq_fp_op[sel_b_idx];
  assign iss_b.fp_rm    = iq_fp_rm[sel_b_idx];
  assign iss_b.fp_rs1   = iq_fp_rs1[sel_b_idx];
  assign iss_b.fp_rs2   = iq_fp_rs2[sel_b_idx];
  assign iss_b.fp_rs3   = iq_fp_rs3[sel_b_idx];
  assign iss_b.fp_rd    = iq_fp_rd[sel_b_idx];
  assign iss_b.fp_dep1_valid = iq_fp_dep1_busy[sel_b_idx];
  assign iss_b.fp_dep2_valid = iq_fp_dep2_busy[sel_b_idx];
  assign iss_b.fp_dep3_valid = iq_fp_dep3_busy[sel_b_idx];
  assign iss_b.fp_dep1 = iq_fp_dep1[sel_b_idx];
  assign iss_b.fp_dep2 = iq_fp_dep2[sel_b_idx];
  assign iss_b.fp_dep3 = iq_fp_dep3[sel_b_idx];

  // === Occupancy for router load balancing ===
  always_comb begin
    occ_o = '0;
    for (int i = 0; i < IQ_SIZE; i++) occ_o += ($clog2(IQ_SIZE) + 1)'(iq_valid[i]);
  end

  // === Sequential: alloc / wakeup / issue-clear ===
  logic iq_full_r;

  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      iq_valid  <= '0;
      iq_full_r <= 1'b0;
      // Per-entry payload, dependency, and age state is initialized on
      // allocation and cannot be selected while iq_valid is clear.
    end else begin
      iq_full_r <= (&iq_valid);

      // ---- Per-entry state machine ----
      for (int i = 0; i < IQ_SIZE; i++) begin
        if (disp_b_selects_entry(i)) begin
`ifdef RAPT_DUAL_ISSUE
          // Slot B has priority if both dispatch selectors ever alias.
          iq_valid[i]    <= 1'b1;
          iq_alu[i]      <= rou_exu.uop_b.alu;
          iq_vj[i]       <= rou_exu.op1_b;
          iq_vk[i]       <= rou_exu.op2_b;
          iq_dest[i]     <= rou_exu.dest_b;
          iq_pr1[i]      <= rou_exu.pr1_b;
          iq_pr2[i]      <= rou_exu.pr2_b;
          iq_pr1_busy[i] <= (|rou_exu.pr1_b) && !disp_b_pr1_fast_wake;
          iq_pr2_busy[i] <= (|rou_exu.pr2_b) && !disp_b_pr2_fast_wake;
          iq_pr1_fast[i] <= disp_b_pr1_fast_wake;
          iq_pr2_fast[i] <= disp_b_pr2_fast_wake;
          iq_prd[i]      <= rou_exu.prd_b;
          iq_rd[i]       <= rou_exu.uop_b.rd;
          iq_fp_valid[i] <= rou_exu.uop_b.fp_valid;
          iq_fp_op[i]    <= rou_exu.uop_b.fp_op;
          iq_fp_rm[i]    <= rou_exu.uop_b.fp_rm;
          iq_fp_rs1[i]   <= rou_exu.uop_b.fp_rs1;
          iq_fp_rs2[i]   <= rou_exu.uop_b.fp_rs2;
          iq_fp_rs3[i]   <= rou_exu.uop_b.fp_rs3;
          iq_fp_rd[i]    <= rou_exu.uop_b.fp_rd;
          iq_fp_dep1_busy[i] <= rou_exu.fp_dep1_valid && !fp_wb_hit(rou_exu.fp_dep1);
          iq_fp_dep2_busy[i] <= rou_exu.fp_dep2_valid && !fp_wb_hit(rou_exu.fp_dep2);
          iq_fp_dep3_busy[i] <= rou_exu.fp_dep3_valid && !fp_wb_hit(rou_exu.fp_dep3);
          iq_fp_dep1[i] <= rou_exu.fp_dep1;
          iq_fp_dep2[i] <= rou_exu.fp_dep2;
          iq_fp_dep3[i] <= rou_exu.fp_dep3;
          iq_pc[i]       <= rou_exu.uop_b.pc;
          iq_c[i]        <= rou_exu.uop_b.c;
          iq_word[i]     <= rou_exu.uop_b.word;
          iq_jen[i]      <= rou_exu.uop_b.jen;
          iq_jren[i]     <= rou_exu.uop_b.jren;
          iq_b_block[i]  <= disp.iss_b_block_b;
          iq_imm[i]      <= rou_exu.uop_b.imm;
          iq_pnpc[i]     <= rou_exu.uop_b.pnpc;
          iq_trap[i]     <= rou_exu.uop_b.trap;
          iq_tval[i]     <= rou_exu.uop_b.tval;
          iq_cause[i]    <= rou_exu.uop_b.cause;
`endif
        end else if (disp.accept_a && free_found_a && i == int'(free_idx_a)) begin
          // Slot-A allocation lands here when accepted by the router.
          iq_valid[i]    <= 1'b1;
          iq_alu[i]      <= rou_exu.uop.alu;
          iq_vj[i]       <= rou_exu.op1;
          iq_vk[i]       <= rou_exu.op2;
          iq_dest[i]     <= rou_exu.dest;
          iq_pr1[i]      <= rou_exu.pr1;
          iq_pr2[i]      <= rou_exu.pr2;
          iq_pr1_busy[i] <= (|rou_exu.pr1) && !disp_a_pr1_fast_wake;
          iq_pr2_busy[i] <= (|rou_exu.pr2) && !disp_a_pr2_fast_wake;
          iq_pr1_fast[i] <= disp_a_pr1_fast_wake;
          iq_pr2_fast[i] <= disp_a_pr2_fast_wake;
          iq_prd[i]      <= rou_exu.prd;
          iq_rd[i]       <= rou_exu.uop.rd;
          iq_fp_valid[i] <= rou_exu.uop.fp_valid;
          iq_fp_op[i]    <= rou_exu.uop.fp_op;
          iq_fp_rm[i]    <= rou_exu.uop.fp_rm;
          iq_fp_rs1[i]   <= rou_exu.uop.fp_rs1;
          iq_fp_rs2[i]   <= rou_exu.uop.fp_rs2;
          iq_fp_rs3[i]   <= rou_exu.uop.fp_rs3;
          iq_fp_rd[i]    <= rou_exu.uop.fp_rd;
          iq_fp_dep1_busy[i] <= rou_exu.fp_dep1_valid && !fp_wb_hit(rou_exu.fp_dep1);
          iq_fp_dep2_busy[i] <= rou_exu.fp_dep2_valid && !fp_wb_hit(rou_exu.fp_dep2);
          iq_fp_dep3_busy[i] <= rou_exu.fp_dep3_valid && !fp_wb_hit(rou_exu.fp_dep3);
          iq_fp_dep1[i] <= rou_exu.fp_dep1;
          iq_fp_dep2[i] <= rou_exu.fp_dep2;
          iq_fp_dep3[i] <= rou_exu.fp_dep3;
          iq_pc[i]       <= rou_exu.uop.pc;
          iq_c[i]        <= rou_exu.uop.c;
          iq_word[i]     <= rou_exu.uop.word;
          iq_jen[i]      <= rou_exu.uop.jen;
          iq_jren[i]     <= rou_exu.uop.jren;
          iq_b_block[i]  <= disp.iss_b_block_a;
          iq_imm[i]      <= rou_exu.uop.imm;
          iq_pnpc[i]     <= rou_exu.uop.pnpc;
          iq_trap[i]     <= rou_exu.uop.trap;
          iq_tval[i]     <= rou_exu.uop.tval;
          iq_cause[i]    <= rou_exu.uop.cause;
        end else if (iq_valid[i] && pr_ready[i]) begin
          // Fast-confirm data capture for an entry that became fully ready
          // this cycle (woken between ready computation and the clock edge).
          if (pr1_fast_confirm[i]) begin
            iq_vj[i]       <= exu_ioq_bcast.result;
            iq_pr1_fast[i] <= 1'b0;
          end
          if (pr2_fast_confirm[i]) begin
            iq_vk[i]       <= exu_ioq_bcast.result;
            iq_pr2_fast[i] <= 1'b0;
          end
          // Issue clear: entries selected on either port free this cycle
          // (dedicated WB ports, never back-pressured).  Only the valid bit
          // and the operand-tracking bits are cleared; payload arrays keep
          // their old values (don't-care once invalid).
          if (sel_onehot[i] || sel_b_onehot[i]) begin
            iq_valid[i]    <= 1'b0;
            iq_pr1_busy[i] <= 1'b0;
            iq_pr2_busy[i] <= 1'b0;
            iq_pr1_fast[i] <= 1'b0;
            iq_pr2_fast[i] <= 1'b0;
            iq_fp_valid[i] <= 1'b0;
            iq_fp_dep1_busy[i] <= 1'b0;
            iq_fp_dep2_busy[i] <= 1'b0;
            iq_fp_dep3_busy[i] <= 1'b0;
            iq_b_block[i]  <= 1'b0;
            iq_trap[i]     <= 1'b0;
          end
        end else if (iq_valid[i]) begin
          // Operand wakeup. Per tag, fast-wake and slow-hit are mutually
          // exclusive (unique producer), so arm order beyond the fast
          // confirm/rebusy pair is don't-care.
          if (pr1_fast_confirm[i]) begin
            iq_vj[i]       <= exu_ioq_bcast.result;
            iq_pr1_busy[i] <= 1'b0;
            iq_pr1_fast[i] <= 1'b0;
          end else if (pr1_fast_rebusy[i]) begin
            iq_pr1_busy[i] <= 1'b1;
            iq_pr1_fast[i] <= 1'b0;
          end else if (pr1_slow_hit[i]) begin
            iq_vj[i]       <= pr1_slow_val[i];
            iq_pr1_busy[i] <= 1'b0;
            iq_pr1_fast[i] <= 1'b0;
          end else if (pr1_fast_wake[i]) begin
            iq_pr1_busy[i] <= 1'b0;
            iq_pr1_fast[i] <= 1'b1;
          end
          if (iq_fp_dep1_busy[i] && fp_wb_hit(iq_fp_dep1[i])) iq_fp_dep1_busy[i] <= 1'b0;
          if (iq_fp_dep2_busy[i] && fp_wb_hit(iq_fp_dep2[i])) iq_fp_dep2_busy[i] <= 1'b0;
          if (iq_fp_dep3_busy[i] && fp_wb_hit(iq_fp_dep3[i])) iq_fp_dep3_busy[i] <= 1'b0;
          if (pr2_fast_confirm[i]) begin
            iq_vk[i]       <= exu_ioq_bcast.result;
            iq_pr2_busy[i] <= 1'b0;
            iq_pr2_fast[i] <= 1'b0;
          end else if (pr2_fast_rebusy[i]) begin
            iq_pr2_busy[i] <= 1'b1;
            iq_pr2_fast[i] <= 1'b0;
          end else if (pr2_slow_hit[i]) begin
            iq_vk[i]       <= pr2_slow_val[i];
            iq_pr2_busy[i] <= 1'b0;
            iq_pr2_fast[i] <= 1'b0;
          end else if (pr2_fast_wake[i]) begin
            iq_pr2_busy[i] <= 1'b0;
            iq_pr2_fast[i] <= 1'b1;
          end
        end
      end

      // ---- Age matrix updates on allocation ----
      // Per-cell one-hot priority (FPGA-robust; same as former RS/MULDIV):
      //   1. B->A cross-cell  2. B row zero  3. B column set
      //   4. A row zero       5. A column set  -  keep
`ifdef RAPT_DUAL_ISSUE
      for (int i = 0; i < IQ_SIZE; i++) begin
        for (int j = 0; j < IQ_SIZE; j++) begin
          if (disp.accept_a && disp.accept_b
              && i == int'(free_idx_a) && j == int'(disp.b_rs_idx)) begin
            age_mat[i][j] <= 1'b1;
          end else if (disp.accept_b && i == int'(disp.b_rs_idx)) begin
            age_mat[i][j] <= 1'b0;
          end else if (disp.accept_b && j == int'(disp.b_rs_idx) && i != int'(disp.b_rs_idx)) begin
            age_mat[i][j] <= iq_valid[i];
          end else if (disp.accept_a && i == int'(free_idx_a)) begin
            age_mat[i][j] <= 1'b0;
          end else if (disp.accept_a && j == int'(free_idx_a) && i != int'(free_idx_a)) begin
            age_mat[i][j] <= iq_valid[i];
          end
        end
      end
`else
      if (disp.accept_a) begin
        for (int j = 0; j < IQ_SIZE; j++) begin
          age_mat[free_idx_a][j] <= 1'b0;
          if (j != int'(free_idx_a)) age_mat[j][free_idx_a] <= iq_valid[j];
        end
      end
`endif
    end
  end

  // PMU: one-cycle pulse on IQ full rising edge
  assign pmu_iq_full = (&iq_valid) && !iq_full_r;

  // ==========================================================================
  //  Assertions (enable with +define+RAPT_ASSERT_EN)
  // ==========================================================================

  // ONE_HOT: issue selects must be one-hot and disjoint (age matrix strict
  // partial order; port B masks out port A's pick).
  `RAPT_SVA_IMPLY(clock, reset, IQ_SEL_ONEHOT, iss.valid, $onehot(sel_onehot))
  `RAPT_SVA_IMPLY(clock, reset, IQ_SEL_B_ONEHOT, iss_b.valid, $onehot(sel_b_onehot))
  `RAPT_SVA_IMPLY(clock, reset, IQ_SEL_AB_DISJOINT, iss_b.valid,
                  ((sel_onehot & sel_b_onehot) == '0))

  // HANDSHAKE: the router must never allocate into an occupied slot.
  `RAPT_SVA_IMPLY(clock, reset, IQ_ALLOC_A_FREE, disp.accept_a, !iq_valid[free_idx_a])
  `RAPT_SVA_IMPLY(clock, reset, IQ_ALLOC_B_FREE, disp.accept_b, !iq_valid[disp.b_rs_idx])

endmodule
