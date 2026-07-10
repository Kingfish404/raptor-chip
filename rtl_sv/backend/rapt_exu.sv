`include "rapt.svh"
`include "rapt_if.svh"

// Execution Unit (EXU) -- top-level wiring & dispatch arbitration.
//
// This module is intentionally thin. It owns:
//   * The routing policy that steers each renamed uop to one of the five
//     execution pipes:
//       IOQ    - loads / stores / atomics (in-order memory queue)
//       MULDIV - pure MUL/DIV arithmetic (private IQ + tag-based FU)
//       BRU    - conditional branches (IQ-C + compare-only pipe)
//       ALU-A  - CSR / system / trap MUST go here; simple ALU may
//       ALU-B  - simple ALU + JAL/JALR only
//     Simple ALU work is load-balanced between ALU-A and ALU-B by IQ
//     occupancy (ties prefer ALU-B, since ALU-A also serves specials).
//   * The single-driver `rou_exu.ready` / `rou_exu.ready_b` back-pressure
//     to the rename / dispatch pipeline.
//
// All micro-architectural state lives in the sub-modules: the generic
// per-pipe issue queues (`rapt_exu_iq`), the combinational pipes
// (`rapt_exu_pipe_a/b/c`), the MUL/DIV pipe, and the IOQ.
module rapt_exu #(
    parameter unsigned IQA_SIZE = `RAPT_RS_SIZE,
    parameter unsigned IQB_SIZE = `RAPT_RS_SIZE,
    parameter unsigned BRQ_SIZE = 4,
    parameter unsigned IOQ_SIZE = `RAPT_IOQ_SIZE,
    parameter unsigned MDQ_SIZE = 4,
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned PLEN     = `RAPT_PHY_LEN,
    parameter unsigned RLEN     = `RAPT_REG_LEN,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    input clock,
    input reset,

    cmu_bcast_if.in cmu_bcast,

    // No modport: EXU drives ready/ready_b (slave) but the queues only read.
    rou_exu_if rou_exu,

    // Unified writeback (CDB) ports -- see exu_wb_if for the index map.
    // No modport: each is driven by one pipe and read by the others.
    exu_wb_if exu_rou,
    exu_wb_if exu_rou_b,
    exu_wb_if exu_rou_c,
    exu_wb_if exu_ioq_bcast,
    exu_wb_if exu_wb_mul,

    exu_lsu_if.master exu_lsu,
    exu_csr_if.master exu_csr,

    csr_bcast_if.in   csr_bcast,
    exu_l1d_if.master exu_l1d,

    // Dispatch-only uop payload snapshot from ROU (read by pipe A at issue)
    input rapt_pkg::uop_payload_t uop_pl[ROB_SIZE]
);

  // === Sub-module dispatch handshakes ===
  exu_disp_rs_if #(.RS_SIZE(IQA_SIZE)) disp_iqa ();
  exu_disp_rs_if #(.RS_SIZE(IQB_SIZE)) disp_iqb ();
  exu_disp_rs_if #(.RS_SIZE(BRQ_SIZE)) disp_brq ();
  exu_disp_rs_if #(.RS_SIZE(MDQ_SIZE)) disp_mdq ();
  exu_disp_ioq_if #(.IOQ_SIZE(IOQ_SIZE)) disp_ioq ();
  exu_load_fast_if #(.PLEN(PLEN)) load_fast ();

  // === Issue buses (IQ -> pipe) ===
  exu_iq_iss_if #(.PLEN(PLEN), .RLEN(RLEN), .XLEN(XLEN)) iss_a ();
  exu_iq_iss_if #(.PLEN(PLEN), .RLEN(RLEN), .XLEN(XLEN)) iss_b ();
  exu_iq_iss_if #(.PLEN(PLEN), .RLEN(RLEN), .XLEN(XLEN)) iss_c ();

  // === Classification ===
  // The MDQ predicate must be airtight: a trap-marked or system uop may
  // carry a garbage `alu` in the MUL range (e.g. fetch page fault), and
  // only the ALU-A pipe handles CSR / trap / redirect semantics.
  // (Only the classification bits of the uop are inspected here.)
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic uop_is_mdq(input rapt_pkg::uop_t u);
    return (u.alu[5:4] == 2'b01)
        && !u.wen && !u.ren && !u.atom
        && !u.system && !u.trap && !u.ecall && !u.ebreak
        && !u.mret && !u.sret && !u.f_i && !u.f_time
        && !u.ben && !u.jen && !u.jren
        && (u.csr_csw == '0);
  endfunction

  // ALU-A-only: CSR / system / trap semantics live exclusively in pipe A.
  // (Conditional branches are checked separately and win: a trap-marked
  // branch resolves on the BRU as before, with trap info already in the
  // ROB from dispatch.)
  function automatic logic uop_is_a_only(input rapt_pkg::uop_t u);
    return u.system || u.trap || u.ecall || u.ebreak
        || u.mret || u.sret || (u.csr_csw != '0);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // Per-slot routing class (mutually exclusive; priority IOQ > MDQ > BRQ)
  logic a_to_ioq, a_to_mdq, a_to_brq, a_only, a_simple;
  assign a_to_ioq = (rou_exu.uop.wen || rou_exu.uop.ren);
  assign a_to_mdq = !a_to_ioq && uop_is_mdq(rou_exu.uop);
  assign a_to_brq = !a_to_ioq && !a_to_mdq && rou_exu.uop.ben;
  assign a_only   = !a_to_ioq && !a_to_mdq && !a_to_brq && uop_is_a_only(rou_exu.uop);
  assign a_simple = !a_to_ioq && !a_to_mdq && !a_to_brq && !a_only;
`ifdef RAPT_DUAL_ISSUE
  logic b_to_ioq, b_to_mdq, b_to_brq, b_only, b_simple;
  assign b_to_ioq = (rou_exu.uop_b.wen || rou_exu.uop_b.ren);
  assign b_to_mdq = !b_to_ioq && uop_is_mdq(rou_exu.uop_b);
  assign b_to_brq = !b_to_ioq && !b_to_mdq && rou_exu.uop_b.ben;
  assign b_only   = !b_to_ioq && !b_to_mdq && !b_to_brq && uop_is_a_only(rou_exu.uop_b);
  assign b_simple = !b_to_ioq && !b_to_mdq && !b_to_brq && !b_only;
