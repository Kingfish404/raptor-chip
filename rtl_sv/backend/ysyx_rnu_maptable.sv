`include "ysyx.svh"
`include "ysyx_rnu_internal_if.svh"

// Register Map Table - maintains speculative (MAP) and committed (RAT) rename maps.
// On flush, MAP is restored from RAT (with one possible in-flight commit applied).
module ysyx_rnu_maptable #(
    parameter unsigned RNUM = `YSYX_REG_SIZE,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter unsigned PLEN = `YSYX_PHY_LEN
) (
    input clock,
    input reset,

    rnu_mt_if.slave mt,

    // Debug: full MAP snapshot (speculative, unpacked array)
    output [PLEN-1:0] map_snapshot [RNUM],
    // Debug: full RAT snapshot (committed, unpacked array)
    output [PLEN-1:0] rat_snapshot [RNUM]
);
  // ---- Speculative Map (MAP) ----
  logic [PLEN-1:0] map [RNUM];

  always @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < RNUM; i = i + 1) begin
        map[i] <= i[PLEN-1:0];
      end
    end else if (mt.flush_pipe) begin
      // Restore MAP from RAT, but apply the in-flight commit if it matches
      for (integer i = 0; i < RNUM; i = i + 1) begin
        if (mt.rat_wen && mt.rat_waddr == i[RLEN-1:0]) begin
          map[i] <= mt.rat_wdata;
        end else begin
          map[i] <= rat[i];
        end
      end
    end else if (mt.map_wen) begin
      map[mt.map_waddr] <= mt.map_wdata;
    end
  end

  // Speculative read ports (rs1, rs2, rd_old)
  assign mt.map_rdata_a = map[mt.map_raddr_a];
  assign mt.map_rdata_b = map[mt.map_raddr_b];
  assign mt.map_rdata_c = map[mt.map_raddr_c];

  // ---- Committed Map (RAT) ----
  logic [PLEN-1:0] rat [RNUM];

  always @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < RNUM; i = i + 1) begin
        rat[i] <= i[PLEN-1:0];
      end
    end else if (mt.rat_wen) begin
      rat[mt.rat_waddr] <= mt.rat_wdata;
    end
  end

  // Expose full MAP and RAT for debug - generate continuous assigns
  genvar gi;
  generate
    for (gi = 0; gi < RNUM; gi = gi + 1) begin : gen_snapshots
      assign map_snapshot[gi] = map[gi];
      assign rat_snapshot[gi] = rat[gi];
    end
  endgenerate
endmodule
