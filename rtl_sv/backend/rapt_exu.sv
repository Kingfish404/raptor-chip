`include "rapt.svh"
`include "rapt_if.svh"

// Execution Unit (EXU) -- top-level wiring & dispatch arbitration.
//
// This module is intentionally thin. It owns:
//   * The routing policy that steers each renamed uop to one of the four
//     scheduler queues feeding five execution pipes:
//       IOQ    - loads / stores / atomics (in-order memory queue)
//       MULDIV - pure MUL/DIV arithmetic (private IQ + tag-based FU)
//       BRQ    - conditional branches (compare-only Branch pipe)
//       ALQ    - everything else: ONE shared ALU issue queue with TWO
//                issue ports feeding the ALU-CSR pipe (full: CSR/system/trap)
//                and ALU pipe (simple arithmetic + jumps). CSR/system/trap
//                entries are flagged ALU-port-blocked at dispatch so they
//                only ever issue to ALU-CSR. Sharing one entry pool lets the two
//                oldest ready uops issue together every cycle, with no
//                dispatch-time load-balancing heuristic.
//   * The single-driver `rou_exu.ready` / `rou_exu.ready_b` back-pressure
//     to the rename / dispatch pipeline.
//
// All micro-architectural state lives in the sub-modules: the generic
// issue queues (`rapt_exu_iq`), the combinational pipes
// (`rapt_exu_pipe_alu_csr`, `rapt_exu_pipe_alu`, and
// `rapt_exu_pipe_branch`), the MUL/DIV pipe, and the IOQ.
module rapt_exu #(
    parameter unsigned ALQ_SIZE = `RAPT_RS_SIZE,
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
    exu_wb_if wb_alu_csr,
    exu_wb_if wb_alu,
    exu_wb_if wb_branch,
    exu_wb_if exu_ioq_bcast,
    exu_wb_if exu_wb_mul,

    exu_lsu_if.master exu_lsu,
    exu_csr_if.master exu_csr,

    csr_bcast_if.in   csr_bcast,
    exu_l1d_if.master exu_l1d,

    // Dispatch-only uop payload snapshot from ROU (read by ALU-CSR at issue)
    input rapt_pkg::uop_payload_t uop_pl[ROB_SIZE]
);

  // === Sub-module dispatch handshakes ===
  exu_disp_rs_if #(.RS_SIZE(ALQ_SIZE)) disp_alq ();
  exu_disp_rs_if #(.RS_SIZE(BRQ_SIZE)) disp_brq ();
  exu_disp_rs_if #(.RS_SIZE(MDQ_SIZE)) disp_mdq ();
  exu_disp_ioq_if #(.IOQ_SIZE(IOQ_SIZE)) disp_ioq ();
  exu_load_fast_if #(.PLEN(PLEN)) load_fast ();

  // === Issue buses (IQ -> pipe) ===
  exu_iq_iss_if #(
      .PLEN(PLEN),
      .RLEN(RLEN),
      .XLEN(XLEN)
  ) iss_alu_csr ();
  exu_iq_iss_if #(
      .PLEN(PLEN),
      .RLEN(RLEN),
      .XLEN(XLEN)
  ) iss_alu ();
  exu_iq_iss_if #(
      .PLEN(PLEN),
      .RLEN(RLEN),
      .XLEN(XLEN)
  ) iss_branch ();
  // Unused second issue port of the single-port BRQ (tied off inside).
  exu_iq_iss_if #(
      .PLEN(PLEN),
      .RLEN(RLEN),
      .XLEN(XLEN)
  ) iss_branch_unused ();

  // === Classification ===
  // The MDQ predicate must be airtight: a trap-marked or system uop may
  // carry a garbage `alu` in the MUL range (e.g. fetch page fault), and
  // only the ALU-CSR pipe handles CSR / trap / redirect semantics.
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

  // ALU-CSR-only: CSR / system / trap semantics live exclusively in that pipe.
  // (Conditional branches are checked separately and win: a trap-marked
  // branch resolves on the Branch pipe as before, with trap info already in the
  // ROB from dispatch.)
  function automatic logic uop_requires_alu_csr(input rapt_pkg::uop_t u);
    return u.system || u.trap || u.ecall || u.ebreak || u.mret || u.sret || (u.csr_csw != '0);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // Per-slot routing class (mutually exclusive; priority IOQ > MDQ > BRQ > ALQ)
  logic a_to_ioq, a_to_mdq, a_to_brq, a_to_alq;
  assign a_to_ioq = (rou_exu.uop.wen || rou_exu.uop.ren);
  assign a_to_mdq = !a_to_ioq && uop_is_mdq(rou_exu.uop);
  assign a_to_brq = !a_to_ioq && !a_to_mdq && rou_exu.uop.ben;
  assign a_to_alq = !a_to_ioq && !a_to_mdq && !a_to_brq;
`ifdef RAPT_DUAL_ISSUE
  logic b_to_ioq, b_to_mdq, b_to_brq, b_to_alq;
  assign b_to_ioq = (rou_exu.uop_b.wen || rou_exu.uop_b.ren);
  assign b_to_mdq = !b_to_ioq && uop_is_mdq(rou_exu.uop_b);
  assign b_to_brq = !b_to_ioq && !b_to_mdq && rou_exu.uop_b.ben;
  assign b_to_alq = !b_to_ioq && !b_to_mdq && !b_to_brq;