`endif

  // === Load balancing for simple ALU work ===
  // Route to the emptier of IQ-A / IQ-B; ties prefer IQ-B (IQ-A also
  // serves the A-only class). When both slots carry simple work they are
  // split across the two queues.
  logic [$clog2(IQA_SIZE):0] occ_iqa;
  logic [$clog2(IQB_SIZE):0] occ_iqb;
  logic pick_b_first;
  assign pick_b_first = (occ_iqb <= occ_iqa);

  logic a_tgt_iqa, a_tgt_iqb;
  assign a_tgt_iqa = a_only || (a_simple && !pick_b_first);
  assign a_tgt_iqb = a_simple && pick_b_first;
`ifdef RAPT_DUAL_ISSUE
  logic b_tgt_iqa, b_tgt_iqb;
  assign b_tgt_iqa = b_only || (b_simple && (a_simple ? a_tgt_iqb : !pick_b_first));
  assign b_tgt_iqb = b_simple && (a_simple ? a_tgt_iqa : pick_b_first);
`endif

  // === Slot-A readiness: the chosen queue must have room ===
  logic rs_ready_a;
  assign rs_ready_a = a_to_ioq ? disp_ioq.ready
                    : a_to_mdq ? disp_mdq.free_found_a
                    : a_to_brq ? disp_brq.free_found_a
                    : a_tgt_iqa ? disp_iqa.free_found_a
                    : disp_iqb.free_found_a;
  assign rou_exu.ready = rs_ready_a;

`ifdef RAPT_DUAL_ISSUE
  // Slot-B readiness -- computed independently of slot A's queue check
  // (A's slot is already gated by `rs_ready_a`). When both slots target
  // the same queue, B needs the queue's second free entry.
  logic rs_ready_b;
  always_comb begin
    if (b_to_ioq) begin
      // `ready_b` is for tail+1 (paired with A); `ready` is for tail
      // (B alone). A's IOQ-slot check is owned by `rs_ready_a`.
      rs_ready_b = a_to_ioq ? disp_ioq.ready_b : disp_ioq.ready;
    end else if (b_to_mdq) begin
      rs_ready_b = a_to_mdq ? disp_mdq.free_found_b : disp_mdq.free_found_a;
    end else if (b_to_brq) begin
      rs_ready_b = a_to_brq ? disp_brq.free_found_b : disp_brq.free_found_a;
    end else if (b_tgt_iqa) begin
      rs_ready_b = a_tgt_iqa ? disp_iqa.free_found_b : disp_iqa.free_found_a;
    end else begin
      rs_ready_b = a_tgt_iqb ? disp_iqb.free_found_b : disp_iqb.free_found_a;
    end
  end
  assign rou_exu.ready_b = rs_ready_b;

  // Allocation index for slot B in each queue: when A targets the same
  // queue, B claims the second free entry; otherwise the first.
  assign disp_iqa.b_rs_idx = a_tgt_iqa ? disp_iqa.free_idx_b : disp_iqa.free_idx_a;
  assign disp_iqb.b_rs_idx = a_tgt_iqb ? disp_iqb.free_idx_b : disp_iqb.free_idx_a;
  assign disp_brq.b_rs_idx = a_to_brq ? disp_brq.free_idx_b : disp_brq.free_idx_a;
  assign disp_mdq.b_rs_idx = a_to_mdq ? disp_mdq.free_idx_b : disp_mdq.free_idx_a;
