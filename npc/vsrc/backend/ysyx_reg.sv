`include "ysyx.svh"

module ysyx_reg #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter bit [7:0] REG_LEN = `YSYX_REG_LEN,
    parameter bit [7:0] REG_NUM = `YSYX_REG_NUM
) (
    input clock,

    input write_en,
    input [REG_LEN-1:0] waddr,
    input [XLEN-1:0] wdata,

    input [REG_LEN-1:0] s1addr,
    input [REG_LEN-1:0] s2addr,
    output [XLEN-1:0] out_src1,
    output [XLEN-1:0] out_src2,

    input reset
);
  logic [XLEN-1:0] rf[REG_NUM];

  assign out_src1 = rf[s1addr[REG_LEN-1:0]];
  assign out_src2 = rf[s2addr[REG_LEN-1:0]];

  always @(posedge clock) begin
    if (reset) begin
      for (integer i = 0; i < REG_NUM; i = i + 1) begin
        rf[i] <= 0;
      end
    end else begin
      if (write_en && waddr[REG_LEN-1:0] != 0) begin
        rf[waddr[REG_LEN-1:0]] <= wdata;
      end
    end
  end
endmodule
