module ysyx_reg (
    input clk,
    input rst,

    input idu_valid,
    input [REG_ADDR_W-1:0] rd,

    input reg_write_en,
    input [REG_ADDR_W-1:0] waddr,
    input [DATA_W-1:0] wdata,
    input [REG_ADDR_W-1:0] s1addr,
    input [REG_ADDR_W-1:0] s2addr,
    output [REG_NUM-1:0] rf_table_o,
    output [DATA_W-1:0] src1_o,
    output [DATA_W-1:0] src2_o
);
  parameter integer REG_ADDR_W = 4;
  parameter integer DATA_W = 32;
  parameter integer REG_NUM = 16;
  reg [DATA_W-1:0] rf[REG_NUM];
  reg [REG_NUM-1:0] rf_table = 0;

  assign src1_o = rf[s1addr[3:0]];
  assign src2_o = rf[s2addr[3:0]];
  assign rf_table_o = rf_table;

  always @(posedge clk) begin
    if (rst) begin
      rf_table[0] <= 0;
    end else begin
      if (idu_valid) begin
        rf_table[rd[4:0]] <= 1;
      end
      if (reg_write_en) begin
        rf_table[waddr[3:0]] <= 0;
      end
    end
  end

  genvar i;
  generate
    for (i = 1; i < REG_NUM; i = i + 1) begin
      always @(posedge clk) begin
        rf[0] <= 0;
        if (rst) begin
          rf[i] <= 0;
        end else if (reg_write_en) begin
          rf[waddr[3:0]] <= wdata;
        end
      end
    end
  endgenerate
endmodule  // ysyx_reg