`else
  assign disp_iqa.b_rs_idx = '0;
  assign disp_iqb.b_rs_idx = '0;
  assign disp_brq.b_rs_idx = '0;
  assign disp_mdq.b_rs_idx = '0;
`endif

  // === Accept signals ===
  assign disp_iqa.accept_a = rou_exu.valid && rs_ready_a && a_tgt_iqa;
  assign disp_iqb.accept_a = rou_exu.valid && rs_ready_a && a_tgt_iqb;
  assign disp_brq.accept_a = rou_exu.valid && rs_ready_a && a_to_brq;
  assign disp_mdq.accept_a = rou_exu.valid && rs_ready_a && a_to_mdq;
`ifdef RAPT_DUAL_ISSUE
  assign disp_iqa.accept_b = rou_exu.valid_b && rs_ready_b && b_tgt_iqa;
  assign disp_iqb.accept_b = rou_exu.valid_b && rs_ready_b && b_tgt_iqb;
  assign disp_brq.accept_b = rou_exu.valid_b && rs_ready_b && b_to_brq;
  assign disp_mdq.accept_b = rou_exu.valid_b && rs_ready_b && b_to_mdq;
`else
  assign disp_iqa.accept_b = 1'b0;
  assign disp_iqb.accept_b = 1'b0;
  assign disp_brq.accept_b = 1'b0;
  assign disp_mdq.accept_b = 1'b0;
`endif

  // IOQ accepts: A is paired with B if both target IOQ; else B may go alone.
  assign disp_ioq.accept_a = rou_exu.valid && rs_ready_a && a_to_ioq;
`ifdef RAPT_DUAL_ISSUE
  assign disp_ioq.accept_b_paired = rou_exu.valid && rs_ready_a && a_to_ioq
                                    && rou_exu.valid_b && rs_ready_b && b_to_ioq;
  assign disp_ioq.accept_b_alone = rou_exu.valid_b && rs_ready_b && b_to_ioq && !a_to_ioq;
