module ysyx_reg (
    input clk,
    input rst,

    input idu_valid,
    input [REG_ADDR_W-1:0] rd,

    input bad_speculation,

    input reg_write_en,
    input [REG_ADDR_W-1:0] waddr,
    input [DATA_W-1:0] wdata,
    input [REG_ADDR_W-1:0] s1addr,
    input [REG_ADDR_W-1:0] s2addr,
    output [REG_NUM-1:0] rf_table_o,
    output [DATA_W-1:0] src1_o,
    output [DATA_W-1:0] src2_o
);
  parameter bit [7:0] REG_ADDR_W = 4;
  parameter bit [7:0] REG_NUM = 16;
  parameter bit [7:0] DATA_W = 32;
  reg [DATA_W-1:0] rf[REG_NUM];
  reg [REG_NUM-1:0] rf_table;

  assign src1_o = rf[s1addr[REG_ADDR_W-1:0]];
  assign src2_o = rf[s2addr[REG_ADDR_W-1:0]];
  assign rf_table_o = rf_table;

  always @(posedge clk) begin
    if (rst) begin
      rf_table <= 0;
    end else begin
      if (bad_speculation) begin
        rf_table <= 0;
      end else begin
        if (idu_valid & rd != 0) begin
          rf_table[rd] <= 1;
        end
        if (reg_write_en) begin
          rf_table[waddr[3:0]] <= 0;
        end
      end
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      rf[0]  <= 0;
      rf[1]  <= 0;
      rf[2]  <= 0;
      rf[3]  <= 0;
      rf[4]  <= 0;
      rf[5]  <= 0;
      rf[6]  <= 0;
      rf[7]  <= 0;
      rf[8]  <= 0;
      rf[9]  <= 0;
      rf[10] <= 0;
      rf[11] <= 0;
      rf[12] <= 0;
      rf[13] <= 0;
      rf[14] <= 0;
      rf[15] <= 0;
    end else if (reg_write_en) begin
      rf[waddr[REG_ADDR_W-1:0]] <= wdata;
    end
  end
endmodule  // ysyx_reg
