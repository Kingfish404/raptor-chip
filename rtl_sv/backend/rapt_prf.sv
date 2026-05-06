`include "rapt.svh"
`include "rapt_if.svh"

// Physical Register File - multi-ported register storage with valid/transient tracking.
// Instantiated at the top level (rapt.sv) as a shared resource:
//   - Read by ROU (operand fetch via exu_prf_if)
//   - Written by EXU ALU (exu_rou_if) and IOQ (exu_ioq_bcast_if)
//   - Commit/dealloc controlled by CMU (rou_cmu_if, cmu_bcast_if)
// On flush, registers marked transient are invalidated and zeroed.
module rapt_prf #(
    parameter unsigned RNUM = `RAPT_REG_SIZE,
    parameter unsigned PNUM = `RAPT_PHY_SIZE,
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    parameter unsigned XLEN = `RAPT_XLEN
) (
    input clock,
    input reset,

    // Read ports (from ROU operand fetch)
    exu_prf_if.slave prf_rd,

    // Write source A: EXU ALU result
    exu_rou_if.in exu_rou,

    // Write source C: EXU ALU slot-B (pure arithmetic)
    exu_rou_b_if.in exu_rou_b,

    // Write source B: IOQ broadcast (LSU/CSR)
    exu_ioq_bcast_if.in exu_ioq_bcast,

    // Commit / dealloc / flush
    rou_cmu_if.in   rou_cmu,
    cmu_bcast_if.in cmu_bcast,

    // Rename map snapshots (from RNU, for debug register view)
    input [PLEN-1:0] map_snapshot[RNUM],
    input [PLEN-1:0] rat_snapshot[RNUM],

    // Debug: architectural register view (committed / speculative)
    output [XLEN-1:0] rf    [RNUM],
    output [XLEN-1:0] rf_map[RNUM],

    // Debug write port (used by rapt_dm abstract access_register while
    // the core is halted). Writes go to the committed mapping
    // `prf_arr[rat_snapshot[dbg_addr_i]]`. x0 writes are silently dropped.
    // Caller must guarantee halted_o is asserted before pulsing dbg_we_i,
    // otherwise the write races with normal commit-time updates.
    input  logic            dbg_we_i,
    input  logic [4:0]      dbg_addr_i,
    input  logic [XLEN-1:0] dbg_wdata_i

`ifdef RAPT_RVFI
    // RVFI: read destination register values at commit time
    , output [XLEN-1:0] rvfi_rd_wdata_a
    , output [XLEN-1:0] rvfi_rd_wdata_b
`endif
);
  logic [XLEN-1:0] prf_arr           [PNUM];
  logic [PNUM-1:0] prf_valid;
  logic [PNUM-1:0] prf_transient;

`ifdef RAPT_RVFI
  assign rvfi_rd_wdata_a = (rou_cmu.rd_a != 0) ? prf_arr[rou_cmu.prd_a] : '0;
  assign rvfi_rd_wdata_b = (rou_cmu.rd_b != 0) ? prf_arr[rou_cmu.prd_b] : '0;
`endif

  // ---- Read ports (combinational) ----
  assign prf_rd.pv1_a       = prf_arr[prf_rd.pr1_a];
  assign prf_rd.pv1_a_valid = prf_valid[prf_rd.pr1_a];
  assign prf_rd.pv2_a       = prf_arr[prf_rd.pr2_a];
  assign prf_rd.pv2_a_valid = prf_valid[prf_rd.pr2_a];

`ifdef RAPT_DUAL_ISSUE
  assign prf_rd.pv1_b       = prf_arr[prf_rd.pr1_b];
  assign prf_rd.pv1_b_valid = prf_valid[prf_rd.pr1_b];
  assign prf_rd.pv2_b       = prf_arr[prf_rd.pr2_b];
  assign prf_rd.pv2_b_valid = prf_valid[prf_rd.pr2_b];
