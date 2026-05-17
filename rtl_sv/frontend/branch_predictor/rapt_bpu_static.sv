`include "rapt.svh"
`include "rapt_bpu_dirp_if.svh"

// Static direction predictor: always predicts "not taken".
//
// Smallest possible direction predictor (zero state). Used as a control
// reference and to estimate BTB-only performance.
(* keep_hierarchy *)
module rapt_bpu_static #(
    parameter int XLEN    = `RAPT_XLEN,
    parameter int GHR_LEN = 64,
    parameter int PHR_LEN = 8,
    // DEPTH: unused here (static predictor has zero state); accepted so
    // every DIRP flavor presents the same parameter list to rapt_bpu.
    parameter int DEPTH   = `RAPT_PHT_SIZE
) (
    `RAPT_BPU_DIRP_PORTS
);
  /* verilator lint_off UNUSEDSIGNAL */
  /* verilator lint_off UNUSEDPARAM */
  // Silence "unused" for the entire DIRP port group when this flavor is selected.
  wire _u = |{ren, raddr, r_ghr, r_phr, update_en, update_pc, update_ghr,
              update_phr, update_taken, update_mispred, init, clock, reset};
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on UNUSEDPARAM */
  assign rd_taken = 1'b0;
endmodule
