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
  parameter bit [7:0] REG_ADDR_W = 4;
  parameter bit [7:0] REG_NUM = 16;
  parameter bit [7:0] DATA_W = 32;
  reg [DATA_W-1:0] rf[REG_NUM];
  reg [REG_NUM-1:0] rf_table;

  // wire not_r0_write = reg_write_en & |waddr[REG_ADDR_W-1:0];

  // assign src1_o = |s1addr[REG_ADDR_W-1:0] ? rf[s1addr[REG_ADDR_W-1:0]] : 0;
  // assign src2_o = |s2addr[REG_ADDR_W-1:0] ? rf[s2addr[REG_ADDR_W-1:0]] : 0;
  assign src1_o = rf[s1addr[REG_ADDR_W-1:0]];
  assign src2_o = rf[s2addr[REG_ADDR_W-1:0]];
  assign rf_table_o = rf_table;

  always @(posedge clk) begin
    if (rst) begin
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

  genvar i;
  generate
    for (i = 1; i < REG_NUM; i = i + 1) begin : g_rf
      always @(posedge clk) begin
        if (rst) begin
          rf[i] <= 0;
        end else if (reg_write_en) begin
          rf[waddr[REG_ADDR_W-1:0]] <= wdata;
        end
      end
    end
  endgenerate
endmodule  // ysyx_reg
