`include "npc_macro.v"

module ysyx_IFU (
  input clk,
  input [ADDR_WIDTH-1:0] pc,
  input [DATA_WIDTH-1:0] inst,
  output reg [DATA_WIDTH-1:0] inst_o
);
  parameter ADDR_WIDTH = 64;
  parameter DATA_WIDTH = 32;

  reg [31:0] inst_mem;
  assign inst_o = inst_mem;
  always @(*) begin
    inst_mem = inst;
  end
endmodule // ysyx_IFU
