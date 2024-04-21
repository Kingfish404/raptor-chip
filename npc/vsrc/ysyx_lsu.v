`include "ysyx_macro.v"

module ysyx_LSU(
    input clk,
    input idu_valid,
    // from exu
    input [ADDR_W-1:0] addr,
    input ren, wen, lsu_avalid,
    input [3:0] alu_op,
    input [DATA_W-1:0] wdata,
    // to exu
    output [DATA_W-1:0] rdata_o,
    output reg rvalid_o,
    output reg wready_o,

    // to bus load
    output [DATA_W-1:0] lsu_araddr_o,
    output lsu_arvalid_o,
    output [7:0] lsu_rstrb_o,
    // from bus load
    input [DATA_W-1:0] lsu_rdata,
    input lsu_rvalid,

    // to bus store
    output [DATA_W-1:0] lsu_awaddr_o,
    output lsu_awvalid_o,
    output [DATA_W-1:0] lsu_wdata_o,
    output [7:0] lsu_wstrb_o,
    output lsu_wvalid_o,
    // from bus store
    input reg lsu_wready
  );
  parameter ADDR_W = 32, DATA_W = 32;

  reg [ADDR_W-1:0] lsu_araddr;

  wire [DATA_W-1:0] rdata;
  wire [7:0] wstrb, rstrb;

  assign lsu_araddr_o = idu_valid ? addr : lsu_araddr;
  // assign lsu_arvalid_o = ren & lsu_avalid;
  assign lsu_arvalid_o = ren & lsu_avalid & !l1d_cache_hit & l1_enable;
  assign lsu_rstrb_o = rstrb;

  // without l1d cache
  // assign rdata = lsu_rdata;
  // assign rvalid_o = lsu_rvalid;

  // with l1d cache
  assign rdata = (lsu_rvalid) ? lsu_rdata : l1d[addr_idx];
  assign rvalid_o = lsu_rvalid | l1d_cache_hit;

  assign lsu_awaddr_o = idu_valid ? addr : lsu_araddr;
  assign lsu_awvalid_o = wen & lsu_avalid;

  assign lsu_wdata_o = wdata;
  assign lsu_wstrb_o = wstrb;
  assign lsu_wvalid_o = wen & lsu_avalid;

  assign wready_o = lsu_wready;

  parameter L1D_SIZE = 64;
  parameter L1D_LEN = 6;
  reg [32-1:0] l1d[L1D_SIZE-1:0];
  reg [L1D_SIZE-1:0] l1d_valid = 0;
  reg [32-L1D_LEN-2-1:0] l1d_tag[L1D_SIZE-1:0];
  reg l1_enable = 0;

  wire arvalid;
  wire [32-L1D_LEN-2-1:0] addr_tag = lsu_araddr_o[ADDR_W-1:L1D_LEN+2];
  wire [L1D_LEN-1:0] addr_idx = lsu_araddr_o[L1D_LEN+2-1:0+2];
  wire l1d_cache_hit = (
         idu_valid & l1_enable &
         l1d_valid[addr_idx] == 1'b1) & (l1d_tag[addr_idx] == addr_tag);

  wire [32-L1D_LEN-2-1:0] waddr_tag = lsu_awaddr_o[ADDR_W-1:L1D_LEN+2];
  wire [L1D_LEN-1:0] waddr_idx = lsu_awaddr_o[L1D_LEN+2-1:0+2];
  wire l1d_cache_hit_w = (
         idu_valid &
         l1d_valid[waddr_idx] == 1'b1) & (l1d_tag[waddr_idx] == waddr_tag);

  // load/store unit
  assign wstrb = (
           ({8{alu_op == `ysyx_ALU_OP_SB}} & 8'h1) |
           ({8{alu_op == `ysyx_ALU_OP_SH}} & 8'h3) |
           ({8{alu_op == `ysyx_ALU_OP_SW}} & 8'hf)
         );
  assign rstrb = (
           ({8{alu_op == `ysyx_ALU_OP_LB}} & 8'h1) |
           ({8{alu_op == `ysyx_ALU_OP_LBU}} & 8'h1) |
           ({8{alu_op == `ysyx_ALU_OP_LH}} & 8'h3) |
           ({8{alu_op == `ysyx_ALU_OP_LHU}} & 8'h3) |
           ({8{alu_op == `ysyx_ALU_OP_LW}} & 8'hf)
         );
  assign rdata_o = (
           ({DATA_W{alu_op == `ysyx_ALU_OP_LB}} & (rdata[7] ? rdata | 'hffffff00 : rdata & 'hff)) |
           ({DATA_W{alu_op == `ysyx_ALU_OP_LBU}} & rdata & 'hff) |
           ({DATA_W{alu_op == `ysyx_ALU_OP_LH}} & (rdata[15] ? rdata | 'hffff0000 : rdata & 'hffff)) |
           ({DATA_W{alu_op == `ysyx_ALU_OP_LHU}} & rdata & 'hffff) |
           ({DATA_W{alu_op == `ysyx_ALU_OP_LW}} & rdata)
         );

  always @(posedge clk)
    begin
      if (l1d_cache_hit)
        begin
          // $display("l1d_cache_hit");
        end
      if (idu_valid)
        begin
          lsu_araddr <= addr;
        end
      if (lsu_avalid)
        begin
          l1_enable <= 1;
        end
      if (!lsu_avalid)
        begin
          l1_enable <= 0;
        end
      if (ren & lsu_rvalid)
        begin
          l1d[addr_idx] <= lsu_rdata;
          l1d_tag[addr_idx] <= addr_tag;
          l1d_valid[addr_idx] <= 1'b1;
        end
      if (lsu_awvalid_o)
        begin
          // $display("l1d_cache_hit_w");
          l1d_valid[waddr_idx] <= 1'b0;
          l1d[waddr_idx] <= 'h0;
        end
    end
endmodule