`endif

  // ---- Write port extraction ----
  logic            wr_a_en;
  logic [PLEN-1:0] wr_a_addr;
  logic [XLEN-1:0] wr_a_data;
  assign wr_a_en   = exu_rou.valid && exu_rou.rd != 0;
  assign wr_a_addr = exu_rou.prd;
  assign wr_a_data = exu_rou.result;

  logic            wr_b_en;
  logic [PLEN-1:0] wr_b_addr;
  logic [XLEN-1:0] wr_b_data;
  assign wr_b_en   = exu_ioq_bcast.valid && exu_ioq_bcast.rd != 0;
  assign wr_b_addr = exu_ioq_bcast.prd;
  assign wr_b_data = exu_ioq_bcast.result;

  logic            wr_c_en;
  logic [PLEN-1:0] wr_c_addr;
  logic [XLEN-1:0] wr_c_data;
  assign wr_c_en   = exu_rou_b.valid && exu_rou_b.rd != 0;
  assign wr_c_addr = exu_rou_b.prd;
  assign wr_c_data = exu_rou_b.result;

  // ---- Commit / dealloc ----
  logic commit_dealloc;
  assign commit_dealloc = rou_cmu.valid_a && rou_cmu.rd_a != 0;

  logic commit_dealloc_b;
  assign commit_dealloc_b = rou_cmu.valid_b && rou_cmu.rd_b != 0;

  // Pre-decode addresses to one-hot vectors (shared decoders, reduce per-entry fanin)
  logic [PNUM-1:0] dealloc_prs_oh, dealloc_prs_b_oh;
  logic [PNUM-1:0] settle_prd_oh, settle_prd_b_oh;
  logic [PNUM-1:0] wr_a_oh, wr_b_oh, wr_c_oh;

  always_comb begin
    dealloc_prs_oh   = '0;
    dealloc_prs_b_oh = '0;
    settle_prd_oh    = '0;
    settle_prd_b_oh  = '0;
    wr_a_oh          = '0;
    wr_b_oh          = '0;
    wr_c_oh          = '0;
    if (commit_dealloc_b) dealloc_prs_b_oh[rou_cmu.prs_b] = 1'b1;
    if (commit_dealloc) dealloc_prs_oh[rou_cmu.prs_a] = 1'b1;
    if (commit_dealloc_b) settle_prd_b_oh[rou_cmu.prd_b] = 1'b1;
    if (commit_dealloc) settle_prd_oh[rou_cmu.prd_a] = 1'b1;
    if (wr_a_en) wr_a_oh[wr_a_addr] = 1'b1;
    if (wr_b_en) wr_b_oh[wr_b_addr] = 1'b1;
    if (wr_c_en) wr_c_oh[wr_c_addr] = 1'b1;
  end

  // ---- Write / state update ----
  always_ff @(posedge clock) begin
    if (reset) begin
      // Only valid/transient need a defined reset value; `prf_arr` data is
      // don't-care because every read is gated by `prf_valid[]`. Skipping
      // PNUM*XLEN data flop reset endpoints removes that fanout from the
      // global reset network (helped STA recovery on reset's BUF_X1 hot
      // path).
      prf_valid     <= {{(PNUM - RNUM) {1'b0}}, {RNUM{1'b1}}};
      prf_transient <= '0;
    end else begin
      for (integer i = 0; i < PNUM; i = i + 1) begin
        // Free old physical register (prs): slot 1 then slot 0 priority
        if (dealloc_prs_b_oh[i]) begin
          prf_valid[i] <= 1'b0;
        end else if (dealloc_prs_oh[i]) begin
          prf_valid[i] <= 1'b0;
          // Settle committed register (prd): no longer transient
        end else if (settle_prd_b_oh[i]) begin
          prf_transient[i] <= 1'b0;
        end else if (settle_prd_oh[i]) begin
          prf_transient[i] <= 1'b0;
        end else if (cmu_bcast.flush_pipe && prf_transient[i]) begin
          // Flush: discard speculative writes. `prf_arr[i]` itself is left
          // intact -- the read side filters with `prf_valid` so the data
          // is don't-care. This avoids dragging `flush_pipe` into the
          // PNUM*XLEN data-flop D mux fanin.
          prf_valid[i]     <= 1'b0;
          prf_transient[i] <= 1'b0;
        end else if (!cmu_bcast.flush_pipe && wr_a_oh[i]) begin
          prf_arr[i]           <= wr_a_data;
          prf_valid[i]     <= 1'b1;
          prf_transient[i] <= 1'b1;
        end else if (!cmu_bcast.flush_pipe && wr_b_oh[i]) begin
          prf_arr[i]           <= wr_b_data;
          prf_valid[i]     <= 1'b1;
          prf_transient[i] <= 1'b1;
        end else if (!cmu_bcast.flush_pipe && wr_c_oh[i]) begin
          prf_arr[i]           <= wr_c_data;
          prf_valid[i]     <= 1'b1;
          prf_transient[i] <= 1'b1;
        end else if (dbg_we_i && dbg_addr_i != 5'd0
                     && rat_snapshot[dbg_addr_i] == PLEN'(i)) begin
          // Halt-time abstract write: target the committed phys reg of
          // architectural reg `dbg_addr_i`. Caller must hold halted=1.
          prf_arr[i] <= dbg_wdata_i;
        end
      end
    end
  end

  // ---- Debug: architectural register view ----
  genvar gi;
  generate
    for (gi = 0; gi < RNUM; gi = gi + 1) begin : gen_rf_debug
      assign rf[gi]     = prf_arr[rat_snapshot[gi]];
      assign rf_map[gi] = prf_arr[map_snapshot[gi]];
    end
  endgenerate
endmodule
