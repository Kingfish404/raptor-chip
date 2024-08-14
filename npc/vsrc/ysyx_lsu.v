`include "ysyx_macro.vh"

module ysyx_lsu (
    input clk,
    input idu_valid,
    // from exu
    input [ADDR_W-1:0] addr,
    input ren,
    input wen,
    lsu_avalid,
    input [3:0] alu_op,
    input [DATA_W-1:0] wdata,
    // to exu
    output [DATA_W-1:0] rdata_o,
    output rvalid_o,
    output wready_o,

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
  parameter bit[7:0] ADDR_W = 32, DATA_W = 32;

  reg [ADDR_W-1:0] lsu_araddr;

  wire [DATA_W-1:0] rdata, rdata_unalign;
  wire [7:0] wstrb, rstrb;

  assign lsu_araddr_o = lsu_araddr;
  // assign lsu_arvalid_o = ren & lsu_avalid;
  assign lsu_arvalid_o = ren & lsu_avalid & !l1d_cache_hit;
  assign lsu_rstrb_o = rstrb;

  // without l1d cache
  // assign rdata = lsu_rdata;
  // assign rvalid_o = lsu_rvalid;

  // with l1d cache
  assign rdata_unalign = (lsu_rvalid) ? lsu_rdata : l1d[addr_idx];
  assign rvalid_o = lsu_rvalid | l1d_cache_hit;

  assign lsu_awaddr_o = lsu_araddr;
  assign lsu_awvalid_o = wen & lsu_avalid;

  assign lsu_wdata_o = wdata;
  assign lsu_wstrb_o = wstrb;
  assign lsu_wvalid_o = wen & lsu_avalid;

  assign wready_o = lsu_wready;

  parameter bit[7:0] L1D_SIZE = 2;
  parameter bit[7:0] L1D_LEN = 1;
  reg [32-1:0] l1d[L1D_SIZE];
  reg [L1D_SIZE-1:0] l1d_valid = 0;
  reg [32-L1D_LEN-2-1:0] l1d_tag[L1D_SIZE];

  wire arvalid;
  wire [32-L1D_LEN-2-1:0] addr_tag = lsu_araddr_o[ADDR_W-1:L1D_LEN+2];
  wire [L1D_LEN-1:0] addr_idx = lsu_araddr_o[L1D_LEN+2-1:0+2];
  wire l1d_cache_hit = (
         ren & lsu_avalid & 0 &
         l1d_valid[addr_idx] == 1'b1) & (l1d_tag[addr_idx] == addr_tag);
  wire l1d_cache_within = (
         (lsu_araddr_o >= 'h30000000 && lsu_araddr_o < 'h40000000) ||
         (lsu_araddr_o >= 'h80000000 && lsu_araddr_o < 'h80400000) ||
         (lsu_araddr_o >= 'ha0000000 && lsu_araddr_o < 'hc0000000) ||
         (0)
       );

  wire [32-L1D_LEN-2-1:0] waddr_tag = lsu_awaddr_o[ADDR_W-1:L1D_LEN+2];
  wire [L1D_LEN-1:0] waddr_idx = lsu_awaddr_o[L1D_LEN+2-1:0+2];
  wire l1d_cache_hit_w = (
         wen & lsu_avalid &
         l1d_valid[waddr_idx] == 1'b1) & (l1d_tag[waddr_idx] == waddr_tag);

  // load/store unit
  assign wstrb = (
           ({8{alu_op == `YSYX_ALU_OP_SB}} & 8'h1) |
           ({8{alu_op == `YSYX_ALU_OP_SH}} & 8'h3) |
           ({8{alu_op == `YSYX_ALU_OP_SW}} & 8'hf)
         );
  assign rstrb = (
           ({8{alu_op == `YSYX_ALU_OP_LB}} & 8'h1) |
           ({8{alu_op == `YSYX_ALU_OP_LBU}} & 8'h1) |
           ({8{alu_op == `YSYX_ALU_OP_LH}} & 8'h3) |
           ({8{alu_op == `YSYX_ALU_OP_LHU}} & 8'h3) |
           ({8{alu_op == `YSYX_ALU_OP_LW}} & 8'hf)
         );

  wire [1:0] araddr_lo = lsu_araddr_o[1:0];
  assign rdata = (
           ({DATA_W{araddr_lo == 2'b00}} & rdata_unalign) |
           ({DATA_W{araddr_lo == 2'b01}} & {{8'b0}, {rdata_unalign[31:8]}}) |
           ({DATA_W{araddr_lo == 2'b10}} & {{16'b0}, {rdata_unalign[31:16]}}) |
           ({DATA_W{araddr_lo == 2'b11}} & {{24'b0}, {rdata_unalign[31:24]}}) |
           (0)
         );
  assign rdata_o = (
           ({DATA_W{alu_op == `YSYX_ALU_OP_LB}} & (rdata[7] ? rdata | 'hffffff00 : rdata & 'hff)) |
           ({DATA_W{alu_op == `YSYX_ALU_OP_LBU}} & rdata & 'hff) |
           ({DATA_W{alu_op == `YSYX_ALU_OP_LH}} &
              (rdata[15] ? rdata | 'hffff0000 : rdata & 'hffff)) |
           ({DATA_W{alu_op == `YSYX_ALU_OP_LHU}} & rdata & 'hffff) |
           ({DATA_W{alu_op == `YSYX_ALU_OP_LW}} & rdata)
         );
  assign lsu_araddr = addr;
  always @(posedge clk) begin
    // if (l1d_cache_hit)
    //   begin
    //     $display("[hit] addr: %h, l1d data: %h, tag: %h, idx: %h",
    //              lsu_araddr_o, l1d[addr_idx], l1d_tag[addr_idx], addr_idx);
    //   end
    if (idu_valid) begin
      // lsu_araddr <= addr;
    end
    if (ren & lsu_rvalid & l1d_cache_within) begin
      l1d[addr_idx] <= lsu_rdata;
      l1d_tag[addr_idx] <= addr_tag;
      l1d_valid[addr_idx] <= 1'b1;
    end
    if (lsu_awvalid_o & l1d_cache_hit_w) begin
      // $display("l1d_cache_hit_w");
      l1d_valid[waddr_idx] <= 1'b0;
    end
  end
endmodule
