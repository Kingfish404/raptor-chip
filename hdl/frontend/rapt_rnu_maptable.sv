`include "rapt.svh"
`include "rapt_rnu_internal_if.svh"

// Register Map Table - maintains speculative (MAP) and committed (RAT) rename maps.
// On flush, MAP is restored from RAT (with one possible in-flight commit applied).
// Dual-issue: 2 speculative write ports, 6 read ports. Slot B is younger and wins
// on same-address conflicts. RAW dependency between slots is handled in RNU (bypass).
module rapt_rnu_maptable #(
    parameter unsigned RNUM = `RAPT_REG_SIZE,
    parameter unsigned PLEN = `RAPT_PHY_LEN
) (
    input clock,
    input reset,

    rnu_mt_if.slave mt,

    // Debug: full MAP snapshot (speculative, unpacked array)
    output [PLEN-1:0] map_snapshot[RNUM],
    // Debug: full RAT snapshot (committed, unpacked array)
    output [PLEN-1:0] rat_snapshot[RNUM]
);
  // ---- Committed Map (RAT) ----
  logic [PLEN-1:0] rat[RNUM];

  // Pre-decode commit write addresses to one-hot.  Shared by the committed-RAT
  // per-entry write below and the MAP flush-restore further down.  Slot B is
  // the younger committed instruction and wins WAW conflicts.
  logic [RNUM-1:0] rat_wen_oh, rat_wen_b_oh;
  always_comb begin
    rat_wen_oh   = '0;
    rat_wen_b_oh = '0;
    if (mt.rat_wen_a) rat_wen_oh[mt.rat_waddr_a] = 1'b1;
    if (mt.rat_wen_b) rat_wen_b_oh[mt.rat_waddr_b] = 1'b1;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < RNUM; i = i + 1) begin
        rat[i] <= PLEN'(i);
      end
    end else begin
      // Per-entry priority write (FPGA-robust; matches the PRF and the MAP
      // flush-restore).  Each RAT entry has ONE next-state mux with explicit
      // priority: the younger committed slot (B) wins WAW conflicts.  This
      // replaces two addressed writes (`rat[waddr_a]<=..; rat[waddr_b]<=..`)
      // to the same register array in one process, which Vivado (KU15P) can
      // mis-synthesise -- observed as a WAW dual-commit latching the OLDER
      // mapping, so a later `ret` read a physical register holding 0 and the
      // core jumped to PC=0 and looped forever.  Functionally identical to the
      // original last-wins semantics (difftest-verified).
      for (integer i = 0; i < RNUM; i = i + 1) begin
        if (rat_wen_b_oh[i]) begin
          rat[i] <= mt.rat_wdata_b;  // younger slot wins
        end else if (rat_wen_oh[i]) begin
          rat[i] <= mt.rat_wdata_a;
        end
      end
    end
  end

  // ---- Speculative Map (MAP) ----
  logic [PLEN-1:0] map[RNUM];
  logic [RNUM-1:0] map_wen_oh;
`ifdef RAPT_DUAL_ISSUE
  logic [RNUM-1:0] map_wen_b_oh;
`endif

  // (rat_wen_oh / rat_wen_b_oh are decoded once above, next to the RAT write,
  //  and reused here for the flush-restore.)

  always_comb begin
    map_wen_oh = '0;
    if (mt.map_wen_a) map_wen_oh[mt.map_waddr_a] = 1'b1;
`ifdef RAPT_DUAL_ISSUE
    map_wen_b_oh = '0;
    if (mt.map_wen_b) map_wen_b_oh[mt.map_waddr_b] = 1'b1;
`endif
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < RNUM; i = i + 1) begin
        map[i] <= PLEN'(i);
      end
    end else if (mt.flush_pipe) begin
      // Restore MAP from RAT, applying in-flight commits (slot 1 has priority)
      for (integer i = 0; i < RNUM; i = i + 1) begin
        if (rat_wen_b_oh[i]) begin
          map[i] <= mt.rat_wdata_b;
        end else if (rat_wen_oh[i]) begin
          map[i] <= mt.rat_wdata_a;
        end else begin
          map[i] <= rat[i];
        end
      end
    end else begin
      // One next-state mux per entry. Slot B is younger and wins WAW.
      for (integer i = 0; i < RNUM; i = i + 1) begin
`ifdef RAPT_DUAL_ISSUE
        if (map_wen_b_oh[i]) begin
          map[i] <= mt.map_wdata_b;
        end else
`endif
        if (map_wen_oh[i]) begin
          map[i] <= mt.map_wdata_a;
        end
      end
    end
  end

  // Speculative read ports: slot A (rs1, rs2, rd_old)
  assign mt.map_rdata_a = map[mt.map_raddr_a];
  assign mt.map_rdata_b = map[mt.map_raddr_b];
  assign mt.map_rdata_c = map[mt.map_raddr_c];

`ifdef RAPT_DUAL_ISSUE
  // Speculative read ports: slot B (rs1_b, rs2_b, rd_old_b)
  // Note: RAW dependency bypass (slot B seeing slot A's write) is done in RNU,
  // not here. These reads return the pre-write maptable state.
  assign mt.map_rdata_d = map[mt.map_raddr_d];
  assign mt.map_rdata_e = map[mt.map_raddr_e];
  assign mt.map_rdata_f = map[mt.map_raddr_f];
`endif

  // Expose full MAP and RAT for debug
  genvar gi;
  generate
    for (gi = 0; gi < RNUM; gi = gi + 1) begin : gen_snapshots
      assign map_snapshot[gi] = map[gi];
      assign rat_snapshot[gi] = rat[gi];
    end
  endgenerate
endmodule
