`include "ysyx.svh"
`include "ysyx_if.svh"

// Physical Register File - multi-ported register storage with valid/transient tracking.
// Instantiated at the top level (ysyx.sv) as a shared resource:
//   - Read by ROU (operand fetch via exu_prf_if)
//   - Written by EXU ALU (exu_rou_if) and IOQ (exu_ioq_bcast_if)
//   - Commit/dealloc controlled by CMU (rou_cmu_if, cmu_bcast_if)
// On flush, registers marked transient are invalidated and zeroed.
module ysyx_prf #(
    parameter unsigned RNUM = `YSYX_REG_SIZE,
    parameter unsigned PNUM = `YSYX_PHY_SIZE,
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
) (
    input clock,
    input reset,

    // Read ports (from ROU operand fetch)
    exu_prf_if.slave prf_rd,

    // Write source A: EXU ALU result
    exu_rou_if.in exu_rou,

    // Write source B: IOQ broadcast (LSU/CSR)
    exu_ioq_bcast_if.in exu_ioq_bcast,

    // Commit / dealloc / flush
    rou_cmu_if.in  rou_cmu,
    cmu_bcast_if.in cmu_bcast,

    // Rename map snapshots (from RNU, for debug register view)
    input [PLEN-1:0] map_snapshot [RNUM],
    input [PLEN-1:0] rat_snapshot [RNUM],

    // Debug: architectural register view (committed / speculative)
    output [XLEN-1:0] rf     [RNUM],
    output [XLEN-1:0] rf_map [RNUM]
);
  logic [XLEN-1:0]  prf       [PNUM];
  logic [PNUM-1:0]  prf_valid;
  logic [PNUM-1:0]  prf_transient;

  // ---- Read ports (combinational) ----
  assign prf_rd.pv1       = prf[prf_rd.pr1];
  assign prf_rd.pv1_valid = prf_valid[prf_rd.pr1];
  assign prf_rd.pv2       = prf[prf_rd.pr2];
  assign prf_rd.pv2_valid = prf_valid[prf_rd.pr2];

  // ---- Write port extraction ----
  logic             wr_a_en;
  logic [PLEN-1:0]  wr_a_addr;
  logic [XLEN-1:0]  wr_a_data;
  assign wr_a_en   = exu_rou.valid && exu_rou.rd != 0;
  assign wr_a_addr = exu_rou.prd;
  assign wr_a_data = exu_rou.result;

  logic             wr_b_en;
  logic [PLEN-1:0]  wr_b_addr;
  logic [XLEN-1:0]  wr_b_data;
  assign wr_b_en   = exu_ioq_bcast.valid && exu_ioq_bcast.rd != 0;
  assign wr_b_addr = exu_ioq_bcast.prd;
  assign wr_b_data = exu_ioq_bcast.result;

  // ---- Commit / dealloc ----
  logic commit_dealloc;
  assign commit_dealloc = rou_cmu.valid && rou_cmu.rd != 0;

  // ---- Write / state update ----
  always @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < PNUM; i = i + 1) begin
        prf[i] <= '0;
      end
      prf_valid     <= {{(PNUM - RNUM){1'b0}}, {RNUM{1'b1}}};
      prf_transient <= '0;
    end else begin
      for (integer i = 0; i < PNUM; i = i + 1) begin
        if (commit_dealloc && rou_cmu.prs == i[PLEN-1:0]) begin
          // Old physical register freed → invalidate
          prf_valid[i] <= 1'b0;
        end else if (commit_dealloc && rou_cmu.prd == i[PLEN-1:0]) begin
          // Committed → no longer transient
          prf_transient[i] <= 1'b0;
        end else if (cmu_bcast.flush_pipe && prf_transient[i]) begin
          // Flush: discard speculative writes
          prf_valid[i]     <= 1'b0;
          prf_transient[i] <= 1'b0;
          prf[i]           <= '0;
        end else if (!cmu_bcast.flush_pipe && wr_a_en && wr_a_addr == i[PLEN-1:0]) begin
          prf[i]           <= wr_a_data;
          prf_valid[i]     <= 1'b1;
          prf_transient[i] <= 1'b1;
        end else if (!cmu_bcast.flush_pipe && wr_b_en && wr_b_addr == i[PLEN-1:0]) begin
          prf[i]           <= wr_b_data;
          prf_valid[i]     <= 1'b1;
          prf_transient[i] <= 1'b1;
        end
      end
    end
  end

  // ---- Debug: architectural register view ----
  genvar gi;
  generate
    for (gi = 0; gi < RNUM; gi = gi + 1) begin : gen_rf_debug
      assign rf[gi]     = prf[rat_snapshot[gi]];
      assign rf_map[gi] = prf[map_snapshot[gi]];
    end
  endgenerate
endmodule
