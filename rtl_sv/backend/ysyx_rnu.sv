`include "ysyx.svh"
`include "ysyx_if.svh"
`include "ysyx_rnu_internal_if.svh"
`include "ysyx_dpi_c.svh"
import ysyx_pkg::*;

// Rename Unit (RNU) — pure rename stage.
// Contains:
//   - Rename Queue (RNQ): buffers decoded uops before renaming
//   - Free List: allocates / deallocates physical registers
//   - Map Table: speculative (MAP) + committed (RAT) rename maps
//
// PRF (Physical Register File) has been moved to the top level (ysyx.sv)
// because it is a shared resource accessed by EXU (write), ROU (read),
// and CMU (commit), with RNU having no direct read/write interaction.
//
// Sub-modules are connected via interfaces (rnu_fl_if, rnu_mt_if)
// for clean modularity and multi-issue scaling.
module ysyx_rnu #(
    parameter unsigned RIQ_SIZE = `YSYX_RIQ_SIZE,
    parameter unsigned RNUM = `YSYX_REG_SIZE,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter unsigned PNUM = `YSYX_PHY_SIZE,
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
) (
    input clock,

    rou_cmu_if.in  rou_cmu,
    cmu_bcast_if.in cmu_bcast,

    idu_rnu_if.slave  idu_rnu,
    rnu_rou_if.master rnu_rou,

    // Debug: MAP and RAT snapshots for architectural register view
    output [PLEN-1:0] map_snapshot [RNUM],
    output [PLEN-1:0] rat_snapshot [RNUM],

    input reset
);
  // ================================================================
  // Rename Queue (RNQ) - single-entry pipeline buffer
  // ================================================================
  logic [$clog2(RIQ_SIZE)-1:0] rnq_head, rnq_tail;
  logic [RIQ_SIZE-1:0]         rnq_valid;

  ysyx_pkg::uop_t              rnq_uops  [RIQ_SIZE];
  logic [RLEN-1:0]             rnq_rd    [RIQ_SIZE];
  logic [31:0]                 rnq_op1   [RIQ_SIZE];
  logic [31:0]                 rnq_op2   [RIQ_SIZE];
  logic [RLEN-1:0]             rnq_rs1   [RIQ_SIZE];
  logic [RLEN-1:0]             rnq_rs2   [RIQ_SIZE];

  logic rnq_enq_fire, rnq_deq_fire;
  assign rnq_enq_fire = idu_rnu.valid && !rnq_valid[rnq_head];
  assign rnq_deq_fire = rnu_rou.ready && rnq_valid[rnq_tail];

  assign rnu_rou.valid = rnq_valid[rnq_tail];
  assign idu_rnu.ready = !rnq_valid[rnq_head];

  always @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      rnq_head  <= '0;
      rnq_tail  <= '0;
      rnq_valid <= '0;
    end else begin
      if (rnq_enq_fire) begin
        rnq_head            <= rnq_head + 1;
        rnq_valid[rnq_head] <= 1'b1;
        rnq_uops[rnq_head]  <= idu_rnu.uop;
        rnq_rd[rnq_head]    <= idu_rnu.uop.rd;
        rnq_op1[rnq_head]   <= idu_rnu.op1;
        rnq_op2[rnq_head]   <= idu_rnu.op2;
        rnq_rs1[rnq_head]   <= idu_rnu.rs1;
        rnq_rs2[rnq_head]   <= idu_rnu.rs2;
      end
      if (rnq_deq_fire) begin
        rnq_tail            <= rnq_tail + 1;
        rnq_valid[rnq_tail] <= 1'b0;
      end
    end
  end

  // RNQ read-side outputs
  assign rnu_rou.uop = rnq_uops[rnq_tail];
  assign rnu_rou.op1 = rnq_op1[rnq_tail];
  assign rnu_rou.op2 = rnq_op2[rnq_tail];

  // ================================================================
  // Commit signals (shared by freelist, maptable, PRF)
  // ================================================================
  logic commit_dealloc;
  assign commit_dealloc = rou_cmu.valid && rou_cmu.rd != 0;

  // ================================================================
  // Internal interface instances
  // ================================================================
  rnu_fl_if      fl_bus  ();    // RNU ↔ Free List
  rnu_mt_if      mt_bus  ();    // RNU ↔ Map Table

  // ================================================================
  // Free List - interface drive
  // ================================================================
  assign fl_bus.flush_pipe  = cmu_bcast.flush_pipe;
  assign fl_bus.flush_rd    = cmu_bcast.rd;
  assign fl_bus.alloc_req   = rnq_deq_fire && !fl_bus.alloc_empty && rnq_rd[rnq_tail] != 0;
  assign fl_bus.dealloc_req = commit_dealloc;
  assign fl_bus.dealloc_pr  = rou_cmu.prs;

  ysyx_rnu_freelist #(
      .RNUM(RNUM), .PNUM(PNUM), .PLEN(PLEN), .RLEN(RLEN)
  ) u_freelist (
      .clock (clock),
      .reset (reset),
      .fl    (fl_bus)
  );

  // ================================================================
  // Map Table - interface drive
  // ================================================================
  assign mt_bus.flush_pipe  = cmu_bcast.flush_pipe;
  // Speculative write (on allocation)
  assign mt_bus.map_wen     = fl_bus.alloc_req;
  assign mt_bus.map_waddr   = rnq_rd[rnq_tail];
  assign mt_bus.map_wdata   = fl_bus.alloc_pr;
  // Speculative read: rs1, rs2
  assign mt_bus.map_raddr_a = rnq_rs1[rnq_tail];
  assign mt_bus.map_raddr_b = rnq_rs2[rnq_tail];
  // Speculative read: rd old mapping (prs for ROB dealloc)
  assign mt_bus.map_raddr_c = rnq_rd[rnq_tail];
  // Committed write
  assign mt_bus.rat_wen     = commit_dealloc;
  assign mt_bus.rat_waddr   = rou_cmu.rd;
  assign mt_bus.rat_wdata   = rou_cmu.prd;

  logic [PLEN-1:0] mt_rat_snapshot [RNUM];
  logic [PLEN-1:0] mt_map_snapshot [RNUM];

  ysyx_rnu_maptable #(
      .RNUM(RNUM), .RLEN(RLEN), .PLEN(PLEN)
  ) u_maptable (
      .clock        (clock),
      .reset        (reset),
      .mt           (mt_bus),
      .map_snapshot (mt_map_snapshot),
      .rat_snapshot (mt_rat_snapshot)
  );

  // Expose snapshots to top level
  genvar gi;
  generate
    for (gi = 0; gi < RNUM; gi = gi + 1) begin : gen_snapshot_out
      assign map_snapshot[gi] = mt_map_snapshot[gi];
      assign rat_snapshot[gi] = mt_rat_snapshot[gi];
    end
  endgenerate

  // ================================================================
  // Register Renaming outputs
  // ================================================================
  assign rnu_rou.pr1 = mt_bus.map_rdata_a;
  assign rnu_rou.pr2 = mt_bus.map_rdata_b;
  assign rnu_rou.prd = (rnq_rd[rnq_tail] != 0) ? fl_bus.alloc_pr : '0;
  // prs = old physical mapping for rd (before rename), needed by ROB for dealloc
  assign rnu_rou.prs = mt_bus.map_rdata_c;

endmodule
