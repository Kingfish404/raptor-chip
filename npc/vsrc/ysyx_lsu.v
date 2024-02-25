`include "ysyx_macro.v"

module ysyx_LSU(
  input clk,
  input idu_valid,
  // from exu
  input [ADDR_W-1:0] addr,
  input ren, wen, avalid,
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
  wire [DATA_W-1:0] rdata;
  wire [7:0] wstrb, rstrb;
  assign rvalid_o = lsu_rvalid;
  assign wready_o = lsu_wready;

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

  assign rdata = lsu_rdata;
  assign lsu_rstrb_o = rstrb;

  assign lsu_awaddr_o = idu_valid ? addr : lsu_araddr;
  assign lsu_awvalid_o = ifsr_ready & wen & avalid;

  assign lsu_wdata_o = wdata;
  assign lsu_wstrb_o = wstrb;
  assign lsu_wvalid_o = ifsr_ready & wen & avalid;

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

endmodule