`else
  assign disp_ioq.accept_b_paired = 1'b0;
  assign disp_ioq.accept_b_alone  = 1'b0;
`endif

  // === PMU aggregation (read by nsim pmu.cc via --public) ===
  // "OoO scheduler has pending work but no ALU-class pipe issued".
  logic [$clog2(BRQ_SIZE):0] occ_brq;
  /* verilator lint_off UNUSEDSIGNAL */
  logic pmu_ooo_valid;
  logic pmu_ooo_valid_found;
  logic pmu_ooo_full;
  /* verilator lint_on UNUSEDSIGNAL */
  assign pmu_ooo_valid = (occ_iqa != '0) || (occ_iqb != '0) || (occ_brq != '0);
  assign pmu_ooo_valid_found = iss_a.valid || iss_b.valid || iss_c.valid;
  // Both ALU IQs full: simple-class dispatch is structurally blocked.
  assign pmu_ooo_full = (occ_iqa == ($clog2(IQA_SIZE) + 1)'(IQA_SIZE))
                     && (occ_iqb == ($clog2(IQB_SIZE) + 1)'(IQB_SIZE));

  // Tie off optional PMU outputs from submodules to avoid empty named-pin connects.
  logic pmu_iqa_full_unused;
  logic pmu_iqb_full_unused;
  logic pmu_brq_full_unused;
  logic pmu_ioq_full_unused;

  // === Issue queues (generic rapt_exu_iq instances) ===
  rapt_exu_iq #(
      .IQ_SIZE (IQA_SIZE),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_iqa (
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .rou_exu      (rou_exu),
      .disp         (disp_iqa),
      .exu_rou      (exu_rou),
      .exu_rou_b    (exu_rou_b),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul   (exu_wb_mul),
      .load_fast    (load_fast),
      .iss          (iss_a),
      .occ_o        (occ_iqa),
      .pmu_iq_full  (pmu_iqa_full_unused)
  );

  rapt_exu_iq #(
      .IQ_SIZE (IQB_SIZE),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_iqb (
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .rou_exu      (rou_exu),
      .disp         (disp_iqb),
      .exu_rou      (exu_rou),
      .exu_rou_b    (exu_rou_b),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul   (exu_wb_mul),
      .load_fast    (load_fast),
      .iss          (iss_b),
      .occ_o        (occ_iqb),
      .pmu_iq_full  (pmu_iqb_full_unused)
  );

  rapt_exu_iq #(
      .IQ_SIZE (BRQ_SIZE),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_brq (
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .rou_exu      (rou_exu),
      .disp         (disp_brq),
      .exu_rou      (exu_rou),
      .exu_rou_b    (exu_rou_b),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul   (exu_wb_mul),
      .load_fast    (load_fast),
      .iss          (iss_c),
      .occ_o        (occ_brq),
      .pmu_iq_full  (pmu_brq_full_unused)
  );

  // === Execution pipes (combinational FU + writeback) ===
  rapt_exu_pipe_a #(
      .ROB_SIZE(ROB_SIZE),
      .XLEN    (XLEN)
  ) u_pipe_a (
      .iss      (iss_a),
      .cmu_bcast(cmu_bcast),
      .csr_bcast(csr_bcast),
      .exu_csr  (exu_csr),
      .exu_rou  (exu_rou),
      .uop_pl   (uop_pl)
  );

  rapt_exu_pipe_b #(
      .XLEN(XLEN)
  ) u_pipe_b (
      .iss      (iss_b),
      .exu_rou_b(exu_rou_b)
  );

  rapt_exu_pipe_c #(
      .XLEN(XLEN)
  ) u_pipe_c (
      .iss      (iss_c),
      .exu_rou_c(exu_rou_c)
  );

  // === Memory + MUL/DIV pipes ===
  rapt_exu_ioq #(
      .IOQ_SIZE(IOQ_SIZE),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_ioq (
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .csr_bcast    (csr_bcast),
      .rou_exu      (rou_exu),
      .disp         (disp_ioq),
      .exu_rou      (exu_rou),
      .exu_rou_b    (exu_rou_b),
      .exu_wb_mul   (exu_wb_mul),
      .exu_lsu      (exu_lsu),
      .exu_l1d      (exu_l1d),
      .exu_ioq_bcast(exu_ioq_bcast),
      .load_fast    (load_fast),
      .pmu_ioq_full (pmu_ioq_full_unused)
  );

  rapt_exu_muldiv #(
      .MDQ_SIZE(MDQ_SIZE),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_muldiv (
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .rou_exu      (rou_exu),
      .disp         (disp_mdq),
      .exu_rou      (exu_rou),
      .exu_rou_b    (exu_rou_b),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul   (exu_wb_mul)
  );

  // ==========================================================================
  //  Assertions (enable with +define+RAPT_ASSERT_EN)
  // ==========================================================================

  // ONE_HOT: each dispatch slot targets exactly one queue when dispatching.
  `RAPT_SVA_IMPLY(clock, reset, EXU_ROUTE_A_ONEHOT, rou_exu.valid,
                  ($onehot({a_to_ioq, a_to_mdq, a_to_brq, a_tgt_iqa, a_tgt_iqb})))
`ifdef RAPT_DUAL_ISSUE
  `RAPT_SVA_IMPLY(clock, reset, EXU_ROUTE_B_ONEHOT, rou_exu.valid_b,
                  ($onehot({b_to_ioq, b_to_mdq, b_to_brq, b_tgt_iqa, b_tgt_iqb})))
`endif

endmodule
