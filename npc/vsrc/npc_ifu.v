`include "npc_common.v"

module ysyx_23060087_IFU #(ADDR_WIDTH = 64, DATA_WIDTH = 32)(
    input clk,
    input [ADDR_WIDTH-1:0] pc,
    input [DATA_WIDTH-1:0] inst,
    output reg [DATA_WIDTH-1:0] inst_o
);
    reg [31:0] inst_mem;
    assign inst_o = inst_mem;
    always @(posedge clk) begin
        inst_mem <= inst;
    end
endmodule // ysyx_23060087_IFU
