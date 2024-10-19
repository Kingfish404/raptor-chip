`include "ysyx.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"

module ysyx_pc (
    input clock,
    input reset,

    input good_speculation,
    input bad_speculation,
    input [DATA_W-1:0] pc_ifu,

    input branch_change,
    input branch_retire,
    input [DATA_W-1:0] npc_wdata,
    output [DATA_W-1:0] out_npc,
    output out_change,
    output out_retire,

    input prev_valid
);
  parameter bit [7:0] DATA_W = `YSYX_W_WIDTH;
  reg [DATA_W-1:0] pc;
  reg change, retire;
  assign out_npc = pc;
  assign out_change = change;
  assign out_retire = retire;

  always @(posedge clock) begin
    if (reset) begin
      pc <= `YSYX_PC_INIT;
      change <= 1;
      `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
    end else begin
      if (prev_valid & !bad_speculation) begin
        change <= branch_change;
        retire <= branch_retire;
        pc <= branch_change ? npc_wdata : pc + 4;
      end else begin
        change <= 0;
        retire <= 0;
        if (good_speculation) begin
          pc <= pc_ifu;
        end
      end
    end
  end
endmodule  //ysyx_PC
