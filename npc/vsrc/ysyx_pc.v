`include "ysyx_macro.vh"
`include "ysyx_macro_soc.vh"
`include "ysyx_macro_dpi_c.vh"

module ysyx_pc (
    input clk,
    input rst,

    input speculation,
    input good_speculation,
    input bad_speculation,
    input [DATA_W-1:0] pc_ifu,

    input [DATA_W-1:0] pc_wbu,

    input use_exu_npc,
    input branch_retire,
    input [DATA_W-1:0] npc_wdata,
    output [DATA_W-1:0] npc_o,
    output [DATA_W-1:0] pc_o,
    output change_o,
    output retire_o,

    input prev_valid
);
  parameter bit [7:0] DATA_W = `YSYX_W_WIDTH;
  reg [DATA_W-1:0] npc;
  reg [DATA_W-1:0] pc;
  reg change, retire;
  assign change_o = change;
  assign retire_o = retire;
  assign npc_o = use_exu_npc ? npc_wdata : npc;
  assign pc_o = pc_wbu;

  always @(posedge clk) begin
    if (rst) begin
      pc <= `YSYX_PC_INIT;
      change <= 1;
      `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
    end else if (prev_valid) begin
      pc <= pc + 4;
      if (use_exu_npc) begin
        npc <= npc_wdata;
        change <= 1;
      end else if (branch_retire) begin
        change <= 0;
        retire <= 1;
      end
    end else begin
      change <= 0;
      retire <= 0;
      if (good_speculation) begin
        pc <= pc_ifu + 4;
      end
    end
  end
endmodule  //ysyx_PC
