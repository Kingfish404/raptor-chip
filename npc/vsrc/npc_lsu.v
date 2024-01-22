`include "npc_macro.v"

module ysyx_LSU(
  input clk,
  input ren, wen, avalid,
  input [3:0] alu_op,
  input idu_valid,
  input [ADDR_W-1:0] addr,
  input [DATA_W-1:0] wdata,

  // for bus load
  output [DATA_W-1:0] lsu_araddr_o,
  output lsu_arvalid_o,
  input lsu_arready,

  input [DATA_W-1:0] lsu_rdata,
  input [1:0] lsu_rresp,
  input lsu_rvalid,
  output lsu_rready_o,

  // for bus store
  output [DATA_W-1:0] lsu_awaddr_o,
  output lsu_awvalid_o,
  input reg lsu_awready,

  output [DATA_W-1:0] lsu_wdata_o,
  output [7:0] lsu_wstrb_o,
  output lsu_wvalid_o,
  input reg lsu_wready,

  input reg [1:0] lsu_bresp,
  input reg lsu_bvalid,
  output lsu_bready_o,

  output [DATA_W-1:0] rdata_o,
  output reg rvalid_wready_o
);
  parameter ADDR_W = 32, DATA_W = 32;
  wire [DATA_W-1:0] rdata;
  wire [7:0] wstrb;
  assign rvalid_wready_o = (rvalid | wready) | (!avalid);

  reg [19:0] lfsr = 1;
  wire ifsr_ready = `ysyx_IFSR_ENABLE ? lfsr[19] : 1;
  always @(posedge clk ) begin
    if ((ren | wen)) begin
      if (!lfsr[19]) begin lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]}; end
    end else begin
      lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]};
    end
  end

  reg [ADDR_W-1:0] lsu_araddr;
  always @(posedge clk) begin
    if (idu_valid) begin
      lsu_araddr <= addr;
    end
  end

  assign lsu_araddr_o = idu_valid ? addr : lsu_araddr;
  assign lsu_arvalid_o = ifsr_ready & ren & avalid;
  assign arready = lsu_arready;

  assign rdata = lsu_rdata;
  assign rresp = lsu_rresp;
  assign rvalid = lsu_rvalid;
  assign lsu_rready_o = ifsr_ready;

  assign lsu_awaddr_o = idu_valid ? addr : lsu_araddr;
  assign lsu_awvalid_o = ifsr_ready & wen & avalid;
  assign awready = lsu_awready;

  assign lsu_wdata_o = wdata;
  assign lsu_wstrb_o = wstrb;
  assign lsu_wvalid_o = ifsr_ready & wen & avalid;
  assign wready = lsu_wready;

  assign bresp = lsu_bresp;
  assign bvalid = lsu_bvalid;
  assign lsu_bready_o = ifsr_ready;

  wire rvalid, wvalid;
  wire arready, awready, wready, bvalid;
  wire [1:0] rresp, bresp;
  // ysyx_MEM_SRAM lsu_sram(
  //   .clk(clk), 
  //   .araddr(addr), .arvalid(ifsr_ready & ren & avalid), .arready_o(arready),
  //   .rdata_o(rdata), .rresp_o(rresp), .rvalid_o(rvalid), .rready(ifsr_ready),
  //   .awaddr(addr), .awvalid(ifsr_ready & wen & avalid), .awready_o(awready),
  //   .wdata(wdata), .wstrb(wstrb), .wvalid(ifsr_ready & wen & avalid), .wready_o(wready),
  //   .bresp_o(bresp), .bvalid_o(bvalid), .bready(ifsr_ready)
  //   );

  // load/store unit
  assign wstrb = (
    ({8{alu_op == `ysyx_ALU_OP_SB}} & 8'h1) | 
    ({8{alu_op == `ysyx_ALU_OP_SH}} & 8'h3) | 
    ({8{alu_op == `ysyx_ALU_OP_SW}} & 8'hf)
  );
  assign rdata_o = (
    ({DATA_W{alu_op == `ysyx_ALU_OP_LB}} & (rdata[7] ? rdata | 'hffffff00 : rdata & 'hff)) | 
    ({DATA_W{alu_op == `ysyx_ALU_OP_LBU}} & rdata & 'hff) | 
    ({DATA_W{alu_op == `ysyx_ALU_OP_LH}} & (rdata[15] ? rdata | 'hffff0000 : rdata & 'hffff)) | 
    ({DATA_W{alu_op == `ysyx_ALU_OP_LHU}} & rdata & 'hffff) | 
    ({DATA_W{alu_op == `ysyx_ALU_OP_LW}} & rdata)
  );

endmodule
