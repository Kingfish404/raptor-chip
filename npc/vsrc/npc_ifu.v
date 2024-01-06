`include "npc_macro.v"

module ysyx_IFU (
  input clk, rst,

  input wire prev_valid, next_ready,
  output reg valid_o, ready_o,

  input [ADDR_W-1:0] pc,
  output reg [DATA_W-1:0] inst_o
);
  parameter ADDR_W = 32;
  parameter DATA_W = 32;

  reg state;
  reg [DATA_W-1:0] inst_mem;
  `ysyx_BUS_FSM();
  always @(posedge clk) begin
    if (rst) begin
      valid_o <= 1; ready_o <= 0;
    end
    else begin
      if (state == `ysyx_IDLE) begin
        if (prev_valid == 1) begin valid_o <= 1; ready_o <= 0; end
      end
      else if (state == `ysyx_WAIT_READY) begin
        if (next_ready == 1) begin ready_o <= 1; valid_o <= 0; end
      end
      if (valid_o) begin
        inst_o <= inst_mem;
      end
    end
  end

  wire arready, awready, rready, wready, bvalid;
  wire [1:0] rresp, bresp;
  ysyx_IFU_LU_SRAM #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) ifu_sram(
    .clk(clk),
    .araddr(pc), .arvalid(valid_o), .arready_o(arready),
    .rdata_o(inst_mem), .rresp_o(rresp), .rvalid_o(valid_o), .rready(1'b1),

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

  reg [DATA_W-1:0] inst_mem;
  always @(posedge clk) begin
    if (arvalid) begin
      pmem_read(araddr, rdata_o);
      rvalid_o <= 1;
    end else begin
      rvalid_o <= 0;
    end
  end
endmodule
