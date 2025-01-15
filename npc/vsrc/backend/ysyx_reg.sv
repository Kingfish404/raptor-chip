`include "ysyx.svh"

module ysyx_reg #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter bit [7:0] REG_LEN = `YSYX_REG_LEN,
    parameter bit [7:0] REG_NUM = `YSYX_REG_NUM
) (
    input clock,

    input idu_valid,
    input [REG_LEN-1:0] rd,

    input bad_speculation,

    input reg_write_en,
    input [REG_LEN-1:0] waddr,
    input [XLEN-1:0] wdata,
    input [REG_LEN-1:0] s1addr,
    input [REG_LEN-1:0] s2addr,

    output [REG_NUM-1:0] out_rf_table,
    output [XLEN-1:0] out_src1,
    output [XLEN-1:0] out_src2,

    input reset
);
  logic [XLEN-1:0] rf[REG_NUM];
  logic [REG_NUM-1:0] rf_table;

  assign out_rf_table = rf_table;
  assign out_src1 = rf[s1addr[REG_LEN-1:0]];
  assign out_src2 = rf[s2addr[REG_LEN-1:0]];

  always @(posedge clock) begin
    if (reset) begin
      rf_table <= 0;
      for (integer i = 0; i < REG_NUM; i = i + 1) begin
        rf[i] <= 0;
      end
    end else begin
      if (bad_speculation) begin
        rf_table <= 0;
      end else begin
        if (reg_write_en) begin
          rf[waddr[REG_LEN-1:0]] <= wdata;
        end
        if (idu_valid && rd != 0) begin
          rf_table[rd] <= 1;
        end
        if (reg_write_en) begin
          rf_table[waddr] <= 0;
        end
      end
    end
  end
endmodule
