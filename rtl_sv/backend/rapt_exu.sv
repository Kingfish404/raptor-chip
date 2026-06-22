`include "rapt.svh"
`include "rapt_if.svh"

// Execution Unit (EXU) -- top-level wiring & dispatch arbitration.
//
// This module is intentionally thin. It owns:
//   * The arbitration policy that routes each renamed uop to either the
//     Reservation Station (`rapt_exu_rs`) for OoO ALU/branch/CSR/MUL or the
//     In-Order Queue (`rapt_exu_ioq`) for loads / stores / atomics.
//   * The single-driver `rou_exu.ready` / `rou_exu.ready_b` back-pressure
//     to the rename / dispatch pipeline.
//
// All micro-architectural state lives in the two sub-modules; refer there
// for scheduling, age-matrix, MUL FU, ALU/BRU, IOQ ordering, etc.
module rapt_exu #(
    parameter unsigned RS_SIZE  = `RAPT_RS_SIZE,
    parameter unsigned IOQ_SIZE = `RAPT_IOQ_SIZE,
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned PLEN     = `RAPT_PHY_LEN,
    parameter unsigned RLEN     = `RAPT_REG_LEN,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    input clock,
    input reset,

    cmu_bcast_if.in cmu_bcast,

    // No modport: EXU drives ready/ready_b (slave) but RS/IOQ only read (monitor).
    rou_exu_if rou_exu,

    // No modport here: RS drives (.out) while IOQ reads (.in) for forwarding.
    exu_rou_if       exu_rou,
    exu_rou_b_if     exu_rou_b,
    exu_rou_c_if.out exu_rou_c,
    // No modport: IOQ drives (.out) while RS reads (.in) for forwarding.
    exu_ioq_bcast_if exu_ioq_bcast,

    exu_lsu_if.master exu_lsu,
    exu_csr_if.master exu_csr,

    csr_bcast_if.in   csr_bcast,
    exu_l1d_if.master exu_l1d,

    // Dispatch-only uop payload snapshot from ROU (read by RS at issue time)
    input rapt_pkg::uop_payload_t uop_pl[ROB_SIZE]
);

  // === Sub-module dispatch handshakes ===
  exu_disp_rs_if #(.RS_SIZE(RS_SIZE)) disp_rs ();
  exu_disp_ioq_if #(.IOQ_SIZE(IOQ_SIZE)) disp_ioq ();
  exu_load_fast_if #(.PLEN(PLEN)) load_fast ();

  // === Arbitration ===
  // A uop goes to IOQ if it touches memory (load/store/atomic), otherwise
  // RS. Slot B (dual issue) follows the same rule independently.
  logic a_to_ioq;
  assign a_to_ioq = (rou_exu.uop.wen || rou_exu.uop.ren);
`ifdef RAPT_DUAL_ISSUE
  logic b_to_ioq;
  assign b_to_ioq = (rou_exu.uop_b.wen || rou_exu.uop_b.ren);
`endif

  // Slot-A readiness: the chosen queue must have room.
  //
  // Note (MUL congestion): we intentionally do NOT gate on `disp_rs.mul_found`
  // here. The RS already supports multiple in-flight MUL uops:
  //   * `rs_mul_vec[i]` excludes entries that are already issued/completed,
  //     so the MUL picker only re-picks fresh, unissued MULs.
  //   * The MUL FU back-pressures issue via `in_valid(mul_found && mul_ready)`,
  //     so even when several MULs sit in RS only one is in flight.
  // Letting MULs queue in RS overlaps their long latency with surrounding
  // ALU/branch work instead of stalling dispatch.
  logic rs_ready_a;
  assign rs_ready_a = a_to_ioq ? disp_ioq.ready : disp_rs.free_found_a;
  assign rou_exu.ready = rs_ready_a;

`ifdef RAPT_DUAL_ISSUE
  // Slot-B readiness -- computed independently of slot A's queue check
  // (A's slot is already gated by `rs_ready_a`). For the paired-IOQ case we
  // only need B's own slot (`ready_b`); for B-alone-IOQ we need the head slot
  // (`ready`); RS allocation uses the next-free index appropriate for B.
  logic rs_ready_b;
  always_comb begin
    if (b_to_ioq) begin
      // Slot B -> IOQ. `ready_b` is for tail+1 (paired with A); `ready` is
      // for tail (B alone). A's IOQ-slot check is owned by `rs_ready_a`.
      rs_ready_b = a_to_ioq ? disp_ioq.ready_b : disp_ioq.ready;
    end else begin
      // Slot B -> RS. When A took an IOQ slot, B claims the first free RS
      // entry (`free_idx_a`); when both go to RS, B claims the second
      // free entry (`free_idx_b`).
      rs_ready_b = a_to_ioq ? disp_rs.free_found_a : disp_rs.free_found_b;
    end
  end
  assign rou_exu.ready_b  = rs_ready_b;

  // RS index for slot-B allocation: A-to-IOQ frees free_idx_a for B.
  assign disp_rs.b_rs_idx = a_to_ioq ? disp_rs.free_idx_a : disp_rs.free_idx_b;
`else
  assign disp_rs.b_rs_idx = '0;
`endif

  // === Accept signals ===
  // RS accepts: gated by valid + readiness + non-IOQ destination.
  assign disp_rs.accept_a = rou_exu.valid && rs_ready_a && !a_to_ioq;
`ifdef RAPT_DUAL_ISSUE
  assign disp_rs.accept_b = rou_exu.valid_b && rs_ready_b && !b_to_ioq;
`else
  assign disp_rs.accept_b = 1'b0;
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

  // Tie off optional PMU outputs from submodules to avoid empty named-pin connects.
  logic pmu_rs_full_unused;
  logic pmu_ioq_full_unused;

  // === Sub-module instantiation ===
  rapt_exu_rs #(
      .RS_SIZE (RS_SIZE),
      .ROB_SIZE(ROB_SIZE),
      .PLEN    (PLEN),
      .RLEN    (RLEN),
      .XLEN    (XLEN)
  ) u_rs (
      .clock        (clock),
      .reset        (reset),
      .cmu_bcast    (cmu_bcast),
      .csr_bcast    (csr_bcast),
      .rou_exu      (rou_exu),
      .disp         (disp_rs),
      .exu_ioq_bcast(exu_ioq_bcast),
      .load_fast    (load_fast),
      .exu_csr      (exu_csr),
      .exu_rou      (exu_rou),
      .exu_rou_b    (exu_rou_b),
      .exu_rou_c    (exu_rou_c),
      .uop_pl       (uop_pl),
      .pmu_rs_full  (pmu_rs_full_unused)
  );

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
      .exu_lsu      (exu_lsu),
      .exu_l1d      (exu_l1d),
      .exu_ioq_bcast(exu_ioq_bcast),
      .load_fast    (load_fast),
      .pmu_ioq_full (pmu_ioq_full_unused)
  );

endmodule
