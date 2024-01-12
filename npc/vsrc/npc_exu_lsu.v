`include "npc_macro.v"

module ysyx_EXU_LSU(
  input clk,
  input ren, wen, avalid,
  input [3:0] alu_op,
  input [ADDR_W-1:0] addr,
  input [DATA_W-1:0] wdata,

  output reg [DATA_W-1:0] rdata_o,
  output rvalid_wready_o
);
  parameter ADDR_W = 32, DATA_W = 32;
  wire [DATA_W-1:0] rdata;
  reg [7:0] wstrb;
  assign rvalid_wready_o = (rvalid | wready) | (!avalid);

  reg [19:0] lfsr = 1;
  wire ifsr_ready = `ysyx_IFSR_ENABLE ? lfsr[19] : 1;
  always @(posedge clk ) begin lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]}; end
  wire rvalid, wvalid;
  wire arready, awready, wready, bvalid;
  wire [1:0] rresp, bresp;
  ysyx_MEM_SRAM lsu_sram(
    .clk(clk), 
    .araddr(addr), .arvalid(ifsr_ready & ren & avalid), .arready_o(arready),
    .rdata_o(rdata), .rresp_o(rresp), .rvalid_o(rvalid), .rready(ifsr_ready),
    .awaddr(addr), .awvalid(ifsr_ready & wen & avalid), .awready_o(awready),
    .wdata(wdata), .wstrb(wstrb), .wvalid(ifsr_ready & wen & avalid), .wready_o(wready),
    .bresp_o(bresp), .bvalid_o(bvalid), .bready(ifsr_ready)
    );

  // load/store unit
  always @(*) begin
    wstrb = 0; rdata_o = 0;
    if (wen) begin
      case (alu_op)
        `ysyx_ALU_OP_SB: begin wstrb = 8'h1; end
        `ysyx_ALU_OP_SH: begin wstrb = 8'h3; end
        `ysyx_ALU_OP_SW: begin wstrb = 8'hf; end
        default:         begin end
      endcase
    end
    if (ren) begin
      case (alu_op)
        `ysyx_ALU_OP_LB: begin
          if (rdata[7] == 1 && alu_op == `ysyx_ALU_OP_LB) begin
            rdata_o = rdata | 'hffffff00;
          end else begin
            rdata_o = rdata & 'hff;
          end
        end
        `ysyx_ALU_OP_LBU:  begin 
          rdata_o = rdata & 'hff;
        end
        `ysyx_ALU_OP_LH: begin
          if (rdata[15] == 1 && alu_op == `ysyx_ALU_OP_LH) begin
            rdata_o = rdata | 'hffff0000;
          end else begin
            rdata_o = rdata & 'hffff;
          end
        end
        `ysyx_ALU_OP_LHU:  begin
          rdata_o = rdata & 'hffff;
          end
        `ysyx_ALU_OP_LW:  begin rdata_o = rdata; end
        default:         begin end
      endcase
    end
  end

endmodule
