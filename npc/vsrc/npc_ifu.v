`include "npc_macro.v"

module ysyx_IFU (
  input clk, rst,

  input wire prev_valid, next_ready,
  output reg valid_o, ready_o,

  input [ADDR_W-1:0] pc, npc,
  output reg [DATA_W-1:0] inst_o
);
  parameter ADDR_W = 32;
  parameter DATA_W = 32;

  reg [ADDR_W-1:0] araddr;
  reg state, start = 0;
  `ysyx_BUS_FSM();
  always @(posedge clk) begin
    if (rst) begin
      valid_o <= 0; ready_o = 1; arvalid <= 1;
      araddr <= `ysyx_PC_INIT;
    end
    else begin
      if (state == `ysyx_IDLE & prev_valid) begin
        arvalid <= prev_valid;
        araddr <= npc;
      end
      else if (state == `ysyx_WAIT_READY) begin
        arvalid <= 0;
        if (next_ready == 1) begin valid_o <= 0; end
      end
    end
  end
  assign ready_o = !valid_o;

  reg arvalid;
  wire arready, awready, rready, wready, bvalid;
  wire [1:0] rresp, bresp;
  ysyx_IFU_LU_SRAM #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) ifu_sram(
    .clk(clk),
    .araddr(araddr), .arvalid(prev_valid | arvalid), .arready_o(arready),
    .rdata_o(inst_o), .rresp_o(rresp), .rvalid_o(valid_o), .rready(1'b1),

    .awaddr(0), .awvalid(0), .awready_o(awready),
    .wdata(0), .wmask(0), .wvalid(0), .wready_o(wready),
    .bresp_o(bresp), .bvalid_o(bvalid), .bready(0)
  );
endmodule // ysyx_IFU

module ysyx_IFU_LU_SRAM(
  input clk, 

  input [ADDR_W-1:0] araddr,
  input arvalid,
  output reg arready_o,

  output reg [DATA_W-1:0] rdata_o,
  output reg [1:0] rresp_o,
  output reg rvalid_o,
  input rready,

  input [ADDR_W-1:0] awaddr,
  input awvalid,
  output reg awready_o,
  input [DATA_W-1:0] wdata,
  input [7:0] wmask,
  input wvalid,
  output reg wready_o,
  output reg [1:0] bresp_o,
  output reg bvalid_o,
  input bready
);
  parameter ADDR_W = 32, DATA_W = 32;

  reg [DATA_W-1:0] inst_mem = 0;
  reg [20:0] delay = 1;
  always @(posedge clk) begin
    if (arvalid) begin
      delay <= {delay[19:0], delay[20]};
      // if (delay[5] == 1)
      begin
        pmem_read(araddr, inst_mem);
        rdata_o <= inst_mem;
        rvalid_o <= 1;
      end
    end else begin
      rvalid_o <= 0;
      delay <= 1;
    end
  end
endmodule