`endif

  // ALU-port block flag: CSR/system/trap entries may only issue to ALU-CSR.
  // Captured into the ALQ entry at dispatch (BRQ/MDQ never use it).
  assign disp_alq.iss_b_block_a = uop_requires_alu_csr(rou_exu.uop);
  assign disp_brq.iss_b_block_a = 1'b0;
  assign disp_mdq.iss_b_block_a = 1'b0;
`ifdef RAPT_DUAL_ISSUE
  assign disp_alq.iss_b_block_b = uop_requires_alu_csr(rou_exu.uop_b);
`else
  assign disp_alq.iss_b_block_b = 1'b0;
`endif
  assign disp_brq.iss_b_block_b = 1'b0;
  assign disp_mdq.iss_b_block_b = 1'b0;

  // === Slot-A readiness: the chosen queue must have room ===
  logic rs_ready_a;
  assign rs_ready_a = a_to_ioq ? disp_ioq.ready
                    : a_to_mdq ? disp_mdq.free_found_a
                    : a_to_brq ? disp_brq.free_found_a
                    : disp_alq.free_found_a;
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
    end else begin
      rs_ready_b = a_to_alq ? disp_alq.free_found_b : disp_alq.free_found_a;
    end
  end
  assign rou_exu.ready_b   = rs_ready_b;

  // Allocation index for slot B in each queue: when A targets the same
  // queue, B claims the second free entry; otherwise the first.
  assign disp_alq.b_rs_idx = a_to_alq ? disp_alq.free_idx_b : disp_alq.free_idx_a;
  assign disp_brq.b_rs_idx = a_to_brq ? disp_brq.free_idx_b : disp_brq.free_idx_a;
  assign disp_mdq.b_rs_idx = a_to_mdq ? disp_mdq.free_idx_b : disp_mdq.free_idx_a;
`else
  assign disp_alq.b_rs_idx = '0;
  assign disp_brq.b_rs_idx = '0;
  assign disp_mdq.b_rs_idx = '0;
`endif

  // === Accept signals ===
  assign disp_alq.accept_a = rou_exu.valid && rs_ready_a && a_to_alq;
  assign disp_brq.accept_a = rou_exu.valid && rs_ready_a && a_to_brq;
  assign disp_mdq.accept_a = rou_exu.valid && rs_ready_a && a_to_mdq;
