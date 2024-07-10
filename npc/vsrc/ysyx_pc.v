`include "ysyx_macro.v"
`include "ysyx_macro_dpi_c.v"

module ysyx_pc (
    input clk,
    input rst,
    input exu_valid,
    input use_exu_npc,
    input [DATA_W-1:0] npc_wdata,
    output reg [DATA_W-1:0] pc_o
);
  parameter integer DATA_W = `ysyx_W_WIDTH;

  always @(posedge clk) begin
    if (rst) begin
      pc_o <= `ysyx_PC_INIT;
      `ysyx_DPI_C_npc_difftest_skip_ref
    end else if (exu_valid) begin
      if (use_exu_npc) begin
        pc_o <= npc_wdata;
      end else begin
        pc_o <= pc_o + 4;
      end
    end
  end
endmodule  //ysyx_PC
