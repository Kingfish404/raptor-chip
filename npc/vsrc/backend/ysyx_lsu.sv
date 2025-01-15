`include "ysyx.svh"

module ysyx_lsu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN,
    parameter bit [7:0] L1D_LEN = `YSYX_L1D_LEN,
    parameter bit [7:0] L1D_SIZE = 2 ** L1D_LEN
) (
    input clock,

    // from exu
    input [XLEN-1:0] addr,
    input ren,
    input wen,
    lsu_avalid,
    input [4:0] alu_op,
    input [XLEN-1:0] wdata,
    // to exu
    output [XLEN-1:0] out_rdata,
    output out_rvalid,
    output out_wready,

    // to bus load
    output [XLEN-1:0] out_lsu_araddr,
    output out_lsu_arvalid,
    output [7:0] out_lsu_rstrb,
    // from bus load
    input [XLEN-1:0] bus_rdata,
    input lsu_rvalid,

    // to bus store
    output [XLEN-1:0] out_lsu_awaddr,
    output out_lsu_awvalid,
    output [XLEN-1:0] out_lsu_wdata,
    output [7:0] out_lsu_wstrb,
    output out_lsu_wvalid,
    // from bus store
    input logic lsu_wready,

    input reset
);
  logic valid_r;

  logic [XLEN-1:0] lsu_araddr;
  logic [XLEN-1:0] rdata, rdata_unalign;
  logic [7:0] wstrb, rstrb;
  logic arvalid;

  logic [32-1:0] l1d[L1D_SIZE], rdata_lsu;
  logic [L1D_SIZE-1:0] l1d_valid = 0;
  logic [32-L1D_LEN-2-1:0] l1d_tag[L1D_SIZE];

  logic [32-L1D_LEN-2-1:0] addr_tag;
  logic [L1D_LEN-1:0] addr_idx;
  logic l1d_cache_hit;
  logic l1d_cache_within;


  logic [32-L1D_LEN-2-1:0] waddr_tag;
  logic [L1D_LEN-1:0] waddr_idx;
  logic l1d_cache_hit_w;

  assign out_lsu_araddr = lsu_araddr;
  assign out_lsu_arvalid = arvalid;
  assign arvalid = ren && lsu_avalid && !l1d_cache_hit;
  assign out_lsu_rstrb = rstrb;

  // without l1d cache
  // assign rdata = bus_rdata;
  // assign rvalid_o = lsu_rvalid;

  // with l1d cache
  assign rdata_unalign = (valid_r) ? rdata_lsu : l1d[addr_idx];
  assign out_rvalid = valid_r || l1d_cache_hit;

  assign out_lsu_awaddr = lsu_araddr;
  assign out_lsu_awvalid = wen && lsu_avalid;

  assign out_lsu_wdata = wdata;
  assign out_lsu_wstrb = wstrb;
  assign out_lsu_wvalid = wen && lsu_avalid;

  assign out_wready = lsu_wready;

  assign l1d_cache_hit = (
         ren && lsu_avalid && 1 &&
         l1d_valid[addr_idx] == 1'b1) && (l1d_tag[addr_idx] == addr_tag);
  assign addr_tag = out_lsu_araddr[XLEN-1:L1D_LEN+2];
  assign addr_idx = out_lsu_araddr[L1D_LEN+2-1:0+2];
  assign l1d_cache_within = (
         (out_lsu_araddr >= 'h30000000 && out_lsu_araddr < 'h40000000) ||
         (out_lsu_araddr >= 'h80000000 && out_lsu_araddr < 'h80400000) ||
         (out_lsu_araddr >= 'ha0000000 && out_lsu_araddr < 'hc0000000) ||
         (0)
       );

  assign waddr_tag = out_lsu_awaddr[XLEN-1:L1D_LEN+2];
  assign waddr_idx = out_lsu_awaddr[L1D_LEN+2-1:0+2];
  assign l1d_cache_hit_w = (
         wen && lsu_avalid &&
         l1d_valid[waddr_idx] == 1'b1) && (l1d_tag[waddr_idx] == waddr_tag);

  // load/store unit
  // assign wstrb = (
  //          ({8{alu_op == `YSYX_ALU_SB}} & 8'h1) |
  //          ({8{alu_op == `YSYX_ALU_SH}} & 8'h3) |
  //          ({8{alu_op == `YSYX_ALU_SW}} & 8'hf)
  //        );
  assign wstrb = {{4{1'b0}}, {alu_op[3:0]}};
  assign rstrb = (
           ({8{alu_op == `YSYX_ALU_LB__}} & 8'h1) |
           ({8{alu_op == `YSYX_ALU_LBU_}} & 8'h1) |
           ({8{alu_op == `YSYX_ALU_LH__}} & 8'h3) |
           ({8{alu_op == `YSYX_ALU_LHU_}} & 8'h3) |
           ({8{alu_op == `YSYX_ALU_LW__}} & 8'hf)
         );

  logic [1:0] araddr_lo = out_lsu_araddr[1:0];
  assign rdata = (
           ({XLEN{araddr_lo == 2'b00}} & rdata_unalign) |
           ({XLEN{araddr_lo == 2'b01}} & {{8'b0}, {rdata_unalign[31:8]}}) |
           ({XLEN{araddr_lo == 2'b10}} & {{16'b0}, {rdata_unalign[31:16]}}) |
           ({XLEN{araddr_lo == 2'b11}} & {{24'b0}, {rdata_unalign[31:24]}}) |
           (0)
         );
  assign out_rdata = (
           ({XLEN{alu_op == `YSYX_ALU_LB__}} & (rdata[7] ? rdata | 'hffffff00 : rdata & 'hff)) |
           ({XLEN{alu_op == `YSYX_ALU_LBU_}} & rdata & 'hff) |
           ({XLEN{alu_op == `YSYX_ALU_LH__}} &
              (rdata[15] ? rdata | 'hffff0000 : rdata & 'hffff)) |
           ({XLEN{alu_op == `YSYX_ALU_LHU_}} & rdata & 'hffff) |
           ({XLEN{alu_op == `YSYX_ALU_LW__}} & rdata)
         );
  assign lsu_araddr = addr;
  always @(posedge clock) begin
    if (reset) begin
      l1d_valid <= 0;
      valid_r   <= 0;
    end else begin
      if (ren && lsu_rvalid) begin
        if (l1d_cache_within) begin
          l1d[addr_idx] <= bus_rdata;
          l1d_tag[addr_idx] <= addr_tag;
          l1d_valid[addr_idx] <= 1'b1;
        end else begin
          rdata_lsu <= bus_rdata;
          valid_r   <= 1'b1;
        end
      end
      if (valid_r) begin
        valid_r <= 0;
      end
      if (out_lsu_awvalid && l1d_cache_hit_w) begin
        // $display("l1d_cache_hit_w");
        l1d_valid[waddr_idx] <= 1'b0;
      end
    end
  end
endmodule