`ifdef RAPT_DUAL_ISSUE
  assign disp_alq.accept_b = rou_exu.valid_b && rs_ready_b && b_to_alq;
  assign disp_brq.accept_b = rou_exu.valid_b && rs_ready_b && b_to_brq;
  assign disp_mdq.accept_b = rou_exu.valid_b && rs_ready_b && b_to_mdq;
`else
  assign disp_alq.accept_b = 1'b0;
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
  logic [$clog2(ALQ_SIZE):0] occ_alq;
  logic [$clog2(BRQ_SIZE):0] occ_brq;
  /* verilator lint_off UNUSEDSIGNAL */
  logic pmu_ooo_valid;
  logic pmu_ooo_valid_found;
  logic pmu_ooo_full;
  /* verilator lint_on UNUSEDSIGNAL */
  assign pmu_ooo_valid = (occ_alq != '0) || (occ_brq != '0);
  assign pmu_ooo_valid_found = iss_alu_csr.valid || iss_alu.valid || iss_branch.valid;
  // ALQ full: ALU-class dispatch is structurally blocked.
  assign pmu_ooo_full = (occ_alq == ($clog2(ALQ_SIZE) + 1)'(ALQ_SIZE));

  // Tie off optional PMU outputs from submodules to avoid empty named-pin connects.
  logic pmu_alq_full_unused;
  logic pmu_brq_full_unused;
  logic pmu_ioq_full_unused;

  // === Issue queues (generic rapt_exu_iq instances) ===
  rapt_exu_iq #(
      .IQ_SIZE  (ALQ_SIZE),
      .HAS_ISS_B(1'b1),
      .ROB_SIZE (ROB_SIZE),
      .PLEN     (PLEN),
      .RLEN     (RLEN),
      .XLEN     (XLEN)
  ) u_alq (
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .rou_exu      (rou_exu),
      .disp         (disp_alq),
      .exu_rou      (wb_alu_csr),
      .exu_rou_b    (wb_alu),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul   (exu_wb_mul),
      .load_fast    (load_fast),
      .iss          (iss_alu_csr),
      .iss_b        (iss_alu),
      .occ_o        (occ_alq),
      .pmu_iq_full  (pmu_alq_full_unused)
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
      .exu_rou      (wb_alu_csr),
      .exu_rou_b    (wb_alu),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul   (exu_wb_mul),
      .load_fast    (load_fast),
      .iss          (iss_branch),
      .iss_b        (iss_branch_unused),
      .occ_o        (occ_brq),
      .pmu_iq_full  (pmu_brq_full_unused)
  );

  // === Execution pipes (combinational FU + writeback) ===
  rapt_exu_pipe_alu_csr #(
      .ROB_SIZE(ROB_SIZE),
      .XLEN    (XLEN)
  ) u_pipe_alu_csr (
      .iss       (iss_alu_csr),
      .cmu_bcast (cmu_bcast),
      .csr_bcast (csr_bcast),
      .exu_csr   (exu_csr),
      .wb_alu_csr(wb_alu_csr),
      .uop_pl    (uop_pl)
  );

  rapt_exu_pipe_alu #(
      .XLEN(XLEN)
  ) u_pipe_alu (
      .iss   (iss_alu),
      .wb_alu(wb_alu)
  );

  rapt_exu_pipe_branch #(
      .XLEN(XLEN)
  ) u_pipe_branch (
      .iss      (iss_branch),
      .wb_branch(wb_branch)
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
      .exu_rou      (wb_alu_csr),
      .exu_rou_b    (wb_alu),
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
      .exu_rou      (wb_alu_csr),
      .exu_rou_b    (wb_alu),
      .exu_ioq_bcast(exu_ioq_bcast),
      .exu_wb_mul   (exu_wb_mul)
  );

  // ==========================================================================
  //  Assertions (enable with +define+RAPT_ASSERT_EN)
  // ==========================================================================

  // ONE_HOT: each dispatch slot targets exactly one queue when dispatching.
  `RAPT_SVA_IMPLY(clock, reset, EXU_ROUTE_A_ONEHOT, rou_exu.valid, ($onehot({a_to_ioq, a_to_mdq,
                                                                             a_to_brq, a_to_alq})))
`ifdef RAPT_DUAL_ISSUE
  `RAPT_SVA_IMPLY(clock, reset, EXU_ROUTE_B_ONEHOT, rou_exu.valid_b, ($onehot
                  ({b_to_ioq, b_to_mdq, b_to_brq, b_to_alq})))
`endif

endmodule
