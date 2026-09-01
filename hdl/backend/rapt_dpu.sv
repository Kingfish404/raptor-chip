`include "rapt.svh"
`include "rapt_if.svh"

// Dispatch Unit (DPU) -- classification, allocation, and back-pressure.
//
// This module is intentionally thin. It owns:
//   * The routing policy that steers each renamed uop to one of five
//     scheduler queues feeding six execution paths:
//       IOQ    - loads / stores / atomics (in-order memory queue)
//       MULDIV - pure MUL/DIV arithmetic (private IQ + tag-based FU)
//       FPQ    - scalar F/D operations (dedicated IQ + FPU, shares CDB0)
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
// issue queues (`rapt_iq`), the combinational pipes and FPU
// (`rapt_ieu_pipe_alu_csr`, `rapt_ieu_pipe_alu`, and
// `rapt_ieu_pipe_branch`), the MUL/DIV pipe, and the IOQ.
module rapt_dpu (
    input clock,
    input reset,

    // No modport: DPU drives ready/ready_b while execution units only read.
    rou_exu_if rou_exu,
    dpu_iq_if.top disp_alq,
    dpu_iq_if.top disp_brq,
    dpu_iq_if.top disp_mdq,
    dpu_iq_if.top disp_fpq,
    dpu_ioq_if.top disp_ioq
);

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

  // FP loads/stores advertise ren/wen and remain in the IOQ. All other
  // scalar-FP operations execute through the independent FP issue queue.
  function automatic logic uop_is_fp_exec(input rapt_pkg::uop_t u);
    return u.fp_valid && !u.wen && !u.ren;
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
  logic a_to_ioq, a_to_mdq, a_to_fpq, a_to_brq, a_to_alq;
  // A decoded trap must reach ALU-CSR before an IOQ request can issue.
  assign a_to_ioq = (rou_exu.uop.wen || rou_exu.uop.ren) && !rou_exu.uop.trap;
  assign a_to_mdq = !a_to_ioq && uop_is_mdq(rou_exu.uop);
  assign a_to_fpq = !a_to_ioq && !a_to_mdq && uop_is_fp_exec(rou_exu.uop);
  assign a_to_brq = !a_to_ioq && !a_to_mdq && !a_to_fpq && rou_exu.uop.ben;
  assign a_to_alq = !a_to_ioq && !a_to_mdq && !a_to_fpq && !a_to_brq;
`ifdef RAPT_DUAL_ISSUE
  logic b_to_ioq, b_to_mdq, b_to_fpq, b_to_brq, b_to_alq;
  assign b_to_ioq = (rou_exu.uop_b.wen || rou_exu.uop_b.ren) && !rou_exu.uop_b.trap;
  assign b_to_mdq = !b_to_ioq && uop_is_mdq(rou_exu.uop_b);
  assign b_to_fpq = !b_to_ioq && !b_to_mdq && uop_is_fp_exec(rou_exu.uop_b);
  assign b_to_brq = !b_to_ioq && !b_to_mdq && !b_to_fpq && rou_exu.uop_b.ben;
  assign b_to_alq = !b_to_ioq && !b_to_mdq && !b_to_fpq && !b_to_brq;
`endif

  // ALU-port block flag: CSR/system/trap entries may only issue to ALU-CSR.
  // Captured into the ALQ entry at dispatch (BRQ/MDQ never use it).
  assign disp_alq.iss_b_block_a = uop_requires_alu_csr(rou_exu.uop);
  assign disp_brq.iss_b_block_a = 1'b0;
  assign disp_mdq.iss_b_block_a = 1'b0;
  assign disp_fpq.iss_b_block_a = 1'b0;
`ifdef RAPT_DUAL_ISSUE
  assign disp_alq.iss_b_block_b = uop_requires_alu_csr(rou_exu.uop_b);
`else
  assign disp_alq.iss_b_block_b = 1'b0;
`endif
  assign disp_brq.iss_b_block_b = 1'b0;
  assign disp_mdq.iss_b_block_b = 1'b0;
  assign disp_fpq.iss_b_block_b = 1'b0;

  // === Slot-A readiness: the chosen queue must have room ===
  logic rs_ready_a;
  assign rs_ready_a = a_to_ioq ? disp_ioq.ready
                    : a_to_mdq ? disp_mdq.free_found_a
                    : a_to_fpq ? disp_fpq.free_found_a
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
    end else if (b_to_fpq) begin
      rs_ready_b = a_to_fpq ? disp_fpq.free_found_b : disp_fpq.free_found_a;
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
  assign disp_fpq.b_rs_idx = a_to_fpq ? disp_fpq.free_idx_b : disp_fpq.free_idx_a;
`else
  assign disp_alq.b_rs_idx = '0;
  assign disp_brq.b_rs_idx = '0;
  assign disp_mdq.b_rs_idx = '0;
  assign disp_fpq.b_rs_idx = '0;
`endif

  // === Accept signals ===
  assign disp_alq.accept_a = rou_exu.valid && rs_ready_a && a_to_alq;
  assign disp_brq.accept_a = rou_exu.valid && rs_ready_a && a_to_brq;
  assign disp_mdq.accept_a = rou_exu.valid && rs_ready_a && a_to_mdq;
  assign disp_fpq.accept_a = rou_exu.valid && rs_ready_a && a_to_fpq;
`ifdef RAPT_DUAL_ISSUE
  assign disp_alq.accept_b = rou_exu.valid_b && rs_ready_b && b_to_alq;
  assign disp_brq.accept_b = rou_exu.valid_b && rs_ready_b && b_to_brq;
  assign disp_mdq.accept_b = rou_exu.valid_b && rs_ready_b && b_to_mdq;
  assign disp_fpq.accept_b = rou_exu.valid_b && rs_ready_b && b_to_fpq;
`else
  assign disp_alq.accept_b = 1'b0;
  assign disp_brq.accept_b = 1'b0;
  assign disp_mdq.accept_b = 1'b0;
  assign disp_fpq.accept_b = 1'b0;
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

  // ==========================================================================
  //  Assertions (enable with +define+RAPT_ASSERT_EN)
  // ==========================================================================

  // ONE_HOT: each dispatch slot targets exactly one queue when dispatching.
  `RAPT_SVA_IMPLY(clock, reset, DPU_ROUTE_A_ONEHOT, rou_exu.valid, ($onehot
                  ({a_to_ioq, a_to_mdq, a_to_fpq, a_to_brq, a_to_alq})))
`ifdef RAPT_DUAL_ISSUE
  `RAPT_SVA_IMPLY(clock, reset, DPU_ROUTE_B_ONEHOT, rou_exu.valid_b, ($onehot
                  ({b_to_ioq, b_to_mdq, b_to_fpq, b_to_brq, b_to_alq})))
`endif

endmodule
